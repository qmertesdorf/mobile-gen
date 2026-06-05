extends Node2D

# ShopView — merchant screen.
# Contract:
#   refresh(shop: Dictionary, gold: int, deck: Array) -> void
#   get_card_rect(i: int) -> Rect2        # 3 card-for-sale rects
#   get_relic_rect() -> Rect2
#   get_removal_rect() -> Rect2           # "remove a card" button
#   get_leave_rect() -> Rect2             # exit to map
# Draw: a gold counter; the 3 cards for sale with prices (dim if bought/unaffordable);
# the relic with its price (dim if none/bought); a removal button (dim if used); a
# Leave button. Positions in get_*_rect match _draw exactly.

const CardDB := preload("res://data/CardDB.gd")
const RelicDB := preload("res://data/RelicDB.gd")
const Chrome := preload("res://Chrome.gd")

# Viewport
const W: float = 1280.0
const H: float = 720.0

# Background palette (mirrors CombatView / MapView)
const COL_BG_TOP    := Color(0.102, 0.063, 0.188)  # #1a1030 indigo
const COL_BG_BOT    := Color(0.176, 0.106, 0.306)  # #2d1b4e violet
const COL_WHITE     := Color(1, 1, 1)
const COL_PANEL     := Color(0.08, 0.06, 0.14, 0.88)
const COL_GOLD      := Color(0.95, 0.80, 0.25)
const COL_MANA      := Color(0.30, 0.55, 1.00)
const COL_HP_BAR    := Color(0.20, 0.78, 0.35)
const COL_DIM       := Color(0.35, 0.35, 0.40, 0.85)
const COL_CARD_BG   := Color(0.12, 0.09, 0.20, 0.95)
const COL_BTN       := Color(0.65, 0.25, 0.90)
const COL_BTN_LEAVE := Color(0.30, 0.55, 0.35)

# Card geometry (same proportions as CombatView hand cards)
const CARD_W: float = 140.0
const CARD_H: float = 190.0

# Vertical layout anchors
const CARDS_Y: float  = 310.0   # card center-y
const RELIC_Y: float  = 310.0   # relic panel center-y (right column)
const HEADER_H: float = 48.0

# Spacing for 3 cards centered in the left 3/4 of the screen
const CARD_SPACING: float = 170.0
const CARDS_START_X: float = W * 0.5 - CARD_SPACING   # leftmost card center-x

# Right-column x (relic + removal side panel)
const SIDE_X: float = 1010.0

var _shop: Dictionary = {}
var _gold: int = 0
var _deck: Array = []

var _font: Font = null
var _tex_bg: Texture2D = null
var _tex_merchant: Texture2D = null
var _tex_relic: Dictionary = {}     # relic id -> Texture2D
var _tex_cardart: Dictionary = {}   # card id -> Texture2D (cached on demand)


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if ResourceLoader.exists("res://art/ui_font.ttf"):
		_font = load("res://art/ui_font.ttf")
	_tex_bg = _try_load("res://art/bg_shop.png")
	_tex_merchant = _try_load("res://art/merchant.png")
	for rid in RelicDB.all_ids():
		_tex_relic[rid] = _try_load("res://art/relic_%s.png" % rid)


