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
# 出現物の「見つかった」一言は data/messages.json の events.field_spawn_<種別> に移動した。
# kind enum → JSON キー接尾辞の対応表 (field_spawn / field_haul で参照)。
const FIELD_KEY := {
	FieldResource.Kind.FORAGE: "forage", FieldResource.Kind.ANIMAL: "animal",
	FieldResource.Kind.TRAVELER: "traveler", FieldResource.Kind.WANDERER: "wanderer",
	FieldResource.Kind.CAMP: "camp", FieldResource.Kind.RUINS: "ruins",
	FieldResource.Kind.MAIDEN: "maiden",
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
# 苗床の累計出産 (母体種族別。演出ローカル・どの苗床母体が何を産んだか可視化する)。
var _nursery_born_goblin: int = 0
var _nursery_born_human: int = 0
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

# 役職任命パネル (操作の深み)。ゴブリン選択中だけ表示し、APPOINT_ROLE コマンドで
# シャーマン/族長/まじない医を任命・解任する (枠超過/性別年齢不適は UI 側で抑止)。
# 表示状態・ボタン参照は演出ローカル (シム・セーブに含めない / KI-09)。
var _role_panel: PanelContainer
var _role_info: Label
var _role_buttons: Array = []  # Array[Dictionary] {btn, role}
var _role_unassign_button: Button

# 文脈駆動チュートリアル (オンボーディング・演出ローカル / KI-09)。平和な序盤に
# 操作のヒントを 1 つずつ出す。autosave に載せない (復元後は既見扱いでスキップ)。
var _tutorial_banner: PanelContainer
var _tutorial_label: Label
var _tutorial_seen: Array = []   # 表示済みヒントキー (Array[String])
var _tutorial_hide_tick: int = -1  # このフレーム以降でバナーを自動的に畳む tick
var _night_was_day: bool = true  # 直前フレームが昼だったか (夜入りの 1 回検出用)

# 会話ログ (演出ローカル)。ON のときだけフレーバー会話を「巣の記録」に流す。既定 OFF で
# ログが流れ続けるのを防ぐ。生成は演出専用 RNG (シム RNG を消費しない / KI-09)。
var _conversation_on: bool = false
var _conversation_toggle_button: Button
# R-18 地の文 (演出ローカル・既定 OFF)。ON のとき交尾の描写を露骨にする (data/adult.json /
# TextDB.compose)。差し込みは成体のつがい (mating) のみ・子供は対象外。シム RNG 非依存 (KI-09)。
var _explicit_on: bool = false
var _explicit_toggle_button: Button
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
# 勝敗パネル (中央)。決着時に大見出し + 到達ルート + 統計 + 再挑戦ボタンを出す。
var _outcome_panel: PanelContainer
var _outcome_title: Label
var _outcome_route: Label
var _outcome_stats: Label
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
	# 役職任命はプレイヤーに委ねる (ハイブリッド操作版)。牧場補充・派遣・見張りの
	# 自動維持は AutoController/world が引き続き面倒を見る (controller.gd / KI 整合)。
	(controller as AutoController).manual_roles = true

	renderer = $Renderer
	renderer.tile_size = 16

	var restored := _load_autosave()

	_build_ui()
	_update_camera()
	get_viewport().size_changed.connect(_update_camera)
	if restored:
		_push_feed("event", TextDB.msg("restore", {"day": world.day}))
	else:
		_push_feed("event", TextDB.msg("new_game", {"count": params.start_goblins}))

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
	_outcome_panel.visible = false
	_tutorial_seen.clear()
	_tutorial_banner.visible = false
	_night_was_day = true
	_feed.clear()
	_feed_lines.clear()
	var diff_jp: String = ["易", "並", "難"][clampi(diff, 0, 2)]
	_push_feed("event", TextDB.msg("new_game_difficulty", {"difficulty": diff_jp, "count": params.start_goblins}))
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
	_update_role_panel()
	_update_tutorial()
	_update_ambience()
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

# ════ イベント → 物語の文 (文面は data/messages.json で編集) ════
func _push_feed_event(e: Dictionary) -> void:
	var t: String = e.get("t", "")
	match t:
		"raid":
			var who := TextDB.label("raid_who", String(e.get("faction", "")), "敵対氏族の群れ")
			var key := "raid_final" if e.get("final", false) else "raid"
			_push_feed("raid", TextDB.msg(key, {"who": who, "count": e.get("count", 0)}))
		"raid_small":
			_push_feed("event", TextDB.msg("raid_small", {"count": e.get("count", 0)}))
		"raid_end":
			_push_feed("raid", TextDB.msg("raid_end", {"alive": e.get("alive", 0)}))
		"surge":
			var pct := "%.0f" % (float(e.get("lost_frac", 0.0)) * 100.0)
			_push_feed("event", TextDB.msg("surge", {"pct": pct}))
		"death":
			var nm := GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))
			var dkey := "death_accident" if e.get("cause", "") == "accident" else "death_combat"
			_push_feed("death", TextDB.msg(dkey, {"name": nm}))
		"fledge":
			_push_feed("event", TextDB.msg("fledge", {"name": GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))}))
		"birth":
			var mother := _find_goblin(int(e.get("mother", -1)))
			var mname: String = GobNames.of(mother) if mother != null else "母ゴブリン"
			_push_feed("birth", TextDB.msg("birth", {"name": mname, "count": e.get("count", 0)}), int(e.get("mother", -1)))
		"grow":
			_push_feed("birth", TextDB.msg("grow", {"name": GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))}), int(e.get("id", -1)))
		"mite_eaten":
			_push_feed("event", TextDB.msg("mite_eaten", {"name": GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))}), int(e.get("id", -1)))
		"fumble":
			var fnm := GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))
			var fkey := "fumble_dropped" if e.get("dropped", false) else "fumble"
			_push_feed("event", TextDB.msg(fkey, {"name": fnm}), int(e.get("id", -1)))
		"forage":
			_forage_feed_count += 1
			if _forage_feed_count % 4 == 0:
				_push_feed("event", TextDB.msg("forage", {"name": GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))}), int(e.get("id", -1)))
		"guard":
			_push_feed("event", TextDB.msg("guard", {"name": GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))}), int(e.get("id", -1)))
		"alarm":
			_push_feed("raid", TextDB.msg("alarm", {"name": GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))}), int(e.get("id", -1)))
		"quarrel":
			var ga := _find_goblin(int(e.get("a", -1)))
			var gb := _find_goblin(int(e.get("b", -1)))
			var na: String = GobNames.of(ga) if ga != null else "ゴブリン"
			var nb: String = GobNames.of(gb) if gb != null else "ゴブリン"
			_push_feed("event", TextDB.msg("quarrel", {"name": na, "other": nb}), int(e.get("a", -1)))
		"court":
			var cf := _find_goblin(int(e.get("f", -1)))
			var cm := _find_goblin(int(e.get("m", -1)))
			var cfn: String = GobNames.of(cf) if cf != null else "雌ゴブリン"
			var cmn: String = GobNames.of(cm) if cm != null else "雄ゴブリン"
			_push_feed("love", TextDB.msg_pick("court", _conv_rng, {"name": cfn, "other": cmn}), int(e.get("f", -1)))
		"mating":
			var mf := _find_goblin(int(e.get("f", -1)))
			var mm := _find_goblin(int(e.get("m", -1)))
			var mfn: String = GobNames.of(mf) if mf != null else "雌ゴブリン"
			var mmn: String = GobNames.of(mm) if mm != null else "雄ゴブリン"
			# R-18 ON ならつがい成立の瞬間を露骨な地の文に ({name}=雌・{other}=雄で雄を能動側に。
			# {fpre}/{mpre} に種族接頭辞を渡し異種を示す)。OFF/データ不在は通常文面 (variant) へ。
			var mtext := TextDB.compose("mating_explicit_pair", _conv_rng, {
					"name": mfn, "other": mmn,
					"fpre": _species_prefix(mf), "mpre": _species_prefix(mm)}) if _explicit_on else ""
			if mtext == "":
				mtext = TextDB.msg_pick("mating", _conv_rng, {"name": mfn, "other": mmn})
			_push_feed("love", mtext, int(e.get("f", -1)))
		"pregnant":
			var f := _find_goblin(int(e.get("id", -1)))
			if f != null:
				_push_feed("love", TextDB.msg_pick("pregnant", _conv_rng, {"name": GobNames.of(f)}), f.id)
		"court_timeout":
			# 求愛の待ちぼうけ (誘った雌が起点)。{name}=雌・{other}=雄で性別整合の文面。
			var tf := _find_goblin(int(e.get("f", -1)))
			var tm := _find_goblin(int(e.get("m", -1)))
			var tfn: String = GobNames.of(tf) if tf != null else "雌ゴブリン"
			var tmn: String = GobNames.of(tm) if tm != null else "雄ゴブリン"
			_push_feed("event", TextDB.msg_pick("court_timeout", _conv_rng, {"name": tfn, "other": tmn}), int(e.get("f", -1)))
		"field_spawn":
			var sp_kind: int = int(e.get("kind", FieldResource.Kind.FORAGE))
			_push_feed("event", TextDB.msg("field_spawn_" + String(FIELD_KEY.get(sp_kind, "forage")), {"amount": e.get("amount", 0)}))
		"dispatch":
			_push_feed("event", TextDB.msg("dispatch", {"count": e.get("count", 0)}))
		"field_haul":
			var fh_kind: int = int(e.get("kind", FieldResource.Kind.FORAGE))
			var fh_who := GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))
			var hkey := "field_haul"
			if fh_kind == FieldResource.Kind.ANIMAL:
				hkey = "field_haul_animal"
			elif fh_kind == FieldResource.Kind.RUINS:
				hkey = "field_haul_ruins"
			_push_feed("event", TextDB.msg(hkey, {"name": fh_who}), int(e.get("id", -1)))
		"field_captive":
			_push_feed("event", TextDB.msg("field_captive", {"name": GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))}), int(e.get("id", -1)))
		"field_gem":
			var fg := _find_goblin(int(e.get("id", -1)))
			var fg_who: String = GobNames.of(fg) if fg != null else "誰か"
			_push_feed("birth", TextDB.msg("field_gem", {"name": fg_who}), int(e.get("id", -1)))
		"field_trade":
			var ft := _find_goblin(int(e.get("id", -1)))
			var ft_who: String = GobNames.of(ft) if ft != null else "誰か"
			var tkey := "field_trade_gems" if e.get("good", "") == "gems" else "field_trade"
			_push_feed("event", TextDB.msg(tkey, {"name": ft_who}), int(e.get("id", -1)))
		"field_faux_pas":
			var fp := _find_goblin(int(e.get("id", -1)))
			var fp_who: String = GobNames.of(fp) if fp != null else "誰か"
			_push_feed("raid", TextDB.msg("field_faux_pas", {"name": fp_who}), int(e.get("id", -1)))
		"wanderer_joined":
			_push_feed("birth", TextDB.msg("wanderer_joined", {"name": GobNames.name_of(int(e.get("id", -1)), int(e.get("sex", 0)))}), int(e.get("id", -1)))
		"wanderer_left":
			_push_feed("event", TextDB.msg("wanderer_left"))
		"field_maiden":
			if e.get("amina", false):
				_push_feed("love", TextDB.msg("field_maiden_amina"))
			else:
				_push_feed("event", TextDB.msg("field_maiden"))
		"field_camp_win":
			var captive_txt := TextDB.label("camp_captive", "yes" if e.get("captive", false) else "no")
			_push_feed("birth", TextDB.msg("field_camp_win", {"captive": captive_txt}))
		"field_camp_loss":
			var cl_id: int = int(e.get("id", -1))
			var cl_g := _find_goblin(cl_id)
			if cl_g != null:
				_push_feed("raid", TextDB.msg("field_camp_loss", {"name": GobNames.of(cl_g)}), cl_id)
			else:
				_push_feed("raid", TextDB.msg("field_camp_loss_none"))
		"field_recall":
			_push_feed("raid", TextDB.msg("field_recall", {"count": e.get("count", 0)}))
		"amina_foreshadow":
			_push_feed("love", TextDB.msg("amina_foreshadow"))
		"amina_closed":
			_push_feed("event", TextDB.msg("amina_closed"))
		"amina_joined":
			var am := _find_goblin(int(e.get("id", -1)))
			var am_name: String = GobNames.of(am) if am != null else "少女"
			_push_feed("love", TextDB.msg("amina_joined", {"name": am_name}), int(e.get("id", -1)))
		"mine_done":
			var miner := _find_goblin(int(e.id))
			var miner_name: String = GobNames.of(miner) if miner != null else "誰か"
			if e.get("gem", false):
				_push_feed("birth", TextDB.msg("mine_done_gem", {"name": miner_name}), int(e.id))
			else:
				_push_feed("event", TextDB.msg("mine_done", {"name": miner_name}), int(e.id))
		"dig_done":
			var digger := _find_goblin(int(e.id))
			_push_feed("event", TextDB.msg("dig_done", {"name": GobNames.of(digger) if digger != null else "誰か"}), int(e.id))
		"build_start":
			_push_feed("event", TextDB.msg("build_start", {"room": ROOM_TYPE_JP.get(int(e.room_type), "部屋")}))
		"build_done":
			_push_feed("birth", TextDB.msg("build_done", {"room": ROOM_TYPE_JP.get(int(e.room_type), "部屋")}), int(e.id))
		"repair_done":
			var fixer := _find_goblin(int(e.id))
			_push_feed("event", TextDB.msg("repair_done", {"name": GobNames.of(fixer) if fixer != null else "誰か"}), int(e.id))
		"breach_warn":
			_push_feed("raid", TextDB.msg("breach_warn"))
		"breach":
			_push_feed("raid", TextDB.msg("breach"))
		"field_done":
			_push_feed("event", TextDB.msg("field_done"))
		"field_expire":
			_push_feed("event", TextDB.msg("field_expire"))
		"victory":
			_push_feed("event", TextDB.msg("victory"))
		"defeat":
			var dfkey := "defeat_totem" if e.get("reason", "") == "totem" else "defeat"
			_push_feed("raid", TextDB.msg(dfkey))
		"captive_gain":
			var cg_who := TextDB.label("captive_who", "human" if e.get("human", false) else "goblin")
			_push_feed("event", TextDB.msg_pick("captive_gain", _conv_rng, {"who": cg_who}))
		"captive_joined":
			_push_feed("event", TextDB.msg_pick("captive_joined", _conv_rng, {"name": GobNames.name_of(int(e.get("id", -1)), Goblin.Sex.MALE)}), int(e.get("id", -1)))
		"sacrifice":
			var kind_txt := TextDB.label("sacrifice_kind", String(e.get("kind", "")), "捕虜")
			_push_feed("event", TextDB.msg_pick("sacrifice", _conv_rng, {"kind": kind_txt}))
		"release_captive":
			var sex_txt := TextDB.label("sex", "male" if int(e.get("sex", 0)) == Goblin.Sex.MALE else "female")
			_push_feed("event", TextDB.msg_pick("release_captive", _conv_rng, {"sex": sex_txt}))
		"tribute":
			var fac_txt := TextDB.label("tribute_faction", String(e.get("faction", "")), "敵対勢力")
			_push_feed("event", TextDB.msg_pick("tribute", _conv_rng, {"faction": fac_txt}))
		"tribute_gems":
			_push_feed("event", TextDB.msg("tribute_gems", {"amount": int(e.get("amount", 0))}))
		"gems_hoard_warn":
			_push_feed("raid", TextDB.msg("gems_hoard_warn"))
		"take_concubine":
			var suitor := _find_goblin(int(e.get("suitor", -1)))
			_push_feed("love", TextDB.msg_pick("take_concubine", _conv_rng, {"name": GobNames.of(suitor) if suitor != null else "誰か"}), int(e.get("suitor", -1)))
		"pending_bond":
			_push_feed("love", TextDB.msg_pick("pending_bond", _conv_rng), int(e.get("id", -1)))
		"approve_bond":
			_push_feed("love", TextDB.msg_pick("approve_bond", _conv_rng), int(e.get("id", -1)))
		"birth_nursery":
			# 母体の種族を明示する (どの苗床母体が産んだか分かるように) + 累計を記録。
			var bn_human: bool = e.get("human", false)
			var bn_count := int(e.get("count", 1))
			if bn_human:
				_nursery_born_human += bn_count
			else:
				_nursery_born_goblin += bn_count
			var bn_key := "birth_nursery_human" if bn_human else "birth_nursery_goblin"
			_push_feed("birth", TextDB.msg_pick(bn_key, _conv_rng, {"count": bn_count}))

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
	# 次の発話までの間隔を散らす。ゴブリンが常にわちゃわちゃ喋っている感を出すため
	# 高頻度 (1 日 = ticks_per_day tick に対し概ね 50〜150 回 ≒ 数 tick おき)。
	@warning_ignore("integer_division")
	_conv_next_tick = world.tick + _conv_rng.randi_range(
			maxi(1, params.ticks_per_day / 150), maxi(2, params.ticks_per_day / 50))
	var pool: Array = []
	for g in world.goblins:
		if g.state != Goblin.State.DEAD and g.state != Goblin.State.KNOCKED_OUT:
			pool.append(g)
	if pool.is_empty():
		return
	# 苗床が稼働中ならたまに苗床アンビエンス (情景 + 母体/見物の台詞) を差し込む。
	if _nursery_active() and _conv_rng.randf() < 0.18:
		var nline := _nursery_line(pool)
		if nline != "" and nline != _conv_last_text:
			_conv_last_text = nline
			_push_feed("love", nline)
		return
	var who: Goblin = pool[_conv_rng.randi() % pool.size()]
	var line := _conversation_line(who, GobNames.of(who))
	if line == "" or line == _conv_last_text:
		return
	_conv_last_text = line
	_push_feed("talk", line, who.id)

