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
##    buffer memory falls by about as much once the device has passed the frames a freed buffer waits for (RenderingDevice disposes of a
##    freed buffer when the frame slot it was freed in comes round again: a few submits later) [placeholder: a probe read twice the
##    expected footprint after a 3 GiB buffer was freed].
## C3 edits: a drop of 1,000 units of energy at the centre of an empty dish raises its grid's total (concentration x cell area) by 1,000
##    within 1e-5 relative (float32 sums) [derived]; an eraser of radius 200 µm and strength 1 at the centre takes the share 1 - d / r of
##    the cell under the centre, leaving d / r of what it held (d its centre's distance) [derived, NutrientField::erase_disc].
## C4 publish: the payload, id, haze, steering and thumbnail textures read back equal the storage buffers the kernels wrote, word for word
##    [derived]. The reuse rule [derived: a texture never written is free; a written one is free once the main side has told of a newer
##    publish in use, on a frame more than frame_queue_size + 1 frames before the newest frame it told of]: with no use told, TEXTURES
##    publishes take TEXTURES different textures and the next publishes nothing; told that the newest is in use on frame 10, nothing is
##    published on frame 10 nor on 10 + frame_queue_size + 1, and every kind is on 10 + frame_queue_size + 2, none into the newest's texture.
## C5 lasting clouds: a dish of 20 mm (400 µm cells: a burst's cloud lives about 25 steps, a death's about 40) with 2,000 founders, a bloom
##    of 10 and every flag but plankton husks, alone and among seven random others: equal after every 20 of 300 steps (a plankton floats
##    an hour first, so bursts begin after about 170 steps), with clouds there at the end: about 73 [derived: 2.9 bursts a step x 25
##    steps], so more than 30.
## C6 numbers: dishes 1 and 2; 2 is frozen; a pipette from 1 with no destination makes dish 3 (not 2 again: numbers are never reused);
##    after 2 is thawed and the three run 40 steps, no id is in two dishes [derived: the new dish's ids carry its own number].
## C7 edits and rows: a drop queued on a dish that is then trashed does not reach the dish that takes its row next (its grid total is
##    its start's within 1e-5); a drop queued on a dish that is then frozen is in the blob (the blob's grid total is the total before
##    plus the drop within 1e-5) [derived: the drop adds 1,000 units to the total].
## C8 the budget, set to what the pool holds plus a new dish's field and squares and 1 MB: a pipette of all of a dish of 20,000 bups (its move
##    needs about 40,000 record slots, past the budget) moves nothing and leaves no new dish (the rows are those before); an iteration
##    whose room would pass it runs no step, sets OVERFLOW_BUDGET for good and says why in `errors` [derived].
## C9 overflow inside the buffers: with WORLD's capacities made smaller than what the next steps need (the records' to the first dish's
##    segment, the clouds' and husks' to their tops), the steps raise the overflow flag and nothing is written past the capacities: the
##    slots in use, the clouds' and husks' tops are within them, every dish's segment ends within the records' capacity, and the slots and
##    block-table words past it (both halves, filled beforehand with a mark) keep the mark [derived: the kernels' guards].

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
	c6_numbers()
	c7_edits_and_rows()
	c8_budget()
	c9_overflow_inside()
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
	var mem_now := core.rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)
	for k in 4:
		core._refresh_stats()
	var mem_small := core.rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)
	print("C2 the device's buffer memory right after the shrink %.1f MB, four submits later %.1f MB" % [mem_now / 1048576.0, mem_small / 1048576.0])
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
	ok(is_equal_approx(left, held * d / 200.0), "C3 the eraser left the centre cell at %.6f of %.6f (expected %.6f)" % [left, held, held * d / 200.0])
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
	var taken := {got["payload"]: true}
	var last := got
	for i in SimCore.TEXTURES - 1:
		last = core.publish(view)
		if last.has("payload"):
			taken[last["payload"]] = true
	ok(taken.size() == SimCore.TEXTURES, "C4 with no use told, %d publishes take %d different textures (%d)" % [SimCore.TEXTURES, SimCore.TEXTURES, taken.size()])
	ok(core.publish(view).is_empty(), "C4 then, with no newer publish in use on the main side, nothing is published")
	var newest := core.publish_seq
	var fq := core.limits.frame_queue_size
	for kind: String in last:
		core.texture_bound(kind, last[kind], 10, newest)
	ok(core.publish(view).is_empty(), "C4 the newest in use on frame 10: nothing is published on frame 10")
	core.texture_bound("payload", last["payload"], 10 + fq + 1, newest)
	ok(core.publish(view).is_empty(), "C4 nor on frame 10 + frame_queue_size + 1")
	core.texture_bound("payload", last["payload"], 10 + fq + 2, newest)
	var again := core.publish(view)
	ok(again.size() == last.size() and not again.values().any(func(i: int) -> bool: return last.values().has(i)), "C4 on frame 10 + frame_queue_size + 2 every kind is published, none into the newest's texture (%s, newest %s)" % [again, last])


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


