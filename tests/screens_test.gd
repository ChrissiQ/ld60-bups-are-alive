extends SceneTree
## Run: godot --headless --path . -s tests/screens_test.gd
## Cross-screen consistency: shared scene paths, and the same Escape behaviour everywhere.

var failures: Array = []


func check(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)


func _escape(echo: bool) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = KEY_ESCAPE
	e.pressed = true
	e.echo = echo
	return e


func _init() -> void:
	for path in [Scenes.MENU, Scenes.INTRO, Scenes.FREE_SETUP, Scenes.GAME]:
		check(ResourceLoader.exists(path), "Scenes constant points at a real scene: %s" % path)

	var menu: Control = load(Scenes.MENU).instantiate()
	root.add_child(menu)
	await process_frame
	menu._show_controls(true)
	check(menu.controls_panel.visible and not menu.buttons.visible, "the controls panel replaces the buttons")
	menu._unhandled_input(_escape(true))
	check(menu.controls_panel.visible, "a held (repeating) Escape does not close the controls panel")
	menu._unhandled_input(_escape(false))
	check(not menu.controls_panel.visible and menu.buttons.visible, "one Escape press closes it and brings the buttons back")

	if failures.is_empty():
		print("SCREENS TESTS OK")
	else:
		print("FAILED:")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)
