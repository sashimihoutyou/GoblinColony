extends Node2D
class_name Renderer
## 描画層 (§4-3)。render(world, delta) で渡された状態を描くだけで、シム状態には
## 一切書き込まない。個体の「見た目の位置」(タイル間の補間)・パーティクル・
## 昼夜トーンはすべてこの層のローカル状態 (KI-09 セーフ)。
##
## ビジュアルは Web 版ダッシュボード (viz/dashboard_template.html) の移植:
## 闇に沈んだ洞窟・琥珀の信仰の炎・耳と目を持つゴブリンスプライト・粒子演出。

var tile_size: int = 16
var sel_kind: int = 0   # 0=なし / 1=ゴブリン / 2=敵 / 3=部屋 / 4=出現物 (main.gd SelKind と対応)
var sel_id: int = -1
# 建築ゴースト (§3-15)。main.gd が毎フレーム設定する {x,y,w,h,ok} (空 = 非建築モード)。
var build_ghost: Dictionary = {}

var _world: World = null
var _font: Font
var _t: float = 0.0            # 演出時計 (実時間)
var _night: float = 0.0        # 昼夜トーン (0=昼, 1=夜。滑らかに追従)
var _sim_speed: float = 1.0    # 停止中は吐息など演出を止めるフラグ
var _ticked: bool = false      # on_tick を一度でも経たか (初回フレームのフォールバック判定)

# --- Web 版と同じ色言語 ---
const COL_FLOOR := Color("1d150c")
const COL_FLOOR_DARK := Color("150f09")
const COL_WALL := Color("0b0805")
const COL_WALL_EDGE := Color("3a3228")
const COL_EXTERIOR := Color("11140d")
const COL_ROCK := Color("241e16")
const COL_BONE := Color("cbbfa6")
const COL_EMBER := Color("e8943a")
const COL_EMBER_BRIGHT := Color("ffb454")
const COL_INK_FAINT := Color(0.353, 0.310, 0.251, 0.75)

const STATE_COLORS := {
	Goblin.State.COMBAT: Color("c0432e"),
	Goblin.State.FEAR: Color("9a6bb0"),
	Goblin.State.DYING: Color("7a4030"),
	Goblin.State.HUNGRY: Color("c08a3a"),
	Goblin.State.SLEEP: Color("4a6b8a"),
	Goblin.State.WORK: Color("7a9a4e"),
	Goblin.State.WANDER: Color("8a7d68"),
	Goblin.State.ENRAGED: Color("ff5530"),
	Goblin.State.KNOCKED_OUT: Color("6a4838"),
}

# --- 演出層の個体状態: id → {prev: Vector2, cur: Vector2, pos: Vector2, face: float} ---
# tick 間は prev→cur を線形補間する (固定タイムステップ補間)。シムの fx/fy へ
# 毎フレーム直接追従すると、座標が 4Hz (1x 時) でステップ更新されるため
# 「tick 直後に加速→次 tick まで減速」のラバーバンド脈動 = カクつきが出る。
# on_tick で prev←cur, cur←最新位置 を確定し、render で α (tick 端数) 補間する。
var _gmap: Dictionary = {}
var _emap: Dictionary = {}
var _mmap: Dictionary = {}   # パン虫 (§3-11)。ゴブリン・敵と同じ補間管理

# --- パーティクル: {kind,x,y,vx,vy,g,life,max_life,size,color,txt} ---
var _particles: Array = []

# --- 静的装飾 (terrain から一度だけ計算。terrain 変化で再計算) ---
var _decor: Array = []
var _terrain_hash: int = 0

func _ready() -> void:
	_font = ThemeDB.fallback_font

# ── tick 確定時: 各ユニットの prev←cur を確定し cur を最新位置へ進める ──
# main が tick ごとに呼ぶ (1 フレームに複数 tick 回れば毎回)。O(個体数) の座標コピーのみ。
func on_tick(world: World) -> void:
	_world = world
	_ticked = true
	var seen := {}
	for g in world.goblins:
		if g.state == Goblin.State.DEAD:
			continue
		seen[g.id] = true
		_advance_entry(_gmap, g.id, _unit_pixel(g))
	# 巣から消えた個体 (死亡/巣立ち。イベント側で fx 済み) を演出層からも除く。
	for id in _gmap.keys():
		if not seen.has(id):
			_gmap.erase(id)
	# 敵。
	var eseen := {}
	for e in world.enemies:
		eseen[e.id] = true
		_advance_entry(_emap, e.id, _unit_pixel(e))
	for id in _emap.keys():
		if not eseen.has(id):
			# 撃破された敵: 血色の破片 (補間位置から)。
			var v3: Dictionary = _emap[id]
			_burst(v3.pos, 4, {"speed": 26.0, "life": 0.5, "size": 1.2, "color": Color("c0432e")})
			_emap.erase(id)
	# パン虫 (消滅時は静かに消える。捕食バーストは on_event 側で出す)。
	var mseen := {}
	for m in world.mites:
		mseen[m.id] = true
		_advance_entry(_mmap, m.id, _unit_pixel(m))
	for mid in _mmap.keys():
		if not mseen.has(mid):
			_mmap.erase(mid)

## エントリの prev/cur を進める。新規 (出生・襲撃出現) は prev=cur=now で登録。
func _advance_entry(m: Dictionary, id: int, now: Vector2) -> void:
	if not m.has(id):
		m[id] = {"prev": now, "cur": now, "pos": now, "face": 1.0}
		return
	var v: Dictionary = m[id]
	v.prev = v.cur
	v.cur = now
	# face は十分な水平移動があるときだけ更新 (既存の 0.5px 閾値を踏襲)。
	if absf(now.x - (v.prev as Vector2).x) > 0.5:
		v.face = 1.0 if now.x > (v.prev as Vector2).x else -1.0

# ── メイン入口: 毎フレーム呼ぶ。alpha = tick 端数 (0..1, 呼び出し側で clamp 済み) ──
func render(world: World, delta: float, sim_speed: float, alpha: float) -> void:
	_world = world
	_sim_speed = sim_speed
	_t += delta
	# まだ on_tick を一度も経ていない初回フレームはエントリを初期化 (フォールバック)。
	if not _ticked:
		on_tick(world)
	_update_decor()
	_update_units(alpha)
	_update_particles((delta if sim_speed > 0.0 else 0.0) * maxf(sim_speed, 1.0))
	# 昼夜トーンは常に滑らかに追従 (停止中も見た目は保持)。
	var target := 0.0 if world.is_day() else 1.0
	_night = lerpf(_night, target, minf(1.0, delta * 1.5))
	queue_redraw()

