extends Node2D

# CombatView — pure visual renderer for the deckbuilder.
# Owns NO rules. Reads state from CombatState (passed via refresh()) and draws it.
# Immediate-mode: call queue_redraw() to repaint; _draw() does everything.
#
# Layout (1280×720 landscape):
#   Background: indigo→violet gradient fill + runic circle + motes
#   Enemy:      center-right, polygon silhouette, HP bar, intent, statuses
#   Hand:       fanned cards along the bottom
#   Player HUD: bottom-left (HP, mana, block)
#   Pile counts: draw=bottom-left-corner, discard=bottom-right-corner
#   End Turn:   bottom-right button rect
#   Reward:     centered overlay (3 card faces + Skip)
#   Win/Lose:   centered overlay
#
# Juice (Task 15):
#   animate_play_card() — card arc/flash → damage/block pop-ups → shake
#   animate_events()    — end-turn event chain (enemy attack flash, burn tick pop-ups)
#   animate_enemy_death() — dissolve + particle burst before win/reward
#   Screen shake        — decaying random offset in _process(), scaled to damage
#   HP/mana tweens      — displayed values lerp toward real values
#   Status pulses       — scale-pop when a status stack is added
#   Intent telegraph    — fade/slide in at start of enemy turn

const CardDB := preload("res://data/CardDB.gd")

# State enum values (mirrored from Main.gd — passed in via refresh)
const STATE_COMBAT  := 0
const STATE_REWARD  := 1
const STATE_REST    := 2
const STATE_WIN     := 3
const STATE_LOSE    := 4

# Viewport
const W: float = 1280.0
const H: float = 720.0

# Element colours
const COL_FIRE      := Color(1.00, 0.65, 0.10)   # amber
const COL_ICE       := Color(0.30, 0.90, 1.00)   # cyan
const COL_LIGHTNING := Color(0.80, 0.50, 1.00)   # violet-yellow
const COL_NEUTRAL   := Color(0.70, 0.70, 0.75)   # grey

# Background palette
const COL_BG_TOP    := Color(0.102, 0.063, 0.188)  # #1a1030 indigo
const COL_BG_BOT    := Color(0.176, 0.106, 0.306)  # #2d1b4e violet

# UI colours
const COL_PANEL     := Color(0.08, 0.06, 0.14, 0.88)
const COL_CARD_BG   := Color(0.12, 0.09, 0.20, 0.95)
const COL_HP_BAR    := Color(0.20, 0.78, 0.35)
const COL_HP_BG     := Color(0.15, 0.15, 0.15)
const COL_MANA      := Color(0.30, 0.55, 1.00)
const COL_BLOCK     := Color(0.60, 0.75, 1.00)
const COL_END_BTN   := Color(0.65, 0.25, 0.90)
const COL_END_HOVER := Color(0.80, 0.40, 1.00)
const COL_SKIP_BTN  := Color(0.35, 0.35, 0.50)
const COL_WHITE     := Color(1, 1, 1)
const COL_BLACK     := Color(0, 0, 0)
const COL_SELECTED  := Color(1.00, 0.90, 0.20)

# Card geometry
const CARD_W: float = 120.0
const CARD_H: float = 160.0
const CARD_HAND_Y: float = 630.0   # center-y of cards in hand
const CARD_SPACING: float = 130.0

# Enemy silhouette anchor
const ENEMY_X: float = 880.0
const ENEMY_Y: float = 340.0

# End Turn button rect
const END_BTN_RECT := Rect2(1080.0, 630.0, 160.0, 50.0)

# Selected card index (for highlight) — set by Main
var selected_card_idx: int = -1

# Current snapshot — set by refresh()
var _combat   # CombatState or null
var _state: int = STATE_COMBAT
var _rewards: Array = []
var _enemy_max_hp: int = 0   # captured once at combat start (enemy may lack max_hp)

# Font reference — Node2D doesn't carry a default font; we use draw_string with null
# which falls back to the project default font in Godot 4. Works headless too.
var _default_font: Font = null

# Mote seed positions (decorative — fixed so they don't jitter each frame)
var _motes: Array = []

# ─── Juice state ──────────────────────────────────────────────────────────────

# Screen shake: decaying random offset applied to this node's position
var _shake_magnitude: float = 0.0
var _shake_offset: Vector2 = Vector2.ZERO
const SHAKE_DECAY: float = 8.0   # per-second exponential decay

# Enemy hit-flash: white modulate overlay, fades over time
var _enemy_flash: float = 0.0   # 0..1, strength of white flash
const FLASH_DECAY: float = 5.0

# Tweened display values (animated toward real values)
var _disp_player_hp: float = -1.0    # -1 = not yet initialised
var _disp_player_block: float = 0.0
var _disp_enemy_hp: float = -1.0
const TWEEN_SPEED: float = 6.0   # lerp speed multiplier (per second)

# Status pulse: Dictionary { "burn": float(0..1), "chill": float(0..1) }
# Each channel decays — drawn as a scale-pop on the status icon
var _status_pulse: Dictionary = {"burn": 0.0, "chill": 0.0}
const PULSE_DECAY: float = 6.0