## 苗床が稼働中か (NURSERY 部屋 + 雌捕虜の母体が居る)。演出判定のみ・RNG 非消費。
func _nursery_active() -> bool:
	var hosts: float = world.cap_female_goblin
	if world.params.human_nursery_allowed:
		hosts += world.cap_female_human
	if hosts < 1.0:
		return false
	for r in world.map.rooms:
		if r.room_type == TileMapData.RoomType.NURSERY:
			return true
	return false

## 苗床アンビエンスを 1 行返す。母体の種族 (ゴブリン/人間) で文面を分ける — 人間母体が居れば
## 人間版 (nursery_human / R-18 nursery_explicit_human)、両方居れば確率で振る。R-18 ON のときは
## 露骨な地の文を合成、それ以外は台詞表から引く ({name} は見物役の生きた成体 1 体。地の文・母体
## 台詞は {name} を使わない)。演出 RNG のみ消費 (KI-09)。
func _nursery_line(pool: Array) -> String:
	var human_host: bool = world.params.human_nursery_allowed and world.cap_female_human >= 1.0
	var goblin_host: bool = world.cap_female_goblin >= 1.0
	# 人間母体が居て、ゴブリン母体が居ない or コイン表なら人間版を出す。
	var use_human := human_host and (not goblin_host or _conv_rng.randf() < 0.5)
	if _explicit_on:
		var ex := TextDB.compose("nursery_explicit_human" if use_human else "nursery_explicit", _conv_rng, {})
		if ex != "":
			return ex
	var who := ""
	if not pool.is_empty():
		who = GobNames.of(pool[_conv_rng.randi() % pool.size()])
	var cat := "nursery_human" if use_human else "nursery"
	if TextDB.chatter_lines(cat).is_empty():
		cat = "nursery"
	# {n}=群がる雄の人数フレーズ (同時輪姦の人数バリエーション。演出 RNG のみ)。
	return TextDB.pick_chatter(cat, _conv_rng, {"name": who, "n": _count_phrase()})

