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
	ok = _test_night_sleep() and ok
	ok = _test_courtship_rendezvous() and ok
	ok = _test_forage_loop() and ok
	ok = _test_field_dispatch() and ok
	ok = _test_guard_alarm() and ok
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
	p.food_per_meal = 1.0
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
		print("  FAIL: hunger did not become 0 (instant meal) at storage")
		return false
	if w.food >= 1.0:
		print("  FAIL: food was not spent on the instant meal")
		return false
	print("  hungry-food-order: OK")
	return true

## 夜トリガー睡眠 + 睡眠 > 空腹の優先順位を検証する (§5)。
## Context を直接組んで StateMachine.step を呼ぶ (World を回さず力学だけを切り出す)。
func _test_night_sleep() -> bool:
	var p := SimParams.new()
	p.sleep_rate = 0.0   # 自然蓄積を止め、夜トリガーだけを切り分ける
	p.hunger_rate = 0.0

	# (a) 昼: 欲求なしの個体は SLEEP にならない (WORK か WANDER の受け皿)。
	var g_day := _fresh_goblin()
	var ctx_day := StateMachine.Context.new()
	ctx_day.is_night = false
	StateMachine.step(g_day, ctx_day, p)
	if g_day.state == Goblin.State.SLEEP:
		print("  FAIL: night-sleep (a) goblin slept during day with no sleepiness")
		return false

	# (b) 夜: 欲求なし (hunger=0) でも巣全体で就寝する。
	var g_night := _fresh_goblin()
	var ctx_night := StateMachine.Context.new()
	ctx_night.is_night = true
	StateMachine.step(g_night, ctx_night, p)
	if g_night.state != Goblin.State.SLEEP:
		print("  FAIL: night-sleep (b) goblin did not sleep at night (state=%d)" % g_night.state)
		return false

	# (c) 夜 + 空腹限界 (latched) でも睡眠が空腹に優先する。
	var g_hungry := _fresh_goblin()
	g_hungry.hunger = 1.0
	g_hungry.hunger_latched = true
	var ctx_hn := StateMachine.Context.new()
	ctx_hn.is_night = true
	ctx_hn.food_in_stock = true
	ctx_hn.food_available = true
	StateMachine.step(g_hungry, ctx_hn, p)
	if g_hungry.state != Goblin.State.SLEEP:
		print("  FAIL: night-sleep (c) hunger beat sleep at night (state=%d)" % g_hungry.state)
		return false

	# (d) 夜 + 交戦中 (sleepiness 低) では夜トリガーで寝ない (防衛輪を崩さない)。
	var g_raid := _fresh_goblin()
	g_raid.sleepiness = 0.0
	var ctx_raid := StateMachine.Context.new()
	ctx_raid.is_night = true
	ctx_raid.in_raid = true
	StateMachine.step(g_raid, ctx_raid, p)
	if g_raid.state == Goblin.State.SLEEP:
		print("  FAIL: night-sleep (d) goblin slept during raid at night")
		return false

	# (e) 夜入りで就寝 → ゲージが sleep_off まで抜けたら夜中でも起きる
	# (同じ夜に再ラッチしない)。sleep_rate=0 なので自然蓄積はなし。
	var g_wake := _fresh_goblin()
	g_wake.sleepiness = 0.5  # sleep_on (0.8) 未満だが夜トリガーで就寝する
	var ctx_wake := StateMachine.Context.new()
	ctx_wake.is_night = true
	ctx_wake.at_rest = true  # 寝床到着済み (ゲージ減少はここからの規約をテスト)
	StateMachine.step(g_wake, ctx_wake, p)
	if g_wake.state != Goblin.State.SLEEP:
		print("  FAIL: night-sleep (e) goblin did not enter sleep at night start")
		return false
	# sleep_relieve_per_tick ぶつ抜けて sleep_off (0.15) を下回るまで進める。
	var guard_e := 0
	while g_wake.state == Goblin.State.SLEEP and guard_e < 1000:
		StateMachine.step(g_wake, ctx_wake, p)
		guard_e += 1
	if g_wake.state == Goblin.State.SLEEP:
		print("  FAIL: night-sleep (e) goblin never woke up (guard exceeded)")
		return false
	if not g_wake.night_sleep_done:
		print("  FAIL: night-sleep (e) night_sleep_done not set after waking")
		return false
	# 起きた後、同じ夜のうちにもう一度ステップしても再ラッチしない。
	StateMachine.step(g_wake, ctx_wake, p)
	if g_wake.state == Goblin.State.SLEEP:
		print("  FAIL: night-sleep (e) goblin re-latched sleep within the same night")
		return false

	print("  night-sleep: OK")
	return true

