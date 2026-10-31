extends SceneTree
## Run: godot --headless --path . -s tests/dishes_test.gd
## Several dishes on the game screen (free mode), over FakeWorld (a small world kept on the main thread:
## SimService.use_backend): a second dish runs beside the main one, has a thumbnail in the strip, and a click on it brings it into the main
## view (the graph, the panels and the camera follow); dishes that die out; the pipette, whose answer comes a frame later; its timer.
##
## Expected values, written before the first run [derived from the rules in main.gd and FakeWorld; the fake's clock starts at 3,661 s and
## each frame stands for 1/60 s of real time, times the speed]:
##  - a second dish joins the set and the strip (2 tabs); every dish sits at the origin and only the main view's dish is shown (the
##    other is parked: hidden, not processing, nothing made to draw); the next-dish step wraps.
##  - dishes of 100 bups (every mean 10) and 300 bups (every mean 20) show a speed of (100 x 10 + 300 x 20) / 400 = 17.5 in the
##    all-dishes section, with 2 dishes and 400 bups [derived].
##  - The source tool: a click selects nothing at once (the world's copy has not come), and the source placed once it has (1-2 frames).
##  - At Main.MAX_DISHES (1,000) running: add, pipette and unfreeze are refused with banner.dish_limit, the dish actions show the warning,
##    and nothing changes (dish count, next number, no ADD_DISH, THAW or PIPETTE sent); a trash frees a row and both work again.
##  - the dishes have one clock: their times are equal after any frame, and both move while the game runs.
##  - a dish that dies out (FakeWorld.kill) out of view: the game pauses on it with banner "DISH 2 WENT EXTINCT", one `extinct`
##    signal however many snapshots say so; resuming sends one REMOVE_DISH for its row and deletes it; the view goes to the dish before it
##    (or back to the one being looked at); number 2 is not reused.
##  - the last dish dying out ends the game: the end dialog, and neither the pause button nor Space resumes; starting again strikes
##    a dish afresh (bups once a snapshot shows it).
##  - The pipette at (18, 0) with radius 30 over 10 bups at (4i, 0), 5 at (200 + i, 100), a parent at (300, 0) and its child
##    "Zed" at (12, 0) (watched) moves the 10 and the child: 11 in the new dish, 6 left of 17. Until its answer (one frame) the world waits
##    quietly (paused set_time, no input). Then the new dish is in view, numbered by the answer (the world's next number, past every dish
##    the world has had: the family tree's home of the moved bups), at the world's time, its history from
##    then; the child keeps its id, its name and its line [parent, child] and its place on the watch list (now the new dish's); the old
##    dish's question is up; the panel's line names the new dish; the old dish's lineage says 1 bup of the parent's line lives in dish 2.
##    A circle with no bups makes no dish: one REMOVE_DISH for the empty new row and "No bups there". A pipette the memory budget refuses
##    shows banner.memory_budget once and makes no dish.
##  - with the timer at 1 h and 1 s to go, at x100 (1.67 s a frame) the game pauses for the pipette within 20 frames and says so;
##    Space and a speed button do not resume; an empty pipette does not; one that moves bups holds the game until its question is answered,
##    and the answer resumes play.
##  - A dish added while a pipette's answer is awaited takes another number than the one the simulation gives the new dish.
##  - A size chosen for one dish goes to that dish; a layer key works with its buttons hidden; Follow centres the bup in the stage.
##  - The graph puts a dish's samples where the world took them: a history begun at world time 3,661 s with samples taken at 3,720.4,
##    3,840.2, 3,960.9 and 4,080.3 s (after the steps that crossed 3,720, 3,840, 3,960 and 4,080) shows them at 59, 179, 299 and 419 s of
##    the dish's own time, in the last-24-hours view and the whole-run view alike; with every dish together, in a game begun at 3,000 s,
##    at 720, 840, 960 and 1,080 s.

