extends SceneTree
## §11.5 昼の外征の完全実装 (A4) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_expedition.gd
##   - 出現テーブル: 7 種別 (FORAGE/ANIMAL/TRAVELER/WANDERER/CAMP/RUINS/MAIDEN) が
##     既定の重みで全て出現しうる。距離 (近い/遠い) はタイル位置から決定的に導出。
##   - 種別ごとのリターン: RUINS→mud(+gems)、ANIMAL→food(+捕虜)。
##   - CAMP: 人数が勝率に効く (単調)。敗北は HP 減のみ (死亡なし)。装備消費。
##   - WANDERER: 部族差のある加入確率で +1 頭数。
##   - MAIDEN/アミナ装置: 保持→懐き予兆→JOINED (amina_joined)。harm で CLOSED。
##   - 遠い出現物はマップ縁寄りに located。
##   - FORAGE ベースライン不変 (field_kind_weights を全 FORAGE にしても挙動同一)。
##   - 新フィールド込みのスナップショット往復 + 復元後 30 tick 決定性。

func _init() -> void:
	var ok := true
	ok = _test_kind_spawn_table() and ok
	ok = _test_distance_far_near() and ok
	ok = _test_forage_baseline_unchanged() and ok
	ok = _test_ruins_returns() and ok
	ok = _test_animal_returns() and ok
	ok = _test_wanderer_join() and ok
	ok = _test_camp_combat() and ok
	ok = _test_traveler_trade() and ok
	ok = _test_amina_device() and ok
	ok = _test_amina_closed_by_harm() and ok
	ok = _test_delayed_reinforcement() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("EXPEDITION_OK")
		quit(0)
	else:
		print("EXPEDITION_FAIL")
		quit(1)

func _make_world(seed_v: int = 7, diff: int = 1) -> World:
	var p := SimParams.new()
	p.seed = seed_v
	var w := World.new()
	w.difficulty = diff
	w.setup(p)
	return w

func _check(cond: bool, label: String) -> bool:
	if not cond:
		printerr("  NG: " + label)
	return cond

## 男性成体 (役職 NONE・部屋未割当) を 1 体取得する。
func _male_adult(w: World) -> Goblin:
	for g in w.goblins:
		if g.sex == Goblin.Sex.MALE and not g.is_child() and g.role == Goblin.Role.NONE:
			return g
	return null

## 出現物を 1 個、指定 kind/distance/tribe で世界に直接置く (RNG を消費しない)。
## 巣口近傍に置き、到着までの A* が確実に通るようにする。
func _spawn_field(w: World, kind: int, distance: int = 0, tribe: String = "", amount: int = 3) -> FieldResource:
	var f := FieldResource.new()
	f.id = w.next_field_id
	w.next_field_id += 1
	var tiles: Array = w._field_tiles_far if distance == 1 else w._field_tiles_near
	if tiles.is_empty():
		tiles = w._field_tiles
	var p: Vector2i = tiles[0]
	f.x = p.x
	f.y = p.y
	f.amount = amount
	f.kind = kind
	f.distance = distance
	f.tribe = tribe
	w.field_resources.append(f)
	return f

## 出現物の位置まで goblin を運び、到着判定 (dispatch_target) が発火するまで
## tick_once を進める (最大 max_ticks)。日中・PEACE のままにする。
## FORAGE/ANIMAL/RUINS は採取後も集積所への配達が残るため、g_id の
## carrying_food/dispatch_id が両方解消されるまで待つ (一発勝負型はその時点で
## 既に field_resources からも消えている)。戻り値は配達完了までに観測した
## last_events を結合した配列 (field_haul/field_captive/field_gem 等を
## 呼び出し側で検査するため。他個体のイベントも混ざるが id で絞って使う)。
## 夜入り・タイムアウトで未解決の場合は null を返す。
func _run_until_resolved(w: World, f_id: int, g_id: int = -1, max_ticks: int = 400):
	var events: Array = []
	for i in range(max_ticks):
		var f_done := w._field_by_id(f_id) == null
		var g_done := true
		if g_id >= 0:
			var g := w._goblin_by_id(g_id)
			g_done = g == null or (not g.carrying_food and g.dispatch_id < 0)
		if f_done and g_done:
			return events
		w.tick_once()
		events.append_array(w.last_events)
		# 解決完了の tick で日没を跨いでも、その tick 内の処理 (配達等) は
		# 既に完了している。解決済みなら夜入りでも失敗にしない。
		var f_done2 := w._field_by_id(f_id) == null
		var g_done2 := true
		if g_id >= 0:
			var g2 := w._goblin_by_id(g_id)
			g_done2 = g2 == null or (not g2.carrying_food and g2.dispatch_id < 0)
		if f_done2 and g_done2:
			return events
		if not w.is_day():
			return null  # 夜入りで未回収は消える (このテストでは失敗扱い)
	return null

