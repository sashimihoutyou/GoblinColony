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
var mites: Array = []          # Array[MiteUnit] (パン虫 §3-11)
var next_goblin_id: int = 0
var next_enemy_id: int = 0
var next_mite_id: int = 0

var tick: int = 0
var day: int = 0
var phase: int = Phase.PEACE
var totem_hp: float = 60.0     # トーテム耐久 (§3-20。0 で破壊 = 敗北。平時に修繕)
var faith: float = 0.0
var cum_faith: float = 0.0
var food: float = 15.0
var surge: float = 0.0         # 損耗時バフ残量 (§2.5 / KI-04)
var over_cap_ticks: int = 0
var next_big_raid_tick: int = 0
var raid_is_human: bool = false
var raid_start_hp: float = 0.0
var outcome: int = Outcome.ONGOING

# ログ (UI / デバッグ用)。
var deaths_total: int = 0
var births_total: int = 0
# 直近イベント (Array[Dictionary])。1 tick ごとにクリア。UI 側が名前等へ整形する。
# 例: {"t":"raid","count":5,"human":false,"final":false} / {"t":"death","id":3,"sex":0,"cause":"combat"}
var last_events: Array = []

# 床タイルの派生キャッシュ (スナップショット対象外。map から決定的に再構築できる)。
# 放浪先・避難/作業/食事スロットの選択に使う。
var _nest_floors: Array = []       # 巣内の全 FLOOR タイル
var _hall_floors: Array = []       # トーテム周辺の床 (儀式・休憩スロット)
var _totem_ring: Array = []        # トーテムの周囲 2 重の輪 (防衛陣形スロット)
var _totem_core: Array = []        # トーテム隣接 8 タイル (非戦闘員の避難所)
var _room_floors: Dictionary = {}  # rooms の index → その部屋の床タイル配列

# --- 初期化 ---
func setup(p: SimParams) -> void:
	params = p
	rng = Rng.new(p.seed)
	map = MapTemplate.make_initial_map()
	goblins = []
	enemies = []
	mites = []
	next_goblin_id = 0
	next_enemy_id = 0
	next_mite_id = 0
	tick = 0
	day = 0
	phase = Phase.PEACE
	totem_hp = p.totem_hp_max
	faith = 0.0
	food = 15.0
	outcome = Outcome.ONGOING
	_rebuild_floor_caches()
	_schedule_next_raid()

	# 初期ゴブリンを巣内に配置。雌雄比は 7:3 (世界観バイブル)。
	var nest_center := map.totem + Vector2i(0, -3)
	for i in range(p.start_goblins):
		var sex := Goblin.Sex.FEMALE if rng.next_float() < 0.3 else Goblin.Sex.MALE
		var g := _make_goblin(sex, Goblin.Role.NONE, Goblin.Origin.FOUNDER)
		_place(g, _find_floor_near(nest_center, 5))
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
	_place(g, map.totem + Vector2i(0, -3))
	return g

## 整数タイルへスナップして配置する (fx/fy も同期)。
func _place(unit, p: Vector2i) -> void:
	unit.x = p.x
	unit.y = p.y
	unit.fx = float(p.x)
	unit.fy = float(p.y)

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
	_step_mites()
	_step_goblins()
	_resolve_combat()
	_step_breeding()
	_step_accidents()
	_step_food()
	_step_starvation()
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
	_rebalance_ranch()
	# ラストバトルは最終日に一度だけ (>= だと日境界ごとに多重スポーンしていた)。
	if day == params.final_day:
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
	_event({"t": "raid", "count": count, "human": human, "final": final_battle})
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
	_event({"t": "raid_small", "count": count})
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
	# マップ縁 (範囲内の外部地面) にスポーンし、巣口へ向かって歩いてくる (§3-14)。
	# 範囲外に置くと A* が開始点を歩行不可とみなし一歩も動けない (旧バグ:
	# 襲撃が永遠に決着せず phase=COMBAT のまま増殖も勝敗も止まっていた)。
	var gate: Vector2i = map.gates[gate_idx]
	var dir := (gate - Vector2i(map.width / 2, map.height / 2))
	var spawn := gate
	if abs(dir.x) > abs(dir.y):
		spawn.x = (map.width - 1) if dir.x > 0 else 0
	else:
		spawn.y = (map.height - 1) if dir.y > 0 else 0
	_place(e, Vector2i(clampi(spawn.x, 0, map.width - 1), clampi(spawn.y, 0, map.height - 1)))
	enemies.append(e)

