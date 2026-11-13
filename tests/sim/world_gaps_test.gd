extends SceneTree
## The pooled world's answers the dish screen needs: the husks' list and the nearest husk, a dose's
## scatter, the gradient's size at a point, the steering picture's texture, a source's release, and a game's numbers and family-tree clock.
## Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/world_gaps_test.gd
##
## Expected values [derived unless marked]:
## K  SimCore builds every kernel on the device, pool_husk_view and the three pool_husk_near passes among them: `errors` is empty.
## H  Two dishes (3 mm, plankton husks on) given 300 and 50 plankton husks of 50 energy at random places in one step: `husk_view` of each
##    lists exactly its own live husks: 300 and 50 transforms, each with a unit basis, whose places are the gather's live husks' places as
##    a set, float for float (copies, no arithmetic). `husk_near` at 20 of dish A's husks with reach 0.01 finds that husk: its x and y
##    exactly, energy 50, age 20 (one step), 0 pieces; at 20 random points with reach 150 it finds a husk whose distance is the least of
##    the gather's within reach (to 1e-3 relative: float32 against double), or none when there is none within reach; at dish B's husks it
##    finds none of A's within 0.01 (a place is not shared by chance).
## C  At 200,000 husks in a 45 mm dish: the list has 200,000 transforms; the read's cost and one husk_near's; through SimThread at
##    x10,000 (2,000 bups beside them), the publish's time and the achieved speed with the husks wanted and not [measured].
## D  A dish of 3 mm, 100 cells (60 µm, a cloud goes to the grid at 30 µm) with 32 units/mm²: a dose of 144 energy over 15 µm (variance
##    max(15² / 4, 100) = 100, sigma 10 < 30) becomes one more cloud of the dish at its point with mass 144 and variance 100, the grid's
##    total unchanged (1e-6 relative); a dose of 6,400 over 100 µm (sigma 50 >= 30) raises the grid's total by 6,400 (1e-5 relative) and
##    makes no cloud. With no step run (a paused world), the probe at the dose reads more than before it: the lists are made again with
##    the cloud (the medium's 5.12e-4 plus the cloud's peak 144 / (2 pi 100) = 0.229, the probe reading at the cloud's centre).
##    A dose as an edit changes nothing a dish does but its arrival: a dish of 200 founders run 5 steps, then given the dose as an edit,
##    then 20 steps, is word for word the same dish given it as a disc event of its world in the first of those 20 steps (0 differing
##    words: the edit's cloud takes the slot the event's would, and the lists the edit makes are made afresh by the step before it reads
##    them).
## G  A dish whose glucose is a ramp c = 5.12e-4 + 5e-8 x (µm), no bups, no feed, after one 20 s step: the probe at its middle gives the
##    way (1, 0) (to 1e-4), and a gradient's size of 5e-8 /µm to 1e-3 relative (diffusion keeps a ramp a ramp; the rim's bend reaches
##    sqrt(D t) ~ 25 µm, not the middle).
## S  Through SimThread, with the main side's part played by the test (every texture it is shown told back as used, each frame): a 3 mm
##    dish with 300 husks shown with the haze and the husks wanted gives FieldViewInfo a steering texture and its publish (steer_index
##    >= 0), and over 2.4 s of frames at x60 (a field picture at most every 100 ms: about 24) more than 8 steering publishes come, so the
##    textures are written again (an index is used for two publishes); the snapshots' husk_view is row 0's with 300 transforms; asked
##    after a husk's place, the answer finds it (50 energy); a source placed at 6 a minute: its copy's `emitted` plus 6 / 60 x the world
##    time since the copy's `time` is the world's own count to 1e-6 relative (Dish.source_details' rule), which is past 10 units after about
##    144 s at x60 (14.4).
## N  Through SimThread with a LineageStore: dish 1, pipettes to 2 and 3; all three trashed: the store keeps no record, claim or tombstone;
##    (T is the world's time at the first begin_game, Ts its time at the save, T2 its time at the thaw.)
##    begin_game at the world's time T (paused) and dish 1 again: its founders are born at minute 0, and its first pipette makes dish 2.
##    Saved at game time Ts - T, trashed, the world run on, then begin_game(T + T2 - Ts) (Main's carried origin) and
##    the save thawed at T2: a founder trashed then (pinned by another holder) dies at minute int((Ts - T) / 60) and keeps born 0 (the
##    game's clock goes on from the save, though the world's moved on).

