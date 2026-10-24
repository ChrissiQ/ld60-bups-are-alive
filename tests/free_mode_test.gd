extends SceneTree
## Run: godot --headless --path . -s tests/free_mode_test.gd
## Checks start conditions, nutrient layouts, and that free mode has no goals and no saving.
## Backs up the real save in memory and restores it if anything touches it.



func check(ok: bool, what: String) -> void:
	TestUtil.check(ok, what)


## Sets a dish's bloom to this many plankton a day (the game sets a density: this is for tests that count them).
func _bloom_per_day(d: Dish, per_day: float) -> void:
	d.bloom_density = per_day / (PI * pow(d.radius / StartConditions.UM_PER_MM, 2))


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
	check(absf(TestUtil.density(d) - 32.0) < 0.5, "default starting nutrient = 32 units/mm² (about 10,000 units in the 10 mm dish), got %.2f" % TestUtil.density(d))
	check(d.radius == 45000.0 and d.bup_limit == 100000, "the default dish is 45 mm in radius with room for 100,000 bups, got %.0f and %d" % [d.radius, d.bup_limit])

	# --- Counts and clamping.
	var s := _small()
	s.bups = 120
	s.nutrient_density = 150
	d.strike(s)
	check(d.population() == 120, "120 bups, got %d" % d.population())
	check(absf(TestUtil.density(d) - 150.0) < 3.0, "150 units/mm² of starting nutrient, got %.1f" % TestUtil.density(d))
	s.bups = 9999
	s.nutrient_density = 9999999  # (more than the most the game allows)
	d.strike(s)
	check(d.population() == Dish.MAX_CELLS, "bups clamped to MAX_CELLS")
	check(absf(TestUtil.density(d) - StartConditions.MAX_NUTRIENT_DENSITY) < StartConditions.MAX_NUTRIENT_DENSITY * 0.02, "starting nutrient clamped to its maximum")
	s.nutrient_density = 0
	d.strike(s)
	check(d.field.is_empty(), "0 starting nutrient means a bare dish")

	# --- With no patchiness the starting nutrient is spread evenly, wherever you look (see below for the patchy kind).
	d.strike(_small())
	d.field.reset(d.radius)
	d.field.set_patchiness(0.0, 1.0, 0)
	d.field.fill(0.001)
	var centre_c := d.field.sample(Vector2.ZERO)
	var edge_c := d.field.sample(Vector2(d.radius * 0.8, 0.0))
	check(centre_c > 0.0 and absf(centre_c - edge_c) < centre_c * 0.02, "without patchiness the medium is uniform (%.5f vs %.5f)" % [centre_c, edge_c])

	# --- Nutrient rate is part of the start conditions.
	var r := StartConditions.new()
	r.feed_density = 17.0
	d.strike(r)
	check(d.feed_density == 17.0, "start rate applied, got %.1f" % d.feed_density)
	r.feed_density = 999.0
	d.strike(r)
	check(d.feed_density == StartConditions.MAX_FEED_DENSITY, "rate clamped to max")
	d.strike(_small())
	check(d.feed_density == 0.0, "no feed by default, got %.1f" % d.feed_density)

	# --- The feed adds nutrient evenly at the chosen rate.
	d.strike(_small())
	d.clear_bups()
	d.field.reset(d.radius)
	d.feed_density = 12.0
	d.advance(3600.0)
	check(absf(TestUtil.density(d) - 12.0) < 0.3, "the feed adds rate x time to every mm² (%.2f units/mm² in an hour at 12/mm²/h)" % TestUtil.density(d))
	# The nutrient put in is patchy, richer and poorer places that stay put, though the total is what was asked for.
	var patchy := _make_dish()
	patchy.set_seed(8)
	var patch_start := StartConditions.new()
	patch_start.dish_radius = 4000.0
	patch_start.nutrient_density = 100.0
	patchy.strike(patch_start)
	var cell_values: PackedFloat32Array = patchy.field.values()
	var seen := []
	for i in patchy.field.size * patchy.field.size:
		if patchy.field.accepts(patchy.field.cell_centre(i)):
			seen.append(cell_values[i])
	var seen_mean := 0.0
	for v in seen:
		seen_mean += v
	seen_mean /= seen.size()
	var seen_spread := 0.0
	for v in seen:
		seen_spread += (v - seen_mean) * (v - seen_mean)
	seen_spread = sqrt(seen_spread / seen.size()) / seen_mean
	check(absf(TestUtil.density(patchy) - 100.0) < 2.0 and absf(seen_spread - Dish.NUTRIENT_PATCHINESS) < 0.1, "the starting nutrient is uneven (spread %.2f of the mean) with the density asked for (%.1f)" % [seen_spread, TestUtil.density(patchy)])
	patchy.feed_density = 20.0
	patchy.advance(3600.0)
	check(absf(TestUtil.density(patchy) - 120.0) < 3.0, "the feed adds its density on average (%.1f)" % TestUtil.density(patchy))
	var same_seed := _make_dish()
	same_seed.set_seed(8)
	same_seed.strike(patch_start)
	var other_seed := _make_dish()
	other_seed.set_seed(9)
	other_seed.strike(patch_start)
	var probe := Vector2(1000, 500)
	check(same_seed.patch_seed != other_seed.patch_seed and not is_equal_approx(other_seed.field.sample(probe), same_seed.field.sample(probe)), "a landscape depends on the seed: another seed, other patches")
	var landscape_copy := _make_dish()
	check(landscape_copy.from_dict(TestUtil.saved(patchy)) and landscape_copy.patch_seed == patchy.patch_seed, "the landscape's seed survives save and load")
	patchy.free()
	same_seed.free()
	other_seed.free()
	landscape_copy.free()

	# --- Dish size.
	var small := StartConditions.new()
	small.dish_radius = 150.0
	small.bups = 100
	small.nutrient_density = 100
	d.strike(small)
	check(d.radius == 150.0, "dish radius 150, got %.0f" % d.radius)
	var inside_small := true
	for id in d.bup_ids():
		inside_small = inside_small and (d.bup_info(id)["pos"] as Vector2).length() <= d.radius
	check(inside_small, "everything starts inside a small dish")
	check(absf(TestUtil.density(d) - 100.0) < 3.0, "...with its starting nutrient density (%.1f)" % TestUtil.density(d))
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
	large_start.nutrient_density = 500
	large.strike(large_start)
	check(large.bup_limit == 1200 and large.field.size == 96 and large.population() == 200 and absf(TestUtil.density(large) - 500.0) < 10.0, "a big dish starts with its own grid, limit and nutrient")
	large.place_source(large.global_position + Vector2(400, 0), 10.0)
	large.advance(600.0)
	var large_copy := _make_dish()
	check(large_copy.from_dict(TestUtil.saved(large)) and large_copy.radius == 1200.0 and large_copy.field.size == 96, "a big dish survives save and load")
	# The nutrient detail (cells across the grid) is a start condition: a finer grid on a big dish, kept through resize, save and load.
	var fine_start := StartConditions.new()
	fine_start.nutrient_resolution = 200
	var fine_dish := _make_dish()
	fine_dish.strike(fine_start)
	check(StartConditions.new().nutrient_resolution == 100 and fine_dish.field.size == 200 and is_equal_approx(fine_dish.field.get_spacing(), 2.0 * fine_dish.radius / 200.0), "the nutrient detail sets the cells across a dish's grid (%d)" % fine_dish.field.size)
	fine_dish.resize_to(fine_dish.radius * 1.5)
	check(fine_dish.field.size == 200, "a resized dish keeps its nutrient detail")
	var fine_copy := _make_dish()
	check(fine_copy.from_dict(TestUtil.saved(fine_dish)) and fine_copy.field.size == 200 and fine_copy.field.get_max_across() == 200, "the nutrient detail survives save and load")
	var old_save := TestUtil.saved(fine_dish)
	old_save.erase("nutrient_resolution")
	old_save["field"] = Array(_make_dish().field.values())  # (a save from before the setting: the default grid)
	var plain := _make_dish()
	plain.strike(StartConditions.new())
	var plain_save := TestUtil.saved(plain)
	plain_save.erase("nutrient_resolution")
	var plain_copy := _make_dish()
	check(plain_copy.from_dict(plain_save) and plain_copy.field.size == 100, "a save without the setting loads with the default grid")
	# The medium thickness (an advanced option): how fast the nutrient spreads, kept through resize, save and load.
	var thin_start := StartConditions.new()
	thin_start.medium_thickness = 4.0
	var thin_dish := _make_dish()
	thin_dish.strike(thin_start)
	var usual_dish := _make_dish()
	usual_dish.strike(StartConditions.new())
	check(is_equal_approx(thin_dish.field.get_diffusion(), Biology.WATER_DIFFUSION / 4.0) and is_equal_approx(usual_dish.field.get_diffusion(), Biology.NUTRIENT_DIFFUSION), "the medium thickness sets how fast the nutrient spreads (%.1f in 4x water, %.1f in the usual medium)" % [thin_dish.field.get_diffusion(), usual_dish.field.get_diffusion()])
	var thin_copy := _make_dish()
	check(thin_copy.from_dict(TestUtil.saved(thin_dish)) and is_equal_approx(thin_copy.medium_thickness, 4.0) and is_equal_approx(thin_copy.field.get_diffusion(), Biology.WATER_DIFFUSION / 4.0), "the medium thickness survives save and load")
	var usual_copy := _make_dish()
	var usual_save := TestUtil.saved(usual_dish)
	usual_save.erase("medium_thickness")
	check(usual_copy.from_dict(usual_save) and is_equal_approx(usual_copy.field.get_diffusion(), Biology.NUTRIENT_DIFFUSION), "a save without the setting loads with the usual medium")
	check(StartConditions.from_dict({"medium_thickness": 0.0}).medium_thickness == StartConditions.MIN_MEDIUM_THICKNESS and StartConditions.from_dict({"medium_thickness": 1000.0}).medium_thickness == StartConditions.MAX_MEDIUM_THICKNESS, "the medium thickness is clamped when loaded")
	check(StartConditions.from_dict({"nutrient_resolution": 9999}).nutrient_resolution == StartConditions.MAX_NUTRIENT_RESOLUTION and StartConditions.from_dict({"nutrient_resolution": 10}).nutrient_resolution == StartConditions.MIN_NUTRIENT_RESOLUTION, "the nutrient detail is clamped when loaded")
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
	seed(20261022)  # (the draws are random, and the brightness bar is within half a standard error of the true mean: a fixed seed keeps the test from flipping)
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
	var colours_before_names := []
	for picker in screen._colors:
		colours_before_names.append(picker.color)
	screen._randomise_names()
	var picked := []
	var names_ok := true
	for edit in screen._names:
		picked.append(edit.text)
		names_ok = names_ok and edit.text != "" and not edit.text.contains(" ") and edit.text.length() <= 8
	var colours_kept := true
	for i in 5:
		colours_kept = colours_kept and colours_before_names[i].is_equal_approx(screen._colors[i].color)
	var distinct := {}
	for n in picked:
		distinct[n] = true
	check(names_ok and distinct.size() == 5 and colours_kept, "Random names gives every founder a short one-word name of its own and leaves the colours (%s)" % [picked])
	var name_list := BupNames.random_pool()
	var list_ok := name_list.size() >= StartConditions.MAX_BUPS
	var seen_names := {}
	for n in name_list:
		list_ok = list_ok and n == n.to_lower() and n.length() >= 2 and n.length() <= 8 and not n.contains(" ") and not seen_names.has(n)
		seen_names[n] = true
	check(list_ok, "the list of random names holds at least one for every possible founder (%d), each lowercase, one word, short, none twice" % name_list.size())
	screen._reset_all()
	var reset_ok := true
	for i in 5:
		reset_ok = reset_ok and screen._names[i].text == "" and screen._colors[i].color.is_equal_approx(Genome.color_of(Genome.founder()))
	check(reset_ok and screen.reset_button.tooltip_text == "Reset all", "the reset icon (hover: Reset all) clears every name and puts every colour back to the default")
	screen._names[2].text = "  Maeve "
	screen._colors[2].color = Color.html("#3366cc")
	var collected: Array = screen._collect()
	check(collected.size() == 3 and collected[0] == {} and collected[2] == {"name": "Maeve", "color": "#3366cc"}, "what is typed and picked is collected, tidied, and trailing founders left at the default are not kept (%s)" % [collected])
	# Going back keeps nothing: the settings stay as they were, even after a reset or edits.
	var founders_before: Array = Session.free_start.founders.duplicate(true)
	var file_before: String = FileAccess.get_file_as_string(StartConditions.settings_path)
	screen._names[0].text = "Edited"
	screen._reset_all()
	screen._back()
	await process_frame
	check(Session.free_start.founders == founders_before and FileAccess.get_file_as_string(StartConditions.settings_path) == file_before, "going back from the founders screen, after edits and a reset, leaves the settings as they were (nothing kept, nothing saved)")
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
	growing.resize_to(1500.0)
	check(growing.radius == 1500.0 and growing.field.size == NutrientField.size_for(1500.0), "resize_to enlarges the dish and its grid")
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
	growing.resize_to(99999.0)
	check(growing.radius == StartConditions.MAX_DISH_RADIUS, "...and never outgrows the largest")
	growing.change_limit(1)
	check(growing.bup_limit == growing.population(), "the bup limit can't be set below the bups there are (%d)" % growing.bup_limit)
	growing.advance(60.0)
	check(growing.population() > 0, "an enlarged dish keeps running")
	growing.free()

	# --- The watch list: watched bups, and their ancestors, keep their records after they die, until taken off.
	var watching := _make_dish()
	watching.strike(_small())
	watching.clear_bups()
	var elder := watching.add_bup(watching.global_position, Genome.founder(), 30.0)
	var young: int = watching.sim.add_bup(Vector2(5, 5), Genome.founder(), 30.0, -1.0, -1.0, 1, Vector2.RIGHT, -1, elder)
	check(watching.watch_bup(young) and not watching.watch_bup(young) and watching.is_watched(young) and watching.watched == [young], "a bup goes on the watch list once")
	watching.remove_bup(elder)
	watching.remove_bup(young)
	check(not watching.has_bup(young) and watching.has_record(young) and watching.has_record(elder), "a watched bup keeps its record after it dies, and so does its ancestor")
	var saved_watch := TestUtil.saved(watching)
	var watch_copy := _make_dish()
	check(watch_copy.from_dict(saved_watch) and watch_copy.watched == [young] and watch_copy.has_record(young), "the watch list survives save and load")
	watch_copy.free()
	watching.unwatch_bup(young)
	check(watching.watched.is_empty() and not watching.has_record(young) and not watching.has_record(elder), "taken off the list, the records go (nothing else needs them)")
	check(not watching.watch_bup(123456), "a bup with no record can't be watched")
	var crowd_ids: Array[int] = []
	for i in Dish.MAX_WATCHED + 5:
		crowd_ids.append(watching.add_bup(watching.global_position + Vector2(i % 20, i / 20) * 2.0, Genome.founder(), 30.0))
	var added := 0
	for id in crowd_ids:
		if watching.watch_bup(id):
			added += 1
	check(added == Dish.MAX_WATCHED and watching.watched.size() == Dish.MAX_WATCHED, "the list holds %d and no more (%d)" % [Dish.MAX_WATCHED, added])
	watching.strike(_small())
	check(watching.watched.is_empty(), "a new dish starts with nothing watched")
	watching.free()

	# --- A dish can shrink about its centre: what is past the new edge goes, the rest keeps its density.
	var shrinking := _make_dish()
	var shrink_start := StartConditions.new()
	shrink_start.dish_radius = 3000.0
	shrink_start.nutrient_density = 30000
	shrinking.strike(shrink_start)
	shrinking.clear_bups()
	var kept_ids: Array[int] = []
	var lost_ids: Array[int] = []
	for offset in [Vector2(500, 0), Vector2(0, -1200)]:
		kept_ids.append(shrinking.add_bup(shrinking.global_position + offset, Genome.founder(), 30.0))
	for offset in [Vector2(2000, 0), Vector2(-2500, 100)]:
		lost_ids.append(shrinking.add_bup(shrinking.global_position + offset, Genome.founder(), 30.0))
	shrinking.place_source(shrinking.global_position + Vector2(500, 0), 5.0)
	shrinking.place_source(shrinking.global_position + Vector2(2200, 0), 5.0)
	shrinking.plankton.append(Plankton.new(Vector2(1000, 0), 0.0, 1e9, 300.0, 0.0))
	shrinking.plankton.append(Plankton.new(Vector2(2500, 0), 0.0, 1e9, 300.0, 0.0))
	shrinking.feed_density = 8.0
	shrinking.bloom_density = 0.25
	var density_before := shrinking.field.sample(Vector2.ZERO)
	shrinking.resize_to(1500.0)
	check(shrinking.radius == 1500.0 and shrinking.field.size == NutrientField.size_for(1500.0), "a dish shrinks to the size asked")
	var survivors_inside := true
	for id in shrinking.sim.bup_ids():
		survivors_inside = survivors_inside and shrinking.bup_world_pos(id).distance_to(shrinking.global_position) <= 1500.0
	check(shrinking.population() == 2 and survivors_inside, "bups past the new edge die and the rest are inside (%d left)" % shrinking.population())
	var kept_alive := true
	for id in kept_ids:
		kept_alive = kept_alive and shrinking.has_bup(id) and shrinking.has_record(id)
	var lost_gone := true
	for id in lost_ids:
		lost_gone = lost_gone and not shrinking.has_bup(id) and not shrinking.has_record(id)
	check(kept_alive and lost_gone, "the bups inside live on, and the dead ones' records are freed (no descendants, not open anywhere)")
	check(shrinking.sources.size() == 1 and shrinking.plankton.size() == 1, "sources and plankton past the edge go (%d sources, %d plankton left)" % [shrinking.sources.size(), shrinking.plankton.size()])
	check(is_equal_approx(shrinking.feed_density, 8.0) and is_equal_approx(shrinking.bloom_density, 0.25) and is_equal_approx(shrinking.bloom_per_day(), 0.25 * PI * 1.5 * 1.5), "the feed and the bloom are densities, so they stay as they were, and the bloom's plankton a day follow the area (%.2f, %.3f, %.3f a day)" % [shrinking.feed_density, shrinking.bloom_density, shrinking.bloom_per_day()])
	check(absf(shrinking.field.sample(Vector2.ZERO) - density_before) < 0.06 * density_before, "the nutrient left keeps its concentration (%.4f then, %.4f now)" % [density_before, shrinking.field.sample(Vector2.ZERO)])
	shrinking.resize_to(10.0)
	check(shrinking.radius == StartConditions.MIN_DISH_RADIUS, "and never below the smallest dish")
	shrinking.resize_to(3000.0)
	check(is_equal_approx(shrinking.feed_density, 8.0) and is_equal_approx(shrinking.bloom_density, 0.25) and is_equal_approx(shrinking.bloom_per_day(), 0.25 * PI * 9.0), "growing again gives the bloom more plankton a day with the area, and leaves the feed and the bloom densities alone")
	shrinking.advance(60.0)
	check(shrinking.population() <= 2, "a shrunken dish keeps running")
	shrinking.free()

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
	check(StartConditions.MAX_DISH_RADIUS == 90000.0 and StartConditions.MAX_BUP_LIMIT == 2000000, "free mode offers dishes up to 90000 µm and limits up to 2,000,000")
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
	d.field.set_patchiness(0.0, 1.0, 0)  # (an even medium, so the brush's effect is plain to see)
	d.field.fill(1.0)
	var total_filled: float = d.field.total()
	var patch := d.global_position + Vector2(-80, 40)
	var middle_before := d.field.sample(patch - d.global_position)
	var removed := d.erase_nutrient(patch, 40.0)
	check(removed > 0.0 and d.field.sample(patch - d.global_position) < middle_before * 0.25, "erasing lowers the nutrient at the middle of the brush")
	var rim := patch + Vector2(36, 0)
	check(d.field.sample(rim - d.global_position) > d.field.sample(patch - d.global_position), "...and less towards its edge")
	check(absf(d.field.sample(d.global_position + Vector2(150, 150) - d.global_position) - middle_before) < middle_before * 0.01, "...and not at all outside it")
	check(absf((total_filled - d.field.total()) / Dish.NUTRIENT_ENERGY - removed) < 0.01, "erasing reports the units it removed")

	# --- Plankton: placed by hand, as many as the dish holds, they float until they burst into nutrient; a bloom adds more at random.
	var bloom := _make_dish()
	bloom.strike(_small())
	bloom.field.reset(bloom.radius)
	var bloom_spot := bloom.global_position + Vector2(40, 30)
	check(bloom.plankton.is_empty() and bloom.bloom_density == 0.0, "a new dish has no plankton in the water and no bloom")
	check(bloom.place_plankton(bloom_spot) and bloom.plankton.size() == 1, "a plankton can be placed")
	check(not bloom.place_plankton(bloom.global_position + Vector2(bloom.radius + 10.0, 0)), "plankton can't be placed outside the dish")
	var lifetime: float = bloom.plankton[0].burst_at - bloom.time
	check(lifetime >= Dish.PLANKTON_MEAN_LIFE * (1.0 - Dish.PLANKTON_LIFE_SPREAD) and lifetime <= Dish.PLANKTON_MEAN_LIFE * (1.0 + Dish.PLANKTON_LIFE_SPREAD), "it bursts at a random time within a set span of the mean life (%.0f s)" % lifetime)
	var before_burst := TestUtil.units(bloom)
	bloom.plankton[0].burst_at = bloom.time + 1.0
	bloom.advance(Dish.BURST_CHECK_SECONDS)  # (they are looked over for bursts once in this long)
	check(bloom.plankton.is_empty() and absf(TestUtil.units(bloom) - before_burst - Dish.PLANKTON_UNITS) < 1.0, "a plankton that bursts is gone and leaves its %.0f units of nutrient (%.1f)" % [Dish.PLANKTON_UNITS, TestUtil.units(bloom) - before_burst])
	for i in 30:
		bloom.place_plankton(bloom_spot)
	check(bloom.plankton.size() == 30, "there is no limit on how many the player places but the dish's (%d)" % bloom.plankton.size())
	bloom.plankton.clear()
	bloom.resize_to(Dish.DEFAULT_RADIUS)  # (the 300 µm dish is too small for a bloom of any size: a day's worth is a fraction of a plankton)
	_bloom_per_day(bloom, 240.0)
	bloom.advance(3600.0)
	check(bloom.plankton.size() >= 8 and bloom.plankton.size() <= 12, "a bloom of 240 a day (10 an hour) adds one every 6 minutes, so about ten are floating after an hour (%d)" % bloom.plankton.size())
	# They arrive on a fixed schedule: exactly one every 6 minutes, whatever else is random.
	var drip := _make_dish()
	drip.strike(_small())
	drip.clear_bups()
	drip.resize_to(Dish.DEFAULT_RADIUS)
	_bloom_per_day(drip, 240.0)
	var arrivals_seen: Array[float] = []
	var seen_ids := {}
	for i in int(3600.0 / 10.0):
		drip.step(10.0)
		for cell in drip.plankton:
			if not seen_ids.has(cell.get_instance_id()):
				seen_ids[cell.get_instance_id()] = true
				arrivals_seen.append(drip.time)
	var even := arrivals_seen.size() >= 9
	for i in range(1, arrivals_seen.size()):
		even = even and absf((arrivals_seen[i] - arrivals_seen[i - 1]) - 360.0) < 10.5
	check(even, "the bloom drips plankton in on a fixed schedule, one every 6 minutes (%s)" % [arrivals_seen]) 
	bloom.bloom_density = 1000.0
	check(bloom.bloom_density == StartConditions.MAX_BLOOM_DENSITY, "the bloom density cannot be set above the most the game allows")
	var biggest_per_step := StartConditions.MAX_BLOOM_DENSITY * PI * pow(StartConditions.MAX_DISH_RADIUS / StartConditions.UM_PER_MM, 2) / 86400.0 * Dish.MAX_STEP
	var biggest_floating := StartConditions.MAX_BLOOM_DENSITY * PI * pow(StartConditions.MAX_DISH_RADIUS / StartConditions.UM_PER_MM, 2) * Dish.PLANKTON_MEAN_LIFE / 86400.0
	check(biggest_per_step < Dish.MAX_BLOOM_ARRIVALS_PER_STEP and biggest_floating < Dish.MAX_PLANKTON, "the most bloom on the biggest dish fits what a step can add (%.0f of %d) and what the dish can hold (%.0f of %d)" % [biggest_per_step, Dish.MAX_BLOOM_ARRIVALS_PER_STEP, biggest_floating, Dish.MAX_PLANKTON])
	# The bursts, which are what feed the colony, come at steady enough intervals: no long gaps with nothing.
	var steady := _make_dish()
	steady.strike(_small())
	steady.clear_bups()
	steady.resize_to(Dish.DEFAULT_RADIUS)
	_bloom_per_day(steady, 24.0)
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
	# A paused dish is redrawn once with no trails: the picture made while time moved may carry them.
	bloom._process(0.0)
	bloom.step(5.0)
	bloom._process(0.0)
	check(bloom._trails_may_show, "a picture made as time moved may carry trails")
	var stamp_then: Array = bloom._render_stamp
	bloom._process(0.0)
	check(not bloom._trails_may_show and bloom._render_stamp == stamp_then, "the next picture, with nothing moving, is made once more, and then no trails remain")
	bloom.bloom_density = 0.0
	bloom.plankton.clear()
	bloom.advance(600.0)
	check(bloom.plankton.is_empty(), "with no bloom nothing appears by itself")
	bloom.place_plankton(bloom_spot)
	var cost_before: float = bloom.bup_info(bloom.sim.bup_ids()[0])["upkeep"]
	bloom.upkeep_factor = 10.0
	var cost_after: float = bloom.bup_info(bloom.sim.bup_ids()[0])["upkeep"]
	check(cost_after > 5.0 * cost_before and cost_after < 10.0 * cost_before, "a higher upkeep factor makes staying alive cost more (%.5f to %.5f a second)" % [cost_before, cost_after])
	bloom.bloom_density = 0.07
	var bloom_copy := _make_dish()
	check(bloom_copy.from_dict(TestUtil.saved(bloom)) and bloom_copy.plankton.size() == 1 and is_equal_approx(bloom_copy.plankton[0].burst_at, bloom.plankton[0].burst_at) and bloom_copy.bloom_density == 0.07, "plankton and the bloom density survive save and load")
	check(StartConditions.from_dict({"bloom_density": 9999}).bloom_density == StartConditions.MAX_BLOOM_DENSITY and StartConditions.new().bloom_density == 0.0, "the bloom density is a start condition: none by default, clamped when loaded")

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
	check(HistoryGraph.nice_ceil(1234.0) == 1600.0 and HistoryGraph.nice_ceil(35300.0) == 40000.0 and HistoryGraph.nice_ceil(100000.0) == 100000.0 and HistoryGraph.nice_ceil(9000.0) == 10000.0, "axis max beyond the table rounds up to a round number that halves to one (%s, %s)" % [HistoryGraph.nice_ceil(1234.0), HistoryGraph.nice_ceil(35300.0)])
	check(SimClock.format(0) == "0:00" and SimClock.format(65) == "1:05" and SimClock.format(900) == "15:00" and SimClock.format(3600) == "1:00:00" and SimClock.format(3725) == "1:02:05", "the clock reads simulation time as m:ss, then h:mm:ss")
	check(HistoryGraph.pop_axis_max(1.2e6, 1000000) == 1000000.0 and HistoryGraph.pop_axis_max(1000000.0, 1000000) == 1000000.0 and HistoryGraph.pop_axis_max(4.0e5, 1000000) == 4.0e5 and HistoryGraph.pop_axis_max(1.2e6, 0) == 1.2e6, "the population axis never tops out above the bup limit (and rounds up to it below)")
	check(HistoryGraph.format_time(3600) == "1h" and HistoryGraph.format_time(7200) == "2h", "graph ticks count hours of simulation time")
	check(HistoryGraph.time_ticks(0.0, 900.0, 300.0) == [0.0, 300.0, 600.0, 900.0], "time ticks over the first window")
	check(HistoryGraph.time_ticks(399.0, 1299.0, 300.0) == [600.0, 900.0, 1200.0], "time ticks over a scrolled window")
	check(HistoryGraph.time_ticks(0.0, 100.0, 300.0) == [0.0], "a short window still has its origin tick")
	var A := HistoryGraph.Span
	check(HistoryGraph.auto_span(100.0) == A.LAST_24 and HistoryGraph.auto_span(86399.0) == A.LAST_24, "until G is pressed the graph shows 24 hours at first")
	check(HistoryGraph.auto_span(86400.0) == A.LAST_72 and HistoryGraph.auto_span(259199.0) == A.LAST_72, "...moves up to 72 hours once the run is 24 hours long")
	check(HistoryGraph.auto_span(259200.0) == A.LAST_WEEK and HistoryGraph.auto_span(604799.0) == A.LAST_WEEK and HistoryGraph.auto_span(604800.0) == A.ALL and HistoryGraph.auto_span(9.0e7) == A.ALL, "...then to a week at 72 hours and to the whole run at a week")
	check(HistoryGraph.window_start_for(A.LAST_24, 100.0) == 0.0 and HistoryGraph.window_start_for(A.LAST_72, 200000.0) == 0.0, "the window starts at zero until the run outgrows it")
	check(HistoryGraph.window_start_for(A.LAST_72, 300000.0) == 300000.0 - 72.0 * 3600.0, "then it follows the newest sample (%s)" % HistoryGraph.window_start_for(A.LAST_72, 300000.0))
	# The graph's spans, and the whole run in a bounded history.
	var spans := HistoryGraph.new()
	check(not spans.chosen and spans.shown_span() == A.LAST_24, "the graph starts on 24 hours and moves up by itself until G is pressed")
	var order := []
	for i in 5:
		spans.cycle_span()
		order.append(spans.shown_span())
	check(order == [A.LAST_72, A.LAST_WEEK, A.ALL, A.LAST_24, A.LAST_72] and spans.chosen, "G goes through the four modes, 24h, 72h, week and the whole run, round again, and from then on it is the player's choice")
	spans.free()
	check(HistoryGraph.span_seconds(HistoryGraph.Span.LAST_72, 100.0) == 72.0 * 3600.0 and HistoryGraph.span_seconds(HistoryGraph.Span.LAST_WEEK, 100.0) == 168.0 * 3600.0, "a fixed span is as long as it says")
	check(HistoryGraph.span_seconds(HistoryGraph.Span.ALL, 600000.0) == 600000.0 and HistoryGraph.span_seconds(HistoryGraph.Span.ALL, 10.0) == HistoryGraph.MIN_ALL_WINDOW, "the whole-run span is the run so far (never under an hour)")
	check(HistoryGraph.window_start_for(HistoryGraph.Span.LAST_24, 50.0 * 3600.0) == 26.0 * 3600.0 and HistoryGraph.window_start_for(HistoryGraph.Span.LAST_24, 10.0 * 3600.0) == 0.0 and HistoryGraph.window_start_for(HistoryGraph.Span.ALL, 900000.0) == 0.0, "a last-N window follows the newest sample once the run outgrows it; the whole run starts at zero")
	check(HistoryGraph.tick_step(24.0 * 3600.0) == 4.0 * 3600.0 and HistoryGraph.tick_step(72.0 * 3600.0) == 12.0 * 3600.0 and HistoryGraph.tick_step(168.0 * 3600.0) == 48.0 * 3600.0, "time ticks are spaced for the window")
	check(HistoryGraph.tick_step(2.0 * 86400.0, 24.0) == 86400.0, "ticks counted in days are whole days apart")
	check(not HistoryGraph.ticks_in_days(HistoryGraph.Span.LAST_WEEK, 168.0 * 3600.0) and HistoryGraph.ticks_in_days(HistoryGraph.Span.ALL, 8.0 * 86400.0) and HistoryGraph.ticks_in_days(HistoryGraph.Span.LAST_72, 8.0 * 86400.0) and not HistoryGraph.ticks_in_days(HistoryGraph.Span.ALL, 3600.0), "the axis counts days past a week, and for the whole run once it is a couple of days")
	check(HistoryGraph.format_time(86400.0 * 3.0, true) == "3d" and HistoryGraph.format_time(86400.0 * 1500.0, true) == "1,500d" and HistoryGraph.format_time(3600.0 * 5.0) == "5h", "days and hours on the ticks")
	# The history goes on after the colony dies out, so its time stays true: the population drops to zero and the traits stay.
	var gone := _make_dish()
	gone.strike(_small())
	for i in 40:
		gone.step(20.0)
	var recorded: int = gone.history["pop"].size()
	var sense_then: float = gone.history["sense"][-1]
	gone.clear_bups()
	for i in 40:
		gone.step(20.0)
	check(gone.history["pop"].size() > recorded and gone.history["pop"][-1] == 0 and gone.history["sense"][-1] == sense_then and gone.history["pop"].size() == int(gone.time / Dish.HISTORY_INTERVAL), "the history keeps its time after the colony dies out (%d samples for %.0f s)" % [gone.history["pop"].size(), gone.time])
	gone.free()
	var whole := _make_dish()
	whole.strike(_small())
	whole.clear_bups()
	whole.add_bup(whole.global_position, Genome.founder(), 30.0)
	var samples := 6000
	var sum_pop := 0.0
	for i in samples:
		whole._record_history()
		sum_pop += whole.history["pop"][-1]
	var whole_n: int = whole.history_all["pop"].size()
	check(whole_n < Dish.HISTORY_ALL_LEN and whole.history_all_factor == 8 and whole_n * whole.history_all_factor <= samples and (whole_n + 1) * whole.history_all_factor > samples, "the whole-run history stays under its limit by merging pairs (%d samples, each of %d)" % [whole_n, whole.history_all_factor])
	check(whole.history["pop"].size() == Dish.HISTORY_LEN, "the fine history keeps its week")
	var mean_all := 0.0
	for v in whole.history_all["pop"]:
		mean_all += v
	check(absf(mean_all / whole_n - sum_pop / samples) < 0.01, "...and its samples are means, so they keep the average")
	var whole_copy := _make_dish()
	check(whole_copy.from_dict(TestUtil.saved(whole)) and whole_copy.history_all["pop"].size() == whole_n and whole_copy.history_all_factor == whole.history_all_factor, "the whole-run history survives save and load")
	whole.free()
	whole_copy.free()
	check(Dish.HISTORY_LEN * Dish.HISTORY_INTERVAL == 168.0 * 3600.0, "the dish keeps a week of samples")
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
		"no bups block": func(x: Dictionary) -> void: x.erase("cells"),
		"bups in the old format, a list": func(x: Dictionary) -> void: x["cells"] = [{"pos": [1.0, 1.0]}],
		"bups block of the wrong size for a record": func(x: Dictionary) -> void: x["cells"] = Dish._pack_bytes(PackedByteArray([1, 2, 3])),
		"bups block that does not decompress to its size": func(x: Dictionary) -> void: x["cells"]["raw"] = int(x["cells"]["raw"]) + 96,
		"no family records": func(x: Dictionary) -> void: x.erase("lineage"),
		"family records cut short": func(x: Dictionary) -> void: x["lineage"]["z"] = str(x["lineage"]["z"]).substr(0, 20),
		"source position too short": func(x: Dictionary) -> void: x["sources"][0]["pos"] = [3.0],
		"source rate is text": func(x: Dictionary) -> void: x["sources"][0]["rate"] = "fast",
		"nutrient field is the wrong size": func(x: Dictionary) -> void: x["field"] = [0.1, 0.2],
		"bups block empty": func(x: Dictionary) -> void: x["cells"] = {},
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
	check(victim.from_dict(odd), "a save with out-of-range values still loads")
	check(victim.radius == StartConditions.MAX_DISH_RADIUS, "...with the radius clamped (%.0f)" % victim.radius)
	check(victim.selected_source == null and victim.selected_id == -1, "a successful load clears the selection")

	# --- StartConditions: one source for limits, and an honest copy().
	check(StartConditions.MAX_BUPS <= StartConditions.MAX_BUP_LIMIT, "the bups slider cap never exceeds the limit slider's")
	check(StartConditions.new().dish_radius == StartConditions.DEFAULT_RADIUS, "default radius is the start's default")
	var original := StartConditions.new()
	original.bups = 33
	original.nutrient_density = 44
	original.feed_density = 7.0
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
	s.nutrient_density = 60
	d.strike(s)
	check(_radii(Array(d.bup_ids()).map(func(id: int) -> Vector2: return d.bup_world_pos(id))).max() <= d.radius, "200 bups inside dish")

	# --- Free mode scene: no goals, no saving, uses start conditions, same sim.
	var save_before := FileAccess.get_file_as_string(SaveGame.PATH) if FileAccess.file_exists(SaveGame.PATH) else ""
	var had_save := FileAccess.file_exists(SaveGame.PATH)
	var mtime_before := FileAccess.get_modified_time(SaveGame.PATH) if had_save else 0
	var chosen := _small()
	chosen.bups = 150
	chosen.nutrient_density = 40
	chosen.feed_density = 11.0
	Session.free_start = chosen
	Session.mode = Session.Mode.FREE
	Session.load_requested = true  # must be ignored in free mode
	var m: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m)
	await process_frame
	check(m.free_mode, "main.free_mode")
	check(m.dish.population() == 150 and absf(TestUtil.density(m.dish) - 40.0) < 1.0 and m.dish.feed_density == 11.0, "free scene started with chosen conditions (%d bups, %.0f units/mm², feed %.0f)" % [m.dish.population(), TestUtil.density(m.dish), m.dish.feed_density])
	for i in 60:
		await process_frame
	check(m.tracker.index == 0, "no goal progress in free mode (pop %d >= 1,000 would complete goal 1)" % m.dish.population())
	check(not m.goal_panel.visible, "free mode has no goal panel")
	var hud_text: String = m.hud.get_parsed_text()
	check(hud_text.contains("bups  150 / ") and hud_text.contains("dish  0.3 mm"), "the readout shows the current population against the limit, and the current dish size ('%s')" % hud_text.get_slice("\n", 1))
	m.dish.change_limit(2000)
	m.dish.resize_to(1500.0)
	await process_frame
	await process_frame
	hud_text = m.hud.get_parsed_text()
	check(hud_text.contains("/ 2,000") and hud_text.contains("dish  1.5 mm"), "...and follows a change of limit or size ('%s')" % hud_text.get_slice("\n", 1))
	m._open_menu()
	check(m.pause_menu.initial_panel.visible and m.pause_menu.initial_bups.value_label.text == "150" and m.pause_menu.initial_nutrients.value_label.text == "40/mm²" and m.pause_menu.initial_rate.value_label.text == "11.0 /mm²/h" and m.pause_menu.initial_dish.value_label.text == "0.3 mm" and m.pause_menu.initial_limit.value_label.text == UiText.thousands(chosen.bup_limit), "the Escape menu records how the dish started, unchanged by later changes (dish %s)" % m.pause_menu.initial_dish.value_label.text)
	check(m.pause_menu.initial_bups.name_label.text == "Bups" and m.pause_menu.initial_rate.name_label.text == "Nutrient feed", "its rows carry their labels")
	check(m.pause_menu.initial_running.visible and m.pause_menu.initial_running.name_label.text == "Simulating on" and m.pause_menu.initial_running.value_label.text == "CPU (auto)", "the record says where the bups are simulated now: the processor, chosen by the game")
	check(not m.pause_menu.initial_backend.visible, "the record has no row for the GPU setting while it is Auto (like the other advanced settings at their defaults)")
	var gpu_start := chosen.copy()
	gpu_start.sim_backend = StartConditions.BACKEND_GPU
	m.pause_menu.open(m.dish, true, gpu_start)
	check(m.pause_menu.initial_backend.visible and m.pause_menu.initial_backend.value_label.text == "On" and m.pause_menu.initial_backend.name_label.text == "GPU simulation", "...and a row saying On when it was not")
	gpu_start.sim_backend = StartConditions.BACKEND_CPU
	m.pause_menu.open(m.dish, true, gpu_start)
	check(m.pause_menu.initial_backend.visible and m.pause_menu.initial_backend.value_label.text == "Off", "...or Off")
	m._close_menu()
	# The dish-size slider covers every size, so a dish at its largest can still shrink.
	m.dish.resize_to(StartConditions.MAX_DISH_RADIUS)
	m._open_menu()
	check(m.pause_menu.dish_row.slider.editable and is_equal_approx(m.pause_menu.dish_row.slider.min_value, StartConditions.MIN_DISH_RADIUS / StartConditions.UM_PER_MM) and is_equal_approx(m.pause_menu.dish_row.slider.value, StartConditions.MAX_DISH_RADIUS / StartConditions.UM_PER_MM), "a dish at its largest still has a live dish row, from the smallest size up to the largest")
	check(m.pause_menu.limit_row.slider.editable, "...and the limit row is live too")
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
	m2.dish.feed_density = 2.0
	m2._restart()
	check(m2.dish.population() == 150 and absf(TestUtil.density(m2.dish) - 40.0) < 1.0 and m2.dish.feed_density == 11.0, "restart reuses free start conditions")
	m2.queue_free()
	await process_frame

	# Goal mode scene still uses the default start and has goals.
	Session.mode = Session.Mode.GOALS
	Session.load_requested = false
	var m3: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(m3)
	# Checked straight after _ready, before the first frame: once frames run, the sim feeds
	# and eats nutrient, so the amounts would depend on how long the first frame took.
	check(not m3.free_mode and m3.dish.population() == 4 and absf(TestUtil.density(m3.dish) - 32.0) < 0.5 and m3.dish.feed_density == 0.0, "goal mode default start: seeded with nutrient, no feed")
	await process_frame
	check(m3.goal_panel.visible and m3.goal_panel.get_parsed_text().begins_with("EXPERIMENT 1 / "), "goal mode shows the goal panel")
	check(not m3.hud.get_parsed_text().contains("DISH"), "goal mode's readout has no dish line")
	m3.queue_free()
	Session.mode = Session.Mode.GOALS

	# Spread colours: a random starting hue, then each next founder one step (1/n) further round the wheel, at full strength.
	var spread := Genome.spread_colors(5)
	var spread_in_order := spread.size() == 5
	for k in range(1, spread.size()):
		spread_in_order = spread_in_order and absf(fposmod(spread[k].h - spread[k - 1].h, 1.0) - 0.2) < 0.001 and is_equal_approx(spread[k].s, 1.0) and is_equal_approx(spread[k].v, 1.0)
	check(spread_in_order, "spread colours go round the wheel in order, a fifth of it apart for five founders")
	_backend_rule_tests()
	TestUtil.finish(self, "FREE MODE TESTS OK")


