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

# ─── Raster asset textures (raster asset pass — Cartoon Arcadia flat-cartoon) ──
# Loaded in _ready(); null when an import sidecar is missing (draw helpers guard).
var _tex_bg: Texture2D = null
var _tex_cardart: Dictionary = {}  # card id -> Texture2D (full-bleed POV art)
var _tex_enemy: Dictionary = {}    # enemy id -> Texture2D
var _tex_card_back: Texture2D = null
var _tex_relic: Dictionary = {}    # relic id -> Texture2D
var _tex_icon: Dictionary = {}     # ui icon name -> Texture2D (painted, cohesive)
var _relics: Array = []            # relic ids held by the player (set via refresh)

# Card ids with full-bleed POV illustrations (one per CardDB id).
const CARD_IDS := [
	"arcane_bolt", "ward", "meditate", "mana_surge",
	"ember", "flame_lash", "immolate", "wildfire",
	"frost_shard", "glacial_wall", "freeze", "blizzard",
	"spark", "chain_lightning", "overload", "thunderclap",
]

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

# Enrage pulse: 0..1 scale-pop applied to the enemy silhouette on enrage events
var _enrage_pulse: float = 0.0
const ENRAGE_PULSE_DECAY: float = 5.0

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
	# Mipmap sampling so downscaled textures (hand cards, pile card-backs, relic,
	# sprites) are smooth instead of grainy. Needs BOTH this filter AND
	# mipmaps/generate=true in each texture's .import.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	# Pre-generate mote positions (deterministic, not random per-frame)
	# (Motes are now baked into the chamber background SVG; kept as a harmless fallback.)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xABC123
	for i in 24:
		_motes.append(Vector2(rng.randf_range(40.0, W - 40.0), rng.randf_range(40.0, H * 0.75)))

	# ── Raster asset pass: load the generated PNGs once. Each load() falls back to
	# null if the import sidecar is missing; the draw helpers guard on null and
	# revert to the old primitive so the game never hard-fails on a missing asset.
	_tex_bg = _try_load("res://art/bg_chamber.png")
	for cid in CARD_IDS:
		_tex_cardart[cid] = _try_load("res://art/card_%s.png" % cid)
	_tex_enemy = {
		"imp":          _try_load("res://art/enemy_imp.png"),
		"frost_wraith": _try_load("res://art/enemy_frost_wraith.png"),
		"golem":        _try_load("res://art/enemy_golem.png"),
		"archmage":     _try_load("res://art/enemy_archmage.png"),
	}
	_tex_card_back = _try_load("res://art/card_back.png")
	_tex_relic = {
		"ember_heart": _try_load("res://art/relic_ember_heart.png"),
		"storm_core":  _try_load("res://art/relic_storm_core.png"),
	}
	_tex_icon = {
		"mana":   _try_load("res://art/icon_mana.png"),
		"burn":   _try_load("res://art/icon_burn.png"),
		"chill":  _try_load("res://art/icon_chill.png"),
		"attack": _try_load("res://art/icon_attack.png"),
		"defend": _try_load("res://art/icon_defend.png"),
		"gem":    _try_load("res://art/icon_gem.png"),
	}


