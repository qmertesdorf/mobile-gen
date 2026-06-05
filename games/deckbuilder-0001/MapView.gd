extends Node2D

# MapView — draws the branching run map and the player's current position.
# Pure visual renderer (owns NO rules). Reads a MapModel passed via refresh().
# Immediate-mode: refresh() stores state + queue_redraw(); _draw() does everything.
#
# Contract (used by Main.gd):
#   refresh(map, cur_id: int, available: Array) -> void   # store + queue_redraw
#   get_node_rect(node_id: int) -> Rect2                   # hit-test for taps
#
# Layout: floor 0 at the BOTTOM, boss at the TOP; x by column, centered. Edges are
# drawn first (thin lines between connected node centers), then node markers coloured
# by type, then a ring/glow on the CURRENT node and a brighter highlight + larger hit
# target on each AVAILABLE-next node. Canvas is 1280×720 landscape.

const Chrome := preload("res://Chrome.gd")

# Viewport
const W: float = 1280.0
const H: float = 720.0

# Background palette (mirrors CombatView)
const COL_BG_TOP    := Color(0.102, 0.063, 0.188)  # #1a1030 indigo
const COL_BG_BOT    := Color(0.176, 0.106, 0.306)  # #2d1b4e violet
const COL_WHITE     := Color(1, 1, 1)
const COL_PANEL     := Color(0.08, 0.06, 0.14, 0.88)

# Edge line colour
const COL_EDGE      := Color(0.62, 0.50, 0.90, 0.70)
const COL_EDGE_DIM  := Color(0.52, 0.44, 0.78, 0.42)   # off-path edge — recedes
const COL_EDGE_HOT  := Color(0.95, 0.85, 0.40, 0.85)   # edge toward an available node

# Node marker geometry
const NODE_R: float = 20.0
const NODE_R_AVAIL: float = 27.0   # larger hit target for available-next nodes

# Layout margins
const MARGIN_X: float = 120.0
const MARGIN_TOP: float = 70.0
const MARGIN_BOT: float = 80.0

# Per-type marker colours (each distinct).
const TYPE_COLORS := {
	"combat":   Color(0.80, 0.30, 0.30),   # red
	"elite":    Color(0.95, 0.45, 0.10),   # orange
	"boss":     Color(0.85, 0.15, 0.75),   # magenta
	"event":    Color(0.30, 0.70, 0.95),   # cyan-blue
	"shop":     Color(0.95, 0.80, 0.25),   # gold
	"campfire": Color(0.35, 0.85, 0.45),   # green
	"treasure": Color(0.60, 0.85, 0.95),   # pale aqua
	"rest":     Color(0.35, 0.85, 0.45),   # green (legacy alias)
}

# Short type labels for markers.
const TYPE_LABELS := {
	"combat":   "FIGHT",
	"elite":    "ELITE",
	"boss":     "BOSS",
	"event":    "?",
	"shop":     "SHOP",
	"campfire": "REST",
	"treasure": "LOOT",
	"rest":     "REST",
}

var _map
var _cur_id: int = -1
var _available: Array = []

var _font: Font = null
var _tex_bg: Texture2D = null
var _tex_node: Dictionary = {}   # node type -> Texture2D


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if ResourceLoader.exists("res://art/ui_font.ttf"):
		_font = load("res://art/ui_font.ttf")
	_tex_bg = _try_load("res://art/bg_map.png")
	for t in ["combat", "elite", "boss", "event", "shop", "campfire", "treasure"]:
		_tex_node[t] = _try_load("res://art/node_%s.png" % t)
	# Legacy "rest" nodes reuse the campfire marker.
	_tex_node["rest"] = _tex_node.get("campfire")


