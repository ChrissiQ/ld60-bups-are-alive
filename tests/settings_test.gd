extends SceneTree
## Run: godot --headless --path . -s tests/settings_test.gd
## Free-mode settings persistence. Redirects to a scratch file so the player's real
## settings and experiment save are never touched.

const TEMP := "user://test_free_settings.json"


func check(ok: bool, what: String) -> void:
	TestUtil.check(ok, what)


func _same(a: StartConditions, b: StartConditions) -> bool:
	return a.bups == b.bups and a.nutrient_density == b.nutrient_density and is_equal_approx(a.feed_density, b.feed_density) and is_equal_approx(a.dish_radius, b.dish_radius)


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
	c.nutrient_density = 33
	c.feed_density = 14.0
	c.dish_radius = 4200.0
	check(c.save(), "save succeeds")
	check(_same(StartConditions.load_saved(), c), "saved settings load back unchanged")

	# Bad data never crashes and never leaves the valid range.
	_write_raw("this is not json")
	check(_same(StartConditions.load_saved(), StartConditions.new()), "garbage file: defaults")
	_write_raw("[1, 2, 3]")
	check(_same(StartConditions.load_saved(), StartConditions.new()), "wrong JSON shape: defaults")
	_write_raw('{"bups": "lots", "nutrient_density": [1], "feed_density": null, "dish_radius": {"x": 1}}')
	check(_same(StartConditions.load_saved(), StartConditions.new()), "wrong value types: defaults")
	_write_raw('{"bups": 99999, "nutrient_density": -5, "feed_density": 500, "dish_radius": 1}')
	var clamped := StartConditions.load_saved()
	check(clamped.bups == StartConditions.MAX_BUPS and clamped.nutrient_density == 0 and clamped.feed_density == StartConditions.MAX_FEED_DENSITY and clamped.dish_radius == StartConditions.MIN_DISH_RADIUS, "out-of-range values clamp")
	# The founders the player named and coloured are kept with the starting conditions, and cleaned up when read back.
	var named := StartConditions.new()
	named.bups = 3
	named.founders = [{"name": "Finnigan", "color": "#ff0000"}, {"name": "", "color": "#00ff80"}]
	var named_copy := named.copy()
	named_copy.founders[0]["name"] = "Changed"
	check(named.founders[0]["name"] == "Finnigan", "a copy's founders are its own")
	var round_trip := StartConditions.from_dict(JSON.parse_string(JSON.stringify(named.to_dict())))
	check(round_trip.founders == named.founders, "founders' names and colours survive being saved and loaded")
	var messy := StartConditions.from_dict({"founders": [{"name": 12, "color": "red"}, "nonsense", {"name": "  Tidy\n", "color": "#ABCDEF"}, {"color": "#12345"}]})
	check(messy.founders.size() == 4 and messy.founders[0] == {} and messy.founders[1] == {} and messy.founders[2] == {"name": "Tidy", "color": "#abcdef"} and messy.founders[3] == {}, "odd founders are made safe: only a real name and a real #rrggbb are kept (%s)" % [messy.founders])
	# A longer saved list than there are founders is cut to the founders there are when saved; a shorter one leaves the rest at the defaults.
	var longer := StartConditions.new()
	longer.bups = 2
	longer.founders = [{"name": "A"}, {"name": "B"}, {"name": "C"}, {"name": "D"}]
	check(longer.to_dict()["founders"] == [{"name": "A"}, {"name": "B"}] and longer.copy().founders.size() == 2, "saving keeps only the first n founders' names and colours, nothing hidden")
	var shorter := StartConditions.new()
	shorter.bups = 5
	shorter.founders = [{"name": "A"}, {"color": "#00ff00"}]
	var shorter_dish := Dish.new()
	root.add_child(shorter_dish)
	shorter_dish.strike(shorter)
	check(shorter_dish.bup_name(1) == "A" and shorter_dish.bup_name(2).ends_with("#2") and shorter_dish.bup_name(5).ends_with("#5") and absf(shorter_dish.bup_info(2)["hue"] - Color.html("#00ff00").h) < 0.01 and absf(shorter_dish.bup_info(3)["hue"] - Genome.founder()["hue"]) < 0.001, "with fewer saved than founders the first ones get theirs and the rest the defaults")
	shorter_dish.free()
	var squeezed := StartConditions.from_dict({"bups": 50, "bup_limit": 10})
	check(squeezed.bup_limit == 50, "the limit is never below the founders (%d)" % squeezed.bup_limit)
	var crowd := []
	for i in 300:
		crowd.append({"name": "x"})
	check(StartConditions.from_dict({"founders": crowd}).founders.size() == StartConditions.MAX_BUPS and StartConditions.MAX_BUPS == 250, "at most 250 founders")
	_write_raw('{"bups": 12}')
	var partial := StartConditions.load_saved()
	check(partial.bups == 12 and partial.nutrient_density == StartConditions.new().nutrient_density, "missing keys fall back individually")

	# End to end through the real setup screen: choose, GO, "relaunch", reopen.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP))
	Session.free_start = StartConditions.load_saved()
	var setup: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(setup)
	await process_frame
	check(setup.bups_row.slider.value == 4 and setup.nutrients_row.slider.value == 32, "first ever visit shows the defaults")
	var wheel_sliders := setup.find_children("*", "HSlider", true, false)
	var wheel_scrolls := wheel_sliders.filter(func(n: Node) -> bool: return n.scrollable)
	check(wheel_sliders.size() >= 8 and wheel_scrolls.is_empty(), "no slider answers the scroll wheel, so scrolling the list over them leaves them alone (%d of %d do)" % [wheel_scrolls.size(), wheel_sliders.size()])
	setup.bups_row.slider.value = 55
	setup.nutrients_row.slider.value = 90
	setup.rate_row.slider.value = 3
	setup.dish_row.slider.value = 2.5
	setup.detail_row.slider.value = 250
	setup.thickness_row.slider.value = 8
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
	check(again.bups_row.slider.value == 55 and again.nutrients_row.slider.value == 90 and again.rate_row.slider.value == 3 and is_equal_approx(again.dish_row.slider.value, 2.5) and again.detail_row.slider.value == 250 and again.thickness_row.slider.value == 8,
		"next launch shows the previous choices (%d, %d, %d, %.1f)" % [again.bups_row.slider.value, again.nutrients_row.slider.value, again.rate_row.slider.value, again.dish_row.slider.value])
	again.queue_free()

	# The preview shows the plankton a bloom keeps floating, once the sliders have been still for a moment (not on every nudge).
	var bloomy := StartConditions.new()
	bloomy.dish_radius = 20000.0  # (a 20 mm dish: about 1,257 mm²)
	bloomy.bloom_density = 0.5  # (about 628 a day, so about 26 floating at a time)
	Session.free_start = bloomy
	var preview: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(preview)
	await process_frame
	check(preview.dish.plankton.is_empty(), "the preview has no plankton the moment it is made")
	await create_timer(preview.PLANKTON_SETTLE_SECONDS + 0.3).timeout
	var floating: int = preview.dish.plankton.size()
	check(floating == roundi(preview.dish.bloom_per_day() / 24.0) and floating > 20, "once still, the preview shows the plankton a bloom keeps floating (%d, a day's %.0f over 24)" % [floating, preview.dish.bloom_per_day()])
	preview.bloom_row.slider.value = 1.0
	await process_frame
	check(preview.dish.plankton.is_empty(), "moving a slider rebuilds the preview, without them until it is still again")
	await create_timer(preview.PLANKTON_SETTLE_SECONDS + 0.3).timeout
	check(preview.dish.plankton.size() == roundi(preview.dish.bloom_per_day() / 24.0), "...and they come back for the new bloom (%d)" % preview.dish.plankton.size())
	preview.bloom_row.slider.value = 0.0
	await create_timer(preview.PLANKTON_SETTLE_SECONDS + 0.3).timeout
	check(preview.dish.plankton.is_empty(), "no bloom, no plankton in the preview")
	preview.queue_free()
	await process_frame

	# The advanced options have a reset of their own: it clears them and nothing else, and is there only while one is changed.
	Session.free_start = StartConditions.new()
	var adv: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(adv)
	await process_frame
	check(not adv.advanced_reset.is_visible_in_tree() and not adv.advanced_toggle.text.contains(Strings.t("free_setup.advanced_changed").strip_edges()), "with the advanced options shut there is no reset showing, and with them as usual no 'changed'")
	adv.bups_row.slider.value = 30
	adv.detail_row.slider.value = 300
	adv.thickness_row.slider.value = 3
	check(not adv.advanced_reset.is_visible_in_tree() and adv.advanced_toggle.text.contains(Strings.t("free_setup.advanced_changed").strip_edges()), "a changed advanced option shows 'changed' on the heading, and still no reset while they are shut")
	adv.advanced_toggle.pressed.emit()
	await process_frame
	check(adv.advanced_reset.is_visible_in_tree() and adv.advanced_reset.tooltip_text == "Use defaults for the advanced options only", "the reset is inside, once they are opened")
	adv.advanced_reset.pressed.emit()
	check(adv.detail_row.slider.value == 100 and is_equal_approx(adv.thickness_row.slider.value, 25.0) and adv._start.nutrient_resolution == 100 and is_equal_approx(adv._start.medium_thickness, 25.0), "its reset puts the advanced options back to their defaults")
	check(adv.bups_row.slider.value == 30 and adv._start.bups == 30, "...and leaves every other setting as it was")
	check(not adv.advanced_toggle.text.contains(Strings.t("free_setup.advanced_changed").strip_edges()), "...and 'changed' goes with them")
	check(not adv.husks_toggle.button_pressed and not adv._start.death_husks and adv.husks_toggle.text == Strings.t("free_setup.husks_off"), "husks start off")
	adv.husks_toggle.button_pressed = true
	check(adv._start.death_husks and adv.husks_toggle.text == Strings.t("free_setup.husks_on") and adv.advanced_toggle.text.contains(Strings.t("free_setup.advanced_changed").strip_edges()), "turning husks on is kept, shown on the toggle and counted as a changed advanced option")
	adv.advanced_reset.pressed.emit()
	check(not adv._start.death_husks and not adv.husks_toggle.button_pressed, "the advanced reset turns husks off")
	adv.queue_free()
	await process_frame

	# The GPU setting, an advanced option: three buttons of one group (Auto, On, Off), kept with the other choices, counted in the
	# advanced heading, reset with the advanced options, and a one-line notice for On where this machine has no GPU to use.
	Session.free_start = StartConditions.new()
	var gs: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(gs)
	await process_frame
	var auto := StartConditions.BACKEND_AUTO
	var on := StartConditions.BACKEND_GPU
	var off := StartConditions.BACKEND_CPU
	var buttons: Dictionary = gs.backend_buttons
	var texts := [buttons[auto].text, buttons[on].text, buttons[off].text]
	check(texts == ["Auto", "On", "Off"], "the three choices read Auto, On, Off (%s)" % str(texts))
	check(buttons[auto].button_pressed and not buttons[on].button_pressed and not buttons[off].button_pressed and gs._start.sim_backend == auto, "the setting starts on Auto")
	check(buttons[auto].button_group == buttons[on].button_group and buttons[on].button_group == buttons[off].button_group and buttons[auto].toggle_mode, "the choices are toggle buttons of one group, like the speed buttons")
	check(not gs.backend_notice.visible and not gs.advanced_toggle.text.contains(Strings.t("free_setup.advanced_changed").strip_edges()), "on Auto there is no notice and the advanced heading is as usual")
	buttons[on].pressed.emit()
	check(buttons[on].button_pressed and not buttons[auto].button_pressed and gs._start.sim_backend == on, "choosing On makes it the only one pressed and the setting")
	check(gs.backend_notice.visible == not GpuWorld.available(), "On shows the one-line notice exactly where there is no GPU to use (here: %s)" % ("none" if not GpuWorld.available() else "one"))
	check(gs.backend_notice.text == Strings.t("free_setup.backend_unavailable") and gs.backend_notice.text.length() < 100, "the notice is a line from strings.cfg")
	check(gs.advanced_toggle.text.contains(Strings.t("free_setup.advanced_changed").strip_edges()), "a setting that is not Auto shows 'changed' on the advanced heading")
	check(Strings.t("free_setup.backend_hint").contains("x100 and up") and Strings.t("free_setup.backend_hint").contains("processor"), "the hint says the GPU applies at fast playback (x100 and up) and the processor runs the slow")
	buttons[off].pressed.emit()
	check(not gs.backend_notice.visible and gs._start.sim_backend == off, "Off needs no notice")
	gs._go()
	check(StartConditions.load_saved().sim_backend == off, "GO saves the setting")
	gs.queue_free()
	await process_frame
	Session.free_start = StartConditions.load_saved()
	var gs2: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(gs2)
	await process_frame
	check(gs2.backend_buttons[off].button_pressed and gs2._start.sim_backend == off, "the next launch shows the setting")
	gs2.advanced_toggle.pressed.emit()
	await process_frame
	gs2.advanced_reset.pressed.emit()
	check(gs2.backend_buttons[auto].button_pressed and gs2._start.sim_backend == auto and not gs2.advanced_toggle.text.contains(Strings.t("free_setup.advanced_changed").strip_edges()), "the advanced options' own reset puts it back to Auto")
	gs2.backend_buttons[on].pressed.emit()
	gs2.reset_button.pressed.emit()
	check(gs2.backend_buttons[auto].button_pressed and gs2._start.sim_backend == auto, "the screen's Use defaults does too")
	gs2.queue_free()
	await process_frame

	# A number box: focus from the keyboard selects the whole number (typing replaces it); focus from a click selects nothing,
	# so the mouse can then select part of it.
	Session.free_start = StartConditions.new()
	var boxes: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(boxes)
	await process_frame
	var box: LineEdit = boxes.bloom_row.value_field
	box.grab_focus()
	await process_frame
	check(box.has_selection() and box.get_selected_text() == box.text and box.text != "", "focus from the keyboard selects the whole number ('%s')" % box.get_selected_text())
	box.release_focus()
	await process_frame
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(-5000, -5000)  # (nowhere near anything)
	Input.parse_input_event(press)
	Input.flush_buffered_events()  # (so the button is down as far as the box can tell)
	box.grab_focus()
	await process_frame
	check(not box.has_selection(), "focus from a click selects nothing, so part of the number can be selected")
	var lift := press.duplicate()
	lift.pressed = false
	Input.parse_input_event(lift)
	Input.flush_buffered_events()
	box.release_focus()
	await process_frame
	box.grab_focus()
	await process_frame
	check(box.has_selection(), "and the next focus from the keyboard selects it all again")
	boxes.queue_free()
	await process_frame

	# Reset to default: loads defaults into the sliders only; nothing is saved or forgotten.
	var prev := StartConditions.new()
	prev.bups = 31
	prev.nutrient_density = 77
	prev.feed_density = 12.0
	prev.dish_radius = 3800.0
	prev.save()
	Session.free_start = StartConditions.load_saved()
	var file_before := FileAccess.get_file_as_string(TEMP)
	var reset_screen: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(reset_screen)
	current_scene = reset_screen
	await process_frame
	check(reset_screen.bups_row.slider.value == 31 and is_equal_approx(reset_screen.dish_row.slider.value, 3.8), "setup opens on the saved preference")
	reset_screen.reset_button.pressed.emit()
	var d := StartConditions.new()
	check(reset_screen.bups_row.slider.value == d.bups and reset_screen.nutrients_row.slider.value == d.nutrient_density and reset_screen.rate_row.slider.value == d.feed_density and is_equal_approx(reset_screen.dish_row.slider.value, d.dish_radius / 1000.0), "Reset to default puts the defaults in the sliders")
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
	reopened.dish_row.slider.value = 5.0
	reopened.nutrients_row.reset_button.pressed.emit()
	check(reopened.nutrients_row.slider.value == d.nutrient_density, "row reset puts that slider at its default")
	check(reopened.bups_row.slider.value == 90 and reopened.rate_row.slider.value == 20 and is_equal_approx(reopened.dish_row.slider.value, 5.0), "...and leaves the other sliders alone")
	reopened.rate_row.reset_button.pressed.emit()
	reopened.dish_row.reset_button.pressed.emit()
	reopened.bups_row.reset_button.pressed.emit()
	check(reopened.bups_row.slider.value == d.bups and reopened.rate_row.slider.value == d.feed_density and is_equal_approx(reopened.dish_row.slider.value, d.dish_radius / 1000.0), "every row has a working reset")
	check(FileAccess.get_file_as_string(TEMP) == file_now, "row resets save nothing")
	check(reopened.reset_button.text == "" and reopened.reset_button.icon != null and reopened.reset_button.tooltip_text == "Use defaults", "top-right reset is icon-only with a 'Use defaults' tooltip")
	check(reopened.bups_row.reset_button.tooltip_text == "Use default (4)", "row tooltip names the default: '%s'" % reopened.bups_row.reset_button.tooltip_text)
	check(reopened.reset_button.focus_mode == Control.FOCUS_ALL and reopened.bups_row.reset_button.focus_mode == Control.FOCUS_ALL, "reset icons can be reached with Tab")
	reopened.bups_row.slider.value = 12
	# Console-font white values; row resets sit left of their labels, away from the numbers.
	for v in [reopened.bups_row.value_field, reopened.nutrients_row.value_field, reopened.rate_row.value_field, reopened.dish_row.value_field]:
		check(v.get_theme_font("font") is FontFile and v.get_theme_color("font_color") == Color.WHITE, "%s is white bundled-font text" % v.name)
	await process_frame
	var pairs := [[reopened.bups_row.reset_button, reopened.bups_row.value_field, "BupsRow/Label"], [reopened.nutrients_row.reset_button, reopened.nutrients_row.value_field, "NutrientsRow/Label"],
		[reopened.rate_row.reset_button, reopened.rate_row.value_field, "RateRow/Label"], [reopened.dish_row.reset_button, reopened.dish_row.value_field, "DishRow/Label"]]
	for pair in pairs:
		var label: Control = reopened.get_node("Panel/Box/Scroll/Rows/" + pair[2])
		check(pair[0].global_position.x < label.global_position.x, "%s is left of its label" % pair[0].name)
		check(pair[0].global_position.x + pair[0].size.x < pair[1].global_position.x - 100.0, "%s is well away from the number" % pair[0].name)
	check(reopened.get_node("Panel/Box/Header/SectionLabel").global_position.x <= reopened.bups_row.reset_button.global_position.x + 8.0, "caption lines up with the left column")
	var column: Control = reopened.get_node("Panel")
	check(column.global_position.x >= 0.0 and column.global_position.x + column.size.x <= reopened.get_viewport_rect().size.x, "the settings box is on the screen")
	var box_inner_right: float = reopened.get_node("Panel").global_position.x + reopened.get_node("Panel").size.x - 24.0
	var global_right: float = reopened.reset_button.global_position.x + reopened.reset_button.size.x
	check(absf(global_right - box_inner_right) <= 1.0, "the global reset sits at the box's right edge, however wide the box is (%.0f vs %.0f)" % [global_right, box_inner_right])
	for v in [reopened.bups_row.value_field, reopened.dish_row.value_field]:
		check(v.global_position.x + v.size.x <= global_right + 1.0, "%s keeps to the right edge the global reset aligns to" % v.name)
	# A saved value off the slider's step grid: what is shown, previewed and played must agree.
	_write_raw('{"bups": 7, "nutrient_density": 33, "feed_density": 6.5, "dish_radius": 3050}')
	Session.free_start = StartConditions.load_saved()
	var off_grid: Control = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(off_grid)
	await process_frame
	check(off_grid._start.feed_density == off_grid.rate_row.value, "working copy takes the slider's rate (%s vs shown %s)" % [off_grid._start.feed_density, off_grid.rate_row.value])
	check(is_equal_approx(off_grid._start.dish_radius, off_grid.dish_row.value * 1000.0), "working copy takes the slider's radius (%s vs shown %s)" % [off_grid._start.dish_radius, off_grid.dish_row.value])
	check(off_grid._start.bups == int(off_grid.bups_row.value) and off_grid._start.nutrient_density == int(off_grid.nutrients_row.value), "bups and nutrients agree too")
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
	TestUtil.finish(self, "SETTINGS TESTS OK")