## (a) 既定の重みで 7 種別すべてが出現しうる (出現テーブルの健全性チェック)。
## _roll_field_kind() は累積和に対する 1 回の next_float() のみで決まる
## (rng 消費順序は _step_field 側の都合なので、ここでは _roll_field_kind() 自体を
## 直接多数回呼び、既定重み (合計 1.0、MAIDEN=0.02) でも 7 種別すべてが
## 出現しうることを確認する (実際の湧き頻度は別途 field_spawn_per_tick が決める)。
func _test_kind_spawn_table() -> bool:
	var ok := true
	var w := _make_world(7, 1)
	var counts := {}
	for i in range(20000):
		var k := w._roll_field_kind()
		counts[k] = counts.get(k, 0) + 1
	for k in range(7):
		ok = _check(counts.get(k, 0) > 0, "種別 %d が出現テーブルから出現する" % k) and ok
	return ok

## (f) 遠い候補は近い候補よりマップ縁 (巣口から遠い) に位置する。
func _test_distance_far_near() -> bool:
	var ok := true
	var w := _make_world(7, 1)
	ok = _check(not w._field_tiles_far.is_empty(), "遠い候補タイルが存在する") and ok
	ok = _check(not w._field_tiles_near.is_empty(), "近い候補タイルが存在する") and ok
	# 遠い候補は全て field_far_min_gate_dist 以上の巣口距離を持つ。
	var p := w.params
	for t in w._field_tiles_far:
		var min_gate_dist := 999999
		for gp in w.map.gates:
			min_gate_dist = mini(min_gate_dist, maxi(absi(t.x - gp.x), absi(t.y - gp.y)))
		ok = _check(min_gate_dist >= p.field_far_min_gate_dist,
				"遠い候補タイルは巣口から十分離れている") and ok
	for t in w._field_tiles_near:
		var min_gate_dist := 999999
		for gp in w.map.gates:
			min_gate_dist = mini(min_gate_dist, maxi(absi(t.x - gp.x), absi(t.y - gp.y)))
		ok = _check(min_gate_dist < p.field_far_min_gate_dist,
				"近い候補タイルは巣口から近い") and ok
	return ok

