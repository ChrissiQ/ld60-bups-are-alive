extends SceneTree
## Two games in one process: a game is run until its bups have divided, ended (every dish trashed), and another begun in the same world.
## Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/two_games_test.gd
##
## Expected values, written before the first run [derived from `SimCore.begin_game`, `ResultWorker` and the family tree's rules]:
##  - Game 1 (30 founders in dish 1, run for 2,400 s of world time at x600) has divided: the world's next id is past 31, so there are ids
##    to collide with. A pipette makes dish 2 (the first game's numbers go 1, 2).
##  - With both dishes trashed the family tree holds nothing (no record, claim or tombstone).
##  - A new game (`begin_game`, then dish 1 again) starts its ids again from 1: its 30 founders are 1 to 30, each a record born at minute 0,
##    and no id above 30 (the first game's) has a record. Its first pipette makes dish 2 (the numbers start again).
##  - Run on until it has divided: every id the tree holds is one of the second game's (born within the game's own minutes, a parent
##    before its child, the alive ones those the world holds), none from the first game's records, which are gone.
##  - A game begun while a dish still runs does not start its ids again (the running dish's bups hold ids): the next id stays at or past
##    where it was, and a dish added to it has founders past that.


func _init() -> void:
	if not SimHarness.begin(self, "two_games_test", "the pooled world"):
		return
	if not ClassDB.class_exists("LineageStore"):
		print("SKIP two_games_test: no LineageStore in this build")
		quit(0)
		return
	_games()
	TestUtil.finish(self, "OK two_games_test")


static func _spec(number: int, radius: float) -> DishSpec:
	var spec := DishSpec.new()
	spec.number = number
	spec.radius = radius
	spec.seed = 5 + number
	spec.flags = 0
	spec.patchiness = 0.0
	spec.nutrient_density = 32.0
	return spec


static func _wait(reply: SimReply) -> void:
	var until := Time.get_ticks_msec() + 20000
	while not reply.is_done() and Time.get_ticks_msec() < until:
		OS.delay_msec(5)


static func _start(store: Object) -> SimThread:
	var thread := SimThread.new(PoolLimits.new(), store)
	thread.start()
	var until := Time.get_ticks_msec() + 20000
	while not thread.status()["ready"] and Time.get_ticks_msec() < until:
		OS.delay_msec(10)
	return thread


static func _frames(thread: SimThread, frames: int, speed: float, paused := false) -> void:
	for f in frames:
		thread.submit(SimCommand.new(SimCommand.KIND_SET_TIME, {"speed": speed, "paused": paused, "real_dt": 1.0 / 60.0}))
		OS.delay_msec(16)


## Waits until the sim thread has drained what was sent and the worker has done what that queued.
static func _settle(thread: SimThread) -> void:
	var r := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(_core: SimCore, _rows: Dictionary) -> int: return 0}, r))
	_wait(r)
	var until := Time.get_ticks_msec() + 5000
	while thread.worker.queued() > 0 and Time.get_ticks_msec() < until:
		OS.delay_msec(5)
	OS.delay_msec(50)


static func _next_id(thread: SimThread) -> int:
	var r := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(core: SimCore, _rows: Dictionary) -> int: return core.next_id()}, r))
	_wait(r)
	return int(r.value()) if r.value() != null else -1


static func _pipette_number(thread: SimThread, row: int, new_row: int) -> int:
	var pip := SimReply.new()
	thread.submit(SimCommand.new(SimCommand.KIND_PIPETTE, {"row": row, "centre": Vector2.ZERO, "radius": 150.0, "new_row": new_row}, pip))
	_frames(thread, 5, 600.0, true)
	_wait(pip)
	return int((pip.value() as Dictionary).get("number", -1)) if pip.value() is Dictionary else -1


