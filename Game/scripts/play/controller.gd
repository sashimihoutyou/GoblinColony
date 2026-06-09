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
	CAST_MIRACLE,   # 奇跡発動 {miracle, x, y}  (P2 で実装)
	BUILD_ROOM,     # 建築 {room_type, x, y}     (P2 で実装)
	DISPATCH,       # 派遣 {count, target}        (P2 で実装)
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
			_:
				pass  # P2 で実装予定の干渉
	queue.clear()

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