## The GPU setting and the rule that picks the backend (Dish.backend_wants_gpu is a function of sizes, speed and population alone).
## A step of 18.5 s is a frame at x10,000 (9 steps), 16.7 s one at x1,000 (1 step), 1.67 s one at x100; moves are BupSim.moves_for of the step.
func _backend_rule_tests() -> void:
	var auto := StartConditions.BACKEND_AUTO
	var on := StartConditions.BACKEND_GPU
	var off := StartConditions.BACKEND_CPU
	# The setting: saved with the rest, anything else is Auto, goal mode's dish is always Auto.
	var chosen := StartConditions.new()
	check(chosen.sim_backend == auto, "the GPU setting starts as Auto")
	chosen.sim_backend = on
	check(StartConditions.from_dict(chosen.to_dict()).sim_backend == on and chosen.copy().sim_backend == on, "the GPU setting is saved and loaded with the rest")
	check(StartConditions.from_dict({"sim_backend": "fast"}).sim_backend == auto and StartConditions.from_dict({"sim_backend": 3}).sim_backend == auto and StartConditions.from_dict({}).sim_backend == auto, "a setting that is not one of the three is Auto")
	var d := _make_dish()
	d.strike(chosen)
	check(d.backend_setting == on and d.backend_running() == "cpu", "a dish takes the setting from its start (and runs on the processor where there is no GPU path: %s)" % d.backend_running())
	d.strike()
	check(d.backend_setting == auto, "goal mode's dish (no start given) is always Auto")
	# Fine steps never run on the GPU, whatever the setting says (it has no fine path).
	for setting: String in [auto, on, off]:
		check(not Dish.backend_wants_gpu(setting, Dish.FINE_STEP, 1, 400, 1000000, false, true) and not Dish.backend_wants_gpu(setting, 0.1, 1, 400, 1000000, true, true), "'%s': a fine step (x1) is never the GPU's, even with a million bups" % setting)
	# Fine or coarse is judged on the speed and the usual frame, not one frame's length: a stray short frame at x100 stays coarse, a real x1 is fine at once.
	var usual := Dish.typical_frame(PackedFloat32Array([0.0167, 0.0166, 0.0168, 0.0167, 0.0165]))
	check(is_equal_approx(usual, 0.0167), "the usual frame is the median of the recent ones: %f" % usual)
	check(Dish.rule_step(0.18, 1, 0.0018, usual) > Dish.FINE_STEP, "x100 with one stray 1.8 ms frame (a 0.18 s step) is still a coarse step")
	check(Dish.rule_step(0.0167, 1, 0.0167, usual) <= Dish.FINE_STEP, "x1 is a fine step on the first frame")
	check(Dish.rule_step(1.67, 1, 0.0167, usual) > Dish.FINE_STEP and Dish.rule_step(10.0, 1, 0.1, usual) > Dish.FINE_STEP, "x100 is coarse, in a normal frame and in a hitch (0.1 s)")
	check(Dish.rule_step(0.1, 1, 0.1, usual) <= Dish.FINE_STEP and Dish.rule_step(0.5, 1, 0.1, usual) <= Dish.FINE_STEP, "x1 and x5 stay fine in a hitch frame (0.1 s): the speed decides, not the frame")
	check(Dish.rule_step(0.18, 0, 0.0018, usual) == 0.18 and Dish.rule_step(0.18, 3, 0.0018, usual) == 0.18 and Dish.rule_step(0.18, 1, 0.0, usual) == 0.18, "without the frame's steps or length, the step is taken as given")
	check(not Dish.backend_wants_gpu(off, 18.5, 7, 400, 1000000, true, true), "Off: never")
	check(Dish.backend_wants_gpu(on, 1.67, 1, 100, 4, false, true) and Dish.backend_wants_gpu(on, 16.7, 1, 100, 4, false, true), "On: at x100 and up, whatever the crowd")
	check(not Dish.backend_wants_gpu(on, 1.67, 1, 100, 4, false, false), "On, but no usable GPU: the processor")
	check(not Dish.backend_wants_gpu(auto, 18.5, 7, 400, 999, false, true) and not Dish.backend_wants_gpu(auto, 18.5, 7, 400, 999, true, true), "Auto: under AUTO_MIN_POPULATION bups, the processor, whatever the grid costs")
	# Auto at x10,000 on a 10 mm dish with the usual grid: the processor's nine steps are 6 ms at about 1,900 bups (the bench: 2,000 bups at m=6 took 622 µs a step, m=7 about 680 µs).
	var up := 0
	for n in range(1000, 20001, 100):
		if Dish.backend_wants_gpu(auto, 18.5, 7, 100, n, false, true):
			up = n
			break
	check(up >= 1700 and up <= 2200, "Auto at x10,000 on a 10 mm dish goes to the GPU from about 1,900 bups (the processor's frame passes AUTO_CPU_UP_USEC): %d" % up)
	check(Dish.backend_wants_gpu(auto, 18.5, 7, 100, up - 100, true, true) and not Dish.backend_wants_gpu(auto, 18.5, 7, 100, up - 100, false, true), "...and just below that it keeps the GPU once there (the processor's frame is still above AUTO_CPU_DOWN_USEC), without having gone to it")
	# Hysteresis where one step is a whole frame (x1,000 on a fine grid: 668 + 0.044 n microseconds): between 3 ms and 6 ms, the answer is where it is.
	check(not Dish.backend_wants_gpu(auto, 16.7, 6, 400, 80000, false, true) and Dish.backend_wants_gpu(auto, 16.7, 6, 400, 80000, true, true), "Auto: 80,000 bups at x1,000 on a fine grid is between the thresholds: the processor stays, the GPU stays")
	check(Dish.backend_wants_gpu(auto, 16.7, 6, 400, 130000, false, true) and not Dish.backend_wants_gpu(auto, 16.7, 6, 400, 40000, true, true), "...130,000 sends it to the GPU, 40,000 sends it back")
	# At x1,000 and x100 the processor keeps up with 100,000 bups on every grid: Auto stays on it.
	for fit: Array in [[100, 1], [400, 6]]:  # (cells across, motion sub-steps of a 16.7 s step on that grid)
		check(not Dish.backend_wants_gpu(auto, 1.67, 1, fit[0], 100000, false, true), "Auto at x100, %d cells, 100,000 bups: the processor" % fit[0])
		check(not Dish.backend_wants_gpu(auto, 16.7, fit[1], fit[0], 100000, false, true), "Auto at x1,000, %d cells, 100,000 bups: the processor" % fit[0])
	# Re-evaluated after anything that changes it, by the same call: speed down, a bigger grid, a new setting.
	check(Dish.backend_wants_gpu(auto, 18.5, 7, 100, 5000, false, true), "5,000 bups at x10,000: the GPU")
	check(not Dish.backend_wants_gpu(auto, 1.67, 1, 100, 5000, true, true), "...the speed drops to x100: the processor, at once")
	check(not Dish.backend_wants_gpu(auto, 0.1, 1, 100, 5000, true, true), "...to x1: the processor")
	check(Dish.backend_wants_gpu(auto, 18.5, 7, 400, 5000, false, true), "...a finer grid at x10,000: still the GPU")
	check(not Dish.backend_wants_gpu(off, 18.5, 7, 400, 5000, true, true), "...the setting set to Off: the processor")
	# A frame of several steps shorter than TOP_SPEED_STEP (x10,000 on a 120 Hz screen: 5 steps of 16.7 s): said by the caller, not guessed from the length.
	check(not Dish.backend_wants_gpu(auto, 16.7, 6, 400, 15000, false, true) and Dish.backend_wants_gpu(auto, 16.7, 6, 400, 15000, false, true, 5), "a frame of 5 steps of 16.7 s (x10,000 at 120 Hz) is the GPU's at 15,000 bups on a fine grid, where one such step (x1,000) is not")
	check(Dish.backend_frame_costs(16.7, 400, 6, 15000, 5).x > 4.9 * Dish.backend_frame_costs(16.7, 400, 6, 15000, 1).x, "...the frame's cost goes with the steps it holds")
	# Plankton clouds slow both backends (the processor more): 10,000 of them send 10,000 bups at x10,000 on a coarse grid to the GPU.
	check(not Dish.backend_wants_gpu(auto, 18.5, 1, 100, 10000, false, true, 0, 0) and Dish.backend_wants_gpu(auto, 18.5, 1, 100, 10000, false, true, 0, 10000), "10,000 bups at x10,000 on a 90 mm dish: the processor, until 10,000 clouds are floating")
	# The device's room: a dish whose limit the GPU cannot hold stays on the processor (GpuWorld.most_bups).
	check(Dish.backend_usable(true, 1000000, 5000000) and not Dish.backend_usable(true, 1000000, 700000) and not Dish.backend_usable(false, 10, 1000000000), "the GPU is used only where it exists and holds the limit")
	# The costs the rule goes by rise with the crowd and with the grid, and the GPU's rise slower.
	var small := Dish.backend_frame_costs(18.5, 100, 7, 2000)
	var big := Dish.backend_frame_costs(18.5, 100, 7, 50000)
	var fine_grid := Dish.backend_frame_costs(18.5, 400, 7, 2000)
	check(big.x > small.x and big.y > small.y and fine_grid.x > small.x and fine_grid.y > small.y, "both backends cost more with more bups and with a finer grid")
	check((big.x - small.x) > 3.0 * (big.y - small.y), "...the processor's cost rises faster with the crowd")
	# Without a GPU nothing is ever loaded, and the frames of coarse steps are counted (a fine step starts the count again).
	var w := _make_dish()
	w.strike(chosen)
	for i in 29:
		w._choose_backend(1.67)
	check(w._coarse_frames == 29 and not w.gpu_active, "29 coarse frames are counted, and the processor still runs (the GPU takes over at %d)" % Dish.COARSE_FRAMES_TO_GPU)
	w._choose_backend(0.1)
	check(w._coarse_frames == 0, "a fine step starts the count again")
	w.set_backend_setting("garbage")
	check(w.backend_setting == auto, "a setting that is not one of the three is Auto, for the dish too")
