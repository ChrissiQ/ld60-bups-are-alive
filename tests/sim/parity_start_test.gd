extends SceneTree
## The starting nutrient, the feed and the grid's detail on the real pool:
## dishes struck as the game strikes them (Dish.strike from StartConditions) or added bare (no bups), at ParityGame.PLACE, read back from
## the pool (SimCore.gather). Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_start_test.gd
##
## Expected values, written before the first run [derived unless marked]:
## N  A 3 mm dish struck with 32 units/mm² (100 cells of 60 µm), paused: the grid holds 32 x Dish.CONCENTRATION_PER_DENSITY x (the cells
##    inside the rim) x the cell's area in energy, within 1e-4 relative (DishGrid.filled: the landscape's weights average 1 over the
##    inside cells, each cell rounded to float32). "Area" is the inside cells', not pi R² (they differ by 0.3% here). The game's dish is
##    always patchy (Dish.NUTRIENT_PATCHINESS; there is no even setting), so the patchy total is this same check.
## P  Two dishes struck with the same seed hold the same grid cell for cell; one with another seed holds another landscape (cells differ)
##    with the same total within 1e-4.
## G  45 mm dishes struck with nutrient detail 100, 200 and 400 have grids of 100², 200² and 400² cells (cells_across: 3,600 wanted,
##    capped by the detail).
## F  A bare 3 mm dish (no bups, no nutrient, feed 3 units/mm² an hour) run about an hour at x3,600: the grid gains
##    Dish.feed_per_second(3) x (the world time that passed) x (the sum of the feed's weights: the inside cells' count) x the cell's area,
##    within 1e-3 relative (every step adds feed x delta x weight to each cell; diffusion moves it, keeping the total).

var g: ParityGame


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_start_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_start_test")
		return
	await _starting_nutrient()
	await _detail()
	await _feed()
	TestUtil.finish(self, "OK parity_start_test")


static func _start(radius: float, density: float) -> StartConditions:
	var s := StartConditions.new()
	s.dish_radius = radius
	s.nutrient_density = density
	s.bups = 4
	s.bup_limit = 1000
	s.feed_density = 0.0
	s.bloom_density = 0.0
	return s


static func _inside(blob: DishBlob) -> int:
	var grid := DishGrid.make(float(blob.spec["radius"]), int(blob.spec["resolution"]), float(blob.spec["patchiness"]), int(blob.spec["patch_seed"]))
	return grid.inside_count


func _starting_nutrient() -> void:
	var a: Dish = await g.strike(_start(3000.0, 32.0), 7, 1)
	var b: Dish = await g.strike(_start(3000.0, 32.0), 7, 2)
	var c: Dish = await g.strike(_start(3000.0, 32.0), 8, 3)
	var ba: DishBlob = await g.gather(a)
	var bb: DishBlob = await g.gather(b)
	var bc: DishBlob = await g.gather(c)
	var gs := ParityGame.grid_of(ba)
	var inside := _inside(ba)
	var want := 32.0 * Dish.CONCENTRATION_PER_DENSITY * inside * gs.y * gs.y
	var got := ParityGame.grid_total(ba)
	TestUtil.show(absf(got - want) <= 1e-4 * want and ba.clouds.is_empty(), "N 32 units/mm² in a 3 mm dish: the grid holds %.4f, want %.4f (%d inside cells of %.0f µm; pi R² would give %.4f)" % [got, want, inside, gs.y, 32.0 * Dish.CONCENTRATION_PER_DENSITY * PI * 3000.0 * 3000.0])
	var differ := 0
	for k in bc.conc.size():
		differ += 1 if bc.conc[k] != ba.conc[k] else 0
	var tc := ParityGame.grid_total(bc)
	TestUtil.show(bb.conc == ba.conc and differ > 0 and absf(tc - want) <= 1e-4 * want, "P the same seed gives the same patches (%s); another seed another landscape (%d cells differ) with the same total (%.4f)" % [bb.conc == ba.conc, differ, tc])
	for d in [a, b, c]:
		d.queue_free()
	await g.run_frames(3)


func _detail() -> void:
	var sizes: Array = []
	for res in [100, 200, 400]:
		var s := _start(45000.0, 4.0)
		s.nutrient_resolution = res
		var d: Dish = await g.strike(s, 9, 10 + res)
		var blob: DishBlob = await g.gather(d)
		sizes.append(blob.conc.size())
		d.queue_free()
		await g.run_frames(3)
	TestUtil.show(sizes == [10000, 40000, 160000], "G 45 mm dishes at detail 100, 200, 400: grids of %s cells" % [sizes])


func _feed() -> void:
	var spec := DishSpec.new()
	spec.number = 20
	spec.radius = 3000.0
	spec.limit = 1000
	spec.seed = 13
	spec.nutrient_density = 0.0
	spec.feed_density = 3.0
	var d: Dish = await g.add(spec)
	await g.settle()
	var t0 := g.world.latest().sim_time
	var before: DishBlob = await g.gather(d)
	await g.run_for(d, 3600.0, 3600.0)
	var t1 := g.world.latest().sim_time
	var after: DishBlob = await g.gather(d)
	var gs := ParityGame.grid_of(after)
	var grid := DishGrid.make(3000.0, int(after.spec["resolution"]), float(after.spec["patchiness"]), int(after.spec["patch_seed"]))
	var weights := 0.0
	for w in grid.weights:
		weights += w
	var want := Dish.feed_per_second(3.0) * (t1 - t0) * weights * gs.y * gs.y
	var gain := ParityGame.total(after) - ParityGame.total(before)
	TestUtil.show(t1 - t0 >= 3000.0 and absf(gain - want) <= 1e-3 * want and after.count() == 0, "F a bare dish fed 3 units/mm² an hour for %.0f s gains %.4f, want %.4f (weights %.2f over %d inside cells)" % [t1 - t0, gain, want, weights, grid.inside_count])
	d.queue_free()
	await g.run_frames(3)