func _try_load(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	return null


# ─── Public API ───────────────────────────────────────────────────────────────

func refresh(combat, state: int, rewards: Array, relics: Array = []) -> void:
	var prev_combat = _combat
	_combat = combat
	_state = state
	_rewards = rewards
	_relics = relics
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
	_enrage_pulse = 0.0
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
			"enemy_enrage":
				var gain: int = ev.get("strength_gain", 0)
				# Bold pop-up near the enemy in aggressive orange-red
				_spawn_pop_up(Vector2(ENEMY_X + randf_range(-15.0, 15.0), ENEMY_Y - 110.0),
					"ENRAGE! +%d" % gain, Color(1.00, 0.35, 0.05), 22)
				# Scale-pulse on the enemy silhouette to reinforce the buff
				_enrage_pulse = 1.0
				queue_redraw()
			"draw":
				var amt: int = ev.get("amount", 0)
				# Subtle pop-up near the draw pile (bottom-left)
				_spawn_pop_up(Vector2(60.0 + randf_range(-8.0, 8.0), H - 38.0),
					"+%d" % amt, Color(0.75, 0.85, 1.00))


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


func _spawn_pop_up(pos: Vector2, text: String, col: Color, font_size: int = 18) -> void:
	# Pop-ups are Label nodes that tween upward + fade, then free themselves.
	# Guard: ThemeDB.fallback_font must exist (always true in Godot 4, headless too).
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_font_size_override("font_size", font_size)
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

	# Enrage pulse decay
	if _enrage_pulse > 0.001:
		_enrage_pulse = move_toward(_enrage_pulse, 0.0, _enrage_pulse * ENRAGE_PULSE_DECAY * delta)
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
	_draw_relics()
	_draw_hand()
	_draw_cast_ghost()
	_draw_pile_counts()
	_draw_end_turn_button()

	if _state == STATE_REWARD:
		_draw_reward_overlay()


# ─── Background ───────────────────────────────────────────────────────────────

func _draw_background() -> void:
	# Asset pass: the wide chamber SVG carries the gradient, runic floor circle,
	# pillars, candle glow and motes in one composed image. Draw it full-frame.
	if _tex_bg != null:
		draw_texture_rect(_tex_bg, Rect2(0.0, 0.0, W, H), false)
		return

	# ── Fallback: procedural primitive background (pre-asset-pass) ──
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
	# Enrage pulse: expand silhouette outward from center for a brief scale-pop
	var enrage_scale: float = 1.0 + _enrage_pulse * 0.18
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
	var center_pt := Vector2(ENEMY_X, ENEMY_Y)
	if enrage_scale != 1.0:
		for i in body_pts.size():
			body_pts[i] = center_pt + (body_pts[i] - center_pt) * enrage_scale

	# Hit-flash: overlay white on top of silhouette to simulate flash
	var flash: float = _enemy_flash
	var base_col := Color(0.22, 0.15, 0.38, dissolve_alpha)
	var glow_col := Color(0.70, 0.30, 1.00, 0.22 * dissolve_alpha)
	var fill_col := base_col.lerp(Color(1.0, 1.0, 1.0, dissolve_alpha), flash)
	var outline_col := Color(0.75, 0.50, 1.00, 0.85 * dissolve_alpha)

	# Asset pass: draw the per-enemy silhouette SVG. Flash = an overbright additive
	# pass (modulate >1 brightens in 2D), enrage = scale-pop, dissolve = alpha.
	# Falls back to the primitive polygon + eyes if the texture is missing.
	var en_id: String = en.get("id", "imp")
	var etex: Texture2D = _tex_enemy.get(en_id, null)
	if etex != null:
		var sz: float = 300.0 * enrage_scale
		# Bottom-anchor to a floor line so the creature STANDS on the runic circle
		# instead of floating (transparent-padded square sprites float if centered).
		var floor_y: float = ENEMY_Y + 150.0
		var dest := Rect2(ENEMY_X - sz * 0.5, floor_y - sz, sz, sz)
		draw_texture_rect(etex, dest, false, Color(1.0, 1.0, 1.0, dissolve_alpha))
		if flash > 0.01:
			draw_texture_rect(etex, dest, false, Color(3.0, 3.0, 3.0, flash * dissolve_alpha))
	else:
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

	# Block badge (if any) — styled shield.
	if e_block > 0:
		_draw_shield_badge(Vector2(ENEMY_X + 96.0, ENEMY_Y + 6.0), 14.0, COL_BLOCK,
			str(e_block), dissolve_alpha)

	# Name + intent + styled HP bar above the enemy, on a legibility panel
	# (intent row at top, name, then the bar — laid out so nothing collides).
	var bar_w: float = 150.0
	var bar_h: float = 16.0
	var bar_x: float = ENEMY_X - bar_w * 0.5
	var bar_y: float = ENEMY_Y - 145.0
	draw_rect(Rect2(ENEMY_X - 98.0, bar_y - 52.0, 196.0, 78.0),
		Color(0.05, 0.04, 0.11, 0.62 * dissolve_alpha))
	_draw_text_alpha(Vector2(ENEMY_X, bar_y - 14.0), e_name, 13, COL_WHITE, true, dissolve_alpha)
	var disp_hp: float = _disp_enemy_hp if _disp_enemy_hp >= 0.0 else float(e_hp)
	var hp_frac: float = clamp(disp_hp / float(e_max_hp), 0.0, 1.0)
	_draw_hp_bar(Rect2(bar_x, bar_y, bar_w, bar_h), hp_frac, COL_HP_BAR,
		"%d/%d" % [e_hp, e_max_hp], dissolve_alpha)

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
	# Slide in from 6px above when animating. Intent = ICON + value, not bare text.
	var intent_y_off: float = (1.0 - _intent_alpha) * -6.0
	var intent_cy: float = bar_y - 40.0 + intent_y_off
	if intent_type != "":
		_draw_intent_icon(Vector2(ENEMY_X - 20.0, intent_cy), intent_type, 9.0,
			Color(intent_col.r, intent_col.g, intent_col.b, intent_a))
		if intent_type == "attack" or intent_type == "defend":
			_draw_text_alpha(Vector2(ENEMY_X + 14.0, intent_cy + 5.0), str(intent_val),
				15, intent_col, true, intent_a)
		elif intent_type == "enrage":
			_draw_text_alpha(Vector2(ENEMY_X + 22.0, intent_cy + 5.0), "RAGE",
				12, intent_col, true, intent_a)

	# Status icons (flame = burn, snowflake = chill) in a row at the enemy's feet,
	# with the pulse scale-pop. Code-drawn so they stay crisp at small size.
	var statuses: Dictionary = en.get("statuses", {})
	var burn_n: int = statuses.get("burn", 0)
	var chill_n: int = statuses.get("chill", 0)
	var active: Array = []
	if burn_n > 0:
		active.append(["burn", burn_n])
	if chill_n > 0:
		active.append(["chill", chill_n])
	var sy: float = ENEMY_Y + 150.0
	var sx: float = ENEMY_X - (active.size() - 1) * 22.0
	for entry in active:
		var kind: String = entry[0]
		var n: int = entry[1]
		var pulse_s: float = 1.0 + _status_pulse.get(kind, 0.0) * 0.5
		var r: float = 11.0 * pulse_s
		var ring: Color = COL_FIRE if kind == "burn" else COL_ICE
		# Finished-badge backing: dark disc + colored ring so the icon reads as authored.
		draw_circle(Vector2(sx, sy), r + 4.0, Color(0.06, 0.05, 0.12, 0.80 * dissolve_alpha))
		draw_arc(Vector2(sx, sy), r + 4.0, 0.0, TAU, 22,
			Color(ring.r, ring.g, ring.b, 0.85 * dissolve_alpha), 2.0)
		var stex: Texture2D = _tex_icon.get(kind)
		if stex != null:
			var iz: float = r * 1.55
			draw_texture_rect(stex, Rect2(sx - iz, sy - iz, iz * 2.0, iz * 2.0), false,
				Color(1, 1, 1, dissolve_alpha))
		elif kind == "burn":
			_draw_flame_icon(Vector2(sx, sy), r, dissolve_alpha)
		else:
			_draw_snowflake_icon(Vector2(sx, sy), r, dissolve_alpha)
		_draw_text_shadow(Vector2(sx + r + 9.0, sy + 5.0), str(n), 13, COL_WHITE, true)
		sx += 46.0


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

	# Panel — flat-cartoon: solid fill + top accent bar + bold outline.
	var px: float = 20.0
	var py: float = 555.0
	var pw: float = 200.0
	var ph_box: float = 100.0
	draw_rect(Rect2(px, py, pw, ph_box), COL_PANEL)
	draw_rect(Rect2(px, py, pw, 4.0), Color(0.70, 0.50, 1.00, 0.85))
	draw_rect(Rect2(px, py, pw, ph_box), Color(0.10, 0.05, 0.18, 0.85), false, 2.0)

	# HP — styled bar with the value CENTERED on it (no overlap).
	_draw_text(Vector2(px + 10, py + 18), "HP", 12, COL_HP_BAR)
	var disp_hp: float = _disp_player_hp if _disp_player_hp >= 0.0 else float(php)
	var hp_frac: float = clamp(disp_hp / float(phmax), 0.0, 1.0)
	_draw_hp_bar(Rect2(px + 38.0, py + 10.0, pw - 50.0, 17.0), hp_frac, COL_HP_BAR,
		"%d / %d" % [php, phmax])

	# Mana orbs — styled (base + glow + highlight + bold outline).
	_draw_text(Vector2(px + 10, py + 52), "Mana", 12, COL_MANA)
	for i in mnmax:
		_draw_mana_orb(Vector2(px + 16.0 + i * 24.0, py + 66.0), i < mn)

	# Block — styled shield badge with the value (only when blocking).
	var disp_blk: int = int(round(_disp_player_block))
	if disp_blk > 0:
		_draw_shield_badge(Vector2(px + pw - 26.0, py + 66.0), 13.0, COL_BLOCK, str(disp_blk))


# ─── Relics ───────────────────────────────────────────────────────────────────

func _draw_relics() -> void:
	if _relics.is_empty():
		return
	var x: float = 20.0
	var y: float = 18.0
	var sz: float = 42.0
	for rid in _relics:
		var box := Rect2(x, y, sz, sz)
		# Round slot behind the icon for a HUD-anchored feel.
		draw_circle(box.get_center(), sz * 0.5 + 2.0, Color(0.06, 0.05, 0.12, 0.62))
		draw_arc(box.get_center(), sz * 0.5 + 2.0, 0.0, TAU, 24, Color(0.7, 0.55, 1.0, 0.7), 1.5)
		var rtex: Texture2D = _tex_relic.get(rid, null)
		if rtex != null:
			draw_texture_rect(rtex, box, false)
		else:
			draw_circle(box.get_center(), sz * 0.36, Color(1.0, 0.5, 0.2, 0.9))
		x += sz + 10.0


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


func _draw_vscrim(r: Rect2, c_top: Color, c_bot: Color) -> void:
	var pts := PackedVector2Array([
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)
	])
	var cols := PackedColorArray([c_top, c_top, c_bot, c_bot])
	draw_polygon(pts, cols)


