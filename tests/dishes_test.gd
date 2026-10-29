extends SceneTree
## Run: godot --headless --path . -s tests/dishes_test.gd
## Several dishes on the game screen (free mode): a second dish runs beside the main one, has a thumbnail in the strip, and a click on it brings it into the
## main view (the graph, the panels and the camera follow).


func _init() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var chosen := TestUtil.small_start()
	chosen.bups = 40
	chosen.nutrient_density = 40
	var m: Node = TestUtil.free_game(chosen)
	root.add_child(m)
	await process_frame
	var first: Dish = m.dish
	TestUtil.check(m.dishes.size() == 1 and not m.dish_strip.visible, "one dish: no strip")
	m.toolbar.set_paused(false)
	var other: Dish = m.add_dish(chosen)
	TestUtil.check(m.dishes.size() == 2 and m.dish == first and m.dish_strip.visible and m.dish_strip.count() == 2, "a second dish joins the set and shows in the strip; the main view stays")
	TestUtil.check(other.global_position.distance_to(first.global_position) >= m.DISH_SPACING, "it is far from the first in the shared world")
	TestUtil.check(first.visibility_layer != other.visibility_layer and (m.get_viewport().canvas_cull_mask & other.visibility_layer) == 0 and (m.get_viewport().canvas_cull_mask & first.visibility_layer) != 0 and (m.get_viewport().canvas_cull_mask & 1) != 0, "the main view shows its own dish and the screen, and no other dish, however far it is zoomed out")
	TestUtil.check(first._overlay.visibility_layer == first.visibility_layer and first._bups_mesh.visibility_layer == first.visibility_layer, "everything a dish draws is on its layer")
	var t0 := other.time
	var t1 := first.time
	for i in 30:
		await process_frame
	TestUtil.check(other.time > t0 and first.time > t1, "both dishes run (%.1f and %.1f s)" % [other.time - t0, first.time - t1])
	TestUtil.check(other.population() > 0, "the other dish has bups")
	TestUtil.check(absf(other.time - first.time) <= m.sim_speed / 60.0 + 1.0, "the dishes keep one clock (%.1f and %.1f s)" % [other.time, first.time])
	var counts := 0.0
	var ids: Array = first.bup_ids()
	for id: int in ids:
		counts += first.bup_info(id)["divisions"]
	TestUtil.check(absf(first.population_stats()["generation"] - counts / ids.size()) < 1e-3, "a dish's generation is the mean of its bups' divisions (%.3f)" % first.population_stats()["generation"])
	var behind := 0
	for id: int in ids:
		var chain := first.lineage_chain(id)
		if chain.size() >= 2 and first.has_bup(chain[chain.size() - 2]):
			behind += 1 if first.bup_info(chain[chain.size() - 2])["divisions"] < first.bup_info(id)["divisions"] else 0
	TestUtil.check(behind == 0, "a bup's count is never above its living parent's: the daughter takes the parent's count after the division")
	var turns := []
	for round in 4:
		m.scheduler.let_one_dish_switch()
		turns.append(m.dishes.filter(func(d: Dish) -> bool: return d.backend.switch_allowed).size())
	TestUtil.check(turns == [1, 1, 1, 1], "exactly one dish at a time may change backend (%s)" % [turns])
	other.backend.switch_wanted = true
	other.backend.switch_wanted_gpu = true
	m.scheduler.let_one_dish_switch()
	m.scheduler.let_one_dish_switch()  # (no advance between: as for a dish the budget leaves out)
	TestUtil.check(other.backend.switch_allowed and other.backend.switch_wanted and not first.backend.switch_allowed, "a dish waiting to change backend keeps its wish and its turn until it is next advanced")
	other.backend.switch_wanted = false
	m.set_main_dish(other)
	TestUtil.check(m.dish == other and m.graph.dish == other and m.watch_list.dishes.has(other), "a choice brings the other dish into the main view, with the graph and the watch list")
	TestUtil.check(m.camera.position.distance_to(other.global_position) <= other.radius, "the camera is on it")
	m.dish_strip.dish_chosen.emit(first)
	TestUtil.check(m.dish == first and m.camera.position.distance_to(first.global_position) <= first.radius, "the strip's click brings the first back")
	# A dish that dies out: the game pauses on it and says so; resuming deletes it and goes to the dish before it.
	var third: Dish = m.add_dish(chosen)
	TestUtil.check(m.dishes.size() == 3 and m.dish == first, "three dishes before one dies out")
	# A processor that cannot afford every dish's step in a frame: the dishes take turns, the furthest behind first, and the world slows instead of the frame growing.
	m.toolbar.set_paused(true)
	var trio: Array[Dish] = [first, other, third]
	for d in trio:
		d.backend.measured_usec = 8000.0  # (each costs most of the 9 ms the simulation may spend in a frame)
	var before_turns := trio.map(func(d: Dish) -> float: return d.time)
	var at_once := 0
	var world_before: float = m.scheduler.world_time()
	for round in 3:
		var times := trio.map(func(d: Dish) -> float: return d.time)
		m.scheduler.advance(1.0)
		var moved := 0
		for k in 3:
			moved += 1 if trio[k].time > times[k] + 0.001 else 0
		at_once = maxi(at_once, moved)
	var every := trio.all(func(d: Dish) -> bool: return d.time > before_turns[trio.find(d)] + 0.001)
	TestUtil.check(at_once == 1 and every, "when each dish costs most of the budget only one is advanced a frame, and in three frames every dish has had its turn (most in one frame: %d)" % at_once)
	TestUtil.check(m.scheduler.world_time() - world_before <= 1.0 + 0.001, "the world's clock moved by about the one step in those three frames (%.2f s), not three: it slows down together" % (m.scheduler.world_time() - world_before))
	for d in trio:
		d.backend.measured_usec = 0.0
	m.toolbar.set_paused(false)
	m.toolbar.set_paused(false)
	other.clear_bups()
	for i in 5:
		await process_frame
	TestUtil.check(m.paused and m.dish == other and m.banner.text == Strings.t("hud.banner_dish_extinct", [2]), "a dish that dies out out of view: the game pauses, shows it and says which (%s)" % m.banner.text)
	TestUtil.check(m.dishes.size() == 3 and not m.toolbar.resume_locked, "...and it stays until play is resumed")
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes.size() == 2 and (not is_instance_valid(other) or (not m.dishes.has(other) and other.is_queued_for_deletion())), "resuming deletes the dish")
	TestUtil.check(m.dish == first and m.banner.text == "" and not m.paused, "the view goes to the dish before it, the banner clears and play goes on")
	TestUtil.check(m.dish_strip.count() == 2 and m._dish_numbers.values().has(3) and not m._dish_numbers.values().has(2), "its number is not reused or shown")
	first.clear_bups()
	for i in 5:
		await process_frame
	TestUtil.check(m.paused and m.dish == first and m.banner.text == Strings.t("hud.banner_dish_extinct", [1]), "the first dish dies out: it is shown")
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes.size() == 1 and m.dish == third and not m.dish_strip.visible, "when the first of several goes, the next one comes into view")
	# The last dish dying out ends the game: nothing but starting again or quitting resumes.
	third.clear_bups()
	for i in 5:
		await process_frame
	TestUtil.check(m.holds.has(&"end") and m.paused and m.toolbar.resume_locked and m.end_dialog.visible, "the last dish dying out ends the game with the window up")
	m.toolbar.set_paused(false)
	TestUtil.check(m.paused, "...and nothing resumes it")
	m.end_dialog.confirmed.emit()
	await process_frame
	TestUtil.check(not m.holds.has(&"end") and not m.toolbar.resume_locked and m.dish.population() > 0 and m.dishes.size() == 1, "starting again begins the dish afresh")
	# A dish that dies out while another is being looked at: afterwards the view goes back to what was being looked at, not to the dish before the dead one.
	var base: Dish = m.dish
	var dying: Dish = m.add_dish(chosen)
	var watched: Dish = m.add_dish(chosen)
	m.set_main_dish(watched)
	m.toolbar.set_paused(false)
	dying.clear_bups()
	for i in 5:
		await process_frame
	TestUtil.check(m.paused and m.dish == dying, "a dish that dies out while another is in view is shown, as before")
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes.size() == 3 - 1 and m.dish == watched and (not is_instance_valid(dying) or not m.dishes.has(dying)), "after it goes, the view is back on the dish that was being looked at, not the one before the dead dish")
	dying = m.add_dish(chosen)
	dying.clear_bups()
	for i in 5:
		await process_frame
	m.set_main_dish(base)  # (the player looks at another dish while the news is up)
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	TestUtil.check(m.dish == base, "if the player moved to another dish while it was shown, they stay where they went")
	m.queue_free()
	await process_frame
	m = load(Scenes.GAME).instantiate()
	root.add_child(m)
	await process_frame
	first = m.dish
	TestUtil.check(m.dishes.size() == 1 and not m.dish_strip.visible, "a new game screen has one dish and no strip")
	# The pipette: the bups in the circle move to a new dish, the rest stay.
	first.clear_bups()
	for i in 10:
		first.add_bup(first.global_position + Vector2(i * 4.0, 0.0), Genome.founder(), 30.0)
	for i in 5:
		first.add_bup(first.global_position + Vector2(200.0 + i, 100.0), Genome.founder(), 30.0)
	var parent := first.add_bup(first.global_position + Vector2(300.0, 0.0), Genome.founder(), 30.0)  # (a bup with a parent, a name and a place on the watch list: all must go with it)
	var child := first.sim.add_bup(Vector2(12.0, 0.0), Genome.founder(), 30.0, -1.0, -1.0, 1, Vector2.RIGHT, -1, parent)
	first.rename_bup(child, "Zed")
	first.watch_bup(child)
	var before := first.population()
	var made: Dish = m.pipette(first.global_position + Vector2(18.0, 0.0), 30.0)
	TestUtil.check(made.has_bup(child) and made.bup_name(child) == "Zed" and made.lineage_chain(child).size() == 2 and made.lineage_chain(child)[0] == parent, "a moved bup is the same bup: its id, its name and its family line come with it")
	TestUtil.check(made.is_watched(child) and not first.is_watched(child) and m.watch_list.dishes.has(made), "...and so does its place on the watch list")
	TestUtil.check(made != null and m.dishes.size() == 2 and m.dish == made, "the pipette makes a second dish and the main view moves to it")
	TestUtil.check(absf(made.time - first.time) < 1.0, "the new dish is at the world's time (%.1f and %.1f s)" % [made.time, first.time])
	TestUtil.check(is_equal_approx(made.history_origin, first.time) or absf(made.history_origin - first.time) < 1.0, "the new dish's history begins at the world's time (%.1f s)" % made.history_origin)
	m.graph.dish = made
	m.graph.dishes = m.dishes
	m.graph.all_dishes = false
	TestUtil.check(m.graph._now() < 1.0 and m.graph._series("pop", 0.0, HistoryGraph.Span.ALL).size() <= 1, "the graph of the new dish counts its own time, not the world's (%.1f s)" % m.graph._now())
	TestUtil.check(made.population() == 11 and first.population() == 6 and before == 17, "the bups in the circle moved (%d in the new dish, %d left)" % [made.population(), first.population()])
	TestUtil.check(m.old_dish_dialog.visible and m._old_dish == first and m.paused, "the pipette asks what to do with the old dish, and the game holds until it is answered")
	m._answer_old_dish("keep")
	TestUtil.check(not m.old_dish_dialog.visible and m.dishes.has(first) and m.paused, "keeping it leaves both dishes there, and the game as paused as it was")
	var moved_id: int = made.sim.alive_ids()[0]
	TestUtil.check(m._info_text(made.bup_info(moved_id)).contains("dish %d" % m._dish_numbers[made]), "a bup's panel says which dish it is in now (dish %d)" % m._dish_numbers[made])
	var seen_from := made.view_zoom
	m.camera.zoom = Vector2.ONE * 0.37
	m.camera.position = made.global_position + Vector2(40.0, -25.0)
	m.set_main_dish(first)
	m.camera.zoom = Vector2.ONE * 0.9
	m.camera.position = first.global_position + Vector2(-70.0, 15.0)
	m.set_main_dish(made)
	TestUtil.check(is_equal_approx(m.camera.zoom.x, 0.37) and m.camera.position.is_equal_approx(made.global_position + Vector2(40.0, -25.0)), "switching back to a dish returns to where and how close it was looked at (zoom %.2f)" % m.camera.zoom.x)
	m.layers_panel.layer_toggled.emit(Dish.Layer.BUPS, false)
	var third_dish: Dish = m.add_dish(chosen)
	TestUtil.check(not first.layer_shown(Dish.Layer.BUPS) and not made.layer_shown(Dish.Layer.BUPS) and not third_dish.layer_shown(Dish.Layer.BUPS), "what is shown is one choice for every dish, new ones too")
	m.layers_panel.layer_toggled.emit(Dish.Layer.BUPS, true)
	await process_frame
	await process_frame
	TestUtil.check(m.dish_strip.get_global_rect().position.y >= m.get_node("%TopBar").get_global_rect().position.y and m.get_node("%TopBar").get_global_rect().encloses(m.dish_strip.get_global_rect()), "the tabs of the dishes sit inside the top bar (%s in %s)" % [m.dish_strip.get_global_rect(), m.get_node("%TopBar").get_global_rect()])
	m.set_main_dish(first)
	var elsewhere: Dictionary = m._alive_elsewhere(first.lineage_chain(parent))
	TestUtil.check(elsewhere.get(parent, []) == [[1, m.dishes.find(made) + 1]], "a lineage entry says how many bups of that line are alive in another dish (%s)" % [elsewhere])
	TestUtil.check(m.pipette(first.global_position + Vector2(5000.0, 5000.0), 30.0) == null and m.dishes.size() == 3, "a circle with no bups makes no dish")
	# The pipette timer: the game pauses for the pipette after the set hours, Space cannot resume, and a pipette that moves something does.
	m._set_pipette_timer(1.0)
	m.toolbar.set_paused(false)
	m._pipette_clock = 3599.0
	first.add_bup(first.global_position, Genome.founder(), 30.0)
	m.sim_speed = 100.0
	for i in 20:
		await process_frame
	TestUtil.check(m.holds.has(&"pipette") and m.paused and m.toolbar.resume_locked and m.vitals.get_parsed_text().contains(Strings.t("hud.pipette_paused")), "after the hours the game pauses and says so in the top bar")
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.pressed = true
	m.toolbar._shortcut_input(space)
	m.toolbar.speed_1000_button.button_pressed = true
	TestUtil.check(m.paused, "neither Space nor a speed button resumes while it waits")
	m.pipette(first.global_position + Vector2(5000.0, 5000.0), 30.0)
	TestUtil.check(m.holds.has(&"pipette") and m.paused, "a pipette that moves nothing does not resume it")
	TestUtil.check(m.dish == first, "an empty pipette leaves the view where it is")
	var again: Dish = m.pipette(first.global_position, 250.0)  # (the bups have swum a little since they were placed)
	TestUtil.check(again != null and m.paused and m.holds.has(&"pipette"), "a pipette that moves bups holds the game until its question is answered")
	m._answer_old_dish("keep")
	TestUtil.check(again != null and m.dish == again and not m.holds.has(&"pipette") and not m.paused and not m.toolbar.resume_locked, "...and the answer resumes play (%s, waiting %s, paused %s, locked %s, bups %d)" % [again != null, m.holds.has(&"pipette"), m.paused, m.toolbar.resume_locked, first.population()])
	# Slowing down from a fast speed leaves one dish ahead of the other: the one behind catches up quickly instead of the one ahead standing still for as long as the gap.
	var lagging: Dish = m.dishes[0]
	var leading: Dish = m.dishes[1]
	leading.time = lagging.time + 40.0
	var frames := 0
	while absf(leading.time - lagging.time) > 1.0 and frames < 400:
		m.scheduler.advance(1.0 / 60.0)
		frames += 1
	TestUtil.check(absf(leading.time - lagging.time) <= 1.0 and frames < 400, "a gap of 40 s between the dishes is closed in %d frames at x1, not 2400" % frames)
	m._set_pipette_timer(0.0)
	# A size chosen for a dish goes to that dish, whichever is in view when it arrives.
	var sized: Dish = m.dishes[0]
	var viewed: Dish = m.dishes[1]
	m.set_main_dish(viewed)
	var viewed_radius := viewed.radius
	var sized_radius := sized.radius
	m._resize_dish(sized, 2000.0)
	TestUtil.check(sized.radius == 2000.0 and viewed.radius == viewed_radius, "a size chosen for one dish does not resize the one in view")
	# A layer's key flips it with the layer buttons hidden (a shortcut does not reach a hidden button).
	m.layers_panel.get_parent().get_parent().visible = false
	var key := InputEventKey.new()
	key.keycode = KeyBindings.key("layer_medium")
	key.pressed = true
	var shown := viewed.layer_shown(Dish.Layer.MEDIUM)
	m._on_key(key)
	TestUtil.check(viewed.layer_shown(Dish.Layer.MEDIUM) == not shown, "a layer key works with its buttons hidden")
	m._on_key(key)
	m.layers_panel.get_parent().get_parent().visible = true
	m.queue_free()
	await process_frame
	TestUtil.finish(self, "DISHES TESTS OK")