# --- 敵の移動・侵入 (§3-14) ---
func _step_enemies() -> void:
	# 衝突 (敵同士): 同じタイルへ重ならない。重なりを許すと巣内で 1 つの
	# 「死の弾塊」になり、坑道の隘路も防衛陣形も素通しになる。先頭が止まれば
	# 後続は坑道に隊列で詰まる (隘路防衛が成立する)。
	var occ := {}
	for e in enemies:
		occ[e.pos()] = (occ.get(e.pos(), 0) as int) + 1
	for e in enemies:
		# 白兵は足を止めて殴り合う (隣接中は移動しない)。追いかけ合いのまま
		# 殴ると隣接が明滅し、互いの DPS が出ず戦闘が間延びする。
		if _adjacent_goblin(e.pos()) != null:
			continue
		# 目標: 巣口未到達なら巣口。侵入後はトーテム (襲撃の目的 §3-20) へ進軍し、
		# 視界内 (6 タイル) のゴブリンにだけ襲いかかる。逃げる個体を地の果てまで
		# 追わせると、戦えない恐怖個体の処刑行進になり群れが必ず壊滅する。
		var target: Vector2i
		var gate: Vector2i = map.gates[e.target_gate_idx]
		if not _inside_nest(e.pos()):
			target = gate
		else:
			var tg := _nearest_goblin_pos(e.pos())
			if tg != Vector2i(-1, -1) and _manhattan(e.pos(), tg) <= 6:
				target = tg
			else:
				# トーテムの周囲 8 タイルへ id ハッシュで散開して包囲する。
				target = map.totem + OFFS8[_slot_hash(e.id) % 8]
				if not map.is_walkable(target.x, target.y):
					target = map.totem
		var before: Vector2i = e.pos()
		_advance_along_path(e, target, params.enemy_move_per_tick, occ)
		if e.pos() != before:
			occ[before] = (occ.get(before, 0) as int) - 1
			occ[e.pos()] = (occ.get(e.pos(), 0) as int) + 1

# --- パン虫 (§3-11 救済床の実体化) ---
# 巣内の床に自然湧きし、ランダムにうろつくだけの食用ザコ。攻撃しない。
# 空腹ゴブリンが視界内に見つけると狩りに向かい、隣接で捕食される (即時満腹)。
# 狩り = 食事の解決は世界側 (_step_goblins) が隣接判定で行う (ここは湧き・移動のみ)。
func _step_mites() -> void:
	# RNG 消費は固定順: 湧き判定 (上限未満のときのみ) → 各 mite の行き先再抽選。
	# enemies/goblins より先に確定し、同 tick 内でゴブリンが現在位置を狙えるようにする。
	if mites.size() < params.mite_max and rng.next_float() < params.mite_spawn_per_tick:
		var m := MiteUnit.new()
		m.id = next_mite_id
		next_mite_id += 1
		_place(m, _random_nest_floor())
		mites.append(m)
	for m in mites:
		# うろつき: パスが尽きたらたまに次の行き先を引く (ゴブリンの WANDER と同じ規約)。
		if m.path.is_empty():
			if rng.next_float() < params.mite_retarget_per_tick:
				_advance_along_path(m, _random_nest_floor(), params.mite_move_per_tick)
		else:
			_advance_along_path(m, Vector2i(m.target_x, m.target_y), params.mite_move_per_tick)

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
		ctx.assigned_to_room = _has_room_assignment(g.id)
		# 隣接 (8 近傍) のパン虫を狩れる。mite は各個体のループ内で都度取得するため、
		# 同 tick に 2 体が同じ 1 匹を食べる二重計上は起きない (食べた時点で erase)。
		var mite := _nearest_mite(g.pos(), 1)
		ctx.food_available = (food > 0.0 and _at_storage(g.pos())) or mite != null
		ctx.food_in_stock = food > 0.0
		var hunger_before: float = g.hunger
		StateMachine.step(g, ctx, params)
		if ctx.food_available and g.state == Goblin.State.HUNGRY and g.hunger < hunger_before:
			if mite != null:
				# パン虫を捕食 (在庫は減らない)。
				mites.erase(mite)
				_event({"t": "mite_eaten", "id": g.id, "sex": g.sex})
			else:
				# 集積所での食事 1 回ぶん一括消費 (即時満腹に対応)。
				food = max(0.0, food - params.food_per_meal)

		if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT:
			continue
		var target := _movement_target(g, in_raid)
		if target != Vector2i(-1, -1):
			_advance_along_path(g, target, _move_speed(g))