func _draw_text_shadow(pos: Vector2, text: String, size: int, col: Color, centered: bool = false) -> void:
	_draw_text(pos + Vector2(1.0, 1.0), text, size, Color(0.0, 0.0, 0.0, 0.85), centered)
	_draw_text(pos, text, size, col, centered)


func _draw_card_face(rect: Rect2, card_data: Dictionary, affordable: bool, selected: bool) -> void:
	# Full-bleed POV card: opaque painted illustration fills the rect; all chrome
	# (legibility panels, cost badge, name, type, effect lines, border) is code-drawn
	# on top so one renderer works for every card. Falls back to a dark body + text
	# if the PNG is missing (mixed-method guard).
	var elem: String = card_data.get("element", "neutral")
	var elem_col: Color = _element_color(elem)
	var cost: int = card_data.get("cost", 0)
	var c_name: String = card_data.get("name", "???")
	var c_type: String = card_data.get("type", "")
	var effect: Dictionary = card_data.get("effect", {})
	var card_id: String = card_data.get("id", "")

	# Font sizes scale with card height so reward / larger cards get bigger text.
	var s: float = rect.size.y / 160.0
	var fs_name: int = int(round(11.0 * s))
	var fs_type: int = int(round(9.0 * s))
	var fs_eff: int = int(round(10.0 * s))
	var fs_cost: int = int(round(13.0 * s))

	# Selected glow halo behind the card.
	if selected:
		draw_rect(Rect2(rect.position - Vector2(6, 6), rect.size + Vector2(12, 12)),
			Color(COL_SELECTED.r, COL_SELECTED.g, COL_SELECTED.b, 0.35))

	# 1. Full-bleed painted art (fallback: dark card body).
	var art: Texture2D = _tex_cardart.get(card_id, null)
	if art != null:
		draw_texture_rect(art, rect, false)
	else:
		draw_rect(rect, COL_CARD_BG)

	# 2. Legibility — DEFINED semi-transparent solid panels behind text (read over
	#    ANY art), each feathered with a short gradient so it doesn't hard-cut.
	var panel_col := Color(0.05, 0.04, 0.11, 0.80)
	var bottom_h: float = rect.size.y * 0.40
	var feather: float = maxf(8.0, rect.size.y * 0.06)
	_draw_vscrim(Rect2(rect.position.x, rect.end.y - bottom_h - feather, rect.size.x, feather),
		Color(panel_col.r, panel_col.g, panel_col.b, 0.0), panel_col)
	draw_rect(Rect2(rect.position.x, rect.end.y - bottom_h, rect.size.x, bottom_h), panel_col)
	var top_h: float = rect.size.y * 0.17
	draw_rect(Rect2(rect.position.x, rect.position.y, rect.size.x, top_h), panel_col)
	_draw_vscrim(Rect2(rect.position.x, rect.position.y + top_h, rect.size.x, feather),
		panel_col, Color(panel_col.r, panel_col.g, panel_col.b, 0.0))

	# 3. Element border (gold when selected, dim when unaffordable).
	var border_col: Color = elem_col if affordable else Color(0.35, 0.35, 0.4, 0.8)
	if selected:
		border_col = COL_SELECTED
	draw_rect(rect, border_col, false, 2.0)

	# 4. Cost badge (top-left) — rich blue mana orb + cost number.
	var badge_r: float = 12.0 * s
	var badge_c := Vector2(rect.position.x + badge_r + 3.0, rect.position.y + badge_r + 4.0)
	_draw_mana_orb(badge_c, affordable, badge_r)
	_draw_text_shadow(badge_c + Vector2(0.0, fs_cost * 0.42), str(cost), int(fs_cost * 1.05), COL_WHITE, true)

	# 5. Name (top panel) — centered in the space RIGHT of the badge (no overlap).
	var name_cx: float = (badge_c.x + badge_r + 4.0 + rect.end.x) * 0.5
	_draw_text_shadow(Vector2(name_cx, rect.position.y + 16.0 * s), c_name, fs_name, COL_WHITE, true)

	# 6. Element pip — painted gem with an element-coloured ring + type tag.
	var type_y: float = rect.end.y - bottom_h + 12.0 * s
	var pip_c := Vector2(rect.position.x + 14.0 * s, type_y - 4.0 * s)
	var pip_r: float = 8.0 * s
	var gem: Texture2D = _tex_icon.get("gem")
	if gem != null:
		draw_arc(pip_c, pip_r + 1.0, 0.0, TAU, 20, Color(elem_col.r, elem_col.g, elem_col.b, 0.9), 2.0)
		draw_texture_rect(gem, Rect2(pip_c.x - pip_r, pip_c.y - pip_r, pip_r * 2.0, pip_r * 2.0), false)
	else:
		draw_circle(pip_c, pip_r * 0.7 + 1.5, Color(0.05, 0.04, 0.11, 0.9))
		draw_circle(pip_c, pip_r * 0.7, elem_col)
	_draw_text_shadow(Vector2(rect.get_center().x, type_y), c_type.to_upper(), fs_type, elem_col, true)

	# 7. Effect lines (bottom panel, drop-shadowed).
	var eff_lines: Array = _effect_summary(effect, elem)
	var ey: float = type_y + 18.0 * s
	for line in eff_lines:
		_draw_text_shadow(Vector2(rect.get_center().x, ey), line, fs_eff, COL_WHITE, true)
		ey += 15.0 * s

	# 8. Unaffordable dim overlay.
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
	# Card-back pile stacks flanking the hand (draw = left gap, discard = right gap).
	_draw_pile_stack(Vector2(256.0, H - 70.0), draw_n, "Draw")
	_draw_pile_stack(Vector2(1016.0, H - 70.0), disc_n, "Disc")