func c6_numbers() -> void:
	var a := Scenario.small(60, 600.0).seed(31)
	a.number = 1
	var b := Scenario.small(60, 600.0).seed(32)
	b.number = 2
	var h := SimHarness.make([a, b])
	var core: SimCore = h.core
	h.step(40)
	var blob: Variant = h.freeze(1)
	var moved := h.pipette(0, Vector2.ZERO, 300.0)
	var dst := h.last_pipette_row
	ok(moved > 0 and dst >= 0 and core.spec_of(dst).number == 3, "C6 the pipette's new dish is number 3 with dish 2 frozen (moved %d, number %d)" % [moved, core.spec_of(dst).number if dst >= 0 else -1])
	var thawed := h.thaw(blob)
	h.step(40)
	var seen := {}
	var twice := 0
	for row: int in core.running_rows():
		for id: int in core.live_ids(row):
			if seen.has(id):
				twice += 1
			seen[id] = true
	ok(thawed >= 0 and twice == 0 and seen.size() > 0, "C6 after the thaw and 40 steps no id is in two dishes (%d ids, %d twice)" % [seen.size(), twice])


func c7_edits_and_rows() -> void:
	var core := SimCore.new()
	var h := SimHarness.new()
	h.core = core
	var keep := Scenario.small(0, 600.0)
	keep.nutrient_density = 4.0
	h.add(keep)
	var gone := Scenario.small(0, 600.0)
	gone.nutrient_density = 4.0
	var row := h.add(gone)
	core.queue_edit(row, WorldEdit.drop(Vector2.ZERO, 1000.0))
	h.remove(row)
	var next := Scenario.small(0, 600.0)
	next.nutrient_density = 4.0
	var again := h.add(next)
	var start := _grid_total(core, again)
	core.run(0, 20.0)
	var now := _grid_total(core, again)
	ok(again == row and absf(now - start) <= 1e-5 * start, "C7 a drop queued on a trashed dish does not reach the dish in its row next (row %d, %.3f -> %.3f)" % [again, start, now])
	var before := _grid_total(core, again)
	core.queue_edit(again, WorldEdit.drop(Vector2.ZERO, 1000.0))
	var blob: Variant = core.freeze(again)
	var n := DishGrid.cells_across(600.0, 100)
	var sp := 1200.0 / n
	var total := 0.0
	for v: float in blob.conc:
		total += v
	total *= sp * sp
	ok(absf(total - before - 1000.0) <= 1e-5 * total, "C7 a drop queued before a freeze is in the blob (%.3f, before it %.3f)" % [total, before])


func c8_budget() -> void:
	var limits := PoolLimits.new()
	limits.world_slots = 256
	var core := SimCore.new(limits)
	var h := SimHarness.new()
	h.core = core
	var src := Scenario.small(20000, 3000.0).seed(41)
	src.limit = 40000
	h.add(src)
	var a := core.arena
	var n := DishGrid.cells_across(3000.0, 100)
	var bins_across := maxi(1, ceili(2.0 * 3000.0 / (0.5 * 6000.0 / n)) + 1)
	limits.memory_budget_bytes = a.estimate_bytes(a.slot_cap, a.cell_cap + ((n * n + 255) / 256) * 256, a.bin_cap + bins_across * bins_across, a.cloud_cap, a.husk_cap) + (1 << 20)  # (1 MB to spare for the new dish; the move needs about 8 MB)
	var rows_before := core.running_rows()
	var reply := core.pipette(0, Vector2.ZERO, 3000.0)
	ok(reply.is_empty() and core.running_rows() == rows_before, "C8 a pipette past the budget moves nothing and leaves no new dish (reply %s, rows %s)" % [reply, core.running_rows()])
	var plan := IterationPlan.new()
	plan.delta = 20.0
	plan.events = {}
	var got := core.run(20, 20.0, plan)
	ok(int(got["steps"]) == 0 and (core.overflow() & SimCore.OVERFLOW_BUDGET) != 0 and not core.errors.is_empty(), "C8 an iteration past the budget runs no step and says so (steps %d, overflow %d, %s)" % [int(got["steps"]), core.overflow(), core.errors])
	limits.memory_budget_bytes = PoolLimits.new().memory_budget_bytes
	core.run(1, 20.0, plan)
	ok((core.overflow() & SimCore.OVERFLOW_BUDGET) != 0, "C8 the refusal stays in overflow() (%d)" % core.overflow())


## Fills buffer `nm` from byte `from` to its end with the byte `mark`.
func _mark(core: SimCore, nm: String, from: int, mark: int) -> void:
	var size: int = core.arena.sizes[nm]
	if from >= size:
		return
	var b := PackedByteArray()
	b.resize(size - from)
	b.fill(mark)
	core.rd.buffer_update(core.arena.buf(nm), from, b.size(), b)


