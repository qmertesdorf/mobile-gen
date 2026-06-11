extends Node2D
## View layer for Tide & Tally. Reads ShopState, replays its events as
## animation, and never owns a rule. Portrait 720x1280.

const ShopState := preload("res://ShopState.gd")
const ItemDB := preload("res://data/ItemDB.gd")
const UpgradeDB := preload("res://data/UpgradeDB.gd")
const MetaSave := preload("res://MetaSave.gd")

# Painted full-frame backdrop (raster asset pass); waves/froth/boardwalk stay code.
const TEX_BG := preload("res://art/bg_beach.png")

# --- palette (concept.art_direction: sunny flat-cartoon seaside) ---
const SAND := Color("#f2e3c2")
const SAND_DARK := Color("#dcc69c")
const SAND_WET := Color("#d4bd92")
const SEA := Color("#2fa6a0")
const SEA_DEEP := Color("#1d7d7c")
const SEA_LIGHT := Color("#5fc3bd")
const CORAL := Color("#ff7b54")
const CORAL_DARK := Color("#d95b38")
const WOOD := Color("#8a5a3b")
const WOOD_DARK := Color("#6e4527")
const INK := Color("#2b3a42")
const CREAM := Color("#fff6e3")
const GOLD := Color("#f4c542")
const RED := Color("#d8453e")
const GREEN := Color("#5da854")

const RES_COLORS: Dictionary = {
	"shell": Color("#f7cfa3"),
	"driftwood": Color("#8a5a3b"),
	"seaglass": Color("#6fd6c2"),
	"pearl": Color("#f5edf3"),
}
const PHASE_TITLES: Dictionary = {
	ShopState.Phase.GATHER: "Low Tide",
	ShopState.Phase.CRAFT: "The Workbench",
	ShopState.Phase.SELL: "Shop's Open!",
	ShopState.Phase.RESULTS: "Day's End",
	ShopState.Phase.DAY_FAILED: "Closed...",
}

var S: RefCounted
var ui: Control
var vfx_rng := RandomNumberGenerator.new()
var bg_time: float = 0.0

# shake
var shake_t: float = 0.0
var shake_dur: float = 0.0
var shake_mag: float = 0.0

# HUD refs
var hud_gold: Label
var hud_phase: Label
var hud_day: Label

# gather refs
var tide_fill: ColorRect
var tide_bar_w: float = 0.0
var carried_label: Label
var banked_label: Label
var bank_btn: Button
var node_boxes: Dictionary = {}  # engine node idx -> TapBox

# sell refs
var sell_shelves_box: Control
var sell_patrons_box: Control
var shelf_tiles: Array = []
var patron_views: Array = []   # {view, fill, maxw}
var patrons_left_label: Label
var sel_patron: int = -1
var sel_shelf: int = -1
var patrons_y: float = 680.0
var patron_skin_next: int = 0

var toast_slot: int = 0


# ================================================================= boot ====

func _ready() -> void:
	vfx_rng.randomize()
	ui = Control.new()
	ui.position = Vector2.ZERO
	ui.size = Vector2(720, 1280)
	ui.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(ui)
	S = ShopState.new()
	S.setup(int(Time.get_ticks_usec()) % 2147483647, MetaSave.read())
	_handle_events(S.start_day())
	_rebuild_ui()


func _process(delta: float) -> void:
	bg_time += delta
	queue_redraw()
	_update_shake(delta)
	var ph: int = S.phase
	if ph == ShopState.Phase.GATHER:
		_handle_events(S.tick_gather(delta))
		_update_gather_hud()
	elif ph == ShopState.Phase.SELL:
		_handle_events(S.tick_sell(delta))
		_update_sell_hud()
	_update_hud()


# ============================================================ background ====

func _draw() -> void:
	# Painted beach backdrop (sky ~0-320, sea ~320-760, sand ~760-1280).
	draw_texture_rect(TEX_BG, Rect2(0, 0, 720, 1280), false)
	# Drifting wave scallops over the painted sea only — each row stops where
	# the painted cliff begins so the arcs never stamp onto rock.
	var row_max_x: Array = [740.0, 560.0, 470.0, 430.0]
	for row in range(4):
		var wy: float = 390.0 + float(row) * 72.0
		var speed: float = 8.0 + float(row) * 7.0
		var off: float = fmod(bg_time * speed + float(row) * 41.0, 96.0)
		var x: float = -96.0 + off
		var xmax: float = row_max_x[row]
		while x < xmax:
			draw_arc(Vector2(x, wy), 26.0, PI, TAU, 10, Color(1, 1, 1, 0.28), 3.0)
			x += 96.0
	# Animated froth edge along the painted waterline (left shore only).
	var foff: float = fmod(bg_time * 14.0, 72.0)
	var fx: float = -72.0 + foff
	while fx < 430.0:
		draw_arc(Vector2(fx, 764.0), 20.0, 0.0, PI, 10, Color(1, 1, 1, 0.40), 4.0)
		fx += 72.0
	# Boardwalk planks (subtle per-plank tint + top edge highlight).
	draw_rect(Rect2(0, 1088, 720, 192), WOOD_DARK)
	draw_rect(Rect2(0, 1088, 720, 3), Color(1.0, 0.92, 0.75, 0.35))
	var py: float = 1092.0
	var row_i: int = 0
	while py < 1280.0:
		var plank: Color = WOOD.lightened(0.06) if row_i % 2 == 0 else WOOD.darkened(0.05)
		draw_rect(Rect2(0, py, 720, 42), plank)
		draw_rect(Rect2(0, py, 720, 2), Color(1.0, 0.92, 0.75, 0.14))
		var seam: float = 180.0 if row_i % 2 == 0 else 420.0
		draw_rect(Rect2(seam, py, 4, 42), WOOD_DARK)
		draw_circle(Vector2(seam - 14.0, py + 21.0), 3.0, WOOD_DARK)
		draw_circle(Vector2(seam + 18.0, py + 21.0), 3.0, WOOD_DARK)
		py += 47.0
		row_i += 1


# ================================================================ events ====

