extends Node2D

# ============================================================
# Aegis Grid II (match3-survival-0002) — a match-3 / survival-defense HYBRID.
#
# The grid (lower screen) is the player's ONLY weapon AND only shield. An enemy
# line advances in real time down a battlefield strip above and chips wall HP on
# contact. RED matches damage + push back the line (OFFENSE); BLUE matches repair
# the wall (DEFENSE). Because the same swaps serve both, every swap is an
# offense-vs-defense decision — the shared resource is the player's attention to
# the board (their swaps).
#
# FORCING FUNCTION (the mechanic that makes the survival layer RESHAPE matching):
# every ~6s the line telegraphs a HEAVY STRIKE — its lead chevron pulses red-hot,
# a shrinking countdown ring draws around it, and a danger vignette bleeds in from
# the top. When the ring closes, the strike CRATERS the wall (large HP hit) UNLESS
# the player landed a BLUE match during the telegraph window, which fires a cyan
# shield-flare that visibly ABSORBS the blow. This forces the player to abandon a
# combo and defend NOW. Conversely, ignoring offense lets the line march in.
#
# CONCURRENCY CONTRACT (deliberate, tuned): the real-time survival subsystem
# (enemy advance, breach damage, AND the telegraph countdown) KEEPS ADVANCING
# during swap/resolve animations. That is what creates the pressure — you cannot
# "pause the war" by dragging gems. See _update(): _update_survival() is called
# in IDLE, SWAPPING and RESOLVING states.
#
# SALIENCE (the run-004 fix): the cross-subsystem causal links are made loud and
# unmissable so the blend reads as ONE loop, not "match-3 with random stuff at the
# same time":
#   - RED match  -> bright tracer streak from each matched red gem UP to the line,
#                   a hit-flash on the line, line-HP bar visibly drops, screen kick.
#   - BLUE match  -> the wall floods cyan and its HP number jumps; if a strike was
#                   telegraphing, a big cyan SHIELD-FLARE absorbs it (= "you blocked
#                   it"), the countdown ring is consumed and the danger vignette
#                   clears. The defended strike is the clearest A->B in the game.
#   - Unblocked strike -> the wall craters: white flash, hard shake, HP number
#                   plummets, red shock-ring at the wall.
#
# Headless-safe: no physics, no scene instancing; all state owned here and
# rendered via _draw(). selftest.gd drives this script's state directly.
#
# Godot 4.6 strict-typing note: clamp/lerp/min/max/abs and indexing untyped
# Array/Dictionary all return Variant. Every receiving var is annotated
# explicitly (: float / : int / : Color) rather than relying on := inference.
# ============================================================

const VIEW_W := 720.0
const VIEW_H := 1280.0

# --- grid config ---
const COLS := 6
const ROWS := 7
const NUM_TYPES := 5
const EMPTY := -1

const T_RED := 0      # attack
const T_BLUE := 1     # shield
# 2,3,4 are neutral fillers (green, amber, violet)

# board geometry (computed in _ready)
var cell_size := 0.0
var board_x := 0.0
var board_y := 0.0
const BOARD_MARGIN_X := 40.0
const BOARD_TOP := 560.0
const BOARD_BOTTOM_MARGIN := 60.0

# battlefield strip (above the grid, above the wall)
var field_top := 96.0
var field_bottom := 0.0
var wall_y := 0.0

# --- palette ---
const COL_BG_TOP := Color(0.051, 0.043, 0.122)
const COL_BG_BOT := Color(0.031, 0.024, 0.078)
const COL_BOARD := Color(0.10, 0.08, 0.20, 0.55)
const COL_CELL := Color(0.15, 0.12, 0.28, 0.40)
const COL_FIELD := Color(0.04, 0.03, 0.10, 0.85)
const COL_WHITE := Color(1, 1, 1)
const COL_WALL := Color(0.25, 0.92, 0.98)        # cyan wall
const COL_ENEMY := Color(0.98, 0.22, 0.78)       # magenta chevrons
const COL_DANGER := Color(1.0, 0.16, 0.22)       # telegraph red-hot

var GEM_COLORS := [
	Color(0.98, 0.28, 0.30),   # 0 red    -> ATTACK (triangle)
	Color(0.30, 0.62, 0.99),   # 1 blue   -> SHIELD (square)
	Color(0.55, 0.92, 0.40),   # 2 green  (circle)
	Color(1.00, 0.74, 0.22),   # 3 amber  (diamond)
	Color(0.72, 0.45, 0.98),   # 4 violet (hexagon)
]

var rng := RandomNumberGenerator.new()

# --- board state ---
var board: Array = []
var cell_offset: Array = []
var cell_pop: Array = []
const POP_TIME := 0.28

enum State { IDLE, SWAPPING, RESOLVING, GAMEOVER }
var state: int = State.IDLE

# swap animation
var swap_a := Vector2i(-1, -1)
var swap_b := Vector2i(-1, -1)
var swap_t := 0.0
const SWAP_TIME := 0.16
var swap_back := false
var swap_pending_check := false

# resolve loop timing
var resolve_phase := 0
var resolve_timer := 0.0
const CLEAR_TIME := 0.30
const FALL_TIME := 0.22
var combo := 0
var _pending_clear: Array = []

# --- selection / input ---
var selected := Vector2i(-1, -1)
var sel_pulse := 0.0
var drag_start_cell := Vector2i(-1, -1)
var drag_start_pos := Vector2.ZERO
var dragging := false

# ============================================================
# SURVIVAL-DEFENSE SYSTEM
# ============================================================
var enemy_advance := 0.0        # 0 (top) .. 1 (at wall)
var enemy_line_hp := 0.0
var enemy_line_max_hp := 0.0
var enemy_wave := 0
const ENEMY_BASE_HP := 60.0
const ENEMY_HP_STEP := 26.0

var advance_speed := 0.0
const ADVANCE_BASE := 0.030
const ADVANCE_STEP := 0.012
const ADVANCE_CAP := 0.105
const RAMP_INTERVAL := 20.0

# wall
var wall_hp := 0.0
const WALL_MAX_HP := 100.0
const BREACH_DPS := 24.0

