extends Node2D

# Main.gd — root controller for Arcane Duel.
# Owns the game flow state machine. ALL rules live in RunController + CombatState.
# This script ONLY reads state and calls engine methods — zero damage math here.
#
# States:
#   COMBAT   — active fight
#   REWARD   — pick-1-of-3 card reward after winning a fight
#   REST     — rest node (auto-handled, no player input needed)
#   WIN      — run complete
#   LOSE     — player HP reached 0
#   MAP      — branching run map; player taps an available next node
#   EVENT    — event node (routed in a later task; auto-skipped for now)
#   SHOP     — shop node (routed in a later task; auto-skipped for now)
#   CAMPFIRE — campfire node (routed in a later task; auto-heals for now)
#
# Flow: map → (combat → reward) | (auto-resolve placeholder) → map → … → boss → WIN.
# Main is a ROUTER: after each node resolves it shows the map; when a node is chosen
# it dispatches to the right screen.

const RunController := preload("res://RunController.gd")

enum State { COMBAT, REWARD, REST, WIN, LOSE, MAP, EVENT, SHOP, CAMPFIRE }

# Run seed — change to vary the run
const RUN_SEED: int = 42

@onready var _view: Node2D = $CombatView
@onready var _map_view: Node2D = $MapView
@onready var _shop_view: Node2D = $ShopView
@onready var _event_view: Node2D = $EventView

var _run: RunController
var _combat     # CombatState
var _state: State = State.COMBAT
var _rewards: Array = []
var _active_shop: Dictionary = {}
var _active_event: Dictionary = {}

# Juice: block input while animations are running so fast taps don't desync
var _animating: bool = false


func _ready() -> void:
	_start_run()


func _start_run() -> void:
	_run = RunController.new()
	_run.start_run(RUN_SEED)
	_combat = null
	_rewards = []
	_animating = false
	# The floor-0 entry is a combat — enter it directly.
	_enter_node()


# ─── Node-type router ─────────────────────────────────────────────────────────

func _show_map() -> void:
	_state = State.MAP
	_combat = null
	_view.visible = false
	if _shop_view:
		_shop_view.visible = false
	if _event_view:
		_event_view.visible = false
	_map_view.visible = true
	_map_view.refresh(_run.map, _run.current_node_id(), _run.available_next())


func _enter_node() -> void:
	# Dispatch on the CURRENT node's type (already chosen on the map).
	if _run.is_run_complete():
		_state = State.WIN; _map_view.visible = false; _view.visible = true; _refresh(); return
	if _run.is_run_lost():
		_state = State.LOSE; _map_view.visible = false; _view.visible = true; _refresh(); return
	var ntype: String = _run.current_node().get("type", "")
	match ntype:
		"combat", "elite", "boss":
			_map_view.visible = false
			if _shop_view:
				_shop_view.visible = false
			if _event_view:
				_event_view.visible = false
			_view.visible = true
			_combat = _run.start_node_combat()
			_view.capture_enemy_max_hp(_combat.enemy.get("hp", 1))
			_state = State.COMBAT
			_refresh()
		"event":
			_view.visible = false; _map_view.visible = false
			_event_view.visible = true
			_active_event = _run.roll_event()
			_state = State.EVENT
			_event_view.refresh(_active_event)
		"shop":
			_view.visible = false; _map_view.visible = false
			_shop_view.visible = true
			_active_shop = _run.roll_shop()
			_state = State.SHOP
			_shop_view.refresh(_active_shop, _run.gold, _run.deck)
		"campfire":
			# Placeholder until Task 13: auto-heal a little, then back to the map.
			_run.take_rest("heal")
			_advance_to_map()
		_:
			# event / treasure placeholders until their tasks: auto-skip.
			_advance_to_map()


func _advance_to_map() -> void:
	if _run.is_on_boss() and _run.is_run_complete():
		_state = State.WIN; _map_view.visible = false; _view.visible = true; _refresh(); return
	_show_map()


func _refresh() -> void:
	if _view == null:
		return
	var relics: Array = _run.relics if _run != null else []
	_view.refresh(_combat, _state as int, _rewards, relics)


