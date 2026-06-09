extends RefCounted
class_name World
## World 層 (§3 / world.ts の α版移植)。全個体を 1 tick 進め、移動・戦闘解決・
## 出生・事故死・襲撃スケジュール・昼夜・ラストバトルを処理する。
##
## 純関数ではなく内部状態を持つが、tick() の中身はステップを明確に分離し、
## RNG は self.rng のみを消費 (KI-09 決定性)。全状態は snapshot() で保存できる。

enum Phase { PEACE, OMEN, COMBAT }
enum Outcome { ONGOING, VICTORY, DEFEAT }

var params: SimParams
var rng: Rng
var map: TileMapData
var goblins: Array = []        # Array[Goblin]
var enemies: Array = []        # Array[EnemyUnit]
var next_goblin_id: int = 0
var next_enemy_id: int = 0

var tick: int = 0
var day: int = 0
var phase: int = Phase.PEACE
var faith: float = 0.0
var cum_faith: float = 0.0
var food: float = 20.0
var surge: float = 0.0         # 損耗時バフ残量 (§2.5 / KI-04)
var over_cap_ticks: int = 0
var next_big_raid_tick: int = 0
var raid_is_human: bool = false
var raid_start_hp: float = 0.0
var outcome: int = Outcome.ONGOING

# ログ (UI / デバッグ用)。
var deaths_total: int = 0
var births_total: int = 0
var last_events: Array = []    # Array[String] 直近イベント

# --- 初期化 ---
func setup(p: SimParams) -> void:
	params = p
	rng = Rng.new(p.seed)
	map = MapTemplate.make_initial_map()
	goblins = []
	enemies = []
	next_goblin_id = 0
	tick = 0
	day = 0
	phase = Phase.PEACE
	faith = 0.0
	food = 20.0
	outcome = Outcome.ONGOING
	_schedule_next_raid()

	# 初期ゴブリンを巣内に配置。雌雄比は 7:3 (世界観バイブル)。
	var nest_center := map.totem + Vector2i(0, -4)
	for i in range(p.start_goblins):
		var sex := Goblin.Sex.FEMALE if rng.next_float() < 0.3 else Goblin.Sex.MALE
		var g := _make_goblin(sex, Goblin.Role.NONE, Goblin.Origin.FOUNDER)
		var spot := _find_floor_near(nest_center, 6)
		g.x = spot.x
		g.y = spot.y
		goblins.append(g)
	# 族長を任命 (恐怖なしの盾 §8)。最初の雄を族長に。
	for g in goblins:
		if g.sex == Goblin.Sex.MALE:
			g.role = Goblin.Role.CHIEF
			g.is_unique = true
			g.max_hp = 20.0
			g.hp = 20.0
			break
	# ネズミ牧場に数体割り当て (食料生産 §3-11)。
	_assign_to_room(TileMapData.RoomType.RAT_RANCH, 3)

func _make_goblin(sex: int, role: int, origin: int) -> Goblin:
	var g := Goblin.new()
	g.id = next_goblin_id
	next_goblin_id += 1
	g.sex = sex
	g.role = role
	g.origin = origin
	g.max_hp = 8.0 if sex == Goblin.Sex.FEMALE else 10.0
	g.hp = g.max_hp
	g.born_tick = tick
	# 性別ごとのデフォルト性格 (世界観バイブルの気質)。
	if sex == Goblin.Sex.FEMALE:
		g.fear_hp_bias = 0.25 + rng.next_float() * 0.1
		g.forage_bias = 0.6 + rng.next_float() * 0.3
		g.work_bias = -0.1 + rng.next_float() * 0.2
	else:
		g.fear_hp_bias = -0.2 + rng.next_float() * 0.15
		g.work_bias = 0.15 + rng.next_float() * 0.25
	g.x = map.totem.x
	g.y = map.totem.y - 4
	return g

