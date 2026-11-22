extends SceneTree
## SimCore's calls beyond the step: right-sized reads, set_params, resize, the tracked
## bups' records and the probes, the founders in the family tree, and a refused iteration (the memory budget). Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/core_calls_test.gd
##
## Expected values [derived unless marked]:
## R  reads: `records`, `live_ids` (the `pool_ids` kernel) and `gather`'s field equal what a straight `buffer_get_data` of the same range
##    gives, byte for byte, after 20 steps of a dish of 60 founders beside another dish (a read copies the bytes, nothing else).
## P  set_params: a dish struck with spec Y (feed 0, upkeep 1, limit 1000, no flags) and given X (feed 5, upkeep 1.3, limit 400,
##    stationary and death husks) by set_params before its first step runs as the dish struck with X: 0 differing words after 40 steps
##    (records, field, clouds, husks, DSTATE but the start, events, stats) [derived: the same DISHP words, the cap the limit's since the
##    count is far below it]; Y left alone differs (so the comparison can see it); giving X's own values again after 20 steps changes
##    nothing (0 words after 40); `gather`'s spec has X's values; bloom_density is handed back as not the core's.
## Z  resize (a dish's grid and bodies): growing a 3 mm dish of 200 founders (20 steps run) to 4.5 mm keeps every
##    record byte for byte and the field's total (sum x spacing², the waiting deposits folded in) to within 1e-6 of itself, and the
##    diffusion's passes become max(2, 2 ceil(k_total / 0.4)) of the new spacing; shrinking it to 1.5 mm removes exactly the bups whose
##    centre lies past 1.5 mm (one death event of 56 bytes each), keeps the others (those inside 1.5 mm less half their length byte
##    for byte), leaves none past the new edge and no cloud past it; both run on for 20 steps with WORLD.overflow 0. 300 plankton clouds are
##    dropped over the 4.5 mm dish first (a step of their discs): the ones past 1.5 mm go with the shrink, the others stay.
## T  track: the records of three ids of a dish are its records' first ANSWER_BYTES bytes; an id of the dish beside it and an id no bup
##    has are left out.
## Q  probe: in a dish with no bups and a uniform medium (32 units/mm², no patches, no feed) after one step, a point at the middle reads
##    the uniform concentration (to 1e-5 of it) and no gradient (equal cells stay equal under diffusion, bit for bit), so the way (0, 0)
##    and the chance 0.5, and a gradient of size 0.
## F  founders: their birth events (no parent) give the family tree one record each; export_dish of the founders writes more than 8 bytes
##    and lists them all; after 360 steps (two hours) with each iteration's events applied, every bup with a parent has a chain rooted at a
##    founder, and there are such bups; the
##    chain of every live bup is the same in a store that imports the dish's export (a freeze and thaw's lineage).
## O  a refused iteration: an empty dish whose one step brings 1,500 plankton clouds (1,138 cloud slots) with the budget at the bytes the
##    pool holds: `run` returns 0 steps, OVERFLOW_BUDGET is set, WORLD's overflow 0, the error names the cloud slots, the dish's dump is
##    unchanged; the same with 1,500 plankton husks names the husk slots; with the budget raised again the step runs (the flag stays).
##    Through SimThread: 8,000 founders in a pool of 16,384 slots with the budget at the bytes it holds: the iterations are refused, the
##    thread reports it once (status errors 1, the snapshot's timing["refused_iteration"] set), and a freeze still replies with its blob.
##    Over a second of x600 frames while refused, the world is tried at most 1000 / SimThread.REFUSED_RETRY_MSEC + 1 = 5 times a second
##    [derived: after a refusal of one step the thread waits for a command that may make room or the retry time; a frame's set_time is
##    not such a command].
## S  through SimThread with a LineageStore (the path WorldClient's calls take): a dish of 20 founders run a few iterations and frozen
##    replies with lineage bytes of more than 8 and lineage ids holding every live id of its blob; for a second dish of 40 founders,
##    asking for two of its ids and a probe gives, in a later snapshot, their records (ANSWER_BYTES each, the right ids), a steering
##    Vector3 each and GpuLayout.PROBE_FLOATS (5) floats for the probe; set_params' feed reaches the core's spec; a pipette of a 700 µm disc replies with moved
##    > 0 and new_row 2 while the iterations run on (the new dish's grid is made on the worker pool), and dish 2 is in a later snapshot
##    with that count; resizing the second dish to 400 µm replies with removed > 0 and the core's spec says 400.
## G  a dish that leaves gives its memory back at once, and the warning follows what the dishes need: two dishes of 20,000 bups (limit
##    60,000) run 3 steps, then the pool is grown by hand to 400,000 slots and 200,000 clouds with the budget set to the bytes held over 0.97.
##    The pool holds 0.97 of the budget (the held share would warn) but the dishes need a small part of it [derived: their slots after a
##    step, at most 2 x 20,000 x 2, over FILL, are under a third of 400,000, and the floors of the other classes are the starting sizes]:
##    the need's share is under 0.5 and the warning is "". Freezing one dish and a pass of no steps then makes the pool hold under 0.4 of
##    the bytes it held [derived: the clouds, entries and husks go to 1.5 x the need, over a tenth of what they were, and the slots to
##    the world's count (the frozen dish's blocks are padding until a step) over FILL], never fewer slots than the world's count; the
##    other dish's dump is unchanged by it; one step later the slots hold less than they did, and the dish's dump equals that of a control
##    core that held the dish alone and never shrank. Through SimThread, paused: with the budget at the need of both dishes over 0.95 the
##    snapshot warns "near"; after the freeze the snapshot's need share is under 0.9, its warning "" within 3 s and the bytes the pool holds
##    have fallen.