func _try_load(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	return null


# Card-face art, loaded + cached on first use (shop contents vary per visit).
func _card_tex(cid: String) -> Texture2D:
	if not _tex_cardart.has(cid):
		_tex_cardart[cid] = _try_load("res://art/card_%s.png" % cid)
	return _tex_cardart[cid]


func refresh(shop: Dictionary, gold: int, deck: Array) -> void:
	_shop = shop
	_gold = gold
	_deck = deck
	queue_redraw()


# ─── Public hit-test API ───────────────────────────────────────────────────────

func get_card_rect(i: int) -> Rect2:
	var cx: float = CARDS_START_X + i * CARD_SPACING
	return Rect2(cx - CARD_W * 0.5, CARDS_Y - CARD_H * 0.5, CARD_W, CARD_H)


func get_relic_rect() -> Rect2:
	return Rect2(SIDE_X - 110.0, RELIC_Y - 80.0, 220.0, 160.0)


# PURGE + Leave share one footer row (matching size + baseline) so the two peer
# actions read as one deliberate control group, not two different alignment systems.
func get_removal_rect() -> Rect2:
	return Rect2(W * 0.5 - 210.0, H - 66.0, 200.0, 50.0)


func get_leave_rect() -> Rect2:
	return Rect2(W * 0.5 + 10.0, H - 66.0, 200.0, 50.0)


# ─── _draw ─────────────────────────────────────────────────────────────────────

func _draw() -> void:
	_draw_background()
	_draw_merchant()
	_draw_header()
	_draw_wares_backing()
	_draw_cards()
	_draw_relic_panel()
	_draw_removal_button()
	_draw_leave_button()


func _draw_wares_backing() -> void:
	# Bind the 3 for-sale cards into ONE display cluster (a soft framed shelf + a warm
	# "display light" glow) and seat each card with a contact shadow — so the wares read
	# as a deliberate group on a surface, not three tiles floating on the painting.
	var r0: Rect2 = get_card_rect(0)
	var r2: Rect2 = get_card_rect(2)
	var pad: float = 22.0
	var cluster := Rect2(r0.position.x - pad, r0.position.y - pad - 6.0,
		(r2.end.x - r0.position.x) + pad * 2.0, r0.size.y + pad * 2.0 + 6.0)
	draw_rect(cluster, Color(0.04, 0.03, 0.09, 0.42))
	draw_rect(cluster, Color(0.62, 0.46, 0.90, 0.30), false, 1.5)
	# Warm pool of display light behind the cards.
	draw_circle(cluster.get_center(), cluster.size.x * 0.42, Color(0.95, 0.72, 0.35, 0.07))
	# Per-card contact shadow on the cluster floor.
	for i in 3:
		var cr: Rect2 = get_card_rect(i)
		draw_set_transform(Vector2(cr.get_center().x, cr.end.y + 6.0), 0.0, Vector2(1.0, 0.30))
		draw_circle(Vector2.ZERO, cr.size.x * 0.52, Color(0.0, 0.0, 0.0, 0.30))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


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


func _draw_merchant() -> void:
	# Shopkeeper greeting on the left margin (clear of the cards at x≈400+).
	if _tex_merchant == null:
		return
	var mh: float = 380.0
	var aspect: float = float(_tex_merchant.get_width()) / float(max(_tex_merchant.get_height(), 1))
	var mw: float = mh * aspect
	var cx: float = 190.0
	var cy: float = 400.0
	draw_texture_rect(_tex_merchant,
		Rect2(cx - mw * 0.5, cy - mh * 0.5, mw, mh), false)


func _draw_header() -> void:
	# Header panel
	draw_rect(Rect2(0.0, 0.0, W, HEADER_H), Color(0.05, 0.04, 0.11, 0.88))
	draw_rect(Rect2(0.0, HEADER_H - 2.0, W, 2.0), Color(0.78, 0.58, 1.00, 0.75))
	_draw_text(Vector2(W * 0.5, 30.0), "Merchant", 22, Color(0.92, 0.80, 0.55), true)

	# Gold counter (top-right). NOTE: the generated token_gold.png reads as two stray
	# figures rather than a coin, so the counter uses the clean ⬡ coin glyph; token_gold
	# is a regen candidate (see asset_pass.notes).
	var gold_str: String = "⬡ %d Gold" % _gold
	_draw_text(Vector2(W - 24.0, 30.0), gold_str, 18, COL_GOLD, false, true)


func _draw_cards() -> void:
	var cards: Array = _shop.get("cards", [])
	for i in 3:
		var rect: Rect2 = get_card_rect(i)
		if i >= cards.size():
			_draw_card_slot_empty(rect)
			continue
		var entry: Dictionary = cards[i]
		var cid: String = entry.get("id", "")
		var cost: int = entry.get("cost", 0)
		var bought: bool = entry.get("bought", false)
		var affordable: bool = (not bought) and (_gold >= cost)
		var dim: bool = bought or (not affordable)
		_draw_card_slot(rect, cid, cost, bought, dim)


func _draw_card_slot_empty(rect: Rect2) -> void:
	draw_rect(rect, Color(0.06, 0.05, 0.12, 0.70))
	draw_rect(rect, Color(0.35, 0.30, 0.50, 0.50), false, 2.0)
	_draw_text(rect.get_center() + Vector2(0.0, 6.0), "—", 20, COL_DIM, true)


func _draw_card_slot(rect: Rect2, cid: String, cost: int, bought: bool, dim: bool) -> void:
	var text_col: Color = COL_WHITE if not dim else COL_DIM

	var card_data: Dictionary = CardDB.card(cid)
	var c_name: String = card_data.get("name", cid)
	var c_elem: String = card_data.get("element", "neutral")
	var elem_col: Color = _element_color(c_elem)

	# Full-bleed card face — the same painted art the player sees in combat.
	var art: Texture2D = _card_tex(cid)
	if art != null:
		var mod: Color = COL_WHITE if not dim else Color(0.46, 0.43, 0.52, 1.0)
		draw_texture_rect(art, rect, false, mod)
	else:
		draw_rect(rect, COL_CARD_BG if not dim else Color(0.07, 0.06, 0.12, 0.75))

	# Element-coloured border over the art.
	var border_col: Color = elem_col if not dim else Color(0.30, 0.28, 0.40, 0.60)
	draw_rect(rect, border_col, false, 2.5)

	# Sold cards recede hard — a dark veil reads "spent / gone", not merely dimmed.
	if bought:
		draw_rect(rect, Color(0.02, 0.02, 0.05, 0.55))

	# Name panel (top strip) — solid scrim for legibility over the painting.
	var top_h: float = rect.size.y * 0.20
	draw_rect(Rect2(rect.position.x, rect.position.y, rect.size.x, top_h),
		Color(0.05, 0.04, 0.12, 0.82))
	_draw_text(Vector2(rect.get_center().x, rect.position.y + top_h * 0.62),
		c_name, 13, text_col if not dim else Color(text_col.r, text_col.g, text_col.b, 0.65), true)

	# Bottom cost badge
	var bot_h: float = rect.size.y * 0.24
	draw_rect(Rect2(rect.position.x, rect.end.y - bot_h, rect.size.x, bot_h),
		Color(0.05, 0.04, 0.12, 0.82))
	if bought:
		_draw_text(Vector2(rect.get_center().x, rect.end.y - bot_h * 0.45),
			"SOLD", 14, COL_DIM, true)
	else:
		var cost_str: String = "⬡ %d" % cost
		var cost_col: Color = COL_GOLD if not dim else Color(COL_GOLD.r, COL_GOLD.g, COL_GOLD.b, 0.45)
		_draw_text(Vector2(rect.get_center().x, rect.end.y - bot_h * 0.45),
			cost_str, 15, cost_col, true)


func _draw_relic_panel() -> void:
	var relic_entry: Dictionary = _shop.get("relic", {})
	var rid: String = relic_entry.get("id", "")
	var cost: int = relic_entry.get("cost", 0)
	var bought: bool = relic_entry.get("bought", false)
	var has_relic: bool = rid != ""
	var affordable: bool = has_relic and (not bought) and (_gold >= cost)
	var dim: bool = (not has_relic) or bought or (not affordable)

	var rect: Rect2 = get_relic_rect()

	# Contact shadow seating the relic display onto the scene.
	draw_set_transform(Vector2(rect.get_center().x, rect.end.y + 4.0), 0.0, Vector2(1.0, 0.28))
	draw_circle(Vector2.ZERO, rect.size.x * 0.46, Color(0.0, 0.0, 0.0, 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Panel
	var bg_col: Color = Color(0.09, 0.07, 0.17, 0.88) if not dim else Color(0.06, 0.05, 0.11, 0.75)
	draw_rect(rect, bg_col)
	var bord_col: Color = Color(0.80, 0.60, 0.20, 0.85) if not dim else Color(0.35, 0.30, 0.45, 0.55)
	draw_rect(rect, bord_col, false, 2.0)

	var label_col: Color = COL_WHITE if not dim else COL_DIM

	# Painted relic icon — the art + name carry it, so no redundant "RELIC" header.
	# Name sits in reserved air below the icon, cost at the foot.
	var circ_c: Vector2 = Vector2(rect.get_center().x, rect.position.y + 48.0)
	var rtex: Texture2D = _tex_relic.get(rid) if has_relic else null
	if rtex != null:
		if not dim:
			draw_circle(circ_c, 26.0, Color(0.70, 0.55, 1.0, 0.20))
		var isz: float = 44.0
		var mod2: Color = COL_WHITE if not dim else Color(0.50, 0.47, 0.55, 1.0)
		draw_texture_rect(rtex,
			Rect2(circ_c.x - isz * 0.5, circ_c.y - isz * 0.5, isz, isz), false, mod2)
	else:
		draw_circle(circ_c, 24.0, Color(0.70, 0.55, 1.0, 0.30 if not dim else 0.12))
		draw_circle(circ_c, 18.0, Color(1.0, 0.5, 0.2, 0.80 if not dim else 0.30))

	var r_name: String = "None" if not has_relic else RelicDB.relic(rid).get("name", rid)
	_draw_text(Vector2(rect.get_center().x, circ_c.y + 46.0),
		r_name, 12, label_col if not dim else Color(label_col.r, label_col.g, label_col.b, 0.55), true)

	# Cost or SOLD/NONE
	if not has_relic:
		_draw_text(Vector2(rect.get_center().x, rect.end.y - 20.0), "—", 14, COL_DIM, true)
	elif bought:
		_draw_text(Vector2(rect.get_center().x, rect.end.y - 20.0), "SOLD", 14, COL_DIM, true)
	else:
		var cost_col: Color = COL_GOLD if affordable else Color(COL_GOLD.r, COL_GOLD.g, COL_GOLD.b, 0.45)
		_draw_text(Vector2(rect.get_center().x, rect.end.y - 20.0),
			"⬡ %d" % cost, 15, cost_col, true)


func _draw_removal_button() -> void:
	var removed: bool = _shop.get("removed", false)
	var removal_cost: int = _shop.get("removal_cost", 75)
	var affordable: bool = (not removed) and (_gold >= removal_cost)
	var dim: bool = removed or (not affordable)

	var rect: Rect2 = get_removal_rect()
	var font: Font = _font if _font != null else ThemeDB.fallback_font
	# Styled body (matches the other buttons), two-line label drawn over it.
	var base: Color = Color(0.50, 0.25, 0.72) if not dim else Color(0.20, 0.18, 0.28)
	Chrome.button(self, font, rect, "", base, 13)

	if removed:
		_draw_text(rect.get_center() + Vector2(0.0, 5.0), "PURGE USED", 13, COL_DIM, true)
	else:
		var cost_col: Color = COL_GOLD if affordable else Color(COL_GOLD.r, COL_GOLD.g, COL_GOLD.b, 0.45)
		_draw_text(rect.get_center() + Vector2(0.0, -6.0), "PURGE CARD", 13,
			COL_WHITE if not dim else COL_DIM, true)
		_draw_text(rect.get_center() + Vector2(0.0, 13.0),
			"⬡ %d" % removal_cost, 13, cost_col, true)


func _draw_leave_button() -> void:
	var rect: Rect2 = get_leave_rect()
	var font: Font = _font if _font != null else ThemeDB.fallback_font
	Chrome.button(self, font, rect, "Leave Shop", COL_BTN_LEAVE, 16)


# ─── Helpers ──────────────────────────────────────────────────────────────────

func _element_color(elem: String) -> Color:
	match elem:
		"fire":      return Color(1.00, 0.65, 0.10)
		"ice":       return Color(0.30, 0.90, 1.00)
		"lightning": return Color(0.80, 0.50, 1.00)
		_:           return Color(0.70, 0.70, 0.75)


# _draw_text: right-aligned when right_align=true (pos.x is the RIGHT edge).
func _draw_text(pos: Vector2, text: String, size: int, col: Color,
		centered: bool = false, right_align: bool = false) -> void:
	var font: Font = _font if _font != null else ThemeDB.fallback_font
	if font == null:
		return
	var off := Vector2(0.0, 0.0)
	if centered:
		var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		off.x = -tw * 0.5
	elif right_align:
		var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		off.x = -tw
	# Shadow + fill (mirrors MapView._draw_text convention)
	draw_string(font, pos + off + Vector2(1.0, 1.0), text, HORIZONTAL_ALIGNMENT_LEFT,
		-1, size, Color(0, 0, 0, 0.85))
	draw_string(font, pos + off, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
