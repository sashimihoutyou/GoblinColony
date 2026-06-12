extends SceneTree
## 捕虜プール + 敵対度メーター + 襲撃間隔接続 (KI-17/23/24)
## + 苗床の確定生産・側室・自然つがい化 (KI-21/§2.5/§3-19。B2 第二増分) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_captives.gd
##   - 襲撃撃退で捕虜を獲得 (人間/ゴブリンの内訳は raid_is_human 連動)。
##   - 平時の雄ゴブリン捕虜の自動加入 (KI-17)。
##   - 生贄の優先順位・信仰への変換・キャップ。
##   - 人間捕虜の解放と敵対度の上下動。
##   - 敵対度 → 大規模襲撃間隔の線形写像。
##   - 新規フィールド (cap_*/human_hostility) のスナップショット往復。
##   - 苗床の確定生産 (部屋なし=停止 / 部屋あり=周期出産・捕虜消耗)。
##   - 人間母体の苗床産 (倍率・敵対度上乗せ)。
##   - take_concubine (プール消費・つがい成立・Origin.CONCUBINE)。
##   - pending_bond の承認 (approve_bond) / 引き離し (tear_apart_bond)。
##   - B2 新規フィールド込みのスナップショット往復 + 復元後の決定性。

func _init() -> void:
	var ok := true
	ok = _test_raid_captive_gain() and ok
	ok = _test_captive_join() and ok
	ok = _test_sacrifice_priority() and ok
	ok = _test_release_hostility() and ok
	ok = _test_raid_interval_mapping() and ok
	ok = _test_snapshot_roundtrip_with_captives() and ok
	ok = _test_nursery_requires_room() and ok
	ok = _test_nursery_goblin_births_and_consumption() and ok
	ok = _test_nursery_human_mother_yield_and_hostility() and ok
	ok = _test_take_concubine() and ok
	ok = _test_pending_bond_approve() and ok
	ok = _test_pending_bond_tear_apart() and ok
	ok = _test_snapshot_roundtrip_with_b2_fields() and ok
	if ok:
		print("CAPTIVES_OK")
		quit(0)
	else:
		print("CAPTIVES_FAIL")
		quit(1)

func _make_world(seed_v: int = 7) -> World:
	var p := SimParams.new()
	p.seed = seed_v
	var w := World.new()
	w.setup(p)
	return w

## 襲撃撃退: 生存者がいれば捕虜を獲得する。raid_is_human で振り分け先が変わる。
func _test_raid_captive_gain() -> bool:
	var ok := true
	# 人間の襲撃を撃退 → 人間捕虜が増える。
	var w := _make_world()
	w.phase = World.Phase.COMBAT
	w.raid_is_human = true
	w.raid_start_hp = w._total_hp()
	w._spawn_enemy_at_gate(0, true)
	w.enemies[0].hp = 0.0
	w._resolve_combat()
	if w.phase != World.Phase.PEACE:
		print("  FAIL: 敵が尽きたら平時に戻るはず")
		ok = false
	if w.cap_male_human <= 0.0 or w.cap_female_human <= 0.0:
		print("  FAIL: 人間の襲撃撃退で人間捕虜が増えるはず (m=%f f=%f)" \
			% [w.cap_male_human, w.cap_female_human])
		ok = false
	if w.cap_male_goblin != 0.0 or w.cap_female_goblin != 0.0:
		print("  FAIL: 人間の襲撃撃退でゴブリン捕虜が増えてはいけない")
		ok = false
	if abs((w.cap_male_human + w.cap_female_human) - w.params.big_raid_captive_gain) > 1e-9:
		print("  FAIL: 捕虜獲得総数が big_raid_captive_gain と合わない")
		ok = false
	# ゴブリン (敵対氏族) の襲撃を撃退 → ゴブリン捕虜が増える。
	var w2 := _make_world()
	w2.phase = World.Phase.COMBAT
	w2.raid_is_human = false
	w2.raid_start_hp = w2._total_hp()
	w2._spawn_enemy_at_gate(0, false)
	w2.enemies[0].hp = 0.0
	w2._resolve_combat()
	if w2.cap_male_goblin <= 0.0 or w2.cap_female_goblin <= 0.0:
		print("  FAIL: ゴブリンの襲撃撃退でゴブリン捕虜が増えるはず")
		ok = false
	if w2.cap_male_human != 0.0 or w2.cap_female_human != 0.0:
		print("  FAIL: ゴブリンの襲撃撃退で人間捕虜が増えてはいけない")
		ok = false
	# 全滅 (生存者なし) なら捕虜は増えない。
	var w3 := _make_world()
	w3.phase = World.Phase.COMBAT
	w3.raid_is_human = true
	w3.raid_start_hp = w3._total_hp()
	for g in w3.goblins:
		g.hp = 0.0
		g.state = Goblin.State.DEAD
	w3._spawn_enemy_at_gate(0, true)
	w3.enemies[0].hp = 0.0
	w3._resolve_combat()
	if w3.cap_male_human != 0.0 or w3.cap_female_human != 0.0 \
			or w3.cap_male_goblin != 0.0 or w3.cap_female_goblin != 0.0:
		print("  FAIL: 全滅時は捕虜を獲得しないはず")
		ok = false
	return ok

