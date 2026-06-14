extends SceneTree
## 中立ルート状態機械 + 難度 + 4 ルート判定 (§13/§14.5.7・A3) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_routes.gd
##   - 人間捕虜の消費系 (生贄/朝貢/苗床/奴隷妻) で harm_committed が立つ。
##   - 解放・ゴブリン捕虜の操作では立たない (保持/解放は非加害)。
##   - 難度が初期敵対度・助走窓 (最初の襲撃の早さ) に効く。
##   - ending_route の分類 (既定 HOSTILE / 三点セットで中立善 / 家畜化条件)。
##   - 新フィールドのスナップショット往復。

func _init() -> void:
	var ok := true
	ok = _test_harm_sacrifice() and ok
	ok = _test_harm_tribute() and ok
	ok = _test_harm_concubine() and ok
	ok = _test_no_harm_release_and_goblin() and ok
	ok = _test_difficulty() and ok
	ok = _test_ending_route() and ok
	ok = _test_snapshot_roundtrip() and ok
	if ok:
		print("ROUTES_OK")
		quit(0)
	else:
		print("ROUTES_FAIL")
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

## 人間捕虜の生贄で harm_committed が立つ (ゴブリン捕虜が無い状態で人間を生贄に)。
func _test_harm_sacrifice() -> bool:
	var ok := true
	var w := _make_world()
	w.cap_male_human = 1.0
	ok = _check(not w.harm_committed, "初期は harm 未確定") and ok
	ok = _check(w.sacrifice_captive(), "人間雄捕虜を生贄にできる") and ok
	ok = _check(w.harm_committed, "人間捕虜の生贄で harm が立つ") and ok
	return ok

## 人間捕虜の朝貢で harm が立つ (敵対度は下がるが中立は閉じる)。
func _test_harm_tribute() -> bool:
	var ok := true
	var w := _make_world()
	w.cap_female_human = 1.0
	w.human_hostility = 0.5
	ok = _check(w.tribute_captive("human"), "人間捕虜を朝貢できる") and ok
	ok = _check(w.harm_committed, "人間捕虜の朝貢で harm が立つ") and ok
	ok = _check(w.human_hostility < 0.5, "朝貢で人間敵対度は下がる") and ok
	return ok

## 人間捕虜を奴隷妻にすると harm が立つ。
func _test_harm_concubine() -> bool:
	var ok := true
	var w := _make_world()
	w.cap_female_human = 1.0
	# 雄ゴブリンの suitor を 1 体探す。
	var suitor: Goblin = null
	for g in w.goblins:
		if g.sex == Goblin.Sex.MALE and not g.is_child():
			suitor = g
			break
	ok = _check(suitor != null, "suitor (雄成体) がいる") and ok
	ok = _check(w.take_concubine(suitor.id, Goblin.Sex.FEMALE, true), "人間雌捕虜を奴隷妻にできる") and ok
	ok = _check(w.harm_committed, "人間捕虜の奴隷妻化で harm が立つ") and ok
	return ok

## 人間捕虜の解放・ゴブリン捕虜の消費では harm が立たない (保持/解放は非加害)。
func _test_no_harm_release_and_goblin() -> bool:
	var ok := true
	var w := _make_world()
	w.cap_male_human = 1.0
	ok = _check(w.release_human_captive(Goblin.Sex.MALE), "人間捕虜を解放できる") and ok
	ok = _check(not w.harm_committed, "解放では harm が立たない") and ok
	# ゴブリン捕虜の生贄・朝貢は harm 無関係。
	w.cap_male_goblin = 2.0
	ok = _check(w.sacrifice_captive(), "ゴブリン捕虜を生贄にできる") and ok
	ok = _check(w.tribute_captive("bunta"), "ゴブリン捕虜を朝貢できる") and ok
	ok = _check(not w.harm_committed, "ゴブリン捕虜の操作では harm が立たない") and ok
	return ok

## 難度が初期敵対度と助走窓 (最初の襲撃 tick) に効く。並は基準 (敵対度 0)。
func _test_difficulty() -> bool:
	var ok := true
	var easy := _make_world(7, 0)
	var normal := _make_world(7, 1)
	var hard := _make_world(7, 2)
	ok = _check(abs(normal.human_hostility) < 1e-9, "並は初期敵対度 0 (基準)") and ok
	ok = _check(abs(easy.human_hostility) < 1e-9, "易は初期敵対度 0 (並と同じ)") and ok
	ok = _check(hard.human_hostility > normal.human_hostility, "難は並より初期人間敵対度が高い") and ok
	ok = _check(hard.bunta_hostility > normal.bunta_hostility, "難は並より初期部族敵対度が高い") and ok
	# 助走窓: 難は最初の襲撃が早く (初期敵対度ぶん)、易は並より遅い (grace ぶん)。
	ok = _check(hard.next_big_raid_tick < normal.next_big_raid_tick, "難は最初の襲撃が早い") and ok
	ok = _check(easy.next_big_raid_tick > normal.next_big_raid_tick, "易は最初の襲撃が遅い (助走窓が長い)") and ok
	var p := SimParams.new()
	ok = _check(easy.next_big_raid_tick == normal.next_big_raid_tick \
			+ int(round(p.first_raid_grace_easy_days * p.ticks_per_day)),
			"易 = 並 + 助走窓 grace") and ok
	return ok

## ending_route: 既定 HOSTILE / 三点セットで中立善 / 家畜化条件で家畜化。
func _test_ending_route() -> bool:
	var ok := true
	var w := _make_world()
	ok = _check(w.ending_route() == 0, "既定は HOSTILE(0)") and ok
	# 中立善: アミナ加入 + 無害 + 宝石献上 + 人間敵対度低。
	w.amina_joined = true
	w.gems_tributed = true
	w.harm_committed = false
	w.human_hostility = 0.1
	ok = _check(w.ending_route() == 1, "三点セットで中立善(1)") and ok
	# 加害すると中立善は閉じる。
	w.harm_committed = true
	ok = _check(w.ending_route() != 1, "harm_committed で中立善は閉じる") and ok
	# 家畜化: 宝石献上 + 人間敵対低 + 部族敵対高 (アミナ/無害は問わない)。
	var w2 := _make_world()
	w2.gems_tributed = true
	w2.human_hostility = 0.1
	w2.bunta_hostility = 0.6
	ok = _check(w2.ending_route() == 2, "家畜化条件で家畜化(2)") and ok
	return ok

## 新フィールド込みのスナップショット往復 + 復元後 30 tick 決定性。
func _test_snapshot_roundtrip() -> bool:
	var ok := true
	var w := _make_world(11, 2)
	w.cap_male_human = 1.0
	w.sacrifice_captive()  # harm を立てておく
	w.gems_tributed = true
	for i in range(40):
		w.tick_once()
	var snap := w.snapshot()
	var w2 := World.new()
	w2.difficulty = 2
	w2.setup(w.params)
	w2.restore(snap)
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(snap),
			"ルート状態込みの往復が一致する") and ok
	ok = _check(w2.harm_committed and w2.gems_tributed, "harm/gems フラグが復元される") and ok
	for i in range(30):
		w.tick_once()
		w2.tick_once()
	ok = _check(JSON.stringify(w2.snapshot()) == JSON.stringify(w.snapshot()),
			"復元後 30 tick の決定性が一致する") and ok
	return ok
