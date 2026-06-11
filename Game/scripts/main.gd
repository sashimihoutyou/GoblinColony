extends Node2D
## メインループ (P1-09 / P1-10)。実時間 → tick 変換 → controller → world.tick → render。
##
## 実時間に触れるのはここだけ (KI-09 tick_driver 相当)。速度倍率と端数持ち越し。
## タイムスケール: 1 tick = 0.375 実秒 × ticks_per_day=240 → 1 日 = 実 90 秒 (3x で 30 秒)。
## tick が細かいのは連続移動 (RimWorld 風) のサンプリングのため (params.gd 参照)。
## UI はコードで構築する (Web 版ダッシュボードと同じ配色言語: 闇の岩・琥珀・苔)。

const MS_PER_TICK := 375.0

# --- Web 版と同じ配色 ---
const C_BG_PANEL := Color(0.078, 0.067, 0.055, 0.92)
const C_ROCK_LINE := Color(0.227, 0.196, 0.157, 0.5)
const C_INK := Color("e8dcc8")
const C_INK_DIM := Color("8a7d68")
const C_INK_FAINT := Color("5a4f40")
const C_EMBER := Color("e8943a")
const C_EMBER_BRIGHT := Color("ffb454")
const C_BLOOD := Color("c0432e")

const STATE_JP := {
	Goblin.State.DEAD: "死亡", Goblin.State.ENRAGED: "激昂", Goblin.State.FEAR: "恐怖",
	Goblin.State.COMBAT: "戦闘", Goblin.State.DYING: "瀕死", Goblin.State.HUNGRY: "空腹",
	Goblin.State.SLEEP: "睡眠", Goblin.State.WORK: "仕事", Goblin.State.WANDER: "放浪",
	Goblin.State.KNOCKED_OUT: "昏倒",
}
const ROLE_JP := {
	Goblin.Role.NONE: "無役", Goblin.Role.SHAMAN: "シャーマン", Goblin.Role.CHIEF: "族長",
	Goblin.Role.WITCH_DOCTOR: "まじない医", Goblin.Role.NURSERY_HOST: "苗床",
	Goblin.Role.CONCUBINE: "側室", Goblin.Role.GUARD: "見張り",
}
const STATE_HEX := {
	Goblin.State.COMBAT: "c0432e", Goblin.State.FEAR: "9a6bb0", Goblin.State.DYING: "7a4030",
	Goblin.State.HUNGRY: "c08a3a", Goblin.State.SLEEP: "4a6b8a", Goblin.State.WORK: "7a9a4e",
	Goblin.State.WANDER: "8a7d68", Goblin.State.ENRAGED: "ff5530", Goblin.State.KNOCKED_OUT: "6a4838",
}
const ROOM_TYPE_JP := {
	TileMapData.RoomType.NEST: "寝床", TileMapData.RoomType.NURSERY: "苗床",
	TileMapData.RoomType.SMITHY: "泥鍛冶屋", TileMapData.RoomType.RAT_RANCH: "ネズミ牧場",
	TileMapData.RoomType.MUSHROOM: "キノコ農園", TileMapData.RoomType.WITCH: "まじない医",
}

# --- 選択対象の種別 (将来の奇跡ターゲティングでも再利用)。renderer の pick_any() が
# 返す int (0=なし/1=ゴブリン/2=敵/3=部屋/4=出現物) をこの enum へ写像する。---
enum SelKind { NONE, GOBLIN, ENEMY, ROOM, FIELD }

var world: World
var params: SimParams
var controller: Controller
var renderer: Renderer

var speed: float = 1.0        # 0 / 1 / 3
var _accum_ms: float = 0.0
var sel_kind: int = SelKind.NONE
var sel_id: int = -1   # GOBLIN/ENEMY: ユニット id。ROOM: world.map.rooms のインデックス
var _forage_feed_count: int = 0  # T4: 採集フィードの間引き (4 回に 1 回だけ流す)
# 奇跡のターゲティング (演出/入力ローカル。シム・セーブに含めない)。
# _armed = 武装中の奇跡 (Controller.Miracle の値 / -1 = 非武装)。武装中は
# 左クリックが選択でなく対象指定になる。Esc/右クリック/残高切れで解除。
var _armed: int = -1
var _miracle_buttons: Array = []  # Array[Dictionary] {btn: Button, def: Dictionary}

# 奇跡の操作定義 (§4)。target: 0=即時 (武装不要) / 1=敵クリック / 2=ゴブリンクリック /
# 3=タイルクリック。cost_key は SimParams のコスト変数名 ("" = 無料の基本命令)。
const MIRACLE_DEFS := [
	{"m": Controller.Miracle.LIGHTNING, "key": KEY_Q, "name": "⚡稲妻",
		"cost_key": "lightning_cost", "target": 1, "hint": "敵をクリックで発動"},
	{"m": Controller.Miracle.MITES, "key": KEY_W, "name": "パン虫",
		"cost_key": "mites_cost", "target": 0, "hint": ""},
	{"m": Controller.Miracle.HONOR, "key": KEY_E, "name": "名誉",
		"cost_key": "honor_cost", "target": 2, "hint": "ゴブリンをクリックで激昂させる"},
	{"m": Controller.Miracle.MUD, "key": KEY_R, "name": "泥壁",
		"cost_key": "mud_cost", "target": 3, "hint": "塞ぎたい地点をクリック (十字に壁化)"},
	{"m": Controller.Miracle.RAGE, "key": KEY_T, "name": "怒り",
		"cost_key": "rage_cost", "target": 3, "hint": "敵の只中をクリックで同士討ち"},
	{"m": Controller.Miracle.SUMMON, "key": KEY_Y, "name": "召喚",
		"cost_key": "summon_cost", "target": 3, "hint": "出現させたい地点をクリック"},
	{"m": Controller.Miracle.RALLY, "key": KEY_G, "name": "集合",
		"cost_key": "", "target": 3, "hint": "集めたい地点をクリック (再押下で解除)"},
]