## シムイベントを演出へ翻訳する (main が tick ごとに転送)。
func on_event(e: Dictionary) -> void:
	var t: String = e.get("t", "")
	match t:
		"death":
			var at := _last_pos_of(int(e.get("id", -1)))
			if at != Vector2.ZERO:
				_burst(at, 5, {"kind": "bone", "speed": 22.0, "up": 16.0, "g": 70.0,
					"life": 1.1, "size": 2.2, "color": COL_BONE})
		"fledge":
			var at2 := _last_pos_of(int(e.get("id", -1)))
			if at2 != Vector2.ZERO:
				_burst(at2, 4, {"speed": 14.0, "life": 0.8, "size": 1.0, "color": Color("8a7d68")})
		"birth":
			var at3 := _last_pos_of(int(e.get("mother", -1)))
			if at3 != Vector2.ZERO:
				_burst(at3, 6, {"speed": 16.0, "up": 8.0, "life": 0.9, "size": 1.2, "color": Color("9adb6e")})
		"court":
			# 誘い: 雌の足元から小さなハートがふわっと上がる (演出層ローカル)。
			var atc := _last_pos_of(int(e.get("f", -1)))
			if atc != Vector2.ZERO:
				_spawn_p({"kind": "text", "txt": "♥", "color": Color("e8a0b8"),
					"x": atc.x, "y": atc.y - 6.0, "vy": -9.0, "life": 1.0, "size": 6.0})
		"pregnant":
			var at4 := _last_pos_of(int(e.get("id", -1)))
			if at4 != Vector2.ZERO:
				_spawn_p({"kind": "text", "txt": "♥", "color": Color("e8a0b8"),
					"x": at4.x, "y": at4.y - 8.0, "vy": -12.0, "life": 1.4, "size": 8.0})
		"surge":
			var c := _tile_center(_world.map.totem)
			_burst(c, 10, {"speed": 30.0, "life": 0.9, "size": 1.4, "color": Color("c0432e")})
		"mite_eaten":
			# パン虫を捕食: 小さな緑系バースト (捕食したゴブリンの補間位置から)。
			var atm := _last_pos_of(int(e.get("id", -1)))
			if atm != Vector2.ZERO:
				_burst(atm, 4, {"speed": 16.0, "life": 0.6, "size": 1.1, "color": Color("9adb6e")})
		"fumble":
			# すっ転んだ: 足元に土埃の小バースト。
			var atf := _last_pos_of(int(e.get("id", -1)))
			if atf != Vector2.ZERO:
				_burst(atf, 3, {"speed": 10.0, "life": 0.5, "size": 1.4, "color": Color("8a7d68")})
		"quarrel":
			# ケンカ: 双方の間に "!" を表示。
			var atq := _last_pos_of(int(e.get("a", -1)))
			if atq != Vector2.ZERO:
				_spawn_p({"kind": "text", "txt": "!", "color": Color("e06a50"),
					"x": atq.x, "y": atq.y - 8.0, "vy": -10.0, "life": 1.0, "size": 8.0})
		"lightning":
			# 嘲りの稲妻 (§4): 着弾点 (ピクセル座標を直接受け取る) に青白い閃光バースト
			# + "⚡"。敵を指すので _last_pos_of (ゴブリン用) は使わない。
			var lx := float(e.get("x", 0.0))
			var ly := float(e.get("y", 0.0))
			_burst(Vector2(lx, ly), 14, {"speed": 60.0, "life": 0.5, "size": 2.0, "color": Color("cfe6ff")})
			_spawn_p({"kind": "text", "txt": "⚡", "color": Color("e8e0ff"),
				"x": lx, "y": ly - 10.0, "vy": -14.0, "life": 0.9, "size": 12.0})
		"field_haul":
			# 巣外の恵みを集積所へ届けた瞬間: 小さな琥珀の粒バースト (採集と同じ扱い)。
			if _world != null:
				_burst(_tile_center(_world.map.storage), 4,
					{"speed": 14.0, "up": 6.0, "life": 0.6, "size": 1.1, "color": COL_EMBER})

## クリック位置 (ワールド座標) から最寄りの生存ゴブリン id を返す (-1 = なし)。
func pick(world: World, pos: Vector2) -> int:
	var best := -1
	var best_d := tile_size * 1.3
	for g in world.goblins:
		if g.state == Goblin.State.DEAD:
			continue
		var v: Dictionary = _gmap.get(g.id, {})
		if v.is_empty():
			continue
		var d: float = (v.pos as Vector2).distance_to(pos)
		if d < best_d:
			best_d = d
			best = g.id
	return best

## クリック位置から対象を拾う。{kind, id} を返す (kind: 0=なし/1=ゴブリン/2=敵/
## 3=部屋/4=出現物)。優先: ユニット (ゴブリン→敵) → 出現物の近接、外れたら部屋矩形。
## 将来の奇跡ターゲティングでも再利用する (敵を指してキャスト等)。
func pick_any(world: World, pos: Vector2) -> Dictionary:
	# 1) 最寄りの生存ゴブリン (既存 pick と同じ近接判定)。
	var gid := pick(world, pos)
	if gid >= 0:
		return {"kind": 1, "id": gid}
	# 2) 最寄りの生存敵 (補間位置 _emap で判定)。
	var best := -1
	var best_d := tile_size * 1.3
	for e in world.enemies:
		if e.hp <= 0.0:
			continue
		var v: Dictionary = _emap.get(e.id, {})
		if v.is_empty():
			continue
		var d: float = (v.pos as Vector2).distance_to(pos)
		if d < best_d:
			best_d = d
			best = e.id
	if best >= 0:
		return {"kind": 2, "id": best}
	# 3) 巣外の出現物 (タイル中心の近接判定。静止しているので補間不要)。
	for f in world.field_resources:
		if _tile_center(f.pos()).distance_to(pos) < tile_size * 1.3:
			return {"kind": 4, "id": f.id}
	# 4) 部屋矩形 (タイル座標で内包判定)。
	var tx := int(floor(pos.x / tile_size))
	var ty := int(floor(pos.y / tile_size))
	for i in world.map.rooms.size():
		var r: Dictionary = world.map.rooms[i]
		if tx >= r.x and tx < r.x + r.w and ty >= r.y and ty < r.y + r.h:
			return {"kind": 3, "id": i}
	return {"kind": 0, "id": -1}