const EXTINCT_BANNER := "hud.banner_dish_extinct"


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
	TestUtil.check(m.dishes.size() == 1 and not m.dish_strip.visible, "one dish: no strip")
	m.toolbar.set_paused(false)
	var other: Dish = m.add_dish(chosen)
	TestUtil.check(m.dishes.size() == 2 and m.dish == first and m.dish_strip.visible and m.dish_strip.count() == 2, "a second dish joins the set and shows in the strip; the main view stays")
	TestUtil.check(other.position == Vector2.ZERO and first.position == Vector2.ZERO, "every dish sits at the screen's origin (what is drawn is in the main dish's own coordinates)")
	TestUtil.check(first.visible and not other.visible and other.is_parked() and not other.can_process() and other.drawing.bups_mesh == null, "only the dish in the main view is shown; the other is parked, does nothing a frame and has made nothing to draw")
	m._step_dish(1)
	TestUtil.check(m.dish == other, "the next-dish step goes to the second dish")
	m._step_dish(1)
	TestUtil.check(m.dish == first, "the next-dish step wraps to the first")
	m._step_dish(-1)
	TestUtil.check(m.dish == other, "the previous-dish step wraps to the last")
	m.set_main_dish(first)
	await process_frame
	var t0 := other.time
	var t1 := first.time
	for i in 30:
		await process_frame
	TestUtil.check(other.time > t0 and first.time > t1, "both dishes run (%.2f and %.2f s)" % [other.time - t0, first.time - t1])
	TestUtil.check(other.population() == 40, "the other dish has its bups (%d)" % other.population())
	TestUtil.check(other.time == first.time, "the dishes keep one clock (%.2f and %.2f s)" % [other.time, first.time])
	m.set_main_dish(other)
	TestUtil.check(m.dish == other and m.graph.dish == other and m.watch_list.dishes.has(other), "a choice brings the other dish into the main view, with the graph and the watch list")
	TestUtil.check(m.camera.position.distance_to(other.global_position) <= other.radius, "the camera is on it")
	m.dish_strip.dish_chosen.emit(first)
	TestUtil.check(m.dish == first and m.camera.position.distance_to(first.global_position) <= first.radius, "the strip's click brings the first back")
	m.set_main_dish(other)
	await process_frame
	m.set_main_dish(first)
	await process_frame
	var views := fake.calls_of(SimCommand.KIND_SET_VIEW)
	TestUtil.check(not views.is_empty() and int(views[-1]["args"]["row"]) == first.row, "a dish back in view tells the world afresh what it shows (the last view asked is its row)")

	# A dish that dies out: the game pauses on it and says so; resuming deletes it and goes to the dish before it.
	var third: Dish = m.add_dish(chosen)
	await process_frame
	TestUtil.check(m.dishes.size() == 3 and m.dish == first, "three dishes before one dies out")
	var signals := [0]
	other.extinct.connect(func() -> void: signals[0] += 1)
	var other_row: int = other.row
	fake.kill(other_row)
	for i in 5:
		await process_frame
	TestUtil.check(m.paused and m.dish == other and m.banner.text == Strings.t(EXTINCT_BANNER, [2]), "a dish that dies out out of view: the game pauses, shows it and says which (%s)" % m.banner.text)
	TestUtil.check(m.dishes.size() == 3 and not m.toolbar.resume_locked, "...and it stays until play is resumed")
	TestUtil.check(signals[0] == 1, "it says so once, though every snapshot since has it extinct (%d)" % signals[0])
	var removes_before := fake.calls_of(SimCommand.KIND_REMOVE_DISH).size()
	m.toolbar.set_paused(false)
	TestUtil.check(m.dishes.has(other), "(resuming deletes it a moment later)")
	for i in 3:
		await process_frame
	var removed := fake.calls_of(SimCommand.KIND_REMOVE_DISH).slice(removes_before)
	TestUtil.check(m.dishes.size() == 2 and not is_instance_valid(other), "resuming deletes the dish")
	TestUtil.check(removed.size() == 1 and removed[0]["args"]["row"] == other_row and not fake.rows().has(other_row), "...and takes it out of the world: one REMOVE_DISH for its row")
	TestUtil.check(m.dish == first and m.banner.text == "" and not m.paused, "the view goes to the dish before it, the banner clears and play goes on")
	TestUtil.check(m.dish_strip.count() == 2 and m._dish_numbers.values().has(3) and not m._dish_numbers.values().has(2), "its number is not reused or shown")
	fake.kill(first.row)
	for i in 5:
		await process_frame
	TestUtil.check(m.paused and m.dish == first and m.banner.text == Strings.t(EXTINCT_BANNER, [1]), "the first dish dies out: it is shown")
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes.size() == 1 and m.dish == third and not m.dish_strip.visible, "when the first of several goes, the next one comes into view")

	# The last dish dying out ends the game: nothing but starting again or quitting resumes.
	fake.kill(third.row)
	for i in 5:
		await process_frame
	TestUtil.check(m.holds.has(&"end") and m.paused and m.toolbar.resume_locked and m.end_dialog.visible, "the last dish dying out ends the game with the window up")
	m.toolbar.set_paused(false)
	m.toolbar._shortcut_input(TestUtil.key_event(KEY_SPACE))
	TestUtil.check(m.paused, "...and neither the pause button nor Space resumes it")
	m.end_dialog.confirmed.emit()
	await process_frame
	await process_frame
	TestUtil.check(not m.holds.has(&"end") and not m.toolbar.resume_locked and m.dish.population() > 0 and m.dishes.size() == 1, "starting again begins the dish afresh")

	# A dish that dies out while another is being looked at: afterwards the view goes back to what was being looked at, not to the dish before the dead one.
	var base: Dish = m.dish
	var dying: Dish = m.add_dish(chosen)
	var watched: Dish = m.add_dish(chosen)
	await process_frame
	m.set_main_dish(watched)
	m.toolbar.set_paused(false)
	fake.kill(dying.row)
	for i in 5:
		await process_frame
	TestUtil.check(m.paused and m.dish == dying, "a dish that dies out while another is in view is shown, as before")
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes.size() == 3 - 1 and m.dish == watched and not is_instance_valid(dying), "after it goes, the view is back on the dish that was being looked at, not the one before the dead dish")
	dying = m.add_dish(chosen)
	await process_frame
	fake.kill(dying.row)
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
	await process_frame
	first = m.dish
	TestUtil.check(m.dishes.size() == 1 and not m.dish_strip.visible, "a new game screen has one dish and no strip")
	await _pipette(m, fake, chosen)
	m.queue_free()
	await process_frame
	await _all_dishes_and_source(fake)
	await _limit(fake, chosen)
	_graph_times()
	TestUtil.finish(self, "DISHES TESTS OK")


