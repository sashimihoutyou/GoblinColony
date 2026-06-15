extends Node2D
## メインループ (P1-09 / P1-10)。実時間 → tick 変換 → controller → world.tick → render。
##
## 実時間に触れるのはここだけ (KI-09 tick_driver 相当)。速度倍率と端数持ち越し。
## タイムスケール: 1 tick = 0.75 実秒 × ticks_per_day=240 → 1 日 = 実 180 秒 (3x で 60 秒)。
## 介入・観察の余地を持たせるため一律 2 倍スローにしている (体感テンポ調整)。
## tick が細かいのは連続移動 (RimWorld 風) のサンプリングのため (params.gd 参照)。
## UI はコードで構築する (Web 版ダッシュボードと同じ配色言語: 闇の岩・琥珀・苔)。

const MS_PER_TICK := 750.0

# --- 自動セーブ (C1 / GDD §14.5.1) ---
# 確定的 tick スナップショット (world.snapshot()) を JSON で保存・復元する。
# 実時間は含めない (KI-09)。タイミングは _step_one_tick 参照。
const AUTOSAVE_PATH := "user://autosave.json"

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

# --- 巣外の出現物 (§11.5 外征)。種別の表示名・見つかったときの一言・
# 派遣パネルでのリターン目安。CAMP のみ別途 _camp_difficulty_hint() で
# 難度ヒントを足す。---
const FIELD_KIND_JP := {
	FieldResource.Kind.FORAGE: "木の実の茂み", FieldResource.Kind.ANIMAL: "獲物の気配",
	FieldResource.Kind.TRAVELER: "旅人", FieldResource.Kind.WANDERER: "放浪ゴブリン",
	FieldResource.Kind.CAMP: "敵性キャンプ", FieldResource.Kind.RUINS: "廃墟",
	FieldResource.Kind.MAIDEN: "行き倒れの少女",
}
const FIELD_SPAWN_JP := {
	FieldResource.Kind.FORAGE: "巣の外に木の実の茂みが見つかった (%d 食ぶん)。",
	FieldResource.Kind.ANIMAL: "巣の外に獲物の気配がある (%d 頭ぶん)。",
	FieldResource.Kind.TRAVELER: "巣の外に旅人が通りかかった。",
	FieldResource.Kind.WANDERER: "巣の外をうろつく放浪ゴブリンを見かけた。",
	FieldResource.Kind.CAMP: "巣の外に敵性キャンプの灯りが見える。",
	FieldResource.Kind.RUINS: "巣の外に古い廃墟が見える (%d 山ぶん)。",
	FieldResource.Kind.MAIDEN: "巣の外で行き倒れの少女を見つけた。",
}
const FIELD_RETURN_JP := {
	FieldResource.Kind.FORAGE: "食料",
	FieldResource.Kind.ANIMAL: "食料(多め)+捕虜の可能性",
	FieldResource.Kind.TRAVELER: "宝石/薬草",
	FieldResource.Kind.WANDERER: "頭数+1の可能性",
	FieldResource.Kind.CAMP: "戦果(宝石+装備+捕虜) or 負傷",
	FieldResource.Kind.RUINS: "建材+宝石の可能性",
	FieldResource.Kind.MAIDEN: "保護(捕虜 or 新たな出会い)",
}
const FIELD_DISTANCE_JP := {0: "近い", 1: "遠い"}

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
# 建築モード (§3-15。演出/入力ローカル)。_armed_build = 武装中の部屋タイプ
# (TileMapData.RoomType / -1 = 非武装)。武装中はゴーストがカーソルに追従し、
# クリックで確定 (= 2 タップ目)。奇跡の武装とは排他。
var _armed_build: int = -1
var _build_buttons: Array = []  # Array[Dictionary] {btn: Button, rt: int}

# 捕虜パネル + つがい承認バナー (§3-19/KI-21。表示状態は演出ローカル)。
var _captive_panel: PanelContainer
var _captive_info: Label
var _concubine_button: Button
var _gem_row: HBoxContainer        # 宝石献上の行 (§14/B5。gems 保有時のみ表示)
var _gem_tribute_button: Button
# 捕虜パネルの手動表示フラグ (演出ローカル)。既定では捕虜が居るときだけ自動表示し、
# 捕虜不在時は隠す (派遣パネルと重ならない)。トグルボタンで強制表示/非表示できる
# (捕虜不在でも宝石献上だけしたい / 邪魔なとき畳む)。
var _captive_pinned: bool = false
var _captive_toggle_button: Button
var _bond_banner: PanelContainer
var _bond_label: Label
var _bond_captive_id: int = -1  # バナーが対象にしている承認待ち側室の id

# 会話ログ (演出ローカル)。ON のときだけフレーバー会話を「巣の記録」に流す。既定 OFF で
# ログが流れ続けるのを防ぐ。生成は演出専用 RNG (シム RNG を消費しない / KI-09)。
var _conversation_on: bool = false
var _conversation_toggle_button: Button
var _conv_rng := RandomNumberGenerator.new()
var _conv_next_tick: int = 0       # 次に会話を試みる tick (スロットル)
var _conv_last_text: String = ""   # 直近の会話 (重複抑制)

# 建築できる部屋 (spec 3-15 の 5 種)。
const BUILD_TYPES := [
	TileMapData.RoomType.RAT_RANCH,
	TileMapData.RoomType.MUSHROOM,
	TileMapData.RoomType.SMITHY,
	TileMapData.RoomType.NURSERY,
	TileMapData.RoomType.WITCH,
]

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
# 防衛配分パネル (§3-17: 襲撃時のみ表示。巣口ごとのスライダー + 自動)
var _defense_panel: PanelContainer
var _defense_sliders: Array = []   # Array[HSlider] (巣口ごと)
var _defense_auto_button: Button
var _defense_syncing: bool = false  # 自動追従でスライダーを書き戻す間の value_changed 抑止

func _ready() -> void:
	_conv_rng.randomize()  # 会話ログ用の演出 RNG (シム RNG とは独立 / KI-09)
	params = SimParams.new()
	world = World.new()
	world.setup(params)
	controller = AutoController.new()
	(controller as AutoController).auto_dispatch = false

	renderer = $Renderer
	renderer.tile_size = 16

	var restored := _load_autosave()

	_build_ui()
	_update_camera()
	get_viewport().size_changed.connect(_update_camera)
	if restored:
		_push_feed("event", "巣の記録を復元した (%d 日目)。" % world.day)
	else:
		_push_feed("event", "巣が築かれた。%d 体のゴブリンと族長。" % params.start_goblins)

## 指定難度で新しい群れを始める (§14.5.2)。world を作り直し、古いセーブを消す
## (前の群れのセーブで即終了画面に戻らないように)。演出層の選択状態もリセット。
func _start_new_game(diff: int) -> void:
	_delete_autosave()
	world = World.new()
	world.difficulty = diff
	world.setup(params)
	speed = 1.0
	_armed = -1
	_armed_build = -1
	sel_kind = SelKind.NONE
	sel_id = -1
	_follow_id = -1
	_outcome_label.visible = false
	_feed.clear()
	_feed_lines.clear()
	var diff_jp: String = ["易", "並", "難"][clampi(diff, 0, 2)]
	_push_feed("event", "新しい群れ (難度: %s)。%d 体のゴブリンと族長。" % [diff_jp, params.start_goblins])
	_refresh_speed_buttons()
	_refresh_miracle_buttons()
	_refresh_build_buttons()

