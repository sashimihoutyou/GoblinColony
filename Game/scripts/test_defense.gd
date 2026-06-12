extends SceneTree
## §3-20 ブリーチング + §3-17 防衛配分 + §9 復興 (壁再建) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_defense.gd
##   - 壁破壊役: 狙い選定 (無敵壁を選ばない) → 破壊予告 → 壁が割れて FLOOR 化。
##   - 防衛配分: 自動 (敵戦力比例) の追従と手動配分の固着。
##   - 戦線の持ち場が配分どおり巣口の防衛ラインへ寄る。
##   - 破られた壁跡の再建 (修復ジョブの拡張)。
##   - 新フィールドのスナップショット往復 + 復元後の決定性。

func _init() -> void:
	var ok := true
	ok = _test_breach_pick_and_break() and ok
	ok = _test_invincible_walls() and ok
	ok = _test_alloc_auto_and_manual() and ok
	ok = _test_defense_slot_split() and ok
	ok = _test_rebuild_flow() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("DEFENSE_OK")
		quit(0)
	else:
		print("DEFENSE_FAIL")
		quit(1)

func _make_world(seed_v: int = 7) -> World:
	var p := SimParams.new()
	p.seed = seed_v
	var w := World.new()
	w.setup(p)
	return w

func _check(cond: bool, label: String) -> bool:
	if not cond:
		printerr("  NG: " + label)
	return cond

## 壁破壊役が壁を狙い、予告を出し、割って FLOOR 化する。
func _test_breach_pick_and_break() -> bool:
	var ok := true
	var w := _make_world()
	w.phase = World.Phase.COMBAT
	# 戦線を南東巣口へ寄せて北の壁破壊役を観察する (交戦で検証が濁らないように)。
	w.set_defense_alloc([0.0, 1.0, 0.0])
	w._spawn_enemy_at_gate(0, false, true)
	var warned := false
	var breached := false
	var breach_pos := Vector2i(-1, -1)
	for i in range(w.params.ticks_per_day * 2):
		w.tick_once()
		for e in w.last_events:
			if e.t == "breach_warn":
				warned = true
			if e.t == "breach":
				breached = true
				breach_pos = Vector2i(int(e.x), int(e.y))
		if breached:
			break
	ok = _check(warned, "破壊予告イベントが出る") and ok
	ok = _check(breached, "壁が割られる") and ok
	if breached:
		ok = _check(w.map.get_tile(breach_pos.x, breach_pos.y) == TileMapData.TileType.FLOOR,
				"割れた壁は FLOOR になる") and ok
		ok = _check(w.breach_sites.has(breach_pos), "跡が breach_sites に残る") and ok
	return ok

## 無敵壁 (マップ縁・トーテム至近) は狙えない。
func _test_invincible_walls() -> bool:
	var ok := true
	var w := _make_world()
	ok = _check(not w._wall_breakable(Vector2i(0, 10)), "マップ縁は無敵") and ok
	ok = _check(not w._wall_breakable(Vector2i(w.map.width - 1, 10)), "右縁も無敵") and ok
	# トーテム至近 (チェビシェフ 2) — 壁があってもなくても false を返す。
	ok = _check(not w._wall_breakable(w.map.totem + Vector2i(1, 1)), "トーテム至近は無敵") and ok
	# 壁破壊役の選定結果は必ず破壊可能な壁。
	w.phase = World.Phase.COMBAT
	w._spawn_enemy_at_gate(0, false, true)
	var e: EnemyUnit = w.enemies[0]
	w._pick_breach_wall(e)
	if e.wall_x >= 0:
		ok = _check(w._wall_breakable(Vector2i(e.wall_x, e.wall_y)),
				"選定された壁は破壊可能") and ok
	return ok

## 自動配分は敵の巣口別頭数へ追従し、手動配分は敵が動いても固着する。
func _test_alloc_auto_and_manual() -> bool:
	var ok := true
	var w := _make_world()
	w.phase = World.Phase.COMBAT
	for i in range(3):
		w._spawn_enemy_at_gate(2, false)
	w._step_defense_alloc()
	ok = _check(absf(w.defense_alloc[2] - 1.0) < 0.001, "自動配分が敵側へ全振りされる") and ok
	ok = _check(not w.defense_alloc_manual, "自動のまま") and ok
	ok = _check(w.set_defense_alloc([1.0, 1.0, 0.0]), "手動配分を設定できる") and ok
	ok = _check(absf(w.defense_alloc[0] - 0.5) < 0.001, "重みが正規化される") and ok
	w._step_defense_alloc()
	ok = _check(absf(w.defense_alloc[0] - 0.5) < 0.001, "手動配分は自動追従で動かない") and ok
	ok = _check(not w.set_defense_alloc([0.0, 0.0]), "巣口数が合わない配分は拒否") and ok
	ok = _check(not w.set_defense_alloc([0.0, 0.0, 0.0]), "全ゼロ配分は拒否") and ok
	w.clear_defense_alloc()
	ok = _check(not w.defense_alloc_manual, "自動へ戻せる") and ok
	return ok