# ─── Input routing ────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	# Block input while juice animations are running
	if _animating:
		return

	var pressed: bool = false
	var pos: Vector2 = Vector2.ZERO

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			pressed = true
			pos = mb.position
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			pressed = true
			pos = st.position

	if not pressed:
		return

	match _state:
		State.COMBAT:
			_handle_combat_tap(pos)
		State.REWARD:
			_handle_reward_tap(pos)
		State.MAP:
			_handle_map_tap(pos)
		State.SHOP:
			_handle_shop_tap(pos)
		State.EVENT:
			_handle_event_tap(pos)
		State.WIN, State.LOSE:
			# Tap anywhere to restart
			_start_run()
		_:
			pass


func _handle_map_tap(pos: Vector2) -> void:
	for nid in _run.available_next():
		if _map_view.get_node_rect(nid).has_point(pos):
			_run.choose_next(nid)
			_enter_node()
			return


func _handle_combat_tap(pos: Vector2) -> void:
	if _combat == null:
		return

	# End Turn button?
	if _view.get_end_turn_rect().has_point(pos):
		_animating = true
		var events: Array = _combat.end_turn()
		_view.animate_events(events, func():
			_animating = false
			_check_combat_outcome()
		)
		return

	# Card in hand?
	var hand: Array = _combat.hand
	var total: int = hand.size()
	for i in total:
		var rect: Rect2 = _view.get_card_rect(i, total)
		if rect.has_point(pos):
			_try_play_card(i)
			return


func _try_play_card(idx: int) -> void:
	if _combat == null:
		return
	var hand: Array = _combat.hand
	if idx < 0 or idx >= hand.size():
		return
	var card_id: String = hand[idx]
	var card_data: Dictionary = preload("res://data/CardDB.gd").card(card_id)
	var cost: int = card_data.get("cost", 0)
	if cost > _combat.mana:
		return   # Not affordable — ignore tap

	# Capture card rect before removing it from hand
	var total: int = _combat.hand.size()
	var card_rect: Rect2 = _view.get_card_rect(idx, total)

	_animating = true
	var events: Array = _combat.play_card(idx)
	_view.selected_card_idx = -1
	_view.animate_play_card(card_rect, events, func():
		_animating = false
		_check_combat_outcome()
	)


func _check_combat_outcome() -> void:
	if _combat == null:
		return

	if _combat.is_won():
		var node: Dictionary = _run.current_node()
		var ntype: String = node.get("type", "")
		if ntype == "boss":
			_run.on_boss_defeated()
			# Play death dissolve then show WIN
			_animating = true
			_view.animate_enemy_death(func():
				_animating = false
				_state = State.WIN
				_refresh()
			)
			return
		# Non-boss win: death anim then reward
		_animating = true
		_view.animate_enemy_death(func():
			_animating = false
			_run.sync_hp_from_combat(_combat)
			_run.grant_combat_gold(_run.current_enemy_id)
			_rewards = _run.offer_rewards()
			_state = State.REWARD
			_refresh()
		)
		return

	if _combat.is_lost():
		_state = State.LOSE
		_refresh()
		return

	# Still ongoing
	_refresh()


func _handle_reward_tap(pos: Vector2) -> void:
	# Skip button?
	if _view.get_skip_rect().has_point(pos):
		_run.choose_reward("")   # empty = skip
		_rewards = []
		# Reward done → back to the map to pick the next node.
		_show_map()
		return

	# One of the 3 reward cards?
	for i in 3:
		if i >= _rewards.size():
			break
		var rect: Rect2 = _view.get_reward_card_rect(i)
		if rect.has_point(pos):
			_run.choose_reward(_rewards[i])
			_rewards = []
			# Reward done → back to the map to pick the next node.
			_show_map()
			return


func _handle_shop_tap(pos: Vector2) -> void:
	if _shop_view.get_leave_rect().has_point(pos):
		_show_map(); return
	for i in 3:
		if _shop_view.get_card_rect(i).has_point(pos):
			_run.buy_card(_active_shop, i)
			_shop_view.refresh(_active_shop, _run.gold, _run.deck); return
	if _shop_view.get_relic_rect().has_point(pos):
		_run.buy_relic(_active_shop)
		_shop_view.refresh(_active_shop, _run.gold, _run.deck); return
	if _shop_view.get_removal_rect().has_point(pos):
		_run.buy_removal(_active_shop, 0)
		_shop_view.refresh(_active_shop, _run.gold, _run.deck); return


func _handle_event_tap(pos: Vector2) -> void:
	var choices: Array = _active_event.get("choices", [])
	for i in choices.size():
		if _event_view.get_choice_rect(i).has_point(pos):
			_run.resolve_event_choice(_active_event, i)
			_show_map()
			return
