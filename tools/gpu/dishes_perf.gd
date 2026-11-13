extends SceneTree
## Two big dishes at once on the game screen at x10,000 (both grow to the limit): what each gets of the frame.
## On macOS:
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/dishes_perf.gd -- [dishes] [seconds]

func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var args := OS.get_cmdline_user_args()
	var count := int(args[0]) if args.size() > 0 else 2
	var seconds := float(args[1]) if args.size() > 1 else 60.0
	var start := StartConditions.new()
	start.bups = 250
	start.bup_limit = int(OS.get_environment("LIMIT")) if OS.get_environment("LIMIT") != "" else 100000
	start.dish_radius = 90000.0
	start.nutrient_density = 4.0
	start.bloom_density = 2.0
	start.spread_founders()
	var m: Node = TestUtil.game_screen(self, start)
	for i in 3600:  # (the screen's _ready, its dish and the world's device come a few frames after the script starts)
		if m.is_node_ready() and m.dish != null and m.dish.row >= 0:
			break
		await process_frame
	for i in 3600:
		if WorldClient.shared().backend.status().get("ready", false):
			break
		await process_frame
	m.toolbar.set_paused(false)
	m._set_paused(false)
	m.sim_speed = float(OS.get_environment("SPEED")) if OS.get_environment("SPEED") != "" else 10000.0
	for i in count - 1:
		m.add_dish(start)
	var t0 := Time.get_ticks_msec()
	var piped := OS.get_environment("PIPETTE") == "1"  # (PIPETTE=1: at 25 s the pipette takes the bups within 30 mm of the middle into a new dish)
	var next := 10.0
	while (Time.get_ticks_msec() - t0) / 1000.0 < seconds:
		await process_frame
		var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
		if piped and elapsed >= 25.0:
			piped = false
			var before: int = m.dish.population()
			var started := Time.get_ticks_msec()
			var made: Dish = m.pipette(m.dish.global_position, 30000.0)
			var took := Time.get_ticks_msec() - started
			var chain := 0
			if made != null:
				var some: int = made.bup_ids()[0]
				chain = made.lineage_chain(some).size()
			print("PIPETTE: %d bups before, %d moved, new dish %s, took %d ms, a moved bup has a family line of %d" % [before, made.population() if made != null else -1, str(made != null), took, chain])
		if elapsed >= next:
			next += 10.0
			var line := "t=%.0fs achieved x%.0f fps %.0f" % [elapsed, m.achieved_speed, Engine.get_frames_per_second()]
			for d: Dish in m.dishes:
				line += " | %d bups sim-h %.1f" % [d.population(), d.time / 3600.0]
			var lo := 1e30
			var hi := -1e30
			for d: Dish in m.dishes:
				lo = minf(lo, d.time)
				hi = maxf(hi, d.time)
			print(line + " | clock spread %.0f s" % (hi - lo))
	quit(0)