## 全振り配分なら全戦線の持ち場がその巣口の防衛ライン近傍になる。
func _test_defense_slot_split() -> bool:
	var ok := true
	var w := _make_world()
	w.set_defense_alloc([1.0, 0.0, 0.0])
	var dp: Vector2i = w._defense_points[0]
	ok = _check(w._inside_nest(dp) and w.map.is_walkable(dp.x, dp.y),
			"防衛ラインは巣内の歩ける床") and ok
	for g in w.goblins:
		if g.sex != Goblin.Sex.MALE and not g.is_unique:
			continue
		if g.is_child():
			continue
		var slot := w._defense_slot(g)
		ok = _check(maxi(abs(slot.x - dp.x), abs(slot.y - dp.y)) <= 2,
				"戦線 id=%d の持ち場が巣口 0 の防衛ライン近傍" % g.id) and ok
	return ok

## 破られた壁跡は order_repair で再建できる (建材は再建コスト)。
func _test_rebuild_flow() -> bool:
	var ok := true
	var w := _make_world()
	# 床に隣接する壁を 1 枚選び、破られた状態を直接つくる。
	var wall := Vector2i(-1, -1)
	for y in range(2, w.map.height - 2):
		for x in range(2, w.map.width - 2):
			if not w._wall_breakable(Vector2i(x, y)):
				continue
			for off in World.OFFS8:
				if w.map.get_tile(x + off.x, y + off.y) == TileMapData.TileType.FLOOR:
					wall = Vector2i(x, y)
					break
			if wall.x >= 0:
				break
		if wall.x >= 0:
			break
	ok = _check(wall.x >= 0, "前提: 破壊可能で床に隣接する壁がある") and ok
	w.map.set_tile(wall.x, wall.y, TileMapData.TileType.FLOOR)
	w.map.wall_hp[w.map.idx(wall.x, wall.y)] = 0
	w.breach_sites.append(wall)
	w._rebuild_floor_caches()
	w.mud = 1.0
	ok = _check(not w.order_repair(wall.x, wall.y), "建材不足 (再建は重い) では発注不可") and ok
	w.mud = 5.0
	ok = _check(w.order_repair(wall.x, wall.y), "再建を発注できる") and ok
	ok = _check(absf(w.mud - (5.0 - w.params.wall_rebuild_cost)) < 0.001,
			"再建コストを消費する") and ok
	var done := false
	for i in range(w.params.ticks_per_day * 3):
		w.tick_once()
		for e in w.last_events:
			if e.t == "repair_done":
				done = true
		if done:
			break
	ok = _check(done, "再建が完了する") and ok
	ok = _check(w.map.get_tile(wall.x, wall.y) == TileMapData.TileType.WALL,
			"壁が戻る") and ok
	ok = _check(w.map.wall_hp[w.map.idx(wall.x, wall.y)] == MapTemplate.WALL_HP,
			"耐久も全快") and ok
	ok = _check(not w.breach_sites.has(wall), "跡が消える") and ok
	return ok

## 新フィールド込みの往復一致 + 復元後 30 tick の決定性。
func _test_snapshot_roundtrip() -> bool:
	var ok := true
	var w := _make_world(11)
	w.phase = World.Phase.COMBAT
	w.set_defense_alloc([0.2, 0.5, 0.3])
	w._spawn_enemy_at_gate(0, false, true)
	w.breach_sites.append(Vector2i(5, 5))
	for i in range(40):
		w.tick_once()
	var snap := w.snapshot()
	var w2 := World.new()
	w2.setup(w.params)
	w2.restore(snap)
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(snap),
			"往復でスナップショットが一致する") and ok
	for i in range(30):
		w.tick_once()
		w2.tick_once()
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(w.snapshot()),
			"復元後 30 tick の決定性が一致する") and ok
	return ok
