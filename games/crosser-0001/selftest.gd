extends SceneTree

# ============================================================
# selftest.gd — headless logic assertions for crosser-0001
# Run: godot --headless --path games/crosser-0001/ --script res://selftest.gd
# Expects: SELFTEST OK on stdout, exit 0.
# ============================================================

func _init() -> void:
	var game: Node2D = load("res://Main.tscn").instantiate()
	get_root().add_child(game)
	# _ready() is deferred after add_child — call init path directly.
	game._start_game()

	var failures: Array[String] = []

	# ----------------------------------------------------------
	# Test 1: hopping forward across all lanes increments score
	#         and resets hero to the bottom.
	# ----------------------------------------------------------
	var score_before: int = game.score
	# Walk hero forward through all hazard lanes to the goal
	for _i in range(game.NUM_HAZARD_LANES + 1):
		game._hop(1)
	# Should have triggered _on_crossing, resetting hero to lane 0
	if game.score <= score_before:
		failures.append("full crossing did not increment score (before=%d after=%d)" % [score_before, game.score])
	if game.hero_lane != 0:
		failures.append("after crossing, hero_lane should be 0 (got %d)" % game.hero_lane)

	# ----------------------------------------------------------
	# Test 2: speed-cross streak — quick crossing awards bonus pts
	# ----------------------------------------------------------
	game._start_game()
	# First crossing: zero cross_timer means it qualifies as quick
	game.cross_timer = 0.0
	game.backtrack_count = 0
	for _i in range(game.NUM_HAZARD_LANES + 1):
		game._hop(1)
	# streak_count should have ticked up after first crossing
	if game.streak_count < 1:
		failures.append("quick crossing did not increment streak_count (got %d)" % game.streak_count)

	# ----------------------------------------------------------
	# Test 3: slow / backtracked crossing resets streak
	# ----------------------------------------------------------
	game._start_game()
	# Make first crossing quick to build streak
	game.cross_timer = 0.0
	game.backtrack_count = 0
	for _i in range(game.NUM_HAZARD_LANES + 1):
		game._hop(1)
	var streak_after_first: int = game.streak_count
	# Second crossing: simulate slow (cross_timer > STREAK_TIME)
	game.cross_timer = game.STREAK_TIME + 1.0
	for _i in range(game.NUM_HAZARD_LANES + 1):
		game._hop(1)
	if game.streak_count != 0:
		failures.append("slow crossing did not reset streak_count (got %d, was %d)" % [game.streak_count, streak_after_first])

	# ----------------------------------------------------------
	# Test 4: hazard overlap triggers game-over (alive = false)
	# ----------------------------------------------------------
	game._start_game()
	# Place hero in lane 1 (first hazard lane)
	game.hero_lane = 1
	game.hero_col  = 0
	# Force a hazard to overlap exactly the hero in that lane
	var lane_entry: Dictionary = game.lanes[0]  # lanes[0] corresponds to hero_lane 1
	lane_entry["hazards"] = [{"x": 0.0, "w": game.CELL * 2.0}]
	game._check_collision()
	if game.alive:
		failures.append("hazard overlap did not trigger game-over (alive still true)")

	# ----------------------------------------------------------
	# Test 5: restart resets all state
	# ----------------------------------------------------------
	game.score         = 9999
	game.streak_count  = 7
	game.tier          = 4
	game.cross_timer   = 100.0
	game._start_game()
	if game.score != 0:
		failures.append("restart did not reset score (got %d)" % game.score)
	if game.streak_count != 0:
		failures.append("restart did not reset streak_count (got %d)" % game.streak_count)
	if game.tier != 0:
		failures.append("restart did not reset tier (got %d)" % game.tier)
	if not game.alive:
		failures.append("restart left game not alive")
	if game.hero_lane != 0:
		failures.append("restart did not place hero at lane 0 (got %d)" % game.hero_lane)

	# ----------------------------------------------------------
	# Test 6: difficulty ramps after RAMP_EVERY_N_CROSSINGS
	# ----------------------------------------------------------
	game._start_game()
	var n: int = game.RAMP_EVERY_N_CROSSINGS
	for _c in range(n):
		game.cross_timer = 0.0
		for _i in range(game.NUM_HAZARD_LANES + 1):
			game._hop(1)
	if game.tier < 1:
		failures.append("difficulty did not ramp after %d crossings (tier=%d)" % [n, game.tier])

	# ----------------------------------------------------------
	# Test 7: sidestep changes hero_col and is clamped
	# ----------------------------------------------------------
	game._start_game()
	var start_col: int = game.hero_col
	game._sidestep(1)
	var expected_col: int = min(start_col + 1, game.NUM_CELLS_X - 1)
	if game.hero_col != expected_col:
		failures.append("sidestep right moved to wrong col (expected %d got %d)" % [expected_col, game.hero_col])
	# Sidestep past left edge should clamp
	game.hero_col = 0
	game._sidestep(-1)
	if game.hero_col != 0:
		failures.append("sidestep left past edge did not clamp (got %d)" % game.hero_col)

	# ----------------------------------------------------------
	# Report
	# ----------------------------------------------------------
	if failures.size() == 0:
		print("SELFTEST OK")
		quit(0)
	else:
		for f in failures:
			print("SELFTEST FAIL: " + f)
		quit(1)