## 自動セーブの復元 (C1)。user://autosave.json が存在し、有効な JSON の
## World.snapshot() であれば world に復元する。存在しない・壊れている場合は
## 何もせず新規開始のまま (setup() 済みの world を使う)。
func _load_autosave() -> bool:
	if not FileAccess.file_exists(AUTOSAVE_PATH):
		return false
	var f := FileAccess.open(AUTOSAVE_PATH, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	world.restore(parsed)
	return true

## 自動セーブの書き出し (C1)。world.snapshot() を JSON 化して保存する
## (実時間は含めない / KI-09)。
func _save_autosave() -> void:
	var f := FileAccess.open(AUTOSAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	# JSON 既定精度で書く。Godot の JSON/var_to_str はいずれも任意 double の
	# テキスト往復をバイト一致できない (17 桁出力を parse が 16 桁へ丸める) ため、
	# バイト一致は追わず「ロード後に自己無矛盾で決定的」を保証する設計とする
	# (KI-09 のバイト一致はライブ dict 往復 = parity 側で担保。autosave は
	# 既定精度の冪等点へ倒し、再ロードで同じ未来を再現する / test_save.gd)。
	f.store_string(JSON.stringify(world.snapshot()))
	f.close()

## 自動セーブの削除 (C1)。勝敗確定後に呼び、古いセーブで再開して即敗北画面に
## なる事態を防ぐ。
func _delete_autosave() -> void:
	if FileAccess.file_exists(AUTOSAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(AUTOSAVE_PATH))

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
	elif world.outcome == World.Outcome.ONGOING:
		# 停止中 (speed=0) でもプレイヤーの指示はキュー経由で即時反映する。
		# (commands は controller.queue に積まれ、通常は _step_one_tick の
		#  controller.apply で消化されるが、停止中は tick が回らず溜まったまま
		#  「捕虜操作・建築・派遣・防衛配分を押しても何も起きない」状態になる。)
		# AI 配分 (decide) は tick に紐づくので呼ばず、プレイヤーのキュー消化のみ。
		controller.apply(world)
	# 描画は毎フレーム (tick 間も補間・粒子・炎が動く)。
	# α = 次 tick までの端数 (固定タイムステップ補間。停止中は固定され静止)。
	renderer.sel_kind = sel_kind
	renderer.sel_id = sel_id
	# 建築ゴースト (§3-15): カーソル追従。置けるかの判定もここで渡す (演出ローカル)。
	if _armed_build >= 0:
		var tl := _ghost_topleft(get_global_mouse_position())
		var size: Vector2i = SimParams.ROOM_BUILD_SIZE[_armed_build]
		renderer.build_ghost = {"x": tl.x, "y": tl.y, "w": size.x, "h": size.y,
				"ok": world.can_place_room(_armed_build, tl.x, tl.y)
					and world.mud >= float(SimParams.ROOM_BUILD_COST[_armed_build])}
	else:
		renderer.build_ghost = {}
	renderer.render(world, delta, speed, clampf(_accum_ms / MS_PER_TICK, 0.0, 1.0))
	_update_status()
	_update_inspector()
	_update_dispatch_panel()
	_update_captive_ui()
	_update_defense_panel()
	# カメラ操作はシム停止中 (speed=0) でも独立して動く。
	_process_keyboard_pan(delta)
	_process_follow_camera(delta)

## 矢印キーでのパン。画面スペースで一定速度になるよう zoom で割る。
## パンしたら追従モードを解除する。WASD は奇跡ホットバー (Q W E R T Y G) と衝突する
## ため割り当てない (W=パン虫の誤発動を防ぐ)。パンは矢印キー / 中ドラッグ / ホイール。
func _process_keyboard_pan(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_physical_key_pressed(KEY_DOWN):
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
	var day_boundary := (world.tick % params.ticks_per_day) == (params.ticks_per_day - 1)
	world.tick_once()
	# シムの構造化イベントをフィードと演出へ翻訳する。
	# on_tick より先に処理する: 死亡/巣立ちバーストは演出層に残る直前の
	# 補間位置 (_last_pos_of) を使うため、その個体が on_tick で除去される前に拾う。
	var raid_ended := false
	var game_over := false
	for e in world.last_events:
		_push_feed_event(e)
		renderer.on_event(e)
		var et: String = e.get("t", "")
		if et == "raid_end":
			raid_ended = true
		elif et == "victory" or et == "defeat":
			game_over = true
	# tick 確定後に演出層の補間ターゲット (prev→cur) を更新する。
	# (1 フレームに複数 tick 回る場合も毎回。O(個体数) の座標コピーのみ)
	renderer.on_tick(world)
	# 会話ログ (演出層のみ・ON のときだけ)。シム RNG を消費しない (KI-09)。
	_maybe_emit_conversation()
	# 自動セーブ (C1 / GDD §14.5.1): 日境界・襲撃終了 (PEACE 遷移) で保存する。
	# 交戦中はセーブしない (直前の安定点に倒す)。勝敗確定後は古いセーブを消す
	# (再開時に即敗北/勝利画面にならないように)。
	if game_over:
		_delete_autosave()
	elif world.phase != World.Phase.COMBAT and (day_boundary or raid_ended):
		_save_autosave()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# 左クリック: 武装中は奇跡/建築の対象指定、そうでなければ個体/敵/部屋を
				# 選択。空振りはタイル指示 (採掘指定・壁修復) を試す。
				if event.pressed:
					if _armed >= 0:
						_try_cast(get_global_mouse_position())
					elif _armed_build >= 0:
						_try_place_build(get_global_mouse_position())
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
						if sel_kind == SelKind.NONE:
							_try_tile_order(get_global_mouse_position())
			MOUSE_BUTTON_RIGHT:
				# 右クリック: 武装中なら奇跡/建築を解除。ゴブリンを拾えれば追従モード開始
				# (インスペクタ選択も同期)。敵/部屋/空振りは選択のみ更新し追従は解除する。
				if event.pressed and (_armed >= 0 or _armed_build >= 0):
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
		if event.keycode == KEY_ESCAPE and (_armed >= 0 or _armed_build >= 0):
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
	# カメラ中心の可動域 = マップ矩形そのもの。中心がマップ端に立てるので、
	# 画面の半分まではマップ外 (外の闇) をはみ出して覗ける。
	cam.position.x = clampf(cam.position.x, 0.0, map_w)
	cam.position.y = clampf(cam.position.y, 0.0, map_h)

# ════ イベント → 物語の文 ════
func _push_feed_event(e: Dictionary) -> void:
	var t: String = e.get("t", "")
	match t:
		"raid":
			var who: String = {
				"human": "人間の討伐隊",
				"kugyo": "苦魚族の群れ",
				"bunta": "ブン・タ＝タ族の群れ",
			}.get(e.get("faction", ""), "敵対氏族の群れ")
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
			_push_feed("birth", "%s が %d 匹の子を産んだ。" % [mname, e.get("count", 0)], int(e.get("mother", -1)))
		"grow":
			_push_feed("birth", "%s が一人前に育った。" % GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))), int(e.get("id", -1)))
		"mite_eaten":
			_push_feed("event", "%s がパン虫を捕まえて食べた。" % GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))), int(e.get("id", -1)))
		"fumble":
			var fnm := GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))
			if e.get("dropped", false):
				_push_feed("event", "%s が転んでキノコを取り落とした。" % fnm, int(e.get("id", -1)))
			else:
				_push_feed("event", "%s がすっ転んだ。" % fnm, int(e.get("id", -1)))
		"forage":
			# 採集はひっきりなしに起きるのでフィードは 4 回に 1 回だけ流す (煩さ低減)。
			_forage_feed_count += 1
			if _forage_feed_count % 4 == 0:
				_push_feed("event", "%s がキノコを集積所に運び込んだ。" \
					% GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))), int(e.get("id", -1)))
		"guard":
			_push_feed("event", "%s が巣口の見張りに就いた。" \
				% GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))), int(e.get("id", -1)))
		"alarm":
			_push_feed("raid", "見張りの %s が警報を上げた!" \
				% GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0))), int(e.get("id", -1)))
		"quarrel":
			var ga := _find_goblin(int(e.get("a", -1)))
			var gb := _find_goblin(int(e.get("b", -1)))
			var na: String = GobNames.of(ga) if ga != null else "ゴブリン"
			var nb: String = GobNames.of(gb) if gb != null else "ゴブリン"
			_push_feed("event", "%s と %s がケンカを始めた!" % [na, nb], int(e.get("a", -1)))
		"court":
			var cf := _find_goblin(int(e.get("f", -1)))
			var cm := _find_goblin(int(e.get("m", -1)))
			var cfn: String = GobNames.of(cf) if cf != null else "雌ゴブリン"
			var cmn: String = GobNames.of(cm) if cm != null else "雄ゴブリン"
			_push_feed("love", "%s が %s を寝床に誘った。" % [cfn, cmn], int(e.get("f", -1)))
		"mating":
			var mf := _find_goblin(int(e.get("f", -1)))
			var mm := _find_goblin(int(e.get("m", -1)))
			var mfn: String = GobNames.of(mf) if mf != null else "雌ゴブリン"
			var mmn: String = GobNames.of(mm) if mm != null else "雄ゴブリン"
			_push_feed("love", "%s と %s が寝床にこもった。" % [mfn, mmn], int(e.get("f", -1)))
		"pregnant":
			var f := _find_goblin(int(e.get("id", -1)))
			if f != null:
				_push_feed("love", "%s が寝床で身ごもった。" % GobNames.of(f), f.id)
		"field_spawn":
			var sp_kind: int = int(e.get("kind", FieldResource.Kind.FORAGE))
			var sp_fmt: String = FIELD_SPAWN_JP.get(sp_kind, FIELD_SPAWN_JP[FieldResource.Kind.FORAGE])
			if sp_fmt.find("%d") >= 0:
				_push_feed("event", sp_fmt % e.get("amount", 0))
			else:
				_push_feed("event", sp_fmt)
		"dispatch":
			_push_feed("event", "%d 体が恵みを取りに巣を出た。" % e.get("count", 0))
		"field_haul":
			var fh_kind: int = int(e.get("kind", FieldResource.Kind.FORAGE))
			var fh_who := GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))
			match fh_kind:
				FieldResource.Kind.ANIMAL:
					_push_feed("event", "%s が獲物を狩り、食料を持ち帰った。" % fh_who, int(e.get("id", -1)))
				FieldResource.Kind.RUINS:
					_push_feed("event", "%s が廃墟から建材を持ち帰った。" % fh_who, int(e.get("id", -1)))
				_:
					_push_feed("event", "%s がキノコを集積所に運び込んだ。" % fh_who, int(e.get("id", -1)))
		"field_captive":
			var fc_who := GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))
			_push_feed("event", "%s が狩りの最中に弱ったゴブリンを連れて帰った。捕虜が増えた。" % fc_who, int(e.get("id", -1)))
		"field_gem":
			var fg := _find_goblin(int(e.get("id", -1)))
			var fg_who: String = GobNames.of(fg) if fg != null else "誰か"
			_push_feed("birth", "%s が廃墟の瓦礫の中から宝石を見つけた!" % fg_who, int(e.get("id", -1)))
		"field_trade":
			var ft := _find_goblin(int(e.get("id", -1)))
			var ft_who: String = GobNames.of(ft) if ft != null else "誰か"
			if e.get("good", "") == "gems":
				_push_feed("event", "%s が旅人と宝石を交換した。" % ft_who, int(e.get("id", -1)))
			else:
				_push_feed("event", "%s が旅人から薬草を譲り受けた。" % ft_who, int(e.get("id", -1)))
		"field_faux_pas":
			var fp := _find_goblin(int(e.get("id", -1)))
			var fp_who: String = GobNames.of(fp) if fp != null else "誰か"
			_push_feed("raid", "%s が旅人に粗相をしてしまった……人間たちとの間に緊張が走る。" % fp_who, int(e.get("id", -1)))
		"wanderer_joined":
			var wj_who := GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))
			_push_feed("birth", "放浪していた %s が群れに加わった。" % wj_who, int(e.get("id", -1)))
		"wanderer_left":
			_push_feed("event", "放浪ゴブリンは去って行った。")
		"field_maiden":
			if e.get("amina", false):
				_push_feed("love", "行き倒れの少女を連れて帰った。手厚く保護することにした。")
			else:
				_push_feed("event", "行き倒れの少女を連れて帰った。捕虜として保護した。")
		"field_camp_win":
			var captive_txt: String = "捕虜も連れて" if e.get("captive", false) else ""
			_push_feed("birth", "★ 敵性キャンプを襲撃し、%s宝石と装備を持ち帰った!" % captive_txt)
		"field_camp_loss":
			var cl_id: int = int(e.get("id", -1))
			var cl_g := _find_goblin(cl_id)
			if cl_g != null:
				_push_feed("raid", "敵性キャンプの襲撃は失敗……%s が傷を負って逃げ帰った。" % GobNames.of(cl_g), cl_id)
			else:
				_push_feed("raid", "敵性キャンプの襲撃は失敗し、何も持ち帰れなかった。")
		"field_recall":
			_push_feed("raid", "外に出ていた %d 体に、急いで帰るよう呼びかけた。" % e.get("count", 0))
		"amina_foreshadow":
			_push_feed("love", "保護した少女が、少しずつこちらに心を開きはじめている……。")
		"amina_closed":
			_push_feed("event", "少女との間にできかけていた何かは、もう戻らない。")
		"amina_joined":
			var am := _find_goblin(int(e.get("id", -1)))
			var am_name: String = GobNames.of(am) if am != null else "少女"
			_push_feed("love", "%s が心を開き、戦わない仲間として群れに加わった。" % am_name, int(e.get("id", -1)))
		"mine_done":
			var miner := _find_goblin(int(e.id))
			var miner_name: String = GobNames.of(miner) if miner != null else "誰か"
			if e.get("gem", false):
				_push_feed("birth", "%s が岩塊を掘り崩した。崩れた奥から宝石が転がり出た!" % miner_name, int(e.id))
			else:
				_push_feed("event", "%s が岩塊を掘り崩し、建材を積み上げた。" % miner_name, int(e.id))
		"dig_done":
			var digger := _find_goblin(int(e.id))
			_push_feed("event", "%s が岩壁を掘り抜き、巣穴がひとつ広がった。"
					% (GobNames.of(digger) if digger != null else "誰か"), int(e.id))
		"build_start":
			_push_feed("event", "%sの建設が始まった。地面に骨と泥で印が引かれる。"
					% ROOM_TYPE_JP.get(int(e.room_type), "部屋"))
		"build_done":
			_push_feed("birth", "%sが完成した!" % ROOM_TYPE_JP.get(int(e.room_type), "部屋"), int(e.id))
		"repair_done":
			var fixer := _find_goblin(int(e.id))
			_push_feed("event", "%s が壁のひびを泥で塗り固めた。"
					% (GobNames.of(fixer) if fixer != null else "誰か"), int(e.id))
		"breach_warn":
			_push_feed("raid", "敵が壁を狙っている……割られる前に塞ぐ手を。")
		"breach":
			_push_feed("raid", "✖ 壁が打ち破られた! 突破口から敵が雪崩れ込む。")
		"field_done":
			_push_feed("event", "茂みを取り尽くした。")
		"field_expire":
			_push_feed("event", "日が暮れ、外の恵みは闇に消えた。")
		"victory":
			_push_feed("event", "★ ラストバトルを撃退 — 勝利!")
		"defeat":
			var reason: String = "トーテムが砕かれた" if e.get("reason", "") == "totem" else "群れは全滅した"
			_push_feed("raid", "✖ %s — 敗北……" % reason)
		"captive_gain":
			var who: String = "人間" if e.get("human", false) else "ゴブリン"
			_push_feed("event", "撃退の戦果として%sの捕虜を得た。" % who)
		"captive_joined":
			_push_feed("event", "捕らわれていた%s が群れに加わった。" \
				% GobNames.name_of(int(e.get("id", -1)), Goblin.Sex.MALE), int(e.get("id", -1)))
		"sacrifice":
			var kind_txt: String = {
				"male_goblin": "ゴブリンの雄捕虜",
				"female_goblin": "ゴブリンの雌捕虜",
				"male_human": "人間の雄捕虜",
				"female_human": "人間の雌捕虜",
			}.get(e.get("kind", ""), "捕虜")
			_push_feed("event", "%sを生贄に捧げ、信仰が高まった。" % kind_txt)
		"release_captive":
			var sex_txt: String = "雄" if int(e.get("sex", 0)) == Goblin.Sex.MALE else "雌"
			_push_feed("event", "人間の%s捕虜を解放した。敵対度が和らいだ。" % sex_txt)
		"tribute":
			var fac_txt: String = {
				"human": "人間", "bunta": "ブン・タ＝タ族", "kugyo": "苦魚族",
			}.get(e.get("faction", ""), "敵対勢力")
			_push_feed("event", "%sへ捕虜を朝貢した。怒りがいくらか鎮まる。" % fac_txt)
		"tribute_gems":
			_push_feed("event", "宝石 %d を人間へ差し出した。和平の対価として怒りが和らぐ。"
					% int(e.get("amount", 0)))
		"gems_hoard_warn":
			_push_feed("raid", "ため込んだ宝の山が人間の目を引いている……抱えるほど狙われる。")
		"take_concubine":
			var suitor := _find_goblin(int(e.get("suitor", -1)))
			_push_feed("love", "%s が捕虜を側室に娶った。" \
					% (GobNames.of(suitor) if suitor != null else "誰か"), int(e.get("suitor", -1)))
		"pending_bond":
			_push_feed("love", "捕虜と寄り添う影がある……つがいを認めるか、引き離すか。", int(e.get("id", -1)))
		"approve_bond":
			_push_feed("love", "つがいが認められた。捕虜は今日から巣の一員だ。", int(e.get("id", -1)))
		"birth_nursery":
			_push_feed("birth", "苗床で子が %d 体、泥の中から這い出した。" % int(e.get("count", 1)))