## The all-dishes figures are every bup of every dish averaged (a dish counts by its bups), read from the snapshot. And the source tool
## selects the source it placed once the world's copy has it (it used to read the list before the copy came).
func _all_dishes_and_source(fake: FakeWorld) -> void:
	var start := TestUtil.small_start()
	start.bups = 100
	var m: Node = TestUtil.game_screen(self, start)
	await process_frame
	var more := TestUtil.small_start()
	more.bups = 300
	var second: Dish = m.add_dish(more)
	fake.means[m.dish.row] = 10.0
	fake.means[second.row] = 20.0
	m.all_details.open = true
	m.toolbar.set_paused(false)
	for i in 3:
		await process_frame
	m.readout.forget(m.vitals)
	m._update_hud()
	var totals: Dictionary = WorldClient.shared().latest().totals
	TestUtil.check(m.dish.population() == 100 and second.population() == 300 and is_equal_approx(float(totals["stats"]["speed"]), 17.5), "dishes of 100 and 300 bups with speeds 10 and 20 make a mean of 17.5 over every bup (%s)" % str(totals.get("stats", {}).get("speed")))
	TestUtil.check(m.all_rows._rows["speed"].value_text == TraitRows.format("speed", 17.5) and m.all_rows._rows["bups"].value_text == "400" and m.all_rows._rows["dishes"].value_text == "2", "the all-dishes section shows it, with 2 dishes and 400 bups")
	m.toolbar.select_tool(Toolbar.Tool.SOURCE)
	var at := Vector2(40.0, 30.0)
	m._click(at)
	TestUtil.check(m.dish.selected.source == null, "a placed source is not selected before the world's copy has it (and nothing breaks)")
	for i in 3:
		await process_frame
	var placed: NutrientSource = m.dish.selected.source
	TestUtil.check(placed != null and m.dish.sources.has(placed) and placed.pos.distance_to(at) < 0.01, "once the copy has it, the source placed is selected")
	fake.means.clear()
	m.queue_free()
	await process_frame