# --- メイン: 1 tick 進める ---
func tick_once() -> void:
	if outcome != Outcome.ONGOING:
		return
	last_events.clear()
	tick += 1
	var day_tick := tick % params.ticks_per_day
	if day_tick == 0:
		day += 1
		_on_day_boundary()

	_update_raid_schedule()
	_step_enemies()
	_step_goblins()
	_resolve_combat()
	_step_breeding()
	_step_accidents()
	_step_food()
	_step_faith()
	_cleanup_dead()
	_step_fledge()
	_check_outcome()

func is_day() -> bool:
	return (tick % params.ticks_per_day) < params.day_ticks

# --- 日境界 ---
func _on_day_boundary() -> void:
	if surge > 0.0:
		surge = max(0.0, surge - params.surge_decay)
	if day >= params.final_day:
		_log("最終日: ラストバトル!")
		_spawn_raid(true, true)  # ラストバトル

# --- 襲撃スケジュール (§3-5 / §3-7) ---
func _schedule_next_raid() -> void:
	# 敵対度は α版では固定中庸 (人間加害なし)。間隔は平和寄り。
	var interval_days := params.big_raid_interval_peace
	next_big_raid_tick = tick + interval_days * params.ticks_per_day

func _update_raid_schedule() -> void:
	# 大規模襲撃の発火。
	if phase == Phase.PEACE and tick >= next_big_raid_tick and day < params.final_day:
		_spawn_raid(false, rng.next_float() < 0.5)
		_schedule_next_raid()
	# 小規模襲撃 (恵み): 1 日 1 回判定、平時のみ。
	if phase == Phase.PEACE and (tick % params.ticks_per_day) == params.day_ticks / 2:
		if rng.next_float() < params.small_raid_prob:
			_spawn_raid_small()

func _spawn_raid(final_battle: bool, human: bool) -> void:
	phase = Phase.COMBAT
	raid_is_human = human
	raid_start_hp = _total_hp()
	var count := int(params.base_enemies + params.enemy_per_day * day)
	if final_battle:
		count = int(count * params.final_mult)
	_log("大規模襲撃: 敵 %d 体" % count)
	# 全巣口に部隊を分散 (§3-14)。
	for i in range(count):
		var gate_idx := i % map.gates.size()
		_spawn_enemy_at_gate(gate_idx, human)

func _spawn_raid_small() -> void:
	# 小規模は無作為 1 巣口のみ。準自動・少数。
	var count := 1 + rng.next_int(2)
	var gate_idx := rng.next_int(map.gates.size())
	phase = Phase.COMBAT
	raid_is_human = false
	raid_start_hp = _total_hp()
	_log("小規模襲撃: 敵 %d 体 (恵み)" % count)
	for i in range(count):
		_spawn_enemy_at_gate(gate_idx, false)

func _spawn_enemy_at_gate(gate_idx: int, human: bool) -> void:
	var e := EnemyUnit.new()
	e.id = next_enemy_id
	next_enemy_id += 1
	e.max_hp = params.enemy_hp
	e.hp = e.max_hp
	e.target_gate_idx = gate_idx
	e.is_human = human
	# マップ外周 3 タイル外にスポーン (§3-14)。巣口の方向に応じて外側へ。
	var gate: Vector2i = map.gates[gate_idx]
	var dir := (gate - Vector2i(map.width / 2, map.height / 2))
	var spawn := gate
	if abs(dir.x) > abs(dir.y):
		spawn.x = (map.width + 2) if dir.x > 0 else -3
	else:
		spawn.y = (map.height + 2) if dir.y > 0 else -3
	e.x = clampi(spawn.x, -3, map.width + 2)
	e.y = clampi(spawn.y, -3, map.height + 2)
	enemies.append(e)