## ステートに応じた移動速度 (タイル/tick)。子は遅く、戦闘・恐怖は駆け、瀕死は這う。
func _move_speed(g: Goblin) -> float:
	var spd := params.move_per_tick
	if g.is_child():
		spd *= params.child_move_factor
	match g.state:
		Goblin.State.COMBAT, Goblin.State.FEAR, Goblin.State.ENRAGED:
			spd *= params.urgent_move_factor
		Goblin.State.DYING:
			spd *= 0.5
	return spd

# ステートに応じた移動目標 (§3-0 対応表)。
# 同じ部屋へ向かう個体が 1 タイルに積み重ならないよう、id ハッシュで
# 部屋内の床スロットへ決定的に散らす (rng 不使用 = 消費順序を乱さない)。
func _movement_target(g: Goblin, in_raid: bool) -> Vector2i:
	# 防衛召集: 交戦中、戦線割り当ての個体は大広間 (トーテム) に集結して迎え撃ち、
	# 視界内 (8 タイル) に踏み込んだ敵にだけ向かっていく。敵まで個別に駆けつけると
	# 広い洞窟では各個撃破される (細い坑道へ 1 体ずつ吸い込まれて数の利を失う)。
	# COMBAT ステートは敵 4 タイル以内で初めて入る (§5)。空腹も召集対象
	# (襲撃警報は食事に優先。離脱→単独で食料庫へ→各個撃破、を防ぐ)。
	# 睡眠・瀕死・恐怖には割り込まない。
	if in_raid and (g.state == Goblin.State.WANDER or g.state == Goblin.State.WORK \
			or g.state == Goblin.State.HUNGRY):
		if (g.sex == Goblin.Sex.MALE or g.is_unique) and not g.is_child():
			# 戦線: トーテムの周囲 2 重の輪に肉の壁を作り、陣形を崩さず迎え撃つ。
			# 敵へ駆け出すと輪に穴が開き、別方向の敵がトーテムを素通しで殴れて
			# しまう (敵はトーテムへ進軍してくるので、待てば白兵になる)。
			if not _totem_ring.is_empty():
				return _totem_ring[_slot_hash(g.id) % _totem_ring.size()]
			return _hall_slot(g.id)
		# 非戦闘員 (雌・子): 肉の壁の内側 = トーテムの足元へ避難する。
		# 巣のあちこちに散ったままだと、敵の視界 (6 タイル) に入った端から
		# 狩られる (雌の絶滅 = 増殖の停止)。
		return _sanctuary_slot(g.id)
	match g.state:
		Goblin.State.COMBAT:
			# 隣接中は足を止めて殴り合う (敵側と同じ白兵の規律)。
			if _adjacent_enemy(g.pos()) != null:
				return Vector2i(-1, -1)
			return _nearest_enemy_pos(g.pos())
		Goblin.State.FEAR:
			# 戦えないので肉の壁の内側へ。外の部屋へ逃げると敵を引き込んだ上で
			# 処刑される (恐怖は隣接攻撃に反撃できない)。
			return _sanctuary_slot(g.id)
		Goblin.State.DYING, Goblin.State.SLEEP:
			return _room_slot(TileMapData.RoomType.NEST, g.id)
		Goblin.State.HUNGRY:
			# 視界内にパン虫が居れば集積所より優先して狩りに向かう。
			# 隣接済みなら足を止める (狩り = 食事は _step_goblins が隣接判定で解決)。
			var mite := _nearest_mite(g.pos(), params.mite_sight)
			if mite != null:
				if max(abs(g.x - mite.x), abs(g.y - mite.y)) <= 1:
					return Vector2i(-1, -1)
				return mite.pos()
			return _eat_slot(g.id)
		Goblin.State.WORK:
			return _work_target(g)
		Goblin.State.WANDER:
			# 移動中は続行、着いたらたまに次の行き先を引く (うろつき)。
			if not g.path.is_empty():
				return Vector2i(g.target_x, g.target_y)
			if rng.next_float() < params.wander_retarget_per_tick:
				return _random_nest_floor()
			return Vector2i(-1, -1)
		_:
			return Vector2i(-1, -1)