# Intent telegraph: 0..1 fade-in value (reset to 0 at start of each enemy turn)
var _intent_alpha: float = 1.0   # 1 = fully visible; new telegraph animates from 0→1
var _intent_animating: bool = false

# Enemy death dissolve: 0..1 (0=alive, 1=fully dissolved)
var _death_dissolve: float = 0.0
var _death_active: bool = false

# Death particles: array of { pos, vel, color, life, max_life }
var _death_particles: Array = []

# Card cast ghost: transient arc animation driven purely by _process
var _cast_ghost_active: bool = false
var _cast_ghost_pos: Vector2 = Vector2.ZERO
var _cast_ghost_target: Vector2 = Vector2(ENEMY_X, ENEMY_Y)
var _cast_ghost_start: Vector2 = Vector2.ZERO
var _cast_ghost_alpha: float = 0.0
var _cast_ghost_t: float = 0.0        # 0..1 normalised progress
const CAST_GHOST_DURATION: float = 0.22

# Accumulated delta for _process-driven timers
var _delta_acc: float = 0.0


func _ready() -> void:
	# Pre-generate mote positions (deterministic, not random per-frame)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xABC123
	for i in 24:
		_motes.append(Vector2(rng.randf_range(40.0, W - 40.0), rng.randf_range(40.0, H * 0.75)))


# ─── Public API ───────────────────────────────────────────────────────────────

func refresh(combat, state: int, rewards: Array) -> void:
	var prev_combat = _combat
	_combat = combat
	_state = state
	_rewards = rewards
	if combat != null and _enemy_max_hp == 0:
		_enemy_max_hp = combat.enemy.get("hp", 1)

	# Initialise tweened display values on first combat (or restart)
	if combat != null and _disp_player_hp < 0.0:
		_disp_player_hp = float(combat.player_hp)
		_disp_player_block = float(combat.player_block)
		_disp_enemy_hp = float(combat.enemy.get("hp", 0))

	# Reset juice on restart (prev_combat null → fresh run)
	if prev_combat == null and combat != null:
		_reset_juice()

	queue_redraw()


func capture_enemy_max_hp(hp: int) -> void:
	_enemy_max_hp = hp


func get_end_turn_rect() -> Rect2:
	return END_BTN_RECT


func get_card_rect(idx: int, total: int) -> Rect2:
	var start_x: float = _hand_start_x(total)
	var cx: float = start_x + idx * CARD_SPACING
	return Rect2(cx - CARD_W * 0.5, CARD_HAND_Y - CARD_H * 0.5, CARD_W, CARD_H)


func get_reward_card_rect(idx: int) -> Rect2:
	var rw: float = 140.0
	var rh: float = 190.0
	var total_w: float = 3.0 * rw + 2.0 * 20.0
	var sx: float = (W - total_w) * 0.5
	return Rect2(sx + idx * (rw + 20.0), H * 0.5 - rh * 0.5 - 20.0, rw, rh)


func get_skip_rect() -> Rect2:
	return Rect2(W * 0.5 - 80.0, H * 0.5 + 120.0, 160.0, 44.0)


# ─── Juice: animate a card-play event chain ───────────────────────────────────
# Called from Main BEFORE refresh(), so we still have the old hand state.

func animate_play_card(card_rect: Rect2, events: Array, done_cb: Callable) -> void:
	# 1. Fire the card arc ghost
	_cast_ghost_start = card_rect.get_center()
	_cast_ghost_pos = _cast_ghost_start
	_cast_ghost_target = Vector2(ENEMY_X, ENEMY_Y)
	_cast_ghost_alpha = 1.0
	_cast_ghost_t = 0.0
	_cast_ghost_active = true

	# 2. After arc lands (CAST_GHOST_DURATION), show pop-ups + shake
	var t := create_tween()
	t.tween_interval(CAST_GHOST_DURATION)
	t.tween_callback(func():
		_process_events(events)
		# Pop-ups need a small window to be visible, then call done
		var t2 := create_tween()
		t2.tween_interval(0.35)
		t2.tween_callback(done_cb)
	)


func animate_events(events: Array, done_cb: Callable) -> void:
	# End-turn: telegraph intent, then process events
	_trigger_intent_telegraph()
	var t := create_tween()
	t.tween_interval(0.30)
	t.tween_callback(func():
		_process_events(events)
		var t2 := create_tween()
		t2.tween_interval(0.40)
		t2.tween_callback(done_cb)
	)


func animate_enemy_death(done_cb: Callable) -> void:
	_death_active = true
	_death_dissolve = 0.0
	_spawn_death_particles()

	var t := create_tween()
	# Dissolve over 0.55s
	t.tween_method(func(v: float): _death_dissolve = v; queue_redraw(), 0.0, 1.0, 0.55)
	t.tween_callback(func():
		_death_active = false
		_death_dissolve = 0.0
		_death_particles = []
		done_cb.call()
	)


# ─── Juice internal helpers ───────────────────────────────────────────────────

