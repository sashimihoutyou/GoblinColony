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
var field_resources: Array = []  # Array[FieldResource] (§11.5 巣外の出現物)
var next_goblin_id: int = 0
var next_enemy_id: int = 0
var next_mite_id: int = 0
var next_field_id: int = 0

var tick: int = 0
var day: int = 0
var phase: int = Phase.PEACE
var totem_hp: float = 60.0     # トーテム耐久 (§3-20。0 で破壊 = 敗北。平時に修繕)
var faith: float = 0.0
var cum_faith: float = 0.0
var food: float = 15.0
# §3-11 資源スカラー (food 以外)。生産・消費はすべてスカラーで完結し、搬送は演出。
# wood/herb は供給経路 (外征 A4 / キノコ農園 B6) の実装待ちで当面 0 のまま。
var wood: float = 0.0          # 建材 (枝)
var mud: float = 0.0           # 建材 (泥。採掘で増える主建材)
var herb: float = 0.0          # 薬草
var equipment: float = 0.0     # 装備 (泥鍛冶屋 §3-16)
var gems: float = 0.0          # 宝石・貴金属 (§7 両刃の外交資源)
var surge: float = 0.0         # 損耗時バフ残量 (§2.5 / KI-04)

# §3-12 ジョブキュー。Job = {id, type, x, y, priority, assigned_id, progress, ...}
# (BUILD は room_type/w/h も持つ)。priority は小さいほど高優先。progress は 0..1 で
# 中断後も保持し、別の個体が続きから再開できる。Haul/Pray/Craft/Guard は既存系
# (運搬=スカラー完結・祈り=役職・製造=B8・警備=T5) が担うため型を設けない。
enum JobType { MINE, BUILD, REPAIR, DIG }
var jobs: Array = []           # Array[Dictionary]
var next_job_id: int = 0
var over_cap_ticks: int = 0
var next_big_raid_tick: int = 0
var raid_is_human: bool = false
var raid_is_small: bool = false  # 現襲撃が小規模 (恵み §11/KI-05) か。捕虜報酬を控えめにする
var raid_faction: String = "kugyo"  # 現襲撃の勢力 ("human"/"bunta"/"kugyo" §13)。既定値は侵攻側
var raid_start_hp: float = 0.0
var alarm_raised: bool = false   # T5: この襲撃で見張りが警報を上げ済みか (襲撃ごとにリセット)
var outcome: int = Outcome.ONGOING
# 奇跡「泥の抱擁」(§4) の一時壁。{x, y, prev, expire_tick} の配列 (KI-09 保存対象)。
var mud_walls: Array = []

# §3-20 破られた壁の跡 (FLOOR 化した座標)。order_repair で再建できる (§9 復興)。
var breach_sites: Array = []     # Array[Vector2i]
# §3-17 防衛配分。巣口ごとの重み (正規化して使う)。manual=false の間は毎 tick
# 敵の巣口別戦力に比例して自動追従し、スライダー操作で manual=true になる。
var defense_alloc: Array = []    # Array[float] (map.gates と同じ長さ)
var defense_alloc_manual: bool = false
# 破壊予告 (§3-20)。enemies の壁破壊役から毎 tick 導出する純粋な派生値
# (スナップショット対象外 = KI-09 で状態を増やさない。真実は enemy.wall_x/y)。
var breach_warnings: Array = []  # Array[Dictionary] {x, y, eta_ticks}
# 集合命令 (§4 基本命令)。(-1,-1) = 未発令。平時の WANDER/WORK をここへ上書きする。
var rally_point: Vector2i = Vector2i(-1, -1)

# --- 捕虜プール + 敵対度 (§2.5/§13。world.ts の捕虜・敵対度セクションの移植 KI-17/23/24) ---
# 捕虜は性別×種族の 4 区分 (float 連続量。world.ts の cap*Goblin/cap*Human と同じ)。
var cap_male_goblin: float = 0.0
var cap_female_goblin: float = 0.0
var cap_male_human: float = 0.0
var cap_female_human: float = 0.0
# 人間勢力の敵対度 (0..1)。残虐な仕打ち (生贄) で上昇、解放で下降 (§13)。
var human_hostility: float = 0.0
# ゴブリン 2 部族の敵対度 (0..1。§13 3 勢力分離 / KI-24 残り)。人間と違い
# 常時の業 (自然ドリフト) でじわじわ悪化する (中立ルート保護は人間のみ §14.5.7)。
var bunta_hostility: float = 0.0
var kugyo_hostility: float = 0.0

# 苗床の確定生産タイマー (tick。§2.5/§3-19。B2 第二増分)。母体が居る間だけ進み、
# nursery_period_ticks に達すると出産処理して 0 へ戻す (world.ts nurseryTimer)。
var nursery_timer: float = 0.0

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
var _field_tiles: Array = []       # 巣外の出現物の候補タイル (§11.5。縁と巣口前を除く EXTERIOR)
var _defense_points: Array = []    # 巣口ごとの防衛ライン地点 (§3-17。巣口の内側 2 タイル)
var _medic_points: Array = []      # まじない医の後衛地点 (spec 3-17。防衛ラインから更に内側へ medic_backline_offset 歩)

# --- 初期化 ---
func setup(p: SimParams) -> void:
	params = p
	rng = Rng.new(p.seed)
	map = MapTemplate.make_initial_map()
	goblins = []
	enemies = []
	mites = []
	field_resources = []
	next_goblin_id = 0
	next_enemy_id = 0
	next_mite_id = 0
	next_field_id = 0
	tick = 0
	day = 0
	phase = Phase.PEACE
	totem_hp = p.totem_hp_max
	faith = 0.0
	food = 15.0
	mud = p.start_mud  # 初期盤面「数日分の食料 + 少量の建材」(GDD §14.5.2)
	jobs = []
	next_job_id = 0
	outcome = Outcome.ONGOING
	mud_walls = []
	breach_sites = []
	defense_alloc_manual = false
	rally_point = Vector2i(-1, -1)
	defense_alloc = []
	for i in range(map.gates.size()):
		defense_alloc.append(1.0 / map.gates.size())
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

	_step_hostility_drift()  # §13 常時の業: ゴブリン 2 部族の敵対度の自然悪化 (毎 tick)
	_update_raid_schedule()
	_step_mud()           # §4 泥の抱擁: 寿命が尽きた泥壁を元のタイルへ戻す
	_step_enemies()
	_step_mites()
	_step_field()         # §11.5: 巣外の出現物の湧き・日没の店じまい
	_step_guard_alarm()   # T5: 見張りが巣内の敵を発見したら警報 (寝た個体を叩き起こす)
	_step_jobs()          # §3-12: ジョブ⇔個体の整合スイープ (中断・死亡・失効の一元化)
	_step_carry_assign()  # §3-21: 倒れたユニークに担ぎ手を割り当てる (この tick の戦闘割当に反映)
	_step_goblins()
	_resolve_combat()
	_step_carry_recover() # §3-21: 寝床に降ろされたユニークの HP 回復
	_step_medic()         # §6/spec 3-17/B4: まじない医による加速回復・遠距離治療 (herb 消費)
	_step_breeding()
	_step_accidents()
	_step_social()
	_step_captives()      # §2.5/KI-17: 雄ゴブリン捕虜の平時自動加入
	_step_captive_bonding()  # §3-19/KI-21: 捕虜との自然つがい化 (承認待ち)
	_step_forage()        # T4: キノコ床の再生長を進める (食料加算は採集者の運搬で行う)
	_step_food()
	_step_workshops()     # §7/B6: キノコ農園→薬草 / 泥鍛冶屋→装備
	_step_starvation()
	_step_faith()
	_step_nursery()       # §2.5/§3-19: 苗床の確定生産 (B2 第二増分)
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
	_staff_workshops()  # §7/B6: 建てたキノコ農園/泥鍛冶屋へ手すきを少人数配員
	_maintain_guards()  # T5: 見張りの目標人数を維持 (死亡で欠けたら補充・過剰なら解任)
	# ラストバトルは最終日に一度だけ (>= だと日境界ごとに多重スポーンしていた)。
	if day == params.final_day:
		_spawn_raid(true, "human")  # ラストバトル (人間勢力の総攻撃)

# --- 襲撃スケジュール (§3-5 / §3-7。間隔は敵対度連動 §11/§13/KI-24) ---
## 敵対度 → 大規模襲撃の間隔 (日) を線形写像する (world.ts raidIntervalDays と同式)。
## 和平 (0) で big_raid_interval_peace、MAX (1) で big_raid_interval_max (最短)。
func raid_interval_days(hostility: float) -> float:
	var h := clampf(hostility, 0.0, 1.0)
	return params.big_raid_interval_peace \
		+ (params.big_raid_interval_max - params.big_raid_interval_peace) * h

## 3 勢力のうち最も高い敵対度 (§13)。襲撃間隔 (難度ダイヤル) の入力になる
## (world.ts maxHostility と同式)。
func max_hostility() -> float:
	return max(human_hostility, max(bunta_hostility, kugyo_hostility))

func _schedule_next_raid() -> void:
	# 次回を「最も怒っている勢力」の敵対度で予約 (敵対度が高いほど短間隔 = 高難度 /
	# KI-08。§13 3 勢力化後は max_hostility が入力 / world.ts と同式)。
	var interval_days := raid_interval_days(max_hostility())
	next_big_raid_tick = tick + int(round(interval_days * params.ticks_per_day))

## 常時の業 (§13 小ノイズ層): ゴブリン 2 部族の敵対度の自然悪化。放置で関係が
## じわじわ悪化する (自然位置がやや敵対寄り。苦魚族が最速)。人間メーターは
## ドリフトさせない (加害でのみ動く = 中立ルート保護 §14.5.7。world.ts と同式)。
func _step_hostility_drift() -> void:
	bunta_hostility = clampf(bunta_hostility + params.hostility_drift_per_tick_bunta, 0.0, 1.0)
	kugyo_hostility = clampf(kugyo_hostility + params.hostility_drift_per_tick_kugyo, 0.0, 1.0)

## 襲撃してくる勢力を抽選する純粋関数 (§13 3 勢力。world.ts pickRaidFaction と同式)。
## r は [0,1) の乱数 1 個。人間判定は従来式 (r < human) のまま = 既存の検証帯を
## 崩さない。残り区間 [human, 1) を [0,1) へ正規化して部族間で分け合う:
## 基礎割合 kugyo_base_share (苦魚族は同種に容赦なく攻めやすい) に互いの
## 敵対度を重みとして上乗せする。
static func pick_raid_faction(human: float, bunta: float, kugyo: float, kugyo_base_share: float, r: float) -> String:
	if r < human:
		return "human"
	var u := 0.0 if human >= 1.0 else (r - human) / (1.0 - human)
	var w_kugyo := kugyo_base_share + kugyo
	var w_bunta := (1.0 - kugyo_base_share) + bunta
	return "kugyo" if u < w_kugyo / (w_kugyo + w_bunta) else "bunta"

func _update_raid_schedule() -> void:
	# 大規模襲撃の発火。勢力: 怒らせた相手が攻めてくる (§13 3 勢力)。RNG 消費は
	# 従来と同じ 1 float (消費順序厳守 / world.ts pickRaidFaction)。
	if phase == Phase.PEACE and tick >= next_big_raid_tick and day < params.final_day:
		var faction := pick_raid_faction(
			human_hostility, bunta_hostility, kugyo_hostility,
			params.kugyo_base_raid_share, rng.next_float())
		_spawn_raid(false, faction)
		_schedule_next_raid()
	# 小規模襲撃 (恵み): 1 日 1 回判定、平時のみ。
	if phase == Phase.PEACE and (tick % params.ticks_per_day) == params.day_ticks / 2:
		if rng.next_float() < params.small_raid_prob:
			_spawn_raid_small()

func _spawn_raid(final_battle: bool, faction: String) -> void:
	phase = Phase.COMBAT
	raid_faction = faction
	raid_is_human = faction == "human"
	raid_is_small = false
	raid_start_hp = _total_hp()
	alarm_raised = false  # T5: 新しい襲撃ごとに警報フラグをリセット
	_recall_dispatched()  # §11.5: 襲撃が来たら派遣中の個体は帰路につく
	_equip_fighters_from_stock()  # §3-16/B8: 警報で戦闘員が共有在庫から武装する
	var count := int(params.base_enemies + params.enemy_per_day * day)
	if final_battle:
		count = int(count * params.final_mult)
	_event({"t": "raid", "count": count, "human": raid_is_human, "faction": faction, "final": final_battle})
	# 全巣口に部隊を分散 (§3-14)。後半 (breacher_from_day〜) は壁破壊役が混ざる
	# (§3-20。breacher_every 体に 1 体・決定的。小規模襲撃には混ざらない)。
	for i in range(count):
		var gate_idx := i % map.gates.size()
		var breacher: bool = day >= params.breacher_from_day \
				and (i % params.breacher_every) == params.breacher_every - 1
		_spawn_enemy_at_gate(gate_idx, raid_is_human, breacher)

