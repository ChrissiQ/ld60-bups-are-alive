extends SceneTree
## Switch checks (windowed: they need a RenderingDevice).
##   godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/switch_check.gd -- bench [reps [clouds]]
##       CPU against GPU, time per step at 2k-50k bups (with `clouds` plankton clouds in the dish, 0 by default): what the Auto rule's
##       costs (Dish.CPU_STEP_MODEL, GPU_STEP_MODEL) were fitted to.
##       BENCH_COUNTS=100000,500000 overrides the crowd sizes; BENCH_CPU_ONLY=1 times the processor alone (for the sizes past what the fit covers).
##   godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/switch_check.gd -- check
##       the state transfer: GPU -> CPU -> GPU round trips, rapid switches, and the saved dictionary.

const Tools := preload("res://tools/gpu/world_tools.gd")

const BENCH_COUNTS := [2000, 5000, 10000, 20000, 50000]
const BENCH_DISHES := [[10000.0, 100], [90000.0, 100], [90000.0, 400]]  ## [radius, nutrient detail]
const BENCH_DELTAS := [1.67, 16.7]


## The GpuWorld of the check: what the pipeline provides to the transfer (the two hooks `export_to_cpu` and `load_from_cpu` call, see
## their comments), made here from readbacks, since a stand-in has no lineage events kernel. A bup that is on the GPU now and was not at the
## last look is a birth (its parent is not known here: 0), one that was and is not is a death, and that is what `_take_unapplied_events`
## hands out, once. The records of a dish that has these events and nothing else are one for each living bup, with no ancestors.
class CheckWorld extends GpuWorld:
	var sets: Array = []
	var known := {}  ## id -> record words of each bup at the last look (what the events are the difference from)
	var resets := 0

	func look(now_seconds: float) -> void:
		var records := gpu.read_bups()
		var words := records.to_float32_array()
		var births := PackedByteArray()
		var deaths := PackedByteArray()
		var seen := {}
		for i in records.size() / GpuSim.RECORD_BYTES:
			var id := GpuSim.id_of(records, i)
			seen[id] = true
			if known.has(id):
				continue
			var o := i * GpuSim.STRIDE
			var e := PackedByteArray()
			e.resize(64)
			e.encode_u32(0, id & 0xFFFFFFFF); e.encode_u32(4, (id >> 32) & 0xFFFFFFFF)
			e.encode_u32(16, 0); e.encode_u32(20, int(words[o + 20])); e.encode_u32(24, int(words[o + 19]))
			for k in [[8, 28], [9, 32], [10, 36], [11, 40], [16, 44], [17, 48], [18, 52], [15, 56], [13, 60]]:
				e.encode_float(k[1], words[o + k[0]])
			births.append_array(e)
		for id: int in known:
			if not seen.has(id):
				var e := PackedByteArray()
				e.resize(GpuLayout.DEATH_WORDS * 4)
				e.encode_u32(GpuLayout.ED_ID_LO * 4, id & 0xFFFFFFFF); e.encode_u32(GpuLayout.ED_ID_HI * 4, (id >> 32) & 0xFFFFFFFF)
				e.encode_u32(GpuLayout.ED_TRAITS * 4, known[id][1]); e.encode_float(GpuLayout.ED_MASS * 4, known[id][0])
				for g in 4:
					e.encode_float((GpuLayout.ED_SPEED + g) * 4, known[id][2 + g])
				deaths.append_array(e)
		known.clear()
		for i in records.size() / GpuSim.RECORD_BYTES:
			known[GpuSim.id_of(records, i)] = _known_of(words, i)
		if births.size() > 0 or deaths.size() > 0:
			sets.append({"births": births, "deaths": deaths, "first_step_end": now_seconds, "step_seconds": 0.0})

	func _take_unapplied_events() -> Array:
		var out := sets
		sets = []
		return out

	func reset_pipeline(bups: int) -> void:
		resets += 1
		sets = []
		known.clear()
		if bups > 0 and not gpu.is_main:  # (a main device has no bups changing here, so nothing needs looking at)
			var records := gpu.rd.buffer_get_data(gpu.buffer("BUPS"), 0, bups * GpuSim.RECORD_BYTES)
			var words := records.to_float32_array()
			for i in bups:
				known[GpuSim.id_of(records, i)] = _known_of(words, i)

	## What a death event of record `i` would say: its mass, its divisions, its four genes.
	static func _known_of(words: PackedFloat32Array, i: int) -> Array:
		var o := i * GpuSim.STRIDE
		return [words[o + GpuLayout.R_MASS], int(words[o + GpuLayout.R_DIVISIONS]), words[o + GpuLayout.R_SPEED], words[o + GpuLayout.R_SENSE], words[o + GpuLayout.R_METABOLISM], words[o + GpuLayout.R_SIZE]]

	func bup_count() -> int:
		var count := [0]  # (a lambda holds a copy of a number: an array is shared)
		_transfer_call(func() -> void: count[0] = gpu.counts()[0])
		return count[0]


