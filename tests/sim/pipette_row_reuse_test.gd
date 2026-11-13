extends SceneTree
## A pipette waits for its new dish's grid (made on the worker pool); the source's client row can be freed and given to another dish
## meanwhile. Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/pipette_row_reuse_test.gd
##
## Expected values, written before the first run [derived from the code: SimThread._pipette keeps the source's client row, WorldClient hands
## a freed client row out again at once, and the retarget looks the row up when the grid is ready]:
## - dish 1 (client row 0, 30 bups) is asked for a pipette that takes every bup (radius 600 over a 244 um colony), then trashed, and a
##   different dish (number 5, 25 bups, another size) is added at client row 0, all before the grid is ready (a grid of 100 cells takes
##   some 100 ms in script, the three commands microseconds): the pipette's answer is a refusal (no bups moved: the dish it was asked
##   about is gone), and dish 5 still has its 25 bups, alone in the world.

func _init() -> void:
	if not SimHarness.begin(self, "pipette_row_reuse_test", "the pooled core (SimCore)"):
		return
	_run()
	TestUtil.finish(self, "OK pipette_row_reuse_test")


func _dish(number: int, radius: float, bups: int) -> DishSpec:
	var spec := DishSpec.new()
	spec.number = number
	spec.radius = radius
	spec.seed = 5 + number
	spec.patchiness = 0.0
	spec.nutrient_density = 32.0
	spec.founders = Scenario.small(bups, radius).seed(60 + number).founder_records(number)
	return spec


func _wait(reply: SimReply) -> void:
	var until := Time.get_ticks_msec() + 20000
	while not reply.is_done() and Time.get_ticks_msec() < until:
		OS.delay_msec(5)


func _frames(thread: SimThread, frames: int, paused: bool) -> void:
	for f in frames:
		thread.submit(SimCommand.new(SimCommand.KIND_SET_TIME, {"speed": 600.0, "paused": paused, "real_dt": 1.0 / 60.0}))
		OS.delay_msec(16)


func _run() -> void:
	var store: Object = ClassDB.instantiate("LineageStore")
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	var thread := SimThread.new(PoolLimits.new(), store)
	thread.start()
	var until := Time.get_ticks_msec() + 20000
	while not thread.status()["ready"] and Time.get_ticks_msec() < until:
		OS.delay_msec(10)
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": _dish(1, 1500.0, 30)}))
	_frames(thread, 20, false)
	var pip := SimReply.new()
	thread.submit(SimCommand.new(SimCommand.KIND_PIPETTE, {"row": 0, "centre": Vector2.ZERO, "radius": 600.0, "new_row": 1}, pip))
	thread.submit(SimCommand.new(SimCommand.KIND_REMOVE_DISH, {"row": 0}))
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": _dish(5, 900.0, 25)}))
	_wait(pip)
	var value: Variant = pip.value()
	var moved := int((value as Dictionary).get("moved", 0)) if value is Dictionary else 0
	TestUtil.show(moved == 0, "the pipette asked of the trashed dish moves nothing (moved %d, error '%s')" % [moved, pip.error()])
	_frames(thread, 10, true)
	var counts := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(core: SimCore, rows: Dictionary) -> Array:
		var out: Array = []
		for client: int in rows:
			out.append([client, core.count(rows[client])])
		return out}, counts))
	_wait(counts)
	TestUtil.show(counts.value() is Array and (counts.value() as Array).size() == 1 and (counts.value() as Array).has([0, 25]), "dish 5 holds its 25 bups and is alone in the world (%s)" % [counts.value()])
	thread.stop()
