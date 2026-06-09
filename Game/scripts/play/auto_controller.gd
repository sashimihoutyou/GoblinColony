extends Controller
class_name AutoController
## α版のオートプレイヤー (P1)。プレイヤー操作なしで 30 日完走を狙う最小の自動配分。
##
## やること:
##  - 牧場係が減ったら無役を補充 (食料を絶やさない)。
##  - シャーマンが居なければ無役の雄を 1 体任命 (信仰の最低限)。
## 干渉は全て Command 経由 (将来のプレイヤー操作と同じ入口 / controller.gd)。

const TARGET_RANCHERS := 3

func decide(world: World) -> void:
	# 1 日に 1 回だけ見直す (頻繁な再配分を避ける)。
	if (world.tick % world.params.ticks_per_day) != 1:
		return

	# 牧場の充足を維持。
	var ranch_idx := -1
	var ranchers := 0
	for i in range(world.map.rooms.size()):
		if world.map.rooms[i].room_type == TileMapData.RoomType.RAT_RANCH:
			ranch_idx = i
			ranchers = (world.map.rooms[i].assigned as Array).size()
			break
	if ranch_idx >= 0 and ranchers < TARGET_RANCHERS:
		var need := TARGET_RANCHERS - ranchers
		for g in world.goblins:
			if need <= 0:
				break
			if g.role == Goblin.Role.NONE and not g.is_unique and not g.is_child() \
					and g.sex == Goblin.Sex.FEMALE:
				queue.append({
					"type": CommandType.ASSIGN_ROOM,
					"goblin_id": g.id, "room_index": ranch_idx,
				})
				need -= 1

	# シャーマン最低 1 体。
	var has_shaman := false
	for g in world.goblins:
		if g.role == Goblin.Role.SHAMAN:
			has_shaman = true
			break
	if not has_shaman:
		for g in world.goblins:
			if g.role == Goblin.Role.NONE and g.sex == Goblin.Sex.MALE and not g.is_child():
				queue.append({
					"type": CommandType.APPOINT_ROLE,
					"goblin_id": g.id, "role": Goblin.Role.SHAMAN,
				})
				break
