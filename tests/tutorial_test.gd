extends SceneTree
## Run: godot --headless --path . -s tests/tutorial_test.gd
## The guided tour: it starts when asked, holds the game, lights something real at each step, waits for what it asks,
## can be skipped at any time, and leaves the screen as it found it.


func check(ok: bool, what: String) -> void:
	TestUtil.check(ok, what)


func _screen(mode: Session.Mode, wanted: bool) -> Node:
	Session.mode = mode
	Session.free_start = TestUtil.small_start()
	Session.tutorial_wanted = wanted
	var m: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	await process_frame
	await process_frame
	return m


func _init() -> void:

	# Not asked for: nothing happens.
	var quiet: Node = await _screen(Session.Mode.FREE, false)
	check(not quiet.tutorial.active and not quiet.tutorial.visible, "no tour unless it is asked for")
	quiet.queue_free()

	# Free mode, walked from the first step to the last.
	var m: Node = await _screen(Session.Mode.FREE, true)
	var tour: Tutorial = m.tutorial
	check(tour.active and tour.visible and not Session.tutorial_wanted, "the tour starts when asked, and the request is used up")
	check(m.paused and tour.blocking and tour.index == 0, "it holds the game and starts by being read")
	check(tour.skip_button.visible and tour.next_button.visible and tour.next_button.text == "Next", "Skip and Next are there")
	var view: Vector2 = m.get_viewport_rect().size
	var was_zoom: Vector2 = m.camera.zoom
	var seen_steps := 0
	var guard := 0
	while tour.active and guard < 40:
		guard += 1
		var step: Dictionary = tour._steps[tour.index]
		var key: String = step["text"]
		await process_frame
		var hole: Rect2 = tour.target_rect()
		var lit := hole.has_area()
		var card_rect := Rect2(tour.card.position, tour.card.size)
		check(Rect2(Vector2.ZERO, view).encloses(card_rect), "step %d: the card is on the screen" % (tour.index + 1))
		check(tour.title_label.text != "" and tour.title_label.text.length() < 20, "step %d: it has a short title (%s)" % [tour.index + 1, tour.title_label.text])
		check(tour.text_label.text == key and key.length() > 10 and key.length() < 260, "step %d: it says something short (%d characters)" % [tour.index + 1, key.length()])
		if lit:
			check(hole.size.x > 10.0 and hole.size.y > 10.0 and Rect2(Vector2.ZERO, view).grow(1.0).intersects(hole), "step %d: it lights a real part of the screen (%s)" % [tour.index + 1, hole])
			check(not card_rect.intersects(hole.grow(Tutorial.SPOT_PAD - 1.0)), "step %d: the card does not cover what it lights" % (tour.index + 1))
		var wait: Callable = step["wait"]
		if wait.is_valid():
			check(not tour.blocking and tour.next_button.visible and tour.next_button.disabled and tour.waiting_label.visible and tour.waiting_label.text == "Try it", "step %d asks for something: Next is there but shut, and it says Try it" % (tour.index + 1))
			check(tour.waiting_label.get_index() < tour.card.get_node("Box/Actions").get_index(), "step %d: Try it is on its own line above the buttons" % (tour.index + 1))
			check(tour.mouse_filter == Control.MOUSE_FILTER_IGNORE and tour.scrims[0].mouse_filter == Control.MOUSE_FILTER_STOP and tour.scrims[3].mouse_filter == Control.MOUSE_FILTER_STOP, "step %d: the dimming takes every click but those on what is lit" % (tour.index + 1))
			check(m.paused, "the game stays held on a step that asks for something")
			var before: int = tour.index
			tour.next()
			check(tour.index == before, "Next does nothing while step %d is not done" % (before + 1))
			if tour.index > 0 and "bup" in key and "Click" in key:
				check(m.camera.zoom.x > was_zoom.x, "the step that asks for a click on a bup has the camera close to it")
				var spot: Vector2 = m.dish.bup_world_pos(m._tutorial_bup)
				m.dish.select_at(spot, 2.0)
			elif "eye" in key:
				m._toggle_watch()
			elif "family tree" in key:
				m._open_lineage()
			elif "back arrow" in key:
				check(step.get("escape_passes", false), "the lineage step lets Escape through to close it")
				check(m._lineage_is_open(), "the lineage step has the lineage open")
				m._step_back()
			await process_frame
			await process_frame
			check(tour.index == before + 1, "doing what step %d asks goes straight on to the next" % (before + 1))
		else:
			check(tour.blocking and tour.mouse_filter == Control.MOUSE_FILTER_STOP and tour.next_button.visible, "step %d is read: it holds the clicks and has Next" % (tour.index + 1))
			if tour.index == tour._steps.size() - 1:
				check(tour.next_button.text == "Done", "the last step says Done")
			tour.next()
		seen_steps += 1
	check(not tour.active and not tour.visible, "the tour ends after the last step")
	check(seen_steps == 16, "a free-mode tour has 16 steps (%d)" % seen_steps)
	check(m.paused and m.dish.selected_id < 0 and not m.dish.is_watched(m._tutorial_bup) and m.camera.zoom.is_equal_approx(was_zoom) and m.camera.position.is_equal_approx(m.dish.global_position), "afterwards it is paused as before, with nothing selected or watched and the camera where it was")
	await process_frame
	await process_frame
	check(m.dish.watched.is_empty() and m._stack.is_empty() and not m.watch_panel.visible and not m.info_panel.visible, "and the panels the tour opened are shut again")
	m.queue_free()

	# Space, Enter and Back; and what a step asks for cannot be spoiled by clicks or keys elsewhere.
	var n: Node = await _screen(Session.Mode.FREE, true)
	var nt: Tutorial = n.tutorial
	check(not nt.back_button.visible, "there is no Back on the first step")
	for code in [KEY_SPACE, KEY_ENTER, KEY_RIGHT]:
		var press := InputEventKey.new()
		press.keycode = code
		press.pressed = true
		var before := nt.index
		nt._input(press)
		check(nt.index == before + 1, "key %s goes on a step" % OS.get_keycode_string(code))
	check(nt.back_button.visible and nt.back_button.text == "Back", "later steps have Back")
	nt.back_button.pressed.emit()
	check(nt.index == 2, "Back goes one step back")
	var left := InputEventKey.new()
	left.keycode = KEY_LEFT
	left.pressed = true
	nt._input(left)
	check(nt.index == 1, "so does the left arrow")
	while nt.index < 9:
		nt.next()
	check(not nt.blocking, "on the click step")
	var tool_key := InputEventKey.new()
	tool_key.keycode = KEY_H
	tool_key.pressed = true
	nt._input(tool_key)
	check(n.tool == Toolbar.Tool.SELECT, "a tool key does nothing while the tour waits for a click (the tool stays Inspect)")
	check(nt.index == 9 and nt.next_button.disabled, "Next is shut until the click is made")
	n.dish.select_at(n.dish.bup_world_pos(n._tutorial_bup), 2.0)
	await process_frame
	await process_frame
	check(nt.index == 10, "making the click goes straight on")
	nt.next()
	check(nt.index == 11 and nt.next_button.disabled, "the watch step is shut until the eye is pressed")
	n._toggle_watch()
	await process_frame
	await process_frame
	check(nt.index == 12, "pressing the eye goes straight on to the watch list")
	nt.back_button.pressed.emit()
	await process_frame
	check(nt.index == 11 and not nt.next_button.disabled and nt.text_label.text.contains("eye"), "Back shows the watch step again, with Next open because the bup is still watched")
	nt.back_button.pressed.emit()
	nt.back_button.pressed.emit()
	await process_frame
	check(nt.index == 9 and not nt.next_button.disabled, "and the click step too, with Next open because the bup is still selected (it does not go on again by itself)")
	n.dish.clear_selection()
	await process_frame
	check(nt.index == 9 and nt.next_button.disabled, "if the bup is let go, Next is shut again")
	nt.skip()
	await process_frame
	check(n.dish.watched.is_empty(), "skipping takes the bup the tour had watched off the list again")
	n.queue_free()

	# Skipped part-way.
	var s: Node = await _screen(Session.Mode.FREE, true)
	s.tutorial.next()
	s.tutorial.next()
	check(s.tutorial.index == 2, "Next goes on one step")
	s.tutorial.skip_button.pressed.emit()
	await process_frame
	check(not s.tutorial.active and not s.tutorial.visible and s.paused, "Skip ends the tour at once")
	s.queue_free()

	# Skipped on a step that asked for something, after the view was changed for it.
	var t: Node = await _screen(Session.Mode.FREE, true)
	while t.tutorial.index < 9:
		t.tutorial.next()
	await process_frame
	check(t.camera.zoom.x > was_zoom.x, "on the step that asks for a click the camera is close")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	t.tutorial._input(escape)
	await process_frame
	check(not t.tutorial.active and t.camera.zoom.is_equal_approx(was_zoom) and t.dish.selected_id < 0, "Escape skips it from there, and the camera goes back")
	check(not t.menu_open, "and does not also open the menu")
	t.queue_free()

	# Goal mode: the goal's own step is there, and a game that was playing plays again afterwards.
	var g: Node = await _screen(Session.Mode.GOALS, true)
	check(g.tutorial.active and g.tutorial._steps.size() == 17, "goal mode's tour has the goal step as well (%d steps)" % g.tutorial._steps.size())
	check(g.tutorial._steps[3]["text"].begins_with("Your experiment") and g.tutorial._steps[6]["text"].contains("experiment 2"), "it explains the goal and that the nutrient tools unlock later")
	check(g.paused, "goal mode is held for the tour")
	g.tutorial.skip()
	await process_frame
	check(not g.paused, "a game that was running runs again when the tour ends")
	g.queue_free()

	# The saved start conditions and the setup toggle.
	var c := StartConditions.new()
	c.tutorial = true
	check(StartConditions.from_dict(c.to_dict()).tutorial and not StartConditions.new().tutorial and not StartConditions.from_dict({"tutorial": "yes"}).tutorial, "the setup's tutorial choice is saved and defaults to off")
	Session.free_start = StartConditions.new()
	var setup: Node = load("res://scenes/free_setup.tscn").instantiate()
	root.add_child(setup)
	await process_frame
	check(setup.tutorial_toggle.text == "Tutorial: off", "free setup starts with the tutorial off")
	setup.tutorial_toggle.button_pressed = true
	check(setup._start.tutorial and setup.tutorial_toggle.text == "Tutorial: on", "its toggle turns the tutorial on")
	setup._reset_to_defaults()
	check(not setup._start.tutorial, "and reset turns it off")
	setup.queue_free()

	Session.mode = Session.Mode.GOALS
	TestUtil.finish(self, "TUTORIAL TESTS OK")