# ════ 内部: 補間移動 ════
# 各エントリの pos を prev→cur の線形補間で求める (固定タイムステップ補間)。
# 出現/消滅の管理は on_tick 側で済んでいるので、ここは毎フレームの位置算出だけ。
# alpha は tick 端数 (0..1)。停止中は alpha が固定され自然に静止する。
func _update_units(alpha: float) -> void:
	for id in _gmap:
		var v: Dictionary = _gmap[id]
		v.pos = (v.prev as Vector2).lerp(v.cur as Vector2, alpha)
	for id in _emap:
		var v2: Dictionary = _emap[id]
		v2.pos = (v2.prev as Vector2).lerp(v2.cur as Vector2, alpha)

func _last_pos_of(id: int) -> Vector2:
	var v: Dictionary = _gmap.get(id, {})
	if v.is_empty():
		return Vector2.ZERO
	return v.pos

## 個体の補間描画位置 (_gmap の pos) をワールド座標で返す。fx/fy 直読みだと
## tick 刻みでカクつくため、カメラ追従にはこちらを使う。未登録/消滅時は
## Vector2.INF (原点 ZERO と区別できる番兵)。
func unit_screen_pos(id: int) -> Vector2:
	var v: Dictionary = _gmap.get(id, {})
	if v.is_empty():
		return Vector2.INF
	return v.pos

func _tile_center(t: Vector2i) -> Vector2:
	return Vector2((t.x + 0.5) * tile_size, (t.y + 0.5) * tile_size)

## 個体の連続座標 (fx/fy) → ピクセル位置。fx=3.0 はタイル 3 の中心。
func _unit_pixel(unit) -> Vector2:
	return Vector2((unit.fx + 0.5) * tile_size, (unit.fy + 0.5) * tile_size)

# ════ 内部: パーティクル ════
func _spawn_p(o: Dictionary) -> void:
	if _particles.size() > 300:
		_particles = _particles.slice(40)
	_particles.append({
		"kind": o.get("kind", "dot"), "x": o.get("x", 0.0), "y": o.get("y", 0.0),
		"vx": o.get("vx", 0.0), "vy": o.get("vy", 0.0), "g": o.get("g", 0.0),
		"life": o.get("life", 1.0), "max_life": o.get("life", 1.0),
		"size": o.get("size", 2.0), "color": o.get("color", COL_BONE),
		"txt": o.get("txt", ""),
	})

func _burst(at: Vector2, n: int, opts: Dictionary) -> void:
	for i in range(n):
		var a := randf() * TAU
		var sp: float = float(opts.get("speed", 24.0)) * (0.4 + randf() * 0.9)
		var d := opts.duplicate()
		d.x = at.x
		d.y = at.y
		d.vx = cos(a) * sp
		d.vy = sin(a) * sp - float(opts.get("up", 0.0))
		_spawn_p(d)

func _update_particles(dt: float) -> void:
	if dt <= 0.0:
		return
	for i in range(_particles.size() - 1, -1, -1):
		var pt: Dictionary = _particles[i]
		pt.life -= dt
		if pt.life <= 0.0:
			_particles.remove_at(i)
			continue
		pt.x += pt.vx * dt
		pt.y += pt.vy * dt
		pt.vy += pt.g * dt

