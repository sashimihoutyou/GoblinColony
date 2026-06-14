extends SceneTree
## まじない医 (§6 / spec 3-17 / B4) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_medic.gd
##   - WITCH_DOCTOR を任命すると、平時は WITCH 部屋付近を作業場とする。
##   - 在任中、寝床で休息中の負傷個体の HP 回復が herb 消費つきで加速する。
##   - herb=0 なら加速なし (素の hp_regen のみ = 経済従属)。
##   - 治療は herb を消費する。
##   - 交戦中、まじない医は防衛ライン (_defense_points) より後衛
##     (_medic_points) に控え、前衛の白兵持ち場には出ない。
##   - 新規キャッシュ (_medic_points) はスナップショット非対象でも復元後 30 tick
##     決定的に一致する。

func _init() -> void:
	var ok := true
	ok = _test_role_work_target() and ok
	ok = _test_heal_acceleration_with_herb() and ok
	ok = _test_no_acceleration_without_herb() and ok
	ok = _test_heal_consumes_herb() and ok
	ok = _test_backline_during_combat() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("MEDIC_OK")
		quit(0)
	else:
		print("MEDIC_FAIL")
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

## 指定タイプの部屋を 1 つマップに直接生やす (test_workshops.gd と同じ手法)。
func _add_room(w: World, rt: int) -> Dictionary:
	for y in range(w.map.height - 3):
		for x in range(w.map.width - 3):
			if w.can_place_room(rt, x, y):
				var size: Vector2i = SimParams.ROOM_BUILD_SIZE[rt]
				var r := {"x": x, "y": y, "w": size.x, "h": size.y,
						"room_type": rt, "assigned": []}
				w.map.rooms.append(r)
				w._rebuild_floor_caches()
				return r
	return {}

## 役職なし・成体・部屋未割当の個体を 1 体選んで返す。
func _pick_plain_adult(w: World, exclude_ids: Array = []) -> Goblin:
	for g in w.goblins:
		if g.role != Goblin.Role.NONE or g.is_unique or g.is_child():
			continue
		if g.id in exclude_ids:
			continue
		if w._has_room_assignment(g.id):
			continue
		return g
	return null

## ① WITCH_DOCTOR を任命すると、平時は WITCH 部屋付近を作業場とする。
func _test_role_work_target() -> bool:
	var ok := true
	var w := _make_world()
	var r := _add_room(w, TileMapData.RoomType.WITCH)
	ok = _check(not r.is_empty(), "まじない医部屋を設置できる") and ok
	var medic := _pick_plain_adult(w)
	ok = _check(medic != null, "任命対象の成体が見つかる") and ok
	if medic == null:
		return false
	medic.role = Goblin.Role.WITCH_DOCTOR
	medic.state = Goblin.State.WORK
	var target := w._work_target(medic)
	ok = _check(target != Vector2i(-1, -1), "WORK 移動目標が得られる") and ok
	# _room_floors のキーは rooms 配列の index。WITCH 部屋の index を探して床タイルを得る。
	var widx := -1
	for i in range(w.map.rooms.size()):
		if w.map.rooms[i].room_type == TileMapData.RoomType.WITCH:
			widx = i
			break
	var tiles: Array = w._room_floors.get(widx, [])
	ok = _check(tiles.has(target), "WITCH 部屋の床タイルが作業場になる") and ok
	return ok

## ② 在任中、寝床で休息中の負傷個体の HP 回復が herb 消費つきで加速する。
func _test_heal_acceleration_with_herb() -> bool:
	var ok := true
	var w := _make_world()
	_add_room(w, TileMapData.RoomType.WITCH)
	var medic := _pick_plain_adult(w)
	ok = _check(medic != null, "まじない医候補が見つかる") and ok
	if medic == null:
		return false
	medic.role = Goblin.Role.WITCH_DOCTOR
	medic.state = Goblin.State.WORK

	var patient := _pick_plain_adult(w, [medic.id])
	ok = _check(patient != null, "患者候補が見つかる") and ok
	if patient == null:
		return false
	patient.hp = patient.max_hp * 0.5
	patient.state = Goblin.State.SLEEP
	var nest_pos := w._room_slot(TileMapData.RoomType.NEST, patient.id)
	w._place(patient, nest_pos)
	ok = _check(w.map.room_type_at(patient.x, patient.y) == TileMapData.RoomType.NEST,
			"患者を寝床タイルへ配置できる") and ok

	w.herb = 100.0
	var hp_before := patient.hp
	var herb_before := w.herb
	w._step_medic()
	var gained := patient.hp - hp_before
	# _step_medic は加速ぶん (medic_heal_bonus_per_tick) のみを上乗せする (素の
	# hp_regen_per_tick は state_machine.step が別途処理するため、ここでは単独確認)。
	var expected := w.params.medic_heal_bonus_per_tick
	ok = _check(absf(gained - expected) < 1e-6,
			"加速ぶんが上乗せされる (got=%.6f expected=%.6f)" % [gained, expected]) and ok
	ok = _check(w.herb < herb_before, "herb を消費する") and ok

	# 比較: まじない医が居ない場合は素の hp_regen のみ。
	var w2 := _make_world()
	var patient2 := _pick_plain_adult(w2)
	patient2.hp = patient2.max_hp * 0.5
	patient2.state = Goblin.State.SLEEP
	w2._place(patient2, w2._room_slot(TileMapData.RoomType.NEST, patient2.id))
	var hp_before2 := patient2.hp
	w2._step_medic()  # まじない医が居ないので何もしない
	# state_machine 側の素の回復 (参考: tick_once 全体では掛かるが、ここでは _step_medic
	# のみを単独確認するため変化なしのはず)。
	ok = _check(absf(patient2.hp - hp_before2) < 1e-9,
			"まじない医が居なければ _step_medic は変化させない") and ok
	return ok