func _games() -> void:
	var store: Object = ClassDB.instantiate("LineageStore")
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	var thread := _start(store)

	# Game 1.
	var first := _spec(1, 1500.0)
	first.founders = Scenario.small(30, 1500.0).seed(61).founder_records(1)
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": first}))
	_frames(thread, 240, 600.0)
	_frames(thread, 5, 600.0, true)
	_settle(thread)
	var next1 := _next_id(thread)
	TestUtil.show(next1 > 31, "game 1 has divided: the world's next id is %d (past 31)" % next1)
	var held1: Array = store.alive_ids()
	TestUtil.show(held1.size() > 30, "...and its family tree holds %d alive bups" % held1.size())
	var numbers := [_pipette_number(thread, 0, 1)]
	TestUtil.show(numbers == [2], "game 1's pipette makes dish 2 (%s)" % [numbers])
	for row in 2:
		thread.submit(SimCommand.new(SimCommand.KIND_REMOVE_DISH, {"row": row}))
	_frames(thread, 10, 600.0, true)
	_settle(thread)
	TestUtil.show(store.record_count() == 0 and store.claim_count() == 0 and store.tombstone_count() == 0, "with every dish trashed the tree keeps nothing (%d records, %d claims, %d tombstones)" % [store.record_count(), store.claim_count(), store.tombstone_count()])

	# Game 2 in the same process.
	var t: float = thread.worker.latest().sim_time
	thread.submit(SimCommand.new(SimThread.KIND_BEGIN_GAME, {"game_began": t}))
	var second := _spec(1, 1500.0)
	second.founders = Scenario.small(30, 1500.0).seed(62).founder_records(1)
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": second}))
	_settle(thread)
	var founder_ids := {}
	for i in 30:
		founder_ids[GpuLayout.id_of(second.founders, i)] = true
	var want := {}
	for i in range(1, 31):
		want[i] = true
	TestUtil.show(founder_ids == want, "game 2's founders have ids 1 to 30 again (%d distinct, lowest %d, highest %d)" % [founder_ids.size(), founder_ids.keys().min(), founder_ids.keys().max()])
	var born_zero := true
	for id: int in founder_ids:
		var info: Dictionary = store.info(id)
		born_zero = born_zero and not info.is_empty() and int(info["born"]) == 0
	TestUtil.show(born_zero, "...each a record of the tree born at minute 0 of the new game")
	var stale := 0
	for id: int in held1:
		if id > 30 and store.has_record(id):
			stale += 1
	TestUtil.show(stale == 0, "...and none of game 1's ids above 30 has a record (%d have)" % stale)
	TestUtil.show(_pipette_number(thread, 0, 1) == 2, "game 2's first pipette makes dish 2: the numbers start again")
	_frames(thread, 240, 600.0)
	_frames(thread, 5, 600.0, true)
	_settle(thread)
	var minutes := int((float(thread.worker.latest().sim_time) - t) / 60.0)
	var next2 := _next_id(thread)
	var alive: Array = store.alive_ids()
	var in_clock := true
	var parents_first := true
	for id: int in alive:
		var info: Dictionary = store.info(id)
		in_clock = in_clock and not info.is_empty() and int(info["born"]) >= 0 and int(info["born"]) <= minutes
		var parent := int(info.get("parent", 0))
		parents_first = parents_first and (parent == 0 or parent < id)
	TestUtil.show(next2 > 31 and alive.size() > 30, "game 2 has divided too (next id %d, %d alive)" % [next2, alive.size()])
	TestUtil.show(in_clock, "every bup the tree holds was born within game 2's %d minutes" % minutes)
	TestUtil.show(parents_first, "...and every parent has a lower id than its child (one id space, no id from game 1 mixed in)")

	# A game begun over a dish that still runs keeps counting ids.
	var before := _next_id(thread)
	thread.submit(SimCommand.new(SimThread.KIND_BEGIN_GAME, {"game_began": float(thread.worker.latest().sim_time)}))
	_settle(thread)
	TestUtil.show(_next_id(thread) >= before, "a game begun over a running dish does not start the ids again (%d, was %d)" % [_next_id(thread), before])
	var third := _spec(3, 1500.0)
	third.founders = Scenario.small(10, 1500.0).seed(63).founder_records(1)
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 2, "spec": third}))
	_settle(thread)
	var lowest := 1 << 62
	for i in 10:
		lowest = mini(lowest, GpuLayout.id_of(third.founders, i))
	TestUtil.show(lowest >= before, "...a dish added to it has founders past them (lowest %d, next id was %d)" % [lowest, before])
	thread.stop()