# ════ 内部: 静的装飾の事前計算 ════
func _update_decor() -> void:
	if _world == null:
		return
	var h := 0
	for v in _world.map.terrain:
		h = ((h * 31) + int(v)) & 0x7FFFFFFF
	# 建築完了 (§3-15) は地形を変えずに部屋を増やすので、部屋数もキーに含める。
	h = ((h * 31) + _world.map.rooms.size()) & 0x7FFFFFFF
	if h == _terrain_hash and not _decor.is_empty():
		return
	_terrain_hash = h
	_decor.clear()
	var m := _world.map
	var ts := float(tile_size)
	for y in range(m.height):
		for x in range(m.width):
			var t := m.get_tile(x, y)
			var hh := GobNames.hash_id(x * 73856093 + y * 19349663)
			var px := (x + 0.5) * ts
			var py := (y + 0.5) * ts
			match t:
				TileMapData.TileType.FLOOR:
					if hh % 100 < 24:  # 床の染み
						_decor.append({"kind": "rect", "x": px - 2 + (hh % 5), "y": py - 2 + ((hh >> 4) % 5),
							"w": 2.0, "h": 2.0, "color": Color(0.06, 0.04, 0.025, 0.8)})
					elif hh % 100 < 30:  # 小石
						_decor.append({"kind": "circle", "x": px + (hh % 7) - 3, "y": py + ((hh >> 5) % 7) - 3,
							"r": 1.2, "color": Color(0.16, 0.13, 0.09)})
				TileMapData.TileType.EXTERIOR:
					if hh % 100 < 18:  # 外の草
						_decor.append({"kind": "line", "x1": px, "y1": py + 3.0, "x2": px + float(hh % 5) - 2.0,
							"y2": py - 3.0, "w": 1.0, "color": Color(0.13, 0.18, 0.10)})
					elif hh % 100 < 23:
						_decor.append({"kind": "circle", "x": px, "y": py, "r": 1.4, "color": Color(0.10, 0.10, 0.08)})
				TileMapData.TileType.RESOURCE_NODE:
					# 岩塊 + 金鉱脈のきらめき。
					_decor.append({"kind": "circle", "x": px, "y": py, "r": ts * 0.34, "color": COL_ROCK})
					_decor.append({"kind": "rect", "x": px - 2, "y": py - 2, "w": 2.0, "h": 2.0, "color": Color("e8c060")})
					_decor.append({"kind": "rect", "x": px + 2, "y": py + 1, "w": 1.5, "h": 1.5, "color": Color("e8c060")})
				TileMapData.TileType.EXHAUSTED:
					# 掘り尽くした跡: きらめきのない砕けた岩屑。
					_decor.append({"kind": "circle", "x": px - 2.0, "y": py + 1.0, "r": 2.2, "color": COL_ROCK})
					_decor.append({"kind": "circle", "x": px + 2.5, "y": py - 1.5, "r": 1.6, "color": COL_ROCK})
					_decor.append({"kind": "circle", "x": px + 1.0, "y": py + 3.0, "r": 1.2, "color": COL_ROCK})
				TileMapData.TileType.STORAGE:
					# キノコと骨の備蓄。
					for k in range(3):
						var mx := px + float(((hh >> (k * 3)) % 9)) - 4.0
						var my := py + float(((hh >> (k * 3 + 2)) % 7)) - 3.0
						_decor.append({"kind": "rect", "x": mx - 0.7, "y": my - 2.0, "w": 1.4, "h": 3.0, "color": Color("3a2d20")})
						_decor.append({"kind": "circle", "x": mx, "y": my - 2.5, "r": 2.0,
							"color": Color("9a5b3c") if k % 2 == 0 else Color("7a6f4e")})
					_decor.append({"kind": "line", "x1": px - 4.0, "y1": py + 5.0, "x2": px + 3.0, "y2": py + 2.0,
						"w": 1.2, "color": Color("8a8070")})
				TileMapData.TileType.GATE:
					# 巣口の骨の門柱。
					_decor.append({"kind": "rect", "x": px - ts * 0.42, "y": py - ts * 0.45, "w": 2.2, "h": ts * 0.9, "color": COL_BONE * Color(1, 1, 1, 0.5)})
					_decor.append({"kind": "rect", "x": px + ts * 0.28, "y": py - ts * 0.45, "w": 2.2, "h": ts * 0.9, "color": COL_BONE * Color(1, 1, 1, 0.5)})
	# 部屋の装飾 + 名札。
	for r in m.rooms:
		var rx0: float = float(r.x)
		var ry0: float = float(r.y)
		var rw: float = float(r.w)
		var rh0: float = float(r.h)
		var cx: float = (rx0 + rw / 2.0) * ts
		if r.room_type == TileMapData.RoomType.NEST:
			for k in range(3):
				var bh := GobNames.hash_id(700 + k * 37)
				var bx: float = (rx0 + 0.7 + float(bh % (maxi(int(rw) - 1, 1) * 10)) / 10.0) * ts
				var by: float = (ry0 + 0.7 + float((bh >> 6) % (maxi(int(rh0) - 1, 1) * 10)) / 10.0) * ts
				_decor.append({"kind": "ellipse", "x": bx, "y": by, "rx": 6.5, "ry": 3.5, "color": Color("2c2010")})
				for s in range(3):
					_decor.append({"kind": "line", "x1": bx - 4.0 + s * 3.0, "y1": by + 2.0,
						"x2": bx - 2.0 + s * 3.0, "y2": by - 2.5, "w": 0.8, "color": Color("4a3a1c")})
			_decor.append({"kind": "text", "x": cx, "y": ry0 * ts - 2.0, "txt": "寝床", "color": COL_INK_FAINT})
		elif r.room_type == TileMapData.RoomType.RAT_RANCH:
			for k in range(2):
				var rh := GobNames.hash_id(900 + k * 53)
				var ratx: float = (rx0 + 0.8 + float(rh % (maxi(int(rw) - 1, 1) * 10)) / 10.0) * ts
				var raty: float = (ry0 + 0.8 + float((rh >> 5) % (maxi(int(rh0) - 1, 1) * 10)) / 10.0) * ts
				_decor.append({"kind": "ellipse", "x": ratx, "y": raty, "rx": 2.6, "ry": 1.6, "color": Color("4a3b2a")})
				_decor.append({"kind": "line", "x1": ratx + 2.4, "y1": raty, "x2": ratx + 5.0, "y2": raty - 1.0, "w": 0.7, "color": Color("4a3b2a")})
			_decor.append({"kind": "text", "x": cx, "y": ry0 * ts - 2.0, "txt": "ネズミ牧場", "color": COL_INK_FAINT})
		else:
			# 建築で増える部屋 (§3-15): 名札のみ (固有の装飾は各機能の実装時に)。
			var jp: String = {
				TileMapData.RoomType.MUSHROOM: "キノコ農園",
				TileMapData.RoomType.SMITHY: "泥鍛冶屋",
				TileMapData.RoomType.NURSERY: "苗床",
				TileMapData.RoomType.WITCH: "まじない医",
			}.get(r.room_type, "")
			if jp != "":
				_decor.append({"kind": "text", "x": cx, "y": ry0 * ts - 2.0, "txt": jp, "color": COL_INK_FAINT})
	# 名札: 集積所・トーテム。
	_decor.append({"kind": "text", "x": (m.storage.x + 0.5) * ts, "y": (m.storage.y as float) * ts - 2.0, "txt": "食料庫", "color": COL_INK_FAINT})
	_decor.append({"kind": "text", "x": (m.totem.x + 0.5) * ts, "y": (m.totem.y - 1.2) * ts, "txt": "トーテム", "color": COL_INK_FAINT})

