extends SceneTree
## Run: godot --headless --path . -s tests/freezer_test.gd
## The freezer: a dish is frozen (its state kept, out of the running set and the world's clock), thawed under its own number at the world's time, or trashed; the
## question after a pipette; the sections of the tray.


func _init() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var chosen := TestUtil.small_start()
	chosen.bups = 40
	chosen.nutrient_density = 40
	var m: Node = TestUtil.game_screen(self, chosen)
	await process_frame
	var first: Dish = m.dish
	await process_frame
	TestUtil.check(m.freezer_section.visible and m.freezer_shelf.actions.freeze_button.disabled, "free mode has the freezer section, and the one running dish cannot be frozen")
	TestUtil.check(not m.all_details.visible and not m.graph_controls.scope_switch.visible, "with one dish there is no all-dishes section and no dish switch on the graph")
	m.toolbar.set_paused(false)
	var second: Dish = m.add_dish(chosen)
	var third: Dish = m.add_dish(chosen)
	for i in 30:
		await process_frame
	TestUtil.check(not m.freezer_shelf.actions.freeze_button.disabled and m.all_details.visible and m.graph_controls.scope_switch.visible, "with several dishes the button is on, and the all-dishes section and the graph's dish switch show")
	TestUtil.check(m.card_actions.visible and not m.card_actions.trash_button.disabled and m.card_actions.freeze_button.text == "Freeze this dish" and m.card_actions.trash_button.text == "Trash this dish", "the dish card has Freeze and Trash buttons too")
	var extra: Dish = m.add_dish(chosen)
	m.set_main_dish(extra)
	m.card_actions.trash_button.pressed.emit()
	TestUtil.check(m.trash_dialog.visible and m.trash_dialog.title == "Trash dish %d?" % m._dish_numbers[extra] and m.dishes.has(extra), "Trash asks first, and nothing is deleted yet")
	m.trash_dialog.get_cancel_button().pressed.emit()
	TestUtil.check(m.dishes.has(extra), "keeping it leaves it running")
	m.freezer_shelf.trash_requested.emit()
	m.trash_dialog.confirmed.emit()
	TestUtil.check(not m.dishes.has(extra) and m.dishes.size() == 3, "confirming trashes the dish in the main view, from the freezer's button too")
	m.set_main_dish(first)
	var number: int = m._dish_numbers[second]
	var bups := second.population()
	var frozen_time := second.time
	second.set_backend_setting(StartConditions.BACKEND_CPU)
	second.moved_out[12345] = 7  # (as a pipette leaves it: bup 12345 went to dish 7)
	m.freeze_dish(second)
	TestUtil.check(m.dishes.size() == 2 and not m.dishes.has(second) and m.freezer_shelf.entries.size() == 1, "a frozen dish leaves the running dishes and is in the freezer")
	TestUtil.check(m.freezer_shelf.entries[0]["number"] == number and m.freezer_shelf.entries[0]["bups"] == bups, "the freezer keeps its number and its count")
	var row: Control = m.freezer_shelf.list.get_child(0)
	TestUtil.check(m.freezer_shelf.list.get_child_count() == 1 and not m.freezer_shelf.empty_note.visible, "its row is in the freezer")
	TestUtil.check(row.get_node("Row/Unfreeze").tooltip_text == "Unfreeze" and row.get_node("Row/Info").tooltip_text == "Info" and row.get_node("Row/Trash").tooltip_text == "Trash", "the row has unfreeze, info and trash buttons")
	TestUtil.check(not row.get_node("Details").visible, "the details are closed")
	row.get_node("Row/Info").pressed.emit()
	TestUtil.check(m.freezer_shelf.list.get_child(0).get_node("Details").visible and m.freezer_shelf.list.get_child(0).get_node("Details").text.contains("%s bups" % UiText.thousands(bups)), "the info button opens the details")
	for i in 40:
		await process_frame
	TestUtil.check(absf(first.time - third.time) <= m.sim_speed / 60.0 + 1.0, "the running dishes keep one clock without it")
	var world: float = m.scheduler.world_time()
	TestUtil.check(world > frozen_time, "the world went on while it was frozen (%.1f > %.1f)" % [world, frozen_time])
	m.thaw(m.freezer_shelf.entries[0])
	var back: Dish = m.dishes.back()
	TestUtil.check(m.dishes.size() == 3 and m.freezer_shelf.entries.is_empty() and m._dish_numbers[back] == number, "thawing puts it among the running dishes under its old number")
	TestUtil.check(absf(back.time - first.time) <= m.sim_speed / 60.0 + 1.0, "it is at the world's time, not the time it was frozen at (%.1f, world %.1f)" % [back.time, first.time])
	TestUtil.check(back.population() == bups, "it has the bups it was frozen with (%d, was %d)" % [back.population(), bups])
	TestUtil.check(back.backend.setting == StartConditions.BACKEND_CPU and back.moved_out.get(12345, -1) == 7, "it keeps its backend setting and where the pipette's bups went (%s, %s)" % [back.backend.setting, back.moved_out])
	var saved := {"time": 100.0, "bloom_due": 150.0, "plankton": [{"born_at": 10.0, "burst_at": 500.0}], "history": {"pop": [1.0, 2.0, 3.0]}, "history_all": {"pop": [5.0]}, "history_all_factor": 2}
	m._move_saved_dish_to(saved, 100.0 + 600.0)
	TestUtil.check(saved["time"] == 700.0 and saved["bloom_due"] == 750.0 and saved["plankton"][0]["burst_at"] == 1100.0 and saved["plankton"][0]["born_at"] == 610.0, "what was due at a time moves on with the dish: nothing is overdue when it runs again")
	TestUtil.check(saved["history"]["pop"].size() == 3 + 5 and saved["history"]["pop"][-1] == 3.0 and saved["history_all"]["pop"].size() == 1 + 2, "its history goes level over the time it was away (5 samples of 120 s, and 2 of 240 s)")
	var t0 := back.time
	for i in 20:
		await process_frame
	TestUtil.check(back.time > t0, "and it runs again")
	# Trash and the limit.
	var trashed_number: int = m._dish_numbers[third]
	m.trash_dish(third)
	TestUtil.check(m.dishes.size() == 2 and not m._dish_numbers.has(third) and not m.freezer_shelf.entries.any(func(e: Dictionary) -> bool: return e["number"] == trashed_number), "a trashed dish is gone, and not in the freezer")
	m.freeze_dish(back)
	m.freeze_dish(m.dish)
	TestUtil.check(m.dishes.size() == 1 and m.freezer_shelf.entries.size() == 1, "dishes freeze down to one running dish")
	var kept: int = m.freezer_shelf.entries.size()
	m.freezer_shelf.add({"number": 99, "data": {"time": 0.0}, "bups": 5, "picture": null})
	m.freezer_shelf.list.get_child(kept).get_node("Row/Trash").pressed.emit()
	TestUtil.check(m.trash_dialog.visible and m.freezer_shelf.entries.size() == kept + 1, "trashing a frozen dish asks first")
	m.trash_dialog.canceled.emit()
	m.trash_dialog.hide()
	TestUtil.check(m.freezer_shelf.entries.size() == kept + 1, "keeping it leaves it frozen")
	m.freezer_shelf.list.get_child(kept).get_node("Row/Trash").pressed.emit()
	m.trash_dialog.confirmed.emit()
	m.trash_dialog.hide()
	TestUtil.check(m.freezer_shelf.entries.size() == kept, "confirming trashes the frozen dish for good")
	m.freeze_dish(m.dish)
	m.trash_dish(m.dish)
	TestUtil.check(m.dishes.size() == 1, "the last running dish can be neither frozen nor trashed")
	# The question after a pipette: nothing else goes on until it is answered.
	var other: Dish = m.add_dish(chosen)
	m._ask_about_old_dish(first, 3, other)
	TestUtil.check(m.old_dish_dialog.visible and m.paused and m.toolbar.resume_locked, "the question is up and the game holds")
	m.old_dish_dialog.get_ok_button().pressed.emit()  # (the real button: OK hides the dialog before it answers, and the dialog must stay closed)
	for i in 3:
		await process_frame
	TestUtil.check(not m.old_dish_dialog.visible and m.freezer_shelf.entries.size() == 2 and m.dishes.size() == 1 and not m.toolbar.resume_locked and not m.paused, "freezing is an answer, and play goes on")
	TestUtil.check(m.all_details != null and m.graph_section != null and m.graph.get_parent().get_parent().get_parent() == m.graph_section, "the graph is in the tray, under its section")
	# The last running dish dies out while dishes are frozen: it stays, empty, until one is thawed, which takes its place; that one dying out ends the game.
	var emptied: Dish = m.dish
	m.toolbar.set_paused(false)
	emptied.clear_bups()
	for i in 10:
		await process_frame
	TestUtil.check(m._extinct_queue.has(emptied) and m.paused, "the last running dish dying out pauses on it")
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes == [emptied] and m._extinct_queue.is_empty() and not m.holds.has(&"end"), "resuming with dishes frozen leaves the empty dish where it is")
	m.thaw(m.freezer_shelf.entries[0])
	TestUtil.check(m.dishes.size() == 1 and m.dishes[0] != emptied and m.dish == m.dishes[0], "thawing replaces the empty dish and brings the thawed one into view")
	m.toolbar.set_paused(false)
	m.dish.clear_bups()
	for i in 10:
		await process_frame
	TestUtil.check(m._extinct_queue.has(m.dish) or m.holds.has(&"end"), "the thawed dish dying out is noticed")
	TestUtil.finish(self, "FREEZER TESTS OK")
