extends SceneTree
## Run: godot --headless --path . -s tests/view_choice_test.gd
## The game moves the main view on its own only so that something is on screen when the dish in view goes (frozen, trashed, died out); it never
## moves it off a dish the player chose, and never later, when an answer from the simulation comes (FakeWorld answers 4 frames after its command).
##
## Expected values [derived from the rule]:
##  - Three dishes, the first in view. It is frozen: the view goes to the one after it at once (the first has no one before it). The player then
##    picks the third, before the freeze has answered; once it has, and after an unfreeze asked meanwhile has shown its dish, the third is in view.
##  - A pipette from the first dish makes a second one when its answer comes: when the player is still looking at the first, the view goes to the
##    new dish; when they chose another dish while the answer was awaited, it stays on that dish and the new dish is parked, with its question asked.
##  - A dish out of view that dies out pauses the game and says which dish, with the view on the dish the player chose; resuming deletes it and the
##    view is still on that dish. A dish in view that dies out is the one shown, and resuming moves the view to its neighbour.


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var fake := TestUtil.use_fake_world(self)
	fake.reply_frames = 4
	var chosen := TestUtil.small_start()
	chosen.bups = 40
	chosen.nutrient_density = 40
	var m: Node = TestUtil.game_screen(self, chosen)
	await process_frame
	m.toolbar.set_paused(false)
	var first: Dish = m.dish
	var second: Dish = m.add_dish(chosen)
	var third: Dish = m.add_dish(chosen)
	for i in 3:
		await process_frame

	# A freeze that answers late, and an unfreeze after it.
	m.freeze_dish(first)
	TestUtil.check(m.dish == second and m.dishes.size() == 2, "freezing the dish in view brings its neighbour into view at once")
	m.set_main_dish(third)
	for i in 8:
		await process_frame
	TestUtil.check(m.freezer_shelf.entries.size() == 1 and not (m.freezer_shelf.entries[0]["reply"] as SimReply).value() == null, "the freeze has answered")
	TestUtil.check(m.dish == third, "the freeze's answer leaves the view on the dish chosen after the freeze")
	m.thaw(m.freezer_shelf.entries[0])
	m.set_main_dish(second)
	for i in 8:
		await process_frame
	TestUtil.check(m.dishes.size() == 3 and m.freezer_shelf.entries.is_empty(), "the unfrozen dish is among the running ones")
	TestUtil.check(m.dish == second, "an unfrozen dish showing up leaves the view on the dish chosen meanwhile")

	# A pipette whose answer comes after the player chose another dish.
	var home: Dish = m.dish
	var other: Dish = third
	var at: Array = []
	for i in 6:
		at.append(Vector2(i * 4.0, 0.0))
	fake.add_bups(home.row, at)
	await process_frame
	m.pipette(home.global_position + Vector2(8.0, 0.0), 30.0)
	m.set_main_dish(other)
	var count: int = m.dishes.size()
	for i in 8:
		await process_frame
	TestUtil.check(m.dishes.size() == count + 1 and m._old_dish == home, "the pipette made its dish and asks about the old one")
	TestUtil.check(m.dish == other, "the pipette's answer leaves the view on the dish chosen while it was awaited")
	var made: Dish = m.dishes.back()
	TestUtil.check(made.is_parked() and not made.visible, "...and the new dish waits parked")
	m._answer_old_dish("keep")
	# The same pipette with the player still on the dish it was made in: the view follows the bups.
	m.set_main_dish(home)
	fake.add_bups(home.row, at)
	await process_frame
	m.pipette(home.global_position + Vector2(8.0, 0.0), 30.0)
	for i in 8:
		await process_frame
	TestUtil.check(m.dish == m.dishes.back() and m.dish != home, "a pipette answered while the player is still on its dish brings the new dish into view")
	m._answer_old_dish("keep")

	# A dish out of view that dies out.
	m.set_main_dish(home)
	var dying: Dish = m.dishes.filter(func(d: Dish) -> bool: return d != home)[0]
	fake.kill(dying.row)
	for i in 8:
		await process_frame
	TestUtil.check(m._extinct_queue.has(dying) and m.paused and m.banner.text == Strings.t("hud.banner_dish_extinct", [m._dish_numbers[dying]]), "a dish out of view that dies out pauses the game and says which")
	TestUtil.check(m.dish == dying, "...and brings it into view, wherever the view was (a surprise, not the player's doing)")
	m.toolbar.set_paused(false)
	for i in 4:
		await process_frame
	TestUtil.check(not is_instance_valid(dying) and m.dish == home, "resuming deletes it and the view goes back to the dish the player chose")

	# The dish in view dying out is the one shown, and its neighbour comes into view when play resumes.
	var before: int = m.dishes.size()
	fake.kill(home.row)
	for i in 8:
		await process_frame
	TestUtil.check(m._extinct_queue.has(home) and m.dish == home and m.paused, "the dish in view dying out is the one shown")
	m.toolbar.set_paused(false)
	for i in 4:
		await process_frame
	TestUtil.check(m.dishes.size() == before - 1 and m.dish != home and m.dishes.has(m.dish), "resuming moves the view to a dish that is there")
	m.queue_free()
	await process_frame
	TestUtil.finish(self, "VIEW CHOICE TESTS OK")