func _draw_pile_stack(center: Vector2, count: int, label: String) -> void:
	var cw: float = 44.0
	var ch: float = 58.0
	var base := Rect2(center.x - cw * 0.5, center.y - ch * 0.5, cw, ch)
	if _tex_card_back != null:
		# Two offset shadow cards behind the face for a "stack" feel.
		for k in range(2, 0, -1):
			var off := Vector2(k * 2.5, k * 2.5)
			draw_texture_rect(_tex_card_back, Rect2(base.position + off, base.size), false,
				Color(0.45, 0.45, 0.55, 0.7))
		draw_texture_rect(_tex_card_back, base, false)
		draw_rect(base, Color(0.7, 0.6, 1.0, 0.45), false, 1.5)
	else:
		draw_rect(base, COL_CARD_BG)
		draw_rect(base, Color(0.6, 0.5, 0.9, 0.6), false)
	# Count badge (bottom-right of the stack) — bold + legible.
	var badge := Vector2(base.end.x - 1.0, base.end.y - 3.0)
	draw_circle(badge, 13.0, Color(0.07, 0.05, 0.14, 0.97))
	draw_arc(badge, 13.0, 0.0, TAU, 22, Color(0.78, 0.66, 1.0), 2.5)
	_draw_text_shadow(badge + Vector2(0.0, 5.0), str(count), 15, COL_WHITE, true)
	_draw_text_shadow(Vector2(center.x, base.end.y + 15.0), label, 12, Color(0.86, 0.80, 0.96), true)