var _store_ok := ClassDB.class_exists("LineageStore")


func _init() -> void:
	if not SimHarness.begin(self, "core_calls_test", "SimCore's calls"):
		return
	_reads()
	_set_params()
	_resize()
	_track_and_probe()
	_founders()
	_refused()
	_refused_through_thread()
	_memory_fraction()
	_give_back()
	_give_back_through_thread()
	_pipette_room()
	_through_thread()
	TestUtil.finish(self, "OK core_calls_test")


static func _spec(number: int, s: Scenario) -> DishSpec:
	var spec := DishSpec.new()
	spec.number = number
	spec.radius = s.radius
	spec.resolution = s.resolution
	spec.limit = s.limit
	spec.seed = s.seed_value
	spec.flags = s.dish_flags()
	spec.nutrient_density = s.nutrient_density
	spec.feed_density = s.feed_density
	spec.founders = s.founder_records(number)
	return spec


static func _diff(core: SimCore, a: int, other: SimCore, b: int) -> String:
	return SimHarness.diff(CanonicalDump.coerce(core.canonical_dump(a)), CanonicalDump.coerce(other.canonical_dump(b)))


func _reads() -> void:
	var h := SimHarness.make([Scenario.small(60, 1500.0).seed(4), Scenario.small(10, 900.0).seed(5)]).step(20)
	var core: SimCore = h.core
	var start := core.dstate_row(0).decode_u32(GpuLayout.DS_START * 4)
	var n := core.count(0)
	var direct := core.rd.buffer_get_data(core.arena.buf(core._cur("BUPS")), start * GpuLayout.RECORD_BYTES, n * GpuLayout.RECORD_BYTES)
	TestUtil.show(n >= 60 and core.records(0) == direct, "R records of %d bups equal a straight read" % n)
	var ids := PackedInt64Array()
	for i in n:
		ids.append(GpuLayout.id_of(direct, i))
	TestUtil.show(core.live_ids(0) == ids, "R live_ids (pool_ids) equal the records' ids in order")
	var blob := core.gather(0)
	var cd: SimCore.CoreDish = core._dishes[0]
	var conc := core.rd.buffer_get_data(core.arena.buf("CONC"), cd.base * 4, cd.grid.n * cd.grid.n * 4)
	TestUtil.show(blob.conc.to_byte_array() == conc and blob.records == direct, "R gather's field and records equal straight reads")
	core.release()


func _set_params() -> void:
	var y := Scenario.small(30, 2000.0).seed(11)
	y.nutrient_density = 2.0
	var x := y.copy()
	x.feed_density = 5.0
	x.limit = 400
	x.with_flags({"stationary": true, "death_husks": true})
	var want := {"feed_density": 5.0, "upkeep": 1.3, "limit": 400, "flags": x.dish_flags()}
	var cx := SimCore.new()
	var sx := _spec(1, x)
	sx.upkeep = 1.3
	var rx := cx.add_dish(sx)
	var cy := SimCore.new()
	var ry := cy.add_dish(_spec(1, y))
	var rest := cy.set_params(ry, want.merged({"bloom_density": 2.0}))
	TestUtil.show(rest == ["bloom_density"], "P set_params hands back what is not the core's: %s" % [rest])
	var cz := SimCore.new()
	var rz := cz.add_dish(_spec(1, y))
	var cw := SimCore.new()
	var rw := cw.add_dish(sx)
	for c: SimCore in [cx, cy, cz, cw]:
		c.run(20, 20.0)
	cw.set_params(rw, want)
	for c: SimCore in [cx, cy, cz, cw]:
		c.run(20, 20.0)
	var line := _diff(cx, rx, cy, ry)
	TestUtil.show(line == "", "P a dish given X by set_params runs as one struck with X%s" % (": " + line if line != "" else ""))
	TestUtil.show(_diff(cx, rx, cz, rz) != "", "P the dish left with Y differs from X")
	line = _diff(cx, rx, cw, rw)
	TestUtil.show(line == "", "P giving X's own values again changes nothing%s" % (": " + line if line != "" else ""))
	var spec := DishSpec.from_dict(cy.gather(ry).spec)
	TestUtil.show(spec.feed_density == 5.0 and spec.upkeep == 1.3 and spec.limit == 400 and spec.flags == x.dish_flags(), "P gather keeps the new settings")
	TestUtil.show(cx.overflow() == 0 and cy.overflow() == 0, "P no overflow")
	for c: SimCore in [cx, cy, cz, cw]:
		c.release()