# --- カメラ操作 (演出層ローカル状態。シムには触れない) ---
const ZOOM_MIN := 1.0         # フィット倍率 (全体表示)
const ZOOM_MAX := 8.0         # 最大拡大
const ZOOM_STEP := 1.15       # ホイール 1 段ぶんの倍率
const RIGHT_PANEL_W := 290.0  # 右パネルぶんの横オフセット
const KEY_PAN_SPEED := 600.0  # キーボードパン速度 (画面スペース px/秒)
const FOLLOW_LERP := 8.0      # 追従カメラの指数追従係数 (大きいほど速く追いつく)
var _zoom_factor: float = 1.0 # フィット倍率に対するユーザー倍率 (1.0=全体フィット)
var _fit_zoom: float = 1.0    # viewport から算出したフィット倍率 (キャッシュ)
var _fit_pos: Vector2 = Vector2.ZERO  # factor=1.0 のときのカメラ位置 (キャッシュ)
var _panning: bool = false    # 中ボタンドラッグ中か
var _follow_id: int = -1      # 右クリックで追従中のゴブリン id (-1 = 追従なし)
# 手動パン/追従が一度でも行われたか。true の間はズーム=1.0 でもフィット位置への
# 自動復帰を止める (ホイールでズームアウトし切ったときのみ _apply_zoom が解除する)。
var _manual_camera: bool = false

# UI ノード (コード構築)
var _status_label: Label
var _eta_label: Label
var _inspector: RichTextLabel
var _feed: RichTextLabel
var _outcome_label: Label
var _speed_buttons: Array = []
var _feed_lines: Array = []
# 派遣パネル (§11.5: 出現物クリック → 頭数スライダー → 確定)
var _dispatch_panel: PanelContainer
var _dispatch_info: Label
var _dispatch_slider: HSlider
var _dispatch_count: Label
var _dispatch_button: Button
var _dispatch_field_id: int = -1  # 対象の出現物 id (-1 = パネル非表示)

func _ready() -> void:
	params = SimParams.new()
	world = World.new()
	world.setup(params)
	controller = AutoController.new()
	(controller as AutoController).auto_dispatch = false

	renderer = $Renderer
	renderer.tile_size = 16

	_build_ui()
	_update_camera()
	get_viewport().size_changed.connect(_update_camera)
	_push_feed("event", "巣が築かれた。%d 体のゴブリンと族長。" % params.start_goblins)

func _process(delta: float) -> void:
	if world.outcome == World.Outcome.ONGOING and speed > 0.0:
		_accum_ms += delta * 1000.0 * speed
		var max_ticks_per_frame := 16  # 暴走防止 (KI-09)。3x (12 tick/秒) でも余裕を持つ
		var done := 0
		while _accum_ms >= MS_PER_TICK and done < max_ticks_per_frame:
			_accum_ms -= MS_PER_TICK
			_step_one_tick()
			done += 1
			if world.outcome != World.Outcome.ONGOING:
				break
	# 描画は毎フレーム (tick 間も補間・粒子・炎が動く)。
	# α = 次 tick までの端数 (固定タイムステップ補間。停止中は固定され静止)。
	renderer.sel_kind = sel_kind
	renderer.sel_id = sel_id
	renderer.render(world, delta, speed, clampf(_accum_ms / MS_PER_TICK, 0.0, 1.0))
	_update_status()
	_update_inspector()
	_update_dispatch_panel()
	# カメラ操作はシム停止中 (speed=0) でも独立して動く。
	_process_keyboard_pan(delta)
	_process_follow_camera(delta)

## 矢印キー / WASD でのパン。画面スペースで一定速度になるよう zoom で割る。
## パンしたら追従モードを解除する。
func _process_keyboard_pan(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT) or Input.is_physical_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT) or Input.is_physical_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_UP) or Input.is_physical_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_physical_key_pressed(KEY_DOWN) or Input.is_physical_key_pressed(KEY_S):
		dir.y += 1.0
	if dir == Vector2.ZERO:
		return
	var cam := $Camera2D as Camera2D
	if cam == null:
		return
	cam.position += dir.normalized() * KEY_PAN_SPEED * delta / cam.zoom.x
	_follow_id = -1
	_manual_camera = true
	_clamp_camera(cam)

## 右クリックで追従中のゴブリンへカメラを軽い指数追従で寄せる。
## 死亡/巣立ちで補間エントリが消えたら自動解除する。
func _process_follow_camera(delta: float) -> void:
	if _follow_id < 0:
		return
	var target := renderer.unit_screen_pos(_follow_id)
	if target == Vector2.INF:
		_follow_id = -1
		return
	var cam := $Camera2D as Camera2D
	if cam == null:
		return
	cam.position = cam.position.lerp(target, 1.0 - exp(-FOLLOW_LERP * delta))
	_clamp_camera(cam)

