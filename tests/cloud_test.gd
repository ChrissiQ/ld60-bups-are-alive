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
	d.stationary_phase = false  # (the tests below that starve bups on purpose want the old rule: a bup with no energy dies at once; the starvation test turns the phase on itself)
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
	_check_husks()
	_check_plankton_husks()
	_check_starvation()
	_check_conjugation()
	_check_reach()
	_check_acetate()
	_check_key()
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


func _check_husks() -> void:
	var d := _dish(90.0)
	d.death_husks = true
	var mass := 12.0
	d.sim.add_bup(Vector2(-3000, 2000), Genome.founder(), 0.0, sqrt(mass), mass, 0, Vector2.RIGHT)
	d.sim.step(20.0, PackedVector2Array(), PackedFloat32Array(), 0.0, 0.0)
	var expected := Biology.DEATH_RELEASE * Cell.COST_PER_MASS * mass
	check(d.population() == 0 and d.sim.husk_count() == 1 and d.field.puff_count() == 0 and d.field.total() == 0.0, "with husks on a dead bup leaves a husk and no cloud yet")
	var copy := Dish.new()
	root.add_child(copy)
	check(copy.from_dict(TestUtil.saved(d)) and copy.death_husks and copy.sim.husk_count() == 1, "a husk, and the setting, survive save and load")
	copy.free()
	var none := PackedVector2Array()
	var rates := PackedFloat32Array()
	for i in 180:  # (an hour: only the first piece, the middle of whose quarter-lifetime is 22 minutes, has leaked)
		d.sim.step(20.0, none, rates, 0.0, 0.0)
	var first := expected * (1.0 - exp(-0.25))
	check(absf(d.field.total() - first) < 1e-3 * first and d.sim.husk_count() == 1, "an hour on, the first piece has leaked (%.3f of %.3f)" % [d.field.total(), first])
	for i in 1500:  # (to nine hours and a little over: every piece)
		d.sim.step(20.0, none, rates, 0.0, 0.0)
	check(d.sim.husk_count() == 0 and absf(d.field.total() - expected) < 1e-3 * expected, "in the end the husk has given all of it back (%.3f of %.3f)" % [d.field.total(), expected])
	d.free()


func _check_starvation() -> void:
	var n := 400
	var none := PackedVector2Array()
	var rates := PackedFloat32Array()
	var survivors := {}
	var masses := {}
	for setting in [false, true]:
		for metabolism in [0.5, 1.0, 2.0]:
			var d := _dish(90.0)
			d.stationary_phase = setting
			var genome := Genome.founder()
			genome["metabolism"] = metabolism
			var mass := 12.0
			for i in n:
				d.sim.add_bup(d.sim.random_point(80000.0), genome, 0.0, sqrt(mass), mass, 0, Vector2.RIGHT)
			for i in 4320:  # (a day of 20 s steps with nothing to eat)
				d.sim.step(20.0, none, rates, 0.0, 0.0)
				if not setting and i == 0:
					survivors["off_first_%s" % metabolism] = d.population()
			survivors["%s_%s" % [setting, metabolism]] = d.population()
			var total := 0.0
			var ex: PackedFloat32Array = d.sim.export_state()
			var np: int = ex.size() / GpuSim.STRIDE
			for i in np:
				total += ex[i * GpuSim.STRIDE + 6]
			masses["%s_%s" % [setting, metabolism]] = total / maxf(np, 1)
			d.free()
	check(survivors["off_first_1.0"] == 0, "with the stationary phase off every bup with no energy dies in its first step")
	var expected := {0.5: exp(-0.22 * exp(0.95 * 1.0397 * 0.5)), 1.0: exp(-0.22 * exp(0.95 * 1.0397)), 2.0: exp(-0.22 * exp(0.95 * 1.0397 * 2.0))}
	for metabolism in [0.5, 1.0, 2.0]:
		var share: float = survivors["true_%s" % metabolism] / float(n)
		check(absf(share - expected[metabolism]) < 0.08, "a day of starvation at metabolism %s leaves %.2f of the bups alive (expected %.2f from the death rate)" % [metabolism, share, expected[metabolism]])
	check(survivors["true_2.0"] < survivors["true_1.0"] and survivors["true_1.0"] < survivors["true_0.5"], "the fast metabolism dies first: the growth rate costs survival")
	check(absf(masses["true_1.0"] / 12.0 - exp(-0.08)) < 0.02, "the survivors have shrunk by about the starving maintenance (%.3f of their mass, expected %.3f)" % [masses["true_1.0"] / 12.0, exp(-0.08)])


