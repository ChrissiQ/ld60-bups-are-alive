extends SceneTree
## Run: godot --headless --path . -s tests/freezer_test.gd
## The freezer: a dish is frozen (its state kept, out of the running set and the world's clock), thawed under its own number at the world's time, or trashed; the
## question after a pipette; the sections of the tray.


func check(ok: bool, what: String) -> void:
	TestUtil.check(ok, what)


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
	await process_frame
	check(m.freezer_section.visible and m.freezer_shelf.freeze_button.disabled, "free mode has the freezer section, and the one running dish cannot be frozen")
	check(not m.all_details.visible and not m.graph_controls.scope_switch.visible, "with one dish there is no all-dishes section and no dish switch on the graph")
	m.toolbar.set_paused(false)
	var second: Dish = m.add_dish(chosen)
	var third: Dish = m.add_dish(chosen)
	for i in 30:
		await process_frame
	check(not m.freezer_shelf.freeze_button.disabled and m.all_details.visible and m.graph_controls.scope_switch.visible, "with several dishes the button is on, and the all-dishes section and the graph's dish switch show")
	var number: int = m._dish_numbers[second]
	var bups := second.population()
	var frozen_time := second.time
	second.set_backend_setting(StartConditions.BACKEND_CPU)
	second.moved_out[12345] = 7  # (as a pipette leaves it: bup 12345 went to dish 7)
	m.freeze_dish(second)
	check(m.dishes.size() == 2 and not m.dishes.has(second) and m.freezer_shelf.entries.size() == 1, "a frozen dish leaves the running dishes and is in the freezer")
	check(m.freezer_shelf.entries[0]["number"] == number and m.freezer_shelf.entries[0]["bups"] == bups, "the freezer keeps its number and its count")
	check(m.freezer_shelf.flow.get_child_count() == 1 and not m.freezer_shelf.empty_note.visible, "its button is in the freezer")
	check(m.freezer_shelf.flow.get_child(0).tooltip_text.begins_with("Unfreeze dish %d" % number), "the button says it unfreezes (%s)" % m.freezer_shelf.flow.get_child(0).tooltip_text)
	for i in 40:
		await process_frame
	check(absf(first.time - third.time) <= m.sim_speed / 60.0 + 1.0, "the running dishes keep one clock without it")
	var world: float = m.world_time()
	check(world > frozen_time, "the world went on while it was frozen (%.1f > %.1f)" % [world, frozen_time])
	m.thaw(m.freezer_shelf.entries[0])
	var back: Dish = m.dishes.back()
	check(m.dishes.size() == 3 and m.freezer_shelf.entries.is_empty() and m._dish_numbers[back] == number, "thawing puts it among the running dishes under its old number")
	check(absf(back.time - first.time) <= m.sim_speed / 60.0 + 1.0, "it is at the world's time, not the time it was frozen at (%.1f, world %.1f)" % [back.time, first.time])
	check(back.population() == bups, "it has the bups it was frozen with (%d, was %d)" % [back.population(), bups])
	check(back.backend_setting == StartConditions.BACKEND_CPU and back.moved_out.get(12345, -1) == 7, "it keeps its backend setting and where the pipette's bups went (%s, %s)" % [back.backend_setting, back.moved_out])
	var saved := {"time": 100.0, "bloom_due": 150.0, "plankton": [{"born_at": 10.0, "burst_at": 500.0}], "history": {"pop": [1.0, 2.0, 3.0]}, "history_all": {"pop": [5.0]}, "history_all_factor": 2}
	m._move_saved_dish_to(saved, 100.0 + 600.0)
	check(saved["time"] == 700.0 and saved["bloom_due"] == 750.0 and saved["plankton"][0]["burst_at"] == 1100.0 and saved["plankton"][0]["born_at"] == 610.0, "what was due at a time moves on with the dish: nothing is overdue when it runs again")
	check(saved["history"]["pop"].size() == 3 + 5 and saved["history"]["pop"][-1] == 3.0 and saved["history_all"]["pop"].size() == 1 + 2, "its history goes level over the time it was away (5 samples of 120 s, and 2 of 240 s)")
	var t0 := back.time
	for i in 20:
		await process_frame
	check(back.time > t0, "and it runs again")
	# Trash and the limit.
	var trashed_number: int = m._dish_numbers[third]
	m.trash_dish(third)
	check(m.dishes.size() == 2 and not m._dish_numbers.has(third) and not m.freezer_shelf.entries.any(func(e: Dictionary) -> bool: return e["number"] == trashed_number), "a trashed dish is gone, and not in the freezer")
	m.freeze_dish(back)
	m.freeze_dish(m.dish)
	check(m.dishes.size() == 1 and m.freezer_shelf.entries.size() == 1, "dishes freeze down to one running dish")
	m.freeze_dish(m.dish)
	m.trash_dish(m.dish)
	check(m.dishes.size() == 1, "the last running dish can be neither frozen nor trashed")
	# The question after a pipette: nothing else goes on until it is answered.
	var other: Dish = m.add_dish(chosen)
	m._ask_about_old_dish(first, 3, other)
	check(m.old_dish_dialog.visible and m.paused and m.toolbar.resume_locked, "the question is up and the game holds")
	m.old_dish_dialog.get_ok_button().pressed.emit()  # (the real button: OK hides the dialog before it answers, and the dialog must stay closed)
	for i in 3:
		await process_frame
	check(not m.old_dish_dialog.visible and m.freezer_shelf.entries.size() == 2 and m.dishes.size() == 1 and not m.toolbar.resume_locked and not m.paused, "freezing is an answer, and play goes on")
	check(m.all_details != null and m.graph_section != null and m.graph.get_parent().get_parent().get_parent() == m.graph_section, "the graph is in the tray, under its section")
	# The last running dish dies out while dishes are frozen: it stays, empty, until one is thawed, which takes its place; that one dying out ends the game.
	var emptied: Dish = m.dish
	m.toolbar.set_paused(false)
	emptied.clear_bups()
	for i in 10:
		await process_frame
	check(m._extinct_queue.has(emptied) and m.paused, "the last running dish dying out pauses on it")
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	check(m.dishes == [emptied] and m._extinct_queue.is_empty() and not m._game_over, "resuming with dishes frozen leaves the empty dish where it is")
	m.thaw(m.freezer_shelf.entries[0])
	check(m.dishes.size() == 1 and m.dishes[0] != emptied and m.dish == m.dishes[0], "thawing replaces the empty dish and brings the thawed one into view")
	m.toolbar.set_paused(false)
	m.dish.clear_bups()
	for i in 10:
		await process_frame
	check(m._extinct_queue.has(m.dish) or m._game_over, "the thawed dish dying out is noticed")
	TestUtil.finish(self, "FREEZER TESTS OK")
