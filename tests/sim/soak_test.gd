extends SceneTree
## The interface stays unfrozen while the sim runs, and the shutdown is clean. A world of one 2,000,000-bup dish (scenario F's
## dish, tools/gpu/world_tools.gd, tests/sim/perf_gates_test.gd) and a small one runs at x10,000 for 10 minutes through the real sim thread (GpuSimBackend, WorldClient), while the main
## thread drives every kind of command on a schedule and checks every reply; then the world is shut down and both threads joined.
## Windowed, through the lock (a run of about 11 minutes). On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/soak_test.gd [-- seconds=600]
##
## Expected values:
## - no deadlock: a new snapshot at least every WATCHDOG_S = 10 s throughout [derived: an iteration at 2M is one step of about 20 ms
##   [measured] plus its readback and publish, so 10 s is hundreds of iterations]; else the test fails at once and quits.
## - every CYCLE_S = 20 s: a pipette of the small dish (a retarget into a new dish), a freeze of that new dish (its blob is that dish,
##   by number: its count has moved on from the bups moved, as the dish ran in between), a thaw of the blob, a trash of the thawed dish; an edit of each kind on the small dish (a drop, a source placed, moved off,
##   removed, plankton placed and removed, an erase); a question (a fraction); the main view moved between the dishes. Every
##   SAVE_EVERY_S = 180 s a save of every dish. Each reply arrives within REPLY_S = 10 s [derived: a reply waits at most for the iteration
##   in flight (about 20 ms) and, for a freeze or a save, a whole read of the dish (a 2M save reads about 230 MB, under a second)].
## - no overflow and no error from the sim at the end (inspect: SimCore.overflow() 0; status errors empty).
## - the interface unfrozen: no main frame over FROZEN_MS = 250 ms after the set-up [placeholder: an unfrozen bound, not smoothness; the
##   interface's smoothness is measured by tests/sim/interface_gate.gd].
## - shutdown: the sim thread stops, frees its device, the two workers drain, and the three threads are joined within JOIN_MS = 5,000 ms
##   [derived: the loop checks its stop flag between iterations]; status alive false afterwards.

const WATCHDOG_S := 10.0
const CYCLE_S := 20.0
const SAVE_EVERY_S := 180.0
const REPLY_S := 10.0
const FROZEN_MS := 250.0
const JOIN_MS := 5000.0
const SPEED := 10000.0

var seconds := 600.0
var _w: WorldClient
var _backend: GpuSimBackend
var _pending: Array = []  ## [what, SimReply, sent msec, Callable(value) or null]
var _replies := 0
var _late := 0


func _initialize() -> void:
	if not SimHarness.device_available():
		SimHarness.skip(self, "soak_test", "needs a local GPU (not available headless)", "the pooled core (SimCore)")
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seconds="):
			seconds = float(a.substr(8))
	var t_setup := Time.get_ticks_msec()
	_backend = GpuSimBackend.new()
	_backend.start(PoolLimits.from_settings())
	_w = WorldClient.new(_backend)
	var big := _w.add_dish(load("res://tests/sim/perf_gates_test.gd").filled_spec(2000000, 90000.0, 1, 3))
	var small_spec: DishSpec = load("res://tests/sim/perf_gates_test.gd").filled_spec(1000, 3000.0, 2, 4)
	small_spec.limit = 20000
	var small := _w.add_dish(small_spec)
	var view := ViewRequest.new()
	view.want_field_view = true
	view.want_thumbnails = true
	_w.set_view(big, view)
	var t0 := Time.get_ticks_msec()
	while not (_w.latest().dishes.has(big) and _w.latest().dishes.has(small)):
		_w.set_time(SPEED, true, 0.0)
		_w.poll()
		await process_frame
		if Time.get_ticks_msec() - t0 > 300000:
			TestUtil.show(false, "the dishes appeared within 300 s (status %s)" % [_backend.status()])
			_backend.shutdown()
			TestUtil.finish(self, "")
			return
	print("set-up %.1f s" % ((Time.get_ticks_msec() - t_setup) / 1000.0))
	var start := Time.get_ticks_usec()
	var last := start
	var last_seq := _w.latest().seq
	var last_seq_usec := start
	var longest_gap := 0.0
	var frames: Array = []
	var next_cycle := 5.0
	var next_save := SAVE_EVERY_S
	var cycle := 0
	var thawed := -1
	var frame := 0
	var dead := false
	while true:
		await process_frame
		frame += 1
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1e6
		last = now
		frames.append(dt * 1000.0)
		var elapsed := (now - start) / 1e6
		if elapsed >= seconds:
			break
		_w.set_time(SPEED, false, dt)
		_w.poll()
		var snap := _w.latest()
		if snap.payload != null:
			_w.texture_bound("payload", snap.payload.texture_index, frame, snap.payload.seq)
		if snap.seq != last_seq:
			longest_gap = maxf(longest_gap, (now - last_seq_usec) / 1e6)
			last_seq = snap.seq
			last_seq_usec = now
		elif (now - last_seq_usec) / 1e6 > WATCHDOG_S:
			TestUtil.show(false, "a new snapshot within %.0f s (none for %.1f s at %.0f s; status %s; timing %s)" % [WATCHDOG_S, (now - last_seq_usec) / 1e6, elapsed, _backend.status(), snap.timing])
			dead = true
			break
		if not _check_replies(now):
			dead = true
			break
		if elapsed >= next_cycle:
			next_cycle += CYCLE_S
			cycle += 1
			thawed = _cycle(cycle, big, small, thawed)
		if elapsed >= next_save:
			next_save += SAVE_EVERY_S
			_expect("save_all", _w.save_all(), func(v: Variant) -> bool: return v is Array and (v as Array).size() >= 2)
	var final := _w.latest()
	print("ran %.0f s: %d snapshots, world %.0f s (x%.0f), longest gap between snapshots %.2f s, %d replies (%d late), dropped %.0f s, lineage %d records" % [
		(Time.get_ticks_usec() - start) / 1e6, final.seq, final.sim_time, final.sim_time / maxf((Time.get_ticks_usec() - start) / 1e6, 1.0),
		longest_gap, _replies, _late, float(final.timing.get("dropped_s", 0.0)), _backend.lineage().record_count()])
	print(load("res://tests/sim/perf_gates_test.gd").frame_figures(frames))
	if not dead:
		var r := _w.inspect(func(core: SimCore, _rows: Dictionary) -> Variant: return core.overflow())
		var t_wait := Time.get_ticks_msec()
		while not r.is_done() and Time.get_ticks_msec() - t_wait < REPLY_S * 1000.0:
			await process_frame
		TestUtil.show(r.is_done() and r.value() == 0, "no overflow at the end (%s)" % [r.value()])
		var errors: Array = _backend.status().get("errors", [])
		TestUtil.show(errors.is_empty(), "no error from the sim (%s)" % [errors])
		TestUtil.show(longest_gap <= WATCHDOG_S, "a snapshot at least every %.0f s (longest gap %.2f s)" % [WATCHDOG_S, longest_gap])
		TestUtil.show(_late == 0, "every reply within %.0f s (%d of %d late)" % [REPLY_S, _late, _replies])
		var worst: float = frames.max() if not frames.is_empty() else 0.0
		TestUtil.show(worst <= FROZEN_MS, "no main frame over %.0f ms (worst %.1f ms)" % [FROZEN_MS, worst])
	var t_join := Time.get_ticks_msec()
	_backend.shutdown()
	var join_ms := Time.get_ticks_msec() - t_join
	TestUtil.show(join_ms <= JOIN_MS and not _backend.status().get("alive", true), "shutdown joined the threads in %d ms (status %s)" % [join_ms, _backend.status()])
	TestUtil.finish(self, "OK soak_test")