# offense / defense tuning
const RED_DAMAGE_PER_GEM := 9.0
const RED_PUSHBACK_PER_GEM := 0.020
const BLUE_REPAIR_PER_GEM := 7.0
const COMBO_DAMAGE_MULT := 0.35

# ---- FORCING FUNCTION: telegraphed heavy strike ----
# A strike telegraphs for TELEGRAPH_TIME seconds. While telegraphing, any BLUE
# match "arms" the shield (blue_defended). When the countdown ring closes:
#   - defended  -> shield-flare absorbs it, small/no wall damage.
#   - undefended -> wall craters for STRIKE_DAMAGE.
# After firing, the next strike schedules after strike_interval (which shrinks
# with the difficulty ramp -> more frequent late game).
enum Tele { NONE, CHARGING }
var tele_state: int = Tele.NONE
var tele_timer := 0.0           # counts down during CHARGING
var tele_total := 0.0           # the full charge time for ring math
var strike_cooldown := 0.0      # seconds until the next telegraph begins
var blue_defended := false      # set true if a blue match landed this telegraph
const TELEGRAPH_TIME := 2.4     # window the player has to land a blue match
const STRIKE_INTERVAL_BASE := 6.0
const STRIKE_INTERVAL_MIN := 3.4
const STRIKE_INTERVAL_STEP := 0.6
const STRIKE_DAMAGE := 34.0     # crater on an UNDEFENDED strike
const STRIKE_CHIP := 4.0        # tiny chip even when defended (defend isn't free pushback)
const STRIKE_ADVANCE_KICK := 0.12  # an undefended strike also lurches the line forward

# telegraph / strike juice
var danger_vignette := 0.0      # 0..1 bleed from top edge while charging
var shield_flare := 0.0         # cyan absorb flare 1->0
var strike_shock := 0.0         # red shock ring at wall on undefended crater 1->0

# nova
var nova_charge := 0.0
const NOVA_PER_GEM := 0.012
const NOVA_COMBO_BONUS := 0.030
var nova_flash := 0.0

# scoring
var score := 0
var enemies_destroyed := 0
var strikes_blocked := 0
var elapsed := 0.0

# --- juice ---
var shake_amt := 0.0
var shake_decay := 6.0
var flash_alpha := 0.0
var wall_pulse := 0.0
var line_hit_flash := 0.0
var tracers: Array = []
var combo_pulse := 0.0
var combo_display := 0
var wall_hp_pop := 0.0          # scale-pop on the wall HP number when it jumps

var particles: Array = []
var bokeh: Array = []
var game_over_t := 0.0

func _ready() -> void:
	rng.randomize()
	_compute_geometry()
	_init_bokeh()
	_new_game()

func _compute_geometry() -> void:
	var avail_w: float = VIEW_W - 2.0 * BOARD_MARGIN_X
	var avail_h: float = VIEW_H - BOARD_TOP - BOARD_BOTTOM_MARGIN
	cell_size = min(avail_w / float(COLS), avail_h / float(ROWS))
	var board_w: float = cell_size * float(COLS)
	var board_h: float = cell_size * float(ROWS)
	board_x = (VIEW_W - board_w) * 0.5
	board_y = BOARD_TOP + (avail_h - board_h) * 0.5
	wall_y = board_y - 18.0
	field_bottom = wall_y - 8.0

func _init_bokeh() -> void:
	bokeh.clear()
	for i in range(16):
		bokeh.append({
			"pos": Vector2(rng.randf() * VIEW_W, rng.randf() * VIEW_H),
			"r": rng.randf_range(14.0, 60.0),
			"spd": rng.randf_range(6.0, 22.0),
			"col": GEM_COLORS[rng.randi() % NUM_TYPES],
			"phase": rng.randf() * TAU,
		})

# ------------------------------------------------------------
# Game setup
# ------------------------------------------------------------
func _new_game() -> void:
	board = []
	cell_offset = []
	cell_pop = []
	for r in range(ROWS):
		var row: Array = []
		var orow: Array = []
		var prow: Array = []
		for c in range(COLS):
			row.append(EMPTY)
			orow.append(0.0)
			prow.append(0.0)
		board.append(row)
		cell_offset.append(orow)
		cell_pop.append(prow)
	_fill_board_no_matches()
	score = 0
	enemies_destroyed = 0
	strikes_blocked = 0
	combo = 0
	combo_display = 0
	elapsed = 0.0
	state = State.IDLE
	selected = Vector2i(-1, -1)
	particles.clear()
	tracers.clear()
	shake_amt = 0.0
	flash_alpha = 0.0
	combo_pulse = 0.0
	wall_pulse = 0.0
	line_hit_flash = 0.0
	nova_flash = 0.0
	game_over_t = 0.0
	wall_hp_pop = 0.0

	# survival state
	wall_hp = WALL_MAX_HP
	enemy_advance = 0.0
	enemy_wave = 0
	enemy_line_max_hp = ENEMY_BASE_HP
	enemy_line_hp = enemy_line_max_hp
	advance_speed = ADVANCE_BASE
	nova_charge = 0.0

	# forcing-function state
	tele_state = Tele.NONE
	tele_timer = 0.0
	tele_total = 0.0
	strike_cooldown = STRIKE_INTERVAL_BASE
	blue_defended = false
	danger_vignette = 0.0
	shield_flare = 0.0
	strike_shock = 0.0

func _fill_board_no_matches() -> void:
	for r in range(ROWS):
		for c in range(COLS):
			var t: int = _pick_safe_type(r, c)
			board[r][c] = t
			cell_offset[r][c] = 0.0
			cell_pop[r][c] = 0.0

func _pick_safe_type(r: int, c: int) -> int:
	var forbidden: Dictionary = {}
	if c >= 2 and board[r][c - 1] == board[r][c - 2] and board[r][c - 1] != EMPTY:
		forbidden[board[r][c - 1]] = true
	if r >= 2 and board[r - 1][c] == board[r - 2][c] and board[r - 1][c] != EMPTY:
		forbidden[board[r - 1][c]] = true
	var choices: Array = []
	for t in range(NUM_TYPES):
		if not forbidden.has(t):
			choices.append(t)
	if choices.is_empty():
		return rng.randi() % NUM_TYPES
	return int(choices[rng.randi() % choices.size()])

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------
func _process(delta: float) -> void:
	_update(delta)
	queue_redraw()