func _spawn_raid_small() -> void:
	# 小規模は無作為 1 巣口のみ。準自動・少数。
	var count := 1 + rng.next_int(2)
	var gate_idx := rng.next_int(map.gates.size())
	phase = Phase.COMBAT
	raid_is_human = false
	raid_is_small = true
	raid_start_hp = _total_hp()
	alarm_raised = false  # T5: 新しい襲撃ごとに警報フラグをリセット
	_recall_dispatched()  # §11.5: 襲撃が来たら派遣中の個体は帰路につく
	_equip_fighters_from_stock()  # §3-16/B8: 警報で戦闘員が共有在庫から武装する
	_event({"t": "raid_small", "count": count})
	for i in range(count):
		_spawn_enemy_at_gate(gate_idx, false)

func _spawn_enemy_at_gate(gate_idx: int, human: bool, breacher: bool = false) -> void:
	var e := EnemyUnit.new()
	e.id = next_enemy_id
	next_enemy_id += 1
	e.max_hp = params.enemy_hp
	e.hp = e.max_hp
	e.target_gate_idx = gate_idx
	e.is_human = human
	e.is_breacher = breacher
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
		# 抑えられない怒り (§4): 残 tick の間は最寄りの同胞だけを狙う。
		if e.enraged_ticks > 0:
			e.enraged_ticks -= 1
			var foe := _nearest_other_enemy(e)
			if foe == null:
				continue  # 一人ぼっちの怒りは空転する (持続だけ減る)
			if maxi(abs(foe.x - e.x), abs(foe.y - e.y)) <= 1:
				continue  # 白兵: 足を止めて殴り合う (下と同じ規律)
			var before_rage: Vector2i = e.pos()
			_advance_along_path(e, foe.pos(), params.enemy_move_per_tick, occ)
			if e.pos() != before_rage:
				occ[before_rage] = (occ.get(before_rage, 0) as int) - 1
				occ[e.pos()] = (occ.get(e.pos(), 0) as int) + 1
			continue
		# 白兵は足を止めて殴り合う (隣接中は移動しない)。追いかけ合いのまま
		# 殴ると隣接が明滅し、互いの DPS が出ず戦闘が間延びする。
		if _adjacent_goblin(e.pos()) != null:
			continue
		# §3-20 壁破壊役: 巣外にいる間は狙いの壁を割ることに専念する。
		# 割れたら (or 狙いを失ったら) 以降は通常の進軍へ戻る。
		if e.is_breacher and not _inside_nest(e.pos()):
			if e.wall_x >= 0 and map.get_tile(e.wall_x, e.wall_y) != TileMapData.TileType.WALL:
				e.wall_x = -1  # 先に割れた (同役の別個体・泥壁の寿命切れなど)
				e.wall_y = -1
			if e.wall_x == -1:  # -2 = 候補なしと判明済み (再走査しない)
				_pick_breach_wall(e)
			if e.wall_x >= 0:
				var wp := Vector2i(e.wall_x, e.wall_y)
				if maxi(abs(e.x - wp.x), abs(e.y - wp.y)) <= 1:
					_damage_wall(wp, e)  # 隣接: 足を止めて壁を殴る
					continue
				var stand := _wall_stand_tile(wp, e.pos())
				if stand != Vector2i(-1, -1):
					var before_b: Vector2i = e.pos()
					_advance_along_path(e, stand, params.enemy_move_per_tick, occ)
					if e.pos() != before_b:
						occ[before_b] = (occ.get(before_b, 0) as int) - 1
						occ[e.pos()] = (occ.get(e.pos(), 0) as int) + 1
					continue
				e.wall_x = -2  # 立ち位置がない → 断念して通常進軍へ
				e.wall_y = -1
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
	_update_breach_warnings()
	_step_defense_alloc()

# --- §3-20 ブリーチング + §3-17 防衛配分 (§9) ---

## 壁破壊役が狙える壁か。マップ縁 (外周岩盤) とトーテム至近 (チェビシェフ 2) は
## 無敵壁 (§9「破壊されない壁」= 重要施設の最低保証 + 端抜けの構造排除)。
func _wall_breakable(p: Vector2i) -> bool:
	if p.x <= 0 or p.y <= 0 or p.x >= map.width - 1 or p.y >= map.height - 1:
		return false
	if maxi(abs(p.x - map.totem.x), abs(p.y - map.totem.y)) <= 2:
		return false
	return map.get_tile(p.x, p.y) == TileMapData.TileType.WALL

## 壁破壊役の狙い選定: 巣の外殻のうち「外側からも内側からも歩ける面に 4 隣接する」
## 一枚壁 = 掘れば突破口になる壁だけを対象に、最寄りを選ぶ (同距離は走査順)。
## rng を使わない決定的選定 (破壊予告が「読める」ことが §9 の要)。
## 候補ゼロなら wall_x = -2 (断念) を立てて通常進軍へ (毎 tick の再走査を防ぐ)。
func _pick_breach_wall(e: EnemyUnit) -> void:
	var dirs4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var best := Vector2i(-1, -1)
	var bd := 999999
	for y in range(1, map.height - 1):
		for x in range(1, map.width - 1):
			var p := Vector2i(x, y)
			if not _wall_breakable(p):
				continue
			var out_ok := false
			var in_ok := false
			for off in dirs4:
				var q: Vector2i = p + off
				if not map.is_walkable(q.x, q.y):
					continue
				if _inside_nest(q):
					in_ok = true
				else:
					out_ok = true
			if not (out_ok and in_ok):
				continue
			var d := maxi(abs(e.x - p.x), abs(e.y - p.y))
			if d < bd:
				bd = d
				best = p
	if best.x < 0:
		e.wall_x = -2  # 候補なし: 以降この個体は通常進軍 (巣口経由)
		return
	e.wall_x = best.x
	e.wall_y = best.y
	_event({"t": "breach_warn", "x": best.x, "y": best.y, "enemy": e.id})