## (d) FORAGE ベースライン不変: field_kind_weights を全 FORAGE にすると、
## 種別抽選ロールが追加されても f.kind は常に FORAGE になり、distance も
## タイル位置から決定的に導出されるだけで FORAGE の往復挙動 (food 加算) は
## 変わらない。さらに、種別抽選の追加ロールが既存の RNG 消費順序 (湧き判定→
## タイル抽選→収量) の後に来ることを、湧き判定の発火タイミング自体が
## 重み設定に依らず一致することで確認する。
func _test_forage_baseline_unchanged() -> bool:
	var ok := true
	var w1 := _make_world(7, 1)  # 既定の重み (FORAGE 含む混合)
	var w2 := _make_world(7, 1)
	w2.params.field_kind_weights = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]  # 全 FORAGE
	# 両方とも同じ seed なので、湧き判定の発火 tick・タイル・amount は一致する
	# はず (種別抽選は湧き判定/タイル抽選/amount の後の追加ロールのため)。
	var spawn1: Array = []
	var spawn2: Array = []
	for i in range(200):
		w1.tick_once()
		w2.tick_once()
		for e in w1.last_events:
			if e.t == "field_spawn":
				spawn1.append({"x": e.x, "y": e.y, "amount": e.amount, "distance": e.distance})
		for e in w2.last_events:
			if e.t == "field_spawn":
				spawn2.append({"x": e.x, "y": e.y, "amount": e.amount, "distance": e.distance})
				ok = _check(int(e.kind) == FieldResource.Kind.FORAGE,
						"全 FORAGE 設定では kind は常に FORAGE") and ok
	ok = _check(spawn1.size() == spawn2.size() and spawn1.size() > 0,
			"湧き判定の発火タイミングは重み設定に依らず一致する (件数)") and ok
	var n: int = mini(spawn1.size(), spawn2.size())
	for i in range(n):
		ok = _check(JSON.stringify(spawn1[i]) == JSON.stringify(spawn2[i]),
				"湧き判定の x/y/amount/distance が一致する (RNG 消費順序不変)") and ok
	# FORAGE の往復: 出現物を 1 個直接置き、派遣→運搬→配達で food が
	# field_carry_value ぶん増える (旧仕様どおり)。
	var w3 := _make_world(7, 1)
	var f := _spawn_field(w3, FieldResource.Kind.FORAGE, 0, "", 1)
	var g := _male_adult(w3)
	ok = _check(g != null, "FORAGE テスト用の男性成体が見つかる") and ok
	g.dispatch_id = f.id
	var food_before := w3.food
	var events = _run_until_resolved(w3, f.id, g.id)
	ok = _check(events != null, "FORAGE 出現物が回収されて配達される") and ok
	var haul: Dictionary = {}
	if events != null:
		for e in events:
			if e.t == "field_haul" and e.id == g.id:
				haul = e
	ok = _check(not haul.is_empty() and int(haul.kind) == FieldResource.Kind.FORAGE,
			"FORAGE の field_haul イベントが発火する (kind=FORAGE)") and ok
	ok = _check(w3.food >= food_before + w3.params.field_carry_value - 1e-6,
			"FORAGE 回収で food が field_carry_value ぶん以上増える (旧仕様どおり)") and ok
	return ok

## (b) RUINS → mud (+ 低確率 gems)。
func _test_ruins_returns() -> bool:
	var ok := true
	var w := _make_world(3, 1)
	# amount=1 だと採取の瞬間に field_resources.erase() されてしまい、配達時に
	# _field_by_id が null を返して f.kind が分からなくなる (_deliver_field_carry
	# の null フォールバック = FORAGE 扱い)。kind を確実に観測するため amount>=2。
	var f := _spawn_field(w, FieldResource.Kind.RUINS, 0, "", 2)
	var g := _male_adult(w)
	ok = _check(g != null, "RUINS テスト用の男性成体が見つかる") and ok
	g.dispatch_id = f.id
	var mud_before := w.mud
	var events = _run_until_resolved(w, f.id, g.id)
	ok = _check(events != null, "RUINS 出現物が回収されて配達される") and ok
	var haul: Dictionary = {}
	if events != null:
		for e in events:
			if e.t == "field_haul" and e.id == g.id:
				haul = e
	ok = _check(not haul.is_empty() and int(haul.kind) == FieldResource.Kind.RUINS,
			"RUINS の field_haul イベントが発火する (kind=RUINS)") and ok
	ok = _check(w.mud >= mud_before + w.params.field_ruins_mud_value - 1e-6,
			"RUINS 回収で mud が field_ruins_mud_value ぶん以上増える") and ok
	return ok

## (b) ANIMAL → food(多め) + 低確率で goblin 捕虜。捕虜が出るまで複数試行する。
func _test_animal_returns() -> bool:
	var ok := true
	var got_food_bonus := false
	var got_captive := false
	for trial in range(40):
		var w := _make_world(100 + trial, 1)
		var f := _spawn_field(w, FieldResource.Kind.ANIMAL, 0, "", 2)  # amount>=2 (RUINS と同じ理由)
		var g := _male_adult(w)
		if g == null:
			continue
		g.dispatch_id = f.id
		var food_before := w.food
		var cap_before := w.cap_male_goblin
		var events = _run_until_resolved(w, f.id, g.id)
		if events == null:
			continue
		var haul: Dictionary = {}
		for e in events:
			if e.t == "field_haul" and e.id == g.id:
				haul = e
		if not haul.is_empty() and int(haul.kind) == FieldResource.Kind.ANIMAL \
				and w.food >= food_before + w.params.field_animal_carry_value - 1e-6:
			got_food_bonus = true
		if w.cap_male_goblin > cap_before:
			got_captive = true
		if got_food_bonus and got_captive:
			break
	ok = _check(got_food_bonus, "ANIMAL 回収で food が field_animal_carry_value ぶん増える") and ok
	ok = _check(got_captive, "ANIMAL 回収で低確率に goblin 捕虜が増える (複数試行)") and ok
	return ok

