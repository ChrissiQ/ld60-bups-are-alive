extends RefCounted
## Helpers for the windowed checks of the game's GPU path (tools/gpu/events_check.gd, queries_check.gd, dish_speed.gd): the dishes of
## validate_dynamics.gd's scenarios, and a load of a dish onto the main RenderingDevice as GpuWorld.load_from_cpu will make it (Step 3C
## owns that; until it exists these checks load the state themselves, the same way).


## The start of a validate_dynamics.gd scenario (B: 3 mm dish, 20k cap, feed; D: 90 mm, bloom 2.0, cap 100k; F: 10 mm, bloom 0.5).
static func start_conditions(scenario: String, bup_limit := 0) -> StartConditions:
	var sc := StartConditions.new()
	match scenario:
		"B":
			sc.bups = 250; sc.bup_limit = 20000; sc.dish_radius = 3000.0; sc.nutrient_density = 32.0; sc.feed_density = 5.0
		"D":
			sc.bups = 250; sc.bup_limit = 100000; sc.dish_radius = 90000.0; sc.nutrient_density = 4.0; sc.bloom_density = 2.0
		"F":
			sc.bups = 250; sc.bup_limit = 20000; sc.dish_radius = 10000.0; sc.nutrient_density = 8.0; sc.bloom_density = 0.5
	if bup_limit > 0:
		sc.bup_limit = bup_limit
	sc.spread_founders()
	return sc


## A dish of the scenario, in the tree (for its _ready) but not processing (its _process draws, which is Step 3A's).
static func make_dish(tree: SceneTree, scenario: String, seed_value: int, bup_limit := 0) -> Dish:
	var dish := Dish.new()
	tree.root.add_child(dish)
	dish.process_mode = Node.PROCESS_MODE_DISABLED
	dish.set_seed(seed_value)
	dish.strike(start_conditions(scenario, bup_limit))
	return dish


## Puts the dish's bups and field on the GPU (main device) and makes the dish run there: the CPU field records, the CPU's bups are
## cleared (their records stay).
static func load_onto_gpu(dish: Dish, seed_value: int, step_seconds := 20.0) -> void:
	var world := GpuWorld.new(dish.sim)
	world.gpu = GpuSim.new(RenderingServer.get_rendering_device())
	var field := dish.field
	var packed := field.export_packed()
	var state := dish.sim.export_state_bytes()
	var feed := dish.feed_density * Dish.CONCENTRATION_PER_DENSITY / 3600.0
	var load := func() -> void:
		world.gpu.load_state(field.get_size(), field.get_spacing(), dish.radius, packed["conc"], field.export_owner(), state, SimConstants.build(), dish.bup_limit, field.export_fill_weights(), feed, step_seconds, field.get_diffusion(), packed["puffs"], seed_value, dish.upkeep_factor, dish.sim.get_next_id())
	RenderingServer.call_on_render_thread(load)
	field.set_recording(true)
	dish.sim.import_state_bytes(PackedByteArray())  # (the bups are on the GPU now; their records stay here)
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
