extends SceneTree
## §13 3 勢力外交 (B1: TS world.ts §13 セクションの移植) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_factions.gd
##   - 常時の業: ゴブリン 2 部族の敵対度が自然悪化 (苦魚族 > ブン・タ＝タ > 0)。
##     人間メーターはドリフトしない (中立ルート保護 §14.5.7)。
##   - 朝貢: 種族の合う捕虜を雄優先で 1 体消費し、対象勢力だけ敵対度が下がる。
##     在庫なしは no-op。朝貢の低下量は解放より大きい。
##   - 勢力抽選 (pick_raid_faction): 人間判定の従来式維持 + 部族間の重み付け。
##   - 襲撃間隔は max(3 勢力) の敵対度で決まる。
##   - 新フィールド (bunta/kugyo_hostility・raid_faction) 込みのスナップショット往復。

func _init() -> void:
	var ok := true
	ok = _test_hostility_drift() and ok
	ok = _test_tribute() and ok
	ok = _test_pick_raid_faction() and ok
	ok = _test_max_interval() and ok
	ok = _test_final_wave() and ok
	ok = _test_snapshot_roundtrip_with_factions() and ok
	if ok:
		print("FACTIONS_OK")
		quit(0)
	else:
		print("FACTIONS_FAIL")
		quit(1)

func _make_world(seed_v: int = 7) -> World:
	var p := SimParams.new()
	p.seed = seed_v
	var w := World.new()
	w.setup(p)
	return w

## 常時の業 (§13 小ノイズ層): 平時放置でゴブリン 2 部族の敵対度がじわじわ悪化する。
## 苦魚族 (kugyo) はブン・タ＝タ族 (bunta) より速く悪化し、人間メーターは
## 加害でのみ動く (中立ルート保護 §14.5.7) のでドリフトしない。
func _test_hostility_drift() -> bool:
	var w := _make_world()
	var ok := true
	# 大規模襲撃を踏まないよう間隔を伸ばして平時のまま 10 日進める。
	w.params.big_raid_interval_peace = 9999
	w.params.big_raid_interval_max = 9999
	w.next_big_raid_tick = 999999
	w.params.small_raid_prob = 0.0
	for d in range(10):
		for i in range(w.params.ticks_per_day):
			w.tick_once()
	if not (w.bunta_hostility > 0.0 and w.kugyo_hostility > 0.0):
		print("  FAIL: 常時の業でゴブリン部族の敵対度が悪化していない (bunta=%f kugyo=%f)" \
			% [w.bunta_hostility, w.kugyo_hostility])
		ok = false
	if not (w.kugyo_hostility > w.bunta_hostility):
		print("  FAIL: 苦魚族の自然悪化はブン・タ＝タより速いはず (bunta=%f kugyo=%f)" \
			% [w.bunta_hostility, w.kugyo_hostility])
		ok = false
	if w.human_hostility != 0.0:
		print("  FAIL: 人間の敵対度はドリフトしないはず (human=%f)" % w.human_hostility)
		ok = false
	# 10 日ぶんの期待値 (per-tick × tick数) と一致するか (KI-02 変換の確認)。
	var ticks := 10 * w.params.ticks_per_day
	var expect_bunta := clampf(w.params.hostility_drift_per_tick_bunta * ticks, 0.0, 1.0)
	var expect_kugyo := clampf(w.params.hostility_drift_per_tick_kugyo * ticks, 0.0, 1.0)
	if abs(w.bunta_hostility - expect_bunta) > 1e-9:
		print("  FAIL: bunta_hostility が per-tick ドリフトの積算と合わない")
		ok = false
	if abs(w.kugyo_hostility - expect_kugyo) > 1e-9:
		print("  FAIL: kugyo_hostility が per-tick ドリフトの積算と合わない")
		ok = false
	return ok

