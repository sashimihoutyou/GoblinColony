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
var alarm_raised: bool = false   # T5: この襲撃で見張りが警報を上げ済みか (襲撃ごとにリセット)
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
	# 見張りを任命 (T5: 巣口の番。目標人数 = alive/10 を 1〜3 でクランプ)。
	_maintain_guards()

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
	# 性別共通の追加ロール (順序固定): 空腹の食いしん坊/小食 → ドジ度 → 気性。
	g.hunger_bias = -0.1 + rng.next_float() * 0.2
	g.clumsy = rng.next_float()
	g.temper = rng.next_float()
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
	_step_guard_alarm()   # T5: 見張りが巣内の敵を発見したら警報 (寝た個体を叩き起こす)
	_step_goblins()
	_resolve_combat()
	_step_breeding()
	_step_accidents()
	_step_social()
	_step_forage()        # T4: キノコ床の再生長を進める (食料加算は採集者の運搬で行う)
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
	_maintain_guards()  # T5: 見張りの目標人数を維持 (死亡で欠けたら補充・過剰なら解任)
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
	alarm_raised = false  # T5: 新しい襲撃ごとに警報フラグをリセット
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
	alarm_raised = false  # T5: 新しい襲撃ごとに警報フラグをリセット
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
		var state_before: int = g.state
		var ctx := StateMachine.Context.new()
		ctx.in_raid = in_raid
		ctx.enemy_nearby = _enemy_near(g.pos(), 4)
		ctx.assigned_to_combat = (g.sex == Goblin.Sex.MALE or g.is_unique)
		ctx.assigned_to_room = _has_room_assignment(g.id) or _is_forager(g)
		# 隣接 (8 近傍) のパン虫を狩れる。mite は各個体のループ内で都度取得するため、
		# 同 tick に 2 体が同じ 1 匹を食べる二重計上は起きない (食べた時点で erase)。
		var mite := _nearest_mite(g.pos(), 1)
		ctx.food_available = (food > 0.0 and _at_storage(g.pos())) or mite != null
		ctx.food_in_stock = food > 0.0
		ctx.is_night = not is_day()
		# 寝床 (NEST) のタイル上に居るか (睡眠ゲージ回復は到着後のみ)。
		ctx.at_rest = map.room_type_at(g.x, g.y) == TileMapData.RoomType.NEST
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
		# WANDER への新規遷移か (食事後・起床後・戦闘解除後など)。前ステートの
		# 残存パスを引き継がず、即座に新しい放浪先を引かせる (世話なし放置防止)。
		var entered_wander: bool = g.state == Goblin.State.WANDER and state_before != Goblin.State.WANDER
		var target := _movement_target(g, in_raid, entered_wander)
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
func _movement_target(g: Goblin, in_raid: bool, entered_wander: bool = false) -> Vector2i:
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
	# 求愛ランデブー (§3-6): 求愛中の個体は寝床 (NEST) のスロットへ向かう。雌雄が
	# 同じタイルに収束するよう、スロット鍵は「ペアの雌の id」で揃える (雌=自分,
	# 雄=courting_id)。食事・睡眠など緊急系には介入せず WORK/WANDER のときだけ。
	if g.courting_id >= 0 and (g.state == Goblin.State.WORK or g.state == Goblin.State.WANDER):
		var pair_key: int = g.id if g.sex == Goblin.Sex.FEMALE else g.courting_id
		return _room_slot(TileMapData.RoomType.NEST, pair_key)
	match g.state:
		Goblin.State.COMBAT:
			# 隣接中は足を止めて殴り合う (敵側と同じ白兵の規律)。
			if _adjacent_enemy(g.pos()) != null:
				return Vector2i(-1, -1)
			return _nearest_enemy_pos(g.pos())
		Goblin.State.FEAR:
			# 戦えない恐怖個体はトーテムの足元 (敵が殺到する) に留まると処刑
			# される。寝床 (NEST) へ退いて前線から離れる。
			return _room_slot(TileMapData.RoomType.NEST, g.id)
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
			# WANDER への新規遷移 (食事後・起床後・戦闘解除後など): 前ステートの
			# 残存パスを引き継がず、即座に新しい放浪先を引く (確率抽選を待たない。
			# rng.next_float() は消費せず _random_nest_floor() の next_int へ直行)。
			if entered_wander:
				return _random_nest_floor()
			# 移動中は続行、着いたらたまに次の行き先を引く (うろつき)。
			if not g.path.is_empty():
				return Vector2i(g.target_x, g.target_y)
			if rng.next_float() < params.wander_retarget_per_tick:
				return _random_nest_floor()
			return Vector2i(-1, -1)
		_:
			return Vector2i(-1, -1)

