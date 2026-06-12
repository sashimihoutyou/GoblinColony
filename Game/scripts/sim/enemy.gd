extends RefCounted
class_name EnemyUnit
## 敵ユニット (§3-0 / §3-14)。同じ TileMap 上に座標を持つ。
## マップ外周 3 タイル外にスポーン → 担当巣口へ A* 移動 → 巣内へ侵入。

var id: int = 0
# fx/fy が真の位置 (連続座標)、x/y は丸めた派生値 (goblin.gd と同じ規約)。
var x: int = 0
var y: int = 0
var fx: float = 0.0
var fy: float = 0.0
var hp: float = 6.0
var max_hp: float = 6.0
var target_gate_idx: int = 0   # 向かっている巣口インデックス
var target_x: int = -1         # 現在の移動目標 (パス再計算判定用)
var target_y: int = -1
var path: Array = []           # Array[Vector2i]
var is_human: bool = false
var enraged_ticks: int = 0     # 奇跡「抑えられない怒り」(§4): 残 tick の間は同士討ち

func pos() -> Vector2i:
	return Vector2i(x, y)

func snapshot() -> Dictionary:
	return {
		"id": id, "x": x, "y": y, "fx": fx, "fy": fy, "hp": hp, "max_hp": max_hp,
		"target_gate_idx": target_gate_idx,
		"target_x": target_x, "target_y": target_y,
		"path": path.map(func(p): return [p.x, p.y]),
		"is_human": is_human,
		"enraged_ticks": enraged_ticks,
	}

static func from_snapshot(d: Dictionary) -> EnemyUnit:
	var e := EnemyUnit.new()
	for k in d.keys():
		if k == "path":
			e.path = (d.path as Array).map(func(p): return Vector2i(p[0], p[1]))
		else:
			e.set(k, d[k])
	return e