const FEED_COLORS := {
	"raid": "e06a50", "event": "e8943a", "birth": "9adb6e",
	"death": "c08a7a", "love": "e8a0b8", "talk": "8a93c0",
}

## フィードへ 1 行流す。subject_id を渡すと行全体が [url=g:id] リンクになり、
## クリックでその個体を選択 + カメラ追従する (_on_feed_meta。死亡/不在なら無効)。
func _push_feed(kind: String, text: String, subject_id: int = -1) -> void:
	var col: String = FEED_COLORS.get(kind, "8a7d68")
	var body := text
	if subject_id >= 0:
		body = "[url=g:%d]%s[/url]" % [subject_id, text]
	_feed_lines.push_front("[color=#5a4f40][%d日][/color] [color=#%s]%s[/color]" % [world.day, col, body])
	if _feed_lines.size() > 40:
		_feed_lines.resize(40)
	if _feed != null:
		_feed.text = "\n".join(_feed_lines)

## 会話ログ (演出層のみ): 観測可能な状態からフレーバー会話をたまに 1 行流す。
## シム RNG (world.rng) は一切消費せず演出 RNG (_conv_rng) を使う (KI-09)。スロットルと
## 直近重複抑制でフィードを溢れさせない。ON のときだけ流す。
func _maybe_emit_conversation() -> void:
	if not _conversation_on:
		return
	if world.tick < _conv_next_tick:
		return
	# 次の発話までの間隔を散らす (1 日 = ticks_per_day tick に対し概ね 5〜12 回)。
	_conv_next_tick = world.tick + _conv_rng.randi_range(
			maxi(1, params.ticks_per_day / 12), maxi(2, params.ticks_per_day / 5))
	var pool: Array = []
	for g in world.goblins:
		if g.state != Goblin.State.DEAD and g.state != Goblin.State.KNOCKED_OUT:
			pool.append(g)
	if pool.is_empty():
		return
	var who: Goblin = pool[_conv_rng.randi() % pool.size()]
	var line := _conversation_line(who, GobNames.of(who))
	if line == "" or line == _conv_last_text:
		return
	_conv_last_text = line
	_push_feed("talk", line, who.id)