## One cycle of commands (see the header). Returns the row of the dish thawed in this cycle (trashed in the next).
func _cycle(n: int, big: int, small: int, thawed: int) -> int:
	if thawed >= 0:
		_w.remove_dish(thawed)
	var pr := _w.pipette(small, Vector2.ZERO, 900.0)
	_expect("pipette", pr, func(v: Variant) -> bool:
		if not (v is Dictionary):
			return false
		var fr := _w.freeze(int(v["new_row"]))
		var number := int(v["number"])
		_expect("freeze", fr, func(b: Variant) -> bool:
			if not (b is DishBlob) or (b as DishBlob).number() != number:
				return false
			_thawed_rows.append(_w.thaw(b))
			return true)
		return true)
	var drop := WorldEdit.drop(Vector2(100.0, 50.0), 500.0)
	_w.edit_world(small, drop)
	var src := WorldEdit.new()
	src.kind = WorldEdit.Kind.PLACE_SOURCE
	src.position = Vector2(-400.0, 200.0)
	src.amount = 3.0
	_w.edit_world(small, src)
	var plank := WorldEdit.new()
	plank.kind = WorldEdit.Kind.PLACE_PLANKTON
	plank.position = Vector2(300.0, -300.0)
	_w.edit_world(small, plank)
	var unplank := WorldEdit.new()
	unplank.kind = WorldEdit.Kind.REMOVE_PLANKTON
	unplank.position = Vector2(300.0, -300.0)
	unplank.radius = 50.0
	_w.edit_world(small, unplank)
	_w.edit_world(small, WorldEdit.erase(Vector2(-200.0, -200.0), 150.0, 0.5))
	_w.ask(small, {"fractions": {"fast": ["speed", 20.0 + n % 5]}})
	_w.ask(big, {"fractions": {"slow": ["speed", 15.0]}})
	var view := ViewRequest.new()
	view.want_field_view = n % 2 == 0
	view.want_thumbnails = true
	_w.set_view(small if n % 3 == 0 else big, view)
	var take := -1
	if not _thawed_rows.is_empty():
		take = _thawed_rows.pop_front()
	return take


var _thawed_rows: Array = []


func _expect(what: String, reply: SimReply, check: Callable) -> void:
	_pending.append([what, reply, Time.get_ticks_usec(), check])


## Completed replies are checked; false (and a failure) when one is late past REPLY_S or wrong.
func _check_replies(now: int) -> bool:
	var current := _pending
	_pending = []
	var still: Array = []
	for p: Array in current:
		var r: SimReply = p[1]
		if r.is_done():
			_replies += 1
			var ok: bool = r.error() == "" and (p[3] as Callable).call(r.value())
			if not ok:
				TestUtil.show(false, "%s's reply is right (error '%s', value %s)" % [p[0], r.error(), str(r.value()).left(200)])
				return false
			continue
		if (now - int(p[2])) / 1e6 > REPLY_S:
			_late += 1
			TestUtil.show(false, "%s's reply within %.0f s" % [p[0], REPLY_S])
			return false
		still.append(p)
	_pending.append_array(still)
	return true