func _work_target(g: Goblin) -> Vector2i:
	# 役職に応じた作業場所。族長/シャーマンはトーテム付近、牧場係は牧場へ。
	if g.role == Goblin.Role.CHIEF or g.role == Goblin.Role.SHAMAN:
		return _hall_slot(g.id)
	for i in range(map.rooms.size()):
		var r: Dictionary = map.rooms[i]
		if (g.id in r.assigned):
			var tiles: Array = _room_floors.get(i, [])
			if not tiles.is_empty():
				return tiles[_slot_hash(g.id) % tiles.size()]
			return Vector2i(r.x + r.w / 2, r.y + r.h / 2)
	return Vector2i(-1, -1)

# 連続移動 (§3-0): 1 tick に speed タイルぶん waypoint へ前進する。
# パス再計算は「目標が 3 タイル超動いた」か「パスが尽きてまだ目標に居ない」とき
# だけに制限する (動く目標を毎 tick A* し直すと頭数×敵数で発散する)。
# occ を渡すと、他ユニットが占有する waypoint の手前で停止する (隊列)。
func _advance_along_path(unit, target: Vector2i, speed: float, occ: Dictionary = {}) -> void:
	if target == Vector2i(-1, -1):
		return
	var need_repath := false
	if unit.target_x != target.x or unit.target_y != target.y:
		if unit.target_x < 0 or unit.path.is_empty() \
				or absi(unit.target_x - target.x) + absi(unit.target_y - target.y) > 3:
			need_repath = true
	elif unit.path.is_empty() and unit.pos() != target:
		need_repath = true
	if need_repath:
		unit.target_x = target.x
		unit.target_y = target.y
		unit.path = Pathfinding.find_path(map, unit.pos(), target)
	var budget := speed
	while budget > 0.0 and not unit.path.is_empty():
		var wp: Vector2i = unit.path[0]
		if not occ.is_empty():
			# 定員に達したタイルへは進めず、手前で詰まって待つ (隊列)。
			var others: int = occ.get(wp, 0)
			if wp == unit.pos():
				others -= 1
			if others >= params.enemy_tile_capacity:
				break
		var dx: float = float(wp.x) - unit.fx
		var dy: float = float(wp.y) - unit.fy
		var d := sqrt(dx * dx + dy * dy)
		if d <= budget:
			unit.fx = float(wp.x)
			unit.fy = float(wp.y)
			budget -= d
			unit.path.pop_front()
		else:
			unit.fx += dx / d * budget
			unit.fy += dy / d * budget
			budget = 0.0
	unit.x = int(roundf(unit.fx))
	unit.y = int(roundf(unit.fy))

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
	# 敵 → ゴブリン。隣にゴブリンが居なければトーテムを壊しにかかる (§3-20)。
	for e in enemies:
		var g := _adjacent_goblin(e.pos())
		if g != null:
			g.hp -= params.enemy_attack
		elif max(abs(e.x - map.totem.x), abs(e.y - map.totem.y)) <= 1:
			totem_hp -= params.enemy_attack
			if totem_hp <= 0.0:
				map.set_tile(map.totem.x, map.totem.y, TileMapData.TileType.FLOOR)
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
	_event({"t": "raid_end", "alive": _alive_count()})
	# 損耗時バフ (§2.5 / KI-04): この戦闘の HP 損失割合が閾値超なら surge 発火。
	var lost_frac := 0.0
	if raid_start_hp > 0.0:
		lost_frac = (raid_start_hp - _total_hp()) / raid_start_hp
	if lost_frac > params.surge_trigger:
		surge = min(params.surge_max, surge + params.surge_gain * lost_frac)
		_event({"t": "surge", "lost_frac": lost_frac})

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
			_event({"t": "grow", "id": g.id, "sex": g.sex})

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
				_event({"t": "pregnant", "id": f.id, "mate": mate.id})

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
	var born := 0
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
		baby.fx = mother.fx
		baby.fy = mother.fy
		baby.max_hp *= 0.5  # 子は脆い
		baby.hp = baby.max_hp
		goblins.append(baby)
		births_total += 1
		born += 1
	if born > 0:
		_event({"t": "birth", "mother": mother.id, "count": born})

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
			g.death_logged = true
			_event({"t": "death", "id": g.id, "sex": g.sex, "cause": "accident"})

