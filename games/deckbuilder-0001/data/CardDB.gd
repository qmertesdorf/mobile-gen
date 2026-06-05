extends Node

const CARDS := {
	"arcane_bolt": {
		"id": "arcane_bolt",
		"name": "Arcane Bolt",
		"element": "neutral",
		"cost": 1,
		"type": "attack",
		"effect": {"damage": 6}
	},
	"ward": {
		"id": "ward",
		"name": "Ward",
		"element": "neutral",
		"cost": 1,
		"type": "skill",
		"effect": {"block": 5}
	},
	"meditate": {
		"id": "meditate",
		"name": "Meditate",
		"element": "neutral",
		"cost": 1,
		"type": "skill",
		"effect": {"draw": 2}
	},
	"mana_surge": {
		"id": "mana_surge",
		"name": "Mana Surge",
		"element": "neutral",
		"cost": 0,
		"type": "skill",
		"effect": {"draw": 1}
	},
	"ember": {
		"id": "ember",
		"name": "Ember",
		"element": "fire",
		"cost": 1,
		"type": "attack",
		"effect": {"damage": 5, "burn": 2}
	},
	"flame_lash": {
		"id": "flame_lash",
		"name": "Flame Lash",
		"element": "fire",
		"cost": 2,
		"type": "attack",
		"effect": {"damage": 8, "burn": 2}
	},
	"immolate": {
		"id": "immolate",
		"name": "Immolate",
		"element": "fire",
		"cost": 3,
		"type": "attack",
		"effect": {"damage": 14, "burn": 1}
	},
	"wildfire": {
		"id": "wildfire",
		"name": "Wildfire",
		"element": "fire",
		"cost": 1,
		"type": "power",
		"effect": {"power": "wildfire"}
	},
	"frost_shard": {
		"id": "frost_shard",
		"name": "Frost Shard",
		"element": "ice",
		"cost": 1,
		"type": "attack",
		"effect": {"damage": 4, "block": 4}
	},
	"glacial_wall": {
		"id": "glacial_wall",
		"name": "Glacial Wall",
		"element": "ice",
		"cost": 2,
		"type": "skill",
		"effect": {"block": 12}
	},
	"freeze": {
		"id": "freeze",
		"name": "Freeze",
		"element": "ice",
		"cost": 1,
		"type": "skill",
		"effect": {"chill": 1}
	},
	"blizzard": {
		"id": "blizzard",
		"name": "Blizzard",
		"element": "ice",
		"cost": 2,
		"type": "attack",
		"effect": {"damage": 6, "chill": 1}
	},
	"spark": {
		"id": "spark",
		"name": "Spark",
		"element": "lightning",
		"cost": 0,
		"type": "attack",
		"effect": {"damage": 3, "lightning_bonus": 3}
	},
	"chain_lightning": {
		"id": "chain_lightning",
		"name": "Chain Lightning",
		"element": "lightning",
		"cost": 1,
		"type": "attack",
		"effect": {"damage": 5, "lightning_bonus": 6}
	},
	"overload": {
		"id": "overload",
		"name": "Overload",
		"element": "lightning",
		"cost": 1,
		"type": "power",
		"effect": {"power": "overload"}
	},
	"thunderclap": {
		"id": "thunderclap",
		"name": "Thunderclap",
		"element": "lightning",
		"cost": 2,
		"type": "attack",
		"effect": {"damage": 7, "draw": 1}
	},
}

const UPGRADES := {
	"arcane_bolt": {"id": "arcane_bolt+", "name": "Arcane Bolt+", "element": "neutral", "cost": 1, "type": "attack", "effect": {"damage": 9}},
	"ward":        {"id": "ward+",        "name": "Ward+",        "element": "neutral", "cost": 1, "type": "skill",  "effect": {"block": 8}},
	"ember":       {"id": "ember+",       "name": "Ember+",       "element": "fire",    "cost": 1, "type": "attack", "effect": {"damage": 7, "burn": 3}},
	"frost_shard": {"id": "frost_shard+", "name": "Frost Shard+", "element": "ice",     "cost": 1, "type": "attack", "effect": {"damage": 6, "block": 6}},
	"spark":       {"id": "spark+",       "name": "Spark+",       "element": "lightning","cost": 0, "type": "attack", "effect": {"damage": 4, "lightning_bonus": 4}},
	"chain_lightning": {"id": "chain_lightning+", "name": "Chain Lightning+", "element": "lightning", "cost": 1, "type": "attack", "effect": {"damage": 7, "lightning_bonus": 8}},
}

static func card(id: String) -> Dictionary:
	if CARDS.has(id):
		return CARDS[id]
	# upgraded ids: find the upgrade def whose id matches.
	for base in UPGRADES:
		if UPGRADES[base]["id"] == id:
			return UPGRADES[base]
	return {}

# Upgraded id for a base card, or the same id if it has no upgrade / is already upgraded.
static func upgrade_id(id: String) -> String:
	if is_upgraded(id):
		return id
	if UPGRADES.has(id):
		return UPGRADES[id]["id"]
	return id

static func is_upgraded(id: String) -> bool:
	return id.ends_with("+")

static func starter_deck() -> Array:
	return [
		"arcane_bolt",
		"arcane_bolt",
		"arcane_bolt",
		"ward",
		"ward",
		"ember",
		"frost_shard",
		"freeze",
		"spark",
		"meditate",
	]

static func all_ids() -> Array:
	return CARDS.keys()