# 同時に群がる雄の人数フレーズ (演出ローカル・苗床の輪姦描写に差し込む)。
const _COUNT_PHRASE := ["二匹の", "三匹の", "四匹の", "五匹の", "六匹の", "何匹もの", "群れじゅうの"]

func _count_phrase() -> String:
	return _COUNT_PHRASE[_conv_rng.randi() % _COUNT_PHRASE.size()]

## 個体の観測状態から会話カテゴリを決め、セリフ表 (data/dialogue.json) から 1 行引く。
## セリフ本体は JSON を編集するだけで増減できる。候補は演出 RNG (_conv_rng) で選び、
## シム RNG (world.rng) は一切消費しない (KI-09)。
func _conversation_line(g: Goblin, who: String) -> String:
	# 一過性の重要状態を上位優先で判定する。寝床・交尾・捕虜系は性別・種族で台詞を分け、
	# 発言者の性別と矛盾しないようにする。身体特性 {cock}/{bust} は全行で差し込める。
	var f := _chat_fields(g, who)  # {name}/{cock}(雄)/{bust}(雌)。id 由来で個体ごと一貫。
	if g.is_child():
		return TextDB.pick_chatter("child", _conv_rng, f)
	if g.pregnant:
		# 妊娠は雌のみ。母体と種主 (mate_id=父) の種族で台詞を分ける (異種=半人半ゴブリン)。
		return _pick_pair_chatter("pregnant", g, _find_goblin(g.mate_id), who)
	if g.mating_ticks >= 0:
		# 交尾の相手は courting_id が指す (寝床へ留めるため完了/中断まで保持される)。
		var partner := _find_goblin(g.courting_id)
		# R-18 ON は性別・種族別の露骨な地の文を合成する (雄=能動 / 雌=受け、相手呼称 {mate})。
		# 成体のつがいのみ・子供は上で除外済み。
		if _explicit_on:
			var ex := _mating_explicit(g, partner, who)
			if ex != "":
				return ex
		# 段階: 雌の mating_ticks/所要 で進行度を測り、終盤 (>=0.7) は中出し/孕ませの climax 台詞へ。
		# 雄側は mating_ticks が 0 のままなので、つがいの雌 (自分 or 相手) の値で判定する。
		var fem := g if g.sex == Goblin.Sex.FEMALE else partner
		var prog := 0.0
		if fem != null and world.params.mating_duration_ticks > 0:
			prog = float(fem.mating_ticks) / float(world.params.mating_duration_ticks)
		var base := "mating_climax" if prog >= 0.7 else "mating"
		return _pick_pair_chatter(base, g, partner, who)
	if g.courting_id >= 0:
		return _pick_pair_chatter("courting", g, _find_goblin(g.courting_id), who)
	if g.pending_bond:
		return _pick_gendered_species("pending_bond", g, who)  # つがい承認待ち (種族で口調を分ける)
	match g.state:
		Goblin.State.HUNGRY:
			return _pick_shared("hungry", g, who)
		Goblin.State.SLEEP:
			return _pick_shared("sleep", g, who)
		Goblin.State.WORK:
			return _pick_shared("work", g, who)
		Goblin.State.FEAR:
			return _pick_shared("fear", g, who)
		Goblin.State.COMBAT:
			return _pick_shared("combat", g, who)
		Goblin.State.ENRAGED:
			return _pick_shared("enraged", g, who)
		_:
			# WANDER ほか: 側室は捕虜暮らしの台詞、隣に誰かいれば 2 体の雑談、いなければ環境フレーバー。
			if g.role == Goblin.Role.CONCUBINE:
				return _pick_gendered_species("concubine", g, who)  # 種族で口調を分ける
			# 人間 (アミナ/承認済み捕虜) は群れの雑談に混ざらず、普通の口調で独り言 (wander_h)。
			if g.species == Goblin.Species.HUMAN:
				return _pick_shared("wander", g, who)
			var other := _nearby_chatter(g)
			if other != null:
				var pf := _chat_fields(g, who)
				pf["other"] = GobNames.of(other)
				return TextDB.pick_chatter("chatter_pair", _conv_rng, pf)
			return _pick_shared("wander", g, who)