var _store_ok := ClassDB.class_exists("LineageStore")


func _init() -> void:
	if not SimHarness.begin(self, "world_gaps_test", "the dish's answers"):
		return
	_kernels()
	_husks()
	_many_husks()
	_drop()
	_drop_as_event()
	_gradient()
	_through_thread()
	_husks_at_speed()
	_numbers_and_clock()
	TestUtil.finish(self, "OK world_gaps_test")


static func _spec(number: int, radius: float, flags := 0) -> DishSpec:
	var spec := DishSpec.new()
	spec.number = number
	spec.radius = radius
	spec.seed = 5 + number
	spec.flags = flags
	spec.patchiness = 0.0
	spec.nutrient_density = 32.0
	return spec


static func _husk_rows(n: int, radius: float, seed_value: int) -> PackedFloat64Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var rows := PackedFloat64Array()
	for k in n:
		var a := rng.randf() * TAU
		var r := radius * 0.9 * sqrt(rng.randf())
		rows.append_array(PackedFloat64Array([1.0, r * cos(a), r * sin(a), 50.0]))
	return rows


static func _plan(events: Dictionary) -> IterationPlan:
	var plan := IterationPlan.new()
	var all := {}
	for row: int in events:
		all[row] = {"discs": PackedFloat64Array(), "husks": events[row], "puffs": PackedFloat64Array(), "deposits": PackedFloat64Array()}
	plan.events = all
	return plan


func _kernels() -> void:
	var core := SimCore.new()
	TestUtil.show(core.errors.is_empty(), "K every kernel builds on the device (%s)" % [core.errors])
	core.release()


## The places of the live husks a gather lists (SimCore._slots_of: alive, a piece not yet let go).
static func _live_places(core: SimCore, row: int) -> Array:
	var h: PackedFloat32Array = core._slots_of(row)[1]
	var out: Array = []
	for k in h.size() / 8:
		out.append(Vector2(h[k * 8], h[k * 8 + 1]))
	return out


static func _view_places(t: PackedFloat32Array) -> Array:
	var out: Array = []
	for k in t.size() / 8:
		out.append(Vector2(t[k * 8 + 3], t[k * 8 + 7]))
	return out


static func _unit_bases(t: PackedFloat32Array) -> bool:
	for k in t.size() / 8:
		var o := k * 8
		if t[o] != 1.0 or t[o + 1] != 0.0 or t[o + 2] != 0.0 or t[o + 4] != 0.0 or t[o + 5] != 1.0 or t[o + 6] != 0.0:
			return false
	return true


static func _sorted(a: Array) -> Array:
	var b := a.duplicate()
	b.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x or (p.x == q.x and p.y < q.y))
	return b