func _resize() -> void:
	var s := Scenario.small(200, 3000.0).seed(21)
	s.bloom_density = 3.0
	var h := SimHarness.make([s]).step(20)
	var core: SimCore = h.core
	var before := core.gather(0)
	var cd: SimCore.CoreDish = core._dishes[0]
	var total_before := _total(before, cd.grid)
	var res := core.resize(0, 4500.0)
	var grown := core.gather(0)
	cd = core._dishes[0]
	TestUtil.show(res.get("removed", -1) == 0 and grown.records == before.records, "Z growing keeps all %d records byte for byte" % before.count())
	var total_after := _total(grown, cd.grid)
	TestUtil.show(absf(total_after - total_before) <= 1e-6 * total_before, "Z growing keeps the field's total: %.6f -> %.6f" % [total_before, total_after])
	var k_total := Biology.WATER_DIFFUSION / Biology.MEDIUM_THICKNESS * 20.0 / (cd.grid.spacing * cd.grid.spacing)
	TestUtil.show(cd.grid.radius == 4500.0 and cd.iterations == maxi(2, 2 * ceili(k_total / 0.4)), "Z the diffusion's passes follow the new grid (%d at %.1f um)" % [cd.iterations, cd.grid.spacing])
	h.scenarios[0].radius = 4500.0
	h._worlds[0].radius = 4500.0
	h.step(20)
	TestUtil.show(core.overflow() == 0 and h.invariants().is_empty(), "Z the grown dish runs on: %s" % [h.invariants()])
	var plan := IterationPlan.new()
	var discs := PackedFloat64Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 22
	for k in 300:
		var a := rng.randf() * TAU
		var r := 4000.0 * sqrt(rng.randf())
		discs.append_array(PackedFloat64Array([1.0, r * cos(a), r * sin(a), 50.0, 20.0]))
	plan.events = {0: {"discs": discs, "husks": PackedFloat64Array(), "puffs": PackedFloat64Array(), "deposits": PackedFloat64Array()}}
	core.run(1, 20.0, plan)
	var big := core.gather(0)
	var clouds_inside := 0
	for k in big.clouds.size() / 8:
		if float(big.clouds[k * 8]) * big.clouds[k * 8] + float(big.clouds[k * 8 + 1]) * big.clouds[k * 8 + 1] <= 1500.0 * 1500.0:
			clouds_inside += 1
	var outside := 0
	var mass_um := float(SimConstants.build()["mass_um"])
	var kept_same := {}
	for i in big.count():
		var o := i * GpuLayout.RECORD_BYTES
		var at := Vector2(big.records.decode_float(o + GpuLayout.R_X * 4), big.records.decode_float(o + GpuLayout.R_Y * 4))
		var d := sqrt(float(at.x) * at.x + float(at.y) * at.y)
		if d > 1500.0:
			outside += 1
		elif d <= 1500.0 - 0.5 * big.records.decode_float(o + GpuLayout.R_MASS * 4) * mass_um:
			kept_same[GpuLayout.id_of(big.records, i)] = big.records.slice(o, o + GpuLayout.RECORD_BYTES)
	res = core.resize(0, 1500.0)
	var small := core.gather(0)
	TestUtil.show(outside > 0 and res.get("removed", -1) == outside and small.count() == big.count() - outside, "Z shrinking removes the %d bups past the new edge (%d left)" % [outside, small.count()])
	TestUtil.show((res["deaths"] as PackedByteArray).size() == outside * GpuLayout.DEATH_WORDS * 4, "Z one death event each")
	var same := 0
	var past := 0
	for i in small.count():
		var o := i * GpuLayout.RECORD_BYTES
		var id := GpuLayout.id_of(small.records, i)
		if kept_same.has(id) and kept_same[id] == small.records.slice(o, o + GpuLayout.RECORD_BYTES):
			same += 1
		if Vector2(small.records.decode_float(o + GpuLayout.R_X * 4), small.records.decode_float(o + GpuLayout.R_Y * 4)).length() > 1500.0:
			past += 1
	TestUtil.show(same == kept_same.size() and past == 0, "Z the %d bups well inside are unchanged (%d), none past the edge (%d)" % [kept_same.size(), same, past])
	var clouds_past := 0
	for k in small.clouds.size() / 8:
		if Vector2(small.clouds[k * 8], small.clouds[k * 8 + 1]).length() > 1500.0:
			clouds_past += 1
	TestUtil.show(big.clouds.size() / 8 > clouds_inside and clouds_inside > 0 and clouds_past == 0 and small.clouds.size() / 8 == clouds_inside, "Z the clouds past the edge go (%d of %d before), the %d inside stay (%d)" % [big.clouds.size() / 8 - clouds_inside, big.clouds.size() / 8, clouds_inside, small.clouds.size() / 8])
	h.scenarios[0].radius = 1500.0
	h._worlds[0].radius = 1500.0
	h.step(20)
	TestUtil.show(core.overflow() == 0 and h.invariants().is_empty(), "Z the shrunk dish runs on: %s" % [h.invariants()])
	core.release()


static func _total(blob: DishBlob, grid: DishGrid) -> float:
	var sum := 0.0
	for c in blob.conc.size():
		var lo := blob.dplo.decode_u32(c * 4)
		var hi := blob.dphi.decode_u32(c * 4)
		sum += blob.conc[c] + (float(hi) * 4096.0 + float(lo) * 9.5367431640625e-7) / (grid.spacing * grid.spacing)
	return sum * grid.spacing * grid.spacing