## At the limit (Main.MAX_DISHES running): adding a dish, a pipette and an unfreeze are refused with the banner and a warning under the dish
## actions, and change nothing (no dish, no number used, no command to the world); after a dish is trashed they work again.
func _limit(fake: FakeWorld, chosen: StartConditions) -> void:
	var m: Node = TestUtil.game_screen(self, chosen)
	await process_frame
	var spare: Dish = m.add_dish(chosen)
	while m.dishes.size() < m.MAX_DISHES:
		m.add_dish(chosen)
	await process_frame
	m.freeze_dish(spare)
	for i in 3:
		await process_frame
	m.add_dish(chosen)
	await process_frame
	m.toolbar.set_paused(false)
	await process_frame
	TestUtil.check(m.dishes.size() == m.MAX_DISHES and m.freezer_shelf.entries.size() == 1, "%d dishes run and one is frozen" % m.dishes.size())
	TestUtil.check(m.card_actions.limit_row.visible and m.freezer_shelf.actions.limit_row.visible, "the dish actions warn that the most dishes are running")
	var number_before: int = m._next_dish_number
	var adds := fake.calls_of(SimCommand.KIND_ADD_DISH).size()
	var thaws := fake.calls_of(SimCommand.KIND_THAW).size()
	var pipettes := fake.calls_of(SimCommand.KIND_PIPETTE).size()
	m.banner.text = ""
	TestUtil.check(m.add_dish(chosen) == null and m.banner.text == Strings.t("banner.dish_limit"), "adding a dish is refused with the banner (%s)" % m.banner.text)
	m.banner.text = ""
	m.pipette(Vector2.ZERO, 50.0)
	TestUtil.check(m._pipette_pending.is_empty() and m.banner.text == Strings.t("banner.dish_limit"), "a pipette is refused with the banner")
	m.banner.text = ""
	m.thaw(m.freezer_shelf.entries[0])
	TestUtil.check(m.freezer_shelf.entries.size() == 1 and not m.freezer_shelf.entries[0].has("thawing") and m.banner.text == Strings.t("banner.dish_limit"), "an unfreeze is refused with the banner, and the dish stays frozen")
	for i in 2:
		await process_frame
	TestUtil.check(m.dishes.size() == m.MAX_DISHES and m._next_dish_number == number_before and fake.calls_of(SimCommand.KIND_ADD_DISH).size() == adds and fake.calls_of(SimCommand.KIND_THAW).size() == thaws and fake.calls_of(SimCommand.KIND_PIPETTE).size() == pipettes, "...and none of them changed anything")
	m.trash_dish(m.dishes[5])
	await process_frame
	TestUtil.check(not m.card_actions.limit_row.visible, "with a dish fewer the warning goes")
	var again: Dish = m.add_dish(chosen)
	TestUtil.check(again != null and m.dishes.size() == m.MAX_DISHES, "and a dish can be added again")
	m.trash_dish(again)
	await process_frame
	var bups_at: Vector2 = fake.place_of(m.dish.row, fake.ids_in(m.dish.row)[0])
	m.pipette(bups_at, 30.0)
	TestUtil.check(fake.calls_of(SimCommand.KIND_PIPETTE).size() == pipettes + 1, "and a pipette is sent again")
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes.size() == m.MAX_DISHES and m._old_dish != null, "...and makes its dish (%d running)" % m.dishes.size())
	m._answer_old_dish("keep")
	m.trash_dish(m.dishes[7])
	m.thaw(m.freezer_shelf.entries[0])
	for i in 3:
		await process_frame
	TestUtil.check(m.freezer_shelf.entries.is_empty() and m.dishes.size() == m.MAX_DISHES, "and a frozen dish unfrozen")
	m.queue_free()
	await process_frame


