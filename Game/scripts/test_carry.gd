extends SceneTree
## ユニークの自動搬送 (§3-21 / B9) のヘッドレス検証。
##
## 実行: godot --headless --path Game --script res://scripts/test_carry.gd
##   - KNOCKED_OUT ユニークに最寄りの非戦闘個体が 1 体だけ担ぎ手として付く。
##   - 担ぎ手は搬送中、戦闘ステートへ遷移しない (戦線に吸われない)。
##   - 寝床 (NEST) 到達で降ろされ、回復が始まりやがて立つ。
##   - 担ぎ手が搬送不能になったら被搬送者を置き、別の担ぎ手が付きうる。
##   - carrying_id を含むスナップショット往復 + 復元後 30 tick の決定性。

func _init() -> void:
	var ok := true
	ok = _test_carrier_assignment() and ok
	ok = _test_carrier_blocks_combat() and ok
	ok = _test_deliver_and_recover() and ok
	ok = _test_carrier_drop_and_reassign() and ok
	ok = _test_snapshot_roundtrip_with_carry() and ok
	if ok:
		print("CARRY_OK")
		quit(0)
	else:
		print("CARRY_FAIL")
		quit(1)

func _make_world(seed_v: int = 7) -> World:
	var p := SimParams.new()
	p.seed = seed_v
	var w := World.new()
	w.setup(p)
	return w

func _find_chief(w: World) -> Goblin:
	for g in w.goblins:
		if g.is_unique:
			return g
	return null

## ① KNOCKED_OUT ユニークに最寄りの非戦闘個体が 1 体だけ担ぎ手として付く
## (最寄り・同距離は id 昇順で決定的)。
func _test_carrier_assignment() -> bool:
	var w := _make_world()
	var chief := _find_chief(w)
	if chief == null:
		print("  FAIL: 族長が見つからない")
		return false
	chief.hp = 0.0
	chief.state = Goblin.State.KNOCKED_OUT
	chief.downed_ticks = 0

	# 候補を 2 体用意: 近い方 (id 小) と遠い方。近い方が選ばれるはず。
	var near: Goblin = null
	var far: Goblin = null
	for g in w.goblins:
		if g.is_unique:
			continue
		if near == null:
			near = g
		elif far == null:
			far = g
		else:
			# 残りは戦闘等に巻き込まれないよう寝床へ離す (誤選定防止)。
			g.state = Goblin.State.SLEEP
	if near == null or far == null:
		print("  FAIL: 候補ゴブリンが不足")
		return false
	w._place(near, chief.pos() + Vector2i(1, 0))
	w._place(far, chief.pos() + Vector2i(5, 0))
	near.state = Goblin.State.WANDER
	far.state = Goblin.State.WANDER

	w._step_carry_assign()

	if near.carrying_id != chief.id:
		print("  FAIL: 最寄りの個体 (id=%d) が担ぎ手にならなかった (got carrying_id=%d)" \
				% [near.id, near.carrying_id])
		return false
	if far.carrying_id != -1:
		print("  FAIL: 遠い個体 (id=%d) が誤って担ぎ手になった" % far.id)
		return false
	# 2 回目の割り当てでも担ぎ手が増えない (1 人の被搬送者に担ぎ手は 1 人)。
	w._step_carry_assign()
	var carriers := 0
	for g in w.goblins:
		if g.carrying_id == chief.id:
			carriers += 1
	if carriers != 1:
		print("  FAIL: 担ぎ手が %d 人になった (1 人のはず)" % carriers)
		return false
	print("  carrier-assignment: OK (carrier id=%d)" % near.id)
	return true

## ② 担ぎ手は搬送中、敵が隣にいても COMBAT へ遷移しない (戦線に吸われない)。
func _test_carrier_blocks_combat() -> bool:
	var w := _make_world(11)
	var chief := _find_chief(w)
	chief.hp = 0.0
	chief.state = Goblin.State.KNOCKED_OUT
	chief.downed_ticks = 0

	var carrier: Goblin = null
	for g in w.goblins:
		if not g.is_unique and g.sex == Goblin.Sex.MALE and not g.is_child():
			carrier = g
			break
	if carrier == null:
		print("  FAIL: 担ぎ手候補 (雄成体) が見つからない")
		return false
	carrier.carrying_id = chief.id
	w._place(carrier, chief.pos())

	# 交戦中にし、担ぎ手の隣に敵を置く。
	w.phase = World.Phase.COMBAT
	w._spawn_enemy_at_gate(0, false)
	var e: EnemyUnit = w.enemies[0]
	w._place(e, carrier.pos() + Vector2i(1, 0))

	w._step_goblins()

	if carrier.state == Goblin.State.COMBAT:
		print("  FAIL: 搬送中の担ぎ手が COMBAT へ遷移した")
		return false
	if w._can_fight(carrier):
		print("  FAIL: 搬送中の担ぎ手が _can_fight=true のまま")
		return false
	print("  carrier-blocks-combat: OK (carrier state=%d)" % carrier.state)
	return true