## 平時の雄ゴブリン捕虜自動加入 (KI-17)。確率を 1.0 にして決定的に検証する。
func _test_captive_join() -> bool:
	var w := _make_world()
	var ok := true
	w.params.male_captive_join_chance_per_tick = 1.0
	w.cap_male_goblin = 1.0
	var pop_before := w._alive_count()
	w.tick_once()
	if w.cap_male_goblin >= 1.0:
		print("  FAIL: 雄ゴブリン捕虜が消費されていない")
		ok = false
	if w._alive_count() != pop_before + 1:
		print("  FAIL: 頭数が 1 増えるはず (got %d -> %d)" % [pop_before, w._alive_count()])
		ok = false
	var newest: Goblin = w.goblins[w.goblins.size() - 1]
	if newest.origin != Goblin.Origin.CAPTIVE_JOINED or newest.sex != Goblin.Sex.MALE:
		print("  FAIL: 加入個体は雄・出自 CAPTIVE_JOINED のはず")
		ok = false
	# 捕虜が 1 体未満なら加入しない。
	var w2 := _make_world()
	w2.params.male_captive_join_chance_per_tick = 1.0
	w2.cap_male_goblin = 0.5
	var pop_before2 := w2._alive_count()
	w2.tick_once()
	if w2._alive_count() != pop_before2:
		print("  FAIL: 捕虜 1 体未満では加入しないはず")
		ok = false
	return ok

