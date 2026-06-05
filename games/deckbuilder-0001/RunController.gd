extends RefCounted

# RunController orchestrates a full deckbuilder run:
#   traverses a seeded branching MapGen graph from a floor-0 combat entry to the boss,
#   deriving each combat's enemy from node type + floor.
# Sits on top of CombatState (combat rules). Headless/pure — no rendering, no autoload.

const CardDB := preload("res://data/CardDB.gd")
const CombatState := preload("res://CombatState.gd")
const EnemyDB := preload("res://data/EnemyDB.gd")
const EventDB := preload("res://data/EventDB.gd")
const MetaSave := preload("res://MetaSave.gd")
const RelicDB := preload("res://data/RelicDB.gd")
const MapGen := preload("res://MapGen.gd")

# Run state.
var rng: RandomNumberGenerator
var deck: Array
var map               # MapModel
var cur_id: int
var current_enemy_id: String
var relics: Array
var run_hp: int
var run_max_hp: int
var gold: int
var _complete: bool
var _lost: bool


func start_run(seed_value: int) -> void:
	rng = RandomNumberGenerator.new()
	rng.seed = seed_value

	deck = CardDB.starter_deck().duplicate()

	map = MapGen.generate(rng)
	# Start on the lowest-id floor-0 entry node.
	var entries: Array = map.nodes_on_floor(0)
	entries.sort()
	cur_id = entries[0]

	relics = []
	_complete = false
	_lost = false

	# Starting relic: ember_heart — at start of combat, apply 1 Burn to the enemy.
	relics.append("ember_heart")

	run_max_hp = 70
	run_hp = run_max_hp
	gold = 0


func current_node() -> Dictionary:
	return map.node(cur_id)


func current_node_id() -> int:
	return cur_id


func available_next() -> Array:
	return map.next_of(cur_id)


func choose_next(node_id: int) -> void:
	if node_id in map.next_of(cur_id):
		cur_id = node_id


func is_on_boss() -> bool:
	return current_node().get("type", "") == "boss"


func start_node_combat() -> CombatState:
	var node: Dictionary = current_node()
	var enemy_id: String = _enemy_for_node(node)
	current_enemy_id = enemy_id

	var cs: CombatState = CombatState.new()
	cs.setup(rng.randi(), deck, enemy_id, run_hp)
	cs.start_combat()

	# Apply relics via the data-driven hook table.
	RelicDB.apply_combat_start(relics, cs)

	return cs


func _enemy_for_node(node: Dictionary) -> String:
	match node.get("type", ""):
		"boss":  return "archmage"
		"elite": return "golem"
		_:
			# Regular combat: shallower floors face the imp, deeper ones the frost wraith.
			return "imp" if node.get("floor", 0) < 4 else "frost_wraith"


func sync_hp_from_combat(cs) -> void:
	# Pull the player's surviving HP back to the run after a combat ends.
	run_hp = cs.player_hp


func grant_combat_gold(enemy_id: String) -> void:
	var e: Dictionary = EnemyDB.enemy(enemy_id)
	var lo: int = e.get("gold_min", 5)
	var hi: int = e.get("gold_max", 10)
	gold += rng.randi_range(lo, hi)


func spend_gold(amount: int) -> bool:
	if amount < 0 or amount > gold:
		return false
	gold -= amount
	return true


func offer_rewards() -> Array:
	# Return exactly 3 DISTINCT card ids drawn from CardDB.all_ids() using the seeded rng.
	# Deterministic given the seed: shuffle a copy of all_ids() and take the first 3.
	var all_ids: Array = CardDB.all_ids().duplicate()
	_shuffle_run(all_ids)

	# Return the first 3 distinct ids (already distinct since all_ids has no duplicates).
	var result: Array = []
	for k in range(3):
		result.append(all_ids[k])
	return result


