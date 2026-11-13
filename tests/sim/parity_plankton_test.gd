extends SceneTree
## A plankton placed by hand floats, then bursts into a cloud that spreads into the grid, and the bloom's timing, on the real pool: a bare 20 mm dish (no bups, no nutrient, no feed) at ParityGame.PLACE, the plankton seen as the screen sees them
## (Dish.plankton, from the world's copies), the nutrient read from the pool (SimCore.gather). Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_plankton_test.gd
##
## Expected values [derived unless marked]:
## The dish: 20 mm, 100 cells of 400 µm; a cloud goes to the grid once its sigma reaches half a cell (200 µm); D = 600 / 25 = 24 µm²/s.
## L  A plankton placed with Dish.place_plankton shows in the dish's next copy, born at the world's time then, and bursts between 0.5 and
##    1.5 of PLANKTON_MEAN_LIFE (1,800 to 5,400 s) later (its burst_at).
## B  Run at x3,600 (steps of 20 s): it is still floating at every snapshot before burst_at and gone at the first snapshot past
##    burst_at + BURST_CHECK_SECONDS + a step (the look-overs are a minute apart, each at a step's end).
## C  At once after the burst, paused: one cloud of PLANKTON_UNITS x 16 = 4,800 energy (a disc of 250 µm: variance 250² / 4, sigma
##    125 < 200, so a cloud), the dish's nutrient 4,800 within 1e-3 relative.
## S  The cloud reaches 200 µm after (200² - 125²) / (2 x 24) = 508 s: about 700 s on, paused, there is no cloud and the grid holds the
##    4,800 within 1e-3 relative (the hand-over's deposits are fixed point: 2^-20 of a concentration unit, 0.15 energy, a cell).
## A  Bloom 1 a mm² a day on the 20 mm dish (pi x 20² = 1,257 a day: one every 68.75 s), run about 1,000 s at x600 (steps of 5 s): each
##    plankton arrives at the end of the first step at or after its due time, so the k-th after the first is born k x 68.75 s after it
##    within a step (5 s).

var g: ParityGame


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_plankton_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_plankton_test")
		return
	var spec := DishSpec.new()
	spec.number = 1
	spec.radius = 20000.0
	spec.limit = 1000
	spec.seed = 17
	spec.nutrient_density = 0.0
	var d: Dish = await g.add(spec)
	g.look_at(d, 0.02)
	await _burst(d)
	await _bloom(d)
	TestUtil.finish(self, "OK parity_plankton_test")


func _burst(d: Dish) -> void:
	var t_placed := g.world.latest().sim_time
	TestUtil.show(d.place_plankton(d.global_position + Vector2(1000.0, -2000.0)), "L the plankton is taken")
	await g.settle()
	var p: Plankton = d.plankton[0] if d.plankton.size() == 1 else null
	var life := p.burst_at - p.born_at if p != null else -1.0
	TestUtil.show(p != null and is_equal_approx(p.born_at, t_placed) and life >= 0.5 * Dish.PLANKTON_MEAN_LIFE and life <= 1.5 * Dish.PLANKTON_MEAN_LIFE, "L the dish's copy shows it, born at %s (placed at %s), bursting %.0f s later" % [p.born_at if p != null else -1.0, t_placed, life])
	if p == null:
		return
	var last_seen := d.time
	var gone_at := -1.0
	var early := false
	for k in 4000:
		await g.frame(3600.0, false)
		var now := d.time  # (the time of the snapshot the dish last took: world.latest() may be newer than what the screen has seen)
		if d.plankton.is_empty():
			gone_at = now
			break
		last_seen = now
		early = early or now > p.burst_at + Dish.BURST_CHECK_SECONDS + Dish.MAX_STEP
	await g.settle()
	TestUtil.show(gone_at >= p.burst_at and not early and last_seen < p.burst_at + Dish.BURST_CHECK_SECONDS + Dish.MAX_STEP, "B it floats until its time (last seen at %.0f s, gone at %.0f s; due %.0f s)" % [last_seen, gone_at, p.burst_at])
	var blob: DishBlob = await g.gather(d)
	var energy := Dish.PLANKTON_UNITS * Dish.NUTRIENT_ENERGY
	var total := ParityGame.total(blob)
	TestUtil.show(blob.clouds.size() == 8 and absf(total - energy) <= 1e-3 * energy, "C at once after the burst (%.0f s): %d cloud, the dish holds %.4f (want %.0f)" % [d.time, blob.clouds.size() / 8, total, energy])
	var t_burst := d.time
	await g.run_for(d, 700.0, 600.0)
	blob = await g.gather(d)
	var grid := ParityGame.grid_total(blob)
	TestUtil.show(blob.clouds.is_empty() and absf(grid - energy) <= 1e-3 * energy, "S %.0f s later: %d clouds, the grid holds %.4f (want %.0f)" % [d.time - t_burst, blob.clouds.size() / 8, grid, energy])


func _bloom(d: Dish) -> void:
	d.bloom_density = 1.0
	var interval := 86400.0 / d.bloom_per_day()
	var born := {}
	var t_end := d.time + 1000.0
	for k in 4000:
		if d.time >= t_end:
			break
		await g.frame(600.0, false)
		for p: Plankton in d.plankton:
			born[p.born_at] = true
	await g.settle()
	var times: Array = born.keys()
	times.sort()
	var worst := 0.0
	for k in times.size():
		worst = maxf(worst, absf(float(times[k]) - float(times[0]) - k * interval))
	TestUtil.show(times.size() >= 12 and worst <= 600.0 / Governor.STEPS_PER_SECOND, "A a bloom of 1 a mm² a day: %d arrivals, each within %.2f s of the first plus k x %.2f s (a step is %.1f s)" % [times.size(), worst, interval, 600.0 / Governor.STEPS_PER_SECOND])