## 生贄: 雄ゴブリン → 人間雄 → 人間雌 → 雌ゴブリンの優先順位。信仰への変換とキャップ。
func _test_sacrifice_priority() -> bool:
	var w := _make_world()
	var ok := true
	# 捕虜が 1 体も無ければ false で無消費。
	if w.sacrifice_captive():
		print("  FAIL: 捕虜が無いのに生贄が成立した")
		ok = false
	# 全種を 1 体ずつ用意し、優先順位どおりに消費されるか確認する。
	w.cap_male_goblin = 1.0
	w.cap_female_goblin = 1.0
	w.cap_male_human = 1.0
	w.cap_female_human = 1.0
	w.faith = 0.0
	w.cum_faith = 0.0
	# ① 雄ゴブリン優先 (係数 0.5)。敵対度は変化しない。
	var hostility_before := w.human_hostility
	if not w.sacrifice_captive():
		print("  FAIL: 生贄が発動しない (雄ゴブリン)")
		ok = false
	if w.cap_male_goblin != 0.0:
		print("  FAIL: 雄ゴブリン捕虜が優先消費されるはず")
		ok = false
	var expect1 := w.params.sacrifice_faith * w.params.male_sacrifice_factor
	if abs(w.faith - expect1) > 1e-9 or abs(w.cum_faith - expect1) > 1e-9:
		print("  FAIL: 雄ゴブリン生贄の信仰変換が合わない (got %f)" % w.faith)
		ok = false
	if abs(w.human_hostility - hostility_before) > 1e-9:
		print("  FAIL: ゴブリン捕虜の生贄で敵対度が変化してはいけない")
		ok = false
	# ② 人間雄 (満額。敵対度上昇)。
	if not w.sacrifice_captive():
		print("  FAIL: 生贄が発動しない (人間雄)")
		ok = false
	if w.cap_male_human != 0.0:
		print("  FAIL: 次は人間雄捕虜が消費されるはず")
		ok = false
	var expect2 := expect1 + w.params.sacrifice_faith
	if abs(w.cum_faith - expect2) > 1e-9:
		print("  FAIL: 人間雄生贄の累計信仰が合わない")
		ok = false
	if abs(w.faith - min(w.faith_cap(), expect2)) > 1e-9:
		print("  FAIL: 人間雄生贄後の信仰残高がキャップ込みで合わない")
		ok = false
	if abs(w.human_hostility - (hostility_before + w.params.hostility_per_human_sacrifice)) > 1e-9:
		print("  FAIL: 人間捕虜の生贄で敵対度が上がるはず")
		ok = false
	# ③ 人間雌 (満額。敵対度さらに上昇)。
	if not w.sacrifice_captive():
		print("  FAIL: 生贄が発動しない (人間雌)")
		ok = false
	if w.cap_female_human != 0.0:
		print("  FAIL: 次は人間雌捕虜が消費されるはず")
		ok = false
	if abs(w.human_hostility - (hostility_before + 2.0 * w.params.hostility_per_human_sacrifice)) > 1e-9:
		print("  FAIL: 人間雌生贄でも敵対度が上がるはず")
		ok = false
	# ④ 雌ゴブリン (最後の手段。満額。敵対度は変化しない)。
	var hostility_after_human := w.human_hostility
	if not w.sacrifice_captive():
		print("  FAIL: 生贄が発動しない (雌ゴブリン)")
		ok = false
	if w.cap_female_goblin != 0.0:
		print("  FAIL: 最後に雌ゴブリン捕虜が消費されるはず")
		ok = false
	if abs(w.human_hostility - hostility_after_human) > 1e-9:
		print("  FAIL: 雌ゴブリン生贄で敵対度が変化してはいけない")
		ok = false
	# ⑤ もう捕虜が無いので不発。
	if w.sacrifice_captive():
		print("  FAIL: 捕虜を使い切った後は不発のはず")
		ok = false
	# ⑥ faith はキャップで頭打ちだが cum_faith は満額積まれる (§3 二重構造)。
	var w2 := _make_world()
	w2.cap_female_goblin = 1.0
	w2.faith = w2.faith_cap()
	var cum_before := w2.cum_faith
	if not w2.sacrifice_captive():
		print("  FAIL: 生贄が発動しない (キャップ確認)")
		ok = false
	if w2.faith > w2.faith_cap() + 1e-9:
		print("  FAIL: 生贄後も faith はキャップを超えないはず")
		ok = false
	if abs(w2.cum_faith - (cum_before + w2.params.sacrifice_faith)) > 1e-9:
		print("  FAIL: cum_faith は満額積まれるはず")
		ok = false
	return ok

## 人間捕虜の解放: 敵対度が下がる。対象が居なければ不発。
func _test_release_hostility() -> bool:
	var w := _make_world()
	var ok := true
	w.cap_male_human = 1.0
	w.cap_female_human = 1.0
	w.human_hostility = 0.5
	if not w.release_human_captive(Goblin.Sex.FEMALE):
		print("  FAIL: 人間雌捕虜の解放が発動しない")
		ok = false
	if w.cap_female_human != 0.0:
		print("  FAIL: 解放した捕虜が減っていない")
		ok = false
	if abs(w.human_hostility - (0.5 - w.params.hostility_release_drop)) > 1e-9:
		print("  FAIL: 解放で敵対度が下がるはず")
		ok = false
	# 対象が居ない性別は不発・敵対度は変化しない。
	var hostility_before := w.human_hostility
	if w.release_human_captive(Goblin.Sex.FEMALE):
		print("  FAIL: 人間雌捕虜が無いのに解放が成立した")
		ok = false
	if abs(w.human_hostility - hostility_before) > 1e-9:
		print("  FAIL: 不発時は敵対度が変化してはいけない")
		ok = false
	# 敵対度は 0 未満にクランプされる。
	w.human_hostility = 0.0
	w.cap_male_human = 5.0
	w.release_human_captive(Goblin.Sex.MALE)
	if w.human_hostility < 0.0:
		print("  FAIL: 敵対度が 0 未満になった")
		ok = false
	return ok