# --- 敵の移動・侵入 (§3-14) ---
func _step_enemies() -> void:
	for e in enemies:
		# 目標: 巣口未到達なら巣口、到達後は最近接ゴブリン or トーテム。
		var target: Vector2i
		var gate: Vector2i = map.gates[e.target_gate_idx]
		if not _inside_nest(e.pos()):
			target = gate
		else:
			var tg := _nearest_goblin_pos(e.pos())
			target = tg if tg != Vector2i(-1, -1) else map.totem
		_advance_along_path(e, target)

# --- ゴブリンの移動 (§3-0 ステート対応) ---
func _step_goblins() -> void:
	var in_raid := phase == Phase.COMBAT and not enemies.is_empty()
	for g in goblins:
		if g.state == Goblin.State.DEAD:
			continue
		var ctx := StateMachine.Context.new()
		ctx.in_raid = in_raid
		ctx.enemy_nearby = _enemy_near(g.pos(), 4)
		ctx.assigned_to_combat = (g.sex == Goblin.Sex.MALE or g.is_unique)
		ctx.food_available = food > 0.0 and _at_storage(g.pos())
		StateMachine.step(g, ctx, params)

		if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT:
			continue
		var target := _movement_target(g)
		if target != Vector2i(-1, -1):
			_advance_along_path(g, target)

# ステートに応じた移動目標 (§3-0 対応表)。
func _movement_target(g: Goblin) -> Vector2i:
	match g.state:
		Goblin.State.COMBAT:
			var ep := _nearest_enemy_pos(g.pos())
			return ep
		Goblin.State.FEAR:
			return _flee_target(g.pos())
		Goblin.State.DYING, Goblin.State.SLEEP:
			return _nearest_room_tile(g.pos(), TileMapData.RoomType.NEST)
		Goblin.State.HUNGRY:
			return map.storage
		Goblin.State.WORK:
			return _work_target(g)
		Goblin.State.WANDER:
			# ランダムな通行可タイル (巣内)。たまにだけ更新。
			if g.path.is_empty() and rng.next_float() < 0.2:
				return _random_nest_floor()
			return Vector2i(-1, -1)
		_:
			return Vector2i(-1, -1)

func _work_target(g: Goblin) -> Vector2i:
	# 役職に応じた作業場所。族長/シャーマンはトーテム付近、牧場係は牧場へ。
	if g.role == Goblin.Role.CHIEF or g.role == Goblin.Role.SHAMAN:
		return map.totem + Vector2i(0, -2)
	for r in map.rooms:
		if (g.id in r.assigned):
			return Vector2i(r.x + r.w / 2, r.y + r.h / 2)
	return Vector2i(-1, -1)

# 1 tick で path に沿って 1 タイル進む。target 変更時のみ再計算 (§3-0)。
func _advance_along_path(unit, target: Vector2i) -> void:
	if target == Vector2i(-1, -1):
		return
	if unit.target_x != target.x or unit.target_y != target.y or unit.path.is_empty():
		unit.target_x = target.x
		unit.target_y = target.y
		unit.path = Pathfinding.find_path(map, unit.pos(), target)
	if not unit.path.is_empty():
		var step: Vector2i = unit.path.pop_front()
		unit.x = step.x
		unit.y = step.y

# --- 戦闘解決 (§3-13: 8 隣接で攻撃) ---
func _resolve_combat() -> void:
	if enemies.is_empty():
		if phase == Phase.COMBAT:
			_end_raid()
		return
	# ゴブリン → 敵。
	for g in goblins:
		if not _can_fight(g):
			continue
		var e := _adjacent_enemy(g.pos())
		if e != null:
			var atk := params.goblin_attack
			if g.equipped:
				atk *= (1.0 + params.equip_bonus)
			if g.is_unique:
				atk *= 1.5
			e.hp -= atk
	# 敵 → ゴブリン。
	for e in enemies:
		var g := _adjacent_goblin(e.pos())
		if g != null:
			g.hp -= params.enemy_attack
	# 死んだ敵を除去。
	var alive: Array = []
	for e in enemies:
		if e.hp > 0.0:
			alive.append(e)
		else:
			# 撃退報酬: 食料少々 (恵み)。
			food += 1.0
	enemies = alive
	if enemies.is_empty():
		_end_raid()