func _handle_events(events: Array) -> void:
	for e in events:
		var ev: Dictionary = e
		var t: String = ev["type"]
		match t:
			"phase_changed":
				sel_patron = -1
				sel_shelf = -1
				_rebuild_ui()
			"day_started":
				pass
			"node_collected":
				var idx: int = ev["idx"]
				var res: String = ev["res"]
				_pop_gather_node(idx, res)
			"haul_full":
				_toast("Basket full — bank it!", RED)
				if carried_label != null:
					_pulse(carried_label, 1.25)
			"banked":
				var n: int = ev["count"]
				_toast("+%d banked" % n, SEA_DEEP)
				if banked_label != null:
					_pulse(banked_label, 1.3)
			"tide_returned":
				var lost: int = ev["lost_count"]
				_froth_sweep()
				_shake(0.35, 9.0)
				if lost > 0:
					_toast("The tide swept %d away!" % lost, RED)
				else:
					_toast("The tide rolls in.", SEA_DEEP)
			"crafted":
				var rid: String = ev["recipe"]
				_toast("Crafted: %s" % ItemDB.recipe_name(rid), GREEN)
				_rebuild_ui()
			"craft_failed":
				_toast("Not enough materials", RED)
			"stocked":
				_rebuild_ui()
			"shelves_full":
				_toast("Shelves are full!", RED)
			"shop_opened":
				pass
			"patron_arrived":
				_refresh_patrons()
			"patron_left":
				_toast("A patron stormed off!", RED)
				_shake(0.15, 4.0)
				_refresh_patrons()
			"sale":
				var amt: int = ev["amount"]
				var bonus: bool = ev["bonus"]
				if bonus:
					_toast("SOLD +%dg  (in demand!)" % amt, GOLD.darkened(0.25))
				else:
					_toast("SOLD +%dg" % amt, GREEN)
				if hud_gold != null:
					_pulse(hud_gold, 1.35)
				_refresh_shelves()
				_refresh_patrons()
			"wrong_item":
				_toast("\"That's not what I want!\"", RED)
			"day_complete":
				pass
			"day_failed":
				pass
			"upgrade_bought":
				var track: String = ev["track"]
				var tr: Dictionary = UpgradeDB.track(track)
				var tname: String = tr["name"]
				_toast("Upgraded: %s" % tname, GREEN)
				_rebuild_ui()
			"upgrade_too_poor":
				_toast("Not enough gold", RED)
			"upgrade_maxed":
				_toast("Already maxed out", INK)


# ================================================================== HUD ====

func _build_hud() -> void:
	var pill := _panel(Rect2(12, 10, 696, 64), CREAM, WOOD, 3, 20)
	ui.add_child(pill)
	hud_day = _label("Day %d" % S.day, 28, INK)
	hud_day.position = Vector2(36, 24)
	hud_day.size = Vector2(140, 36)
	ui.add_child(hud_day)
	var title: String = PHASE_TITLES[S.phase]
	hud_phase = _label(title, 28, SEA_DEEP, HORIZONTAL_ALIGNMENT_CENTER)
	hud_phase.position = Vector2(160, 24)
	hud_phase.size = Vector2(400, 36)
	ui.add_child(hud_phase)
	var coin := _coin(Vector2(572, 42), 14.0)
	ui.add_child(coin)
	hud_gold = _label(str(S.gold), 28, WOOD_DARK, HORIZONTAL_ALIGNMENT_LEFT)
	hud_gold.position = Vector2(594, 24)
	hud_gold.size = Vector2(110, 36)
	hud_gold.pivot_offset = Vector2(30, 18)
	ui.add_child(hud_gold)


func _update_hud() -> void:
	if hud_gold != null:
		hud_gold.text = str(S.gold)
	if hud_day != null:
		hud_day.text = "Day %d" % S.day
	if hud_phase != null:
		var title: String = PHASE_TITLES[S.phase]
		hud_phase.text = title


# ============================================================== screens ====

func _rebuild_ui() -> void:
	for c in ui.get_children():
		c.queue_free()
	node_boxes.clear()
	shelf_tiles.clear()
	patron_views.clear()
	tide_fill = null
	carried_label = null
	banked_label = null
	patrons_left_label = null
	sell_shelves_box = null
	sell_patrons_box = null
	_build_hud()
	var ph: int = S.phase
	if ph == ShopState.Phase.GATHER:
		_build_gather()
	elif ph == ShopState.Phase.CRAFT:
		_build_craft()
	elif ph == ShopState.Phase.SELL:
		_build_sell()
	elif ph == ShopState.Phase.RESULTS:
		_build_results()
	elif ph == ShopState.Phase.DAY_FAILED:
		_build_day_failed()


# ------------------------------------------------------------- gather -----