## (e) WANDERER: 部族差のある加入確率で +1 頭数 (bunta は高確率、kugyo は低確率)。
func _test_wanderer_join() -> bool:
	var ok := true
	var bunta_joins := 0
	var kugyo_joins := 0
	var trials := 30
	for trial in range(trials):
		var wb := _make_world(200 + trial, 1)
		var fb := _spawn_field(wb, FieldResource.Kind.WANDERER, 0, "bunta", 1)
		var gb := _male_adult(wb)
		if gb != null:
			var before := wb.goblins.size()
			gb.dispatch_id = fb.id
			if _run_until_resolved(wb, fb.id) != null and wb.goblins.size() > before:
				bunta_joins += 1
		var wk := _make_world(300 + trial, 1)
		var fk := _spawn_field(wk, FieldResource.Kind.WANDERER, 0, "kugyo", 1)
		var gk := _male_adult(wk)
		if gk != null:
			var before2 := wk.goblins.size()
			gk.dispatch_id = fk.id
			if _run_until_resolved(wk, fk.id) != null and wk.goblins.size() > before2:
				kugyo_joins += 1
	ok = _check(bunta_joins > kugyo_joins,
			"bunta 出身の放浪者は kugyo より加入率が高い (%d vs %d / %d 試行)" % [bunta_joins, kugyo_joins, trials]) and ok
	ok = _check(bunta_joins >= trials / 2,
			"bunta 出身の放浪者は概ね加入する (%d/%d)" % [bunta_joins, trials]) and ok
	return ok

## (c) CAMP: 人数が勝率に単調に効く。敗北は HP 減のみ (死亡なし)。装備消費。
func _test_camp_combat() -> bool:
	var ok := true
	var trials := 60
	var wins_1 := 0
	var wins_5 := 0
	for trial in range(trials):
		# 1 体のみ派遣。
		var w1 := _make_world(400 + trial, 1)
		var f1 := _spawn_field(w1, FieldResource.Kind.CAMP, 0, "", 0)
		var males1: Array = []
		for g in w1.goblins:
			if g.sex == Goblin.Sex.MALE and not g.is_child() and g.role == Goblin.Role.NONE:
				males1.append(g)
		if males1.size() < 1:
			continue
		var hurt1: Goblin = males1[0]
		var hp_before: float = hurt1.hp
		hurt1.dispatch_id = f1.id
		w1._equip_dispatched(f1.id)
		var gems_before1 := w1.gems
		_run_until_resolved(w1, f1.id)
		if w1.gems > gems_before1:
			wins_1 += 1
		else:
			# 敗北: HP は減るが死亡しない。
			ok = _check(hurt1.hp < hp_before, "CAMP 敗北で HP が減る") and ok
			ok = _check(hurt1.state != Goblin.State.DEAD, "CAMP 敗北で死亡しない (§0)") and ok
			ok = _check(hurt1.hp >= 1.0, "CAMP 敗北の HP は 1.0 未満にならない (即・致命にしない)") and ok

		# 多数 (5 体) 派遣。
		var w5 := _make_world(400 + trial, 1)
		var f5 := _spawn_field(w5, FieldResource.Kind.CAMP, 0, "", 0)
		var males5: Array = []
		for g in w5.goblins:
			if g.sex == Goblin.Sex.MALE and not g.is_child() and g.role == Goblin.Role.NONE:
				males5.append(g)
		var squad: Array = males5.slice(0, mini(5, males5.size()))
		if squad.size() < 2:
			continue
		var equip_before := w5.equipment
		w5.equipment = 10.0  # 装備を十分に用意 (B8 在庫消費を確認するため)
		for g in squad:
			g.dispatch_id = f5.id
		w5._equip_dispatched(f5.id)
		ok = _check(w5.equipment < 10.0, "CAMP 出発前に共有装備在庫が消費される") and ok
		for g in squad:
			ok = _check(g.equipped, "CAMP 出発した個体は装備済みになる (在庫十分時)") and ok
		var gems_before5 := w5.gems
		_run_until_resolved(w5, f5.id)
		if w5.gems > gems_before5:
			wins_5 += 1
	ok = _check(wins_5 >= wins_1,
			"5 体派遣の勝利数は 1 体派遣以上 (単調性。%d vs %d / %d 試行)" % [wins_5, wins_1, trials]) and ok
	ok = _check(wins_5 > 0, "5 体派遣では少なくとも何度か勝利する") and ok
	return ok

