extends SceneTree
## godot --headless --path <proj> -s bench.gd -- N radius_um resolution bloom steps
func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var n := int(a[0]); var rad := float(a[1]); var res := int(a[2]); var bloom := float(a[3]); var steps := int(a[4])
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(1)
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = 100000; sc.dish_radius = rad; sc.nutrient_resolution = res; sc.bloom_density = bloom
	sc.nutrient_density = 32.0
	sc.spread_founders()
	dish.strike(sc)
	var sim = dish.sim
	while dish.population() < n:
		var g := Genome.founder()
		var born := Cell.mass_to_add(g)
		sim.add_bup(sim.random_point(rad * 0.9), g, Dish.FOUNDER_ENERGY, sqrt(born * 1.5), born, 0, Vector2.RIGHT)
	for i in 5: dish.step(20.0)
	var t0 := Time.get_ticks_usec()
	for i in steps: dish.step(20.0)
	var dt := float(Time.get_ticks_usec() - t0) / steps
	print("N=%d pop=%d R=%d res=%d: %.0f us/step  (-> x%.0f at 9ms/frame)" % [n, dish.population(), rad, res, dt, 20.0 * 9000.0 / dt * 60.0 / 60.0 * 1.0])
	quit(0)