func _husks() -> void:
	var core := SimCore.new()
	var flags := 1 << GpuLayout.DPF_PLANKTON_HUSKS
	var a := core.add_dish(_spec(1, 3000.0, flags))
	var b := core.add_dish(_spec(2, 3000.0, flags))
	core.run(1, 20.0, _plan({a: _husk_rows(300, 3000.0, 11), b: _husk_rows(50, 3000.0, 12)}))
	var va := core.husk_view(a)
	var vb := core.husk_view(b)
	var la := _live_places(core, a)
	var lb := _live_places(core, b)
	TestUtil.show(va.size() == 300 * 8 and vb.size() == 50 * 8 and la.size() == 300 and lb.size() == 50, "H each dish's list holds its own live husks (%d and %d; the gather has %d and %d)" % [va.size() / 8, vb.size() / 8, la.size(), lb.size()])
	TestUtil.show(_unit_bases(va) and _sorted(_view_places(va)) == _sorted(la) and _sorted(_view_places(vb)) == _sorted(lb), "H the transforms have a unit basis and the husks' places, float for float")
	var at := PackedFloat32Array()
	for k in 20:
		var p: Vector2 = la[k * 7]
		at.append_array(PackedFloat32Array([p.x, p.y, 0.01]))
	var exact := 0
	for k in 20:
		var got: Array = core.husk_near(a, at.slice(k * 3, k * 3 + 3))
		var f: PackedFloat32Array = got[0]
		if f.size() == 5 and f[0] == at[k * 3] and f[1] == at[k * 3 + 1] and f[2] == 50.0 and is_equal_approx(f[3], 20.0) and f[4] == 0.0:
			exact += 1
	TestUtil.show(exact == 20, "H at a husk's place the husk is found: its place, 50 energy, 20 s, no piece let go (%d of 20)" % exact)
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var right := 0
	var with_one := 0
	for k in 5:
		var q := PackedFloat32Array()
		var want: Array = []
		for j in GpuLayout.HUSK_QUERIES:
			var p := Vector2(rng.randf_range(-2700.0, 2700.0), rng.randf_range(-2700.0, 2700.0))
			q.append_array(PackedFloat32Array([p.x, p.y, 150.0]))
			var best := INF
			for h: Vector2 in la:
				best = minf(best, Vector2(p).distance_to(h))
			want.append(best if best <= 150.0 else -1.0)
		var got := core.husk_near(a, q)
		for j in GpuLayout.HUSK_QUERIES:
			var f: PackedFloat32Array = got[j]
			var w: float = want[j]
			if w < 0.0:
				right += 1 if f.is_empty() else 0
			else:
				with_one += 1
				right += 1 if f.size() == 5 and absf(Vector2(f[0], f[1]).distance_to(Vector2(q[j * 3], q[j * 3 + 1])) - w) <= 1e-3 * maxf(w, 1.0) else 0
	TestUtil.show(right == 5 * GpuLayout.HUSK_QUERIES, "H at random points the nearest live husk within reach is found, or none (%d of %d right; %d had one within reach)" % [right, 5 * GpuLayout.HUSK_QUERIES, with_one])
	var crossed := 0
	for k in 10:
		var p: Vector2 = lb[k]
		var f: PackedFloat32Array = core.husk_near(a, PackedFloat32Array([p.x, p.y, 0.01]))[0]
		crossed += 0 if f.is_empty() else 1
	TestUtil.show(crossed == 0, "H dish B's husks are not dish A's (%d found)" % crossed)
	core.release()


