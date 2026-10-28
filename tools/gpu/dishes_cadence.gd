extends SceneTree
## A big GPU dish and a small one on the game screen at x10,000: in how many frames each moves, and by how much (a small dish must not move in bursts while the world is slowed by the big one).
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/dishes_cadence.gd   (about 100 s; not with the game running)
func _initialize() -> void:
	_run()
func _run() -> void:
	SimConstants.apply()
	var big := StartConditions.new()
	big.bups = 250; big.bup_limit = 350000; big.dish_radius = 90000.0; big.nutrient_density = 4.0; big.bloom_density = 2.0
	big.spread_founders()
	var m: Node = TestUtil.free_game(big)
	root.add_child(m)
	await process_frame
	m.toolbar.set_paused(false)
	m.sim_speed = 10000.0
	var small := StartConditions.new()
	small.bups = 250; small.bup_limit = 50000; small.dish_radius = 18200.0; small.nutrient_density = 10.0
	small.spread_founders()
	m.add_dish(small)
	var t0 := Time.get_ticks_msec()
	var last := [0.0, 0.0]
	var moved := [0, 0]
	var gaps := [0.0, 0.0]
	var frames := 0
	var window_start := 60000
	while (Time.get_ticks_msec() - t0) < 100000:
		await process_frame
		if Time.get_ticks_msec() - t0 < window_start:
			last = [m.dishes[0].time, m.dishes[1].time]
			continue
		frames += 1
		for i in 2:
			var t: float = m.dishes[i].time
			if t != last[i]:
				moved[i] += 1
				gaps[i] += t - last[i]
			last[i] = t
	print("frames %d | big dish moved in %d, small dish moved in %d | mean advance per move: big %.1f s, small %.1f s | achieved x%.0f" % [frames, moved[0], moved[1], gaps[0] / maxf(moved[0], 1), gaps[1] / maxf(moved[1], 1), m.achieved_speed])
	quit(0)