## 敵対度 → 大規模襲撃間隔の線形写像 (world.ts raidIntervalDays と同式)。
func _test_raid_interval_mapping() -> bool:
	var w := _make_world()
	var ok := true
	if abs(w.raid_interval_days(0.0) - w.params.big_raid_interval_peace) > 1e-9:
		print("  FAIL: 敵対度 0 で big_raid_interval_peace のはず")
		ok = false
	if abs(w.raid_interval_days(1.0) - w.params.big_raid_interval_max) > 1e-9:
		print("  FAIL: 敵対度 1 で big_raid_interval_max のはず")
		ok = false
	# 中間値は線形補間。
	var mid := w.raid_interval_days(0.5)
	var expect_mid := (w.params.big_raid_interval_peace + w.params.big_raid_interval_max) * 0.5
	if abs(mid - expect_mid) > 1e-9:
		print("  FAIL: 敵対度 0.5 で線形補間の中間値になるはず")
		ok = false
	# 範囲外もクランプされる。
	if abs(w.raid_interval_days(2.0) - w.params.big_raid_interval_max) > 1e-9:
		print("  FAIL: 敵対度 > 1 は 1 にクランプされるはず")
		ok = false
	return ok

## 新規フィールド込みのスナップショット往復 (KI-09)。
func _test_snapshot_roundtrip_with_captives() -> bool:
	var w := _make_world()
	w.cap_male_goblin = 2.0
	w.cap_female_goblin = 1.0
	w.cap_male_human = 1.0
	w.cap_female_human = 1.0
	w.human_hostility = 0.3
	for i in range(20):
		w.tick_once()
	var snap := w.snapshot()
	var w2 := World.new()
	w2.setup(w.params)
	w2.restore(snap)
	if JSON.stringify(w2.snapshot()) != JSON.stringify(snap):
		print("  FAIL: 捕虜フィールド込みの往復が一致しない")
		return false
	for i in range(30):
		w.tick_once()
		w2.tick_once()
	if JSON.stringify(w.snapshot()) != JSON.stringify(w2.snapshot()):
		print("  FAIL: 復元後の進行が一致しない (決定性)")
		return false
	return true

## NURSERY 部屋を w.map.rooms へ直接追加し、床キャッシュを再構築するテスト用ヘルパー。
## NEST 部屋 (10,24,9x9) と同じ実在の床域を再利用する (重複登録で構わない。
## _room_floors はインデックス別に独立して構築されるため)。
func _add_nursery_room(w: World) -> void:
	w.map.rooms.append({"x": 10, "y": 24, "w": 9, "h": 9,
		"room_type": TileMapData.RoomType.NURSERY, "assigned": []})
	w._rebuild_floor_caches()

## 苗床: NURSERY 部屋が無ければ稼働しない (nursery_timer は 0 のまま・出産なし)。
## 部屋を追加すると母体 (雌ゴブリン捕虜) が居る間だけタイマーが進み、
## nursery_period_ticks に達すると出産する (world.ts stepFaithAndNursery の移植)。
func _test_nursery_requires_room() -> bool:
	var ok := true
	# 部屋なし: 母体が居てもタイマーが進まず出産もしない。
	var w := _make_world()
	w.cap_female_goblin = 10.0
	var pop_before := w._alive_count()
	for i in range(50):
		w.tick_once()
	if w.nursery_timer != 0.0:
		print("  FAIL: 部屋が無いと nursery_timer は 0 のままのはず")
		ok = false
	if w._alive_count() != pop_before:
		print("  FAIL: 部屋が無いと苗床産は発生しないはず")
		ok = false
	if abs(w.cap_female_goblin - 10.0) > 1e-9:
		print("  FAIL: 部屋が無いと母体は消耗しないはず")
		ok = false

	# 部屋あり・母体なし: タイマーは 0 のまま。
	var w2 := _make_world()
	_add_nursery_room(w2)
	w2.tick_once()
	if w2.nursery_timer != 0.0:
		print("  FAIL: 部屋があっても母体が居なければ nursery_timer は 0 のはず")
		ok = false

	# 部屋あり・母体あり: タイマーが進む。
	var w3 := _make_world()
	_add_nursery_room(w3)
	w3.cap_female_goblin = 10.0
	w3.tick_once()
	if w3.nursery_timer != 1.0:
		print("  FAIL: 部屋・母体が揃うと nursery_timer が進むはず (got %f)" % w3.nursery_timer)
		ok = false
	return ok