func _build_gather() -> void:
	# Tide bar.
	var bar_bg := _panel(Rect2(12, 82, 696, 34), Color(CREAM.r, CREAM.g, CREAM.b, 0.9), SEA_DEEP, 2, 12)
	ui.add_child(bar_bg)
	tide_bar_w = 688.0
	tide_fill = ColorRect.new()
	tide_fill.position = Vector2(16, 86)
	tide_fill.size = Vector2(tide_bar_w, 26)
	tide_fill.color = SEA
	tide_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(tide_fill)
	var bar_txt := _label("TIDE", 18, INK, HORIZONTAL_ALIGNMENT_CENTER)
	bar_txt.position = Vector2(12, 88)
	bar_txt.size = Vector2(696, 22)
	ui.add_child(bar_txt)
	# Resource nodes. Map engine positions onto the painted bands first — FAR
	# pools go to open water only (the painted cliff owns the right side), NEAR
	# pools to the wet shoreline — then relax overlaps so every pool and its
	# resource icon stays readable (view-only; taps still hit the same nodes).
	var placed: Array = []
	for i in range(S.gather_nodes.size()):
		var nd: Dictionary = S.gather_nodes[i]
		if nd["taken"]:
			continue
		var pos: Vector2 = nd["pos"]
		var nx: float
		var ny: float
		if nd["far"]:
			nx = 24.0 + pos.x * 330.0
			ny = 380.0 + clampf((pos.y - 0.04) / 0.38, 0.0, 1.0) * 240.0
		else:
			nx = 24.0 + pos.x * 600.0
			ny = 764.0 + clampf((pos.y - 0.56) / 0.40, 0.0, 1.0) * 84.0
		placed.append({"idx": i, "p": Vector2(nx, ny), "far": nd["far"]})
	for pass_i in range(12):
		var moved: bool = false
		for a in range(placed.size()):
			for b in range(a + 1, placed.size()):
				var pa: Vector2 = placed[a]["p"]
				var pb: Vector2 = placed[b]["p"]
				var d: Vector2 = pb - pa
				if absf(d.x) < 86.0 and absf(d.y) < 86.0:
					var push: Vector2 = d.normalized() if d.length() > 0.01 else Vector2(1, 0)
					placed[a]["p"] = pa - push * 12.0
					placed[b]["p"] = pb + push * 12.0
					moved = true
		if not moved:
			break
	for e in placed:
		var ent: Dictionary = e
		var far_e: bool = ent["far"]
		var pv: Vector2 = ent["p"]
		pv.x = clampf(pv.x, 8.0, 354.0 if far_e else 624.0)
		pv.y = clampf(pv.y, 380.0, 620.0) if far_e else clampf(pv.y, 760.0, 850.0)
		var i2: int = ent["idx"]
		var nd2: Dictionary = S.gather_nodes[i2]
		var res: String = nd2["res"]
		var box := TapBox.new()
		box.size = Vector2(88, 88)
		box.position = pv
		var blob := NodeBlob.new()
		blob.res = res
		blob.far = far_e
		blob.size = Vector2(88, 88)
		blob.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(blob)
		var icon := IconView.new()
		icon.kind = res
		icon.position = Vector2(20, 16)
		icon.size = Vector2(48, 48)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(icon)
		box.tapped.connect(func() -> void: _handle_events(S.tap_node(i2)))
		ui.add_child(box)
		node_boxes[i2] = box
	# Basket panel.
	var bp := _panel(Rect2(12, 952, 696, 120), CREAM, WOOD, 3, 18)
	ui.add_child(bp)
	carried_label = _label("", 26, INK)
	carried_label.position = Vector2(36, 968)
	carried_label.size = Vector2(330, 34)
	carried_label.pivot_offset = Vector2(80, 17)
	ui.add_child(carried_label)
	banked_label = _label("", 26, SEA_DEEP)
	banked_label.position = Vector2(36, 1010)
	banked_label.size = Vector2(330, 34)
	banked_label.pivot_offset = Vector2(80, 17)
	ui.add_child(banked_label)
	bank_btn = _button("Bank It", CORAL)
	bank_btn.position = Vector2(400, 966)
	bank_btn.size = Vector2(280, 88)
	bank_btn.pressed.connect(func() -> void: _handle_events(S.bank()))
	ui.add_child(bank_btn)
	var go_btn := _button("Head to Shop →", WOOD)
	go_btn.position = Vector2(140, 1124)
	go_btn.size = Vector2(440, 96)
	go_btn.pressed.connect(func() -> void: _handle_events(S.finish_gather()))
	ui.add_child(go_btn)
	_update_gather_hud()


func _update_gather_hud() -> void:
	if S.phase != ShopState.Phase.GATHER:
		return
	if bank_btn != null:
		var can_bank: bool = S.unbanked_total() > 0
		bank_btn.disabled = not can_bank
		bank_btn.modulate.a = 1.0 if can_bank else 0.6
	if tide_fill != null:
		var frac: float = clamp(S.tide_left / S.tide_window(), 0.0, 1.0)
		tide_fill.size = Vector2(tide_bar_w * frac, 26.0)
		if frac < 0.25:
			var blink: float = 0.6 + 0.4 * sin(bg_time * 10.0)
			tide_fill.color = Color(CORAL.r, CORAL.g, CORAL.b, blink)
		else:
			tide_fill.color = SEA
	if carried_label != null:
		carried_label.text = "In hand: %d / %d" % [S.unbanked_total(), S.haul_capacity()]
	if banked_label != null:
		banked_label.text = "Basket: %d banked" % _dict_total(S.resources)


func _pop_gather_node(idx: int, res: String) -> void:
	if not node_boxes.has(idx):
		return
	var box: Control = node_boxes[idx]
	node_boxes.erase(idx)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in box.get_children():
		var cc: Control = c
		cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(box, "scale", Vector2(1.5, 1.5), 0.18).set_ease(Tween.EASE_OUT)
	tw.tween_property(box, "modulate:a", 0.0, 0.18)
	tw.chain().tween_callback(box.queue_free)
	var bcol: Color = RES_COLORS[res]
	_burst(box.position + Vector2(44, 44), bcol)
	if carried_label != null:
		_pulse(carried_label, 1.2)


# -------------------------------------------------------------- craft -----

