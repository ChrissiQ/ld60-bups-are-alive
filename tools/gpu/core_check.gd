extends SceneTree
## SimCore's own checks beyond the sim tests (tests/sim/*): the arena's growth and shrinking, the field edits, the publish into the shared
## textures, and a dish whose clouds last (the sim tests' dishes hand theirs to the grid within a step or two). Windowed, through the lock:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/core_check.gd
##
## Expected values, written before the first run:
## C1 growth: a dish with every flag but plankton husks (200 founders, 900 µm, a bloom) among six random others, in a pool started at 256
##    of everything (it grows several times) and in one started big: every dish's dump equal after every 20 of 100 steps, WORLD's overflow 0
##    in both [derived: a growth copies what the buffers hold and moves nothing; a dish's run does not depend on the pool's sizes].
## C2 shrink: a dish of 300,000 founders taken out of a pool that then runs a small dish: the record slots shrink to the limits' floor or
##    twice the slots in use, and the buffers the arena holds fall by the slots' share (380 B a slot) [derived]; the device's own count of
##    buffer memory falls by about as much [placeholder: a probe read twice the expected footprint after a 3 GiB buffer was freed].
## C3 edits: a drop of 1,000 units of energy at the centre of an empty dish raises its grid's total (concentration x cell area) by 1,000
##    within 1e-5 relative (float32 sums) [derived]; an eraser of radius 200 µm and strength 1 at the centre leaves the cell under the
##    centre at 1 - d / r of what it held (d its centre's distance) [derived, NutrientField::erase_disc].
## C4 publish: the payload, id, haze, steering and thumbnail textures read back equal the storage buffers the kernels wrote, word for word
##    [derived]; with every texture bound on the main side's frame now, nothing is published (no free texture) [derived].
## C5 lasting clouds: a dish of 20 mm (400 µm cells: a burst's cloud lives about 25 steps, a death's about 40) with 2,000 founders, a bloom
##    of 10 and every flag but plankton husks, alone and among seven random others: equal after every 20 of 300 steps (a plankton floats
##    an hour first, so bursts begin after about 170 steps), with clouds there at the end: about 73 [derived: 2.9 bursts a step x 25
##    steps], so more than 30.

var fails := 0


func ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		fails += 1


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	c1_growth()
	c2_shrink()
	c3_edits()
	c4_publish()
	c5_lasting_clouds()
	print("CORE CHECK %s (%.1f s)" % ["OK" if fails == 0 else "FAILED (%d)" % fails, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(0 if fails == 0 else 1)


func _x(radius: float, founders: int, number: int) -> Scenario:
	var x := Scenario.small(founders, radius).seed(17).with_all_flags()
	x.flags["plankton_husks"] = false
	x.bloom_density = 10.0
	x.number = number
	return x


func _others(n: int, seed_v: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var out: Array = []
	for i in n:
		var o := Scenario.random_other(rng)
		o.number = 2 + i
		out.append(o)
	return out


## Two harnesses over the same scenarios stepped side by side: every dish's dump compared after every 20 of `steps` steps.
func _same_runs(name: String, a: SimHarness, b: SimHarness, steps: int) -> void:
	for k in steps / 20:
		a.step(20)
		b.step(20)
		var line := ""
		for row in a.scenarios:
			line = SimHarness.diff(a.dump(row), b.dump(row))
			if line != "":
				line = "row %d: %s" % [row, line]
				break
		ok(line == "", "%s after %d steps: %s" % [name, (k + 1) * 20, line if line != "" else "same"])
		if line != "":
			return


func c1_growth() -> void:
	var dishes: Array = [_x(900.0, 200, 1)]
	dishes.append_array(_others(6, 77))
	var small := PoolLimits.new()
	small.world_slots = 256
	small.field_cells = 256
	small.cloud_slots = 256
	small.husk_slots = 256
	small.bins = 256
	var a := SimHarness.make(dishes.map(func(s: Scenario) -> Scenario: return s.copy()))
	var b := SimHarness.new()
	b.core = SimCore.new(small)
	for s: Scenario in dishes:
		b.add(s.copy())
	var caps := "slots %d, cells %d, clouds %d, husks %d" % [b.core.arena.slot_cap, b.core.arena.cell_cap, b.core.arena.cloud_cap, b.core.arena.husk_cap]
	_same_runs("C1 a pool grown from 256 against one made big", a, b, 100)
	print("C1 the small pool after its dishes were added: %s; after 100 steps: slots %d, clouds %d, husks %d, events %d" % [caps, b.core.arena.slot_cap, b.core.arena.cloud_cap, b.core.arena.husk_cap, b.core.arena.event_cap])
	ok(a.core.overflow() == 0 and b.core.overflow() == 0, "C1 WORLD's overflow 0 in both")


func c2_shrink() -> void:
	var core := SimCore.new()
	var big := Scenario.small(300000, 20000.0).seed(5)
	big.limit = 400000
	var h := SimHarness.new()
	h.core = core
	var row := h.add(big)
	h.step(1)
	var mem_big := core.rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)
	var arena_big := core.arena.bytes_now()
	var slots_big := core.arena.slot_cap
	h.remove(row)
	h.add(Scenario.small(50, 600.0).seed(6))
	core.arena.shrink_after_msec = 0
	h.step(2)
	h.step(2)
	var mem_small := core.rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)
	var arena_small := core.arena.bytes_now()
	var freed_expected := (slots_big - core.arena.slot_cap) * 380
	print("C2 record slots %d -> %d; the arena's buffers %.1f -> %.1f MB (expected a fall of about %.1f MB); the device's buffer memory %.1f -> %.1f MB" % [slots_big, core.arena.slot_cap, arena_big / 1048576.0, arena_small / 1048576.0, freed_expected / 1048576.0, mem_big / 1048576.0, mem_small / 1048576.0])
	ok(core.arena.slot_cap < slots_big and core.arena.slot_cap <= maxi(PoolLimits.new().world_slots, 2 * core.world_word(GpuLayout.WD_SLOTS) + 256), "C2 the record slots shrank")
	ok(absf(float(arena_big - arena_small) - freed_expected) <= 0.05 * freed_expected, "C2 the arena's buffers fell by the slots' share")
	ok(mem_big - mem_small >= 0.8 * freed_expected, "C2 the device's buffer memory fell by at least 0.8 of that (%.1f MB)" % ((mem_big - mem_small) / 1048576.0))
	ok(h.invariants().is_empty() and core.overflow() == 0, "C2 the small dish runs on after the shrink")


func _grid_total(core: SimCore, row: int) -> float:
	var d := core.canonical_dump(row)
	var f: PackedByteArray = d["field"]
	var g := core.spec_of(row)
	var n := DishGrid.cells_across(g.radius, g.resolution)
	var sp := 2.0 * g.radius / n
	var t := 0.0
	for i in n * n:
		t += f.decode_float(i * 4)
	return t * sp * sp


func c3_edits() -> void:
	var core := SimCore.new()
	var s := Scenario.small(0, 600.0)
	s.nutrient_density = 4.0
	var h := SimHarness.new()
	h.core = core
	var row := h.add(s)
	var before := _grid_total(core, row)
	ok(core.queue_edit(row, WorldEdit.drop(Vector2.ZERO, 1000.0)), "C3 a drop is the core's edit")
	core.run(0, 20.0)
	var after := _grid_total(core, row)
	ok(absf(after - before - 1000.0) <= 1e-5 * after, "C3 a drop of 1,000 raised the grid's total %.3f -> %.3f" % [before, after])
	var n := DishGrid.cells_across(600.0, 100)
	var sp := 1200.0 / n
	var c := (n / 2) * n + n / 2
	var cx := (n / 2 + 0.5) * sp - 600.0
	var held: float = core.canonical_dump(row)["field"].decode_float(c * 4)
	core.queue_edit(row, WorldEdit.erase(Vector2.ZERO, 200.0, 1.0))
	core.run(0, 20.0)
	var left: float = core.canonical_dump(row)["field"].decode_float(c * 4)
	var d := sqrt(2.0) * cx
	ok(is_equal_approx(left, held * (1.0 - d / 200.0)), "C3 the eraser left the centre cell at %.6f of %.6f (expected %.6f)" % [left, held, held * (1.0 - d / 200.0)])
	var e := WorldEdit.new()
	e.kind = WorldEdit.Kind.PLACE_SOURCE
	ok(not core.queue_edit(row, e) and e.as_world_op()["op"] == "add_source", "C3 a source is the dish's world's edit, not the core's")


func c4_publish() -> void:
	var h := SimHarness.make([Scenario.small(300, 900.0).seed(3).with_all_flags()])
	h.step(20)
	var core: SimCore = h.core
	var view := ViewRequest.new()
	view.row = 0
	view.want_field_view = true
	view.want_thumbnails = true
	core.texture_bound("payload", 0, 0)
	var got := core.publish(view)
	ok(got.has("payload") and got.has("haze") and got.has("steer") and got.has("thumbs"), "C4 every kind was published: %s" % [got])
	if not got.has("payload"):
		return
	var pay: RID = core.textures("payload")[got["payload"]]
	var ids: RID = core.textures("ids")[got["payload"]]
	var texels := core.rd.texture_get_data(pay, 0).size() / GpuLayout.PAYLOAD_BYTES
	ok(core.rd.texture_get_data(pay, 0) == core.rd.buffer_get_data(core.arena.buf("PAYLOAD"), 0, texels * GpuLayout.PAYLOAD_BYTES), "C4 the payload texture is the PAYLOAD buffer (%d texels)" % texels)
	ok(core.rd.texture_get_data(ids, 0) == core.rd.buffer_get_data(core.arena.buf("IDTEX"), 0, texels * GpuLayout.IDT_BYTES), "C4 the id texture is the IDTEX buffer")
	var n := DishGrid.cells_across(900.0, 100)
	for pair in [["haze", "HAZEPIX"], ["steer", "STEERPIX"]]:
		var tex: RID = core.textures(pair[0])[got[pair[0]]]
		ok(core.rd.texture_get_data(tex, 0) == core.rd.buffer_get_data(core.arena.buf(pair[1]), 0, n * n * 4), "C4 the %s texture is the %s buffer" % pair)
	var thumbs: RID = core.textures("thumbs")[got["thumbs"]]
	ok(core.rd.texture_get_data(thumbs, 0) == core.rd.buffer_get_data(core.arena.buf("THUMBS")), "C4 the thumbnail atlas is the THUMBS buffer")
	var recs: PackedByteArray = h.dump(0)["records"]
	var px := core.rd.texture_get_data(pay, 0)
	ok(px.decode_u32(GpuLayout.PL_X * 4) == recs.decode_u32(GpuLayout.R_X * 4) and px.decode_u32(GpuLayout.PL_Y * 4) == recs.decode_u32(GpuLayout.R_Y * 4), "C4 the first texel is the first bup's place")
	for kind in ["payload", "haze", "steer", "thumbs"]:
		for i in SimCore.TEXTURES:
			core.texture_bound(kind, i, 10)
	ok(core.publish(view).is_empty(), "C4 with every texture bound this frame nothing is published")


func c5_lasting_clouds() -> void:
	var x := _x(20000.0, 2000, 1)
	x.limit = 20000
	var lone := SimHarness.make([x.copy()])
	var all: Array = [x.copy()]
	all.append_array(_others(7, 99))
	var pool := SimHarness.make(all)
	for k in 15:
		lone.step(20)
		pool.step(20)
		var line := SimHarness.diff(lone.dump(0), pool.dump(0))
		var clouds: int = lone.dump(0)["clouds"].size() / 32
		ok(line == "", "C5 the lasting clouds' dish among seven others after %d steps (%d clouds): %s" % [(k + 1) * 20, clouds, line if line != "" else "same"])
		if line != "":
			return
	ok(lone.dump(0)["clouds"].size() / 32 > 30, "C5 the dish has clouds that last")
	ok(pool.invariants().is_empty(), "C5 the pool's invariants hold")