func _track_and_probe() -> void:
	var h := SimHarness.make([Scenario.small(80, 1500.0).seed(31), Scenario.small(20, 1500.0).seed(32)]).step(10)
	var core: SimCore = h.core
	var recs := core.records(0)
	var ids := PackedInt64Array([GpuLayout.id_of(recs, 0), GpuLayout.id_of(recs, 5), GpuLayout.id_of(recs, 9), core.live_ids(1)[0], 1 << 40])
	var got := core.track(0, ids)
	var right := got.size() == 3
	for k in 3:
		var i: int = [0, 5, 9][k]
		right = right and got.get(ids[k], PackedByteArray()) == recs.slice(i * GpuLayout.RECORD_BYTES, i * GpuLayout.RECORD_BYTES + GpuLayout.ANSWER_BYTES)
	TestUtil.show(right, "T track finds the three bups of its dish, record for record, and neither the other dish's nor a missing id (%d found)" % got.size())
	core.release()
	var c := SimCore.new()
	var spec := DishSpec.new()
	spec.number = 1
	spec.radius = 1500.0
	spec.seed = 3
	spec.patchiness = 0.0
	var row := c.add_dish(spec)
	c.run(1, 20.0)
	var p := c.probe(row, PackedFloat32Array([0.0, 0.0, 20.0, 1.0]))
	var uniform := 32.0 * Dish.CONCENTRATION_PER_DENSITY
	TestUtil.show(p.size() == GpuLayout.PROBE_FLOATS and p[4] == 0.0 and absf(p[3] - uniform) <= 1e-5 * uniform and p[0] == 0.0 and p[1] == 0.0 and p[2] == 0.5, "Q a probe at the middle of a uniform medium reads %.4f (want %.4f), way (%.3f, %.3f), chance %.3f" % [p[3] if p.size() > 3 else -1.0, uniform, p[0] if p.size() > 0 else -1.0, p[1] if p.size() > 1 else -1.0, p[2] if p.size() > 2 else -1.0])
	c.release()


func _founders() -> void:
	if not _store_ok:
		print("SKIP core_calls_test founders: no LineageStore in this build")
		return
	var s := Scenario.small(20, 1500.0).seed(41)
	var spec := _spec(1, s)
	var store: Object = ClassDB.instantiate("LineageStore")
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	store.apply_events(SimCore.founder_births(spec.founders, spec.number), PackedByteArray(), 0.0, 0.0)
	var founders := {}
	for i in 20:
		founders[GpuLayout.id_of(spec.founders, i)] = true
	TestUtil.show(store.record_count() == 20, "F the founders' births give the tree %d records" % store.record_count())
	var core := SimCore.new()
	var row := core.add_dish(spec)
	TestUtil.show(store.export_dish(1, core.live_ids(row))["bytes"].size() > 8, "F the export of the founders is more than 8 bytes")
	var t := 0.0
	for k in 18:
		core.run(20, 20.0)
		var d := core.canonical_dump(row)
		store.apply_events(d["births"], d["deaths"], t + 20.0, 20.0)
		t += 400.0
	var recs := core.records(row)
	var rooted := 0
	var with_parents := 0
	for i in recs.size() / GpuLayout.RECORD_BYTES:
		var chain: PackedInt64Array = store.chain(GpuLayout.id_of(recs, i))
		if chain.size() >= 2:
			with_parents += 1
			if founders.has(chain[0]):
				rooted += 1
	TestUtil.show(with_parents > 0 and rooted == with_parents, "F every chain of a bup with a parent is rooted at a founder (%d of %d)" % [rooted, with_parents])
	var live := core.live_ids(row)
	var ex: Dictionary = store.export_dish(1, live)
	var other: Object = ClassDB.instantiate("LineageStore")
	other.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	other.import_bytes(ex["bytes"], PackedInt64Array(), live, 1)
	var same := 0
	for id: int in live:
		if other.chain(id) == store.chain(id) and store.chain(id).size() > 0:
			same += 1
	TestUtil.show(same == live.size(), "F after an export and import every live bup's chain is the same (%d of %d)" % [same, live.size()])
	core.release()