func _can_fight(g: Goblin) -> bool:
	if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT:
		return false
	if g.state == Goblin.State.FEAR or g.state == Goblin.State.DYING:
		return false
	# 雌は戦線に立たない (恐怖閾値が高い / 産み手の保護 §8)。
	if g.sex == Goblin.Sex.FEMALE and not g.is_unique:
		return false
	return true

func _end_raid() -> void:
	phase = Phase.PEACE
	# 損耗時バフ (§2.5 / KI-04): この戦闘の HP 損失割合が閾値超なら surge 発火。
	var lost_frac := 0.0
	if raid_start_hp > 0.0:
		lost_frac = (raid_start_hp - _total_hp()) / raid_start_hp
	if lost_frac > params.surge_trigger:
		surge = min(params.surge_max, surge + params.surge_gain * lost_frac)
		_log("損耗バフ発火 (損耗 %.0f%%)" % (lost_frac * 100.0))

# --- 増殖 (§3-6) ---
func _step_breeding() -> void:
	# 妊娠の進行と出産。
	for g in goblins.duplicate():
		if g.pregnant:
			g.pregnant_ticks += 1
			if g.pregnant_ticks >= params.pregnancy_ticks:
				_give_birth(g)
		# 子の成体化。
		if g.is_child() and (tick - g.child_born_tick) >= params.child_grow_ticks:
			g.child_born_tick = -1

	# 求愛: 雌が起点 (雌律速)。平時かつ昼のみ。
	if phase != Phase.PEACE or not is_day():
		return
	for f in goblins:
		if f.sex != Goblin.Sex.FEMALE or f.pregnant or f.is_child():
			continue
		if f.state == Goblin.State.DEAD or f.state == Goblin.State.FEAR:
			continue
		# 損耗バフで妊娠率を乗算 (§2.5 必須骨格)。
		var chance := params.court_base_chance * (1.0 + surge)
		if rng.next_float() < chance:
			# 相手の雄を探す (近場優先・相性で確率)。
			var mate := _find_mate(f)
			if mate != null and rng.next_float() < (0.3 + Goblin.compatibility(f, mate) * 0.7):
				f.pregnant = true
				f.pregnant_ticks = 0
				f.mate_id = mate.id

func _find_mate(f: Goblin) -> Goblin:
	var best: Goblin = null
	var best_d := 999999
	for m in goblins:
		if m.sex != Goblin.Sex.MALE or m.is_child() or m.bereaved:
			continue
		if m.state == Goblin.State.DEAD:
			continue
		var d := _manhattan(f.pos(), m.pos())
		if d < best_d:
			best_d = d
			best = m
	return best

func _give_birth(mother: Goblin) -> void:
	mother.pregnant = false
	mother.pregnant_ticks = 0
	# 頭数上限を超えるなら産まない (二段収束)。
	if _alive_count() >= params.cap_pop:
		return
	var litter := _roll_litter()
	for i in range(litter):
		if _alive_count() >= params.cap_pop:
			break
		var sex := Goblin.Sex.FEMALE if rng.next_float() < 0.3 else Goblin.Sex.MALE
		var baby := _make_goblin(sex, Goblin.Role.NONE, Goblin.Origin.BORN)
		baby.child_born_tick = tick
		baby.mother_id = mother.id
		baby.father_id = mother.mate_id
		baby.x = mother.x
		baby.y = mother.y
		baby.max_hp *= 0.5  # 子は脆い
		baby.hp = baby.max_hp
		goblins.append(baby)
		births_total += 1

func _roll_litter() -> int:
	var r := rng.next_float()
	var acc := 0.0
	for i in range(params.litter_weights.size()):
		acc += params.litter_weights[i]
		if r < acc:
			return i + 1
	return params.litter_weights.size()