# T4: この個体がキノコ採集の対象か (雌成体・役職 NONE・部屋未割当)。
# 仕事の有無は「摘み取り可能なスポットがある or 運搬中」で判定する (放浪との切替)。
func _is_forager(g: Goblin) -> bool:
	if g.sex != Goblin.Sex.FEMALE or g.is_child() or g.role != Goblin.Role.NONE:
		return false
	if _has_room_assignment(g.id):
		return false
	if g.carrying_food:
		return true
	# 摘み取り可能なスポット (再生長 0) が 1 つでもあれば仕事がある。
	for i in range(map.forage_spots.size()):
		if map.forage_regrow[i] == 0:
			return true
	return false

# T4: 採集者の WORK 移動目標。運搬中なら集積所、非運搬なら最寄りの生長済みスポット。
# 食料への加算・摘み取りは到着判定 (チェビシェフ <=1) でここから副作用として行う。
func _forage_target(g: Goblin) -> Vector2i:
	if g.carrying_food:
		# 集積所へ運搬。到着で食料を加え、手ぶらに戻る (採集ループを 1 周終える)。
		if _at_storage(g.pos()):
			food += params.forage_carry_value
			g.carrying_food = false
			_event({"t": "forage", "id": g.id, "sex": g.sex})
			return Vector2i(-1, -1)
		return _eat_slot(g.id)  # 集積所隣接スロットへ散らして向かう (_slot_hash 規約)
	# 非運搬: 最寄りの生長済みスポットへ。距離最小・同距離はインデックス順 (決定的)。
	var best := -1
	var bd := 999999
	for i in range(map.forage_spots.size()):
		if map.forage_regrow[i] != 0:
			continue
		var sp: Vector2i = map.forage_spots[i]
		var d: int = maxi(abs(g.x - sp.x), abs(g.y - sp.y))
		if d < bd:
			bd = d
			best = i
	if best < 0:
		return Vector2i(-1, -1)  # 摘み取れるスポットがない (再生長待ち) → その場で待機
	var spot: Vector2i = map.forage_spots[best]
	if maxi(abs(g.x - spot.x), abs(g.y - spot.y)) <= 1:
		# 到着: 摘み取り (再生長を仕掛け、運搬状態へ)。先着が摘めば他は次 tick で
		# 別スポットへ向き直る (forage_regrow が即 >0 になり選択対象から外れる)。
		map.forage_regrow[best] = params.forage_regrow_ticks
		g.carrying_food = true
		return Vector2i(-1, -1)
	return spot

func _work_target(g: Goblin) -> Vector2i:
	# T4: 雌の採集者はキノコ床⇔集積所を往復する (役職判定より先に分岐)。
	if _is_forager(g):
		return _forage_target(g)
	# 役職に応じた作業場所。族長/シャーマンはトーテム付近、牧場係は牧場へ。
	if g.role == Goblin.Role.CHIEF or g.role == Goblin.Role.SHAMAN:
		return _hall_slot(g.id)
	# T5: 見張りは担当巣口の内側に立つ (持ち場で番をする)。
	if g.role == Goblin.Role.GUARD:
		return _guard_post(g)
	for i in range(map.rooms.size()):
		var r: Dictionary = map.rooms[i]
		if (g.id in r.assigned):
			var tiles: Array = _room_floors.get(i, [])
			if not tiles.is_empty():
				return tiles[_slot_hash(g.id) % tiles.size()]
			return Vector2i(r.x + r.w / 2, r.y + r.h / 2)
	return Vector2i(-1, -1)