# ─── End Turn button ──────────────────────────────────────────────────────────

func _draw_end_turn_button() -> void:
	# Styled flat-cartoon button: drop shadow, solid fill, top cel highlight, bold outline.
	var r := END_BTN_RECT
	draw_rect(Rect2(r.position + Vector2(0.0, 3.0), r.size), Color(0.0, 0.0, 0.0, 0.35))
	draw_rect(r, COL_END_BTN)
	draw_rect(Rect2(r.position, Vector2(r.size.x, r.size.y * 0.45)), Color(1.0, 1.0, 1.0, 0.16))
	draw_rect(r, Color(0.14, 0.02, 0.20, 0.95), false, 2.5)
	_draw_text_shadow(r.get_center() + Vector2(0.0, 5.0), "End Turn", 15, COL_WHITE, true)


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

	# Skip button — styled (matches End Turn).
	var skip_r := get_skip_rect()
	draw_rect(Rect2(skip_r.position + Vector2(0.0, 3.0), skip_r.size), Color(0.0, 0.0, 0.0, 0.35))
	draw_rect(skip_r, COL_SKIP_BTN)
	draw_rect(Rect2(skip_r.position, Vector2(skip_r.size.x, skip_r.size.y * 0.45)), Color(1.0, 1.0, 1.0, 0.14))
	draw_rect(skip_r, Color(0.12, 0.12, 0.18, 0.9), false, 2.0)
	_draw_text_shadow(skip_r.get_center() + Vector2(0.0, 5.0), "Skip", 14, COL_WHITE, true)