func _step_one_tick() -> void:
	controller.decide(world)
	controller.apply(world)
	world.tick_once()
	# シムの構造化イベントをフィードと演出へ翻訳する。
	# on_tick より先に処理する: 死亡/巣立ちバーストは演出層に残る直前の
	# 補間位置 (_last_pos_of) を使うため、その個体が on_tick で除去される前に拾う。
	for e in world.last_events:
		_push_feed_event(e)
		renderer.on_event(e)
	# tick 確定後に演出層の補間ターゲット (prev→cur) を更新する。
	# (1 フレームに複数 tick 回る場合も毎回。O(個体数) の座標コピーのみ)
	renderer.on_tick(world)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# 左クリック: 武装中は奇跡の対象指定、そうでなければ個体/敵/部屋を選択。
				if event.pressed:
					if _armed >= 0:
						_try_cast(get_global_mouse_position())
					else:
						var picked := renderer.pick_any(world, get_global_mouse_position())
						sel_kind = _sel_kind_from_pick(int(picked.kind))
						sel_id = int(picked.id)
						# 出現物 (§11.5): 選択と同時に派遣パネルを開く。
						# それ以外をクリックしたらパネルは閉じる。
						if sel_kind == SelKind.FIELD:
							_open_dispatch_panel(sel_id)
						else:
							_close_dispatch_panel()
			MOUSE_BUTTON_RIGHT:
				# 右クリック: 武装中なら奇跡を解除。ゴブリンを拾えれば追従モード開始
				# (インスペクタ選択も同期)。敵/部屋/空振りは選択のみ更新し追従は解除する。
				if event.pressed and _armed >= 0:
					_disarm()
				elif event.pressed:
					var picked2 := renderer.pick_any(world, get_global_mouse_position())
					var kind2 := _sel_kind_from_pick(int(picked2.kind))
					sel_kind = kind2
					sel_id = int(picked2.id)
					if kind2 == SelKind.GOBLIN:
						_follow_id = sel_id
						_manual_camera = true
					else:
						_follow_id = -1
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_apply_zoom(_zoom_factor * ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_apply_zoom(_zoom_factor / ZOOM_STEP)
			MOUSE_BUTTON_MIDDLE:
				# 中ボタンドラッグでパン開始/終了。
				_panning = event.pressed
	elif event is InputEventMouseMotion and _panning:
		var cam := $Camera2D as Camera2D
		if cam != null:
			# 画面上のドラッグ量ぶん、カメラを逆方向へ動かす (ズーム補正)。
			cam.position -= event.relative / cam.zoom
			_follow_id = -1
			_manual_camera = true
			_clamp_camera(cam)
	elif event is InputEventKey and event.pressed and not event.echo:
		# 奇跡のショートカット (MIRACLE_DEFS の key)。Esc: 武装解除。
		if event.keycode == KEY_ESCAPE and _armed >= 0:
			_disarm()
		else:
			for def in MIRACLE_DEFS:
				if event.keycode == def.key:
					_press_miracle(def)
					break

## ホイールズーム: カーソル位置をアンカーに倍率を変える (factor は 1.0〜8.0)。
func _apply_zoom(new_factor: float) -> void:
	var cam := $Camera2D as Camera2D
	if cam == null:
		return
	new_factor = clampf(new_factor, ZOOM_MIN, ZOOM_MAX)
	var old_factor := _zoom_factor
	if absf(new_factor - old_factor) < 0.0001:
		return
	_zoom_factor = new_factor
	if _zoom_factor <= ZOOM_MIN + 0.0001:
		# 全体フィットへ正確に復帰 (右パネルぶんのオフセット込み)。
		# ホイールでズームアウトし切ったときだけ、手動パン/追従の解除も含めて
		# フィット表示へ戻す (仕様: フィット復帰はここのみがトリガー)。
		_zoom_factor = ZOOM_MIN
		_manual_camera = false
		_follow_id = -1
		cam.zoom = Vector2(_fit_zoom, _fit_zoom)
		cam.position = _fit_pos
		return
	# カーソル下のワールド点が画面上で動かないよう位置補正。
	var mouse_world := get_global_mouse_position()
	var old_zoom := cam.zoom.x
	var new_zoom := _fit_zoom * _zoom_factor
	cam.zoom = Vector2(new_zoom, new_zoom)
	# Camera2D.zoom は大きいほど拡大 → スケール比は old_zoom / new_zoom。
	cam.position = mouse_world + (cam.position - mouse_world) * (old_zoom / new_zoom)
	_clamp_camera(cam)

## カメラ位置をマップ矩形から大きく外れないようクランプ。
## ズーム=1.0 (フィット) かつ手動操作 (パン/追従) が一度も無ければフィット位置に固定する。
## 手動操作後はズーム=1.0 でも自由に動ける (フィット復帰はホイールズームアウトのみ)。
func _clamp_camera(cam: Camera2D) -> void:
	if _zoom_factor <= ZOOM_MIN + 0.0001 and not _manual_camera:
		cam.position = _fit_pos
		return
	var m := world.map
	var map_w := m.width * renderer.tile_size
	var map_h := m.height * renderer.tile_size
	# 表示半分ぶんの余白を残してマップ中心からの可動域を制限する。
	var view := get_viewport_rect().size / cam.zoom
	var half := view * 0.5
	var min_x := minf(half.x, map_w * 0.5)
	var max_x := maxf(map_w - half.x, map_w * 0.5)
	var min_y := minf(half.y, map_h * 0.5)
	var max_y := maxf(map_h - half.y, map_h * 0.5)
	cam.position.x = clampf(cam.position.x, min_x, max_x)
	cam.position.y = clampf(cam.position.y, min_y, max_y)

# ════ イベント → 物語の文 ════
func _push_feed_event(e: Dictionary) -> void:
	var t: String = e.get("t", "")
	match t:
		"raid":
			var who: String = "人間の討伐隊" if e.get("human", false) else "敵対氏族の群れ"
			if e.get("final", false):
				_push_feed("raid", "ラストバトル! %s %d 体が押し寄せる!" % [who, e.get("count", 0)])
			else:
				_push_feed("raid", "襲撃! %s %d 体が巣口に迫る。" % [who, e.get("count", 0)])
		"raid_small":
			_push_feed("event", "小競り合い: 敵 %d 体 (恵み)。" % e.get("count", 0))
		"raid_end":
			_push_feed("raid", "襲撃を退けた。生存 %d 体。" % e.get("alive", 0))
		"surge":
			_push_feed("event", "群れが本能で奮い立つ (損耗 %.0f%%)。" % (float(e.get("lost_frac", 0.0)) * 100.0))
		"death":
			var nm := GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))
			var cause: String = "事故で死んだ" if e.get("cause", "") == "accident" else "戦いで散った"
			_push_feed("death", "%s が%s。" % [nm, cause])
		"fledge":
			_push_feed("event", "%s が巣立っていった。" % GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))))
		"birth":
			var mother := _find_goblin(int(e.get("mother", -1)))
			var mname: String = GobNames.of(mother) if mother != null else "母ゴブリン"
			_push_feed("birth", "%s が %d 匹の子を産んだ。" % [mname, e.get("count", 0)])
		"grow":
			_push_feed("birth", "%s が一人前に育った。" % GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))))
		"mite_eaten":
			_push_feed("event", "%s がパン虫を捕まえて食べた。" % GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))))
		"fumble":
			var fnm := GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))
			if e.get("dropped", false):
				_push_feed("event", "%s が転んでキノコを取り落とした。" % fnm)
			else:
				_push_feed("event", "%s がすっ転んだ。" % fnm)
		"forage":
			# 採集はひっきりなしに起きるのでフィードは 4 回に 1 回だけ流す (煩さ低減)。
			_forage_feed_count += 1
			if _forage_feed_count % 4 == 0:
				_push_feed("event", "%s がキノコを集積所に運び込んだ。" \
					% GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))))
		"guard":
			_push_feed("event", "%s が巣口の見張りに就いた。" \
				% GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))))
		"alarm":
			_push_feed("raid", "見張りの %s が警報を上げた!" \
				% GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))))
		"quarrel":
			var ga := _find_goblin(int(e.get("a", -1)))
			var gb := _find_goblin(int(e.get("b", -1)))
			var na: String = GobNames.of(ga) if ga != null else "ゴブリン"
			var nb: String = GobNames.of(gb) if gb != null else "ゴブリン"
			_push_feed("event", "%s と %s がケンカを始めた!" % [na, nb])
		"court":
			var cf := _find_goblin(int(e.get("f", -1)))
			var cm := _find_goblin(int(e.get("m", -1)))
			var cfn: String = GobNames.of(cf) if cf != null else "雌ゴブリン"
			var cmn: String = GobNames.of(cm) if cm != null else "雄ゴブリン"
			_push_feed("love", "%s が %s を寝床に誘った。" % [cfn, cmn])
		"pregnant":
			var f := _find_goblin(int(e.get("id", -1)))
			if f != null:
				_push_feed("love", "%s が寝床で身ごもった。" % GobNames.of(f))
		"field_spawn":
			_push_feed("event", "巣の外に木の実の茂みが見つかった (%d 食ぶん)。" % e.get("amount", 0))
		"dispatch":
			_push_feed("event", "%d 体が恵みを取りに巣を出た。" % e.get("count", 0))
		"field_done":
			_push_feed("event", "茂みを取り尽くした。")
		"field_expire":
			_push_feed("event", "日が暮れ、外の恵みは闇に消えた。")
		"victory":
			_push_feed("event", "★ ラストバトルを撃退 — 勝利!")
		"defeat":
			var reason: String = "トーテムが砕かれた" if e.get("reason", "") == "totem" else "群れは全滅した"
			_push_feed("raid", "✖ %s — 敗北……" % reason)