func _build_craft() -> void:
	var panel := _panel(Rect2(16, 84, 688, 1000), CREAM, WOOD, 4, 22)
	ui.add_child(panel)
	# Materials row.
	var mat_title := _label("MATERIALS", 20, WOOD_DARK)
	mat_title.position = Vector2(40, 100)
	mat_title.size = Vector2(300, 26)
	ui.add_child(mat_title)
	var mx: float = 40.0
	for res in ItemDB.RESOURCES:
		var rid: String = res
		var chip := _panel(Rect2(mx, 130, 152, 56), SAND, SAND_DARK, 2, 14)
		ui.add_child(chip)
		var icon := IconView.new()
		icon.kind = rid
		icon.position = Vector2(mx + 8, 136)
		icon.size = Vector2(44, 44)
		ui.add_child(icon)
		var cnt := _label("x %d" % S.resource_count(rid), 24, INK)
		cnt.position = Vector2(mx + 58, 142)
		cnt.size = Vector2(90, 30)
		ui.add_child(cnt)
		mx += 164.0
	# Demand banner.
	var dnames: Array = []
	for d in S.demand:
		var did: String = d
		dnames.append(ItemDB.recipe_name(did))
	var demand_lbl := _label("In demand today (+50%%): %s" % ", ".join(PackedStringArray(dnames)), 21, CORAL_DARK)
	demand_lbl.position = Vector2(40, 198)
	demand_lbl.size = Vector2(640, 28)
	ui.add_child(demand_lbl)
	# Recipe rows.
	var ry: float = 236.0
	for r_id in ItemDB.RECIPE_ORDER:
		var rid2: String = r_id
		var rec: Dictionary = ItemDB.recipe(rid2)
		var row := _panel(Rect2(32, ry, 656, 78), Color(SAND.r, SAND.g, SAND.b, 0.55), SAND_DARK, 1, 12)
		ui.add_child(row)
		var icon2 := IconView.new()
		icon2.kind = rid2
		icon2.position = Vector2(44, ry + 11)
		icon2.size = Vector2(56, 56)
		ui.add_child(icon2)
		var rname: String = rec["name"]
		var price: int = rec["price"]
		var star: String = "  ★" if S.demand.has(rid2) else ""
		var name_lbl := _label(rname, 22, INK)
		name_lbl.position = Vector2(112, ry + 10)
		name_lbl.size = Vector2(240, 28)
		ui.add_child(name_lbl)
		var price_col: Color = CORAL_DARK if S.demand.has(rid2) else GOLD.darkened(0.5)
		var price_lbl := _label("%dg%s" % [price, star], 20, price_col)
		price_lbl.position = Vector2(112, ry + 42)
		price_lbl.size = Vector2(200, 26)
		ui.add_child(price_lbl)
		# Cost chips.
		var cost: Dictionary = rec["cost"]
		var cx: float = 320.0
		for cres in cost.keys():
			var crid: String = cres
			var need: int = cost[crid]
			var have: bool = S.resource_count(crid) >= need
			var ci := IconView.new()
			ci.kind = crid
			ci.position = Vector2(cx, ry + 18)
			ci.size = Vector2(34, 34)
			if not have:
				ci.modulate = Color(1, 1, 1, 0.45)
			ui.add_child(ci)
			var cl := _label(str(need), 20, INK if have else Color("#b03030"))
			cl.position = Vector2(cx + 40, ry + 24)
			cl.size = Vector2(30, 26)
			ui.add_child(cl)
			cx += 76.0
		var craft_btn := _button("Craft", SEA)
		craft_btn.disabled = not S.can_craft(rid2)
		craft_btn.position = Vector2(556, ry + 10)
		craft_btn.size = Vector2(118, 58)
		craft_btn.pressed.connect(func() -> void: _handle_events(S.craft(rid2)))
		ui.add_child(craft_btn)
		ry += 86.0
	# Shelves strip.
	var sh_lbl := _label("SHELVES  %d / %d" % [S.shelves.size(), S.shelf_slots()], 20, WOOD_DARK)
	sh_lbl.position = Vector2(40, ry + 6)
	sh_lbl.size = Vector2(300, 26)
	ui.add_child(sh_lbl)
	var sx: float = 40.0
	for i in range(S.shelf_slots()):
		var slot := _panel(Rect2(sx, ry + 36, 72, 72), Color(WOOD.r, WOOD.g, WOOD.b, 0.18), WOOD, 2, 10)
		ui.add_child(slot)
		if i < S.shelves.size():
			var sid: String = S.shelves[i]
			var si := IconView.new()
			si.kind = sid
			si.position = Vector2(sx + 12, ry + 48)
			si.size = Vector2(48, 48)
			ui.add_child(si)
		sx += 82.0
	# Workbench stock strip (tap to shelve).
	var wy: float = ry + 122.0
	var wb_lbl := _label("WORKBENCH — tap an item to shelve it", 20, WOOD_DARK)
	wb_lbl.position = Vector2(40, wy)
	wb_lbl.size = Vector2(560, 26)
	ui.add_child(wb_lbl)
	var wx: float = 40.0
	for i in range(S.stock.size()):
		var iid: String = S.stock[i]
		var tile := TapBox.new()
		tile.position = Vector2(wx, wy + 30)
		tile.size = Vector2(76, 76)
		var tp := _panel(Rect2(0, 0, 76, 76), SAND, CORAL, 2, 10)
		tp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.add_child(tp)
		var ti := IconView.new()
		ti.kind = iid
		ti.position = Vector2(14, 14)
		ti.size = Vector2(48, 48)
		ti.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.add_child(ti)
		var s_idx: int = i
		tile.tapped.connect(func() -> void: _handle_events(S.stock_shelf(s_idx)))
		ui.add_child(tile)
		wx += 86.0
	if S.stock.is_empty():
		var none_lbl := _label("(craft something above)", 19, Color(INK.r, INK.g, INK.b, 0.5))
		none_lbl.position = Vector2(40, wy + 48)
		none_lbl.size = Vector2(400, 26)
		ui.add_child(none_lbl)
	# Open shop.
	var open_btn := _button("Open Shop →", CORAL)
	open_btn.position = Vector2(140, 1124)
	open_btn.size = Vector2(440, 96)
	open_btn.pressed.connect(func() -> void: _handle_events(S.open_shop()))
	ui.add_child(open_btn)


# --------------------------------------------------------------- sell -----

func _build_sell() -> void:
	# Solid pill behind the header text — it sits over painted art.
	var head_pill := _panel(Rect2(110, 78, 500, 64), Color(CREAM.r, CREAM.g, CREAM.b, 0.94), WOOD, 2, 16)
	ui.add_child(head_pill)
	patrons_left_label = _label("", 22, INK, HORIZONTAL_ALIGNMENT_CENTER)
	patrons_left_label.position = Vector2(60, 84)
	patrons_left_label.size = Vector2(600, 28)
	ui.add_child(patrons_left_label)
	var hint := _label("Tap a patron, then the item they want", 19, Color(INK.r, INK.g, INK.b, 0.72), HORIZONTAL_ALIGNMENT_CENTER)
	hint.position = Vector2(60, 112)
	hint.size = Vector2(600, 24)
	ui.add_child(hint)
	sell_shelves_box = Control.new()
	sell_shelves_box.position = Vector2.ZERO
	sell_shelves_box.size = Vector2(720, 1280)
	# IGNORE, not PASS: a full-screen PASS box wins the viewport hit-test and
	# shadows clickable siblings underneath (PASS bubbles to ancestors, never to
	# siblings). IGNORE skips the box itself; its child tiles stay clickable.
	sell_shelves_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(sell_shelves_box)
	sell_patrons_box = Control.new()
	sell_patrons_box.position = Vector2.ZERO
	sell_patrons_box.size = Vector2(720, 1280)
	sell_patrons_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(sell_patrons_box)
	# Counter band sits right under the shelf panel; patrons queue below it.
	var rows: int = int(ceil(float(S.shelf_slots()) / 4.0))
	var panel_h: float = 24.0 + float(rows) * 208.0
	var counter_y: float = 146.0 + panel_h + 14.0
	patrons_y = counter_y + 70.0
	# Thin counter lip under the shelf panel (the big sign moved to the boardwalk).
	var counter := _panel(Rect2(16, counter_y, 688, 26), WOOD, WOOD_DARK, 2, 8)
	ui.add_child(counter)
	# Shop plaque on the boardwalk so the bottom band isn't dead timber.
	var plaque := _panel(Rect2(200, 1112, 320, 54), WOOD, WOOD_DARK, 3, 14)
	ui.add_child(plaque)
	var sign_lbl := _label("· TIDE & TALLY ·", 21, CREAM, HORIZONTAL_ALIGNMENT_CENTER)
	sign_lbl.position = Vector2(200, 1126)
	sign_lbl.size = Vector2(320, 28)
	ui.add_child(sign_lbl)
	_refresh_shelves()
	_refresh_patrons()


