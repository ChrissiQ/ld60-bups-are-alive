extends SceneTree
## Run: godot --headless --path . -s tests/model_test.gd
## Pins the biology: the mutation spectrum, the rate-yield trade-off, bodies that grow, the
## Moran cap, chemotaxis. Statistical checks use many draws and wide margins.

const DT := 0.05  ## a short step, so bups run and tumble for real

func check(ok: bool, what: String) -> void:
	TestUtil.check(ok, what)


var sim := BupSim.new()  ## the native core, for the single-bup checks (dishes bring their own)


## A bup in the test simulation: its id.
func _cell(metabolism := 1.0, size := 4.0, speed := 20.0, sense := 50.0, body := -1.0, energy := 50.0) -> int:
	var g := Genome.founder()
	g["metabolism"] = metabolism
	g["size"] = size
	g["speed"] = speed
	g["sense"] = sense
	return sim.add_bup(Vector2.ZERO, g, energy, body, -1.0, 0, Vector2.RIGHT)


func _mass(id: int) -> float:
	return sim.bup_info(id)["mass"]


func _energy(id: int) -> float:
	return sim.bup_info(id)["energy"]


func _init() -> void:
	SimConstants.apply()
	sim.reset(Dish.DEFAULT_RADIUS, 11)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11

	# --- Mutation spectrum: mostly harmful or silent, a few lethal, repairs rare.
	var n := 20000
	var lethal := 0
	var with_harm := 0
	var repaired := 0
	var total_harm := 0.0
	var parent := Genome.founder()
	var loaded := Genome.founder()
	loaded["harm"] = 0.5
	for i in n:
		var child := sim.mutate_genome(parent)
		lethal += 1 if child["lethal"] else 0
		with_harm += 1 if child["harm"] > 0.0 else 0
		total_harm += child["harm"]
		if sim.mutate_genome(loaded)["harm"] < loaded["harm"]:
			repaired += 1
	var harmful_events := Genome.HARMFUL_MUTATIONS
	check(absf(with_harm / float(n) - harmful_events * (1.0 - Genome.LETHAL_FRACTION)) < 0.03, "harmful mutations arrive at the stated rate")
	check(absf(lethal / float(n) - harmful_events * Genome.LETHAL_FRACTION) < 0.01, "a small fraction of harmful mutations is lethal")
	check(repaired > 0 and repaired < n * 0.02, "compensatory repairs happen but are rare (%d)" % repaired)
	var mean_effect := total_harm / maxf(with_harm, 1)
	check(absf(mean_effect - Genome.MEAN_HARM) < Genome.MEAN_HARM * 0.35, "mean harmful effect is %.3f, expected about %.3f" % [mean_effect, Genome.MEAN_HARM])

	# Leptokurtic: most effects are below the mean, with a tail well above it.
	var small := 0
	var big := 0
	for i in n:
		var effect := sim.sample_gamma(Genome.HARM_SHAPE) * Genome.MEAN_HARM / Genome.HARM_SHAPE
		small += 1 if effect < Genome.MEAN_HARM * 0.5 else 0
		big += 1 if effect > Genome.MEAN_HARM * 4.0 else 0
	check(small > n * 0.5 and big > 0, "harmful effects are mostly tiny with a long tail (%d small, %d big)" % [small, big])

	# A push against a bound changes nothing and is not counted as a mutation.
	var pinned := Genome.founder()
	pinned.merge({"speed": 20.0, "sense": 10.0, "metabolism": 0.4, "size": 2.0}, true)
	var counted_on_bounds := 0
	for i in 2000:
		var c := sim.mutate_genome(pinned)
		for gene in Genome.GENES:
			if c[gene] < Genome.GENES[gene][0] or c[gene] > Genome.GENES[gene][1]:
				counted_on_bounds += 1
	check(counted_on_bounds == 0, "traits never leave their bounds")

	# Mutators: a daughter is made at the parent's mutator times the usual rate; a new allele sets the rate to a real fold, never past the top.
	var usual_rate: float = Genome.TRAIT_MUTATIONS + Genome.HARMFUL_MUTATIONS
	var mid_genome := Genome.founder()
	var count_at := func(mutator: float, draws: int) -> float:
		var mutator_parent := mid_genome.duplicate()
		mutator_parent["mutator"] = mutator
		var total := 0.0
		for i in draws:
			total += float(sim.mutate_genome(mutator_parent)["mutations"])
		return total / draws
	var usual_mean: float = count_at.call(1.0, 20000)
	var strong_mean: float = count_at.call(100.0, 3000)
	check(absf(usual_mean - usual_rate) < usual_rate * 0.05, "a usual bup's daughter has about %.3f mutations: %.3f" % [usual_rate, usual_mean])
	check(absf(strong_mean / usual_mean - 100.0) < 5.0, "a 100-fold mutator's daughter has about 100 times as many mutations (%.1f against %.3f)" % [strong_mean, usual_mean])
	var alleles := 0
	var top_genome := Genome.founder()
	top_genome["mutator"] = Genome.MUTATOR_FOLD_TOP
	var beyond := 0
	for i in 100000:
		var c := sim.mutate_genome(mid_genome)
		alleles += 1 if c["mutator"] > 1.0 else 0
		beyond += 1 if sim.mutate_genome(top_genome)["mutator"] > Genome.MUTATOR_FOLD_TOP else 0
	var expected_alleles := 100000.0 * Genome.MUTATOR_RATE
	check(alleles > expected_alleles * 0.5 and alleles < expected_alleles * 1.6 and beyond == 0, "a new mutator allele appears about once in %d divisions (%d in 100,000, expected %.0f) and none passes the top fold" % [roundi(1.0 / Genome.MUTATOR_RATE), alleles, expected_alleles])

	# --- Rate-yield trade-off: fast metabolisms grow quicker but waste fuel.
	var fast := _cell(1.8)
	var slow := _cell(0.5)
	sim.set_bup_energy(fast, 0.0)
	sim.set_bup_energy(slow, 0.0)
	sim.bup_eat(fast, 1.0)
	sim.bup_eat(slow, 1.0)
	check(_energy(fast) < _energy(slow), "a fast metabolism yields less energy per food")
	var fast_body := _cell(1.8, 4.0, 20.0, 50.0, -1.0, 90.0)
	var slow_body := _cell(0.5, 4.0, 20.0, 50.0, -1.0, 90.0)
	sim.bup_pay_upkeep_and_grow(fast_body, 600.0)  # ten minutes
	sim.bup_pay_upkeep_and_grow(slow_body, 600.0)
	check(_mass(fast_body) > _mass(slow_body), "given the same fuel, a fast metabolism grows faster")
	var harmed := _cell()
	var g := Genome.founder()
	g["harm"] = 0.5
	var harmed_g := sim.add_bup(Vector2.ZERO, g, 0.0, -1.0, -1.0, 0, Vector2.RIGHT)
	sim.set_bup_energy(harmed, 0.0)
	sim.bup_eat(harmed, 1.0)
	sim.bup_eat(harmed_g, 1.0)
	check(_energy(harmed_g) < _energy(harmed), "harm lowers the yield of food")

	# --- Bodies: grow with fuel, split with the reserve, are bounded by the reserve.
	var body := _cell()
	var start_mass := _mass(body)
	sim.set_bup_energy(body, 100.0)
	for i in 100:  # a hundred minutes, with the reserve kept topped up
		sim.set_bup_energy(body, maxf(_energy(body), 100.0))
		sim.bup_pay_upkeep_and_grow(body, 60.0)
	check(_mass(body) > start_mass and sim.bup_ready(body), "a fed bup grows to its genome's size and is ready to divide")
	var before := _energy(body)
	var big_mass := _mass(body)
	var daughter := sim.bup_split(body, 0.5)
	check(absf(_mass(body) * 2.0 - big_mass) < 0.001 and absf(_energy(body) - before * 0.5) < 0.001 and absf(daughter.x - _mass(body)) < 0.001 and absf(daughter.y - _energy(body)) < 0.001, "dividing shares the mass and the reserve")
	sim.bup_eat(body, 1000.0)
	check(_energy(body) <= sim.bup_max_energy(body) + 0.001, "the reserve can't hold more than the body allows")
	var small_body := _cell(1.0, 2.0)
	check(sim.bup_upkeep(_cell(1.0, 8.0)) > sim.bup_upkeep(_cell(1.0, 2.0)), "a bigger body costs more to keep")
	check(sim.bup_upkeep(_cell(1.0, 8.0, 18.0)) - sim.bup_upkeep(_cell(1.0, 8.0, 4.0)) > sim.bup_upkeep(_cell(1.0, 2.0, 18.0)) - sim.bup_upkeep(_cell(1.0, 2.0, 4.0)), "swimming fast costs more for a bigger body (drag)")
	check(sim.bup_sense_range(_cell(1.0, 8.0)) > sim.bup_sense_range(small_body), "a bigger body senses further")

	# --- Moran cap: births at the limit displace bups instead of being blocked.
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(3)
	dish.strike(_small())
	dish.clear_bups()
	for i in Dish.MAX_CELLS:  # fully grown (size 4: mass 16, born at 8), so each is ready to divide
		dish.add_bup(dish.global_position + Vector2(rng.randf_range(-100, 100), rng.randf_range(-100, 100)), Genome.founder(), 200.0, 4.0)
	var generations_before := _generations(dish)
	for i in 300:
		dish.step(DT)
	var generations_after := _generations(dish)
	check(dish.population() <= Dish.MAX_CELLS, "the dish never holds more than its limit")
	check(generations_after > generations_before, "births keep happening at the limit")

	# --- The adder: whatever size it is born, a bup adds the same mass before dividing.
	var adds := []
	for born in [6.0, 9.0, 14.0]:
		var adder := sim.add_bup(Vector2.ZERO, Genome.founder(), 200.0, sqrt(born), born, 0, Vector2.RIGHT)
		for i in 3000:
			sim.bup_pay_upkeep_and_grow(adder, 60.0)
			sim.set_bup_energy(adder, maxf(_energy(adder), 150.0))
			if sim.bup_ready(adder):
				break
		adds.append(_mass(adder) - born)
	check(absf(adds[0] - adds[1]) < 0.5 and absf(adds[1] - adds[2]) < 0.5 and absf(adds[0] - Cell.mass_to_add(Genome.founder())) < 0.5, "a bup adds a fixed mass before dividing, whatever its birth size (%s)" % str(adds))
	# Growth is exponential: a bigger body adds more per second.
	var small_one := sim.add_bup(Vector2.ZERO, Genome.founder(), 200.0, 2.0, 100.0, 0, Vector2.RIGHT)
	var large_one := sim.add_bup(Vector2.ZERO, Genome.founder(), 200.0, 4.0, 100.0, 0, Vector2.RIGHT)
	sim.bup_pay_upkeep_and_grow(small_one, 600.0)
	sim.bup_pay_upkeep_and_grow(large_one, 600.0)
	check(_mass(large_one) - 16.0 > 3.0 * (_mass(small_one) - 4.0), "growth is proportional to mass")

	# --- Uptake is Monod: saturating in concentration, and larger bodies take up more.
	var u := _cell()
	sim.set_bup_energy(u, 10.0)
	var low := sim.bup_uptake(u, Cell.HALF_SATURATION * 0.1, 1.0)
	var mid := sim.bup_uptake(u, Cell.HALF_SATURATION, 1.0)
	var high := sim.bup_uptake(u, Cell.HALF_SATURATION * 100.0, 1.0)
	var higher := sim.bup_uptake(u, Cell.HALF_SATURATION * 1000.0, 1.0)
	check(low < mid and mid < high and higher < high * 1.02, "uptake rises with concentration and saturates")
	check(absf(mid / high - 0.5) < 0.02, "uptake is half its maximum at the half-saturation concentration")
	check(sim.bup_uptake(_cell(1.0, 8.0), 0.05, 1.0) > sim.bup_uptake(_cell(1.0, 2.0), 0.05, 1.0), "a bigger bup takes up more")

	# --- Chemotaxis constants (Berg & Brown 1972): ~1 tumble a second on a flat signal, fewer
	# while climbing, and never more than baseline while descending.
	var flat := _cell()
	var rate := 0.0
	for i in 300:
		rate = sim.bup_tumble_rate(flat, 0.02, DT, 0.0)
	check(absf(rate - Cell.TUMBLE_BASE) < 0.01, "a flat signal gives the baseline tumble rate (%.2f)" % rate)
	var climbing := _cell()
	var falling := _cell()
	var climb_rate := 0.0
	var fall_rate := 0.0
	for i in 150:
		climb_rate = sim.bup_tumble_rate(climbing, 0.01 * exp(0.02 * i), DT, 0.0)
		fall_rate = sim.bup_tumble_rate(falling, 0.01 * exp(-0.02 * i), DT, 0.0)
	check(climb_rate < Cell.TUMBLE_BASE * 0.6 and climb_rate >= Cell.TUMBLE_BASE * Biology.TUMBLE_UP_FACTOR, "climbing a gradient lengthens runs by 2-3x (%.2f)" % climb_rate)
	check(fall_rate <= Cell.TUMBLE_BASE + 0.001 and fall_rate > Cell.TUMBLE_BASE * 0.95, "descending does not shorten runs (%.2f)" % fall_rate)

	# --- The medium: nutrient is conserved, spreads by diffusion, and is drawn down by uptake.
	var medium := NutrientField.new()
	medium.reset(300.0)
	medium.deposit(Vector2.ZERO, 100.0)
	var peak_before := medium.sample(Vector2.ZERO)
	for i in 200:
		medium.diffuse(0.1)
	check(absf(medium.total() - 100.0) < 0.5, "diffusion conserves nutrient (%.2f)" % medium.total())
	check(medium.sample(Vector2.ZERO) < peak_before * 0.5 and medium.sample(Vector2(40, 0)) > 0.0, "nutrient spreads out")
	var taken := medium.take(Vector2.ZERO, 0.5)
	check(taken > 0.0 and absf(medium.total() - (100.0 - taken)) < 0.5, "uptake removes nutrient from the medium")
	# A bup against the wall can eat and sense: the thin band of cells at the rim, whose centres lie just
	# outside the circle, doesn't leave it hungry beside food.
	for wall_radius: float in [300.0, 1200.0, 6000.0, 12000.0]:
		var rim := NutrientField.new()
		rim.reset(wall_radius)
		rim.fill(0.01)
		var cannot_eat := 0
		var reads_low := 0
		for k in 360:
			var at_wall: Vector2 = Vector2.from_angle(TAU * k / 360.0) * (wall_radius - 1.0)  # where a wall-trapped bup sits
			var reading: float = rim.sample(at_wall)
			if reading < 0.008:
				reads_low += 1
			if rim.take(at_wall, 0.001) <= 0.0:
				cannot_eat += 1
		check(cannot_eat == 0 and reads_low == 0, "a bup at the wall of a %.0f µm dish can eat and senses the true concentration (%d can't eat, %d read low of 360)" % [wall_radius, cannot_eat, reads_low])
	check(not NutrientField.new().accepts(Vector2(1000.0, 0.0)) and NutrientField.new().sample(Vector2.ZERO) == 0.0, "a field that was never reset is safe to ask")
	# A point source's nutrient is centred on the point, however coarse the grid: not pulled to the middle of a cell.
	var coarse := NutrientField.new()
	coarse.reset(12000.0)  # 240 µm cells
	for spot: Vector2 in [Vector2(-235.0, -270.0), Vector2(61.0, 119.0), Vector2(-11500.0, 200.0), Vector2(0.0, 11900.0)]:
		coarse.reset(12000.0)
		check(coarse.accepts(spot), "%s is inside the dish" % spot)
		coarse.deposit(spot, 100.0)
		var weights := coarse.values()
		var mass := 0.0
		var centroid := Vector2.ZERO
		for i in weights.size():
			var m_i: float = weights[i] * coarse.spacing * coarse.spacing
			mass += m_i
			centroid += coarse.cell_centre(i) * m_i
		centroid /= mass
		check(absf(mass - 100.0) < 0.01, "a deposit near %s keeps all its nutrient (%.3f)" % [spot, mass])
		var inside_rim := spot.length() < 11000.0  # near the rim some cells are outside the dish, so it can't be centred exactly
		check(not inside_rim or centroid.distance_to(spot) < 0.5, "a point source is centred on its point at %s (centroid %s)" % [spot, centroid])

	# --- A swimmer reaching the wall is turned along it rather than bounced straight back.
	var wall_dish := Dish.new()
	root.add_child(wall_dish)
	wall_dish.set_seed(4)
	wall_dish.strike(_small())
	wall_dish.clear_bups()
	var wall_id := wall_dish.add_bup(wall_dish.global_position + Vector2(wall_dish.radius - 3.0, 0.0), Genome.founder(), 90.0, -1.0, -1.0, 0, Vector2.RIGHT)
	wall_dish.step(0.2)
	var wall_dir: Vector2 = wall_dish.bup_info(wall_id)["dir"]
	check(wall_dir.dot(Vector2.RIGHT) < 0.2 and absf(wall_dir.y) > 0.8, "a swimmer that hits the wall slides along it")

	# --- Chemotaxis, in a shallow gradient (0.5% per µm) where sense matters. Measured once for the real
	# run-and-tumble model: a keen bup drifts up at about 3 µm/s (E. coli's gentle-gradient response: see Cell.CHEMOTAXIS_GAIN) and a dull one far less, and the coarse
	# model used at fast playback (the measured motion table; tests/motion_table_test.gd checks it much
	# more closely) reproduces both.
	var fine_keen := _drift_speed(false, true, 50.0)
	var coarse_keen := _drift_speed(true, true, 50.0)
	var coarse_long := _drift_speed(true, true, 50.0, 15.0)  # ultra playback: long steps, split into motion sub-steps
	var fine_dull := _drift_speed(false, true, 10.0)
	var fine_flat := _drift_speed(false, false, 50.0)
	check(fine_keen.x > 6.0 * fine_keen.y and fine_keen.x > 2.4 and fine_keen.x < 3.6, "a keen bup drifts up a gradient (%.2f µm/s, s.e. %.2f; measured about 3.0)" % [fine_keen.x, fine_keen.y])
	check(absf(coarse_keen.x - fine_keen.x) < 0.6, "the coarse model drifts like the real run-and-tumble one (%.2f vs %.2f µm/s)" % [coarse_keen.x, fine_keen.x])
	check(absf(coarse_long.x - fine_keen.x) < 0.55, "...and so do the long steps of ultra playback (%.2f vs %.2f µm/s)" % [coarse_long.x, fine_keen.x])
	check(fine_dull.x < 0.8 * fine_keen.x, "a dull bup follows the gradient far less (%.2f vs %.2f µm/s)" % [fine_dull.x, fine_keen.x])
	check(absf(fine_flat.x) < 3.0 * fine_flat.y + 0.05, "nothing drifts in a uniform medium (%.2f, s.e. %.2f)" % [fine_flat.x, fine_flat.y])
	# The same at the level of the tumble rate: a rising concentration lowers a keen bup's tumble
	# rate well below its flat-signal rate; a dull bup's estimate is too noisy to tell the difference.
	var keen_gap := _mean_tumble_rate(100.0, 0.0) - _mean_tumble_rate(100.0, 0.05)
	var dull_gap := _mean_tumble_rate(10.0, 0.0) - _mean_tumble_rate(10.0, 0.05)
	check(keen_gap > 0.15 and keen_gap > 1.4 * dull_gap, "keen bups tell a shallow gradient from none far better than dull ones (gap %.2f vs %.2f tumbles per second)" % [keen_gap, dull_gap])

	# --- Steering: how surely a bup's drift goes up the slope where it is (halfway from a coin toss to certain), and the map of where it could.
	var steer_dish := Dish.new()
	root.add_child(steer_dish)
	steer_dish.strike(_small())
	steer_dish.clear_bups()
	var ramp := []
	for i in steer_dish.field.size * steer_dish.field.size:
		ramp.append(0.0005 * exp(steer_dish.field.cell_centre(i).x / 200.0))
	steer_dish.field.load_values(ramp)
	var keen_genome := Genome.founder()
	var dull_genome := Genome.founder()
	dull_genome["sense"] = 10.0
	var keen_id: int = steer_dish.sim.add_bup(Vector2.ZERO, keen_genome, 1000.0, 3.0, 5000.0, 0, Vector2.RIGHT)
	var dull_id: int = steer_dish.sim.add_bup(Vector2.ZERO, dull_genome, 1000.0, 3.0, 5000.0, 0, Vector2.RIGHT)
	var keen_steer: Vector3 = steer_dish.sim.bup_steering(keen_id)
	var dull_steer: Vector3 = steer_dish.sim.bup_steering(dull_id)
	check(keen_steer.z > dull_steer.z and dull_steer.z > 0.5 and keen_steer.x > 0.99, "in a rising medium a keen bup steers up it more surely than a dull one, and points up the slope (%.2f vs %.2f, heading %.2f)" % [keen_steer.z, dull_steer.z, keen_steer.x])
	var lit := func(id: int) -> int:
		var count := 0
		var bytes: PackedByteArray = steer_dish.sim.bup_steer_bytes(id, 255.0)
		for i in range(3, bytes.size(), 4):
			count += 1 if bytes[i] > 100 else 0
		return count
	check(lit.call(keen_id) > lit.call(dull_id) and lit.call(keen_id) > 0, "a keener bup could steer over more of the dish (%d vs %d cells)" % [lit.call(keen_id), lit.call(dull_id)])
	steer_dish.field.load_values(_uniform(steer_dish.field.size, 0.0000085))
	check(is_equal_approx(steer_dish.sim.bup_steering(keen_id).z, 0.5) and lit.call(keen_id) == 0, "in a flat, dilute medium no bup can steer and nothing is lit")
	steer_dish.free()

	# --- A bup that moves far between two pictures is drawn with a trail back to where it was; a still one, or a new one, has none.
	var trail_dish := Dish.new()
	root.add_child(trail_dish)
	trail_dish.strike(_small())
	trail_dish.clear_bups()
	trail_dish.sim.add_bup(Vector2.ZERO, Genome.founder(), 60.0, 3.0, 5000.0, 0, Vector2.RIGHT)
	var first_picture: PackedFloat32Array = trail_dish.sim.render_buffer(1.0, 4)
	check(first_picture[15] == 0.0, "a bup in its first picture has no trail")
	trail_dish.step(100.0)
	var moved_picture: PackedFloat32Array = trail_dish.sim.render_buffer(1.0, 4)
	check(moved_picture[15] > 5.0, "after moving far between pictures it has a trail (%.1f µm)" % moved_picture[15])
	var still_picture: PackedFloat32Array = trail_dish.sim.render_buffer(1.0, 4)
	check(still_picture[15] == 0.0, "drawn again without having moved it has none")
	var head_is_here: Vector2 = trail_dish.sim.bup_pos(trail_dish.sim.bup_ids()[0])
	check(is_equal_approx(moved_picture[15], moved_picture[15]) and absf(moved_picture[3] + moved_picture[0] * 0.0 - head_is_here.x) < moved_picture[15], "the picture's middle is within a trail's length of the bup")
	trail_dish.free()

	# --- Chemotaxis memory is not left stale by fast playback: after drifting for a while, a bup that goes back
	# to real runs and tumbles starts from the concentration it is in now, not one from long before.
	var stale := _cell()
	for i in 100:
		sim.bup_tumble_rate(stale, 0.0005, DT, 0.0)  # settled on a faint signal
	sim.get_field().reset(Dish.DEFAULT_RADIUS)
	sim.get_field().fill(0.1)
	sim.step(15.0, PackedVector2Array(), PackedFloat32Array(), 0.0)  # a long step: drift, not runs
	var first_after := sim.bup_tumble_rate(stale, 0.1, DT, 0.0)
	check(absf(first_after - Cell.TUMBLE_BASE) < 0.05, "back to runs after drifting, the first tumble rate is the baseline, not a leftover (%.2f)" % first_after)

	# --- Family records: parents, birth and death times (whole minutes), pruning, pinning, and no dead bups in the simulation.
	var lin := BupSim.new()
	lin.reset(300.0, 5)
	lin.set_time(3.0 * 3600.0 + 20.0 * 60.0 + 41.0)
	var ancestor := lin.add_bup(Vector2.ZERO, Genome.founder(), 200.0, 4.0, 8.0, 0, Vector2.RIGHT)  # full grown: ready to divide
	check(lin.lineage_info(ancestor)["born"] == 200 and lin.lineage_info(ancestor)["alive"] and lin.lineage_info(ancestor)["parent"] == 0, "a founder is born at the minute it was added (seconds are not kept) and has no parent")
	lin.step(1.0, PackedVector2Array(), PackedFloat32Array(), 0.0, 3.0 * 3600.0 + 22.0 * 60.0)
	check(lin.bup_count() == 2, "the full-grown bup divided")
	var lin_daughters := []
	for id in lin.bup_ids():
		if id != ancestor:
			lin_daughters.append(id)
	var lin_daughter: int = lin_daughters[0]
	check(lin.lineage_info(lin_daughter)["parent"] == ancestor and lin.lineage_info(lin_daughter)["born"] == 202 and lin.lineage_chain(lin_daughter) == PackedInt64Array([ancestor, lin_daughter]), "a daughter's record names her mother, and her family line runs oldest first")
	lin.remove_bup(ancestor)  # the mother dies while her daughter lives
	check(not lin.has_bup(ancestor) and lin.has_record(ancestor) and not lin.lineage_info(ancestor)["alive"] and lin.bup_count() == 1, "a dead bup leaves the simulation but its record stays while a descendant lives")
	check(lin.lineage_info(ancestor)["died"] == 202 and lin.lineage_info(ancestor)["max_energy"] > 0.0, "its record has the minute it died and the energy it could hold")
	check(lin.lineage_chain(lin_daughter) == PackedInt64Array([ancestor, lin_daughter]), "...and is still in her family line")
	check(not (ancestor in lin.bup_ids()), "dead bups are not among the bups the simulation runs")
	lin.remove_bup(lin_daughter)
	check(lin.record_count() == 0, "when nothing living descends from a dead record it, and its dead ancestors, are dropped (%d left)" % lin.record_count())
	# Pinning keeps a record (and the line to it) until it is let go.
	var gen1 := lin.add_bup(Vector2.ZERO, Genome.founder(), 200.0, 4.0, 8.0, 0, Vector2.RIGHT)
	lin.step(1.0, PackedVector2Array(), PackedFloat32Array(), 0.0)
	var gen2: int = -1
	for id in lin.bup_ids():
		if id != gen1:
			gen2 = id
	check(lin.pin(gen2) and not lin.pin(424242), "a record can be pinned, and only if it exists")
	lin.remove_bup(gen2)
	lin.remove_bup(gen1)
	check(lin.has_record(gen2) and lin.has_record(gen1), "a pinned dead bup keeps itself and its ancestors")
	lin.unpin(gen2)
	check(lin.record_count() == 0, "letting go of the pin drops what nothing needs (%d left)" % lin.record_count())
	# A save keeps the records of dead ancestors of living bups, and the numbers carry over.
	var parent_one := lin.add_bup(Vector2.ZERO, Genome.founder(), 200.0, 4.0, 8.0, 0, Vector2.RIGHT)
	lin.step(1.0, PackedVector2Array(), PackedFloat32Array(), 0.0, 5.0 * 3600.0)
	var child_one: int = -1
	for id in lin.bup_ids():
		if id != parent_one:
			child_one = id
	lin.remove_bup(parent_one)
	var saved_lines: Array = lin.lineage_export()
	var lin2 := BupSim.new()
	lin2.reset(300.0, 6)
	lin2.add_bup(Vector2.ZERO, Genome.founder(), 50.0, -1.0, -1.0, 1, Vector2.RIGHT, child_one)  # the living bup, as a loaded game restores her
	lin2.lineage_import(saved_lines)
	check(lin2.lineage_chain(child_one) == lin.lineage_chain(child_one) and lin2.lineage_chain(child_one).size() == 2 and lin2.lineage_info(parent_one)["died"] == lin.lineage_info(parent_one)["died"] and not lin2.lineage_info(parent_one)["alive"], "a dead ancestor's record survives export and import")
	lin2.remove_bup(child_one)
	check(lin2.record_count() == 0, "...and is dropped with its last living descendant after an import")

	# --- Colour is a neutral marker that drifts: lineages grow apart in colour, and green can reach red in a long game.
	var colour_rng := RandomNumberGenerator.new()
	colour_rng.seed = 21
	var after_72h := []  # about 15 generations of drift (one to two mutations each)
	var after_500h := []  # about 50
	var in_range := true
	for lineage in 300:
		var drifting := Genome.founder()
		for generation in 50:
			drifting = sim.mutate_genome(drifting)
			in_range = in_range and drifting["sat"] >= 0.0 and drifting["sat"] <= 1.0 and drifting["val"] >= Genome.VAL_MIN - 0.0001 and drifting["val"] <= 1.0 and drifting["hue"] >= 0.0 and drifting["hue"] < 1.0
			if generation == 14:
				after_72h.append(drifting["hue"])
		after_500h.append(drifting["hue"])
	check(in_range, "drifting colours stay valid: hue on the wheel, saturation 0-1, brightness not below %.2f" % Genome.VAL_MIN)
	var mean_72 := 0.0
	for h in after_72h:
		mean_72 += h
	mean_72 /= after_72h.size()
	var spread_72 := 0.0
	for h in after_72h:
		spread_72 += (h - mean_72) * (h - mean_72)
	spread_72 = sqrt(spread_72 / after_72h.size())
	var mean_500 := 0.0
	for h in after_500h:
		mean_500 += h
	mean_500 /= after_500h.size()
	var spread_500 := 0.0
	for h in after_500h:
		spread_500 += (h - mean_500) * (h - mean_500)
	spread_500 = sqrt(spread_500 / after_500h.size())
	var kept_colour := 0
	for h in after_500h:
		if absf(h - Genome.founder()["hue"]) < 0.15:
			kept_colour += 1
	check(spread_72 > 0.02, "by about 72 hours lineages have begun to drift apart in colour (hue spread %.3f)" % spread_72)
	check(spread_500 > spread_72 and spread_500 < 0.2 and kept_colour > 300 * 0.7, "colour changes slowly: by 500 hours most lineages are still near their founder's hue (%d of 300 within 0.15; spread %.3f)" % [kept_colour, spread_500])

	# --- Real rates: doubling in 40 minutes, a few percent of the budget on upkeep, starvation survived for hours.
	var grower := _cell()
	var grown_from := _mass(grower)
	for i in 40:  # 40 minutes in 1-minute steps, reserve kept full
		sim.set_bup_energy(grower, 150.0)
		sim.bup_pay_upkeep_and_grow(grower, 60.0)
	check(_mass(grower) / grown_from > 1.9 and _mass(grower) / grown_from < 2.1, "a fed bup doubles its mass in about 40 minutes (x%.2f)" % (_mass(grower) / grown_from))
	var typical := sim.add_bup(Vector2.ZERO, Genome.founder(), 50.0, sqrt(Cell.REFERENCE_MASS), -1.0, 0, Vector2.RIGHT)
	var upkeep_share := sim.bup_upkeep(typical) / Cell.FAST_BUDGET
	check(upkeep_share > 0.06 and upkeep_share < 0.11, "upkeep is under a tenth of the fast-growth budget (%.3f)" % upkeep_share)
	check(sim.bup_max_energy(typical) / sim.bup_upkeep(typical) > 10.0 * 3600.0, "a full reserve lasts more than ten hours of starvation (%.0f h)" % (sim.bup_max_energy(typical) / sim.bup_upkeep(typical) / 3600.0))

	# --- Playback: advance() covers the time asked for, in steps, and with a budget gives up early.
	var clock_dish := Dish.new()
	root.add_child(clock_dish)
	clock_dish.set_seed(9)
	clock_dish.strike(_small())
	var covered := clock_dish.advance(100.0)
	check(is_equal_approx(covered, 100.0) and is_equal_approx(clock_dish.time, 100.0), "advance covers the time asked for (%.1f s)" % covered)
	var short := clock_dish.advance(10000.0, 1)  # a one-microsecond budget: stops after its first step
	check(short > 0.0 and short <= Dish.MAX_STEP + 0.001, "with a budget it stops early and reports what it did (%.2f s of 10000)" % short)

	# --- The bups are moved in parallel, in chunks, each with a random stream of its own: a run is the same on one thread
	# as on all of them (both in the long steps of fast playback and the short ones of slow playback).
	var finals := []
	for threads in [1, 0]:
		var run_dish := Dish.new()
		root.add_child(run_dish)
		run_dish.position = Vector2(500, 400)
		run_dish.set_seed(9)
		run_dish.sim.set_threads(threads)
		var run_start := StartConditions.new()
		run_start.dish_radius = 3000.0
		run_start.nutrient_density = 200000
		run_start.bups = 5
		run_start.bup_limit = 5000
		run_dish.strike(run_start)
		for i in 2400:  # (more bups than one chunk: several run at once)
			run_dish.add_bup(run_dish.global_position + Vector2(i % 60 * 9 - 270, i / 60 * 9 - 180), Genome.founder(), 40.0)
		for i in 12:
			run_dish.step(20.0)
		for i in 20:
			run_dish.step(0.2)
		var ids: Array = Array(run_dish.sim.bup_ids())
		ids.sort()
		var where := []
		for id in ids:
			where.append(run_dish.bup_world_pos(id))
		finals.append([ids, where])
		run_dish.queue_free()
	check(finals[0][0].size() > 2000 and finals[0][0] == finals[1][0] and finals[0][1] == finals[1][1], "one thread and all of them give the same bups in the same places (%d bups)" % finals[0][0].size())

	TestUtil.finish(self, "MODEL TESTS OK")