const FEED_COLORS := {
	"raid": "e06a50", "event": "e8943a", "birth": "9adb6e",
	"death": "c08a7a", "love": "e8a0b8",
}

func _push_feed(kind: String, text: String) -> void:
	var col: String = FEED_COLORS.get(kind, "8a7d68")
	_feed_lines.push_front("[color=#5a4f40][%d日][/color] [color=#%s]%s[/color]" % [world.day, col, text])
	if _feed_lines.size() > 40:
		_feed_lines.resize(40)
	if _feed != null:
		_feed.text = "\n".join(_feed_lines)

func _find_goblin(id: int) -> Goblin:
	for g in world.goblins:
		if g.id == id:
			return g
	return null

## renderer.pick_any() の int (0=なし/1=ゴブリン/2=敵/3=部屋/4=出現物) を SelKind へ写像する。
func _sel_kind_from_pick(kind: int) -> int:
	match kind:
		1: return SelKind.GOBLIN
		2: return SelKind.ENEMY
		3: return SelKind.ROOM
		4: return SelKind.FIELD
		_: return SelKind.NONE

# ════ 奇跡 (§4) ════
## 奇跡の現在コスト (ランク連動 §3。無料の基本命令は 0)。
func _miracle_cost(def: Dictionary) -> float:
	if def.cost_key == "":
		return 0.0
	return float(params.get(def.cost_key)) * world.miracle_mult()

