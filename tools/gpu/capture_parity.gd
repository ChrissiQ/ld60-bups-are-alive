extends SceneTree
## Parity fixtures: what the CPU engine answers today, recorded so that the pooled GPU world can be compared against it
## once the CPU engine is gone. Every mode writes into <outdir> (default tools/gpu/golden/parity); the README there says which file is what.
## godot --path . --rendering-driver metal --position 6000,6000 --resolution 1920x1080 -s tools/gpu/capture_parity.gd -- <mode> [outdir]   (the screens mode needs the resolution: 250% does not fit the default window)
##   state    the queries_check state (20,000 bups, 60 clouds, RADIUS 3000) and the CPU's answers on it (deterministic)
##   husks    a 50-bup CPU dish with death husks and stationary phase run 6 sim-hours: the husk list and the family records (deterministic)
##   goal     goal mode's dish on the CPU, seed 1, the tracker stepped as Main does (deterministic)
##   screens  the game screen at interface sizes 100/150/250% (png), and one debug log from it (timing and pixels vary)
## (tools/gpu/capture_parity.sh runs all four)

const RADIUS := 3000.0
const BUPS := 20000
const POINTS := 300
const GENES := ["speed", "sense", "metabolism", "size"]
const INFO_KEYS := ["pos", "dir", "energy", "mass", "birth_mass", "divisions", "speed", "sense", "metabolism", "size_gene", "hue", "harm", "mutations", "upkeep", "max_energy", "steering"]

var out := ""


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var mode: String = a[0] if a.size() > 0 else "state"
	out = a[1] if a.size() > 1 else "res://tools/gpu/golden/parity"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	SimConstants.apply()
	match mode:
		"state":
			_state()
			quit(0)
		"husks":
			_husks()
			quit(0)
		"goal":
			_goal()
			quit(0)
		"screens":
			_screens()
		_:
			push_error("capture_parity: unknown mode " + mode)
			quit(1)


func _write(name: String, text: String) -> void:
	var f := FileAccess.open(out.path_join(name), FileAccess.WRITE)
	f.store_string(text)


func _write_bytes(name: String, bytes: PackedByteArray, gzip := false) -> void:
	var f := FileAccess.open_compressed(out.path_join(name), FileAccess.WRITE, FileAccess.COMPRESSION_GZIP) if gzip else FileAccess.open(out.path_join(name), FileAccess.WRITE)
	f.store_buffer(bytes)


func _floats(v: PackedFloat32Array) -> PackedByteArray:
	return v.to_byte_array()


