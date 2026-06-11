extends SceneTree
## 奇跡 (§4) + トーテムランク連動 (§3) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_miracles.gd
##   - ランク導出・残高キャップ・シャーマン枠の連動。
##   - 奇跡 6 種 + 集合命令の発動と効果 (コスト消費・対象判定・持続と解除)。
##   - 新規フィールド (mud_walls / rally_point / enraged_ticks) のスナップショット往復。

func _init() -> void:
	var ok := true
	ok = _test_rank_and_cap() and ok
	ok = _test_lightning() and ok
	ok = _test_mites_blessing() and ok
	ok = _test_honor() and ok
	ok = _test_mud_wall() and ok
	ok = _test_rage() and ok
	ok = _test_summon() and ok
	ok = _test_rally() and ok
	ok = _test_snapshot_roundtrip_with_miracles() and ok
	if ok:
		print("MIRACLES_OK")
		quit(0)
	else:
		print("MIRACLES_FAIL")
		quit(1)

func _make_world(seed_v: int = 7) -> World:
	var p := SimParams.new()
	p.seed = seed_v
	var w := World.new()
	w.setup(p)
	return w

## ランク: 累計信仰のしきい値で上がり、残高キャップ・シャーマン枠・奇跡倍率が連動する。
func _test_rank_and_cap() -> bool:
	var w := _make_world()
	var ok := true
	if w.rank() != 0 or w.shaman_slots() != w.params.shaman_base_slots:
		print("  FAIL: 初期ランクは 0 / 枠は base のはず")
		ok = false
	w.cum_faith = float(w.params.rank_thresholds[1]) + 1.0
	if w.rank() != 2:
		print("  FAIL: しきい値 2 本超えでランク 2 のはず (got %d)" % w.rank())
		ok = false
	if w.shaman_slots() != w.params.shaman_base_slots + 2:
		print("  FAIL: シャーマン枠がランクに連動していない")
		ok = false
	if abs(w.miracle_mult() - (1.0 + w.params.miracle_rank_gain * 2.0)) > 1e-9:
		print("  FAIL: 奇跡倍率がランクに連動していない")
		ok = false
	# 残高はキャップで頭打ち・累計は積み続ける (§3 二重構造)。
	w.faith = w.faith_cap()
	var cum_before := w.cum_faith
	for i in range(int(w.params.ticks_per_day * 0.5)):
		w._step_faith()
	if w.faith > w.faith_cap() + 1e-9:
		print("  FAIL: 残高がキャップを超えた (%f > %f)" % [w.faith, w.faith_cap()])
		ok = false
	if w.cum_faith <= cum_before:
		print("  FAIL: キャップ中も累計は積まれるはず")
		ok = false
	return ok

## 稲妻: コスト消費 + ランク連動ダメージ。残高不足・対象不在は不発で無消費。
func _test_lightning() -> bool:
	var w := _make_world()
	var ok := true
	w.faith = 100.0
	w.cum_faith = 0.0  # ランク 0
	w._spawn_enemy_at_gate(0, false)
	var e: EnemyUnit = w.enemies[0]
	var faith_before := w.faith
	if not w.cast_lightning(e.id):
		print("  FAIL: 稲妻が発動しない")
		ok = false
	if abs((faith_before - w.faith) - w.params.lightning_cost) > 1e-9:
		print("  FAIL: 稲妻のコストが合わない")
		ok = false
	if e.hp > e.max_hp - w.params.lightning_damage + 1e-9:
		print("  FAIL: 稲妻のダメージが入っていない")
		ok = false
	w.faith = 0.0
	if w.cast_lightning(e.id):
		print("  FAIL: 残高不足で発動してはいけない")
		ok = false
	return ok

## 恵みのパン虫: 自然湧き上限 (mite_max) を超えて一斉に湧く。
func _test_mites_blessing() -> bool:
	var w := _make_world()
	var ok := true
	w.faith = 100.0
	if not w.cast_mites():
		print("  FAIL: パン虫の恵みが発動しない")
		ok = false
	if w.mites.size() < w.params.mite_blessing_count:
		print("  FAIL: パン虫が %d 匹湧くはず (got %d)" % [w.params.mite_blessing_count, w.mites.size()])
		ok = false
	if w.mites.size() <= w.params.mite_max:
		print("  FAIL: 奇跡は自然湧き上限を超えるはず")
		ok = false
	return ok

