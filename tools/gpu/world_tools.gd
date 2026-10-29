extends RefCounted
## Helpers for the windowed checks of the game's GPU path (tools/gpu/events_check.gd, queries_check.gd, validate_dynamics.gd,
## game_dynamics.gd): the dishes of the scenarios, their SAMPLE line, and a load of a dish onto the main RenderingDevice through
## GpuWorld.load_from_cpu.


## The start of a validate_dynamics.gd scenario (the scenarios A-F, L, S and M of game_dynamics.gd; an unknown name is an error).
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
	sc.spread_founders()
	return sc


## The sources a scenario places on its dish (E has three steady ones).
static func place_sources(dish: Dish, scenario: String) -> void:
	if scenario == "E":
		dish.place_source(dish.global_position + Vector2(-30000.0, 0.0), 20.0)
		dish.place_source(dish.global_position + Vector2(20000.0, 25000.0), 20.0)
		dish.place_source(dish.global_position + Vector2(0.0, -40000.0), 20.0)


## The sim-hours a scenario runs when the command line gives no number.
static func default_hours(scenario: String) -> int:
	return {"A": 60, "B": 12, "C": 30, "D": 24, "E": 24, "F": 24, "L": 16, "M": 12, "S": 120}[scenario]


## One SAMPLE line, the format compare_dynamics.py and game_dynamics_flags.py read: `means` are speed, sense, metabolism, size, harm.
static func sample_line(mode: String, scenario: String, seed_value: int, hour: float, pop: int, means: Array, energy: float, nutrient: float) -> void:
	print("SAMPLE %s %s %d %.2f %d %.4f %.4f %.5f %.5f %.5f %.4f %.2f" % [mode, scenario, seed_value, hour, pop, means[0], means[1], means[2], means[3], means[4], energy, nutrient])


## A dish of the scenario, in the tree (for its _ready) but not processing (its _process draws).
static func make_dish(tree: SceneTree, scenario: String, seed_value: int, bup_limit := 0) -> Dish:
	var dish := Dish.new()
	tree.root.add_child(dish)
	dish.process_mode = Node.PROCESS_MODE_DISABLED
	dish.set_seed(seed_value)
	dish.strike(start_conditions(scenario, bup_limit))
	place_sources(dish, scenario)
	return dish


## Puts the dish's bups and field on the GPU (main device) and makes the dish run there: the CPU field records, the CPU's bups are
## cleared (their records stay).
static func load_onto_gpu(dish: Dish, seed_value: int, step_seconds := 20.0) -> void:
	var world := GpuWorld.new(dish.sim)
	var params := dish._gpu_params()
	params["seed"] = seed_value
	params["step_seconds"] = step_seconds
	world.load_from_cpu(dish.field, params)
	dish.gpu_world = world
	dish.set_backend_setting(StartConditions.BACKEND_GPU)  # (so that the dish's own backend rule, asked at every advance, keeps the GPU: Auto would take a small colony back to the CPU)
	dish.gpu_active = true


## Every bup's record on the GPU, read now (stalls). On the render thread, as every RenderingDevice call.
static func read_bups(gpu: GpuSim) -> PackedByteArray:
	var out := []
	RenderingServer.call_on_render_thread(func() -> void: out.append(gpu.read_bups()))
	return out[0]


## The GPU's overflow counters, read now (stalls).
static func overflows(gpu: GpuSim) -> Dictionary:
	var out := []
	RenderingServer.call_on_render_thread(func() -> void: out.append(gpu.overflows()))
	return out[0]


## Frees the dish's GPU state (on the render thread) so the run ends cleanly.
static func release(dish: Dish) -> void:
	if dish.gpu_world != null and dish.gpu_world.gpu != null:
		var gpu := dish.gpu_world.gpu
		RenderingServer.call_on_render_thread(gpu.release)


## How many bups a dish's to_dict() holds (they are one compressed block of records: see DishCodec.pack_bytes).
static func saved_count(saved: Dictionary) -> int:
	var records: Variant = DishCodec.unpack_bytes(saved["cells"])
	return records.size() / GpuSim.RECORD_BYTES if records != null else -1