var _checks := 0


func _ok(ok: bool, what: String) -> void:
	_checks += 1
	TestUtil.check(ok, what)
	print(("ok   " if ok else "FAIL ") + what)


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var mode: String = a[0] if a.size() > 0 else "check"
	SimConstants.apply()
	if mode == "bench":
		_bench(int(a[1]) if a.size() > 1 else 5, int(a[2]) if a.size() > 2 else 0)
	else:
		_check()
	quit(0 if TestUtil.failures.is_empty() else 1)


# ---- check -------------------------------------------------------------------------------------------------------------------

func _scenario_d() -> StartConditions:
	var sc := StartConditions.new()  # (validate_dynamics.gd's scenario D: a 90 mm dish living on plankton bursts, clouds on the GPU)
	sc.bups = 250; sc.bup_limit = 100000; sc.dish_radius = 90000.0; sc.nutrient_density = 4.0; sc.bloom_density = 2.0
	sc.spread_founders()
	return sc


## `batches` of nine 20 s steps on the GPU of `world` (a local device): the dish's own world (plankton) runs on the CPU with the field
## recording, as validate_dynamics.gd does, and what it did goes to the GPU as events; then the look at the births and deaths.
func _gpu_batches(dish: Dish, world: CheckWorld, batches: int) -> void:
	var was_active := dish.gpu_active
	dish.gpu_active = false  # (the dish's world steps on the CPU here: its GPU path is the pipeline's, not this check's)
	for b in batches:
		var events := GpuSim.WorldEvents.new()
		for st in 9:
			dish.step(20.0)
			events.add_step(dish.field)
		world.gpu.run_steps(9, events.as_dict())
		world.look(dish.time)
	dish.gpu_active = was_active


## What the GPU holds now, read back: {"records", "count", "next_id", "total" (grid and clouds), "clouds"}.
func _gpu_state(world: CheckWorld) -> Dictionary:
	var gpu := world.gpu
	var conc := gpu.read_conc_settled()
	var total := 0.0
	for v in conc:
		total += v
	total *= gpu.spacing * gpu.spacing
	var puffs := gpu.read_puffs()
	for pf: Array in puffs:
		total += pf[2]
	return {"records": gpu.read_bups(), "count": gpu.counts()[0], "next_id": gpu.next_id(), "total": total, "clouds": puffs.size()}


func _ids(records: PackedByteArray) -> PackedInt64Array:
	var out := PackedInt64Array()
	for i in records.size() / GpuSim.RECORD_BYTES:
		out.append(GpuSim.id_of(records, i))
	return out


## How the bups' records differ: "same", or how many words differ and the largest relative difference of a float word (ids and the
## pictures' places, words 0, 21, 22 and 23, are compared as integers).
func _record_diff(a: PackedByteArray, b: PackedByteArray) -> String:
	if a == b:
		return "same"
	if a.size() != b.size():
		return "sizes %d and %d" % [a.size(), b.size()]
	var fa := a.to_float32_array()
	var fb := b.to_float32_array()
	var differ := 0
	var worst := 0.0
	var worst_word := -1
	var id_words := 0
	for i in fa.size():
		var word := i % GpuSim.STRIDE
		if a.decode_u32(i * 4) == b.decode_u32(i * 4):
			continue
		differ += 1
		if word in [0, 21, 22, 23]:
			id_words += 1
			continue
		var rel := absf(fa[i] - fb[i]) / maxf(absf(fa[i]), 1e-30)
		if rel > worst:
			worst = rel
			worst_word = word
	return "%d words differ (%d of them ids or picture places), largest relative %s in word %d" % [differ, id_words, String.num_scientific(worst), worst_word]


