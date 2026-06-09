extends Node2D
class_name Renderer
## 状態を持たない描画層 (§4-3)。render(world) で渡された worldState を描くだけ。
##
## エンジニアアート: 単色タイル + 文字ラベルが既定。ただし tile_textures /
## sprite_textures に画像パスが指定されていればそちらを優先で使う (ユーザ方針)。
## 画像が無い/読込失敗なら自動的に単色フォールバックへ。

var tile_size: int = 16
var _world: World = null

# 画像パス指定 (任意)。空なら単色フォールバック。
# 例: tile_textures[TileMapData.TileType.FLOOR] = "res://art/floor.png"
var tile_textures: Dictionary = {}
var goblin_texture_path: String = ""
var enemy_texture_path: String = ""

var _tex_cache: Dictionary = {}   # path -> Texture2D (失敗は null をキャッシュ)
var _font: Font

# 単色フォールバックのタイル色。
const TILE_COLORS := {
	TileMapData.TileType.FLOOR: Color(0.55, 0.45, 0.35),
	TileMapData.TileType.WALL: Color(0.20, 0.18, 0.16),
	TileMapData.TileType.GATE: Color(0.85, 0.65, 0.20),
	TileMapData.TileType.EXTERIOR: Color(0.30, 0.40, 0.25),
	TileMapData.TileType.RESOURCE_NODE: Color(0.45, 0.55, 0.70),
	TileMapData.TileType.STORAGE: Color(0.70, 0.60, 0.30),
	TileMapData.TileType.TOTEM: Color(0.85, 0.20, 0.75),
	TileMapData.TileType.EXHAUSTED: Color(0.35, 0.35, 0.35),
}

func _ready() -> void:
	_font = ThemeDB.fallback_font

func render(world: World) -> void:
	_world = world
	queue_redraw()

func _get_texture(path: String) -> Texture2D:
	if path == "":
		return null
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_tex_cache[path] = tex
	return tex

func _draw() -> void:
	if _world == null:
		return
	var m := _world.map
	# --- タイル ---
	for y in range(m.height):
		for x in range(m.width):
			var t := m.terrain[m.idx(x, y)]
			var rect := Rect2(x * tile_size, y * tile_size, tile_size, tile_size)
			var tex := _get_texture(tile_textures.get(t, ""))
			if tex != null:
				draw_texture_rect(tex, rect, false)
			else:
				draw_rect(rect, TILE_COLORS.get(t, Color.MAGENTA), true)
				# 壁の耐久を暗さで表現。
				if t == TileMapData.TileType.WALL:
					pass
			# グリッド線 (薄く)。
			draw_rect(rect, Color(0, 0, 0, 0.08), false, 1.0)

	# トーテム強調 + ラベル。
	_label(m.totem, "核", Color.WHITE)

	# --- 敵 ---
	var etex := _get_texture(enemy_texture_path)
	for e in _world.enemies:
		var c := Vector2(e.x * tile_size + tile_size / 2.0, e.y * tile_size + tile_size / 2.0)
		if etex != null:
			draw_texture(etex, c - etex.get_size() / 2.0)
		else:
			draw_circle(c, tile_size * 0.4, Color(0.85, 0.15, 0.15))
			_label_at(c, "X", Color.WHITE)

	# --- ゴブリン ---
	var gtex := _get_texture(goblin_texture_path)
	for g in _world.goblins:
		if g.state == Goblin.State.DEAD:
			continue
		var c := Vector2(g.x * tile_size + tile_size / 2.0, g.y * tile_size + tile_size / 2.0)
		if gtex != null:
			draw_texture(gtex, c - gtex.get_size() / 2.0)
		else:
			var col := _state_color(g)
			var r := tile_size * (0.45 if g.is_unique else 0.32)
			draw_circle(c, r, col)
			# 雌は縁取りで区別。
			if g.sex == Goblin.Sex.FEMALE:
				draw_arc(c, r, 0, TAU, 12, Color.WHITE, 1.5)
		# HP バー。
		var frac: float = clampf(g.hp / g.max_hp, 0.0, 1.0)
		var bar := Rect2(c.x - tile_size * 0.4, c.y - tile_size * 0.6, tile_size * 0.8 * frac, 2.0)
		draw_rect(bar, Color.GREEN if frac > 0.4 else Color.RED, true)

func _state_color(g: Goblin) -> Color:
	# 緊急度: 戦闘/恐怖/瀕死=赤、空腹/睡眠=黄、平常=緑 (§4-1 ミニカードと整合)。
	match g.state:
		Goblin.State.COMBAT, Goblin.State.FEAR, Goblin.State.DYING, Goblin.State.KNOCKED_OUT:
			return Color(0.90, 0.25, 0.20)
		Goblin.State.HUNGRY, Goblin.State.SLEEP:
			return Color(0.90, 0.80, 0.20)
		_:
			return Color(0.30, 0.75, 0.35)

func _label(tile: Vector2i, text: String, col: Color) -> void:
	var c := Vector2(tile.x * tile_size + tile_size / 2.0, tile.y * tile_size + tile_size / 2.0)
	_label_at(c, text, col)

func _label_at(c: Vector2, text: String, col: Color) -> void:
	if _font == null:
		return
	draw_string(_font, c + Vector2(-tile_size * 0.3, tile_size * 0.3), text,
		HORIZONTAL_ALIGNMENT_CENTER, -1, 10, col)