## 名誉ある死: 対象が激昂し、敵が尽きると解除される。ユニークは対象外。
func _test_honor() -> bool:
	var w := _make_world()
	var ok := true
	w.faith = 100.0
	var target: Goblin = null
	for g in w.goblins:
		if not g.is_unique and g.sex == Goblin.Sex.MALE:
			target = g
			break
	var chief: Goblin = null
	for g in w.goblins:
		if g.is_unique:
			chief = g
			break
	if w.cast_honor(chief.id):
		print("  FAIL: ユニーク (族長) は激昂の対象外のはず")
		ok = false
	if not w.cast_honor(target.id):
		print("  FAIL: 名誉ある死が発動しない")
		ok = false
	if target.state != Goblin.State.ENRAGED:
		print("  FAIL: 対象が激昂していない")
		ok = false
	if not w._can_fight(target):
		print("  FAIL: 激昂中は戦えるはず")
		ok = false
	# 敵不在の平時なら state_machine が次 tick で解除する。
	w.tick_once()
	if target.state == Goblin.State.ENRAGED:
		print("  FAIL: 敵不在で激昂が解除されるはず")
		ok = false
	return ok

## 泥の抱擁: 巣口が一時的に壁化して A* が塞がり、寿命で元のタイルへ戻る。
func _test_mud_wall() -> bool:
	var w := _make_world()
	var ok := true
	w.faith = 100.0
	var gate: Vector2i = w.map.gates[0]
	# 巣外の縁 → 巣口 が塞がる前は通れる。
	var outside := Vector2i(gate.x, 0)
	if Pathfinding.find_path(w.map, outside, w.map.totem).is_empty():
		print("  FAIL: (前提) 塞ぐ前は巣口経由で到達できるはず")
		ok = false
	if not w.cast_mud(gate.x, gate.y):
		print("  FAIL: 泥の抱擁が発動しない")
		ok = false
	if w.map.get_tile(gate.x, gate.y) != TileMapData.TileType.WALL:
		print("  FAIL: 巣口が壁化していない")
		ok = false
	if w.mud_walls.is_empty():
		print("  FAIL: mud_walls に記録されていない")
		ok = false
	# 寿命まで進めると元のタイル (GATE) へ戻る。
	for i in range(int(w.params.mud_wall_ticks) + 2):
		w.tick_once()
	if w.map.get_tile(gate.x, gate.y) != TileMapData.TileType.GATE:
		print("  FAIL: 泥壁が寿命で巣口へ戻っていない (tile=%d)" % w.map.get_tile(gate.x, gate.y))
		ok = false
	if not w.mud_walls.is_empty():
		print("  FAIL: 期限切れの泥壁が残っている")
		ok = false
	return ok

## 抑えられない怒り: 範囲内の敵が同士討ちし、互いに HP を削り合う。
func _test_rage() -> bool:
	var w := _make_world()
	var ok := true
	w.faith = 100.0
	# 敵 2 体を隣接させて配置。
	w._spawn_enemy_at_gate(0, false)
	w._spawn_enemy_at_gate(0, false)
	var e0: EnemyUnit = w.enemies[0]
	var e1: EnemyUnit = w.enemies[1]
	w._place(e0, w.map.totem + Vector2i(3, 0))
	w._place(e1, w.map.totem + Vector2i(4, 0))
	if not w.cast_rage(e0.x, e0.y):
		print("  FAIL: 抑えられない怒りが発動しない")
		ok = false
	if e0.enraged_ticks <= 0 or e1.enraged_ticks <= 0:
		print("  FAIL: 範囲内の敵が激昂していない")
		ok = false
	var hp_before := e0.hp + e1.hp
	w._resolve_combat()
	if e0.hp + e1.hp >= hp_before - 1e-9:
		print("  FAIL: 同士討ちで HP が削れていない")
		ok = false
	# 範囲外 (遠方) の敵には効かない。
	w._spawn_enemy_at_gate(1, false)
	var far: EnemyUnit = w.enemies[2]
	if far.enraged_ticks != 0:
		print("  FAIL: 範囲外の敵が激昂している")
		ok = false
	return ok

