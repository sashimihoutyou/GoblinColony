extends SceneTree
## §3-11 資源スカラー + §3-12 ジョブキュー + §3-15 建築 + §3-20 壁修復の
## ヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_jobs.gd
##   - 採掘指定 (トグル) → 取得 → 完了でノード枯渇・建材加算。
##   - 中断 (WORK 離脱) でジョブ解放・進捗保持 (§3-12 の表)。
##   - 失効 (対象消滅) でジョブ破棄。
##   - 部屋建築: 配置検証・建材消費・完了で rooms[] へ追加。
##   - 壁修復: 損傷壁のみ・建材消費・完了で全快。
##   - 新規フィールド (資源/jobs) のスナップショット往復 + 復元後の決定性。

func _init() -> void:
	var ok := true
	ok = _test_mine_flow() and ok
	ok = _test_interrupt_release() and ok
	ok = _test_job_expiry() and ok
	ok = _test_build_flow() and ok
	ok = _test_repair_flow() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("JOBS_OK")
		quit(0)
	else:
		print("JOBS_FAIL")
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

## 採掘: 指定トグル → 自動取得 → 完了でノードが枯渇し建材が増える。
func _test_mine_flow() -> bool:
	var ok := true
	var w := _make_world()
	var node := Vector2i(11, 17)  # map_template の固定ノード
	ok = _check(w.map.get_tile(node.x, node.y) == TileMapData.TileType.RESOURCE_NODE,
			"前提: (11,17) は採掘ノード") and ok
	# トグル: 指定 → 解除 → 再指定。
	ok = _check(w.designate_mine(node.x, node.y), "採掘指定できる") and ok
	ok = _check(w.jobs.size() == 1, "ジョブが積まれる") and ok
	ok = _check(w.designate_mine(node.x, node.y), "再タップで解除") and ok
	ok = _check(w.jobs.is_empty(), "解除でジョブが消える") and ok
	ok = _check(not w.designate_mine(5, 5), "ノード以外は指定できない") and ok
	w.designate_mine(node.x, node.y)
	var mud_before := w.mud
	# 採掘 0.5 日 + 徒歩。3 日以内に完了するはず (平和期間内)。
	var done := false
	for i in range(w.params.ticks_per_day * 3):
		w.tick_once()
		for e in w.last_events:
			if e.t == "mine_done":
				done = true
		if done:
			break
	ok = _check(done, "採掘が完了する") and ok
	ok = _check(w.map.get_tile(node.x, node.y) == TileMapData.TileType.EXHAUSTED,
			"ノードが枯渇タイルになる") and ok
	ok = _check(w.mud >= mud_before + w.params.mine_yield_mud - 0.001,
			"建材が収量ぶん増える") and ok
	ok = _check(w.jobs.is_empty(), "完了でジョブが消える") and ok
	return ok

## 中断: WORK を離れた持ち主からジョブが外れ、進捗は保持される (§3-12 の表)。
func _test_interrupt_release() -> bool:
	var ok := true
	var w := _make_world()
	w.designate_mine(11, 17)
	var j: Dictionary = w.jobs[0]
	# 適格な無役個体を 1 体選んで手で取得させる (単体力学の検証)。
	var g: Goblin = null
	for cand in w.goblins:
		if cand.role == Goblin.Role.NONE and cand.sex == Goblin.Sex.MALE \
				and not cand.is_child() and not w._has_room_assignment(cand.id):
			g = cand
			break
	ok = _check(g != null, "前提: 無役の雄成体がいる") and ok
	w._claim_job(g)
	ok = _check(g.job_id == j.id and j.assigned_id == g.id, "ジョブを取得できる") and ok
	j.progress = 0.4
	g.state = Goblin.State.COMBAT  # 戦闘割り込み
	w._step_jobs()
	ok = _check(j.assigned_id == -1 and g.job_id == -1, "中断でジョブが解放される") and ok
	ok = _check(absf(j.progress - 0.4) < 0.0001, "進捗は保持される") and ok
	return ok

## 失効: 対象タイルが消えたジョブはスイープで破棄され、持ち主も解放される。
func _test_job_expiry() -> bool:
	var ok := true
	var w := _make_world()
	w.designate_mine(11, 17)
	w.map.set_tile(11, 17, TileMapData.TileType.EXHAUSTED)  # 対象消滅を擬似再現
	w._step_jobs()
	ok = _check(w.jobs.is_empty(), "失効ジョブが破棄される") and ok
	return ok

