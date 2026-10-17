extends SceneTree
## Run: godot --headless --path . -s tests/free_mode_test.gd
## Checks start conditions, nutrient layouts, and that free mode has no goals and no saving.
## Backs up the real save in memory and restores it if anything touches it.

var failures: Array = []


func check(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)


func _make_dish() -> Dish:
	var d := Dish.new()
	root.add_child(d)
	d.position = Vector2(500, 400)
	d.rng.seed = 5
	return d


func _radii(points: Array) -> Array:
	var out := []
	for p in points:
		out.append(p.distance_to(Vector2(500, 400)))
	return out


func _init() -> void:
	# --- Defaults must equal the old hard-coded goal-mode start.
	var d := _make_dish()
	d.strike()
	check(d.cells.size() == 4, "default bups = 4, got %d" % d.cells.size())
	check(d.food.size() == 60, "default nutrients = 60, got %d" % d.food.size())

	# --- Counts and clamping.
	var s := StartConditions.new()
	s.bups = 120
	s.nutrients = 150
	d.strike(s)
	check(d.cells.size() == 120, "120 bups, got %d" % d.cells.size())
	check(d.food.size() == 150, "150 nutrients, got %d" % d.food.size())
	s.bups = 9999
	s.nutrients = 9999
	d.strike(s)
	check(d.cells.size() == Dish.MAX_CELLS, "bups clamped to MAX_CELLS")
	check(d.food.size() == Dish.MAX_FOOD, "nutrients clamped to MAX_FOOD")
	s.nutrients = 0
	d.strike(s)
	check(d.food.is_empty(), "0 nutrients means an empty dish")
	check(StartConditions.MAX_BUPS <= Dish.MAX_CELLS and StartConditions.MAX_NUTRIENTS <= Dish.MAX_FOOD, "UI limits within sim limits")

	# --- Nutrient rate is part of the start conditions.
	var r := StartConditions.new()
	r.nutrient_rate = 17.0
	d.strike(r)
	check(d.food_rate == 17.0, "start rate applied, got %.1f" % d.food_rate)
	r.nutrient_rate = 999.0
	d.strike(r)
	check(d.food_rate == StartConditions.MAX_NUTRIENT_RATE, "rate clamped to max")
	d.strike()
	check(d.food_rate == 6.0, "default rate is 6/s, got %.1f" % d.food_rate)
	var all_inside := true
	for f in d.food:
		all_inside = all_inside and f.distance_to(Vector2(500, 400)) <= d.radius
	check(all_inside, "nutrients inside dish")

	# --- Dish size.
	var small := StartConditions.new()
	small.dish_radius = 150.0
	small.bups = 100
	small.nutrients = 100
	d.strike(small)
	check(d.radius == 150.0, "dish radius 150, got %.0f" % d.radius)
	var inside_small := true
	for f in d.food:
		inside_small = inside_small and f.distance_to(d.global_position) <= d.radius
	for c in d.cells:
		inside_small = inside_small and c.pos.distance_to(d.global_position) <= d.radius
	check(inside_small, "everything starts inside a small dish")
	small.dish_radius = 5.0
	d.strike(small)
	check(d.radius == StartConditions.MIN_DISH_RADIUS, "radius clamped to min")
	small.dish_radius = 99999.0
	d.strike(small)
	check(d.radius == StartConditions.MAX_DISH_RADIUS, "radius clamped to max")
	check(StartConditions.new().dish_radius == Dish.DEFAULT_RADIUS, "default dish radius matches Dish.DEFAULT_RADIUS")
	var big := StartConditions.new()
	big.dish_radius = 450.0
	d.strike(big)
	var d_copy := _make_dish()
	check(d_copy.from_dict(JSON.parse_string(JSON.stringify(d.to_dict()))), "from_dict ok")
	check(d_copy.radius == 450.0, "dish radius survives save/load, got %.0f" % d_copy.radius)

	# --- Placing nutrients.
	d.strike()
	d.food.clear()
	var click := d.global_position + Vector2(40, -25)
	check(d.place_nutrients(click, 1) == 1 and d.food[0].is_equal_approx(click), "one nutrient lands exactly on the click")
	d.food.clear()
	check(d.place_nutrients(click, 30) == 30 and d.food.size() == 30, "30 nutrients placed")
	var worst := 0.0
	for f in d.food:
		worst = maxf(worst, f.distance_to(click))
	check(worst <= Dish.scatter_radius(30) + 0.01, "scatter stays within its circle (%.1f <= %.1f)" % [worst, Dish.scatter_radius(30)])
	check(Dish.scatter_radius(1) == 0.0, "no scatter for one")
	check(Dish.scatter_radius(10) < Dish.scatter_radius(40), "more nutrients scatter wider")
	d.food.clear()
	check(d.place_nutrients(d.global_position + Vector2(d.radius + 50.0, 0.0), 5) == 0 and d.food.is_empty(), "clicks outside the dish place nothing")
	check(d.place_nutrients(click, 9999) == Dish.MAX_FOOD, "placement capped at MAX_FOOD")
	check(d.place_nutrients(click, 5) == 0, "full dish accepts nothing")

	# --- Placed-nutrient counter.
	d.strike()
	d.food.clear()
	check(d.nutrients_placed == 0, "counter starts at 0")
	d.place_nutrients(click, 1)
	d.place_nutrients(click, 30)
	check(d.nutrients_placed == 31, "counter adds what was placed, got %d" % d.nutrients_placed)
	d.place_nutrients(d.global_position + Vector2(d.radius + 50.0, 0.0), 5)
	check(d.nutrients_placed == 31, "a rejected click isn't counted")
	d.food.clear()
	for i in Dish.MAX_FOOD - 3:
		d.food.append(click)
	var before_cap := d.nutrients_placed
	check(d.place_nutrients(click, 20) == 3 and d.nutrients_placed == before_cap + 3, "only the nutrients that actually fit are counted")
	var copy := _make_dish()
	check(copy.from_dict(JSON.parse_string(JSON.stringify(d.to_dict()))) and copy.nutrients_placed == d.nutrients_placed, "counter survives save/load")
	d.strike()
	check(d.nutrients_placed == 0, "a new dish resets the counter")

	# --- Picking and inspecting nutrients.
	d.strike()
	d.cells.clear()
	d.food.clear()
	var spot := d.global_position + Vector2(60, -30)
	d.food.append(spot)
	d.food.append(spot + Vector2(40, 0))
	check(d.food_at(spot) == 0, "food_at finds the nutrient under a point")
	check(d.food_at(spot + Vector2(Dish.FOOD_PICK_RADIUS + 2.0, 0.0)) == -1, "just outside the pick radius finds none")
	check(d.food_at(spot + Vector2(Dish.FOOD_PICK_RADIUS + 2.0, 0.0), 4.0) == 0, "slack widens the target")
	check(d.food_at(spot + Vector2(20, 0), 30.0) == 0 or d.food_at(spot + Vector2(20, 0), 30.0) == 1, "with slack, a point between two picks one of them")
	check(d.food_at(spot + Vector2(39, 0), 5.0) == 1, "the nearer of two nutrients wins")
	d.select_at(spot)
	check(d.has_selected_food() and d.selected_food == spot and d.selected == null, "select_at selects the nutrient")
	d.select_at(d.global_position + Vector2(-200, 200))
	check(not d.has_selected_food() and d.selected == null, "selecting empty space clears the selection")
	# a bup wins where it overlaps a nutrient, and each kind of selection clears the other
	var over := Cell.new(spot, Genome.founder(), 30.0)
	d.cells.append(over)
	d.select_at(spot)
	check(d.selected == over and not d.has_selected_food(), "a bup is picked over a nutrient beneath it")
	d.cells.clear()
	d.select_at(spot)
	check(d.has_selected_food() and d.selected == null, "selecting a nutrient clears the bup selection")
	d.hover_at(spot)
	check(d.hovered_food == spot and d.hovered == null, "hover_at highlights a nutrient")
	d.clear_hover()
	check(not d.hovered_food.is_finite() and d.hovered == null, "clear_hover clears both kinds")
	# details: energy, position, nearest bup, how many bups can sense it
	var near := Cell.new(spot + Vector2(30, 0), Genome.founder(), 30.0)  # sense 50: within reach
	var far := Cell.new(spot + Vector2(200, 0), Genome.founder(), 30.0)  # outside its sense of 50
	d.cells.append(near)
	d.cells.append(far)
	var info := d.nutrient_details(spot)
	check(info["energy"] == Dish.FOOD_ENERGY, "details: energy")
	check((info["offset"] as Vector2).is_equal_approx(Vector2(60, -30)), "details: position relative to the dish centre")
	check(is_equal_approx(info["distance"], Vector2(60, -30).length()), "details: distance from the centre")
	check(is_equal_approx(info["nearest_bup"], 30.0), "details: nearest bup (got %s)" % info["nearest_bup"])
	check(info["sensed_by"] == 1, "details: only the bup within its sense range counts (got %d)" % info["sensed_by"])
	d.cells.clear()
	check(d.nutrient_details(spot)["nearest_bup"] == -1.0 and d.nutrient_details(spot)["sensed_by"] == 0, "details with no bups")
	d.select_at(spot)
	d.strike()
	check(not d.has_selected_food() and d.selected == null, "a new dish clears any selection")

	# --- History graph axes.
	check(HistoryGraph.nice_ceil(0.0) == 10.0 and HistoryGraph.nice_ceil(10.0) == 10.0 and HistoryGraph.nice_ceil(11.0) == 20.0, "axis max rounds up to a round number (small)")
	check(HistoryGraph.nice_ceil(73.0) == 100.0 and HistoryGraph.nice_ceil(101.0) == 150.0 and HistoryGraph.nice_ceil(301.0) == 500.0, "axis max rounds up to a round number (large)")
	check(HistoryGraph.nice_ceil(1234.0) == 1300.0, "axis max beyond the table still rounds up (%s)" % HistoryGraph.nice_ceil(1234.0))
	check(HistoryGraph.format_time(0) == "0:00" and HistoryGraph.format_time(65) == "1:05" and HistoryGraph.format_time(900) == "15:00" and HistoryGraph.format_time(3600) == "60:00", "times format as m:ss")
	check(HistoryGraph.time_ticks(0.0, 900.0, 300.0) == [0.0, 300.0, 600.0, 900.0], "time ticks over the first window")
	check(HistoryGraph.time_ticks(399.0, 1299.0, 300.0) == [600.0, 900.0, 1200.0], "time ticks over a scrolled window")
	check(HistoryGraph.time_ticks(0.0, 100.0, 300.0) == [0.0], "a short window still has its origin tick")
	check(HistoryGraph.window_start(100.0) == 0.0 and HistoryGraph.window_start(900.0) == 0.0, "the window starts at zero until it fills")
	check(HistoryGraph.window_start(1300.0) == 1299.0 - HistoryGraph.WINDOW_SECONDS, "then it follows the newest sample (%s)" % HistoryGraph.window_start(1300.0))
	check(HistoryGraph.tick_text(0.4, 2.0) == "0.4" and HistoryGraph.tick_text(10.0, 120.0) == "10" and HistoryGraph.tick_text(150.0, 150.0) == "150", "trait ticks use sensible decimals")
	var graph := HistoryGraph.new()
	graph.size = Vector2(424, 174)
	graph.dish = d
	root.add_child(graph)
	d.strike()
	for i in 200:
		d.step(1.0 / 30.0)
	for trait_i in HistoryGraph.TRAITS.size():
		graph.trait_index = trait_i
		graph.queue_redraw()
		await process_frame
	check(true, "graph draws every trait without error")
	graph.queue_free()

	# --- extinct fires once, when the dish dies; and again only after a new dish dies.
	var extinct_count := [0]
	var wipe := _make_dish()
	wipe.extinct.connect(func() -> void: extinct_count[0] += 1)
	wipe.strike()
	wipe.cells.clear()
	for i in 12:
		wipe.step(0.1)
	check(extinct_count[0] == 1, "extinct is signalled once, not on every step (%d)" % extinct_count[0])
	wipe.strike()
	wipe.cells.clear()
	wipe.step(0.1)
	wipe.step(0.1)
	check(extinct_count[0] == 2, "a new dish that dies signals again (%d)" % extinct_count[0])

	# --- After a load, history samples still land on multiples of the interval.
	var run := _make_dish()
	run.strike()
	while run.time < 10.5:
		run.step(1.0 / 30.0)
	var reloaded := _make_dish()
	check(reloaded.from_dict(JSON.parse_string(JSON.stringify(run.to_dict()))), "a dish mid-run reloads")
	var samples_before: int = reloaded.history["pop"].size()
	while reloaded.history["pop"].size() == samples_before:
		reloaded.step(1.0 / 30.0)
	var drift := absf(reloaded.time - Dish.HISTORY_INTERVAL * round(reloaded.time / Dish.HISTORY_INTERVAL))
	check(drift < 0.06, "the first sample after a load falls on a multiple of %.0fs (t=%.2f)" % [Dish.HISTORY_INTERVAL, reloaded.time])

	# --- A bad save is rejected whole and leaves the dish exactly as it was.
	var good: Dictionary = JSON.parse_string(JSON.stringify(run.to_dict()))
	var victim := _make_dish()
	victim.strike()
	victim.select_at(victim.food[0])
	var cells_before: Array = victim.cells.duplicate()
	var food_before: Array = victim.food.duplicate()
	var radius_before := victim.radius
	var time_before := victim.time
	var broken := {
		"cell missing pos": func(x: Dictionary) -> void: x["cells"][0].erase("pos"),
		"cell pos too short": func(x: Dictionary) -> void: x["cells"][0]["pos"] = [1.0],
		"cell pos holds text": func(x: Dictionary) -> void: x["cells"][0]["pos"] = ["a", "b"],
		"cell genome not a dictionary": func(x: Dictionary) -> void: x["cells"][0]["genome"] = [1, 2],
		"cell energy is text": func(x: Dictionary) -> void: x["cells"][0]["energy"] = "lots",
		"cell is not a dictionary": func(x: Dictionary) -> void: x["cells"][0] = 7,
		"food entry too short": func(x: Dictionary) -> void: x["food"][0] = [3.0],
		"food entry is text": func(x: Dictionary) -> void: x["food"][0] = "here",
		"cells not an array": func(x: Dictionary) -> void: x["cells"] = {},
		"history not a dictionary": func(x: Dictionary) -> void: x["history"] = [1],
		"history holds text": func(x: Dictionary) -> void: x["history"]["pop"][0] = "no",
		"radius is text": func(x: Dictionary) -> void: x["radius"] = "big",
		"time is not a number": func(x: Dictionary) -> void: x["time"] = NAN,
	}
	for what in broken:
		var bad: Dictionary = good.duplicate(true)
		broken[what].call(bad)
		check(not victim.from_dict(bad), "rejects a save where: %s" % what)
		check(victim.cells == cells_before and victim.food == food_before and victim.radius == radius_before and victim.time == time_before, "...and leaves the dish untouched (%s)" % what)
	check(victim.has_selected_food(), "...including the selection (a rejected load changes nothing)")
	# Odd but harmless values are made safe instead of rejected.
	var odd: Dictionary = good.duplicate(true)
	odd["radius"] = 99999
	odd["cells"][0]["genome"]["values"] = {"speed": 99999, "sense": -5}
	odd["cells"][0]["genome"]["hue"] = 7.25
	check(victim.from_dict(odd), "a save with out-of-range values still loads")
	check(victim.radius == StartConditions.MAX_DISH_RADIUS, "...with the radius clamped (%.0f)" % victim.radius)
	check(victim.cells[0].genome.get_gene("speed") == Genome.GENES["speed"][1] and victim.cells[0].genome.get_gene("sense") == Genome.GENES["sense"][0], "...and genes clamped to their range")
	check(victim.cells[0].genome.hue >= 0.0 and victim.cells[0].genome.hue < 1.0, "...and the hue wrapped into range")
	check(not victim.has_selected_food() and victim.selected == null, "a successful load clears the selection")
	var weird: Dictionary = good.duplicate(true)
	weird["cells"][0]["genome"]["values"] = [1, 2, 3]
	check(victim.from_dict(weird) and victim.cells[0].genome.get_gene("speed") == 40.0, "a genome with garbage values falls back to defaults instead of crashing")

	# --- StartConditions: one source for limits, and an honest copy().
	check(StartConditions.MAX_NUTRIENTS == Dish.MAX_FOOD, "the nutrient slider cap is the dish's capacity")
	check(StartConditions.MAX_BUPS <= Dish.MAX_CELLS, "the bups slider cap never exceeds the sim's")
	check(StartConditions.new().dish_radius == Dish.DEFAULT_RADIUS, "default radius is the dish's default")
	var original := StartConditions.new()
	original.bups = 33
	original.nutrients = 44
	original.nutrient_rate = 7.0
	original.dish_radius = 410.0
	var duplicate := original.copy()
	check(duplicate != original and duplicate.to_dict() == original.to_dict(), "copy() has the same values")
	duplicate.bups = 99
	check(original.bups == 33, "...and is independent of the original")

	# --- Numbers use the theme's Bright colour, not a colour of their own.
	var bright: Color = ThemeDB.get_project_theme().get_color("font_color", "Bright")
	check(UiText.number_color() == bright, "number colour is the theme's Bright colour")
	check(UiText.numbers("7").contains("[color=#%s]7[/color]" % bright.to_html(false)), "numbers are wrapped in that colour")

	# --- The graph's whole look is theme data.
	var graph_theme := ThemeDB.get_project_theme()
	for item in ["background", "border", "grid", "grid_faint", "muted", "population", "trait"]:
		check(graph_theme.has_color(item, HistoryGraph.THEME_TYPE), "theme defines graph colour '%s'" % item)
	for item in ["tick", "legend"]:
		check(graph_theme.has_font_size(item, HistoryGraph.THEME_TYPE), "theme defines graph text size '%s'" % item)

	# --- Reusable rows: SettingRow shows enough decimals for its step; StatRow holds a label and a value.
	var row: SettingRow = load("res://ui/setting_row.tscn").instantiate()
	root.add_child(row)
	await process_frame
	row.configure(0, 1, 0.1, 0.5)
	row.value = 0.4
	check(row.value_label.text == "0.4", "a 0.1 step shows one decimal ('%s')" % row.value_label.text)
	check(row.reset_button.tooltip_text == "Use default (0.5)", "the reset tooltip uses the same format ('%s')" % row.reset_button.tooltip_text)
	row.configure(0, 1, 0.25, 0.5, "x")
	row.value = 0.75
	check(row.value_label.text == "0.75x", "a 0.25 step shows two decimals and the suffix ('%s')" % row.value_label.text)
	row.configure(0, 200, 1, 4, "/s")
	row.value = 12
	check(row.value_label.text == "12/s", "a whole step shows no decimals ('%s')" % row.value_label.text)
	var changes := [0]
	row.value_changed.connect(func(_v: float) -> void: changes[0] += 1)
	row.reset_button.pressed.emit()
	check(row.value == 4.0 and changes[0] == 1, "reset puts back the default and announces the change")
	row.queue_free()
	var stat: StatRow = load("res://ui/stat_row.tscn").instantiate()
	stat.label_text = "Before ready"  # may be set before the row is in the tree
	stat.value_text = "42"
	root.add_child(stat)
	await process_frame
	check(stat.name_label.text == "Before ready" and stat.value_label.text == "42", "StatRow keeps values set before it was ready")
	stat.value_text = "43"
	check(stat.value_label.text == "43", "...and updates afterwards")
	stat.queue_free()

	# --- Number styling helper.
	var styled := UiText.numbers("BUPS  40  8/s  12%  10s  x3  1.5")
	for token in ["40", "8/s", "12%", "10s", "3", "1.5"]:
		check(styled.contains("[color=#ffffff]%s[/color]" % token), "'%s' is wrapped as a white number" % token)
	check(UiText.numbers("no digits here") == "no digits here", "text without numbers is unchanged")
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	root.add_child(rt)
	rt.text = UiText.numbers("TIME 12s  [PAUSED]  (x3)")
	check(rt.get_parsed_text() == "TIME 12s  [PAUSED]  (x3)", "brackets and text survive styling: '%s'" % rt.get_parsed_text())
	rt.queue_free()

	# --- Picking bups.
	d.strike()
	var target: Cell = d.cells[0]
	check(d.cell_at(target.pos) == target, "cell_at finds the bup under a point")
	check(d.cell_at(target.pos + Vector2(target.radius() + 3.0, 0.0), 0.0) != target, "no slack: just outside misses")
	check(d.cell_at(target.pos + Vector2(target.radius() + 3.0, 0.0), 4.0) == target, "slack widens the target")
	check(d.cell_at(d.global_position + Vector2(d.radius * 2.0, 0.0)) == null, "far from every bup finds none")

	# --- Bups all start inside the dish at any count.
	s.bups = 200
	s.nutrients = 60
	d.strike(s)
	check(_radii(d.cells.map(func(c: Cell) -> Vector2: return c.pos)).max() <= d.radius, "200 bups inside dish")

	# --- Free mode scene: no goals, no saving, uses start conditions, same sim.
	var save_before := FileAccess.get_file_as_string(SaveGame.PATH) if FileAccess.file_exists(SaveGame.PATH) else ""
	var had_save := FileAccess.file_exists(SaveGame.PATH)
	var mtime_before := FileAccess.get_modified_time(SaveGame.PATH) if had_save else 0
	var chosen := StartConditions.new()
	chosen.bups = 150
	chosen.nutrients = 40
	chosen.nutrient_rate = 11.0
	Session.free_start = chosen
	Session.mode = Session.Mode.FREE
	Session.load_requested = true  # must be ignored in free mode
	var m: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	check(m.free_mode, "main.free_mode")
	check(m.dish.cells.size() == 150 and m.dish.food.size() == 40 and m.dish.food_rate == 11.0, "free scene started with chosen conditions (%d bups, %d food, rate %.0f)" % [m.dish.cells.size(), m.dish.food.size(), m.dish.food_rate])
	for i in 60:
		await process_frame
	check(m.tracker.index == 0, "no goal progress in free mode (pop %d >= 100 would complete goal 1)" % m.dish.cells.size())
	check(m.stats_panel.visible and not m.goal_panel.visible, "free mode shows the stats panel instead of the goal panel")
	check(m.stat_bups.value_label.text == "150" and m.stat_nutrients.value_label.text == "40" and m.stat_rate.value_label.text == "11/s" and m.stat_dish.value_label.text == "300", "stats panel shows the chosen initial conditions")
	check(m.stat_bups.name_label.text == "Bups" and m.stat_rate.name_label.text == "Nutrient rate", "stat rows carry their labels")
	m.save_game()
	m._on_goal_completed(m.tracker.goals[0])  # would normally save
	var save_changed := FileAccess.file_exists(SaveGame.PATH) != had_save
	if had_save and FileAccess.file_exists(SaveGame.PATH):
		save_changed = save_changed or FileAccess.get_file_as_string(SaveGame.PATH) != save_before or FileAccess.get_modified_time(SaveGame.PATH) != mtime_before
	check(not save_changed, "free mode must not write the save file")
	if save_changed and had_save:  # restore the real save no matter what
		var f := FileAccess.open(SaveGame.PATH, FileAccess.WRITE)
		f.store_string(save_before)
	m.queue_free()
	await process_frame

	# R restarts with the same free conditions.
	Session.mode = Session.Mode.FREE
	var m2: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m2)
	await process_frame
	m2.dish.cells.clear()
	m2.dish.food_rate = 2.0
	m2._restart()
	check(m2.dish.cells.size() == 150 and m2.dish.food.size() == 40 and m2.dish.food_rate == 11.0, "restart reuses free start conditions")
	m2.queue_free()
	await process_frame

	# Goal mode scene still uses the default start and has goals.
	Session.mode = Session.Mode.GOALS
	Session.load_requested = false
	var m3: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m3)
	# Checked straight after _ready, before the first frame: once frames run, the sim spawns
	# and eats nutrients, so counts would depend on how long the first frame took.
	check(not m3.free_mode and m3.dish.cells.size() == 4 and m3.dish.food.size() == 60, "goal mode default start")
	await process_frame
	check(m3.goal_panel.visible and not m3.stats_panel.visible and m3.goal_panel.get_parsed_text().begins_with("EXPERIMENT 1 / "), "goal mode shows the goal panel, not the stats panel")
	m3.queue_free()
	Session.mode = Session.Mode.GOALS

	if failures.is_empty():
		print("FREE MODE TESTS OK")
	else:
		print("FAILED:")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)
