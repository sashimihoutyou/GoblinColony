extends RefCounted
class_name MapTemplate
## 固定テンプレートの初期マップ生成 (§3-0 / P1-02)。
##
## ランダムなし — 乱数は使わず、すべて決定的なノイズ関数 (sin の重ね合わせ) で形を作る。
## 岩山 (楕円 + 角度ノイズ) に有機的な洞窟を彫る: 大広間 (トーテム)・寝床・食料庫・
## ネズミ牧場・採掘坑道をうねる坑道で連結し、巣口 3 本 (北・南東・南西) だけが外気と
## つながる。封鎖補修 + 接続保証つきで、巣口以外から敵が入れないことを構造的に保証する。
## 数値はプレイテストで調整 (§NUMBERS)。

const W := 56
const H := 40
const WALL_HP := 20  # §NUMBERS MAX_WALL_HP 暫定

# 岩山の外形 (楕円)。ふちは角度ノイズでごつごつさせる。
const ROCK_C := Vector2(28.0, 24.0)
const ROCK_RX := 25.0
const ROCK_RY := 16.5

const DIRS4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

static func make_initial_map() -> TileMapData:
	var m := TileMapData.new()
	m.width = W
	m.height = H
	m.terrain = PackedInt32Array()
	m.terrain.resize(W * H)
	m.wall_hp = PackedInt32Array()
	m.wall_hp.resize(W * H)

	# 外は地面、岩山の内側は岩。
	for y in range(H):
		for x in range(W):
			var i := m.idx(x, y)
			if _in_rock(x, y):
				m.terrain[i] = TileMapData.TileType.WALL
				m.wall_hp[i] = WALL_HP
			else:
				m.terrain[i] = TileMapData.TileType.EXTERIOR
				m.wall_hp[i] = 0

	# --- 部屋 (有機ブロブ)。位相をずらして同じ形の繰り返しを避ける ---
	var hall := Vector2i(28, 25)     # 大広間 (トーテム)
	var nest := Vector2i(14, 28)     # 寝床
	var pantry := Vector2i(41, 28)   # 食料庫
	var ranch := Vector2i(39, 17)    # ネズミ牧場
	var mine_w := Vector2i(12, 18)   # 採掘坑道 (西)
	var mine_s := Vector2i(22, 32)   # 採掘坑道 (南)
	_carve_blob(m, hall, 5.5, 0.0)
	_carve_blob(m, nest, 4.0, 1.7)
	_carve_blob(m, pantry, 3.5, 3.1)
	_carve_blob(m, ranch, 4.0, 4.6)
	_carve_blob(m, mine_w, 3.0, 2.3)
	_carve_blob(m, mine_s, 2.5, 5.2)

	# --- 坑道 (うねる通路で連結。ループも作り行き止まり感を消す) ---
	_carve_tunnel(m, hall, nest, 0.9)
	_carve_tunnel(m, hall, pantry, 2.2)
	_carve_tunnel(m, hall, ranch, 3.8)
	_carve_tunnel(m, hall, mine_w, 5.1)
	_carve_tunnel(m, hall, mine_s, 1.4)
	_carve_tunnel(m, nest, mine_w, 2.8)
	_carve_tunnel(m, pantry, ranch, 4.3)

	# --- 巣口 3 本 (北・南東・南西): 坑道を外気までまっすぐ掘り抜く ---
	_carve_gate(m, Vector2i(28, 22), Vector2i(0, -1))  # 北 (大広間から)
	_carve_gate(m, pantry, Vector2i(1, 0))             # 南東 (食料庫から)
	_carve_gate(m, nest, Vector2i(-1, 0))              # 南西 (寝床から)

	# --- 特殊タイル ---
	var totem := Vector2i(28, 26)
	m.terrain[m.idx(totem.x, totem.y)] = TileMapData.TileType.TOTEM
	m.totem = totem
	m.terrain[m.idx(pantry.x, pantry.y)] = TileMapData.TileType.STORAGE
	m.storage = pantry
	var nodes := [Vector2i(11, 17), Vector2i(13, 19), Vector2i(22, 33)]
	for p in nodes:
		m.terrain[m.idx(p.x, p.y)] = TileMapData.TileType.RESOURCE_NODE

	# --- 接続保証 (保険): トーテムから届かない要所は直線坑道で強制接続 ---
	var key_points: Array = [nest, pantry, ranch, mine_w, mine_s]
	key_points.append_array(nodes)
	key_points.append_array(m.gates)
	_ensure_connected(m, totem, key_points)

	# --- 封鎖補修: 巣口以外で床が外気と 4 隣接しないよう外側を岩でふさぐ ---
	_seal_leaks(m)

	# --- 部屋登録 (バウンディングボックス。タイル選択は床のみを使う) ---
	m.rooms.append({"x": 10, "y": 24, "w": 9, "h": 9,
		"room_type": TileMapData.RoomType.NEST, "assigned": []})
	m.rooms.append({"x": 35, "y": 13, "w": 9, "h": 9,
		"room_type": TileMapData.RoomType.RAT_RANCH, "assigned": []})

	# --- キノコ床 (T4 採集スポット): 坑道沿いの床に決定的に 6 箇所散らす ---
	_place_forage_spots(m, 6)
	return m