## ③ herb=0 なら加速なし (素の hp_regen のみ = 経済従属)。
func _test_no_acceleration_without_herb() -> bool:
	var ok := true
	var w := _make_world()
	_add_room(w, TileMapData.RoomType.WITCH)
	var medic := _pick_plain_adult(w)
	medic.role = Goblin.Role.WITCH_DOCTOR
	medic.state = Goblin.State.WORK

	var patient := _pick_plain_adult(w, [medic.id])
	patient.hp = patient.max_hp * 0.5
	patient.state = Goblin.State.SLEEP
	w._place(patient, w._room_slot(TileMapData.RoomType.NEST, patient.id))

	w.herb = 0.0
	var hp_before := patient.hp
	w._step_medic()
	var gained := patient.hp - hp_before
	ok = _check(absf(gained) < 1e-9,
			"herb=0 では _step_medic による加速はない (got=%.6f)" % gained) and ok
	ok = _check(w.herb == 0.0, "herb は負にならない") and ok
	return ok

## ④ 治療は herb を消費する (消費量が herb_per_medic_heal_per_tick と一致)。
func _test_heal_consumes_herb() -> bool:
	var ok := true
	var w := _make_world()
	_add_room(w, TileMapData.RoomType.WITCH)
	var medic := _pick_plain_adult(w)
	medic.role = Goblin.Role.WITCH_DOCTOR
	medic.state = Goblin.State.WORK

	var patient := _pick_plain_adult(w, [medic.id])
	patient.hp = patient.max_hp * 0.5
	patient.state = Goblin.State.SLEEP
	w._place(patient, w._room_slot(TileMapData.RoomType.NEST, patient.id))

	w.herb = 10.0
	w._step_medic()
	var consumed := 10.0 - w.herb
	ok = _check(absf(consumed - w.params.herb_per_medic_heal_per_tick) < 1e-6,
			"治療 1 件で herb_per_medic_heal_per_tick ぶん消費する (got=%.6f)" % consumed) and ok
	return ok

## ⑤ 交戦中、まじない医は防衛ライン (_defense_points) より後衛 (_medic_points) に控え、
## 前衛の白兵持ち場には出ない。
func _test_backline_during_combat() -> bool:
	var ok := true
	var w := _make_world(13)
	_add_room(w, TileMapData.RoomType.WITCH)
	var medic := _pick_plain_adult(w)
	ok = _check(medic != null, "まじない医候補が見つかる") and ok
	if medic == null:
		return false
	medic.role = Goblin.Role.WITCH_DOCTOR
	medic.state = Goblin.State.WORK
	w._place(medic, w._hall_slot(medic.id))

	# 交戦状態にし、戦線へ召集する経路 (_movement_target) を確認する。
	w.phase = World.Phase.COMBAT
	w._spawn_enemy_at_gate(0, false)

	var target := w._movement_target(medic, true, false)
	ok = _check(target != Vector2i(-1, -1), "後衛への移動目標が得られる") and ok
	ok = _check(not w._defense_points.has(target),
			"まじない医の持ち場は前衛の防衛ライン地点と一致しない") and ok
	ok = _check(w._medic_points.has(target) or w._totem_core.has(target),
			"まじない医の持ち場は後衛地点 (_medic_points) かその周辺である") and ok

	# ctx.assigned_to_combat 相当: WITCH_DOCTOR は COMBAT へ遷移しない (戦線に出ない)。
	for i in range(20):
		w.tick_once()
	ok = _check(medic.state != Goblin.State.COMBAT,
			"まじない医は COMBAT ステートへ遷移しない (got state=%d)" % medic.state) and ok
	return ok

## ⑥ 新規キャッシュ (_medic_points) を含む状態でも、スナップショット往復・
## 復元後 30 tick の決定性が成立する (KI-09)。
func _test_snapshot_roundtrip() -> bool:
	var ok := true
	var w := _make_world(21)
	_add_room(w, TileMapData.RoomType.WITCH)
	_add_room(w, TileMapData.RoomType.MUSHROOM)
	var medic := _pick_plain_adult(w)
	medic.role = Goblin.Role.WITCH_DOCTOR
	medic.state = Goblin.State.WORK
	w.herb = 5.0

	for i in range(40):
		w.tick_once()

	var snap := w.snapshot()
	var w2 := World.new()
	w2.setup(w.params)
	w2.restore(snap)
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(snap),
			"まじない医込みのスナップショット往復が一致する") and ok

	for i in range(30):
		w.tick_once()
		w2.tick_once()
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(w.snapshot()),
			"復元後 30 tick の決定性が一致する") and ok
	return ok