## 状態別カテゴリを話者種族で引く。ゴブリンはバカ口調 (<cat>)、人間は普通口調 (<cat>_h があれば
## それ・無ければ <cat> へフォールバック)。アミナ/承認済み人間捕虜がバカ化しないための分岐。
func _pick_shared(cat: String, g: Goblin, who: String) -> String:
	if g.species == Goblin.Species.HUMAN and not TextDB.chatter_lines(cat + "_h").is_empty():
		return TextDB.pick_chatter(cat + "_h", _conv_rng, _chat_fields(g, who))
	return TextDB.pick_chatter(cat, _conv_rng, _chat_fields(g, who))

# 身体特性の描写語 (id 由来・小柄＋不釣り合いな巨根の王道。控えめ→凶悪へ。雌の胸は貧→巨)。
const _COCK_GOBLIN := ["ずんぐりした太茎", "逞しい一物", "凶悪な巨根", "馬のような剛直"]
const _COCK_HUMAN := ["雄々しい肉茎", "長大な逸物", "猛々しい剛直"]
const _BUST_DESC := ["慎ましい乳", "豊かな乳房", "たわわな巨乳"]

## 雄の竿の描写語 (id 由来で決定的・種族別)。雄でなければ ""。
func _cock_desc(g: Goblin) -> String:
	if g == null or g.sex != Goblin.Sex.MALE:
		return ""
	var e := Goblin.endowment(g.id)
	if g.species == Goblin.Species.HUMAN:
		return _COCK_HUMAN[mini(int(e * _COCK_HUMAN.size()), _COCK_HUMAN.size() - 1)]
	return _COCK_GOBLIN[mini(int(e * _COCK_GOBLIN.size()), _COCK_GOBLIN.size() - 1)]