## キノコ床を巣内の床へ決定的に配置する (rng 不使用)。
## NEST/RAT_RANCH の部屋と集積所・トーテム周辺 2 タイルを避け、坑道沿い (= 部屋外) の
## FLOOR を床走査順に列挙し、固定ストライドで間引きつつ既存スポットと一定距離あける
## (観賞上、雌が巣のあちこちを歩き回るよう散らす)。
static func _place_forage_spots(m: TileMapData, count: int) -> void:
	m.forage_spots = []
	m.forage_regrow = []
	# 候補: 部屋 (NEST/RAT_RANCH) 外で、集積所・トーテムからチェビシェフ距離 2 超の床。
	var cands: Array = []
	for y in range(m.height):
		for x in range(m.width):
			if m.get_tile(x, y) != TileMapData.TileType.FLOOR:
				continue
			var rt := m.room_type_at(x, y)
			if rt == TileMapData.RoomType.NEST or rt == TileMapData.RoomType.RAT_RANCH:
				continue
			if maxi(absi(x - m.storage.x), absi(y - m.storage.y)) <= 2:
				continue
			if maxi(absi(x - m.totem.x), absi(y - m.totem.y)) <= 2:
				continue
			cands.append(Vector2i(x, y))
	if cands.is_empty():
		return
	# 固定ストライドで走査し、既存スポットからマンハッタン距離 6 以上離れたものを採る
	# (坑道に沿って散る)。足りなければストライド・距離を緩めて埋める。
	for min_dist in [6, 3, 0]:
		var stride: int = maxi(1, cands.size() / (count * 3))
		var i := 0
		while i < cands.size() and m.forage_spots.size() < count:
			var p: Vector2i = cands[i]
			var ok := true
			for s in m.forage_spots:
				if absi((s as Vector2i).x - p.x) + absi((s as Vector2i).y - p.y) < min_dist:
					ok = false
					break
			if ok:
				m.forage_spots.append(p)
				m.forage_regrow.append(0)  # 初期は全スポット摘み取り可
			i += stride
		if m.forage_spots.size() >= count:
			break

## 岩山の内側か (楕円 + 角度ノイズ)。
static func _in_rock(x: int, y: int) -> bool:
	var nx := (float(x) - ROCK_C.x) / ROCK_RX
	var ny := (float(y) - ROCK_C.y) / ROCK_RY
	var d := sqrt(nx * nx + ny * ny)
	var a := atan2(ny, nx)
	var edge := 1.0 + 0.05 * sin(3.0 * a + 1.3) + 0.04 * sin(7.0 * a + 0.6)
	return d < edge

## 岩を 1 タイル床に掘る。外気と 8 隣接する場所は掘らない (巣口以外の穴あき防止)。
static func _carve_floor(m: TileMapData, p: Vector2i) -> void:
	if not m.in_bounds(p.x, p.y):
		return
	if m.terrain[m.idx(p.x, p.y)] != TileMapData.TileType.WALL:
		return
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if m.get_tile(p.x + dx, p.y + dy) == TileMapData.TileType.EXTERIOR:
				return
	m.terrain[m.idx(p.x, p.y)] = TileMapData.TileType.FLOOR
	m.wall_hp[m.idx(p.x, p.y)] = 0

## 有機的な部屋: 半径が角度で揺らぐブロブを掘る。
static func _carve_blob(m: TileMapData, c: Vector2i, r: float, phase: float) -> void:
	var ri := int(ceil(r * 1.2))
	for y in range(c.y - ri, c.y + ri + 1):
		for x in range(c.x - ri, c.x + ri + 1):
			var dx := float(x - c.x)
			var dy := float(y - c.y)
			var dist := sqrt(dx * dx + dy * dy)
			var a := atan2(dy, dx)
			var rr := r * (0.85 + 0.15 * sin(3.0 * a + phase) + 0.08 * sin(7.0 * a + phase * 2.0))
			if dist <= rr:
				_carve_floor(m, Vector2i(x, y))

