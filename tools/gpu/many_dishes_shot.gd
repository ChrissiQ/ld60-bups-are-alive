extends SceneTree
## The game screen with many dishes on the real pooled world, windowed, in a busy state (a picked bup, a full watch list, the pipette tool
## open, frozen dishes, the all-dishes details open), saved at interface sizes 100%, 150% and 250% for a look; it also prints the strip's
## and the freezer's made nodes and the screen's main-thread time a frame.
## tools/run_windowed.sh <log> -- --path . --rendering-driver metal --resolution 1920x1080 --position 6000,6000 -s tools/gpu/many_dishes_shot.gd -- <out_dir> [dishes]

const FROZEN := 6  ## dishes put in the freezer for the picture
const WATCHED := 12  ## bups put on the watch list
const WAIT_MSEC := 700000  ## the longest the world is waited for (every dish in it, the freezes answered)


func _initialize() -> void:
	_run()


func _time(call: Callable, n: int) -> float:
	var t := Time.get_ticks_usec()
	for i in n:
		call.call()
	return float(Time.get_ticks_usec() - t) / n


func _run() -> void:
	SimConstants.apply()
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://many_dishes"
	var count := int(args[1]) if args.size() > 1 else 1000
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var start := StartConditions.new()
	start.dish_radius = 600.0  # (a 48-cell grid: gate C's small dishes)
	start.bups = 60
	start.bup_limit = 300
	start.nutrient_density = 32.0
	start.spread_founders()
	var m: Node = TestUtil.game_screen(self, start)
	for i in 600:
		await process_frame
		if m.is_node_ready() and m.dish != null and i > 5:
			break
	m.toolbar.set_paused(false)
	m.sim_speed = 100.0
	var t0 := Time.get_ticks_msec()
	while m.dishes.size() < count + FROZEN:
		if m.add_dish(start) == null:
			break
		if m.dishes.size() % 50 == 0:
			await process_frame
	print("SHOT asked for %d dishes in %d ms" % [m.dishes.size(), Time.get_ticks_msec() - t0])
	var shown := 0
	var marks := 0
	while Time.get_ticks_msec() - t0 < WAIT_MSEC:
		await process_frame
		shown = WorldClient.shared().latest().dishes.size()
		if shown >= m.dishes.size():
			break
		if (Time.get_ticks_msec() - t0) / 10000 > marks:
			marks += 1
			print("SHOT %d s: %d dishes in the snapshot" % [(Time.get_ticks_msec() - t0) / 1000, shown])
	print("SHOT every dish in the world after %d ms (%d of %d)" % [Time.get_ticks_msec() - t0, shown, m.dishes.size()])
	for i in 300:  # (an atlas with every dish's tile, so the frozen ones keep a picture)
		await process_frame
	for i in FROZEN:
		m.freeze_dish(m.dishes[m.dishes.size() - 1 - i * 7])
	while m.holds.stills_world() and Time.get_ticks_msec() - t0 < WAIT_MSEC:
		await process_frame
	for i in 300:
		await process_frame
	print("SHOT running %d, in the snapshot %d, frozen %d" % [m.dishes.size(), WorldClient.shared().latest().dishes.size(), m.freezer_shelf.entries.size()])
	var ids: PackedInt64Array = m.dish.bup_ids()
	for i in mini(WATCHED, ids.size()):
		m.dish.watch_bup(ids[i])
	if not ids.is_empty():
		m.dish.selected.bup = ids[0]
	m.all_details.open = true
	m.freezer_section.open = true
	m.toolbar.select_tool(Toolbar.Tool.PIPETTE)
	m.set_main_dish(m.dishes[m.dishes.size() / 2])
	m.set_main_dish(m.dishes[0])
	m.dish.selected.bup = ids[0] if not ids.is_empty() else -1
	for i in 120:
		await process_frame
	for paused in [true, false]:
		m.toolbar.set_paused(paused)
		m.sim_speed = 100.0  # (after the pause button, which may set the speed)
		for i in 60:
			await process_frame
		var sampled := [false]
		var on_snap := func(s: Snapshot) -> void:
			for r: int in s.history:
				if not (s.history[r] as Array).is_empty():
					sampled[0] = true
		WorldClient.shared().snapshot_changed.connect(on_snap)
		var quiet: Array[float] = []
		var with_samples: Array[float] = []
		var t_frame := Time.get_ticks_usec()
		for i in 240:
			sampled[0] = false
			await process_frame
			var ms := (Time.get_ticks_usec() - t_frame) / 1000.0
			t_frame = Time.get_ticks_usec()
			(with_samples if sampled[0] else quiet).append(ms)
		WorldClient.shared().snapshot_changed.disconnect(on_snap)
		quiet.sort()
		with_samples.sort()
		print("SHOT frame (wall clock) at %d dishes, %s (speed x%d, achieved x%.0f): %d frames without history samples p50 %.2f p95 %.2f worst %.2f ms; %d with samples, worst %.2f ms" % [m.dishes.size(), "paused" if paused else "running", int(m.sim_speed), m.achieved_speed, quiet.size(), quiet[quiet.size() / 2] if not quiet.is_empty() else 0.0, quiet[int(quiet.size() * 0.95)] if not quiet.is_empty() else 0.0, quiet.back() if not quiet.is_empty() else 0.0, with_samples.size(), with_samples.back() if not with_samples.is_empty() else 0.0])
	print("SHOT strip tabs made %d (of %d), freezer rows made %d (of %d)" % [m.dish_strip.tabs_made(), m.dish_strip.count(), m.freezer_shelf.rows_made(), m.freezer_shelf.entries.size()])
	var thumbs: ThumbsInfo = WorldClient.shared().latest().thumbs
	print("SHOT thumbnails: atlas %s, tiles %d" % [("index %d, publish %d" % [thumbs.texture_index, thumbs.seq]) if thumbs != null else "none", thumbs.tiles.size() if thumbs != null else 0])
	var snap := WorldClient.shared().latest()
	var sampled := snap.history.keys().filter(func(r: int) -> bool: return not (snap.history[r] as Array).is_empty()).size()
	var parts := [
		_time(func() -> void: m._process(1.0 / 60.0), 60), _time(func() -> void: m._on_snapshot(snap), 20), _time(func() -> void: m.dish_strip.refresh(1.0 / 60.0), 200),
		_time(func() -> void: m.watch_list.refresh(), 60), _time(func() -> void: m.graph.refresh(), 60), _time(func() -> void: m._update_all_details(), 60),
	]
	print("SHOT main thread at %d dishes [measured, us]: Main._process %.0f, the screen's snapshot handler %.0f (rows with samples %d, world copies %d), strip refresh %.1f, watch list %.0f, graph %.0f, all-dishes %.1f" % [m.dishes.size(), parts[0], parts[1], sampled, snap.worlds.size(), parts[2], parts[3], parts[4], parts[5]])
	UserSettings.native_override = 1.0
	for pct in [100, 150, 250]:
		UserSettings.ui_scale = pct / 100.0
		UserSettings.apply()
		for i in 60:
			await process_frame
		var image := m.get_viewport().get_texture().get_image()
		var path := ProjectSettings.globalize_path(out.path_join("game_%d.png" % pct))
		image.save_png(path)
		print("SHOT %d%%: %s %s" % [pct, str(image.get_size()), path])
		m.side.ensure_control_visible(m.freezer_section)  # (the tray scrolled down to the watch list and the freezer)
		for i in 10:
			await process_frame
		path = ProjectSettings.globalize_path(out.path_join("game_%d_tray.png" % pct))
		m.get_viewport().get_texture().get_image().save_png(path)
		m.side.scroll_vertical = 0
	var picture: Image = m.dish_strip.picture_of(m.dishes[1])
	print("SHOT a tile read back for a freeze: %s" % (str(picture.get_size()) if picture != null else "none"))
	quit(0)
