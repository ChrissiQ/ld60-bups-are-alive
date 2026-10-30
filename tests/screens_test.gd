extends SceneTree
## Run: godot --headless --path . -s tests/screens_test.gd
## Cross-screen consistency: shared scene paths, and the same Escape behaviour everywhere.



func _init() -> void:
	for path in [Scenes.MENU, Scenes.INTRO, Scenes.FREE_SETUP, Scenes.GAME]:
		TestUtil.check(ResourceLoader.exists(path), "Scenes constant points at a real scene: %s" % path)

	var menu: Control = load(Scenes.MENU).instantiate()
	root.add_child(menu)
	await process_frame
	var menu_hues := []
	for id in menu.dish.bup_ids():
		menu_hues.append(menu.dish.bup_info(id)["hue"])
	menu_hues.sort()
	var menu_even: bool = menu_hues.size() == 4
	for k in menu_hues.size():
		menu_even = menu_even and absf(fposmod(menu_hues[(k + 1) % menu_hues.size()] - menu_hues[k], 1.0) - 0.25) < 0.01
	TestUtil.check(menu_even, "the dish behind the title starts with founders in evenly spaced colours (%s)" % [menu_hues])
	menu._show_controls(true)
	TestUtil.check(menu.controls_panel.visible and not menu.buttons.is_visible_in_tree(), "the controls panel replaces the buttons")
	menu._unhandled_input(TestUtil.key_event(KEY_ESCAPE, true, true))
	TestUtil.check(menu.controls_panel.visible, "a held (repeating) Escape does not close the controls panel")
	menu._unhandled_input(TestUtil.key_event(KEY_ESCAPE, true, false))
	TestUtil.check(not menu.controls_panel.visible and menu.buttons.is_visible_in_tree(), "one Escape press closes it and brings the buttons back")

	menu.queue_free()
	for scale in [1.0, 2.5]:
		UserSettings.native_override = 0.7407  # (a 3456 x 2104 screen at twice the system scale)
		UserSettings.ui_scale = scale
		UserSettings._applied = false
		UserSettings.apply()
		var big: Control = load(Scenes.MENU).instantiate()
		root.add_child(big)
		for i in 6:
			await process_frame
		var window_h: float = big.get_viewport_rect().size.y
		var column: Control = big.button_scroll.get_parent()
		var tall: bool = big.buttons.get_combined_minimum_size().y > big.button_scroll.size.y + 0.5
		TestUtil.check(column.get_combined_minimum_size().y <= window_h, "at %d%% the title, the tagline and the buttons fit the window (%.0f of %.0f)" % [int(scale * 100.0), column.get_combined_minimum_size().y, window_h])
		var scroll_box: Rect2 = big.button_scroll.get_global_rect()
		TestUtil.check(absf(scroll_box.get_center().x - big.get_viewport_rect().size.x * 0.5) < 2.0 and scroll_box.size.x <= big.buttons.get_combined_minimum_size().x + 40.0, "at %d%% the buttons are in the middle with their scrollbar beside them (%s)" % [int(scale * 100.0), scroll_box])
		TestUtil.check(big.title.get_global_rect().position.y >= 0.0, "at %d%% the title is inside the window" % int(scale * 100.0))
		TestUtil.check(not tall or big.button_scroll.get_v_scroll_bar().visible, "at %d%% buttons taller than their room scroll, and only they do" % int(scale * 100.0))
		big.queue_free()
		await process_frame

	TestUtil.finish(self, "SCREENS TESTS OK")