func _reset_juice() -> void:
	_shake_magnitude = 0.0
	_shake_offset = Vector2.ZERO
	_enemy_flash = 0.0
	_disp_player_hp = -1.0
	_disp_player_block = 0.0
	_disp_enemy_hp = -1.0
	_status_pulse = {"burn": 0.0, "chill": 0.0}
	_intent_alpha = 1.0
	_intent_animating = false
	_death_active = false
	_death_dissolve = 0.0
	_death_particles = []
	_cast_ghost_active = false
	position = Vector2.ZERO


func _process_events(events: Array) -> void:
	for ev in events:
		var etype: String = ev.get("type", "")
		match etype:
			"damage":
				var amt: int = ev.get("amount", 0)
				_trigger_enemy_hit(amt)
				_spawn_pop_up(Vector2(ENEMY_X + randf_range(-20.0, 20.0), ENEMY_Y - 90.0),
					"-%d" % amt, Color(1.0, 0.35, 0.20))
			"block":
				var amt: int = ev.get("amount", 0)
				_spawn_pop_up(Vector2(120.0, 555.0 + randf_range(-10.0, 10.0)),
					"+%d BLK" % amt, COL_BLOCK)
			"status":
				var stat: String = ev.get("status", "")
				var amt: int = ev.get("amount", 0)
				if stat == "burn":
					_status_pulse["burn"] = 1.0
					_spawn_pop_up(Vector2(ENEMY_X - 20.0, ENEMY_Y + 100.0),
						"Burn +%d" % amt, COL_FIRE)
				elif stat == "chill":
					_status_pulse["chill"] = 1.0
					_spawn_pop_up(Vector2(ENEMY_X + 20.0, ENEMY_Y + 100.0),
						"Chill +%d" % amt, COL_ICE)
			"burn_tick":
				var amt: int = ev.get("amount", 0)
				_trigger_enemy_hit(int(float(amt) * 0.5))  # softer shake for DoT
				_spawn_pop_up(Vector2(ENEMY_X + randf_range(-15.0, 15.0), ENEMY_Y - 70.0),
					"~%d" % amt, COL_FIRE)
			"enemy_attack":
				var dealt: int = ev.get("damage_dealt", 0)
				if dealt > 0:
					# Flash the player HUD area
					_spawn_pop_up(Vector2(120.0, 570.0),
						"-%d HP" % dealt, Color(1.0, 0.3, 0.3))
			"enemy_defend":
				var amt: int = ev.get("amount", 0)
				_spawn_pop_up(Vector2(ENEMY_X, ENEMY_Y + 110.0),
					"+%d DEF" % amt, COL_BLOCK)
			"chilled_skip":
				_spawn_pop_up(Vector2(ENEMY_X, ENEMY_Y - 100.0),
					"FROZEN!", COL_ICE)


func _trigger_enemy_hit(magnitude: int) -> void:
	# Shake: clamp to max 20px for very high damage
	_shake_magnitude = clamp(float(magnitude) * 0.8, 2.0, 20.0)
	# Hit-flash
	_enemy_flash = 1.0
	queue_redraw()


func _trigger_intent_telegraph() -> void:
	# Slide intent in from 0→1 alpha
	_intent_alpha = 0.0
	_intent_animating = true
	var t := create_tween()
	t.tween_method(func(v: float): _intent_alpha = v; queue_redraw(), 0.0, 1.0, 0.25)
	t.tween_callback(func(): _intent_animating = false)


func _spawn_pop_up(pos: Vector2, text: String, col: Color) -> void:
	# Pop-ups are Label nodes that tween upward + fade, then free themselves.
	# Guard: ThemeDB.fallback_font must exist (always true in Godot 4, headless too).
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.position = pos
	add_child(lbl)

	var t := create_tween()
	# Rise 55px over 0.55s, while fading to transparent
	t.set_parallel(true)
	t.tween_property(lbl, "position:y", pos.y - 55.0, 0.55)
	t.tween_property(lbl, "modulate:a", 0.0, 0.55)
	t.set_parallel(false)
	t.tween_callback(lbl.queue_free)


func _spawn_death_particles() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xDEAD
	_death_particles = []
	var colors: Array = [
		Color(0.8, 0.4, 1.0), Color(1.0, 0.6, 0.2), Color(0.4, 0.8, 1.0),
		Color(1.0, 1.0, 0.5), Color(0.6, 0.3, 1.0)
	]
	for i in 24:
		var angle: float = rng.randf() * TAU
		var speed: float = rng.randf_range(40.0, 140.0)
		_death_particles.append({
			"pos": Vector2(ENEMY_X, ENEMY_Y),
			"vel": Vector2(cos(angle), sin(angle)) * speed,
			"color": colors[i % colors.size()],
			"life": 0.0,
			"max_life": rng.randf_range(0.4, 0.7)
		})


# ─── _process: per-frame decay for shake, flash, tweens ──────────────────────

