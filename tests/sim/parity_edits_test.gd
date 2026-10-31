extends SceneTree
## A dose of nutrient, the eraser and edits as the world's events on the real pool, with the resize
## (the field and the bups through a smaller dish and back): a Dish node at ParityGame.PLACE (away from the origin) edited as the screen
## edits it, paused, the pool read before and after each edit (SimCore.gather). Windowed only:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_edits_test.gd
##
## Expected values, written before the first run [derived unless marked]:
## A dish of 3 mm (100 cells of 60 µm; a cloud goes to the grid at half a cell, 30 µm), 32 units/mm², 50 founders, paused throughout.
## D1 A dose of 9 (Dish.drop_nutrients: 144 energy over Dish.scatter_radius(9) = 15 µm; variance max(15² / 4, 100) = 100, sigma 10 < 30)
##    is one more cloud at the click's point exactly (dish-local (310, -220)), mass 144, variance 100; the nutrient's total rises by 144
##    within 1e-4 relative. The bups are unchanged word for word.
## D2 A dose of 400 (6,400 energy over 100 µm, sigma 50 >= 30) goes onto the cells in its disc, an equal share each: the total rises by
##    6,400 within 1e-4 relative, no new cloud, and the added nutrient's centroid lies within a cell (60 µm) of the click (-900, 400).
## E  The eraser (Dish.erase_nutrient, brush 300 µm at the cell centre (330, -210), where D1's cloud lies 22.4 µm off): each inside cell
##    whose centre is within 300 µm keeps (1 - 0.9 (1 - d / 300)) of what it held (the centre cell 0.1 of it), and so does the cloud;
##    nothing else changes (each value within 1e-5 relative of that, in float32 against doubles); the total falls by the sum of what they
##    lost, within 1e-5 relative; the bups are unchanged word for word. erase_nutrient returns 0 (the simulation erases on its own thread:
##    "the total drops by the returned amount" cannot hold, so the drop is checked against the cells instead).
## R  A dish of 1250 µm (100 cells of 25 µm) with 300 founders spread over 0.9 of it, paused. Shrunk to 1000 µm (Dish.resize_to; 80 cells of
##    25 µm, the old grid's cells on the new one's centres): every cell inside the new rim holds the old cell's value there exactly (a
##    bilinear read at a cell centre; no rescale when shrinking), the bups past 1000 µm go (as many as the records say lie past it) and die
##    in the family tree, every other bup keeps its record word for word, or (a bup straddling the rim) is moved in to the rim less half its
##    length. Grown back to 1250 µm: the 1000 µm grid's cells hold their values, but its last row and column, which the resample's clamp (to
##    n - 1.001) reads 0.999 of the way from the cell before; all of them times one factor (the rescale to the old total, within 1e-5 of 1:
##    the clamp's moves over the total), each within 3e-7 relative (float32 rounding of the read and the product); the rest of the new grid holds none, the total is the smaller dish's within 1e-6 relative, the bups are unchanged word for word.

var g: ParityGame


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_edits_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_edits_test")
		return
	var start := StartConditions.new()
	start.dish_radius = 3000.0
	start.bups = 50
	start.bup_limit = 1000
	start.nutrient_density = 32.0
	start.feed_density = 0.0
	start.bloom_density = 0.0
	var dish: Dish = await g.strike(start, 3)
	g.look_at(dish, 0.2)
	var before: DishBlob = await g.gather(dish)
	var spot := Vector2(310.0, -220.0)
	TestUtil.show(dish.drop_nutrients(dish.global_position + spot, 9), "D1 the dose is taken")
	await g.settle()
	var after: DishBlob = await g.gather(dish)
	var found := false
	for k in after.clouds.size() / 8:
		if Vector2(after.clouds[k * 8], after.clouds[k * 8 + 1]) == spot and is_equal_approx(after.clouds[k * 8 + 2], 144.0) and is_equal_approx(after.clouds[k * 8 + 3], 100.0):
			found = true
	var rise := ParityGame.total(after) - ParityGame.total(before)
	TestUtil.show(found and after.clouds.size() == before.clouds.size() + 8 and absf(rise - 144.0) <= 1e-4 * 144.0 and after.records == before.records, "D1 a dose of 9 is one more cloud at %s (found %s; clouds %d -> %d), the total rises by %.6f (want 144), the bups unchanged %s" % [spot, found, before.clouds.size() / 8, after.clouds.size() / 8, rise, after.records == before.records])
	before = after
	var big := Vector2(-900.0, 400.0)
	dish.drop_nutrients(dish.global_position + big, 400)
	await g.settle()
	after = await g.gather(dish)
	rise = ParityGame.total(after) - ParityGame.total(before)
	var gs := ParityGame.grid_of(before)
	var centroid := Vector2.ZERO
	var added := 0.0
	for c in after.conc.size():
		var gain := after.conc[c] - before.conc[c]
		if gain != 0.0:
			centroid += gain * (Vector2(c % int(gs.x), c / int(gs.x)) + Vector2(0.5, 0.5)) * gs.y
			added += gain
	centroid = centroid / added - Vector2.ONE * float(before.spec["radius"]) if added > 0.0 else Vector2.INF
	TestUtil.show(absf(rise - 6400.0) <= 1e-4 * 6400.0 and after.clouds.size() == before.clouds.size() and centroid.distance_to(big) <= gs.y, "D2 a dose of 400 goes onto the cells: the total rises by %.4f (want 6400), clouds %d -> %d, centroid %s (the click %s)" % [rise, before.clouds.size() / 8, after.clouds.size() / 8, centroid, big])
	before = after
	await _erase(dish, before)
	dish.queue_free()
	await g.run_frames(3)
	await _resize()
	TestUtil.finish(self, "OK parity_edits_test")