## 欲求・恐怖・戦闘の割り込みに掛からない健康な無役成体。
func _fresh_goblin() -> Goblin:
	var g := Goblin.new()
	g.id = 1
	g.sex = Goblin.Sex.MALE
	g.state = Goblin.State.WANDER
	g.role = Goblin.Role.NONE
	g.hp = 10.0
	g.max_hp = 10.0
	g.hunger = 0.0
	g.hunger_latched = false
	g.sleepiness = 0.0
	g.sleep_latched = false
	return g

## キノコ採集ループ (T4) の決定論的検証。雌 1 体 + 生長済みスポット 1 つを用意し、
## 摘み取り → 集積所へ運搬 → food が forage_carry_value ぶん増えることを確認する。
func _test_forage_loop() -> bool:
	var p := SimParams.new()
	p.start_goblins = 1
	p.food_per_rancher_tick = 0.0
	p.hunger_rate = 0.0          # 空腹/睡眠の割り込みを抑えて採集だけを切り出す
	p.sleep_rate = 0.0
	p.accident_prob = 0.0        # 事故死で個体が消えないように
	p.fumble_prob = 0.0          # 転倒で取り落とさないように
	p.move_per_tick = 100.0      # 1 tick で到達できるよう十分速く
	var w := World.new()
	w.setup(p)
	w.food = 0.0
	# 唯一の個体を雌・無役・成体にし、スポットの真上に置く。
	var g := w.goblins[0] as Goblin
	g.sex = Goblin.Sex.FEMALE
	g.role = Goblin.Role.NONE
	g.is_unique = false
	g.child_born_tick = -1
	g.hunger = 0.0
	g.hunger_latched = false
	g.sleepiness = 0.0
	g.sleep_latched = false
	g.carrying_food = false
	# 部屋割当を外す (採集者条件: 役職 NONE・部屋未割当)。
	for r in w.map.rooms:
		(r.assigned as Array).clear()
	# スポットを 1 つだけ生長済みにし、他は再生長中にして対象を一意にする。
	if w.map.forage_spots.is_empty():
		print("  FAIL: forage — no forage spots on map")
		return false
	for i in range(w.map.forage_regrow.size()):
		w.map.forage_regrow[i] = p.forage_regrow_ticks
	w.map.forage_regrow[0] = 0
	var spot: Vector2i = w.map.forage_spots[0]
	w._place(g, spot)
	# 摘み取り: スポット上で 1 tick 回すと carrying_food になり、スポットが再生長へ。
	w.tick_once()
	if not g.carrying_food:
		print("  FAIL: forage — female did not pick mushroom on the spot")
		return false
	if w.map.forage_regrow[0] <= 0:
		print("  FAIL: forage — picked spot did not enter regrow")
		return false
	var food_before: float = w.food
	# 運搬: 集積所まで回す (毎 tick 集積所へ向かう。move 100 で数 tick)。
	var guard := 0
	while g.carrying_food and guard < 200:
		w.tick_once()
		guard += 1
	if g.carrying_food:
		print("  FAIL: forage — carrier never reached storage (guard exceeded)")
		return false
	if w.food < food_before + p.forage_carry_value - 0.001:
		print("  FAIL: forage — food did not increase by carry value (%.2f → %.2f)" % [
			food_before, w.food])
		return false
	print("  forage-loop: OK (food %.1f → %.1f)" % [food_before, w.food])
	return true

