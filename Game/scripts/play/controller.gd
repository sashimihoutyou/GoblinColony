extends RefCounted
class_name Controller
## プレイヤー/AI の意思決定をワールドへ流し込む抽象層。
##
## α版はオートプレイのみだが、次の実装で「プレイヤー操作」を同じ口に差し込めるよう、
## 全ての干渉を Command としてキューに積む形に統一する (§4-2 「対象を指定して確定」)。
## main.gd は毎 tick の直前に controller.decide(world) を呼び、queue を world に適用する。
##
## サブクラス:
##   AutoController   — α版の自動補充・自動配分 (P1)。
##   PlayerController — 将来。UI 入力を Command に変換 (P2)。

# Command 種別。world 側の干渉 API はこれを介してのみ行う (将来の操作と共通の入口)。
enum CommandType {
	ASSIGN_ROOM,    # ゴブリンを部屋へ任命 {goblin_id, room_index}
	APPOINT_ROLE,   # 役職任命 {goblin_id, role}
	CAST_MIRACLE,   # 奇跡発動 {miracle, x, y} or {miracle, target_id}
	BUILD_ROOM,     # 建築 {room_type, x, y} (§3-15。x,y = 左上角)
	DESIGNATE_MINE, # 採掘指定のトグル {x, y} (§3-12)
	DESIGNATE_DIG,  # 掘削指定のトグル {x, y} (§10 巣穴拡張)
	REPAIR_WALL,    # 壁修復の発注 {x, y} (§3-20)
	DISPATCH,       # 派遣 {count, target}  (§11.5: target = 出現物 id)
	SACRIFICE,      # 生贄 (対象不要。優先順位は world.sacrifice_captive() 側で決定)
	RELEASE_CAPTIVE,  # 人間捕虜の解放 {sex}
	TRIBUTE,        # 朝貢 {faction} ("human"/"bunta"/"kugyo" §13 双方向化)
	TRIBUTE_GEMS,   # 宝石献上 {amount} (§14/B5。非加害。gems_tributed を立てる)
	TAKE_CONCUBINE,   # 奴隷妻化 {suitor_id, captive_sex, captive_is_human} (KI-19/§3-19)
	APPROVE_BOND,     # 自然つがいの承認 {captive_id} (KI-21)
	TEAR_APART_BOND,  # 自然つがいの引き離し {captive_id, cause} (KI-21)
	SET_DEFENSE_ALLOC,  # 防衛配分スライダー {weights: Array} (§3-17)
	DEFENSE_AUTO,       # 防衛配分を自動 (敵戦力比例) へ戻す (§3-17)
}

# 奇跡の種別 (§4)。CAST_MIRACLE コマンドの cmd.miracle に入れる。
enum Miracle {
	LIGHTNING,      # 嘲りの稲妻 {target_id = 敵 id}
	MITES,          # 恵みのパン虫 (対象不要)
	HONOR,          # 名誉ある死 {target_id = ゴブリン id}
	MUD,            # 泥の抱擁 {x, y}
	RAGE,           # 抑えられない怒り {x, y}
	SUMMON,         # 下僕召喚 {x, y}
	RALLY,          # 集合命令 {x, y} (無料の基本命令)
	RALLY_CLEAR,    # 集合解除 (対象不要)
}

var queue: Array = []  # Array[Dictionary] {type, ...}

## 毎 tick 呼ばれる。サブクラスが queue に Command を積む。
func decide(_world: World) -> void:
	pass

## queue を world に適用してクリア。α版で使う最小の干渉だけ実装。
func apply(world: World) -> void:
	for cmd in queue:
		match cmd.type:
			CommandType.ASSIGN_ROOM:
				_apply_assign(world, cmd)
			CommandType.APPOINT_ROLE:
				_apply_role(world, cmd)
			CommandType.DISPATCH:
				world.dispatch_to_field(cmd.target, cmd.count)
			CommandType.CAST_MIRACLE:
				_apply_miracle(world, cmd)
			CommandType.SACRIFICE:
				world.sacrifice_captive()
			CommandType.RELEASE_CAPTIVE:
				world.release_human_captive(cmd.sex)
			CommandType.TRIBUTE:
				world.tribute_captive(cmd.faction)
			CommandType.TRIBUTE_GEMS:
				world.tribute_gems(cmd.amount)
			CommandType.BUILD_ROOM:
				world.order_build(cmd.room_type, cmd.x, cmd.y)
			CommandType.DESIGNATE_MINE:
				world.designate_mine(cmd.x, cmd.y)
			CommandType.DESIGNATE_DIG:
				world.designate_dig(cmd.x, cmd.y)
			CommandType.REPAIR_WALL:
				world.order_repair(cmd.x, cmd.y)
			CommandType.TAKE_CONCUBINE:
				world.take_concubine(cmd.suitor_id, cmd.captive_sex, cmd.captive_is_human)
			CommandType.APPROVE_BOND:
				world.approve_bond(cmd.captive_id)
			CommandType.TEAR_APART_BOND:
				world.tear_apart_bond(cmd.captive_id, cmd.cause)
			CommandType.SET_DEFENSE_ALLOC:
				world.set_defense_alloc(cmd.weights)
			CommandType.DEFENSE_AUTO:
				world.clear_defense_alloc()
			_:
				pass
	queue.clear()

func _apply_miracle(world: World, cmd: Dictionary) -> void:
	match cmd.miracle:
		Miracle.LIGHTNING:
			world.cast_lightning(cmd.get("target_id", -1))
		Miracle.MITES:
			world.cast_mites()
		Miracle.HONOR:
			world.cast_honor(cmd.get("target_id", -1))
		Miracle.MUD:
			world.cast_mud(cmd.x, cmd.y)
		Miracle.RAGE:
			world.cast_rage(cmd.x, cmd.y)
		Miracle.SUMMON:
			world.cast_summon(cmd.x, cmd.y)
		Miracle.RALLY:
			world.cast_rally(cmd.x, cmd.y)
		Miracle.RALLY_CLEAR:
			world.rally_clear()

func _apply_assign(world: World, cmd: Dictionary) -> void:
	if cmd.room_index < 0 or cmd.room_index >= world.map.rooms.size():
		return
	var room = world.map.rooms[cmd.room_index]
	if not (cmd.goblin_id in room.assigned):
		room.assigned.append(cmd.goblin_id)

func _apply_role(world: World, cmd: Dictionary) -> void:
	for g in world.goblins:
		if g.id == cmd.goblin_id:
			g.role = cmd.role
			break