## Whether the CPU now holds what `g` (a _gpu_state) was: the bups (count, ids in order), the next id, the field's total, the clouds,
## and a record of each living bup (and, with these events, no other).
func _same_as_gpu(dish: Dish, g: Dictionary, label: String, ancestors := false) -> void:
	var cpu := dish.sim.export_state_bytes()
	_ok(dish.sim.bup_count() == g["count"], "%s: population %d = GPU's %d" % [label, dish.sim.bup_count(), g["count"]])
	_ok(_ids(cpu) == _ids(g["records"]), "%s: the ids are the GPU's, in order" % label)
	_ok(dish.sim.get_next_id() == g["next_id"], "%s: next id %d = GPU's %d" % [label, dish.sim.get_next_id(), g["next_id"]])
	var relative := absf(dish.field.total() - g["total"]) / maxf(absf(g["total"]), 1e-30)
	_ok(relative < 1e-9, "%s: field total (grid and clouds) %.6f vs GPU's %.6f, relative %s" % [label, dish.field.total(), g["total"], String.num_scientific(relative)])
	_ok(dish.field.puff_count() == g["clouds"], "%s: %d clouds = GPU's %d" % [label, dish.field.puff_count(), g["clouds"]])
	var alive := dish.sim.alive_ids()
	_ok(_sorted(alive) == _sorted(_ids(g["records"])), "%s: every living bup has a living record, and no other does (%d records alive)" % [label, alive.size()])
	var records_held: int = dish.sim.lineage_export().size()
	if ancestors:  # (a dish that came from a save has dead ancestors of living bups: records of their own)
		_ok(records_held >= g["count"] and records_held - g["count"] < 100, "%s: lineage_export() has %d records for the GPU's population %d (the saved ancestors are kept)" % [label, records_held, g["count"]])
	else:
		_ok(records_held == g["count"], "%s: lineage_export() has %d records = the GPU's population %d (these events give each bup a record and no ancestors)" % [label, records_held, g["count"]])
	print("     record words, CPU against GPU: ", _record_diff(cpu, g["records"]))


func _sorted(ids: PackedInt64Array) -> Array:
	var out := Array(ids)
	out.sort()
	return out


## A snapshot of the CPU's side: the bups' bytes, the packed field, the next id and the lineage as text.
func _cpu_snapshot(dish: Dish) -> Dictionary:
	return {"state": dish.sim.export_state_bytes(), "packed": dish.field.export_packed(), "next_id": dish.sim.get_next_id(), "lineage": JSON.stringify(dish.sim.lineage_export()), "total": dish.field.total()}


func _same_snapshot(a: Dictionary, b: Dictionary, label: String) -> void:
	_ok(a["state"] == b["state"], "%s: the bups' bytes are identical (%d bups, ids included)" % [label, a["state"].size() / GpuSim.RECORD_BYTES])
	_ok(a["packed"]["conc"] == b["packed"]["conc"] and a["packed"]["puffs"] == b["packed"]["puffs"], "%s: the grid and the clouds are identical (%d clouds)" % [label, a["packed"]["puffs"].size() / 5])
	_ok(a["next_id"] == b["next_id"] and a["lineage"] == b["lineage"], "%s: next id and every family record are identical" % label)