func _try_load(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	return null


func refresh(map, cur_id: int, available: Array) -> void:
	_map = map
	_cur_id = cur_id
	_available = available
	queue_redraw()


# ─── _draw ──────────────────────────────────────────────────────────────────────

func _draw() -> void:
	_draw_background()
	if _map == null:
		return

	var fcount: int = _map.floor_count()
	if fcount <= 0:
		return

	# 1) Edges first — gently bowed paths between connected nodes. The available path
	#    (current → choosable) is bright gold; the rest of the graph recedes so the eye
	#    lands on the real choice, not on a uniform cobweb.
	for fl in range(fcount):
		for nid in _map.nodes_on_floor(fl):
			var from_c: Vector2 = _center_of(nid)
			for to_id in _map.next_of(nid):
				var to_c: Vector2 = _center_of(to_id)
				var hot: bool = (nid == _cur_id) and (to_id in _available)
				var col: Color = COL_EDGE_HOT if hot else COL_EDGE_DIM
				var wdt: float = 5.0 if hot else 3.0
				# Inset both ends to the marker radius so the path connects ring-to-ring
				# and never runs under an icon's transparent interior or its label pill.
				var dir: Vector2 = to_c - from_c
				var dist: float = dir.length()
				if dist < 1.0:
					continue
				dir /= dist
				var inset: float = NODE_R_AVAIL + 8.0
				if dist <= inset * 2.0 + 6.0:
					inset = maxf(0.0, dist * 0.5 - 6.0)
				var a: Vector2 = from_c + dir * inset
				var b: Vector2 = to_c - dir * inset
				var pts: PackedVector2Array = _curve_points(a, b)
				draw_polyline(pts, Color(0.04, 0.03, 0.08, 0.5), wdt + 2.5)
				draw_polyline(pts, col, wdt)

	# 2) Node markers, coloured by type.
	for fl in range(fcount):
		for nid in _map.nodes_on_floor(fl):
			_draw_node(nid)

	# 2b) Labels in a top-most pass — opaque pills always above any neighbour's ring.
	for fl in range(fcount):
		for nid in _map.nodes_on_floor(fl):
			_draw_node_label(nid)

	# 3) Title / legend strip.
	_draw_header()


func _draw_background() -> void:
	# Painted opaque background when present; gradient bands as a fallback.
	if _tex_bg != null:
		draw_texture_rect(_tex_bg, Rect2(0.0, 0.0, W, H), false)
		return
	var bands: int = 16
	for i in bands:
		var t0: float = float(i) / float(bands)
		var t1: float = float(i + 1) / float(bands)
		var c: Color = COL_BG_TOP.lerp(COL_BG_BOT, (t0 + t1) * 0.5)
		draw_rect(Rect2(0.0, t0 * H, W, (t1 - t0) * H), c)


func _draw_node(nid: int) -> void:
	var node: Dictionary = _map.node(nid)
	if node.is_empty():
		return
	var ntype: String = node.get("type", "")
	var center: Vector2 = _center_of(nid)
	var base_col: Color = TYPE_COLORS.get(ntype, Color(0.6, 0.6, 0.65))

	var is_current: bool = (nid == _cur_id)
	var is_available: bool = (nid in _available)
	var r: float = NODE_R_AVAIL if is_available else NODE_R

	# Soft elliptical contact shadow grounds the marker into the scene so it reads as
	# standing in the world, not floating on a wallpaper (subtler for locked nodes).
	var sh_a: float = 0.34 if (is_current or is_available) else 0.20
	draw_set_transform(center + Vector2(0.0, r * 0.82), 0.0, Vector2(1.0, 0.42))
	draw_circle(Vector2.ZERO, r * 0.95, Color(0.0, 0.0, 0.0, sh_a))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Current node: pulsing ring/glow behind the marker.
	if is_current:
		draw_circle(center, r + 14.0, Color(0.95, 0.90, 0.40, 0.18))
		draw_arc(center, r + 9.0, 0.0, TAU, 40, Color(0.98, 0.92, 0.45, 0.95), 3.0)

	# Available node: bright double halo to draw the eye (the primary "you can pick this"
	# signal, so it must read without relying on the icon's colour).
	if is_available:
		draw_circle(center, r + 11.0, Color(base_col.r, base_col.g, base_col.b, 0.38))
		draw_arc(center, r + 8.0, 0.0, TAU, 44, Color(1, 1, 1, 0.95), 3.5)
		draw_arc(center, r + 4.0, 0.0, TAU, 44, Color(0.05, 0.04, 0.10, 0.6), 1.5)

	# Marker — painted node icon when present, else the coloured disc fallback.
	# Reachable nodes (current/available) render full-bright; locked-out ones drop in
	# VALUE (genuinely darker, not just hue) so the choosable set is unmistakable even
	# in greyscale.
	var tex: Texture2D = _tex_node.get(ntype)
	var lit: bool = is_current or is_available
	if tex != null:
		var half: float = r + 4.0
		var mod: Color = COL_WHITE if lit else Color(0.42, 0.42, 0.52, 0.82)
		draw_texture_rect(tex, Rect2(center.x - half, center.y - half, half * 2.0, half * 2.0),
			false, mod)
	else:
		var disc_col: Color = base_col
		if is_available:
			disc_col = base_col.lerp(COL_WHITE, 0.25)
		elif not is_current:
			disc_col = base_col.darkened(0.45)
		draw_circle(center, r, disc_col)
		draw_arc(center, r, 0.0, TAU, 40, Color(0.05, 0.04, 0.10, 0.85), 2.0)


func _draw_node_label(nid: int) -> void:
	# Drawn in a separate top-most pass so the opaque pill is never covered by a
	# neighbouring node's ring/icon. Dim locked-node labels to match their markers.
	var node: Dictionary = _map.node(nid)
	if node.is_empty():
		return
	var ntype: String = node.get("type", "")
	var lit: bool = (nid == _cur_id) or (nid in _available)
	# Labels only where they earn their pixels: the nodes you can act on NOW, plus the
	# rare high-stakes types (boss/elite) you always want to spot from afar. Common locked
	# nodes stay icon-only so a 15-node screen isn't tiled with competing dark pills.
	if not lit and ntype != "boss" and ntype != "elite":
		return
	var center: Vector2 = _center_of(nid)
	var r: float = NODE_R_AVAIL if (nid in _available) else NODE_R
	var label: String = TYPE_LABELS.get(ntype, ntype.to_upper())
	var col: Color = COL_WHITE if lit else Color(0.78, 0.74, 0.62, 0.92)
	var font: Font = _font if _font != null else ThemeDB.fallback_font
	Chrome.label_pill(self, font, center + Vector2(0.0, r + 15.0), label, 13, col)


func _curve_points(a: Vector2, b: Vector2) -> PackedVector2Array:
	# Quadratic bezier bowed off the straight line — reads as a path, not a taut wire.
	var d: Vector2 = b - a
	var perp: Vector2 = Vector2(-d.y, d.x).normalized()
	var ctrl: Vector2 = (a + b) * 0.5 + perp * minf(d.length() * 0.16, 42.0)
	var pts: PackedVector2Array = PackedVector2Array()
	var steps: int = 10
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		var omt: float = 1.0 - t
		pts.append(omt * omt * a + 2.0 * omt * t * ctrl + t * t * b)
	return pts


func _draw_header() -> void:
	# Soft top-down scrim instead of a hard letterbox bar — the painting bleeds through
	# under the title instead of being guillotined by a flat black band.
	Chrome.vscrim(self, Rect2(0.0, 0.0, W, 60.0),
		Color(0.05, 0.04, 0.11, 0.92), Color(0.05, 0.04, 0.11, 0.0))
	_draw_text(Vector2(W * 0.5, 26.0), "Choose your path", 18,
		Color(0.92, 0.86, 0.55), true)


# ─── Geometry ─────────────────────────────────────────────────────────────────

func _center_of(node_id: int) -> Vector2:
	var node: Dictionary = _map.node(node_id)
	if node.is_empty():
		return Vector2(W * 0.5, H * 0.5)
	return _node_center(node.get("floor", 0), node.get("col", 0),
		_map.nodes_on_floor(node.get("floor", 0)).size())


func _node_center(floor: int, col: int, width: int) -> Vector2:
	# (floor,col) → screen position. floor 0 at BOTTOM, last floor at TOP; columns
	# spread horizontally and centered. _draw and get_node_rect share this so they
	# always agree.
	var fcount: int = _map.floor_count() if _map != null else 1
	var usable_h: float = H - MARGIN_TOP - MARGIN_BOT
	var y: float
	if fcount <= 1:
		y = H - MARGIN_BOT
	else:
		# floor 0 → bottom (H-MARGIN_BOT), floor (fcount-1) → top (MARGIN_TOP).
		var fy: float = float(floor) / float(fcount - 1)
		y = (H - MARGIN_BOT) - fy * usable_h

	var usable_w: float = W - 2.0 * MARGIN_X
	var x: float
	if width <= 1:
		x = W * 0.5
	else:
		var fx: float = float(col) / float(width - 1)
		x = MARGIN_X + fx * usable_w
	return Vector2(x, y)


func get_node_rect(node_id: int) -> Rect2:
	# On-screen rect for a node marker; matches the positions used in _draw.
	# Use the larger available-node radius so the tap target is generous.
	var center: Vector2 = _center_of(node_id)
	var r: float = NODE_R_AVAIL + 8.0
	return Rect2(center.x - r, center.y - r, r * 2.0, r * 2.0)


# ─── Text helper (mirrors CombatView) ─────────────────────────────────────────

func _draw_text(pos: Vector2, text: String, size: int, col: Color, centered: bool = false) -> void:
	var font: Font = _font if _font != null else ThemeDB.fallback_font
	if font == null:
		return
	var off := Vector2(0.0, 0.0)
	if centered:
		var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		off.x = -tw * 0.5
	# Shadow for legibility, then the fill.
	draw_string(font, pos + off + Vector2(1.0, 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.85))
	draw_string(font, pos + off, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