## 下僕召喚: 成体雄が 1 体増え、コストが重い (頭数上限の対象 = 巣立ちで流出し得る)。
func _test_summon() -> bool:
	var w := _make_world()
	var ok := true
	w.faith = 100.0
	var pop_before := w._alive_count()
	var faith_before := w.faith
	if not w.cast_summon(w.map.totem.x, w.map.totem.y - 2):
		print("  FAIL: 下僕召喚が発動しない")
		ok = false
	if w._alive_count() != pop_before + 1:
		print("  FAIL: 頭数が 1 増えるはず")
		ok = false
	var newest: Goblin = w.goblins[w.goblins.size() - 1]
	if newest.origin != Goblin.Origin.SUMMONED or newest.is_child():
		print("  FAIL: 召喚個体は成体・出自 SUMMONED のはず")
		ok = false
	if abs((faith_before - w.faith) - w.params.summon_cost) > 1e-9:
		print("  FAIL: 召喚コストが合わない")
		ok = false
	return ok

## 集合命令: 平時の手すきが地点へ寄り、解除で通常へ戻る。無料。
func _test_rally() -> bool:
	var w := _make_world()
	var ok := true
	var spot: Vector2i = w.map.totem + Vector2i(0, -4)
	var faith_before := w.faith
	if not w.cast_rally(spot.x, spot.y):
		print("  FAIL: 集合命令が発動しない")
		ok = false
	if abs(w.faith - faith_before) > 1e-9:
		print("  FAIL: 集合命令は無料のはず")
		ok = false
	# 数 tick 進めて WANDER/WORK の個体が地点へ寄っているか (近づいていれば良い)。
	var before_avg := _avg_dist_to(w, spot)
	for i in range(int(w.params.ticks_per_day * 0.1)):
		w.tick_once()
	var after_avg := _avg_dist_to(w, spot)
	if after_avg >= before_avg:
		print("  FAIL: 集合で平均距離が縮むはず (%f -> %f)" % [before_avg, after_avg])
		ok = false
	w.rally_clear()
	if w.rally_point != Vector2i(-1, -1):
		print("  FAIL: 解除されていない")
		ok = false
	return ok

func _avg_dist_to(w: World, p: Vector2i) -> float:
	var total := 0.0
	var n := 0
	for g in w.goblins:
		if g.state == Goblin.State.WANDER or g.state == Goblin.State.WORK:
			total += float(w._manhattan(g.pos(), p))
			n += 1
	return total / max(1, n)

## 新規フィールド込みのスナップショット往復 (KI-09)。
func _test_snapshot_roundtrip_with_miracles() -> bool:
	var w := _make_world()
	w.faith = 100.0
	var gate: Vector2i = w.map.gates[1]
	w.cast_mud(gate.x, gate.y)
	w.cast_rally(w.map.totem.x, w.map.totem.y - 4)
	w._spawn_enemy_at_gate(0, false)
	w.cast_rage(w.enemies[0].x, w.enemies[0].y)
	for i in range(20):
		w.tick_once()
	# 既存の保証 (test_smoke と同じ規律): ライブ Dictionary からの復元で、
	# 復元後も同じに進むこと。※JSON ファイル経由は int→float 正規化が未整備
	# (rooms 等の既存フィールド共通の宿題) なので対象外。
	var snap := w.snapshot()
	var w2 := World.new()
	w2.setup(w.params)
	w2.restore(snap)
	if JSON.stringify(w2.snapshot()) != JSON.stringify(snap):
		print("  FAIL: 奇跡フィールド込みの往復が一致しない")
		return false
	for i in range(30):
		w.tick_once()
		w2.tick_once()
	if JSON.stringify(w.snapshot()) != JSON.stringify(w2.snapshot()):
		print("  FAIL: 復元後の進行が一致しない (決定性)")
		return false
	return true