# Fisher-Yates over the run's seeded rng (member helper).
func _shuffle_run(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp


func roll_shop() -> Dictionary:
	# Seeded inventory. Cards drawn from CardDB, relic from un-owned RelicDB ids.
	var ids: Array = CardDB.all_ids().duplicate()
	_shuffle_run(ids)
	var cards: Array = []
	for i in range(3):
		var cid: String = ids[i]
		cards.append({"id": cid, "cost": rng.randi_range(50, 75)})
	# Relic: first un-owned relic id (or "" if none left).
	var relic_id: String = ""
	for rid in RelicDB.all_ids():
		if not (rid in relics):
			relic_id = rid
			break
	return {
		"cards": cards,
		"relic": {"id": relic_id, "cost": rng.randi_range(120, 150)},
		"removal_cost": 75,
		"removed": false,
	}


func buy_card(shop: Dictionary, index: int) -> bool:
	var cards: Array = shop.get("cards", [])
	if index < 0 or index >= cards.size():
		return false
	var entry: Dictionary = cards[index]
	if entry.get("bought", false):
		return false
	if not spend_gold(entry.get("cost", 999999)):
		return false
	deck.append(entry["id"])
	entry["bought"] = true
	return true


func buy_relic(shop: Dictionary) -> bool:
	var entry: Dictionary = shop.get("relic", {})
	var rid: String = entry.get("id", "")
	if rid == "" or entry.get("bought", false):
		return false
	if not spend_gold(entry.get("cost", 999999)):
		return false
	relics.append(rid)
	entry["bought"] = true
	return true


func buy_removal(shop: Dictionary, deck_index: int) -> bool:
	if shop.get("removed", false):
		return false
	if deck_index < 0 or deck_index >= deck.size():
		return false
	if not spend_gold(shop.get("removal_cost", 999999)):
		return false
	deck.remove_at(deck_index)
	shop["removed"] = true
	return true


func choose_reward(card_id: String) -> void:
	# Empty string = explicit skip; just no-op.
	if card_id.is_empty():
		return
	deck.append(card_id)


func take_rest(action: String) -> void:
	if action == "heal":
		# No persistent player HP across combats in this slice — recorded no-op.
		pass
	elif action == "remove":
		# Remove the first card from the deck (card removal).
		if not deck.is_empty():
			deck.remove_at(0)


func grant_elite_relic() -> void:
	relics.append("storm_core")


func advance() -> void:
	# With map traversal, advancing = choosing the next node (done via choose_next
	# in the UI). This shim remains for non-combat auto-resolve paths that pick the
	# first available next node when there is exactly one.
	var nx: Array = available_next()
	if nx.size() == 1:
		choose_next(nx[0])


func is_run_complete() -> bool:
	return _complete


func is_run_lost() -> bool:
	return _lost


func on_boss_defeated() -> void:
	# Write meta-progression: unlock 1 new card + bump ascension + record best.
	var meta: MetaSave = MetaSave.new()
	var state: Dictionary = meta.load_state()

	var unlocked: Array = state.get("unlocked_cards", [])

	# Pick the first card from all_ids not already unlocked (deterministic).
	var candidate: String = ""
	for id in CardDB.all_ids():
		if not (id in unlocked):
			candidate = id
			break

	# Fallback: just use "immolate" (should always be available on a fresh save).
	if candidate.is_empty():
		candidate = "immolate"

	unlocked.append(candidate)
	state["unlocked_cards"] = unlocked
	state["ascension"] = max(state.get("ascension", 0), 1)
	# Record best as the boss enemy name.
	state["best"] = "archmage"

	meta.save_state(state)
	_complete = true


func roll_event() -> Dictionary:
	var ids: Array = EventDB.all_ids()
	var pick: String = ids[rng.randi_range(0, ids.size() - 1)]
	return EventDB.event(pick)


func resolve_event_choice(ev: Dictionary, choice_index: int) -> void:
	var choices: Array = ev.get("choices", [])
	if choice_index < 0 or choice_index >= choices.size():
		return
	var fx: Dictionary = choices[choice_index].get("effects", {})
	if fx.has("gold"):
		gold = max(0, gold + int(fx["gold"]))
	if fx.has("hp"):
		run_hp = clampi(run_hp + int(fx["hp"]), 0, run_max_hp)
	if fx.has("add_card"):
		deck.append(String(fx["add_card"]))
	if fx.get("remove_card", false) and not deck.is_empty():
		deck.remove_at(0)
	if fx.has("relic"):
		var rid: String = String(fx["relic"])
		if not (rid in relics):
			relics.append(rid)


# TEST-ONLY: walk the map greedily to the boss node and invoke the boss-win path
# directly. This lets the self-test exercise the meta write without playing every node.
func force_boss_defeat_for_test() -> void:
	var guard: int = 0
	while not is_on_boss() and guard < 50:
		var nx: Array = available_next()
		if nx.is_empty():
			break
		choose_next(nx[0])
		guard += 1
	on_boss_defeated()
