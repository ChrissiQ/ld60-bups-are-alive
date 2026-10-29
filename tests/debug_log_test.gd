extends SceneTree
## Run: godot --headless --path . -s tests/debug_log_test.gd
## The F12 debug log: what it holds, that it writes a stamped file, that every write prunes, and that F12 works in the tour.


func _logs() -> Array:
	return Array(DirAccess.get_files_at(DebugLog.directory)).filter(func(f: String) -> bool: return f.ends_with(".log"))


func _init() -> void:
	DebugLog.directory = "user://test_logs"
	DirAccess.make_dir_recursive_absolute(DebugLog.directory)
	for f in DirAccess.get_files_at(DebugLog.directory):
		DirAccess.remove_absolute(DebugLog.directory.path_join(f))

	Session.mode = Session.Mode.FREE
	Session.free_start = TestUtil.small_start()
	Session.tutorial_wanted = true
	var m: Node = load(Scenes.GAME).instantiate()
	root.add_child(m)
	for i in 3:
		await process_frame
	var dish: Dish = m.dish
	var hotkey: Node = root.get_node("DebugHotkey")
	current_scene = m
	TestUtil.check(str(ProjectSettings.get_setting("autoload/DebugHotkey")) == "*res://ui/debug_hotkey.tscn", "DebugHotkey is registered as an autoload")

	# What it holds.
	dish.selected_id = dish.bup_ids()[0]
	var data: Variant = JSON.parse_string(DebugLog.report(dish, m, m.debug_state()))
	TestUtil.check(data is Dictionary, "the report is readable text")
	if data is Dictionary:
		for key in ["written", "godot", "dish", "nutrient", "selected", "constants", "screen"]:
			TestUtil.check(data.has(key), "the report has %s" % key)
		TestUtil.check(data.has("backend") and data["backend"]["setting"] == "auto" and data["backend"]["running"] == "cpu" and data["backend"]["gpu_available"] == GpuWorld.available(), "it says where the bups run: the setting, and that they run on the processor (headless has no GPU path)")
		TestUtil.check(data["backend"].has("gpu_device") and data["backend"].has("gpu_overflows") and data["backend"]["gpu_overflows"] is Dictionary, "...the GPU's name and its overflow counters (none here)")
		TestUtil.check(data["nutrient"]["by_distance_from_centre"].size() == DebugLog.RIM_FRACTIONS.size(), "it has the nutrient by distance from the centre")
		TestUtil.check(data["selected"].has("bup") and data["selected"]["bup"].has("genome") == false and data["selected"]["bup"].has("sense"), "it has the selected bup")
		TestUtil.check(data["screen"]["tutorial_step"] == 0, "it says the tour is up, and where")
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
	TestUtil.finish(self, "DEBUG LOG TESTS OK")