## 苗床: ゴブリン母体 (cap_female_goblin) による周期出産。nursery_period_ticks 到達で
## floor(host * nursery_yield_per_captive) 体を追加し、母体を nursery_captive_consume
## 分だけ消耗する (world.ts birthNurseryChildren / stepFaithAndNursery と同式)。
func _test_nursery_goblin_births_and_consumption() -> bool:
	var ok := true
	var w := _make_world()
	_add_nursery_room(w)
	# 周期を小さくしてテストを高速化する (yield/consume レートはそのまま)。
	w.params.nursery_period_ticks = 5
	w.cap_female_goblin = 10.0
	var pop_before := w._alive_count()
	var births_before := w.births_total

	var expect_born := int(floor(10.0 * w.params.nursery_yield_per_captive))  # floor(10*0.16)=1
	if expect_born <= 0:
		print("  FAIL: テスト前提が崩れている (expect_born<=0)")
		return false

	# period_ticks-1 回までは出産しない。
	for i in range(w.params.nursery_period_ticks - 1):
		w.tick_once()
	if w._alive_count() != pop_before:
		print("  FAIL: nursery_period_ticks 未到達では出産しないはず")
		ok = false

	# 到達した tick で出産・消耗が発生する。
	w.tick_once()
	if w.nursery_timer != 0.0:
		print("  FAIL: 出産後 nursery_timer は 0 に戻るはず (got %f)" % w.nursery_timer)
		ok = false
	if w._alive_count() != pop_before + expect_born:
		print("  FAIL: 苗床産で頭数が %d 増えるはず (got %d -> %d)" \
			% [expect_born, pop_before, w._alive_count()])
		ok = false
	if w.births_total != births_before + expect_born:
		print("  FAIL: births_total が苗床産ぶん増えるはず")
		ok = false
	var expect_consume := float(expect_born) * w.params.nursery_captive_consume
	if abs(w.cap_female_goblin - (10.0 - expect_consume)) > 1e-9:
		print("  FAIL: 母体 (cap_female_goblin) が消耗するはず (got %f)" % w.cap_female_goblin)
		ok = false

	# 新しく生まれた個体は Origin.NURSERY / Role.NONE / 子 (child_born_tick>=0)。
	var newest: Goblin = w.goblins[w.goblins.size() - 1]
	if newest.origin != Goblin.Origin.NURSERY:
		print("  FAIL: 苗床産の出自は Origin.NURSERY のはず")
		ok = false
	if newest.role != Goblin.Role.NONE:
		print("  FAIL: 苗床産の役職は Role.NONE のはず")
		ok = false
	if not newest.is_child():
		print("  FAIL: 苗床産は子 (child_born_tick>=0) のはず")
		ok = false
	return ok