func _update(delta: float) -> void:
	delta = min(delta, 0.05)
	sel_pulse += delta
	_update_bokeh(delta)
	_update_particles(delta)
	_update_tracers(delta)
	if shake_amt > 0.0:
		shake_amt = max(0.0, shake_amt - shake_decay * delta * shake_amt - 0.2 * delta)
	flash_alpha = max(0.0, flash_alpha - 3.5 * delta)
	combo_pulse = max(0.0, combo_pulse - 3.0 * delta)
	wall_pulse = max(0.0, wall_pulse - 2.5 * delta)
	line_hit_flash = max(0.0, line_hit_flash - 4.0 * delta)
	nova_flash = max(0.0, nova_flash - 1.6 * delta)
	shield_flare = max(0.0, shield_flare - 2.2 * delta)
	strike_shock = max(0.0, strike_shock - 2.0 * delta)
	wall_hp_pop = max(0.0, wall_hp_pop - 3.0 * delta)

	match state:
		State.IDLE:
			_update_survival(delta)
		State.SWAPPING:
			_update_swap(delta)
			_update_survival(delta)
		State.RESOLVING:
			_update_resolve(delta)
			_update_survival(delta)
		State.GAMEOVER:
			game_over_t += delta

# The real-time advancing-threat system + the telegraphed-strike forcing function.
# CONCURRENCY CONTRACT: this runs in IDLE, SWAPPING and RESOLVING — it never pauses
# for the player's discrete actions.
func _update_survival(delta: float) -> void:
	elapsed += delta
	var step: int = int(elapsed / RAMP_INTERVAL)
	advance_speed = min(ADVANCE_CAP, ADVANCE_BASE + float(step) * ADVANCE_STEP)

	# advance the enemy line toward the wall
	enemy_advance += advance_speed * delta
	if enemy_advance >= 1.0:
		enemy_advance = 1.0
		wall_hp -= BREACH_DPS * delta
		shake_amt = max(shake_amt, 2.0)
		if wall_hp <= 0.0:
			wall_hp = 0.0
			_game_over()
			return

	_update_telegraph(delta, step)

# Telegraph / heavy-strike state machine (the forcing function).
func _update_telegraph(delta: float, ramp_step: int) -> void:
	if tele_state == Tele.NONE:
		strike_cooldown -= delta
		if strike_cooldown <= 0.0:
			_begin_telegraph()
	else:  # CHARGING
		tele_timer -= delta
		# danger vignette ramps up as the ring closes
		var prog: float = 1.0 - clamp(tele_timer / max(0.001, tele_total), 0.0, 1.0)
		danger_vignette = max(danger_vignette, prog)
		if tele_timer <= 0.0:
			_fire_strike(ramp_step)

func _begin_telegraph() -> void:
	tele_state = Tele.CHARGING
	tele_total = TELEGRAPH_TIME
	tele_timer = TELEGRAPH_TIME
	blue_defended = false
	danger_vignette = 0.0

# Resolve the strike when the countdown ring closes.
func _fire_strike(ramp_step: int) -> void:
	tele_state = Tele.NONE
	# schedule the next strike; interval shrinks with the ramp (more frequent late)
	var interval: float = max(STRIKE_INTERVAL_MIN, STRIKE_INTERVAL_BASE - float(ramp_step) * STRIKE_INTERVAL_STEP)
	strike_cooldown = interval

	if blue_defended:
		# DEFENDED: the cyan shield-flare absorbs the blow. Loud, unmissable A->B.
		strikes_blocked += 1
		score += 120
		shield_flare = 1.0
		wall_pulse = 1.0
		flash_alpha = max(flash_alpha, 0.18)
		shake_amt = max(shake_amt, 4.0)
		wall_hp = max(0.0, wall_hp - STRIKE_CHIP)
		danger_vignette = 0.0
	else:
		# UNDEFENDED: the wall craters. White flash, hard shake, HP plummets.
		wall_hp -= STRIKE_DAMAGE
		strike_shock = 1.0
		flash_alpha = max(flash_alpha, 0.55)
		shake_amt = max(shake_amt, 14.0)
		wall_hp_pop = 1.0
		# the strike also lurches the line forward (the threat literally surges in)
		enemy_advance = min(1.0, enemy_advance + STRIKE_ADVANCE_KICK)
		danger_vignette = 0.0
		if wall_hp <= 0.0:
			wall_hp = 0.0
			_game_over()
	blue_defended = false

# Apply the outcome of a cleared match group by gem type.
func _apply_match_effects(matches: Array) -> void:
	var red_count := 0
	var blue_count := 0
	for cell in matches:
		var cc: int = cell.x
		var rr: int = cell.y
		var t: int = board[rr][cc]
		if t == T_RED:
			red_count += 1
		elif t == T_BLUE:
			blue_count += 1

	var combo_mult: float = 1.0 + COMBO_DAMAGE_MULT * float(max(0, combo - 1))

	# RED -> OFFENSE: damage + push back the line, with a tracer streak up to it.
	if red_count > 0:
		var dmg: float = float(red_count) * RED_DAMAGE_PER_GEM * combo_mult
		enemy_line_hp -= dmg
		var push: float = float(red_count) * RED_PUSHBACK_PER_GEM * combo_mult
		enemy_advance = max(0.0, enemy_advance - push)
		line_hit_flash = 1.0
		shake_amt = max(shake_amt, 3.0 + float(red_count))
		for cell in matches:
			if board[cell.y][cell.x] == T_RED:
				var src: Vector2 = _cell_center(cell.x, cell.y)
				var dst: Vector2 = Vector2(src.x, _enemy_line_y())
				tracers.append({
					"from": src, "to": dst, "life": 0.22, "max_life": 0.22,
					"col": GEM_COLORS[T_RED],
				})
		if enemy_line_hp <= 0.0:
			enemies_destroyed += 1
			score += 250
			_spawn_reinforcement(0.45)

	# BLUE -> DEFENSE: repair the wall AND arm the shield against a telegraphing strike.
	if blue_count > 0:
		var repair: float = float(blue_count) * BLUE_REPAIR_PER_GEM * combo_mult
		var before: float = wall_hp
		wall_hp = min(WALL_MAX_HP, wall_hp + repair)
		wall_pulse = 1.0
		if wall_hp > before + 0.5:
			wall_hp_pop = 1.0
		# FORCING FUNCTION: a blue match during the telegraph window blocks the strike.
		if tele_state == Tele.CHARGING:
			blue_defended = true

	# nova charge
	var charge: float = float(matches.size()) * NOVA_PER_GEM
	charge += float(max(0, combo - 1)) * NOVA_COMBO_BONUS
	nova_charge = min(1.0, nova_charge + charge)
	if nova_charge >= 1.0:
		_fire_nova()