func _refused() -> void:
	for kind: String in ["discs", "husks"]:
		var limits := PoolLimits.new()
		limits.cloud_slots = 256
		limits.husk_slots = 256
		var core := SimCore.new(limits)
		var spec := DishSpec.new()
		spec.number = 1
		spec.radius = 3000.0
		spec.seed = 5
		if kind == "husks":
			spec.flags = 1 << GpuLayout.DPF_PLANKTON_HUSKS
		var row := core.add_dish(spec)
		core.run(1, 20.0)
		limits.memory_budget_bytes = core.arena.bytes_now()
		var rows := PackedFloat64Array()
		var rng := RandomNumberGenerator.new()
		rng.seed = 9
		for k in 1500:
			var a := rng.randf() * TAU
			var r := 2500.0 * sqrt(rng.randf())
			if kind == "discs":
				rows.append_array(PackedFloat64Array([1.0, r * cos(a), r * sin(a), 50.0, 20.0]))
			else:
				rows.append_array(PackedFloat64Array([1.0, r * cos(a), r * sin(a), 50.0]))
		var plan := IterationPlan.new()
		plan.events = {row: {"discs": rows if kind == "discs" else PackedFloat64Array(), "husks": rows if kind == "husks" else PackedFloat64Array(),
			"puffs": PackedFloat64Array(), "deposits": PackedFloat64Array()}}
		var before := CanonicalDump.coerce(core.canonical_dump(row))
		var res := core.run(1, 20.0, plan)
		var want := "cloud slots" if kind == "discs" else "husk slots"
		var err: String = core.errors[-1] if not core.errors.is_empty() else ""
		TestUtil.show(int(res["steps"]) == 0 and (core.overflow() & SimCore.OVERFLOW_BUDGET) != 0 and (core.overflow() & SimCore.OVERFLOW_DEVICE) == 0 and core.world_word(GpuLayout.WD_OVERFLOW) == 0,
			"O %s: the step is refused, OVERFLOW_BUDGET set, no device overflow (steps %d, overflow %d)" % [kind, int(res["steps"]), core.overflow()])
		TestUtil.show(err.contains(want), "O %s: the error names the %s: %s" % [kind, want, err])
		var line := SimHarness.diff(before, CanonicalDump.coerce(core.canonical_dump(row)))
		TestUtil.show(line == "", "O %s: nothing ran (the dump is unchanged)%s" % [kind, ": " + line if line != "" else ""])
		limits.memory_budget_bytes = 6 * 1024 * 1024 * 1024
		res = core.run(1, 20.0, plan)
		TestUtil.show(int(res["steps"]) == 1 and core.overflow() == SimCore.OVERFLOW_BUDGET, "O %s: with room again the step runs; the flag stays (overflow %d)" % [kind, core.overflow()])
		core.release()


## The share of the budget the dish needs reaches the warning: a budget set to the need over 0.95 gives near, over 0.5 gives none; a budget
## at the bytes held gives a held share of 1 (the next growth is then over the budget).
func _memory_fraction() -> void:
	var core := SimCore.new(PoolLimits.new())
	core.add_dish(_spec_small())
	var held := core.arena.bytes_now()
	var need := core.need_bytes()
	core.limits.memory_budget_bytes = int(need / 0.95)
	TestUtil.show(PoolLimits.warning_state({"memory_need_fraction": float(need) / core.limits.memory_budget_bytes}) == PoolLimits.WARN_NEAR, "M a budget just above what the dish needs (%.3f of it) warns" % (float(need) / core.limits.memory_budget_bytes))
	core.limits.memory_budget_bytes = need * 2
	TestUtil.show(PoolLimits.warning_state({"memory_need_fraction": float(need) / core.limits.memory_budget_bytes}) == "", "M twice what it needs gives no warning")
	core.limits.memory_budget_bytes = held
	TestUtil.show(is_equal_approx(core.arena.memory_fraction(), 1.0) and core.arena.next_growth_bytes() > 0 and not core.arena.fits(core.arena.slot_cap * 2, 0, 0, 0, 0), "M at the whole budget the fraction is 1 and the next growth (%d bytes) does not fit" % core.arena.next_growth_bytes())
	core.release()


## Room made ahead for a pipette, and the warm-up pass: once the slots in use pass 0.7 of the capacity the capacity grows for the largest
## dish's pipette (what the pipette itself would ask for), unless the result would pass 0.9 of the budget (then nothing changes); a core
## warmed up before its first dish runs as one that was not (the same canonical dump after the same steps).
func _pipette_room() -> void:
	var limits := PoolLimits.new()
	limits.world_slots = 4096
	var core := SimCore.new(limits)
	var s := Scenario.small(3000, 3000.0).seed(7)
	s.limit = 3000
	var row := core.add_dish(_spec(1, s))
	var used := core.world_word(GpuLayout.WD_SLOTS)
	var cap := core.arena.slot_cap
	var need := used + SimCore._align(core.count(row)) + SimCore.BLK
	print("P pre-grow: used %d of %d slots, a pipette would need %d" % [used, cap, need])
	TestUtil.show(used >= SimCore.PRE_GROW_USE * cap and need > int(SimArena.FILL * cap), "P the scene is past 0.7 and a pipette would need to grow it")
	var budget := limits.memory_budget_bytes
	limits.memory_budget_bytes = core.arena.bytes_now()
	TestUtil.show(not core.prepare_pipette_room() and core.arena.slot_cap == cap and core.errors.is_empty(), "P with no room under the budget nothing is done and nothing is said (cap %d)" % core.arena.slot_cap)
	limits.memory_budget_bytes = int(core.arena.estimate_bytes(core.arena.slot_cap_for(need), core.arena.cell_cap, core.arena.bin_cap, core.arena.cloud_cap, core.arena.husk_cap) / 0.95)
	TestUtil.show(not core.prepare_pipette_room() and core.arena.slot_cap == cap, "P when the growth would leave over 0.9 of the budget held nothing is done")
	limits.memory_budget_bytes = budget
	TestUtil.show(core.prepare_pipette_room() and core.arena.slot_cap >= int(need / SimArena.FILL), "P with room it grows to what the pipette asks for (%d -> %d)" % [cap, core.arena.slot_cap])
	var again := core.arena.slot_cap
	var moved := core.pipette(row, Vector2.ZERO, 1500.0)
	TestUtil.show(not moved.is_empty() and core.arena.slot_cap == again and not core.prepare_pipette_room(), "P the pipette then finds the room (cap stays %d) and nothing more grows" % core.arena.slot_cap)
	core.release()
	var plain := SimCore.new(PoolLimits.new())
	var warmed := SimCore.new(PoolLimits.new())
	warmed.warm_up_pipette()
	var small := Scenario.small(400, 1500.0).seed(9)
	var a := plain.add_dish(_spec(1, small))
	var b := warmed.add_dish(_spec(1, small))
	plain.run(40, 20.0)
	warmed.run(40, 20.0)
	var line := SimHarness.diff(CanonicalDump.coerce(plain.canonical_dump(a)), CanonicalDump.coerce(warmed.canonical_dump(b)))
	TestUtil.show(line == "" and warmed.errors.is_empty(), "P a core warmed up for the pipette runs 40 steps as one that was not%s" % (": " + line if line != "" else ""))
	plain.release()
	warmed.release()