func _state() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var sim := BupSim.new()
	sim.reset(RADIUS, 5)
	sim.set_limit(BUPS + 1000)
	var spots := []
	for i in BUPS:
		var g := Genome.founder()
		g["speed"] = 10.0 + 40.0 * sim.random_float()
		g["sense"] = 20.0 + 100.0 * sim.random_float()
		g["metabolism"] = 0.6 + 0.8 * sim.random_float()
		g["size"] = 3.0 + 2.0 * sim.random_float()
		g["harm"] = 0.0 if i % 3 == 0 else 0.3 * sim.random_float() * sim.random_float()
		g["mutations"] = int(10.0 * sim.random_float())
		var born := Cell.mass_to_add(g)
		var at: Vector2 = sim.random_point(RADIUS * 0.95) if i < BUPS - 50 else spots[i % 97]
		spots.append(at)
		sim.add_bup(at, g, 30.0, sqrt(born * (1.0 + sim.random_float())), born, i % 5, Vector2.RIGHT)
	var field := sim.get_field()
	field.fill(0.002)
	for k in 60:
		field.add_cloud(sim.random_point(RADIUS * 0.8), 20.0, 2000.0 + 100.0 * k)
	var state := sim.export_state_bytes()
	_write_bytes("state_records.bin.gz", state, true)
	var packed := field.export_packed()
	_write_bytes("state_field_conc.bin.gz", _floats(packed["conc"]), true)
	_write_bytes("state_field_puffs.bin.gz", _floats(packed["puffs"]), true)
	var ids := sim.bup_ids()
	var lines := PackedStringArray()
	lines.append("# state: %d bups radius %.0f seed 5; rng seed 7 for the points; ids are the sim's, in bup_ids() order" % [BUPS, RADIUS])
	# pick and nearest_and_count, the rounds of queries_check
	for r in POINTS:
		var pixel: float = [0.5, 2.0, 20.0][r % 3]
		var slack: float = [0.0, 3.0][r % 2]
		var at: Vector2
		if r % 2 == 0:
			at = sim.bup_info(ids[rng.randi_range(0, BUPS - 1)])["pos"] + Vector2(rng.randf_range(-2.0, 2.0), rng.randf_range(-2.0, 2.0))
		else:
			at = Vector2(rng.randf_range(-RADIUS, RADIUS), rng.randf_range(-RADIUS, RADIUS))
		var id := sim.pick_bup(at, slack, pixel)
		lines.append("pick %d %s %s %s -> %d" % [r, var_to_str(at), slack, pixel, id])
		for s in GpuLayout.NEAR_SLOTS:
			var q := Vector2(rng.randf_range(-RADIUS, RADIUS), rng.randf_range(-RADIUS, RADIUS))
			var radius: float = [0.0, 60.0, 300.0, 1000.0][s]
			lines.append("near %d %s %s -> %s" % [r, var_to_str(q), radius, var_to_str(sim.nearest_and_count(q, radius))])
	_write("queries_pick_near.txt", "\n".join(lines) + "\n")
	# population answers
	var words := state.to_float32_array()
	var fractions := [["speed", 30.0], ["sense", float(words[GpuLayout.R_SENSE + GpuLayout.RECORD_WORDS * 17])], ["metabolism", float(words[GpuLayout.R_METABOLISM + GpuLayout.RECORD_WORDS * 123]) + 1e-12], ["size", 4.2]]
	var stats := PackedStringArray(["# population_stats (full dict, var_to_str), then fraction_with_gene_at_least(gene, threshold)", var_to_str(sim.population_stats())])
	for f: Array in fractions:
		stats.append("fraction %s %s -> %s" % [f[0], var_to_str(f[1]), var_to_str(sim.fraction_with_gene_at_least(f[0], f[1]))])
	_write("queries_stats.txt", "\n".join(stats) + "\n")
	# bup_info (all keys) and the steering readout for 40 fixed bups
	var info := PackedStringArray(["# bup_info dict and bup_steering for the bups at these indexes of bup_ids(): 0, 500, 1000, ... (40 of them)"])
	for k in 40:
		var id: int = ids[k * 500]
		info.append("id %d index %d" % [id, k * 500])
		info.append("  info %s" % var_to_str(sim.bup_info(id)))
		info.append("  steering %s radius2 %s pos %s" % [var_to_str(sim.bup_steering(id)), var_to_str(sim.bup_radius(id, 2.0)), var_to_str(sim.bup_pos(id))])
	_write("queries_info.txt", "\n".join(info) + "\n")
	# the medium at 50 fixed points: the dish's nutrient_at readout (concentration and slope) and steering_at
	var med := PackedStringArray(["# field.read(local) (x = concentration, y z = gradient) and steering_at(local, speed 30, sense_range 60) at 50 points of a fixed grid"])
	var grid_rng := RandomNumberGenerator.new()
	grid_rng.seed = 11
	for k in 50:
		var p := Vector2(grid_rng.randf_range(-RADIUS * 0.9, RADIUS * 0.9), grid_rng.randf_range(-RADIUS * 0.9, RADIUS * 0.9))
		med.append("point %s read %s steering_at %s" % [var_to_str(p), var_to_str(field.read(p)), var_to_str(sim.steering_at(p, 30.0, 60.0))])
	_write("medium_points.txt", "\n".join(med) + "\n")
	# haze bytes (the arguments dish_drawing.gd uses) and steer maps of three bups
	var haze := field.haze_bytes(Cell.DETECTION_FLOOR, 0.5 * 255.0 / sqrt(10.0 * Cell.HALF_SATURATION), 0.45 * 255.0)
	_write_bytes("haze_bytes.bin.gz", haze, true)
	var steer := PackedStringArray(["# bup_steer_bytes(id, Dish.STEER_ALPHA) for these ids, files steer_<id>.bin.gz; haze_bytes.bin.gz is %d bytes" % haze.size()])
	for k in [3, BUPS / 2, BUPS - 1]:
		var id: int = ids[k]
		var bytes := sim.bup_steer_bytes(id, Dish.STEER_ALPHA)
		_write_bytes("steer_%d.bin.gz" % id, bytes, true)
		steer.append("id %d index %d bytes %d" % [id, k, bytes.size()])
	_write("steer_ids.txt", "\n".join(steer) + "\n")
	print("PARITY state: %d bups, haze %d bytes" % [sim.bup_count(), haze.size()])


