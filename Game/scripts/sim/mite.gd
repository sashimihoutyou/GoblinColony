extends RefCounted
class_name MiteUnit
## パン虫 (§3-11)。巣内をうろつく食用ザコ。攻撃せず、空腹ゴブリンに狩られて
## 一食になる (隣接された時点で食われるので hp は持たない)。
## 同じ TileMap 上に連続座標を持ち、ランダムに行き先を引いてゆっくり歩く。

var id: int = 0
# fx/fy が真の位置 (連続座標)、x/y は丸めた派生値 (goblin.gd / enemy.gd と同じ規約)。
var x: int = 0
var y: int = 0
var fx: float = 0.0
var fy: float = 0.0
var target_x: int = -1         # 現在のうろつき目標 (パス再計算判定用)
var target_y: int = -1
var path: Array = []           # Array[Vector2i]

func pos() -> Vector2i:
	return Vector2i(x, y)

func snapshot() -> Dictionary:
	return {
		"id": id, "x": x, "y": y, "fx": fx, "fy": fy,
		"target_x": target_x, "target_y": target_y,
		"path": path.map(func(p): return [p.x, p.y]),
	}

static func from_snapshot(d: Dictionary) -> MiteUnit:
	var m := MiteUnit.new()
	for k in d.keys():
		if k == "path":
			m.path = (d.path as Array).map(func(p): return Vector2i(p[0], p[1]))
		else:
			m.set(k, d[k])
	return m
