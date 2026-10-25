extends SceneTree
## Two big dishes at once on the game screen at x10,000 (both grow to the limit, on the GPU): what each gets of the frame.
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
	start.bup_limit = 100000
	start.dish_radius = 90000.0
	start.nutrient_density = 4.0
	start.bloom_density = 2.0
	start.spread_founders()
	Session.free_start = start
	Session.mode = Session.Mode.FREE
	Session.load_requested = false
	var m: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	m.toolbar.set_paused(false)
	m.sim_speed = 10000.0
	for i in count - 1:
		m.add_dish(start)
	var t0 := Time.get_ticks_msec()
	var next := 10.0
	while (Time.get_ticks_msec() - t0) / 1000.0 < seconds:
		await process_frame
		var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
		if elapsed >= next:
			next += 10.0
			var line := "t=%.0fs achieved x%.0f fps %.0f" % [elapsed, m.achieved_speed, Engine.get_frames_per_second()]
			for d: Dish in m.dishes:
				line += " | %d bups %s sim-h %.1f" % [d.population(), d.backend_running(), d.time / 3600.0]
			print(line)
	quit(0)