## 雌の胸の描写語 (id 由来で決定的)。雌でなければ ""。
func _bust_desc(g: Goblin) -> String:
	if g == null or g.sex != Goblin.Sex.FEMALE:
		return ""
	var b := Goblin.bust(g.id)
	return _BUST_DESC[mini(int(b * _BUST_DESC.size()), _BUST_DESC.size() - 1)]

## chatter の差し込みフィールド: 話者名 {name} + 話者の身体特性 (雄={cock} / 雌={bust})。
## id 由来で決定的 (Goblin.endowment/bust)。該当しない性別では "" (台詞側が使わない)。
func _chat_fields(g: Goblin, who: String) -> Dictionary:
	return {"name": who, "cock": _cock_desc(g), "bust": _bust_desc(g)}

# 相手(雄)の竿サイズ(0..1)に応じた、受け手の反応フレーズ (サイズに合わせた反応)。控えめ→凶悪。
const _COCK_REACT := ["ちょうどよくて", "ぐいぐい きて", "おくまで とどいて", "おおきすぎて"]

## 相手(雄)の竿サイズに応じた、受け手の反応フレーズ。雄でなければ ""。
func _cock_react(partner: Goblin) -> String:
	if partner == null or partner.sex != Goblin.Sex.MALE:
		return ""
	var e := Goblin.endowment(partner.id)
	return _COCK_REACT[mini(int(e * _COCK_REACT.size()), _COCK_REACT.size() - 1)]

## mating/courting の差し込みに相手の身体を足す: 相手の竿 {mate_cock}・胸 {mate_bust}・
## 竿サイズに応じた反応 {cock_react} (ペニス/バストサイズに合わせた反応・描写に使う)。
func _pair_fields(g: Goblin, partner: Goblin, who: String) -> Dictionary:
	var d := _chat_fields(g, who)
	d["mate_cock"] = _cock_desc(partner)
	d["mate_bust"] = _bust_desc(partner)
	d["cock_react"] = _cock_react(partner)
	return d

## 話者の種族 + 性別でカテゴリを選ぶ (ゴブリン=<base>_g<sex> / 人間=<base>_h<sex>)。無ければ
## <base>_<sex> → <base> へフォールバック。ゴブリンはバカっぽく、人間は普通に喋る分離に使う
## (捕虜つがい系。ゴブリン捕虜=dumb / 人間捕虜=articulate)。演出 RNG のみ消費 (KI-09)。
func _pick_gendered_species(base: String, g: Goblin, who: String) -> String:
	var s := _species_tag(g)
	var x := "m" if g.sex == Goblin.Sex.MALE else "f"
	for key in [base + "_" + s + x, base + "_" + x, base]:
		if not TextDB.chatter_lines(key).is_empty():
			return TextDB.pick_chatter(key, _conv_rng, _chat_fields(g, who))
	return TextDB.pick_chatter(base, _conv_rng, _chat_fields(g, who))

## 性別サフィックス (_m=雄 / _f=雌) 付きカテゴリを優先し、無ければ基底へフォールバックする。
## 発言者の性別と台詞が矛盾しないようにするための共通ヘルパ (演出 RNG のみ消費 / KI-09)。
func _pick_gendered(base: String, g: Goblin, who: String) -> String:
	var suffix := "_f" if g.sex == Goblin.Sex.FEMALE else "_m"
	if not TextDB.chatter_lines(base + suffix).is_empty():
		return TextDB.pick_chatter(base + suffix, _conv_rng, _chat_fields(g, who))
	return TextDB.pick_chatter(base, _conv_rng, _chat_fields(g, who))

## 種族タグ ("g"=ゴブリン / "h"=人間)。null は "g" 扱い (相手不在時の安全側)。
func _species_tag(g: Goblin) -> String:
	return "h" if (g != null and g.species == Goblin.Species.HUMAN) else "g"

## 種族 + 性別 + 相手種族でカテゴリを選び、最も具体的なものから順にフォールバックする。
## 例: 雄ゴブリン×人間雌 → mating_gm_h → (無ければ) mating_m → mating。人間話者は必ず
## 人間カテゴリ (mating_hm_g 等) を用意してあるのでゴブリン声へは落ちない。{name} のみ渡す。
## 発言者の性別・種族と台詞が矛盾しないようにするための共通ヘルパ (演出 RNG のみ / KI-09)。
func _pick_pair_chatter(base: String, g: Goblin, partner: Goblin, who: String) -> String:
	var s := _species_tag(g)
	var x := "m" if g.sex == Goblin.Sex.MALE else "f"
	var p := _species_tag(partner)
	var fields := _pair_fields(g, partner, who)  # 自分+相手の身体・サイズ反応を差し込む
	for key in ["%s_%s%s_%s" % [base, s, x, p], "%s_%s%s" % [base, s, x], "%s_%s" % [base, x], base]:
		if not TextDB.chatter_lines(key).is_empty():
			return TextDB.pick_chatter(key, _conv_rng, fields)
	return TextDB.pick_chatter(base, _conv_rng, fields)

