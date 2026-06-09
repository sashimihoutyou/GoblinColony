extends SceneTree
## ヘッドレス通しプレイ検証 (P1 Go 基準: ラストバトル含む 30 日完走)。
##
## 実行: godot --headless --path Game --script res://scripts/test_smoke.gd
##   - 描画なしでシミュレーションを最後まで回し、決着 (勝利/敗北) を確認する。
##   - スナップショット往復が一致するか (KI-09) も確認する。

func _init() -> void:
	var ok := true
	ok = _test_run_to_end() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("SMOKE_OK")
		quit(0)
	else:
		print("SMOKE_FAIL")
		quit(1)

func _test_run_to_end() -> bool:
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)
	var max_ticks := (p.final_day + 5) * p.ticks_per_day
	var guard := 0
	while w.outcome == World.Outcome.ONGOING and guard < max_ticks:
		w.tick_once()
		guard += 1
	print("  run-to-end: day=%d outcome=%d alive=%d births=%d deaths=%d" % [
		w.day, w.outcome, w._alive_count(), w.births_total, w.deaths_total])
	if w.outcome == World.Outcome.ONGOING:
		print("  FAIL: did not reach a terminal outcome")
		return false
	return true

func _test_snapshot_roundtrip() -> bool:
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)
	# 適当に進める。
	for i in range(57):
		w.tick_once()
	var snap := w.snapshot()
	# 復元した別ワールドと、元ワールドを同じだけさらに進めて一致を確認。
	var w2 := World.new()
	w2.setup(p)
	w2.restore(snap)
	for i in range(40):
		w.tick_once()
		w2.tick_once()
	var a := JSON.stringify(w.snapshot())
	var b := JSON.stringify(w2.snapshot())
	if a != b:
		print("  FAIL: snapshot roundtrip diverged")
		return false
	print("  snapshot-roundtrip: OK")
	return true
