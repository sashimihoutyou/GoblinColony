extends SceneTree
## 食料経済の検証 (food_economy_spec.md §5-2)。
##
## 実行: godot --headless --path Game --script res://scripts/test_food.gd

func _init() -> void:
	var ok := true
	ok = _test_steady_surplus() and ok
	ok = _test_active_rancher_accounting() and ok
	ok = _test_starvation_progression() and ok
	ok = _test_mite_relief() and ok
	ok = _test_instant_meal() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("FOOD_OK")
		quit(0)
	else:
		print("FOOD_FAIL")
		quit(1)

## ① 既定パラメータで平時を回すと在庫が慢性ゼロから脱し、終盤は黒字側へ寄る。
func _test_steady_surplus() -> bool:
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)
	var days := 15
	var positive_ticks := 0
	var total_ticks := 0
	var last_3_days_start := (days - 3) * p.ticks_per_day
	for i in range(days * p.ticks_per_day):
		w.tick_once()
		if i >= last_3_days_start:
			total_ticks += 1
			if w.food > 0.0:
				positive_ticks += 1
	var ratio := float(positive_ticks) / float(total_ticks)
	print("  steady-surplus: final food=%.2f, last-3-days positive ratio=%.2f" % [w.food, ratio])
	if ratio < 0.5:
		print("  FAIL: stock stays chronically empty in late game")
		return false
	return true

## ② 牧場で実際に WORK している個体のみが生産する (建て置き禁止)。
func _test_active_rancher_accounting() -> bool:
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)

	var ranch: Dictionary
	for r in w.map.rooms:
		if r.room_type == TileMapData.RoomType.RAT_RANCH:
			ranch = r
			break

	# 全割当ゴブリンを牧場の外で SLEEP させる -> 稼働なし。
	for gid in (ranch.assigned as Array):
		var g := w._goblin_by_id(int(gid))
		g.state = Goblin.State.SLEEP
		w._place(g, w.map.totem)
	w.food = float(w._alive_count()) + 10.0  # 救済床が作動しない水準
	var before := w.food
	w._step_food()
	if w.food != before:
		print("  FAIL: food changed with no active ranchers (got delta %.4f)" % (w.food - before))
		return false

	# 割当ゴブリンを牧場内に置き WORK させる -> 稼働数 × food_per_rancher_tick だけ増える。
	var active := 0
	for gid in (ranch.assigned as Array):
		var g := w._goblin_by_id(int(gid))
		g.state = Goblin.State.WORK
		w._place(g, Vector2i(ranch.x, ranch.y))
		active += 1
	before = w.food
	w._step_food()
	var expected := before + active * p.food_per_rancher_tick
	if absf(w.food - expected) > 1e-6:
		print("  FAIL: active rancher production mismatch (got %.4f, expected %.4f)" % [w.food, expected])
		return false
	print("  active-rancher-accounting: OK (active=%d)" % active)
	return true

## ④ 在庫0かつ空腹限界の個体は HP が単調減少し、やがて餓死する。
func _test_starvation_progression() -> bool:
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)
	w.food = 0.0
	for g in w.goblins:
		g.hunger = 1.0

	# 死亡対象として、ユニーク以外の1体を選ぶ。
	var target: Goblin = null
	for g in w.goblins:
		if not g.is_unique:
			target = g
			break
	if target == null:
		print("  FAIL: no non-unique goblin to test starvation on")
		return false

	var prev_hp := target.hp
	var died := false
	for i in range(2000):
		w.food = 0.0  # 救済床・牧場生産を無効化し続ける (純粋に餓死ロジックのみ検証)
		w._step_starvation()
		if target.hp > prev_hp:
			print("  FAIL: hp increased during starvation")
			return false
		prev_hp = target.hp
		if target.state == Goblin.State.DEAD:
			died = true
			break

	if not died:
		print("  FAIL: goblin did not starve to death")
		return false
	var found_event := false
	for g in w.goblins:
		if g.id == target.id:
			found_event = true
	# cleanup されていない時点で state==DEAD かつ death_logged が立っていることを確認。
	if target.state != Goblin.State.DEAD or not target.death_logged:
		print("  FAIL: starved goblin not marked DEAD/death_logged")
		return false
	print("  starvation-progression: OK (id=%d)" % target.id)
	return true