## 個体の観測状態に応じた会話の 1 行 (演出フレーバー)。複数候補から _conv_rng で選ぶ。
func _conversation_line(g: Goblin, who: String) -> String:
	var opts: Array = []
	if g.is_child():
		opts = ["%s が小石を転がして遊んでいる。", "%s 「おっきくなったら戦うんだ!」",
				"%s が大人の真似をして胸を張った。"]
	elif g.pregnant:
		opts = ["%s はおなかをさすって目を細めた。", "%s 「腹の子は族長より強くなる」"]
	elif g.mating_ticks >= 0:
		opts = ["%s 「…しずかにしててくれ」", "寝床から %s の満ち足りた唸りが漏れる。"]
	elif g.courting_id >= 0:
		opts = ["%s が落ち着かない様子で寝床の方を気にしている。", "%s 「来てくれるかな…」"]
	else:
		match g.state:
			Goblin.State.HUNGRY:
				opts = ["%s は腹を鳴らした。「…腹減った」", "%s がキノコの匂いを探している。",
						"%s 「飯はまだか」"]
			Goblin.State.SLEEP:
				opts = ["%s が寝言で何かつぶやいた。", "%s はいびきをかいて丸くなっている。"]
			Goblin.State.WORK:
				opts = ["%s が鼻歌まじりに手を動かす。", "%s 「働けば飯が増える…たぶん」",
						"%s がツルハシを担ぎ直した。"]
			Goblin.State.FEAR:
				opts = ["%s が物陰でガタガタ震えている。", "%s 「いやだ、死にたくない…」"]
			Goblin.State.COMBAT:
				opts = ["%s が雄叫びを上げた!", "%s 「来やがれ!」"]
			Goblin.State.ENRAGED:
				opts = ["%s の目が血走っている。", "%s が手当たり次第に殴りかかる!"]
			_:
				# WANDER ほか: 隣に誰かいれば雑談、いなければ環境フレーバー。
				var other := _nearby_chatter(g)
				if other != null:
					return "%s と %s が顔を寄せて何か話している。" % [who, GobNames.of(other)]
				opts = ["%s がぼんやり洞窟を眺めている。", "%s 「今日もトーテムは燃えてるな」",
						"%s が爪で岩肌に落書きしている。", "%s が遠くの物音に耳を澄ませた。"]
	if opts.is_empty():
		return ""
	return (opts[_conv_rng.randi() % opts.size()] as String) % who

