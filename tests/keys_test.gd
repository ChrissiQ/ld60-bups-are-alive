extends SceneTree
## Run: godot --headless --path . -s tests/keys_test.gd
## The keys can be changed and kept: swaps, reserved keys, {action} marks in texts, and the toolbar, layers and controls list following.


func _init() -> void:
	KeyBindings.path = "user://keys_test.cfg"
	KeyBindings.reset()
	TestUtil.check(KeyBindings.key("pause") == KEY_SPACE and KeyBindings.label("pause") == "Space", "the defaults are in place")
	TestUtil.check(KeyBindings.matches("tool_select", TestUtil.key_event(KEY_I)) and not KeyBindings.matches("tool_select", TestUtil.key_event(KEY_H)), "an action matches its key only")
	TestUtil.check(Strings.t("tutorial.watch").contains("(or O)"), "a {watch} mark in a text becomes the key")

	var seen := [0]
	var listener := func() -> void: seen[0] += 1
	KeyBindings.listen(listener)
	TestUtil.check(KeyBindings.set_key("tool_select", KEY_K) == "" and KeyBindings.key("tool_select") == KEY_K and seen[0] == 1, "a free key is simply taken, and listeners hear of it")
	TestUtil.check(KeyBindings.set_key("tool_pan", KEY_K) == "tool_select" and KeyBindings.key("tool_select") == KEY_H and KeyBindings.key("tool_pan") == KEY_K, "a key another action had swaps with it, so no key does two things")
	TestUtil.check(KeyBindings.set_key("pause", KEY_ESCAPE) == "!" and KeyBindings.key("pause") == KEY_SPACE, "a reserved key is refused")
	TestUtil.check(not KeyBindings.is_default(), "changes are noticed")
	TestUtil.check(FileAccess.file_exists(KeyBindings.path), "changes are kept in a file")

	var main: Node = load(Scenes.GAME).instantiate()
	root.add_child(main)
	await process_frame
	var toolbar: Toolbar = main.toolbar
	TestUtil.check(toolbar.select_button.tooltip_text.ends_with("(H)") and toolbar.pan_button.tooltip_text.ends_with("(K)"), "the toolbar's tooltips follow the keys (%s, %s)" % [toolbar.select_button.tooltip_text, toolbar.pan_button.tooltip_text])
	TestUtil.check(toolbar.pan_button.shortcut.events[0].keycode == KEY_K, "...and so do its shortcuts")
	KeyBindings.set_key("layer_bups", KEY_J)
	TestUtil.check(main.layers_panel.bups_button.tooltip_text.ends_with("(J)"), "the layers follow too")

	var panel: ControlsPanel = load("res://ui/controls_panel.tscn").instantiate()
	root.add_child(panel)
	panel.visible = true
	await process_frame
	panel._wait_for_key("frame")
	TestUtil.check(panel.is_waiting(), "clicking a key button waits for the new key")
	panel._input(TestUtil.key_event(KEY_F2))
	TestUtil.check(KeyBindings.key("frame") == KEY_F2 and not panel.is_waiting(), "the next key is taken")
	panel._wait_for_key("frame")
	panel._input(TestUtil.key_event(KEY_ESCAPE))
	TestUtil.check(KeyBindings.key("frame") == KEY_F2 and not panel.is_waiting(), "Escape cancels and keeps the old key")
	panel.reset_button.pressed.emit()
	TestUtil.check(KeyBindings.is_default() and not FileAccess.file_exists(KeyBindings.path), "reset puts every key back and removes the file")
	KeyBindings.set_key("pause", KEY_SPACE)
	TestUtil.check(KeyBindings.is_default(), "setting a key to the one it already was is no change: Reset keys stays off")
	KeyBindings.set_key("pause", KEY_P)
	KeyBindings.set_key("pause", KEY_SPACE)
	TestUtil.check(KeyBindings.is_default() and not FileAccess.file_exists(KeyBindings.path), "changing a key and changing it back leaves no change")

	# The reduce-motion preference follows the operating system until the player chooses.
	TestUtil.check(UserSettings.reduce_motion_choice == "system" and UserSettings.reduce_motion == false, "reduce motion follows the system by default (a headless run has none to follow)")
	UserSettings.reduce_motion_choice = "on"
	TestUtil.check(UserSettings.reduce_motion, "On overrides the system")
	UserSettings.reduce_motion_choice = "off"
	TestUtil.check(not UserSettings.reduce_motion, "Off overrides it too")
	UserSettings.reduce_motion_choice = "system"

	var row: SettingRow = load("res://ui/setting_row.tscn").instantiate()
	root.add_child(row)
	await process_frame
	row.configure(0, 100, 1, 50)
	var reports := [0]
	row.value_changed.connect(func(_v: float) -> void: reports[0] += 1)
	row.slider.drag_started.emit()
	row.slider.value = 30
	row.slider.value = 60
	TestUtil.check(reports[0] == 0 and row.value_field.text == "60", "while the handle is held the number follows it but nothing is reported")
	row.slider.drag_ended.emit(true)
	TestUtil.check(reports[0] == 1, "the release reports once")
	row.slider.value = 70
	TestUtil.check(reports[0] == 2, "a change with no drag (a click on the track, the keys, the number box) is reported at once")
	row.queue_free()

	UserSettings.ui_scale = 2.0
	UserSettings.fullscreen = false
	UserSettings.reduce_motion_choice = "on"
	UserSettings.path = "user://prefs_test.cfg"
	UserSettings.reset()
	TestUtil.check(UserSettings.ui_scale == 1.0 and UserSettings.fullscreen and UserSettings.reduce_motion_choice == "system", "resetting the options puts every one back to its default")
	DirAccess.remove_absolute("user://prefs_test.cfg")

	KeyBindings.unlisten(listener)
	TestUtil.finish(self, "KEYS TESTS OK")
