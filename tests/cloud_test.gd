extends SceneTree
## Run: godot --headless --path . -s tests/cloud_test.gd
## A plankton's nutrient is kept as a Gaussian cloud (NutrientField puffs) where the grid is too coarse to hold it, and given
## to the grid once it has spread to about a cell. This checks that: a fine grid (a small dish) is untouched; the nutrient is
## conserved through spreading and the handover; a cloud reads as the Gaussian it is, gradient included; what a bup takes
## comes out of the cloud; clouds survive a save; and the bups move the same whatever the number of threads.

const UNITS := 300.0


func check(ok: bool, what: String) -> void:
	TestUtil.check(ok, what)


func _dish(radius_mm: float, seed_value := 5) -> Dish:
	var d := Dish.new()
	root.add_child(d)
	d.set_seed(seed_value)
	var start := StartConditions.new()
	start.dish_radius = radius_mm * 1000.0
	start.nutrient_density = 0.0
	start.bups = 1
	start.bup_limit = 50000
	d.strike(start)
	d.clear_bups()
	return d


func _init() -> void:
	SimConstants.apply()
	_check_small_dish_unchanged()
	_check_reads()
	_check_conservation()
	_check_uptake()
	_check_save()
	_check_sources()
	_check_death_release()
	_check_plume()
	_check_threads()
	TestUtil.finish(self, "CLOUD TESTS OK")


func _check_small_dish_unchanged() -> void:
	var a := _dish(10.0)
	var b := _dish(10.0)
	for p: Vector2 in [Vector2(500, 300), Vector2(-2000, 1500), Vector2(7000, 0)]:
		a.field.add_cloud(p, Dish.PLANKTON_PATCH_RADIUS, UNITS * Dish.NUTRIENT_ENERGY)
		b.field.deposit_disc(p, Dish.PLANKTON_PATCH_RADIUS, UNITS * Dish.NUTRIENT_ENERGY)
	check(a.field.puff_count() == 0 and a.field.values() == b.field.values(), "on a 10 mm dish (200 µm cells) a burst goes straight onto the grid, as it always did")
	a.free()
	b.free()


func _check_reads() -> void:
	var d := _dish(90.0)
	var energy := UNITS * Dish.NUTRIENT_ENERGY
	var where := Vector2(4000, -3000)
	d.field.add_cloud(where, Dish.PLANKTON_PATCH_RADIUS, energy)
	check(d.field.puff_count() == 1 and absf(d.field.total() - energy) < 1e-3 * energy, "on a 90 mm dish a burst is kept as a cloud, and the dish holds its nutrient (%.1f of %.1f)" % [d.field.total(), energy])
	var variance := 0.25 * Dish.PLANKTON_PATCH_RADIUS * Dish.PLANKTON_PATCH_RADIUS
	var peak: float = d.field.sample(where)
	check(absf(peak / (energy / (TAU * variance)) - 1.0) < 1e-6, "a cloud's concentration at its centre is mass / (2 pi variance) (%.5f)" % peak)
	var off := where + Vector2(180, 90)
	var reading: Vector3 = d.field.read(off)
	var h := 0.5
	var numeric_x: float = (d.field.sample(off + Vector2(h, 0)) - d.field.sample(off - Vector2(h, 0))) / (2.0 * h)
	var numeric_y: float = (d.field.sample(off + Vector2(0, h)) - d.field.sample(off - Vector2(0, h))) / (2.0 * h)
	check(reading.y < 0.0 and reading.z < 0.0 and absf(reading.y / numeric_x - 1.0) < 1e-3 and absf(reading.z / numeric_y - 1.0) < 1e-3, "its gradient points at its centre and is the slope of its concentration (%s, %s against %s, %s)" % [reading.y, reading.z, numeric_x, numeric_y])
	check(d.field.min_cloud_sigma(where.x, where.y) < 130.0 and d.field.min_cloud_sigma(-30000.0, 30000.0) > 1.0e9, "a place near a cloud knows the cloud's size, and a place far from any does not")
	d.free()


func _check_conservation() -> void:
	var d := _dish(90.0, 9)
	var energy := UNITS * Dish.NUTRIENT_ENERGY
	for i in 40:
		d.field.add_cloud(d.sim.random_point(86000.0), Dish.PLANKTON_PATCH_RADIUS, energy)
	d.field.add_cloud(Vector2(89500, 0), Dish.PLANKTON_PATCH_RADIUS, energy)  # (at the wall)
	var before: float = d.field.total()
	var clouds_before: int = d.field.puff_count()
	for i in int(8.0 * 3600.0 / 20.0):
		d.step(20.0)
	check(clouds_before == 41 and d.field.puff_count() == 0, "clouds spread and, by about five hours, have all been given to the grid (%d of %d left)" % [d.field.puff_count(), clouds_before])
	check(absf(d.field.total() / before - 1.0) < 1e-4, "the nutrient is conserved through the spreading and the handover (%.1f before, %.1f after)" % [before, d.field.total()])
	d.free()