## 近くで雑談できる相手 (チェビシェフ距離 1 の生きている別個体) を 1 体返す。なければ null。
func _nearby_chatter(g: Goblin) -> Goblin:
	for o in world.goblins:
		if o.id == g.id or o.state == Goblin.State.DEAD or o.state == Goblin.State.KNOCKED_OUT:
			continue
		if max(abs(o.x - g.x), abs(o.y - g.y)) <= 1:
			return o
	return null

func _find_goblin(id: int) -> Goblin:
	for g in world.goblins:
		if g.id == id:
			return g
	return null

## フィードのリンククリック (巣の記録 → 現場へ)。対象の個体が生きていれば選択して
## カメラ追従を開始する。死亡・巣立ち済みで補間エントリが無ければ何もしない (無効)。
func _on_feed_meta(meta: Variant) -> void:
	var s := String(meta)
	if not s.begins_with("g:"):
		return
	var id := int(s.substr(2))
	var g := _find_goblin(id)
	if g == null or g.state == Goblin.State.DEAD:
		return
	if renderer.unit_screen_pos(id) == Vector2.INF:
		return  # 演出層にもう居ない (除去済み)
	sel_kind = SelKind.GOBLIN
	sel_id = id
	_follow_id = id
	_manual_camera = true

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
	_armed_build = -1  # 建築モードとは排他
	_refresh_build_buttons()
	_refresh_miracle_buttons()

func _disarm() -> void:
	_armed = -1
	_armed_build = -1
	_refresh_miracle_buttons()
	_refresh_build_buttons()

func _armed_def() -> Dictionary:
	for def in MIRACLE_DEFS:
		if int(def.m) == _armed:
			return def
	return {}

# ════ 建築モード (§3-15) ════
func _press_build(rt: int) -> void:
	_armed = -1  # 奇跡の武装とは排他
	_armed_build = -1 if _armed_build == rt else rt
	_refresh_miracle_buttons()
	_refresh_build_buttons()

func _refresh_build_buttons() -> void:
	for bb in _build_buttons:
		var rt: int = bb.rt
		var cost: float = SimParams.ROOM_BUILD_COST[rt]
		(bb.btn as Button).text = "%s %.0f" % [ROOM_TYPE_JP[rt], cost]
		_style_button(bb.btn as Button, _armed_build == rt)
		(bb.btn as Button).disabled = (_armed_build != rt) and world.mud < cost

## カーソル位置を中心にしたゴーストの左上角タイル。
func _ghost_topleft(pos: Vector2) -> Vector2i:
	var size: Vector2i = SimParams.ROOM_BUILD_SIZE[_armed_build]
	var tp := Vector2i(int(pos.x / renderer.tile_size), int(pos.y / renderer.tile_size))
	return tp - Vector2i(size.x / 2, size.y / 2)

## 建築モードの左クリック = 2 タップ目の確定。検証はシム側 can_place_room に委ね、
## ここでは結果に応じたフィードバックだけ出す。
func _try_place_build(pos: Vector2) -> void:
	var rt := _armed_build
	var tl := _ghost_topleft(pos)
	if not world.can_place_room(rt, tl.x, tl.y):
		_push_feed("event", "そこには%sを建てられない (巣内の空いた床が要る)。" % ROOM_TYPE_JP[rt])
		return
	var cost: float = SimParams.ROOM_BUILD_COST[rt]
	if world.mud < cost:
		_push_feed("event", "建材が足りない (必要 %.0f)。岩を掘らせよう。" % cost)
		return
	controller.queue.append({
		"type": Controller.CommandType.BUILD_ROOM,
		"room_type": rt, "x": tl.x, "y": tl.y,
	})
	_disarm()  # 2 タップ確定で建築モードを抜ける