# ════ 描画 ════
func _draw() -> void:
	if _world == null:
		return
	var m := _world.map
	var ts := float(tile_size)

	# --- タイル ---
	for y in range(m.height):
		for x in range(m.width):
			var t := m.terrain[m.idx(x, y)]
			var rect := Rect2(x * ts, y * ts, ts, ts)
			match t:
				TileMapData.TileType.WALL:
					# 岩肌: ハッシュでわずかな明暗 (一枚岩に見せない)。
					var wh := GobNames.hash_id(x * 73856093 + y * 19349663)
					draw_rect(rect, COL_WALL.lerp(COL_ROCK, float(wh % 100) / 480.0), true)
					# 立体感: 下が歩行可なら南面に明るい縁 (壁の高さ)。
					if m.is_walkable(x, y + 1):
						draw_rect(Rect2(x * ts, y * ts + ts - 3.0, ts, 3.0), COL_WALL_EDGE, true)
				TileMapData.TileType.EXTERIOR:
					draw_rect(rect, COL_EXTERIOR, true)
				TileMapData.TileType.TOTEM:
					draw_rect(rect, COL_FLOOR_DARK, true)
				_:
					# 床系: ハッシュでわずかに明暗を散らし岩肌に。
					var hh := GobNames.hash_id(x * 73856093 + y * 19349663)
					var base := COL_FLOOR.lerp(COL_FLOOR_DARK, float(hh % 100) / 250.0)
					draw_rect(rect, base, true)
			# 洞窟の奥行き: 壁の根本 (北側が壁) の歩行可タイルに影を落とす。
			if t != TileMapData.TileType.WALL:
				if m.get_tile(x, y - 1) == TileMapData.TileType.WALL:
					draw_rect(Rect2(x * ts, y * ts, ts, 3.5), Color(0, 0, 0, 0.32), true)
				if m.get_tile(x - 1, y) == TileMapData.TileType.WALL:
					draw_rect(Rect2(x * ts, y * ts, 2.5, ts), Color(0, 0, 0, 0.18), true)

	# --- 静的装飾 ---
	for d in _decor:
		_draw_decor(d)

	# --- キノコ床 (T4 採集スポット。生長済みは明るく、再生長中はしぼむ) ---
	# forage_regrow は毎 tick 変わる動的状態なので decor キャッシュに乗せず直接描く。
	for i in range(m.forage_spots.size()):
		var grown: bool = (i < m.forage_regrow.size()) and m.forage_regrow[i] == 0
		_draw_forage(_tile_center(m.forage_spots[i] as Vector2i), i, grown)

	# --- 破壊予告 (§3-20)。壁破壊役が狙う壁を脈動する警告色でハイライト ---
	_draw_breach_warnings(ts)
	# --- ジョブ指示 (§3-12) + 建築ゴースト (§3-15)。動的状態なので直接描く ---
	_draw_jobs(ts)
	if not build_ghost.is_empty():
		var gr := Rect2(float(build_ghost.x) * ts, float(build_ghost.y) * ts,
				float(build_ghost.w) * ts, float(build_ghost.h) * ts)
		var okc := Color(0.55, 0.85, 0.45, 0.22) if bool(build_ghost.ok) else Color(0.85, 0.30, 0.20, 0.20)
		draw_rect(gr, okc, true)
		draw_rect(gr, Color(okc.r, okc.g, okc.b, 0.8), false, 2.0)

	# --- トーテム像 + 炎 ---
	_draw_totem(m)

	# --- 巣外の出現物 (§11.5 木の実の茂み。amount は毎 tick 変わるので直接描く) ---
	for f in _world.field_resources:
		_draw_field_resource(f)

	# --- パン虫 (補間位置。床の上をうろつく食用ザコ) ---
	for mu in _world.mites:
		var vm: Dictionary = _mmap.get(mu.id, {})
		if vm.is_empty():
			continue
		_draw_mite(vm.pos as Vector2, mu.id)

	# --- 敵 (補間位置) ---
	for e in _world.enemies:
		var v: Dictionary = _emap.get(e.id, {})
		if v.is_empty():
			continue
		_draw_enemy(v.pos as Vector2, e, float(v.face))

	# --- ゴブリン (y ソートで擬似奥行き) ---
	var order: Array = []
	for g in _world.goblins:
		if g.state == Goblin.State.DEAD:
			continue
		if _gmap.has(g.id):
			order.append(g)
	order.sort_custom(func(a, b): return (_gmap[a.id].pos as Vector2).y < (_gmap[b.id].pos as Vector2).y)
	for g in order:
		var v2: Dictionary = _gmap[g.id]
		_draw_goblin(v2.pos as Vector2, g, float(v2.face))

	# --- パーティクル ---
	for pt in _particles:
		_draw_particle(pt)

	# --- 昼夜トーン (夜は青く沈む) ---
	if _night > 0.02:
		draw_rect(Rect2(0, 0, m.width * ts, m.height * ts), Color(0.03, 0.055, 0.125, _night * 0.38), true)

	# --- 交戦ヴィネット ---
	if _world.phase == World.Phase.COMBAT:
		var wpx := m.width * ts
		var hpx := m.height * ts
		var a := 0.07 + 0.03 * sin(_t * 4.0)
		var red := Color(0.75, 0.26, 0.18, a)
		draw_rect(Rect2(0, 0, wpx, 6), red, true)
		draw_rect(Rect2(0, hpx - 6, wpx, 6), red, true)
		draw_rect(Rect2(0, 0, 6, hpx), red, true)
		draw_rect(Rect2(wpx - 6, 0, 6, hpx), red, true)

	# --- 選択中の対象 (ゴブリン/敵/部屋) ---
	match sel_kind:
		1:  # ゴブリン: 名前つきの淡い輪
			if _gmap.has(sel_id):
				var g3 := _find_goblin(sel_id)
				if g3 != null:
					var pos: Vector2 = _gmap[sel_id].pos
					draw_arc(pos, ts * 0.55 + sin(_t * 5.0) * 1.2, 0, TAU, 24, Color("e8dcc8"), 1.0)
					var nm := GobNames.of(g3)
					_draw_text_crisp(pos + Vector2(0, -ts * 0.8), nm, 9, Color("e8dcc8"))
		2:  # 敵: 血色の輪
			if _emap.has(sel_id):
				var epos: Vector2 = _emap[sel_id].pos
				draw_arc(epos, ts * 0.55 + sin(_t * 5.0) * 1.2, 0, TAU, 24, Color("c0432e"), 1.5)
		3:  # 部屋: 矩形のアウトライン
			if sel_id >= 0 and sel_id < _world.map.rooms.size():
				var r: Dictionary = _world.map.rooms[sel_id]
				draw_rect(Rect2(r.x * ts, r.y * ts, r.w * ts, r.h * ts), Color("e8dcc8", 0.85), false, 1.5)
		4:  # 出現物: 琥珀の輪 (回収/日没で消えたら輪も消える)
			for f in _world.field_resources:
				if f.id == sel_id:
					draw_arc(_tile_center(f.pos()), ts * 0.7 + sin(_t * 5.0) * 1.2, 0, TAU, 24,
						COL_EMBER_BRIGHT, 1.2)
					break