## TRAVELER: gems か herb を少量。低確率で human_hostility の「業の漏れ」。
func _test_traveler_trade() -> bool:
	var ok := true
	var got_gems := false
	var got_herb := false
	var got_faux_pas := false
	for trial in range(40):
		var w := _make_world(500 + trial, 1)
		var f := _spawn_field(w, FieldResource.Kind.TRAVELER, 0, "", 1)
		var g := _male_adult(w)
		if g == null:
			continue
		g.dispatch_id = f.id
		var gems_before := w.gems
		var herb_before := w.herb
		var hostility_before := w.human_hostility
		if _run_until_resolved(w, f.id) == null:
			continue
		if w.gems > gems_before:
			got_gems = true
		if w.herb > herb_before:
			got_herb = true
		if w.human_hostility > hostility_before:
			got_faux_pas = true
	ok = _check(got_gems or got_herb, "TRAVELER は gems か herb を持ち帰る") and ok
	ok = _check(got_faux_pas, "TRAVELER は低確率で粗相により human_hostility が上がる (複数試行)") and ok
	return ok

## (e) MAIDEN/アミナ装置: 保持→懐き予兆→JOINED (amina_joined)。
## 初回 MAIDEN は cap_female_human を増やさず amina_state=HOLDING にする。
func _test_amina_device() -> bool:
	var ok := true
	var w := _make_world(7, 1)
	var f := _spawn_field(w, FieldResource.Kind.MAIDEN, 0, "", 1)
	var g := _male_adult(w)
	ok = _check(g != null, "MAIDEN テスト用の男性成体が見つかる") and ok
	g.dispatch_id = f.id
	var cap_before := w.cap_female_human
	ok = _check(_run_until_resolved(w, f.id) != null, "MAIDEN 出現物が回収されて消える") and ok
	ok = _check(w.amina_state == w.AminaState.HOLDING, "初回 MAIDEN で amina_state=HOLDING になる") and ok
	ok = _check(absf(w.cap_female_human - cap_before) < 1e-9,
			"初回 MAIDEN は cap_female_human を増やさない (消費プールから保護)") and ok
	# _resolve_maiden の同一 tick 内で _step_amina が 1 回走るため、観測値は
	# amina_hold_ticks - 1 になる (HOLDING に入った直後に 1 回デクリメントされる)。
	ok = _check(w.amina_hold_ticks_left == w.params.amina_hold_ticks - 1,
			"amina_hold_ticks_left が初期化・1 回デクリメントされる") and ok
	# 保持期間 (既定 3 日 = 720 tick) を実 tick で回すと出産・死亡・襲撃などの
	# 副作用で頭数照合が複雑になるため、amina_hold_ticks_left を直接操作して
	# 「予兆の境界」と「満了」だけを狙って検証する (rng 消費順序とは無関係な
	# 世界状態の直接操作。amina_state マシン自体のロジックのみを見るテスト)。
	var foreshadow_threshold := int(float(w.params.amina_hold_ticks) * w.params.amina_foreshadow_frac)
	# _step_amina は「left <= threshold」を見てから 1 減らすので、left を
	# threshold ちょうどに設定した tick で予兆が発火する。
	w.amina_hold_ticks_left = foreshadow_threshold
	w.amina_foreshadow_emitted = false
	var goblins_before := w.goblins.size()
	var foreshadow_seen := false
	var joined_seen := false
	w.tick_once()
	for e in w.last_events:
		if e.t == "amina_foreshadow":
			foreshadow_seen = true
		if e.t == "amina_joined":
			joined_seen = true
	ok = _check(foreshadow_seen, "保持期間の半ばで「懐き予兆」イベントが発火する") and ok
	ok = _check(not joined_seen, "予兆の時点ではまだ JOINED にならない") and ok
	# 満了直前まで一気に進め、最後の 1 tick で JOINED させる。
	w.amina_hold_ticks_left = 1
	w.tick_once()
	for e in w.last_events:
		if e.t == "amina_joined":
			joined_seen = true
	ok = _check(joined_seen, "保持完了で amina_joined イベントが発火する") and ok
	ok = _check(w.amina_state == w.AminaState.JOINED, "amina_state=JOINED になる") and ok
	ok = _check(w.amina_joined, "amina_joined フラグが立つ (A3 中立善ルート解放)") and ok
	ok = _check(w.amina_goblin_id >= 0, "amina_goblin_id が設定される") and ok
	ok = _check(w.goblins.size() == goblins_before + 1, "ユニーク個体 (アミナ) が 1 体加入する") and ok
	var amina: Goblin = null
	for og in w.goblins:
		if og.id == w.amina_goblin_id:
			amina = og
	ok = _check(amina != null, "アミナ個体が goblins 配列に存在する") and ok
	if amina != null:
		ok = _check(amina.sex == Goblin.Sex.FEMALE, "アミナは女性") and ok
		ok = _check(amina.is_unique, "アミナは is_unique (事故死無効)") and ok
		ok = _check(not w._can_fight(amina), "アミナは戦闘不能 (非戦闘)") and ok
		ok = _check(w._is_amina(amina), "_is_amina がアミナを識別する") and ok
	return ok

