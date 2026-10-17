extends SceneTree
## Run: godot --headless --path . -s tests/settings_test.gd
## Free-mode settings persistence. Redirects to a scratch file so the player's real
## settings and experiment save are never touched.

const TEMP := "user://test_free_settings.json"
var failures: Array = []


func check(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)


func _same(a: StartConditions, b: StartConditions) -> bool:
	return a.bups == b.bups and a.nutrients == b.nutrients and is_equal_approx(a.nutrient_rate, b.nutrient_rate) and is_equal_approx(a.dish_radius, b.dish_radius)


func _write_raw(text: String) -> void:
	var f := FileAccess.open(TEMP, FileAccess.WRITE)
	f.store_string(text)


func _init() -> void:
	var real_path := StartConditions.settings_path
	check(real_path != TEMP, "default settings path is not the test path")
	StartConditions.settings_path = TEMP
	if FileAccess.file_exists(TEMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP))

	# Never started free mode: defaults.
	check(_same(StartConditions.load_saved(), StartConditions.new()), "no file: defaults")

	# Round trip.
	var c := StartConditions.new()
	c.bups = 77
	c.nutrients = 33
	c.nutrient_rate = 14.0
	c.dish_radius = 420.0
	check(c.save(), "save succeeds")
	check(_same(StartConditions.load_saved(), c), "saved settings load back unchanged")

	# Bad data never crashes and never leaves the valid range.
	_write_raw("this is not json")
	check(_same(StartConditions.load_saved(), StartConditions.new()), "garbage file: defaults")
	_write_raw("[1, 2, 3]")
	check(_same(StartConditions.load_saved(), StartConditions.new()), "wrong JSON shape: defaults")
	_write_raw('{"bups": "lots", "nutrients": [1], "nutrient_rate": null, "dish_radius": {"x": 1}}')
	check(_same(StartConditions.load_saved(), StartConditions.new()), "wrong value types: defaults")
	_write_raw('{"bups": 99999, "nutrients": -5, "nutrient_rate": 500, "dish_radius": 1}')
	var clamped := StartConditions.load_saved()
	check(clamped.bups == StartConditions.MAX_BUPS and clamped.nutrients == 0 and clamped.nutrient_rate == StartConditions.MAX_NUTRIENT_RATE and clamped.dish_radius == StartConditions.MIN_DISH_RADIUS, "out-of-range values clamp")
	_write_raw('{"bups": 12}')
	var partial := StartConditions.load_saved()
	check(partial.bups == 12 and partial.nutrients == StartConditions.new().nutrients, "missing keys fall back individually")

	# End to end through the real setup screen: choose, GO, "relaunch", reopen.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP))
	Session.free_start = StartConditions.load_saved()
	var setup: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(setup)
	await process_frame
	check(setup.bups_row.slider.value == 4 and setup.nutrients_row.slider.value == 60, "first ever visit shows the defaults")
	setup.bups_row.slider.value = 55
	setup.nutrients_row.slider.value = 90
	setup.rate_row.slider.value = 3
	setup.dish_row.slider.value = 250
	check(not FileAccess.file_exists(TEMP), "tweaking sliders alone saves nothing")
	setup._go()
	check(FileAccess.file_exists(TEMP), "GO saves the settings")
	setup.queue_free()
	await process_frame
	# Simulate a fresh launch: reload from disk the way Session does at startup.
	Session.free_start = StartConditions.load_saved()
	var again: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(again)
	await process_frame
	check(again.bups_row.slider.value == 55 and again.nutrients_row.slider.value == 90 and again.rate_row.slider.value == 3 and again.dish_row.slider.value == 250,
		"next launch shows the previous choices (%d, %d, %d, %d)" % [again.bups_row.slider.value, again.nutrients_row.slider.value, again.rate_row.slider.value, again.dish_row.slider.value])
	again.queue_free()

	# Reset to default: loads defaults into the sliders only; nothing is saved or forgotten.
	var prev := StartConditions.new()
	prev.bups = 31
	prev.nutrients = 77
	prev.nutrient_rate = 12.0
	prev.dish_radius = 380.0
	prev.save()
	Session.free_start = StartConditions.load_saved()
	var file_before := FileAccess.get_file_as_string(TEMP)
	var reset_screen: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(reset_screen)
	current_scene = reset_screen
	await process_frame
	check(reset_screen.bups_row.slider.value == 31 and reset_screen.dish_row.slider.value == 380, "setup opens on the saved preference")
	reset_screen.reset_button.pressed.emit()
	var d := StartConditions.new()
	check(reset_screen.bups_row.slider.value == d.bups and reset_screen.nutrients_row.slider.value == d.nutrients and reset_screen.rate_row.slider.value == d.nutrient_rate and reset_screen.dish_row.slider.value == d.dish_radius, "Reset to default puts the defaults in the sliders")
	check(FileAccess.get_file_as_string(TEMP) == file_before, "Reset doesn't touch the saved file")
	check(_same(Session.free_start, prev), "Reset doesn't change the remembered preference")
	reset_screen._back()  # backing out after a reset
	await process_frame
	check(FileAccess.get_file_as_string(TEMP) == file_before, "backing out after a reset saves nothing")
	check(_same(StartConditions.load_saved(), prev), "the previous preference is still what loads next time")
	# Reopen: still shows the previous preference, not the defaults.
	current_scene = null
	var reopened: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(reopened)
	await process_frame
	check(reopened.bups_row.slider.value == 31 and reopened.nutrients_row.slider.value == 77, "reopening shows the previous preference")
	# Per-row reset icons reset one setting only, and save nothing.
	var file_now := FileAccess.get_file_as_string(TEMP)
	reopened.bups_row.slider.value = 90
	reopened.nutrients_row.slider.value = 120
	reopened.rate_row.slider.value = 20
	reopened.dish_row.slider.value = 500
	reopened.nutrients_row.reset_button.pressed.emit()
	check(reopened.nutrients_row.slider.value == d.nutrients, "row reset puts that slider at its default")
	check(reopened.bups_row.slider.value == 90 and reopened.rate_row.slider.value == 20 and reopened.dish_row.slider.value == 500, "...and leaves the other sliders alone")
	reopened.rate_row.reset_button.pressed.emit()
	reopened.dish_row.reset_button.pressed.emit()
	reopened.bups_row.reset_button.pressed.emit()
	check(reopened.bups_row.slider.value == d.bups and reopened.rate_row.slider.value == d.nutrient_rate and reopened.dish_row.slider.value == d.dish_radius, "every row has a working reset")
	check(FileAccess.get_file_as_string(TEMP) == file_now, "row resets save nothing")
	check(reopened.reset_button.text == "" and reopened.reset_button.icon != null and reopened.reset_button.tooltip_text == "Use defaults", "top-right reset is icon-only with a 'Use defaults' tooltip")
	check(reopened.bups_row.reset_button.tooltip_text == "Use default (4)", "row tooltip names the default: '%s'" % reopened.bups_row.reset_button.tooltip_text)
	check(reopened.reset_button.focus_mode == Control.FOCUS_ALL and reopened.bups_row.reset_button.focus_mode == Control.FOCUS_ALL, "reset icons can be reached with Tab")
	reopened.bups_row.slider.value = 12
	# Console-font white values; row resets sit left of their labels, away from the numbers.
	for v in [reopened.bups_row.value_label, reopened.nutrients_row.value_label, reopened.rate_row.value_label, reopened.dish_row.value_label]:
		check(v.get_theme_font("font") is FontFile and v.get_theme_color("font_color") == Color.WHITE, "%s is white bundled-font text" % v.name)
	await process_frame
	var pairs := [[reopened.bups_row.reset_button, reopened.bups_row.value_label, "BupsRow/Label"], [reopened.nutrients_row.reset_button, reopened.nutrients_row.value_label, "NutrientsRow/Label"],
		[reopened.rate_row.reset_button, reopened.rate_row.value_label, "RateRow/Label"], [reopened.dish_row.reset_button, reopened.dish_row.value_label, "DishRow/Label"]]
	for pair in pairs:
		var label: Control = reopened.get_node("Panel/Box/" + pair[2])
		check(pair[0].global_position.x < label.global_position.x, "%s is left of its label" % pair[0].name)
		check(pair[0].global_position.x + pair[0].size.x < pair[1].global_position.x - 100.0, "%s is well away from the number" % pair[0].name)
	check(reopened.get_node("SectionLabel").global_position.x <= reopened.bups_row.reset_button.global_position.x + 8.0, "caption lines up with the left column")
	var global_right: float = reopened.reset_button.global_position.x + reopened.reset_button.size.x
	for v in [reopened.bups_row.value_label, reopened.dish_row.value_label]:
		check(v.global_position.x + v.size.x <= global_right + 1.0, "%s keeps to the right edge the global reset aligns to" % v.name)
	# A saved value off the slider's step grid: what is shown, previewed and played must agree.
	_write_raw('{"bups": 7, "nutrients": 33, "nutrient_rate": 6.5, "dish_radius": 305}')
	Session.free_start = StartConditions.load_saved()
	var off_grid: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(off_grid)
	await process_frame
	check(off_grid._start.nutrient_rate == off_grid.rate_row.value, "working copy takes the slider's rate (%s vs shown %s)" % [off_grid._start.nutrient_rate, off_grid.rate_row.value])
	check(off_grid._start.dish_radius == off_grid.dish_row.value, "working copy takes the slider's radius (%s vs shown %s)" % [off_grid._start.dish_radius, off_grid.dish_row.value])
	check(off_grid._start.bups == int(off_grid.bups_row.value) and off_grid._start.nutrients == int(off_grid.nutrients_row.value), "bups and nutrients agree too")
	off_grid.queue_free()
	Session.free_start = StartConditions.load_saved()

	# Reset then GO saves the defaults.
	reopened.reset_button.pressed.emit()
	reopened._go()
	check(_same(StartConditions.load_saved(), StartConditions.new()), "Reset then GO saves the defaults")
	reopened.queue_free()
	if is_instance_valid(reset_screen):
		reset_screen.queue_free()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP))
	StartConditions.settings_path = real_path
	if failures.is_empty():
		print("SETTINGS TESTS OK")
	else:
		print("FAILED:")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)