func _erase(dish: Dish, before: DishBlob) -> void:
	var gs := ParityGame.grid_of(before)
	var n := int(gs.x)
	var sp := gs.y
	var r := float(before.spec["radius"])
	var at := Vector2(330.0, -210.0)
	var brush := 300.0
	var got := dish.erase_nutrient(dish.global_position + at, brush)
	await g.settle()
	var after: DishBlob = await g.gather(dish)
	var grid := DishGrid.make(r, int(before.spec["resolution"]), float(before.spec["patchiness"]), int(before.spec["patch_seed"]))
	var worst := 0.0
	var lost := 0.0
	var centre_share := -1.0
	for c in n * n:
		var want := before.conc[c]
		var p := (Vector2(c % n, c / n) + Vector2(0.5, 0.5)) * sp - Vector2(r, r)
		var d := p.distance_to(at)
		if grid.inside[c] == 1 and d < brush:
			want = before.conc[c] * (1.0 - 0.9 * (1.0 - d / brush))
			if d < 1e-6:
				centre_share = after.conc[c] / before.conc[c]
		lost += before.conc[c] - want
		if want != 0.0 or after.conc[c] != 0.0:
			worst = maxf(worst, absf(after.conc[c] - want) / maxf(absf(want), 1e-30))
	lost *= sp * sp
	var cloud_ok := after.clouds.size() == before.clouds.size()
	for k in before.clouds.size() / 8:
		var m := before.clouds[k * 8 + 2]
		var d := Vector2(before.clouds[k * 8], before.clouds[k * 8 + 1]).distance_to(at)
		var want := m * (1.0 - 0.9 * (1.0 - d / brush)) if d < brush else m
		lost += m - want
		cloud_ok = cloud_ok and absf(after.clouds[k * 8 + 2] - want) <= 1e-5 * maxf(want, 1e-30)
	var fall := ParityGame.total(before) - ParityGame.total(after)
	TestUtil.show(worst <= 1e-5 and cloud_ok and absf(centre_share - 0.1) <= 1e-5, "E the eraser takes its share of every cell and cloud in its brush: worst cell off by %s relative, clouds right %s, the centre cell keeps %.6f (want 0.1)" % [String.num_scientific(worst), cloud_ok, centre_share])
	TestUtil.show(absf(fall - lost) <= 1e-5 * lost and after.records == before.records, "E the total falls by %.4f, what the cells and clouds lost %.4f; the bups unchanged %s" % [fall, lost, after.records == before.records])
	TestUtil.show(got == 0.0, "E erase_nutrient returns %s ('drops by the returned amount' cannot hold: the amount is not known on the main thread)" % got)