func _refresh_shelves() -> void:
	if sell_shelves_box == null:
		return
	for c in sell_shelves_box.get_children():
		c.queue_free()
	shelf_tiles.clear()
	sel_shelf = -1
	var rows: int = int(ceil(float(S.shelf_slots()) / 4.0))
	var panel := _panel(Rect2(16, 146, 688, 24.0 + float(rows) * 208.0), CREAM, WOOD, 4, 18)
	sell_shelves_box.add_child(panel)
	for i in range(S.shelf_slots()):
		var col: int = i % 4
		var row: int = i / 4
		var x: float = 36.0 + float(col) * 166.0
		var y: float = 162.0 + float(row) * 208.0
		# Wood shelf plank under each row of goods.
		if col == 0:
			var plank := _panel(Rect2(28, y + 168, 664, 14), WOOD, WOOD_DARK, 1, 4)
			sell_shelves_box.add_child(plank)
		if i >= S.shelves.size():
			var empty := _panel(Rect2(x, y, 156, 168), Color(SAND.r, SAND.g, SAND.b, 0.4), SAND_DARK, 1, 10)
			sell_shelves_box.add_child(empty)
			shelf_tiles.append(null)
			continue
		var item: String = S.shelves[i]
		var tile := TapBox.new()
		tile.position = Vector2(x, y)
		tile.size = Vector2(156, 168)
		var style := _panel(Rect2(0, 0, 156, 168), SAND, WOOD, 2, 10)
		style.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.add_child(style)
		tile.set_meta("panel", style)
		var icon := IconView.new()
		icon.kind = item
		icon.position = Vector2(38, 18)
		icon.size = Vector2(80, 80)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.add_child(icon)
		var price: int = ItemDB.base_price(item)
		var bonus: bool = S.demand.has(item)
		var ptext: String = "%dg ★" % int(ceil(float(price) * ItemDB.DEMAND_BONUS)) if bonus else "%dg" % price
		var plabel := _label(ptext, 20, CORAL_DARK.darkened(0.12) if bonus else WOOD_DARK, HORIZONTAL_ALIGNMENT_CENTER)
		plabel.position = Vector2(0, 104)
		plabel.size = Vector2(156, 26)
		plabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.add_child(plabel)
		var nlabel := _label(ItemDB.recipe_name(item), 16, INK, HORIZONTAL_ALIGNMENT_CENTER)
		nlabel.position = Vector2(4, 134)
		nlabel.size = Vector2(148, 22)
		nlabel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.add_child(nlabel)
		var s_idx: int = i
		tile.tapped.connect(func() -> void: _on_shelf_tapped(s_idx))
		sell_shelves_box.add_child(tile)
		shelf_tiles.append(tile)