## R-18 交尾の地の文を、話者の性別・種族で文法を選び、相手の呼称 {mate} を差し込んで合成する。
## ゴブリン話者は mating_explicit_m/f、人間話者は mating_explicit_hm/hf。失敗時は "" (通常文面へ)。
func _mating_explicit(g: Goblin, partner: Goblin, who: String) -> String:
	var key: String
	if g.species == Goblin.Species.HUMAN:
		key = "mating_explicit_hf" if g.sex == Goblin.Sex.FEMALE else "mating_explicit_hm"
	else:
		key = "mating_explicit_f" if g.sex == Goblin.Sex.FEMALE else "mating_explicit_m"
	# {cock}/{bust}=話者自身の身体、{mate_cock}/{mate_bust}=相手の竿/胸、{cock_react}=相手の
	# 竿サイズに応じた反応、{mate}=相手の呼称。いずれも id 由来で決定的 (同じ個体は常に同じ描写)。
	return TextDB.compose(key, _conv_rng, {
		"name": who, "mate": _mate_descriptor(partner),
		"cock": _cock_desc(g), "bust": _bust_desc(g),
		"mate_cock": _cock_desc(partner), "mate_bust": _bust_desc(partner),
		"cock_react": _cock_react(partner)})

## R-18 地の文用の相手呼称 (性別 × 種族)。相手不在なら汎用語。
func _mate_descriptor(partner: Goblin) -> String:
	if partner == null:
		return "相手"
	var male := partner.sex == Goblin.Sex.MALE
	if partner.species == Goblin.Species.HUMAN:
		return "人間の男" if male else "人間の女"
	return "雄" if male else "雌"

## つがい両者 (pair) 用の種族接頭辞 ("" か "人間の ")。R-18 のフィード文面で種族を示す。
func _species_prefix(g: Goblin) -> String:
	return "人間の " if (g != null and g.species == Goblin.Species.HUMAN) else ""

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
	@warning_ignore("integer_division")
	var topleft := tp - Vector2i(size.x / 2, size.y / 2)
	return topleft

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
	# マップ外 (画面外の闇) は何もしない。get_tile が範囲外で WALL を返すため、
	# ここで弾かないと外の空クリックが「掘れない壁」扱いになってしまう。
	if not world.map.in_bounds(tp.x, tp.y):
		return
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
	_update_outcome_panel()

