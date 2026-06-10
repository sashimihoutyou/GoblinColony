extends SceneTree
## 多シード勝率ハーネス (§15 実数調整の土台 / KI-22/25)。
##
## 実行: godot --headless --path Game --script res://scripts/test_seeds.gd
##   - 複数シードで 30 日通しを回し、勝率と人口動態を出す。
##   - smoke より重い (数分) ので CI 的な常用ではなく調整作業時に手で回す。
##   - 現行の安定帯: enemy_tile_capacity=1 で 6/6 勝 (2 にすると 1/6 まで落ちる)。

const N_SEEDS := 6

func _init() -> void:
	var wins := 0
	for seed_v in range(N_SEEDS):
		var p := SimParams.new()
		p.seed = seed_v
		var w := World.new()
		w.setup(p)
		var guard := 0
		var max_ticks := (p.final_day + 5) * p.ticks_per_day
		while w.outcome == World.Outcome.ONGOING and guard < max_ticks:
			w.tick_once()
			guard += 1
		print("seed=%d outcome=%d day=%d alive=%d births=%d deaths=%d" % [
			seed_v, w.outcome, w.day, w._alive_count(), w.births_total, w.deaths_total])
		if w.outcome == World.Outcome.VICTORY:
			wins += 1
	print("WINS: %d/%d" % [wins, N_SEEDS])
	quit(0)