func _refresh_patrons() -> void:
	if sell_patrons_box == null:
		return
	for c in sell_patrons_box.get_children():
		c.queue_free()
	patron_views.clear()
	sel_patron = -1
	for i in range(S.patrons.size()):
		var p: Dictionary = S.patrons[i]
		var want: String = p["want"]
		# Stable per-patron look: assign a skin once on first sight so the same
		# body slides left with its bubble/bar when the queue shifts.
		if not p.has("skin"):
			p["skin"] = patron_skin_next
			patron_skin_next += 1
		var pv := PatronView.new()
		# Slight baseline stagger so the row follows the sand, not a ruler.
		var stag: float = -8.0 + float((int(p["skin"]) % 2)) * 16.0
		pv.position = Vector2(20.0 + float(i) * 172.0, patrons_y + stag)
		pv.size = Vector2(164, 330)
		pv.idx = int(p["skin"])
		pv.pivot_offset = Vector2(82, 300)
		# Want bubble with a tail pointing at its patron.
		var bubble := _panel(Rect2(46, 30, 72, 72), CREAM, INK, 2, 16)
		bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pv.add_child(bubble)
		var tail := Polygon2D.new()
		tail.polygon = PackedVector2Array([Vector2(72, 100), Vector2(92, 100), Vector2(82, 116)])
		tail.color = CREAM
		pv.add_child(tail)
		var icon := IconView.new()
		icon.kind = want
		icon.position = Vector2(58, 42)
		icon.size = Vector2(48, 48)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pv.add_child(icon)
		# Patience bar: dark solid track + border so the gauge reads over any art.
		var bb := _panel(Rect2(18, 2, 128, 20), Color(INK.r, INK.g, INK.b, 0.85), WOOD_DARK, 1, 8)
		pv.add_child(bb)
		var fill := ColorRect.new()
		fill.position = Vector2(22, 6)
		fill.size = Vector2(120, 12)
		fill.color = GREEN
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pv.add_child(fill)
		# Non-colour critical cue, toggled in _update_sell_hud.
		var alert := _label("!", 30, RED, HORIZONTAL_ALIGNMENT_CENTER)
		alert.position = Vector2(118, 24)
		alert.size = Vector2(30, 34)
		alert.visible = false
		pv.add_child(alert)
		var p_idx: int = i
		pv.tapped.connect(func() -> void: _on_patron_tapped(p_idx))
		sell_patrons_box.add_child(pv)
		patron_views.append({"view": pv, "fill": fill, "alert": alert})
		# Arrival pop (squash & stretch).
		pv.scale = Vector2(1.1, 0.7)
		var tw := create_tween()
		tw.tween_property(pv, "scale", Vector2(1, 1), 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _update_sell_hud() -> void:
	if S.phase != ShopState.Phase.SELL:
		return
	if patrons_left_label != null:
		var total_left: int = S.patrons_to_come + S.patrons.size()
		patrons_left_label.text = "Patrons still coming: %d" % total_left
	var mp: float = S.max_patience()
	for i in range(patron_views.size()):
		if i >= S.patrons.size():
			break
		var w: Dictionary = patron_views[i]
		var p: Dictionary = S.patrons[i]
		var left: float = p["patience"]
		var frac: float = clamp(left / mp, 0.0, 1.0)
		var fill: ColorRect = w["fill"]
		# Keep a minimum visible sliver while the patron is still waiting.
		fill.size = Vector2(maxf(120.0 * frac, 4.0 if left > 0.0 else 0.0), 12.0)
		var alert: Label = w["alert"]
		alert.visible = frac < 0.25
		if frac < 0.25:
			# Blink floors at 0.55 alpha — the critical signal never vanishes.
			var blink: float = 0.775 + 0.225 * sin(bg_time * 12.0)
			fill.color = Color(RED.r, RED.g, RED.b, blink)
			alert.modulate.a = blink
		elif frac < 0.55:
			fill.color = GOLD.darkened(0.1)
		else:
			fill.color = GREEN


func _on_patron_tapped(idx: int) -> void:
	if idx < 0 or idx >= patron_views.size():
		return
	sel_patron = idx
	for i in range(patron_views.size()):
		var w: Dictionary = patron_views[i]
		var pv: Control = w["view"]
		pv.set("selected", i == idx)
		pv.queue_redraw()
	_try_serve()


func _on_shelf_tapped(idx: int) -> void:
	sel_shelf = idx
	for i in range(shelf_tiles.size()):
		var t: Variant = shelf_tiles[i]
		if t == null:
			continue
		var tile: Control = t
		var panel: Panel = tile.get_meta("panel")
		var sb: StyleBoxFlat = panel.get_theme_stylebox("panel")
		if i == idx:
			sb.border_color = CORAL
			sb.set_border_width_all(5)
		else:
			sb.border_color = WOOD
			sb.set_border_width_all(2)
	_try_serve()


func _try_serve() -> void:
	if sel_patron < 0 or sel_shelf < 0:
		return
	# Burst at bubble height — the queue shifts left immediately on a sale, so a
	# body-level burst reads as if the NEXT patron paid.
	var ppos := Vector2(102.0 + float(sel_patron) * 172.0, patrons_y + 60.0)
	var events: Array = S.serve(sel_patron, sel_shelf)
	for e in events:
		var ev: Dictionary = e
		var t: String = ev["type"]
		if t == "sale":
			_burst(ppos, GOLD)
			_coin_arc(ppos)
		elif t == "wrong_item":
			if sel_patron < patron_views.size():
				var w: Dictionary = patron_views[sel_patron]
				var pv: Control = w["view"]
				var tw := create_tween()
				tw.tween_property(pv, "position:x", pv.position.x + 10.0, 0.05)
				tw.tween_property(pv, "position:x", pv.position.x - 10.0, 0.05)
				tw.tween_property(pv, "position:x", pv.position.x, 0.05)
	sel_shelf = -1
	_handle_events(events)


# ------------------------------------------------------------ results -----

func _build_results() -> void:
	var panel := _panel(Rect2(28, 96, 664, 988), CREAM, WOOD, 4, 22)
	ui.add_child(panel)
	var title := _label("Day %d complete!" % S.day, 40, SEA_DEEP, HORIZONTAL_ALIGNMENT_CENTER)
	title.position = Vector2(28, 124)
	title.size = Vector2(664, 50)
	ui.add_child(title)
	var sales_word: String = "sale" if S.sales_count == 1 else "sales"
	var line: String = "Earned %dg  ·  %d %s  ·  %d walked out" % [S.day_income, S.sales_count, sales_word, S.walkout_count]
	var income := _label(line, 23, INK, HORIZONTAL_ALIGNMENT_CENTER)
	income.position = Vector2(28, 184)
	income.size = Vector2(664, 30)
	ui.add_child(income)
	# (Gold total lives in the HUD pill right above — stating it twice flattened
	# the header.)
	var up_title := _label("— SPEND YOUR GOLD —", 24, WOOD_DARK, HORIZONTAL_ALIGNMENT_CENTER)
	up_title.position = Vector2(28, 250)
	up_title.size = Vector2(664, 30)
	ui.add_child(up_title)
	var ry: float = 300.0
	var all_tracks: Array = []
	all_tracks.append_array(UpgradeDB.TOOL_TRACKS)
	all_tracks.append_array(UpgradeDB.SHOP_TRACKS)
	for tr_id in all_tracks:
		var track: String = tr_id
		var t: Dictionary = UpgradeDB.track(track)
		var lvl: int = S.upgrades[track]
		var mx: int = t["max"]
		var cost: int = UpgradeDB.cost(track, lvl)
		var row := _panel(Rect2(44, ry, 632, 96), Color(SAND.r, SAND.g, SAND.b, 0.55), SAND_DARK, 1, 12)
		ui.add_child(row)
		var tname: String = t["name"]
		var name_lbl := _label(tname, 23, INK)
		name_lbl.position = Vector2(64, ry + 12)
		name_lbl.size = Vector2(260, 28)
		ui.add_child(name_lbl)
		var tdesc: String = t["desc"]
		var desc_lbl := _label(tdesc, 17, Color(INK.r, INK.g, INK.b, 0.85))
		desc_lbl.position = Vector2(64, ry + 44)
		desc_lbl.size = Vector2(280, 24)
		ui.add_child(desc_lbl)
		# Level pips.
		var pips := PipsView.new()
		pips.filled = lvl
		pips.total = mx
		pips.position = Vector2(64, ry + 70)
		pips.size = Vector2(140, 16)
		ui.add_child(pips)
		if cost < 0:
			var maxed := _label("MAX", 22, SEA_DEEP, HORIZONTAL_ALIGNMENT_CENTER)
			maxed.position = Vector2(520, ry + 32)
			maxed.size = Vector2(130, 30)
			ui.add_child(maxed)
		else:
			var afford: bool = S.gold >= cost
			var buy_btn := _button("%dg" % cost, SEA)
			buy_btn.disabled = not afford
			buy_btn.position = Vector2(520, ry + 18)
			buy_btn.size = Vector2(130, 60)
			buy_btn.pressed.connect(func() -> void: _handle_events(S.buy_upgrade(track)))
			ui.add_child(buy_btn)
		ry += 104.0
	var next_btn := _button("Next Day →", CORAL)
	next_btn.position = Vector2(140, 1124)
	next_btn.size = Vector2(440, 96)
	next_btn.pressed.connect(func() -> void: _handle_events(S.next_day()))
	ui.add_child(next_btn)


func _build_day_failed() -> void:
	var panel := _panel(Rect2(60, 440, 600, 240), CREAM, RED, 4, 22)
	ui.add_child(panel)
	var title := _label("Nothing to sell!", 40, RED, HORIZONTAL_ALIGNMENT_CENTER)
	title.position = Vector2(60, 482)
	title.size = Vector2(600, 50)
	ui.add_child(title)
	var sub := _label("The shop stayed dark today.\nComb the beach and craft something first.", 22, INK, HORIZONTAL_ALIGNMENT_CENTER)
	sub.position = Vector2(80, 552)
	sub.size = Vector2(560, 80)
	ui.add_child(sub)
	# CTA lives on the boardwalk like every other phase.
	var retry_btn := _button("Comb the Beach Again", CORAL)
	retry_btn.position = Vector2(140, 1124)
	retry_btn.size = Vector2(440, 96)
	retry_btn.pressed.connect(func() -> void: _handle_events(S.restart_day()))
	ui.add_child(retry_btn)


# ================================================================= juice ====

func _shake(dur: float, mag: float) -> void:
	shake_t = dur
	shake_dur = dur
	shake_mag = mag


func _update_shake(delta: float) -> void:
	if shake_t <= 0.0:
		position = Vector2.ZERO
		return
	shake_t -= delta
	var k: float = clamp(shake_t / shake_dur, 0.0, 1.0)
	position = Vector2(vfx_rng.randf_range(-1.0, 1.0), vfx_rng.randf_range(-1.0, 1.0)) * shake_mag * k


func _pulse(node: Control, peak: float) -> void:
	var tw := create_tween()
	tw.tween_property(node, "scale", Vector2(peak, peak), 0.08).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "scale", Vector2(1, 1), 0.16).set_ease(Tween.EASE_IN)