## 勝敗パネルの表示更新。決着 (VICTORY/DEFEAT) で見出し + 到達ルート (§13 / A3) +
## 統計 (誕生/死/到達日) を出す。文面は messages.json の labels.ending から。
func _update_outcome_panel() -> void:
	if _outcome_panel == null:
		return
	if world.outcome == World.Outcome.ONGOING:
		_outcome_panel.visible = false
		return
	if world.outcome == World.Outcome.VICTORY:
		_outcome_title.text = TextDB.label("ending", "victory_title", "★ 勝利")
		_outcome_title.add_theme_color_override("font_color", C_EMBER_BRIGHT)
		var route_key: String = ["route_repel", "route_peace", "route_tamed"][clampi(world.ending_route(), 0, 2)]
		_outcome_route.text = TextDB.label("ending", route_key, "")
	else:
		_outcome_title.text = TextDB.label("ending", "defeat_title", "✖ 敗北")
		_outcome_title.add_theme_color_override("font_color", C_BLOOD)
		_outcome_route.text = TextDB.label("ending", "defeat_body", "")
	_outcome_stats.text = TextDB.label("ending", "stats",
		"{day} 日 · 誕生 {births} · 死 {deaths} · 頭数 {alive}").format({
			"day": world.day, "births": world.births_total,
			"deaths": world.deaths_total, "alive": world._alive_count(),
		})
	_outcome_panel.visible = true

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
	# 人間個体 (捕虜由来の側室・苗床母体・アミナ) は種族を明示する (異種つがいの演出 / §14)。
	var species_jp := "人間 " if g.species == Goblin.Species.HUMAN else ""
	var sex_jp := species_jp + ("♀ 雌" if g.sex == Goblin.Sex.FEMALE else "♂ 雄")
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
		# 交尾中は courting_id が相手を指す (寝床へ留めるため完了/中断まで保持される)。
		var mate := _find_goblin(g.courting_id)
		var mate_nm: String = GobNames.of(mate) if mate != null else "つがい"
		tags.append("[color=#e8a0b8]寝床にこもっている (相手 %s)[/color]" % mate_nm)
	elif g.courting_id >= 0:
		# 求愛は雌が起点 (§3-6)。雌=誘っている / 雄=誘われている、で表記を分ける。
		var ct := _find_goblin(g.courting_id)
		var ct_nm: String = GobNames.of(ct) if ct != null else "相手"
		var verb := "を寝床に誘っている" if g.sex == Goblin.Sex.FEMALE else "に寝床へ誘われている"
		tags.append("[color=#e8a0b8]%s%s[/color]" % [ct_nm, verb])
	if g.pending_bond:
		tags.append("[color=#e8a0b8]つがいの承認待ち[/color]")
	if g.role == Goblin.Role.CONCUBINE:
		var spouse := _find_goblin(g.mate_id)
		var sp_nm: String = GobNames.of(spouse) if spouse != null else "娶り主"
		tags.append("[color=#e8a0b8]側室 (%s の伴侶)[/color]" % sp_nm)
	# 出自 (捕虜・苗床産まれは群れの来歴として表示する)。
	if g.origin == Goblin.Origin.CONCUBINE or g.origin == Goblin.Origin.CAPTIVE_JOINED:
		tags.append("[color=#8a7d68]捕虜出身[/color]")
	elif g.origin == Goblin.Origin.NURSERY:
		tags.append("[color=#8a7d68]苗床産まれ[/color]")
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
	for cfg in [["易", 0, "easy"], ["並", 1, "normal"], ["難", 2, "hard"]]:
		var db := Button.new()
		db.text = cfg[0]
		db.add_theme_font_size_override("font_size", 12)
		db.tooltip_text = TextDB.label("difficulty", cfg[2], "")
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

	# --- 勝敗パネル (中央)。決着時に見出し + ルート + 統計 + 再挑戦導線を出す ---
	_outcome_panel = PanelContainer.new()
	_outcome_panel.set_anchors_preset(Control.PRESET_CENTER)
	_outcome_panel.offset_left = -260.0
	_outcome_panel.offset_right = 260.0
	_outcome_panel.offset_top = -110.0
	_outcome_panel.offset_bottom = 110.0
	_outcome_panel.add_theme_stylebox_override("panel", _panel_style())
	_outcome_panel.visible = false
	var obox := VBoxContainer.new()
	obox.add_theme_constant_override("separation", 10)
	obox.alignment = BoxContainer.ALIGNMENT_CENTER
	_outcome_panel.add_child(obox)
	_outcome_title = Label.new()
	_outcome_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_outcome_title.add_theme_font_size_override("font_size", 28)
	_outcome_title.add_theme_color_override("font_color", C_EMBER_BRIGHT)
	obox.add_child(_outcome_title)
	_outcome_route = Label.new()
	_outcome_route.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_outcome_route.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_outcome_route.custom_minimum_size = Vector2(500, 0)
	_outcome_route.add_theme_font_size_override("font_size", 14)
	_outcome_route.add_theme_color_override("font_color", C_INK)
	obox.add_child(_outcome_route)
	_outcome_stats = Label.new()
	_outcome_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_outcome_stats.add_theme_font_size_override("font_size", 12)
	_outcome_stats.add_theme_color_override("font_color", C_INK_DIM)
	obox.add_child(_outcome_stats)
	var orow := HBoxContainer.new()
	orow.alignment = BoxContainer.ALIGNMENT_CENTER
	orow.add_theme_constant_override("separation", 6)
	var retry_label := Label.new()
	retry_label.text = TextDB.label("ending", "retry", "新しい群れ:")
	retry_label.add_theme_color_override("font_color", C_INK_FAINT)
	retry_label.add_theme_font_size_override("font_size", 12)
	orow.add_child(retry_label)
	for cfg in [["易", 0], ["並", 1], ["難", 2]]:
		var rb := Button.new()
		rb.text = cfg[0]
		rb.add_theme_font_size_override("font_size", 13)
		_style_button(rb, false)
		var lvl: int = cfg[1]
		rb.pressed.connect(func() -> void: _start_new_game(lvl))
		orow.add_child(rb)
	obox.add_child(orow)
	ui.add_child(_outcome_panel)

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
	_explicit_toggle_button = Button.new()
	_explicit_toggle_button.add_theme_font_size_override("font_size", 12)
	_explicit_toggle_button.pressed.connect(func() -> void:
		_explicit_on = not _explicit_on
		_refresh_toggle_buttons())
	toggle_bar.add_child(_explicit_toggle_button)
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

	# --- 役職任命パネル (操作の深み)。ゴブリン選択中だけ表示。捕虜パネルの上の帯 ---
	_role_panel = PanelContainer.new()
	_role_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_role_panel.offset_left = -640.0
	_role_panel.offset_right = -298.0
	_role_panel.offset_top = -330.0
	_role_panel.offset_bottom = -228.0
	_role_panel.add_theme_stylebox_override("panel", _panel_style())
	_role_panel.visible = false
	var rbox := VBoxContainer.new()
	rbox.add_theme_constant_override("separation", 4)
	_role_panel.add_child(rbox)
	rbox.add_child(_section_title("役 職 任 命"))
	_role_info = Label.new()
	_role_info.add_theme_color_override("font_color", C_INK)
	_role_info.add_theme_font_size_override("font_size", 12)
	rbox.add_child(_role_info)
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 4)
	for cfg in [["シャーマン", Goblin.Role.SHAMAN], ["まじない医", Goblin.Role.WITCH_DOCTOR]]:
		var rb := Button.new()
		rb.text = cfg[0]
		rb.add_theme_font_size_override("font_size", 11)
		_style_button(rb, false)
		var role_v: int = cfg[1]
		rb.pressed.connect(func() -> void: _appoint_role(role_v))
		rrow.add_child(rb)
		_role_buttons.append({"btn": rb, "role": role_v})
	_role_unassign_button = Button.new()
	_role_unassign_button.text = "解任"
	_role_unassign_button.add_theme_font_size_override("font_size", 11)
	_style_button(_role_unassign_button, false)
	_role_unassign_button.pressed.connect(func() -> void: _appoint_role(Goblin.Role.NONE))
	rrow.add_child(_role_unassign_button)
	rbox.add_child(rrow)
	ui.add_child(_role_panel)

	# --- チュートリアルバナー (オンボーディング・中央上)。平和な序盤にヒントを 1 つずつ ---
	_tutorial_banner = PanelContainer.new()
	_tutorial_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_tutorial_banner.offset_left = -300.0
	_tutorial_banner.offset_right = 300.0
	_tutorial_banner.offset_top = 108.0
	_tutorial_banner.offset_bottom = 156.0
	_tutorial_banner.add_theme_stylebox_override("panel", _panel_style())
	_tutorial_banner.visible = false
	var tbox := VBoxContainer.new()
	_tutorial_banner.add_child(tbox)
	_tutorial_label = Label.new()
	_tutorial_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_label.custom_minimum_size = Vector2(580, 0)
	_tutorial_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tutorial_label.add_theme_color_override("font_color", C_EMBER_BRIGHT)
	_tutorial_label.add_theme_font_size_override("font_size", 13)
	tbox.add_child(_tutorial_label)
	ui.add_child(_tutorial_banner)

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
	var is_active := world.outcome == World.Outcome.ONGOING and world.phase != World.Phase.PEACE
	_defense_panel.visible = is_active
	if not is_active:
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
		var info := "捕虜 — ゴブリン 雄%d 雌%d / 人間 雄%d 雌%d" % [
			int(world.cap_male_goblin), int(world.cap_female_goblin),
			int(world.cap_male_human), int(world.cap_female_human)]
		# 苗床の母体ステータス: 稼働中なら雌捕虜が母体になっている内訳と累計出産を出す
		# (個体は抽象カウントなので「種族×頭数」で誰がどうなったかを示す)。
		var has_nursery := false
		for r in world.map.rooms:
			if r.room_type == TileMapData.RoomType.NURSERY:
				has_nursery = true
				break
		if has_nursery:
			var host_g := int(world.cap_female_goblin)
			var host_h := int(world.cap_female_human) if world.params.human_nursery_allowed else 0
			if host_g + host_h > 0:
				info += "\n🍼 苗床の母体: 雌ゴブ%d・雌人間%d が孕み中" % [host_g, host_h]
			else:
				info += "\n🍼 苗床は空 (雌捕虜を母体にできる)"
			if _nursery_born_goblin + _nursery_born_human > 0:
				info += "\n  これまで苗床で ゴブ母から%d・人母から%d 匹" % [
					_nursery_born_goblin, _nursery_born_human]
		elif world.cap_female_goblin + world.cap_female_human >= 1.0:
			info += "\n雌捕虜は苗床部屋を建てると母体にできる"
		_captive_info.text = info
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

