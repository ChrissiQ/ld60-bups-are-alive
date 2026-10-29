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
	TestUtil.check(menu.controls_panel.visible and not menu.buttons.visible, "the controls panel replaces the buttons")
	menu._unhandled_input(TestUtil.key_event(KEY_ESCAPE, true, true))
	TestUtil.check(menu.controls_panel.visible, "a held (repeating) Escape does not close the controls panel")
	menu._unhandled_input(TestUtil.key_event(KEY_ESCAPE, true, false))
	TestUtil.check(not menu.controls_panel.visible and menu.buttons.visible, "one Escape press closes it and brings the buttons back")

	TestUtil.finish(self, "SCREENS TESTS OK")