func _spawn_reinforcement(pushback: float) -> void:
	enemy_wave += 1
	enemy_advance = max(0.0, enemy_advance - pushback)
	enemy_line_max_hp = ENEMY_BASE_HP + float(enemy_wave) * ENEMY_HP_STEP
	enemy_line_hp = enemy_line_max_hp

func _fire_nova() -> void:
	nova_charge = 0.0
	nova_flash = 1.0
	flash_alpha = max(flash_alpha, 0.5)
	shake_amt = max(shake_amt, 12.0)
	enemies_destroyed += 1
	score += 400
	_spawn_reinforcement(1.0)
	enemy_advance = 0.0

func _game_over() -> void:
	if state == State.GAMEOVER:
		return
	state = State.GAMEOVER
	shake_amt = 16.0
	flash_alpha = 0.6
	game_over_t = 0.0

# ------------------------------------------------------------
# Swap handling
# ------------------------------------------------------------
func _begin_swap(a: Vector2i, b: Vector2i, is_undo: bool) -> void:
	swap_a = a
	swap_b = b
	swap_t = 0.0
	swap_back = is_undo
	swap_pending_check = not is_undo
	state = State.SWAPPING

func _update_swap(delta: float) -> void:
	swap_t += delta
	if swap_t >= SWAP_TIME:
		var ta: int = board[swap_a.y][swap_a.x]
		var tb: int = board[swap_b.y][swap_b.x]
		board[swap_a.y][swap_a.x] = tb
		board[swap_b.y][swap_b.x] = ta
		if swap_pending_check:
			var matches: Array = _find_matches()
			if matches.is_empty():
				_begin_swap(swap_a, swap_b, true)
				shake_amt = max(shake_amt, 3.0)
			else:
				combo = 0
				state = State.RESOLVING
				_start_clear(matches)
		else:
			selected = Vector2i(-1, -1)
			state = State.IDLE
			swap_a = Vector2i(-1, -1)
			swap_b = Vector2i(-1, -1)

# ------------------------------------------------------------
# Match detection
# ------------------------------------------------------------
func _find_matches() -> Array:
	var matched: Dictionary = {}
	var result: Array = []
	for r in range(ROWS):
		var run_start := 0
		while run_start < COLS:
			var t: int = board[r][run_start]
			var run_end := run_start
			if t != EMPTY:
				while run_end + 1 < COLS and board[r][run_end + 1] == t:
					run_end += 1
			if t != EMPTY and (run_end - run_start + 1) >= 3:
				for c in range(run_start, run_end + 1):
					var key: String = str(r) + "," + str(c)
					if not matched.has(key):
						matched[key] = true
						result.append(Vector2i(c, r))
			run_start = run_end + 1
	for c in range(COLS):
		var run_start := 0
		while run_start < ROWS:
			var t: int = board[run_start][c]
			var run_end := run_start
			if t != EMPTY:
				while run_end + 1 < ROWS and board[run_end + 1][c] == t:
					run_end += 1
			if t != EMPTY and (run_end - run_start + 1) >= 3:
				for r in range(run_start, run_end + 1):
					var key: String = str(r) + "," + str(c)
					if not matched.has(key):
						matched[key] = true
						result.append(Vector2i(c, r))
			run_start = run_end + 1
	return result

# ------------------------------------------------------------
# Resolve loop: clear -> fall/refill -> rescan
# ------------------------------------------------------------
func _start_clear(matches: Array) -> void:
	combo += 1
	var cleared: int = matches.size()
	score += cleared * 10 * combo

	# apply survival/defense effects BEFORE clearing (gem types still on the board)
	_apply_match_effects(matches)

	flash_alpha = max(flash_alpha, 0.30)
	shake_amt = max(shake_amt, 2.5 + float(combo) * 1.2)
	for cell in matches:
		var c: int = cell.x
		var r: int = cell.y
		cell_pop[r][c] = POP_TIME
		var pcol: Color = GEM_COLORS[board[r][c]] if board[r][c] != EMPTY else COL_WHITE
		_spawn_burst(_cell_center(c, r), pcol)

	if combo >= 2:
		combo_pulse = 1.0
		combo_display = combo

	resolve_phase = 0
	resolve_timer = CLEAR_TIME
	_pending_clear = matches.duplicate()

func _update_resolve(delta: float) -> void:
	resolve_timer -= delta
	for r in range(ROWS):
		for c in range(COLS):
			if cell_pop[r][c] > 0.0:
				cell_pop[r][c] = max(0.0, cell_pop[r][c] - delta)
			var off: float = cell_offset[r][c]
			if off != 0.0:
				off = lerp(off, 0.0, min(1.0, delta * 12.0))
				if abs(off) < 0.5:
					off = 0.0
				cell_offset[r][c] = off

	if resolve_timer > 0.0:
		return

	if resolve_phase == 0:
		for cell in _pending_clear:
			board[cell.y][cell.x] = EMPTY
		_pending_clear = []
		_apply_gravity_and_refill()
		resolve_phase = 1
		resolve_timer = FALL_TIME
	else:
		var more: Array = _find_matches()
		if more.is_empty():
			for r in range(ROWS):
				for c in range(COLS):
					cell_offset[r][c] = 0.0
			selected = Vector2i(-1, -1)
			swap_a = Vector2i(-1, -1)
			swap_b = Vector2i(-1, -1)
			state = State.IDLE
		else:
			_start_clear(more)