## Overflow: a bup eating faster than it can grow lets go of acetate (up to the share the threshold-linear law gives), one that eats slowly does not,
## and a bup with room and no glucose takes acetate up at its yield, to the amount it took out of the field.
func _check_acetate() -> void:
	var none := PackedVector2Array()
	var rates := PackedFloat32Array()
	var mass := 12.0
	var rich := _dish(90.0)
	rich.field.fill(Cell.HALF_SATURATION * 20.0)
	for i in 200:
		rich.sim.add_bup(rich.sim.random_point(80000.0), Genome.founder(), 0.0, sqrt(mass), mass, 0, Vector2.RIGHT)
	var eaten_before: float = rich.field.total()
	rich.sim.step(20.0, none, rates, 0.0, 0.0)
	var let_go: float = rich.acetate.total()
	var taken: float = eaten_before - rich.field.total()
	check(let_go > 0.0 and let_go < 0.5 * taken, "bups eating fast let go of acetate, under half of what they eat (%.3f of %.3f)" % [let_go, taken])
	rich.free()
	var lean := _dish(90.0)
	lean.field.fill(Cell.HALF_SATURATION * 0.05)
	for i in 200:
		lean.sim.add_bup(lean.sim.random_point(80000.0), Genome.founder(), 0.0, sqrt(mass), mass, 0, Vector2.RIGHT)
	lean.sim.step(20.0, none, rates, 0.0, 0.0)
	check(lean.acetate.total() < 0.01 * let_go, "bups eating slowly let go of none (%.5f)" % lean.acetate.total())
	lean.free()
	var bodies := []
	var gone := 0.0
	for with_acetate in [false, true]:
		var d := _dish(90.0)
		if with_acetate:
			d.acetate.fill(Cell.HALF_SATURATION * 4.0)
		var start: float = d.acetate.total()
		for i in 200:
			d.sim.add_bup(Vector2(float(i % 20 - 10) * 3000.0, float(i / 20 - 5) * 3000.0), Genome.founder(), 0.5 * Cell.COST_PER_MASS * mass, sqrt(mass), mass, 0, Vector2.RIGHT)
		d.sim.step(20.0, none, rates, 0.0, 0.0)
		var ex: PackedFloat32Array = d.sim.export_state()
		var body := 0.0
		for i in ex.size() / GpuSim.STRIDE:
			body += ex[i * GpuSim.STRIDE + 5] + ex[i * GpuSim.STRIDE + 6] * Cell.COST_PER_MASS
		bodies.append(body)
		gone = start - d.acetate.total()
		d.free()
	check(gone > 0.0 and absf((bodies[1] - bodies[0]) / gone - 1.0) < 0.02, "a bup with room and no glucose takes acetate up at its yield (%.4f gone, bodies %.2f against %.2f without)" % [gone, bodies[1], bodies[0]])


func _check_plankton_husks() -> void:
	var d := _dish(90.0)
	d.plankton_husks = true
	d.bloom_density = 0.0
	var energy := 40.0 * Dish.NUTRIENT_ENERGY
	d.plankton.append(Plankton.new(d.global_position + Vector2(2000, 1000), 0.0, 100.0, 40.0, 0))
	d.advance(200.0)
	check(d.plankton.is_empty() and d.sim.husk_count() == 1 and d.field.puff_count() == 0, "a plankton that dies with husks on leaves a husk and no cloud")
	d.advance(Biology.HUSK_SECONDS * 0.75)
	var leaked: float = d.field.total()
	check(leaked > 0.4 * energy and leaked < energy, "its nutrient leaks back over hours (%.0f of %.0f)" % [leaked, energy])
	var copy := Dish.new()
	root.add_child(copy)
	check(copy.from_dict(TestUtil.saved(d)) and copy.plankton_husks, "the setting survives save and load")
	var plain := _dish(90.0)
	plain.bloom_density = 0.0
	plain.plankton.append(Plankton.new(plain.global_position + Vector2(2000, 1000), 0.0, 100.0, 40.0, 0))
	plain.advance(200.0)
	check(plain.sim.husk_count() == 0 and plain.field.total() > 0.99 * energy, "with them off it bursts into a cloud at once")
	d.free()
	copy.free()
	plain.free()