## ボタン押下/ショートカット: 即時系はその場で発動、対象系は武装をトグルする。
func _press_miracle(def: Dictionary) -> void:
	var cost := _miracle_cost(def)
	# 集合は特別: 発令中なら押下 = 解除。
	if def.m == Controller.Miracle.RALLY and world.rally_point != Vector2i(-1, -1):
		world.rally_clear()
		_push_feed("event", "集合を解いた。みなが持ち場へ戻っていく。")
		_disarm()
		return
	if world.faith < cost:
		_push_feed("event", "信仰が足りない (必要 %.0f)。" % cost)
		return
	if int(def.target) == 0:
		# 即時系 (恵みのパン虫): 武装不要でその場で発動。
		if def.m == Controller.Miracle.MITES and world.cast_mites():
			_push_feed("event", "恵みのパン虫! 巣のあちこちで丸い影がもぞもぞ湧いた。(信仰 -%.0f)" % cost)
		_refresh_miracle_buttons()
		return
	_armed = -1 if _armed == int(def.m) else int(def.m)
	_refresh_miracle_buttons()

func _disarm() -> void:
	_armed = -1
	_refresh_miracle_buttons()

func _armed_def() -> Dictionary:
	for def in MIRACLE_DEFS:
		if int(def.m) == _armed:
			return def
	return {}

## 武装中の左クリック: 対象 (敵/ゴブリン/タイル) を指定して発動する。対象外クリックは
## 無視 (武装維持)。発動後も武装を保って連射でき、残高が尽きると自動解除する。
func _try_cast(pos: Vector2) -> void:
	var def := _armed_def()
	if def.is_empty():
		return
	var done := false
	match int(def.target):
		1:  # 敵クリック (稲妻)
			var picked := renderer.pick_any(world, pos)
			if int(picked.kind) != 2:
				return
			var eid := int(picked.id)
			var fx := 0.0
			var fy := 0.0
			for e in world.enemies:
				if e.id == eid:
					fx = (e.fx + 0.5) * renderer.tile_size
					fy = (e.fy + 0.5) * renderer.tile_size
					break
			if world.cast_lightning(eid):
				renderer.on_event({"t": "lightning", "x": fx, "y": fy})
				_push_feed("raid", "嘲りの稲妻が敵を撃った! (信仰 -%.0f)" % _miracle_cost(def))
				done = true
		2:  # ゴブリンクリック (名誉ある死)
			var picked2 := renderer.pick_any(world, pos)
			if int(picked2.kind) != 1:
				return
			if world.cast_honor(int(picked2.id)):
				var g := _find_goblin(int(picked2.id))
				_push_feed("raid", "%s が名誉ある死を授かり、激昂した! (信仰 -%.0f)"
						% [GobNames.of(g) if g != null else "誰か", _miracle_cost(def)])
				done = true
			else:
				_push_feed("event", "その者には授けられない (族長と子は対象外)。")
		3:  # タイルクリック (泥壁/怒り/召喚/集合)
			var tp := Vector2i(int(pos.x / renderer.tile_size), int(pos.y / renderer.tile_size))
			match int(def.m):
				Controller.Miracle.MUD:
					if world.cast_mud(tp.x, tp.y):
						_push_feed("raid", "泥の抱擁が大地を盛り上げ、道を塞いだ。(信仰 -%.0f)" % _miracle_cost(def))
						done = true
				Controller.Miracle.RAGE:
					if world.cast_rage(tp.x, tp.y):
						_push_feed("raid", "抑えられない怒りが敵中に弾け、同士討ちが始まった! (信仰 -%.0f)" % _miracle_cost(def))
						done = true
					else:
						_push_feed("event", "範囲に敵がいない。")
				Controller.Miracle.SUMMON:
					if world.cast_summon(tp.x, tp.y):
						_push_feed("birth", "下僕が泥の中から這い出てきた。(信仰 -%.0f)" % _miracle_cost(def))
						done = true
				Controller.Miracle.RALLY:
					if world.cast_rally(tp.x, tp.y):
						_push_feed("event", "集合の声! 手すきの者がぞろぞろ集まってくる。")
						_disarm()  # 集合は一発で武装解除 (解除はボタン再押下)
						return
	if done and world.faith < _miracle_cost(def):
		_disarm()  # 残高が尽きたら自動解除
	_refresh_miracle_buttons()

func _refresh_miracle_buttons() -> void:
	for mb in _miracle_buttons:
		var def: Dictionary = mb.def
		var btn: Button = mb.btn
		var armed: bool = _armed == int(def.m)
		if def.m == Controller.Miracle.RALLY and world.rally_point != Vector2i(-1, -1):
			btn.text = "%s解除" % def.name
		elif def.cost_key == "":
			btn.text = String(def.name)
		else:
			btn.text = "%s %.0f" % [def.name, _miracle_cost(def)]
		_style_button(btn, armed)
		btn.disabled = (not armed) and world.faith < _miracle_cost(def)