func _process(delta: float) -> void:
	var dirty: bool = false

	# Shake decay
	if _shake_magnitude > 0.01:
		_shake_magnitude = move_toward(_shake_magnitude, 0.0, _shake_magnitude * SHAKE_DECAY * delta)
		var rng := RandomNumberGenerator.new()
		rng.seed = Time.get_ticks_msec()
		_shake_offset = Vector2(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)
		) * _shake_magnitude
		position = _shake_offset
		dirty = true
	elif position != Vector2.ZERO:
		position = Vector2.ZERO
		dirty = true

	# Enemy hit-flash decay
	if _enemy_flash > 0.001:
		_enemy_flash = move_toward(_enemy_flash, 0.0, _enemy_flash * FLASH_DECAY * delta)
		dirty = true

	# HP/mana display tween (lerp displayed values toward real values)
	if _combat != null:
		var real_php: float = float(_combat.player_hp)
		var real_blk: float = float(_combat.player_block)
		var real_ehp: float = float(_combat.enemy.get("hp", 0))

		if _disp_player_hp < 0.0:
			_disp_player_hp = real_php
		if abs(_disp_player_hp - real_php) > 0.5:
			_disp_player_hp = lerp(_disp_player_hp, real_php, TWEEN_SPEED * delta)
			dirty = true
		else:
			_disp_player_hp = real_php

		if abs(_disp_player_block - real_blk) > 0.5:
			_disp_player_block = lerp(_disp_player_block, real_blk, TWEEN_SPEED * delta)
			dirty = true
		else:
			_disp_player_block = real_blk

		if _disp_enemy_hp < 0.0:
			_disp_enemy_hp = real_ehp
		if abs(_disp_enemy_hp - real_ehp) > 0.5:
			_disp_enemy_hp = lerp(_disp_enemy_hp, real_ehp, TWEEN_SPEED * delta)
			dirty = true
		else:
			_disp_enemy_hp = real_ehp

	# Status pulse decay
	for key in _status_pulse.keys():
		if _status_pulse[key] > 0.001:
			_status_pulse[key] = move_toward(_status_pulse[key], 0.0,
				_status_pulse[key] * PULSE_DECAY * delta)
			dirty = true

	# Cast ghost arc
	if _cast_ghost_active:
		_cast_ghost_t += delta / CAST_GHOST_DURATION
		if _cast_ghost_t >= 1.0:
			_cast_ghost_t = 1.0
			_cast_ghost_active = false
		# Parabolic arc: lerp pos + arc up in y
		var p := _cast_ghost_t
		_cast_ghost_pos = _cast_ghost_start.lerp(_cast_ghost_target, p)
		# Arc lift: sin(p*PI)*-80 (peaks at midpoint)
		_cast_ghost_pos.y += sin(p * PI) * -80.0
		_cast_ghost_alpha = 1.0 - p
		dirty = true

	# Death particles
	if _death_active and not _death_particles.is_empty():
		for particle in _death_particles:
			particle["life"] += delta
			particle["pos"] += particle["vel"] * delta
			particle["vel"] = particle["vel"] * (1.0 - 2.0 * delta)  # drag
		dirty = true

	if dirty:
		queue_redraw()


# ─── _draw ────────────────────────────────────────────────────────────────────

func _draw() -> void:
	# Guard: in headless mode CanvasItem draw calls still work but some GPU paths
	# may be skipped. We simply proceed — all primitives used here (draw_rect,
	# draw_circle, draw_polyline, draw_string) are safe headless.
	_draw_background()

	if _state == STATE_WIN:
		_draw_overlay_message("✦ VICTORY ✦", "Tap / click to play again", Color(0.90, 0.80, 0.20))
		return
	if _state == STATE_LOSE:
		_draw_overlay_message("✦ DEFEAT ✦", "Tap / click to play again", Color(0.85, 0.25, 0.25))
		return

	if _combat == null:
		return

	_draw_enemy()
	_draw_death_particles()
	_draw_player_hud()
	_draw_hand()
	_draw_cast_ghost()
	_draw_pile_counts()
	_draw_end_turn_button()

	if _state == STATE_REWARD:
		_draw_reward_overlay()


# ─── Background ───────────────────────────────────────────────────────────────

func _draw_background() -> void:
	# Vertical gradient: draw horizontal bands from top (indigo) to bottom (violet)
	var bands: int = 16
	for i in bands:
		var t0: float = float(i) / float(bands)
		var t1: float = float(i + 1) / float(bands)
		var c0: Color = COL_BG_TOP.lerp(COL_BG_BOT, t0)
		var c1: Color = COL_BG_TOP.lerp(COL_BG_BOT, t1)
		# approximate with midpoint colour
		var c: Color = c0.lerp(c1, 0.5)
		var y0: float = t0 * H
		var y1: float = t1 * H
		draw_rect(Rect2(0.0, y0, W, y1 - y0), c)

	# Faint runic circle on the "floor" (bottom center)
	var center := Vector2(W * 0.5, H * 0.88)
	draw_arc(center, 180.0, 0.0, TAU, 64, Color(0.60, 0.40, 1.00, 0.08), 2.0)
	draw_arc(center, 140.0, 0.0, TAU, 64, Color(0.60, 0.40, 1.00, 0.05), 1.5)
	# Cross lines inside the circle (runic feel)
	draw_line(center + Vector2(-140.0, 0.0), center + Vector2(140.0, 0.0), Color(0.60, 0.40, 1.00, 0.04), 1.0)
	draw_line(center + Vector2(0.0, -140.0), center + Vector2(0.0, 140.0), Color(0.60, 0.40, 1.00, 0.04), 1.0)

	# Floating motes
	for mv in _motes:
		var pos: Vector2 = mv
		draw_circle(pos, 1.8, Color(0.80, 0.70, 1.00, 0.18))

	# Subtle glow halo in center-right (enemy area)
	var halo_c := Color(0.60, 0.20, 1.00, 0.07)
	draw_circle(Vector2(ENEMY_X, ENEMY_Y), 160.0, halo_c)
	draw_circle(Vector2(ENEMY_X, ENEMY_Y), 100.0, Color(0.60, 0.20, 1.00, 0.04))


