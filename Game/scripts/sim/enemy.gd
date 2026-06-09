extends RefCounted
class_name EnemyUnit
## 敵ユニット (§3-0 / §3-14)。同じ TileMap 上に座標を持つ。
## マップ外周 3 タイル外にスポーン → 担当巣口へ A* 移動 → 巣内へ侵入。

var id: int = 0
var x: int = 0
var y: int = 0
var hp: float = 6.0
var max_hp: float = 6.0
var target_gate_idx: int = 0   # 向かっている巣口インデックス
var path: Array = []           # Array[Vector2i]
var is_human: bool = false

func pos() -> Vector2i:
	return Vector2i(x, y)

func snapshot() -> Dictionary:
	return {
		"id": id, "x": x, "y": y, "hp": hp, "max_hp": max_hp,
		"target_gate_idx": target_gate_idx,
		"path": path.map(func(p): return [p.x, p.y]),
		"is_human": is_human,
	}

static func from_snapshot(d: Dictionary) -> EnemyUnit:
	var e := EnemyUnit.new()
	for k in d.keys():
		if k == "path":
			e.path = (d.path as Array).map(func(p): return Vector2i(p[0], p[1]))
		else:
			e.set(k, d[k])
	return e