## 朝貢 (§13 双方向化): 種族の合う捕虜を雄優先で 1 体消費し、対象勢力だけ下がる。
## 在庫なしは no-op で false。朝貢の低下量は解放より大きい。
func _test_tribute() -> bool:
	var w := _make_world()
	var ok := true

	# 在庫が無ければ no-op で false。
	if w.tribute_captive("kugyo"):
		print("  FAIL: 捕虜が無いのに朝貢が成立した (kugyo)")
		ok = false
	if w.tribute_captive("human"):
		print("  FAIL: 捕虜が無いのに朝貢が成立した (human)")
		ok = false

	# ゴブリン部族への朝貢: ゴブリン捕虜を雄優先で消費し、対象勢力だけ下がる。
	w.cap_male_goblin = 1.0
	w.cap_female_goblin = 1.0
	w.cap_male_human = 1.0
	w.human_hostility = 0.5
	w.bunta_hostility = 0.3
	w.kugyo_hostility = 0.3
	var kugyo_before: float = w.kugyo_hostility
	var bunta_before: float = w.bunta_hostility
	if not w.tribute_captive("kugyo"):
		print("  FAIL: 朝貢が発動しない (kugyo)")
		ok = false
	if w.kugyo_hostility >= kugyo_before:
		print("  FAIL: 朝貢で苦魚族の敵対度が下がるはず (%f -> %f)" % [kugyo_before, w.kugyo_hostility])
		ok = false
	if w.bunta_hostility != bunta_before:
		print("  FAIL: 朝貢は対象勢力のみ下げるはず (ブン・タ＝タが変化した)")
		ok = false
	if w.cap_male_goblin != 0.0 or w.cap_female_goblin != 1.0:
		print("  FAIL: 朝貢は雄ゴブリン捕虜を優先消費するはず (male=%f female=%f)" \
			% [w.cap_male_goblin, w.cap_female_goblin])
		ok = false

	# 雄を使い切った後は雌ゴブリン捕虜が消費される。
	if not w.tribute_captive("bunta"):
		print("  FAIL: 朝貢が発動しない (bunta, 雌のみ残)")
		ok = false
	if w.cap_female_goblin != 0.0:
		print("  FAIL: 雄を使い切ったら雌ゴブリン捕虜が消費されるはず")
		ok = false
	if w.bunta_hostility >= bunta_before:
		print("  FAIL: 朝貢でブン・タ＝タの敵対度が下がるはず (%f -> %f)" % [bunta_before, w.bunta_hostility])
		ok = false

	# ゴブリン捕虜が尽きたら no-op。
	if w.tribute_captive("kugyo"):
		print("  FAIL: ゴブリン捕虜が無いのに朝貢が成立した")
		ok = false

	# 人間勢力への朝貢: 人間捕虜を消費し、人間敵対度のみ下がる。
	var human_before: float = w.human_hostility
	if not w.tribute_captive("human"):
		print("  FAIL: 朝貢が発動しない (human)")
		ok = false
	if w.cap_male_human != 0.0:
		print("  FAIL: 人間勢力への朝貢は人間捕虜 (雄) を消費するはず")
		ok = false
	if w.human_hostility >= human_before:
		print("  FAIL: 人間勢力への朝貢で人間敵対度が下がるはず (%f -> %f)" % [human_before, w.human_hostility])
		ok = false

	# 人間捕虜が尽きたら no-op (敵対度は不変)。
	var human_after: float = w.human_hostility
	if w.tribute_captive("human"):
		print("  FAIL: 人間捕虜が無いのに朝貢が成立した")
		ok = false
	if w.human_hostility != human_after:
		print("  FAIL: 不発時は敵対度が変化してはいけない (human)")
		ok = false

	# 朝貢の低下量は解放より大きい (能動的外交の手応え §13)。
	if not (w.params.hostility_tribute_drop > w.params.hostility_release_drop):
		print("  FAIL: hostility_tribute_drop は hostility_release_drop より大きいはず (%f vs %f)" \
			% [w.params.hostility_tribute_drop, w.params.hostility_release_drop])
		ok = false

	# 0 未満にクランプされる。
	var w2 := _make_world()
	w2.cap_male_goblin = 5.0
	w2.kugyo_hostility = 0.0
	w2.tribute_captive("kugyo")
	if w2.kugyo_hostility < 0.0:
		print("  FAIL: 敵対度が 0 未満になった (kugyo)")
		ok = false

	return ok

## 勢力抽選 (world.ts pickRaidFaction と同式)。人間判定は従来式 (r < human) を
## 維持し、残りを部族の重み (kugyo_base_share + 各敵対度) で分け合う。
func _test_pick_raid_faction() -> bool:
	var ok := true
	var share := SimParams.new().kugyo_base_raid_share

	# 人間判定は従来式 (r < human) を維持。
	if World.pick_raid_faction(0.8, 0.0, 0.0, share, 0.5) != "human":
		print("  FAIL: r < human なら human のはず")
		ok = false
	if World.pick_raid_faction(0.2, 0.0, 0.0, share, 0.5) == "human":
		print("  FAIL: r >= human なら human ではないはず")
		ok = false

	# ブン・タ＝タの敵対度を上げると同部族が来やすくなる。
	if World.pick_raid_faction(0.0, 5.0, 0.0, share, 0.9) != "bunta":
		print("  FAIL: ブン・タ＝タの敵対度が高いと bunta が選ばれるはず")
		ok = false
	# 苦魚族の敵対度を上げると同部族が来やすくなる。
	if World.pick_raid_faction(0.0, 0.0, 5.0, share, 0.9) != "kugyo":
		print("  FAIL: 苦魚族の敵対度が高いと kugyo が選ばれるはず")
		ok = false

	# 敵対度ゼロ同士なら kugyo_base_raid_share (既定 0.7) で苦魚族側が広い。
	# u=0.5 (中央) は wKugyo=0.7, wBunta=0.3 で 0.5 < 0.7/(0.7+0.3)=0.7 → kugyo。
	if World.pick_raid_faction(0.0, 0.0, 0.0, share, 0.5) != "kugyo":
		print("  FAIL: 敵対度ゼロ同士の中央値は kugyo_base_raid_share により kugyo になるはず")
		ok = false

	return ok