## 空振りクリックのタイル指示: 採掘ノード → 指定/解除トグル、損傷壁 → 修復発注。
func _try_tile_order(pos: Vector2) -> void:
	var tp := Vector2i(int(pos.x / renderer.tile_size), int(pos.y / renderer.tile_size))
	var t := world.map.get_tile(tp.x, tp.y)
	if t == TileMapData.TileType.RESOURCE_NODE:
		var had := false
		for j in world.jobs:
			if j.type == World.JobType.MINE and j.x == tp.x and j.y == tp.y:
				had = true
		controller.queue.append({
			"type": Controller.CommandType.DESIGNATE_MINE, "x": tp.x, "y": tp.y,
		})
		_push_feed("event", "採掘の指示を取り消した。" if had else "岩塊に採掘の印を付けた。")
	elif t == TileMapData.TileType.WALL \
			and world.map.wall_hp[world.map.idx(tp.x, tp.y)] < MapTemplate.WALL_HP:
		# 傷んだ壁 → 修復 (掘削より優先。自分の壁を掘り崩さない)。
		if world.mud < world.params.wall_repair_cost:
			_push_feed("event", "壁を直す建材がない (必要 %.0f)。" % world.params.wall_repair_cost)
			return
		controller.queue.append({
			"type": Controller.CommandType.REPAIR_WALL, "x": tp.x, "y": tp.y,
		})
		_push_feed("event", "ひび割れた壁に修復の印を付けた。")
	elif t == TileMapData.TileType.WALL and world._wall_diggable(tp):
		# 素の壁 → 掘削 (§10 巣穴拡張)。トグル。
		var had := false
		for j in world.jobs:
			if j.type == World.JobType.DIG and j.x == tp.x and j.y == tp.y:
				had = true
		controller.queue.append({
			"type": Controller.CommandType.DESIGNATE_DIG, "x": tp.x, "y": tp.y,
		})
		_push_feed("event", "掘削の指示を取り消した。" if had else "岩壁に掘削の印を付けた。")
	elif t == TileMapData.TileType.WALL:
		# 掘れない壁 (外殻・トーテム至近)。
		_push_feed("event", "この岩は固く掘り崩せない (外との境・トーテムの守り)。")

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
	var res_txt := "  建材 %.0f" % world.mud
	if world.equipment > 0.0:
		res_txt += "  装備 %.0f" % world.equipment
	if world.herb > 0.0:
		res_txt += "  薬草 %.0f" % world.herb
	if world.gems > 0.0:
		res_txt += "  宝石 %.0f" % world.gems
	var captive_txt := ""
	var captive_total := world.cap_male_goblin + world.cap_female_goblin \
		+ world.cap_male_human + world.cap_female_human
	if captive_total >= 1.0:
		captive_txt = "  捕虜%d" % int(captive_total)
	# 敵対度は最も怒っている勢力を表示する (§10: 警告色 1 勢力。詳細パネルは B7)。
	var hostilities := [
		["人間", world.human_hostility],
		["苦魚族", world.kugyo_hostility],
		["ブン・タ＝タ", world.bunta_hostility],
	]
	var angriest: Array = hostilities[0]
	for h in hostilities:
		if h[1] > angriest[1]:
			angriest = h
	if angriest[1] > 0.0:
		captive_txt += "  敵対 %s %.0f%%" % [angriest[0], float(angriest[1]) * 100.0]
	_status_label.text = "第 %d 日 %s %s · %s   頭数 %d/%d (子%d)  食料 %.0f%s  信仰 %.0f/%.0f ランク%d  surge %.1f%s%s" % [
		world.day, bar, time_txt, phase_txt,
		world._alive_count(), params.cap_pop, _child_count(),
		world.food, res_txt, world.faith, world.faith_cap(), world.rank(), world.surge, totem_txt, captive_txt,
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
	# 勝敗バナー。勝利時は到達ルート (§13 4 ルート / A3) を添える。
	if world.outcome == World.Outcome.VICTORY:
		var route_txt: String = {
			0: "ゴブリン連合は人間の総攻撃を退けた",
			1: "敵でも友でもなく — 人間との和平が成った",
			2: "宝石を差し出し、人間に飼われる道を選んだ",
		}.get(world.ending_route(), "")
		_outcome_label.text = "★ 勝利 — %s" % route_txt
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
	if g.mating_ticks >= 0:
		tags.append("[color=#e8a0b8]寝床にこもっている…[/color]")
	elif g.courting_id >= 0:
		tags.append("[color=#e8a0b8]求愛中[/color]")
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
	# 新規ゲームの難度セレクタ (§14.5.2: 易/並/難。押下でその難度の新しい群れを始める。
	# 自動開始は並のまま継続するので scene_smoke / autosave 復元を妨げない)。
	var diff_label := Label.new()
	diff_label.text = "   新規:"
	diff_label.add_theme_color_override("font_color", C_INK_FAINT)
	diff_label.add_theme_font_size_override("font_size", 12)
	top_box.add_child(diff_label)
	for cfg in [["易", 0], ["並", 1], ["難", 2]]:
		var db := Button.new()
		db.text = cfg[0]
		db.add_theme_font_size_override("font_size", 12)
		_style_button(db, false)
		var lvl: int = cfg[1]
		db.pressed.connect(func() -> void: _start_new_game(lvl))
		top_box.add_child(db)
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
	# 行クリックで対象へカメラ追従 ([url=g:id] リンク / _push_feed が付与)。
	_feed.meta_clicked.connect(_on_feed_meta)
	vbox.add_child(_feed)
	ui.add_child(right)

	# --- 勝敗バナー (中央) ---
	_outcome_label = Label.new()
	_outcome_label.set_anchors_preset(Control.PRESET_CENTER)
	_outcome_label.add_theme_font_size_override("font_size", 28)
	_outcome_label.add_theme_color_override("font_color", C_EMBER_BRIGHT)
	_outcome_label.visible = false
	ui.add_child(_outcome_label)

	# --- 左下: 速度コントロール + 奇跡 (下段) / 建築 (上段) ---
	# 2 本の HBox は高さを明示して横帯に分離する (offset_bottom 未設定だと両方とも
	# 画面下端まで伸びて矩形が重なり、後追加の建築バーが速度/奇跡のクリックを奪う)。
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bar.offset_top = -38.0
	bar.offset_bottom = -8.0
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
	# 建築バー (§3-15)。速度バーの上段 (重ならない横帯)。押下で建築モード。
	var build_bar := HBoxContainer.new()
	build_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	build_bar.offset_top = -74.0
	build_bar.offset_bottom = -42.0
	build_bar.offset_left = 8.0
	build_bar.add_theme_constant_override("separation", 4)
	var build_label := Label.new()
	build_label.text = "⚒建築:"
	build_label.add_theme_color_override("font_color", C_INK_FAINT)
	build_label.add_theme_font_size_override("font_size", 12)
	build_bar.add_child(build_label)
	for rt in BUILD_TYPES:
		var btn := Button.new()
		btn.add_theme_font_size_override("font_size", 12)
		var rt_v: int = rt
		btn.pressed.connect(func() -> void: _press_build(rt_v))
		build_bar.add_child(btn)
		_build_buttons.append({"btn": btn, "rt": rt_v})
	ui.add_child(build_bar)
	# トグルバー (建築バーのさらに上段)。会話ログの ON/OFF と捕虜パネルの表示切替。
	var toggle_bar := HBoxContainer.new()
	toggle_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	toggle_bar.offset_top = -110.0
	toggle_bar.offset_bottom = -78.0
	toggle_bar.offset_left = 8.0
	toggle_bar.add_theme_constant_override("separation", 4)
	_conversation_toggle_button = Button.new()
	_conversation_toggle_button.add_theme_font_size_override("font_size", 12)
	_conversation_toggle_button.pressed.connect(func() -> void:
		_conversation_on = not _conversation_on
		_refresh_toggle_buttons())
	toggle_bar.add_child(_conversation_toggle_button)
	_captive_toggle_button = Button.new()
	_captive_toggle_button.add_theme_font_size_override("font_size", 12)
	_captive_toggle_button.pressed.connect(func() -> void:
		_captive_pinned = not _captive_pinned
		_update_captive_ui())
	toggle_bar.add_child(_captive_toggle_button)
	ui.add_child(toggle_bar)
	_refresh_speed_buttons()
	_refresh_miracle_buttons()
	_refresh_build_buttons()
	_refresh_toggle_buttons()

	# --- 派遣パネル (§11.5。中央下。出現物クリックで開く) ---
	_dispatch_panel = PanelContainer.new()
	_dispatch_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	# 点アンカー (中央下) なので寸法はオフセットで明示する (280×128 px。
	# 種別/距離/リターン目安の表示ぶん高さを少し広げた)。
	_dispatch_panel.offset_left = -140.0
	_dispatch_panel.offset_right = 140.0
	_dispatch_panel.offset_top = -176.0
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
		_dispatch_count.text = "ゴブリン %d 体" % int(v)
		_update_dispatch_panel())
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

	# --- 捕虜パネル (§10/KI-23。捕虜がいる間だけ表示。右パネルの左隣・下端) ---
	_captive_panel = PanelContainer.new()
	_captive_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	# 派遣パネル (中央下・帯 -176..-48) と縦に重ならないよう、その上の帯へ持ち上げる。
	_captive_panel.offset_left = -640.0
	_captive_panel.offset_right = -298.0
	_captive_panel.offset_top = -220.0
	_captive_panel.offset_bottom = -140.0
	_captive_panel.add_theme_stylebox_override("panel", _panel_style())
	_captive_panel.visible = false
	var cbox := VBoxContainer.new()
	cbox.add_theme_constant_override("separation", 4)
	_captive_panel.add_child(cbox)
	_captive_info = Label.new()
	_captive_info.add_theme_color_override("font_color", C_INK)
	_captive_info.add_theme_font_size_override("font_size", 12)
	cbox.add_child(_captive_info)
	var crow1 := HBoxContainer.new()
	crow1.add_theme_constant_override("separation", 4)
	for cfg in [
		["生贄", func() -> void:
			controller.queue.append({"type": Controller.CommandType.SACRIFICE})],
		["解放♂", func() -> void:
			controller.queue.append({"type": Controller.CommandType.RELEASE_CAPTIVE,
					"sex": Goblin.Sex.MALE})],
		["解放♀", func() -> void:
			controller.queue.append({"type": Controller.CommandType.RELEASE_CAPTIVE,
					"sex": Goblin.Sex.FEMALE})],
	]:
		var cb := Button.new()
		cb.text = cfg[0]
		cb.add_theme_font_size_override("font_size", 11)
		_style_button(cb, false)
		cb.pressed.connect(cfg[1])
		crow1.add_child(cb)
	# 側室: 選択中のゴブリンに異性の捕虜を娶らせる (ゴブリン捕虜優先)。
	_concubine_button = Button.new()
	_concubine_button.text = "側室"
	_concubine_button.add_theme_font_size_override("font_size", 11)
	_style_button(_concubine_button, false)
	_concubine_button.pressed.connect(_press_concubine)
	crow1.add_child(_concubine_button)
	cbox.add_child(crow1)
	var crow2 := HBoxContainer.new()
	crow2.add_theme_constant_override("separation", 4)
	var tlabel := Label.new()
	tlabel.text = "朝貢:"
	tlabel.add_theme_color_override("font_color", C_INK_DIM)
	tlabel.add_theme_font_size_override("font_size", 11)
	crow2.add_child(tlabel)
	for cfg in [["人間", "human"], ["ブン・タ＝タ", "bunta"], ["苦魚", "kugyo"]]:
		var tb := Button.new()
		tb.text = cfg[0]
		tb.add_theme_font_size_override("font_size", 11)
		_style_button(tb, false)
		var fac: String = cfg[1]
		tb.pressed.connect(func() -> void:
			controller.queue.append({"type": Controller.CommandType.TRIBUTE, "faction": fac}))
		crow2.add_child(tb)
	cbox.add_child(crow2)
	# 宝石献上 (§14/B5。差し出せば和平の対価。非加害＝中立善を閉じない)。
	_gem_row = HBoxContainer.new()
	_gem_row.add_theme_constant_override("separation", 4)
	var glabel := Label.new()
	glabel.text = "宝石:"
	glabel.add_theme_color_override("font_color", C_INK_DIM)
	glabel.add_theme_font_size_override("font_size", 11)
	_gem_row.add_child(glabel)
	_gem_tribute_button = Button.new()
	_gem_tribute_button.add_theme_font_size_override("font_size", 11)
	_style_button(_gem_tribute_button, false)
	_gem_tribute_button.pressed.connect(func() -> void:
		controller.queue.append({"type": Controller.CommandType.TRIBUTE_GEMS,
				"amount": world.params.gems_tribute_amount}))
	_gem_row.add_child(_gem_tribute_button)
	cbox.add_child(_gem_row)
	ui.add_child(_captive_panel)

	# --- つがい承認バナー (KI-21。承認待ちが出たときだけ中央上に出す) ---
	_bond_banner = PanelContainer.new()
	_bond_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_bond_banner.offset_left = -240.0
	_bond_banner.offset_right = 240.0
	_bond_banner.offset_top = 44.0
	_bond_banner.offset_bottom = 100.0
	_bond_banner.add_theme_stylebox_override("panel", _panel_style())
	_bond_banner.visible = false
	var bbox := VBoxContainer.new()
	bbox.add_theme_constant_override("separation", 4)
	_bond_banner.add_child(bbox)
	_bond_label = Label.new()
	_bond_label.add_theme_color_override("font_color", C_INK)
	_bond_label.add_theme_font_size_override("font_size", 12)
	bbox.add_child(_bond_label)
	var brow2 := HBoxContainer.new()
	brow2.add_theme_constant_override("separation", 6)
	var approve := Button.new()
	approve.text = "つがいを認める"
	approve.add_theme_font_size_override("font_size", 12)
	_style_button(approve, true)
	approve.pressed.connect(func() -> void:
		if _bond_captive_id >= 0:
			controller.queue.append({"type": Controller.CommandType.APPROVE_BOND,
					"captive_id": _bond_captive_id}))
	brow2.add_child(approve)
	var tear := Button.new()
	tear.text = "引き離す"
	tear.add_theme_font_size_override("font_size", 12)
	_style_button(tear, false)
	tear.pressed.connect(func() -> void:
		if _bond_captive_id >= 0:
			controller.queue.append({"type": Controller.CommandType.TEAR_APART_BOND,
					"captive_id": _bond_captive_id, "cause": "torn_bond"}))
	brow2.add_child(tear)
	bbox.add_child(brow2)
	ui.add_child(_bond_banner)

	# --- 防衛配分パネル (§3-17。襲撃 (予兆/交戦) の間だけ表示。中央下・派遣より上) ---
	_defense_panel = PanelContainer.new()
	_defense_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_defense_panel.offset_left = -150.0
	_defense_panel.offset_right = 150.0
	_defense_panel.offset_top = -176.0
	_defense_panel.offset_bottom = -48.0
	_defense_panel.add_theme_stylebox_override("panel", _panel_style())
	_defense_panel.visible = false
	var defbox := VBoxContainer.new()
	defbox.add_theme_constant_override("separation", 4)
	_defense_panel.add_child(defbox)
	defbox.add_child(_section_title("防 衛 配 分"))
	# 巣口ごとに 1 本ずつスライダーを並べる (値 0..100 = 配分の生重み)。
	_defense_sliders = []
	for gi in range(world.map.gates.size()):
		var grow := HBoxContainer.new()
		grow.add_theme_constant_override("separation", 6)
		var gate_label := Label.new()
		gate_label.text = "巣口%d" % (gi + 1)
		gate_label.add_theme_color_override("font_color", C_INK_DIM)
		gate_label.add_theme_font_size_override("font_size", 12)
		gate_label.custom_minimum_size = Vector2(48, 0)
		grow.add_child(gate_label)
		var gslider := HSlider.new()
		gslider.min_value = 0
		gslider.max_value = 100
		gslider.step = 1
		gslider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		gslider.value_changed.connect(func(_v: float) -> void: _on_defense_slider_changed())
		grow.add_child(gslider)
		defbox.add_child(grow)
		_defense_sliders.append(gslider)
	_defense_auto_button = Button.new()
	_defense_auto_button.text = "自動 (敵に追従)"
	_defense_auto_button.add_theme_font_size_override("font_size", 12)
	_style_button(_defense_auto_button, true)
	_defense_auto_button.pressed.connect(func() -> void:
		controller.queue.append({"type": Controller.CommandType.DEFENSE_AUTO}))
	defbox.add_child(_defense_auto_button)
	ui.add_child(_defense_panel)

