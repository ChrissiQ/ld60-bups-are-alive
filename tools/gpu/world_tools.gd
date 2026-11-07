extends RefCounted
## The dishes of the windowed checks as scenarios of the pooled world (the scenarios A-F, L, S and M of validate_dynamics.gd), their
## SAMPLE line and the figures a SAMPLE line holds. Pure data in, no device: the checks give the scenario to a `SimHarness`.


## The start of a scenario (an unknown name is an error); `bup_limit` replaces the scenario's limit when above 0.
static func start_conditions(scenario: String, bup_limit := 0) -> StartConditions:
	var sc := StartConditions.new()
	match scenario:
		"A":
			pass
		"B":
			sc.bups = 250; sc.bup_limit = 20000; sc.dish_radius = 3000.0; sc.nutrient_density = 32.0; sc.feed_density = 5.0
		"C":
			sc.bups = 250; sc.bup_limit = 100000; sc.dish_radius = 90000.0; sc.nutrient_density = 32.0; sc.feed_density = 2.0
		"D":
			sc.bups = 250; sc.bup_limit = 100000; sc.dish_radius = 90000.0; sc.nutrient_density = 4.0; sc.bloom_density = 2.0
		"E":
			sc.bups = 250; sc.bup_limit = 50000; sc.dish_radius = 90000.0; sc.nutrient_density = 8.0; sc.bloom_density = 0.5
		"F":
			sc.bups = 250; sc.bup_limit = 20000; sc.dish_radius = 10000.0; sc.nutrient_density = 8.0; sc.bloom_density = 0.5
		"L":
			sc.bups = 250; sc.bup_limit = 300000; sc.dish_radius = 90000.0; sc.nutrient_density = 4.0; sc.bloom_density = 4.0
		"S":
			sc.bups = 250; sc.bup_limit = 20000; sc.dish_radius = 10000.0; sc.nutrient_density = 8.0
		"M":
			sc.bups = 250; sc.bup_limit = 1000000; sc.dish_radius = 90000.0; sc.nutrient_density = 32.0; sc.feed_density = 5.0; sc.bloom_density = 5.0
		_:
			push_error("world_tools: unknown scenario '%s'" % scenario)
	if bup_limit > 0:
		sc.bup_limit = bup_limit
	return sc


## The sources a scenario places on its dish, dish-local: [position, rate] each (E has three steady ones).
static func sources_of(scenario: String) -> Array:
	if scenario == "E":
		return [[Vector2(-30000.0, 0.0), 20.0], [Vector2(20000.0, 25000.0), 20.0], [Vector2(0.0, -40000.0), 20.0]]
	return []


## The scenario as a harness dish: StartConditions' values, its sources, the seed.
static func scenario(name: String, seed_value: int, bup_limit := 0) -> Scenario:
	var start := start_conditions(name, bup_limit)
	var s := Scenario.new()
	s.label = name
	s.radius = start.dish_radius
	s.limit = start.bup_limit
	s.bups = start.bups
	s.nutrient_density = start.nutrient_density
	s.feed_density = start.feed_density
	s.bloom_density = start.bloom_density
	s.resolution = start.nutrient_resolution
	s.sources = sources_of(name)
	s.seed_value = seed_value
	return s


## The sim-hours a scenario runs when the command line gives no number.
static func default_hours(name: String) -> int:
	return {"A": 60, "B": 12, "C": 30, "D": 24, "E": 24, "F": 24, "L": 16, "M": 12, "S": 120}[name]


## One SAMPLE line, the format compare_dynamics.py and game_dynamics_flags.py read: `means` are speed, sense, metabolism, size, harm.
static func sample_line(mode: String, name: String, seed_value: int, hour: float, pop: int, means: Array, energy: float, nutrient: float) -> void:
	print("SAMPLE %s %s %d %.2f %d %.4f %.4f %.5f %.5f %.5f %.4f %.2f" % [mode, name, seed_value, hour, pop, means[0], means[1], means[2], means[3], means[4], energy, nutrient])