func _check() -> void:
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(1)
	dish.strike(_scenario_d())
	var world := CheckWorld.new(dish.sim, true)
	dish.feed_density = 0.0
	world.load_from_cpu(dish.field, dish._gpu_params())
	_ok(dish.sim.bup_count() == 0 and dish.sim.alive_ids().size() == 250 and dish.field.puff_count() == 0, "load_from_cpu: the CPU's bups are gone, the 250 records stay")
	var loaded := world.bup_count()
	_ok(loaded == 250, "...and the GPU holds the 250 founders (%d)" % loaded)
	world.look(dish.time)
	var started := Time.get_ticks_msec()
	_gpu_batches(dish, world, 180)  # (one sim-hour)
	print("     one sim-hour on the GPU: %d ms" % (Time.get_ticks_msec() - started))

	# 1. GPU -> CPU after an hour: the CPU holds what the GPU's last readback says.
	var g1 := _gpu_state(world)
	_ok(g1["count"] > 250 and g1["clouds"] > 0, "scenario D after 1 sim-hour: %d bups, %d clouds on the GPU (it has divided, and holds clouds)" % [g1["count"], g1["clouds"]])
	world.export_to_cpu(dish.field)
	_same_as_gpu(dish, g1, "export after 1 h")
	var first := _cpu_snapshot(dish)

	# 2. Back to the GPU and out again: byte-identical to the first export.
	world.load_from_cpu(dish.field, dish._gpu_params())
	var g2 := _gpu_state(world)
	_ok(g2["records"] == first["state"] and g2["count"] == g1["count"] and g2["next_id"] == g1["next_id"], "load_from_cpu: the GPU holds exactly the bytes the CPU exported (%s)" % _record_diff(first["state"], g2["records"]))
	world.export_to_cpu(dish.field)
	_same_snapshot(first, _cpu_snapshot(dish), "second export")

	# 3. Ten rapid switches with nothing between them: nothing is lost or changed.
	var worst_total := 0.0
	var identical := true
	for k in 10:
		world.load_from_cpu(dish.field, dish._gpu_params())
		world.export_to_cpu(dish.field)
		var snap := _cpu_snapshot(dish)
		identical = identical and snap["state"] == first["state"] and snap["packed"]["conc"] == first["packed"]["conc"] and snap["packed"]["puffs"] == first["packed"]["puffs"] and snap["lineage"] == first["lineage"] and snap["next_id"] == first["next_id"]
		worst_total = maxf(worst_total, absf(snap["total"] - first["total"]) / first["total"])
	_ok(identical, "10 rapid switches: every bup, every record, the grid, the clouds and the next id as they were")
	_ok(worst_total < 1e-6, "10 rapid switches: field total conserved (worst relative change %s)" % String.num_scientific(worst_total))

	# 3b. What the dish's world did since the last batch went to the GPU (a drop, a burst: recorded by the field, not yet sent) is not lost
	# on the way back: it is added to what the GPU holds.
	world.load_from_cpu(dish.field, dish._gpu_params())
	var before_drop := _gpu_state(world)["total"] as float
	dish.field.add_cloud(Vector2(12000.0, -8000.0), 150.0, 300.0)  # (a cloud: recorded, as the field is recording)
	dish.field.add_cloud(Vector2(-3000.0, 2000.0), 5.0, 80.0)  # (a drop too small to be a cloud: deposited on the grid cells, recorded as cells)
	world.export_to_cpu(dish.field)
	_ok(absf(dish.field.total() - (before_drop + 380.0)) < 1e-6 * before_drop and dish.field.take_recorded_puffs().is_empty(), "export_to_cpu keeps what the field recorded after the last batch: total %.3f = %.3f + 380" % [dish.field.total(), before_drop])

	# 4. Ten switches with time between them, as x1 and x100 alternate: the processor runs 20 fine steps with the bups, the GPU 27 steps.
	var pop_before := dish.sim.bup_count()
	var all_good := true
	var worst_gap := 0.0
	for k in 10:
		for st in 20:
			dish.step(0.2)  # (the fine path)
		var cpu_ids := _sorted(dish.sim.alive_ids())
		var cpu_pop := dish.sim.bup_count()
		var total_before := dish.field.total()
		world.load_from_cpu(dish.field, dish._gpu_params())
		var g := _gpu_state(world)
		all_good = all_good and g["count"] == cpu_pop and _sorted(_ids(g["records"])) == cpu_ids
		worst_gap = maxf(worst_gap, absf(g["total"] - total_before) / total_before)
		_gpu_batches(dish, world, 3)
		var g_out := _gpu_state(world)
		world.export_to_cpu(dish.field)
		all_good = all_good and dish.sim.bup_count() == g_out["count"] and _ids(dish.sim.export_state_bytes()) == _ids(g_out["records"]) and _sorted(dish.sim.alive_ids()) == _sorted(_ids(g_out["records"]))
		worst_gap = maxf(worst_gap, absf(dish.field.total() - g_out["total"]) / g_out["total"])
	_ok(all_good, "10 switches with 20 fine steps on the CPU and 27 on the GPU between them: no bup lost going either way, and a living record for each of the %d that live now (%d before)" % [dish.sim.bup_count(), pop_before])
	_ok(worst_gap < 1e-6, "...field total across each switch within 1e-6 relative (worst %s)" % String.num_scientific(worst_gap))

	# 5. Save with the bups on the GPU, load, go on.
	dish.gpu_world = world
	dish.gpu_active = true
	dish._gpu_on_cpu = true
	dish._mark_gpu_dirty()  # (as an edit would: the CPU's bups go to the GPU)
	_ok(not dish._gpu_on_cpu and world.bup_count() == dish.population() and dish.sim.bup_count() == 0, "_mark_gpu_dirty loads the GPU at once (%d bups)" % world.bup_count())
	_gpu_batches(dish, world, 4)
	var g_save := _gpu_state(world)
	var saved := dish.to_dict()
	_ok(Tools.saved_count(saved) == g_save["count"] and dish._gpu_on_cpu and dish.sim.bup_count() == g_save["count"], "to_dict in GPU mode saves the GPU's %d bups (the state came over first)" % g_save["count"])
	dish.gpu_active = false
	var saved_cpu := dish.to_dict()
	_ok(JSON.stringify(saved) == JSON.stringify(saved_cpu), "the saved dictionary equals the one the CPU path saves for the same exported state")
	var baseline := Dish.new()
	root.add_child(baseline)
	baseline.set_seed(2)
	_ok(baseline.from_dict(JSON.parse_string(JSON.stringify(saved))), "a CPU dish loads it")
	_ok(baseline.sim.alive_ids().size() == Tools.saved_count(saved), "...with a living record for each of its %d bups (the records it has: %d)" % [Tools.saved_count(saved), baseline.sim.alive_ids().size()])
	var baseline_saved := JSON.stringify(baseline.to_dict())
	var reloaded := Dish.new()
	root.add_child(reloaded)
	reloaded.set_seed(3)
	reloaded.gpu_world = CheckWorld.new(reloaded.sim, true)
	reloaded.gpu_active = true
	reloaded._gpu_on_cpu = true
	_ok(reloaded.from_dict(JSON.parse_string(JSON.stringify(saved))), "a dish that is on the GPU loads it")
	var reloaded_world: CheckWorld = reloaded.gpu_world
	_ok(not reloaded._gpu_on_cpu and reloaded_world.bup_count() == g_save["count"] and reloaded.sim.bup_count() == 0, "...and the GPU holds its %d bups at once" % reloaded_world.bup_count())
	_ok(JSON.stringify(reloaded.to_dict()) == baseline_saved, "saving it again from the GPU's copy gives the dictionary the CPU path gives (the round trip through the GPU changes nothing)")
	reloaded._load_gpu()  # (the save above brought the bups to the CPU: the next coarse frame would take them back, as this does)
	_gpu_batches(reloaded, reloaded_world, 3)
	var g_after := _gpu_state(reloaded_world)
	reloaded_world.export_to_cpu(reloaded.field)
	_same_as_gpu(reloaded, g_after, "continued on the GPU after the load", true)

	# 6. The dish's own switching, on the main device (the way the game runs).
	if GpuWorld.available():
		_dish_switching()
	else:
		print("     (the main device cannot run the GPU path here: the dish's own switching was not run)")
	print("%d checks" % _checks)
	TestUtil.finish(self, "SWITCH CHECK OK", "SWITCH CHECK FAILED:")


