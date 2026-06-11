extends RefCounted
## Pure rules engine for Tide & Tally. No nodes, no rendering.
## Every rule mutates state and returns an Array of event Dictionaries the
## view replays as animation. Seedable RNG -> deterministic self-test.

const ItemDB := preload("res://data/ItemDB.gd")
const UpgradeDB := preload("res://data/UpgradeDB.gd")
const MetaSave := preload("res://MetaSave.gd")

enum Phase { GATHER, CRAFT, SELL, RESULTS, DAY_FAILED }

var rng := RandomNumberGenerator.new()

# --- persistent meta ---
var day: int = 1
var gold: int = 0
var upgrades: Dictionary = {"haul": 0, "tide": 0, "rare": 0, "shelf": 0, "patience": 0, "traffic": 0}

# --- carried between phases/days ---
var resources: Dictionary = {}   # res_id -> count (banked)
var stock: Array = []            # crafted item ids, not yet shelved
var shelves: Array = []          # item ids on display

# --- per-phase state ---
var phase: int = Phase.GATHER
var gather_nodes: Array = []     # {res:String, far:bool, pos:Vector2 (normalized 0..1), taken:bool}
var unbanked: Dictionary = {}    # in-hand haul, swept by the tide if not banked
var tide_left: float = 0.0
var demand: Array = []           # today's in-demand recipe ids (sell for DEMAND_BONUS)
var patrons: Array = []          # {want:String, patience:float, max_patience:float}
var patrons_to_come: int = 0
var spawn_timer: float = 0.0
var day_income: int = 0
var sales_count: int = 0
var walkout_count: int = 0

# Tuning constants — gentle start, capped ramp (concept.core_loop curve).
const BASE_HAUL: int = 3
const BASE_TIDE: float = 25.0
const TIDE_PER_LEVEL: float = 6.0
const NODE_COUNT: int = 12
const BASE_PATRONS: int = 4
const MAX_PATRONS: int = 12
const QUEUE_VISIBLE: int = 4
const BASE_PATIENCE: float = 12.0
const PATIENCE_PER_LEVEL: float = 0.25  # +25% wait per Cozy Decor level
const DRAIN_BASE: float = 1.0
const DRAIN_PER_DAY: float = 0.06
const DRAIN_CAP: float = 1.6
const SPAWN_INTERVAL: float = 2.5
const FIRST_SPAWN: float = 0.8
const SHELF_WANT_CHANCE: float = 0.7    # fairness: patrons mostly want what you actually stocked


# ---------------------------------------------------------------- setup ----

func setup(seed_value: int, save_data: Dictionary) -> void:
	rng.seed = seed_value
	if save_data.is_empty():
		return
	day = int(save_data.get("day", 1))
	gold = int(save_data.get("gold", 0))
	var saved_up: Dictionary = save_data.get("upgrades", {})
	for k in upgrades.keys():
		upgrades[k] = int(saved_up.get(k, 0))
	var saved_res: Dictionary = save_data.get("resources", {})
	for k in saved_res.keys():
		resources[k] = int(saved_res[k])
	var saved_stock: Array = save_data.get("stock", [])
	for s in saved_stock:
		stock.append(String(s))
	var saved_shelves: Array = save_data.get("shelves", [])
	for s in saved_shelves:
		shelves.append(String(s))


func snapshot() -> Dictionary:
	return {
		"day": day,
		"gold": gold,
		"upgrades": upgrades.duplicate(),
		"resources": resources.duplicate(),
		"stock": stock.duplicate(),
		"shelves": shelves.duplicate(),
	}


# ------------------------------------------------------------- derived ----

func haul_capacity() -> int:
	var lvl: int = upgrades["haul"]
	return BASE_HAUL + lvl


func tide_window() -> float:
	var lvl: int = upgrades["tide"]
	return BASE_TIDE + TIDE_PER_LEVEL * float(lvl)


func shelf_slots() -> int:
	var lvl: int = upgrades["shelf"]
	return 4 + lvl


func patron_count() -> int:
	var lvl: int = upgrades["traffic"]
	var n: int = BASE_PATRONS + (day - 1) + lvl
	return mini(n, MAX_PATRONS)


func max_patience() -> float:
	var lvl: int = upgrades["patience"]
	return BASE_PATIENCE * (1.0 + PATIENCE_PER_LEVEL * float(lvl))


func patience_drain() -> float:
	var d: float = DRAIN_BASE + DRAIN_PER_DAY * float(day - 1)
	return minf(d, DRAIN_CAP)


func demand_tier() -> int:
	# Demand shifts toward fancier goods as days pass: t1-2 early, all tiers from day 4.
	if day < 2:
		return 1
	if day < 4:
		return 2
	return 3


func unbanked_total() -> int:
	var n: int = 0
	for k in unbanked.keys():
		var c: int = unbanked[k]
		n += c
	return n


func resource_count(id: String) -> int:
	return int(resources.get(id, 0))


# -------------------------------------------------------------- gather ----

