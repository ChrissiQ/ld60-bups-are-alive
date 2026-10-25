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
	check(made != null and m.dishes.size() == 2 and m.dish == first, "the pipette makes a second dish and leaves the main view where it is")
	check(made.population() == 10 and first.population() == 5 and before == 15, "the bups in the circle moved (%d in the new dish, %d left)" % [made.population(), first.population()])
	var moved_id: int = made.sim.alive_ids()[0]
	check(made.line_from_dish(moved_id) == 1, "a moved bup's line says it came from dish 1")
	check(m.pipette(first.global_position + Vector2(5000.0, 5000.0), 30.0) == null and m.dishes.size() == 2, "a circle with no bups makes no dish")
	m.queue_free()
	await process_frame
	TestUtil.finish(self, "DISHES TESTS OK")