## A small CPU dish with death husks, run for a while (the husks and the family records after it).
func _husks() -> void:
	var start := StartConditions.new()
	start.bups = 50
	start.bup_limit = 20000
	start.dish_radius = 3000.0
	start.nutrient_density = 32.0
	start.death_husks = true
	start.stationary_phase = true
	start.sim_backend = StartConditions.BACKEND_CPU
	start.spread_founders()
	var d := Dish.new()
	root.add_child(d)
	d.process_mode = Node.PROCESS_MODE_DISABLED
	d.set_seed(3)
	d.strike(start)
	for i in 1080:  # 6 sim-hours in 20 s steps
		d.advance(20.0)
	var sim := d.sim
	var ids := sim.bup_ids()
	var lines := PackedStringArray()
	lines.append("# dish: 50 founders, 3000 um radius, density 32, death_husks and stationary_phase, CPU, seed 3, 6 sim-hours; time %s population %d husks %d records %d" % [d.time, d.population(), sim.husk_count(), sim.record_count()])
	var ex := sim.husks_export()
	lines.append("# husks_export: 5 floats a husk (x y energy age next)")
	for k in ex.size() / 5:
		lines.append("husk %s %s %s %s %s" % [ex[k * 5], ex[k * 5 + 1], ex[k * 5 + 2], ex[k * 5 + 3], ex[k * 5 + 4]])
	if ex.size() >= 5:
		var near := sim.husk_near(Vector2(ex[0], ex[1]), 0.01)
		lines.append("husk_near first %s" % var_to_str(near))
		lines.append("husk_buffer(2.0, 0) floats %d" % sim.husk_buffer(2.0, 0).size())
	_write("husks.txt", "\n".join(lines) + "\n")
	_write_bytes("lineage_export.bin.gz", sim.lineage_export_bytes(), true)
	var alive := sim.alive_ids()
	var meta := PackedStringArray(["records=%d" % sim.record_count(), "alive=%d" % alive.size(), "next_id=%d" % sim.get_next_id(), "population=%d" % d.population(), "time=%s" % d.time])
	_write("lineage_export.txt", "\n".join(meta) + "\n")
	print("PARITY husks: %d husks, %d records, %d alive" % [sim.husk_count(), sim.record_count(), alive.size()])


func _goal() -> void:
	var d := Dish.new()
	root.add_child(d)
	d.process_mode = Node.PROCESS_MODE_DISABLED
	d.set_seed(1)
	d.strike(null)
	d.set_backend_setting(StartConditions.BACKEND_CPU)
	var tracker := GoalTracker.new()
	var log := PackedStringArray()
	var done_at: Array = []
	tracker.goal_completed.connect(func(goal: Goal) -> void:
		done_at.append([goal.title, d.time])
		log.append("COMPLETED %s at %s s (%s)" % [goal.title, d.time, SimClock.format(d.time)])
		tracker.apply_costs(d))
	tracker.apply_costs(d)
	var cap := 40.0 * 3600.0
	var next_sample := 0.0
	while d.time < cap and not tracker.all_done():
		if d.time >= next_sample:
			log.append("t %d pop %d goal %d held %s sense>=70 %s" % [int(d.time), d.population(), tracker.index, tracker.held, d.fraction_with_gene_at_least("sense", GoalTracker.SENSE_TARGET)])
			next_sample += 1800.0
		var done := d.advance(20.0)
		tracker.update(d, done)
	log.insert(0, "# goal mode: Dish.strike(null), seed 1, CPU backend, advance(20 s) then tracker.update as Main does, until both goals or %d sim-hours; ended at %s s, goal index %d" % [int(cap / 3600.0), d.time, tracker.index])
	_write("goal_run.txt", "\n".join(log) + "\n")
	print("PARITY goal: ended at %s s, index %d, completions %s" % [d.time, tracker.index, str(done_at)])


func _screens() -> void:
	var start := StartConditions.new()
	start.bups = 300
	start.dish_radius = 4000.0
	start.bup_limit = 30000
	start.nutrient_density = 32.0
	start.spread_founders()
	var m: Node = TestUtil.game_screen(self, start)
	for i in 600:
		await process_frame
		if m.is_node_ready() and m.toolbar != null and m.dish != null and i > 5:
			break
	m.toolbar.set_paused(false)
	m.sim_speed = 600.0
	for i in 120:
		await process_frame
	UserSettings.native_override = 1.0
	var log_path := ""
	for pct in [100, 150, 250]:
		UserSettings.ui_scale = pct / 100.0
		UserSettings.apply()
		for i in 30:
			await process_frame
		var image := m.get_viewport().get_texture().get_image()
		image.save_png(ProjectSettings.globalize_path(out.path_join("game_%d.png" % pct)))
		print("PARITY screen %d%%: %s" % [pct, str(image.get_size())])
	var shot := m.get_viewport().get_texture().get_image()
	DebugLog.directory = ProjectSettings.globalize_path(out.path_join("debuglog"))
	var written := DebugLog.write(DebugLog.report(m.dish, m, m.debug_state()), shot)
	print("PARITY debug log: " + written)
	quit(0)
