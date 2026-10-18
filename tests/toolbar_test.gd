extends SceneTree
## Run: godot --headless --path . -s tests/toolbar_test.gd
## Drives the game screen with synthetic input: click vs drag, tools, zoom, shortcuts.
## Uses free mode so nothing can touch the real save file.

var failures: Array = []


func check(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)


func _button(m: Node, index: MouseButton, pressed: bool, pos: Vector2) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = index
	e.pressed = pressed
	e.position = pos
	m._unhandled_input(e)


func _motion(m: Node, pos: Vector2, rel: Vector2, mask: int = MOUSE_BUTTON_MASK_LEFT) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.relative = rel
	e.button_mask = mask  # the button state a real motion event reports
	m._unhandled_input(e)


func _click(m: Node, pos: Vector2) -> void:
	_button(m, MOUSE_BUTTON_LEFT, true, pos)
	_button(m, MOUSE_BUTTON_LEFT, false, pos)


func _drag(m: Node, from: Vector2, delta: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var mask := MOUSE_BUTTON_MASK_MIDDLE if button == MOUSE_BUTTON_MIDDLE else MOUSE_BUTTON_MASK_LEFT
	_button(m, button, true, from)
	_motion(m, from + delta * 0.5, delta * 0.5, mask)
	_motion(m, from + delta, delta * 0.5, mask)
	_button(m, button, false, from + delta)


## Puts the pointer over a point of the dish, as far as the select tool's readout is concerned.
func _hover_over(m: Node, world: Vector2) -> void:
	m.dish.clear_hover()
	m._hover_dish(world)
	m._update_info_panel()


func _screen(m: Node, world: Vector2) -> Vector2:
	return m.get_viewport_rect().size * 0.5 + (world - m.camera.position) * m.camera.zoom.x


func _world(m: Node, screen: Vector2) -> Vector2:
	return m.camera.position + (screen - m.get_viewport_rect().size * 0.5) / m.camera.zoom.x


func _key(code: Key, shift: bool = false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.shift_pressed = shift
		e.pressed = pressed
		Input.parse_input_event(e)
		await process_frame


func _init() -> void:
	var start := StartConditions.new()
	start.dish_radius = 300.0  # the tests place things by hand and count on a small dish
	start.nutrients = 0
	start.nutrient_rate = 0.0
	Session.free_start = start
	Session.mode = Session.Mode.FREE
	var m: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	var view: Vector2 = m.get_viewport_rect().size
	var centre := view * 0.5

	var dish_top: float = centre.y - m.dish.radius * m.camera.zoom.x
	check(m.camera.zoom.x <= 1.0 and dish_top >= 80.0, "dish fits below the toolbar (top at y=%.0f, zoom %.2f)" % [dish_top, m.camera.zoom.x])
	check(m.camera.position.is_equal_approx(m.dish.global_position), "camera starts on the dish")
	check(m.tool == Toolbar.Tool.SELECT, "default tool is select")
	check(m.tool == m.toolbar.current_tool(), "the screen's tool and the toolbar's selection agree from the start")
	for t in Toolbar.Tool.values():
		check(m.toolbar.button_for(t) != null, "the toolbar has a button for tool %d" % t)
	check(m.tool_options.toolbar == m.toolbar, "the options tray is wired to its toolbar by export, not by a hard-coded path")
	m.toolbar.select_tool(Toolbar.Tool.PAN)
	check(m.toolbar.current_tool() == Toolbar.Tool.PAN and m.tool == Toolbar.Tool.PAN, "current_tool() follows the selection")
	m.toolbar.select_tool(Toolbar.Tool.SELECT)
	check(m.paused and m.pause_ring.visible and m.toolbar.pause_button.button_pressed, "free mode starts paused with the red ring")
	var paused_label: Label = m.pause_ring.get_node("PausedLabel")
	await process_frame
	var win: Vector2 = m.get_viewport_rect().size
	var label_rect: Rect2 = paused_label.get_global_rect()
	check(paused_label.is_visible_in_tree() and paused_label.text == "PAUSED", "PAUSED shows while paused")
	check(paused_label.get_theme_color("font_color").r > 0.8 and paused_label.get_theme_color("font_color").g < 0.3 and paused_label.get_theme_font_size("font_size") >= 40, "PAUSED is large and red")
	check(absf(label_rect.get_center().x - win.x * 0.5) <= 1.0, "PAUSED is centred horizontally")
	check(is_equal_approx(label_rect.end.y, win.y - 16.0), "PAUSED sits 8px inside the 8px border (bottom edge %.0f, window %.0f)" % [label_rect.end.y, win.y])
	check(paused_label.mouse_filter == Control.MOUSE_FILTER_IGNORE, "PAUSED doesn't swallow clicks")
	check(paused_label.get_theme_font("font").resource_path == "res://fonts/CommitMono-700.otf", "PAUSED is the bundled font in bold")
	check(_exclusive(m.toolbar) and not m.toolbar.speed_1_button.button_pressed, "free mode start: only Pause is lit")
	var t0: float = m.dish.time
	await create_timer(1.2).timeout
	check(m.dish.time == t0, "paused: the sim doesn't advance")
	check(m.dish.flash == 0.0, "paused: the opening lightning flash still fades (flash=%.2f)" % m.dish.flash)
	m.toolbar.set_paused(false)
	check(not m.paused and not m.pause_ring.visible, "resuming removes the ring")
	check(not paused_label.is_visible_in_tree(), "resuming hides PAUSED too")
	await create_timer(0.2).timeout
	check(m.dish.time > t0, "resumed: the sim advances")
	m.toolbar.set_paused(true)
	m._restart()
	check(m.paused and m.pause_ring.visible, "restarting in free mode pauses again")
	m.toolbar.set_paused(false)

	# --- Nutrient tool: click drops a dose, drag pans.
	m.toolbar.set_paused(true)  # the medium then changes only by what the clicks do
	m.toolbar.select_tool(Toolbar.Tool.NUTRIENT)
	check(m.tool == Toolbar.Tool.NUTRIENT, "toolbar selects nutrient tool")
	check(m.tool_options.visible and m.tool_options.nutrient_count_box.is_visible_in_tree(), "nutrient tool shows its options")
	await process_frame
	await process_frame
	check(is_equal_approx(m.tool_options.size.x, m.toolbar.size.x) and is_equal_approx(m.tool_options.global_position.x, m.toolbar.global_position.x), "tray is exactly as wide as the toolbar (%.0f vs %.0f)" % [m.tool_options.size.x, m.toolbar.size.x])
	check(is_equal_approx(m.tool_options.global_position.y, m.toolbar.global_position.y + m.toolbar.size.y), "tray touches the bottom of the toolbar, no gap")
	var box_centre: float = m.tool_options.nutrient_count_box.global_position.x + m.tool_options.nutrient_count_box.size.x * 0.5
	var button_centre: float = m.toolbar.nutrient_button.global_position.x + m.toolbar.nutrient_button.size.x * 0.5
	check(absf(box_centre - button_centre) <= 1.0, "number box sits directly under the nutrient button (%.1f vs %.1f)" % [box_centre, button_centre])
	check(m.tool_options.nutrient_count_box.value == 1.0, "count defaults to 1")
	var count_field: LineEdit = m.tool_options.nutrient_count_box.get_line_edit()
	check(count_field.get_tooltip(Vector2.ZERO) == "Nutrients per click", "hovering the number says 'Nutrients per click' (got '%s')" % count_field.get_tooltip(Vector2.ZERO))
	check(m.tool_options.nutrient_count_box.get_tooltip(Vector2.ZERO) == "Nutrients per click", "...and so does the box's arrow area")
	check(m.toolbar.theme_type_variation == &"ToolbarPanelOpen", "toolbar squares its bottom corners while the tray is open")
	check(m.tool_options.get_node_or_null("NutrientOptions/Label") == null, "no caption in the tray")
	check(m.tool_options.global_position.y >= m.toolbar.global_position.y + m.toolbar.size.y, "options sit below the main toolbar")
	var options_bottom: float = m.tool_options.global_position.y + m.tool_options.size.y
	var dish_top_now: float = centre.y - m.dish.radius * m.camera.zoom.x
	check(dish_top_now >= options_bottom, "the dish clears the options bar (dish top %.0f, bar bottom %.0f)" % [dish_top_now, options_bottom])
	m.tool_options.nutrient_count_box.value = 9999
	check(m.tool_options.nutrient_count() == 100, "nutrient count caps at 100, got %d" % m.tool_options.nutrient_count())
	var box: SpinBox = m.tool_options.nutrient_count_box
	var field := box.get_line_edit()
	await process_frame
	var digits_w := field.get_theme_font("font").get_string_size("100", HORIZONTAL_ALIGNMENT_LEFT, -1, field.get_theme_font_size("font_size")).x
	check(box.size.x <= 56.0, "nutrient box is compact (%.0fpx)" % box.size.x)
	check(digits_w + 8.0 <= field.size.x, "three digits still fit the field (%.0f + padding in %.0fpx)" % [digits_w, field.size.x])
	m.tool_options.nutrient_count_box.value = 1
	var p := centre + Vector2(50, 30)
	_click(m, p)
	check(absf(TestUtil.units(m.dish) - 1.0) < 0.01, "a click drops one unit of nutrient, got %.2f" % TestUtil.units(m.dish))
	var dropped_at: Vector2 = _world(m, p) - m.dish.global_position
	check(m.dish.field.sample(dropped_at) > m.dish.field.sample(dropped_at + Vector2(80, 0)), "...where it was clicked")
	_click(m, centre + Vector2(900, 0))
	check(absf(TestUtil.units(m.dish) - 1.0) < 0.01, "a click outside the dish drops nothing")
	m.tool_options.nutrient_count_box.value = 30
	_click(m, p)
	check(absf(TestUtil.units(m.dish) - 31.0) < 0.01, "a dose of 30 adds 30 more, got %.2f" % TestUtil.units(m.dish))
	await process_frame
	await process_frame
	check(m.dish.nutrients_placed == 31, "dish counted 31 placed, got %d" % m.dish.nutrients_placed)
	check(m.hud.get_parsed_text().contains("PLACED  31"), "the readout shows the placed count: '%s'" % m.hud.get_parsed_text().get_slice("\n", 3))
	check(m.hud.get_theme_font("normal_font") is FontFile and m.hud.get_theme_font("normal_font").resource_path.begins_with("res://fonts/CommitMono"), "HUD text uses the bundled font")
	for node in [m.hud, m.goal_panel, m.info_text]:
		check(node.mouse_filter == Control.MOUSE_FILTER_IGNORE, "%s doesn't swallow clicks" % node.name)

	var before: float = TestUtil.units(m.dish)
	var cam_before: Vector2 = m.camera.position
	_drag(m, centre, Vector2(60, 0))
	check(is_equal_approx(TestUtil.units(m.dish), before), "a drag must not drop nutrient")
	check(is_equal_approx(m.camera.position.x, cam_before.x - 60.0 / m.camera.zoom.x), "drag pans the camera by the pointer distance (%.1f)" % (m.camera.position.x - cam_before.x))
	cam_before = m.camera.position
	_button(m, MOUSE_BUTTON_LEFT, true, centre)
	_motion(m, centre + Vector2(3, 0), Vector2(3, 0))  # under the drag threshold
	_button(m, MOUSE_BUTTON_LEFT, false, centre + Vector2(3, 0))
	check(TestUtil.units(m.dish) > before + 29.0, "a tiny wobble is still a click")
	check(m.camera.position.is_equal_approx(cam_before), "...and doesn't pan")

	# --- Pan tool: dragging pans, clicking does nothing.
	m.toolbar.select_tool(Toolbar.Tool.PAN)
	check(not m.tool_options.visible and not m.tool_options.nutrient_count_box.is_visible_in_tree(), "pan tool has no options, so no number box")
	check(m.toolbar.theme_type_variation == &"ToolbarPanel", "toolbar is a closed rounded bar again with no tray")
	before = TestUtil.units(m.dish)
	_click(m, centre)
	check(is_equal_approx(TestUtil.units(m.dish), before), "click with pan tool does nothing")
	cam_before = m.camera.position
	_drag(m, centre, Vector2(0, 40))
	check(is_equal_approx(m.camera.position.y, cam_before.y - 40.0 / m.camera.zoom.x), "pan tool drag pans")
	_drag(m, centre, Vector2(5000, 5000))
	check(m.camera.position.length() <= m.dish.radius + 0.01, "panning can't leave the dish behind (%.0f)" % m.camera.position.length())
	m.camera.position = m.dish.global_position

	# --- A drag whose release the GUI ate (e.g. released over the toolbar) must not stick.
	m.toolbar.select_tool(Toolbar.Tool.PAN)
	cam_before = m.camera.position
	_button(m, MOUSE_BUTTON_LEFT, true, centre)
	_motion(m, centre + Vector2(30, 0), Vector2(30, 0))
	check(m._dragging and m.camera.position.x < cam_before.x, "a held drag pans")
	var cam_dragged: Vector2 = m.camera.position
	_motion(m, centre + Vector2(60, 0), Vector2(30, 0), 0)  # the button is no longer down, but no release reached us
	check(m._press_button == MOUSE_BUTTON_NONE and not m._dragging, "motion with no button held cancels a stuck drag")
	_motion(m, centre + Vector2(90, 0), Vector2(30, 0), 0)
	check(m.camera.position.is_equal_approx(cam_dragged), "...and the camera stops following the cursor")
	m.camera.position = m.dish.global_position
	m.toolbar.select_tool(Toolbar.Tool.SELECT)

	# --- Select tool: click selects, empty click deselects, middle button pans.
	var picks: Dictionary = m.tool_options.pick_buttons
	var pick_names := ["Select all", "Background", "Bups", "Nutrient sources"]
	var picks_ok: bool = m.tool_options.visible and picks.size() == 4 and picks[0].button_pressed
	for i in picks.size():
		picks_ok = picks_ok and picks[i].icon != null and picks[i].text == "" and picks[i].tooltip_text == pick_names[i]
	check(picks_ok, "the select tool has a tray of four icon buttons (no text) named on hover, with Select all chosen")
	var bup: int = m.dish.bup_ids()[0]
	m.dish.sim.set_bup_pos(bup, Vector2(20, 10))
	_click(m, centre + Vector2(20, 10))
	check(m.dish.selected_id == bup, "info click selects the bup")
	await process_frame
	await process_frame  # process_frame fires before nodes' _process, so allow a full frame
	check(not m.name_row.swatch.visible, "a living bup, which can be seen in the dish, has no colour square")
	check(m.info_panel.visible and m.name_row.visible and m.name_row.name_label.text.contains("bup #") and m.info_text.get_parsed_text().contains("generation"), "info panel shows the selected bup, named with its number ('%s')" % m.name_row.name_label.text)
	_click(m, centre + Vector2(-250, -250))
	check(m.dish.selected_id == -1, "clicking empty space deselects")
	m.dish.selected_id = bup
	cam_before = m.camera.position
	_drag(m, centre, Vector2(30, 0), MOUSE_BUTTON_MIDDLE)
	check(not m.camera.position.is_equal_approx(cam_before), "middle-button drag pans in any tool")
	check(m.dish.selected_id == bup, "...without changing the selection")
	m.dish.remove_bup(bup)
	await process_frame
	await process_frame
	check(m.dish.selected_id == bup and m.info_panel.visible and m.info_panel.theme_type_variation == &"DeceasedPanel" and m.info_text.get_parsed_text().contains("status: deceased") and m.info_text.get_parsed_text().contains("died") and not m.follow_button.visible, "when the selected bup dies its panel stays, as a deceased one (grey, status, time of death)")
	check(m.name_row.swatch.visible and m.name_row.swatch.color.is_equal_approx(Genome.color_of(m.dish.lineage_info(bup))), "a deceased bup shows a small square in its colour by its name, since it can't be seen in the dish")
	await _key(KEY_ESCAPE)
	check(m.dish.selected_id == -1 and not m.info_panel.visible and not m.dish.has_record(bup), "Escape closes it, and the dead bup's record is dropped with nothing left to need it")
	m.camera.position = m.dish.global_position

	# --- A long frame can't snowball: the sim catches up on at most MAX_FRAME_SECONDS.
	m.toolbar.speed_1000_button.button_pressed = true
	var sim_before: float = m.dish.time
	m._process(5.0)
	var caught_up: float = m.dish.time - sim_before
	check(caught_up <= m.MAX_FRAME_SECONDS * 1000.0 + 0.05 and caught_up > 0.5, "a 5s hitch at x1000 advances the sim by at most %.0fs, not 5000s" % caught_up)
	m.toolbar.speed_1_button.button_pressed = true

	# --- Readout: playback speed is its own labelled line, not a suffix on the time.
	m.toolbar.set_paused(false)
	m.toolbar.speed_1_button.button_pressed = true
	await process_frame
	await process_frame
	var readout: String = m.hud.get_parsed_text()
	check(readout.contains("PLAYBACK  x1") and not readout.contains("(x"), "readout shows 'PLAYBACK  x1' on its own line and no '(x..)' after the time: '%s'" % readout.get_slice("\n", 1))
	var time_line := ""
	for line in readout.split("\n"):
		if line.begins_with("TIME  "):
			time_line = line
	check(time_line != "" and not time_line.contains("x"), "the TIME line is just the time ('%s')" % time_line)
	m.toolbar.speed_1000_button.button_pressed = true
	await process_frame
	await process_frame
	check(m.hud.get_parsed_text().contains("PLAYBACK  x1,000"), "speed 1000 reads 'PLAYBACK  x1,000'")
	m.toolbar.set_paused(true)
	await process_frame
	await process_frame
	check(m.hud.get_parsed_text().contains("PLAYBACK  paused") and not m.hud.get_parsed_text().contains("[PAUSED]"), "paused reads 'PLAYBACK  paused'")
	m.toolbar.speed_1_button.button_pressed = true  # resume at normal speed

	# --- Select tool: the panel follows the pointer until a bup or source is clicked.
	m.toolbar.select_tool(Toolbar.Tool.SELECT)
	m.dish.clear_bups()
	m.dish.sources.clear()
	m.dish.field.reset(m.dish.radius)
	m.toolbar.set_paused(true)  # keep everything still so the readings are exact
	var spot: Vector2 = m.dish.global_position + Vector2(-70, 40)
	m.dish.field.deposit(spot - m.dish.global_position, 8.0)
	await process_frame
	await process_frame
	_hover_over(m, spot)
	var point_text: String = m.info_text.get_parsed_text()
	check(m.info_panel.visible and point_text.begins_with("NUTRIENT\nconcentration"), "hovering ground shows the nutrient there: '%s'" % point_text.replace("\n", " | "))
	check(point_text.contains("position  -70, 40") and point_text.contains("nearest bup  none") and point_text.contains("nearest source  none"), "...with its position and what is near: '%s'" % point_text.replace("\n", " | "))
	check(not m.source_rate_row.visible and not m.delete_source_button.visible, "...and no source controls")
	m.dish.field.reset(m.dish.radius)
	m.dish.edit_count += 1  # (the dish is told when the medium is changed by hand, so the readout looks again)
	_hover_over(m, spot)
	check(m.info_text.get_parsed_text().contains("gradient  flat"), "an empty medium reads flat")
	var rising := []
	for k in m.dish.field.size * m.dish.field.size:
		rising.append(0.02 * exp(m.dish.field.cell_centre(k).x / 100.0))
	m.dish.field.load_values(rising)
	m.dish.edit_count += 1
	_hover_over(m, spot)
	check(m.info_text.get_parsed_text().contains("rising to the E"), "a medium that rises to the right says so: '%s'" % m.info_text.get_parsed_text().replace("\n", " | "))
	var near_pos := spot + Vector2(20, 0)
	var near_bup: int = m.dish.add_bup(near_pos, Genome.founder(), 30.0)
	m.dish.place_source(spot + Vector2(0, 60), 2.0)
	_hover_over(m, spot)
	check(m.info_text.get_parsed_text().contains("nearest bup  20 away") and m.info_text.get_parsed_text().contains("nearest source  60 away"), "the readout shows what is near: '%s'" % m.info_text.get_parsed_text().replace("\n", " | "))
	# Hovering a bup or a source shows that instead; clicking pins it.
	_hover_over(m, near_pos)
	check(m.name_row.visible and m.info_text.get_parsed_text().contains("generation") and not m.name_row.rename_button.visible, "hovering a bup shows the bup, but can't rename it")
	_hover_over(m, m.dish.sources[0].pos)
	check(m.info_text.get_parsed_text().begins_with("NUTRIENT SOURCE") and not m.source_rate_row.visible, "hovering a source shows it, read-only")
	m.dish.select_at(near_pos)
	_hover_over(m, spot)
	check(m.name_row.visible and m.info_text.get_parsed_text().contains("generation") and not m.info_text.get_parsed_text().contains("NUTRIENT") and m.name_row.rename_button.visible, "a clicked bup stays on the panel while the pointer moves away, and can be renamed")
	m.dish.select_at(m.dish.global_position + Vector2(-200, -200))
	_hover_over(m, spot)
	check(m.dish.selected_id == -1 and m.info_text.get_parsed_text().begins_with("NUTRIENT\nconcentration"), "clicking empty ground lets go, and the panel follows the pointer again")
	m.dish.remove_bup(near_bup)
	m.dish.select_at(m.dish.global_position + Vector2(-200, -200))
	m.dish.sources.clear()
	m.toolbar.select_tool(Toolbar.Tool.NUTRIENT)
	_click(m, _screen(m, spot))
	check(m.dish.selected_id == -1 and m.dish.selected_source == null, "the nutrient tool drops nutrient; it doesn't select")
	m.toolbar.select_tool(Toolbar.Tool.SELECT)
	m.toolbar.set_paused(false)
	m.dish.clear_bups()
	for i in 4:
		m.dish.add_bup(m.dish.global_position + Vector2(100 + i * 10, 100), Genome.founder(), 30.0)

	# --- Zoom.
	m.camera.zoom = Vector2.ONE
	_button(m, MOUSE_BUTTON_WHEEL_UP, true, centre)
	check(m.camera.zoom.x > 1.0, "wheel up zooms in")
	_button(m, MOUSE_BUTTON_WHEEL_DOWN, true, centre)
	check(is_equal_approx(m.camera.zoom.x, 1.0), "wheel down zooms back out")
	m.camera.zoom = Vector2.ONE
	m.toolbar.zoom_in_button.pressed.emit()
	check(is_equal_approx(m.camera.zoom.x, m.ZOOM_BUTTON_STEP), "zoom-in button steps zoom")
	for i in 100:
		_button(m, MOUSE_BUTTON_WHEEL_UP, true, centre)
	check(is_equal_approx(m.camera.zoom.x, m.ZOOM_MAX), "zoom clamps at max")
	for i in 200:
		_button(m, MOUSE_BUTTON_WHEEL_DOWN, true, centre)
	check(is_equal_approx(m.camera.zoom.x, m.ZOOM_MIN), "zoom clamps at min")
	m.camera.zoom = Vector2.ONE
	# Zooming keeps a selected bup or source where it is on the screen; with nothing selected it zooms about the middle.
	m.dish.selected_id = -1
	m.dish.selected_source = null
	m.camera.position = m.dish.global_position
	var cam_unselected: Vector2 = m.camera.position
	m.toolbar.zoom_in_button.pressed.emit()
	check(m.camera.position.is_equal_approx(cam_unselected), "with nothing selected, zooming leaves the camera on the middle")
	m.camera.zoom = Vector2.ONE
	var pinned_id: int = m.dish.add_bup(m.dish.global_position + Vector2(60, -40), Genome.founder(), 30.0)
	m.dish.selected_id = pinned_id
	var pinned_at: Vector2 = _screen(m, m.dish.bup_world_pos(pinned_id))
	m.toolbar.zoom_in_button.pressed.emit()
	check(_screen(m, m.dish.bup_world_pos(pinned_id)).is_equal_approx(pinned_at) and m.camera.zoom.x > 1.0, "zooming in keeps the selected bup at the same place on the screen")
	m.toolbar.zoom_out_button.pressed.emit()
	check(_screen(m, m.dish.bup_world_pos(pinned_id)).is_equal_approx(pinned_at), "...and zooming out does too")
	# A selection scrolled out of view anchors nothing: zooming goes back to being about the middle.
	m.camera.zoom = Vector2.ONE
	m.camera.position = m.dish.bup_world_pos(pinned_id) + Vector2(3000.0, 0.0)
	var panned_away: Vector2 = m.camera.position
	m.toolbar.zoom_in_button.pressed.emit()
	check(m.camera.zoom.x > 1.0 and m.camera.position.is_equal_approx(panned_away), "with the selection off the screen, zooming stays about the middle of the view")
	m.camera.zoom = Vector2.ONE
	m.camera.position = m.dish.global_position
	m.dish.remove_bup(pinned_id)
	m.dish.selected_id = -1
	m.dish.place_source(m.dish.global_position + Vector2(-70, 30), 2.0)
	m.dish.selected_source = m.dish.sources[0]
	pinned_at = _screen(m, m.dish.selected_source.pos)
	m.toolbar.zoom_in_button.pressed.emit()
	check(_screen(m, m.dish.selected_source.pos).is_equal_approx(pinned_at), "a selected source stays put when zooming too")
	m.dish.remove_source(m.dish.sources[0])
	m.camera.zoom = Vector2.ONE
	m.camera.position = m.dish.global_position

	# --- Follow: the info panel's button keeps the selected bup in the middle of the view.
	m.toolbar.set_paused(true)  # nothing moves unless the test moves it
	var tracked: int = m.dish.add_bup(m.dish.global_position + Vector2(90, 50), Genome.founder(), 30.0)
	m.dish.selected_id = tracked
	await process_frame
	await process_frame
	check(m.follow_button.visible and m.follow_button.text == "Follow", "a selected bup offers a Follow button")
	m.follow_button.pressed.emit()
	check(m.camera.position.is_equal_approx(m.dish.bup_world_pos(tracked)), "Follow centres the view on the bup at once")
	m.dish.sim.set_bup_pos(tracked, Vector2(-120, 80))
	await process_frame
	await process_frame
	check(m.camera.position.is_equal_approx(m.dish.bup_world_pos(tracked)) and m.follow_button.text == "Stop following", "...and the view stays on it as it moves")
	m.toolbar.zoom_in_button.pressed.emit()
	check(m.camera.position.is_equal_approx(m.dish.bup_world_pos(tracked)), "...also when zooming")
	_drag(m, centre, Vector2(30, 0), MOUSE_BUTTON_MIDDLE)
	m.dish.sim.set_bup_pos(tracked, Vector2(100, 100))
	await process_frame
	await process_frame
	check(m.following_id == -1 and not m.camera.position.is_equal_approx(m.dish.bup_world_pos(tracked)), "panning by hand stops following")
	m.follow_button.pressed.emit()
	m.follow_button.pressed.emit()
	check(m.following_id == -1 and m.follow_button.text == "Follow", "the button toggles following off")
	m.follow_button.pressed.emit()
	var other: int = m.dish.add_bup(m.dish.global_position + Vector2(-50, -50), Genome.founder(), 30.0)
	m.dish.selected_id = other
	await process_frame
	await process_frame
	check(m.following_id == -1, "selecting another bup stops following the first")
	m.dish.selected_id = tracked
	m.follow_button.pressed.emit()
	m.dish.remove_bup(tracked)
	await process_frame
	await process_frame
	check(m.following_id == -1 and not m.follow_button.visible, "following ends when the bup dies")
	m.dish.remove_bup(other)
	m.dish.selected_id = -1
	m.toolbar.set_paused(false)
	m.camera.zoom = Vector2.ONE
	m.camera.position = m.dish.global_position

	# --- Renaming: a pencil by the name; Enter keeps the new name, Escape cancels it (and only that).
	var named_id: int = m.dish.add_bup(m.dish.global_position + Vector2(-30, 50), Genome.founder(), 30.0)
	m.dish.selected_id = named_id
	await process_frame
	await process_frame
	var default_label: String = m.name_row.name_label.text
	check(default_label == m.dish.bup_default_name(named_id) and default_label.contains("#%d" % named_id), "an unnamed bup shows its default name ('%s')" % default_label)
	m.name_row.rename_button.pressed.emit()
	check(m.name_row.editing and m.name_row.edit.visible and not m.name_row.name_label.visible and m.name_row.edit.placeholder_text == default_label, "the pencil opens a box to type a name, hinting the default")
	await _key(KEY_ESCAPE)
	check(not m.name_row.editing and m.dish.selected_id == named_id and not m.menu_open, "Escape while typing cancels only the typing")
	m.name_row.rename_button.pressed.emit()
	m.name_row.edit.text = "Finnigan"
	m.name_row.edit.text_submitted.emit("Finnigan")
	await process_frame
	check(m.dish.bup_name(named_id) == "Finnigan" and m.name_row.name_label.text == "Finnigan" and not m.name_row.editing, "Enter gives the bup the name ('%s')" % m.name_row.name_label.text)
	m.name_row.rename_button.pressed.emit()
	m.name_row.edit.text = "   "
	m.name_row.edit.text_submitted.emit("   ")
	check(m.dish.bup_name(named_id) == default_label, "an empty name goes back to the number")
	m.dish.remove_bup(named_id)
	m.dish.selected_id = -1
	await process_frame

	# --- The select tool's modes: each looks only at what it is named for and ignores the rest.
	m.dish.clear_bups()
	m.dish.sources.clear()
	m.camera.zoom = Vector2.ONE
	m.camera.position = m.dish.global_position
	var mode_spot: Vector2 = m.dish.global_position + Vector2(-70, 40)
	var mode_bup: int = m.dish.add_bup(mode_spot, Genome.founder(), 30.0)
	m.dish.place_source(mode_spot, 2.0)
	await process_frame
	await process_frame
	var heading := func() -> String: return m.info_text.get_parsed_text().get_slice("\n", 0)
	_hover_over(m, mode_spot)
	check(heading.call() == "NUTRIENT SOURCE", "Select all: a source over a bup shows the source ('%s')" % heading.call())
	picks[3].button_pressed = true
	_hover_over(m, mode_spot)
	check(m.dish.pick_mode == Dish.PickMode.SOURCES and heading.call() == "NUTRIENT SOURCE", "Nutrient sources: shows the source")
	_hover_over(m, m.dish.global_position + Vector2(120, -90))
	check(not m.info_panel.visible, "...and nothing over empty ground or a bup")
	picks[2].button_pressed = true
	_hover_over(m, mode_spot)
	check(m.name_row.visible and m.info_text.get_parsed_text().contains("generation") and m.dish.hovered_source == null, "Bups: shows the bup, not the source on top of it")
	_hover_over(m, m.dish.global_position + Vector2(120, -90))
	check(not m.info_panel.visible, "...and nothing over empty ground")
	picks[1].button_pressed = true
	_hover_over(m, mode_spot)
	check(heading.call() == "NUTRIENT" and m.dish.hovered_id == -1 and m.dish.hovered_source == null, "Background: the medium's readout even over a bup and a source ('%s')" % heading.call())
	m.dish.select_at(mode_spot)
	check(m.dish.selected_id == -1 and m.dish.selected_source == null, "...and clicking picks nothing")
	picks[2].button_pressed = true
	m.dish.select_at(mode_spot)
	check(m.dish.selected_id == mode_bup and m.dish.selected_source == null, "a click in Bups mode picks the bup")
	picks[3].button_pressed = true
	check(m.dish.selected_id == -1, "changing to a mode that doesn't look at bups lets go of the selected bup")
	m.dish.select_at(mode_spot)
	check(m.dish.selected_source != null and m.dish.selected_id == -1, "a click in Nutrient sources mode picks the source")
	picks[1].button_pressed = true
	check(m.dish.selected_source == null, "...and changing to Background lets go of it")
	picks[0].button_pressed = true
	m.dish.sources.clear()
	await process_frame

	# --- At high playback speed a readout's figures change at most a few times a second, but a new subject shows at once.
	m.toolbar.set_paused(false)
	m.toolbar.speed_1000_button.button_pressed = true
	var live_bup: int = m.dish.add_bup(mode_spot, Genome.founder(), 30.0)
	m.dish.place_source(m.dish.global_position + Vector2(80, 60), 2.0)
	var live_source: NutrientSource = m.dish.sources.back()
	var bare: Vector2 = m.dish.global_position + Vector2(-120, 90)
	_hover_over(m, bare)
	check(heading.call() == "NUTRIENT", "running at x1000, the medium's readout shows ('%s')" % heading.call())
	_hover_over(m, live_source.pos)
	check(heading.call() == "NUTRIENT SOURCE", "...and hovering a source switches the readout to it at once ('%s')" % heading.call())
	m.info_text.set_meta("set_at", Time.get_ticks_msec())
	var source_text: String = m.info_text.get_parsed_text()
	live_source.emitted += 500.0
	m._update_info_panel()
	check(m.info_text.get_parsed_text() == source_text, "...but the same source's figures don't rewrite within the live interval")
	m.info_text.set_meta("set_at", 0)
	m._update_info_panel()
	check(m.info_text.get_parsed_text() != source_text, "...and do once it has passed")
	_hover_over(m, mode_spot)
	check(m.name_row.visible and m.info_text.get_parsed_text().contains("generation"), "hovering a bup switches the readout to it at once")
	m.toolbar.set_paused(true)
	m.dish.clear_bups()
	m.dish.sources.clear()
	await process_frame

	# --- Lineage: a stack of views over the info. Escape goes back one step; anything else closes them all.
	m.dish.clear_bups()
	var grandmother: int = m.dish.add_bup(m.dish.global_position + Vector2(10, 10), Genome.founder(), 200.0, 4.0, 8.0, 0, Vector2.RIGHT)
	m.dish.step(1.0)  # she divides: a mother
	var mother := -1
	for id in m.dish.bup_ids():
		if id != grandmother:
			mother = id
	m.dish.sim.set_bup_energy(mother, 200.0)
	m.dish.selected_id = mother
	await process_frame
	await process_frame
	check(m.lineage_button.visible and m.lineage_button.tooltip_text == "Lineage" and not m.lineage_panel.visible, "the info panel has a Lineage button; the lineage is not open yet")
	m.lineage_button.pressed.emit()
	await process_frame
	await process_frame
	check(m.lineage_entries.get_child(0).get_child(1).text.contains("\nborn"), "each lineage entry has its name on one row and its times below, so nothing is cut off")
	check(m._concentration_text(0.002) == "125 units/mm²" and m._concentration_text(0.0000001) == "0.0 units/mm²" and m._concentration_text(0.00005) == "3.1 units/mm²", "concentration is shown in units per mm² (%s, %s)" % [m._concentration_text(0.002), m._concentration_text(0.00005)])
	check(m.lineage_panel.visible and not m.info_panel.visible and m.lineage_entries.get_child_count() == 2, "the lineage covers the info and lists the family line (%d entries)" % m.lineage_entries.get_child_count())
	check(m.lineage_entries.get_child(1).get_child(1).disabled and not m.lineage_entries.get_child(0).get_child(1).disabled, "the bup itself is marked, its ancestors can be clicked")
	var swatch_mother: ColorRect = m.lineage_entries.get_child(1).get_child(0)
	var swatch_grandmother: ColorRect = m.lineage_entries.get_child(0).get_child(0)
	check(swatch_mother.color.is_equal_approx(Genome.color_of(m.dish.lineage_info(mother))) and swatch_grandmother.color.is_equal_approx(Genome.color_of(m.dish.lineage_info(grandmother))), "each line of the lineage has a small square in that bup's colour")
	check(m.lineage_entries.get_child(0).get_child(1).text.begins_with(m.dish.bup_name(grandmother)), "entries use the bups' names ('%s')" % m.lineage_entries.get_child(0).get_child(1).text)
	await _drag(m, centre, Vector2(30, 0), MOUSE_BUTTON_MIDDLE)
	check(m.lineage_panel.visible and m._stack.size() == 2, "panning leaves the lineage as it is")
	m.lineage_entries.get_child(0).get_child(1).pressed.emit()
	await process_frame
	await process_frame
	check(m.dish.selected_id == grandmother and m.info_panel.visible and not m.lineage_panel.visible and m._stack.size() == 3, "clicking an ancestor shows her info (and selects her), not her lineage")
	m.lineage_button.pressed.emit()
	await process_frame
	check(m.lineage_panel.visible and m._stack.size() == 4, "her lineage can be opened in turn: the views nest")
	m.dish.remove_bup(grandmother)  # she dies while all this is open
	m.dish.remove_bup(mother)
	check(m.dish.has_record(grandmother) and m.dish.has_record(mother), "the bups on the stack are kept when they die")
	await _key(KEY_ESCAPE)
	await process_frame
	check(m.info_panel.visible and m.dish.selected_id == grandmother and m.info_text.get_parsed_text().contains("status: deceased") and m._stack.size() == 3, "Escape goes back one step: to her info, now showing she has died")
	await _key(KEY_ESCAPE)
	await process_frame
	check(m.lineage_panel.visible and m.dish.selected_id == mother and m._stack.size() == 2, "...then to the first lineage")
	await _key(KEY_ESCAPE)
	await process_frame
	check(m.info_panel.visible and m.dish.selected_id == mother and m._stack.size() == 1, "...then to the first info")
	await _key(KEY_ESCAPE)
	await process_frame
	check(m.dish.selected_id == -1 and m._stack.is_empty() and not m.info_panel.visible and not m.menu_open and not m.dish.has_record(grandmother) and not m.dish.has_record(mother), "the next Escape closes it all; nothing is kept now nothing needs it")
	# Anything outside the stack closes the lot, however deep.
	var kin_a: int = m.dish.add_bup(m.dish.global_position + Vector2(10, 10), Genome.founder(), 200.0, 4.0, 8.0, 0, Vector2.RIGHT)
	m.dish.step(1.0)
	var kin_b := -1
	for id in m.dish.bup_ids():
		if id != kin_a:
			kin_b = id
	m.dish.selected_id = kin_b
	await process_frame
	await process_frame
	m.lineage_button.pressed.emit()
	await process_frame
	await process_frame
	m.lineage_entries.get_child(0).get_child(1).pressed.emit()
	await process_frame
	check(m._stack.size() == 3, "(three steps deep)")
	m.toolbar.select_tool(Toolbar.Tool.NUTRIENT)
	await process_frame
	await process_frame
	check(m._stack.is_empty() and m.dish.selected_id == -1 and not m.lineage_panel.visible and not m.info_panel.visible, "choosing another tool closes every step and the info")
	m.toolbar.select_tool(Toolbar.Tool.SELECT)
	m.dish.selected_id = kin_b
	await process_frame
	m.lineage_button.pressed.emit()
	await process_frame
	var stranger: int = m.dish.add_bup(m.dish.global_position + Vector2(-90, 10), Genome.founder(), 30.0)
	m.dish.selected_id = stranger  # a different bup selected from outside the stack
	await process_frame
	await process_frame
	check(m._stack.size() == 1 and m.dish.selected_id == stranger and not m.lineage_panel.visible, "selecting another bup starts afresh on that bup")
	m.dish.selected_id = -1
	await process_frame
	check(m._stack.is_empty(), "no selection, no stack")
	m.dish.clear_bups()

	# --- Escape: lets go of a selection first, then opens the menu, then closes it again.
	m.dish.add_bup(m.dish.global_position + Vector2(40, 40), Genome.founder(), 30.0)
	var picked: int = m.dish.bup_ids()[0]
	m.dish.selected_id = picked
	m.following_id = picked
	await _key(KEY_ESCAPE)
	check(m.dish.selected_id == -1 and m.following_id == -1 and not m.menu_open and not m.pause_menu.visible, "Escape with something selected lets go of it and does not open the menu")
	m.dish.place_source(m.dish.global_position + Vector2(-60, 20), 2.0)
	m.dish.selected_source = m.dish.sources[0]
	await _key(KEY_ESCAPE)
	check(m.dish.selected_source == null and not m.menu_open, "...also for a selected source")
	await _key(KEY_ESCAPE)
	check(m.menu_open and m.pause_menu.visible, "with nothing selected, Escape opens the menu")
	var time_open: float = m.dish.time
	m.toolbar.set_paused(false)
	m._process(0.1)
	check(m.dish.time == time_open, "the game is frozen behind the menu")
	var trait_before: int = m.graph.trait_index
	await _key(KEY_T)
	check(m.graph.trait_index == trait_before, "keys don't reach the game behind the menu")
	await _key(KEY_ESCAPE)
	check(not m.menu_open and not m.pause_menu.visible, "a third Escape closes the menu")
	m._process(0.1)
	check(m.dish.time > time_open, "...and the game runs again")

	# --- The free-mode menu: enlarge the dish and change the bup limit, never below what exists.
	await _key(KEY_ESCAPE)
	check(m.pause_menu.settings.visible, "free mode's menu shows the dish settings")
	check(is_equal_approx(m.pause_menu.dish_row.slider.min_value, m.dish.radius / StartConditions.UM_PER_MM) and m.pause_menu.dish_row.slider.max_value == StartConditions.MAX_DISH_RADIUS / StartConditions.UM_PER_MM, "the dish radius can only grow (from %.0f)" % m.dish.radius)
	check(m.pause_menu.limit_row.slider.min_value >= m.dish.population() and m.pause_menu.limit_row.slider.max_value == StartConditions.MAX_BUP_LIMIT, "the bup limit can't go below the bups there are")
	var bups_then: int = m.dish.population()
	m.dish.field.deposit(Vector2(30, 30), 160.0)
	var nutrient_then := TestUtil.units(m.dish)
	var radius_then: float = m.dish.radius
	m.pause_menu.dish_row.slider.value = radius_then / StartConditions.UM_PER_MM + 0.5
	check(is_equal_approx(m.dish.radius, radius_then + 500.0) and m.dish.population() == bups_then, "choosing a larger dish enlarges it and keeps every bup")
	check(absf(TestUtil.units(m.dish) - nutrient_then) < 0.001 * maxf(nutrient_then, 1.0) + 0.01, "...and all the nutrient (%.2f then, %.2f now)" % [nutrient_then, TestUtil.units(m.dish)])
	m.pause_menu.limit_row.slider.value = m.pause_menu.limit_row.slider.min_value + 500.0
	check(m.dish.bup_limit == int(m.pause_menu.limit_row.slider.min_value) + 500, "choosing a limit changes it")
	await _key(KEY_ESCAPE)
	check(not m.menu_open, "Escape closes the free-mode menu too")
	m.dish.strike(start)  # back to the small dish the rest of the tests are laid out for
	m.camera.zoom = Vector2.ONE
	m.camera.position = m.dish.global_position

	# --- Tooltips, shortcuts, focus.
	var expected := {
		m.toolbar.select_button: "(S)", m.toolbar.pan_button: "(H)", m.toolbar.nutrient_button: "(N)",
		m.toolbar.zoom_in_button: "(+)", m.toolbar.zoom_out_button: "(-)", m.toolbar.pause_button: "(Space)",
		m.toolbar.speed_1_button: "(1)", m.toolbar.speed_100_button: "(2)", m.toolbar.speed_1000_button: "(3)",
	}
	for b in expected:
		check(b.tooltip_text.ends_with(expected[b]), "%s tooltip ends with %s, is '%s'" % [b.name, expected[b], b.tooltip_text])
		check(b.get_tooltip(Vector2.ZERO) == b.tooltip_text, "%s tooltip is shown as written" % b.name)
		check(b.focus_mode == Control.FOCUS_NONE, "%s doesn't take focus" % b.name)
		check(b.icon != null, "%s has an icon" % b.name)
	await _key(KEY_N)
	check(m.tool == Toolbar.Tool.NUTRIENT, "N key selects the nutrient tool")
	await _key(KEY_H)
	check(m.tool == Toolbar.Tool.PAN, "H key selects the pan tool")
	await _key(KEY_S)
	check(m.tool == Toolbar.Tool.SELECT, "S key selects the select tool")
	check(_exclusive(m.toolbar), "exactly one playback button is selected at the start")
	await _key(KEY_SPACE)
	check(m.paused and m.pause_ring.visible and _exclusive(m.toolbar) and m.toolbar.pause_button.button_pressed, "Space pauses, shows the ring, and only Pause is lit")
	await _key(KEY_SPACE)
	check(not m.paused and not m.pause_ring.visible and _exclusive(m.toolbar) and not m.toolbar.pause_button.button_pressed, "Space resumes, hides the ring, and Pause is no longer lit")
	m.toolbar.speed_100_button.button_pressed = true
	check(m.sim_speed == 100.0 and not m.paused and _exclusive(m.toolbar), "x100 plays at 100x")
	m.toolbar.pause_button.button_pressed = true
	check(m.paused and not m.toolbar.speed_100_button.button_pressed and _exclusive(m.toolbar), "clicking Pause deselects the speed button")
	m.toolbar.speed_100_button.button_pressed = true
	m.toolbar.pause_button.button_pressed = true
	await _key(KEY_SPACE)
	check(not m.paused and m.sim_speed == 100.0 and m.toolbar.speed_100_button.button_pressed and _exclusive(m.toolbar), "Space resumes at the last speed (x100)")
	m.toolbar.speed_1_button.button_pressed = true
	check(m.sim_speed == 1.0 and not m.paused and _exclusive(m.toolbar), "back to normal speed")
	m.toolbar.pause_button.button_pressed = true
	await _key(KEY_2)
	check(not m.paused and m.sim_speed == 100.0 and not m.pause_ring.visible and _exclusive(m.toolbar), "a speed key while paused resumes")
	m.toolbar.speed_1_button.button_pressed = true
	await _key(KEY_3)
	check(m.sim_speed == 1000.0, "3 key sets x1000")
	await _key(KEY_2)
	check(m.sim_speed == 100.0, "2 key sets x100")
	await _key(KEY_1)
	check(m.sim_speed == 1.0, "1 key sets x1")
	await _key(KEY_4)
	check(m.sim_speed == 10000.0 and _exclusive(m.toolbar) and m.toolbar.speed_ultra_button.button_pressed, "4 key sets the ultra speed, x10000")
	check(m.achieved_speed == 10000.0 and not m._playback_text().contains("running"), "a speed just chosen reads as itself, not as 'running slower'")
	m.achieved_speed = 4000.0
	check(m._playback_text() == "x10000 (running x4000)", "when the sim can't keep up the readout says what it achieves: '%s'" % m._playback_text())
	m.achieved_speed = 10000.0
	await _key(KEY_1)
	await _key(KEY_EQUAL)
	check(m.camera.zoom.x > 1.0, "= key zooms in")
	m.camera.zoom = Vector2.ONE
	await _key(KEY_EQUAL, true)
	check(m.camera.zoom.x > 1.0, "+ (shift+=) zooms in")
	await _key(KEY_MINUS)
	check(m.camera.zoom.x < 1.3, "- key zooms out")

	# --- Nutrient sources: place, select, edit the rate, erase, delete.
	m.dish.sources.clear()
	m.dish.clear_bups()
	m.camera.zoom = Vector2.ONE
	m.camera.position = m.dish.global_position
	await process_frame
	m.toolbar.select_tool(Toolbar.Tool.SOURCE)
	check(m.tool == Toolbar.Tool.SOURCE and m.tool_options.visible and m.tool_options.source_rate_box.is_visible_in_tree(), "the source tool shows its rate box")
	check(m.tool_options.source_rate_box.get_line_edit().get_tooltip(Vector2.ZERO) == "Nutrients per minute", "hovering the rate box says what it is")
	m.tool_options.source_rate_box.value = 12.5
	spot = m.dish.global_position + Vector2(80, 20)
	_click(m, _screen(m, spot))
	check(m.dish.sources.size() == 1 and absf(m.dish.sources[0].rate - 12.5) < 0.01 and m.dish.sources[0].pos.distance_to(spot) < 0.5, "a click places a source with the chosen rate")
	check(m.tool == Toolbar.Tool.SELECT and m.dish.selected_source == m.dish.sources[0] and m.dish.selected_id == -1, "placing a source switches to the select tool with that source selected")
	var field_before: float = TestUtil.units(m.dish)
	m.dish.advance(60.0)
	check(absf(TestUtil.units(m.dish) - field_before - 12.5) < 0.5, "a source keeps releasing nutrient into the medium at its rate (%.1f units in 1 min)" % (TestUtil.units(m.dish) - field_before))
	_click(m, _screen(m, m.dish.global_position + Vector2(900, 900)))
	check(m.dish.sources.size() == 1, "a click outside the dish places no source")
	m.toolbar.select_tool(Toolbar.Tool.SELECT)
	_click(m, _screen(m, spot + Vector2(3, 2)))
	await process_frame
	await process_frame
	check(m.dish.selected_source == m.dish.sources[0] and m.info_panel.visible and m.info_text.get_parsed_text().begins_with("NUTRIENT SOURCE"), "the select tool selects a source and shows its box")
	check(m.source_rate_row.is_visible_in_tree() and m.delete_source_button.is_visible_in_tree(), "a selected source has a rate row and a delete button")
	check(is_equal_approx(m.source_rate_row.value, 12.5), "the rate row shows the source's rate (%.1f)" % m.source_rate_row.value)
	m.source_rate_row.value = 20
	check(is_equal_approx(m.dish.sources[0].rate, 20.0), "changing the row changes the source's rate")
	m.dish.place_source(m.dish.global_position + Vector2(-90, 0), 7.5)
	_click(m, _screen(m, m.dish.global_position + Vector2(-90, 0)))
	await process_frame
	check(is_equal_approx(m.dish.sources[1].rate, 7.5) and is_equal_approx(m.dish.sources[0].rate, 20.0), "selecting another source shows its rate without changing either")
	m.delete_source_button.pressed.emit()
	await process_frame
	check(m.dish.sources.size() == 1 and m.dish.sources[0].pos.distance_to(spot) < 0.5 and m.dish.selected_source == null and not m.source_rate_row.is_visible_in_tree(), "the delete button removes the selected source")
	m.dish.selected_source = m.dish.sources[0]
	await _key(KEY_DELETE)
	check(m.dish.sources.is_empty(), "the Delete key removes the selected source")
	# The eraser takes nutrient out of the medium under its brush.
	m.toolbar.set_paused(true)
	m.dish.field.reset(m.dish.radius)
	m.dish.field.fill(800.0)
	m.toolbar.select_tool(Toolbar.Tool.ERASE)
	check(m.tool_options.visible and m.tool_options.brush_size_box.is_visible_in_tree(), "the eraser shows its brush size")
	check(m.tool_options.brush_size_box.get_line_edit().get_tooltip(Vector2.ZERO) == "Brush radius", "hovering the brush size says what it is")
	m.tool_options.brush_size_box.value = 40
	check(m.tool_options.brush_radius() == 40.0, "the brush radius is the box's value")
	var wiped: Vector2 = spot - m.dish.global_position
	var before_erase: float = m.dish.field.sample(wiped)
	_click(m, _screen(m, spot))
	check(m.dish.field.sample(wiped) < before_erase * 0.25, "a click wipes most of the nutrient under the brush")
	check(m.dish.field.sample(wiped + Vector2(38, 0)) > m.dish.field.sample(wiped), "...less towards its edge")
	check(absf(m.dish.field.sample(wiped + Vector2(120, 0)) - before_erase) < before_erase * 0.02, "...and none outside it")
	_click(m, centre + Vector2(900, 0))
	check(absf(m.dish.field.sample(wiped + Vector2(120, 0)) - before_erase) < before_erase * 0.02, "erasing outside the dish does nothing")
	m.toolbar.set_paused(false)
	for i in Dish.MAX_SOURCES + 3:
		m.dish.place_source(m.dish.global_position + Vector2(i * 10 - 100, 150), 5.0)
	check(m.dish.sources.size() == Dish.MAX_SOURCES, "the dish holds at most %d sources" % Dish.MAX_SOURCES)
	m.dish.sources.clear()
	m.toolbar.select_tool(Toolbar.Tool.SELECT)

	# Goal mode starts running, but pausing shows the same ring.
	m.queue_free()
	await process_frame
	Session.mode = Session.Mode.GOALS
	Session.load_requested = false
	var g: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(g)
	await process_frame
	check(not g.paused and not g.pause_ring.visible, "goal mode starts running, no ring")
	check(_exclusive(g.toolbar) and g.toolbar.speed_1_button.button_pressed, "goal mode start: only Play is lit")
	# Escape in goal mode: the menu has no dish settings, and quitting saves.
	var quits := [0]
	g.pause_menu.quit_requested.disconnect(g._quit_to_menu)  # (so the test isn't taken back to the title screen)
	g.pause_menu.quit_requested.connect(func() -> void: quits[0] += 1)
	await _key(KEY_ESCAPE)
	check(g.menu_open and g.pause_menu.visible and not g.pause_menu.settings.visible, "goal mode's menu opens on Escape without dish settings")
	check(g.pause_menu.quit_button.text == "Save and Quit to Menu", "...and says quitting saves")
	g.pause_menu.quit_button.pressed.emit()
	check(quits[0] == 1, "quitting from goal mode doesn't ask first")
	await _key(KEY_ESCAPE)
	check(not g.menu_open, "Escape closes it")
	g.toolbar.set_paused(true)
	check(g.paused and g.pause_ring.visible, "goal mode pause shows the ring too")
	for locked_tool in [Toolbar.Tool.NUTRIENT, Toolbar.Tool.SOURCE, Toolbar.Tool.ERASE]:
		check(g.toolbar.button_for(locked_tool).disabled, "goal 1 locks the nutrient tools")
	check(not g.toolbar.button_for(Toolbar.Tool.SELECT).disabled and not g.toolbar.button_for(Toolbar.Tool.PAN).disabled, "...but not select or pan")
	check(g.toolbar.source_button.tooltip_text.contains("unlocks with experiment 2"), "a locked tool says why")
	g.tracker.index = 1
	g._sync_tool_locks()
	for locked_tool in [Toolbar.Tool.NUTRIENT, Toolbar.Tool.SOURCE, Toolbar.Tool.ERASE]:
		check(not g.toolbar.button_for(locked_tool).disabled, "experiment 2 unlocks the nutrient tools")
	g.toolbar.select_tool(Toolbar.Tool.SOURCE)
	g.tracker.index = 0
	g._sync_tool_locks()
	check(g.tool == Toolbar.Tool.SELECT, "locking the selected tool falls back to select")
	g.queue_free()
	Session.mode = Session.Mode.GOALS

	if failures.is_empty():
		print("TOOLBAR TESTS OK")
	else:
		print("FAILED:")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)



## True when exactly one of Pause / x1 / x100 / x1,000 / x10,000 is selected.
func _exclusive(toolbar: Toolbar) -> bool:
	var lit := 0
	for b in [toolbar.pause_button, toolbar.speed_1_button, toolbar.speed_100_button, toolbar.speed_1000_button, toolbar.speed_ultra_button]:
		if b.button_pressed:
			lit += 1
	return lit == 1
