extends SceneTree
## Run: godot --headless --path . -s tests/dishes_test.gd
## Several dishes on the game screen (free mode): a second dish runs beside the main one, has a thumbnail in the strip, and a click on it brings it into the
## main view (the graph, the panels and the camera follow); a restart lets the others go.


func check(ok: bool, what: String) -> void:
	TestUtil.check(ok, what)


func _init() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var chosen := TestUtil.small_start()
	chosen.bups = 40
	chosen.nutrient_density = 40
	Session.free_start = chosen
	Session.mode = Session.Mode.FREE
	Session.load_requested = false
	var m: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	var first: Dish = m.dish
	check(m.dishes.size() == 1 and not m.dish_strip.visible, "one dish: no strip")
	m.toolbar.set_paused(false)
	var other: Dish = m.add_dish(chosen)
	check(m.dishes.size() == 2 and m.dish == first and m.dish_strip.visible and m.dish_strip.count() == 2, "a second dish joins the set and shows in the strip; the main view stays")
	check(other.global_position.distance_to(first.global_position) >= m.DISH_SPACING, "it is far from the first in the shared world")
	var t0 := other.time
	var t1 := first.time
	for i in 30:
		await process_frame
	check(other.time > t0 and first.time > t1, "both dishes run (%.1f and %.1f s)" % [other.time - t0, first.time - t1])
	check(other.population() > 0, "the other dish has bups")
	check(absf(other.time - first.time) <= m.sim_speed / 60.0 + 1.0, "the dishes keep one clock (%.1f and %.1f s)" % [other.time, first.time])
	var turns := []
	for round in 4:
		m._let_one_dish_switch()
		turns.append(m.dishes.filter(func(d: Dish) -> bool: return d.switch_allowed).size())
	check(turns == [1, 1, 1, 1], "exactly one dish at a time may change backend (%s)" % [turns])
	m.set_main_dish(other)
	check(m.dish == other and m.graph.dish == other and m.watch_panel.dish == other, "a choice brings the other dish into the main view, with the graph and the watch list")
	check(m.camera.position.distance_to(other.global_position) < 1.0, "the camera is on it")
	m.dish_strip.dish_chosen.emit(first)
	check(m.dish == first and m.camera.position.distance_to(first.global_position) < 1.0, "the strip's click brings the first back")
	m._restart()
	await process_frame
	check(m.dishes.size() == 1 and m.dish == first and not m.dish_strip.visible, "a restart lets the others go")
	# The pipette: the bups in the circle move to a new dish, the rest stay.
	first.clear_bups()
	for i in 10:
		first.add_bup(first.global_position + Vector2(i * 4.0, 0.0), Genome.founder(), 30.0)
	for i in 5:
		first.add_bup(first.global_position + Vector2(200.0 + i, 100.0), Genome.founder(), 30.0)
	var before := first.population()
	var made: Dish = m.pipette(first.global_position + Vector2(18.0, 0.0), 30.0)
	check(made != null and m.dishes.size() == 2 and m.dish == made, "the pipette makes a second dish and the main view moves to it")
	check(absf(made.time - first.time) < 1.0, "the new dish is at the world's time (%.1f and %.1f s)" % [made.time, first.time])
	check(made.population() == 10 and first.population() == 5 and before == 15, "the bups in the circle moved (%d in the new dish, %d left)" % [made.population(), first.population()])
	var moved_id: int = made.sim.alive_ids()[0]
	check(made.line_from_dish(moved_id) == 1, "a moved bup's line says it came from dish 1")
	m.set_main_dish(first)
	check(m.pipette(first.global_position + Vector2(5000.0, 5000.0), 30.0) == null and m.dishes.size() == 2, "a circle with no bups makes no dish")
	# The pipette timer: the game pauses for the pipette after the set hours, Space cannot resume, and a pipette that moves something does.
	m._set_pipette_timer(1.0)
	m.toolbar.set_paused(false)
	m._pipette_clock = 3599.0
	first.add_bup(first.global_position, Genome.founder(), 30.0)
	m.sim_speed = 100.0
	for i in 20:
		await process_frame
	check(m._pipette_waiting and m.paused and m.toolbar.resume_locked and m.paused_label.text == "PIPETTE", "after the hours the game pauses and says PIPETTE")
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	m.toolbar._shortcut_input(space)
	m.toolbar.speed_1000_button.button_pressed = true
	check(m.paused, "neither Space nor a speed button resumes while it waits")
	m.pipette(first.global_position + Vector2(5000.0, 5000.0), 30.0)
	check(m._pipette_waiting and m.paused, "a pipette that moves nothing does not resume it")
	check(m.dish == first, "an empty pipette leaves the view where it is")
	var again: Dish = m.pipette(first.global_position, 250.0)  # (the bups have swum a little since they were placed)
	check(again != null and m.dish == again and not m._pipette_waiting and not m.paused and not m.toolbar.resume_locked, "a pipette that moves bups resumes play (%s, waiting %s, paused %s, locked %s, bups %d)" % [again != null, m._pipette_waiting, m.paused, m.toolbar.resume_locked, first.population()])
	m._set_pipette_timer(0.0)
	m.queue_free()
	await process_frame
	TestUtil.finish(self, "DISHES TESTS OK")