## 苗床: 人間母体 (cap_female_human) は human_nursery_yield_factor 倍の出産数になり、
## 1 体産むごとに human_hostility が hostility_per_human_nursery_birth 増える
## (world.ts stepFaithAndNursery の人間母体ぶん)。
func _test_nursery_human_mother_yield_and_hostility() -> bool:
	var ok := true
	var w := _make_world()
	_add_nursery_room(w)
	w.params.nursery_period_ticks = 3
	w.cap_female_goblin = 0.0
	w.cap_female_human = 10.0
	w.human_hostility = 0.0
	var pop_before := w._alive_count()

	var expect_born := int(floor(10.0 * w.params.nursery_yield_per_captive \
		* w.params.human_nursery_yield_factor))  # floor(10*0.16*2.0)=3
	if expect_born <= 0:
		print("  FAIL: テスト前提が崩れている (expect_born<=0)")
		return false

	for i in range(w.params.nursery_period_ticks):
		w.tick_once()

	if w._alive_count() != pop_before + expect_born:
		print("  FAIL: 人間母体の苗床産で頭数が %d 増えるはず (got %d -> %d)" \
			% [expect_born, pop_before, w._alive_count()])
		ok = false
	var expect_consume := float(expect_born) * w.params.nursery_captive_consume
	if abs(w.cap_female_human - (10.0 - expect_consume)) > 1e-9:
		print("  FAIL: 人間母体 (cap_female_human) が消耗するはず (got %f)" % w.cap_female_human)
		ok = false
	var expect_hostility := float(expect_born) * w.params.hostility_per_human_nursery_birth
	if abs(w.human_hostility - expect_hostility) > 1e-9:
		print("  FAIL: 人間母体の苗床産で敵対度が上がるはず (got %f, want %f)" \
			% [w.human_hostility, expect_hostility])
		ok = false
	return ok

## take_concubine: 異性の捕虜カテゴリを 1 体消費して側室として加える。
## プール減少・mate_id の相互設定・Origin.CONCUBINE/Role.CONCUBINE・つがいバフを確認する。
## 失敗系 (同性・プール不足・対象不在) も確認する (world.ts takeConcubine と同式)。
func _test_take_concubine() -> bool:
	var ok := true
	var w := _make_world()
	var suitor: Goblin = w.goblins[0]
	suitor.sex = Goblin.Sex.MALE
	suitor.state = Goblin.State.WANDER
	var hp_before := suitor.hp
	var max_hp_before := suitor.max_hp
	var fear_before := suitor.fear_hp_bias
	w.cap_female_goblin = 2.0
	var pop_before := w._alive_count()

	if not w.take_concubine(suitor.id, Goblin.Sex.FEMALE, false):
		print("  FAIL: take_concubine が成立しないはず (異性・プール十分)")
		ok = false
	if abs(w.cap_female_goblin - 1.0) > 1e-9:
		print("  FAIL: cap_female_goblin が 1 減るはず (got %f)" % w.cap_female_goblin)
		ok = false
	if w._alive_count() != pop_before + 1:
		print("  FAIL: 側室追加で頭数が 1 増えるはず")
		ok = false
	var concubine: Goblin = w.goblins[w.goblins.size() - 1]
	if concubine.origin != Goblin.Origin.CONCUBINE or concubine.role != Goblin.Role.CONCUBINE:
		print("  FAIL: 新規側室の出自/役職が CONCUBINE のはず")
		ok = false
	if concubine.sex != Goblin.Sex.FEMALE:
		print("  FAIL: 指定した性別 (FEMALE) の側室が生成されるはず")
		ok = false
	if concubine.mate_id != suitor.id or suitor.mate_id != concubine.id:
		print("  FAIL: mate_id が双方向に設定されるはず")
		ok = false
	# つがいバフ (雄=最大HP/HP増・恐怖閾値減)。
	if abs(suitor.max_hp - (max_hp_before + w.params.bond_male_hp_bonus)) > 1e-9 \
			or abs(suitor.hp - (hp_before + w.params.bond_male_hp_bonus)) > 1e-9:
		print("  FAIL: 雄の娶り主に bond_male_hp_bonus が加算されるはず")
		ok = false
	if abs(suitor.fear_hp_bias - (fear_before - w.params.bond_male_fear_reduce)) > 1e-9:
		print("  FAIL: 雄の娶り主の fear_hp_bias が減るはず")
		ok = false

	# 失敗系: 同性は不成立 (プールは変化しない)。
	var w2 := _make_world()
	var suitor2: Goblin = w2.goblins[0]
	suitor2.sex = Goblin.Sex.MALE
	w2.cap_male_goblin = 2.0
	if w2.take_concubine(suitor2.id, Goblin.Sex.MALE, false):
		print("  FAIL: 同性は側室にできないはず")
		ok = false
	if abs(w2.cap_male_goblin - 2.0) > 1e-9:
		print("  FAIL: 不成立時はプールが変化しないはず")
		ok = false

	# 失敗系: プール不足。
	var w3 := _make_world()
	var suitor3: Goblin = w3.goblins[0]
	suitor3.sex = Goblin.Sex.MALE
	w3.cap_female_goblin = 0.0
	if w3.take_concubine(suitor3.id, Goblin.Sex.FEMALE, false):
		print("  FAIL: プール不足では側室にできないはず")
		ok = false

	# 失敗系: 対象 (suitor) が存在しない/死亡。
	var w4 := _make_world()
	w4.cap_female_goblin = 2.0
	if w4.take_concubine(99999, Goblin.Sex.FEMALE, false):
		print("  FAIL: 存在しない suitor では不成立のはず")
		ok = false
	var dead_suitor: Goblin = w4.goblins[0]
	dead_suitor.sex = Goblin.Sex.MALE
	dead_suitor.state = Goblin.State.DEAD
	if w4.take_concubine(dead_suitor.id, Goblin.Sex.FEMALE, false):
		print("  FAIL: 死亡した suitor では不成立のはず")
		ok = false
	return ok

