extends RefCounted
class_name Pathfinding
## A* 経路探索 (§3-0 / P1-05)。タイルグリッド上の純関数。
## 壁タイルのみ回避 (§3-13)。8 方向移動 (戦闘の 8 隣接判定と整合)。
## α版はキャッシュなしの単純実装 (最適化は P2 以降)。

const DIRS := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
]

## from から to へのパスを返す (from は含まず、to を含む)。
## 到達不能なら空配列。
static func find_path(map: TileMapData, from: Vector2i, to: Vector2i) -> Array:
	if from == to:
		return []
	if not map.is_walkable(to.x, to.y):
		return []

	var open: Array = [from]               # 簡易優先度配列
	var came_from: Dictionary = {}
	var g_score: Dictionary = {from: 0.0}
	var f_score: Dictionary = {from: _heuristic(from, to)}
	var closed: Dictionary = {}

	while not open.is_empty():
		# f_score 最小のノードを取り出す。
		var current: Vector2i = open[0]
		var best_i := 0
		for i in range(1, open.size()):
			if f_score.get(open[i], INF) < f_score.get(current, INF):
				current = open[i]
				best_i = i
		open.remove_at(best_i)

		if current == to:
			return _reconstruct(came_from, current)

		closed[current] = true
		for d in DIRS:
			var nb: Vector2i = current + d
			if not map.is_walkable(nb.x, nb.y):
				continue
			if closed.has(nb):
				continue
			# 斜め移動の角抜け禁止: 両隣のいずれかが壁なら斜め不可。
			if d.x != 0 and d.y != 0:
				if not map.is_walkable(current.x + d.x, current.y) \
						and not map.is_walkable(current.x, current.y + d.y):
					continue
			var step := 1.0 if (d.x == 0 or d.y == 0) else 1.41421356
			var tentative: float = g_score.get(current, INF) + step
			if tentative < g_score.get(nb, INF):
				came_from[nb] = current
				g_score[nb] = tentative
				f_score[nb] = tentative + _heuristic(nb, to)
				if not open.has(nb):
					open.append(nb)
	return []  # 到達不能

static func _heuristic(a: Vector2i, b: Vector2i) -> float:
	# オクタイル距離 (8 方向)。
	var dx := abs(a.x - b.x)
	var dy := abs(a.y - b.y)
	return float(dx + dy) + (1.41421356 - 2.0) * float(min(dx, dy))

static func _reconstruct(came_from: Dictionary, current: Vector2i) -> Array:
	var path: Array = [current]
	while came_from.has(current):
		current = came_from[current]
		path.push_front(current)
	path.remove_at(0)  # from を除く
	return path