# --- 食料 (§3-11) ---
func _step_food() -> void:
	var active_ranchers := 0
	for r in map.rooms:
		if r.room_type != TileMapData.RoomType.RAT_RANCH:
			continue
		for gid in (r.assigned as Array):
			var g: Goblin = _goblin_by_id(int(gid))
			if g == null or g.state == Goblin.State.DEAD:
				continue
			if g.state == Goblin.State.WORK and _in_room(r, g.pos()):
				active_ranchers += 1
	food += active_ranchers * params.food_per_rancher_tick
	# 救済はパン虫の実体湧き (_step_mites) が担う (旧 food_passive_per_tick の抽象救済を置換)。

func _step_starvation() -> void:
	if food > 0.0:
		return
	for g in goblins:
		if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT:
			continue
		if g.hunger < params.starve_threshold:
			continue
		g.hp -= params.starve_hp_per_tick
		if g.hp <= 0.0:
			if g.is_unique:
				g.hp = 0.0
				continue
			g.hp = 0.0
			g.state = Goblin.State.DEAD
			g.death_logged = true
			_event({"t": "death", "id": g.id, "sex": g.sex, "cause": "starvation"})

func _step_faith() -> void:
	var shamans := 0
	for g in goblins:
		if g.role == Goblin.Role.SHAMAN or g.role == Goblin.Role.CHIEF:
			shamans += 1
	var gain := shamans * params.faith_per_shaman_tick
	faith += gain
	cum_faith += gain
	# トーテムの修繕 (§3-20): 平時に削れたぶんを直す。
	if phase == Phase.PEACE and totem_hp < params.totem_hp_max:
		totem_hp = min(params.totem_hp_max, totem_hp + params.totem_repair_per_tick)

# --- 死亡の一元化 (KI-20) ---
func _cleanup_dead() -> void:
	var alive: Array = []
	for g in goblins:
		if g.state == Goblin.State.DEAD:
			deaths_total += 1
			# 事故死/巣立ちは各所で記録済み。それ以外はここで戦死として記録する
			# (ダメージは戦闘解決のみが与えるため)。
			if not g.death_logged:
				_event({"t": "death", "id": g.id, "sex": g.sex, "cause": "combat"})
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
					g.death_logged = true
					_event({"t": "fledge", "id": g.id, "sex": g.sex})
					break
			over_cap_ticks = 0
	else:
		over_cap_ticks = 0