## pending_bond → approve_bond: 承認で側室 (Role.CONCUBINE) が貢献する一員 (Role.NONE) に
## 昇格し、性別別性格 4 項目が再設定され、つがいバフが付与される。娶り主側の
## pending_bond も解除される (world.ts approveBond と同式)。
func _test_pending_bond_approve() -> bool:
	var ok := true
	var w := _make_world()
	var suitor: Goblin = w.goblins[0]
	suitor.sex = Goblin.Sex.MALE
	suitor.state = Goblin.State.WANDER
	w.cap_female_goblin = 1.0
	if not w.take_concubine(suitor.id, Goblin.Sex.FEMALE, false):
		print("  FAIL: 前提の take_concubine が失敗した")
		return false
	var concubine: Goblin = w.goblins[w.goblins.size() - 1]
	# 自然つがい化が承認待ちになった状態を直接模す (KI-21)。
	concubine.pending_bond = true
	suitor.pending_bond = true
	var max_hp_before := concubine.max_hp
	var hp_before := concubine.hp

	if not w.approve_bond(concubine.id):
		print("  FAIL: approve_bond が成立しないはず")
		ok = false
	if concubine.pending_bond:
		print("  FAIL: 承認後 captive 側の pending_bond は解除されるはず")
		ok = false
	if suitor.pending_bond:
		print("  FAIL: 承認後 mate 側の pending_bond も解除されるはず")
		ok = false
	if concubine.role != Goblin.Role.NONE:
		print("  FAIL: 承認で Role.NONE (貢献する一員) になるはず")
		ok = false
	# 性別別性格 4 項目 (雌の基準値)。fear_hp_bias/hunger_bias はつがいバフの対象外なので
	# 基準値のまま。work_bias/forage_bias はつがいバフ (bond_female_work_bonus 加算) 後の値になる。
	if abs(concubine.fear_hp_bias - 0.25) > 1e-9 or abs(concubine.hunger_bias - 0.05) > 1e-9:
		print("  FAIL: 承認後の性格 (雌基準値: fear_hp_bias/hunger_bias) が一致しない")
		ok = false
	# つがいバフ (雌=work_bias/forage_bias に bond_female_work_bonus 加算)。
	if abs(concubine.work_bias - (-0.1 + w.params.bond_female_work_bonus)) > 1e-9 \
			or abs(concubine.forage_bias - (0.6 + w.params.bond_female_work_bonus)) > 1e-9:
		print("  FAIL: 承認時につがいバフ (bond_female_work_bonus) が適用されるはず")
		ok = false
	if abs(concubine.max_hp - max_hp_before) > 1e-9 or abs(concubine.hp - hp_before) > 1e-9:
		print("  FAIL: 雌の承認では HP/最大HP は変化しないはず")
		ok = false

	# 失敗系: pending でない/存在しない captive_id は false。
	if w.approve_bond(concubine.id):
		print("  FAIL: 既に承認済みの captive を再承認できてはいけない")
		ok = false
	if w.approve_bond(99999):
		print("  FAIL: 存在しない captive_id は不成立のはず")
		ok = false
	return ok