## 建築: 配置検証 → 建材消費 → 建設ジョブ → 完了で rooms[] に載る。
func _test_build_flow() -> bool:
	var ok := true
	var w := _make_world()
	var rt := TileMapData.RoomType.MUSHROOM
	# 置ける場所をマップから走査で見つける (テンプレート変更に追従)。
	var spot := Vector2i(-1, -1)
	for y in range(w.map.height):
		for x in range(w.map.width):
			if w.can_place_room(rt, x, y):
				spot = Vector2i(x, y)
				break
		if spot.x >= 0:
			break
	ok = _check(spot.x >= 0, "部屋を置ける床がある") and ok
	ok = _check(not w.can_place_room(rt, 0, 0), "マップ縁 (岩) には置けない") and ok
	var cost: float = SimParams.ROOM_BUILD_COST[rt]
	w.mud = cost - 1.0
	ok = _check(not w.order_build(rt, spot.x, spot.y), "建材不足では発注できない") and ok
	w.mud = cost + 2.0
	var rooms_before := w.map.rooms.size()
	ok = _check(w.order_build(rt, spot.x, spot.y), "発注できる") and ok
	ok = _check(absf(w.mud - 2.0) < 0.001, "確定時に建材を消費する") and ok
	ok = _check(not w.can_place_room(rt, spot.x, spot.y), "建設予定地には重ねて置けない") and ok
	ok = _check(w.map.rooms.size() == rooms_before, "完了までは rooms[] に載らない") and ok
	var done := false
	for i in range(w.params.ticks_per_day * 4):
		w.tick_once()
		for e in w.last_events:
			if e.t == "build_done":
				done = true
		if done:
			break
	ok = _check(done, "建設が完了する") and ok
	ok = _check(w.map.rooms.size() == rooms_before + 1, "完了で部屋が増える") and ok
	if w.map.rooms.size() > rooms_before:
		var r: Dictionary = w.map.rooms[w.map.rooms.size() - 1]
		ok = _check(r.room_type == rt and r.x == spot.x and r.y == spot.y,
				"部屋の種類と位置が一致する") and ok
	return ok

## 壁修復: 損傷壁のみ発注可・建材消費・完了で全快。
func _test_repair_flow() -> bool:
	var ok := true
	var w := _make_world()
	# 床に隣接する壁 (作業者が立てる) を 1 枚選んで傷つける。
	var wall := Vector2i(-1, -1)
	for y in range(1, w.map.height - 1):
		for x in range(1, w.map.width - 1):
			if w.map.get_tile(x, y) != TileMapData.TileType.WALL:
				continue
			for off in World.OFFS8:
				if w.map.get_tile(x + off.x, y + off.y) == TileMapData.TileType.FLOOR:
					wall = Vector2i(x, y)
					break
			if wall.x >= 0:
				break
		if wall.x >= 0:
			break
	ok = _check(wall.x >= 0, "前提: 床に隣接する壁がある") and ok
	ok = _check(not w.order_repair(wall.x, wall.y), "無傷の壁は発注できない") and ok
	w.map.wall_hp[w.map.idx(wall.x, wall.y)] = 5
	var mud_before := w.mud
	ok = _check(w.order_repair(wall.x, wall.y), "損傷壁は発注できる") and ok
	ok = _check(not w.order_repair(wall.x, wall.y), "二重発注はできない") and ok
	ok = _check(absf(w.mud - (mud_before - w.params.wall_repair_cost)) < 0.001,
			"発注時に建材を消費する") and ok
	var done := false
	for i in range(w.params.ticks_per_day * 3):
		w.tick_once()
		for e in w.last_events:
			if e.t == "repair_done":
				done = true
		if done:
			break
	ok = _check(done, "修復が完了する") and ok
	ok = _check(w.map.wall_hp[w.map.idx(wall.x, wall.y)] == MapTemplate.WALL_HP,
			"壁が全快する") and ok
	return ok

## スナップショット往復: 資源 + 進行中ジョブを含めて一致し、復元後も決定的。
func _test_snapshot_roundtrip() -> bool:
	var ok := true
	var w := _make_world(11)
	w.designate_mine(11, 17)
	w.designate_mine(13, 19)
	w.mud = 10.0
	w.gems = 2.0
	var rt := TileMapData.RoomType.WITCH
	for y in range(w.map.height):
		var placed := false
		for x in range(w.map.width):
			if w.can_place_room(rt, x, y):
				w.order_build(rt, x, y)
				placed = true
				break
		if placed:
			break
	for i in range(60):
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