## harm_committed が立つと、保持中の MAIDEN は CLOSED になり amina_joined は
## 立たない (§14 不可逆)。
func _test_amina_closed_by_harm() -> bool:
	var ok := true
	var w := _make_world(7, 1)
	var f := _spawn_field(w, FieldResource.Kind.MAIDEN, 0, "", 1)
	var g := _male_adult(w)
	g.dispatch_id = f.id
	ok = _check(_run_until_resolved(w, f.id) != null, "MAIDEN 出現物が回収されて消える") and ok
	ok = _check(w.amina_state == w.AminaState.HOLDING, "amina_state=HOLDING") and ok
	w.cap_male_human = 1.0
	ok = _check(w.sacrifice_captive(), "人間捕虜を生贄にできる (harm を立てる)") and ok
	ok = _check(w.harm_committed, "harm_committed が立つ") and ok
	var closed_seen := false
	w.tick_once()
	for e in w.last_events:
		if e.t == "amina_closed":
			closed_seen = true
	ok = _check(closed_seen, "harm_committed で amina_closed イベントが発火する") and ok
	ok = _check(w.amina_state == w.AminaState.CLOSED, "amina_state=CLOSED になる") and ok
	ok = _check(not w.amina_joined, "amina_joined は立たない (§14 不可逆に閉じる)") and ok
	# CLOSED 後はそれ以上進行しない。
	for i in range(10):
		w.tick_once()
	ok = _check(w.amina_state == w.AminaState.CLOSED, "CLOSED から進行しない") and ok
	return ok

