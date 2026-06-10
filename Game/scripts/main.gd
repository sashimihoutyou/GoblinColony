extends Node2D
## メインループ (P1-09 / P1-10)。実時間 → tick 変換 → controller → world.tick → render。
##
## 実時間に触れるのはここだけ (KI-09 tick_driver 相当)。速度倍率と端数持ち越し。
## タイムスケール: 1 tick = 0.25 実秒 × ticks_per_day=240 → 1 日 = 実 60 秒 (3x で 20 秒)。
## tick が細かいのは連続移動 (RimWorld 風) のサンプリングのため (params.gd 参照)。
## UI はコードで構築する (Web 版ダッシュボードと同じ配色言語: 闇の岩・琥珀・苔)。

const MS_PER_TICK := 250.0

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
	Goblin.Role.CONCUBINE: "側室",
}
const STATE_HEX := {
	Goblin.State.COMBAT: "c0432e", Goblin.State.FEAR: "9a6bb0", Goblin.State.DYING: "7a4030",
	Goblin.State.HUNGRY: "c08a3a", Goblin.State.SLEEP: "4a6b8a", Goblin.State.WORK: "7a9a4e",
	Goblin.State.WANDER: "8a7d68", Goblin.State.ENRAGED: "ff5530", Goblin.State.KNOCKED_OUT: "6a4838",
}

var world: World
var params: SimParams
var controller: Controller
var renderer: Renderer

var speed: float = 1.0        # 0 / 1 / 3
var _accum_ms: float = 0.0
var selected_id: int = -1

# --- カメラ操作 (演出層ローカル状態。シムには触れない) ---
const ZOOM_MIN := 1.0         # フィット倍率 (全体表示)
const ZOOM_MAX := 8.0         # 最大拡大
const ZOOM_STEP := 1.15       # ホイール 1 段ぶんの倍率
const RIGHT_PANEL_W := 290.0  # 右パネルぶんの横オフセット
var _zoom_factor: float = 1.0 # フィット倍率に対するユーザー倍率 (1.0=全体フィット)
var _fit_zoom: float = 1.0    # viewport から算出したフィット倍率 (キャッシュ)
var _fit_pos: Vector2 = Vector2.ZERO  # factor=1.0 のときのカメラ位置 (キャッシュ)
var _panning: bool = false    # 中ボタンドラッグ中か

# UI ノード (コード構築)
var _status_label: Label
var _eta_label: Label
var _inspector: RichTextLabel
var _feed: RichTextLabel
var _outcome_label: Label
var _speed_buttons: Array = []
var _feed_lines: Array = []

func _ready() -> void:
	params = SimParams.new()
	world = World.new()
	world.setup(params)
	controller = AutoController.new()

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
	renderer.selected_id = selected_id
	renderer.render(world, delta, speed, clampf(_accum_ms / MS_PER_TICK, 0.0, 1.0))
	_update_status()
	_update_inspector()

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
				# 左クリック: 個体選択 (ワールド座標なのでカメラ変換に自動追従)。
				if event.pressed:
					selected_id = renderer.pick(world, get_global_mouse_position())
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
			_clamp_camera(cam)

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
		_zoom_factor = ZOOM_MIN
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

## カメラ位置をマップ矩形から大きく外れないようクランプ (ズームイン時のみ可動)。
func _clamp_camera(cam: Camera2D) -> void:
	if _zoom_factor <= ZOOM_MIN + 0.0001:
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
		"pregnant":
			var f := _find_goblin(int(e.get("id", -1)))
			if f != null:
				_push_feed("love", "%s が身ごもった。" % GobNames.of(f))
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
	_status_label.text = "第 %d 日 %s %s · %s   頭数 %d/%d (子%d)  食料 %.0f  信仰 %.0f  surge %.1f%s" % [
		world.day, bar, time_txt, phase_txt,
		world._alive_count(), params.cap_pop, _child_count(),
		world.food, world.faith, world.surge, totem_txt,
	]
	if world.outcome == World.Outcome.ONGOING and world.phase == World.Phase.PEACE:
		var days_left := float(world.next_big_raid_tick - world.tick) / float(params.ticks_per_day)
		_eta_label.text = "次の大襲撃まで 約 %s" % ("1 日未満" if days_left < 1.0 else "%d 日" % ceili(days_left))
		_eta_label.add_theme_color_override("font_color", C_BLOOD if days_left <= 1.0 else C_INK_FAINT)
	else:
		_eta_label.text = ""
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

func _update_inspector() -> void:
	if _inspector == null:
		return
	var g := _find_goblin(selected_id)
	if g == null:
		_inspector.text = "[color=#5a4f40]ゴブリンをタップすると、その個体の暮らしぶりが見える。[/color]"
		return
	var sex_jp := "♀ 雌" if g.sex == Goblin.Sex.FEMALE else "♂ 雄"
	var age_days := float(world.tick - g.born_tick) / float(params.ticks_per_day)
	var state_hex: String = STATE_HEX.get(g.state, "8a7d68")
	var lines: Array = []
	lines.append("[b][color=#ffb454]%s[/color][/b]" % GobNames.of(g))
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
	if g.bereaved:
		tags.append("伴侶を失った悲しみ")
	if not tags.is_empty():
		lines.append("[color=#5a4f40]" + " · ".join(tags) + "[/color]")
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
	ui.add_child(bar)
	_refresh_speed_buttons()

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
	# 現在のユーザー倍率を保って再適用 (factor=1.0 ならフィット位置へ正確に復帰)。
	var z := _fit_zoom * _zoom_factor
	cam.zoom = Vector2(z, z)
	if _zoom_factor <= ZOOM_MIN + 0.0001:
		cam.position = _fit_pos
	else:
		_clamp_camera(cam)
