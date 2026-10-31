extends SceneTree
## Run: godot --headless --path . -s tests/freezer_test.gd
## The freezer, on the game screen over FakeWorld (a small world kept on the main thread: SimService.use_backend):
## a dish is frozen (the simulation takes it out of the world whole, and answers a frame later), thawed under its own number at the world's
## time, or trashed; the question after a pipette; the sections of the tray; the save, which has no freezer.
##
## Expected values, written before the first run [derived from the rules in main.gd and FakeWorld; the fake's clock starts at 3,661 s and
## each frame stands for 1/60 s of real time, times the speed]:
##  - the last dish's buttons say why they are off; with 3 dishes the freeze and trash buttons are on. A freeze sends one FREEZE for
##    the dish's row; the dish leaves the running set and the world's rows at once, its entry keeps its number and its count, and its row
##    is in the freezer. Until the answer comes (one frame) the game waits quietly: the world's next set_time is paused, the tray takes no
##    input, and the toolbar is not paused (nothing is shown).
##  - The freezer's details line gives the time it was frozen at on the game's clock (the world's less the game's beginning: about 300 s
##    after 30 frames at x600), not the world's (3,661 s and more); the dish had at least 2 history samples then (300 s crosses 2 or 3
##    multiples of 120 s).
##  - thawed 40 frames later at x600 (10 s a frame: 400 s away), it is among the running dishes under its old number once a
##    snapshot shows it, at the world's time, with the bups it was frozen with; its history gains int(400 / 120) = 3 level samples; its
##    founders' family records are alive again with the dish as their home. An Unfreeze asked before the freeze has answered is done when
##    it answers. A thaw the memory budget refuses leaves the entry in the freezer as it was and shows banner.memory_budget; the next one
##    works. DishWorld.load_blob moves what was due on by the time away (100 s saved, loaded at 700 s: bloom due 150 -> 750, a plankton born
##    at 100 and bursting at t -> 700 and t + 600); DishHistory.pad from 100 s to 700 s adds a fine sample for each multiple of 120 s
##    crossed (120 to 600: 5) and a whole-run one for each multiple of 240 s (240, 480: 2).
##  - a trash removes the dish and sends one REMOVE_DISH for its row; trashing a frozen dish asks first, and confirmed, releases its
##    claims on the family tree (LineageStore.claim_count back to 0) once its freeze has answered.
##  - the last running dish dying out with dishes frozen pauses on it and stays, empty, after resuming; an unfreeze takes its place
##    and comes into view; that one dying out is noticed.
##  - a goal-mode save written to a scratch file has only the keys dish, goals and version (no freezer); loaded, the shelf is empty,
##    the dish has the bups it was saved with, and the game's clock carries on from what it was (|shown - saved| < 1e-6 s), though the
##    world's clock moved on; a save whose dish is of another format is no save.
##  - the question after a pipette holds the game until a button answers; Freeze is an answer, and play goes on.