## 防衛スライダー操作: 3 本の生重みを束ねて手動配分コマンドを送る (§3-17)。
## 自動追従でスライダーを書き戻す間 (_defense_syncing) は無視する。
func _on_defense_slider_changed() -> void:
	if _defense_syncing:
		return
	var weights: Array = []
	for s in _defense_sliders:
		weights.append((s as HSlider).value)
	controller.queue.append({"type": Controller.CommandType.SET_DEFENSE_ALLOC,
			"weights": weights})

## 防衛配分パネルの毎フレーム更新 (襲撃中のみ表示。自動中はスライダーを実配分へ追従)。
func _update_defense_panel() -> void:
	var show := world.outcome == World.Outcome.ONGOING and world.phase != World.Phase.PEACE
	_defense_panel.visible = show
	if not show:
		return
	_style_button(_defense_auto_button, not world.defense_alloc_manual)
	# 自動中は実配分 (敵戦力比例) をスライダーへ反映する (操作は手動化のトリガー)。
	if not world.defense_alloc_manual:
		_defense_syncing = true
		for i in range(_defense_sliders.size()):
			if i < world.defense_alloc.size():
				(_defense_sliders[i] as HSlider).value = round(world.defense_alloc[i] * 100.0)
		_defense_syncing = false

## 側室ボタン: 選択中ゴブリンを婿/嫁に、異性の捕虜 (ゴブリン優先・なければ人間) を娶らせる。
func _press_concubine() -> void:
	var suitor := _find_goblin(sel_id) if sel_kind == SelKind.GOBLIN else null
	if suitor == null or suitor.is_child():
		_push_feed("event", "側室を娶らせるには、相手のゴブリン (成体) を選んでおく。")
		return
	var want_sex := Goblin.Sex.FEMALE if suitor.sex == Goblin.Sex.MALE else Goblin.Sex.MALE
	var goblin_stock: float = world.cap_female_goblin if want_sex == Goblin.Sex.FEMALE \
			else world.cap_male_goblin
	var human_stock: float = world.cap_female_human if want_sex == Goblin.Sex.FEMALE \
			else world.cap_male_human
	if goblin_stock < 1.0 and human_stock < 1.0:
		_push_feed("event", "娶らせられる異性の捕虜がいない。")
		return
	controller.queue.append({"type": Controller.CommandType.TAKE_CONCUBINE,
			"suitor_id": suitor.id, "captive_sex": want_sex,
			"captive_is_human": goblin_stock < 1.0})