# T5: 見張りの持ち場 = 担当巣口の内側の床 (gate からチェビシェフ距離 2〜3 で巣内側)。
# 決定的に 1 タイルを選ぶ (gate に最も近い該当床。同距離は走査順で安定)。たまに
# 隣の巣口へローテーションして坑道を歩く姿が見える (持ち場の巡回)。
func _guard_post(g: Goblin) -> Vector2i:
	if map.gates.is_empty():
		return _hall_slot(g.id)
	# 0.5 日ごとに担当巣口をローテーション (決定的トリガー。rng 不使用)。
	var half := maxi(1, int(0.5 * params.ticks_per_day))
	if g.guard_gate >= 0 and (tick % half) == 0:
		g.guard_gate = (g.guard_gate + 1) % map.gates.size()
	var gi: int = g.guard_gate if g.guard_gate >= 0 else 0
	gi = clampi(gi, 0, map.gates.size() - 1)
	var gate: Vector2i = map.gates[gi]
	# gate から巣内側 (トーテム寄り) で距離 2〜3 の床を、gate に最も近い順で 1 つ。
	var best := Vector2i(-1, -1)
	var bd := 999999
	for p in _nest_floors:
		var dg: int = maxi(abs(p.x - gate.x), abs(p.y - gate.y))
		if dg < 2 or dg > 3:
			continue
		# 巣内側であること (トーテムへ向かう敵を最初に迎える位置)。
		if _manhattan(p, map.totem) >= _manhattan(gate, map.totem):
			continue
		if dg < bd:
			bd = dg
			best = p
	if best != Vector2i(-1, -1):
		return best
	# フォールバック: 距離条件を満たす床が無ければ gate に最も近い巣内床へ寄る。
	# (_find_floor_near は rng を消費するため、移動目標の選択では使わない =
	#  スロット選択は rng 不使用の規約を守る)
	var near := Vector2i(-1, -1)
	var nd := 999999
	for p in _nest_floors:
		var dn: int = _manhattan(p, gate)
		if dn < nd:
			nd = dn
			near = p
	return near if near != Vector2i(-1, -1) else _hall_slot(g.id)

# T5: 見張りの目標人数を維持する (任命/補充/解任)。setup と日境界で呼ぶ。
# 候補は雄成体・役職 NONE・部屋未割当から work_bias 降順 (同値は id 昇順) で決定的に選ぶ。
func _maintain_guards() -> void:
	if map.gates.is_empty():
		return
	var target := clampi(_alive_count() / 10, 1, 3)
	# 現任の見張り (生存) を集計。
	var current: Array = []
	for g in goblins:
		if g.role == Goblin.Role.GUARD and g.state != Goblin.State.DEAD:
			current.append(g)
	# 過剰なら id 昇順で末尾を NONE へ戻す (決定的)。
	if current.size() > target:
		current.sort_custom(func(a, b): return a.id < b.id)
		while current.size() > target:
			var g: Goblin = current.pop_back()
			g.role = Goblin.Role.NONE
			g.guard_gate = -1
	elif current.size() < target:
		# 不足ぶんを候補から補充。work_bias 降順・同値 id 昇順で決定的に選ぶ。
		var pool: Array = []
		for g in goblins:
			if g.sex != Goblin.Sex.MALE or g.is_child() or g.role != Goblin.Role.NONE:
				continue
			if _has_room_assignment(g.id):
				continue
			pool.append(g)
		pool.sort_custom(func(a, b):
			if a.work_bias != b.work_bias:
				return a.work_bias > b.work_bias
			return a.id < b.id)
		var gate_idx := 0
		# 既存の見張りが使っている巣口の次から順繰りに割り当てる。
		for gg in current:
			gate_idx = maxi(gate_idx, gg.guard_gate + 1)
		var need := target - current.size()
		for i in range(min(need, pool.size())):
			var g: Goblin = pool[i]
			g.role = Goblin.Role.GUARD
			g.guard_gate = gate_idx % map.gates.size()
			gate_idx += 1
			_event({"t": "guard", "id": g.id})