## 巣外の出現物 + 派遣 (§11.5) の決定論的検証。
##  (1) 派遣 2 体が巣口を抜けて摘み取り → 集積所運搬で food が収量ぶん増える
##  (2) 取り尽くしで出現物が消え、配達後に派遣が解除される
##  (3) 夜になると未回収の出現物が消え、非運搬の派遣も解除される
func _test_field_dispatch() -> bool:
	var p := SimParams.new()
	p.start_goblins = 4
	p.food_per_rancher_tick = 0.0
	p.hunger_rate = 0.0          # 空腹/睡眠/求愛の割り込みを抑えて派遣だけを切り出す
	p.sleep_rate = 0.0
	p.accident_prob = 0.0
	p.fumble_prob = 0.0
	p.court_base_chance = 0.0
	p.field_spawn_per_tick = 0.0  # 自然湧きを止め、テストが置いた 1 つに限定
	p.move_per_tick = 100.0
	var w := World.new()
	w.setup(p)
	w.food = 0.0
	# 全員を手すきの成体にする (役職・部屋割当・採集仕事を外す)。
	for r in w.map.rooms:
		(r.assigned as Array).clear()
	for g in w.goblins:
		g.role = Goblin.Role.NONE
		g.is_unique = false
		g.child_born_tick = -1
		g.hunger = 0.0
		g.hunger_latched = false
		g.sleepiness = 0.0
		g.sleep_latched = false
	for i in range(w.map.forage_regrow.size()):
		w.map.forage_regrow[i] = p.forage_regrow_ticks
	# 出現物を直接置く (湧き抽選と同じタイル選択を使う)。
	var pos := w._field_spawn_tile()
	if pos == Vector2i(-1, -1):
		print("  FAIL: field — no reachable exterior spawn tile")
		return false
	var f := FieldResource.new()
	f.id = w.next_field_id
	w.next_field_id += 1
	f.x = pos.x
	f.y = pos.y
	f.amount = 2
	w.field_resources.append(f)
	# (1)(2) 2 体派遣 → 収量 2 食が集積所に届き、出現物が消える。
	if w.dispatch_to_field(f.id, 2) != 2:
		print("  FAIL: field — could not dispatch 2 goblins")
		return false
	var guard := 0
	while w.food < 2.0 - 0.001 and guard < 500:
		w.tick_once()
		guard += 1
	if w.food < 2.0 - 0.001:
		print("  FAIL: field — hauled food did not reach 2.0 (food=%.2f)" % w.food)
		return false
	if w._field_by_id(f.id) != null:
		print("  FAIL: field — depleted resource was not removed")
		return false
	# 配達と解除の後始末が済むまで少し回す。
	for i in range(30):
		w.tick_once()
	for g in w.goblins:
		if g.dispatch_id != -1 or g.carrying_food:
			print("  FAIL: field — goblin %d still dispatched/carrying after depletion" % g.id)
			return false
	# (3) 夜の店じまい: 出現物 + 非運搬の派遣を置いて夜の tick を 1 回回す。
	var f2 := FieldResource.new()
	f2.id = w.next_field_id
	w.next_field_id += 1
	f2.x = pos.x
	f2.y = pos.y
	f2.amount = 2
	w.field_resources.append(f2)
	var g0 := w.goblins[0] as Goblin
	g0.dispatch_id = f2.id
	w.tick = p.day_ticks  # 次の tick_once で夜に入る (日境界はまたがない)
	w.tick_once()
	if not w.field_resources.is_empty():
		print("  FAIL: field — resource survived nightfall")
		return false
	if g0.dispatch_id != -1:
		print("  FAIL: field — dispatch not recalled at nightfall")
		return false
	print("  field-dispatch: OK (food %.1f, guard=%d)" % [w.food, guard])
	return true

## 警報 (T5) の決定論的検証。就寝中の個体 + 巣内の敵 + 生存見張りを用意し、
## _step_guard_alarm で alarm イベントが出て、全個体の sleep_latched が解除されることを確認する。
func _test_guard_alarm() -> bool:
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)
	# 見張りが少なくとも 1 体居ること (setup で任命済み)。
	var guard_g: Goblin = null
	for g in w.goblins:
		if g.role == Goblin.Role.GUARD:
			guard_g = g
			break
	if guard_g == null:
		print("  FAIL: alarm — no guard appointed at setup")
		return false
	# 全個体を就寝ラッチ状態に。
	for g in w.goblins:
		g.sleep_latched = true
		g.night_sleep_done = false
	# 交戦フェーズにし、巣内 (トーテム隣) に敵を 1 体置き、見張りの隣に寄せる。
	w.phase = World.Phase.COMBAT
	w.alarm_raised = false
	var e := EnemyUnit.new()
	e.id = 9000
	e.max_hp = p.enemy_hp
	e.hp = e.max_hp
	w._place(e, guard_g.pos())  # 見張りと同タイル = チェビシェフ距離 0 (8 以内)
	# 念のため巣内であることを確認 (見張りの持ち場は巣内のはず)。
	if not w._inside_nest(e.pos()):
		w._place(e, w.map.totem)
		w._place(guard_g, w.map.totem)
	w.enemies = [e]
	# 見張りは起きている状態に (SLEEP/DEAD/KNOCKED_OUT 以外)。
	guard_g.state = Goblin.State.WORK
	guard_g.sleep_latched = false
	w.last_events.clear()
	w._step_guard_alarm()
	# alarm イベントが出たか。
	var alarmed := false
	for ev in w.last_events:
		if ev.get("t", "") == "alarm":
			alarmed = true
			break
	if not alarmed:
		print("  FAIL: alarm — no alarm event raised by guard near intruder")
		return false
	if not w.alarm_raised:
		print("  FAIL: alarm — alarm_raised flag not set")
		return false
	# 全生存個体の sleep_latched が解除されたか (叩き起こし)。
	for g in w.goblins:
		if g.state == Goblin.State.DEAD:
			continue
		if g.sleep_latched:
			print("  FAIL: alarm — goblin %d still sleep_latched after alarm" % g.id)
			return false
	# 1 襲撃 1 回: もう一度呼んでも二重発火しない。
	w.last_events.clear()
	w._step_guard_alarm()
	for ev in w.last_events:
		if ev.get("t", "") == "alarm":
			print("  FAIL: alarm — alarm fired twice in one raid")
			return false
	print("  guard-alarm: OK")
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
	# 求愛ランデブー化後も増殖が止まらないこと (births_total > 0)。
	if w.births_total <= 0:
		print("  FAIL: no births over the whole run (breeding stalled)")
		return false
	return true

