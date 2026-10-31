class_name DishState
extends RefCounted
## What a snapshot says of one dish: a light record, not a node. `stats` has the keys of `BupSim.population_stats` (STATS_KEYS).

const STATS_KEYS: Array[String] = ["count", "speed", "sense", "metabolism", "size", "harm", "mutations", "mutator", "donor", "key", "generation"]

var number := 0  ## the dish's number as the player sees it (never reused)
var count := 0  ## the bups alive in it
var stats: Dictionary = {}  ## STATS_KEYS to means (count is the count)
var fractions: Dictionary = {}  ## the answers to the asked "share with a gene at least" questions
var extinct := false
var overflow := 0  ## births refused at the pool's edge
var cloud_count := 0
var husk_count := 0


## Every dish of `states` (row -> DishState) together: {dishes: how many, count: their bups, stats: each of STATS_KEYS but the count
## averaged over every bup of every dish (a dish counts by its bups; 0 with no bups), extinct: the rows of the dishes that have died out}.
## Worked out once a snapshot, where it is made, so the screen reads it without looking at each dish.
static func aggregate(states: Dictionary) -> Dictionary:
	var total := 0.0
	var sums := {}
	var extinct: Array[int] = []
	for row: int in states:
		var ds: DishState = states[row]
		if ds.extinct:
			extinct.append(row)
		var n := float(ds.count)
		total += n
		if n <= 0.0:
			continue
		for key: String in STATS_KEYS:
			if key != "count":
				sums[key] = float(sums.get(key, 0.0)) + float(ds.stats.get(key, 0.0)) * n
	var means := {"count": int(total)}
	for key: String in STATS_KEYS:
		if key != "count":
			means[key] = float(sums.get(key, 0.0)) / total if total > 0.0 else 0.0
	return {"dishes": states.size(), "count": int(total), "stats": means, "extinct": extinct}