func _toast(text: String, color: Color) -> void:
	# Darken light accents so every toast reads on the cream pill.
	var ink: Color = color.darkened(0.22)
	var l := _label(text, 28, ink, HORIZONTAL_ALIGNMENT_CENTER)
	l.position = Vector2(0, 1090.0 - float(toast_slot % 3) * 44.0)
	l.size = Vector2(720, 40)
	toast_slot += 1
	# Solid cream pill with the standard wood border so toasts read over any art.
	var back := _panel(Rect2(110, -4, 500, 48), Color(CREAM.r, CREAM.g, CREAM.b, 0.96), WOOD, 3, 22)
	back.show_behind_parent = true
	l.add_child(back)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "position:y", l.position.y - 56.0, 1.1).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(l, "modulate:a", 0.0, 1.1).set_ease(Tween.EASE_IN)
	tw.tween_callback(l.queue_free)


func _burst(pos: Vector2, color: Color) -> void:
	for i in range(10):
		var d := Polygon2D.new()
		var sz: float = vfx_rng.randf_range(5.0, 10.0)
		d.polygon = PackedVector2Array([Vector2(0, -sz), Vector2(sz, 0), Vector2(0, sz), Vector2(-sz, 0)])
		d.color = color
		d.position = pos
		ui.add_child(d)
		var ang: float = vfx_rng.randf_range(0.0, TAU)
		var dist: float = vfx_rng.randf_range(40.0, 110.0)
		var target: Vector2 = pos + Vector2(cos(ang), sin(ang)) * dist
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(d, "position", target, 0.45).set_ease(Tween.EASE_OUT)
		tw.tween_property(d, "scale", Vector2(0.1, 0.1), 0.45).set_ease(Tween.EASE_IN)
		tw.chain().tween_callback(d.queue_free)