func _resize() -> void:
	var spec := DishSpec.new()
	spec.number = 2
	spec.radius = 1250.0
	spec.resolution = StartConditions.MIN_NUTRIENT_RESOLUTION
	spec.limit = 2000
	spec.seed = 21
	spec.nutrient_density = 32.0
	spec.founders = Scenario.small(300, 1250.0).seed(21).founder_records(2)
	var dish: Dish = await g.add(spec)
	await g.settle()
	var big: DishBlob = await g.gather(dish)
	dish.resize_to(1000.0)
	await g.settle()
	var small: DishBlob = await g.gather(dish)
	var gb := ParityGame.grid_of(big)
	var gs := ParityGame.grid_of(small)
	var grid := DishGrid.make(1000.0, StartConditions.MIN_NUTRIENT_RESOLUTION, float(small.spec["patchiness"]), int(small.spec["patch_seed"]))
	var shift := int((1250.0 - 1000.0) / gs.y)
	var cells_ok := gb.y == 25.0 and gs.y == 25.0 and int(gs.x) == 80
	for c in small.conc.size():
		var x := c % int(gs.x)
		var y := c / int(gs.x)
		var want := big.conc[(y + shift) * int(gb.x) + x + shift] if grid.inside[c] == 1 else 0.0
		cells_ok = cells_ok and small.conc[c] == want
	var mass_um := float(SimConstants.build()["mass_um"])
	var past := 0
	var moved := 0
	var same := 0
	var kept := {}
	var by_id := {}
	for i in small.count():
		by_id[GpuLayout.id_of(small.records, i)] = small.records.slice(i * GpuLayout.RECORD_BYTES, (i + 1) * GpuLayout.RECORD_BYTES)
	var gone: Array = []
	var wrong := 0
	for i in big.count():
		var rec := big.records.slice(i * GpuLayout.RECORD_BYTES, (i + 1) * GpuLayout.RECORD_BYTES)
		var id := GpuLayout.id_of(big.records, i)
		var p := Vector2(rec.decode_float(GpuLayout.R_X * 4), rec.decode_float(GpuLayout.R_Y * 4))
		var dist := p.length()
		if dist > 1000.0:
			past += 1
			gone.append(id)
			wrong += 1 if by_id.has(id) else 0
			continue
		var now: PackedByteArray = by_id.get(id, PackedByteArray())
		if dist <= 1000.0 - 0.5 * rec.decode_float(GpuLayout.R_MASS * 4) * mass_um:
			if now == rec:
				same += 1
			else:
				wrong += 1
		else:
			var q := Vector2(now.decode_float(GpuLayout.R_X * 4), now.decode_float(GpuLayout.R_Y * 4)) if now.size() > 0 else Vector2.INF
			if absf(q.length() - (1000.0 - 0.5 * rec.decode_float(GpuLayout.R_MASS * 4) * mass_um)) <= 1e-3:
				moved += 1
			else:
				wrong += 1
	var store := dish.lineage_store()
	var dead := 0
	for id: int in gone:
		var info: Dictionary = store.info(id) if store != null else {}
		dead += 1 if info.is_empty() or not info["alive"] else 0  # (a founder with no living descendant is pruned with its death)
	TestUtil.show(cells_ok, "R shrunk to 1000 µm: every cell inside the new rim holds the old cell's value there exactly (%d cells of %.0f µm)" % [int(gs.x), gs.y])
	TestUtil.show(wrong == 0 and small.count() == big.count() - past and dead == past, "R %d bups past 1000 µm went and died in the family tree (%d dead); %d kept word for word, %d moved in to the rim, %d wrong" % [past, dead, same, moved, wrong])
	dish.resize_to(1250.0)
	await g.settle()
	var again: DishBlob = await g.gather(dish)
	var ga := ParityGame.grid_of(again)
	var back_ok := int(ga.x) == int(gb.x) and ga.y == gb.y
	var grid_big := DishGrid.make(1250.0, StartConditions.MIN_NUTRIENT_RESOLUTION, float(again.spec["patchiness"]), int(again.spec["patch_seed"]))
	var on := int(gs.x)
	var ratios: Array = []
	var outside := 0
	var expected := {}  ## the bigger grid's cell -> what the resample reads there before its rescale
	for c in again.conc.size():
		var x := c % int(ga.x) - shift
		var y := c / int(ga.x) - shift
		if not (x >= 0 and y >= 0 and x < on and y < on and grid_big.inside[c] == 1):
			outside += 1 if again.conc[c] != 0.0 else 0
			continue
		var fx := minf(float(x), on - 1.001)
		var fy := minf(float(y), on - 1.001)
		var x0 := int(fx)
		var y0 := int(fy)
		var j := y0 * on + x0
		var top := small.conc[j] + (small.conc[j + 1] - small.conc[j]) * (fx - x0)
		var bottom := small.conc[j + on] + (small.conc[j + on + 1] - small.conc[j + on]) * (fx - x0)
		expected[c] = top + (bottom - top) * (fy - y0)
		if expected[c] != 0.0:
			ratios.append(again.conc[c] / expected[c])
	ratios.sort()
	var scale: float = ratios[ratios.size() / 2] if not ratios.is_empty() else 0.0
	var worst := 0.0
	for c: int in expected:
		worst = maxf(worst, absf(again.conc[c] - expected[c] * scale) / maxf(absf(expected[c]), 1e-30))
	var t_small := ParityGame.total(small)
	var t_again := ParityGame.total(again)
	TestUtil.show(back_ok and absf(scale - 1.0) <= 1e-5 and worst <= 3e-7 and outside == 0, "R grown back to 1250 µm: the 1000 µm grid's values in place, its last row and column read 0.999 of the way from the cell before, all rescaled by one factor %.8f (off the read by at most %s relative); none around them (%d cells hold some)" % [scale, String.num_scientific(worst), outside])
	TestUtil.show(absf(t_again - t_small) <= 1e-6 * t_small and again.records == small.records, "R grown back: total %.4f -> %.4f (within 1e-6); the bups unchanged %s" % [t_small, t_again, again.records == small.records])