## ズーム下でも文字がにじまない draw_string。Camera2D の zoom はフォントの
## オーバーサンプリングに反映されない (Godot の既知の制約) ため、小サイズで
## ラスタライズされたグリフが拡大されてガタつく。ズーム倍率をフォントサイズへ
## 織り込んで実効ピクセルサイズでラスタライズし、逆スケールで見た目のサイズへ
## 戻す (システムフォールバック由来のカナにも効く)。
## ジョブ指示の印 (§3-12)。採掘=琥珀の脈動枠 / 建設=予定地の枠 + 進捗バー /
## 修復=青白い脈動枠。プレイヤーの指示が画面に残っていることを示す。
func _draw_jobs(ts: float) -> void:
	var pulse := 0.45 + 0.25 * sin(_t * 3.0)
	for j in _world.jobs:
		match int(j.type):
			World.JobType.MINE:
				var r := Rect2(float(j.x) * ts + 1.0, float(j.y) * ts + 1.0, ts - 2.0, ts - 2.0)
				draw_rect(r, Color(0.95, 0.75, 0.30, pulse), false, 1.5)
			World.JobType.DIG:
				# 掘削指定 (§10): 土色の破線風枠 + 進捗の塗り (採掘とは別色)。
				var dr := Rect2(float(j.x) * ts + 1.0, float(j.y) * ts + 1.0, ts - 2.0, ts - 2.0)
				draw_rect(dr, Color(0.55, 0.42, 0.26, 0.18 + 0.4 * clampf(float(j.progress), 0.0, 1.0)), true)
				draw_rect(dr, Color(0.72, 0.56, 0.34, pulse), false, 1.5)
			World.JobType.BUILD:
				var br := Rect2(float(j.x) * ts, float(j.y) * ts,
						float(j.w) * ts, float(j.h) * ts)
				draw_rect(br, Color(0.85, 0.70, 0.40, 0.08), true)
				draw_rect(br, Color(0.85, 0.70, 0.40, 0.55), false, 1.5)
				var pw := br.size.x * clampf(float(j.progress), 0.0, 1.0)
				draw_rect(Rect2(br.position.x, br.position.y - 4.0, br.size.x, 3.0), Color(0, 0, 0, 0.5), true)
				draw_rect(Rect2(br.position.x, br.position.y - 4.0, pw, 3.0), COL_EMBER, true)
			World.JobType.REPAIR:
				var rr := Rect2(float(j.x) * ts + 2.0, float(j.y) * ts + 2.0, ts - 4.0, ts - 4.0)
				draw_rect(rr, Color(0.60, 0.85, 0.95, pulse * 0.8), false, 1.5)

## 破壊予告 (§3-20)。狙われている壁を赤い脈動でハイライトし、残り tick (秒目安) を
## 添える。eta が短いほど明滅が速く強くなる (「割られる前にもう一枚」の緊張)。
func _draw_breach_warnings(ts: float) -> void:
	for bw in _world.breach_warnings:
		var eta: int = int(bw.eta_ticks)
		var urgency := clampf(1.0 - float(eta) / 120.0, 0.2, 1.0)  # 0.5 日で最大
		var pulse := 0.35 + 0.4 * urgency * (0.5 + 0.5 * sin(_t * (3.0 + 5.0 * urgency)))
		var r := Rect2(float(bw.x) * ts, float(bw.y) * ts, ts, ts)
		draw_rect(r, Color(0.85, 0.20, 0.12, pulse * 0.5), true)
		draw_rect(r, Color(0.95, 0.35, 0.20, pulse), false, 2.0)
		# 残り秒の目安 (1 tick = MS_PER_TICK。ざっくり tick/3 ≒ 秒)。
		var secs := maxi(1, int(round(float(eta) / 2.67)))
		_draw_text_crisp(Vector2((bw.x + 0.5) * ts, float(bw.y) * ts - 3.0),
				"⚠%d" % secs, 9.0, Color(0.98, 0.55, 0.35), HORIZONTAL_ALIGNMENT_CENTER, 40.0)

func _draw_text_crisp(at: Vector2, txt: String, size: float, color: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER, width: float = 60.0) -> void:
	if _font == null:
		return
	var k: float = maxf(1.0, get_viewport_transform().get_scale().x)
	var fs: int = maxi(1, roundi(size * k))
	draw_set_transform(at, 0.0, Vector2.ONE / k)
	var off_x: float = -width * 0.5 * k if width > 0.0 else 0.0
	var w: float = width * k if width > 0.0 else -1.0
	draw_string(_font, Vector2(off_x, 0), txt, align, w, fs, color)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _find_goblin(id: int) -> Goblin:
	for g in _world.goblins:
		if g.id == id:
			return g
	return null

func _draw_decor(d: Dictionary) -> void:
	match d.kind:
		"rect":
			draw_rect(Rect2(d.x, d.y, d.w, d.h), d.color, true)
		"circle":
			draw_circle(Vector2(d.x, d.y), d.r, d.color)
		"ellipse":
			# 楕円: スケールした円弧で代用 (draw_set_transform)。
			draw_set_transform(Vector2(d.x, d.y), 0.0, Vector2(1.0, float(d.ry) / float(d.rx)))
			draw_circle(Vector2.ZERO, d.rx, d.color)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		"line":
			draw_line(Vector2(d.x1, d.y1), Vector2(d.x2, d.y2), d.color, d.w)
		"text":
			_draw_text_crisp(Vector2(d.x, d.y), d.txt, 8, d.color)

## 巣外の出現物 (§11.5): 木の実の茂み。暗い緑の塊 + 残量ぶんの琥珀の実 +
## 気づきやすいようゆっくり明滅する淡い輪 (すべて演出。シム状態に触れない)。
func _draw_field_resource(f: FieldResource) -> void:
	var c := _tile_center(f.pos())
	var ts := float(tile_size)
	# 明滅する淡いハイライト輪 (約 3 秒周期)。
	var pulse := 0.5 + 0.5 * sin(_t * 2.1)
	draw_arc(c, ts * 0.75, 0, TAU, 20, Color(COL_EMBER_BRIGHT, 0.10 + 0.18 * pulse), 1.0)
	# 茂み (3 つの塊で有機的に)。
	draw_circle(c + Vector2(-3.0, 1.0), 4.0, Color("2e4023"))
	draw_circle(c + Vector2(3.0, 1.0), 3.6, Color("36492a"))
	draw_circle(c + Vector2(0.0, -2.0), 4.2, Color("3f5430"))
	# 実: 残量ぶんの琥珀の粒 (決定的配置。摘まれると減っていく)。
	const BERRY_OFFS := [
		Vector2(-4.0, -1.0), Vector2(3.0, -3.0), Vector2(0.0, 2.0),
		Vector2(-2.0, -4.0), Vector2(4.0, 0.0),
	]
	for i in range(mini(f.amount, BERRY_OFFS.size())):
		draw_circle(c + BERRY_OFFS[i], 1.3, COL_EMBER_BRIGHT)