# ════ 役職任命 (操作の深み) ════
## 選択中ゴブリンの現役シャーマン数を数える (枠表示・自動任命と同じ集計)。
func _shaman_count() -> int:
	var n := 0
	for g in world.goblins:
		if g.role == Goblin.Role.SHAMAN:
			n += 1
	return n

## 役職を任命/解任する。選択中ゴブリンへ APPOINT_ROLE コマンドを積む (controller.gd で
## 即時反映)。妥当性 (性別/年齢/枠) はここで弾く (シム側の枠は強制でない / KI-03)。
func _appoint_role(role: int) -> void:
	var g := _find_goblin(sel_id) if sel_kind == SelKind.GOBLIN else null
	if g == null:
		return
	if role != Goblin.Role.NONE:
		if g.is_child():
			_push_feed("event", "子どもには役職を任せられない。")
			return
		if g.is_unique:
			_push_feed("event", "族長には別の役職を兼ねさせられない。")
			return
		if role == Goblin.Role.SHAMAN:
			if g.sex != Goblin.Sex.MALE:
				_push_feed("event", "シャーマンは雄の成体に限る。")
				return
			if g.role != Goblin.Role.SHAMAN and _shaman_count() >= world.shaman_slots():
				_push_feed("event", "シャーマンの任命枠が埋まっている (トーテムのランクを上げると増える)。")
				return
	controller.queue.append({"type": Controller.CommandType.APPOINT_ROLE,
			"goblin_id": g.id, "role": role})

## 役職任命パネルの毎フレーム更新 (ゴブリン選択中だけ表示。枠超過/不適はボタン無効化)。
func _update_role_panel() -> void:
	if _role_panel == null:
		return
	var g := _find_goblin(sel_id) if sel_kind == SelKind.GOBLIN else null
	# 子・族長・捕虜由来 (側室/苗床) は任命対象外なので隠す。
	var targetable := g != null and not g.is_child() and not g.is_unique \
			and g.role != Goblin.Role.CONCUBINE and g.role != Goblin.Role.NURSERY_HOST
	_role_panel.visible = targetable
	if not targetable:
		return
	var shamans := _shaman_count()
	_role_info.text = "%s — 現在: %s   (シャーマン %d/%d 枠)" % [
		GobNames.of(g), ROLE_JP.get(g.role, "?"), shamans, world.shaman_slots()]
	for rbd in _role_buttons:
		var role_v: int = rbd.role
		var btn := rbd.btn as Button
		var ok := g.role != role_v
		if role_v == Goblin.Role.SHAMAN:
			ok = ok and g.sex == Goblin.Sex.MALE and shamans < world.shaman_slots()
		btn.disabled = not ok
	_role_unassign_button.disabled = g.role == Goblin.Role.NONE

# ════ 文脈駆動チュートリアル (オンボーディング・演出ローカル / KI-09) ════
## 平和な序盤に操作ヒントを 1 つずつ出す。autosave 復元後は出さない (既見扱い)。
## バナーは数秒で自動的に畳む (新しいヒントが来たら差し替え)。
func _show_tutorial(key: String, text: String) -> void:
	if _tutorial_seen.has(key) or text.is_empty():
		return
	_tutorial_seen.append(key)
	_tutorial_label.text = text
	_tutorial_banner.visible = true
	# 約 12 実秒で自動的に畳む (speed に依らず実時間。tick で近似)。
	_tutorial_hide_tick = world.tick + int(round(12.0 / (MS_PER_TICK / 1000.0)))

func _update_tutorial() -> void:
	if _tutorial_banner == null:
		return
	# 表示中のバナーを時間で畳む。
	if _tutorial_banner.visible and _tutorial_hide_tick >= 0 and world.tick >= _tutorial_hide_tick:
		_tutorial_banner.visible = false
	if world.outcome != World.Outcome.ONGOING:
		return
	# 平和な間だけ序盤ヒントを順に出す (day はシムの確定値だが表示判断は演出ローカル)。
	if world.phase == World.Phase.PEACE:
		if world.day == 0:
			_show_tutorial("day0_select", TextDB.label("tutorial", "day0_select"))
		elif world.day == 1 and _tutorial_seen.has("day0_select"):
			_show_tutorial("day0_role", TextDB.label("tutorial", "day0_role"))
		elif world.day == 2 and _tutorial_seen.has("day0_role"):
			_show_tutorial("day1_build", TextDB.label("tutorial", "day1_build"))
		elif world.day == 3 and _tutorial_seen.has("day1_build"):
			_show_tutorial("day2_dispatch", TextDB.label("tutorial", "day2_dispatch"))
	# 最初の大襲撃が近づいたら 1 回だけ防衛のヒント。
	if world.phase == World.Phase.PEACE and world.outcome == World.Outcome.ONGOING:
		var days_left := float(world.next_big_raid_tick - world.tick) / float(params.ticks_per_day)
		if days_left <= 1.0:
			_show_tutorial("raid_incoming", TextDB.label("tutorial", "raid_incoming"))

# ════ 夜の演出フィード (オンボーディング/雰囲気・演出ローカル) ════
## 昼→夜の切り替わりを 1 回だけフィードに流す (夜は外征不可・就寝の合図)。
func _update_ambience() -> void:
	if world.outcome != World.Outcome.ONGOING:
		_night_was_day = world.is_day()
		return
	var is_day := world.is_day()
	if _night_was_day and not is_day:
		_push_feed("event", TextDB.msg_pick("night_fall", _conv_rng, {}, ""))
	_night_was_day = is_day

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
	if _explicit_toggle_button != null:
		_explicit_toggle_button.text = "R18 ON" if _explicit_on else "R18 OFF"
		_style_button(_explicit_toggle_button, _explicit_on)
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