func _apply_gravity_and_refill() -> void:
	for c in range(COLS):
		var write_r := ROWS - 1
		for r in range(ROWS - 1, -1, -1):
			if board[r][c] != EMPTY:
				if write_r != r:
					board[write_r][c] = board[r][c]
					board[r][c] = EMPTY
					var prev_off: float = cell_offset[r][c]
					cell_offset[write_r][c] = float(write_r - r) * cell_size * -1.0 + prev_off
				write_r -= 1
		var spawn_index := 0
		for r in range(write_r, -1, -1):
			board[r][c] = rng.randi() % NUM_TYPES
			cell_offset[r][c] = -float(spawn_index + r + 2) * cell_size
			spawn_index += 1
			cell_pop[r][c] = 0.0

# ------------------------------------------------------------
# Particles & ambient
# ------------------------------------------------------------
func _spawn_burst(pos: Vector2, col: Color) -> void:
	var n := 8
	for i in range(n):
		var ang: float = rng.randf() * TAU
		var spd: float = rng.randf_range(80.0, 240.0)
		particles.append({
			"pos": pos,
			"vel": Vector2(cos(ang), sin(ang)) * spd,
			"life": rng.randf_range(0.3, 0.6),
			"max_life": 0.6,
			"col": col,
			"size": rng.randf_range(3.0, 7.0),
		})

func _update_particles(delta: float) -> void:
	var i := particles.size() - 1
	while i >= 0:
		var p: Dictionary = particles[i]
		p.life -= delta
		if p.life <= 0.0:
			particles.remove_at(i)
		else:
			p.vel *= (1.0 - 2.5 * delta)
			p.vel.y += 220.0 * delta
			p.pos += p.vel * delta
		i -= 1

func _update_tracers(delta: float) -> void:
	var i := tracers.size() - 1
	while i >= 0:
		var tr: Dictionary = tracers[i]
		tr.life -= delta
		if tr.life <= 0.0:
			tracers.remove_at(i)
		i -= 1

func _update_bokeh(delta: float) -> void:
	for b in bokeh:
		b.pos.y -= b.spd * delta
		b.phase += delta * 0.6
		if b.pos.y < -b.r:
			b.pos.y = VIEW_H + b.r
			b.pos.x = rng.randf() * VIEW_W

# ------------------------------------------------------------
# Input
# ------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if state == State.GAMEOVER:
		if (event is InputEventScreenTouch and event.pressed) or \
		   (event is InputEventMouseButton and event.pressed):
			_new_game()
		return

	var pos := Vector2.ZERO
	var is_down := false
	var is_up := false
	var is_move := false

	if event is InputEventScreenTouch:
		pos = event.position
		is_down = event.pressed
		is_up = not event.pressed
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		is_down = event.pressed
		is_up = not event.pressed
	elif event is InputEventScreenDrag:
		pos = event.position
		is_move = true
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		pos = event.position
		is_move = true
	else:
		return

	if state != State.IDLE:
		return

	if is_down:
		var cell := _pixel_to_cell(pos)
		if cell.x >= 0:
			drag_start_cell = cell
			drag_start_pos = pos
			dragging = true
			selected = cell
	elif is_move and dragging:
		var d := pos - drag_start_pos
		if d.length() > cell_size * 0.45:
			var dir := Vector2i.ZERO
			if abs(d.x) > abs(d.y):
				dir = Vector2i(1, 0) if d.x > 0 else Vector2i(-1, 0)
			else:
				dir = Vector2i(0, 1) if d.y > 0 else Vector2i(0, -1)
			var target := drag_start_cell + dir
			if _in_bounds(target):
				_begin_swap(drag_start_cell, target, false)
			dragging = false
			drag_start_cell = Vector2i(-1, -1)
	elif is_up:
		dragging = false

func _pixel_to_cell(pos: Vector2) -> Vector2i:
	var lx := pos.x - board_x
	var ly := pos.y - board_y
	if lx < 0.0 or ly < 0.0:
		return Vector2i(-1, -1)
	var c := int(lx / cell_size)
	var r := int(ly / cell_size)
	if c < 0 or c >= COLS or r < 0 or r >= ROWS:
		return Vector2i(-1, -1)
	return Vector2i(c, r)

func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < COLS and cell.y >= 0 and cell.y < ROWS

# ------------------------------------------------------------
# Geometry helpers
# ------------------------------------------------------------
func _cell_center(c: int, r: int) -> Vector2:
	return Vector2(board_x + (float(c) + 0.5) * cell_size,
		board_y + (float(r) + 0.5) * cell_size)

func _enemy_line_y() -> float:
	return lerp(field_top + 36.0, field_bottom, clamp(enemy_advance, 0.0, 1.0))

# ------------------------------------------------------------
# Rendering
# ------------------------------------------------------------
func _draw() -> void:
	var shake := Vector2.ZERO
	if shake_amt > 0.0:
		shake = Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * shake_amt

	_draw_gradient_bg()
	_draw_bokeh()

	draw_set_transform(shake, 0.0, Vector2.ONE)

	_draw_battlefield()
	_draw_enemy_line()
	_draw_telegraph()
	_draw_wall()
	_draw_shield_flare()
	_draw_strike_shock()
	_draw_tracers()
	_draw_board_panel()
	_draw_gems()
	_draw_particles()
	_draw_nova_sweep()

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	_draw_danger_vignette()
	_draw_hud()
	_draw_flash()

	if state == State.GAMEOVER:
		_draw_game_over()

func _draw_gradient_bg() -> void:
	var steps := 24
	for i in range(steps):
		var f: float = float(i) / float(steps - 1)
		var col: Color = COL_BG_TOP.lerp(COL_BG_BOT, f)
		var y: float = f * VIEW_H
		draw_rect(Rect2(0, y, VIEW_W, VIEW_H / float(steps) + 1.0), col)

func _draw_bokeh() -> void:
	for b in bokeh:
		var a: float = 0.05 + 0.03 * sin(b.phase)
		var col: Color = b.col
		col.a = max(0.02, a)
		draw_circle(b.pos, b.r, col)

