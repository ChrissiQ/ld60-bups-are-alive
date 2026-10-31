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