## ③ パン虫による救済: 巣内に自然湧きし、空腹個体が隣接で捕食する (在庫を減らさない)。
func _test_mite_relief() -> bool:
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)

	# (a) 多 tick 回すと上限を超えず、いずれ 1 匹以上湧く。
	var ever_spawned := false
	for i in range(20 * p.ticks_per_day):
		w._step_mites()
		if w.mites.size() > p.mite_max:
			print("  FAIL: mites exceeded mite_max (%d > %d)" % [w.mites.size(), p.mite_max])
			return false
		if w.mites.size() >= 1:
			ever_spawned = true
	if not ever_spawned:
		print("  FAIL: no mite ever spawned over many ticks")
		return false

	# (b) food=0・空腹 latched の対象個体の隣にパン虫を直接置き、_step_goblins 1 回で
	#     hunger==0・パン虫が消える・food は 0 のまま (在庫を減らさない) を検証。
	w.food = 0.0
	var target: Goblin = null
	for g in w.goblins:
		if not g.is_unique:
			if target == null:
				target = g
				continue
		g.hunger = 0.0          # 他個体は満腹化 (同 tick の競合を避ける)
		g.hunger_latched = false
	if target == null:
		print("  FAIL: no non-unique goblin for mite-eat test")
		return false
	target.hunger = 1.0
	target.hunger_latched = true
	# 既存のパン虫を一掃し、対象の隣に 1 匹だけ生成する (隣接判定を確定させる)。
	w.mites = []
	var mite := MiteUnit.new()
	mite.id = w.next_mite_id
	w.next_mite_id += 1
	w._place(mite, target.pos() + Vector2i(1, 0))
	w.mites.append(mite)
	w._step_goblins()
	if target.hunger != 0.0:
		print("  FAIL: hunger did not become 0 on mite eat (got %.4f)" % target.hunger)
		return false
	if not w.mites.is_empty():
		print("  FAIL: mite not consumed (remaining %d)" % w.mites.size())
		return false
	if w.food != 0.0:
		print("  FAIL: mite eat changed food stock (got %.4f, expected 0)" % w.food)
		return false

	# (c) 視界内にパン虫が居れば _movement_target は集積所でなくパン虫位置を返す。
	var hg: Goblin = null
	for g in w.goblins:
		if not g.is_unique:
			hg = g
			break
	hg.state = Goblin.State.HUNGRY
	# 集積所から十分離れた巣内床に置き、その視界内 (隣接でない位置) にパン虫を置く。
	w._place(hg, w._random_nest_floor())
	w.mites = []
	var mite2 := MiteUnit.new()
	mite2.id = w.next_mite_id
	w.next_mite_id += 1
	w._place(mite2, hg.pos() + Vector2i(3, 0))   # 視界内 (6) かつ非隣接
	w.mites.append(mite2)
	var tgt := w._movement_target(hg, false)
	if tgt != mite2.pos():
		print("  FAIL: hungry goblin did not target mite (got %s, expected %s)" % [tgt, mite2.pos()])
		return false
	print("  mite-relief: OK (spawned, eaten without stock loss, targeted)")
	return true

## ⑥ 食事は即時かつ一括消費 (集積所到着 tick で hunger=0、在庫は food_per_meal だけ減る)。
func _test_instant_meal() -> bool:
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)

	# 牧場の割当を空にして稼働ゼロにする (生産経路を完全に遮断)。
	for r in w.map.rooms:
		if r.room_type == TileMapData.RoomType.RAT_RANCH:
			r.assigned = []

	# 対象として、ユニーク以外の1体を選ぶ。それ以外は空腹を解除して
	# 同 tick に食事させない (在庫の差分を対象 1 体ぶんに限定する)。
	var target: Goblin = null
	for g in w.goblins:
		if not g.is_unique:
			if target == null:
				target = g
				continue
			g.hunger = 0.0
			g.hunger_latched = false

	if target == null:
		print("  FAIL: no non-unique goblin to test instant meal on")
		return false

	target.hunger = 1.0
	target.hunger_latched = true
	w._place(target, w._eat_slot(target.id))

	# 在庫が生存頭数を上回るようにし、消費後もパン虫の自然湧きが発生しないようにする。
	w.food = 20.0
	var before := w.food
	w._step_goblins()

	if target.hunger != 0.0:
		print("  FAIL: hunger did not become 0 on instant meal (got %.4f)" % target.hunger)
		return false
	var expected := before - p.food_per_meal
	if absf(w.food - expected) > 1e-6:
		print("  FAIL: food consumption mismatch (got %.4f, expected %.4f)" % [w.food, expected])
		return false
	print("  instant-meal: OK")
	return true

## ⑤ 食料・飢餓・牧場割当を含むスナップショット往復が一致する。
func _test_snapshot_roundtrip() -> bool:
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)
	for i in range(57):
		w.tick_once()
	# パン虫を 1 匹手動生成して mites に積み、パン虫込みの往復一致を検証する。
	var mite := MiteUnit.new()
	mite.id = w.next_mite_id
	w.next_mite_id += 1
	w._place(mite, w._random_nest_floor())
	w.mites.append(mite)
	var snap := w.snapshot()
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
	print("  snapshot-roundtrip: OK (food=%.2f)" % w.food)
	return true