func _many_husks() -> void:
	var core := SimCore.new()
	var row := core.add_dish(_spec(1, 45000.0, 1 << GpuLayout.DPF_PLANKTON_HUSKS))
	for k in 4:
		core.run(1, 20.0, _plan({row: _husk_rows(50000, 45000.0, 100 + k)}))
	var times: Array = []
	var near_times: Array = []
	var n := 0
	for k in 5:
		var t0 := Time.get_ticks_usec()
		n = core.husk_view(row).size() / 8
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
		t0 = Time.get_ticks_usec()
		core.husk_near(row, PackedFloat32Array([0.0, 0.0, 200.0, 1000.0, 0.0, 200.0, 0.0, 1000.0, 200.0, -1000.0, 0.0, 200.0]))
		near_times.append((Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	near_times.sort()
	TestUtil.show(n == 200000, "C 200,000 husks are listed (%d)" % n)
	print("C [measured] reading 200,000 husks' transforms (6.4 MB): median %.2f ms (min %.2f, max %.2f); a husk_near of 4 places: median %.2f ms" % [times[2], times[0], times[4], near_times[2]])
	core.release()


static func _grid_total(core: SimCore, row: int) -> float:
	var blob := core.gather(row)
	var n := DishGrid.cells_across(core.spec_of(row).radius, core.spec_of(row).resolution)
	var sp := 2.0 * core.spec_of(row).radius / n
	var total := 0.0
	for v: float in blob.conc:
		total += v
	return total * sp * sp


func _drop() -> void:
	var core := SimCore.new()
	var row := core.add_dish(_spec(1, 3000.0))
	core.run(1, 20.0)
	var before := _grid_total(core, row)
	var clouds_before: int = (core._slots_of(row)[0] as PackedFloat32Array).size() / 8
	var spot := Vector2(310.0, -220.0)
	var probe_q := PackedFloat32Array([spot.x, spot.y, 20.0, 50.0])
	var read_before := core.probe(row, probe_q)
	core.queue_edit(row, WorldEdit.drop(spot, 144.0, Dish.scatter_radius(9)))
	core.run(0, 20.0)
	var clouds: PackedFloat32Array = core._slots_of(row)[0]
	var found := false
	for k in clouds.size() / 8:
		if clouds[k * 8] == spot.x and clouds[k * 8 + 1] == spot.y and is_equal_approx(clouds[k * 8 + 2], 144.0) and is_equal_approx(clouds[k * 8 + 3], 100.0):
			found = true
	var after := _grid_total(core, row)
	TestUtil.show(found and clouds.size() / 8 == clouds_before + 1 and absf(after - before) <= 1e-6 * before, "D a dose of 9 over 15 µm is one more cloud at its point (144, variance 100), the grid's total unchanged (%d -> %d clouds; %.4f -> %.4f)" % [clouds_before, clouds.size() / 8, before, after])
	var read_now := core.probe(row, probe_q)
	var want := read_before[3] + 144.0 / (TAU * 100.0)
	TestUtil.show(absf(read_now[3] - want) <= 1e-4 * want, "D with no step run the probe at the dose reads it: %s before, %s after (want %s)" % [String.num_scientific(read_before[3]), String.num_scientific(read_now[3]), String.num_scientific(want)])
	core.run(1, 20.0)
	before = _grid_total(core, row)
	clouds_before = (core._slots_of(row)[0] as PackedFloat32Array).size() / 8
	core.queue_edit(row, WorldEdit.drop(Vector2(-900.0, 400.0), 6400.0, 100.0))
	core.run(0, 20.0)
	after = _grid_total(core, row)
	var clouds_now: int = (core._slots_of(row)[0] as PackedFloat32Array).size() / 8
	TestUtil.show(absf(after - before - 6400.0) <= 1e-5 * after and clouds_now == clouds_before, "D a dose over 100 µm goes onto the cells (total %.3f -> %.3f, clouds %d -> %d)" % [before, after, clouds_before, clouds_now])
	core.release()


func _drop_as_event() -> void:
	var dumps: Array = []
	for as_edit in [true, false]:
		var core := SimCore.new()
		var spec := _spec(1, 3000.0)
		spec.limit = 4000
		spec.founders = Scenario.small(200, 3000.0).seed(9).founder_records(1)
		var row := core.add_dish(spec)
		core.run(5, 20.0)
		var plan := IterationPlan.new()
		if as_edit:
			core.queue_edit(row, WorldEdit.drop(Vector2(310.0, -220.0), 144.0, 15.0))
		else:
			plan.events = {row: {"discs": PackedFloat64Array([1.0, 310.0, -220.0, 144.0, 15.0]), "husks": PackedFloat64Array(), "puffs": PackedFloat64Array(), "deposits": PackedFloat64Array()}}
		core.run(20, 20.0, plan)
		dumps.append(CanonicalDump.coerce(core.canonical_dump(row)))
		print("D the dish after the dose (%s): %d bups, %d clouds" % ["edit" if as_edit else "event", core.count(row), (core._slots_of(row)[0] as PackedFloat32Array).size() / 8])
		core.release()
	var line := SimHarness.diff(dumps[0], dumps[1])
	TestUtil.show(line == "", "D a dose as an edit is the dish a disc event makes, word for word, 20 steps on%s" % (": " + line if line != "" else ""))


func _gradient() -> void:
	var core := SimCore.new()
	var spec := _spec(1, 3000.0)
	var row := core.add_dish(spec)
	var n := DishGrid.cells_across(spec.radius, spec.resolution)
	var sp := 2.0 * spec.radius / n
	var values := PackedFloat32Array()
	values.resize(n * n)
	for cy in n:
		for cx in n:
			values[cy * n + cx] = 5.12e-4 + 5e-8 * ((cx + 0.5) * sp - spec.radius)
	core.set_field(row, values)
	core.run(1, 20.0)
	var p := core.probe(row, PackedFloat32Array([0.0, 0.0, 20.0, 50.0]))
	TestUtil.show(p.size() == GpuLayout.PROBE_FLOATS and absf(p[0] - 1.0) <= 1e-4 and absf(p[1]) <= 1e-4 and absf(p[4] - 5e-8) <= 1e-3 * 5e-8, "G a ramp's gradient: way (%.5f, %.5f), size %s (want 5e-8)" % [p[0] if p.size() > 0 else -1.0, p[1] if p.size() > 1 else -1.0, String.num_scientific(p[4] if p.size() > 4 else -1.0)])
	core.release()


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


## `frames` frames of 1/60 s at `speed`; `each` (if given) is called after each with the frame's number.
static func _frames(thread: SimThread, frames: int, speed: float, paused := false, each := Callable()) -> void:
	for f in frames:
		thread.submit(SimCommand.new(SimCommand.KIND_SET_TIME, {"speed": speed, "paused": paused, "real_dt": 1.0 / 60.0}))
		OS.delay_msec(16)
		if each.is_valid():
			each.call(f)


func _through_thread() -> void:
	var thread := _start(null)
	var spec := _spec(1, 3000.0, 1 << GpuLayout.DPF_PLANKTON_HUSKS)
	spec.founders = Scenario.small(20, 3000.0).seed(31).founder_records(1)
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": spec}))
	var rows := _husk_rows(300, 3000.0, 41)
	var made := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(core: SimCore, map: Dictionary) -> int:
		core.run(1, 20.0, _plan({map[0]: rows}))
		return core.husk_view(map[0]).size() / 8}, made))
	_wait(made)
	var src := WorldEdit.new()
	src.kind = WorldEdit.Kind.PLACE_SOURCE
	src.position = Vector2(100.0, 100.0)
	src.amount = 6.0
	thread.submit(SimCommand.new(SimCommand.KIND_EDIT_WORLD, {"row": 0, "edit": src}))
	var v := ViewRequest.new()
	v.row = 0
	v.camera = Rect2(-3000.0, -3000.0, 6000.0, 6000.0)
	v.pixel_um = 6.0
	v.want_field_view = true
	v.want_husks = true
	thread.submit(SimCommand.new(SimCommand.KIND_SET_VIEW, {"row": 0, "view": v}))
	var first := Vector2(rows[1], rows[2])
	thread.submit(SimCommand.new(SimCommand.KIND_ASK, {"row": 0, "questions": {"husks": [[first.x, first.y, 0.01]]}}))
	var steer_seqs := {}
	var steer_indexes := {}
	var index_seqs := {}  ## index -> seqs it held
	var husks_seen := [-1]
	var tell := func(f: int) -> void:
		var snap: Snapshot = thread.worker.latest()
		var fv := snap.field_view
		if snap.payload != null:
			thread.texture_bound("payload", snap.payload.texture_index, f + 1, snap.payload.seq)
		if fv != null:
			if fv.texture_index >= 0:
				thread.texture_bound("haze", fv.texture_index, f + 1, fv.seq)
			if fv.steer_index >= 0:
				thread.texture_bound("steer", fv.steer_index, f + 1, fv.steer_seq)
				steer_seqs[fv.steer_seq] = true
				steer_indexes[fv.steer_index] = true
				if not index_seqs.has(fv.steer_index):
					index_seqs[fv.steer_index] = {}
				index_seqs[fv.steer_index][fv.steer_seq] = true
		if not snap.husk_view.is_empty() and int(snap.husk_view["row"]) == 0:
			husks_seen[0] = (snap.husk_view["transforms"] as PackedFloat32Array).size() / 8
	_frames(thread, 150, 60.0, false, tell)
	var reused := index_seqs.values().any(func(s: Dictionary) -> bool: return s.size() >= 2)
	TestUtil.show(steer_seqs.size() > 8 and reused, "S the steering picture has its texture and publish: %d publishes over %d textures, one reused: %s" % [steer_seqs.size(), steer_indexes.size(), reused])
	TestUtil.show(made.value() == 300 and husks_seen[0] == 300, "S the snapshots list row 0's 300 husks (%s, %d)" % [made.value(), husks_seen[0]])
	var snap: Snapshot = thread.worker.latest()
	var answers: Array = (snap.answers.get(0, {}) as Dictionary).get("husks", [])
	var f: PackedFloat32Array = answers[0]["found"] if answers.size() == 1 else PackedFloat32Array()
	TestUtil.show(f.size() == 5 and Vector2(f[0], f[1]) == Vector2(float(first.x), float(first.y)) and f[2] == 50.0, "S asked after a husk's place, the answer finds it (%s)" % [f])
	_frames(thread, 5, 60.0, true)
	_settle(thread)
	snap = thread.worker.latest()
	var copy: DishWorldCopy = snap.worlds.get(0)
	var s: Dictionary = copy.sources[0] if copy != null and copy.sources.size() == 1 else {}
	var now: Dictionary = (thread._worlds[0] as DishWorld).copy()
	var exact: float = (now["sources"] as Dictionary).values()[0]["emitted"]
	var guessed: float = float(s.get("emitted", -1.0)) + 6.0 / 60.0 * (float(now["time"]) - (copy.time if copy != null else 0.0))
	TestUtil.show(not s.is_empty() and exact > 10.0 and absf(guessed - exact) <= 1e-6 * exact, "S a source's release from its copy (%.3f at %.1f s) and its rate since is the world's own (%.3f, want %.3f)" % [float(s.get("emitted", -1.0)), copy.time if copy != null else -1.0, guessed, exact])
	thread.stop()


