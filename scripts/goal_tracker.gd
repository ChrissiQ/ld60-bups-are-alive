class_name GoalTracker
extends RefCounted
## Walks the goal ladder in order. Goals are checked against a single dish for now.

signal goal_completed(goal: Goal)

const POP_TARGET := 100
const SENSE_TARGET := 75.0
const SENSE_FRACTION := 0.6
const SENSE_MIN_POP := 15

var goals: Array[Goal] = []
var index := 0
var held := 0.0


func _init() -> void:
	goals.append(Goal.new(
		"A Living Colony",
		"Grow the colony to %d bups." % POP_TARGET,
		0.0,
		func(d: Dish) -> float: return minf(d.cells.size() / float(POP_TARGET), 1.0),
		func(d: Dish) -> String: return "%d / %d bups" % [d.cells.size(), POP_TARGET],
	))
	goals.append(Goal.new(
		"Keen Senses",
		"Breed a strain where %d%% of bups sense food from %d units away. Hold for 10s. Scarcity rewards seeking." % [SENSE_FRACTION * 100, SENSE_TARGET],
		10.0,
		func(d: Dish) -> float:
			if d.cells.size() < SENSE_MIN_POP:
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
	if goal == null or dish.cells.is_empty():
		return
	if goal.progress.call(dish) >= 1.0:
		held += delta
		if held >= goal.hold_time:
			index += 1
			held = 0.0
			goal_completed.emit(goal)
	else:
		held = 0.0