## 求愛ランデブー (§3-6) の決定論的検証。雌雄 1 組に courting_id を相互設定し、
##  (1) NEST 部屋で隣接した tick 以降に妊娠が成立する
##  (2) 遠く離れたままだとタイムアウトで静かに解散する
## の 2 ケースをシード固定で確認する。
func _test_courtship_rendezvous() -> bool:
	# (1) 寝床で合流 → 妊娠。
	var p := SimParams.new()
	var w := World.new()
	w.setup(p)
	var nest := _find_nest_tile(w.map)
	if nest == Vector2i(-1, -1):
		print("  FAIL: courtship — no NEST floor tile found")
		return false
	var pair := _pick_pair(w)
	if pair.is_empty():
		print("  FAIL: courtship — could not find a female+male pair")
		return false
	var f: Goblin = pair[0]
	var m: Goblin = pair[1]
	# 妊娠・求愛以外の割り込み (空腹/睡眠/恐怖) を抑えて力学を切り出す。
	for g in w.goblins:
		g.hunger = 0.0
		g.hunger_latched = false
		g.sleepiness = 0.0
	f.pregnant = false
	f.courting_id = m.id
	f.court_ticks = 0
	m.courting_id = f.id
	m.court_ticks = 0
	# 両者を寝床の同一タイルに隣接配置。
	w._place(f, nest)
	w._place(m, nest)
	w._step_courtship()
	if not f.pregnant:
		print("  FAIL: courtship (1) — adjacent-in-nest pair did not conceive")
		return false
	if f.courting_id != -1 or m.courting_id != -1:
		print("  FAIL: courtship (1) — courting not cleared after conception")
		return false
	if f.mate_id != m.id:
		print("  FAIL: courtship (1) — mate_id not recorded")
		return false

	# (2) 離れたまま → タイムアウト解散。
	var w2 := World.new()
	w2.setup(p)
	var pair2 := _pick_pair(w2)
	var f2: Goblin = pair2[0]
	var m2: Goblin = pair2[1]
	for g in w2.goblins:
		g.hunger = 0.0
		g.hunger_latched = false
		g.sleepiness = 0.0
	f2.pregnant = false
	f2.courting_id = m2.id
	f2.court_ticks = 0
	m2.courting_id = f2.id
	m2.court_ticks = 0
	# 雌を NEST、雄を遠く (集積所付近) に固定し、毎 tick 引き離して合流させない。
	var far := w2.map.storage
	var guard := 0
	var dissolved := false
	while guard <= p.court_timeout_ticks + 2:
		w2._place(f2, nest)
		w2._place(m2, far)
		w2._step_courtship()
		if f2.courting_id == -1 and m2.courting_id == -1:
			dissolved = true
			break
		guard += 1
	if not dissolved:
		print("  FAIL: courtship (2) — distant pair never timed out")
		return false
	if f2.pregnant:
		print("  FAIL: courtship (2) — distant pair conceived without meeting")
		return false
	if guard <= p.court_timeout_ticks:
		print("  FAIL: courtship (2) — dissolved too early (guard=%d, timeout=%d)" % [
			guard, p.court_timeout_ticks])
		return false

	print("  courtship-rendezvous: OK")
	return true

## NEST 部屋の歩行可能な床タイルを 1 つ返す (なければ (-1,-1))。
func _find_nest_tile(m) -> Vector2i:
	for r in m.rooms:
		if r.room_type != TileMapData.RoomType.NEST:
			continue
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				if m.is_walkable(x, y) and m.room_type_at(x, y) == TileMapData.RoomType.NEST:
					return Vector2i(x, y)
	return Vector2i(-1, -1)

## 初期個体から成体の雌・雄を 1 体ずつ拾う ([f, m])。見つからなければ空配列。
func _pick_pair(w) -> Array:
	var f: Goblin = null
	var m: Goblin = null
	for g in w.goblins:
		if g.is_child():
			continue
		if g.sex == Goblin.Sex.FEMALE and f == null:
			f = g
		elif g.sex == Goblin.Sex.MALE and m == null:
			m = g
	if f == null or m == null:
		return []
	return [f, m]

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
