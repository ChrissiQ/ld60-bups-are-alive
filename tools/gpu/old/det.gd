extends SceneTree
func run(threads: int, bloom: float) -> String:
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(3)
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = 30000; sc.dish_radius = 20000.0; sc.bloom_density = bloom; sc.nutrient_density = 10.0; sc.feed_density = 2.0
	sc.spread_founders()
	dish.strike(sc)
	dish.sim.set_threads(threads)
	while dish.population() < 20000:
		var g := Genome.founder()
		var born := Cell.mass_to_add(g)
		dish.sim.add_bup(dish.sim.random_point(18000.0), g, Dish.FOUNDER_ENERGY, sqrt(born * 1.5), born, 0, Vector2.RIGHT)
	for i in 120: dish.step(20.0)
	var e := 0.0
	for id in dish.sim.bup_ids(): e += float(dish.sim.bup_info(id)["energy"])
	return "pop=%d energy=%.6f field=%.6f hash=%d puffs=%d" % [dish.population(), e, dish.field.total(), dish.field.values().to_byte_array().hex_encode().hash(), dish.field.puff_count()]
func _init() -> void:
	for bloom in [0.0, 5.0]:
		var a := run(1, bloom); var b := run(0, bloom)
		print("DET bloom=%s\n  1 thread : %s\n  all      : %s\n  %s" % [str(bloom), a, b, "IDENTICAL" if a == b else "DIFFERENT"])
	quit(0)