## (f)/(6) 遅れて来る増援: 遠い出現物に派遣中の個体が、襲撃予兆で帰路につき
## (dispatch_id 解除・field_returning=true)、巣内へ着いたら field_returning が
## 解除される (carrying_food でない限り即座に解除可能)。
func _test_delayed_reinforcement() -> bool:
	var ok := true
	var w := _make_world(7, 1)
	# 遠い FORAGE を直接置いて、男性個体を派遣する。
	var f := _spawn_field(w, FieldResource.Kind.FORAGE, 1, "", 5)
	var g := _male_adult(w)
	ok = _check(g != null, "派遣テスト用の男性成体が見つかる") and ok
	g.dispatch_id = f.id
	# 出現物の位置まで歩かせる (運搬前)。
	for i in range(60):
		if g.dispatch_id < 0:
			break
		w.tick_once()
		if w._field_by_id(f.id) == null:
			break
	# 襲撃を直接発火させ、_recall_dispatched が呼ばれることを確認する。
	if g.dispatch_id >= 0 and not g.carrying_food:
		w._spawn_raid(false, "kugyo")
		var recalled := false
		for e in w.last_events:
			if e.t == "field_recall":
				recalled = true
		ok = _check(recalled, "襲撃発生で field_recall イベントが発火する") and ok
		ok = _check(g.dispatch_id == -1, "襲撃発生で dispatch_id が解除される") and ok
		ok = _check(g.field_returning, "襲撃発生で field_returning=true になる") and ok
		# 巣内へ戻るまで進める。
		var arrived := false
		for i in range(400):
			w.tick_once()
			if not g.field_returning:
				arrived = true
				break
			if w.outcome != World.Outcome.ONGOING:
				break
		ok = _check(arrived, "帰路についた個体は巣内に着くと field_returning が解除される") and ok
		if arrived:
			ok = _check(w._inside_nest(g.pos()), "field_returning 解除時、個体は巣内にいる") and ok
	else:
		# 運搬中で配達優先になっているケースでも、carrying_food の個体は
		# dispatch_id を保持したまま配達を済ませることを確認する。
		ok = _check(g.carrying_food, "運搬中なら carrying_food=true") and ok
		w._spawn_raid(false, "kugyo")
		ok = _check(g.dispatch_id >= 0, "運搬中の個体は襲撃でも dispatch_id を保持する (配達優先)") and ok
	return ok

## (g) 新フィールド込みのスナップショット往復 + 復元後 30 tick 決定性。
func _test_snapshot_roundtrip() -> bool:
	var ok := true
	var w := _make_world(7, 1)
	# アミナ装置を HOLDING まで進める。
	var f := _spawn_field(w, FieldResource.Kind.MAIDEN, 1, "bunta", 2)
	var g := _male_adult(w)
	g.dispatch_id = f.id
	_run_until_resolved(w, f.id)
	ok = _check(w.amina_state == w.AminaState.HOLDING, "アミナ装置が HOLDING 状態") and ok
	# WANDERER の出現物を 1 個追加で置いておく (tribe フィールドの往復確認)。
	_spawn_field(w, FieldResource.Kind.WANDERER, 1, "kugyo", 1)
	for i in range(20):
		w.tick_once()
	# field_returning が立った個体を作る (_step_goblins が巣内なら即クリアして
	# しまうため、tick_once の外でスナップショット直前に立てる)。
	var g2: Goblin = null
	for og in w.goblins:
		if og.id != g.id and og.sex == Goblin.Sex.MALE and not og.is_child():
			g2 = og
			break
	if g2 != null:
		g2.field_returning = true
	var snap := w.snapshot()
	var w2 := World.new()
	w2.difficulty = w.difficulty
	w2.setup(w.params)
	w2.restore(snap)
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(snap),
			"A4 新フィールド込みのスナップショット往復が一致する") and ok
	ok = _check(w2.amina_state == w.amina_state, "amina_state が復元される") and ok
	ok = _check(w2.amina_hold_ticks_left == w.amina_hold_ticks_left, "amina_hold_ticks_left が復元される") and ok
	ok = _check(w2.amina_foreshadow_emitted == w.amina_foreshadow_emitted, "amina_foreshadow_emitted が復元される") and ok
	ok = _check(w2.amina_goblin_id == w.amina_goblin_id, "amina_goblin_id が復元される") and ok
	var found_wanderer_tribe := false
	for rf in w2.field_resources:
		if rf.kind == FieldResource.Kind.WANDERER and rf.tribe == "kugyo":
			found_wanderer_tribe = true
	ok = _check(found_wanderer_tribe, "FieldResource.tribe が復元される") and ok
	if g2 != null:
		var g2r := w2._goblin_by_id(g2.id)
		ok = _check(g2r != null and g2r.field_returning, "Goblin.field_returning が復元される") and ok
	for i in range(30):
		w.tick_once()
		w2.tick_once()
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(w.snapshot()),
			"復元後 30 tick の決定性が一致する") and ok
	return ok
