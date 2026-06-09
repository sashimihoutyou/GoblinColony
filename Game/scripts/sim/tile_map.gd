extends RefCounted
class_name TileMapData
## グリッドマップ (§3-0)。Godot 組み込みの TileMap と名前衝突を避けるため TileMapData。
##
## 整数タイル座標で全位置を表す。描画時のみ tile_size を掛けてピクセル変換する
## (§3-0 座標系)。スナップショット保存対象 (KI-09)。

enum TileType {
	FLOOR,          # 床 (通行可)
	WALL,           # 壁 (通行不可・hp あり §3-20)
	GATE,           # 巣口 (通行可・ゴブリン/敵どちらも通れる §3-0)
	EXTERIOR,       # 外部地面 (通行可)
	RESOURCE_NODE,  # 採掘対象
	STORAGE,        # 集積所 (空腹ゴブリンが food を消費 §3-11)
	TOTEM,          # トーテム (核・破壊で敗北)
	EXHAUSTED,      # 枯渇した採掘ノード
}

enum RoomType {
	NONE,
	NEST,           # 寝床 (族長の間含む)
	NURSERY,        # 苗床
	SMITHY,         # 泥鍛冶屋
	RAT_RANCH,      # ネズミ牧場 (食料)
	MUSHROOM,       # キノコ農園
	WITCH,          # まじない医
}

var width: int = 0
var height: int = 0
var terrain: PackedInt32Array = PackedInt32Array()  # width*height の flat 配列
var wall_hp: PackedInt32Array = PackedInt32Array()  # WALL タイルのみ有効 (§3-20)
var gates: Array = []   # Array[Vector2i] 巣口座標
var rooms: Array = []   # Array[Dictionary] {x,y,w,h,room_type,assigned}
var totem: Vector2i = Vector2i(-1, -1)
var storage: Vector2i = Vector2i(-1, -1)

func idx(x: int, y: int) -> int:
	return y * width + x

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height

func get_tile(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return TileType.WALL
	return terrain[idx(x, y)]

func set_tile(x: int, y: int, t: int) -> void:
	terrain[idx(x, y)] = t

## A* が通行可とみなすか (§3-0: 壁タイルのみ回避)。
func is_walkable(x: int, y: int) -> bool:
	if not in_bounds(x, y):
		return false
	return terrain[idx(x, y)] != TileType.WALL

## どの部屋タイプのタイルか (なければ NONE)。
func room_type_at(x: int, y: int) -> int:
	for r in rooms:
		if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h:
			return r.room_type
	return RoomType.NONE

func snapshot() -> Dictionary:
	return {
		"width": width,
		"height": height,
		"terrain": Array(terrain),
		"wall_hp": Array(wall_hp),
		"gates": gates.map(func(g): return [g.x, g.y]),
		"rooms": rooms.duplicate(true),
		"totem": [totem.x, totem.y],
		"storage": [storage.x, storage.y],
	}

func restore(d: Dictionary) -> void:
	width = d.width
	height = d.height
	terrain = PackedInt32Array(d.terrain)
	wall_hp = PackedInt32Array(d.wall_hp)
	gates = (d.gates as Array).map(func(g): return Vector2i(g[0], g[1]))
	rooms = (d.rooms as Array).duplicate(true)
	totem = Vector2i(d.totem[0], d.totem[1])
	storage = Vector2i(d.storage[0], d.storage[1])