## The husks' list at x10,000: a 45 mm dish of 2,000 founders and 200,000 husks run 3 s with the husks not wanted, then 3 s wanted; the
## publish's time (timing.publish_ms: the pictures, and the husks' read at most every 100 ms) and the achieved speed of each [measured].
func _husks_at_speed() -> void:
	var thread := _start(null)
	var spec := _spec(1, 45000.0, 1 << GpuLayout.DPF_PLANKTON_HUSKS)
	spec.limit = 100000
	spec.founders = Scenario.small(2000, 45000.0).seed(61).founder_records(1)
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": spec}))
	var made := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(core: SimCore, map: Dictionary) -> int:
		for k in 4:
			core.run(1, 20.0, _plan({map[0]: _husk_rows(50000, 45000.0, 200 + k)}))
		return core.husk_view(map[0]).size() / 8}, made))
	_wait(made)
	var out := {}
	for wanted in [false, true]:
		var v := ViewRequest.new()
		v.row = 0
		v.camera = Rect2(-45000.0, -45000.0, 90000.0, 90000.0)
		v.pixel_um = 90.0
		v.want_husks = wanted
		thread.submit(SimCommand.new(SimCommand.KIND_SET_VIEW, {"row": 0, "view": v}))
		var publish: Array = []
		var speeds: Array = []
		var reads := [0, -1]
		_frames(thread, 180, 10000.0, false, func(f: int) -> void:
			var snap: Snapshot = thread.worker.latest()
			if snap.payload != null:
				thread.texture_bound("payload", snap.payload.texture_index, f + 1, snap.payload.seq)
			if f >= 60:
				publish.append(float(snap.timing.get("publish_ms", 0.0)))
				speeds.append(snap.achieved_speed)
			var version := int(snap.husk_view.get("version", -1))
			if version != reads[1]:
				reads[1] = version
				reads[0] += 1)
		publish.sort()
		var mean := 0.0
		for p: float in publish:
			mean += p / publish.size()
		var speed := 0.0
		for s: float in speeds:
			speed += s / speeds.size()
		out[wanted] = [mean, publish[publish.size() * 95 / 100], speed, reads[0]]
	print("C [measured] x10,000, 2,000 bups and 200,000 husks: publish %.2f ms mean (p95 %.2f), achieved x%.0f without the husks; %.2f ms (p95 %.2f), x%.0f with them (%d lists read in 3 s)" % [out[false][0], out[false][1], out[false][2], out[true][0], out[true][1], out[true][2], out[true][3]])
	TestUtil.show(made.value() == 200000, "C the 200,000 husks are in the dish (%s)" % [made.value()])
	thread.stop()


