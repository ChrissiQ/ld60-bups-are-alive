extends SceneTree
## Run: godot --headless --path . -s tests/dish_strip_test.gd
## The strip and the tray's sections at a thousand dishes, over FakeWorld.
##
## Expected values, written before the first run:
##  - The strip is hidden with one dish and has k entries for k dishes; its count reads "k dishes".
##  - At 1,000 dishes it makes at most 40 tabs at every scroll position [derived: a strip of at most 1,199 px of tabs about 64 px apart
##    is 19 in view, plus one cut at each end and OVERSCAN (4) each side: 19 + 1 + 8 = 28 here, 40 the bound]; each tab made shows the
##    dish its place stands for.
##  - Bringing dish 700 into view scrolls its tab into view, lit, and no other made tab is lit; a click on a made tab brings its dish in.
##  - The strip's main-thread cost a frame (`refresh`) at 1,000 dishes is at most 1.5 x the single-dish path's at 20 [placeholder bound: the single-dish path's 2.5 us
##    measured headless with the SubViewport strip at 20 dishes, so at most 3.75 us].
##  - The all-dishes section reads the snapshot's totals: its update at 1,000 dishes costs no more than 1.5 x the single-dish path's loop at 20 dishes
##    [measured baseline: 68.8 us, so at most 103 us].
##  - The freezer at 1,000 frozen entries makes at most its rows in view and OVERSCAN (3) each side [derived from its row height], at the
##    top and in the middle of its list.

const STRIP_REFRESH_BOUND_US := 3.75
const ALL_DETAILS_BOUND_US := 103.0
const MOST_TABS := 40


func _initialize() -> void:
	_run()


func _time(call: Callable, n: int) -> float:
	var t := Time.get_ticks_usec()
	for i in n:
		call.call()
	return float(Time.get_ticks_usec() - t) / n


func _run() -> void:
	SimConstants.apply()
	TestUtil.use_fake_world(self)
	var chosen := TestUtil.small_start()
	chosen.bups = 10
	var m: Node = TestUtil.game_screen(self, chosen)
	await process_frame
	var strip: DishStrip = m.dish_strip
	TestUtil.check(not strip.visible and strip.count() == 1, "one dish: no strip")
	m.add_dish(chosen)
	m.add_dish(chosen)
	await process_frame
	TestUtil.check(strip.visible and strip.count() == 3 and strip.count_label.text == Strings.t("dish_strip.count", ["3"]), "three dishes: three entries and their count (%s)" % strip.count_label.text)
	while m.dishes.size() < 1000:
		m.add_dish(chosen)
	for i in 3:
		await process_frame
	TestUtil.check(strip.count() == 1000 and strip.count_label.text == Strings.t("dish_strip.count", ["1,000"]), "a thousand entries (%s)" % strip.count_label.text)
	var most := 0
	var wrong := 0
	var bar := strip.scroll.get_h_scroll_bar()
	for share in [0.0, 0.25, 0.5, 0.75, 1.0]:
		strip.scroll.scroll_horizontal = int(share * (bar.max_value - bar.page))
		await process_frame
		most = maxi(most, strip.tabs_made())
		for k in strip.tabs_made():
			var tab: Button = strip._tabs[k]
			if tab.text != Strings.t("dishes.caption", [m._dish_numbers[m.dishes[strip._first + k]]]):
				wrong += 1
	for i in 30:
		strip._step(7)
		most = maxi(most, strip.tabs_made())
	TestUtil.check(most <= MOST_TABS and most > 0, "at most %d tabs are made at any scroll position (%d)" % [MOST_TABS, most])
	TestUtil.check(wrong == 0, "each tab made shows the dish its place stands for (%d wrong)" % wrong)
	var far: Dish = m.dishes[700]
	m.set_main_dish(far)
	await process_frame
	await process_frame
	var lit := strip._tabs.filter(func(t: Button) -> bool: return t.button_pressed)
	TestUtil.check(lit.size() == 1 and int(lit[0].get_meta(&"entry")) == 700, "dish 700 in view: its tab is scrolled into view and lit, and no other")
	var other_tab: Button = strip._tabs[0] if int(strip._tabs[0].get_meta(&"entry")) != 700 else strip._tabs[1]
	var other_dish: Dish = m.dishes[int(other_tab.get_meta(&"entry"))]
	other_tab.pressed.emit()
	await process_frame
	TestUtil.check(m.dish == other_dish, "a click on a made tab brings its dish into view")
	var strip_us := _time(func() -> void: strip.refresh(1.0 / 60.0), 4000)
	TestUtil.check(strip_us <= STRIP_REFRESH_BOUND_US, "the strip's refresh at 1,000 dishes costs %.2f us a frame (bound %.2f)" % [strip_us, STRIP_REFRESH_BOUND_US])
	m.all_details.open = true
	var all_us := _time(func() -> void: m._update_all_details(), 2000)
	TestUtil.check(all_us <= ALL_DETAILS_BOUND_US, "the all-dishes section's update at 1,000 dishes costs %.1f us (bound %.1f)" % [all_us, ALL_DETAILS_BOUND_US])
	print("DISH STRIP figures: strip refresh %.2f us, all-dishes update %.1f us, tabs made at most %d" % [strip_us, all_us, most])

	var shelf: FreezerShelf = m.freezer_shelf
	m.freezer_section.open = true
	for i in 1000:
		shelf.entries.append({"number": 2000 + i, "data": {"time": 60.0 * i}, "bups": i, "picture": null})
	shelf.refresh()
	await process_frame
	await process_frame
	var in_view := ceili(FreezerShelf.SCROLL_MAX_HEIGHT / shelf._row_height) + 1
	var bound := in_view + 2 * FreezerShelf.OVERSCAN
	TestUtil.check(shelf.rows_made() <= bound and shelf.row_for(shelf.entries[0]) != null, "the freezer makes at most its rows in view and %d either side at the top (%d of %d, bound %d)" % [FreezerShelf.OVERSCAN, shelf.rows_made(), shelf.entries.size(), bound])
	shelf.scroll.scroll_vertical = int(500.0 * (shelf._row_height + float(shelf.list.get_theme_constant("separation"))))
	await process_frame
	await process_frame
	var middle := shelf.row_for(shelf.entries[500])
	TestUtil.check(shelf.rows_made() <= bound and middle != null and (middle.get_node("Row/Caption") as Label).text == Strings.t("hud.frozen_row", [2500, "500"]), "...and in the middle, where the rows show the entries there (%d made)" % shelf.rows_made())
	m.queue_free()
	await process_frame
	TestUtil.finish(self, "DISH STRIP TESTS OK")
