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
	d.set_seed(5)
	return d


func _first(d: Dish) -> Dictionary:
	return d.bup_info(d.bup_ids()[0])


func _radii(points: Array) -> Array:
	var out := []
	for p in points:
		out.append(p.distance_to(Vector2(500, 400)))
	return out



## A dish of the old 300 µm size: these tests place things by hand and count on a small, fine grid.
func _small() -> StartConditions:
	return TestUtil.small_start()


func _init() -> void:
	# --- Defaults must equal the old hard-coded goal-mode start.
	var d := _make_dish()
	d.strike()
	check(d.population() == 4, "default bups = 4, got %d" % d.population())
	check(absf(TestUtil.units(d) - 10000.0) < 0.5, "default starting nutrient = 10,000 units, got %.1f" % TestUtil.units(d))
	check(d.radius == 10000.0 and d.bup_limit == 20000, "the default dish is 10 mm in radius with room for 20,000 bups, got %.0f and %d" % [d.radius, d.bup_limit])

	# --- Counts and clamping.
	var s := _small()
	s.bups = 120
	s.nutrients = 150
	d.strike(s)
	check(d.population() == 120, "120 bups, got %d" % d.population())
	check(absf(TestUtil.units(d) - 150.0) < 0.5, "150 units of starting nutrient, got %.1f" % TestUtil.units(d))
	s.bups = 9999
	s.nutrients = 999999
	d.strike(s)
	check(d.population() == Dish.MAX_CELLS, "bups clamped to MAX_CELLS")
	check(absf(TestUtil.units(d) - StartConditions.MAX_NUTRIENTS) < 0.5, "starting nutrient clamped to its maximum")
	s.nutrients = 0
	d.strike(s)
	check(d.field.is_empty(), "0 starting nutrient means a bare dish")

	# --- The starting nutrient is spread evenly, wherever you look.
	d.strike(_small())
	var centre_c := d.field.sample(Vector2.ZERO)
	var edge_c := d.field.sample(Vector2(d.radius * 0.8, 0.0))
	check(centre_c > 0.0 and absf(centre_c - edge_c) < centre_c * 0.02, "the starting medium is uniform (%.5f vs %.5f)" % [centre_c, edge_c])

	# --- Nutrient rate is part of the start conditions.
	var r := StartConditions.new()
	r.nutrient_rate = 17.0
	d.strike(r)
	check(d.food_rate == 17.0, "start rate applied, got %.1f" % d.food_rate)
	r.nutrient_rate = 999.0
	d.strike(r)
	check(d.food_rate == StartConditions.MAX_NUTRIENT_RATE, "rate clamped to max")
	d.strike(_small())
	check(d.food_rate == 0.0, "no feed by default, got %.1f" % d.food_rate)

	# --- The feed adds nutrient evenly at the chosen rate.
	d.strike(_small())
	d.clear_bups()
	d.field.reset(d.radius)
	d.food_rate = 12.0
	d.advance(120.0)
	check(absf(TestUtil.units(d) - 12.0 * 2.0) < 2.0, "the feed adds rate x time (%.1f units in 2 min at 12/min)" % TestUtil.units(d))
	check(absf(d.field.sample(Vector2.ZERO) - d.field.sample(Vector2(d.radius * 0.7, 0.0))) < d.field.sample(Vector2.ZERO) * 0.03, "...evenly over the dish")

	# --- Dish size.
	var small := StartConditions.new()
	small.dish_radius = 150.0
	small.bups = 100
	small.nutrients = 100
	d.strike(small)
	check(d.radius == 150.0, "dish radius 150, got %.0f" % d.radius)
	var inside_small := true
	for id in d.bup_ids():
		inside_small = inside_small and (d.bup_info(id)["pos"] as Vector2).length() <= d.radius
	check(inside_small, "everything starts inside a small dish")
	check(absf(TestUtil.units(d) - 100.0) < 0.5, "...with its starting nutrient (%.1f)" % TestUtil.units(d))
	small.dish_radius = 5.0
	d.strike(small)
	check(d.radius == StartConditions.MIN_SIM_RADIUS, "radius clamped to the smallest the simulation runs")
	small.dish_radius = 99999.0
	d.strike(small)
	check(d.radius == StartConditions.MAX_DISH_RADIUS, "radius clamped to max")
	var big := StartConditions.new()
	big.dish_radius = 450.0
	d.strike(big)
	var d_copy := _make_dish()
	check(d_copy.from_dict(TestUtil.saved(d)), "from_dict ok")
	check(d_copy.radius == 450.0, "dish radius survives save/load, got %.0f" % d_copy.radius)

	# --- Dropping nutrient: a dose into the medium.
	d.strike(_small())
	d.field.reset(d.radius)
	var click := d.global_position + Vector2(40, -25)
	check(d.drop_nutrients(click, 1) and absf(TestUtil.units(d) - 1.0) < 0.01, "one unit dropped adds one unit of nutrient")
	check(d.field.sample(click - d.global_position) > d.field.sample(click - d.global_position + Vector2(100, 0)), "a drop is densest where it lands")
	d.field.reset(d.radius)
	check(d.drop_nutrients(click, 30) and absf(TestUtil.units(d) - 30.0) < 0.01, "a dose of 30 adds 30 units")
	check(Dish.scatter_radius(1) == 0.0, "no spread for one")
	check(Dish.scatter_radius(10) < Dish.scatter_radius(40), "a bigger dose spreads wider")
	d.field.reset(d.radius)
	check(not d.drop_nutrients(d.global_position + Vector2(d.radius + 50.0, 0.0), 5) and d.field.is_empty(), "a drop outside the dish adds nothing")

	# --- Big dishes: the grid keeps a fine spacing as far as its cost limit allows, and the crowd limit
	# grows with the radius. (300 µm: 48 cells of 12.5 µm; 1.2 mm: 96 cells of 25 µm; 6 mm: capped at 100.)
	check(NutrientField.size_for(300.0) == 48 and NutrientField.size_for(1200.0) == 96 and NutrientField.size_for(6000.0) == Dish.FIELD_MAX_ACROSS, "the grid size follows the dish radius up to its limit (%d, %d, %d)" % [NutrientField.size_for(300.0), NutrientField.size_for(1200.0), NutrientField.size_for(6000.0)])
	var big_field := NutrientField.new()
	big_field.reset(1200.0)
	check(is_equal_approx(big_field.spacing, 25.0), "a 1.2 mm dish has 25 µm grid cells (%.1f)" % big_field.spacing)
	check(Dish.cap_for(150.0) == Dish.MAX_CELLS and Dish.cap_for(300.0) == Dish.MAX_CELLS and Dish.cap_for(1200.0) == 1200 and Dish.cap_for(6000.0) == 6000, "the crowd limit grows with the radius")
	var large := _make_dish()
	var large_start := StartConditions.new()
	large_start.dish_radius = 1200.0
	large_start.bup_limit = Dish.cap_for(1200.0)
	large_start.bups = 200
	large_start.nutrients = 500
	large.strike(large_start)
	check(large.bup_limit == 1200 and large.field.size == 96 and large.population() == 200 and absf(TestUtil.units(large) - 500.0) < 1.0, "a big dish starts with its own grid, limit and nutrient")
	large.place_source(large.global_position + Vector2(400, 0), 10.0)
	large.advance(600.0)
	var large_copy := _make_dish()
	check(large_copy.from_dict(TestUtil.saved(large)) and large_copy.radius == 1200.0 and large_copy.field.size == 96, "a big dish survives save and load")
	check(absf(TestUtil.units(large_copy) - TestUtil.units(large)) < 0.5, "...with its dissolved nutrient (%.1f vs %.1f)" % [TestUtil.units(large_copy), TestUtil.units(large)])
	check(large_copy.bup_limit == 1200, "...and its bup limit")
	large.free()
	large_copy.free()

	# --- The bups' picture has room for the bups there are, not for the limit; and bups stay visible when the dish is drawn small.
	var picture := _make_dish()
	await process_frame  # (so the dish has built its picture)
	var picture_start := _small()
	picture_start.bup_limit = 100000
	picture_start.bups = 4
	picture.strike(picture_start)
	picture._process(0.0)
	check(picture._bups_mesh.multimesh.instance_count <= 1024, "with a 100,000 limit but 4 bups the picture holds %d, not 100,000" % picture._bups_mesh.multimesh.instance_count)
	for i in 3000:
		picture.add_bup(picture.global_position + Vector2(i % 50, i / 50), Genome.founder(), 30.0)
	picture._process(0.0)
	check(picture._bups_mesh.multimesh.instance_count >= picture.population() and picture._bups_mesh.multimesh.visible_instance_count == picture.population(), "...and grows with the colony (%d of %d)" % [picture._bups_mesh.multimesh.instance_count, picture.population()])
	picture.scale = Vector2.ONE * 0.02
	picture._process(0.0)
	var small_picture: PackedFloat32Array = picture.sim.render_buffer(picture.pixel(), 1)
	check(small_picture[12] >= Cell.MIN_VISIBLE_LENGTH_PX * picture.pixel() - 0.01 and small_picture[13] >= Cell.MIN_VISIBLE_WIDTH_PX * picture.pixel() - 0.01, "a dish drawn at 2%% size still draws each bup at least %.0f px long and %.0f px thick" % [Cell.MIN_VISIBLE_LENGTH_PX, Cell.MIN_VISIBLE_WIDTH_PX])
	picture.free()

	# --- Bup numbers and names: birth order, kept for life, restarting with the dish; names die with their bup.
	var numbered := _make_dish()
	var number_start := _small()
	number_start.bups = 5
	numbered.strike(number_start)
	var founders: PackedInt64Array = numbered.bup_ids()
	var in_order := true
	for i in founders.size():
		in_order = in_order and founders[i] == i + 1
	check(in_order, "the founders are numbered 1, 2, 3 ... in order")
	var later: int = numbered.add_bup(numbered.global_position, Genome.founder(), 30.0)
	check(later == 6 and numbered.bup_name(later) == "%s #6" % Cell.title_for(Genome.founder()["size"]), "the next bup born is the next number ('%s')" % numbered.bup_name(later))
	var big_genome := Genome.founder()
	big_genome["size"] = 7.0
	var big_one: int = numbered.add_bup(numbered.global_position, big_genome, 30.0)
	check(numbered.bup_name(big_one) == "big bup #%d" % big_one, "the size word goes with the number ('%s')" % numbered.bup_name(big_one))
	numbered.rename_bup(later, "  Finnigan\n ")
	check(numbered.bup_name(later) == "Finnigan" and numbered.bup_default_name(later) == "bup #6" and numbered.bup_custom_name(later) == "Finnigan", "a bup can be given a name, tidied up")
	numbered.rename_bup(later, "x".repeat(100))
	check(numbered.bup_name(later).length() == BupNames.MAX_LENGTH, "names are kept to a sensible length")
	numbered.rename_bup(later, "Finnigan")
	numbered.rename_bup(9999, "Nobody")
	check(numbered.bup_name(9999) == "" and numbered.bup_custom_name(9999) == "", "there is no name for a bup that isn't there")
	numbered.advance(60.0)
	check(numbered.bup_name(later) == "Finnigan", "the number and name last through the bup's life")
	var restored := _make_dish()
	check(restored.from_dict(TestUtil.saved(numbered)), "a dish with named bups saves and loads")
	check(restored.bup_name(later) == "Finnigan" and restored.bup_ids() == numbered.bup_ids(), "the numbers and names survive a save and load")
	check(restored.add_bup(restored.global_position, Genome.founder(), 30.0) == numbered.sim.get_next_id(), "...and the next number carries on where it was")
	numbered.remove_bup(later)
	check(numbered.bup_custom_name(later) == "" and not numbered.has_record(later), "a name goes with its bup's record")
	numbered.strike(number_start)
	check(numbered.bup_ids()[0] == 1 and numbered.bup_name(1).ends_with("#1"), "starting the dish over starts the numbers at 1 again")
	# Family records, with names, survive a save and load: a dead ancestor keeps its record and its name.
	var family := _make_dish()
	family.strike(number_start)
	family.clear_bups()
	family.time = 4.0 * 3600.0 + 125.0
	family.sim.set_time(family.time)
	var gran: int = family.add_bup(family.global_position, Genome.founder(), 200.0, 4.0, 8.0, 0, Vector2.RIGHT)
	family.step(1.0)  # she divides
	var kid := -1
	for id in family.bup_ids():
		if id != gran:
			kid = id
	family.rename_bup(gran, "Gran")
	family.time += 3600.0
	family.sim.set_time(family.time)
	family.remove_bup(gran)
	check(family.has_record(gran) and family.bup_name(gran) == "Gran" and family.lineage_info(gran)["born"] == 242 and family.lineage_info(gran)["died"] == 302, "a dead ancestor keeps her record and her name, with birth and death to the minute (%s)" % [family.lineage_info(gran)])
	var family_copy := _make_dish()
	check(family_copy.from_dict(TestUtil.saved(family)), "a dish with a family history saves and loads")
	check(family_copy.lineage_chain(kid) == family.lineage_chain(kid) and family_copy.bup_name(gran) == "Gran" and not family_copy.lineage_info(gran)["alive"] and family_copy.lineage_info(gran)["died"] == 302, "the family line, the dead ancestor and her name come back")
	family_copy.remove_bup(kid)
	check(not family_copy.has_record(gran) and not family_copy.has_record(kid), "and are dropped as before when nothing living descends from them")
	family.free()
	family_copy.free()
	numbered.free()
	restored.free()

	# --- The setup screen keeps the bup limit at or above the number of founders.
	var limit_setup: Control = load(Scenes.FREE_SETUP).instantiate()
	root.add_child(limit_setup)
	await process_frame
	limit_setup.limit_row.value = 10
	limit_setup.bups_row.value = 60
	check(limit_setup.limit_row.slider.min_value >= 60 and limit_setup.limit_row.value >= 60 and limit_setup._start.bup_limit >= 60, "raising the founders raises the limit's floor and the limit with it (limit %d)" % limit_setup._start.bup_limit)
	limit_setup.queue_free()
	await process_frame

	# --- Founders take the name and colour chosen for them; the rest start unnamed, in the default green.
	var founded := _make_dish()
	var founded_start := _small()
	founded_start.bups = 3
	founded_start.founders = [{"name": "Finnigan", "color": "#ff0000"}, {}]
	founded.strike(founded_start)
	check(founded.bup_name(1) == "Finnigan" and founded.bup_name(2).ends_with("#2") and founded.bup_name(3).ends_with("#3"), "a founder given a name has it; the others keep their numbers (%s, %s)" % [founded.bup_name(1), founded.bup_name(2)])
	var red_info := founded.bup_info(1)
	check(red_info["hue"] < 0.01 and absf(red_info["sat"] - 1.0) < 0.01 and absf(red_info["val"] - 1.0) < 0.01, "a founder coloured red starts red (hue %.2f, sat %.2f, val %.2f)" % [red_info["hue"], red_info["sat"], red_info["val"]])
	check(absf(founded.bup_info(2)["hue"] - Genome.founder()["hue"]) < 0.001 and absf(founded.bup_info(3)["sat"] - Genome.founder()["sat"]) < 0.001, "founders with no colour chosen start in the default green")
	var saved_colour := _make_dish()
	check(saved_colour.from_dict(TestUtil.saved(founded)) and absf(saved_colour.bup_info(1)["hue"] - red_info["hue"]) < 0.001 and saved_colour.bup_name(1) == "Finnigan", "colours and names are saved and loaded with the dish")
	founded.free()
	saved_colour.free()

	# --- The founders screen: a row for each founder, to name and colour; random colours; what is chosen is kept.
	var kept_start := Session.free_start
	var five := StartConditions.new()
	five.bups = 5
	five.founders = [{"name": "Finnigan", "color": "#ff0000"}]
	Session.free_start = five
	var screen: Control = load(Scenes.FOUNDERS).instantiate()
	root.add_child(screen)
	await process_frame
	check(screen.list.get_child_count() == 5 and screen._names.size() == 5 and screen._colors.size() == 5, "the founders screen has a row for each of the %d founders" % five.bups)
	check(screen._names[0].text == "Finnigan" and screen._names[1].text == "" and screen._names[1].placeholder_text == "bup #2", "a kept name is shown; an unnamed founder shows its number as the hint ('%s')" % screen._names[1].placeholder_text)
	check(screen._colors[0].color.is_equal_approx(Color.html("#ff0000")) and screen._colors[1].color.is_equal_approx(Genome.color_of(Genome.founder())), "a kept colour is shown; the rest are the default green")
	check(not screen._colors[0].edit_alpha, "colours have no opacity, just #rrggbb")
	check(screen._collect() == [{"name": "Finnigan", "color": "#ff0000"}], "the founders left as they are add nothing to what is kept: a short list means the first ones, then defaults (%s)" % [screen._collect()])
	var greys := 0
	var darks := 0
	var too_dark := 0
	var sat_total := 0.0
	var val_total := 0.0
	for i in 1000:
		var random_pick := Genome.random_color()
		greys += 1 if random_pick.s < 0.15 else 0
		darks += 1 if random_pick.v < 0.5 else 0
		too_dark += 1 if random_pick.v < Genome.RANDOM_VAL_MIN - 0.001 else 0
		sat_total += random_pick.s
		val_total += random_pick.v
	check(greys > 20 and greys < 100 and darks > 100 and too_dark == 0, "random colours still include greys (%d of 1000, not many) and darker shades (%d), but never too dark to see (%d)" % [greys, darks, too_dark])
	check(sat_total / 1000.0 > 0.55 and val_total / 1000.0 > 0.66, "...and lean towards vivid and bright (saturation %.2f, brightness %.2f on average; an even spread gives 0.50 and 0.65)" % [sat_total / 1000.0, val_total / 1000.0])
	for count in [1, 2, 4, 10]:
		var spread := Genome.spread_colors(count)
		var hues := []
		for color in spread:
			hues.append(color.h)
		hues.sort()
		var even: bool = spread.size() == count
		for k in count:
			var gap: float = fposmod(hues[(k + 1) % count] - hues[k], 1.0) if count > 1 else 1.0 / count
			even = even and absf(gap - 1.0 / count) < 0.001 and spread[k].s > 0.999 and spread[k].v > 0.999
		check(even, "%d founders get hues %.0f degrees apart, at full saturation and brightness" % [count, 360.0 / count])
	check(Genome.spread_colors(4)[0] != Genome.spread_colors(4)[0] or Genome.spread_colors(4)[1] != Genome.spread_colors(4)[1], "...from a different place on the wheel each time")
	screen._spread_colors()
	var screen_hues := []
	for picker in screen._colors:
		screen_hues.append(picker.color.h)
	screen_hues.sort()
	var screen_even: bool = true
	for k in 5:
		screen_even = screen_even and absf(fposmod(screen_hues[(k + 1) % 5] - screen_hues[k], 1.0) - 0.2) < 0.01
	check(screen_even and screen._names[0].text == "Finnigan", "the Spread colours button spaces the founders' hues evenly and leaves the names")
	var before_random := []
	for picker in screen._colors:
		before_random.append(picker.color)
	screen._randomise_colors()
	var all_changed := true
	for i in 5:
		all_changed = all_changed and not before_random[i].is_equal_approx(screen._colors[i].color)
	check(all_changed and screen._names[0].text == "Finnigan", "Random colours gives every founder a new colour and leaves the names alone")
	screen._names[2].text = "  Maeve "
	screen._colors[2].color = Color.html("#3366cc")
	var collected: Array = screen._collect()
	check(collected.size() == 5 and collected[2] == {"name": "Maeve", "color": "#3366cc"}, "what is typed and picked is collected, tidied (%s)" % [collected[2]])
	screen.queue_free()
	Session.free_start = kept_start
	await process_frame

	# --- The colour picker is small and plain, with no eyedropper and no screen-recording message, even if the picker adds one.
	var picking := ColorPicking.make_button()
	root.add_child(picking)
	await process_frame
	var dropper: Button = null
	for node in picking.get_picker().find_children("*", "Button", true, false):
		if node.tooltip_text.begins_with("Pick a color"):
			dropper = node
	check(not picking.edit_alpha and dropper != null and not dropper.visible, "the colour picker has no opacity and no screen eyedropper")
	var permission_note := LinkButton.new()  # what the picker adds when macOS hasn't allowed screen recording
	permission_note.text = "Screen Recording permission missing!"
	picking.get_picker().find_children("*", "VBoxContainer", true, false)[0].add_child(permission_note)
	picking.get_popup().popup_centered()
	for i in 3:
		await process_frame
	check(not permission_note.visible and not dropper.visible, "the screen-recording message and the eyedropper stay hidden when the picker opens")
	picking.get_popup().hide()
	picking.queue_free()
	await process_frame

	# --- Goal mode's dish starts with founders in evenly spaced colours; free mode stays green unless the player says otherwise.
	var goal_dish := _make_dish()
	goal_dish.strike()
	var goal_hues := []
	for id in goal_dish.bup_ids():
		goal_hues.append(goal_dish.bup_info(id)["hue"])
	goal_hues.sort()
	var goal_even: bool = goal_hues.size() == 4
	for k in goal_hues.size():
		goal_even = goal_even and absf(fposmod(goal_hues[(k + 1) % goal_hues.size()] - goal_hues[k], 1.0) - 0.25) < 0.01
	check(goal_even, "the goal game's four founders start in evenly spaced colours (%s)" % [goal_hues])
	goal_dish.strike(_small())
	check(absf(goal_dish.bup_info(1)["hue"] - Genome.founder()["hue"]) < 0.001, "...while a free-mode dish with no colours chosen is still green")
	goal_dish.free()

	# --- A dish can be enlarged with everything in it, but never shrunk.
	var growing := _make_dish()
	growing.strike(_small())
	growing.place_source(growing.global_position + Vector2(100, 0), 5.0)
	growing.field.deposit(Vector2(-60.0, 30.0), 200.0)
	growing.advance(120.0)
	var ids_before := growing.bup_ids()
	var positions_before := []
	for id in ids_before:
		positions_before.append(growing.bup_info(id)["pos"])
	var units_before := TestUtil.units(growing)
	var centre_before := Vector2.ZERO
	var mass_before := 0.0
	var values_before := growing.field.values()
	for i in values_before.size():
		var m_i: float = values_before[i] * growing.field.spacing * growing.field.spacing
		mass_before += m_i
		centre_before += growing.field.cell_centre(i) * m_i
	centre_before /= mass_before
	growing.grow_to(1500.0)
	check(growing.radius == 1500.0 and growing.field.size == NutrientField.size_for(1500.0), "grow_to enlarges the dish and its grid")
	check(growing.bup_ids() == ids_before, "...keeping every bup")
	var same_places := true
	for i in ids_before.size():
		same_places = same_places and (growing.bup_info(ids_before[i])["pos"] as Vector2).is_equal_approx(positions_before[i])
	check(same_places, "...where they were")
	check(absf(TestUtil.units(growing) - units_before) < 0.001 * maxf(units_before, 1.0) + 0.01, "...and all its nutrient (%.2f before, %.2f after)" % [units_before, TestUtil.units(growing)])
	check(growing.sources.size() == 1, "...and its sources")
	# The nutrient stays where it was, with empty dish around it: it is not stretched over the bigger dish.
	var grown_values := growing.field.values()
	var nutrient_mass := 0.0
	var nutrient_centre := Vector2.ZERO
	var farthest := 0.0
	for i in grown_values.size():
		var cell_mass: float = grown_values[i] * growing.field.spacing * growing.field.spacing
		nutrient_mass += cell_mass
		nutrient_centre += growing.field.cell_centre(i) * cell_mass
		if grown_values[i] > 1e-7:
			farthest = maxf(farthest, growing.field.cell_centre(i).length())
	nutrient_centre /= nutrient_mass
	check(nutrient_centre.distance_to(centre_before) < 2.0, "...the nutrient's centre of mass hasn't moved (%s then, %s now)" % [centre_before, nutrient_centre])
	check(farthest <= 300.0 + growing.field.spacing, "...and it still reaches only as far as the old dish did (%.0f µm of 300; cells %.0f µm)" % [farthest, growing.field.spacing])
	check(growing.field.sample(Vector2(900.0, 0.0)) == 0.0, "...with nothing in the new space around it")
	growing.grow_to(800.0)
	check(growing.radius == 1500.0, "a dish never shrinks")
	growing.grow_to(99999.0)
	check(growing.radius == StartConditions.MAX_DISH_RADIUS, "...and never outgrows the largest")
	growing.change_limit(1)
	check(growing.bup_limit == growing.population(), "the bup limit can't be set below the bups there are (%d)" % growing.bup_limit)
	growing.advance(60.0)
	check(growing.population() > 0, "an enlarged dish keeps running")
	growing.free()

	# --- The bup limit is a start condition: chosen, enforced, saved, and clamped when loaded.
	var limited := _make_dish()
	var limit_start := _small()
	limit_start.bup_limit = 50
	limit_start.bups = 200
	limited.strike(limit_start)
	check(limited.bup_limit == 50 and limited.population() == 50, "the bup limit caps the starting crowd (%d)" % limited.population())
	limited.advance(3.0 * 3600.0)
	check(limited.population() <= 50, "...and the colony as it grows (%d)" % limited.population())
	var limit_copy := _make_dish()
	check(limit_copy.from_dict(TestUtil.saved(limited)) and limit_copy.bup_limit == 50, "the limit survives save and load")
	check(StartConditions.from_dict({"bup_limit": 99999999}).bup_limit == StartConditions.MAX_BUP_LIMIT and StartConditions.from_dict({"bup_limit": 1}).bup_limit == StartConditions.MIN_BUP_LIMIT, "a saved limit is clamped to the slider's range")
	check(StartConditions.MAX_DISH_RADIUS == 12000.0 and StartConditions.MAX_BUP_LIMIT == 100000, "free mode offers dishes up to 12000 µm and limits up to 100000")
	limited.free()
	limit_copy.free()

	# --- Nothing can be put where it would vanish: every spot near the rim is either refused, or takes
	# its full dose; a spot the grid can't hold is never accepted as a source.
	d.strike(_small())
	var refused := 0
	var accepted := 0
	var lost := 0
	for angle in range(0, 360, 3):
		for margin in [0.0, 1.0, 3.0, 6.0, 9.0, 12.0]:
			var at: Vector2 = d.global_position + Vector2.from_angle(deg_to_rad(float(angle))) * (d.radius - margin)
			d.field.reset(d.radius)
			d.sources.clear()
			if d.can_place_at(at):
				accepted += 1
				d.field.deposit(at - d.global_position, 10.0)
				if absf(d.field.total() - 10.0) > 0.01:
					lost += 1
				check(d.place_source(at, 5.0), "a spot that can take nutrient accepts a source (%d deg, %.0f from the rim)" % [angle, margin])
			else:
				refused += 1
				check(not d.place_source(at, 5.0) and not d.drop_nutrients(at, 3), "a spot that can't hold nutrient accepts neither a source nor a dose (%d deg, %.0f from the rim)" % [angle, margin])
	check(lost == 0 and accepted > 0 and refused > 0, "no accepted rim spot loses its nutrient (%d accepted, %d refused, %d lost)" % [accepted, refused, lost])
	d.sources.clear()

	# --- Dropped-nutrient counter.
	d.strike(_small())
	check(d.nutrients_placed == 0, "counter starts at 0")
	d.drop_nutrients(click, 1)
	d.drop_nutrients(click, 30)
	check(d.nutrients_placed == 31, "counter adds what was dropped, got %d" % d.nutrients_placed)
	d.drop_nutrients(d.global_position + Vector2(d.radius + 50.0, 0.0), 5)
	check(d.nutrients_placed == 31, "a rejected drop isn't counted")
	var copy := _make_dish()
	check(copy.from_dict(TestUtil.saved(d)) and copy.nutrients_placed == d.nutrients_placed, "counter survives save/load")
	d.strike(_small())
	check(d.nutrients_placed == 0, "a new dish resets the counter")

	# --- The eraser takes nutrient out of a patch, most at its middle.
	d.strike(_small())
	d.clear_bups()
	d.field.reset(d.radius)
	d.field.fill(500.0)
	var patch := d.global_position + Vector2(-80, 40)
	var middle_before := d.field.sample(patch - d.global_position)
	var removed := d.erase_nutrient(patch, 40.0)
	check(removed > 0.0 and d.field.sample(patch - d.global_position) < middle_before * 0.25, "erasing lowers the nutrient at the middle of the brush")
	var rim := patch + Vector2(36, 0)
	check(d.field.sample(rim - d.global_position) > d.field.sample(patch - d.global_position), "...and less towards its edge")
	check(absf(d.field.sample(d.global_position + Vector2(150, 150) - d.global_position) - middle_before) < middle_before * 0.01, "...and not at all outside it")
	check(absf((500.0 - d.field.total()) / Dish.NUTRIENT_ENERGY - removed) < 0.01, "erasing reports the units it removed")

	# --- Plankton: placed by hand, as many as the dish holds, they float until they burst into nutrient; a bloom adds more at random.
	var bloom := _make_dish()
	bloom.strike(_small())
	bloom.field.reset(bloom.radius)
	var bloom_spot := bloom.global_position + Vector2(40, 30)
	check(bloom.plankton.is_empty() and bloom.bloom_rate == 0.0, "a new dish has no plankton in the water and no bloom")
	check(bloom.place_plankton(bloom_spot) and bloom.plankton.size() == 1, "a plankton can be placed")
	check(not bloom.place_plankton(bloom.global_position + Vector2(bloom.radius + 10.0, 0)), "plankton can't be placed outside the dish")
	var lifetime: float = bloom.plankton[0].burst_at - bloom.time
	check(lifetime >= Dish.PLANKTON_MEAN_LIFE * (1.0 - Dish.PLANKTON_LIFE_SPREAD) and lifetime <= Dish.PLANKTON_MEAN_LIFE * (1.0 + Dish.PLANKTON_LIFE_SPREAD), "it bursts at a random time within a set span of the mean life (%.0f s)" % lifetime)
	var before_burst := TestUtil.units(bloom)
	bloom.plankton[0].burst_at = bloom.time + 1.0
	bloom.step(2.0)
	check(bloom.plankton.is_empty() and absf(TestUtil.units(bloom) - before_burst - Dish.PLANKTON_UNITS) < 1.0, "a plankton that bursts is gone and leaves its %.0f units of nutrient (%.1f)" % [Dish.PLANKTON_UNITS, TestUtil.units(bloom) - before_burst])
	for i in 30:
		bloom.place_plankton(bloom_spot)
	check(bloom.plankton.size() == 30, "there is no limit on how many the player places but the dish's (%d)" % bloom.plankton.size())
	bloom.plankton.clear()
	bloom.bloom_rate = 240.0
	bloom.advance(3600.0)
	check(bloom.plankton.size() >= 8 and bloom.plankton.size() <= 12, "a bloom of 240 a day (10 an hour) adds one every 6 minutes, so about ten are floating after an hour (%d)" % bloom.plankton.size())
	bloom.bloom_rate = 1000.0
	check(bloom.bloom_rate == StartConditions.MAX_BLOOM_RATE, "the bloom rate cannot be set above the most the game allows")
	# The bursts, which are what feed the colony, come at steady enough intervals: no long gaps with nothing.
	var steady := _make_dish()
	steady.strike(_small())
	steady.clear_bups()
	steady.bloom_rate = 24.0
	var gaps := []
	var last_burst := 0.0
	var floating := steady.plankton.size()
	for i in int(72.0 * 3600.0 / 20.0):
		steady.step(20.0)
		if steady.plankton.size() < floating:  # (one burst, at least, since the last step)
			gaps.append(steady.time - last_burst)
			last_burst = steady.time
		floating = steady.plankton.size()
	var longest := 0.0
	for g: float in gaps:
		longest = maxf(longest, g)
	check(gaps.size() >= 40 and longest < 3.0 * 3600.0, "at 24 a day the nutrient arrives about hourly with no gap past 3 hours (%d bursts, longest gap %.1f h)" % [gaps.size(), longest / 3600.0])
	bloom.bloom_rate = 0.0
	bloom.plankton.clear()
	bloom.advance(600.0)
	check(bloom.plankton.is_empty(), "with no bloom nothing appears by itself")
	bloom.place_plankton(bloom_spot)
	var cost_before: float = bloom.bup_info(bloom.sim.bup_ids()[0])["upkeep"]
	bloom.upkeep_factor = 10.0
	var cost_after: float = bloom.bup_info(bloom.sim.bup_ids()[0])["upkeep"]
	check(cost_after > 5.0 * cost_before and cost_after < 10.0 * cost_before, "a higher upkeep factor makes staying alive cost more (%.5f to %.5f a second)" % [cost_before, cost_after])
	bloom.bloom_rate = 7.0  # (a day)
	var bloom_copy := _make_dish()
	check(bloom_copy.from_dict(TestUtil.saved(bloom)) and bloom_copy.plankton.size() == 1 and is_equal_approx(bloom_copy.plankton[0].burst_at, bloom.plankton[0].burst_at) and bloom_copy.bloom_rate == 7.0, "plankton and the bloom rate survive save and load")
	check(StartConditions.from_dict({"bloom_rate": 9999}).bloom_rate == StartConditions.MAX_BLOOM_RATE and StartConditions.new().bloom_rate == 0.0, "the bloom rate is a start condition: none by default, clamped when loaded")

