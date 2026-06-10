extends SceneTree
## ヘッドレス通しプレイ検証 (P1 Go 基準: ラストバトル含む 30 日完走)。
##
## 実行: godot --headless --path Game --script res://scripts/test_smoke.gd
##   - 描画なしでシミュレーションを最後まで回し、決着 (勝利/敗北) を確認する。
##   - スナップショット往復が一致するか (KI-09) も確認する。

func _init() -> void:
	var ok := true
	ok = _test_map_integrity() and ok
	ok = _test_hungry_arrival_does_not_spend_food() and ok
	ok = _test_run_to_end() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("SMOKE_OK")
		quit(0)
	else:
		print("SMOKE_FAIL")
		quit(1)

## 有機洞窟マップの構造検証: トーテムから全要所へ到達できるか (接続性) と、
## 巣口以外で床が外気と 4 隣接していないか (密閉性 = 敵の侵入経路は巣口のみ)。
func _test_map_integrity() -> bool:
	var m := MapTemplate.make_initial_map()
	var ok := true
	# BFS (4 方向) でトーテムから到達できるタイル集合。
	var seen := {m.totem: true}
	var queue: Array = [m.totem]
	while not queue.is_empty():
		var p: Vector2i = queue.pop_front()
		for d in MapTemplate.DIRS4:
			var nb: Vector2i = p + d
			if m.is_walkable(nb.x, nb.y) and not seen.has(nb):
				seen[nb] = true
				queue.append(nb)
	# 要所: 集積所・巣口 3 本・各部屋の床・採掘ノード。
	if m.gates.size() != 3:
		print("  FAIL: expected 3 gates, got %d" % m.gates.size())
		ok = false
	var targets: Array = [m.storage]
	targets.append_array(m.gates)
	for tpos in targets:
		if not seen.has(tpos):
			print("  FAIL: unreachable key tile %s" % str(tpos))
			ok = false
	for r in m.rooms:
		var found := false
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				if seen.has(Vector2i(x, y)):
					found = true
		if not found:
			print("  FAIL: room %d has no reachable floor" % int(r.room_type))
			ok = false
	var nodes := 0
	var floors := 0
	for y in range(m.height):
		for x in range(m.width):
			var t := m.get_tile(x, y)
			if t == TileMapData.TileType.RESOURCE_NODE and seen.has(Vector2i(x, y)):
				nodes += 1
			if t == TileMapData.TileType.FLOOR:
				floors += 1
				# 密閉性: 床は外気と 4 隣接しない (出入りは GATE タイル経由のみ)。
				for d in MapTemplate.DIRS4:
					if m.get_tile(x + d.x, y + d.y) == TileMapData.TileType.EXTERIOR:
						print("  FAIL: floor (%d,%d) leaks to exterior" % [x, y])
						ok = false
	if nodes < 3:
		print("  FAIL: reachable resource nodes = %d (< 3)" % nodes)
		ok = false
	if floors < 150:
		print("  FAIL: floor tiles = %d (< 150) — cave too small" % floors)
		ok = false
	if ok:
		print("  map-integrity: OK (floors=%d gates=%d)" % [floors, m.gates.size()])
	return ok

func _test_hungry_arrival_does_not_spend_food() -> bool:
	var p := SimParams.new()
	p.start_goblins = 1
	p.food_per_rancher_tick = 0.0
	p.food_eat_amount = 1.0
	p.hunger_rate = 0.0
	p.sleep_rate = 0.0
	p.move_per_tick = 100.0
	var w := World.new()
	w.setup(p)
	w.food = 1.0
	var g := w.goblins[0] as Goblin
	g.role = Goblin.Role.NONE
	g.hunger = 0.8
	g.hunger_latched = true
	g.sleepiness = 0.0
	g.sleep_latched = false
	w._place(g, w.map.totem)
	w.tick_once()
	if not w._at_storage(g.pos()):
		print("  FAIL: hungry goblin did not reach storage")
		return false
	if w.food < 1.0:
		print("  FAIL: food was spent on arrival before hunger relief")
		return false
	var hunger_after_arrival: float = g.hunger
	w.tick_once()
	if g.hunger >= hunger_after_arrival:
		print("  FAIL: hunger did not recover at storage")
		return false
	if w.food >= 1.0:
		print("  FAIL: food was not spent while eating")
		return false
	print("  hungry-food-order: OK")
	return true

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