## G (see the header).
func _give_back() -> void:
	var core := SimCore.new(PoolLimits.new())
	var control := SimCore.new(PoolLimits.new())
	var specs: Array[DishSpec] = []
	for k in 2:
		var s := Scenario.small(20000, 3000.0).seed(81 + k)
		s.limit = 60000
		specs.append(_spec(k + 1, s))
	var a := core.add_dish(specs[0])
	var b := core.add_dish(specs[1])
	var c := control.add_dish(specs[0])
	for i in 3:
		core.run(1, 20.0)
		control.run(1, 20.0)
	core.arena.ensure_slots(400000)
	core.arena.ensure_clouds(200000)
	core._after_growth()
	core.limits.memory_budget_bytes = int(core.arena.bytes_now() / 0.97)
	core.run(1, 20.0)
	control.run(1, 20.0)
	var held := core.arena.bytes_now()
	var share := float(core.need_bytes()) / core.limits.memory_budget_bytes
	TestUtil.show(core.arena.memory_fraction() > 0.9 and share < 0.5 and PoolLimits.warning_state({"memory_need_fraction": share}) == "",
		"G the pool holds %.2f of the budget and the dishes need %.2f of it: no warning" % [core.arena.memory_fraction(), share])
	core.freeze(b)
	var after_freeze := float(core.need_bytes()) / core.limits.memory_budget_bytes
	TestUtil.show(after_freeze < share, "G the need falls once a dish leaves (%.3f to %.3f)" % [share, after_freeze])
	var dump := CanonicalDump.coerce(core.canonical_dump(a))
	var slots_before := core.arena.slot_cap
	core.run(0, 20.0, IterationPlan.new())
	var world_slots := core.world_word(GpuLayout.WD_SLOTS)
	TestUtil.show(core.arena.bytes_now() < 0.4 * held and core.arena.slot_cap < slots_before and core.arena.slot_cap >= world_slots,
		"G a pass of no steps gives back at once: the pool holds %d of %d bytes, %d slots of %d (the world counts %d)" % [core.arena.bytes_now(), held, core.arena.slot_cap, slots_before, world_slots])
	TestUtil.show(SimHarness.diff(dump, CanonicalDump.coerce(core.canonical_dump(a))) == "", "G the dish that stayed is unchanged by the pass")
	var slots_paused := core.arena.slot_cap
	core.run(1, 20.0)
	TestUtil.show(core.arena.slot_cap <= slots_paused and not core._leave_owed, "G after a step nothing more is owed (%d slots, %d before the step)" % [core.arena.slot_cap, slots_paused])
	control.run(1, 20.0)
	for i in 3:
		core.run(1, 20.0)
		control.run(1, 20.0)
	var line := _diff(core, a, control, c)
	TestUtil.show(line == "", "G the dish that stayed runs as it does in a pool that never shrank%s" % (": " + line if line != "" else ""))
	core.release()
	control.release()