func _draw_totem(m: TileMapData) -> void:
	var c := _tile_center(m.totem)
	var ts := float(tile_size)
	# 影 + 柱 + 笠 + 彫られた目。
	_ellipse(c + Vector2(0, ts * 0.4), ts * 0.5, ts * 0.16, Color(0, 0, 0, 0.4))
	draw_rect(Rect2(c.x - 3.5, c.y - 14.0, 7.0, 18.0), Color("3a2a18"), true)
	draw_rect(Rect2(c.x - 5.5, c.y - 17.0, 11.0, 4.0), Color("241a0e"), true)
	draw_rect(Rect2(c.x - 2.5, c.y - 10.0, 2.0, 2.0), COL_EMBER, true)
	draw_rect(Rect2(c.x + 0.5, c.y - 10.0, 2.0, 2.0), COL_EMBER, true)
	# 炎: 揺らめく舌 + グロー (夜は強く)。
	var fy := c.y - 20.0
	var flick := 0.7 + 0.3 * sin(_t * 9.7) * sin(_t * 5.3)
	var glow_r := 26.0 + 16.0 * flick + _night * 14.0
	for i in range(3):
		var rr := glow_r * (1.0 - i * 0.3)
		draw_circle(Vector2(c.x, fy), rr, Color(0.91, 0.58, 0.22, 0.05 + i * 0.03 + _night * 0.02))
	var sway := sin(_t * 13.0) * 1.6
	var pts := PackedVector2Array([
		Vector2(c.x - 3.0, fy + 4.0),
		Vector2(c.x - 4.0, fy - 4.0 * flick),
		Vector2(c.x + sway, fy - 9.0 * flick),
		Vector2(c.x + 4.0, fy - 4.0 * flick),
		Vector2(c.x + 3.0, fy + 4.0),
	])
	draw_colored_polygon(pts, COL_EMBER_BRIGHT)
	_ellipse(Vector2(c.x, fy + 1.0), 1.6, 3.0 * flick, Color("ffe0a0"))
	# 火の粉。
	if randf() < 0.08:
		_spawn_p({"x": c.x + randf_range(-2, 2), "y": fy, "vx": randf_range(-4, 4),
			"vy": -randf_range(10, 22), "g": -6.0, "life": randf_range(0.8, 1.8), "size": 1.0,
			"color": COL_EMBER_BRIGHT if randf() < 0.5 else COL_EMBER})

func _ellipse(at: Vector2, rx: float, ry: float, col: Color) -> void:
	if rx <= 0.0:
		return
	draw_set_transform(at, 0.0, Vector2(1.0, ry / rx))
	draw_circle(Vector2.ZERO, rx, col)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# ── ゴブリンスプライト (Web 版 drawGoblin の移植) ──
func _draw_goblin(pos: Vector2, g: Goblin, face: float) -> void:
	var state_col: Color = STATE_COLORS.get(g.state, Color("8a7d68"))
	var is_chief := g.role == Goblin.Role.CHIEF
	var ph := float(GobNames.hash_id(g.id) % 628) / 100.0
	var r := 6.0 if is_chief else (3.2 if g.is_child() else 4.6)
	var sleeping := g.state == Goblin.State.SLEEP or g.state == Goblin.State.DYING \
		or g.state == Goblin.State.KNOCKED_OUT
	var moving := _sim_speed > 0.0 and g.state != Goblin.State.SLEEP
	var bob := 0.0 if sleeping else sin(_t * (11.0 if moving else 2.2) + ph) * r * 0.14
	var x := pos.x
	var by := pos.y - bob

	# 影
	_ellipse(Vector2(x, pos.y + r * 0.95), r * 0.95, r * 0.3, Color(0, 0, 0, 0.4))
	# 微光
	var pulse := 0.7 + 0.3 * sin(_t * 3.0 + ph)
	draw_circle(Vector2(x, by), r * 2.2, Color(state_col.r, state_col.g, state_col.b, 0.08))
	# 耳
	var ear_y := by - r * 0.5
	var ear_col := state_col
	draw_colored_polygon(PackedVector2Array([
		Vector2(x - r * 0.5, ear_y), Vector2(x - r * 1.7, ear_y - r * 0.9), Vector2(x - r * 0.25, ear_y - r * 0.55),
	]), ear_col)
	draw_colored_polygon(PackedVector2Array([
		Vector2(x + r * 0.5, ear_y), Vector2(x + r * 1.7, ear_y - r * 0.9), Vector2(x + r * 0.25, ear_y - r * 0.55),
	]), ear_col)
	# 体 (寝ているときは横たわる)
	if sleeping and g.state != Goblin.State.HUNGRY:
		_ellipse(Vector2(x, by + r * 0.25), r * 1.15, r * 0.75, state_col)
	else:
		_ellipse(Vector2(x, by), r * 0.95, r * 1.1, state_col)
	# 腹の明るみ (雌はやや明るい)
	var belly_a := 0.22 if g.sex == Goblin.Sex.FEMALE else 0.10
	_ellipse(Vector2(x, by + r * 0.3), r * 0.5, r * 0.55, Color(0.91, 0.86, 0.78, belly_a))
	# 目
	var eo := face * r * 0.28
	if sleeping:
		draw_line(Vector2(x - r * 0.42 + eo, by - r * 0.25), Vector2(x - r * 0.1 + eo, by - r * 0.25), Color("0a0908"), 1.0)
		draw_line(Vector2(x + r * 0.1 + eo, by - r * 0.25), Vector2(x + r * 0.42 + eo, by - r * 0.25), Color("0a0908"), 1.0)
	else:
		var eye_col := Color("ffd0a0") if g.state == Goblin.State.ENRAGED else Color("f5ecd8")
		draw_circle(Vector2(x - r * 0.3 + eo, by - r * 0.25), r * 0.22, eye_col)
		draw_circle(Vector2(x + r * 0.3 + eo, by - r * 0.25), r * 0.22, eye_col)
		draw_circle(Vector2(x - r * 0.3 + eo * 1.3, by - r * 0.25), r * 0.1, Color("16100a"))
		draw_circle(Vector2(x + r * 0.3 + eo * 1.3, by - r * 0.25), r * 0.1, Color("16100a"))
	# 得物
	if g.state == Goblin.State.COMBAT or g.state == Goblin.State.ENRAGED:
		var swing := sin(_t * 12.0 + ph) * 0.7
		draw_line(Vector2(x + face * r * 0.8, by),
			Vector2(x + face * r * (1.9 + swing * 0.3), by - r * (1.1 + swing)), Color("6a4a28"), 1.6)
	elif g.state == Goblin.State.WORK and not is_chief:
		var swing2 := sin(_t * 9.0 + ph)
		draw_line(Vector2(x + face * r * 0.7, by + r * 0.2),
			Vector2(x + face * r * 1.8, by - r * (0.8 + swing2 * 0.5)), Color("7a6a50"), 1.3)
		if swing2 < -0.85 and randf() < 0.25:
			_burst(Vector2(x + face * r * 2.0, pos.y + r * 0.5), 2,
				{"speed": 18.0, "up": 14.0, "g": 90.0, "life": 0.5, "size": 1.1, "color": Color("8a7a60")})
	# 族長の骨冠 + 炎の輪
	if is_chief:
		for k in range(-1, 2):
			var kx := x + k * r * 0.5
			draw_colored_polygon(PackedVector2Array([
				Vector2(kx - 1.4, by - r * 1.0), Vector2(kx, by - r * 1.65), Vector2(kx + 1.4, by - r * 1.0),
			]), Color("e8c060"))
		draw_arc(Vector2(x, by), r + 3.4, 0, TAU, 20, Color(1.0, 0.71, 0.33, 0.35 + pulse * 0.3), 1.2)
	# 見張り (GUARD): 背に小さな槍を負う識別 (演出層ローカル / T5)。
	if g.role == Goblin.Role.GUARD:
		draw_line(Vector2(x - face * r * 0.8, by + r * 0.6),
			Vector2(x - face * r * 1.1, by - r * 1.5), Color("8a7a58"), 1.2)
		draw_colored_polygon(PackedVector2Array([
			Vector2(x - face * r * 1.1, by - r * 1.5),
			Vector2(x - face * r * 1.35, by - r * 1.1),
			Vector2(x - face * r * 0.85, by - r * 1.1),
		]), COL_BONE)
	# キノコ運搬中 (T4): 頭上に小さなキノコを抱える。
	if g.carrying_food:
		var mx := x + face * r * 0.7
		var my := by - r * 1.1
		draw_line(Vector2(mx, my + 1.4), Vector2(mx, my - 0.4), Color("9a8a70"), 1.0)
		_ellipse(Vector2(mx, my - 0.8), 1.8, 1.0, Color("c08a5a"))
	# HP の弧 (低 HP のみ)
	var frac := clampf(g.hp / g.max_hp, 0.0, 1.0)
	if frac < 0.4:
		draw_arc(Vector2(x, by), r + 1.8, -PI * 0.5, -PI * 0.5 + TAU * frac, 16, Color("c0432e"), 1.5)
	# ステートの吐息 (粒子)
	if _sim_speed > 0.0:
		if g.state == Goblin.State.SLEEP and randf() < 0.012:
			_spawn_p({"kind": "text", "txt": "z", "color": Color("7a9ab8"),
				"x": x + r, "y": by - r, "vx": 6.0, "vy": -10.0, "life": 1.6, "size": 8.0})
		elif g.state == Goblin.State.FEAR and randf() < 0.02:
			_spawn_p({"color": Color("9ab8d8"), "x": x - face * r * 0.6, "y": by - r * 0.6,
				"vx": -face * 8.0, "vy": -6.0, "g": 60.0, "life": 0.6, "size": 1.2})
		elif g.state == Goblin.State.HUNGRY and randf() < 0.02:
			_spawn_p({"color": Color("a8842a"), "x": x + randf_range(-r, r), "y": by + r * 0.4,
				"vx": randf_range(-6, 6), "vy": 8.0, "g": 40.0, "life": 0.5, "size": 1.0})