# ─── Enemy ────────────────────────────────────────────────────────────────────

func _draw_enemy() -> void:
	if _combat == null:
		return
	var en: Dictionary = _combat.enemy
	var e_name: String = en.get("name", "???")
	var e_hp: int = en.get("hp", 0)
	var e_block: int = en.get("block", 0)
	var e_max_hp: int = _enemy_max_hp if _enemy_max_hp > 0 else e_hp

	# Death dissolve: fade out the entire enemy silhouette
	var dissolve_alpha: float = 1.0 - _death_dissolve
	if dissolve_alpha <= 0.001:
		return

	# Silhouette — a simple imp/demon shape using polylines
	# Body: slightly organic blob (octagon-ish polygon)
	var body_pts: PackedVector2Array = PackedVector2Array([
		Vector2(ENEMY_X - 30, ENEMY_Y + 80),   # bottom-left
		Vector2(ENEMY_X - 50, ENEMY_Y + 20),
		Vector2(ENEMY_X - 45, ENEMY_Y - 40),
		Vector2(ENEMY_X - 20, ENEMY_Y - 80),
		Vector2(ENEMY_X + 20, ENEMY_Y - 80),
		Vector2(ENEMY_X + 45, ENEMY_Y - 40),
		Vector2(ENEMY_X + 50, ENEMY_Y + 20),
		Vector2(ENEMY_X + 30, ENEMY_Y + 80),
	])

	# Hit-flash: overlay white on top of silhouette to simulate flash
	var flash: float = _enemy_flash
	var base_col := Color(0.22, 0.15, 0.38, dissolve_alpha)
	var glow_col := Color(0.70, 0.30, 1.00, 0.22 * dissolve_alpha)
	var fill_col := base_col.lerp(Color(1.0, 1.0, 1.0, dissolve_alpha), flash)
	var outline_col := Color(0.75, 0.50, 1.00, 0.85 * dissolve_alpha)

	# Glow halo behind silhouette
	draw_colored_polygon(body_pts, glow_col)
	# Fill with the actual silhouette colour (white-flashed)
	draw_colored_polygon(body_pts, fill_col)
	# Outline
	draw_polyline(body_pts, outline_col, 2.0, true)

	# Glowing eyes — dim during dissolve
	var eye_alpha: float = dissolve_alpha
	var eye_y: float = ENEMY_Y - 55.0
	draw_circle(Vector2(ENEMY_X - 12, eye_y), 6.0, Color(1.0, 0.3, 0.1, 0.35 * eye_alpha))
	draw_circle(Vector2(ENEMY_X - 12, eye_y), 4.0, Color(1.0, 0.5, 0.2, eye_alpha))
	draw_circle(Vector2(ENEMY_X + 12, eye_y), 6.0, Color(1.0, 0.3, 0.1, 0.35 * eye_alpha))
	draw_circle(Vector2(ENEMY_X + 12, eye_y), 4.0, Color(1.0, 0.5, 0.2, eye_alpha))

	# Block badge (if any)
	if e_block > 0:
		_draw_badge(Vector2(ENEMY_X + 55, ENEMY_Y + 40), str(e_block),
			Color(COL_BLOCK.r, COL_BLOCK.g, COL_BLOCK.b, dissolve_alpha))

	# HP bar above enemy — uses tweened display value
	var bar_w: float = 120.0
	var bar_h: float = 12.0
	var bar_x: float = ENEMY_X - bar_w * 0.5
	var bar_y: float = ENEMY_Y - 105.0
	draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(COL_HP_BG.r, COL_HP_BG.g, COL_HP_BG.b, dissolve_alpha))
	var disp_hp: float = _disp_enemy_hp if _disp_enemy_hp >= 0.0 else float(e_hp)
	var hp_frac: float = clamp(disp_hp / float(e_max_hp), 0.0, 1.0)
	draw_rect(Rect2(bar_x, bar_y, bar_w * hp_frac, bar_h),
		Color(COL_HP_BAR.r, COL_HP_BAR.g, COL_HP_BAR.b, dissolve_alpha))
	draw_rect(Rect2(bar_x, bar_y, bar_w, bar_h), Color(0.5, 0.5, 0.5, 0.6 * dissolve_alpha), false)
	_draw_text_alpha(Vector2(ENEMY_X, bar_y - 2.0), "%s  %d/%d" % [e_name, e_hp, e_max_hp],
		14, COL_WHITE, true, dissolve_alpha)

	# Intent above HP bar — with telegraph alpha
	var intent_a: float = _intent_alpha * dissolve_alpha
	var intent: Dictionary = en.get("intent", {})
	var intent_type: String = intent.get("type", "")
	var intent_val: int = intent.get("value", 0)
	var intent_str: String = ""
	var intent_col: Color = COL_WHITE
	match intent_type:
		"attack":
			intent_str = "ATK %d" % intent_val
			intent_col = Color(1.00, 0.45, 0.35)
		"defend":
			intent_str = "DEF %d" % intent_val
			intent_col = Color(0.45, 0.80, 1.00)
		"enrage":
			intent_str = "ENRAGE"
			intent_col = Color(1.00, 0.70, 0.10)
		_:
			intent_str = "?"
	# Slide in from 6px above when animating
	var intent_y_off: float = (1.0 - _intent_alpha) * -6.0
	_draw_text_alpha(Vector2(ENEMY_X, bar_y - 22.0 + intent_y_off),
		intent_str, 15, intent_col, true, intent_a)

	# Status icons with pulse scale-pop
	var statuses: Dictionary = en.get("statuses", {})
	var burn_n: int = statuses.get("burn", 0)
	var chill_n: int = statuses.get("chill", 0)
	var sx: float = ENEMY_X - 35.0
	var sy: float = ENEMY_Y + 92.0
	if burn_n > 0:
		var pulse_s: float = 1.0 + _status_pulse.get("burn", 0.0) * 0.5
		var r: float = 8.0 * pulse_s
		draw_circle(Vector2(sx, sy), r, Color(1.0, 0.4, 0.1, 0.80 * dissolve_alpha))
		_draw_text_alpha(Vector2(sx + 14, sy + 5), str(burn_n), 12,
			Color(1.0, 0.7, 0.3, dissolve_alpha), false, dissolve_alpha)
		sx += 36.0
	if chill_n > 0:
		var pulse_s: float = 1.0 + _status_pulse.get("chill", 0.0) * 0.5
		var r: float = 8.0 * pulse_s
		draw_circle(Vector2(sx, sy), r, Color(0.3, 0.8, 1.0, 0.80 * dissolve_alpha))
		_draw_text_alpha(Vector2(sx + 14, sy + 5), str(chill_n), 12,
			Color(0.5, 0.9, 1.0, dissolve_alpha), false, dissolve_alpha)