# T5: 見張りの警報。交戦中に巣内へ侵入した敵を見張りが発見したら、1 襲撃に 1 回だけ
# 全個体を叩き起こす (寝た個体が防衛召集に乗れるようにする)。_step_goblins の直前に呼ぶ。
func _step_guard_alarm() -> void:
	if alarm_raised or phase != Phase.COMBAT:
		return
	# 巣内に敵が居るか。
	var intruder := false
	for e in enemies:
		if _inside_nest(e.pos()):
			intruder = true
			break
	if not intruder:
		return
	# いずれかの生存 (起きている) 見張りからチェビシェフ距離 8 以内に敵がいるか。
	var alarm_guard: Goblin = null
	for g in goblins:
		if g.role != Goblin.Role.GUARD:
			continue
		if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT \
				or g.state == Goblin.State.SLEEP:
			continue
		for e in enemies:
			if maxi(abs(g.x - e.x), abs(g.y - e.y)) <= 8:
				alarm_guard = g
				break
		if alarm_guard != null:
			break
	if alarm_guard == null:
		return
	# 警報: 全生存個体を起こす (睡眠ラッチ解除 + 今夜は就寝済み扱い)。睡眠ゲージは
	# そのまま (起きて防衛に向かう。in_raid 中は夜トリガーの再ラッチが効かない)。
	alarm_raised = true
	for g in goblins:
		if g.state == Goblin.State.DEAD:
			continue
		g.sleep_latched = false
		g.night_sleep_done = true
	_event({"t": "alarm", "id": alarm_guard.id})

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

	# 求愛ランデブーの成立・解消 (雌が起点・雄は従属)。発火より先に処理して、
	# このフレームで誘われた雌を即タイムアウト判定しない (court_ticks=0 始まり)。
	_step_courtship()

	# 求愛の誘い: 雌が起点 (雌律速)。平時かつ昼のみ。
	if phase != Phase.PEACE or not is_day():
		return
	for f in goblins:
		if f.sex != Goblin.Sex.FEMALE or f.pregnant or f.is_child():
			continue
		if f.courting_id >= 0:
			continue  # すでに求愛中の雌は新規の誘いをしない
		if f.state == Goblin.State.DEAD or f.state == Goblin.State.FEAR:
			continue
		# 誘えるのは活動中 (放浪/仕事/空腹) のときだけ。就寝中・瀕死では誘わない。
		if f.state != Goblin.State.WANDER and f.state != Goblin.State.WORK \
				and f.state != Goblin.State.HUNGRY:
			continue
		# 損耗バフで誘いの発火率を乗算 (§2.5 必須骨格)。
		var chance := params.court_base_chance * (1.0 + surge)
		if rng.next_float() < chance:
			# 相手の雄を探す (近場優先・相性で確率)。
			var mate := _find_mate(f)
			if mate != null and rng.next_float() < (0.3 + Goblin.compatibility(f, mate) * 0.7):
				# 妊娠はさせず、両者を相互に求愛中にして寝床へ向かわせる。
				f.courting_id = mate.id
				f.court_ticks = 0
				mate.courting_id = f.id
				mate.court_ticks = 0
				_event({"t": "court", "f": f.id, "m": mate.id})