func _check_death_release() -> void:
	var d := _dish(90.0)
	var mass := 12.0
	var where := Vector2(-3000, 2000)
	d.sim.add_bup(where, Genome.founder(), 0.0, sqrt(mass), mass, 0, Vector2.RIGHT)  # (no energy: it starves in the first step)
	d.sim.step(20.0, PackedVector2Array(), PackedFloat32Array(), 0.0, 0.0)
	var expected := Biology.DEATH_RELEASE * Cell.COST_PER_MASS * mass
	check(d.population() == 0, "a bup with no energy dies in its first step")
	check(d.field.puff_count() == 1 and absf(d.field.total() - expected) < 1e-4 * expected, "a bup that starves gives back a share of its body as a cloud where it died (%.3f of %.3f)" % [d.field.total(), expected])
	d.free()


func _check_uptake() -> void:
	var d := _dish(90.0)
	var energy := UNITS * Dish.NUTRIENT_ENERGY
	var where := Vector2(1000, 1000)
	d.field.add_cloud(where, Dish.PLANKTON_PATCH_RADIUS, energy)
	d.field.fill(0.002 / 40.0)  # (a little in the grid too, so the share between them is used)
	var before: float = d.field.total()
	var got: float = d.field.take(where + Vector2(50, 20), 2.0)
	check(absf(got - 2.0) < 1e-9 and absf(before - d.field.total() - got) < 1e-6 * before, "a bup takes what it wants from the cloud and the grid together, and the dish loses just that (%.4f)" % got)
	var greedy: float = d.field.take(where, 1.0e9)
	check(greedy < 1.0e9 and d.field.total() >= 0.0 and d.field.puff_count() == 1, "it cannot take more than is there")
	d.free()


func _check_save() -> void:
	var d := _dish(90.0)
	for i in 6:
		d.field.add_cloud(d.sim.random_point(80000.0), Dish.PLANKTON_PATCH_RADIUS, UNITS * Dish.NUTRIENT_ENERGY)
	d.advance(1200.0)
	var copy := Dish.new()
	root.add_child(copy)
	var saved := TestUtil.saved(d)
	check(copy.from_dict(saved) and copy.field.puff_count() == d.field.puff_count() and absf(copy.field.total() / d.field.total() - 1.0) < 1e-6, "clouds survive save and load (%d, %.2f against %.2f)" % [copy.field.puff_count(), copy.field.total(), d.field.total()])
	var old := saved.duplicate(true)
	old.erase("clouds")
	var plain := Dish.new()
	root.add_child(plain)
	check(plain.from_dict(old) and plain.field.puff_count() == 0, "a save from before the clouds loads with none")
	d.free()
	copy.free()
	plain.free()


