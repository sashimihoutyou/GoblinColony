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
var surge: float = 0.0         # 損耗時バフ残量 (§2.5 / KI-04)
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
	outcome = Outcome.ONGOING
	mud_walls = []
	rally_point = Vector2i(-1, -1)
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
	_step_goblins()
	_resolve_combat()
	_step_breeding()
	_step_accidents()
	_step_social()
	_step_captives()      # §2.5/KI-17: 雄ゴブリン捕虜の平時自動加入
	_step_captive_bonding()  # §3-19/KI-21: 捕虜との自然つがい化 (承認待ち)
	_step_forage()        # T4: キノコ床の再生長を進める (食料加算は採集者の運搬で行う)
	_step_food()
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
	var count := int(params.base_enemies + params.enemy_per_day * day)
	if final_battle:
		count = int(count * params.final_mult)
	_event({"t": "raid", "count": count, "human": raid_is_human, "faction": faction, "final": final_battle})
	# 全巣口に部隊を分散 (§3-14)。
	for i in range(count):
		var gate_idx := i % map.gates.size()
		_spawn_enemy_at_gate(gate_idx, raid_is_human)

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
		ctx.assigned_to_combat = (g.sex == Goblin.Sex.MALE or g.is_unique) \
				and g.role != Goblin.Role.CONCUBINE and g.role != Goblin.Role.NURSERY_HOST
		# §11.5: 派遣中・運搬中も WORK 扱い (運搬は派遣解除後も配達を済ませる)。
		ctx.assigned_to_room = _has_room_assignment(g.id) or _is_forager(g) \
				or g.dispatch_id >= 0 or g.carrying_food
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
			g.hp -= params.enemy_attack
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
		"raid_is_human": raid_is_human, "raid_is_small": raid_is_small,
		"raid_faction": raid_faction,
		"raid_start_hp": raid_start_hp,
		"alarm_raised": alarm_raised,
		"mud_walls": mud_walls.map(func(m):
			return [int(m.x), int(m.y), int(m.prev), int(m.expire_tick)]),
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
	surge = d.surge; over_cap_ticks = d.over_cap_ticks
	next_big_raid_tick = d.next_big_raid_tick
	raid_is_human = d.raid_is_human; raid_is_small = d.get("raid_is_small", false)
	raid_faction = d.get("raid_faction", "kugyo")
	raid_start_hp = d.raid_start_hp
	alarm_raised = d.alarm_raised
	mud_walls = (d.get("mud_walls", []) as Array).map(func(m):
		return {"x": int(m[0]), "y": int(m[1]), "prev": int(m[2]), "expire_tick": int(m[3])})
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