## ③ 寝床 (NEST) に到達したら降ろされ (carrying_id=-1)、回復が始まりやがて立つ
## (KNOCKED_OUT 解除)。
func _test_deliver_and_recover() -> bool:
	var w := _make_world(3)
	var chief := _find_chief(w)
	chief.hp = 0.0
	chief.state = Goblin.State.KNOCKED_OUT
	chief.downed_ticks = 5  # 猶予を消費済みの状態からでも、搬送成立でリセットされる

	var carrier: Goblin = null
	for g in w.goblins:
		if not g.is_unique:
			carrier = g
			break
	if carrier == null:
		print("  FAIL: 担ぎ手候補が見つからない")
		return false
	carrier.carrying_id = chief.id
	carrier.state = Goblin.State.WANDER
	w._place(carrier, chief.pos())

	# 寝床へ運ばれるのに十分な tick を回す。
	var delivered := false
	var stood_up := false
	for i in range(int(w.params.ticks_per_day) * 2):
		w.tick_once()
		if not delivered and carrier.carrying_id == -1:
			delivered = true
			if w.map.room_type_at(chief.x, chief.y) != TileMapData.RoomType.NEST:
				print("  FAIL: 降ろされた地点が NEST ではない")
				return false
		if delivered and chief.state != Goblin.State.KNOCKED_OUT:
			stood_up = true
			break
	if not delivered:
		print("  FAIL: 寝床に到達せず降ろされなかった")
		return false
	if not stood_up:
		print("  FAIL: 回復して立ち上がらなかった")
		return false
	if chief.hp <= 0.0:
		print("  FAIL: 立ち上がった族長の HP が 0 以下")
		return false
	if chief.downed_ticks != -1:
		print("  FAIL: 立ち上がった族長の downed_ticks が -1 にリセットされていない")
		return false
	print("  deliver-and-recover: OK (chief hp=%.3f)" % chief.hp)
	return true

## ④ 担ぎ手が恐怖で搬送不能になったら被搬送者を置き (carrying_id=-1)、
## 次 tick に別の担ぎ手が付きうる。
func _test_carrier_drop_and_reassign() -> bool:
	var w := _make_world(5)
	var chief := _find_chief(w)
	chief.hp = 0.0
	chief.state = Goblin.State.KNOCKED_OUT
	chief.downed_ticks = 0

	var carrier: Goblin = null
	var other: Goblin = null
	for g in w.goblins:
		if g.is_unique:
			continue
		if carrier == null:
			carrier = g
		elif other == null:
			other = g
		else:
			g.state = Goblin.State.SLEEP  # 誤選定防止
	if carrier == null or other == null:
		print("  FAIL: 候補ゴブリンが不足")
		return false

	carrier.carrying_id = chief.id
	carrier.state = Goblin.State.WANDER
	w._place(carrier, chief.pos())
	w._place(other, chief.pos() + Vector2i(2, 0))
	other.state = Goblin.State.WANDER

	# 担ぎ手を恐怖状態に直接落とす (搬送不能)。
	carrier.state = Goblin.State.FEAR
	w._step_goblins()

	if carrier.carrying_id != -1:
		print("  FAIL: 恐怖状態の担ぎ手が被搬送者を置かなかった")
		return false

	# 次 tick の割り当てで別の担ぎ手 (other) が付きうる。
	other.state = Goblin.State.WANDER
	w._step_carry_assign()
	if other.carrying_id != chief.id:
		print("  FAIL: 別の担ぎ手 (id=%d) が再割り当てされなかった (got carrying_id=%d)" \
				% [other.id, other.carrying_id])
		return false
	print("  carrier-drop-and-reassign: OK")
	return true

## ⑤ carrying_id を含むスナップショット往復が一致し、復元後 30 tick も決定的に一致する。
func _test_snapshot_roundtrip_with_carry() -> bool:
	var w := _make_world(9)
	var chief := _find_chief(w)
	chief.hp = 0.0
	chief.state = Goblin.State.KNOCKED_OUT
	chief.downed_ticks = 1

	var carrier: Goblin = null
	for g in w.goblins:
		if not g.is_unique:
			carrier = g
			break
	carrier.carrying_id = chief.id
	carrier.state = Goblin.State.WANDER
	w._place(carrier, chief.pos() + Vector2i(3, 0))

	for i in range(10):
		w.tick_once()

	var snap := w.snapshot()
	if not snap.goblins[0].has("carrying_id"):
		print("  FAIL: snapshot に carrying_id が含まれていない")
		return false

	var w2 := World.new()
	w2.setup(w.params)
	w2.restore(snap)
	if JSON.stringify(w2.snapshot()) != JSON.stringify(snap):
		print("  FAIL: carrying_id 込みの往復が一致しない")
		return false

	for i in range(30):
		w.tick_once()
		w2.tick_once()
	if JSON.stringify(w.snapshot()) != JSON.stringify(w2.snapshot()):
		print("  FAIL: 復元後の進行が一致しない (決定性)")
		return false
	print("  snapshot-roundtrip-with-carry: OK")
	return true