## 壁の隣の立ち位置 (歩ける 8 近傍のうち敵の現在地に最も近いタイル。決定的)。
func _wall_stand_tile(wall: Vector2i, from: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var bd := 999999
	for off in OFFS8:
		var q: Vector2i = wall + off
		if not map.is_walkable(q.x, q.y):
			continue
		var d := maxi(abs(from.x - q.x), abs(from.y - q.y))
		if d < bd:
			bd = d
			best = q
	return best

## 壁へダメージ。0 で FLOOR 化 (= 突破口)。跡は breach_sites に残り再建できる (§9 復興)。
func _damage_wall(p: Vector2i, e: EnemyUnit) -> void:
	var i := map.idx(p.x, p.y)
	map.wall_hp[i] = maxi(0, map.wall_hp[i] - params.wall_damage_per_tick)
	if map.wall_hp[i] > 0:
		return
	map.set_tile(p.x, p.y, TileMapData.TileType.FLOOR)
	if not breach_sites.has(p):
		breach_sites.append(p)
	# 泥の抱擁の壁だった場合は泥壁台帳からも消す (_step_mud の二重復元防止)。
	for k in range(mud_walls.size() - 1, -1, -1):
		var mw: Dictionary = mud_walls[k]
		if int(mw.x) == p.x and int(mw.y) == p.y:
			mud_walls.remove_at(k)
	_invalidate_paths_through([{"x": p.x, "y": p.y}])
	_rebuild_floor_caches()
	_event({"t": "breach", "x": p.x, "y": p.y})
	e.wall_x = -1
	e.wall_y = -1

## 破壊予告 (§3-20) を enemies から導出する (毎 tick。スナップショット対象外)。
## eta = 徒歩の残り + 殴る残り (tick)。renderer が警告ハイライトに使う。
func _update_breach_warnings() -> void:
	breach_warnings.clear()
	for e in enemies:
		if not e.is_breacher or e.wall_x < 0:
			continue
		var wp := Vector2i(e.wall_x, e.wall_y)
		var walk := maxf(0.0, float(maxi(abs(e.x - wp.x), abs(e.y - wp.y)) - 1)) \
				/ params.enemy_move_per_tick
		var hits := float(map.wall_hp[map.idx(wp.x, wp.y)]) / float(params.wall_damage_per_tick)
		breach_warnings.append({"x": wp.x, "y": wp.y, "eta_ticks": int(walk + hits)})

## 防衛ライン地点 (§3-17): 各巣口から巣の内側へ 2 歩 (トーテム寄りの床を貪欲に選ぶ)。
## まじない医の後衛地点 (spec 3-17) は、同じ貪欲法でさらに medic_backline_offset 歩
## トーテム側へ進めた地点 (前衛から離し被弾を抑える。戦線が無い間も _medic_slot から
## 参照されるため毎 tick 用意しておく)。
func _rebuild_defense_points() -> void:
	_defense_points = []
	_medic_points = []
	for gate in map.gates:
		var p: Vector2i = gate
		for step in range(2):
			p = _step_toward_totem(p)
		_defense_points.append(p)
		var mp := p
		for step in range(params.medic_backline_offset):
			mp = _step_toward_totem(mp)
		_medic_points.append(mp)

## p の 8 近傍で、巣内の歩行可能なタイルのうちトーテムに最も近い (チェビシェフ) もの
## を返す貪欲な 1 歩 (近傍候補が無ければ p のまま)。防衛ライン/後衛地点の算出に共用
## (元の _rebuild_defense_points の探索を関数化したのみで挙動は変えていない)。
func _step_toward_totem(p: Vector2i) -> Vector2i:
	var best := p
	var bd := 999999
	for off in OFFS8:
		var q: Vector2i = p + off
		if not map.is_walkable(q.x, q.y) or not _inside_nest(q):
			continue
		var d := maxi(abs(q.x - map.totem.x), abs(q.y - map.totem.y))
		if d < bd:
			bd = d
			best = q
	return best

## 配分スライダー (§3-17)。weights は巣口数ぶんの非負値 (合計は内部で正規化)。
func set_defense_alloc(weights: Array) -> bool:
	if weights.size() != map.gates.size():
		return false
	var total := 0.0
	for w in weights:
		total += maxf(0.0, float(w))
	if total <= 0.0:
		return false
	for i in range(weights.size()):
		defense_alloc[i] = maxf(0.0, float(weights[i])) / total
	defense_alloc_manual = true
	return true

## 自動配分へ戻す (敵戦力比例の追従を再開する)。
func clear_defense_alloc() -> void:
	defense_alloc_manual = false

## 自動配分 (§3-17): 敵の担当巣口別の頭数比へ毎 tick 追従する。壁破壊役は
## 狙い壁に最も近い巣口へ計上する (突破口の内側へ前衛が寄る)。
func _step_defense_alloc() -> void:
	if defense_alloc_manual or enemies.is_empty():
		return
	var counts := []
	counts.resize(map.gates.size())
	counts.fill(0.0)
	for e in enemies:
		var gi: int = e.target_gate_idx
		if e.is_breacher and e.wall_x >= 0:
			var bd := 999999
			for k in range(map.gates.size()):
				var g: Vector2i = map.gates[k]
				var d := maxi(abs(g.x - e.wall_x), abs(g.y - e.wall_y))
				if d < bd:
					bd = d
					gi = k
		counts[gi] += 1.0
	var total := 0.0
	for c in counts:
		total += c
	if total <= 0.0:
		return
	for i in range(counts.size()):
		defense_alloc[i] = counts[i] / total

## 戦線個体の持ち場 (§3-17)。生存戦力を id 順に並べ、配分重みの累積区間で巣口へ
## 割り振る (rng なし・全員が同じ並びを計算するので毎 tick 安定)。
func _defense_slot(g: Goblin) -> Vector2i:
	if _defense_points.is_empty():
		return Vector2i(-1, -1)
	var fighters := []
	for o in goblins:
		if o.state == Goblin.State.DEAD or o.state == Goblin.State.KNOCKED_OUT:
			continue
		# B4: まじない医は後衛 (_medic_slot) へ控えるため、前衛のランク付けには含めない。
		if o.role == Goblin.Role.WITCH_DOCTOR:
			continue
		if (o.sex == Goblin.Sex.MALE or o.is_unique) and not o.is_child():
			fighters.append(o.id)
	fighters.sort()
	var rank := fighters.find(g.id)
	if rank < 0:
		return Vector2i(-1, -1)
	var frac := (float(rank) + 0.5) / float(fighters.size())
	var cum := 0.0
	var gi := _defense_points.size() - 1
	for i in range(defense_alloc.size()):
		cum += defense_alloc[i]
		if frac <= cum:
			gi = i
			break
	var dp: Vector2i = _defense_points[gi]
	var slot: Vector2i = dp + OFFS8[_slot_hash(g.id) % 8]
	return slot if map.is_walkable(slot.x, slot.y) and _inside_nest(slot) else dp

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

# --- 巣外の出現物 (§11.5 昼の外征の縮小版: 採取系のみ) ---
# 日中、巣外の地面に採取物がランダムに湧く。プレイヤーが派遣 (DISPATCH) した
# ゴブリンが巣口を抜けて往復し、一食ずつ集積所へ持ち帰る。取りに行けば得・
# 放置しても損はしない前向きの機会に留める (§11.5 / §0)。
func _step_field() -> void:
	if not is_day():
		# 夜は暗くて外に出られない (§11.5 外征の締め切り)。日没で未回収ぶんは
		# 消え、派遣も解除する (運搬中の一食は _dispatch_target が届けてから手じまい)。
		if not field_resources.is_empty():
			for f in field_resources:
				_event({"t": "field_expire", "id": f.id, "x": f.x, "y": f.y})
			field_resources.clear()
		_recall_dispatched()
		return
	# RNG 消費は固定順: 上限未満のときのみ湧き判定 → 候補タイル抽選 (パン虫と同じ規約)。
	if field_resources.size() >= params.field_max:
		return
	if rng.next_float() >= params.field_spawn_per_tick:
		return
	var p := _field_spawn_tile()
	if p == Vector2i(-1, -1):
		return
	var f := FieldResource.new()
	f.id = next_field_id
	next_field_id += 1
	f.x = p.x
	f.y = p.y
	f.amount = params.field_amount_min + rng.next_int(params.field_amount_spread)
	field_resources.append(f)
	_event({"t": "field_spawn", "id": f.id, "x": f.x, "y": f.y, "amount": f.amount})

## 出現タイルを引く。他の出現物との重なりを避け、巣口から歩いて届くこと
## (A* 接続) を確認する。候補が引けなければ (-1,-1) = 今回は湧かない
## (試行回数固定 = RNG 消費は状態から決定的)。
func _field_spawn_tile() -> Vector2i:
	if _field_tiles.is_empty() or map.gates.is_empty():
		return Vector2i(-1, -1)
	for attempt in range(8):
		var p: Vector2i = _field_tiles[rng.next_int(_field_tiles.size())]
		var near_other := false
		for f in field_resources:
			if maxi(abs(f.x - p.x), abs(f.y - p.y)) <= 2:
				near_other = true
				break
		if near_other:
			continue
		if not Pathfinding.find_path(map, map.gates[0], p).is_empty():
			return p
	return Vector2i(-1, -1)

## §11.5 派遣: 出現物 resource_id へ count 体を送る (Controller の DISPATCH 経由)。
## 夜・交戦中・出現物消滅後は無視。候補は手すきの成体 (役職 NONE・部屋未割当・
## 非ユニーク・非妊娠・求愛/運搬中でない・WANDER か WORK) から forage_bias 降順
## (同値は id 昇順) で決定的に選ぶ。実際に送れた数を返す。
func dispatch_to_field(resource_id: int, count: int) -> int:
	if not is_day() or phase != Phase.PEACE or count <= 0:
		return 0
	if _field_by_id(resource_id) == null:
		return 0
	var pool := _dispatch_pool()
	var n: int = mini(count, pool.size())
	for i in range(n):
		pool[i].dispatch_id = resource_id
	if n > 0:
		_event({"t": "dispatch", "count": n, "resource_id": resource_id})
	return n

## 派遣に出せる手すきの成体 (forage_bias 降順・同値 id 昇順で決定的)。
## UI のスライダー上限 (dispatch_pool_count) と dispatch_to_field が同じ条件を見る。
func _dispatch_pool() -> Array:
	var pool: Array = []
	for g in goblins:
		if g.state == Goblin.State.DEAD or g.is_child() or g.is_unique:
			continue
		if g.role != Goblin.Role.NONE or _has_room_assignment(g.id):
			continue
		if g.dispatch_id >= 0 or g.carrying_food or g.courting_id >= 0 or g.pregnant:
			continue
		if g.state != Goblin.State.WANDER and g.state != Goblin.State.WORK:
			continue
		pool.append(g)
	pool.sort_custom(func(a, b):
		if a.forage_bias != b.forage_bias:
			return a.forage_bias > b.forage_bias
		return a.id < b.id)
	return pool

## UI 用: いま派遣に出せる頭数 (読み取りのみ。rng 不消費)。
func dispatch_pool_count() -> int:
	return _dispatch_pool().size()

## 襲撃発生・日没の自動帰還 (§11.5「予兆で帰路につく」の P1 簡易版: 即時解除)。
## 派遣が解けた個体は WANDER の受け皿に落ち、夜なら睡眠で寝床へ歩いて戻る。
## 運搬中の個体は配達を済ませてから手じまいする (_dispatch_target の規約)。
func _recall_dispatched() -> void:
	for g in goblins:
		if g.dispatch_id >= 0 and not g.carrying_food:
			g.dispatch_id = -1

func _field_by_id(id: int) -> FieldResource:
	for f in field_resources:
		if f.id == id:
			return f
	return null

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
		# 側室/苗床ホストは戦線に出ない (子を産む役割に専念 / world.ts §3-6 と同条件)。
		# §3-21: 搬送中の担ぎ手も戦線に吸われない (倒れたユニークの搬送を優先)。
		# B4/spec 3-17: まじない医は後衛に控え、白兵の戦線へは吸われない。
		ctx.assigned_to_combat = (g.sex == Goblin.Sex.MALE or g.is_unique) \
				and g.role != Goblin.Role.CONCUBINE and g.role != Goblin.Role.NURSERY_HOST \
				and g.role != Goblin.Role.WITCH_DOCTOR and g.carrying_id < 0
		# §11.5: 派遣中・運搬中も WORK 扱い (運搬は派遣解除後も配達を済ませる)。
		# §3-12: ジョブを取得中、または取得できる未割当ジョブがあるときも WORK へ。
		ctx.assigned_to_room = _has_room_assignment(g.id) or _is_forager(g) \
				or g.dispatch_id >= 0 or g.carrying_food \
				or g.job_id >= 0 or _job_open_for(g)
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

		# §3-21: 搬送不能 (恐怖/瀕死/激昂/死亡) になったら被搬送者を置いていく。
		# 次 tick の _step_carry_assign が別の担ぎ手を探す。
		if g.carrying_id >= 0 and (g.state == Goblin.State.FEAR or g.state == Goblin.State.DYING \
				or g.state == Goblin.State.ENRAGED or g.state == Goblin.State.DEAD):
			_event({"t": "carry_drop", "carrier": g.id, "downed": g.carrying_id})
			g.carrying_id = -1

		if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT:
			continue
		# WANDER への新規遷移か (食事後・起床後・戦闘解除後など)。前ステートの
		# 残存パスを引き継がず、即座に新しい放浪先を引かせる (世話なし放置防止)。
		var entered_wander: bool = g.state == Goblin.State.WANDER and state_before != Goblin.State.WANDER
		var target := _movement_target(g, in_raid, entered_wander)
		if target != Vector2i(-1, -1):
			_advance_along_path(g, target, _move_speed(g))

		# §3-21: 搬送中は被搬送者を担ぎ手の座標へ引きずる。寝床タイルへ到達したら
		# 降ろして (carrying_id=-1) 回復を開始させる (downed_ticks をリセット)。
		if g.carrying_id >= 0:
			var carried := _goblin_by_id(g.carrying_id)
			if carried != null:
				_place(carried, g.pos())
				if map.room_type_at(g.x, g.y) == TileMapData.RoomType.NEST:
					_event({"t": "carry_deliver", "carrier": g.id, "downed": carried.id})
					g.carrying_id = -1
					carried.downed_ticks = 0

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
	# §3-21 搬送: 倒れたユニークを担いでいる間は他の行動より優先し、最寄りの
	# 寝床 (NEST) へ直行する (戦線召集・求愛・rally 等のいずれにも割り込まれない)。
	if g.carrying_id >= 0:
		return _nearest_nest_floor(g.pos())
	# 防衛召集: 交戦中、戦線割り当ての個体は大広間 (トーテム) に集結して迎え撃ち、
	# 視界内 (8 タイル) に踏み込んだ敵にだけ向かっていく。敵まで個別に駆けつけると
	# 広い洞窟では各個撃破される (細い坑道へ 1 体ずつ吸い込まれて数の利を失う)。
	# COMBAT ステートは敵 4 タイル以内で初めて入る (§5)。空腹も召集対象
	# (襲撃警報は食事に優先。離脱→単独で食料庫へ→各個撃破、を防ぐ)。
	# 睡眠・瀕死・恐怖には割り込まない。
	if in_raid and (g.state == Goblin.State.WANDER or g.state == Goblin.State.WORK \
			or g.state == Goblin.State.HUNGRY):
		# B4/spec 3-17: まじない医は前衛の白兵 (_defense_slot) ではなく、防衛ラインの
		# さらに内側 (_medic_points) の後衛へ控える。被弾を抑えつつ、近くの負傷者を
		# 遠距離治療する (_step_medic)。
		if g.role == Goblin.Role.WITCH_DOCTOR:
			return _medic_slot(g)
		if (g.sex == Goblin.Sex.MALE or g.is_unique) and not g.is_child():
			# 戦線 (§3-17): 平素は配分重みに従い巣口の防衛ラインで迎え撃つ
			# (隘路は数の利を殺せる)。敵がトーテム至近まで踏み込んだら従来の
			# 「トーテムの周囲 2 重の輪」へ収束する (最後の砦。輪に穴を開けない
			# 規律は従来どおりで、駆けつけ各個撃破はしない)。
			if not _enemy_near(map.totem, params.totem_panic_radius):
				var dslot := _defense_slot(g)
				if dslot != Vector2i(-1, -1):
					return dslot
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
	# 集合命令 (§4 基本命令): 平時の手すき (WANDER/WORK) を rally 地点へ上書きする。
	# 欲求・戦闘・求愛・運搬・派遣には割り込まない (解除で通常へ戻る)。
	if rally_point != Vector2i(-1, -1) and not in_raid \
			and (g.state == Goblin.State.WANDER or g.state == Goblin.State.WORK) \
			and g.courting_id < 0 and not g.carrying_food and g.dispatch_id < 0:
		# 1 タイルに積み重ならないよう id ハッシュで周囲 8 タイルへ散らす。
		var slot: Vector2i = rally_point + OFFS8[_slot_hash(g.id) % 8]
		return slot if map.is_walkable(slot.x, slot.y) else rally_point
	match g.state:
		Goblin.State.COMBAT:
			# 隣接中は足を止めて殴り合う (敵側と同じ白兵の規律)。
			if _adjacent_enemy(g.pos()) != null:
				return Vector2i(-1, -1)
			return _nearest_enemy_pos(g.pos())
		Goblin.State.ENRAGED:
			# 激昂 (§4): 最寄りの敵へ向かい、隣接で足を止めて殴り合う。
			# 敵が尽きたら動かない (解除は state_machine の ENRAGED 節)。
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

# §11.5 派遣の WORK 移動目標。出現物⇔集積所を往復する (_forage_target と同じ
# 「到着判定で副作用」規約)。出現物が消えたら (取り尽くし/日没)、運搬中の一食を
# 届けてから派遣を解除する (KI-20「ジョブを抱えて消えない」と同じ思想)。
func _dispatch_target(g: Goblin) -> Vector2i:
	var f := _field_by_id(g.dispatch_id)
	if g.carrying_food:
		if _at_storage(g.pos()):
			food += params.field_carry_value
			g.carrying_food = false
			_event({"t": "field_haul", "id": g.id, "sex": g.sex})
			if f == null:
				g.dispatch_id = -1
			return Vector2i(-1, -1)
		return _eat_slot(g.id)  # 集積所隣接スロットへ散らして向かう (_slot_hash 規約)
	if f == null:
		g.dispatch_id = -1
		return Vector2i(-1, -1)
	if maxi(abs(g.x - f.x), abs(g.y - f.y)) <= 1:
		# 到着: 一食ぶん摘み取り、運搬状態へ。取り尽くしたら出現物を畳む
		# (他の派遣個体は次 tick に f == null を見て手ぶらで巣へ戻る)。
		f.amount -= 1
		g.carrying_food = true
		if f.amount <= 0:
			field_resources.erase(f)
			_event({"t": "field_done", "id": f.id, "x": f.x, "y": f.y})
		return Vector2i(-1, -1)
	return f.pos()

func _work_target(g: Goblin) -> Vector2i:
	# §11.5 派遣: 出現物の回収はキノコ採集より優先 (プレイヤーの明示指示)。
	# 派遣解除後 (襲撃/日没) も運搬中なら _dispatch_target が配達を済ませる。
	if g.dispatch_id >= 0 or (g.carrying_food and not _is_forager(g)):
		return _dispatch_target(g)
	# T4: 雌の採集者はキノコ床⇔集積所を往復する (役職判定より先に分岐)。
	if _is_forager(g):
		return _forage_target(g)
	# 役職に応じた作業場所。族長/シャーマンはトーテム付近、牧場係は牧場へ。
	if g.role == Goblin.Role.CHIEF or g.role == Goblin.Role.SHAMAN:
		return _hall_slot(g.id)
	# T5: 見張りは担当巣口の内側に立つ (持ち場で番をする)。
	if g.role == Goblin.Role.GUARD:
		return _guard_post(g)
	# B4: まじない医は平時、まじない医部屋 (WITCH) 付近で治療の準備をする
	# (部屋が未建設なら _room_slot のフォールバックで大広間へ)。
	if g.role == Goblin.Role.WITCH_DOCTOR:
		return _room_slot(TileMapData.RoomType.WITCH, g.id)
	for i in range(map.rooms.size()):
		var r: Dictionary = map.rooms[i]
		if (g.id in r.assigned):
			var tiles: Array = _room_floors.get(i, [])
			if not tiles.is_empty():
				return tiles[_slot_hash(g.id) % tiles.size()]
			return Vector2i(r.x + r.w / 2, r.y + r.h / 2)
	# §3-12 ジョブキュー: 役職も部屋もない手すきは未割当ジョブを取得して働く。
	if g.job_id < 0:
		_claim_job(g)
	if g.job_id >= 0:
		return _job_target(g)
	return Vector2i(-1, -1)

# --- §3-12 ジョブキュー + §3-15 建築 + §3-20 壁修復 ---

## 個体がジョブを取得できる立場か (成体・無役・部屋/派遣/採集/運搬なし)。
func _job_eligible(g: Goblin) -> bool:
	if g.is_child() or g.role != Goblin.Role.NONE:
		return false
	if g.dispatch_id >= 0 or g.carrying_food or _is_forager(g):
		return false
	return not _has_room_assignment(g.id)

## 取得できる未割当ジョブがあるか (WORK へ入るかの判定用)。
func _job_open_for(g: Goblin) -> bool:
	if jobs.is_empty() or not _job_eligible(g):
		return false
	for j in jobs:
		if j.assigned_id < 0:
			return true
	return false

## §3-12「未割当・最寄り・性格重みで最高スコア」の 1 件を取得する。
## priority を最優先に、距離 − work_bias×換算タイル の小さい順。同点は積んだ順 (決定的)。
func _claim_job(g: Goblin) -> void:
	if not _job_eligible(g):
		return
	var best: Dictionary = {}
	var best_key := 0.0
	for j in jobs:
		if j.assigned_id >= 0:
			continue
		var d := maxi(absi(g.x - j.x), absi(g.y - j.y))
		var key: float = float(j.priority) * 10000.0 + float(d) \
				- g.work_bias * params.job_affinity_tiles
		if best.is_empty() or key < best_key:
			best = j
			best_key = key
	if not best.is_empty():
		best.assigned_id = g.id
		g.job_id = best.id

func _job_by_id(id: int) -> Dictionary:
	for j in jobs:
		if j.id == id:
			return j
	return {}

func _job_work_rate(t: int) -> float:
	match t:
		JobType.MINE:
			return params.mine_work_per_tick
		JobType.BUILD:
			return params.build_work_per_tick
		JobType.REPAIR:
			return params.repair_work_per_tick
		JobType.DIG:
			return params.dig_work_per_tick
	return 0.0

## 取得中ジョブの WORK 移動目標。到着 (ジョブ矩形へチェビシェフ <=1) で進捗を
## 進め、1.0 で完了する (_forage_target と同じ「到着判定で副作用」規約)。
func _job_target(g: Goblin) -> Vector2i:
	var j := _job_by_id(g.job_id)
	if j.is_empty():
		g.job_id = -1
		return Vector2i(-1, -1)
	var w: int = j.get("w", 1)
	var h: int = j.get("h", 1)
	var dx := maxi(maxi(j.x - g.x, g.x - (j.x + w - 1)), 0)
	var dy := maxi(maxi(j.y - g.y, g.y - (j.y + h - 1)), 0)
	if maxi(dx, dy) <= 1:
		j.progress += _job_work_rate(j.type)
		if j.progress >= 1.0:
			_complete_job(j, g)
		return Vector2i(-1, -1)
	var tgt := Vector2i(j.x + w / 2, j.y + h / 2)
	if not map.is_walkable(tgt.x, tgt.y):
		# 壁修復などターゲット自体が通行不可: 隣接の歩ける床に立って作業する。
		for off in OFFS8:
			var q := Vector2i(j.x + off.x, j.y + off.y)
			if map.is_walkable(q.x, q.y):
				return q
	return tgt

func _complete_job(j: Dictionary, g: Goblin) -> void:
	match j.type:
		JobType.MINE:
			# 採掘完了: ノードは枯渇し建材になる。稀に宝石 (§7 二経路の採掘側)。
			map.set_tile(j.x, j.y, TileMapData.TileType.EXHAUSTED)
			mud += params.mine_yield_mud
			var gem := rng.next_float() < params.gem_mine_chance
			if gem:
				gems += 1.0
			_event({"t": "mine_done", "id": g.id, "x": j.x, "y": j.y, "gem": gem})
		JobType.BUILD:
			# 建設完了: ここで初めて rooms[] に載る (spec 3-15)。
			map.rooms.append({"x": j.x, "y": j.y, "w": j.w, "h": j.h,
					"room_type": j.room_type, "assigned": []})
			_rebuild_floor_caches()
			_event({"t": "build_done", "id": g.id, "room_type": j.room_type,
					"x": j.x, "y": j.y})
		JobType.REPAIR:
			var rp := Vector2i(j.x, j.y)
			if breach_sites.has(rp):
				# 再建 (§9 復興): 上にユニットが立っている間は完了を持ち越す
				# (壁の中に閉じ込めない)。進捗 1.0 で待機し続ける。
				if _unit_on_tile(rp):
					j.progress = 1.0
					return
				map.set_tile(rp.x, rp.y, TileMapData.TileType.WALL)
				breach_sites.erase(rp)
				_invalidate_paths_through([{"x": rp.x, "y": rp.y}])
				_rebuild_floor_caches()
			map.wall_hp[map.idx(j.x, j.y)] = MapTemplate.WALL_HP
			_event({"t": "repair_done", "id": g.id, "x": j.x, "y": j.y})
		JobType.DIG:
			# 掘削完了 (§10 巣穴拡張): 壁を床化し、掘り出した土から少量の建材。
			# 床化で経路・床キャッシュが変わるので採掘と同じ後処理を行う。
			map.set_tile(j.x, j.y, TileMapData.TileType.FLOOR)
			map.wall_hp[map.idx(j.x, j.y)] = 0  # もう壁ではない (修復対象にしない)
			mud += params.dig_yield_mud
			_invalidate_paths_through([{"x": j.x, "y": j.y}])
			_rebuild_floor_caches()
			_event({"t": "dig_done", "id": g.id, "x": j.x, "y": j.y})
	jobs.erase(j)
	g.job_id = -1

## 採掘指定のトグル (§10 資源なぞり指定の最小版: ノードをタップで指定/解除)。
func designate_mine(x: int, y: int) -> bool:
	for j in jobs:
		if j.type == JobType.MINE and j.x == x and j.y == y:
			_cancel_job(j)
			return true
	if map.get_tile(x, y) != TileMapData.TileType.RESOURCE_NODE:
		return false
	jobs.append({"id": next_job_id, "type": JobType.MINE, "x": x, "y": y,
			"priority": 2, "assigned_id": -1, "progress": 0.0})
	next_job_id += 1
	return true

## 掘削できる素の壁か (§10 巣穴拡張)。破壊可能 (マップ縁・トーテム至近を除く) で、
## 8 近傍に EXTERIOR が一つも無く (外殻を破らない = 内側のみ。斜め接触も排除して
## 角抜けでの開通も防ぐ)、かつ 8 近傍に巣内の歩ける床がある (ゴブリンが隣に立てて
## 掘れる + 掘った床が巣に繋がる)。
func _wall_diggable(p: Vector2i) -> bool:
	if not _wall_breakable(p):
		return false
	var has_floor := false
	for off in OFFS8:
		var q: Vector2i = p + off
		if map.get_tile(q.x, q.y) == TileMapData.TileType.EXTERIOR:
			return false
		if map.is_walkable(q.x, q.y) and _inside_nest(q):
			has_floor = true
	return has_floor

## 掘削指定のトグル (§10。素の壁をタップ → 掘削ジョブ / 再タップで解除)。
func designate_dig(x: int, y: int) -> bool:
	for j in jobs:
		if j.type == JobType.DIG and j.x == x and j.y == y:
			_cancel_job(j)
			return true
	if not _wall_diggable(Vector2i(x, y)):
		return false
	jobs.append({"id": next_job_id, "type": JobType.DIG, "x": x, "y": y,
			"priority": 3, "assigned_id": -1, "progress": 0.0})
	next_job_id += 1
	return true

## 部屋テンプレートが置けるか (§3-15。x,y は左上角)。素の FLOOR のみ・既存部屋
## /建設予定と非重複 (EXTERIOR/巣口/トーテム/集積所はタイル型で自然に弾かれる)。
func can_place_room(room_type: int, x: int, y: int) -> bool:
	if not SimParams.ROOM_BUILD_SIZE.has(room_type):
		return false
	var size: Vector2i = SimParams.ROOM_BUILD_SIZE[room_type]
	for ty in range(y, y + size.y):
		for tx in range(x, x + size.x):
			if map.get_tile(tx, ty) != TileMapData.TileType.FLOOR:
				return false
			if map.room_type_at(tx, ty) != TileMapData.RoomType.NONE:
				return false
	for j in jobs:
		if j.type != JobType.BUILD:
			continue
		if x < j.x + j.w and j.x < x + size.x and y < j.y + j.h and j.y < y + size.y:
			return false
	return true

## 建築発注 (§3-15: 建築モード→ゴースト→2 タップ確定)。建材は確定時に即時消費し、
## 完了までは建設ジョブとして jobs に居る (rooms[] へは完了時に載る)。
func order_build(room_type: int, x: int, y: int) -> bool:
	if not can_place_room(room_type, x, y):
		return false
	var cost: float = SimParams.ROOM_BUILD_COST[room_type]
	if mud < cost:
		return false
	mud -= cost
	var size: Vector2i = SimParams.ROOM_BUILD_SIZE[room_type]
	jobs.append({"id": next_job_id, "type": JobType.BUILD, "x": x, "y": y,
			"w": size.x, "h": size.y, "room_type": room_type,
			"priority": 1, "assigned_id": -1, "progress": 0.0})
	next_job_id += 1
	_event({"t": "build_start", "room_type": room_type, "x": x, "y": y})
	return true

## 壁修復の発注 (§3-20)。損傷した壁、または破られた壁跡 (再建 §9 復興) のみ。
## 建材は発注時に消費する (再建は修復より重い)。
func order_repair(x: int, y: int) -> bool:
	var rebuild := breach_sites.has(Vector2i(x, y)) \
			and map.get_tile(x, y) == TileMapData.TileType.FLOOR
	if not rebuild:
		if map.get_tile(x, y) != TileMapData.TileType.WALL:
			return false
		if map.wall_hp[map.idx(x, y)] >= MapTemplate.WALL_HP:
			return false
	for j in jobs:
		if j.type == JobType.REPAIR and j.x == x and j.y == y:
			return false  # 既に発注済み
	var cost := params.wall_rebuild_cost if rebuild else params.wall_repair_cost
	if mud < cost:
		return false
	mud -= cost
	jobs.append({"id": next_job_id, "type": JobType.REPAIR, "x": x, "y": y,
			"priority": 0, "assigned_id": -1, "progress": 0.0})
	next_job_id += 1
	return true

## 整合スイープ (§3-12 の中断表: 戦闘/恐怖/空腹/睡眠/ケンカ/死亡/巣立ち。すべての
## 中断をここで一元化する = KI-20 と同じ思想)。WORK を離れた持ち主からジョブを
## 解放し (進捗は保持)、失効したジョブ (ノード消滅・壁全快など) を破棄する。
func _step_jobs() -> void:
	for i in range(jobs.size() - 1, -1, -1):
		var j: Dictionary = jobs[i]
		if not _job_valid(j):
			_cancel_job(j)
			continue
		if j.assigned_id >= 0:
			var g := _goblin_by_id(j.assigned_id)
			if g == null or g.state != Goblin.State.WORK or g.job_id != j.id:
				if g != null and g.job_id == j.id:
					g.job_id = -1
				j.assigned_id = -1

func _job_valid(j: Dictionary) -> bool:
	match j.type:
		JobType.MINE:
			return map.get_tile(j.x, j.y) == TileMapData.TileType.RESOURCE_NODE
		JobType.REPAIR:
			# 再建 (破られた壁跡 §9): 跡が残っている限り有効。
			if breach_sites.has(Vector2i(j.x, j.y)):
				return map.get_tile(j.x, j.y) == TileMapData.TileType.FLOOR
			# 修復: 壁でなくなった (泥壁が溶けた等)・全快したら失効。
			return map.get_tile(j.x, j.y) == TileMapData.TileType.WALL \
					and map.wall_hp[map.idx(j.x, j.y)] < MapTemplate.WALL_HP
		JobType.DIG:
			# 掘削: 掘削可能な壁である限り有効 (敵のブリーチで床化したら失効)。
			return _wall_diggable(Vector2i(j.x, j.y))
		_:
			return true

func _cancel_job(j: Dictionary) -> void:
	if j.assigned_id >= 0:
		var g := _goblin_by_id(j.assigned_id)
		if g != null and g.job_id == j.id:
			g.job_id = -1
	jobs.erase(j)

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

# --- ユニークの自動搬送 (§3-21) ---

## 担ぎ手として選定できるか (非戦闘・手すき・未搬送・非ユニーク)。
## 「雌 or 子 or 手すきの個体」は戦闘/恐怖/瀕死/激昂を除いた残り全体に等しい
## (男性成体も平時や前線外なら担げる)。
func _can_carry(c: Goblin) -> bool:
	if c.state == Goblin.State.DEAD or c.state == Goblin.State.KNOCKED_OUT:
		return false
	if c.is_unique or c.carrying_id >= 0:
		return false
	if c.state == Goblin.State.COMBAT or c.state == Goblin.State.FEAR \
			or c.state == Goblin.State.DYING or c.state == Goblin.State.ENRAGED:
		return false
	return true

## 倒れたユニークへの担ぎ手割り当て (_step_goblins の直前。決定的・rng 不消費)。
## - 担ぎ手の被搬送者が死亡/起立済みなら解放する。
## - 担ぎ手のいない KNOCKED_OUT ユニークへ、最寄り (マンハッタン距離、同距離は
##   id 昇順) の _can_carry な個体を 1 体だけ割り当てる。
func _step_carry_assign() -> void:
	# 被搬送者が死亡/復帰済みの担ぎ手を解放 (1 人の被搬送者に担ぎ手 1 人を維持)。
	for c in goblins:
		if c.carrying_id < 0:
			continue
		var carried := _goblin_by_id(c.carrying_id)
		if carried == null or carried.state != Goblin.State.KNOCKED_OUT:
			c.carrying_id = -1
	for downed in goblins:
		if downed.state != Goblin.State.KNOCKED_OUT:
			continue
		var has_carrier := false
		for c in goblins:
			if c.carrying_id == downed.id:
				has_carrier = true
				break
		if has_carrier:
			continue
		var best: Goblin = null
		var best_d := 999999
		for c in goblins:
			if c.id == downed.id or not _can_carry(c):
				continue
			var d := _manhattan(c.pos(), downed.pos())
			if best == null or d < best_d or (d == best_d and c.id < best.id):
				best_d = d
				best = c
		if best != null:
			best.carrying_id = downed.id
			_event({"t": "carry_start", "carrier": best.id, "downed": downed.id})

## 寝床に降ろされた (carrying_id で誰にも担われていない) KNOCKED_OUT ユニークの
## HP 回復 (既存の自然回復 hp_regen_per_tick に乗せる)。hp > 0 になれば次 tick の
## state_machine が downed_ticks をリセットして通常ステートへ戻す。
func _step_carry_recover() -> void:
	for g in goblins:
		if g.state != Goblin.State.KNOCKED_OUT:
			continue
		if map.room_type_at(g.x, g.y) != TileMapData.RoomType.NEST:
			continue
		var being_carried := false
		for c in goblins:
			if c.carrying_id == g.id:
				being_carried = true
				break
		if being_carried:
			continue
		g.hp = min(g.max_hp, g.hp + params.hp_regen_per_tick)

## まじない医 (§6 / spec 3-17 / B4)。在任中、薬草 (herb) を消費して負傷個体の
## HP 回復を助ける。herb が尽きれば素の hp_regen のみ (キノコ農園との経済従属)。
## 効果は控えめ (D1 調整前提)。RNG は消費しない (id 順で決定的)。
##  - 平時: 寝床 (NEST) で休息中 (SLEEP/DYING) の負傷者を、追加レートで加速回復。
##  - 戦時: 後衛に控えたまじない医の周囲 (チェビシェフ medic_field_heal_radius) の
##    負傷者を遠距離で少量回復 (前衛から離れていても支援できる)。
func _step_medic() -> void:
	var medics := []
	for g in goblins:
		if g.role == Goblin.Role.WITCH_DOCTOR and g.state != Goblin.State.DEAD \
				and g.state != Goblin.State.KNOCKED_OUT:
			medics.append(g)
	if medics.is_empty():
		return
	medics.sort_custom(func(a, b): return a.id < b.id)

	# 平時: 寝床で休息中の負傷者を加速回復 (id 順に herb を消費)。
	for g in goblins:
		if g.hp >= g.max_hp:
			continue
		if g.state != Goblin.State.SLEEP and g.state != Goblin.State.DYING:
			continue
		if map.room_type_at(g.x, g.y) != TileMapData.RoomType.NEST:
			continue
		if herb < params.herb_per_medic_heal_per_tick:
			break  # herb 不足。残りは素の hp_regen のみ (state_machine が処理済み)。
		herb -= params.herb_per_medic_heal_per_tick
		g.hp = min(g.max_hp, g.hp + params.medic_heal_bonus_per_tick)

	# 戦時: 後衛のまじない医の周囲の負傷者を遠距離治療 (id 順に herb を消費)。
	if phase != Phase.COMBAT:
		return
	for m in medics:
		if herb < params.herb_per_medic_heal_per_tick:
			break
		for g in goblins:
			if g.id == m.id or g.hp >= g.max_hp:
				continue
			if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT:
				continue
			if maxi(abs(g.x - m.x), abs(g.y - m.y)) > params.medic_field_heal_radius:
				continue
			if herb < params.herb_per_medic_heal_per_tick:
				break
			herb -= params.herb_per_medic_heal_per_tick
			g.hp = min(g.max_hp, g.hp + params.medic_field_heal_per_tick)

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

## §3-16/B8: 襲撃開始時、未装備の戦闘員 (雄/ユニーク成体・生存・戦闘可) が共有在庫
## (equipment) から 1 ずつ取って装備する。在庫が尽きたら素手 (equipped=false)。
## id 順で決定的に配り、消費はスカラー (搬送・取得動線の演出は描画層 / spec 3-11 思想)。
func _equip_fighters_from_stock() -> void:
	var fighters: Array = []
	for g in goblins:
		if g.equipped or g.is_child():
			continue
		if g.sex != Goblin.Sex.MALE and not g.is_unique:
			continue
		if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT:
			continue
		fighters.append(g)
	fighters.sort_custom(func(a, b): return a.id < b.id)
	for g in fighters:
		if equipment < 1.0:
			break
		equipment -= 1.0
		g.equipped = true

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
			if g.state == Goblin.State.ENRAGED:
				atk *= params.honor_attack_mult  # 名誉ある死 (§4): 捨て身の強化
			e.hp -= atk
	# 敵 → ゴブリン。隣にゴブリンが居なければトーテムを壊しにかかる (§3-20)。
	# 抑えられない怒り (§4) 中の敵は同胞だけを殴り、ゴブリン/トーテムに手を出さない。
	for e in enemies:
		if e.enraged_ticks > 0:
			var foe := _adjacent_other_enemy(e)
			if foe != null:
				foe.hp -= params.enemy_attack
			continue
		var g := _adjacent_goblin(e.pos())
		if g != null:
			var dmg := params.enemy_attack
			# B4/spec 3-17: 後衛のまじない医は被ダメ低下 (気休め程度。決定打にはしない)。
			if g.role == Goblin.Role.WITCH_DOCTOR:
				dmg *= (1.0 - params.medic_dmg_reduce)
			g.hp -= dmg
		elif max(abs(e.x - map.totem.x), abs(e.y - map.totem.y)) <= 1:
			totem_hp -= params.enemy_attack
			if totem_hp <= 0.0:
				map.set_tile(map.totem.x, map.totem.y, TileMapData.TileType.FLOOR)
				_rebuild_floor_caches()  # トーテム破壊で FLOOR が増える (KI-09)
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
	# §3-21: 搬送中の担ぎ手は戦線に吸われない (殴り合いより搬送を優先する)。
	if g.carrying_id >= 0:
		return false
	# 激昂 (§4 名誉ある死): 恐怖も性別の縛りも越えて死ぬまで戦う。
	if g.state == Goblin.State.ENRAGED:
		return true
	if g.state == Goblin.State.FEAR or g.state == Goblin.State.DYING:
		return false
	# 雌は戦線に立たない (恐怖閾値が高い / 産み手の保護 §8)。
	if g.sex == Goblin.Sex.FEMALE and not g.is_unique:
		return false
	return true

func _end_raid() -> void:
	phase = Phase.PEACE
	_event({"t": "raid_end", "alive": _alive_count()})
	# §3-16/B8: 装備の軽い消耗。生存装備個体ごとに一定確率で壊れる (装備需要を循環。
	# rng 消費順序を保つため生存個体を id 順で回す)。
	var survivors: Array = []
	for g in goblins:
		if g.equipped and g.state != Goblin.State.DEAD:
			survivors.append(g)
	survivors.sort_custom(func(a, b): return a.id < b.id)
	for g in survivors:
		if rng.next_float() < params.equip_wear_chance:
			g.equipped = false
	# 損耗時バフ (§2.5 / KI-04): この戦闘の HP 損失割合が閾値超なら surge 発火。
	var lost_frac := 0.0
	if raid_start_hp > 0.0:
		lost_frac = (raid_start_hp - _total_hp()) / raid_start_hp
	if lost_frac > params.surge_trigger:
		surge = min(params.surge_max, surge + params.surge_gain * lost_frac)
		_event({"t": "surge", "lost_frac": lost_frac})
	# 撃退成功 (生存者あり) なら捕虜を獲得する (§2.5 襲撃撃退で捕虜 / KI-17)。
	# 直前の襲撃の勢力構成 (raid_is_human) に従って性別×種族へ振り分ける。全滅時は獲得なし。
	# 小規模 (恵み) は控えめな量 (world.ts captiveGainSmall。インフレ防止 KI-25)。
	if _alive_count() > 0:
		var total := params.small_raid_captive_gain if raid_is_small \
				else params.big_raid_captive_gain
		var male_frac := params.captive_male_frac_human if raid_is_human else params.captive_male_frac_goblin
		var males := total * male_frac
		var females := total - males
		if raid_is_human:
			cap_male_human += males
			cap_female_human += females
		else:
			cap_male_goblin += males
			cap_female_goblin += females
		_event({"t": "captive_gain", "human": raid_is_human, "male": males, "female": females})

# --- 増殖 (§3-6) ---
## 在庫/頭数 (食事回数 per capita。§2.5・B3)。頭数0なら不足側 (0) に寄せる。
func _food_per_capita() -> float:
	var pop := _alive_count()
	return 0.0 if pop <= 0 else food / float(pop)

func _step_breeding() -> void:
	# 食料従属 (§2.5・B3): 在庫/頭数で不足/過剰を判定し、求愛成立率・流産率に効く。
	var per_capita := _food_per_capita()
	var food_shortage := per_capita < params.food_per_capita_shortage
	var food_surplus := per_capita > params.food_per_capita_surplus
	# 妊娠の進行と出産。
	for g in goblins.duplicate():
		if g.pregnant:
			# 食料不足が続くと健康な個体でも確率流産する (在庫従属 §2.5・B3)。
			# 不足でなければ rng を引かない (消費順序を変えない / world.ts と同じ)。
			if food_shortage and rng.next_float() < params.food_shortage_miscarry_per_tick:
				g.pregnant = false
				g.pregnant_ticks = 0
				_event({"t": "miscarry", "id": g.id})
				continue
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
		# 損耗バフ + 食料過剰バフで誘いの発火率を上乗せ、食料不足で抑制 (§2.5・B3)。
		var food_bonus := params.food_surplus_court_bonus if food_surplus else 0.0
		var food_mult := params.food_shortage_court_mult if food_shortage else 1.0
		var chance := params.court_base_chance * (1.0 + surge + food_bonus) * food_mult
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

## 求愛を中断させる危機ステートか (FEAR/COMBAT/DYING/KNOCKED_OUT/ENRAGED)。
func _court_blocked(g: Goblin) -> bool:
	return g.state == Goblin.State.FEAR or g.state == Goblin.State.COMBAT \
		or g.state == Goblin.State.ENRAGED \
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

# --- 捕虜の平時自動加入 (KI-17) ---
# 投獄された雄ゴブリン捕虜は、平時に低確率で「気が向いて」群れに加わる。
# 成体なので即戦力 (子の成長ラグなし)。雄は自前で生まれるため旨味は薄いが、
# 急な戦力穴埋めや、生贄にするほどでもない端数の捌け口になる (world.ts §3.6 相当)。
func _step_captives() -> void:
	if phase != Phase.PEACE:
		return
	if cap_male_goblin < 1.0:
		return
	if rng.next_float() < params.male_captive_join_chance_per_tick:
		cap_male_goblin -= 1.0
		var g := _make_goblin(Goblin.Sex.MALE, Goblin.Role.NONE, Goblin.Origin.CAPTIVE_JOINED)
		_place(g, _random_nest_floor())
		goblins.append(g)
		_event({"t": "captive_joined", "id": g.id})

# --- 奴隷妻化 (捕虜つがい / KI-19/§3-19。B2 第二増分) ---
## suitor_id の個体が異性の捕虜を娶る。捕虜プールから 1 体取り出して側室
## (Role.CONCUBINE) として個体化し、mate_id を相互に設定する。娶った側には
## つがいバフ (_apply_bond_buff) を与える。苗床との違い: 苗床は捕虜消費のみで
## 個体は無関係だが、奴隷妻は特定個体が望み、その個体が生存力を得る。
## 異性でない・対象捕虜が居ない・suitor が不在/死亡なら何もせず false。
func take_concubine(suitor_id: int, captive_sex: int, captive_is_human: bool) -> bool:
	var suitor: Goblin = null
	for g in goblins:
		if g.id == suitor_id and g.state != Goblin.State.DEAD:
			suitor = g
			break
	if suitor == null:
		return false
	if captive_sex == suitor.sex:
		return false  # 異性のみ

	var consumed := false
	if captive_is_human and captive_sex == Goblin.Sex.MALE and cap_male_human >= 1.0:
		cap_male_human -= 1.0
		consumed = true
	elif captive_is_human and captive_sex == Goblin.Sex.FEMALE and cap_female_human >= 1.0:
		cap_female_human -= 1.0
		consumed = true
	elif not captive_is_human and captive_sex == Goblin.Sex.MALE and cap_male_goblin >= 1.0:
		cap_male_goblin -= 1.0
		consumed = true
	elif not captive_is_human and captive_sex == Goblin.Sex.FEMALE and cap_female_goblin >= 1.0:
		cap_female_goblin -= 1.0
		consumed = true
	if not consumed:
		return false

	var concubine := Goblin.new()
	concubine.id = next_goblin_id
	next_goblin_id += 1
	concubine.sex = captive_sex
	concubine.role = Goblin.Role.CONCUBINE
	concubine.origin = Goblin.Origin.CONCUBINE
	concubine.max_hp = 8.0 if captive_sex == Goblin.Sex.FEMALE else 10.0
	concubine.hp = concubine.max_hp
	concubine.born_tick = tick
	concubine.mate_id = suitor.id
	_place(concubine, _room_slot(TileMapData.RoomType.NEST, concubine.id))
	suitor.mate_id = concubine.id
	_apply_bond_buff(suitor)
	goblins.append(concubine)
	_event({"t": "take_concubine", "suitor": suitor.id, "concubine": concubine.id})
	return true

## つがいのステータスアップ。雄=生存力 (最大HP増 + 恐怖閾値↓)、雌=内政効率
## (仕事/採餌重み増) (KI-18)。対象 g を直接書き換える。
func _apply_bond_buff(g: Goblin) -> void:
	if g.sex == Goblin.Sex.MALE:
		g.max_hp += params.bond_male_hp_bonus
		g.hp += params.bond_male_hp_bonus
		g.fear_hp_bias -= params.bond_male_fear_reduce
	else:
		g.work_bias += params.bond_female_work_bonus
		g.forage_bias += params.bond_female_work_bonus

# --- 捕虜との自然つがい化 (§3-19/KI-21。B2 第二増分) ---
## 各 tick 平時にごくごく稀に発生。捕虜と巣のゴブリンの間に絆が芽生え、
## プレイヤーの承認 (approve_bond) / 引き離し (tear_apart_bond) を待つ
## 状態 (pending_bond) になる。
##
## 発生対象は2系統:
##  (a) 未娶の捕虜カテゴリ → 個体化して pending_bond の側室として加える。
##  (b) 既に側室 (Role.CONCUBINE) の捕虜 → そのまま pending_bond に昇格。
## 決定性: rng を一定順序で消費。発生率 captive_bond_chance_per_tick は極小。
## 既に承認待ちが居るなら新規発生を抑える (通知の氾濫を防ぐ)。
func _step_captive_bonding() -> void:
	if phase != Phase.PEACE:
		return
	for g in goblins:
		if g.pending_bond and g.state != Goblin.State.DEAD:
			return
	if rng.next_float() >= params.captive_bond_chance_per_tick:
		return

	# 相手になる巣のゴブリン (成体・生存・側室でない・pending でない・つがい無し) を集める。
	var eligible: Array = []
	for g in goblins:
		if g.state == Goblin.State.DEAD or g.is_child():
			continue
		if g.role == Goblin.Role.CONCUBINE or g.pending_bond:
			continue
		if g.mate_id >= 0:
			continue  # 既につがい持ちは対象外
		eligible.append(g)
	# world.ts stepCaptiveBonding と同じく、eligible が空ならここで打ち切る
	# (ルート b の 50% ロールも含めて rng を消費しない。消費順序維持)。
	if eligible.is_empty():
		return

	# (b) 既存の側室から自然つがい化するルート (50%)。
	var concubines: Array = []
	for g in goblins:
		if g.role == Goblin.Role.CONCUBINE and g.state != Goblin.State.DEAD and not g.pending_bond:
			concubines.append(g)
	if concubines.size() > 0 and rng.next_float() < 0.5:
		var pick: Goblin = concubines[rng.next_int(concubines.size())]
		# 側室は既に娶り主 (mate_id) がいる。その絆が「正当なもの」に変わる。
		pick.pending_bond = true
		_event({"t": "pending_bond", "id": pick.id})
		return

	# (a) 未娶の捕虜を個体化して pending_bond の側室として加える。
	var suitor: Goblin = eligible[rng.next_int(eligible.size())]
	var want_sex := Goblin.Sex.FEMALE if suitor.sex == Goblin.Sex.MALE else Goblin.Sex.MALE  # 異性
	# 捕虜カテゴリから 1 消費 (ゴブリン優先、なければ人間)。
	var consumed := false
	if want_sex == Goblin.Sex.FEMALE and cap_female_goblin >= 1.0:
		cap_female_goblin -= 1.0
		consumed = true
	elif want_sex == Goblin.Sex.MALE and cap_male_goblin >= 1.0:
		cap_male_goblin -= 1.0
		consumed = true
	elif want_sex == Goblin.Sex.FEMALE and cap_female_human >= 1.0:
		cap_female_human -= 1.0
		consumed = true
	elif want_sex == Goblin.Sex.MALE and cap_male_human >= 1.0:
		cap_male_human -= 1.0
		consumed = true
	if not consumed:
		return  # 該当する捕虜が居ない

	var lover := Goblin.new()
	lover.id = next_goblin_id
	next_goblin_id += 1
	lover.sex = want_sex
	lover.role = Goblin.Role.CONCUBINE
	lover.origin = Goblin.Origin.CONCUBINE
	lover.max_hp = 8.0 if want_sex == Goblin.Sex.FEMALE else 10.0
	lover.hp = lover.max_hp
	lover.born_tick = tick
	lover.mate_id = suitor.id
	lover.pending_bond = true  # 承認待ち
	_place(lover, _room_slot(TileMapData.RoomType.NEST, lover.id))
	suitor.mate_id = lover.id
	suitor.pending_bond = true
	goblins.append(lover)
	_event({"t": "pending_bond", "id": lover.id})

## 自然つがい化した捕虜を承認する (KI-21)。pending_bond を解除し、捕虜側を
## 巣に貢献する一員 (Role.NONE) に昇格させる (性別別性格を再設定)。娶り主側の
## pending_bond も解除し、まだバフ未適用 (自然発生(a)経路) ならつがいバフを与える
## (takeConcubine 経由なら既にバフ済みなので二重適用しない)。
## captive_id が見つからない/pending でなければ何もせず false。
func approve_bond(captive_id: int) -> bool:
	var captive: Goblin = null
	for g in goblins:
		if g.id == captive_id and g.pending_bond:
			captive = g
			break
	if captive == null:
		return false
	# 捕虜を貢献する一員に昇格 (側室 → 無役)。性別別性格を与える (世代差なし。
	# world.ts: sexedPersonality(sex, () => 0) と同じ基準値で 4 項目とも上書き)。
	captive.role = Goblin.Role.NONE
	captive.pending_bond = false
	if captive.sex == Goblin.Sex.FEMALE:
		captive.fear_hp_bias = 0.25
		captive.hunger_bias = 0.05
		captive.forage_bias = 0.6
		captive.work_bias = -0.1
	else:
		captive.fear_hp_bias = -0.2
		captive.hunger_bias = 0.0
		captive.forage_bias = 0.0
		captive.work_bias = 0.15
	_apply_bond_buff(captive)  # つがいバフ
	# 娶り主側も pending_bond 解除。
	var mate := _goblin_by_id(captive.mate_id)
	if mate != null:
		mate.pending_bond = false
	_event({"t": "approve_bond", "id": captive.id})
	return true

## 自然つがいを引き離す (KI-21)。両方を処刑 (execution) または追放 (banishment)
## しないと引き離せない (片方だけ消すと残った方が悲嘆する仕様)。captive_id と
## その娶り主の両方を Dead にする (cleanup で除去 / KI-20 死亡ログは
## death_logged 経由で記録)。両方消すので悲嘆は発生しない。
func tear_apart_bond(captive_id: int, cause: String) -> bool:
	var captive: Goblin = null
	for g in goblins:
		if g.id == captive_id and g.pending_bond:
			captive = g
			break
	if captive == null:
		return false
	var mate := _goblin_by_id(captive.mate_id)
	captive.state = Goblin.State.DEAD
	captive.death_logged = true
	_event({"t": "death", "id": captive.id, "sex": captive.sex, "cause": cause})
	if mate != null and mate.state != Goblin.State.DEAD:
		mate.state = Goblin.State.DEAD
		mate.death_logged = true
		_event({"t": "death", "id": mate.id, "sex": mate.sex, "cause": cause})
	return true

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

## 工房の生産 (§7 / B6)。キノコ農園 → 薬草、泥鍛冶屋 → 装備。牧場と同じく
## 「その部屋で実際に WORK 中 (部屋内に居る) 個体数 × 日次レート」で加算する
## (建て置きでは生産しない / _step_food と同規律)。
func _step_workshops() -> void:
	var farmers := 0
	var smiths := 0
	for r in map.rooms:
		var rt: int = r.room_type
		if rt != TileMapData.RoomType.MUSHROOM and rt != TileMapData.RoomType.SMITHY:
			continue
		for gid in (r.assigned as Array):
			var g: Goblin = _goblin_by_id(int(gid))
			if g == null or g.state != Goblin.State.WORK or not _in_room(r, g.pos()):
				continue
			if rt == TileMapData.RoomType.MUSHROOM:
				farmers += 1
			else:
				smiths += 1
	herb += farmers * params.herb_per_farmer_tick
	equipment += smiths * params.equip_per_smith_tick

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
	# 二重構造 (§3): 残高はランク連動キャップで頭打ち、超過ぶんは累計にのみ積む。
	faith = min(faith_cap(), faith + gain)
	cum_faith += gain
	# トーテムの修繕 (§3-20): 平時に削れたぶんを直す。
	if phase == Phase.PEACE and totem_hp < params.totem_hp_max:
		totem_hp = min(params.totem_hp_max, totem_hp + params.totem_repair_per_tick)

# --- 苗床の確定生産 (§2.5/§3-19。B2 第二増分) ---
# 産み手は雌の捕虜 (胎を産み手とする部屋)。雌ゴブリン捕虜が基準の母体、解禁時のみ
# 雌人間捕虜も母体にできる (大柄ゆえ多産だが消耗も速い = KI-17 の死蔵を解消)。
# 仔は母体の種を問わず必ずゴブリン (§2.5)。Godot 版は §3-19 の確定どおり、苗床部屋
# (RoomType.NURSERY) が存在する間だけ稼働する (部屋が無ければタイマーを 0 に保つ =
# 「部屋が無ければ停止」)。rng は消費しない (世代の性別は tick からの決定的ハッシュ /
# world.ts birthNurseryChildren と同式でスナップショット往復に影響しない)。
func _step_nursery() -> void:
	var has_room := false
	for r in map.rooms:
		if r.room_type == TileMapData.RoomType.NURSERY:
			has_room = true
			break
	if not has_room:
		nursery_timer = 0.0
		return

	var goblin_hosts: float = max(0.0, cap_female_goblin)
	var human_hosts: float = max(0.0, cap_female_human) if params.human_nursery_allowed else 0.0
	if goblin_hosts <= 0.0 and human_hosts <= 0.0:
		nursery_timer = 0.0
		return

	nursery_timer += 1.0
	if nursery_timer < float(params.nursery_period_ticks):
		return
	nursery_timer = 0.0

	# ゴブリン母体ぶん (基準レート)。確定生産で子を追加 (成長ラグ付き §2.5)。
	var goblin_born := int(floor(goblin_hosts * params.nursery_yield_per_captive))
	_birth_nursery_children(goblin_born, 0)
	# 苗床は産み手を緩やかに消耗する (§2.5 即物性)。
	cap_female_goblin = max(0.0, cap_female_goblin - float(goblin_born) * params.nursery_captive_consume)

	# 人間母体ぶん (大柄ゆえ多産 = 倍率を乗せる)。多産のぶん消耗も速く、人間雌捕虜は
	# 「速いが続かない」高価値な産み手になる (KI-17 の死蔵を解消)。
	var human_born := int(floor(human_hosts * params.nursery_yield_per_captive * params.human_nursery_yield_factor))
	_birth_nursery_children(human_born, goblin_born)  # k オフセットで性別パターンを分離
	cap_female_human = max(0.0, cap_female_human - float(human_born) * params.nursery_captive_consume)
	# 人間の胎を仔産み機にする残虐が人間勢力の憎悪を募らせる (§13)。
	if human_born > 0:
		human_hostility = clampf(human_hostility + float(human_born) * params.hostility_per_human_nursery_birth, 0.0, 1.0)

## 苗床の確定生産で子ゴブリンを count 体追加する (母体の種を問わず仔はゴブリン)。
## 性別は tick と (k+kOffset) から決定的に決め、出生比 (雌 30%) に寄せる
## (rng を持たないため / スナップショット不変。world.ts birthNurseryChildren と同式)。
## 苗床部屋の床タイルへ配置する (_room_slot は rng を消費しない)。
func _birth_nursery_children(count: int, k_offset: int) -> void:
	for k in range(count):
		# JS の ToInt32 (32bit へ切り詰めてから XOR) を模す: 各乗算結果を 32bit へ
		# マスクしてから XOR する (world.ts: ((tick*2654435761) ^ ((k+kOffset)*40503)) >>> 0)。
		var a: int = (tick * 2654435761) & 0xFFFFFFFF
		var b: int = ((k + k_offset) * 40503) & 0xFFFFFFFF
		var hash_v: int = (a ^ b) & 0xFFFFFFFF
		var sex := Goblin.Sex.FEMALE if float(hash_v % 100) / 100.0 < 0.3 else Goblin.Sex.MALE
		var child := Goblin.new()
		child.id = next_goblin_id
		next_goblin_id += 1
		child.sex = sex
		child.role = Goblin.Role.NONE
		child.origin = Goblin.Origin.NURSERY
		child.max_hp = 8.0 if sex == Goblin.Sex.FEMALE else 10.0
		child.hp = child.max_hp
		child.born_tick = tick
		# 苗床産は個体差なし (world.ts: sexedPersonality(sex, () => 0))。性別ごとの
		# 基準バイアスのみ与える (jitter=0。4 項目とも既定値で初期化する)。
		if sex == Goblin.Sex.FEMALE:
			child.fear_hp_bias = 0.25
			child.hunger_bias = 0.05
			child.forage_bias = 0.6
			child.work_bias = -0.1
		else:
			child.fear_hp_bias = -0.2
			child.hunger_bias = 0.0
			child.forage_bias = 0.0
			child.work_bias = 0.15
		child.child_born_tick = tick
		child.max_hp *= 0.5  # 子は脆い (_give_birth と同条件)
		child.hp = child.max_hp
		_place(child, _room_slot(TileMapData.RoomType.NURSERY, child.id))
		goblins.append(child)
		births_total += 1
	if count > 0:
		_event({"t": "birth_nursery", "count": count})

# --- トーテムランク (§3 / P3-04) ---
## 累計信仰から導出する派生値 (保存しない = KI-09 セーフ)。減らない。
func rank() -> int:
	var r := 0
	for t in params.rank_thresholds:
		if cum_faith >= float(t):
			r += 1
	return r

## 信仰残高のキャップ (ランク連動 §3)。超過ぶんは累計にのみ積まれる。
func faith_cap() -> float:
	return params.faith_base_cap + params.faith_cap_per_rank * rank()

## シャーマン任命枠 (上限であって強制でない KI-03)。
func shaman_slots() -> int:
	return params.shaman_base_slots + rank()

## 奇跡の一律ランクアップ倍率 (§4: 性能が向上し、消費も増加する)。
func miracle_mult() -> float:
	return 1.0 + params.miracle_rank_gain * rank()

# --- 奇跡コマンド (§4): プレイヤー入力 (main.gd) / Controller から呼ぶ ---
# 規約: 残高不足・対象不在・終局時は何も消費せず false。成功時のみコストを引いて
# true。撃破後の除去と恵み食料は次 tick の _resolve_combat が一元処理する (KI-20)。
# 演出/フィードは main.gd 側が出す。cast_* は tick 外で走るが、消費する rng は
# SimState の一部なので決定性・スナップショット往復は崩れない (KI-09)。

## 嘲りの稲妻。指定 id の生存敵に固定ダメージ (敵を減らす・直接)。
func cast_lightning(enemy_id: int) -> bool:
	var cost := params.lightning_cost * miracle_mult()
	if outcome != Outcome.ONGOING or faith < cost:
		return false
	var target: EnemyUnit = null
	for e in enemies:
		if e.id == enemy_id and e.hp > 0.0:
			target = e
			break
	if target == null:
		return false
	faith -= cost
	target.hp -= params.lightning_damage * miracle_mult()
	return true

## 恵みのパン虫。巣内にパン虫を一斉に湧かせる (維持・強化/平時・面的)。
## 自然湧きの上限 (mite_max) を超えられるのは奇跡だけ (§14 パン虫の生態)。
func cast_mites() -> bool:
	var cost := params.mites_cost * miracle_mult()
	if outcome != Outcome.ONGOING or faith < cost:
		return false
	faith -= cost
	var n := int(round(params.mite_blessing_count * miracle_mult()))
	for i in range(n):
		var m := MiteUnit.new()
		m.id = next_mite_id
		next_mite_id += 1
		_place(m, _random_nest_floor())
		mites.append(m)
	_event({"t": "mite_blessing", "count": n})
	return true

## 名誉ある死。対象を激昂させる (博打/捨て身)。恐怖なし・攻撃強化で、敵が尽きる
## まで戦い続ける (解除は state_machine の ENRAGED 節)。ユニーク (族長) と子は不可。
func cast_honor(goblin_id: int) -> bool:
	var cost := params.honor_cost * miracle_mult()
	if outcome != Outcome.ONGOING or faith < cost:
		return false
	var g := _goblin_by_id(goblin_id)
	if g == null or g.is_unique or g.is_child():
		return false
	if g.state == Goblin.State.DEAD or g.state == Goblin.State.KNOCKED_OUT:
		return false
	faith -= cost
	g.state = Goblin.State.ENRAGED
	_event({"t": "honor", "id": g.id, "sex": g.sex})
	return true

# 泥壁の形 = 指定タイル + 上下左右 (十字)。坑道 (幅 1〜2) を 1 発で塞げる広さ。
const MUD_OFFS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

## 泥の抱擁。指定地点に一時的な泥壁を生成して侵入経路を塞ぐ (今すぐ凌ぐ・防御)。
## 床・巣口・外の地面のみ壁化でき、ユニットが立つタイルは避ける (閉じ込め防止)。
## 寿命が尽きると元のタイルへ戻る (_step_mud)。
func cast_mud(x: int, y: int) -> bool:
	var cost := params.mud_cost * miracle_mult()
	if outcome != Outcome.ONGOING or faith < cost:
		return false
	var expire := tick + int(params.mud_wall_ticks * miracle_mult())
	var placed: Array = []
	for o in MUD_OFFS:
		var p: Vector2i = Vector2i(x, y) + o
		if not map.in_bounds(p.x, p.y):
			continue
		var t := map.get_tile(p.x, p.y)
		if t != TileMapData.TileType.FLOOR and t != TileMapData.TileType.GATE \
				and t != TileMapData.TileType.EXTERIOR:
			continue
		if _unit_on_tile(p):
			continue
		placed.append({"x": p.x, "y": p.y, "prev": t, "expire_tick": expire})
	if placed.is_empty():
		return false
	faith -= cost
	for m in placed:
		map.set_tile(m.x, m.y, TileMapData.TileType.WALL)
		mud_walls.append(m)
	_invalidate_paths_through(placed)
	# FLOOR タイルが減るので床キャッシュを再構築する (KI-09: setup 時と restore 時で
	# 床キャッシュがズレるとパス再抽選 (_random_nest_floor) の結果が分岐し、
	# 復元後の決定性が崩れる)。
	_rebuild_floor_caches()
	_event({"t": "mud", "x": x, "y": y, "tiles": placed.size()})
	return true

## 抑えられない怒り。範囲内の敵を一定時間同士討ちさせる (敵を乱す・間接)。
func cast_rage(x: int, y: int) -> bool:
	var cost := params.rage_cost * miracle_mult()
	if outcome != Outcome.ONGOING or faith < cost:
		return false
	var dur := int(params.rage_ticks * miracle_mult())
	var n := 0
	for e in enemies:
		if e.hp > 0.0 and maxi(abs(e.x - x), abs(e.y - y)) <= params.rage_radius:
			e.enraged_ticks = dur
			n += 1
	if n == 0:
		return false
	faith -= cost
	_event({"t": "rage", "count": n})
	return true

## 下僕召喚。指定地点付近にゴブリン (成体雄) を 1 体出現させる (欠員補充・戦時/点的)。
## 消費は重く常用不可。頭数上限の対象で、超過すれば巣立ちで流出する (§4)。
func cast_summon(x: int, y: int) -> bool:
	var cost := params.summon_cost * miracle_mult()
	if outcome != Outcome.ONGOING or faith < cost:
		return false
	var p := _find_floor_near(Vector2i(x, y), 3)
	if not map.is_walkable(p.x, p.y):
		p = _random_nest_floor()
	faith -= cost
	var g := _make_goblin(Goblin.Sex.MALE, Goblin.Role.NONE, Goblin.Origin.SUMMONED)
	_place(g, p)
	goblins.append(g)
	_event({"t": "summon", "id": g.id})
	return true

## 集合命令 (§4 基本命令)。無料。平時の手すき (WANDER/WORK) を指定地点へ集める。
## 欲求・戦闘・求愛・運搬には割り込まない緊急上書き専用。解除 (rally_clear) で戻る。
func cast_rally(x: int, y: int) -> bool:
	if outcome != Outcome.ONGOING or not map.is_walkable(x, y):
		return false
	rally_point = Vector2i(x, y)
	_event({"t": "rally", "x": x, "y": y})
	return true

func rally_clear() -> void:
	if rally_point != Vector2i(-1, -1):
		_event({"t": "rally_clear"})
	rally_point = Vector2i(-1, -1)

# --- 捕虜コマンド (§2.5/§13: プレイヤー入力 / Controller から呼ぶ) ---

## 生贄。捕虜 1 体を信仰へ変換する (world.ts emergencyReinforce と同じ優先順位)。
## 優先順位: 雄ゴブリン捕虜 (安い燃料・係数 0.5) → 人間雄捕虜 → 人間雌捕虜
## → 雌ゴブリン捕虜 (最後の手段)。人間捕虜の生贄は敵対度を上げる (§13)。
## 捕虜が 1 体も無ければ何もせず false。
func sacrifice_captive() -> bool:
	if outcome != Outcome.ONGOING:
		return false
	var gain := 0.0
	var kind := ""
	if cap_male_goblin >= 1.0:
		cap_male_goblin -= 1.0
		gain = params.sacrifice_faith * params.male_sacrifice_factor
		kind = "male_goblin"
	elif cap_male_human >= 1.0:
		cap_male_human -= 1.0
		gain = params.sacrifice_faith
		kind = "male_human"
		human_hostility = clampf(human_hostility + params.hostility_per_human_sacrifice, 0.0, 1.0)
	elif cap_female_human >= 1.0:
		cap_female_human -= 1.0
		gain = params.sacrifice_faith
		kind = "female_human"
		human_hostility = clampf(human_hostility + params.hostility_per_human_sacrifice, 0.0, 1.0)
	elif cap_female_goblin >= 1.0:
		cap_female_goblin -= 1.0
		gain = params.sacrifice_faith
		kind = "female_goblin"
	else:
		return false
	# 二重構造 (§3): _step_faith と同じくキャップで頭打ち、累計には満額を積む。
	faith = min(faith_cap(), faith + gain)
	cum_faith += gain
	_event({"t": "sacrifice", "kind": kind, "gain": gain})
	return true

## 人間捕虜の解放。指定性別の人間捕虜を 1 体解放し、敵対度を下げる (§13)。
## 対象の捕虜が居なければ何もせず false。
func release_human_captive(sex: int) -> bool:
	if outcome != Outcome.ONGOING:
		return false
	if sex == Goblin.Sex.MALE and cap_male_human >= 1.0:
		cap_male_human -= 1.0
	elif sex == Goblin.Sex.FEMALE and cap_female_human >= 1.0:
		cap_female_human -= 1.0
	else:
		return false
	human_hostility = clampf(human_hostility - params.hostility_release_drop, 0.0, 1.0)
	_event({"t": "release_captive", "sex": sex})
	return true

## 朝貢 (§13 双方向化 / KI-24 残り): 捕虜 1 体を相手勢力へ返し、敵対度を大きく
## 下げる (解放より効く能動的な外交手段)。人間勢力には人間捕虜、ゴブリン部族には
## ゴブリン捕虜と、種族が合う捕虜しか差し出せない。雄から先に出す (雌は産み手と
## して温存 / KI-17)。在庫が無ければ何もせず false (world.ts tributeCaptive と同式)。
func tribute_captive(faction: String) -> bool:
	if outcome != Outcome.ONGOING:
		return false
	if faction == "human":
		if cap_male_human >= 1.0:
			cap_male_human -= 1.0
		elif cap_female_human >= 1.0:
			cap_female_human -= 1.0
		else:
			return false
		human_hostility = clampf(human_hostility - params.hostility_tribute_drop, 0.0, 1.0)
	else:
		if cap_male_goblin >= 1.0:
			cap_male_goblin -= 1.0
		elif cap_female_goblin >= 1.0:
			cap_female_goblin -= 1.0
		else:
			return false
		if faction == "bunta":
			bunta_hostility = clampf(bunta_hostility - params.hostility_tribute_drop, 0.0, 1.0)
		else:
			kugyo_hostility = clampf(kugyo_hostility - params.hostility_tribute_drop, 0.0, 1.0)
	_event({"t": "tribute", "faction": faction})
	return true

# --- 奇跡の下働きヘルパ ---
## 泥壁の寿命処理: 尽きたタイルを元へ戻す。
func _step_mud() -> void:
	if mud_walls.is_empty():
		return
	var keep: Array = []
	var reverted := false
	for m in mud_walls:
		if tick >= int(m.expire_tick):
			map.set_tile(int(m.x), int(m.y), int(m.prev))
			reverted = true
		else:
			keep.append(m)
	mud_walls = keep
	# FLOOR タイルが戻るので床キャッシュを再構築する (cast_mud と対称。KI-09)。
	if reverted:
		_rebuild_floor_caches()

## 指定タイルに生存ユニット (ゴブリン/敵/パン虫) が立っているか。
func _unit_on_tile(p: Vector2i) -> bool:
	for g in goblins:
		if g.state != Goblin.State.DEAD and g.pos() == p:
			return true
	for e in enemies:
		if e.hp > 0.0 and e.pos() == p:
			return true
	for m in mites:
		if m.pos() == p:
			return true
	return false

## 新しい壁を踏む経路を破棄して再計算させる (path 空 → _advance_along_path が引き直す)。
func _invalidate_paths_through(tiles: Array) -> void:
	var blocked := {}
	for m in tiles:
		blocked[Vector2i(int(m.x), int(m.y))] = true
	for arr in [goblins, enemies, mites]:
		for u in arr:
			for wp in u.path:
				if blocked.has(wp):
					u.path = []
					break

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

## 抑えられない怒り (§4) の標的: 自分以外で最寄りの生存敵 (マンハッタン距離)。
func _nearest_other_enemy(e: EnemyUnit) -> EnemyUnit:
	var best: EnemyUnit = null
	var best_d := 999999
	for o in enemies:
		if o.id == e.id or o.hp <= 0.0:
			continue
		var d := _manhattan(e.pos(), o.pos())
		if d < best_d:
			best_d = d
			best = o
	return best

## 隣接 (8 近傍) の自分以外の生存敵 (同士討ちの白兵判定)。
func _adjacent_other_enemy(e: EnemyUnit) -> EnemyUnit:
	for o in enemies:
		if o.id != e.id and o.hp > 0.0 \
				and maxi(abs(o.x - e.x), abs(o.y - e.y)) <= 1:
			return o
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
	_field_tiles = []
	_rebuild_defense_points()
	for y in range(map.height):
		for x in range(map.width):
			# §11.5 出現物の候補: 巣外の地面。マップ縁 (敵スポーン帯) から 2 タイル、
			# 巣口の目前 (チェビシェフ 3) を避ける。
			if map.get_tile(x, y) == TileMapData.TileType.EXTERIOR \
					and x >= 2 and y >= 2 and x < map.width - 2 and y < map.height - 2:
				var near_gate := false
				for gp in map.gates:
					if maxi(abs(x - gp.x), abs(y - gp.y)) <= 3:
						near_gate = true
						break
				if not near_gate:
					_field_tiles.append(Vector2i(x, y))
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

## まじない医の後衛持ち場 (spec 3-17)。防衛ライン (_defense_points) から更に
## medic_backline_offset 歩トーテム側へ下がった _medic_points の中から、所属する
## 戦線 (_defense_slot と同じ id 順ランク → 配分区間) に対応する地点へ。前衛の
## 持ち場と同じ巣口集計を使うことで、その戦線の負傷者に近い位置に留まる。
func _medic_slot(g: Goblin) -> Vector2i:
	if _medic_points.is_empty():
		return _sanctuary_slot(g.id)
	var medics := []
	for o in goblins:
		if o.role == Goblin.Role.WITCH_DOCTOR and o.state != Goblin.State.DEAD \
				and o.state != Goblin.State.KNOCKED_OUT:
			medics.append(o.id)
	medics.sort()
	var rank := medics.find(g.id)
	if rank < 0:
		return _sanctuary_slot(g.id)
	var frac := (float(rank) + 0.5) / float(medics.size())
	var cum := 0.0
	var gi := _medic_points.size() - 1
	for i in range(defense_alloc.size()):
		cum += defense_alloc[i]
		if frac <= cum:
			gi = i
			break
	var mp: Vector2i = _medic_points[gi]
	var slot: Vector2i = mp + OFFS8[_slot_hash(g.id) % 8]
	return slot if map.is_walkable(slot.x, slot.y) and _inside_nest(slot) else mp

## 指定タイプの部屋の床スロット (なければ大広間)。
func _room_slot(room_type: int, id: int) -> Vector2i:
	for i in range(map.rooms.size()):
		if map.rooms[i].room_type == room_type:
			var tiles: Array = _room_floors.get(i, [])
			if not tiles.is_empty():
				return tiles[_slot_hash(id) % tiles.size()]
	return _hall_slot(id)

## §3-21 搬送: p から最も近い寝床 (NEST) の床タイル (マンハッタン距離。同距離は
## 部屋・タイルの走査順で安定)。NEST が無ければ大広間スロットへ (rng 不使用)。
func _nearest_nest_floor(p: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var bd := 999999
	for i in range(map.rooms.size()):
		if map.rooms[i].room_type != TileMapData.RoomType.NEST:
			continue
		for fp in _room_floors.get(i, []):
			var d := _manhattan(p, fp)
			if d < bd:
				bd = d
				best = fp
	if best == Vector2i(-1, -1):
		return _hall_slot(p.x * 73856093 ^ p.y * 19349663)
	return best

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

## ある個体が工房 (キノコ農園/泥鍛冶屋) に配属済みか。牧場の配員プールから工房員を
## 除くために使う (相互に取り合わない。工房が無ければ常に false = 既存挙動不変)。
func _in_workshop(id: int) -> bool:
	for r in map.rooms:
		if (r.room_type == TileMapData.RoomType.MUSHROOM \
				or r.room_type == TileMapData.RoomType.SMITHY) and (id in (r.assigned as Array)):
			return true
	return false

## §7/B6: 建てた工房を少人数 (目標 workshop_staff) まで自動配員する。GDD §10
## 「建てる = 生産の意図宣言、ゴブリンが埋める」。役職なし成体・どの部屋にも未配属
## の手すきから id 順で補充する (牧場・苗床・他工房とは _has_room_assignment で排他)。
## 個別任命 UI は B7。
func _staff_workshops() -> void:
	const WORKSHOP_STAFF := 2
	for r in map.rooms:
		var rt: int = r.room_type
		if rt != TileMapData.RoomType.MUSHROOM and rt != TileMapData.RoomType.SMITHY:
			continue
		var cleaned: Array = []
		for gid in (r.assigned as Array):
			var g: Goblin = _goblin_by_id(int(gid))
			if g != null and g.state != Goblin.State.DEAD:
				cleaned.append(gid)
		r.assigned = cleaned
		if r.assigned.size() >= WORKSHOP_STAFF:
			continue
		var pool: Array = []
		for g in goblins:
			if g.role != Goblin.Role.NONE or g.is_unique or g.is_child():
				continue
			if g.state == Goblin.State.DEAD or _has_room_assignment(g.id):
				continue
			pool.append(g.id)
		pool.sort()
		for gid in pool:
			if r.assigned.size() >= WORKSHOP_STAFF:
				break
			r.assigned.append(gid)

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
						and not (g.id in assigned) and not _in_workshop(g.id):
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
		"wood": wood, "mud": mud, "herb": herb,
		"equipment": equipment, "gems": gems,
		"jobs": jobs.duplicate(true), "next_job_id": next_job_id,
		"surge": surge, "over_cap_ticks": over_cap_ticks,
		"next_big_raid_tick": next_big_raid_tick,
		"raid_is_human": raid_is_human, "raid_is_small": raid_is_small,
		"raid_faction": raid_faction,
		"raid_start_hp": raid_start_hp,
		"alarm_raised": alarm_raised,
		"mud_walls": mud_walls.map(func(m):
			return [int(m.x), int(m.y), int(m.prev), int(m.expire_tick)]),
		"breach_sites": breach_sites.map(func(b): return [b.x, b.y]),
		"defense_alloc": defense_alloc.duplicate(),
		"defense_alloc_manual": defense_alloc_manual,
		"rally_point": [rally_point.x, rally_point.y],
		"cap_male_goblin": cap_male_goblin, "cap_female_goblin": cap_female_goblin,
		"cap_male_human": cap_male_human, "cap_female_human": cap_female_human,
		"human_hostility": human_hostility,
		"bunta_hostility": bunta_hostility, "kugyo_hostility": kugyo_hostility,
		"nursery_timer": nursery_timer,
		"outcome": outcome, "next_goblin_id": next_goblin_id,
		"next_enemy_id": next_enemy_id, "next_mite_id": next_mite_id,
		"next_field_id": next_field_id,
		"deaths_total": deaths_total, "births_total": births_total,
		"rng": rng.snapshot(),
		"map": map.snapshot(),
		"goblins": goblins.map(func(g): return g.snapshot()),
		"enemies": enemies.map(func(e): return e.snapshot()),
		"mites": mites.map(func(m): return m.snapshot()),
		"field_resources": field_resources.map(func(f): return f.snapshot()),
	}

func restore(d: Dictionary) -> void:
	tick = d.tick; day = d.day; phase = d.phase; totem_hp = d.totem_hp
	faith = d.faith; cum_faith = d.cum_faith; food = d.food
	wood = d.get("wood", 0.0); mud = d.get("mud", 0.0); herb = d.get("herb", 0.0)
	equipment = d.get("equipment", 0.0); gems = d.get("gems", 0.0)
	# jobs: JSON 経由だと int フィールド (id/type/x/y/priority/assigned_id/w/h/
	# room_type) が float 化する。type 比較や map.idx() で壊れるため int() で正規化
	# する (C1 / KI-09)。progress は float のまま。BUILD のみ w/h/room_type を持つ。
	jobs = (d.get("jobs", []) as Array).map(func(j: Dictionary) -> Dictionary:
		var nj := {
			"id": int(j.id), "type": int(j.type), "x": int(j.x), "y": int(j.y),
			"priority": int(j.priority), "assigned_id": int(j.assigned_id),
			"progress": float(j.progress),
		}
		if j.has("w"): nj["w"] = int(j.w)
		if j.has("h"): nj["h"] = int(j.h)
		if j.has("room_type"): nj["room_type"] = int(j.room_type)
		return nj)
	next_job_id = int(d.get("next_job_id", 0))
	surge = d.surge; over_cap_ticks = d.over_cap_ticks
	next_big_raid_tick = d.next_big_raid_tick
	raid_is_human = d.raid_is_human; raid_is_small = d.get("raid_is_small", false)
	raid_faction = d.get("raid_faction", "kugyo")
	raid_start_hp = d.raid_start_hp
	alarm_raised = d.alarm_raised
	mud_walls = (d.get("mud_walls", []) as Array).map(func(m):
		return {"x": int(m[0]), "y": int(m[1]), "prev": int(m[2]), "expire_tick": int(m[3])})
	breach_sites = (d.get("breach_sites", []) as Array).map(func(b):
		return Vector2i(int(b[0]), int(b[1])))
	defense_alloc = (d.get("defense_alloc", []) as Array).map(func(w): return float(w))
	if defense_alloc.is_empty():
		for i in range(map.gates.size() if map != null else 0):
			defense_alloc.append(1.0 / map.gates.size())
	defense_alloc_manual = d.get("defense_alloc_manual", false)
	var rp: Array = d.get("rally_point", [-1, -1])
	rally_point = Vector2i(int(rp[0]), int(rp[1]))
	cap_male_goblin = d.cap_male_goblin; cap_female_goblin = d.cap_female_goblin
	cap_male_human = d.cap_male_human; cap_female_human = d.cap_female_human
	human_hostility = d.human_hostility
	bunta_hostility = d.get("bunta_hostility", 0.0)
	kugyo_hostility = d.get("kugyo_hostility", 0.0)
	nursery_timer = d.get("nursery_timer", 0.0)
	outcome = d.outcome; next_goblin_id = d.next_goblin_id
	next_enemy_id = d.next_enemy_id; next_mite_id = d.next_mite_id
	next_field_id = d.next_field_id
	deaths_total = d.deaths_total; births_total = d.births_total
	rng.restore(d.rng)
	map.restore(d.map)
	goblins = (d.goblins as Array).map(func(x): return Goblin.from_snapshot(x))
	enemies = (d.enemies as Array).map(func(x): return EnemyUnit.from_snapshot(x))
	mites = (d.mites as Array).map(func(x): return MiteUnit.from_snapshot(x))
	field_resources = (d.field_resources as Array).map(func(x): return FieldResource.from_snapshot(x))
	_rebuild_floor_caches()
