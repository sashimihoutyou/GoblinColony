extends SceneTree
## 宝石の両刃 (§7・§14・§14.5.7・§14.5.8・B5) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_gems.gd
##   - ため込み (gems > 閾値) で人間敵対度が上昇 / 閾値以下では無罰 (baseline 不変)。
##   - ため込みドリフトは 1 日あたり上限でクランプ。
##   - 宝石献上 (tribute_gems): gems 減・人間敵対度低下・gems_tributed=true・
##     ★ harm_committed は立たない (§14.5.7 非加害)。対比で人間捕虜朝貢は harm を立てる。
##   - gems 不足では tribute_gems は no-op。
##   - 献上 + アミナ + 無害 + 人間敵対低 で ending_route()==1 (中立善が実プレイ到達)。
##   - 新フィールド込みスナップショット往復。

func _init() -> void:
	var ok := true
	ok = _test_hoard_above_threshold() and ok
	ok = _test_hoard_below_threshold_baseline() and ok
	ok = _test_hoard_drift_capped() and ok
	ok = _test_tribute_gems_basic() and ok
	ok = _test_tribute_gems_not_harm() and ok
	ok = _test_tribute_gems_insufficient() and ok
	ok = _test_neutral_route_opens() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("GEMS_OK")
		quit(0)
	else:
		print("GEMS_FAIL")
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

## 閾値超過で人間敵対度が上昇する。
func _test_hoard_above_threshold() -> bool:
	var ok := true
	var w := _make_world()
	w.gems = w.params.gems_hoard_threshold + 10.0
	w.human_hostility = 0.0
	w._step_gems_hoard_drift()
	ok = _check(w.human_hostility > 0.0, "閾値超過で人間敵対度が上がる") and ok
	return ok

## 閾値以下では上がらない (baseline 不変 = 外征で宝石を集めなければ無発動)。
func _test_hoard_below_threshold_baseline() -> bool:
	var ok := true
	var w := _make_world()
	w.gems = w.params.gems_hoard_threshold  # ちょうど閾値 (超過 0)
	w.human_hostility = 0.0
	for i in range(w.params.ticks_per_day):
		w._step_gems_hoard_drift()
	ok = _check(abs(w.human_hostility) < 1e-9, "閾値以下では人間敵対度が動かない") and ok
	# gems=0 の通常プレイでも当然不変。
	w.gems = 0.0
	w._step_gems_hoard_drift()
	ok = _check(abs(w.human_hostility) < 1e-9, "宝石0では無発動 (baseline)") and ok
	return ok

## ため込みドリフトは 1 tick あたり上限でクランプ (大量保有でも青天井にしない)。
func _test_hoard_drift_capped() -> bool:
	var ok := true
	var w := _make_world()
	w.gems = w.params.gems_hoard_threshold + 100000.0  # 超過量を極端に
	w.human_hostility = 0.0
	w._step_gems_hoard_drift()
	ok = _check(w.human_hostility <= w.params.gems_hoard_hostility_max_per_tick + 1e-9,
			"ため込みドリフトは per-tick 上限でクランプ") and ok
	return ok

## 宝石献上: gems 減・人間敵対度低下・gems_tributed=true。
func _test_tribute_gems_basic() -> bool:
	var ok := true
	var w := _make_world()
	w.gems = 20.0
	w.human_hostility = 0.5
	var amt := w.params.gems_tribute_amount
	ok = _check(w.tribute_gems(amt), "宝石を献上できる") and ok
	ok = _check(abs(w.gems - (20.0 - amt)) < 1e-9, "献上ぶん宝石が減る") and ok
	ok = _check(w.human_hostility < 0.5, "献上で人間敵対度が下がる") and ok
	ok = _check(w.gems_tributed, "gems_tributed が立つ") and ok
	return ok

## ★ 宝石献上は非加害 (§14.5.7): harm_committed を立てない。対比で人間捕虜朝貢は立てる。
func _test_tribute_gems_not_harm() -> bool:
	var ok := true
	var w := _make_world()
	w.gems = 100.0
	for i in range(5):
		w.tribute_gems(w.params.gems_tribute_amount)
	ok = _check(not w.harm_committed, "宝石献上では harm_committed が立たない (非加害)") and ok
	# 対比: 人間捕虜の朝貢は加害として harm を立てる (加害判定の一元化の確認)。
	w.cap_male_human = 1.0
	ok = _check(w.tribute_captive("human"), "人間捕虜を朝貢できる") and ok
	ok = _check(w.harm_committed, "人間捕虜の朝貢は harm を立てる (対比)") and ok
	return ok

## 宝石不足では no-op。
func _test_tribute_gems_insufficient() -> bool:
	var ok := true
	var w := _make_world()
	w.gems = 1.0  # tribute_amount (5) 未満
	var before := w.human_hostility
	ok = _check(not w.tribute_gems(w.params.gems_tribute_amount), "宝石不足では献上できない") and ok
	ok = _check(abs(w.gems - 1.0) < 1e-9 and not w.gems_tributed, "no-op で状態が変わらない") and ok
	ok = _check(abs(w.human_hostility - before) < 1e-9, "敵対度も変わらない") and ok
	return ok

## 献上で中立善ルートが実プレイ到達可能になる (A3 ending_route の gems_tributed 条件)。
func _test_neutral_route_opens() -> bool:
	var ok := true
	var w := _make_world()
	w.gems = 200.0
	w.human_hostility = 0.4
	# 献上を重ねて人間敵対度を十分下げる。
	for i in range(30):
		if w.human_hostility <= 0.2:
			break
		w.tribute_gems(w.params.gems_tribute_amount)
	w.amina_joined = true
	# 無害 (harm 未確定) + アミナ + 宝石献上 + 人間敵対低 = 中立善。
	ok = _check(not w.harm_committed, "無害が保たれている") and ok
	ok = _check(w.gems_tributed, "宝石献上済み") and ok
	ok = _check(w.human_hostility <= 0.3, "人間敵対度が低い (%.3f)" % w.human_hostility) and ok
	ok = _check(w.ending_route() == 1, "中立善ルートに到達 (ending_route==1)") and ok
	return ok

## 新フィールド込みスナップショット往復 + 復元後 30 tick 決定性。
func _test_snapshot_roundtrip() -> bool:
	var ok := true
	var w := _make_world(11)
	w.gems = 25.0
	w.tribute_gems(w.params.gems_tribute_amount)
	for i in range(40):
		w.tick_once()
	var snap := w.snapshot()
	var w2 := World.new()
	w2.setup(w.params)
	w2.restore(snap)
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(snap),
			"宝石/献上状態込みの往復が一致する") and ok
	for i in range(30):
		w.tick_once()
		w2.tick_once()
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(w.snapshot()),
			"復元後 30 tick の決定性が一致する") and ok
	return ok