const SCRATCH := "user://freezer_test_save.json"


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var fake := FakeWorld.new()
	root.get_node("SimService").use_backend(fake)
	var chosen := TestUtil.small_start()
	chosen.bups = 40
	chosen.nutrient_density = 40
	var m: Node = TestUtil.game_screen(self, chosen)
	await process_frame
	var first: Dish = m.dish
	await process_frame
	TestUtil.check(m.card_actions.freeze_button.tooltip_text == "You can't freeze the last dish" and m.card_actions.trash_button.tooltip_text == "You can't trash the last dish", "the last dish's tips say why the buttons are off")
	TestUtil.check(m.freezer_section.visible and m.freezer_shelf.actions.freeze_button.disabled, "free mode has the freezer section, and the one running dish cannot be frozen")
	TestUtil.check(not m.all_details.visible and not m.graph_controls.scope_switch.visible, "with one dish there is no all-dishes section and no dish switch on the graph")
	m.toolbar.set_paused(false)
	var second: Dish = m.add_dish(chosen)
	var third: Dish = m.add_dish(chosen)
	m.sim_speed = 600.0  # (300 s in 30 frames: the dishes' histories have samples to go on level with)
	for i in 30:
		await process_frame
	m.sim_speed = 1.0
	TestUtil.check(not m.freezer_shelf.actions.freeze_button.disabled and m.all_details.visible and m.graph_controls.scope_switch.visible, "with several dishes the button is on, and the all-dishes section and the graph's dish switch show")
	TestUtil.check(m.card_actions.visible and not m.card_actions.trash_button.disabled and m.card_actions.freeze_button.text == "Freeze this dish" and m.card_actions.trash_button.text == "Trash this dish", "the dish card has Freeze and Trash buttons too")
	TestUtil.check(m.card_actions.freeze_button.tooltip_text == "Stash this dish in the freezer for later" and m.card_actions.trash_button.tooltip_text == "Throw this dish out for good", "with several dishes the tips say what the buttons do")
	var extra: Dish = m.add_dish(chosen)
	await process_frame
	var extra_row: int = extra.row
	m.set_main_dish(extra)
	m.card_actions.trash_button.pressed.emit()
	TestUtil.check(m.trash_dialog.visible and m.trash_dialog.title == "Trash dish %d?" % m._dish_numbers[extra] and m.dishes.has(extra), "Trash asks first, and nothing is deleted yet")
	m.trash_dialog.get_cancel_button().pressed.emit()
	TestUtil.check(m.dishes.has(extra), "keeping it leaves it running")
	m.freezer_shelf.trash_requested.emit()
	m.trash_dialog.confirmed.emit()
	TestUtil.check(not m.dishes.has(extra) and m.dishes.size() == 3, "confirming trashes the dish in the main view, from the freezer's button too")
	await process_frame
	TestUtil.check(fake.calls_of(SimCommand.KIND_REMOVE_DISH).filter(func(c: Dictionary) -> bool: return c["args"]["row"] == extra_row).size() == 1 and not fake.rows().has(extra_row), "a trash takes the dish out of the world: one REMOVE_DISH for its row")
	m.set_main_dish(first)

	# Freeze: out of the world at once, the blob a frame later; the game waits quietly meanwhile.
	var number: int = m._dish_numbers[second]
	var world_number: int = second.number
	var bups := second.population()
	var second_row: int = second.row
	var founders: PackedInt64Array = fake.ids_in(second_row)
	var history_before: int = second.history.fine["pop"].size()
	var game_time: float = m.world_time() - m.game_began
	m.freeze_dish(second)
	TestUtil.check(m.dishes.size() == 2 and not m.dishes.has(second) and m.freezer_shelf.entries.size() == 1, "a frozen dish leaves the running dishes and is in the freezer")
	TestUtil.check(fake.calls_of(SimCommand.KIND_FREEZE).size() == 1 and fake.calls_of(SimCommand.KIND_FREEZE)[0]["args"]["row"] == second_row and not fake.rows().has(second_row), "one FREEZE for its row, and the world has it no longer")
	TestUtil.check(m.freezer_shelf.entries[0]["label"] == number and m.freezer_shelf.entries[0]["number"] == world_number and m.freezer_shelf.entries[0]["bups"] == bups and bups == 40, "the freezer keeps its number and its count (%d)" % bups)
	TestUtil.check(m.holds.stills_world() and not m.paused and m.hud_layer.process_mode == Node.PROCESS_MODE_DISABLED, "until the answer comes the world waits and the tray takes no input, with nothing shown")
	var clock_then := fake.clock
	await process_frame
	TestUtil.check(fake.clock == clock_then and fake.calls_of(SimCommand.KIND_SET_TIME)[-1]["args"]["paused"], "the frame it waits for the answer the world stands still")
	await process_frame
	TestUtil.check(not m.holds.stills_world() and m.hud_layer.process_mode == Node.PROCESS_MODE_INHERIT and not fake.calls_of(SimCommand.KIND_SET_TIME)[-1]["args"]["paused"], "once it has answered the world runs on")
	var row: Control = m.freezer_shelf.row_for(m.freezer_shelf.entries[0])
	TestUtil.check(row != null and m.freezer_shelf.rows_made() == 1 and not m.freezer_shelf.empty_note.visible, "its row is in the freezer")
	TestUtil.check(row.get_node("Row/Unfreeze").tooltip_text == "Unfreeze" and row.get_node("Row/Info").tooltip_text == "Info" and row.get_node("Row/Trash").tooltip_text == "Trash", "the row has unfreeze, info and trash buttons")
	TestUtil.check(not row.get_node("Details").visible, "the details are closed")
	row.get_node("Row/Info").pressed.emit()
	var details: Label = m.freezer_shelf.row_for(m.freezer_shelf.entries[0]).get_node("Details")
	TestUtil.check(details.visible and details.text.contains("%s bups" % UiText.thousands(bups)), "the info button opens the details")
	TestUtil.check(details.text.contains(SimClock.format(game_time)) and not details.text.contains(SimClock.format(game_time + m.game_began)), "...which say when it was frozen on the game's clock (%s), not the world's" % details.text)
	TestUtil.check(history_before >= 2, "it had history samples when it was frozen (%d)" % history_before)
	m.sim_speed = 600.0
	for i in 40:
		await process_frame
	TestUtil.check(first.time == third.time, "the running dishes keep one clock without it")
	var frozen_at: float = m.freezer_shelf.entries[0]["reply"].value().world["time"]
	var world: float = m.world_time()
	TestUtil.check(world > frozen_at + 300.0, "the world went on while it was frozen (%.1f > %.1f)" % [world, frozen_at])
	m.sim_speed = 1.0

	# Unfreeze: a thaw the memory budget refuses leaves the entry as it was; the next one brings it back under its number.
	fake.refuse_next(SimCommand.KIND_THAW)
	m.thaw(m.freezer_shelf.entries[0])
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes.size() == 2 and m.freezer_shelf.entries.size() == 1 and not m.freezer_shelf.entries[0].has("thawing") and m.banner.text == Strings.t("banner.memory_budget"), "a refused unfreeze leaves it in the freezer and says why (%s)" % m.banner.text)
	m.thaw(m.freezer_shelf.entries[0])
	TestUtil.check(m.freezer_shelf.entries.size() == 1 and m.holds.stills_world(), "an unfrozen dish stays in the freezer until the world shows it")
	await process_frame
	await process_frame
	var back: Dish = m.dishes.back()
	TestUtil.check(m.dishes.size() == 3 and m.freezer_shelf.entries.is_empty() and m._dish_numbers[back] == number, "thawing puts it among the running dishes under its old number")
	TestUtil.check(back.time == first.time, "it is at the world's time, not the time it was frozen at (%.1f, world %.1f)" % [back.time, first.time])
	TestUtil.check(back.population() == bups, "it has the bups it was frozen with (%d, was %d)" % [back.population(), bups])
	var padded := int((m.world_time() - frozen_at) / DishHistory.INTERVAL)
	TestUtil.check(padded == 3 and back.history.fine["pop"].size() == history_before + padded, "its history goes level for the time it was away (%d samples, %d before, %d padded)" % [back.history.fine["pop"].size(), history_before, padded])
	var alive := Array(founders).all(func(id: int) -> bool: return back.has_bup(id))
	TestUtil.check(founders.size() == 40 and alive, "its bups' family records are alive again, in this dish")
	var saved := DishWorld.new(1000.0, 1)
	saved.time = 100.0
	saved.set_bloom(0.08)
	saved.apply({"op": "add_plankton", "pos": Vector2(10.0, 0.0)})
	var kept := saved.save()
	kept["bloom_due"] = 150.0
	var burst: float = kept["plankton"][0]["burst_at"]
	var moved := DishWorld.new()
	moved.load_blob(kept, 700.0)
	var now := moved.save()
	TestUtil.check(now["time"] == 700.0 and now["bloom_due"] == 750.0 and now["plankton"][0]["born_at"] == 700.0 and now["plankton"][0]["burst_at"] == burst + 600.0, "what was due at a time moves on with the dish: nothing is overdue when it runs again")
	var history := {"history": {"pop": [1.0, 2.0, 3.0]}, "history_all": {"pop": [5.0]}, "history_all_factor": 2}
	DishHistory.pad(history, 100.0, 700.0)
	TestUtil.check(history["history"]["pop"].size() == 3 + 5 and history["history"]["pop"][-1] == 3.0 and history["history_all"]["pop"].size() == 1 + 2, "its history goes level over the time it was away (5 samples of 120 s, and 2 of 240 s)")
	var t0 := back.time
	m.toolbar.set_paused(false)
	for i in 20:
		await process_frame
	TestUtil.check(back.time > t0, "and it runs again")

	# Trash and the limit.
	var trashed_number: int = m._dish_numbers[third]
	m.trash_dish(third)
	TestUtil.check(m.dishes.size() == 2 and not m._dish_numbers.has(third) and not m.freezer_shelf.entries.any(func(e: Dictionary) -> bool: return e["label"] == trashed_number), "a trashed dish is gone, and not in the freezer")
	m.freeze_dish(back)
	m.freeze_dish(m.dish)
	TestUtil.check(m.dishes.size() == 1 and m.freezer_shelf.entries.size() == 1, "dishes freeze down to one running dish")
	await process_frame
	await process_frame
	var kept_count: int = m.freezer_shelf.entries.size()
	m.freezer_shelf.add({"number": 99, "label": 99, "data": {"time": 0.0}, "bups": 5, "picture": null})
	m.freezer_shelf.row_for(m.freezer_shelf.entries[kept_count]).get_node("Row/Trash").pressed.emit()
	TestUtil.check(m.trash_dialog.visible and m.freezer_shelf.entries.size() == kept_count + 1, "trashing a frozen dish asks first")
	m.trash_dialog.canceled.emit()
	m.trash_dialog.hide()
	TestUtil.check(m.freezer_shelf.entries.size() == kept_count + 1, "keeping it leaves it frozen")
	m.freezer_shelf.row_for(m.freezer_shelf.entries[kept_count]).get_node("Row/Trash").pressed.emit()
	m.trash_dialog.confirmed.emit()
	m.trash_dialog.hide()
	TestUtil.check(m.freezer_shelf.entries.size() == kept_count, "confirming trashes the frozen dish for good")
	m.freeze_dish(m.dish)
	m.trash_dish(m.dish)
	TestUtil.check(m.dishes.size() == 1, "the last running dish can be neither frozen nor trashed")

	# Trashing a frozen dish lets go of its claims on the family tree, once its freeze has answered.
	var claims_before: int = fake.store.claim_count()
	var spare: Dish = m.add_dish(chosen)
	await process_frame
	m.freeze_dish(spare)
	var spare_entry: Dictionary = m.freezer_shelf.entries.back()
	m._trash_frozen(spare_entry)
	TestUtil.check(m.freezer_shelf.entries.has(spare_entry) and spare_entry.get("then") == "trash" and fake.store.claim_count() > claims_before, "a dish whose freeze has not answered is trashed once it has (claims %d, were %d)" % [fake.store.claim_count(), claims_before])
	await process_frame
	await process_frame
	TestUtil.check(not m.freezer_shelf.entries.has(spare_entry) and fake.store.claim_count() == claims_before, "...and its claims on the family tree go with it (%d)" % fake.store.claim_count())

	# The question after a pipette: nothing else goes on until it is answered.
	var other: Dish = m.add_dish(chosen)
	await process_frame
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
	fake.kill(emptied.row)
	for i in 10:
		await process_frame
	TestUtil.check(m._extinct_queue.has(emptied) and m.paused, "the last running dish dying out pauses on it")
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes == [emptied] and m._extinct_queue.is_empty() and not m.holds.has(&"end"), "resuming with dishes frozen leaves the empty dish where it is")
	m.thaw(m.freezer_shelf.entries[0])
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes.size() == 1 and m.dishes[0] != emptied and m.dish == m.dishes[0], "thawing replaces the empty dish and brings the thawed one into view")
	m.toolbar.set_paused(false)
	fake.kill(m.dish.row)
	for i in 10:
		await process_frame
	TestUtil.check(m._extinct_queue.has(m.dish) or m.holds.has(&"end"), "the thawed dish dying out is noticed")
	m.queue_free()
	await process_frame
	await _save(fake)
	TestUtil.finish(self, "FREEZER TESTS OK")