# --- 勝敗判定 ---
func _check_outcome() -> void:
	if _alive_count() == 0:
		outcome = Outcome.DEFEAT
		_event({"t": "defeat", "reason": "annihilation"})
		return
	if map.get_tile(map.totem.x, map.totem.y) != TileMapData.TileType.TOTEM:
		outcome = Outcome.DEFEAT
		_event({"t": "defeat", "reason": "totem"})
		return
	# ラストバトル撃退でクリア。
	if day >= params.final_day and phase == Phase.PEACE and enemies.is_empty():
		outcome = Outcome.VICTORY
		_event({"t": "victory"})

# === ヘルパ ===
func _alive_count() -> int:
	var n := 0
	for g in goblins:
		if g.state != Goblin.State.DEAD:
			n += 1
	return n

func _goblin_by_id(id: int) -> Goblin:
	for g in goblins:
		if g.id == id:
			return g
	return null

func _in_room(r: Dictionary, p: Vector2i) -> bool:
	return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h

func _has_room_assignment(id: int) -> bool:
	for r in map.rooms:
		if id in (r.assigned as Array):
			return true
	return false

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

# チェビシェフ距離で最寄りのパン虫 (range 内)。なければ null
# (_adjacent_enemy / _enemy_near と同じ max(abs dx, abs dy) の距離規約)。
func _nearest_mite(p: Vector2i, radius: int) -> MiteUnit:
	var best: MiteUnit = null
	var bd := radius + 1
	for m in mites:
		var d := maxi(abs(p.x - m.x), abs(p.y - m.y))
		if d <= radius and d < bd:
			bd = d
			best = m
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

# --- 床スロット (タイル選択。rng 不使用 = 消費順序を乱さない) ---

## map から床タイルのキャッシュを再構築する (setup / restore 時)。
func _rebuild_floor_caches() -> void:
	_nest_floors = []
	_hall_floors = []
	_totem_ring = []
	_totem_core = []
	_room_floors = {}
	for y in range(map.height):
		for x in range(map.width):
			if map.get_tile(x, y) != TileMapData.TileType.FLOOR:
				continue
			var p := Vector2i(x, y)
			_nest_floors.append(p)
			if _manhattan(p, map.totem) <= 5:
				_hall_floors.append(p)
			if max(abs(x - map.totem.x), abs(y - map.totem.y)) <= 2:
				_totem_ring.append(p)
			if max(abs(x - map.totem.x), abs(y - map.totem.y)) <= 1:
				_totem_core.append(p)
	for i in range(map.rooms.size()):
		var r: Dictionary = map.rooms[i]
		var tiles: Array = []
		for y in range(r.y, r.y + r.h):
			for x in range(r.x, r.x + r.w):
				if map.get_tile(x, y) == TileMapData.TileType.FLOOR:
					tiles.append(Vector2i(x, y))
		_room_floors[i] = tiles

## id から決定的に散らすハッシュ (goblin.compatibility と同系の整数ミックス)。
static func _slot_hash(id: int) -> int:
	return (id * 2654435761) & 0x7FFFFFFF

## 大広間 (トーテム周辺) の床スロット。族長/シャーマンの儀式位置。
func _hall_slot(id: int) -> Vector2i:
	if _hall_floors.is_empty():
		return map.totem + Vector2i(0, -2)
	return _hall_floors[_slot_hash(id) % _hall_floors.size()]

## トーテム足元 (隣接 8 タイル) の避難スロット。防衛陣形の内側。
func _sanctuary_slot(id: int) -> Vector2i:
	if _totem_core.is_empty():
		return _hall_slot(id)
	return _totem_core[_slot_hash(id) % _totem_core.size()]