## 求愛ランデブーの毎 tick 処理 (§3-6): 求愛中の雌を起点に、寝床での合流で妊娠を
## 成立させ、危機・平時離脱・タイムアウトでは静かに解散する。雄側は従属 (相互に解除)。
func _step_courtship() -> void:
	# 孤児参照の掃除 (雌雄問わず): 相手が既に配列から消えている (事故死・餓死は
	# _step_breeding より後に発生し _cleanup_dead で除去される) か、相手の
	# courting_id がこちらを指していない非対称状態なら解除する。これが無いと
	# 死んだ雌に誘われた雄が永久に求愛中のまま残る (寝床へ歩き続け、以後
	# どの雌からも誘えなくなる)。
	for g in goblins:
		if g.courting_id < 0:
			continue
		var partner := _goblin_by_id(g.courting_id)
		if partner == null or partner.state == Goblin.State.DEAD \
				or partner.courting_id != g.id:
			g.courting_id = -1
			g.court_ticks = 0
	for f in goblins:
		if f.sex != Goblin.Sex.FEMALE or f.courting_id < 0:
			continue
		var mate := _goblin_by_id(f.courting_id)
		# 解消条件: 相手が居ない/死亡、自分または相手が危機ステート、非平時、タイムアウト。
		var dissolve := false
		if mate == null or mate.state == Goblin.State.DEAD or f.state == Goblin.State.DEAD:
			dissolve = true
		elif phase != Phase.PEACE:
			dissolve = true
		elif _court_blocked(f) or _court_blocked(mate):
			dissolve = true
		elif f.court_ticks > params.court_timeout_ticks:
			dissolve = true
		if dissolve:
			if mate != null:
				mate.courting_id = -1
				mate.court_ticks = 0
			f.courting_id = -1
			f.court_ticks = 0
			continue
		f.court_ticks += 1
		# 成立: 雌雄がチェビシェフ距離 1 以内 かつ 雌が NEST 部屋内に居る。
		var adjacent: bool = max(abs(f.x - mate.x), abs(f.y - mate.y)) <= 1
		var in_nest: bool = map.room_type_at(f.x, f.y) == TileMapData.RoomType.NEST
		if adjacent and in_nest:
			f.pregnant = true
			f.pregnant_ticks = 0
			f.mate_id = mate.id
			f.courting_id = -1
			f.court_ticks = 0
			mate.courting_id = -1
			mate.court_ticks = 0
			_event({"t": "pregnant", "id": f.id, "mate": mate.id})

## 求愛を中断させる危機ステートか (FEAR/COMBAT/DYING/KNOCKED_OUT)。
func _court_blocked(g: Goblin) -> bool:
	return g.state == Goblin.State.FEAR or g.state == Goblin.State.COMBAT \
		or g.state == Goblin.State.DYING or g.state == Goblin.State.KNOCKED_OUT

func _find_mate(f: Goblin) -> Goblin:
	var best: Goblin = null
	var best_d := 999999
	for m in goblins:
		if m.sex != Goblin.Sex.MALE or m.is_child() or m.bereaved:
			continue
		if m.state == Goblin.State.DEAD:
			continue
		if m.courting_id >= 0:
			continue  # すでに別の雌と求愛中の雄は誘えない
		# 寝ている/瀕死/戦闘中の雄は誘えない (活動中のみ)。
		if m.state != Goblin.State.WANDER and m.state != Goblin.State.WORK \
				and m.state != Goblin.State.HUNGRY:
			continue
		var d := _manhattan(f.pos(), m.pos())
		if d > 20:
			continue  # 遠すぎる雄は誘えない (マンハッタン距離上限)
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

# --- 事故死 / ドジ (§3-3: ステートマシン外の独立レイヤー) ---
func _step_accidents() -> void:
	for g in goblins:
		if g.state != Goblin.State.WANDER:
			continue
		if g.is_unique:
			continue  # ユニークは事故死無効 (§8)
		# 各個体ごとに固定順で 2 ロールを消費する (RNG 消費順序を分岐させない)。
		# 1) 転倒 (非致死): ドジな個体ほど起きやすい。移動を中断するだけ。
		if rng.next_float() < params.fumble_prob * (0.4 + 1.2 * g.clumsy):
			g.path = []
			g.target_x = -1
			g.target_y = -1
			# T4: 運搬中なら手のキノコを取り落とす (食料は加算されない)。
			var dropped: bool = g.carrying_food
			if dropped:
				g.carrying_food = false
			_event({"t": "fumble", "id": g.id, "sex": g.sex, "dropped": dropped})
		# 2) 事故死: ドジな個体ほど確率が上がる (平均は従来の accident_prob と同じ)。
		if rng.next_float() < params.accident_prob * (0.5 + g.clumsy):
			g.hp = 0.0
			g.state = Goblin.State.DEAD
			g.death_logged = true
			_event({"t": "death", "id": g.id, "sex": g.sex, "cause": "accident"})