## A source keeps releasing nutrient at its rate. Where the grid is too coarse for the plume near it, what it releases is kept
## up and let go as small clouds every so often; the nutrient must still add up, whether the source is running, has been
## taken away, or has been saved, and the plume must peak at the source.
func _check_sources() -> void:
	var d := _dish(90.0, 13)
	d.place_source(d.global_position + Vector2(2000, 1000), 30.0)  # (30 units a minute)
	d.advance(1200.0)
	var made: float = 30.0 * 20.0 * Dish.NUTRIENT_ENERGY
	check(d.field.puff_count() > 0 and absf(d.field.total() / made - 1.0) < 1e-3, "a source on a 90 mm dish releases its nutrient as clouds, and none of it is lost (%.1f of %.1f in %d clouds)" % [d.field.total(), made, d.field.puff_count()])
	var at_source: float = d.field.sample(Vector2(2000, 1000))
	var away: float = d.field.sample(Vector2(2000, 1000) + Vector2(900, 0))
	var toward: Vector2 = d.field.read(Vector2(2000, 1000) + Vector2(300, 0)).y * Vector2.RIGHT
	check(at_source > 3.0 * away and toward.x < 0.0, "the plume peaks at the source and its gradient points at it (%.5f there, %.5f 900 µm away)" % [at_source, away])
	var before: float = d.field.total()
	d.remove_source(d.sources[0])
	d.step(20.0)
	check(absf(d.field.total() - before) < 1e-3 * before, "taking a source away loses nothing it had kept (%.3f then, %.3f now)" % [before, d.field.total()])
	var copy := _dish(90.0, 14)
	copy.place_source(copy.global_position + Vector2(-3000, 500), 12.0)
	copy.advance(90.0)  # (less than a release interval since the last: some of what it released is still being kept)
	var total_now: float = copy.field.total()
	var reloaded := Dish.new()
	root.add_child(reloaded)
	check(reloaded.from_dict(TestUtil.saved(copy)) and absf(reloaded.field.total() / total_now - 1.0) < 1e-6, "a saved dish has all the nutrient its sources have released (%.3f of %.3f)" % [reloaded.field.total(), total_now])
	var drop := _dish(90.0, 15)
	drop.drop_nutrients(drop.global_position + Vector2(500, -500), 1)
	check(drop.field.puff_count() == 1 and absf(drop.field.total() - Dish.NUTRIENT_ENERGY) < 1e-6, "a single unit of nutrient dropped in a big dish is a point-sized cloud, all there")
	var fine := Dish.new()
	root.add_child(fine)
	fine.strike(TestUtil.small_start())  # (a 300 µm dish: cells of 12.5 µm, finer than a source's plume: straight onto the grid, as before)
	fine.place_source(fine.global_position + Vector2(20, 0), 30.0)
	fine.advance(120.0)
	check(fine.field.puff_count() == 0 and fine.field.total() > 0.0, "on a fine grid a source's nutrient goes straight onto the grid")
	for dish: Dish in [d, copy, reloaded, drop, fine]:
		dish.free()


## A steady source's plume after three hours in the thick medium, against the exact solution for a constant point source in an
## open 2D medium: c = Q / (4 pi D) * E1(r^2 / (4 D t)). On a 1,800 µm grid, where the clouds hold all of it, it should be right from
## 100 µm out to the far field (where it falls below what bups can detect).
func _e1(x: float) -> float:
	if x < 1.0:
		var sum := -0.5772156649 - log(x)
		var term := 1.0
		for k in range(1, 40):
			term *= -x / k
			sum -= term / k
		return sum
	var b := x + 1.0
	var c := 1.0e30
	var dd := 1.0 / b
	var h := dd
	for i in range(1, 100):
		var an := -float(i * i)
		b += 2.0
		dd = 1.0 / (an * dd + b)
		c = b + an / c
		var del := c * dd
		h *= del
		if absf(del - 1.0) < 1e-12:
			break
	return h * exp(-x)


func _check_plume() -> void:
	var d := _dish(90.0, 7)
	var where := Vector2(5000, 3000)
	d.place_source(d.global_position + where, 30.0)
	d.advance(3.0 * 3600.0)
	var q := 30.0 / 60.0 * Dish.NUTRIENT_ENERGY
	var worst := 0.0
	var report := ""
	for r in [100.0, 300.0, 900.0, 2000.0]:
		var exact := q / (4.0 * PI * Biology.NUTRIENT_DIFFUSION) * _e1(r * r / (4.0 * Biology.NUTRIENT_DIFFUSION * 3.0 * 3600.0))
		var ratio: float = d.field.sample(where + Vector2(r, 0.0)) / exact
		worst = maxf(worst, absf(ratio - 1.0))
		report += "  %.0f µm: %.3f" % [r, ratio]
	check(worst < 0.05, "a source's plume after three hours matches the exact solution within 5%% at 100 to 2,000 µm (ratios%s)" % report)
	d.free()


## The bups move the same however many threads there are, with clouds in the field (and each looks at them as often as it needs).
func _check_threads() -> void:
	var positions := []
	for threads in [1, 0]:
		var d := _dish(90.0, 21)
		d.sim.set_threads(threads)
		for i in 30:
			d.field.add_cloud(d.sim.random_point(20000.0), Dish.PLANKTON_PATCH_RADIUS, UNITS * Dish.NUTRIENT_ENERGY)
		var ids := []
		for i in 3000:
			ids.append(d.sim.add_bup(d.sim.random_point(20000.0), Genome.founder(), 1000.0, 3.0, 5000.0, 0, Vector2.RIGHT))
		for i in 30:
			d.step(20.0)
		var sum := Vector2.ZERO
		for id: int in ids:
			var info: Dictionary = d.bup_info(id)
			if not info.is_empty():
				sum += info["pos"]
		positions.append(sum)
		d.free()
	check(positions[0].is_equal_approx(positions[1]), "bups move the same on one thread as on many, with clouds in the field (%s, %s)" % [positions[0], positions[1]])