# ─── Win / Lose overlay ───────────────────────────────────────────────────────

func _draw_overlay_message(headline: String, sub: String, col: Color) -> void:
	# Scrim over the chamber bg (drawn earlier) + glow halo.
	draw_rect(Rect2(0, 0, W, H), Color(0.0, 0.0, 0.0, 0.70))
	draw_circle(Vector2(W * 0.5, H * 0.5), 220.0, Color(col.r, col.g, col.b, 0.12))
	# Styled banner panel behind the headline (accent strips + bold outline).
	var bw: float = 520.0
	var bh: float = 122.0
	var br := Rect2(W * 0.5 - bw * 0.5, H * 0.5 - bh * 0.5 - 8.0, bw, bh)
	draw_rect(br, Color(0.06, 0.04, 0.12, 0.88))
	draw_rect(Rect2(br.position, Vector2(bw, 5.0)), col)
	draw_rect(Rect2(br.position.x, br.end.y - 5.0, bw, 5.0), col)
	draw_rect(br, Color(col.r, col.g, col.b, 0.85), false, 2.5)
	_draw_text_shadow(Vector2(W * 0.5, H * 0.5 - 12.0), headline, 40, col, true)
	_draw_text_shadow(Vector2(W * 0.5, H * 0.5 + 30.0), sub, 18, COL_WHITE, true)