func _draw_battlefield() -> void:
	var fx := BOARD_MARGIN_X
	var fw: float = VIEW_W - 2.0 * BOARD_MARGIN_X
	var fh: float = field_bottom - field_top
	draw_rect(Rect2(fx, field_top, fw, fh), COL_FIELD, true)
	draw_rect(Rect2(fx, field_top, fw, 2.0), Color(0.5, 0.4, 0.9, 0.5), true)
	var vanish := Vector2(fx + fw * 0.5, field_top - 140.0)
	var n_lines := 7
	for i in range(n_lines + 1):
		var bx: float = fx + fw * float(i) / float(n_lines)
		var bottom := Vector2(bx, field_bottom)
		var topp: Vector2 = vanish.lerp(Vector2(bx, field_top), 0.85)
		draw_line(topp, bottom, Color(0.35, 0.30, 0.6, 0.18), 1.0)
	var bands := 6
	for i in range(bands):
		var f: float = float(i) / float(bands - 1)
		var y: float = lerp(field_top + 6.0, field_bottom - 4.0, f)
		var a: float = 0.05 + 0.10 * f
		draw_line(Vector2(fx, y), Vector2(fx + fw, y), Color(0.4, 0.35, 0.7, a), 1.0)

func _draw_enemy_line() -> void:
	var fx := BOARD_MARGIN_X
	var fw: float = VIEW_W - 2.0 * BOARD_MARGIN_X
	var y: float = _enemy_line_y()
	var n := COLS + 1
	var prox: float = clamp(enemy_advance, 0.0, 1.0)
	var base: Color = COL_ENEMY.lerp(Color(1.0, 0.15, 0.25), prox)
	var hitc: Color = base.lerp(COL_WHITE, line_hit_flash)
	var chev_w: float = fw / float(n)
	var ch: float = clamp(chev_w * 0.5, 10.0, 26.0)
	# while telegraphing, the LEAD chevron pulses red-hot
	var lead := int(n / 2)
	for i in range(n):
		var cx: float = fx + chev_w * (float(i) + 0.5)
		var c2: Color = hitc
		if tele_state == Tele.CHARGING and i == lead:
			var pulse: float = 0.5 + 0.5 * sin(sel_pulse * 14.0)
			c2 = hitc.lerp(COL_DANGER, 0.5 + 0.5 * pulse)
		draw_circle(Vector2(cx, y), ch * 1.4, Color(c2.r, c2.g, c2.b, 0.18))
		var pts := PackedVector2Array([
			Vector2(cx - ch, y - ch * 0.6),
			Vector2(cx, y + ch * 0.7),
			Vector2(cx + ch, y - ch * 0.6),
			Vector2(cx + ch, y - ch * 0.1),
			Vector2(cx, y + ch * 1.15),
			Vector2(cx - ch, y - ch * 0.1),
		])
		draw_colored_polygon(pts, c2)
	var hp_frac: float = clamp(enemy_line_hp / max(1.0, enemy_line_max_hp), 0.0, 1.0)
	var hbw: float = fw * 0.7
	var hbx: float = fx + (fw - hbw) * 0.5
	var hby: float = y - ch - 14.0
	draw_rect(Rect2(hbx, hby, hbw, 6.0), Color(0, 0, 0, 0.4), true)
	draw_rect(Rect2(hbx, hby, hbw * hp_frac, 6.0), base, true)

# The shrinking countdown ring around the lead chevron — the telegraph itself.
func _draw_telegraph() -> void:
	if tele_state != Tele.CHARGING:
		return
	var fx := BOARD_MARGIN_X
	var fw: float = VIEW_W - 2.0 * BOARD_MARGIN_X
	var n := COLS + 1
	var lead := int(n / 2)
	var chev_w: float = fw / float(n)
	var cx: float = fx + chev_w * (float(lead) + 0.5)
	var cy: float = _enemy_line_y()
	var center := Vector2(cx, cy)
	var frac: float = clamp(tele_timer / max(0.001, tele_total), 0.0, 1.0)
	# the ring shrinks (radius) AND closes (arc) as the strike nears
	var max_r := 54.0
	var r: float = lerp(18.0, max_r, frac)
	var danger_a: float = 0.55 + 0.35 * (1.0 - frac)
	# outer halo
	draw_arc(center, r + 4.0, 0.0, TAU, 40, Color(COL_DANGER.r, COL_DANGER.g, COL_DANGER.b, 0.15), 8.0)
	# the closing countdown arc (full at start, empty as it fires)
	draw_arc(center, r, -PI * 0.5, -PI * 0.5 + TAU * frac, 48, Color(1.0, 0.4, 0.4, danger_a), 4.0)
	# a tightening inner ring at fixed radius for "about to fire" read
	if frac < 0.4:
		var snap: float = 1.0 - frac / 0.4
		draw_arc(center, 16.0, 0.0, TAU, 28, Color(1, 1, 1, 0.4 + 0.5 * snap), 3.0)

func _draw_danger_vignette() -> void:
	if danger_vignette <= 0.0:
		return
	# red bleed from the TOP edge while a strike charges (screen-space, post-shake)
	var v: float = clamp(danger_vignette, 0.0, 1.0)
	var bands := 10
	var h := 220.0
	for i in range(bands):
		var f: float = float(i) / float(bands - 1)
		var a: float = (1.0 - f) * 0.30 * v
		var y: float = f * h
		draw_rect(Rect2(0, y, VIEW_W, h / float(bands) + 1.0),
			Color(COL_DANGER.r, COL_DANGER.g, COL_DANGER.b, a), true)

func _draw_wall() -> void:
	var fx := BOARD_MARGIN_X
	var fw: float = VIEW_W - 2.0 * BOARD_MARGIN_X
	var hp_frac: float = clamp(wall_hp / WALL_MAX_HP, 0.0, 1.0)
	var thick: float = lerp(5.0, 16.0, hp_frac)
	var bright: float = lerp(0.35, 1.0, hp_frac)
	var wc := Color(COL_WALL.r * bright, COL_WALL.g * bright, COL_WALL.b * bright, 1.0)
	if wall_pulse > 0.0:
		var pa: float = wall_pulse * 0.5
		draw_rect(Rect2(fx - 6, wall_y - thick - 6, fw + 12, thick + 12),
			Color(COL_WALL.r, COL_WALL.g, COL_WALL.b, pa), true)
	draw_rect(Rect2(fx, wall_y - thick - 4.0, fw, thick + 8.0),
		Color(wc.r, wc.g, wc.b, 0.25), true)
	draw_rect(Rect2(fx, wall_y - thick, fw, thick), wc, true)

