extends RefCounted
class_name MapTemplate
## 固定テンプレートの初期マップ生成 (§3-0 / P1-02)。
## ランダムなし。巣口 3 本 (北・南東・南西)・トーテム最奥・初期は族長の間のみ。
## 数値はプレイテストで調整 (§NUMBERS)。

const W := 40
const H := 30
const WALL_HP := 20  # §NUMBERS MAX_WALL_HP 暫定

static func make_initial_map() -> TileMapData:
	var m := TileMapData.new()
	m.width = W
	m.height = H
	m.terrain = PackedInt32Array()
	m.terrain.resize(W * H)
	m.wall_hp = PackedInt32Array()
	m.wall_hp.resize(W * H)

	# 全面を外部地面で初期化。
	for i in range(W * H):
		m.terrain[i] = TileMapData.TileType.EXTERIOR
		m.wall_hp[i] = 0

	# 巣の矩形 (中央)。外周を壁で囲い、内部を床にする。
	var nx := 8
	var ny := 6
	var nw := 24
	var nh := 18
	for y in range(ny, ny + nh):
		for x in range(nx, nx + nw):
			var on_edge := (x == nx or x == nx + nw - 1 or y == ny or y == ny + nh - 1)
			if on_edge:
				m.terrain[m.idx(x, y)] = TileMapData.TileType.WALL
				m.wall_hp[m.idx(x, y)] = WALL_HP
			else:
				m.terrain[m.idx(x, y)] = TileMapData.TileType.FLOOR

	# 巣口 3 本 (北・南東・南西)。壁を巣口タイルに置換。
	var gate_n := Vector2i(nx + nw / 2, ny)
	var gate_se := Vector2i(nx + nw - 1, ny + nh - 5)
	var gate_sw := Vector2i(nx, ny + nh - 5)
	for g in [gate_n, gate_se, gate_sw]:
		m.terrain[m.idx(g.x, g.y)] = TileMapData.TileType.GATE
		m.wall_hp[m.idx(g.x, g.y)] = 0
		m.gates.append(g)

	# トーテム: 巣の最奥 (北巣口から遠い南中央寄り)。
	var totem := Vector2i(nx + nw / 2, ny + nh - 3)
	m.terrain[m.idx(totem.x, totem.y)] = TileMapData.TileType.TOTEM
	m.totem = totem

	# 集積所 (§3-11)。トーテム近く。
	var storage := Vector2i(nx + nw / 2 + 3, ny + nh - 3)
	m.terrain[m.idx(storage.x, storage.y)] = TileMapData.TileType.STORAGE
	m.storage = storage

	# 採掘ノードをいくつか巣内に配置。
	for p in [Vector2i(nx + 4, ny + 3), Vector2i(nx + nw - 5, ny + 3), Vector2i(nx + 5, ny + nh - 4)]:
		m.terrain[m.idx(p.x, p.y)] = TileMapData.TileType.RESOURCE_NODE

	# 初期部屋: 族長の間 (左奥) + ネズミ牧場 (食料の最低限) + 寝床。
	_add_room(m, nx + 2, ny + nh - 6, 4, 3, TileMapData.RoomType.NEST)        # 族長の間/寝床
	_add_room(m, nx + nw - 7, ny + 2, 4, 3, TileMapData.RoomType.RAT_RANCH)   # ネズミ牧場

	return m

static func _add_room(m: TileMapData, x: int, y: int, w: int, h: int, room_type: int) -> void:
	m.rooms.append({"x": x, "y": y, "w": w, "h": h, "room_type": room_type, "assigned": []})
	# 部屋内を床にする (壁に重なる場合は床へ)。
	for ry in range(y, y + h):
		for rx in range(x, x + w):
			if m.in_bounds(rx, ry) and m.terrain[m.idx(rx, ry)] == TileMapData.TileType.FLOOR:
				pass  # 既に床
