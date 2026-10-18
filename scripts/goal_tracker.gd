class_name GoalTracker
extends RefCounted
## Walks the goal ladder in order. Goals are checked against a single dish for now.

signal goal_completed(goal: Goal)

const POP_TARGET := 100
const SENSE_TARGET := 70.0
const SENSE_FRACTION := 0.5
const SENSE_MIN_POP := 15
const SENSE_HOLD := 1800.0  ## sim seconds (half an hour)

var goals: Array[Goal] = []
var index := 0
var held := 0.0


func _init() -> void:
	goals.append(Goal.new(
		"A Living Colony",
		"Grow the colony to %d bups." % POP_TARGET,
		0.0,
		func(d: Dish) -> float: return minf(d.population() / float(POP_TARGET), 1.0),
		func(d: Dish) -> String: return "%d / %d bups" % [d.population(), POP_TARGET],
	))
	goals.append(Goal.new(
		"Keen Senses",
		"Breed a strain where %d%% of bups sense food from %d units away. Hold for %s.\n\nNutrient tools are unlocked. Cut the random feed (DOWN key) and place a nutrient source at the far edge of the dish: only bups that can find it will thrive." % [SENSE_FRACTION * 100, SENSE_TARGET, SimClock.format(SENSE_HOLD)],
		SENSE_HOLD,
		func(d: Dish) -> float:
			if d.population() < SENSE_MIN_POP:
				return 0.0
			return minf(d.fraction_with_gene_at_least("sense", SENSE_TARGET) / SENSE_FRACTION, 1.0),
		func(d: Dish) -> String:
			return "%.0f%% keen-sensed (need %d%%, min %d bups)" % [
				d.fraction_with_gene_at_least("sense", SENSE_TARGET) * 100.0, SENSE_FRACTION * 100, SENSE_MIN_POP],
	))


func to_dict() -> Dictionary:
	return {"index": index, "held": held}


func from_dict(d: Dictionary) -> void:
	index = clampi(int(d.get("index", 0)), 0, goals.size())
	held = float(d.get("held", 0.0))


func current() -> Goal:
	return goals[index] if index < goals.size() else null


func all_done() -> bool:
	return index >= goals.size()


func update(dish: Dish, delta: float) -> void:
	var goal := current()
	if goal == null or dish.population() == 0:
		return
	if goal.progress.call(dish) >= 1.0:
		held += delta
		if held >= goal.hold_time:
			index += 1
			held = 0.0
			goal_completed.emit(goal)
	else:
		held = 0.0