# Big cyan shield-flare across the wall when a telegraphed strike is BLOCKED.
func _draw_shield_flare() -> void:
	if shield_flare <= 0.0:
		return
	var fx := BOARD_MARGIN_X
	var fw: float = VIEW_W - 2.0 * BOARD_MARGIN_X
	var a: float = clamp(shield_flare, 0.0, 1.0)
	# a dome of cyan absorbing the blow, rising above the wall
	var dome_h: float = lerp(0.0, 90.0, a)
	draw_rect(Rect2(fx - 10, wall_y - dome_h, fw + 20, dome_h),
		Color(COL_WALL.r, COL_WALL.g, COL_WALL.b, 0.28 * a), true)
	# bright crest line + expanding ring at the wall center
	draw_rect(Rect2(fx - 10, wall_y - dome_h, fw + 20, 4.0),
		Color(1, 1, 1, 0.8 * a), true)
	var center := Vector2(VIEW_W * 0.5, wall_y)
	draw_arc(center, lerp(20.0, 160.0, 1.0 - a), 0.0, TAU, 48,
		Color(COL_WALL.r, COL_WALL.g, COL_WALL.b, a * 0.7), 5.0)

# Red shock-ring at the wall when an UNDEFENDED strike craters it.
func _draw_strike_shock() -> void:
	if strike_shock <= 0.0:
		return
	var a: float = clamp(strike_shock, 0.0, 1.0)
	var center := Vector2(VIEW_W * 0.5, wall_y)
	draw_arc(center, lerp(10.0, 220.0, 1.0 - a), 0.0, TAU, 48,
		Color(COL_DANGER.r, COL_DANGER.g, COL_DANGER.b, a), 6.0)

func _draw_tracers() -> void:
	for tr in tracers:
		var a: float = clamp(tr.life / tr.max_life, 0.0, 1.0)
		var col: Color = tr.col
		col.a = a
		draw_line(tr.from, tr.to, Color(col.r, col.g, col.b, a * 0.4), 7.0)
		draw_line(tr.from, tr.to, Color(1, 1, 1, a), 2.0)
		draw_circle(tr.to, 10.0 * a, Color(1, 1, 1, a * 0.8))

func _draw_board_panel() -> void:
	var w: float = cell_size * float(COLS)
	var h: float = cell_size * float(ROWS)
	var pad := 10.0
	draw_rect(Rect2(board_x - pad, board_y - pad, w + 2 * pad, h + 2 * pad), COL_BOARD, true)
	for r in range(ROWS):
		for c in range(COLS):
			var p := Vector2(board_x + c * cell_size, board_y + r * cell_size)
			draw_rect(Rect2(p.x + 3, p.y + 3, cell_size - 6, cell_size - 6), COL_CELL, true)

func _draw_gems() -> void:
	for r in range(ROWS):
		for c in range(COLS):
			var t: int = board[r][c]
			if t == EMPTY:
				continue
			var center := _cell_center(c, r)
			center += _swap_visual_offset(c, r)
			center.y += cell_offset[r][c]

			var scale := 1.0
			var pop: float = cell_pop[r][c]
			if pop > 0.0:
				var pf: float = pop / POP_TIME
				scale = 1.0 + (1.0 - pf) * 0.6

			if selected == Vector2i(c, r) and state == State.IDLE:
				scale *= 1.0 + 0.10 * sin(sel_pulse * 9.0)

			var radius: float = cell_size * 0.36 * scale
			var col: Color = GEM_COLORS[t]

			var step: float = radius * 0.32
			for i in range(4):
				var hc := Color(col.r, col.g, col.b, 0.12 - i * 0.025)
				if hc.a > 0.0:
					draw_circle(center, radius + float(i) * step, hc)

			_draw_gem_shape(t, center, radius, col)

			draw_circle(center - Vector2(radius * 0.28, radius * 0.28), radius * 0.18,
				Color(1, 1, 1, 0.35))

			if pop > 0.0:
				var fa: float = (pop / POP_TIME) * 0.8
				draw_circle(center, radius * 0.8, Color(1, 1, 1, fa))

func _draw_gem_shape(t: int, center: Vector2, radius: float, col: Color) -> void:
	match t:
		0:
			var pts := PackedVector2Array([
				center + Vector2(0, -radius),
				center + Vector2(radius * 0.9, radius * 0.7),
				center + Vector2(-radius * 0.9, radius * 0.7),
			])
			draw_colored_polygon(pts, col)
		1:
			var s: float = radius * 1.5
			draw_rect(Rect2(center.x - s * 0.5, center.y - s * 0.5, s, s), col, true)
		2:
			draw_circle(center, radius, col)
			draw_arc(center, radius, 0, TAU, 32, Color(1, 1, 1, 0.30), 2.0)
		3:
			var pts2 := PackedVector2Array([
				center + Vector2(0, -radius),
				center + Vector2(radius, 0),
				center + Vector2(0, radius),
				center + Vector2(-radius, 0),
			])
			draw_colored_polygon(pts2, col)
		4:
			var pts3 := PackedVector2Array()
			for i in range(6):
				var a: float = PI / 6.0 + float(i) * (TAU / 6.0)
				pts3.append(center + Vector2(cos(a), sin(a)) * radius)
			draw_colored_polygon(pts3, col)

func _swap_visual_offset(c: int, r: int) -> Vector2:
	if state != State.SWAPPING:
		return Vector2.ZERO
	var cell := Vector2i(c, r)
	var f: float = clamp(swap_t / SWAP_TIME, 0.0, 1.0)
	f = f * f * (3.0 - 2.0 * f)
	if cell == swap_a:
		var dest := _cell_center(swap_b.x, swap_b.y)
		var src := _cell_center(swap_a.x, swap_a.y)
		return (dest - src) * f
	elif cell == swap_b:
		var dest2 := _cell_center(swap_a.x, swap_a.y)
		var src2 := _cell_center(swap_b.x, swap_b.y)
		return (dest2 - src2) * f
	return Vector2.ZERO