# --- ケンカ (§5 個性配線。相性の悪い雄同士の小競り合い) ---
func _step_social() -> void:
	# クールダウンは毎 tick デクリメント (0 で下げ止め)。
	for g in goblins:
		if g.quarrel_cd > 0:
			g.quarrel_cd -= 1
	if phase != Phase.PEACE:
		return  # 平時のみ (交戦中は防衛に集中させる)
	for a in goblins:
		if a.sex != Goblin.Sex.MALE or a.is_unique or a.is_child():
			continue
		if a.state != Goblin.State.WANDER or a.quarrel_cd > 0:
			continue
		# 配列順で最初に見つかる「相性が悪く気性が荒い」相手を探す。
		var b: Goblin = null
		for cand in goblins:
			if cand == a:
				continue
			if cand.sex != Goblin.Sex.MALE or cand.is_unique or cand.is_child():
				continue
			if cand.state != Goblin.State.WANDER or cand.quarrel_cd > 0:
				continue
			if max(abs(a.x - cand.x), abs(a.y - cand.y)) > 1:
				continue
			if Goblin.compatibility(a, cand) >= 0.35:
				continue
			if a.temper + cand.temper <= 0.9:
				continue
			b = cand
			break
		if b == null:
			continue
		if rng.next_float() < params.quarrel_prob:
			a.hp = max(1.0, a.hp - params.quarrel_damage)
			b.hp = max(1.0, b.hp - params.quarrel_damage)
			a.quarrel_cd = params.quarrel_cooldown_ticks
			b.quarrel_cd = params.quarrel_cooldown_ticks
			_event({"t": "quarrel", "a": a.id, "b": b.id})

# --- キノコ採集 (T4): キノコ床の再生長 ---
# 摘み取られたスポット (forage_regrow[i] > 0) を毎 tick デクリメントする。
# 0 になったら再び摘み取り可。食料への加算は採集者が集積所へ運んだ時点で行う
# (_movement_target の WORK 分岐)。
func _step_forage() -> void:
	for i in range(map.forage_regrow.size()):
		if map.forage_regrow[i] > 0:
			map.forage_regrow[i] -= 1

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

# --- 奇跡コマンド (§4 / §12): プレイヤー入力 (main.gd) から呼ぶ ---
## 嘲りの稲妻。指定 id の生存敵に固定ダメージを与える。信仰残高が足りれば消費して
## true を返す (残高不足・対象不在・終局時は false)。撃破後の除去と恵み食料は次 tick
## の _resolve_combat が一元処理する (KI-20)。演出/フィードは main.gd 側が出す。
func cast_lightning(enemy_id: int) -> bool:
	if outcome != Outcome.ONGOING or faith < params.lightning_cost:
		return false
	var target: EnemyUnit = null
	for e in enemies:
		if e.id == enemy_id and e.hp > 0.0:
			target = e
			break
	if target == null:
		return false
	faith -= params.lightning_cost
	target.hp -= params.lightning_damage
	return true

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
			# T4: 死亡に加え雌も外す (創設時の _assign_to_room は性別を見ないため、
			# 混ざった雌は最初の日境界でここから抜けて採集へ回る)。
			if g != null and g.state != Goblin.State.DEAD and g.sex == Goblin.Sex.MALE:
				cleaned.append(gid)
		assigned = cleaned
		if assigned.size() < target:
			var pool: Array = []
			for g in goblins:
				# T4: 牧場プールは雄のみ (雌は採集専任へ移した)。
				if g.sex != Goblin.Sex.MALE:
					continue
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
		"alarm_raised": alarm_raised,
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
	alarm_raised = d.alarm_raised
	outcome = d.outcome; next_goblin_id = d.next_goblin_id
	next_enemy_id = d.next_enemy_id; next_mite_id = d.next_mite_id
	deaths_total = d.deaths_total; births_total = d.births_total
	rng.restore(d.rng)
	map.restore(d.map)
	goblins = (d.goblins as Array).map(func(x): return Goblin.from_snapshot(x))
	enemies = (d.enemies as Array).map(func(x): return EnemyUnit.from_snapshot(x))
	mites = (d.mites as Array).map(func(x): return MiteUnit.from_snapshot(x))
	_rebuild_floor_caches()