## The acetate key: a bup with it takes acetate up KEY_FACTOR times as fast and grows KEY_COST slower; a potentiated one (level 1) is like any other; the levels are
## made at their rates (a daughter of a level-0 parent is potentiated at KEY_POTENTIATION_RATE, of a level-1 parent has the key at KEY_RATE, of a level-2 parent keeps it).
func _check_key() -> void:
	var none := PackedVector2Array()
	var rates := PackedFloat32Array()
	var mass := 12.0
	var gains := {}
	var growth := {}
	for level in [0, 1, 2]:
		var d := _dish(90.0)
		d.acetate.fill(Cell.HALF_SATURATION * 4.0)
		var genome := Genome.founder()
		genome["reach"] = level << 8
		for i in 100:
			d.sim.add_bup(Vector2(float(i % 10 - 5) * 3000.0, float(i / 10 - 5) * 3000.0), genome, 0.3 * Cell.COST_PER_MASS * mass, sqrt(mass), mass, 0, Vector2.RIGHT)
		var before: float = d.acetate.total()
		d.sim.step(20.0, none, rates, 0.0, 0.0)
		gains[level] = before - d.acetate.total()
		d.free()
		var g := _dish(90.0)
		for i in 100:
			g.sim.add_bup(Vector2(float(i % 10 - 5) * 3000.0, float(i / 10 - 5) * 3000.0), genome, 0.9 * Cell.COST_PER_MASS * mass, sqrt(mass), mass, 0, Vector2.RIGHT)
		g.sim.step(20.0, none, rates, 0.0, 0.0)
		var ex: PackedFloat32Array = g.sim.export_state()
		var total := 0.0
		for i in ex.size() / GpuSim.STRIDE:
			total += ex[i * GpuSim.STRIDE + 6]
		growth[level] = total
		g.free()
	check(absf(gains[2] / gains[0] - Genome.KEY_FACTOR) < 0.05 * Genome.KEY_FACTOR and absf(gains[1] / gains[0] - 1.0) < 0.01, "the key takes acetate up %.2f times as fast (expected %.1f), a potentiated bup as fast as any (%.3f)" % [gains[2] / gains[0], Genome.KEY_FACTOR, gains[1] / gains[0]])
	var grown0: float = growth[0] - 100.0 * mass
	check(grown0 > 0.0 and absf((growth[2] - 100.0 * mass) / grown0 - (1.0 - Genome.KEY_COST)) < 0.01 and absf((growth[1] - 100.0 * mass) / grown0 - 1.0) < 0.005, "the key costs %.1f%% of the growth (expected %.0f%%), potentiation nothing" % [100.0 * (1.0 - (growth[2] - 100.0 * mass) / grown0), 100.0 * Genome.KEY_COST])
	check(Genome.key_level(2 << 8 | 5) == 2 and Genome.key_level(1 << 8) == 1 and Genome.key_level(255) == 0, "the key's level is read from bits 8-9 of the reach word")
	var d := _dish(90.0)
	var consts := SimConstants.build()
	consts["key_potentiation_rate"] = 0.05
	consts["key_rate"] = 0.1
	BupSim.configure(consts)
	var counts := [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
	for level in [0, 1, 2]:
		var parent := Genome.founder()
		parent["reach"] = level << 8
		for i in 20000:
			var r: Dictionary = d.sim.mutate_genome(parent)
			if not r["lethal"]:
				counts[level][Genome.key_level(int(r["reach"]))] += 1
	var from0: float = counts[0][1] / 20000.0
	var from1: float = counts[1][2] / 20000.0
	check(absf(from0 - 0.05) < 0.004 and absf(from1 - 0.1) < 0.006 and counts[0][2] == 0 and counts[1][0] == 0 and counts[2][2] > 19000, "a daughter is potentiated at its rate (%.4f of 0.05), made a key at its (%.4f of 0.1), only from a potentiated line, and keeps the key" % [from0, from1])
	SimConstants.apply()
	d.free()


func _check_conjugation() -> void:
	var d := _dish(90.0)
	var donor_genome := Genome.founder()
	donor_genome.merge({"speed": 30.0, "sense": 100.0, "metabolism": 1.5, "size": 6.0, "donor": true}, true)
	var plain := Genome.founder()
	plain.merge({"speed": 10.0, "sense": 40.0, "metabolism": 0.5, "size": 3.0}, true)
	var n := 600
	var mass := 12.0
	var recipients := []
	for i in n:
		var at := Vector2(-40000.0 + 120.0 * (i % 60), -40000.0 + 120.0 * (i / 60))
		d.sim.add_bup(at, donor_genome, 50.0, sqrt(mass), mass, 0, Vector2.RIGHT)
		recipients.append(d.sim.add_bup(at + Vector2(2.0, 0.0), plain, 50.0, sqrt(mass), mass, 0, Vector2.RIGHT))
	var apart := d.sim.add_bup(Vector2(0.0, 0.0), plain, 50.0, sqrt(mass), mass, 0, Vector2.RIGHT)  # (a bup with no donor near it)
	d.sim.conjugate(10.0)  # (a touching pair transfers with chance 1 - exp(-0.1 x 10), about 0.63)
	var transferred := 0
	var runs := [0, 0, 0, 0]
	for id: int in recipients:
		var info := d.sim.bup_info(id)
		var genes := [info["speed"], info["sense"], info["metabolism"], info["size_gene"]]
		if genes[0] == 30.0:
			transferred += 1
			for g in 4:
				runs[g] += 1 if genes[g] == [30.0, 100.0, 1.5, 6.0][g] else 0
	var share := float(transferred) / n
	check(absf(share - (1.0 - exp(-Genome.CONJ_RATE * 10.0))) < 0.06, "touching pairs transfer at the rate: %.3f of %d (expected %.3f)" % [share, n, 1.0 - exp(-Genome.CONJ_RATE * 10.0)])
	check(runs[0] == transferred and absf(float(runs[1]) / transferred - Genome.CONJ_CONTINUE) < 0.08 and absf(float(runs[2]) / transferred - 0.25) < 0.08 and absf(float(runs[3]) / transferred - 0.125) < 0.06, "a transfer is a run from the first gene, each next one with the chance %.2f: %s of %d" % [Genome.CONJ_CONTINUE, str(runs), transferred])
	check(d.sim.bup_info(apart)["speed"] == 10.0, "a bup that touches no donor takes nothing")
	var still_donors := 0
	for id: int in d.sim.bup_ids():
		var info := d.sim.bup_info(id)
		if info["donor"] and info["speed"] != 30.0:
			still_donors += 1
	check(still_donors == 0, "a donor keeps its own genes")
	d.free()


func _check_reach() -> void:
	var d := _dish(90.0)
	var top := Genome.founder()
	top["speed"] = 39.9
	var raised := top.duplicate()
	raised["reach"] = 3  # (speed's ceiling raised three times: the lowest two bits)
	var over_plain := 0
	var over_raised := 0
	var highest := 0.0
	for i in 3000:
		var a: Dictionary = d.sim.mutate_genome(top)
		var b: Dictionary = d.sim.mutate_genome(raised)
		over_plain += 1 if a["speed"] > 40.0 else 0
		over_raised += 1 if b["speed"] > 40.0 else 0
		highest = maxf(highest, b["speed"])
	check(over_plain == 0 and over_raised > 100 and highest <= 40.0 * Genome.REACH_FACTOR_3, "a raised ceiling lets a gene pass its usual top (%d of 3000 daughters over 40, the highest %.1f, none past %.0f)" % [over_raised, highest, 40.0 * Genome.REACH_FACTOR_3])
	var mass := 12.0
	var gains := []
	for genome in [Genome.founder(), raised]:
		var id: int = d.sim.add_bup(Vector2(0.0, 0.0), genome, 90.0, sqrt(mass), mass, 0, Vector2.RIGHT)
		d.sim.bup_pay_upkeep_and_grow(id, 60.0)
		gains.append(float(d.sim.bup_info(id)["mass"]) - mass)
	check(absf(gains[1] / gains[0] - (1.0 - 3.0 * Genome.REACH_COST)) < 0.03, "each raise costs a share of growth: a bup raised three times grows %.2f of what the usual one does (expected %.2f)" % [gains[1] / gains[0], 1.0 - 3.0 * Genome.REACH_COST])
	var text := Genome.reach_text(0x0D)  # (speed +1, sense +3: two bits a gene)
	check(text == "%s +1, %s +3" % [Genome.label("speed"), Genome.label("sense")], "the panel's text of raised ceilings: %s" % text)
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