## 襲撃間隔は「最も怒っている勢力」(max_hostility) の敵対度で決まる (§11/KI-08)。
func _test_max_interval() -> bool:
	var w := _make_world()
	var ok := true
	w.human_hostility = 0.0
	w.bunta_hostility = 0.0
	w.kugyo_hostility = 1.0
	if abs(w.max_hostility() - 1.0) > 1e-9:
		print("  FAIL: max_hostility は 3 勢力の最大値のはず (got %f)" % w.max_hostility())
		ok = false
	if abs(w.raid_interval_days(w.max_hostility()) - w.params.big_raid_interval_max) > 1e-9:
		print("  FAIL: 襲撃間隔は max(3勢力) の敵対度で big_raid_interval_max になるはず")
		ok = false
	# human が最大のケースでも同様。
	var w2 := _make_world()
	w2.human_hostility = 0.6
	w2.bunta_hostility = 0.1
	w2.kugyo_hostility = 0.2
	if abs(w2.max_hostility() - 0.6) > 1e-9:
		print("  FAIL: human が最大なら max_hostility は human のはず (got %f)" % w2.max_hostility())
		ok = false
	return ok

## §11/B10: ラストバトル手前の波状期は敵対度が低くても間隔が下限でキャップされる。
func _test_final_wave() -> bool:
	var w := _make_world()
	var ok := true
	# 全勢力の敵対度を 0 にし、平時の長間隔 (big_raid_interval_peace) を基準にする。
	w.human_hostility = 0.0
	w.bunta_hostility = 0.0
	w.kugyo_hostility = 0.0
	# 波状期の手前 (序盤): 間隔は平時のまま (キャップされない)。
	w.day = 0
	w.tick = 0
	w._schedule_next_raid()
	var early_days := float(w.next_big_raid_tick) / float(w.params.ticks_per_day)
	if abs(early_days - w.params.big_raid_interval_peace) > 0.5:
		print("  FAIL: 序盤は平時間隔のはず (got %.2f 日)" % early_days)
		ok = false
	# 波状期 (最終日の手前 final_wave_days 日以内): 間隔が下限でキャップ。
	w.day = w.params.final_day - 1
	w.tick = w.day * w.params.ticks_per_day
	w._schedule_next_raid()
	var wave_days := float(w.next_big_raid_tick - w.tick) / float(w.params.ticks_per_day)
	if wave_days > w.params.final_wave_interval_days + 0.5:
		print("  FAIL: 波状期は間隔が下限 %.1f 日でキャップされるはず (got %.2f)" \
				% [w.params.final_wave_interval_days, wave_days])
		ok = false
	if wave_days >= early_days:
		print("  FAIL: 波状期の間隔は序盤より短いはず (%.2f >= %.2f)" % [wave_days, early_days])
		ok = false
	return ok

## 新規フィールド (bunta/kugyo_hostility・raid_faction) 込みのスナップショット往復
## (KI-09 / test_captives.gd の規律: ライブ dict + 復元後 30 tick 決定性)。
func _test_snapshot_roundtrip_with_factions() -> bool:
	var w := _make_world()
	w.cap_male_goblin = 2.0
	w.cap_female_goblin = 1.0
	w.cap_male_human = 1.0
	w.cap_female_human = 1.0
	w.human_hostility = 0.3
	w.bunta_hostility = 0.1
	w.kugyo_hostility = 0.4
	w.raid_faction = "bunta"
	for i in range(20):
		w.tick_once()
	var snap := w.snapshot()
	var w2 := World.new()
	w2.setup(w.params)
	w2.restore(snap)
	if JSON.stringify(w2.snapshot()) != JSON.stringify(snap):
		print("  FAIL: 3 勢力フィールド込みの往復が一致しない")
		return false
	for i in range(30):
		w.tick_once()
		w2.tick_once()
	if JSON.stringify(w.snapshot()) != JSON.stringify(w2.snapshot()):
		print("  FAIL: 復元後の進行が一致しない (決定性)")
		return false
	return true
