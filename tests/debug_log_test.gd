extends SceneTree
## Run: godot --headless --path . -s tests/debug_log_test.gd
## The F12 debug log: what it holds, that it writes a stamped file, that every write prunes, and that F12 works in the tour.


func _logs() -> Array:
	return Array(DirAccess.get_files_at(DebugLog.directory)).filter(func(f: String) -> bool: return f.ends_with(".log"))


func _initialize() -> void:
	DebugLog.directory = "user://test_logs"
	DirAccess.make_dir_recursive_absolute(DebugLog.directory)
	for f in DirAccess.get_files_at(DebugLog.directory):
		DirAccess.remove_absolute(DebugLog.directory.path_join(f))

	var canned := TestUtil.use_fake_world(self)  # (the world the headless run has runs nothing: this one serves three bups in dish 1)
	canned.device = "test device"
	Session.mode = Session.Mode.FREE
	Session.free_start = TestUtil.small_start()
	Session.tutorial_wanted = true
	var m: Node = load(Scenes.GAME).instantiate()
	root.add_child(m)
	for i in 3:
		await process_frame
	var dish: Dish = m.dish
	canned.serve_dish(dish.number, 3)
	for i in 3:
		await process_frame
	var hotkey: Node = root.get_node("DebugHotkey")
	current_scene = m
	TestUtil.check(str(ProjectSettings.get_setting("autoload/DebugHotkey")) == "*res://ui/debug_hotkey.tscn", "DebugHotkey is registered as an autoload")

	# What it holds.
	dish.selected.bup = dish.bup_ids()[0]
	for i in 3:
		await process_frame  # (the world answers about a picked bup a frame later)
	var data: Variant = JSON.parse_string(DebugLog.report(dish, m, m.debug_state()))
	TestUtil.check(data is Dictionary, "the report is readable text")
	if data is Dictionary:
		for key in ["written", "godot", "dish", "nutrient", "selected", "constants", "screen"]:
			TestUtil.check(data.has(key), "the report has %s" % key)
		TestUtil.check(data.has("backend") and data["backend"]["running"] == "gpu" and data["backend"]["gpu_available"] == GpuSimBackend.available(), "it says where the bups run: that the world simulates (the canned backend can)")
		TestUtil.check(data["backend"].get("gpu_device") == "test device" and data["backend"].get("main_device") is String, "...both devices' names: the simulation's from the backend, the main one's from the renderer")
		var be: Dictionary = data["backend"]
		TestUtil.check(data.get("display") is Dictionary and (data["display"] as Dictionary).has("assumed_frame_ms") and float(data["display"]["assumed_frame_ms"]) > 0.0 and data["display"].has("refresh_hz_now"), "the log says the display's frame the game assumed, and the refresh rate the screen reports now")
		for key in ["k", "step_s", "iteration_world_s", "duty", "T_ITER_ms", "step_ms_ema", "sync_ms", "publish_ms"]:
			TestUtil.check(be["governor"].has(key) and (be["governor"][key] is float or be["governor"][key] is int), "the governor has the number %s" % key)
		TestUtil.check(is_equal_approx(float(be["governor"]["iteration_world_s"]), float(be["governor"]["k"]) * float(be["governor"]["step_s"])), "...the world time of the last iteration is its steps times the step length")
		TestUtil.check(be["governor"]["T_ITER_ms"] == Governor.T_ITER_MS and be["pool"] is Dictionary and be["pool_in_use"] is Dictionary and be["pool_overflow"] is float and be["payload_behind_sim_s"] is float,"...T_ITER is the governor's, and the pool, what of it is in use, its overflow bits and the payload's age are there (the canned world serves none)")
		TestUtil.check(be.has("syncs_unfinished") and be["syncs_unfinished"] is float and float(be["syncs_unfinished"]) == 0.0, "...the syncs found unfinished are counted (none on the canned world)")
		TestUtil.check(be.has("time_process") and (be["time_process"] is float or be["time_process"] is int), "backend has the process time")
		TestUtil.check(be.has("draw_slots") and be["draw_slots"] is Dictionary and be["draw_slots"].has("drawn") and be["draw_slots"].has("capacity") and be["draw_slots"].has("live"), "...draw_slots has drawn, capacity and live")
		TestUtil.check(be.get("pictures_last_second") is Dictionary and (be["pictures_last_second"] as Dictionary).has("shown"), "...pictures_last_second says how often the picture changed")
		TestUtil.check(be.has("pick_latency_frames") and be["pick_latency_frames"] is Dictionary and be["pick_latency_frames"].has("last") and be["pick_latency_frames"].has("max") and be["pick_latency_frames"].has("last_ms"), "...pick_latency_frames has last, max and last_ms")
		TestUtil.check(data["dish"].has("births_refused") and data["dish"]["births_refused"] is float,"the dish has its births refused at the pool's edge")
		TestUtil.check(data["dish"].has("layers_hidden") and data["dish"]["layers_hidden"] is Array, "layers_hidden is an Array")
		TestUtil.check(data["nutrient"]["by_distance_from_centre"].size() == DebugLog.RIM_FRACTIONS.size(), "it has the nutrient by distance from the centre")
		var rf: Dictionary = data.get("recent_frames", {})
		TestUtil.check(int(rf.get("frames", 0)) > 3 and float(rf.get("late_limit_ms", 0.0)) > 0.0 and rf.has("late_share") and rf.has("late_with_long_process_share"), "the log has the recent frames: a count, the late limit and shares (%s)" % str(rf.get("frames")))
		for key in ["frame_ms", "process_ms", "poll_ms", "main_own_ms", "main_children_ms", "family_tree_lookup_ms"]:
			TestUtil.check((rf.get(key, {}) as Dictionary).has("p95") and (rf.get(key, {}) as Dictionary).has("p99"), "...%s has its spread" % key)
		TestUtil.check(float(rf["frame_ms"]["p50"]) > 0.0 and float(rf["process_ms"]["p95"]) > 0.0 and float(rf["main_own_ms"]["p95"]) > 0.0, "...frame, process and the game screen's own times are figures")
		TestUtil.check((rf.get("parts_p95_ms", {}) as Dictionary).size() == 4 and rf.get("longest") is Array and (rf["longest"] as Array).size() > 0 and (rf["longest"][0] as Dictionary).has("seconds_before_key") and (rf["longest"][0] as Dictionary).has("pointer_over_stage"), "...the parts' p95 and the longest frames with their flags")
		var ri: Dictionary = data.get("recent_iterations", {})
		TestUtil.check(ri.has("iterations") and (ri.get("iteration_ms", {}) as Dictionary).has("p50") and (ri.get("sync_ms", {}) as Dictionary).has("p95") and (ri.get("submit_ms_most", {}) as Dictionary).has("max") and (ri.get("step_cost_ms", {}) as Dictionary).has("p95"), "the log has the recent iterations' figures")
		# A record made by hand: one long frame with a long process step, a pointer over the dish and a new picture.
		FrameRecord.clear()
		for k in 6:
			FrameRecord.begin()
			if k == 3:
				OS.delay_msec(40)
				FrameRecord.note_flag(FrameRecord.NEW_PICTURE | FrameRecord.POINTER_DISH)
			FrameRecord.end()
		var fake := FrameRecord.recent_frames(16.0)
		var worst: Dictionary = (fake["longest"] as Array)[0]
		TestUtil.check(int(fake["frames"]) == 5 and int(fake["late"]) == 1 and float(worst["frame_ms"]) >= 39.0 and float(worst["process_ms"]) >= 39.0 and worst["new_picture"] and worst["pointer_over_dish"] and not worst["hover_card"], "a long frame is the longest, flagged, and counted late (%s)" % str(worst))
		TestUtil.check(is_equal_approx(float(fake["late_with_long_process_share"]), 1.0) and float(fake["late_share"]) == 0.2, "...its process step passed a display frame")
		TestUtil.check(FrameRecord.process_p95(10000.0) >= 39.0, "...and the overlay's figure takes it in")
		for k in FrameRecord.CAPACITY + 10:
			FrameRecord.begin()
			FrameRecord.end()
		TestUtil.check(int(FrameRecord.recent_frames(16.0, 0)["frames"]) <= FrameRecord.CAPACITY, "the ring holds no more than its capacity")
		TestUtil.check(data["selected"].has("bup") and data["selected"]["bup"].has("genome") == false and data["selected"]["bup"].has("sense"), "it has the selected bup")
		TestUtil.check(data["screen"]["tutorial_step"] == 0, "it says the tour is up, and where")
	# The memory warning: the fraction and the state are in the log, and the screen's banner says it while it holds.
	TestUtil.check(data["backend"]["memory"]["warning"] == "" and data["backend"]["memory"]["warn_fraction"] == PoolLimits.WARN_FRACTION, "the log has the memory share and no warning below the threshold")
	canned.memory_fraction = 0.99  # (what the pool holds does not warn; what the dishes need does)
	canned.need_fraction = PoolLimits.WARN_FRACTION + 0.02
	for i in 4:
		await process_frame
	var warned: Dictionary = JSON.parse_string(DebugLog.report(dish, m, m.debug_state()))["backend"]["memory"]
	TestUtil.check(warned["warning"] == PoolLimits.WARN_NEAR and absf(float(warned["need_fraction"]) - 0.92) < 0.001 and absf(float(warned["fraction"]) - 0.99) < 0.001 and int(warned["next_growth_bytes"]) == 123, "at the need's threshold the log says near, with the need, the held share and the next growth")
	TestUtil.check(m.banner.text == Strings.t("banner.memory_near"), "...and the banner says graphics memory is nearly full")
	canned.refusing_iteration = "no room"
	for i in 4:
		await process_frame
	var stalled: Dictionary = JSON.parse_string(DebugLog.report(dish, m, m.debug_state()))["backend"]["memory"]
	TestUtil.check(stalled["warning"] == PoolLimits.WARN_STALLED and m.banner.text == Strings.t("banner.memory_stalled") and Strings.t("banner.memory_stalled") != Strings.t("banner.memory_budget"), "refused iterations: the log says stalled and the banner has its own words, not the action's")
	canned.refusing_iteration = ""
	canned.need_fraction = PoolLimits.WARN_FRACTION - 0.01  # (the pool still holds 0.99: no warning)
	TestUtil.check(PoolLimits.warning_state({"memory_need_fraction": PoolLimits.WARN_FRACTION}) == PoolLimits.WARN_NEAR and PoolLimits.warning_state({"memory_need_fraction": PoolLimits.WARN_FRACTION - 0.001}) == "", "the threshold is at 0.90 exactly")
	m.call("_show_banner", "", 0.0)
	for i in 4:
		await process_frame
	TestUtil.check(m.banner.text == "", "below the threshold the warning goes")
	var as_text := DebugLog.report(dish, m, {})
	TestUtil.check(not as_text.contains(OS.get_environment("USER")) or OS.get_environment("USER").length() < 3, "it does not hold the user name")

	# F12 reaches the screen through the tour and writes a log and says so afterwards.
	TestUtil.check(m.tutorial.active, "the tour is up")
	m.tutorial._input(TestUtil.key_event(KEY_F12))
	TestUtil.check(m.tutorial.active, "the tour does not take F12 as a key of its own")
	# F3 shows and hides the timing overlay (also through the tour), its rows fill with numbers, and it ignores the mouse.
	var overlay: TimingOverlay = m.timing_overlay
	TestUtil.check(not overlay.visible and KeyBindings.set_key("pause", KEY_F3) == "!", "the overlay is off at start and F3 is not a key to rebind")
	m.tutorial._input(TestUtil.key_event(KEY_F3))
	TestUtil.check(m.tutorial.active, "the tour does not take F3 as a key of its own")
	hotkey._input(TestUtil.key_event(KEY_F3))
	await process_frame
	TestUtil.check(overlay.visible, "F3 shows the overlay")
	for i in 3:
		await process_frame
	overlay.refresh()
	for row: String in TimingOverlay.ROWS:
		if row in TimingOverlay.MEMORY_ROWS:
			continue
		var shown: String = overlay._values[row].text
		TestUtil.check(shown.length() > 0 and shown.find("%") < 0 or row == "late", "the overlay's %s row has a figure (%s)" % [row, shown])
		TestUtil.check(shown.strip_edges() != "" and (shown[0].is_valid_int() or shown[0] == "x"), "...which starts with a number (%s)" % shown)
	# The memory rows: a discrete card gives the pool, need and card rows; a shared-memory machine the pool, need and system rows; an unknown figure hides its row.
	var gib := int(TimingOverlay.GIB)
	var base := {"memory_budget_bytes": 12 * gib, "memory_fraction": 0.5, "memory_need_fraction": 0.25}
	var card_timing := base.duplicate()
	card_timing["machine"] = {"machine": {"shared": 0, "card_budget": 8 * gib, "card_usage": 2 * gib, "physical": 32 * gib, "available": 16 * gib}}
	var f := TimingOverlay.memory_figures(card_timing)
	TestUtil.check(f.has("pool") and f.has("need") and f.has("card") and not f.has("system"), "a card with usage and budget shows its row, not the system's")
	overlay.show_memory(f)
	TestUtil.check(overlay._values["pool"].text == "6.00 of 12.00 GB (50%)" and overlay._values["need"].text == "3.00 of 12.00 GB (25%)" and overlay._values["card"].text == "2.00 of 8.00 GB (25%)", "the memory rows read in gigabytes (%s | %s | %s)" % [overlay._values["pool"].text, overlay._values["need"].text, overlay._values["card"].text])
	TestUtil.check(overlay._values["pool"].visible and overlay._captions["card"].visible and not overlay._values["system"].visible and not overlay._captions["system"].visible, "the known rows show, the system row is hidden")
	var shared_timing := base.duplicate()
	shared_timing["machine"] = {"machine": {"shared": 1, "card_budget": -1, "card_usage": -1, "physical": 16 * gib, "available": 4 * gib}}
	f = TimingOverlay.memory_figures(shared_timing)
	overlay.show_memory(f)
	TestUtil.check(f.has("system") and not f.has("card") and overlay._values["system"].text == "12.00 of 16.00 GB (75%)" and not overlay._values["card"].visible, "shared graphics memory shows the system's memory in use")
	var unknown_timing := base.duplicate()
	unknown_timing["machine"] = {"machine": {"shared": 0, "card_budget": 8 * gib, "card_usage": -1, "physical": -1, "available": -1}}
	f = TimingOverlay.memory_figures(unknown_timing)
	overlay.show_memory(f)
	TestUtil.check(not f.has("card") and not f.has("system") and not overlay._values["card"].visible and not overlay._values["system"].visible, "a device row whose figure is unknown is hidden")
	overlay.show_memory(TimingOverlay.memory_figures({}))
	TestUtil.check(not overlay._values["pool"].visible and not overlay._values["need"].visible, "with no budget known the pool rows are hidden")
	TestUtil.check(overlay.late_share(16.7) >= 0.0 and overlay.late_share(16.7) <= 1.0, "the late share is a share")
	overlay._frames = [[0, 10], [0, 40], [0, 20], [0, 25]]
	TestUtil.check(is_equal_approx(overlay.late_share(16.0), 0.5), "a frame is late past 1.5 display frames (two of four are)")
	var all_ignore := true
	var pending: Array = [overlay]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		pending.append_array(node.get_children())
		if node is Control and (node as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
			all_ignore = false
	TestUtil.check(all_ignore, "nothing in the overlay takes the mouse")
	hotkey._input(TestUtil.key_event(KEY_F3))
	await process_frame
	TestUtil.check(not overlay.visible, "F3 hides it again")
	hotkey._input(TestUtil.key_event(KEY_F12))
	TestUtil.check(not hotkey.notice.visible, "nothing is said before the log is written")
	for i in hotkey.FREEZE_FRAMES + 3:
		await process_frame
	TestUtil.check(_logs().size() == 1, "F12 writes one log (%d)" % _logs().size())
	TestUtil.check(hotkey.notice.visible and hotkey.notice.text == "Debug info logged", "and then says so")
	TestUtil.check(not hotkey._logging, "and is ready for the next press")
	hotkey._process(hotkey.NOTICE_SECONDS + 5.0)
	TestUtil.check(hotkey.notice.visible, "a long frame does not use the notice up (the log of a big dish takes seconds to write)")
	hotkey._notice_until = Time.get_ticks_msec() - 1  # (the few seconds are up)
	hotkey._process(0.0)
	TestUtil.check(not hotkey.notice.visible, "the notice goes after a few seconds")
	var first: String = _logs()[0]
	var kept: Variant = JSON.parse_string(FileAccess.get_file_as_string(DebugLog.directory.path_join(first)))
	TestUtil.check(kept is Dictionary and kept["scene"] == Scenes.GAME and kept.has("dish"), "the log names the screen and has its dish")

	# On a screen without a dish (the intro): the screen and the session, and no dish.
	m.queue_free()
	var menu: Node = load(Scenes.INTRO).instantiate()
	root.add_child(menu)
	current_scene = menu
	await process_frame
	hotkey.write()
	for i in hotkey.FREEZE_FRAMES + 2:
		await process_frame
	var newest := _logs()
	newest.sort()
	var on_menu: Variant = JSON.parse_string(FileAccess.get_file_as_string(DebugLog.directory.path_join(newest[-1])))
	TestUtil.check(newest.size() == 2 and on_menu is Dictionary and on_menu["scene"] == Scenes.INTRO and not on_menu.has("dish") and on_menu.has("session"), "on a screen with no dish it logs the screen and the session only")
	menu.queue_free()

	# A dialog that is up has the keyboard to itself (a window of its own): F12 reaches the log from there too.
	var before := _logs().size()
	var ask := ConfirmationDialog.new()
	root.add_child(ask)
	ask.window_input.emit(TestUtil.key_event(KEY_F12))
	for i in hotkey.FREEZE_FRAMES + 2:
		await process_frame
	TestUtil.check(_logs().size() == before + 1, "F12 writes a log while a dialog is up")
	ask.queue_free()

	# Free setup has a preview dish, which is the one logged.
	var setup: Node = load(Scenes.FREE_SETUP).instantiate()
	root.add_child(setup)
	current_scene = setup
	await process_frame
	hotkey.write()
	for i in hotkey.FREEZE_FRAMES + 2:
		await process_frame
	newest = _logs()
	newest.sort()
	var on_setup: Variant = JSON.parse_string(FileAccess.get_file_as_string(DebugLog.directory.path_join(newest[-1])))
	TestUtil.check(on_setup is Dictionary and on_setup.has("dish") and on_setup.has("nutrient"), "in free setup it logs the preview dish")

	# Writing and pruning.
	for i in DebugLog.MAX_KEPT + 5:
		DebugLog.write("{}")
		OS.delay_msec(2)  # (a press is never two in a millisecond)
	TestUtil.check(_logs().size() <= DebugLog.MAX_KEPT and _logs().size() > DebugLog.MAX_KEPT - 5, "no more than %d logs are kept (%d)" % [DebugLog.MAX_KEPT, _logs().size()])
	var names := _logs()
	names.sort()
	TestUtil.check(names[0].begins_with("bups-") and names[0].ends_with(".log"), "logs are stamped")
	var image := Image.create(4, 4, false, Image.FORMAT_RGB8)
	DebugLog.write("{}", image)
	var pngs := Array(DirAccess.get_files_at(DebugLog.directory)).filter(func(f: String) -> bool: return f.ends_with(".png"))
	TestUtil.check(pngs.size() == 1, "a screenshot is saved beside its log (%s)" % [DirAccess.get_files_at(DebugLog.directory)])
	DebugLog.prune(Time.get_unix_time_from_system() + (DebugLog.MAX_AGE_DAYS + 1) * 86400.0)
	TestUtil.check(_logs().is_empty() and DirAccess.get_files_at(DebugLog.directory).is_empty(), "logs older than %d days go, with their screenshots" % DebugLog.MAX_AGE_DAYS)
	DirAccess.remove_absolute(DebugLog.directory)

	# The pick latency: polls from a bup's first question to the first answer about it, from a snapshot taken after the question.
	var fake := FakeSimBackend.new()
	var wc := WorldClient.new(fake)
	wc.ask(0, {"tracked": [7]})  # (asked at poll 0, before any snapshot)
	var one := Snapshot.new()
	one.seq = 1
	fake.serve(one)
	wc.poll()  # (poll 1: no answer yet)
	TestUtil.check(wc.pick_latency()["max"] == 0, "no answer, no latency yet")
	var two := Snapshot.new()
	two.seq = 2
	two.answers[0] = {"tracked": {7: PackedByteArray([0])}}
	fake.serve(two)
	wc.poll()  # (poll 2: the answer arrives)
	TestUtil.check(wc.pick_latency()["last"] == 2 and wc.pick_latency()["max"] == 2, "the answer came two polls after the question (%s)" % wc.pick_latency())
	TestUtil.finish(self, "DEBUG LOG TESTS OK")