## うねる坑道: 基本は残距離の大きい軸へ 1 歩、周期的に直交へそれて曲がりを作る。
## 3 歩に 1 歩は横を 1 タイル広げ、幅 1〜2 の自然な通路にする。
static func _carve_tunnel(m: TileMapData, a: Vector2i, b: Vector2i, phase: float) -> void:
	var p := a
	_carve_floor(m, p)
	var k := 0
	while p != b and k < 300:
		k += 1
		var d := b - p
		var step: Vector2i
		if d.x != 0 and (absi(d.x) >= absi(d.y) or d.y == 0):
			step = Vector2i(signi(d.x), 0)
		else:
			step = Vector2i(0, signi(d.y))
		var wob := sin(float(k) * 0.55 + phase)
		if absf(wob) > 0.8:
			if step.x != 0 and absi(d.x) > 3:
				step = Vector2i(0, 1 if wob > 0.0 else -1)
			elif step.y != 0 and absi(d.y) > 3:
				step = Vector2i(1 if wob > 0.0 else -1, 0)
		p += step
		_carve_floor(m, p)
		if k % 3 == 0:
			_carve_floor(m, p + Vector2i(step.y, step.x))

## 巣口: from から dir へ外気に届くまで掘り抜き、最後の岩内タイルを GATE にする。
## ここだけは外気隣接の掘削を許す (_carve_floor を使わない)。
static func _carve_gate(m: TileMapData, from: Vector2i, dir: Vector2i) -> void:
	var p := from
	var prev := from
	for k in range(40):
		if m.get_tile(p.x, p.y) == TileMapData.TileType.EXTERIOR:
			m.terrain[m.idx(prev.x, prev.y)] = TileMapData.TileType.GATE
			m.wall_hp[m.idx(prev.x, prev.y)] = 0
			m.gates.append(prev)
			return
		if m.terrain[m.idx(p.x, p.y)] == TileMapData.TileType.WALL:
			m.terrain[m.idx(p.x, p.y)] = TileMapData.TileType.FLOOR
			m.wall_hp[m.idx(p.x, p.y)] = 0
		prev = p
		p += dir
	# 外気に届かなければ巣口なし (テスト _test_map_connectivity が検出する)。

## 接続保証: origin から到達できない要所へ直線 (L 字) 坑道を強制で掘る保険。
static func _ensure_connected(m: TileMapData, origin: Vector2i, targets: Array) -> void:
	for t in targets:
		if not _reachable(m, origin, t):
			_carve_straight(m, origin, t)

static func _reachable(m: TileMapData, a: Vector2i, b: Vector2i) -> bool:
	var seen := {a: true}
	var queue: Array = [a]
	while not queue.is_empty():
		var p: Vector2i = queue.pop_front()
		if p == b:
			return true
		for d in DIRS4:
			var nb: Vector2i = p + d
			if m.is_walkable(nb.x, nb.y) and not seen.has(nb):
				seen[nb] = true
				queue.append(nb)
	return false

static func _carve_straight(m: TileMapData, a: Vector2i, b: Vector2i) -> void:
	var p := a
	while p.x != b.x:
		p.x += signi(b.x - p.x)
		if m.terrain[m.idx(p.x, p.y)] == TileMapData.TileType.WALL:
			m.terrain[m.idx(p.x, p.y)] = TileMapData.TileType.FLOOR
			m.wall_hp[m.idx(p.x, p.y)] = 0
	while p.y != b.y:
		p.y += signi(b.y - p.y)
		if m.terrain[m.idx(p.x, p.y)] == TileMapData.TileType.WALL:
			m.terrain[m.idx(p.x, p.y)] = TileMapData.TileType.FLOOR
			m.wall_hp[m.idx(p.x, p.y)] = 0

## 封鎖補修: 床が外気と 4 隣接していたら、外気側を岩に変えて巣を密閉する。
## (斜め接触は pathfinding の角抜け禁止ルールで通れないため許容。)
static func _seal_leaks(m: TileMapData) -> void:
	for y in range(H):
		for x in range(W):
			if m.terrain[m.idx(x, y)] != TileMapData.TileType.FLOOR:
				continue
			for d in DIRS4:
				var n := Vector2i(x + d.x, y + d.y)
				if m.in_bounds(n.x, n.y) \
						and m.terrain[m.idx(n.x, n.y)] == TileMapData.TileType.EXTERIOR:
					m.terrain[m.idx(n.x, n.y)] = TileMapData.TileType.WALL
					m.wall_hp[m.idx(n.x, n.y)] = WALL_HP
