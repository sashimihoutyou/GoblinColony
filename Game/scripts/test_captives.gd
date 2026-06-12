extends SceneTree
## 捕虜プール + 敵対度メーター + 襲撃間隔接続 (KI-17/23/24) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_captives.gd
##   - 襲撃撃退で捕虜を獲得 (人間/ゴブリンの内訳は raid_is_human 連動)。
##   - 平時の雄ゴブリン捕虜の自動加入 (KI-17)。
##   - 生贄の優先順位・信仰への変換・キャップ。
##   - 人間捕虜の解放と敵対度の上下動。
##   - 敵対度 → 大規模襲撃間隔の線形写像。
##   - 新規フィールド (cap_*/human_hostility) のスナップショット往復。

func _init() -> void:
	var ok := true
	ok = _test_raid_captive_gain() and ok
	ok = _test_captive_join() and ok
	ok = _test_sacrifice_priority() and ok
	ok = _test_release_hostility() and ok
	ok = _test_raid_interval_mapping() and ok
	ok = _test_snapshot_roundtrip_with_captives() and ok
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