# ════ HUD ════
func _update_status() -> void:
	if _status_label == null:
		return
	var phase_txt: String = (["平時", "予兆", "⚔ 交戦"] as Array)[world.phase]
	var time_txt := "昼" if world.is_day() else "夜"
	var day_frac := float(world.tick % params.ticks_per_day) / float(params.ticks_per_day)
	var bar := _text_bar(day_frac, 10)
	var totem_txt := ""
	if world.totem_hp < params.totem_hp_max:
		totem_txt = "  ⚠トーテム %.0f/%.0f" % [world.totem_hp, params.totem_hp_max]
	_status_label.text = "第 %d 日 %s %s · %s   頭数 %d/%d (子%d)  食料 %.0f  信仰 %.0f/%.0f ランク%d  surge %.1f%s" % [
		world.day, bar, time_txt, phase_txt,
		world._alive_count(), params.cap_pop, _child_count(),
		world.food, world.faith, world.faith_cap(), world.rank(), world.surge, totem_txt,
	]
	var armed_def := _armed_def()
	if not armed_def.is_empty():
		# 武装中は ETA 行を奇跡のヒントに差し替える。
		_eta_label.text = "%s: %s (Esc/右クリックで解除)" % [armed_def.name, armed_def.hint]
		_eta_label.add_theme_color_override("font_color", C_EMBER_BRIGHT)
	elif world.outcome == World.Outcome.ONGOING and world.phase == World.Phase.PEACE:
		var days_left := float(world.next_big_raid_tick - world.tick) / float(params.ticks_per_day)
		_eta_label.text = "次の大襲撃まで 約 %s" % ("1 日未満" if days_left < 1.0 else "%d 日" % ceili(days_left))
		_eta_label.add_theme_color_override("font_color", C_BLOOD if days_left <= 1.0 else C_INK_FAINT)
	else:
		_eta_label.text = ""
	# 残高は時間で増えるので、ボタンの有効/無効だけ毎フレーム追従させる
	# (再スタイルは武装トグル時のみ。毎フレームの StyleBox 生成を避ける)。
	for mb in _miracle_buttons:
		var mdef: Dictionary = mb.def
		(mb.btn as Button).disabled = (_armed != int(mdef.m)) and world.faith < _miracle_cost(mdef)
	# 勝敗バナー。
	if world.outcome == World.Outcome.VICTORY:
		_outcome_label.text = "★ 勝利 — 規定日数を生き延びた!"
		_outcome_label.visible = true
	elif world.outcome == World.Outcome.DEFEAT:
		_outcome_label.text = "✖ 敗北"
		_outcome_label.visible = true

func _text_bar(frac: float, width: int) -> String:
	var filled := int(round(frac * width))
	return "▰".repeat(filled) + "▱".repeat(width - filled)

func _child_count() -> int:
	var n := 0
	for g in world.goblins:
		if g.is_child() and g.state != Goblin.State.DEAD:
			n += 1
	return n

const _INSPECTOR_HELP := "[color=#5a4f40]ゴブリン・敵・部屋をタップすると、その詳細が見える。[/color]"

func _update_inspector() -> void:
	if _inspector == null:
		return
	match sel_kind:
		SelKind.GOBLIN:
			var g := _find_goblin(sel_id)
			if g == null:
				_inspector.text = _INSPECTOR_HELP
				return
			_update_inspector_goblin(g)
		SelKind.ENEMY:
			_update_inspector_enemy(sel_id)
		SelKind.ROOM:
			_update_inspector_room(sel_id)
		SelKind.FIELD:
			var f := world._field_by_id(sel_id)
			if f == null:
				_inspector.text = _INSPECTOR_HELP
			else:
				_inspector.text = "[b][color=#ffb454]木の実の茂み[/color][/b]\n" \
					+ "[color=#8a7d68]巣外の恵み · のこり %d 食ぶん[/color]" % f.amount
		_:
			_inspector.text = _INSPECTOR_HELP

func _update_inspector_goblin(g: Goblin) -> void:
	var sex_jp := "♀ 雌" if g.sex == Goblin.Sex.FEMALE else "♂ 雄"
	var age_days := float(world.tick - g.born_tick) / float(params.ticks_per_day)
	var state_hex: String = STATE_HEX.get(g.state, "8a7d68")
	var lines: Array = []
	var follow_tag := "  [color=#e8943a]📍追従中[/color]" if _follow_id == g.id else ""
	lines.append("[b][color=#ffb454]%s[/color][/b]%s" % [GobNames.of(g), follow_tag])
	lines.append("[color=#8a7d68]%s · %s · %.1f 日齢 · [color=#%s]%s[/color][/color]" % [
		sex_jp, ROLE_JP.get(g.role, "?"), age_days, state_hex, STATE_JP.get(g.state, "?")])
	lines.append("[color=#7a9a4e]体力[/color] %s %.1f/%.0f" % [_text_bar(g.hp / g.max_hp, 8), g.hp, g.max_hp])
	lines.append("[color=#c08a3a]空腹[/color] %s %d%%" % [_text_bar(g.hunger, 8), int(g.hunger * 100)])
	lines.append("[color=#4a6b8a]眠気[/color] %s %d%%" % [_text_bar(g.sleepiness, 8), int(g.sleepiness * 100)])
	var tags: Array = []
	if g.is_unique:
		tags.append("[color=#ffb454]恐怖を持たない盾[/color]")
	if g.is_child():
		tags.append("子ゴブリン")
	if g.pregnant:
		var left := float(params.pregnancy_ticks - g.pregnant_ticks) / float(params.ticks_per_day)
		tags.append("[color=#e8a0b8]身ごもっている (あと %.1f 日)[/color]" % left)
	if g.equipped:
		tags.append("武装済み")
	if g.dispatch_id >= 0:
		tags.append("[color=#e8943a]外の恵みへ派遣中[/color]")
	if g.carrying_food:
		tags.append("[color=#9adb6e]食料を運搬中[/color]")
	if g.role == Goblin.Role.GUARD and g.guard_gate >= 0:
		tags.append("[color=#e8943a]第%d巣口の番[/color]" % (g.guard_gate + 1))
	if g.bereaved:
		tags.append("伴侶を失った悲しみ")
	if not tags.is_empty():
		lines.append("[color=#5a4f40]" + " · ".join(tags) + "[/color]")
	_inspector.text = "\n".join(lines)

