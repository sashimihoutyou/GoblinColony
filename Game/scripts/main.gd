extends Node2D
## メインループ (P1-09 / P1-10)。実時間 → tick 変換 → controller → world.tick → render。
##
## 実時間に触れるのはここだけ (KI-09 tick_driver 相当)。速度倍率と端数持ち越し。
## α版は AutoController でオートプレイ。次の実装では controller を PlayerController に
## 差し替えるだけで操作可能になる (controller.gd の Command キュー経由)。

const MS_PER_TICK := 1000.0   # 1x で 1 tick = 1 秒 (§NUMBERS 暫定。1日=20秒)

var world: World
var params: SimParams
var controller: Controller
var renderer: Renderer

var speed: float = 1.0        # 0 / 1 / 3
var _accum_ms: float = 0.0

@onready var status_label: Label = $UI/StatusBar/StatusLabel
@onready var event_label: Label = $UI/EventLabel

func _ready() -> void:
	params = SimParams.new()
	world = World.new()
	world.setup(params)
	controller = AutoController.new()

	renderer = $Renderer
	renderer.tile_size = 16
	# 画像を使いたい場合はここでパスを指定 (無ければ単色フォールバック):
	#   renderer.tile_textures[TileMapData.TileType.FLOOR] = "res://art/floor.png"
	#   renderer.goblin_texture_path = "res://art/goblin.png"

	_wire_speed_buttons()
	_update_camera()
	renderer.render(world)

func _process(delta: float) -> void:
	if world.outcome != World.Outcome.ONGOING:
		_update_status()
		return
	if speed <= 0.0:
		return
	_accum_ms += delta * 1000.0 * speed
	var max_ticks_per_frame := 6  # 暴走防止 (KI-09)
	var done := 0
	while _accum_ms >= MS_PER_TICK and done < max_ticks_per_frame:
		_accum_ms -= MS_PER_TICK
		_step_one_tick()
		done += 1
		if world.outcome != World.Outcome.ONGOING:
			break
	renderer.render(world)
	_update_status()

func _step_one_tick() -> void:
	controller.decide(world)
	controller.apply(world)
	world.tick_once()

func _wire_speed_buttons() -> void:
	$UI/SpeedBar/Pause.pressed.connect(func(): speed = 0.0)
	$UI/SpeedBar/Play1x.pressed.connect(func(): speed = 1.0)
	$UI/SpeedBar/Play3x.pressed.connect(func(): speed = 3.0)

func _update_camera() -> void:
	# マップ全体が見えるよう中央に寄せる (α版は固定俯瞰)。
	var m := world.map
	var cam := $Camera2D as Camera2D
	if cam:
		cam.position = Vector2(m.width * renderer.tile_size / 2.0, m.height * renderer.tile_size / 2.0)
		var zoom_x := get_viewport_rect().size.x / (m.width * renderer.tile_size + 40.0)
		var zoom_y := get_viewport_rect().size.y / (m.height * renderer.tile_size + 120.0)
		var z: float = min(zoom_x, zoom_y)
		cam.zoom = Vector2(z, z)

func _update_status() -> void:
	if status_label:
		var phase_txt := ["平時", "予兆", "交戦"][world.phase]
		var time_txt := "昼" if world.is_day() else "夜"
		status_label.text = "日 %d/%d (%s/%s)  頭数 %d/%d  信仰 %.0f  食料 %.0f  敵 %d  出生%d/死亡%d" % [
			world.day, params.final_day, time_txt, phase_txt,
			world._alive_count(), params.cap_pop,
			world.faith, world.food, world.enemies.size(),
			world.births_total, world.deaths_total,
		]
	if event_label:
		if world.outcome == World.Outcome.VICTORY:
			event_label.text = "★ 勝利 — 規定日数を生き延びた!"
		elif world.outcome == World.Outcome.DEFEAT:
			event_label.text = "✖ 敗北"
		elif not world.last_events.is_empty():
			event_label.text = " / ".join(world.last_events)
		else:
			event_label.text = ""