# ─── Death particles (drawn separately so they outlast the dissolving body) ───

func _draw_death_particles() -> void:
	if _death_particles.is_empty():
		return
	for particle in _death_particles:
		var life: float = particle["life"]
		var max_life: float = particle["max_life"]
		if life >= max_life:
			continue
		var frac: float = life / max_life
		var alpha: float = 1.0 - frac
		var col: Color = particle["color"]
		col.a = alpha
		var r: float = lerp(5.0, 1.5, frac)
		draw_circle(particle["pos"], r, col)


# ─── Player HUD ───────────────────────────────────────────────────────────────

func _draw_player_hud() -> void:
	if _combat == null:
		return
	var php: int   = _combat.player_hp
	var phmax: int = _combat.player_max_hp
	var mn: int    = _combat.mana
	var mnmax: int = _combat.mana_max

	# Panel background
	var px: float = 20.0
	var py: float = 555.0
	var pw: float = 200.0
	var ph_box: float = 100.0
	draw_rect(Rect2(px, py, pw, ph_box), COL_PANEL)

	# HP — tweened width
	_draw_text(Vector2(px + 10, py + 18), "HP", 13, COL_HP_BAR)
	var hp_w: float = pw - 20.0
	draw_rect(Rect2(px + 10, py + 22, hp_w, 10.0), COL_HP_BG)
	var disp_hp: float = _disp_player_hp if _disp_player_hp >= 0.0 else float(php)
	var hp_frac: float = clamp(disp_hp / float(phmax), 0.0, 1.0)
	draw_rect(Rect2(px + 10, py + 22, hp_w * hp_frac, 10.0), COL_HP_BAR)
	_draw_text(Vector2(px + 10, py + 38), "%d / %d" % [php, phmax], 12, COL_WHITE)

	# Mana orbs — filled orbs tween on mana change (simple immediate draw, no tween needed)
	_draw_text(Vector2(px + 10, py + 55), "Mana", 12, COL_MANA)
	for i in mnmax:
		var ox: float = px + 12.0 + i * 22.0
		var oy: float = py + 68.0
		if i < mn:
			draw_circle(Vector2(ox, oy), 8.0, COL_MANA)
			draw_arc(Vector2(ox, oy), 8.0, 0.0, TAU, 16, Color(0.6, 0.8, 1.0, 0.5), 1.5)
		else:
			draw_arc(Vector2(ox, oy), 8.0, 0.0, TAU, 16, Color(0.35, 0.45, 0.65, 0.6), 1.5)

	# Block — tweened display value
	var disp_blk: int = int(round(_disp_player_block))
	if disp_blk > 0:
		_draw_text(Vector2(px + 10, py + 88), "Block %d" % disp_blk, 12, COL_BLOCK)