func _update_inspector_enemy(id: int) -> void:
	var e: EnemyUnit = null
	for cand in world.enemies:
		if cand.id == id:
			e = cand
			break
	if e == null:
		_inspector.text = "[color=#5a4f40]討ち取った。[/color]"
		return
	var lines: Array = []
	var title := "人間の襲撃者" if e.is_human else "ゴブリンの襲撃者 (敵対部族)"
	lines.append("[b][color=#c0432e]%s[/color][/b]" % title)
	lines.append("[color=#7a9a4e]体力[/color] %s %.1f/%.0f" % [_text_bar(e.hp / e.max_hp, 8), e.hp, e.max_hp])
	lines.append("[color=#8a7d68]第%d巣口へ進軍中[/color]" % (e.target_gate_idx + 1))
	_inspector.text = "\n".join(lines)

func _update_inspector_room(idx: int) -> void:
	if idx < 0 or idx >= world.map.rooms.size():
		_inspector.text = _INSPECTOR_HELP
		return
	var r: Dictionary = world.map.rooms[idx]
	var name_jp: String = ROOM_TYPE_JP.get(r.room_type, "?")
	var lines: Array = []
	lines.append("[b][color=#ffb454]%s[/color][/b]" % name_jp)
	lines.append("[color=#8a7d68]広さ %d×%d[/color]" % [r.w, r.h])
	var assigned_n: int = (r.assigned as Array).size() if r.has("assigned") else 0
	lines.append("[color=#7a9a4e]配置済み[/color] %d 体" % assigned_n)
	_inspector.text = "\n".join(lines)

# ════ UI 構築 (Web 版ダッシュボードの配色) ════
func _build_ui() -> void:
	var ui := $UI as CanvasLayer

	# --- 上端ステータスバー ---
	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.add_theme_stylebox_override("panel", _panel_style())
	var top_box := HBoxContainer.new()
	top_box.add_theme_constant_override("separation", 16)
	top.add_child(top_box)
	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", C_INK)
	_status_label.add_theme_font_size_override("font_size", 13)
	top_box.add_child(_status_label)
	_eta_label = Label.new()
	_eta_label.add_theme_color_override("font_color", C_INK_FAINT)
	_eta_label.add_theme_font_size_override("font_size", 12)
	top_box.add_child(_eta_label)
	ui.add_child(top)

	# --- 右パネル: 観察対象 + 巣の記録 ---
	var right := PanelContainer.new()
	right.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	right.offset_left = -290.0
	right.offset_top = 40.0
	right.offset_bottom = -44.0
	right.add_theme_stylebox_override("panel", _panel_style())
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	right.add_child(vbox)

	vbox.add_child(_section_title("観 察 対 象"))
	_inspector = RichTextLabel.new()
	_inspector.bbcode_enabled = true
	_inspector.fit_content = true
	_inspector.custom_minimum_size = Vector2(0, 130)
	_inspector.add_theme_font_size_override("normal_font_size", 12)
	_inspector.add_theme_font_size_override("bold_font_size", 14)
	vbox.add_child(_inspector)

	vbox.add_child(_section_title("巣 の 記 録"))
	_feed = RichTextLabel.new()
	_feed.bbcode_enabled = true
	_feed.scroll_active = true
	_feed.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_feed.add_theme_font_size_override("normal_font_size", 11)
	vbox.add_child(_feed)
	ui.add_child(right)

	# --- 勝敗バナー (中央) ---
	_outcome_label = Label.new()
	_outcome_label.set_anchors_preset(Control.PRESET_CENTER)
	_outcome_label.add_theme_font_size_override("font_size", 28)
	_outcome_label.add_theme_color_override("font_color", C_EMBER_BRIGHT)
	_outcome_label.visible = false
	ui.add_child(_outcome_label)

	# --- 左下: 速度コントロール ---
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bar.offset_top = -40.0
	bar.offset_left = 8.0
	bar.add_theme_constant_override("separation", 4)
	for cfg in [["‖ 停止", 0.0], ["▶ 1x", 1.0], ["▶▶ 3x", 3.0]]:
		var b := Button.new()
		b.text = cfg[0]
		b.add_theme_font_size_override("font_size", 12)
		_style_button(b, false)
		var sp: float = cfg[1]
		b.pressed.connect(func() -> void:
			speed = sp
			_refresh_speed_buttons())
		bar.add_child(b)
		_speed_buttons.append({"btn": b, "speed": sp})
	# 奇跡バー (§4)。武装中は強調表示、残高不足で無効化。コストはランク連動で
	# ラベルに常時表示する (_refresh_miracle_buttons)。
	for def in MIRACLE_DEFS:
		var mb := Button.new()
		mb.add_theme_font_size_override("font_size", 12)
		var d: Dictionary = def
		mb.pressed.connect(func() -> void: _press_miracle(d))
		bar.add_child(mb)
		_miracle_buttons.append({"btn": mb, "def": def})
	ui.add_child(bar)
	_refresh_speed_buttons()
	_refresh_miracle_buttons()

	# --- 派遣パネル (§11.5。中央下。出現物クリックで開く) ---
	_dispatch_panel = PanelContainer.new()
	_dispatch_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	# 点アンカー (中央下) なので寸法はオフセットで明示する (260×102 px)。
	_dispatch_panel.offset_left = -130.0
	_dispatch_panel.offset_right = 130.0
	_dispatch_panel.offset_top = -150.0
	_dispatch_panel.offset_bottom = -48.0
	_dispatch_panel.add_theme_stylebox_override("panel", _panel_style())
	_dispatch_panel.visible = false
	var dbox := VBoxContainer.new()
	dbox.add_theme_constant_override("separation", 6)
	_dispatch_panel.add_child(dbox)
	dbox.add_child(_section_title("巣 外 の 恵 み"))
	_dispatch_info = Label.new()
	_dispatch_info.add_theme_color_override("font_color", C_INK)
	_dispatch_info.add_theme_font_size_override("font_size", 12)
	dbox.add_child(_dispatch_info)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	_dispatch_slider = HSlider.new()
	_dispatch_slider.min_value = 1
	_dispatch_slider.step = 1
	_dispatch_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dispatch_slider.value_changed.connect(func(v: float) -> void:
		_dispatch_count.text = "ゴブリン %d 体" % int(v))
	srow.add_child(_dispatch_slider)
	_dispatch_count = Label.new()
	_dispatch_count.add_theme_color_override("font_color", C_EMBER_BRIGHT)
	_dispatch_count.add_theme_font_size_override("font_size", 12)
	srow.add_child(_dispatch_count)
	dbox.add_child(srow)
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 4)
	_dispatch_button = Button.new()
	_dispatch_button.text = "派遣する"
	_dispatch_button.add_theme_font_size_override("font_size", 12)
	_style_button(_dispatch_button, true)
	_dispatch_button.pressed.connect(_confirm_dispatch)
	brow.add_child(_dispatch_button)
	var cancel := Button.new()
	cancel.text = "やめる"
	cancel.add_theme_font_size_override("font_size", 12)
	_style_button(cancel, false)
	cancel.pressed.connect(_close_dispatch_panel)
	brow.add_child(cancel)
	dbox.add_child(brow)
	ui.add_child(_dispatch_panel)