## pending_bond → tear_apart_bond: 引き離しで承認待ちの捕虜とその娶り主の両方が
## Goblin.State.DEAD + death_logged=true になる (片方だけ残すと悲嘆するため両方処刑/追放。
## world.ts tearApartBond と同式)。
func _test_pending_bond_tear_apart() -> bool:
	var ok := true
	var w := _make_world()
	var suitor: Goblin = w.goblins[0]
	suitor.sex = Goblin.Sex.MALE
	suitor.state = Goblin.State.WANDER
	w.cap_female_goblin = 1.0
	if not w.take_concubine(suitor.id, Goblin.Sex.FEMALE, false):
		print("  FAIL: 前提の take_concubine が失敗した")
		return false
	var concubine: Goblin = w.goblins[w.goblins.size() - 1]
	concubine.pending_bond = true
	suitor.pending_bond = true
	var deaths_before := w.deaths_total

	if not w.tear_apart_bond(concubine.id, "execution"):
		print("  FAIL: tear_apart_bond が成立しないはず")
		ok = false
	if concubine.state != Goblin.State.DEAD or not concubine.death_logged:
		print("  FAIL: captive 側が DEAD + death_logged になるはず")
		ok = false
	if suitor.state != Goblin.State.DEAD or not suitor.death_logged:
		print("  FAIL: mate 側も DEAD + death_logged になるはず")
		ok = false
	# death イベントが両者ぶん記録される。
	var death_events := 0
	for e in w.last_events:
		if e.t == "death" and (e.id == concubine.id or e.id == suitor.id):
			death_events += 1
	if death_events != 2:
		print("  FAIL: death イベントが両者ぶん (2件) 記録されるはず (got %d)" % death_events)
		ok = false

	# 失敗系: pending でない/存在しない captive_id は false。
	var w2 := _make_world()
	if w2.tear_apart_bond(w2.goblins[0].id, "execution"):
		print("  FAIL: pending_bond でない個体は引き離せないはず")
		ok = false
	if w2.tear_apart_bond(99999, "execution"):
		print("  FAIL: 存在しない captive_id は不成立のはず")
		ok = false
	return ok

## B2 新規フィールド (nursery_timer / pending_bond 等) 込みのスナップショット往復 (KI-09)。
## 苗床部屋を生やした状態で進行させ、承認待ちの個体も含めて往復・決定性を確認する。
func _test_snapshot_roundtrip_with_b2_fields() -> bool:
	var w := _make_world(11)
	_add_nursery_room(w)
	w.params.nursery_period_ticks = 4
	w.cap_male_goblin = 1.0
	w.cap_female_goblin = 3.0
	w.cap_male_human = 1.0
	w.cap_female_human = 3.0

	var suitor: Goblin = w.goblins[0]
	suitor.sex = Goblin.Sex.MALE
	suitor.state = Goblin.State.WANDER
	if not w.take_concubine(suitor.id, Goblin.Sex.FEMALE, false):
		print("  FAIL: 前提の take_concubine が失敗した")
		return false
	var concubine: Goblin = w.goblins[w.goblins.size() - 1]
	concubine.pending_bond = true
	suitor.pending_bond = true

	for i in range(10):
		w.tick_once()
	if w.nursery_timer <= 0.0 and w.births_total == 0:
		print("  FAIL: テスト前提が崩れている (苗床が一度も進行していない)")
		return false

	var snap := w.snapshot()
	var w2 := World.new()
	w2.setup(w.params)
	w2.restore(snap)
	if JSON.stringify(w2.snapshot()) != JSON.stringify(snap):
		print("  FAIL: B2 新規フィールド込みの往復が一致しない")
		return false

	for i in range(30):
		w.tick_once()
		w2.tick_once()
	if JSON.stringify(w.snapshot()) != JSON.stringify(w2.snapshot()):
		print("  FAIL: 復元後の進行が一致しない (決定性。B2 新規フィールド)")
		return false
	return true