## a goal-mode save has no freezer, and a load shows an empty one; the game's clock carries on across it.
func _save(fake: FakeWorld) -> void:
	SaveGame.delete(SCRATCH)
	Session.mode = Session.Mode.GOALS
	Session.load_requested = false
	var m: Node = load(Scenes.GAME).instantiate()
	m.save_path = SCRATCH
	root.add_child(m)
	m.toolbar.set_paused(false)
	for i in 30:
		await process_frame
	var bups: int = m.dish.population()
	var shown: float = m.world_time() - m.game_began
	m.save_game()
	var written: Variant = JSON.parse_string(FileAccess.get_file_as_string(SCRATCH))
	var keys: Array = (written as Dictionary).keys() if written is Dictionary else []
	keys.sort()
	TestUtil.check(keys == ["dish", "goals", "version"], "a save holds the dish and the goals, and no freezer (%s)" % [keys])
	m.queue_free()
	await process_frame
	fake.clock += 5000.0  # (the world runs on before the save is loaded)
	Session.mode = Session.Mode.GOALS
	Session.load_requested = true
	m = load(Scenes.GAME).instantiate()
	m.save_path = SCRATCH
	root.add_child(m)
	var carried: float = m.world_time() - m.game_began
	TestUtil.check(absf(carried - shown) < 1e-6 and shown > 0.0, "the game's clock carries on from the save (%.3f, saved at %.3f), not from the world's (%.1f)" % [carried, shown, m.world_time()])
	for i in 3:
		await process_frame
	TestUtil.check(m.freezer_shelf.entries.is_empty() and m.dish.population() == bups and bups > 0, "a loaded game has an empty freezer and the dish it saved (%d bups, saved %d)" % [m.dish.population(), bups])
	m.queue_free()
	await process_frame
	(written as Dictionary)["dish"]["format"] = DishCodec.FORMAT - 1
	var file := FileAccess.open(SCRATCH, FileAccess.WRITE)
	file.store_string(JSON.stringify(written))
	file.close()
	TestUtil.check(SaveGame.read(SCRATCH).is_empty() and not SaveGame.has_save(SCRATCH), "a save whose dish is of another format is no save")
	SaveGame.delete(SCRATCH)
