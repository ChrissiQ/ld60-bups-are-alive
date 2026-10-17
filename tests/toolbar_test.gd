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
	check(m.tool == Toolbar.Tool.INFO, "default tool is info")
	check(m.tool == m.toolbar.current_tool(), "the screen's tool and the toolbar's selection agree from the start")
	for t in Toolbar.Tool.values():
		check(m.toolbar.button_for(t) != null, "the toolbar has a button for tool %d" % t)
	check(m.tool_options.toolbar == m.toolbar, "the options tray is wired to its toolbar by export, not by a hard-coded path")
	m.toolbar.select_tool(Toolbar.Tool.PAN)
	check(m.toolbar.current_tool() == Toolbar.Tool.PAN and m.tool == Toolbar.Tool.PAN, "current_tool() follows the selection")
	m.toolbar.select_tool(Toolbar.Tool.INFO)
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

	# --- Nutrient tool: click places, drag pans.
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
	check(m.dish.food.size() == 1, "click places one nutrient, got %d" % m.dish.food.size())
	check(m.dish.food.size() == 1 and m.dish.food[0].is_equal_approx(_world(m, p)), "...exactly where clicked")
	_click(m, centre + Vector2(900, 0))
	check(m.dish.food.size() == 1, "click outside the dish places nothing")
	m.tool_options.nutrient_count_box.value = 30
	_click(m, p)
	check(m.dish.food.size() == 31, "count 30 places 30 more, got %d" % m.dish.food.size())
	await process_frame
	await process_frame
	check(m.dish.nutrients_placed == 31, "dish counted 31 placed, got %d" % m.dish.nutrients_placed)
	check(m.hud.get_parsed_text().contains("PLACED  31"), "the readout shows the placed count: '%s'" % m.hud.get_parsed_text().get_slice("\n", 3))
	check(m.hud.get_theme_font("normal_font") is FontFile and m.hud.get_theme_font("normal_font").resource_path.begins_with("res://fonts/CommitMono"), "HUD text uses the bundled font")
	for node in [m.hud, m.goal_panel, m.info_text, m.stats_panel]:
		check(node.mouse_filter == Control.MOUSE_FILTER_IGNORE, "%s doesn't swallow clicks" % node.name)

	var before: int = m.dish.food.size()
	var cam_before: Vector2 = m.camera.position
	_drag(m, centre, Vector2(60, 0))
	check(m.dish.food.size() == before, "a drag must not place nutrients")
	check(is_equal_approx(m.camera.position.x, cam_before.x - 60.0 / m.camera.zoom.x), "drag pans the camera by the pointer distance (%.1f)" % (m.camera.position.x - cam_before.x))
	cam_before = m.camera.position
	_button(m, MOUSE_BUTTON_LEFT, true, centre)
	_motion(m, centre + Vector2(3, 0), Vector2(3, 0))  # under the drag threshold
	_button(m, MOUSE_BUTTON_LEFT, false, centre + Vector2(3, 0))
	check(m.dish.food.size() > before, "a tiny wobble is still a click")
	check(m.camera.position.is_equal_approx(cam_before), "...and doesn't pan")

	# --- Pan tool: dragging pans, clicking does nothing.
	m.toolbar.select_tool(Toolbar.Tool.PAN)
	check(not m.tool_options.visible and not m.tool_options.nutrient_count_box.is_visible_in_tree(), "pan tool has no options, so no number box")
	check(m.toolbar.theme_type_variation == &"ToolbarPanel", "toolbar is a closed rounded bar again with no tray")
	before = m.dish.food.size()
	_click(m, centre)
	check(m.dish.food.size() == before, "click with pan tool does nothing")
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
	m.toolbar.select_tool(Toolbar.Tool.INFO)

	# --- Info tool: click selects, empty click deselects, middle button pans.
	m.toolbar.select_tool(Toolbar.Tool.INFO)
	check(not m.tool_options.visible, "info tool has no options either")
	var bup: Cell = m.dish.cells[0]
	bup.pos = m.dish.global_position + Vector2(20, 10)
	_click(m, centre + Vector2(20, 10))
	check(m.dish.selected == bup, "info click selects the bup")
	await process_frame
	await process_frame  # process_frame fires before nodes' _process, so allow a full frame
	check(m.info_panel.visible and m.info_text.get_parsed_text().contains("BUP"), "info panel shows the selected bup")
	_click(m, centre + Vector2(-250, -250))
	check(m.dish.selected == null, "clicking empty space deselects")
	m.dish.selected = bup
	cam_before = m.camera.position
	_drag(m, centre, Vector2(30, 0), MOUSE_BUTTON_MIDDLE)
	check(not m.camera.position.is_equal_approx(cam_before), "middle-button drag pans in any tool")
	check(m.dish.selected == bup, "...without changing the selection")
	m.dish.cells.erase(bup)
	await process_frame
	await process_frame
	check(m.dish.selected == null and not m.info_panel.visible, "selection clears when the bup dies")
	m.camera.position = m.dish.global_position

	# --- A long frame can't snowball: the sim catches up on at most MAX_FRAME_SECONDS.
	m.toolbar.speed_8_button.button_pressed = true
	var sim_before: float = m.dish.time
	m._process(5.0)
	var caught_up: float = m.dish.time - sim_before
	check(caught_up <= m.MAX_FRAME_SECONDS * 8.0 + 0.05 and caught_up > 0.5, "a 5s hitch at x8 advances the sim by %.2fs, not 40s" % caught_up)
	m.toolbar.speed_1_button.button_pressed = true

	# --- Readout: playback speed is its own labelled line, not a suffix on the time.
	m.toolbar.set_paused(false)
	m.toolbar.speed_1_button.button_pressed = true
	await process_frame
	await process_frame
	var readout: String = m.hud.get_parsed_text()
	check(readout.contains("PLAYBACK  x1") and not readout.contains("(x"), "readout shows 'PLAYBACK  x1' on its own line and no '(x..)' after the time: '%s'" % readout.get_slice("\n", 1))
	check(readout.get_slice("\n", 1).begins_with("TIME  ") and not readout.get_slice("\n", 1).contains("x"), "the TIME line is just the time")
	m.toolbar.speed_8_button.button_pressed = true
	await process_frame
	await process_frame
	check(m.hud.get_parsed_text().contains("PLAYBACK  x8"), "speed 8 reads 'PLAYBACK  x8'")
	m.toolbar.set_paused(true)
	await process_frame
	await process_frame
	check(m.hud.get_parsed_text().contains("PLAYBACK  paused") and not m.hud.get_parsed_text().contains("[PAUSED]"), "paused reads 'PLAYBACK  paused'")
	m.toolbar.speed_1_button.button_pressed = true  # resume at normal speed

	# --- Info tool on a nutrient.
	m.toolbar.select_tool(Toolbar.Tool.INFO)
	m.dish.cells.clear()
	m.dish.food.clear()
	var pellet: Vector2 = m.dish.global_position + Vector2(-70, 40)
	m.dish.food.append(pellet)
	await process_frame  # the camera only applies its position to the view on the next frame
	await process_frame
	_click(m, _screen(m, pellet))
	check(m.dish.has_selected_food() and m.dish.selected_food == pellet, "info click selects the nutrient")
	await process_frame
	await process_frame
	var pellet_text: String = m.info_text.get_parsed_text()
	check(m.info_panel.visible and pellet_text.begins_with("NUTRIENT"), "info panel shows the nutrient (title)")
	check(pellet_text.contains("energy  12") and pellet_text.contains("position  -70, 40") and pellet_text.contains("nearest bup  none") and pellet_text.contains("sensed by  0 bups"), "nutrient details are shown: '%s'" % pellet_text.replace("\n", " | "))
	m.toolbar.set_paused(true)  # keep the bup still so the distances are exact
	m.dish.cells.append(Cell.new(pellet + Vector2(20, 0), Genome.founder(), 30.0))
	await process_frame
	await process_frame
	check(m.info_text.get_parsed_text().contains("nearest bup  20 away") and m.info_text.get_parsed_text().contains("sensed by  1 bup"), "details update live: '%s'" % m.info_text.get_parsed_text().replace("\n", " | "))
	m.dish.food.erase(pellet)  # a bup ate it
	await process_frame
	await process_frame
	check(not m.dish.has_selected_food() and not m.info_panel.visible, "the selection clears when the nutrient is eaten")
	m.dish.food.append(pellet)
	m.toolbar.select_tool(Toolbar.Tool.NUTRIENT)
	_click(m, _screen(m, pellet))
	check(not m.dish.has_selected_food(), "the nutrient tool places food; it doesn't select")
	m.toolbar.select_tool(Toolbar.Tool.INFO)
	m.dish.select_at(pellet)
	_click(m, _screen(m, m.dish.global_position + Vector2(-200, -200)))
	check(not m.dish.has_selected_food() and m.dish.selected == null, "clicking empty space deselects")
	m.toolbar.set_paused(false)
	m.dish.food.clear()
	m.dish.cells.clear()
	for i in 4:
		m.dish.cells.append(Cell.new(m.dish.global_position + Vector2(100 + i * 10, 100), Genome.founder(), 30.0))

	# --- Zoom.
	m.camera.zoom = Vector2.ONE
	_button(m, MOUSE_BUTTON_WHEEL_UP, true, centre)
	check(m.camera.zoom.x > 1.0, "wheel up zooms in")
	_button(m, MOUSE_BUTTON_WHEEL_DOWN, true, centre)
	check(is_equal_approx(m.camera.zoom.x, 1.0), "wheel down zooms back out")
	m.camera.zoom = Vector2.ONE
	m.toolbar.zoom_in_button.pressed.emit()
	check(is_equal_approx(m.camera.zoom.x, Main_zoom_step()), "zoom-in button steps zoom")
	for i in 100:
		_button(m, MOUSE_BUTTON_WHEEL_UP, true, centre)
	check(m.camera.zoom.x == m.ZOOM_MAX, "zoom clamps at max")
	for i in 200:
		_button(m, MOUSE_BUTTON_WHEEL_DOWN, true, centre)
	check(m.camera.zoom.x == m.ZOOM_MIN, "zoom clamps at min")
	m.camera.zoom = Vector2.ONE

	# --- Tooltips, shortcuts, focus.
	var expected := {
		m.toolbar.info_button: "(I)", m.toolbar.pan_button: "(H)", m.toolbar.nutrient_button: "(N)",
		m.toolbar.zoom_in_button: "(+)", m.toolbar.zoom_out_button: "(-)", m.toolbar.pause_button: "(Space)",
		m.toolbar.speed_1_button: "(1)", m.toolbar.speed_3_button: "(2)", m.toolbar.speed_8_button: "(3)",
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
	await _key(KEY_I)
	check(m.tool == Toolbar.Tool.INFO, "I key selects the info tool")
	check(_exclusive(m.toolbar), "exactly one playback button is selected at the start")
	await _key(KEY_SPACE)
	check(m.paused and m.pause_ring.visible and _exclusive(m.toolbar) and m.toolbar.pause_button.button_pressed, "Space pauses, shows the ring, and only Pause is lit")
	await _key(KEY_SPACE)
	check(not m.paused and not m.pause_ring.visible and _exclusive(m.toolbar) and not m.toolbar.pause_button.button_pressed, "Space resumes, hides the ring, and Pause is no longer lit")
	m.toolbar.speed_3_button.button_pressed = true
	check(m.sim_speed == 3.0 and not m.paused and _exclusive(m.toolbar), "x3 plays at 3x")
	m.toolbar.pause_button.button_pressed = true
	check(m.paused and not m.toolbar.speed_3_button.button_pressed and _exclusive(m.toolbar), "clicking Pause deselects the speed button")
	m.toolbar.speed_3_button.button_pressed = true
	m.toolbar.pause_button.button_pressed = true
	await _key(KEY_SPACE)
	check(not m.paused and m.sim_speed == 3.0 and m.toolbar.speed_3_button.button_pressed and _exclusive(m.toolbar), "Space resumes at the last speed (x3)")
	m.toolbar.speed_1_button.button_pressed = true
	check(m.sim_speed == 1.0 and not m.paused and _exclusive(m.toolbar), "back to normal speed")
	m.toolbar.pause_button.button_pressed = true
	await _key(KEY_2)
	check(not m.paused and m.sim_speed == 3.0 and not m.pause_ring.visible and _exclusive(m.toolbar), "a speed key while paused resumes")
	m.toolbar.speed_1_button.button_pressed = true
	await _key(KEY_3)
	check(m.sim_speed == 8.0, "3 key sets x8")
	await _key(KEY_2)
	check(m.sim_speed == 3.0, "2 key sets x3")
	await _key(KEY_1)
	check(m.sim_speed == 1.0, "1 key sets x1")
	await _key(KEY_EQUAL)
	check(m.camera.zoom.x > 1.0, "= key zooms in")
	m.camera.zoom = Vector2.ONE
	await _key(KEY_EQUAL, true)
	check(m.camera.zoom.x > 1.0, "+ (shift+=) zooms in")
	await _key(KEY_MINUS)
	check(m.camera.zoom.x < 1.3, "- key zooms out")

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
	g.toolbar.set_paused(true)
	check(g.paused and g.pause_ring.visible, "goal mode pause shows the ring too")
	g.queue_free()
	Session.mode = Session.Mode.GOALS

	if failures.is_empty():
		print("TOOLBAR TESTS OK")
	else:
		print("FAILED:")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)


func Main_zoom_step() -> float:
	return 1.25


## True when exactly one of Pause / x1 / x3 / x8 is selected.
func _exclusive(toolbar: Toolbar) -> bool:
	var lit := 0
	for b in [toolbar.pause_button, toolbar.speed_1_button, toolbar.speed_3_button, toolbar.speed_8_button]:
		if b.button_pressed:
			lit += 1
	return lit == 1