## The graph's times of a dish's samples, which the world takes at the multiples of DishHistory.INTERVAL of its own clock.
func _graph_times() -> void:
	var d := Dish.new()
	var other := Dish.new()
	for one: Dish in [d, other]:
		one.history.begin(3661.0)
		for t: float in [3720.4, 3840.2, 3960.9, 4080.3]:
			one.history.record(t, FakeScenes.stats(10))
		one.time = 4090.0
	var graph := HistoryGraph.new()
	graph.dish = d
	var xs := func(points: PackedVector2Array) -> Array: return Array(points).map(func(p: Vector2) -> float: return snappedf(p.x, 0.01))
	var fine: Array = xs.call(graph._series("pop", 0.0, HistoryGraph.Span.LAST_24))
	var whole: Array = xs.call(graph._series("pop", 0.0, HistoryGraph.Span.ALL))
	TestUtil.check(fine == [59.0, 179.0, 299.0, 419.0] and whole == fine, "the graph puts a dish's samples at the world's multiples, on the dish's own clock (%s, whole run %s)" % [fine, whole])
	graph.dishes = [d, other]
	graph.all_dishes = true
	graph.game_began = 3000.0
	var together: Array = xs.call(graph._series("pop", 0.0, HistoryGraph.Span.LAST_24))
	var counts: Array = Array(graph._series("pop", 0.0, HistoryGraph.Span.LAST_24)).map(func(p: Vector2) -> float: return p.y)
	TestUtil.check(together == [720.0, 840.0, 960.0, 1080.0] and counts == [20.0, 20.0, 20.0, 20.0], "with every dish together they are on the game's clock, and summed (%s, %s)" % [together, counts])
	for node: Node in [d, other, graph]:
		node.free()


