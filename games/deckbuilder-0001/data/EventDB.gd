extends Node

# Data-driven events. Each choice's "effects" dict may contain:
#   "gold": int (delta), "hp": int (delta, capped at run_max_hp),
#   "add_card": String (card id appended to deck),
#   "remove_card": bool (remove first deck card),
#   "relic": String (relic id granted).
const EVENTS := {
	"wandering_alchemist": {
		"id": "wandering_alchemist",
		"title": "The Wandering Alchemist",
		"body": "A hooded figure offers a vial — for a price.",
		"choices": [
			{"label": "Drink it (heal 15)", "effects": {"hp": 15}},
			{"label": "Buy a secret (-40 gold, +relic)", "effects": {"gold": -40, "relic": "storm_core"}},
			{"label": "Decline", "effects": {}},
		],
	},
	"cursed_altar": {
		"id": "cursed_altar",
		"title": "Cursed Altar",
		"body": "Gold glints on a blood-stained altar.",
		"choices": [
			{"label": "Take the gold (+60, -10 HP)", "effects": {"gold": 60, "hp": -10}},
			{"label": "Cleanse a card (remove)", "effects": {"remove_card": true}},
			{"label": "Leave", "effects": {}},
		],
	},
	"arcane_font": {
		"id": "arcane_font",
		"title": "Arcane Font",
		"body": "Raw magic pools in a cracked basin.",
		"choices": [
			{"label": "Channel it (+1 card: chain_lightning)", "effects": {"add_card": "chain_lightning"}},
			{"label": "Rest here (heal 10)", "effects": {"hp": 10}},
		],
	},
}

static func all_ids() -> Array:
	return EVENTS.keys()

static func event(id: String) -> Dictionary:
	return EVENTS.get(id, {}).duplicate(true)