## G through SimThread, paused.
func _give_back_through_thread() -> void:
	var thread := SimThread.new(PoolLimits.new(), null)
	thread.start()
	var until := Time.get_ticks_msec() + 20000
	while not thread.status()["ready"] and Time.get_ticks_msec() < until:
		OS.delay_msec(10)
	thread.submit(SimCommand.new(SimCommand.KIND_SET_TIME, {"speed": 1.0, "paused": true, "real_dt": 1.0 / 60.0}))
	for k in 2:
		var s := Scenario.small(20000, 3000.0).seed(91 + k)
		s.limit = 60000
		thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": k, "spec": _spec(k + 1, s)}))
	_timing_until(thread, func(t: Dictionary) -> bool: return int(t.get("iterations", 0)) >= 0 and t.has("pool") and int(t["pool_in_use"]["slots"]) >= 40000)
	OS.delay_msec(500)  # (the dishes' first pictures are made, so the need counts them)
	var squeeze := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(core: SimCore, _rows: Dictionary) -> Array:
		core.arena.ensure_slots(400000)
		core.arena.ensure_clouds(200000)
		core._after_growth()
		core._need_bytes = -1
		core.limits.memory_budget_bytes = int(core.need_bytes() / 0.95)
		return [core.arena.bytes_now(), core.limits.memory_budget_bytes]}, squeeze))
	_wait(squeeze)
	var figures: Array = squeeze.value()
	var near := _timing_until(thread, func(t: Dictionary) -> bool: return PoolLimits.warning_state(t) == PoolLimits.WARN_NEAR)
	TestUtil.show(not near.is_empty(), "G through SimThread, two dishes need 0.95 of the budget: the snapshot warns near")
	var freeze := SimReply.new()
	thread.submit(SimCommand.new(SimCommand.KIND_FREEZE, {"row": 1}, freeze))
	_wait(freeze)
	var cleared := _timing_until(thread, func(t: Dictionary) -> bool: return PoolLimits.warning_state(t) == "" and float(t["memory_need_fraction"]) < 0.9)
	TestUtil.show(not cleared.is_empty(), "G paused, the warning is gone within 3 s of the freeze (need share %.2f)" % float(cleared.get("memory_need_fraction", -1.0)))
	var fell := _timing_until(thread, func(t: Dictionary) -> bool: return int(t["pool"]["bytes"]) < 0.6 * int(figures[0]))
	TestUtil.show(not fell.is_empty(), "G paused, the pool's bytes fall from %d (now %d)" % [int(figures[0]), int(thread.worker.latest().timing["pool"]["bytes"])])
	thread.stop()


## The newest snapshot's timing once `test` holds of it (within 3 s), else an empty dictionary.
func _timing_until(thread: SimThread, test: Callable) -> Dictionary:
	var until := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < until:
		var snap: Snapshot = thread.worker.latest()
		if snap != null and not snap.timing.is_empty() and bool(test.call(snap.timing)):
			return snap.timing
		OS.delay_msec(20)
	return {}


func _spec_small() -> DishSpec:
	var spec := DishSpec.new()
	spec.number = 1
	spec.radius = 600.0
	spec.seed = 3
	return spec


func _refused_through_thread() -> void:
	var thread := SimThread.new(PoolLimits.new(), null)
	thread.start()
	var until := Time.get_ticks_msec() + 20000
	while not thread.status()["ready"] and Time.get_ticks_msec() < until:
		OS.delay_msec(10)
	var s := Scenario.small(8000, 3000.0).seed(51)
	s.limit = 1000000
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": _spec(1, s)}))
	var squeeze := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(core: SimCore, _rows: Dictionary) -> int:
		core.limits.memory_budget_bytes = core.arena.bytes_now()
		return core.arena.bytes_now()}, squeeze))
	_wait(squeeze)
	for f in 30:
		thread.submit(SimCommand.new(SimCommand.KIND_SET_TIME, {"speed": 600.0, "paused": false, "real_dt": 1.0 / 60.0}))
		OS.delay_msec(16)
	OS.delay_msec(300)
	var errors: Array = thread.status()["errors"]
	var refusals := errors.filter(func(e: String) -> bool: return e.contains("refused"))
	var snap: Snapshot = thread.worker.latest()
	TestUtil.show(refusals.size() == 1, "O through SimThread the refusal is reported once (%d errors: %s)" % [errors.size(), errors])
	TestUtil.show(snap != null and String(snap.timing.get("refused_iteration", "")).contains("refused"), "O the snapshot says the iterations are refused")
	var tries := _refused_tries_a_second(thread)
	TestUtil.show(tries <= 1000.0 / SimThread.REFUSED_RETRY_MSEC + 1.0, "O a refused world is tried again at most every %d ms, not spun on: %.1f tries a second over 1 s of x600 frames [measured]" % [SimThread.REFUSED_RETRY_MSEC, tries])
	var freeze := SimReply.new()
	thread.submit(SimCommand.new(SimCommand.KIND_FREEZE, {"row": 0}, freeze))
	_wait(freeze)
	TestUtil.show(freeze.is_done() and freeze.error() == "" and freeze.value() is DishBlob and (freeze.value() as DishBlob).count() == 8000, "O a freeze still replies with the dish's blob (%s)" % [freeze.error()])
	thread.stop()
	TestUtil.show(not thread.status()["alive"], "O the thread stops and joins")


