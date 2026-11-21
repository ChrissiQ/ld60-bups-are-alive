extends SceneTree
## The step length follows the speed, never the frame. The same dish is run
## twice through the real sim thread (GpuSimBackend, WorldClient) at x1, once fed by frames of 1/120 s and once by frames of 1/240 s,
## for the same simulated time, and the two end states are compared word for word.
## Windowed, through the lock. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/refresh_rate_test.gd
##
## Expected values:
## - both runs take steps of 1/120 s (x1: Governor.step_length(1) [derived]) and run exactly N = 240 steps from (N + 0.5) steps'
##   time (N frames of 1/120 s and half a frame, or 2N + 1 frames of 1/240 s), then one more step alone (a frame of 1/120 s, or of 1/240 s
##   on the half step left), so the last iteration is a single step in both [derived from the Governor's owed time]; no time is dropped
##   (each frame waits until the sim has caught up, so what is owed never passes the cap).
## - the canonical dumps of the dish (records, field, clouds, husks, DSTATE, the last iteration's events, stats) after N + 1 steps differ
##   in 0 words [derived: the same step length, the same steps and the same world events, and a step's result does not depend on how
##   steps are grouped into iterations (the continuation property)].
## - the client sends no display frame (WorldClient.display_ms 0, so the governor does not pace): the frames fed are shorter than a display
##   frame of a 60 Hz screen, and pacing would count such a frame as none, so the run would wait for a step never owed.
## - the dish: 200 founders in a 1.5 mm dish, every flag on, a bloom of 2 a mm² a day and a source, seed 21 (the fine path: 1/120 s is under
##   FINE_STEP).

const N := 240
const WAIT_MSEC := 60000


func _initialize() -> void:
	if not SimHarness.device_available():
		SimHarness.skip(self, "refresh_rate_test", "needs a local GPU (not available headless)", "the pooled core (SimCore)")
		return
	var a: Dictionary = await _run(1.0 / 120.0)
	var b: Dictionary = await _run(1.0 / 240.0)
	print("run at 1/120 s frames: %s" % [a.get("note", "")])
	print("run at 1/240 s frames: %s" % [b.get("note", "")])
	TestUtil.show(a.get("ok", false), "frames of 1/120 s: %d steps of 1/120 s, nothing dropped" % (N + 1))
	TestUtil.show(b.get("ok", false), "frames of 1/240 s: %d steps of 1/120 s, nothing dropped" % (N + 1))
	if a.has("dump") and b.has("dump"):
		var recs: PackedByteArray = (a["dump"] as Dictionary).get("records", PackedByteArray())
		TestUtil.show(recs.size() >= GpuLayout.RECORD_BYTES, "the dish holds bups at the end (%d)" % (recs.size() / GpuLayout.RECORD_BYTES))
		var d := SimHarness.diff(CanonicalDump.coerce(a["dump"]), CanonicalDump.coerce(b["dump"]))
		TestUtil.show(d == "", "the two end states differ in 0 words%s" % ("" if d == "" else ": " + d))
	TestUtil.finish(self, "OK refresh_rate_test")


static func spec() -> DishSpec:
	var s := Scenario.small(200, 1500.0).seed(21).with_all_flags()
	s.bloom_density = 2.0
	var sp := DishSpec.new()
	sp.number = 1
	sp.radius = s.radius
	sp.resolution = s.resolution
	sp.limit = s.limit
	sp.seed = s.seed_value
	sp.flags = s.dish_flags()
	sp.nutrient_density = s.nutrient_density
	sp.bloom_density = s.bloom_density
	sp.founders = s.founder_records(1)
	sp.world = {"sources": [{"pos": Vector2(300.0, -200.0), "rate": 4.0}]}
	return sp


## One run fed by frames of `dt`: {ok, note, dump}.
func _run(dt: float) -> Dictionary:
	var backend := GpuSimBackend.new()
	backend.start(PoolLimits.new())
	var w := WorldClient.new(backend)
	w.display_ms = 0.0
	var row := w.add_dish(spec())
	var out := {"ok": false}
	if not await _until(w, func(s: Snapshot) -> bool: return s.dishes.has(row)):
		out["note"] = "the dish never appeared (status %s)" % [backend.status()]
		backend.shutdown()
		return out
	var step := Governor.step_length(1.0)
	var frames: Array = []
	if is_equal_approx(dt, step):
		for f in N:
			frames.append(dt)
		frames.append(0.5 * dt)
	else:
		for f in 2 * N + 1:
			frames.append(dt)
	var fed := 0.0
	for f: float in frames:
		var due := int(floor(fed / step + Governor.OWED_TOLERANCE))
		if not await _until(w, func(s: Snapshot) -> bool: return int(s.timing.get("steps_total", 0)) >= due):
			break
		w.set_time(1.0, false, f)
		fed += f
	var reached := await _until(w, func(s: Snapshot) -> bool: return int(s.timing.get("steps_total", 0)) >= N)
	w.set_time(1.0, false, dt)
	reached = reached and await _until(w, func(s: Snapshot) -> bool: return int(s.timing.get("steps_total", 0)) >= N + 1)
	await process_frame
	w.set_time(1.0, true, 0.0)
	var t: Dictionary = w.latest().timing
	var steps := int(t.get("steps_total", -1))
	var dropped := float(t.get("dropped_s", -1.0))
	var r := w.inspect(func(core: SimCore, rows: Dictionary) -> Variant:
		var ds := core.dstate_row(rows[row])
		return {"dump": core.canonical_dump(rows[row]), "step": ds.decode_u32(GpuLayout.DS_STEP * 4), "overflow": core.overflow()})
	while not r.is_done():
		await process_frame
	var v: Dictionary = r.value() if r.value() is Dictionary else {}
	out["dump"] = v.get("dump", {})
	out["note"] = "world steps %d, dish step %s, step %.6f s, dropped %.6f s, overflow %s, iterations %s" % [steps, v.get("step"), float(t.get("delta", 0.0)), dropped, v.get("overflow"), t.get("iterations")]
	out["ok"] = reached and steps == N + 1 and int(v.get("step", -1)) == N + 1 and dropped == 0.0 and is_equal_approx(float(t.get("delta", 0.0)), step) and int(v.get("overflow", 1)) == 0
	backend.shutdown()
	return out


## Waits (polling the world each frame) until `cond(latest snapshot)` holds; false after WAIT_MSEC.
func _until(w: WorldClient, cond: Callable) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < WAIT_MSEC:
		w.poll()
		var s := w.latest()
		if s != null and cond.call(s):
			return true
		await process_frame
	return false