## The pipette, its timer, and what follows.
func _pipette(m: Node, fake: FakeWorld, chosen: StartConditions) -> void:
	var first: Dish = m.dish
	var row: int = first.row
	fake.kill(row)  # (and new bups at once: no snapshot sees the dish empty)
	var at: Array = []
	for i in 10:
		at.append(Vector2(i * 4.0, 0.0))
	for i in 5:
		at.append(Vector2(200.0 + i, 100.0))
	fake.add_bups(row, at)
	var parent: int = fake.add_bups(row, [Vector2(300.0, 0.0)])[0]  # (a bup with a parent, a name and a place on the watch list: all must go with it)
	var child: int = fake.add_bups(row, [Vector2(12.0, 0.0)], parent)[0]
	first.rename_bup(child, "Zed")
	first.watch_bup(child)
	await process_frame
	await process_frame
	var before := first.population()
	var was_paused: bool = m.paused
	m.pipette(first.global_position + Vector2(18.0, 0.0), 30.0)
	TestUtil.check(m.holds.stills_world() and m.dishes.size() == 1 and m.hud_layer.process_mode == Node.PROCESS_MODE_DISABLED and m.paused == was_paused, "the pipette's answer comes later: meanwhile the game waits quietly (the pause button as it was)")
	TestUtil.check(fake.calls_of(SimCommand.KIND_PIPETTE).size() == 1 and fake.calls_of(SimCommand.KIND_PIPETTE)[0]["args"]["centre"] == Vector2(18.0, 0.0), "the simulation is asked to move the bups within the circle (dish-local)")
	var early: Dish = m.add_dish(chosen)  # (a dish added before the answer: it must not take the new dish's number)
	await process_frame
	TestUtil.check(fake.calls_of(SimCommand.KIND_SET_TIME)[-1]["args"]["paused"], "the world stands still while the pipette's answer is awaited")
	await process_frame
	var made: Dish = m.dish
	TestUtil.check(made != first and made != early and m.dishes.size() == 3 and m._dish_numbers[made] == fake.store.info(child)["home"] and m._dish_numbers[early] != m._dish_numbers[made], "the pipette makes a dish numbered by the simulation's answer, and the dish added meanwhile another (%d, %d)" % [m._dish_numbers.get(made, -1), m._dish_numbers.get(early, -1)])
	m.trash_dish(early)
	TestUtil.check(made.has_bup(child) and made.bup_name(child) == "Zed" and made.lineage_chain(child) == PackedInt64Array([parent, child]), "a moved bup is the same bup: its id, its name and its family line come with it")
	TestUtil.check(made.is_watched(child) and not first.is_watched(child) and m.watch_list.dishes.has(made), "...and so does its place on the watch list")
	TestUtil.check(m.dish == made, "the main view moves to the new dish")
	TestUtil.check(made.time == first.time, "the new dish is at the world's time (%.1f and %.1f s)" % [made.time, first.time])
	TestUtil.check(made.history.origin == first.time, "the new dish's history begins at the world's time (%.1f s)" % made.history.origin)
	m.graph.dish = made
	m.graph.dishes = m.dishes
	m.graph.all_dishes = false
	TestUtil.check(m.graph._now() < 1.0 and m.graph._series("pop", 0.0, HistoryGraph.Span.ALL).size() <= 1, "the graph of the new dish counts its own time, not the world's (%.1f s)" % m.graph._now())
	await process_frame
	TestUtil.check(made.population() == 11 and first.population() == 6 and before == 17, "the bups in the circle moved (%d in the new dish, %d left of %d)" % [made.population(), first.population(), before])
	TestUtil.check(m.old_dish_dialog.visible and m._old_dish == first and m.paused, "the pipette asks what to do with the old dish, and the game holds until it is answered")
	m._answer_old_dish("keep")
	TestUtil.check(not m.old_dish_dialog.visible and m.dishes.has(first) and m.paused, "keeping it leaves both dishes there, and the game as paused as it was")
	var moved_id: int = made.bup_ids()[0]
	made.selected.bup = moved_id
	for i in 3:  # (the dish asks after the frame's snapshot was published: the answer comes in the one after)
		await process_frame
	TestUtil.check(not made.bup_info(moved_id).is_empty() and PanelText.bup(made.bup_info(moved_id), m._dish_numbers[made]).contains("dish %d" % m._dish_numbers[made]), "a bup's panel says which dish it is in now (dish %d)" % m._dish_numbers[made])
	made.selected.bup = -1
	var seen_from: float = made.view_zoom
	m.camera.zoom = Vector2.ONE * 0.37
	m.camera.position = made.global_position + Vector2(40.0, -25.0)
	m.set_main_dish(first)
	m.camera.zoom = Vector2.ONE * 0.9
	m.camera.position = first.global_position + Vector2(-70.0, 15.0)
	m.set_main_dish(made)
	TestUtil.check(is_equal_approx(m.camera.zoom.x, 0.37) and m.camera.position.is_equal_approx(made.global_position + Vector2(40.0, -25.0)), "switching back to a dish returns to where and how close it was looked at (zoom %.2f, was %.2f)" % [m.camera.zoom.x, seen_from])
	m.layers_panel.layer_toggled.emit(Dish.Layer.BUPS, false)
	var third_dish: Dish = m.add_dish(chosen)
	TestUtil.check(not first.layer_shown(Dish.Layer.BUPS) and not made.layer_shown(Dish.Layer.BUPS) and not third_dish.layer_shown(Dish.Layer.BUPS), "what is shown is one choice for every dish, new ones too")
	m.layers_panel.layer_toggled.emit(Dish.Layer.BUPS, true)
	await process_frame
	await process_frame
	TestUtil.check(m.dish_strip.get_global_rect().position.y >= m.get_node("%TopBar").get_global_rect().position.y and m.get_node("%TopBar").get_global_rect().encloses(m.dish_strip.get_global_rect()), "the tabs of the dishes sit inside the top bar (%s in %s)" % [m.dish_strip.get_global_rect(), m.get_node("%TopBar").get_global_rect()])
	m.set_main_dish(first)
	var elsewhere: Dictionary = m.lineage.alive_elsewhere(first.lineage_chain(parent))
	TestUtil.check(elsewhere.get(parent, []) == [[1, m._dish_numbers[made]]], "a lineage entry says how many bups of that line are alive in another dish (%s)" % [elsewhere])
	var removes_before := fake.calls_of(SimCommand.KIND_REMOVE_DISH).size()
	m.pipette(first.global_position + Vector2(5000.0, 5000.0), 30.0)
	await process_frame
	await process_frame
	var removed := fake.calls_of(SimCommand.KIND_REMOVE_DISH).slice(removes_before)
	TestUtil.check(m.dishes.size() == 3 and removed.size() == 1 and m.banner.text == Strings.t("hud.banner_pipette_empty"), "a circle with no bups makes no dish (its empty new dish leaves the world)")
	fake.refuse_next(SimCommand.KIND_PIPETTE)
	m.pipette(first.global_position, 250.0)
	for i in 3:
		await process_frame
	TestUtil.check(m.dishes.size() == 3 and m.banner.text == Strings.t("banner.memory_budget") and not m.holds.stills_world(), "a pipette the graphics memory has no room for makes no dish and says why (%s)" % m.banner.text)

	# The pipette timer: the game pauses for the pipette after the set hours, Space cannot resume, and a pipette that moves something does.
	m._set_pipette_timer(1.0)
	m.toolbar.set_paused(false)
	m._pipette_clock = 3599.0
	fake.add_bups(first.row, [Vector2.ZERO])
	m.sim_speed = 100.0
	for i in 20:
		await process_frame
	TestUtil.check(m.holds.has(&"pipette") and m.paused and m.toolbar.resume_locked and m.vitals.get_parsed_text().contains(Strings.t("hud.pipette_paused")), "after the hours the game pauses and says so in the top bar")
	m.toolbar._shortcut_input(TestUtil.key_event(KEY_SPACE))
	m.toolbar.speed_1000_button.button_pressed = true
	TestUtil.check(m.paused, "neither Space nor a speed button resumes while it waits")
	m.pipette(first.global_position + Vector2(5000.0, 5000.0), 30.0)
	for i in 2:
		await process_frame
	TestUtil.check(m.holds.has(&"pipette") and m.paused, "a pipette that moves nothing does not resume it")
	TestUtil.check(m.dish == first, "an empty pipette leaves the view where it is")
	m.pipette(first.global_position, 250.0)
	for i in 2:
		await process_frame
	var again: Dish = m.dish
	TestUtil.check(again != first and m.paused and m.holds.has(&"pipette") and m.old_dish_dialog.visible, "a pipette that moves bups holds the game until its question is answered")
	m._answer_old_dish("keep")
	TestUtil.check(m.dish == again and not m.holds.has(&"pipette") and not m.paused and not m.toolbar.resume_locked, "...and the answer resumes play (waiting %s, paused %s, locked %s)" % [m.holds.has(&"pipette"), m.paused, m.toolbar.resume_locked])
	m._set_pipette_timer(0.0)
	m.sim_speed = 1.0

	# A size chosen for a dish goes to that dish, whichever is in view when it arrives.
	var sized: Dish = m.dishes[0]
	var viewed: Dish = m.dishes[1]
	m.set_main_dish(viewed)
	var viewed_radius: float = viewed.radius
	m._resize_dish(sized, 2000.0)
	TestUtil.check(sized.radius == 2000.0 and viewed.radius == viewed_radius, "a size chosen for one dish does not resize the one in view")
	# A layer's key flips it with the layer buttons hidden (a shortcut does not reach a hidden button).
	m.layers_panel.get_parent().get_parent().visible = false
	var key := TestUtil.key_event(KeyBindings.key("layer_medium"))
	var shown: bool = viewed.layer_shown(Dish.Layer.MEDIUM)
	m._on_key(key)
	TestUtil.check(viewed.layer_shown(Dish.Layer.MEDIUM) == not shown, "a layer key works with its buttons hidden")
	m._on_key(key)
	m.layers_panel.get_parent().get_parent().visible = true
	var followed: Dish = m.dish
	var followed_id: int = followed.bup_ids()[0]
	followed.selected.bup = followed_id
	for i in 3:
		await process_frame
	m.stage_input.toggle_follow()
	var cam: Camera2D = m.stage_input.camera
	var on_screen: Vector2 = (followed.bup_world_pos(m.stage_input.following_id) - cam.position) * cam.zoom.x + m.get_viewport().get_visible_rect().size * 0.5
	TestUtil.check(not followed.bup_info(followed_id).is_empty() and followed.bup_world_pos(followed_id) != followed.global_position, "the followed bup's place has come")
	TestUtil.check(m.stage_input.following_id >= 0 and on_screen.distance_to(m.stage.get_global_rect().get_center()) < 1.0, "Follow puts the bup in the middle of the stage the tray leaves clear (%s, %s)" % [on_screen, m.stage.get_global_rect().get_center()])