# ── キノコ床スプライト (小さなキノコ群。生長済み = 明るい笠、再生長中 = しぼむ) ──
func _draw_forage(pos: Vector2, id: int, grown: bool) -> void:
	var cap_col := Color("c08a5a") if grown else Color("4a3a2c")  # 笠 (摘めると明るい)
	var stem_col := Color("9a8a70") if grown else Color("3a342a") # 柄
	var h := GobNames.hash_id(id * 2654435761)
	# 3 本のキノコを足元に散らす (決定的な小オフセット)。
	for k in range(3):
		var ox := float((h >> (k * 4)) % 7) - 3.0
		var oy := float((h >> (k * 4 + 2)) % 5) - 2.0
		var cx := pos.x + ox
		var cy := pos.y + oy
		var sc := 1.0 if grown else 0.7
		draw_line(Vector2(cx, cy + 2.0 * sc), Vector2(cx, cy - 0.5 * sc), stem_col, 1.0)
		_ellipse(Vector2(cx, cy - 1.0 * sc), 2.2 * sc, 1.2 * sc, cap_col)

# ── パン虫スプライト (青白い小さな幼虫。体長 3px ほど、わずかに蠢く) ──
func _draw_mite(pos: Vector2, id: int) -> void:
	var wig := sin(_t * 8.0 + float(id)) * 0.6   # 蠢き
	var col := Color("a8c0d0")
	_ellipse(pos + Vector2(0, 1.6), 2.0, 0.7, Color(0, 0, 0, 0.25))  # 影
	# 体節 = 楕円 2 つ (頭側 + 尾側)。
	_ellipse(pos + Vector2(-1.0, wig * 0.3), 1.4, 1.0, col)
	_ellipse(pos + Vector2(1.0, -wig * 0.3), 1.2, 0.9, col.darkened(0.1))

# ── 敵スプライト (槍持ちのミニ人型) ──
func _draw_enemy(pos: Vector2, e: EnemyUnit, face: float) -> void:
	var bob := sin(_t * 6.0 + float(e.id)) * 0.8
	var col := Color("b85a40") if e.is_human else Color("9a5838")
	_ellipse(pos + Vector2(0, 4), 3.0, 1.1, Color(0, 0, 0, 0.35))
	_ellipse(pos + Vector2(0, bob), 2.6, 3.4, col)
	draw_circle(pos + Vector2(0, -4 + bob), 1.8, Color("d8b090") if e.is_human else col)
	draw_line(pos + Vector2(face * 3.0, 3.0 + bob), pos + Vector2(face * 5.5, -7.0 + bob), COL_BONE, 0.9)
	# HP バー (削れているときのみ)
	var frac := clampf(e.hp / e.max_hp, 0.0, 1.0)
	if frac < 0.999:
		draw_rect(Rect2(pos.x - 4.0, pos.y - 8.0, 8.0 * frac, 1.5), Color("c0432e"), true)

func _draw_particle(pt: Dictionary) -> void:
	var a := clampf(float(pt.life) / float(pt.max_life), 0.0, 1.0)
	var col: Color = pt.color
	col.a *= a
	match pt.kind:
		"text":
			_draw_text_crisp(Vector2(pt.x, pt.y), pt.txt, float(pt.size), col,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0)
		"bone":
			draw_line(Vector2(pt.x - pt.size, pt.y + pt.size), Vector2(pt.x + pt.size, pt.y - pt.size), col, 1.2)
			draw_circle(Vector2(pt.x - pt.size, pt.y + pt.size), 1.0, col)
		_:
			draw_circle(Vector2(pt.x, pt.y), float(pt.size) * (0.5 + a * 0.5), col)
