extends SceneTree
## メインシーンの headless 起動スモーク。
## UI 構築・レンダラー・メインループがエラーなく数秒回り、tick が進むことを確認する。
## (描画結果そのものは headless では検証できない。パースエラー・実行時エラーの検出が目的。)
##
## 実行: godot --headless --path Game --script res://scripts/test_scene_smoke.gd
##   期待出力: SCENE_SMOKE_OK

var _frames: int = 0
var _main: Node = null

func _init() -> void:
	var packed := load("res://scenes/Main.tscn") as PackedScene
	if packed == null:
		print("SCENE_SMOKE_FAIL: Main.tscn をロードできない")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child.call_deferred(_main)
	process_frame.connect(_on_frame)

func _on_frame() -> void:
	_frames += 1
	if _frames < 300:
		return
	# 5 秒ぶん回した後、シミュレーションが実際に進んでいるか。
	var w: World = _main.world
	if w == null or w.tick <= 0:
		print("SCENE_SMOKE_FAIL: tick が進んでいない (tick=%s)" % [w.tick if w != null else "null"])
		quit(1)
		return
	if _main.renderer == null:
		print("SCENE_SMOKE_FAIL: renderer が無い")
		quit(1)
		return
	print("  scene-smoke: frames=%d tick=%d day=%d alive=%d" % [
		_frames, w.tick, w.day, w._alive_count()])
	print("SCENE_SMOKE_OK")
	quit(0)