func _numbers_and_clock() -> void:
	if not _store_ok:
		print("SKIP world_gaps_test numbers: no LineageStore in this build")
		return
	var store: Object = ClassDB.instantiate("LineageStore")
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	var thread := _start(store)
	var spec := _spec(1, 1500.0)
	spec.founders = Scenario.small(30, 1500.0).seed(51).founder_records(1)
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": spec}))
	_frames(thread, 30, 600.0)
	var numbers: Array = []
	for dest in [1, 2]:
		var pip := SimReply.new()
		thread.submit(SimCommand.new(SimCommand.KIND_PIPETTE, {"row": 0, "centre": Vector2.ZERO, "radius": 600.0, "new_row": dest}, pip))
		_frames(thread, 5, 600.0)
		_wait(pip)
		numbers.append(int((pip.value() as Dictionary).get("number", -1)) if pip.value() is Dictionary else -1)
	TestUtil.show(numbers == [2, 3], "N the first game's pipettes make dishes 2 and 3 (%s)" % [numbers])
	for row in 3:
		thread.submit(SimCommand.new(SimCommand.KIND_REMOVE_DISH, {"row": row}))
	_frames(thread, 10, 600.0, true)
	_settle(thread)
	TestUtil.show(store.record_count() == 0 and store.claim_count() == 0 and store.tombstone_count() == 0, "N with every dish trashed the store keeps nothing (%d records, %d claims, %d tombstones)" % [store.record_count(), store.claim_count(), store.tombstone_count()])
	var t: float = thread.worker.latest().sim_time
	thread.submit(SimCommand.new(SimThread.KIND_BEGIN_GAME, {"game_began": t}))
	var again := _spec(1, 1500.0)
	again.founders = Scenario.small(30, 1500.0).seed(52).founder_records(1)
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": again}))
	_settle(thread)
	var founder := GpuLayout.id_of(again.founders, 0)
	var info: Dictionary = store.info(founder)
	TestUtil.show(not info.is_empty() and int(info["born"]) == 0, "N a new game's founders are born at minute 0 of its clock (born %s; the world's clock at %.0f s)" % [info.get("born", "none"), t])
	var pip := SimReply.new()
	# (30 founders lie in the game's disc, 40 + 40 sqrt(26) = 244 µm across: a pipette of 600 takes all of them and leaves dish 1 empty; 150 takes about 38% and leaves the rest)
	thread.submit(SimCommand.new(SimCommand.KIND_PIPETTE, {"row": 0, "centre": Vector2.ZERO, "radius": 150.0, "new_row": 1}, pip))
	_frames(thread, 5, 600.0, true)
	_wait(pip)
	var number := int((pip.value() as Dictionary).get("number", -1)) if pip.value() is Dictionary else -1
	TestUtil.show(number == 2, "N a new game's first pipette makes dish 2 (%d)" % number)
	_frames(thread, 20, 600.0)
	_frames(thread, 5, 600.0, true)
	_settle(thread)
	var save := SimReply.new()
	thread.submit(SimCommand.new(SimCommand.KIND_SAVE_ALL, {}, save))
	_wait(save)
	var blob: DishBlob = (save.value() as Array)[0]
	var ts := float(blob.world["time"])
	var kept := GpuLayout.id_of(blob.records, 0)
	var born_saved := int((store.info(kept) as Dictionary).get("born", -1))
	for row in 2:
		thread.submit(SimCommand.new(SimCommand.KIND_REMOVE_DISH, {"row": row}))
	_frames(thread, 20, 600.0)
	_frames(thread, 5, 600.0, true)
	_settle(thread)
	var t2: float = thread.worker.latest().sim_time
	var origin := t + t2 - ts
	thread.submit(SimCommand.new(SimThread.KIND_BEGIN_GAME, {"game_began": origin}))
	thread.submit(SimCommand.new(SimCommand.KIND_THAW, {"row": 0, "blob": blob}))
	_settle(thread)
	store.pin(kept, 99)
	thread.submit(SimCommand.new(SimCommand.KIND_REMOVE_DISH, {"row": 0}))
	_settle(thread)
	var r: Dictionary = store.info(kept)
	var want := int((t2 - origin) / 60.0)  # (int((Ts - T) / 60), in the thread's own arithmetic)
	TestUtil.show(not r.is_empty() and int(r["died"]) == want and int(r["born"]) == born_saved and born_saved >= 0 and t2 > ts + 60.0, "N a loaded game's clock goes on from its save: trashed at once after the thaw, a bup dies at minute %s (want %d, %d by the save's own clock), born %s (saved %d); the world moved on %.0f s" % [r.get("died", "none"), want, int((ts - t) / 60.0), r.get("born", "none"), born_saved, t2 - ts])
	store.unpin(kept, 99)
	thread.stop()


## Waits until the sim thread has drained what was sent and the worker has done what that queued (an inspect's reply, then a quiet frame).
static func _settle(thread: SimThread) -> void:
	var r := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(_core: SimCore, _rows: Dictionary) -> int: return 0}, r))
	_wait(r)
	var until := Time.get_ticks_msec() + 5000
	while thread.worker.queued() > 0 and Time.get_ticks_msec() < until:
		OS.delay_msec(5)
	OS.delay_msec(50)