# ════ 派遣パネル (§11.5) ════
## 出現物クリックで開く。スライダー上限は開いた時点の手すき頭数
## (開いている間の変動は確定時に world 側が実際に送れる数へ丸める)。
func _open_dispatch_panel(field_id: int) -> void:
	_dispatch_field_id = field_id
	var pool := world.dispatch_pool_count()
	if pool > 0:
		_dispatch_slider.max_value = pool
		_dispatch_slider.value = clampi(2, 1, pool)  # 既定 2 体 (オートプレイと同じ)
		_dispatch_slider.editable = true
		_dispatch_button.disabled = false
	else:
		_dispatch_slider.max_value = 1
		_dispatch_slider.value = 1
		_dispatch_slider.editable = false
		_dispatch_button.disabled = true
	_dispatch_count.text = "ゴブリン %d 体" % int(_dispatch_slider.value)
	_dispatch_panel.visible = true

func _close_dispatch_panel() -> void:
	_dispatch_field_id = -1
	if _dispatch_panel != null:
		_dispatch_panel.visible = false

func _confirm_dispatch() -> void:
	if _dispatch_field_id >= 0:
		controller.queue.append({
			"type": Controller.CommandType.DISPATCH,
			"target": _dispatch_field_id, "count": int(_dispatch_slider.value),
		})
	_close_dispatch_panel()

## 毎フレーム: 対象の出現物が消えたら (回収完了・日没) パネルを自動で閉じ、
## 残量・手すき表示を追従させる (スライダー値はいじらない)。
func _update_dispatch_panel() -> void:
	if _dispatch_panel == null or not _dispatch_panel.visible:
		return
	var f := world._field_by_id(_dispatch_field_id)
	if f == null:
		_close_dispatch_panel()
		return
	if _dispatch_button.disabled:
		_dispatch_info.text = "のこり %d 食ぶん — 手すきのゴブリンがいない" % f.amount
	else:
		_dispatch_info.text = "のこり %d 食ぶん" % f.amount

func _refresh_speed_buttons() -> void:
	for d in _speed_buttons:
		_style_button(d.btn as Button, absf(float(d.speed) - speed) < 0.01)

func _section_title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", C_INK_FAINT)
	l.add_theme_font_size_override("font_size", 10)
	return l

func _panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = C_BG_PANEL
	s.border_color = C_ROCK_LINE
	s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	s.set_content_margin_all(10)
	return s

func _style_button(b: Button, active: bool) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = C_EMBER if active else Color(0.165, 0.141, 0.114, 0.95)
	s.border_color = C_EMBER_BRIGHT if active else C_ROCK_LINE
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	s.set_content_margin_all(6)
	b.add_theme_stylebox_override("normal", s)
	b.add_theme_stylebox_override("hover", s)
	b.add_theme_stylebox_override("pressed", s)
	b.add_theme_color_override("font_color", Color("1a1106") if active else C_INK)

func _update_camera() -> void:
	# マップ全体が見えるよう中央に寄せる (右パネルぶん左へ寄せる)。
	# フィット倍率・位置を再計算してキャッシュし、現在の _zoom_factor を保ったまま再適用する。
	var m := world.map
	var cam := $Camera2D as Camera2D
	if cam == null:
		return
	var vp := get_viewport_rect().size
	var usable_w := vp.x - RIGHT_PANEL_W
	var zoom_x := usable_w / (m.width * renderer.tile_size + 24.0)
	var zoom_y := (vp.y - 90.0) / (m.height * renderer.tile_size + 24.0)
	_fit_zoom = minf(zoom_x, zoom_y)
	_fit_pos = Vector2(m.width * renderer.tile_size / 2.0, m.height * renderer.tile_size / 2.0) \
		+ Vector2(RIGHT_PANEL_W / 2.0 / _fit_zoom, -20.0 / _fit_zoom)
	# 現在のユーザー倍率を保って再適用
	# (factor=1.0 かつ手動操作なしならフィット位置へ正確に復帰)。
	var z := _fit_zoom * _zoom_factor
	cam.zoom = Vector2(z, z)
	if _zoom_factor <= ZOOM_MIN + 0.0001 and not _manual_camera:
		cam.position = _fit_pos
	else:
		_clamp_camera(cam)
