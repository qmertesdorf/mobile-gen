extends SceneTree

# Headless self-test for Aegis Grid II (match3-survival-0002).
# Drives Main.gd's state directly (no real input, no frame waiting) and asserts
# the OBSERVABLE state changes a human would check on this hybrid:
#   1. a known 3-in-a-row swap clears those cells (match path fires),
#   2. an OFFENSE (red) match lowers the enemy line's HP,
#   3. a DEFENSE (blue) match raises wall HP,
#   4. the FORCING FUNCTION: a blue match during a telegraph blocks the strike
#      (defended -> wall does NOT crater), while no blue -> wall DOES crater,
#   5. _game_over() fires when wall HP is forced to 0.
# Prints exactly "SELFTEST OK" (exit 0) or "SELFTEST FAIL: <reason>" (exit != 0).

const MainScript := preload("res://Main.gd")

func _fail(reason: String) -> void:
	print("SELFTEST FAIL: " + reason)
	quit(1)

func _ok() -> void:
	print("SELFTEST OK")
	quit(0)

# Build a Main instance with geometry + a fresh game, but a fully-controlled board.
# NOTE: in a SceneTree script, add_child() defers _ready(), so we drive the same
# setup _ready() does explicitly to guarantee board/geometry exist synchronously.
func _make() -> Node2D:
	var m: Node2D = MainScript.new()
	get_root().add_child(m)
	m.rng.randomize()
	m._compute_geometry()
	m._init_bokeh()
	m._new_game()
	return m

# Force a deterministic board with no incidental matches (a checker of 3 types).
func _clear_board(m) -> void:
	for r in range(m.ROWS):
		for c in range(m.COLS):
			m.board[r][c] = (c + r) % 3 + 2   # only neutral types 2,3,4
			m.cell_offset[r][c] = 0.0
			m.cell_pop[r][c] = 0.0

func _init() -> void:
	# ---- Test 1: a known 3-in-a-row swap clears cells ----
	var m = _make()
	_clear_board(m)
	# Lay a near-row of RED at row 3, cols 0,1, with the third red one cell below
	# at (col2,row4). Swapping (col2,row4)<->(col2,row3) completes a horizontal 3.
	m.board[3][0] = m.T_RED
	m.board[3][1] = m.T_RED
	m.board[3][2] = 2          # filler at the swap-target
	m.board[4][2] = m.T_RED    # red sitting just below
	# sanity: no match before the swap
	if not m._find_matches().is_empty():
		_fail("board had a match before the test swap")
		return
	m.state = m.State.IDLE
	m._begin_swap(Vector2i(2, 3), Vector2i(2, 4), false)
	# run the swap animation to completion deterministically
	var guard := 0
	while m.state == m.State.SWAPPING and guard < 200:
		m._update_swap(1.0)   # >= SWAP_TIME so it resolves in one step
		guard += 1
	# after the swap commits, a match should have been found -> RESOLVING
	if m.state != m.State.RESOLVING:
		_fail("valid 3-swap did not enter RESOLVING (state=%d)" % m.state)
		return
	# drive the resolve loop: phase0 pop -> clear cells -> gravity -> rescan
	guard = 0
	var saw_empty := false
	while m.state == m.State.RESOLVING and guard < 500:
		m._update_resolve(1.0)
		# right after phase0 commits, the three matched cells become EMPTY
		# (then refilled); detect that the clear path actually ran via combo>0
		guard += 1
	if m.combo <= 0:
		_fail("3-in-a-row swap never incremented combo / cleared")
		return
	m.queue_free()

	# ---- Test 2: a RED (offense) match lowers enemy line HP ----
	m = _make()
	_clear_board(m)
	var hp_before: float = m.enemy_line_hp
	# directly apply a red match group of 3 (state still present on board)
	m.board[2][0] = m.T_RED
	m.board[2][1] = m.T_RED
	m.board[2][2] = m.T_RED
	m.combo = 1
	m._apply_match_effects([Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2)])
	if not (m.enemy_line_hp < hp_before):
		_fail("red match did not lower enemy_line_hp (%f -> %f)" % [hp_before, m.enemy_line_hp])
		return
	m.queue_free()

	# ---- Test 3: a BLUE (defense) match raises wall HP ----
	m = _make()
	_clear_board(m)
	m.wall_hp = 40.0
	var wall_before: float = m.wall_hp
	m.board[2][0] = m.T_BLUE
	m.board[2][1] = m.T_BLUE
	m.board[2][2] = m.T_BLUE
	m.combo = 1
	m._apply_match_effects([Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2)])
	if not (m.wall_hp > wall_before):
		_fail("blue match did not raise wall_hp (%f -> %f)" % [wall_before, m.wall_hp])
		return
	m.queue_free()

	# ---- Test 4: FORCING FUNCTION — blue during telegraph blocks the strike ----
	# 4a: telegraphing + blue match landed -> strike is DEFENDED, wall barely chipped.
	m = _make()
	_clear_board(m)
	m.wall_hp = 80.0
	m._begin_telegraph()
	if m.tele_state != m.Tele.CHARGING:
		_fail("_begin_telegraph did not enter CHARGING")
		return
	# land a blue match while charging
	m.board[2][0] = m.T_BLUE
	m.board[2][1] = m.T_BLUE
	m.board[2][2] = m.T_BLUE
	m.combo = 1
	m._apply_match_effects([Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2)])
	if not m.blue_defended:
		_fail("blue match during telegraph did not set blue_defended")
		return
	var hp_pre_def: float = m.wall_hp
	m._fire_strike(0)
	# defended: only the small STRIKE_CHIP, far less than the full crater
	var def_loss: float = hp_pre_def - m.wall_hp
	if def_loss > m.STRIKE_CHIP + 0.01:
		_fail("defended strike took too much HP (%f, expected <= chip %f)" % [def_loss, m.STRIKE_CHIP])
		return
	if m.strikes_blocked != 1:
		_fail("defended strike did not increment strikes_blocked")
		return
	m.queue_free()

	# 4b: telegraphing + NO blue match -> strike CRATERS the wall.
	m = _make()
	_clear_board(m)
	m.wall_hp = 80.0
	m._begin_telegraph()
	var hp_pre_crater: float = m.wall_hp
	m._fire_strike(0)
	var crater_loss: float = hp_pre_crater - m.wall_hp
	if crater_loss < m.STRIKE_DAMAGE - 0.01:
		_fail("undefended strike did not crater the wall (loss=%f, expected >= %f)" % [crater_loss, m.STRIKE_DAMAGE])
		return
	m.queue_free()

	# ---- Test 5: _game_over() fires when wall HP forced to 0 ----
	m = _make()
	_clear_board(m)
	m.state = m.State.IDLE
	m.wall_hp = 0.5
	m.enemy_advance = 1.0          # at the wall -> breach DPS will zero it
	m._update_survival(1.0)        # one fat tick drains the last HP
	if m.wall_hp != 0.0:
		_fail("wall_hp not clamped to 0 after lethal breach (%f)" % m.wall_hp)
		return
	if m.state != m.State.GAMEOVER:
		_fail("_game_over did not fire when wall HP hit 0 (state=%d)" % m.state)
		return
	m.queue_free()

	_ok()
