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
	for expected in ["DishCard", "DishDetails", "GraphSection", "AllDetails", "WatchSection", "FreezerSection"]:
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
	for scale in [1.0, 2.05, 2.5]:
		UserSettings.ui_scale = scale
		UserSettings.apply()
		m.graph_section.open = true
		for i in 6:
			await process_frame
		var open_width: float = m.side.size.x
		m.graph_section.open = false
		for i in 6:
			await process_frame
		TestUtil.check(is_equal_approx(m.side.size.x, open_width), "at %d%% the tray is as wide with the graph closed (%.0f) as open (%.0f)" % [int(scale * 100.0), m.side.size.x, open_width])
		TestUtil.check(m.vitals.size.y >= m.vitals.get_content_height(), "at %d%% the top bar's readout is as tall as its text" % int(scale * 100.0))
	# Reordering: the headings drag, the order is a user setting, and only the movable sections take part.
	var scratch := "user://tray_order_test.cfg"
	var real_path := UserSettings.path
	UserSettings.path = scratch
	var tray: Node = m.graph_section.get_parent()
	var before := TraySection.order_of(tray)
	TestUtil.check(before.has("DishDetails") and before.has("GraphSection") and before.has("FreezerSection"), "the dish's details are among the sections that can be moved (%s)" % [before])
	var dragged: TraySection = m.freezer_section
	TestUtil.check(m.graph_section._can_drop(Vector2.ZERO, dragged) and not m.graph_section._can_drop(Vector2.ZERO, m.graph_section) and m.graph_section._can_drop(Vector2.ZERO, m.dish_details), "a section can be dropped on another's heading, not on itself, and the dish's details take part like the rest")
	dragged._drag_data(Vector2(5, 5))
	var slot: DropSlot = dragged._slot
	TestUtil.check(not dragged.visible and slot != null and slot.get_parent() == tray and slot.get_index() == dragged.get_index() - 1 + 0 or slot.get_index() < dragged.get_index(), "dragging leaves a slot in the section's place and lifts the section out")
	TestUtil.check(TraySection.order_of(tray) == before, "the order does not change while dragging")
	TestUtil.check(TraySection._movable(tray).all(func(s: TraySection) -> bool: return not dragged._accepting.has(s.header)), "a drag leaves every heading's own drag handlers alone")
	dragged._finish_drag(false)
	TestUtil.check(dragged.visible and TraySection.order_of(tray) == before and UserSettings.tray_order.is_empty() and not is_instance_valid(slot) or slot.is_queued_for_deletion(), "cancelling puts it back and keeps nothing")
	dragged._drag_data(Vector2(5, 5))
	tray.move_child(dragged._slot, m.graph_section.get_index())
	dragged._finish_drag(true)
	TestUtil.check(dragged.visible and TraySection.order_of(tray).find("FreezerSection") < before.find("FreezerSection"), "letting go puts the section in the slot")
	var chosen_order := TraySection.order_of(tray)
	TestUtil.check(UserSettings.tray_order == chosen_order, "the order is kept as a user setting")
	var kept := ConfigFile.new()
	TestUtil.check(kept.load(scratch) == OK and PackedStringArray(kept.get_value("interface", "tray_order")) == chosen_order, "and written to the preferences file")
	m.graph_section.get_parent().move_child(m.graph_section, tray.get_child_count() - 1)
	TraySection.apply_order(tray)
	TestUtil.check(TraySection.order_of(tray) == chosen_order, "applying the setting puts the sections back in it")
	UserSettings.reset()
	TestUtil.check(UserSettings.tray_order.is_empty() and TraySection.order_of(tray) == before, "the reset puts the sections back in the scene's order")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(scratch))
	UserSettings.path = real_path
	TestUtil.finish(self, "TRAY SECTIONS TESTS OK", "TRAY SECTIONS TESTS FAILED:")