func start_day() -> Array:
	phase = Phase.GATHER
	gather_nodes.clear()
	unbanked.clear()
	patrons.clear()
	day_income = 0
	sales_count = 0
	walkout_count = 0
	tide_left = tide_window()
	_roll_demand()
	_spawn_gather_nodes()
	return [
		{"type": "day_started", "day": day, "demand": demand.duplicate()},
		# Like every other phase mutation: the view rebuilds on phase_changed,
		# so next_day()/restart_day() must announce the RESULTS->GATHER flip.
		{"type": "phase_changed", "phase": Phase.GATHER},
	]


func _roll_demand() -> void:
	demand.clear()
	var pool: Array = ItemDB.recipes_up_to_tier(demand_tier()).duplicate()
	# Seeded Fisher-Yates (Array.shuffle() ignores custom RNG seeds).
	for i in range(pool.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: Variant = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	demand.append(pool[0])
	if pool.size() > 1:
		demand.append(pool[1])


func _spawn_gather_nodes() -> void:
	var rare_lvl: int = upgrades["rare"]
	for i in range(NODE_COUNT):
		var far: bool = i >= NODE_COUNT / 2  # half near, half far
		var res: String = _roll_node_resource(far, rare_lvl)
		var px: float = rng.randf_range(0.06, 0.94)
		var py: float
		if far:
			py = rng.randf_range(0.04, 0.42)
		else:
			py = rng.randf_range(0.56, 0.96)
		gather_nodes.append({"res": res, "far": far, "pos": Vector2(px, py), "taken": false})


func _roll_node_resource(far: bool, rare_lvl: int) -> String:
	var r: float = rng.randf()
	if not far:
		if r < 0.6:
			return "shell"
		return "driftwood"
	# Far pools: rarer goods; pearls gated behind the Pry Bar.
	var pearl_chance: float = 0.0
	if rare_lvl >= 1:
		pearl_chance = 0.15 + 0.15 * float(rare_lvl - 1)
	if r < pearl_chance:
		return "pearl"
	if r < pearl_chance + 0.5:
		return "seaglass"
	if r < pearl_chance + 0.7:
		return "driftwood"
	return "shell"


func tap_node(idx: int) -> Array:
	if phase != Phase.GATHER or idx < 0 or idx >= gather_nodes.size():
		return []
	var node: Dictionary = gather_nodes[idx]
	if node["taken"]:
		return []
	if unbanked_total() >= haul_capacity():
		return [{"type": "haul_full"}]
	node["taken"] = true
	var res: String = node["res"]
	unbanked[res] = int(unbanked.get(res, 0)) + 1
	return [{"type": "node_collected", "res": res, "idx": idx, "carried": unbanked_total(), "capacity": haul_capacity()}]


func bank() -> Array:
	if phase != Phase.GATHER:
		return []
	var moved: int = unbanked_total()
	if moved == 0:
		return []
	for k in unbanked.keys():
		var c: int = unbanked[k]
		resources[k] = int(resources.get(k, 0)) + c
	unbanked.clear()
	return [{"type": "banked", "count": moved}]


func tick_gather(dt: float) -> Array:
	if phase != Phase.GATHER:
		return []
	tide_left -= dt
	if tide_left > 0.0:
		return []
	# Tide returns: whatever is still in hand is swept away.
	tide_left = 0.0
	var lost: Dictionary = unbanked.duplicate()
	var lost_n: int = unbanked_total()
	unbanked.clear()
	phase = Phase.CRAFT
	return [
		{"type": "tide_returned", "lost": lost, "lost_count": lost_n},
		{"type": "phase_changed", "phase": Phase.CRAFT},
	]


## Walk back to the shop early: you carry your basket out, nothing is lost.
func finish_gather() -> Array:
	if phase != Phase.GATHER:
		return []
	var events: Array = bank()
	phase = Phase.CRAFT
	events.append({"type": "phase_changed", "phase": Phase.CRAFT})
	return events


# --------------------------------------------------------------- craft ----

func can_craft(recipe_id: String) -> bool:
	var r: Dictionary = ItemDB.recipe(recipe_id)
	var cost: Dictionary = r["cost"]
	for res in cost.keys():
		var need: int = cost[res]
		if resource_count(res) < need:
			return false
	return true


func craft(recipe_id: String) -> Array:
	if phase != Phase.CRAFT or not ItemDB.RECIPES.has(recipe_id):
		return []
	if not can_craft(recipe_id):
		return [{"type": "craft_failed", "recipe": recipe_id}]
	var r: Dictionary = ItemDB.recipe(recipe_id)
	var cost: Dictionary = r["cost"]
	for res in cost.keys():
		var need: int = cost[res]
		resources[res] = resource_count(res) - need
	stock.append(recipe_id)
	return [{"type": "crafted", "recipe": recipe_id}]


func stock_shelf(stock_idx: int) -> Array:
	if phase != Phase.CRAFT or stock_idx < 0 or stock_idx >= stock.size():
		return []
	if shelves.size() >= shelf_slots():
		return [{"type": "shelves_full"}]
	var item: String = stock[stock_idx]
	stock.remove_at(stock_idx)
	shelves.append(item)
	return [{"type": "stocked", "item": item, "slot": shelves.size() - 1}]


# ---------------------------------------------------------------- sell ----

func open_shop() -> Array:
	if phase != Phase.CRAFT:
		return []
	if shelves.is_empty():
		# Soft fail: nothing to sell, the day ends early (restartable).
		phase = Phase.DAY_FAILED
		return [{"type": "day_failed"}, {"type": "phase_changed", "phase": Phase.DAY_FAILED}]
	phase = Phase.SELL
	patrons_to_come = patron_count()
	spawn_timer = FIRST_SPAWN
	return [{"type": "shop_opened", "patrons_today": patrons_to_come}, {"type": "phase_changed", "phase": Phase.SELL}]


func _roll_patron_want() -> String:
	# Fairness: mostly want something actually on the shelves; otherwise any
	# recipe up to today's demand tier.
	if not shelves.is_empty() and rng.randf() < SHELF_WANT_CHANCE:
		var i: int = rng.randi_range(0, shelves.size() - 1)
		return shelves[i]
	var pool: Array = ItemDB.recipes_up_to_tier(demand_tier())
	var j: int = rng.randi_range(0, pool.size() - 1)
	return pool[j]


func tick_sell(dt: float) -> Array:
	if phase != Phase.SELL:
		return []
	var events: Array = []
	# Arrivals.
	if patrons_to_come > 0 and patrons.size() < QUEUE_VISIBLE:
		spawn_timer -= dt
		if spawn_timer <= 0.0:
			spawn_timer = SPAWN_INTERVAL
			patrons_to_come -= 1
			var want: String = _roll_patron_want()
			var mp: float = max_patience()
			patrons.append({"want": want, "patience": mp, "max_patience": mp})
			events.append({"type": "patron_arrived", "want": want})
	# Patience drain + walkouts.
	var drain: float = patience_drain()
	var i: int = patrons.size() - 1
	while i >= 0:
		var p: Dictionary = patrons[i]
		var left: float = p["patience"]
		left -= drain * dt
		p["patience"] = left
		if left <= 0.0:
			patrons.remove_at(i)
			walkout_count += 1
			events.append({"type": "patron_left", "want": p["want"]})
		i -= 1
	# Day completion: everyone resolved, or shelves sold bare.
	if patrons_to_come == 0 and patrons.is_empty():
		events.append_array(_end_day(false))
	elif shelves.is_empty():
		patrons.clear()
		patrons_to_come = 0
		events.append_array(_end_day(true))
	return events


func serve(patron_idx: int, shelf_idx: int) -> Array:
	if phase != Phase.SELL:
		return []
	if patron_idx < 0 or patron_idx >= patrons.size():
		return []
	if shelf_idx < 0 or shelf_idx >= shelves.size():
		return []
	var p: Dictionary = patrons[patron_idx]
	var want: String = p["want"]
	var item: String = shelves[shelf_idx]
	if item != want:
		return [{"type": "wrong_item", "want": want, "offered": item}]
	var price: int = ItemDB.base_price(item)
	var bonus: bool = demand.has(item)
	if bonus:
		price = int(ceil(float(price) * ItemDB.DEMAND_BONUS))
	gold += price
	day_income += price
	sales_count += 1
	shelves.remove_at(shelf_idx)
	patrons.remove_at(patron_idx)
	return [{"type": "sale", "item": item, "amount": price, "bonus": bonus}]


func _end_day(sold_out: bool) -> Array:
	phase = Phase.RESULTS
	MetaSave.write(snapshot())
	return [
		{"type": "day_complete", "day": day, "income": day_income, "sold_out": sold_out,
			"sales": sales_count, "walkouts": walkout_count},
		{"type": "phase_changed", "phase": Phase.RESULTS},
	]


# ------------------------------------------------------------- results ----

func buy_upgrade(track: String) -> Array:
	if phase != Phase.RESULTS or not UpgradeDB.TRACKS.has(track):
		return []
	var lvl: int = upgrades[track]
	var c: int = UpgradeDB.cost(track, lvl)
	if c < 0:
		return [{"type": "upgrade_maxed", "track": track}]
	if gold < c:
		return [{"type": "upgrade_too_poor", "track": track, "cost": c}]
	gold -= c
	upgrades[track] = lvl + 1
	MetaSave.write(snapshot())
	return [{"type": "upgrade_bought", "track": track, "level": lvl + 1, "cost": c}]


func next_day() -> Array:
	if phase != Phase.RESULTS:
		return []
	day += 1
	MetaSave.write(snapshot())
	return start_day()


## From DAY_FAILED: retry the same day (gold/upgrades/resources kept).
func restart_day() -> Array:
	if phase != Phase.DAY_FAILED:
		return []
	return start_day()