## Dish._choose_backend and the edits, with a GpuWorld on the main RenderingDevice (the pipeline's hooks as in CheckWorld).
func _dish_switching() -> void:
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(4)
	var sc := _scenario_d()
	sc.bups = 40
	sc.dish_radius = 20000.0
	sc.sim_backend = StartConditions.BACKEND_GPU
	dish.strike(sc)
	var world := CheckWorld.new(dish.sim)
	dish.gpu_world = world
	var pop := dish.sim.bup_count()
	dish._choose_backend(1.67)
	_ok(dish.gpu_active and world.gpu != null and world.gpu.is_main and dish.sim.bup_count() == 0 and world.bup_count() == pop, "main device, setting On: a dish just made goes to the GPU at the first frame, with its %d bups (main device: %s)" % [pop, world.device_name()])
	dish.set_backend_setting(StartConditions.BACKEND_CPU)
	dish._choose_backend(1.67)
	_ok(not dish.gpu_active and dish.sim.bup_count() == pop, "Off brings them back at once")
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	for i in Dish.wait_frames(Dish.RULE_FRAME_SECONDS) - 1:
		dish._choose_backend(1.67)
	_ok(not dish.gpu_active and dish.sim.bup_count() == pop, "On again (the dish is no longer fresh): %d frames in a row, still the processor" % (Dish.wait_frames(Dish.RULE_FRAME_SECONDS) - 1))
	dish._choose_backend(1.67)
	_ok(dish.gpu_active and dish.sim.bup_count() == 0 and world.bup_count() == pop, "...the next one moves the %d bups to the GPU" % pop)
	dish._choose_backend(0.1)
	_ok(dish.gpu_active and world.bup_count() == pop, "a fine step (x1) stays on the GPU (it has a fine path)")
	dish.set_backend_setting(StartConditions.BACKEND_CPU)
	dish._choose_backend(1.67)
	_ok(not dish.gpu_active and dish.sim.bup_count() == pop and dish._gpu_wanted_seconds == 0.0, "the setting Off brings them back at once: %d bups on the CPU" % dish.sim.bup_count())
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	for i in Dish.wait_frames(Dish.RULE_FRAME_SECONDS):
		dish._choose_backend(1.67)
	_ok(dish.gpu_active, "...and On sends them out again after %d frames" % Dish.wait_frames(Dish.RULE_FRAME_SECONDS))
	# Edits while on the GPU.
	var radius_before := dish.radius
	dish.resize_to(radius_before * 1.5)
	_ok(dish.gpu_active and not dish._gpu_on_cpu and world.bup_count() == pop and absf(dish.radius - radius_before * 1.5) < 1.0 and world.gpu.radius == dish.radius, "resize_to on the GPU: a round trip through the CPU, the GPU reloaded with the new dish (radius %.0f)" % world.gpu.radius)
	dish.change_limit(5000)
	_ok(dish.bup_limit == 5000 and world.gpu.limit == 5000 and world.bup_count() == pop, "change_limit on the GPU: the limit is the GPU's too (%d)" % world.gpu.limit)
	var id := dish.add_bup(Vector2(100.0, 100.0), Genome.founder(), Dish.FOUNDER_ENERGY, 1.0)
	_ok(world.bup_count() == pop + 1 and dish.has_bup(id), "add_bup on the GPU: the new bup is in the GPU's %d" % world.bup_count())
	dish.remove_bup(id)
	_ok(world.bup_count() == pop, "remove_bup on the GPU: gone again (%d)" % world.bup_count())
	var saved := dish.to_dict()
	_ok(Tools.saved_count(saved) == pop and dish._gpu_on_cpu, "to_dict on the GPU: %d bups saved, the CPU holds them until the GPU takes them back" % Tools.saved_count(saved))
	dish._choose_backend(1.67)
	_ok(dish.gpu_active and not dish._gpu_on_cpu and world.bup_count() == pop, "the next coarse frame reloads the GPU")
	dish.set_backend_setting(StartConditions.BACKEND_CPU)
	dish._choose_backend(1.67)
	_ok(not dish.gpu_active and dish.sim.bup_count() == pop, "the setting set to Off moves them back at the next frame")
	# Auto at x10,000: the rule's two thresholds (the GPU takes over above AUTO_CPU_UP_USEC, hands back below AUTO_CPU_DOWN_USEC), so a
	# dish whose estimate lies between them stays where it is. Each side is asked of the rule with where the dish is.
	var top := Dish.backend_frame_costs(18.5, dish.field.get_size(), dish.sim.moves_for(18.5), pop, 0, dish.field.puff_count())
	dish.set_backend_setting(StartConditions.BACKEND_AUTO)
	for i in 40:
		dish._choose_backend(18.5)
	var takes_over := Dish.backend_wants_gpu(StartConditions.BACKEND_AUTO, 18.5, dish.sim.moves_for(18.5), dish.field.get_size(), pop, false, true, 0, dish.field.puff_count())
	_ok(dish.gpu_active == takes_over, "Auto with %d bups at x10,000, from the processor (its frame estimated at %.0f µs, the GPU's %.0f; the GPU takes over above %.0f): %s" % [pop, top.x, top.y, Dish.AUTO_CPU_UP_USEC, "the GPU" if takes_over else "the processor"])
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	for i in Dish.wait_frames(Dish.RULE_FRAME_SECONDS):
		dish._choose_backend(1.67)
	_ok(dish.gpu_active, "On again: the GPU after %d coarse frames" % Dish.wait_frames(Dish.RULE_FRAME_SECONDS))
	dish.set_backend_setting(StartConditions.BACKEND_AUTO)
	for i in Dish.AUTO_DOWN_FRAMES:
		dish._choose_backend(18.5)
	var keeps := Dish.backend_wants_gpu(StartConditions.BACKEND_AUTO, 18.5, dish.sim.moves_for(18.5), dish.field.get_size(), pop, true, true, 0, dish.field.puff_count())
	_ok(dish.gpu_active == keeps, "...and from the GPU (it hands back below %.0f µs): %s after %d frames" % [Dish.AUTO_CPU_DOWN_USEC, "the GPU" if keeps else "the processor", Dish.AUTO_DOWN_FRAMES])
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	for i in Dish.wait_frames(Dish.RULE_FRAME_SECONDS):
		dish._choose_backend(1.67)
	# Auto's hand-back, at x100, where the rule wants the processor even from the GPU.
	var x100 := Dish.backend_frame_costs(1.67, dish.field.get_size(), dish.sim.moves_for(1.67), pop, 0, dish.field.puff_count())
	_ok(dish.gpu_active and not Dish.backend_wants_gpu(StartConditions.BACKEND_AUTO, 1.67, dish.sim.moves_for(1.67), dish.field.get_size(), pop, true, true, 0, dish.field.puff_count()), "on the GPU, and Auto's rule wants the processor for %d bups at x100 (its frame estimated at %.0f µs, below %.0f)" % [pop, x100.x, Dish.AUTO_CPU_DOWN_USEC])
	dish.set_backend_setting(StartConditions.BACKEND_AUTO)
	for i in Dish.AUTO_DOWN_FRAMES - 1:
		dish._choose_backend(1.67)
	_ok(dish.gpu_active, "the setting changed to Auto, whose rule wants the processor: %d frames, the GPU still holds them (its count may be late)" % (Dish.AUTO_DOWN_FRAMES - 1))
	dish._choose_backend(1.67)
	_ok(not dish.gpu_active and dish.sim.bup_count() == pop, "...the next one (%d in a row) brings them back" % Dish.AUTO_DOWN_FRAMES)
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	for i in Dish.wait_frames(Dish.RULE_FRAME_SECONDS):
		dish._choose_backend(1.67)
	dish.set_backend_setting(StartConditions.BACKEND_AUTO)
	for i in 5:
		dish._choose_backend(1.67)
	_ok(dish.gpu_active and dish._cpu_votes == 5, "Auto again, wanting the processor: 5 frames counted (%d), the GPU still holds them" % dish._cpu_votes)
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	dish._choose_backend(18.5)
	_ok(dish.gpu_active and dish._cpu_votes == 0, "...and the rule's wait starts again whenever it wants the GPU")
	dish._choose_backend(0.1)
	_ok(dish.gpu_active, "...and a fine step keeps it there (setting On)")
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	for i in Dish.wait_frames(Dish.RULE_FRAME_SECONDS):
		dish._choose_backend(1.67)
	dish.strike(sc)
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	for i in Dish.wait_frames(Dish.RULE_FRAME_SECONDS):
		dish._choose_backend(1.67)
	var fresh_pop := dish.sim.bup_count()
	_ok(dish.gpu_active and world.bup_count() == 40, "a new dish while on the GPU (strike): the GPU holds the new dish's %d bups" % world.bup_count())
	_ok(fresh_pop == 0, "...and the CPU holds none of them")