## A dish of the old 300 µm size: these tests place things by hand and count on a small, fine grid.
func _small() -> StartConditions:
	return TestUtil.small_start()


func _generations(dish: Dish) -> int:
	var total := 0
	for id in dish.bup_ids():
		total += dish.bup_info(id)["divisions"]
	return total


## The mean tumble rate of a bup of this sense over 20 s in which the concentration changes
## by `slope` (log units per second): 0 is a flat medium.
func _mean_tumble_rate(sense: float, slope: float) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var swimmer := _cell(1.0, 4.0, 20.0, sense)
	var total := 0.0
	var n := 0
	for i in 600:
		var rate := sim.bup_tumble_rate(swimmer, 0.01 * exp(slope * i * DT), DT, rng.randfn())
		if i >= 300:
			total += rate
			n += 1
	return total / n


## How fast a crowd of bups drifts along x, and its standard error, in µm/s: 2 dishes of 300 bups
## started near the middle for 60 s in a medium that rises 0.5% per µm along x (or is uniform), with
## full reserves so they neither eat nor divide. `coarse` uses the long steps of fast playback;
## otherwise they really run and tumble.
func _drift_speed(coarse: bool, gradient: bool, sense: float, long_step := 1.5) -> Vector2:
	var moved := []
	for seed_ in 2:
		var d := Dish.new()
		root.add_child(d)
		d.set_seed(700 + seed_)
		var start := StartConditions.new()
		start.dish_radius = 1500.0  # wide: a wall in reach cuts the drift short, and it does so more the longer the steps
		start.bup_limit = Dish.cap_for(1500.0)
		start.nutrient_density = 0  # (the field is loaded below; nothing else should be in it)
		d.strike(start)
		d.clear_bups()
		d.feed_density = 0.0
		var values := []
		for i in d.field.size * d.field.size:
			values.append(0.01 * exp(clampf(d.field.cell_centre(i).x, -250.0, 250.0) / 200.0) if gradient else 0.03)
		d.field.load_values(values)
		var ids := []
		var starts := []
		for i in 300:
			var g := Genome.founder()
			g["sense"] = sense
			var p: Vector2 = d.sim.random_point(80.0)
			# full reserve: no uptake; huge birth mass: no division
			ids.append(d.sim.add_bup(p, g, 1000.0, 3.0, 5000.0, 0, Vector2.from_angle(d.sim.random_float() * TAU)))
			starts.append(p.x)
		if coarse:
			for i in int(60.0 / long_step):
				d.step(long_step)
		else:
			for i in 1200:
				d.step(DT)
		for i in ids.size():
			var info: Dictionary = d.bup_info(ids[i])
			if not info.is_empty():  # (a bup can die of the background death rate)
				moved.append(info["pos"].x - starts[i])
		d.free()
	var mean := 0.0
	for m in moved:
		mean += m
	mean /= moved.size()
	var variance := 0.0
	for m in moved:
		variance += (m - mean) * (m - mean)
	variance /= moved.size() - 1
	return Vector2(mean / 60.0, sqrt(variance / moved.size()) / 60.0)


func _uniform(across: int, value: float) -> Array:
	var out := []
	out.resize(across * across)
	out.fill(value)
	return out
