class_name DishScheduler
extends RefCounted
## The world clock and the scheduler of the dishes that run at once: every dish is advanced to one shared time, the ones on the processor
## take turns when it cannot afford them all, and Auto moves one dish at a time between the processor and the GPU. It holds no nodes: the
## dishes are Main's array, which it reads and advances.

const FRAME_BUDGET_USEC := 9000  ## the most time the simulation may spend per frame; past it the sim falls behind its speed instead of the game stuttering
const LOCKSTEP_MIN_GAP := 1.0  ## a dish at least this many simulated seconds behind the world's target is advanced (a shorter step would be a fine one, Dish.FINE_STEP or less, whose run-and-tumble steps cost far more per simulated second); nearer, it waits
const LOCKSTEP_MIN_SHARE := 0.25  ## at speeds where a frame holds less than four of those seconds, a quarter of the frame's step
const CATCHUP_SECONDS := 5.0  ## when the dishes are further apart than a frame holds (after a fast speed, one dish can be a minute ahead), the ones behind are asked for this many simulated seconds a frame (what the frame's budget allows) until they have caught up
const COST_SMOOTHING := 0.4  ## how much of a dish's newest timing goes into its running average

var dishes: Array[Dish]
var _turn := 0  ## whose turn it is to change backend when no dish is waiting


func _init(all: Array[Dish]) -> void:
	dishes = all


## One world clock: every dish is advanced to the same time, so no dish runs faster than another over time. The target is a frame's simulated seconds past the
## slowest dish; a dish that has reached it waits, and a dish that is short of it by less than a second (or a quarter of a frame's step, if that is less) waits for the next frame
## (a tiny step would take it off the GPU). A dish that is ahead of a slow world moves every frame by what the slow one gained, so it stays smooth. The dishes that move share the frame's budget. If the machine cannot keep up, the whole world slows together. Returns how far the world's clock moved.
func advance(asked: float) -> float:
	var cpu_total := 0.0  # (the processor's load: what each dish still running on it is estimated to need for a frame)
	for d in dishes:
		if not d.gpu_active:
			cpu_total += d.backend.cpu_cost_estimate
	for d in dishes:
		d.backend.other_cpu_load = cpu_total - (0.0 if d.gpu_active else d.backend.cpu_cost_estimate)
	let_one_dish_switch()
	var before := world_time()
	var latest := before
	for d in dishes:
		latest = maxf(latest, d.time)
	if latest - before > maxf(LOCKSTEP_MIN_GAP, 2.0 * asked):
		# The dishes are further apart than the world moves in a frame (slowing down from a fast speed leaves them so): waiting for the slowest at the speed asked would
		# freeze the others for as long as the gap is, so the ones behind catch up first, as fast as the frame's budget lets them, and the ones ahead wait.
		var behind: Array[Dish] = dishes.filter(func(d: Dish) -> bool: return latest - d.time > 0.0)
		behind = _within_budget(behind, latest)
		var catch_share := FRAME_BUDGET_USEC / maxi(behind.size(), 1)
		for d in behind:
			_advance_timed(d, minf(latest - d.time, maxf(asked, CATCHUP_SECONDS)), catch_share)
		return minf(maxf(world_time() - before, 0.0), asked)  # (what the speed readout and the timers see is the pace asked for, not the catching up)
	var target := before + asked
	var due: Array[Dish] = []
	for d in dishes:
		if target - d.time >= minf(LOCKSTEP_MIN_GAP, asked * LOCKSTEP_MIN_SHARE):
			due.append(d)
	due = _within_budget(due, target)
	var share := FRAME_BUDGET_USEC / maxi(due.size(), 1)
	for d in due:
		_advance_timed(d, target - d.time, share)
	return maxf(world_time() - before, 0.0)


## Which of the dishes that are due this frame the processor can afford. A dish on the processor costs what it was timed to take (or what the cost model says, until it has been
## timed); the GPU's dishes cost the processor next to nothing and always go. The dishes furthest behind go first, and one dish on the processor always goes, however much it costs, so
## the world never stops; the ones left out are further behind next frame, so they go first then: the dishes take turns, and when the processor cannot keep up with all of them the whole
## world slows down together (its clock is the slowest dish's) instead of every frame costing the sum of every dish's step and the interface waiting for it.
func _within_budget(due: Array[Dish], target: float) -> Array[Dish]:
	var ordered := due.duplicate()
	ordered.sort_custom(func(a: Dish, b: Dish) -> bool: return target - a.time > target - b.time)
	var left := float(FRAME_BUDGET_USEC)
	var chosen: Array[Dish] = []
	var on_processor := 0
	for d: Dish in ordered:
		if d.gpu_active:
			chosen.append(d)
			continue
		var cost := d.backend.measured_usec if d.backend.measured_usec > 0.0 else d.backend.cpu_cost_estimate
		if on_processor == 0 or cost <= left:
			left -= cost
			on_processor += 1
			chosen.append(d)
	return chosen


## Advances a dish and, when it ran on the processor, notes how long that took (see DishBackend.measured_usec).
func _advance_timed(d: Dish, seconds: float, budget_usec: int) -> void:
	var started := Time.get_ticks_usec()
	d.advance(seconds, budget_usec)
	if d.gpu_active:
		d.backend.measured_usec = 0.0  # (the timing was of the processor; on the GPU it is timed afresh if the dish comes back)
	else:
		var took := float(Time.get_ticks_usec() - started)
		d.backend.measured_usec = took if d.backend.measured_usec <= 0.0 else lerpf(d.backend.measured_usec, took, COST_SMOOTHING)


## Auto moves one dish between the processor and the GPU at a time: dishes that all decide in the same frame would each see the others' load as it was, and all go (or all come
## back) together. Of the dishes waiting, the one that wants the GPU and costs the processor most goes first; with none waiting, the turn goes round the dishes.
## A dish's wish (`DishBackend.switch_wanted`) lasts until it is next advanced, which asks again: a dish that the budget leaves out or that is not due keeps its turn
## until it does advance, instead of the turn passing to it in a frame it is not advanced in and being lost.
func let_one_dish_switch() -> void:
	var chosen: Dish = null
	for d in dishes:
		if not d.backend.switch_wanted:
			continue
		if chosen == null or (d.backend.switch_wanted_gpu and (not chosen.backend.switch_wanted_gpu or d.backend.cpu_cost_estimate > chosen.backend.cpu_cost_estimate)) or (not d.backend.switch_wanted_gpu and not chosen.backend.switch_wanted_gpu and d.backend.cpu_cost_estimate < chosen.backend.cpu_cost_estimate):
			chosen = d
	if chosen == null:  # (nobody is waiting: the turn goes round, so no two dishes ever decide in the same frame)
		_turn = (_turn + 1) % dishes.size()
		chosen = dishes[_turn]
	for d in dishes:
		d.backend.switch_allowed = d == chosen


## The world's time: that of the slowest dish.
func world_time() -> float:
	var slowest := INF
	for d in dishes:
		slowest = minf(slowest, d.time)
	return 0.0 if dishes.is_empty() else slowest