func _coin_arc(from_pos: Vector2) -> void:
	# A coin flies from the sale up to the HUD gold counter.
	var coin := _coin(from_pos, 12.0)
	ui.add_child(coin)
	var tw := create_tween()
	tw.tween_property(coin, "position", Vector2(580, 42), 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(coin.queue_free)


func _froth_sweep() -> void:
	var froth := ColorRect.new()
	froth.color = Color(1, 1, 1, 0.75)
	froth.position = Vector2(0, 320)
	froth.size = Vector2(720, 200)
	froth.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(froth)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(froth, "position:y", 900.0, 0.55).set_ease(Tween.EASE_OUT)
	tw.tween_property(froth, "modulate:a", 0.0, 0.6).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(froth.queue_free)


# =============================================================== helpers ====

func _dict_total(d: Dictionary) -> int:
	var n: int = 0
	for k in d.keys():
		var c: int = d[k]
		n += c
	return n


func _panel(rect: Rect2, bg: Color, border: Color, bw: int, radius: int) -> Panel:
	var p := Panel.new()
	p.position = rect.position
	p.size = rect.size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	p.add_theme_stylebox_override("panel", sb)
	return p


func _label(text: String, font_size: int, color: Color, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align as HorizontalAlignment
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(text: String, bg: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_color_override("font_color", CREAM)
	b.add_theme_color_override("font_pressed_color", CREAM)
	b.add_theme_color_override("font_hover_color", CREAM)
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = bg.darkened(0.35)
	sb.set_border_width_all(3)
	sb.border_width_bottom = 7
	sb.set_corner_radius_all(16)
	b.add_theme_stylebox_override("normal", sb)
	var sbp: StyleBoxFlat = sb.duplicate()
	sbp.bg_color = bg.darkened(0.15)
	sbp.border_width_bottom = 3
	b.add_theme_stylebox_override("pressed", sbp)
	b.add_theme_stylebox_override("hover", sb)
	var sbd: StyleBoxFlat = sb.duplicate()
	sbd.bg_color = SAND_DARK
	sbd.border_color = SAND_DARK.darkened(0.25)
	sbd.border_width_bottom = 3
	b.add_theme_stylebox_override("disabled", sbd)
	b.add_theme_color_override("font_disabled_color", WOOD_DARK)
	return b


func _coin(pos: Vector2, r: float) -> Control:
	var c := CoinView.new()
	c.radius = r
	c.position = pos - Vector2(r, r)
	c.size = Vector2(r * 2.0, r * 2.0)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


# ========================================================= inner classes ====

class TapBox extends Control:
	signal tapped
	var selected: bool = false

	func _gui_input(event: InputEvent) -> void:
		var hit: bool = false
		if event is InputEventScreenTouch and event.pressed:
			hit = true
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			hit = true
		if hit:
			accept_event()
			tapped.emit()


class CoinView extends Control:
	const TEX_COIN := preload("res://art/coin.png")
	var radius: float = 12.0

	func _draw() -> void:
		var ts: Vector2 = TEX_COIN.get_size()
		var k: float = minf(size.x / ts.x, size.y / ts.y)
		var ds: Vector2 = ts * k
		draw_texture_rect(TEX_COIN, Rect2((size - ds) * 0.5, ds), false)


class PipsView extends Control:
	var filled: int = 0
	var total: int = 4

	func _draw() -> void:
		for i in range(total):
			var c := Vector2(10.0 + float(i) * 26.0, 8.0)
			if i < filled:
				draw_circle(c, 9.0, Color("#1d7d7c"))
				draw_circle(c, 7.5, Color("#2fa6a0"))
				draw_circle(c - Vector2(2.2, 2.6), 2.4, Color(1, 1, 1, 0.7))
			else:
				draw_circle(c, 9.0, Color("#8a5a3b", 0.45))
				draw_circle(c, 7.5, Color("#f2e3c2", 0.55))
				draw_arc(c + Vector2(0, 1.5), 5.0, 0.3, PI - 0.3, 10, Color("#8a5a3b", 0.30), 2.0)


class NodeBlob extends Control:
	const TEX_POOL := preload("res://art/gather_node_pool.png")
	const TEX_POOL_FAR := preload("res://art/gather_node_pool_far.png")
	var res: String = "shell"
	var far: bool = false

	func _draw() -> void:
		var c := Vector2(44, 44)
		# Painted tide pool, gently squashed for perspective.
		var pool: Texture2D = TEX_POOL_FAR if far else TEX_POOL
		draw_texture_rect(pool, Rect2(0, 20, 88, 66), false)
		# Soft white sparkle behind the goodie (the old coloured halo read as a
		# flat smudge over the painted pool).
		draw_circle(c - Vector2(0, 4), 24.0, Color(1, 1, 1, 0.30))


class PatronView extends Control:
	const TEXES: Array = [
		preload("res://art/patron_a.png"),
		preload("res://art/patron_b.png"),
		preload("res://art/patron_c.png"),
		preload("res://art/patron_d.png"),
	]
	signal tapped
	var selected: bool = false
	var idx: int = 0

	func _gui_input(event: InputEvent) -> void:
		var hit: bool = false
		if event is InputEventScreenTouch and event.pressed:
			hit = true
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			hit = true
		if hit:
			accept_event()
			tapped.emit()

	func _draw() -> void:
		# Feet shadow.
		draw_set_transform(Vector2(82, 296), 0.0, Vector2(1.0, 0.3))
		draw_circle(Vector2.ZERO, 44.0, Color(0, 0, 0, 0.15))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# Painted villager, contain-fit in the body zone under the want bubble.
		var t: Texture2D = TEXES[idx % TEXES.size()]
		var zone := Rect2(10, 108, 144, 190)
		var ts: Vector2 = t.get_size()
		var k: float = minf(zone.size.x / ts.x, zone.size.y / ts.y)
		var ds: Vector2 = ts * k
		var dpos := Vector2(zone.position.x + (zone.size.x - ds.x) * 0.5, zone.end.y - ds.y)
		if selected:
			# Coral highlight ring at the feet + soft glow behind the body.
			draw_set_transform(Vector2(82, 296), 0.0, Vector2(1.0, 0.3))
			draw_arc(Vector2.ZERO, 52.0, 0.0, TAU, 32, Color("#ff7b54"), 6.0)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			draw_texture_rect(t, Rect2(dpos - ds * 0.04, ds * 1.08), false, Color(1.0, 0.55, 0.35, 0.55))
		draw_texture_rect(t, Rect2(dpos, ds), false)


class IconView extends Control:
	# Raster item icons (asset pass). The pearl token is cropped from the
	# painted pearl_ring art (a standalone pearl fought diffusion 4x).
	const TEXES: Dictionary = {
		"pearl": preload("res://art/icon_pearl.png"),
		"shell": preload("res://art/icon_shell.png"),
		"driftwood": preload("res://art/icon_driftwood.png"),
		"seaglass": preload("res://art/icon_seaglass.png"),
		"shell_charm": preload("res://art/icon_shell_charm.png"),
		"driftwood_frame": preload("res://art/icon_driftwood_frame.png"),
		"seaglass_pendant": preload("res://art/icon_seaglass_pendant.png"),
		"wind_chime": preload("res://art/icon_wind_chime.png"),
		"pearl_ring": preload("res://art/icon_pearl_ring.png"),
		"tide_lantern": preload("res://art/icon_tide_lantern.png"),
	}
	var kind: String = "shell"

	func _draw() -> void:
		var s: float = minf(size.x, size.y)
		var c: Vector2 = size * 0.5
		if TEXES.has(kind):
			var t: Texture2D = TEXES[kind]
			var ts: Vector2 = t.get_size()
			var k: float = minf(size.x / ts.x, size.y / ts.y)
			var ds: Vector2 = ts * k
			draw_texture_rect(t, Rect2((size - ds) * 0.5, ds), false)
		else:
			draw_circle(c, s * 0.3, Color("#ff7b54"))