# ─── Helpers ──────────────────────────────────────────────────────────────────

func _draw_badge(pos: Vector2, label: String, col: Color) -> void:
	draw_circle(pos, 14.0, col.darkened(0.4))
	draw_arc(pos, 14.0, 0.0, TAU, 24, col, 2.0)
	_draw_text(pos + Vector2(-5.0, 5.0), label, 11, COL_WHITE)


# ─── Code-drawn (mixed-method) gameplay icons — crisp at small size ───────────

func _draw_flame_icon(center: Vector2, r: float, alpha: float) -> void:
	var outer := PackedVector2Array([
		center + Vector2(0.0, -r * 1.3),
		center + Vector2(r * 0.85, r * 0.2),
		center + Vector2(r * 0.5, r * 0.9),
		center + Vector2(-r * 0.5, r * 0.9),
		center + Vector2(-r * 0.85, r * 0.2),
	])
	draw_colored_polygon(outer, Color(1.0, 0.45, 0.10, 0.95 * alpha))
	var inner := PackedVector2Array([
		center + Vector2(0.0, -r * 0.6),
		center + Vector2(r * 0.45, r * 0.25),
		center + Vector2(0.0, r * 0.7),
		center + Vector2(-r * 0.45, r * 0.25),
	])
	draw_colored_polygon(inner, Color(1.0, 0.85, 0.35, 0.95 * alpha))


func _draw_snowflake_icon(center: Vector2, r: float, alpha: float) -> void:
	var col := Color(0.55, 0.9, 1.0, 0.95 * alpha)
	for i in 3:
		var a: float = float(i) * PI / 3.0
		var d := Vector2(cos(a), sin(a)) * r
		draw_line(center - d, center + d, col, 2.5)
	draw_circle(center, r * 0.22, col)


func _draw_intent_icon(center: Vector2, kind: String, sz: float, col: Color) -> void:
	# Painted icon for attack/defend; code fallback (incl. enrage chevron) otherwise.
	var itex: Texture2D = _tex_icon.get(kind) if (kind == "attack" or kind == "defend") else null
	if itex != null:
		var s := sz * 1.8
		draw_texture_rect(itex, Rect2(center.x - s, center.y - s, s * 2.0, s * 2.0), false,
			Color(1, 1, 1, col.a))
		return
	match kind:
		"attack":
			# Bold blade/arrow pointing at the player (left).
			draw_colored_polygon(PackedVector2Array([
				center + Vector2(sz, -sz * 0.7),
				center + Vector2(sz, sz * 0.7),
				center + Vector2(-sz, 0.0),
			]), col)
		"defend":
			# Shield: pointed-bottom pentagon.
			draw_colored_polygon(PackedVector2Array([
				center + Vector2(-sz, -sz * 0.9),
				center + Vector2(sz, -sz * 0.9),
				center + Vector2(sz, sz * 0.2),
				center + Vector2(0.0, sz * 1.1),
				center + Vector2(-sz, sz * 0.2),
			]), col)
		"enrage":
			# Up double-chevron.
			for off in [0.0, sz * 0.75]:
				draw_polyline(PackedVector2Array([
					center + Vector2(-sz, sz * 0.4 - off),
					center + Vector2(0.0, -sz * 0.5 - off),
					center + Vector2(sz, sz * 0.4 - off),
				]), col, 2.5)
		_:
			draw_circle(center, sz * 0.5, col)


