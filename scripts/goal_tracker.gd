class_name GoalTracker
extends RefCounted
## Walks the goal ladder in order. Goals are checked against a single dish for now.

signal goal_completed(goal: Goal)

const POP_TARGET := 1000  ## a colony big enough to select from in experiment 2
const SENSE_TARGET := 70.0
const SENSE_FRACTION := 0.5
const SENSE_MIN_POP := 15
const SENSE_HOLD := 1800.0  ## sim seconds (half an hour)

var goals: Array[Goal] = []
var index := 0
var held := 0.0


func _init() -> void:
	goals.append(Goal.new(
		Strings.t("goals.living_title"),
		Strings.t("goals.living_text", [POP_TARGET]),
		0.0,
		func(d: Dish) -> float: return minf(d.population() / float(POP_TARGET), 1.0),
		func(d: Dish) -> String: return Strings.t("goals.living_status", [UiText.thousands(d.population()), UiText.thousands(POP_TARGET)]),
	))
	goals.append(Goal.new(
		Strings.t("goals.keen_title"),
		Strings.t("goals.keen_text", [SENSE_FRACTION * 100, SENSE_TARGET, SimClock.format(SENSE_HOLD), Dish.SUGGESTED_BLOOM_DENSITY]),
		SENSE_HOLD,
		func(d: Dish) -> float:
			if d.population() < SENSE_MIN_POP:
				return 0.0
			return minf(d.fraction_with_gene_at_least("sense", SENSE_TARGET) / SENSE_FRACTION, 1.0),
		func(d: Dish) -> String:
			return Strings.t("goals.keen_status", [d.fraction_with_gene_at_least("sense", SENSE_TARGET) * 100.0, SENSE_FRACTION * 100, SENSE_MIN_POP]),
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
