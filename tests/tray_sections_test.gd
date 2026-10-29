extends SceneTree
## Run: godot --headless --path . -s tests/tray_sections_test.gd
## Every section of the side tray is the same thing: a plain TraySection of the game screen's scene (the same script, the same place in the tray, the same size flags and theme, its own
## content as children), never a scene or a subclass of its own. So they open and close the same way, fill the tray's width the same way, and shrink to a heading the same way, in every
## state the tray can be in.


func _init() -> void:
	_run()


func _sections(m: Node) -> Array[TraySection]:
	var out: Array[TraySection] = []
	for node in m.find_children("*", "PanelContainer", true, false):
		if node is TraySection:
			out.append(node)
	return out


func _same_width(m: Node, what: String) -> void:
	var sections := _sections(m).filter(func(s: TraySection) -> bool: return s.is_visible_in_tree())  # (the all-dishes section is hidden while there is one dish)
	var widths := {}
	for section in sections:
		widths[snappedf(section.size.x, 0.5)] = true
	TestUtil.check(widths.size() == 1, "%s: all %d sections are as wide as each other (%s)" % [what, sections.size(), sections.map(func(s: TraySection) -> String: return "%s %.0f%s" % [s.name, s.size.x, "" if s.open else " (closed)"])])


func _run() -> void:
	SimConstants.apply()
	var chosen := TestUtil.small_start()
	chosen.bups = 30
	var m: Node = TestUtil.game_screen(self, chosen)
	for i in 6:
		await process_frame
	var sections := _sections(m)
	var names := sections.map(func(s: TraySection) -> String: return s.name)
	for expected in ["DishDetails", "GraphSection", "AllDetails", "WatchSection", "FreezerSection"]:
		TestUtil.check(names.has(expected), "the tray has the %s section (%s)" % [expected, names])
	var first := sections[0]
	for section in sections:
		TestUtil.check(section.get_script() == first.get_script() and section.get_class() == "PanelContainer" and section.get_parent() == first.get_parent(), "%s is a plain tray section in the tray, like the rest" % section.name)
		TestUtil.check(section.size_flags_horizontal == first.size_flags_horizontal and section.size_flags_vertical == first.size_flags_vertical and section.theme_type_variation == first.theme_type_variation and section.mouse_filter == first.mouse_filter, "%s has the same size flags, theme and mouse setting" % section.name)
		TestUtil.check(section.header != null and section.body != null and section.header.get_parent() == section.body.get_parent() and section.header.theme_type_variation == &"SectionButton", "%s has a heading with a chevron over its content" % section.name)
	_same_width(m, "at the start")
	for step in ["collapsed", "opened again"]:
		for section in _sections(m):
			section.header.pressed.emit()  # (the heading opens and closes it)
		for i in 4:
			await process_frame
		for section in _sections(m):
			TestUtil.check(section.body.visible == section.open, "%s: %s, its content is %s" % [section.name, step, "shown" if section.open else "hidden"])
			if not section.open:
				TestUtil.check(section.size.y < 70.0, "%s: collapsed, it is only its heading (%.0f px)" % [section.name, section.size.y])
		_same_width(m, step)
	# With a bup picked and watched, watched no more, and the sections open and closed in turn.
	var id: int = m.dish.bup_ids()[0]
	m.dish.selected.bup = id
	m.dish.watch_bup(id)
	for i in 8:
		await process_frame
	_same_width(m, "with a bup watched")
	m.watch_section.open = false
	for i in 4:
		await process_frame
	_same_width(m, "with the watch list collapsed")
	m.dish.unwatch_bup(id)
	for i in 4:
		await process_frame
	_same_width(m, "after the bup is not watched any more")
	TestUtil.check(m.watch_section.size.y < 70.0, "the collapsed watch list is only its heading")
	for scale in [1.5, 2.5]:
		UserSettings.ui_scale = scale
		UserSettings.apply()
		for i in 6:
			await process_frame
		_same_width(m, "at an interface size of %d%%" % int(scale * 100.0))
	TestUtil.finish(self, "TRAY SECTIONS TESTS OK", "TRAY SECTIONS TESTS FAILED:")