func _through_thread() -> void:
	if not _store_ok:
		print("SKIP core_calls_test through SimThread: no LineageStore in this build")
		return
	var store: Object = ClassDB.instantiate("LineageStore")
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	var thread := SimThread.new(PoolLimits.new(), store)
	thread.start()
	var until := Time.get_ticks_msec() + 20000
	while not thread.status()["ready"] and Time.get_ticks_msec() < until:
		OS.delay_msec(10)
	var a := _spec(1, Scenario.small(20, 1500.0).seed(71))
	var b := _spec(2, Scenario.small(40, 1500.0).seed(72))
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": a}))
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 1, "spec": b}))
	var ids := PackedInt64Array([a.founders.size() / GpuLayout.RECORD_BYTES + 4, a.founders.size() / GpuLayout.RECORD_BYTES + 18])  # (the core numbers dish b's founders after a's 20: 21..60)
	thread.submit(SimCommand.new(SimCommand.KIND_ASK, {"row": 1, "questions": {"tracked": Array(ids), "probes": [[0.0, 0.0, 20.0, 1.0]]}}))
	_run_for(thread, 20)
	var freeze := SimReply.new()
	thread.submit(SimCommand.new(SimCommand.KIND_FREEZE, {"row": 0}, freeze))
	_wait(freeze)
	var blob: DishBlob = freeze.value()
	var lineage: PackedByteArray = blob.host.get("lineage", PackedByteArray()) if blob != null else PackedByteArray()
	var exported := PackedInt64Array(blob.host.get("lineage_ids", [])) if blob != null else PackedInt64Array()
	var all_in := blob != null and blob.count() > 0
	for i in (blob.count() if blob != null else 0):
		all_in = all_in and exported.has(GpuLayout.id_of(blob.records, i))
	TestUtil.show(lineage.size() > 8 and all_in, "S a frozen dish's lineage through the thread: %d bytes, %d ids, every live id in it" % [lineage.size(), exported.size()])
	var snap: Snapshot = thread.worker.latest()
	var ans: Dictionary = snap.answers.get(1, {})
	var tracked: Dictionary = ans.get("tracked", {})
	var right := tracked.size() == 2
	for id: int in ids:
		var r: PackedByteArray = tracked.get(id, PackedByteArray())
		right = right and r.size() == GpuLayout.ANSWER_BYTES and SimCore._answer_id(r) == id and (ans.get("steer", {}) as Dictionary).get(id) is Vector3
	TestUtil.show(right and (ans.get("probes", PackedFloat32Array()) as PackedFloat32Array).size() == GpuLayout.PROBE_FLOATS, "S the snapshot answers the tracked bups (%d), their steering and the probe" % tracked.size())
	thread.submit(SimCommand.new(SimCommand.KIND_SET_PARAMS, {"row": 1, "params": {"feed_density": 7.0}}))
	var feed := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(core: SimCore, rows: Dictionary) -> float: return core.spec_of(rows[1]).feed_density}, feed))
	_wait(feed)
	TestUtil.show(is_equal_approx(float(feed.value()), 7.0), "S set_params' feed reaches the core (%s)" % [feed.value()])
	var iterations_before := int(thread.worker.latest().timing.get("iterations", 0))
	var pip := SimReply.new()
	thread.submit(SimCommand.new(SimCommand.KIND_PIPETTE, {"row": 1, "centre": Vector2.ZERO, "radius": 700.0, "new_row": 2}, pip))
	_run_for(thread, 30, pip)
	var value: Dictionary = pip.value() if pip.value() is Dictionary else {}
	var iterations_after := int(thread.worker.latest().timing.get("iterations", 0))
	TestUtil.show(pip.error() == "" and int(value.get("moved", 0)) > 0 and int(value.get("new_row", -1)) == 2, "S a pipette through the thread moved %d bups into row %d (%s)" % [int(value.get("moved", 0)), int(value.get("new_row", -1)), pip.error()])
	print("S iterations while the pipette's grid was made: %d" % (iterations_after - iterations_before))
	_run_for(thread, 10)
	var ds: DishState = thread.worker.latest().dishes.get(2)
	TestUtil.show(ds != null and ds.count > 0, "S the new dish is in a later snapshot (%d bups)" % (ds.count if ds != null else -1))
	var rs := SimReply.new()
	thread.submit(SimCommand.new(SimCommand.KIND_RESIZE, {"row": 1, "radius": 400.0}, rs))
	_wait(rs)
	var radius := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(core: SimCore, rows: Dictionary) -> float: return core.spec_of(rows[1]).radius}, radius))
	_wait(radius)
	var rv: Dictionary = rs.value() if rs.value() is Dictionary else {}
	TestUtil.show(int(rv.get("removed", 0)) > 0 and is_equal_approx(float(radius.value()), 400.0), "S resizing through the thread removed %d bups; the spec says %s um" % [int(rv.get("removed", 0)), radius.value()])
	thread.stop()


## The iterations a refused world is tried (SimThread's `iterations`, which counts refused ones too) a second, over a second of x600
## frames as the game sends them.
static func _refused_tries_a_second(thread: SimThread) -> float:
	var before := int(thread.worker.latest().timing.get("iterations", 0))
	var t0 := Time.get_ticks_msec()
	_run_for(thread, 60)
	OS.delay_msec(50)
	var after := int(thread.worker.latest().timing.get("iterations", 0))
	return (after - before) * 1000.0 / maxf(Time.get_ticks_msec() - t0, 1.0)


## Frames of x600 for `frames` sixtieths of a second (until `reply` is done, when one is given).
static func _run_for(thread: SimThread, frames: int, reply: SimReply = null) -> void:
	for f in frames:
		thread.submit(SimCommand.new(SimCommand.KIND_SET_TIME, {"speed": 600.0, "paused": false, "real_dt": 1.0 / 60.0}))
		OS.delay_msec(16)
	if reply != null:
		_wait(reply)


static func _wait(reply: SimReply) -> void:
	var until := Time.get_ticks_msec() + 20000
	while not reply.is_done() and Time.get_ticks_msec() < until:
		OS.delay_msec(5)