func _marked(core: SimCore, nm: String, from: int, mark: int) -> bool:
	var size: int = core.arena.sizes[nm]
	if from >= size:
		return true
	var b := core.rd.buffer_get_data(core.arena.buf(nm), from, size - from)
	for k in b.size():
		if b[k] != mark:
			return false
	return true


## The first `n` bups of dish `row` with an empty reserve (they die at the next step: the dish has no food).
func _starve(core: SimCore, row: int, n: int) -> void:
	var start := core.dstate_row(row).decode_u32(GpuLayout.DS_START * 4)
	var buf := core.arena.buf(core._cur("BUPS"))
	var zero := PackedByteArray()
	zero.resize(4)
	for i in n:
		core.rd.buffer_update(buf, (start + i) * GpuLayout.RECORD_BYTES + GpuLayout.R_ENERGY * 4, 4, zero)


## Dish 0 (death husks) loses 150 of its 300 bups and dish 1 (deaths give clouds) 40 of its 300 in one step; the next layout (1 block and
## 2) passes the records' capacity, set to dish 0's segment of 2 blocks; the husks' and clouds' capacities are their tops.
func c9_overflow_inside() -> void:
	var first := Scenario.small(300, 900.0).seed(51).with_flags({"death_husks": true})
	var second := Scenario.small(300, 900.0).seed(52)
	for sc: Scenario in [first, second]:
		sc.nutrient_density = 0.0
		sc.limit = 1000
	var h := SimHarness.make([first, second])
	var core: SimCore = h.core
	var plan := IterationPlan.new()
	plan.delta = 20.0
	plan.events = {}
	core.run(4, 20.0, plan)
	core.run(4, 20.0, plan)
	var used := core.world_word(GpuLayout.WD_SLOTS)
	var cap := core.dstate_row(0).decode_u32(GpuLayout.DS_START * 4) + ((core.count(0) + 255) / 256) * 256
	ok(cap < used and core.dstate_row(1).decode_u32(GpuLayout.DS_START * 4) == cap, "C9 the records' capacity %d is dish 0's segment, below the slots in use %d" % [cap, used])
	var clouds := core.world_word(GpuLayout.WD_CLOUD_SLOTS)
	var husks := core.world_word(GpuLayout.WD_HUSK_SLOTS)
	_starve(core, 0, 150)
	_starve(core, 1, 40)
	core._set_wd(GpuLayout.WD_SLOT_CAPACITY, cap)
	core._set_wd(GpuLayout.WD_PUFF_CAPACITY, clouds)
	core._set_wd(GpuLayout.WD_HUSK_CAPACITY, husks)
	var cur := core._cur("BUPS")
	var other := "BUPS2" if cur == "BUPS" else "BUPS"
	var cur_blk := core._cur("BLKDISH")
	var other_blk := "BLKDISH2" if cur_blk == "BLKDISH" else "BLKDISH"
	var marks := [[other, cap * GpuLayout.RECORD_BYTES, 0xAB], [cur, used * GpuLayout.RECORD_BYTES, 0xAB], [other_blk, (cap / 256) * 4, 0xAC], [cur_blk, (used / 256) * 4, 0xAC]]
	for m: Array in marks:
		_mark(core, m[0], m[1], m[2])
	var caps_before := [core.arena.slot_cap, core.arena.cloud_cap, core.arena.husk_cap]
	core.run(2, 20.0, plan)
	ok([core.arena.slot_cap, core.arena.cloud_cap, core.arena.husk_cap] == caps_before, "C9 the arena did not grow (the smaller capacities held)")
	ok((core.overflow() & SimCore.OVERFLOW_DEVICE) != 0, "C9 the steps raised the overflow flag (%d)" % core.overflow())
	var slots := core.world_word(GpuLayout.WD_SLOTS)
	ok(slots <= cap, "C9 the slots in use %d are within the capacity %d" % [slots, cap])
	ok(core.world_word(GpuLayout.WD_CLOUD_SLOTS) <= clouds and core.world_word(GpuLayout.WD_HUSK_SLOTS) <= husks, "C9 the clouds' top %d and the husks' %d are within their capacities %d, %d" % [core.world_word(GpuLayout.WD_CLOUD_SLOTS), core.world_word(GpuLayout.WD_HUSK_SLOTS), clouds, husks])
	var ends_ok := true
	for row: int in core.running_rows():
		if core.dstate_row(row).decode_u32(GpuLayout.DS_START * 4) + core.count(row) > cap:
			ends_ok = false
	ok(ends_ok, "C9 every dish's segment ends within the records' capacity")
	var kept := true
	for m: Array in marks:
		kept = kept and _marked(core, m[0], m[1], m[2])
	ok(kept, "C9 nothing was written past the records' capacity (records and block table, both halves)")