# ---- bench -------------------------------------------------------------------------------------------------------------------

## A dish with `n` bups spread over most of it, as bench.gd places them (limit = n: the crowd stays about that size).
func _bench_dish(n: int, radius: float, detail: int, clouds: int) -> Dish:
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(3)
	var sc := StartConditions.new()
	sc.bups = 4
	sc.bup_limit = n
	sc.dish_radius = radius
	sc.nutrient_resolution = detail
	sc.nutrient_density = 32.0
	sc.spread_founders()
	dish.strike(sc)
	var born_with := Cell.mass_to_add(Genome.founder())
	for i in n - 4:
		var grown := born_with * (1.0 + dish.sim.random_float())
		dish.sim.add_bup(dish.sim.random_point(radius * 0.95), Genome.founder(), Dish.FOUNDER_ENERGY * dish.sim.random_float(), sqrt(grown), born_with, 0, Vector2.RIGHT)
	for i in clouds:  # (bursts about 60 µm wide, small against any grid cell here: held as clouds)
		dish.field.add_cloud(dish.sim.random_point(radius * 0.95), 60.0, 300.0)
	return dish


func _bench(reps: int, clouds: int) -> void:
	var consts := SimConstants.build()
	var counts: Array = BENCH_COUNTS
	if OS.get_environment("BENCH_COUNTS") != "":
		counts = []
		for text in OS.get_environment("BENCH_COUNTS").split(","):
			counts.append(int(text))
	var cpu_only := OS.get_environment("BENCH_CPU_ONLY") == "1"
	for dish_cfg: Array in BENCH_DISHES:
		for delta: float in BENCH_DELTAS:
			for n: int in counts:
				var dish := _bench_dish(n, dish_cfg[0], dish_cfg[1], clouds)
				var cpu := []
				var none_pos := PackedVector2Array()
				var none_rates := PackedFloat32Array()
				for k in 3:
					dish.sim.step(delta, none_pos, none_rates, 0.0, delta * k)
				for rep in reps:
					var t0 := Time.get_ticks_usec()
					for k in 4:
						dish.sim.step(delta, none_pos, none_rates, 0.0, delta * k)
					cpu.append(float(Time.get_ticks_usec() - t0) / 4.0)
				if cpu_only:
					cpu.sort()
					print("BENCH clouds=%d r=%d cells=%d delta=%.2f N=%d | cpu %.0f us/step (median %.0f, max %.0f)" % [dish.field.puff_count(), dish_cfg[0], dish.field.get_size(), delta, n, cpu[0], cpu[cpu.size() / 2], cpu[cpu.size() - 1]])
					dish.free()
					continue
				var field := dish.field
				var gpu := GpuSim.new()
				var records := dish.sim.export_state_bytes()
				var packed := field.export_packed()
				gpu.load_state(field.get_size(), field.get_spacing(), dish.radius, packed["conc"], field.export_owner(), records, consts, n, field.export_fill_weights(), 0.0, delta, field.get_diffusion(), packed["puffs"], 3, 1.0, dish.sim.get_next_id())
				gpu.run_steps(3)
				var one := []
				var nine := []
				for rep in reps:
					var t1 := Time.get_ticks_usec()
					gpu.run_steps(1)
					one.append(float(Time.get_ticks_usec() - t1))
					var t9 := Time.get_ticks_usec()
					gpu.run_steps(9)
					nine.append(float(Time.get_ticks_usec() - t9))
				cpu.sort(); one.sort(); nine.sort()
				var g1: float = (nine[0] - one[0]) / 8.0  ## marginal us per step; the rest of a one-step batch is the batch's own fixed cost
				var f0: float = one[0] - g1
				print("BENCH clouds=%d r=%d cells=%d delta=%.2f N=%d | cpu %.0f us/step (median %.0f, max %.0f) | gpu1 %.0f us (median %.0f) gpu9 %.0f us (median %.0f) -> marginal %.0f us/step, fixed %.0f us" % [dish.field.puff_count(), dish_cfg[0], dish_cfg[1], delta, n, cpu[0], cpu[cpu.size() / 2], cpu[-1], one[0], one[one.size() / 2], nine[0], nine[nine.size() / 2], g1, f0])
				dish.free()