# ─── Hand ─────────────────────────────────────────────────────────────────────

func _draw_hand() -> void:
	if _combat == null:
		return
	var hand: Array = _combat.hand
	var total: int = hand.size()
	if total == 0:
		return
	var mn: int = _combat.mana

	var start_x: float = _hand_start_x(total)

	for i in total:
		var card_id: String = hand[i]
		var card_data: Dictionary = CardDB.card(card_id)
		var cx: float = start_x + i * CARD_SPACING
		var cy: float = CARD_HAND_Y
		var rect := Rect2(cx - CARD_W * 0.5, cy - CARD_H * 0.5, CARD_W, CARD_H)

		var cost: int = card_data.get("cost", 0)
		var affordable: bool = cost <= mn

		# Highlight selected card
		var is_selected: bool = (i == selected_card_idx)
		var card_cy_off: float = -12.0 if is_selected else 0.0
		rect.position.y += card_cy_off

		_draw_card_face(rect, card_data, affordable, is_selected)


func _hand_start_x(total: int) -> float:
	# Center the spread of cards; clamp so they don't overflow
	var total_span: float = (total - 1) * CARD_SPACING
	var min_x: float = CARD_W * 0.5 + 10.0
	var max_x: float = END_BTN_RECT.position.x - CARD_W * 0.5 - 10.0
	var ideal_start: float = W * 0.5 - total_span * 0.5
	return clamp(ideal_start, min_x, max_x)


func _draw_card_face(rect: Rect2, card_data: Dictionary, affordable: bool, selected: bool) -> void:
	var elem: String = card_data.get("element", "neutral")
	var elem_col: Color = _element_color(elem)
	var cost: int = card_data.get("cost", 0)
	var c_name: String = card_data.get("name", "???")
	var c_type: String = card_data.get("type", "")
	var effect: Dictionary = card_data.get("effect", {})

	# Glow halo if selected
	if selected:
		draw_rect(Rect2(rect.position - Vector2(6, 6), rect.size + Vector2(12, 12)),
			Color(COL_SELECTED.r, COL_SELECTED.g, COL_SELECTED.b, 0.35))

	# Card body
	draw_rect(rect, COL_CARD_BG)

	# Element-colored top bar
	var top_bar := Rect2(rect.position, Vector2(rect.size.x, 6.0))
	draw_rect(top_bar, elem_col)

	# Border
	var border_col: Color = elem_col if affordable else Color(0.3, 0.3, 0.35, 0.7)
	if selected:
		border_col = COL_SELECTED
	draw_rect(rect, border_col, false)  # outline only

	# Cost gem (top-left)
	var gem_c := Vector2(rect.position.x + 13.0, rect.position.y + 18.0)
	draw_circle(gem_c, 9.0, COL_MANA if affordable else Color(0.25, 0.25, 0.35))
	_draw_text(gem_c + Vector2(-4.0, 5.0), str(cost), 11, COL_WHITE)

	# Card name
	_draw_text(Vector2(rect.get_center().x, rect.position.y + 22.0), c_name, 11, COL_WHITE, true)

	# Type tag
	_draw_text(Vector2(rect.get_center().x, rect.position.y + 40.0), c_type.to_upper(), 9,
		elem_col, true)

	# Effect summary
	var eff_lines: Array = _effect_summary(effect, elem)
	var ey: float = rect.position.y + 65.0
	for line in eff_lines:
		_draw_text(Vector2(rect.get_center().x, ey), line, 10, COL_WHITE, true)
		ey += 14.0

	# Dim overlay if unaffordable
	if not affordable:
		draw_rect(rect, Color(0.0, 0.0, 0.0, 0.45))


# ─── Cast ghost (card arc) ─────────────────────────────────────────────────────

func _draw_cast_ghost() -> void:
	if not _cast_ghost_active:
		return
	# Draw a glowing rhombus at the ghost position with fading alpha
	var col := Color(1.0, 0.95, 0.5, _cast_ghost_alpha)
	var glow_col := Color(1.0, 0.85, 0.3, _cast_ghost_alpha * 0.4)
	var pos := _cast_ghost_pos
	var sz: float = 18.0 * (1.0 - _cast_ghost_t * 0.4)
	# Outer glow
	draw_circle(pos, sz + 6.0, glow_col)
	# Card ghost rhombus
	var pts := PackedVector2Array([
		Vector2(pos.x, pos.y - sz),
		Vector2(pos.x + sz * 0.6, pos.y),
		Vector2(pos.x, pos.y + sz),
		Vector2(pos.x - sz * 0.6, pos.y),
	])
	draw_colored_polygon(pts, col)
	# Trail dot slightly behind
	if _cast_ghost_t > 0.1:
		var trail_p: float = _cast_ghost_t - 0.1
		var trail_pos := _cast_ghost_start.lerp(_cast_ghost_target, trail_p)
		trail_pos.y += sin(trail_p * PI) * -80.0
		draw_circle(trail_pos, 5.0, Color(1.0, 0.8, 0.3, _cast_ghost_alpha * 0.3))


