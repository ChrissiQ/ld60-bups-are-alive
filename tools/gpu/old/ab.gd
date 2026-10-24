extends SceneTree
## -- N radius_um res nutrient_density steps
func make(n: int, rad: float, res: int, dens: float, parallel: bool) -> Dish:
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(7)
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = 100000; sc.dish_radius = rad; sc.nutrient_resolution = res
	sc.nutrient_density = dens
	sc.spread_founders()
	dish.strike(sc)
	var sim = dish.sim
	sim.set_parallel_uptake(parallel)
	while dish.population() < n:
		var g := Genome.founder()
		var born := Cell.mass_to_add(g)
		sim.add_bup(sim.random_point(rad * 0.9), g, Dish.FOUNDER_ENERGY, sqrt(born * 1.5), born, 0, Vector2.RIGHT)
	return dish
func energies(dish: Dish) -> Dictionary:
	var out := {}
	for id in dish.sim.bup_ids():
		out[id] = float(dish.sim.bup_info(id)["energy"])
	return out
func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var n := int(a[0]); var rad := float(a[1]); var res := int(a[2]); var dens := float(a[3]); var steps := int(a[4])
	var old := make(n, rad, res, dens, false)
	var neu := make(n, rad, res, dens, true)
	var e0 := energies(old)
	var e0n := energies(neu)
	var same := true
	for id in e0: if not is_equal_approx(e0[id], e0n.get(id, -1.0)): same = false
	var f0: float = old.field.total()
	for i in steps:
		old.step(20.0); neu.step(20.0)
	var e1 := energies(old); var e1n := energies(neu)
	var gain_o := 0.0; var gain_n := 0.0; var sum_abs := 0.0; var maxd := 0.0; var cnt := 0
	for id in e1:
		if e1n.has(id) and e0.has(id):
			var go: float = e1[id] - e0[id]; var gn: float = e1n[id] - e0[id]
			gain_o += go; gain_n += gn; sum_abs += absf(go - gn); maxd = maxf(maxd, absf(go - gn)); cnt += 1
	var fo: float = old.field.total(); var fn: float = neu.field.total()
	print("N=%d R=%d res=%d dens=%s steps=%d | start-identical=%s common=%d/%d | field total: old %.4f new %.4f (rel diff %.8f; removed old %.4f new %.4f) | gain sum old %.1f new %.1f (rel %.8f) | mean|per-bup diff|/mean gain %.8f, max diff %.3f | pop old %d new %d" % [n, rad, res, str(dens), steps, str(same), cnt, e1.size(), fo, fn, (fn - fo) / maxf(fo, 1e-12), f0 - fo, f0 - fn, gain_o, gain_n, (gain_n - gain_o) / maxf(absf(gain_o), 1e-12), (sum_abs / maxf(cnt, 1)) / maxf(absf(gain_o) / maxf(cnt, 1), 1e-12), maxd, old.population(), neu.population()])
	quit(0)
