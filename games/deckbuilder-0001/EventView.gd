extends Node2D

# EventView — narrative event with choice buttons.
# Contract:
#   refresh(event: Dictionary) -> void
#   get_choice_rect(i: int) -> Rect2   # one rect per choice
# Draw: the event title, the body text (wrapped to fit), and a stacked, full-width
# button per choice showing that choice's "label". Reuse the ShopView/MapView palette
# + ui_font. get_choice_rect(i) MUST match the button positions in _draw.

# Viewport
const W: float = 1280.0
const H: float = 720.0

# Palette (mirrors ShopView / CombatView)
const COL_BG_TOP    := Color(0.102, 0.063, 0.188)  # #1a1030 indigo
const COL_BG_BOT    := Color(0.176, 0.106, 0.306)  # #2d1b4e violet
const COL_WHITE     := Color(1, 1, 1)
const COL_PANEL     := Color(0.08, 0.06, 0.14, 0.88)
const COL_BTN       := Color(0.65, 0.25, 0.90)
const COL_BTN_BORDER := Color(0.85, 0.65, 1.00, 0.85)

# Layout constants
const HEADER_H: float = 48.0
const PANEL_X: float  = 200.0
const PANEL_W: float  = W - PANEL_X * 2.0    # 880px centred
const TITLE_Y: float  = 90.0
const BODY_Y: float   = 160.0
const BODY_H: float   = 200.0
const BTN_START_Y: float = 390.0
const BTN_H: float   = 64.0
const BTN_GAP: float = 18.0

var _event: Dictionary = {}
var _font: Font = null


func _ready() -> void:
	if ResourceLoader.exists("res://art/ui_font.ttf"):
		_font = load("res://art/ui_font.ttf")


func refresh(event: Dictionary) -> void:
	_event = event
	queue_redraw()


# ─── Public hit-test API ──────────────────────────────────────────────────────

func get_choice_rect(i: int) -> Rect2:
	var y: float = BTN_START_Y + i * (BTN_H + BTN_GAP)
	return Rect2(PANEL_X, y, PANEL_W, BTN_H)


# ─── _draw ────────────────────────────────────────────────────────────────────

func _draw() -> void:
	_draw_background()
	_draw_header()
	_draw_title()
	_draw_body()
	_draw_choices()


func _draw_background() -> void:
	var bands: int = 16
	for i in bands:
		var t0: float = float(i) / float(bands)
		var t1: float = float(i + 1) / float(bands)
		var c: Color = COL_BG_TOP.lerp(COL_BG_BOT, (t0 + t1) * 0.5)
		draw_rect(Rect2(0.0, t0 * H, W, (t1 - t0) * H), c)


func _draw_header() -> void:
	draw_rect(Rect2(0.0, 0.0, W, HEADER_H), Color(0.05, 0.04, 0.11, 0.88))
	draw_rect(Rect2(0.0, HEADER_H - 2.0, W, 2.0), Color(0.78, 0.58, 1.00, 0.75))
	_draw_text(Vector2(W * 0.5, 30.0), "Event", 22, Color(0.92, 0.80, 0.55), true)


func _draw_title() -> void:
	var title: String = _event.get("title", "")
	if title.is_empty():
		return
	# Subtle title panel
	draw_rect(Rect2(PANEL_X - 16.0, TITLE_Y - 28.0, PANEL_W + 32.0, 44.0),
		Color(0.06, 0.05, 0.14, 0.70))
	draw_rect(Rect2(PANEL_X - 16.0, TITLE_Y - 28.0, PANEL_W + 32.0, 44.0),
		Color(0.78, 0.58, 1.00, 0.45), false, 1.5)
	_draw_text(Vector2(W * 0.5, TITLE_Y), title, 24, Color(0.95, 0.85, 1.00), true)


func _draw_body() -> void:
	var body: String = _event.get("body", "")
	if body.is_empty():
		return
	# Body panel
	draw_rect(Rect2(PANEL_X, BODY_Y, PANEL_W, BODY_H), COL_PANEL)
	draw_rect(Rect2(PANEL_X, BODY_Y, PANEL_W, BODY_H),
		Color(0.50, 0.40, 0.70, 0.45), false, 1.5)

	# Wrap body text manually — split on spaces, accumulate until too wide.
	var font: Font = _font if _font != null else ThemeDB.fallback_font
	if font == null:
		return
	var font_size: int = 17
	var line_h: float = float(font_size) + 6.0
	var max_w: float = PANEL_W - 32.0
	var words: Array = body.split(" ", false)
	var lines: Array = []
	var current_line: String = ""
	for word in words:
		var test: String = current_line + ("" if current_line.is_empty() else " ") + word
		var tw: float = font.get_string_size(test, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		if tw > max_w and not current_line.is_empty():
			lines.append(current_line)
			current_line = word
		else:
			current_line = test
	if not current_line.is_empty():
		lines.append(current_line)

	var text_y: float = BODY_Y + 28.0
	for line in lines:
		_draw_text(Vector2(W * 0.5, text_y), line, font_size, Color(0.88, 0.85, 0.95), true)
		text_y += line_h


func _draw_choices() -> void:
	var choices: Array = _event.get("choices", [])
	for i in choices.size():
		var rect: Rect2 = get_choice_rect(i)
		# Button background
		draw_rect(rect, COL_BTN)
		draw_rect(rect, COL_BTN_BORDER, false, 2.0)
		# Label
		var label: String = choices[i].get("label", "")
		_draw_text(rect.get_center() + Vector2(0.0, 7.0), label, 18, COL_WHITE, true)


# ─── Helpers ─────────────────────────────────────────────────────────────────

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
	# Shadow + fill (mirrors ShopView._draw_text convention)
	draw_string(font, pos + off + Vector2(1.0, 1.0), text, HORIZONTAL_ALIGNMENT_LEFT,
		-1, size, Color(0, 0, 0, 0.85))
	draw_string(font, pos + off, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