# --- 事故死 (§3-3: ステートマシン外の独立レイヤー) ---
func _step_accidents() -> void:
	for g in goblins:
		if g.state != Goblin.State.WANDER:
			continue
		if g.is_unique:
			continue  # ユニークは事故死無効 (§8)
		if rng.next_float() < params.accident_prob:
			g.hp = 0.0
			g.state = Goblin.State.DEAD
			_log("事故死: #%d" % g.id)

# --- 食料 (§3-11) ---
func _step_food() -> void:
	# 生産: ネズミ牧場の割当数 × レート。
	var ranchers := 0
	for r in map.rooms:
		if r.room_type == TileMapData.RoomType.RAT_RANCH:
			ranchers += (r.assigned as Array).size()
	food += ranchers * params.food_per_rancher_tick
	# 消費は state_machine が food_available 経由で行うが、集積所での実消費を反映。
	for g in goblins:
		if g.state == Goblin.State.HUNGRY and _at_storage(g.pos()) and food > 0.0:
			food = max(0.0, food - params.food_eat_amount)

func _step_faith() -> void:
	var shamans := 0
	for g in goblins:
		if g.role == Goblin.Role.SHAMAN or g.role == Goblin.Role.CHIEF:
			shamans += 1
	var gain := shamans * params.faith_per_shaman_tick
	faith += gain
	cum_faith += gain

# --- 死亡の一元化 (KI-20) ---
func _cleanup_dead() -> void:
	var alive: Array = []
	for g in goblins:
		if g.state == Goblin.State.DEAD:
			deaths_total += 1
		else:
			alive.append(g)
	goblins = alive

# --- 巣立ち (§2.5 安全弁) ---
func _step_fledge() -> void:
	if phase != Phase.PEACE:
		over_cap_ticks = 0
		return
	if _alive_count() > params.cap_pop:
		over_cap_ticks += 1
		if over_cap_ticks >= params.fledge_grace_ticks:
			# 無役の成体を 1 体巣立ちさせる。
			for g in goblins:
				if g.role == Goblin.Role.NONE and not g.is_child() and not g.is_unique:
					g.state = Goblin.State.DEAD  # 巣から除外 (cleanup で消える)
					_log("巣立ち: #%d" % g.id)
					break
			over_cap_ticks = 0
	else:
		over_cap_ticks = 0

# --- 勝敗判定 ---
func _check_outcome() -> void:
	if _alive_count() == 0:
		outcome = Outcome.DEFEAT
		_log("全滅 — 敗北")
		return
	if map.get_tile(map.totem.x, map.totem.y) != TileMapData.TileType.TOTEM:
		outcome = Outcome.DEFEAT
		_log("トーテム破壊 — 敗北")
		return
	# ラストバトル撃退でクリア。
	if day >= params.final_day and phase == Phase.PEACE and enemies.is_empty():
		outcome = Outcome.VICTORY
		_log("ラストバトル撃退 — 勝利!")

# === ヘルパ ===
func _alive_count() -> int:
	var n := 0
	for g in goblins:
		if g.state != Goblin.State.DEAD:
			n += 1
	return n

func _total_hp() -> float:
	var s := 0.0
	for g in goblins:
		if g.state != Goblin.State.DEAD:
			s += g.hp
	return s

func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _inside_nest(p: Vector2i) -> bool:
	return map.in_bounds(p.x, p.y) and map.get_tile(p.x, p.y) != TileMapData.TileType.EXTERIOR

func _enemy_near(p: Vector2i, radius: int) -> bool:
	for e in enemies:
		if _manhattan(p, e.pos()) <= radius:
			return true
	return false

func _adjacent_enemy(p: Vector2i) -> EnemyUnit:
	for e in enemies:
		if max(abs(p.x - e.x), abs(p.y - e.y)) <= 1:
			return e
	return null

