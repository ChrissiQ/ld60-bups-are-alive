extends SceneTree
## Run: godot --headless --path . -s tests/births_bound_test.gd
## The bound on a dish's births that SimCore._ensure_room reserves room by (SimCore.births_series), computed from the constants:
##  - the fastest growth of a bup's mass in one step is 1 + GROWTH_RATE x (metabolism max x third raise) x (1 - 3 x REACH_COST) x delta
##    (about 1.0147 at the longest step, 20 s), and the least mass of a bup that divides is ADD_MASS_FACTOR x size min^2 (2);
##  - the series is the dish's bups at each step: it never passes the cap, never falls, equals doubling when the mass is not known, and
##    from 5,000 bups of mass 7 each takes 14 steps to at most about 240,000 (doubling would give 82 million);
##  - the guards: the model the bound rests on is in the kernel text (the growth expression, the division condition, the writers of a
##    bup's mass), so a change to any of them fails here and the bound has to be derived again.


func _init() -> void:
	_constants()
	_series()
	_kernel_text()
	TestUtil.finish(self, "births_bound_test OK")


func _constants() -> void:
	var g := SimCore.growth_factor_max(Governor.MAX_STEP)
	var expected := 1.0 + Cell.GROWTH_RATE * 3.0 * 0.85 * 20.0
	TestUtil.check(is_equal_approx(g, expected), "growth_factor_max(20 s) is 1 + GROWTH_RATE x 3.0 x 0.85 x 20 (%s, expected %s)" % [g, expected])
	TestUtil.check(g > 1.014 and g < 1.015, "the fastest growth in a 20 s step is about 1.47%% (%s)" % g)
	TestUtil.check(is_equal_approx(SimCore.division_mass_min(), 2.0), "the least mass that divides is 2")
	TestUtil.check(Genome.GENES["metabolism"][1] == 2.0 and Genome.GENES["size"][0] == 2.0, "the gene ranges the bound is derived from (metabolism max 2.0, size min 2.0)")
	TestUtil.check(Genome.REACH_FACTOR_1 < Genome.REACH_FACTOR_2 and Genome.REACH_FACTOR_2 < Genome.REACH_FACTOR_3, "the raised ceilings ascend, the third is the largest")
	TestUtil.check(is_equal_approx(Genome.REACH_COST, 0.05) and Cell.ADD_MASS_FACTOR == 0.5, "REACH_COST 0.05 and ADD_MASS_FACTOR 0.5, as the derivation uses")
	TestUtil.check(Genome.REACH_COST * 3.0 < 0.8, "three raises never meet the kernel's 0.2 floor on the reach factor")
	TestUtil.check(SimCore.growth_factor_max(1.0) < g and SimCore.growth_factor_max(0.0) == 1.0, "growth falls with the step and is 1 with none")


func _series() -> void:
	var delta := Governor.MAX_STEP
	var steps := 14
	var cap := 2_000_000
	var known := SimCore.births_series(5000, 5000.0 * 7.0, cap, steps, delta)
	TestUtil.check(known.size() == steps + 1 and known[0] == 5000, "the series has steps + 1 numbers and begins at the count")
	var rising := true
	for j in steps:
		rising = rising and known[j + 1] >= known[j] and known[j + 1] <= 2 * known[j]
	TestUtil.check(rising, "the series never falls and never more than doubles in a step")
	TestUtil.check(known[steps] < 300_000 and known[steps] > 100_000, "5,000 bups of mass 7 reach at most about 240,000 in 14 steps (%d)" % known[steps])
	var unknown := SimCore.births_series(5000, -1.0, cap, steps, delta)
	TestUtil.check(unknown[steps] == mini(cap, 5000 << steps) and unknown[steps] == cap, "an unknown mass gives doubling, held at the cap (%d)" % unknown[steps])
	var capped := SimCore.births_series(1_900_000, 1.0e9, cap, steps, delta)
	var held := true
	for v in capped:
		held = held and v <= cap
	TestUtil.check(held and capped[steps] == cap, "the series never passes the cap")
	var over := SimCore.births_series(3_000_000, 1.0e9, cap, 2, delta)
	TestUtil.check(over[0] == cap, "a count over the cap begins at the cap")
	# a dish of the least mass that divides can only double, and a heavier one has more bups' worth of mass to split
	var light := SimCore.births_series(100, 100.0 * 2.0, cap, 3, delta)
	TestUtil.check(light[3] <= 800, "100 bups of the least mass reach at most 800 in 3 steps (%d)" % light[3])
	var starved := SimCore.births_series(100, 0.0, cap, 5, delta)
	TestUtil.check(starved[5] == 100, "a dish with no mass has no births")


func _kernel_text() -> void:
	var all: Dictionary = GpuKernels.all()
	var life := _flat(all, ["pool_life", "pool_ac_conj_life"])
	TestUtil.check(life.contains("mass >= birth + add_mass"), "a bup divides when its mass is at least its birth mass plus add_mass")
	TestUtil.check(life.contains("add_mass = P[P_ADD_MASS_FACTOR] * BUPS[b + R_SIZE] * BUPS[b + R_SIZE]"), "add_mass is ADD_MASS_FACTOR x size^2")
	var swim := _flat(all, ["pool_swim"])
	var grow_expr := "float grow = min(P[P_GROWTH_RATE] * metab * mass * delta * (donor > 0.5 ? 1.0 - P[P_DONOR_COST] : 1.0) * max(0.2, 1.0 - P[P_REACH_COST] * raised) * (((rl >> 8) & 3) == 2 ? 1.0 - P[P_KEY_COST] : 1.0),"
	TestUtil.check(swim.contains(grow_expr), "a bup's growth in a step is the expression the bound is derived from")
	TestUtil.check(swim.contains("mass += grow;"), "mass grows only by `grow` in the swim kernel")
	# the places a bup's mass is written: the swim kernel (growth, starvation), division (a share each) and a daughter's birth
	var writers := 0
	for name: String in all:
		var src: String = all[name]["source"]
		for line in src.split("\n"):
			if line.contains("R_MASS] =") and not line.contains("R_MASS] ==") and not line.contains("CHILD[") and not line.contains("BUPS[b + R_MASS] = mass;"):
				writers += 1
	TestUtil.check(writers == 0, "no kernel writes a bup's mass but by assigning the local `mass` back, or a daughter's (%d other writers)" % writers)


func _flat(all: Dictionary, names: Array) -> String:
	var out := ""
	for n: String in names:
		if all.has(n):
			out += (all[n]["source"] as String).replace("\n", " ").replace("\t", " ")
	return out
