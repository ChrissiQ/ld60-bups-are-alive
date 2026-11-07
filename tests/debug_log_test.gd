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
		for key in ["k", "duty", "T_ITER_ms", "step_ms_ema", "sync_ms", "publish_ms"]:
			TestUtil.check(be["governor"].has(key) and (be["governor"][key] is float or be["governor"][key] is int), "the governor has the number %s" % key)
		TestUtil.check(be["governor"]["T_ITER_ms"] == Governor.T_ITER_MS and be["pool"] is Dictionary and be["pool_overflow"] is float and be["payload_behind_sim_s"] is float,"...T_ITER is the governor's, and the pool, its overflow bits and the payload's age are there (the canned world serves none)")
		TestUtil.check(be.has("time_process") and (be["time_process"] is float or be["time_process"] is int), "backend has the process time")
		TestUtil.check(be.has("draw_slots") and be["draw_slots"] is Dictionary and be["draw_slots"].has("drawn") and be["draw_slots"].has("capacity") and be["draw_slots"].has("live"), "...draw_slots has drawn, capacity and live")
		TestUtil.check(be.has("pick_latency_frames") and be["pick_latency_frames"] is Dictionary and be["pick_latency_frames"].has("last") and be["pick_latency_frames"].has("max") and be["pick_latency_frames"].has("last_ms"), "...pick_latency_frames has last, max and last_ms")
		TestUtil.check(data["dish"].has("births_refused") and data["dish"]["births_refused"] is float,"the dish has its births refused at the pool's edge")
		TestUtil.check(data["dish"].has("layers_hidden") and data["dish"]["layers_hidden"] is Array, "layers_hidden is an Array")
		TestUtil.check(data["nutrient"]["by_distance_from_centre"].size() == DebugLog.RIM_FRACTIONS.size(), "it has the nutrient by distance from the centre")
		TestUtil.check(data["selected"].has("bup") and data["selected"]["bup"].has("genome") == false and data["selected"]["bup"].has("sense"), "it has the selected bup")
		TestUtil.check(data["screen"]["tutorial_step"] == 0, "it says the tour is up, and where")
	# The memory warning: the fraction and the state are in the log, and the screen's banner says it while it holds.
	TestUtil.check(data["backend"]["memory"]["warning"] == "" and data["backend"]["memory"]["warn_fraction"] == PoolLimits.WARN_FRACTION, "the log has the memory share and no warning below the threshold")
	canned.memory_fraction = PoolLimits.WARN_FRACTION + 0.02
	for i in 4:
		await process_frame
	var warned: Dictionary = JSON.parse_string(DebugLog.report(dish, m, m.debug_state()))["backend"]["memory"]
	TestUtil.check(warned["warning"] == PoolLimits.WARN_NEAR and absf(float(warned["fraction"]) - 0.92) < 0.001 and int(warned["next_growth_bytes"]) == 123, "at the threshold the log says near, with the fraction and the next growth")
	TestUtil.check(m.banner.text == Strings.t("banner.memory_near"), "...and the banner says graphics memory is nearly full")
	canned.refusing_iteration = "no room"
	for i in 4:
		await process_frame
	var stalled: Dictionary = JSON.parse_string(DebugLog.report(dish, m, m.debug_state()))["backend"]["memory"]
	TestUtil.check(stalled["warning"] == PoolLimits.WARN_STALLED and m.banner.text == Strings.t("banner.memory_stalled") and Strings.t("banner.memory_stalled") != Strings.t("banner.memory_budget"), "refused iterations: the log says stalled and the banner has its own words, not the action's")
	canned.refusing_iteration = ""
	canned.memory_fraction = PoolLimits.WARN_FRACTION - 0.01
	TestUtil.check(PoolLimits.warning_state({"memory_fraction": PoolLimits.WARN_FRACTION}) == PoolLimits.WARN_NEAR and PoolLimits.warning_state({"memory_fraction": PoolLimits.WARN_FRACTION - 0.001}) == "", "the threshold is at 0.90 exactly")
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
