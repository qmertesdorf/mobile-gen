extends Node2D

# Neon Dash — self-contained endless runner.
# All rendering via _draw(); collision via Rect2 AABB. No physics bodies,
# no child scene instancing, so it runs cleanly under --headless.

const VIEW_W: float = 720.0
const VIEW_H: float = 1280.0

# Visual palette (art direction).
const COLOR_BG: Color = Color("#0a0a12")
const COLOR_PLAYER: Color = Color("#22e6ff")
const COLOR_OBSTACLE_A: Color = Color("#ff3df0")
const COLOR_OBSTACLE_B: Color = Color("#ffe14d")
const COLOR_GROUND: Color = Color("#22e6ff")

# Ground / player geometry.
const GROUND_Y: float = 1080.0
const PLAYER_X: float = 140.0
const PLAYER_SIZE: float = 64.0

# Physics tuning.
const GRAVITY: float = 2600.0
const JUMP_VELOCITY: float = -1150.0

# Scroll / spawn tuning.
const BASE_SCROLL_SPEED: float = 360.0
const MAX_SCROLL_SPEED: float = 1100.0
const SPEED_RAMP: float = 7.0        # speed added per second survived
const SPAWN_MIN: float = 0.9
const SPAWN_MAX: float = 1.6

# Game state.
var player_y: float = GROUND_Y - PLAYER_SIZE
var player_vy: float = 0.0
var on_ground: bool = true

var obstacles: Array = []           # each: { "rect": Rect2, "color": Color }
var spawn_timer: float = 0.0
var scroll_speed: float = BASE_SCROLL_SPEED

var score: float = 0.0
var best_score: int = 0
var game_over: bool = false

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _font: Font = null
var _font_size: int = 32


func _ready() -> void:
	_rng.randomize()
	# Headless-safe default font lookup; guard so a null never crashes _draw().
	if ThemeDB.fallback_font != null:
		_font = ThemeDB.fallback_font
		_font_size = ThemeDB.fallback_font_size
	_reset()


func _reset() -> void:
	player_y = GROUND_Y - PLAYER_SIZE
	player_vy = 0.0
	on_ground = true
	obstacles.clear()
	spawn_timer = _rng.randf_range(SPAWN_MIN, SPAWN_MAX)
	scroll_speed = BASE_SCROLL_SPEED
	score = 0.0
	game_over = false
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	var tapped: bool = false
	if event is InputEventScreenTouch and event.pressed:
		tapped = true
	elif event is InputEventMouseButton and event.pressed:
		tapped = true
	if tapped:
		_on_tap()


func _on_tap() -> void:
	if game_over:
		_reset()
		return
	if on_ground:
		player_vy = JUMP_VELOCITY
		on_ground = false


func _process(delta: float) -> void:
	if game_over:
		queue_redraw()
		return

	# Score climbs with distance/time.
	score += delta * 60.0
	best_score = max(best_score, int(score))

	# Ramp difficulty.
	scroll_speed = min(MAX_SCROLL_SPEED, scroll_speed + SPEED_RAMP * delta)

	# Player physics: gravity + ground collision.
	player_vy += GRAVITY * delta
	player_y += player_vy * delta
	var floor_y: float = GROUND_Y - PLAYER_SIZE
	if player_y >= floor_y:
		player_y = floor_y
		player_vy = 0.0
		on_ground = true

	# Obstacle spawning.
	spawn_timer -= delta
	if spawn_timer <= 0.0:
		_spawn_obstacle()
		spawn_timer = _rng.randf_range(SPAWN_MIN, SPAWN_MAX)

	# Advance + despawn obstacles, check collision.
	var player_rect: Rect2 = Rect2(PLAYER_X, player_y, PLAYER_SIZE, PLAYER_SIZE)
	var kept: Array = []
	for ob in obstacles:
		var r: Rect2 = ob["rect"]
		r.position.x -= scroll_speed * delta
		ob["rect"] = r
		if r.position.x + r.size.x < 0.0:
			continue  # off-screen left
		if player_rect.intersects(r):
			_trigger_game_over()
		kept.append(ob)
	obstacles = kept

	queue_redraw()


func _spawn_obstacle() -> void:
	var h: float = _rng.randf_range(70.0, 200.0)
	var w: float = _rng.randf_range(40.0, 80.0)
	var color: Color = COLOR_OBSTACLE_A if _rng.randf() < 0.5 else COLOR_OBSTACLE_B
	var rect: Rect2 = Rect2(VIEW_W + w, GROUND_Y - h, w, h)
	obstacles.append({ "rect": rect, "color": color })


func _trigger_game_over() -> void:
	game_over = true
	best_score = max(best_score, int(score))


func _draw() -> void:
	# Background.
	draw_rect(Rect2(0.0, 0.0, VIEW_W, VIEW_H), COLOR_BG, true)

	# Glowing ground line (drawn as a couple of overlaid lines for subtle glow).
	draw_line(Vector2(0.0, GROUND_Y), Vector2(VIEW_W, GROUND_Y), COLOR_GROUND * Color(1, 1, 1, 0.35), 8.0)
	draw_line(Vector2(0.0, GROUND_Y), Vector2(VIEW_W, GROUND_Y), COLOR_GROUND, 3.0)

	# Obstacles.
	for ob in obstacles:
		var r: Rect2 = ob["rect"]
		var c: Color = ob["color"]
		draw_rect(Rect2(r.position - Vector2(3, 3), r.size + Vector2(6, 6)), c * Color(1, 1, 1, 0.3), true)
		draw_rect(r, c, true)

	# Player square (with subtle glow halo).
	var p: Rect2 = Rect2(PLAYER_X, player_y, PLAYER_SIZE, PLAYER_SIZE)
	draw_rect(Rect2(p.position - Vector2(4, 4), p.size + Vector2(8, 8)), COLOR_PLAYER * Color(1, 1, 1, 0.3), true)
	draw_rect(p, COLOR_PLAYER, true)

	# Score text (guarded — null font is skipped, score still tracked).
	if _font != null:
		draw_string(_font, Vector2(40.0, 80.0), "SCORE %d" % int(score), HORIZONTAL_ALIGNMENT_LEFT, -1.0, _font_size, COLOR_PLAYER)
		if game_over:
			draw_string(_font, Vector2(40.0, 140.0), "GAME OVER - TAP TO RESTART", HORIZONTAL_ALIGNMENT_LEFT, -1.0, _font_size, COLOR_OBSTACLE_A)