## 捕虜パネル + つがい承認バナーの毎フレーム更新 (表示はすべて演出ローカル)。
func _update_captive_ui() -> void:
	var total := world.cap_male_goblin + world.cap_female_goblin \
			+ world.cap_male_human + world.cap_female_human
	# 捕虜が居るときだけ自動表示する (何も操作できない捕虜不在時は隠して派遣パネルと
	# 重ならないようにする)。手動トグル (_captive_pinned) を ON にすれば、捕虜不在でも
	# 宝石献上のために開ける。捕虜が居なくなったら自動で畳む (pin はそのまま手動制御)。
	_captive_panel.visible = total >= 1.0 or _captive_pinned
	if _captive_toggle_button != null:
		_captive_toggle_button.text = "捕虜▲" if _captive_panel.visible else "捕虜▼"
	if _captive_panel.visible:
		_captive_info.text = "捕虜 — ゴブリン 雄%d 雌%d / 人間 雄%d 雌%d" % [
			int(world.cap_male_goblin), int(world.cap_female_goblin),
			int(world.cap_male_human), int(world.cap_female_human)]
		_concubine_button.disabled = sel_kind != SelKind.GOBLIN
		_gem_row.visible = world.gems >= 1.0
		_gem_tribute_button.text = "宝石 %d を人間へ献上" % int(world.params.gems_tribute_amount)
		_gem_tribute_button.disabled = world.gems < world.params.gems_tribute_amount
	# 承認待ちの先頭 1 件をバナーに出す (複数いても順に処理される)。
	var pending: Goblin = null
	for g in world.goblins:
		if g.pending_bond and g.state != Goblin.State.DEAD:
			pending = g
			break
	if pending == null:
		_bond_banner.visible = false
		_bond_captive_id = -1
		return
	_bond_captive_id = pending.id
	var mate := _find_goblin(pending.mate_id)
	_bond_label.text = "%s が捕虜の %s とつがいになりたがっている。" % [
		GobNames.of(mate) if mate != null else "誰か", GobNames.of(pending)]
	_bond_banner.visible = true

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
	_update_dispatch_panel()

## CAMP の手応えヒント (§11.5)。隊の実効戦力 (人数 + 装備ボーナス見込み) と
## field_camp_strength を比べたおおまかな所感を返す。実際の勝率計算
## (_resolve_camp の effective/(effective+strength)) の近似であり、装備の
## 在庫状況までは見ない (出発時に揃わない場合もあるため目安にとどめる)。
func _camp_difficulty_hint(headcount: int) -> String:
	if headcount <= 0:
		return ""
	var effective: float = float(headcount) * (1.0 + world.params.equip_bonus * 0.5)
	var strength: float = world.params.field_camp_strength
	var ratio := effective / (effective + strength)
	if ratio >= 0.6:
		return " (手応え: 楽勝そう)"
	elif ratio >= 0.35:
		return " (手応え: 五分五分)"
	else:
		return " (手応え: 厳しそう)"

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
## 残量・手すき表示を追従させる (スライダー値はいじらない)。種別名・距離・
## リターン目安 (CAMP は手応えヒント付き) を併記する (§11.5)。
func _update_dispatch_panel() -> void:
	if _dispatch_panel == null or not _dispatch_panel.visible:
		return
	var f := world._field_by_id(_dispatch_field_id)
	if f == null:
		_close_dispatch_panel()
		return
	var kind_name: String = FIELD_KIND_JP.get(f.kind, "出現物")
	var dist_name: String = FIELD_DISTANCE_JP.get(f.distance, "近い")
	var return_hint: String = FIELD_RETURN_JP.get(f.kind, "食料")
	var lines: Array = []
	lines.append("%s ・ %s ・ のこり %d" % [kind_name, dist_name, f.amount])
	var hint_extra: String = ""
	if f.kind == FieldResource.Kind.CAMP:
		hint_extra = _camp_difficulty_hint(int(_dispatch_slider.value))
	lines.append("リターン: %s%s" % [return_hint, hint_extra])
	if _dispatch_button.disabled:
		lines.append("手すきのゴブリンがいない")
	_dispatch_info.text = "\n".join(lines)

func _refresh_speed_buttons() -> void:
	for d in _speed_buttons:
		_style_button(d.btn as Button, absf(float(d.speed) - speed) < 0.01)

## トグルボタン (会話ログ ON/OFF・捕虜パネル) のラベルと強調を表示状態に合わせる。
func _refresh_toggle_buttons() -> void:
	if _conversation_toggle_button != null:
		_conversation_toggle_button.text = "会話ログ ON" if _conversation_on else "会話ログ OFF"
		_style_button(_conversation_toggle_button, _conversation_on)
	# 捕虜トグルのラベル (▲表示中/▼畳む) は _update_captive_ui が表示状態に追従させる。
	if _captive_toggle_button != null and _captive_toggle_button.text == "":
		_captive_toggle_button.text = "捕虜▼"

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
