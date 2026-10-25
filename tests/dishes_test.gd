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
	m.queue_free()
	await process_frame
	TestUtil.finish(self, "DISHES TESTS OK")