func _draw_hp_bar(rect: Rect2, frac: float, fill_col: Color, text: String, alpha: float = 1.0) -> void:
	# Flat-cartoon styled bar: dark base, flat fill + cel highlight, bold outline,
	# value CENTERED on the bar with a shadow (legible, not overlapping awkwardly).
	frac = clampf(frac, 0.0, 1.0)
	draw_rect(rect, Color(0.08, 0.06, 0.13, 0.92 * alpha))
	if frac > 0.0:
		var fill := Rect2(rect.position, Vector2(rect.size.x * frac, rect.size.y))
		draw_rect(fill, Color(fill_col.r, fill_col.g, fill_col.b, alpha))
		draw_rect(Rect2(fill.position, Vector2(fill.size.x, maxf(2.0, fill.size.y * 0.38))),
			Color(1, 1, 1, 0.22 * alpha))
	draw_rect(rect, Color(0.0, 0.0, 0.0, 0.8 * alpha), false, 2.0)
	if text != "":
		_draw_text_shadow(Vector2(rect.get_center().x, rect.get_center().y + rect.size.y * 0.30),
			text, int(rect.size.y * 0.78), Color(1, 1, 1, alpha), true)


func _draw_mana_orb(center: Vector2, filled: bool, r: float = 11.0) -> void:
	# Richly-rendered code orb: glow + radial body (rim→mid→core) + highlight + bold
	# outline. Reliable bright-blue mana that small-icon generation kept rendering dark.
	var ow: float = maxf(1.5, r * 0.16)
	if filled:
		draw_circle(center, r + 2.0, Color(0.30, 0.65, 1.0, 0.35))
		draw_circle(center, r, Color(0.10, 0.28, 0.75))
		draw_circle(center, r * 0.82, Color(0.20, 0.50, 0.98))
		draw_circle(center, r * 0.55, Color(0.45, 0.78, 1.0))
		draw_circle(center - Vector2(r * 0.30, r * 0.38), r * 0.24, Color(1, 1, 1, 0.9))
		draw_arc(center, r, 0.0, TAU, 24, Color(0.03, 0.05, 0.15, 0.95), ow)
	else:
		draw_circle(center, r, Color(0.12, 0.14, 0.22, 0.7))
		draw_circle(center, r * 0.55, Color(0.20, 0.24, 0.36, 0.7))
		draw_arc(center, r, 0.0, TAU, 24, Color(0.03, 0.05, 0.15, 0.8), ow)


func _draw_shield_badge(center: Vector2, sz: float, col: Color, text: String, alpha: float = 1.0) -> void:
	var pts := PackedVector2Array([
		center + Vector2(-sz, -sz * 0.9),
		center + Vector2(sz, -sz * 0.9),
		center + Vector2(sz, sz * 0.2),
		center + Vector2(0.0, sz * 1.15),
		center + Vector2(-sz, sz * 0.2),
	])
	draw_colored_polygon(pts, Color(col.r * 0.5, col.g * 0.5, col.b * 0.6, 0.95 * alpha))
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, Color(0.9, 0.95, 1.0, 0.95 * alpha), 2.0)
	if text != "":
		_draw_text_shadow(center + Vector2(0.0, sz * 0.4), text, int(sz * 1.1), Color(1, 1, 1, alpha), true)


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
		lines.append("DMG %d" % d)
	if effect.has("lightning_bonus"):
		lines.append("+%d vs afflicted" % effect.get("lightning_bonus"))
	if effect.has("block"):
		lines.append("Block +%d" % effect.get("block"))
	if effect.has("burn"):
		lines.append("Burn +%d" % effect.get("burn"))
	if effect.has("chill"):
		lines.append("Chill +%d" % effect.get("chill"))
	if effect.has("draw"):
		lines.append("Draw %d" % effect.get("draw"))
	if effect.has("power"):
		var pid: String = effect.get("power", "")
		match pid:
			"wildfire":
				lines.append("Attacks Burn 1")
			"overload":
				lines.append("+2 vs afflicted")
			_:
				lines.append("POWER")
	return lines
