extends SceneTree
## 工房 (§7/B6) + 装備経済 (§3-16/§14.5.6/B8) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_workshops.gd
##   - キノコ農園で稼働個体が薬草を生産 / 泥鍛冶屋で装備を生産 (建て置きは不生産)。
##   - 建てた工房へ日境界で自動配員される (牧場と取り合わない)。
##   - 襲撃開始で未装備の戦闘員が共有在庫から武装し、在庫が尽きたら素手。
##   - 襲撃終了で装備が一定確率で消耗する。
##   - 資源 (herb/equipment) のスナップショット往復。

func _init() -> void:
	var ok := true
	ok = _test_mushroom_herb() and ok
	ok = _test_smithy_equipment() and ok
	ok = _test_idle_room_no_production() and ok
	ok = _test_auto_staffing() and ok
	ok = _test_equip_from_stock() and ok
	ok = _test_equip_wear() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("WORKSHOPS_OK")
		quit(0)
	else:
		print("WORKSHOPS_FAIL")
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

## 指定タイプの部屋を 1 つマップに直接生やす (建築フローは test_jobs で検証済み)。
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

## 部屋に 1 体を配属し、部屋内で WORK させて稼働状態を作る。
func _put_worker(w: World, r: Dictionary) -> Goblin:
	for g in w.goblins:
		if g.role == Goblin.Role.NONE and not g.is_unique and not g.is_child() \
				and not w._has_room_assignment(g.id):
			r.assigned.append(g.id)
			g.state = Goblin.State.WORK
			w._place(g, Vector2i(r.x, r.y))
			return g
	return null

func _test_mushroom_herb() -> bool:
	var ok := true
	var w := _make_world()
	var r := _add_room(w, TileMapData.RoomType.MUSHROOM)
	ok = _check(not r.is_empty(), "キノコ農園を設置できる") and ok
	var worker := _put_worker(w, r)
	ok = _check(worker != null, "農園に稼働個体を置ける") and ok
	var before := w.herb
	w._step_workshops()
	ok = _check(absf(w.herb - (before + w.params.herb_per_farmer_tick)) < 1e-6,
			"稼働 1 体ぶんの薬草が増える") and ok
	return ok

func _test_smithy_equipment() -> bool:
	var ok := true
	var w := _make_world()
	var r := _add_room(w, TileMapData.RoomType.SMITHY)
	ok = _check(not r.is_empty(), "泥鍛冶屋を設置できる") and ok
	var worker := _put_worker(w, r)
	ok = _check(worker != null, "鍛冶屋に稼働個体を置ける") and ok
	var before := w.equipment
	w._step_workshops()
	ok = _check(absf(w.equipment - (before + w.params.equip_per_smith_tick)) < 1e-6,
			"稼働 1 体ぶんの装備が増える") and ok
	return ok

## 配属はあるが部屋内で WORK していない (建て置き) なら生産しない。
func _test_idle_room_no_production() -> bool:
	var ok := true
	var w := _make_world()
	var r := _add_room(w, TileMapData.RoomType.SMITHY)
	var worker := _put_worker(w, r)
	worker.state = Goblin.State.SLEEP  # 稼働でない
	w._place(worker, w.map.totem)        # 部屋の外
	var before := w.equipment
	w._step_workshops()
	ok = _check(absf(w.equipment - before) < 1e-6, "建て置き (非稼働) は生産しない") and ok
	return ok

## 建てた工房へ日境界で自動配員される (牧場と取り合わない)。
func _test_auto_staffing() -> bool:
	var ok := true
	var w := _make_world()
	var r := _add_room(w, TileMapData.RoomType.MUSHROOM)
	w._staff_workshops()
	ok = _check((r.assigned as Array).size() >= 1, "工房に自動配員される") and ok
	# 配員された個体は牧場のプールに混ざらない (取り合い防止)。
	for gid in (r.assigned as Array):
		ok = _check(w._in_workshop(int(gid)), "工房員は _in_workshop で識別される") and ok
	# 牧場の割当と工房の割当が重複しない。
	var ranch_ids: Array = []
	for rr in w.map.rooms:
		if rr.room_type == TileMapData.RoomType.RAT_RANCH:
			ranch_ids = rr.assigned
	for gid in (r.assigned as Array):
		ok = _check(not (gid in ranch_ids), "工房員が牧場にも入っていない") and ok
	return ok

## 襲撃開始で未装備の戦闘員が共有在庫から武装し、在庫が尽きたら素手。
func _test_equip_from_stock() -> bool:
	var ok := true
	var w := _make_world()
	# 戦闘員 (雄/ユニーク成体) を数える。
	var fighters := 0
	for g in w.goblins:
		if (g.sex == Goblin.Sex.MALE or g.is_unique) and not g.is_child():
			fighters += 1
	ok = _check(fighters >= 2, "戦闘員が複数いる (前提)") and ok
	# 在庫を戦闘員より 1 少なく与える → 1 体は素手で残る。
	w.equipment = float(fighters - 1)
	w._equip_fighters_from_stock()
	var equipped := 0
	for g in w.goblins:
		if g.equipped:
			equipped += 1
	ok = _check(equipped == fighters - 1, "在庫ぶんだけ武装する (%d/%d)" % [equipped, fighters]) and ok
	ok = _check(absf(w.equipment) < 1e-6, "在庫を使い切る") and ok
	# もう一度呼んでも増えない (既装備は再取得しない・在庫0)。
	w._equip_fighters_from_stock()
	var equipped2 := 0
	for g in w.goblins:
		if g.equipped:
			equipped2 += 1
	ok = _check(equipped2 == equipped, "在庫0では追加武装しない") and ok
	return ok

## 襲撃終了で装備が消耗しうる (確率1で必ず外れることを確認)。
func _test_equip_wear() -> bool:
	var ok := true
	var w := _make_world()
	w.params.equip_wear_chance = 1.0  # 必ず壊れる
	for g in w.goblins:
		if (g.sex == Goblin.Sex.MALE or g.is_unique) and not g.is_child():
			g.equipped = true
	w.phase = World.Phase.COMBAT
	w.raid_start_hp = w._total_hp()
	w._end_raid()  # enemies 空なので終了処理が走る
	var still := 0
	for g in w.goblins:
		if g.equipped:
			still += 1
	ok = _check(still == 0, "消耗確率1で全装備が外れる") and ok
	return ok

func _test_snapshot_roundtrip() -> bool:
	var ok := true
	var w := _make_world(11)
	_add_room(w, TileMapData.RoomType.MUSHROOM)
	_add_room(w, TileMapData.RoomType.SMITHY)
	w.herb = 5.0
	w.equipment = 3.0
	for i in range(40):
		w.tick_once()
	var snap := w.snapshot()
	var w2 := World.new()
	w2.setup(w.params)
	w2.restore(snap)
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(snap),
			"工房/資源込みの往復が一致する") and ok
	for i in range(30):
		w.tick_once()
		w2.tick_once()
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(w.snapshot()),
			"復元後 30 tick の決定性が一致する") and ok
	return ok