# ─── Pile counts ──────────────────────────────────────────────────────────────

func _draw_pile_counts() -> void:
	if _combat == null:
		return
	var draw_n: int  = _combat.draw_pile.size()
	var disc_n: int  = _combat.discard_pile.size()
	# Draw pile: bottom-left
	_draw_text(Vector2(20.0, H - 12.0), "Draw: %d" % draw_n, 12, Color(0.7, 0.7, 0.8))
	# Discard pile: bottom-right (before end button)
	_draw_text(Vector2(END_BTN_RECT.position.x - 10.0, H - 12.0),
		"Disc: %d" % disc_n, 12, Color(0.7, 0.7, 0.8))


# ─── End Turn button ──────────────────────────────────────────────────────────

func _draw_end_turn_button() -> void:
	# Drawn button (Main handles hit-testing via get_end_turn_rect())
	var r := END_BTN_RECT
	draw_rect(r, COL_END_BTN)
	draw_rect(r, Color(1.0, 0.7, 1.0, 0.5), false)
	_draw_text(r.get_center() + Vector2(0.0, 5.0), "End Turn", 14, COL_WHITE, true)


# ─── Reward overlay ───────────────────────────────────────────────────────────

func _draw_reward_overlay() -> void:
	# Dim scrim
	draw_rect(Rect2(0, 0, W, H), Color(0.0, 0.0, 0.0, 0.55))

	# Title
	_draw_text(Vector2(W * 0.5, H * 0.5 - 140.0), "Choose a Card Reward", 20,
		Color(0.95, 0.85, 0.40), true)

	# 3 card faces
	for i in 3:
		if i >= _rewards.size():
			break
		var r_id: String = _rewards[i]
		var r_data: Dictionary = CardDB.card(r_id)
		var rect := get_reward_card_rect(i)
		_draw_card_face(rect, r_data, true, false)

	# Skip button
	var skip_r := get_skip_rect()
	draw_rect(skip_r, COL_SKIP_BTN)
	draw_rect(skip_r, Color(0.6, 0.6, 0.7, 0.6), false)
	_draw_text(skip_r.get_center() + Vector2(0.0, 5.0), "Skip", 14, COL_WHITE, true)


# ─── Win / Lose overlay ───────────────────────────────────────────────────────

func _draw_overlay_message(headline: String, sub: String, col: Color) -> void:
	# Scrim
	draw_rect(Rect2(0, 0, W, H), Color(0.0, 0.0, 0.0, 0.70))
	# Glow halo
	draw_circle(Vector2(W * 0.5, H * 0.5), 200.0, Color(col.r, col.g, col.b, 0.10))
	# Text
	_draw_text(Vector2(W * 0.5, H * 0.5 - 30.0), headline, 36, col, true)
	_draw_text(Vector2(W * 0.5, H * 0.5 + 20.0), sub, 18, COL_WHITE, true)


# ─── Helpers ──────────────────────────────────────────────────────────────────

func _draw_badge(pos: Vector2, label: String, col: Color) -> void:
	draw_circle(pos, 14.0, col.darkened(0.4))
	draw_arc(pos, 14.0, 0.0, TAU, 24, col, 2.0)
	_draw_text(pos + Vector2(-5.0, 5.0), label, 11, COL_WHITE)


func _draw_text(pos: Vector2, text: String, size: int, col: Color, centered: bool = false) -> void:
	# Use the default ThemeDB font (works in headless + desktop)
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return
	var off := Vector2(0.0, 0.0)
	if centered:
		var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		off.x = -tw * 0.5
	draw_string(font, pos + off, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw_text_alpha(pos: Vector2, text: String, size: int, col: Color,
		centered: bool = false, alpha: float = 1.0) -> void:
	var c := Color(col.r, col.g, col.b, col.a * alpha)
	_draw_text(pos, text, size, c, centered)


func _element_color(elem: String) -> Color:
	match elem:
		"fire":      return COL_FIRE
		"ice":       return COL_ICE
		"lightning": return COL_LIGHTNING
		_:           return COL_NEUTRAL


func _effect_summary(effect: Dictionary, elem: String) -> Array:
	var lines: Array = []
	if effect.has("damage"):
		var d: int = effect.get("damage")
		var txt: String = "DMG %d" % d
		if effect.has("lightning_bonus"):
			txt += "+%d" % effect.get("lightning_bonus")
		lines.append(txt)
	if effect.has("block"):
		lines.append("Block +%d" % effect.get("block"))
	if effect.has("burn"):
		lines.append("Burn +%d" % effect.get("burn"))
	if effect.has("chill"):
		lines.append("Chill +%d" % effect.get("chill"))
	if effect.has("draw"):
		lines.append("Draw %d" % effect.get("draw"))
	if effect.has("power"):
		lines.append("POWER")
	return lines