## 指定タイプの部屋の床スロット (なければ大広間)。
func _room_slot(room_type: int, id: int) -> Vector2i:
	for i in range(map.rooms.size()):
		if map.rooms[i].room_type == room_type:
			var tiles: Array = _room_floors.get(i, [])
			if not tiles.is_empty():
				return tiles[_slot_hash(id) % tiles.size()]
	return _hall_slot(id)

## 集積所の周囲 8 タイルから空腹個体ごとの食事位置を選ぶ (積み重なり防止)。
const OFFS8 := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]
func _eat_slot(id: int) -> Vector2i:
	for k in range(8):
		var p: Vector2i = map.storage + OFFS8[(_slot_hash(id) + k) % 8]
		if map.is_walkable(p.x, p.y) \
				and map.get_tile(p.x, p.y) != TileMapData.TileType.EXTERIOR:
			return p
	return map.storage

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
	if _nest_floors.is_empty():
		return map.totem + Vector2i(0, -2)
	return _nest_floors[rng.next_int(_nest_floors.size())]

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

func _rebalance_ranch() -> void:
	var target := int(round(_alive_count() * params.ranch_assign_frac))
	for r in map.rooms:
		if r.room_type != TileMapData.RoomType.RAT_RANCH:
			continue
		var assigned: Array = r.assigned
		var cleaned: Array = []
		for gid in assigned:
			var g: Goblin = _goblin_by_id(int(gid))
			if g != null and g.state != Goblin.State.DEAD:
				cleaned.append(gid)
		assigned = cleaned
		if assigned.size() < target:
			var pool: Array = []
			for g in goblins:
				if g.role == Goblin.Role.NONE and not g.is_unique and not g.is_child() \
						and not (g.id in assigned):
					pool.append(g.id)
			pool.sort()
			for gid in pool:
				if assigned.size() >= target:
					break
				assigned.append(gid)
		while assigned.size() > target:
			assigned.pop_back()
		r.assigned = assigned

func _event(e: Dictionary) -> void:
	last_events.append(e)

# --- スナップショット (KI-09) ---
func snapshot() -> Dictionary:
	return {
		"tick": tick, "day": day, "phase": phase, "totem_hp": totem_hp,
		"faith": faith, "cum_faith": cum_faith, "food": food,
		"surge": surge, "over_cap_ticks": over_cap_ticks,
		"next_big_raid_tick": next_big_raid_tick,
		"raid_is_human": raid_is_human, "raid_start_hp": raid_start_hp,
		"outcome": outcome, "next_goblin_id": next_goblin_id,
		"next_enemy_id": next_enemy_id, "next_mite_id": next_mite_id,
		"deaths_total": deaths_total, "births_total": births_total,
		"rng": rng.snapshot(),
		"map": map.snapshot(),
		"goblins": goblins.map(func(g): return g.snapshot()),
		"enemies": enemies.map(func(e): return e.snapshot()),
		"mites": mites.map(func(m): return m.snapshot()),
	}

func restore(d: Dictionary) -> void:
	tick = d.tick; day = d.day; phase = d.phase; totem_hp = d.totem_hp
	faith = d.faith; cum_faith = d.cum_faith; food = d.food
	surge = d.surge; over_cap_ticks = d.over_cap_ticks
	next_big_raid_tick = d.next_big_raid_tick
	raid_is_human = d.raid_is_human; raid_start_hp = d.raid_start_hp
	outcome = d.outcome; next_goblin_id = d.next_goblin_id
	next_enemy_id = d.next_enemy_id; next_mite_id = d.next_mite_id
	deaths_total = d.deaths_total; births_total = d.births_total
	rng.restore(d.rng)
	map.restore(d.map)
	goblins = (d.goblins as Array).map(func(x): return Goblin.from_snapshot(x))
	enemies = (d.enemies as Array).map(func(x): return EnemyUnit.from_snapshot(x))
	mites = (d.mites as Array).map(func(x): return MiteUnit.from_snapshot(x))
	_rebuild_floor_caches()