func _draw_particles() -> void:
	for p in particles:
		var a: float = clamp(p.life / p.max_life, 0.0, 1.0)
		var col: Color = p.col
		col.a = a
		draw_circle(p.pos, p.size * a, col)

func _draw_nova_sweep() -> void:
	if nova_flash <= 0.0:
		return
	var a: float = nova_flash * 0.7
	draw_rect(Rect2(0, field_top, VIEW_W, field_bottom - field_top),
		Color(1, 1, 1, a * 0.6), true)
	var sweep_y: float = lerp(field_bottom, field_top, nova_flash)
	draw_rect(Rect2(0, sweep_y - 8.0, VIEW_W, 16.0), Color(1, 1, 1, a), true)

func _draw_flash() -> void:
	if flash_alpha > 0.0:
		draw_rect(Rect2(0, 0, VIEW_W, VIEW_H), Color(1, 1, 1, flash_alpha * 0.35))

# ------------------------------------------------------------
# HUD
# ------------------------------------------------------------
func _get_font() -> Font:
	if ThemeDB and ThemeDB.fallback_font:
		return ThemeDB.fallback_font
	return null

func _draw_text(font: Font, pos: Vector2, txt: String, size: int, col: Color) -> void:
	if font == null:
		return
	draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

func _draw_hud() -> void:
	var font := _get_font()

	# WALL HP (top-left) with a scale-pop when it jumps
	var wall_frac: float = clamp(wall_hp / WALL_MAX_HP, 0.0, 1.0)
	_draw_text(font, Vector2(34, 40), "WALL", 22, Color(1, 1, 1, 0.6))
	var wcol := Color(0.95, 0.25, 0.25)
	if wall_frac > 0.5:
		wcol = COL_WALL
	elif wall_frac > 0.25:
		wcol = Color(1.0, 0.74, 0.22)
	var hp_size: int = int(38 * (1.0 + wall_hp_pop * 0.5))
	_draw_text(font, Vector2(34, 78), str(int(round(wall_hp))), hp_size, wcol)
	var wbx := 34.0
	var wby := 86.0
	var wbw := 200.0
	draw_rect(Rect2(wbx, wby, wbw, 8.0), Color(0, 0, 0, 0.4), true)
	draw_rect(Rect2(wbx, wby, wbw * wall_frac, 8.0), wcol, true)

	# NOVA charge (top-right)
	_draw_text(font, Vector2(VIEW_W - 150, 40), "NOVA", 22, Color(1, 1, 1, 0.6))
	var nbx := VIEW_W - 234.0
	var nby := 86.0
	var nbw := 200.0
	draw_rect(Rect2(nbx, nby, nbw, 8.0), Color(0, 0, 0, 0.4), true)
	var ncol := Color(0.9, 0.85, 1.0)
	draw_rect(Rect2(nbx, nby, nbw * nova_charge, 8.0), ncol, true)
	var ring_c := Vector2(VIEW_W - 50, 52)
	var ring_r: float = 16.0 + 3.0 * sin(sel_pulse * 6.0) * nova_charge
	var ra: float = 0.3 + 0.6 * nova_charge
	draw_arc(ring_c, ring_r, 0, TAU * nova_charge, 28, Color(1, 1, 1, ra), 3.0)

	# SCORE (top-center)
	_draw_text(font, Vector2(VIEW_W * 0.5 - 60, 40), "SCORE", 20, Color(1, 1, 1, 0.5))
	_draw_text(font, Vector2(VIEW_W * 0.5 - 50, 78), str(score), 30, COL_WHITE)

	# TELEGRAPH countdown — large, high-contrast, center, only while charging.
	if tele_state == Tele.CHARGING:
		var secs: float = max(0.0, tele_timer)
		var warn: String = "BLOCK! " + ("%0.1f" % secs)
		var pulse: float = 0.6 + 0.4 * sin(sel_pulse * 12.0)
		var tcol := Color(1.0, 0.35, 0.35, 0.7 + 0.3 * pulse)
		_draw_text(font, Vector2(VIEW_W * 0.5 - 110, board_y - 86.0), warn, 40, tcol)
		_draw_text(font, Vector2(VIEW_W * 0.5 - 150, board_y - 50.0),
			"match BLUE to shield", 22, Color(1, 1, 1, 0.7))

	# combo pulse near the grid when active
	if combo_pulse > 0.0 and combo_display >= 2:
		var pscale: float = 1.0 + combo_pulse * 0.6
		var size: int = int(40 * pscale)
		var ccol: Color = GEM_COLORS[combo_display % NUM_TYPES]
		ccol.a = clamp(combo_pulse + 0.3, 0.0, 1.0)
		_draw_text(font, Vector2(VIEW_W * 0.5 - 90, board_y - 16.0),
			"x" + str(combo_display) + " COMBO", size, ccol)

func _draw_game_over() -> void:
	draw_rect(Rect2(0, 0, VIEW_W, VIEW_H), Color(0.0, 0.0, 0.05, 0.65))
	var font := _get_font()
	var pulse: float = 1.0 + 0.05 * sin(game_over_t * 4.0)
	_draw_text(font, Vector2(VIEW_W * 0.5 - 160, VIEW_H * 0.40), "WALL BREACHED", int(48 * pulse), Color(1, 0.3, 0.35))
	_draw_text(font, Vector2(VIEW_W * 0.5 - 120, VIEW_H * 0.40 + 70), "Score: " + str(score), 34, COL_WALL)
	_draw_text(font, Vector2(VIEW_W * 0.5 - 150, VIEW_H * 0.40 + 116), "Enemies destroyed: " + str(enemies_destroyed), 24, Color(0.98, 0.5, 0.8))
	_draw_text(font, Vector2(VIEW_W * 0.5 - 150, VIEW_H * 0.40 + 152), "Strikes blocked: " + str(strikes_blocked), 24, COL_WALL)
	if sin(game_over_t * 3.0) > -0.3:
		_draw_text(font, Vector2(VIEW_W * 0.5 - 140, VIEW_H * 0.40 + 220), "Tap to defend again", 28, Color(1, 1, 1, 0.8))