func _adjacent_goblin(p: Vector2i) -> Goblin:
	for g in goblins:
		if g.state == Goblin.State.DEAD:
			continue
		if max(abs(p.x - g.x), abs(p.y - g.y)) <= 1:
			return g
	return null

func _nearest_enemy_pos(p: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var bd := 999999
	for e in enemies:
		var d := _manhattan(p, e.pos())
		if d < bd:
			bd = d
			best = e.pos()
	return best

func _nearest_goblin_pos(p: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var bd := 999999
	for g in goblins:
		if g.state == Goblin.State.DEAD:
			continue
		var d := _manhattan(p, g.pos())
		if d < bd:
			bd = d
			best = g.pos()
	return best

func _flee_target(p: Vector2i) -> Vector2i:
	# 敵から最も遠い巣内タイル (簡易: トーテム方向へ退避)。
	return map.totem + Vector2i(0, -2)

func _nearest_room_tile(p: Vector2i, room_type: int) -> Vector2i:
	for r in map.rooms:
		if r.room_type == room_type:
			return Vector2i(r.x + r.w / 2, r.y + r.h / 2)
	return map.totem + Vector2i(0, -3)

func _at_storage(p: Vector2i) -> bool:
	return max(abs(p.x - map.storage.x), abs(p.y - map.storage.y)) <= 1

func _find_floor_near(center: Vector2i, radius: int) -> Vector2i:
	for attempt in range(20):
		var dx := rng.next_int(radius * 2 + 1) - radius
		var dy := rng.next_int(radius * 2 + 1) - radius
		var p := center + Vector2i(dx, dy)
		if map.is_walkable(p.x, p.y) and map.get_tile(p.x, p.y) == TileMapData.TileType.FLOOR:
			return p
	return center

func _random_nest_floor() -> Vector2i:
	return _find_floor_near(map.totem + Vector2i(0, -4), 8)

func _assign_to_room(room_type: int, count: int) -> void:
	var assigned := 0
	for r in map.rooms:
		if r.room_type != room_type:
			continue
		for g in goblins:
			if assigned >= count:
				return
			if g.role == Goblin.Role.NONE and not g.is_unique and not (g.id in r.assigned):
				r.assigned.append(g.id)
				assigned += 1

func _log(msg: String) -> void:
	last_events.append(msg)

# --- スナップショット (KI-09) ---
func snapshot() -> Dictionary:
	return {
		"tick": tick, "day": day, "phase": phase,
		"faith": faith, "cum_faith": cum_faith, "food": food,
		"surge": surge, "over_cap_ticks": over_cap_ticks,
		"next_big_raid_tick": next_big_raid_tick,
		"raid_is_human": raid_is_human, "raid_start_hp": raid_start_hp,
		"outcome": outcome, "next_goblin_id": next_goblin_id,
		"next_enemy_id": next_enemy_id,
		"deaths_total": deaths_total, "births_total": births_total,
		"rng": rng.snapshot(),
		"map": map.snapshot(),
		"goblins": goblins.map(func(g): return g.snapshot()),
		"enemies": enemies.map(func(e): return e.snapshot()),
	}

func restore(d: Dictionary) -> void:
	tick = d.tick; day = d.day; phase = d.phase
	faith = d.faith; cum_faith = d.cum_faith; food = d.food
	surge = d.surge; over_cap_ticks = d.over_cap_ticks
	next_big_raid_tick = d.next_big_raid_tick
	raid_is_human = d.raid_is_human; raid_start_hp = d.raid_start_hp
	outcome = d.outcome; next_goblin_id = d.next_goblin_id
	next_enemy_id = d.next_enemy_id
	deaths_total = d.deaths_total; births_total = d.births_total
	rng.restore(d.rng)
	map.restore(d.map)
	goblins = (d.goblins as Array).map(func(x): return Goblin.from_snapshot(x))
	enemies = (d.enemies as Array).map(func(x): return EnemyUnit.from_snapshot(x))