# --- Selecting and inspecting: bups and sources are picked, the medium is read anywhere.
	d.strike(_small())
	d.clear_bups()
	d.field.reset(d.radius)
	var spot := d.global_position + Vector2(60, -30)
	d.place_source(spot, 2.0)
	check(d.source_at(spot) == d.sources[0], "source_at finds the source under a point")
	check(d.source_at(spot + Vector2(Dish.SOURCE_PICK_RADIUS + 2.0, 0.0)) == null, "just outside the pick radius finds none")
	check(d.source_at(spot + Vector2(Dish.SOURCE_PICK_RADIUS + 2.0, 0.0), 4.0) == d.sources[0], "slack widens a source's target")
	d.select_at(spot)
	check(d.selected_source == d.sources[0] and d.selected_id == -1, "select_at selects the source")
	d.select_at(d.global_position + Vector2(-200, 200))
	check(d.selected_source == null and d.selected_id == -1, "selecting empty space lets go of the selection")
	d.add_bup(spot, Genome.founder(), 30.0)
	d.select_at(spot)
	check(d.selected_source != null and d.selected_id == -1, "a source is picked over a bup on top of it")
	d.hover_at(spot)
	check(d.hovered_source != null and d.hovered_id == -1, "...and so is its hover")
	d.select_at(spot + Vector2(Dish.SOURCE_PICK_RADIUS - 2.0, 0.0))
	check(d.selected_source != null, "a click a little away from a source still picks it (within %.0f µm)" % Dish.SOURCE_PICK_RADIUS)
	d.clear_bups()
	d.select_at(spot)
	check(d.selected_source != null and d.selected_id == -1, "selecting a source clears the bup selection")
	d.hover_at(spot)
	check(d.hovered_source == d.sources[0] and d.hovered_id == -1, "hover_at highlights a source")
	d.clear_hover()
	check(d.hovered_source == null and d.hovered_id == -1, "clear_hover clears both kinds")
	# The medium at a point: concentration, which way it rises, what is near.
	d.sources.clear()
	var values := []
	for i in d.field.size * d.field.size:
		values.append(0.05 + 0.0002 * d.field.cell_centre(i).x)
	d.field.load_values(values)
	d.add_bup(spot + Vector2(30, 0), Genome.founder(), 30.0)
	d.add_bup(spot + Vector2(200, 0), Genome.founder(), 30.0)
	d.place_source(spot + Vector2(0, 70), 2.0)
	var info := d.nutrient_at(spot)
	check((info["offset"] as Vector2).is_equal_approx(Vector2(60, -30)), "point info: position relative to the dish centre")
	check(is_equal_approx(info["distance"], Vector2(60, -30).length()), "point info: distance from the centre")
	check(absf(info["concentration"] - (0.05 + 0.0002 * 60.0)) < 0.002, "point info: concentration here (%.4f)" % info["concentration"])
	check((info["gradient"] as Vector2).x > 0.00015 and absf((info["gradient"] as Vector2).y) < 0.00005, "point info: the medium rises towards +x")
	check(is_equal_approx(info["nearest_bup"], 30.0) and is_equal_approx(info["nearest_source"], 70.0), "point info: nearest bup and source")
	d.clear_bups()
	d.sources.clear()
	check(d.nutrient_at(spot)["nearest_bup"] == -1.0 and d.nutrient_at(spot)["nearest_source"] == -1.0, "point info with nothing near")
	d.select_at(spot)
	d.place_source(spot, 2.0)
	d.select_at(spot)
	d.strike(_small())
	check(d.selected_source == null and d.selected_id == -1, "a new dish clears any selection")

	# --- History graph axes.
	check(HistoryGraph.nice_ceil(0.0) == 10.0 and HistoryGraph.nice_ceil(10.0) == 10.0 and HistoryGraph.nice_ceil(11.0) == 20.0, "axis max rounds up to a round number (small)")
	check(HistoryGraph.nice_ceil(73.0) == 100.0 and HistoryGraph.nice_ceil(101.0) == 150.0 and HistoryGraph.nice_ceil(301.0) == 500.0, "axis max rounds up to a round number (large)")
	check(HistoryGraph.nice_ceil(1234.0) == 1300.0, "axis max beyond the table still rounds up (%s)" % HistoryGraph.nice_ceil(1234.0))
	check(SimClock.format(0) == "0:00" and SimClock.format(65) == "1:05" and SimClock.format(900) == "15:00" and SimClock.format(3600) == "1:00:00" and SimClock.format(3725) == "1:02:05", "the clock reads simulation time as m:ss, then h:mm:ss")
	check(HistoryGraph.format_time(3600) == "1h" and HistoryGraph.format_time(7200) == "2h", "graph ticks count hours of simulation time")
	check(HistoryGraph.time_ticks(0.0, 900.0, 300.0) == [0.0, 300.0, 600.0, 900.0], "time ticks over the first window")
	check(HistoryGraph.time_ticks(399.0, 1299.0, 300.0) == [600.0, 900.0, 1200.0], "time ticks over a scrolled window")
	check(HistoryGraph.time_ticks(0.0, 100.0, 300.0) == [0.0], "a short window still has its origin tick")
	check(HistoryGraph.window_seconds(100.0) == 24.0 * 3600.0 and HistoryGraph.window_seconds(86399.0) == 24.0 * 3600.0, "the graph spans 24 hours at first")
	check(HistoryGraph.window_seconds(86400.0) == 72.0 * 3600.0 and HistoryGraph.window_seconds(200000.0) == 72.0 * 3600.0, "...and 72 hours once the run reaches 24")
	check(HistoryGraph.window_start(100.0) == 0.0 and HistoryGraph.window_start(200000.0) == 0.0, "the window starts at zero until the run outgrows it")
	check(HistoryGraph.window_start(300000.0) == 300000.0 - 72.0 * 3600.0, "then it follows the newest sample (%s)" % HistoryGraph.window_start(300000.0))
	check(Dish.HISTORY_LEN * Dish.HISTORY_INTERVAL == 72.0 * 3600.0, "the dish keeps 72 hours of samples")
	check(HistoryGraph.harm_axis_max([]) == 10.0 and HistoryGraph.harm_axis_max([4.0, 9.9]) == 10.0 and HistoryGraph.harm_axis_max([12.0]) == 20.0 and HistoryGraph.harm_axis_max([35.0]) == 50.0 and HistoryGraph.harm_axis_max([5.0, 99.0]) == 100.0, "the harm axis grows to hold the data, up to 100%")
	check(HistoryGraph.tick_text(0.4, 2.0) == "0.4" and HistoryGraph.tick_text(10.0, 120.0) == "10" and HistoryGraph.tick_text(150.0, 150.0) == "150", "trait ticks use sensible decimals")
	var graph := HistoryGraph.new()
	graph.size = Vector2(424, 174)
	graph.dish = d
	root.add_child(graph)
	d.strike(_small())
	for i in 200:
		d.step(1.0 / 30.0)
	for trait_i in HistoryGraph.TRAITS.size():
		graph.trait_index = trait_i
		graph.queue_redraw()
		await process_frame
	graph.queue_free()

	# --- extinct fires once, when the dish dies; and again only after a new dish dies.
	var extinct_count := [0]
	var wipe := _make_dish()
	wipe.extinct.connect(func() -> void: extinct_count[0] += 1)
	wipe.strike(_small())
	wipe.clear_bups()
	for i in 12:
		wipe.step(0.1)
	check(extinct_count[0] == 1, "extinct is signalled once, not on every step (%d)" % extinct_count[0])
	wipe.strike(_small())
	wipe.clear_bups()
	wipe.step(0.1)
	wipe.step(0.1)
	check(extinct_count[0] == 2, "a new dish that dies signals again (%d)" % extinct_count[0])

	# --- After a load, history samples still land on multiples of the interval.
	var run := _make_dish()
	run.strike(_small())
	run.place_source(run.global_position + Vector2(30, 30), 3.0)  # so there is a source to save and to corrupt
	while run.time < 1.25 * Dish.HISTORY_INTERVAL:
		run.step(0.5)
	var reloaded := _make_dish()
	check(reloaded.from_dict(TestUtil.saved(run)), "a dish mid-run reloads")
	var samples_before: int = reloaded.history["pop"].size()
	while reloaded.history["pop"].size() == samples_before:
		reloaded.step(0.05)
	var drift := absf(reloaded.time - Dish.HISTORY_INTERVAL * round(reloaded.time / Dish.HISTORY_INTERVAL))
	check(drift < 0.06, "the first sample after a load falls on a multiple of %.0fs (t=%.2f)" % [Dish.HISTORY_INTERVAL, reloaded.time])

	# --- A bad save is rejected whole and leaves the dish exactly as it was.
	var good: Dictionary = TestUtil.saved(run)
	var victim := _make_dish()
	victim.strike(_small())
	victim.place_source(victim.global_position + Vector2(50, 20), 2.0)
	victim.select_at(victim.global_position + Vector2(50, 20))
	var cells_before := victim.bup_ids()
	var sources_before: Array = victim.sources.duplicate()
	var radius_before := victim.radius
	var time_before := victim.time
	var broken := {
		"cell missing pos": func(x: Dictionary) -> void: x["cells"][0].erase("pos"),
		"cell pos too short": func(x: Dictionary) -> void: x["cells"][0]["pos"] = [1.0],
		"cell pos holds text": func(x: Dictionary) -> void: x["cells"][0]["pos"] = ["a", "b"],
		"cell genome not a dictionary": func(x: Dictionary) -> void: x["cells"][0]["genome"] = [1, 2],
		"cell energy is text": func(x: Dictionary) -> void: x["cells"][0]["energy"] = "lots",
		"cell is not a dictionary": func(x: Dictionary) -> void: x["cells"][0] = 7,
		"source position too short": func(x: Dictionary) -> void: x["sources"][0]["pos"] = [3.0],
		"source rate is text": func(x: Dictionary) -> void: x["sources"][0]["rate"] = "fast",
		"nutrient field is the wrong size": func(x: Dictionary) -> void: x["field"] = [0.1, 0.2],
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
		check(victim.bup_ids() == cells_before and victim.sources == sources_before and victim.radius == radius_before and victim.time == time_before, "...and leaves the dish untouched (%s)" % what)
	check(victim.selected_source != null, "...including the selection (a rejected load changes nothing)")
	# Odd but harmless values are made safe instead of rejected.
	var odd: Dictionary = good.duplicate(true)
	odd["radius"] = 99999
	odd["cells"][0]["genome"]["values"] = {"speed": 99999, "sense": -5}
	odd["cells"][0]["genome"]["hue"] = 7.25
	check(victim.from_dict(odd), "a save with out-of-range values still loads")
	check(victim.radius == StartConditions.MAX_DISH_RADIUS, "...with the radius clamped (%.0f)" % victim.radius)
	check(_first(victim)["speed"] == Genome.GENES["speed"][1] and _first(victim)["sense"] == Genome.GENES["sense"][0], "...and genes clamped to their range")
	check(_first(victim)["hue"] >= 0.0 and _first(victim)["hue"] < 1.0, "...and the hue wrapped into range")
	check(victim.selected_source == null and victim.selected_id == -1, "a successful load clears the selection")
	var weird: Dictionary = good.duplicate(true)
	weird["cells"][0]["genome"]["values"] = [1, 2, 3]
	check(victim.from_dict(weird) and _first(victim)["speed"] == Genome.founder()["speed"], "a genome with garbage values falls back to defaults instead of crashing")

	# --- StartConditions: one source for limits, and an honest copy().
	check(StartConditions.MAX_BUPS <= StartConditions.MAX_BUP_LIMIT, "the bups slider cap never exceeds the limit slider's")
	check(StartConditions.new().dish_radius == Dish.DEFAULT_RADIUS, "default radius is the dish's default")
	var original := StartConditions.new()
	original.bups = 33
	original.nutrients = 44
	original.nutrient_rate = 7.0
	original.dish_radius = 4100.0
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
	check(row.value_field.text == "0.4", "a 0.1 step shows one decimal ('%s')" % row.value_field.text)
	check(row.reset_button.tooltip_text == "Use default (0.5)", "the reset tooltip uses the same format ('%s')" % row.reset_button.tooltip_text)
	row.configure(0, 1, 0.25, 0.5, "x")
	row.value = 0.75
	check(row.value_field.text == "0.75" and row.unit_label.text == "x", "a 0.25 step shows two decimals, and the unit sits outside the number ('%s' '%s')" % [row.value_field.text, row.unit_label.text])
	row.configure(0, 200, 1, 4, "/s")
	row.value = 12
	check(row.value_field.text == "12" and row.unit_label.text == "/s", "a whole step shows no decimals ('%s')" % row.value_field.text)
	var changes := [0]
	row.value_changed.connect(func(_v: float) -> void: changes[0] += 1)
	row.reset_button.pressed.emit()
	check(row.value == 4.0 and changes[0] == 1, "reset puts back the default and announces the change")
	# Click the number to type an exact value.
	row.configure(0, 100000, 1, 4)
	row.value = 5
	var type_in := func(text: String) -> void:
		row.value_field.grab_focus()
		row.value_field.text = text
		row.value_field.text_submitted.emit(text)
	changes[0] = 0
	type_in.call("12345")
	await process_frame
	check(row.value == 12345.0 and row.value_field.text == "12,345" and changes[0] == 1 and not row.value_field.has_focus(), "typing a number sets it exactly, tidies it up and lets go of the keyboard ('%s')" % row.value_field.text)
	type_in.call("1,234")
	check(row.value == 1234.0, "commas in what was typed are ignored")
	type_in.call("999999")
	check(row.value == 100000.0, "a number above the range is held to the top of it")
	type_in.call("-5")
	check(row.value == 0.0, "...and below it to the bottom")
	type_in.call("lots")
	check(row.value == 0.0 and row.value_field.text == "0", "text that isn't a number puts the old value back ('%s')" % row.value_field.text)
	row.configure(0, 60, 0.1, 10, "/min")
	type_in.call("17.3/min")
	check(is_equal_approx(row.value, 17.3) and row.value_field.text == "17.3" and row.unit_label.text == "/min", "a decimal with its unit typed is understood, and shown without it ('%s')" % row.value_field.text)
	row.value_field.grab_focus()
	check(row.value_field.text == "17.3", "clicking the number shows the bare number to edit ('%s')" % row.value_field.text)
	# Up and Down step the number while it is being edited.
	var press := func(key: Key, shift := false) -> void:
		var e := InputEventKey.new()
		e.keycode = key
		e.pressed = true
		e.shift_pressed = shift
		row.value_field.gui_input.emit(e)
	row.value_field.release_focus()
	row.configure(0, 100000, 1, 4)
	row.value = 40
	row.value_field.grab_focus()
	press.call(KEY_UP)
	check(row.value == 41.0 and row.value_field.text == "41" and row.value_field.has_focus(), "Up raises the number by one and stays in the box ('%s')" % row.value_field.text)
	press.call(KEY_DOWN)
	press.call(KEY_DOWN)
	check(row.value == 39.0, "Down lowers it by one")
	press.call(KEY_UP, true)
	check(row.value == 49.0, "Shift moves ten at a time")
	row.value_field.text = "1,000"
	press.call(KEY_UP)
	check(row.value == 1001.0, "what has been typed counts first")
	row.value_field.text = "0"
	press.call(KEY_DOWN)
	check(row.value == 0.0, "the range still holds")
	row.value_field.release_focus()
	row.configure(1, 12, 0.1, 6, "mm")
	row.value = 6.0
	row.value_field.grab_focus()
	press.call(KEY_UP)
	check(is_equal_approx(row.value, 7.0), "a row with a fine step still moves by a whole unit (6 -> 7 mm)")
	row.value_field.release_focus()
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
	# --- Big numbers get thousands separators, everywhere numbers are shown.
	check(UiText.group("1") == "1" and UiText.group("999") == "999" and UiText.group("1000") == "1,000" and UiText.group("178335") == "178,335" and UiText.group("1234567") == "1,234,567", "digits are grouped in threes")
	check(UiText.thousands(178335) == "178,335" and UiText.thousands(12000) == "12,000" and UiText.thousands(999) == "999" and UiText.thousands(0) == "0", "whole numbers are grouped")
	check(UiText.thousands(1234.5, 1) == "1,234.5" and UiText.thousands(-5000) == "-5,000" and UiText.thousands(-0.2, 0) == "0" and UiText.thousands(0.25, 2) == "0.25", "decimals and signs survive")
	var grouped := UiText.numbers("BUPS  178335  x10000  50%  1234.5  288:19:43")
	check(grouped.contains("178,335") and grouped.contains("x[color=") and grouped.contains("10,000") and grouped.contains("1,234.5") and grouped.contains("50[color") == false and grouped.contains("288") and not grouped.contains("178335"), "numbers in a text are grouped as they are coloured: %s" % grouped)
	check(UiText.numbers("12%").contains("12%[/color]") and UiText.numbers("8/s").contains("8/s[/color]"), "units stay with their number")
	check(HistoryGraph.format_time(3600.0 * 1500) == "1,500h" and HistoryGraph.tick_text(5500.0, 6000.0) == "5,500", "graph labels are grouped too")
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	root.add_child(rt)
	rt.text = UiText.numbers("TIME 12s  [PAUSED]  (x3)")
	check(rt.get_parsed_text() == "TIME 12s  [PAUSED]  (x3)", "brackets and text survive styling: '%s'" % rt.get_parsed_text())
	rt.queue_free()

	# --- Each bup is drawn at its true size, or on its own at the least that shows: never thinner or shorter than a few pixels, with no bup enlarging another.
	var drawing := BupSim.new()
	drawing.reset(300.0, 2)
	var newborn_bup := drawing.add_bup(Vector2.ZERO, Genome.founder(), 50.0, 2.0, 4.0, 0, Vector2.RIGHT)  # 1 µm long: mass 4
	var adult_bup := drawing.add_bup(Vector2.ZERO, Genome.founder(), 50.0, 4.0, 8.0, 0, Vector2.RIGHT)  # 4 µm long: mass 16
	var huge_bup := drawing.add_bup(Vector2.ZERO, Genome.founder(), 50.0, 6.0, 8.0, 0, Vector2.RIGHT)  # 9 µm long: mass 36
	var near := drawing.render_buffer(0.5, 3)  # zoomed in: half a micrometre a pixel
	check(is_equal_approx(near[12], 1.0) and is_equal_approx(near[28], 4.0) and is_equal_approx(near[44], 9.0) and is_equal_approx(near[13], Biology.WIDTH), "where bups are big enough to see they are exactly true size (%.2f, %.2f, %.2f µm)" % [near[12], near[28], near[44]])
	var far := drawing.render_buffer(3.0, 3)  # 3 µm a pixel: the least that shows is 6 µm long and 3 µm thick
	check(is_equal_approx(far[12], 6.0) and is_equal_approx(far[28], 6.0) and is_equal_approx(far[44], 9.0) and is_equal_approx(far[13], 3.0), "a bup too small to see is drawn at the least that shows, on its own: the big one is unchanged (%.2f, %.2f, %.2f µm; %.2f thick)" % [far[12], far[28], far[44], far[13]])
	check(is_equal_approx(drawing.bup_radius(adult_bup, 3.0), 3.0) and is_equal_approx(drawing.bup_radius(huge_bup, 3.0), 4.5), "the ring and the picking follow what is drawn")
	var lone := BupSim.new()
	lone.reset(300.0, 3)
	lone.add_bup(Vector2.ZERO, Genome.founder(), 50.0, 2.0, 4.0, 0, Vector2.RIGHT)  # 1 µm long
	check(lone.pick_bup(Vector2(2.0, 0.0), 0.0, 3.0) != -1 and lone.pick_bup(Vector2(2.0, 0.0), 0.0, 0.5) == -1, "a bup that is drawn bigger than it is can be picked by the size it is drawn at")

	# --- The selection ring is a fixed 12 px, and only grows when its subject is over half its diameter.
	check(Dish.ring_radius_pixels(1.0) == 12.0 and Dish.ring_radius_pixels(6.0) == 12.0, "the ring keeps its size for a subject up to half its diameter")
	check(is_equal_approx(Dish.ring_radius_pixels(8.0), 32.0) and is_equal_approx(Dish.ring_radius_pixels(32.0), 128.0), "...and above that grows to keep the subject a quarter of it (8 px -> 32, 32 px -> 128)")

	# --- Picking bups.
	d.strike(_small())
	var target: int = d.bup_ids()[0]
	for id in d.bup_ids():  # alone, so a neighbour can't be the nearer pick
		if id != target:
			d.remove_bup(id)
	var target_pos := d.bup_world_pos(target)
	var target_radius: float = d.sim.bup_radius(target, d.pixel())
	check(d.cell_at(target_pos) == target, "cell_at finds the bup under a point")
	check(d.cell_at(target_pos + Vector2(target_radius + 3.0, 0.0), 0.0) != target, "no slack: just outside misses")
	check(d.cell_at(target_pos + Vector2(target_radius + 3.0, 0.0), 4.0) == target, "slack widens the target")
	check(d.cell_at(d.global_position + Vector2(d.radius * 2.0, 0.0)) == -1, "far from every bup finds none")

	# --- Bups all start inside the dish at any count.
	s.bups = 200
	s.nutrients = 60
	d.strike(s)
	check(_radii(Array(d.bup_ids()).map(func(id: int) -> Vector2: return d.bup_world_pos(id))).max() <= d.radius, "200 bups inside dish")

	# --- Free mode scene: no goals, no saving, uses start conditions, same sim.
	var save_before := FileAccess.get_file_as_string(SaveGame.PATH) if FileAccess.file_exists(SaveGame.PATH) else ""
	var had_save := FileAccess.file_exists(SaveGame.PATH)
	var mtime_before := FileAccess.get_modified_time(SaveGame.PATH) if had_save else 0
	var chosen := _small()
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
	check(m.dish.population() == 150 and absf(TestUtil.units(m.dish) - 40.0) < 2.0 and m.dish.food_rate == 11.0, "free scene started with chosen conditions (%d bups, %.0f nutrient, rate %.0f)" % [m.dish.population(), TestUtil.units(m.dish), m.dish.food_rate])
	for i in 60:
		await process_frame
	check(m.tracker.index == 0, "no goal progress in free mode (pop %d >= 1,000 would complete goal 1)" % m.dish.population())
	check(not m.goal_panel.visible, "free mode has no goal panel")
	var hud_text: String = m.hud.get_parsed_text()
	check(hud_text.contains("bups  150 / ") and hud_text.contains("dish  0.3 mm"), "the readout shows the current population against the limit, and the current dish size ('%s')" % hud_text.get_slice("\n", 1))
	m.dish.change_limit(2000)
	m.dish.grow_to(1500.0)
	await process_frame
	await process_frame
	hud_text = m.hud.get_parsed_text()
	check(hud_text.contains("/ 2,000") and hud_text.contains("dish  1.5 mm"), "...and follows a change of limit or size ('%s')" % hud_text.get_slice("\n", 1))
	m._open_menu()
	check(m.pause_menu.initial_panel.visible and m.pause_menu.initial_bups.value_label.text == "150" and m.pause_menu.initial_nutrients.value_label.text == "40" and m.pause_menu.initial_rate.value_label.text == "11/min" and m.pause_menu.initial_dish.value_label.text == "0.3 mm" and m.pause_menu.initial_limit.value_label.text == UiText.thousands(chosen.bup_limit), "the Escape menu records how the dish started, unchanged by later changes (dish %s)" % m.pause_menu.initial_dish.value_label.text)
	check(m.pause_menu.initial_bups.name_label.text == "Bups" and m.pause_menu.initial_rate.name_label.text == "Nutrient feed", "its rows carry their labels")
	m._close_menu()
	# A slider that can't move is faint, disabled and says why (the dish can't shrink, so at its largest there is nothing to choose).
	m.dish.grow_to(StartConditions.MAX_DISH_RADIUS)
	m._open_menu()
	check(not m.pause_menu.dish_row.slider.editable and not m.pause_menu.dish_row.value_field.editable and m.pause_menu.dish_row.reset_button.disabled and m.pause_menu.dish_row.modulate.a < 1.0 and m.pause_menu.dish_row.slider.tooltip_text != "", "a dish already at its largest has a disabled, faint dish row that says why")
	check(m.pause_menu.limit_row.slider.editable, "...while the limit row, which can still change, stays live")
	m._close_menu()
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
	m2.dish.clear_bups()
	m2.dish.food_rate = 2.0
	m2._restart()
	check(m2.dish.population() == 150 and absf(TestUtil.units(m2.dish) - 40.0) < 2.0 and m2.dish.food_rate == 11.0, "restart reuses free start conditions")
	m2.queue_free()
	await process_frame

	# Goal mode scene still uses the default start and has goals.
	Session.mode = Session.Mode.GOALS
	Session.load_requested = false
	var m3: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m3)
	# Checked straight after _ready, before the first frame: once frames run, the sim feeds
	# and eats nutrient, so the amounts would depend on how long the first frame took.
	check(not m3.free_mode and m3.dish.population() == 4 and absf(TestUtil.units(m3.dish) - 10000.0) < 0.5 and m3.dish.food_rate == 0.0, "goal mode default start: seeded with nutrient, no feed")
	await process_frame
	check(m3.goal_panel.visible and m3.goal_panel.get_parsed_text().begins_with("EXPERIMENT 1 / "), "goal mode shows the goal panel")
	check(not m3.hud.get_parsed_text().contains("DISH"), "goal mode's readout has no dish line")
	m3.queue_free()
	Session.mode = Session.Mode.GOALS

	if failures.is_empty():
		print("FREE MODE TESTS OK")
	else:
		print("FAILED:")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)
