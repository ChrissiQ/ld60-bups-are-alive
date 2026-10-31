extends SceneTree
## Run: godot --headless --path . -s tests/bup_gauges_test.gd
## Checks the two bars of a bup's panel (BupGauges, GaugeBar) from the figures they are given: the lengths, ticks and marks (derived below from the figures), the tone that says how
## the bup stands, and the grey of a dead bup. The bars read only an info dictionary, so no simulation is involved.
## Constants the expectations come from: Cell.MAINTENANCE_FLOOR = 5, food-limited at or below 1.25 x the floor (6.25), starving below 0.5 x the floor (2.5),
## Biology.STARVE_MIN_MASS_SHARE = 0.25.


func _info(mass: float, energy: float) -> Dictionary:
	return {"mass": mass, "birth_mass": 4.0, "div_mass": 8.0, "energy": energy, "max_energy": 40.0}


func _initialize() -> void:
	var g := BupGauges.new()
	root.add_child(g)
	await process_frame
	var mass_bar: GaugeBar = g._mass_bar
	var reserve_bar: GaugeBar = g._reserve_bar

	# A healthy bup, mass 6 of 8 (born at 4), reserve 20 of 40. Derived: mass fill 6/8 = 0.75, birth tick 4/8 = 0.5; reserve fill 20/40 = 0.5, floor tick and band 5/40 = 0.125.
	g.show_bup(_info(6.0, 20.0), false, true)
	TestUtil.check(mass_bar.kind == GaugeBar.Kind.MASS and is_equal_approx(mass_bar.fraction, 0.75) and mass_bar.ticks.size() == 1 and is_equal_approx(mass_bar.ticks[0], 0.5), "the mass bar is the body's length, with a tick at the birth mass (%.3f, %s)" % [mass_bar.fraction, mass_bar.ticks])
	TestUtil.check(mass_bar.mark < 0.0 and mass_bar.tone == GaugeBar.Tone.NORMAL, "no death mark without starvation, and the normal tone")
	TestUtil.check(g._mass_value.text == "6.0", "the mass bar's number is the mass, one decimal ('%s')" % g._mass_value.text)
	TestUtil.check(reserve_bar.kind == GaugeBar.Kind.RESERVE and is_equal_approx(reserve_bar.fraction, 0.5) and is_equal_approx(reserve_bar.band, 0.125) and is_equal_approx(reserve_bar.ticks[0], 0.125), "the reserve bar's track is what the body can hold, with the floor as tick and band (%.3f, %.3f)" % [reserve_bar.fraction, reserve_bar.band])
	TestUtil.check(reserve_bar.tone == GaugeBar.Tone.NORMAL and g._reserve_value.text == "20" and g._reserve_state.text == "", "a well-fed bup: green, its number, no word ('%s')" % g._reserve_state.text)

	# The fill never leaves the track: mass 20 of 8 is a full bar.
	g.show_bup(_info(20.0, 400.0), false, true)
	TestUtil.check(mass_bar.fraction == 1.0 and reserve_bar.fraction == 1.0, "a fill is clamped to its track")

	# Food-limited: derived, 6 <= 6.25 and not starving (6 >= 2.5).
	g.show_bup(_info(6.0, 6.0), false, true)
	TestUtil.check(reserve_bar.tone == GaugeBar.Tone.LIMITED and g._reserve_state.text == Strings.t("gauges.food_limited") and g._reserve_state.theme_type_variation == &"StatLimited" and mass_bar.tone == GaugeBar.Tone.NORMAL, "a reserve at the floor is amber and says food-limited; the mass bar stays normal")

	# Just above the band: 7 > 6.25 is green.
	g.show_bup(_info(6.0, 7.0), false, true)
	TestUtil.check(reserve_bar.tone == GaugeBar.Tone.NORMAL and g._reserve_state.text == "", "above 1.25 x the floor the reserve is green")

	# Starving by reserve with no starvation option: derived, 2 < 2.5.
	g.show_bup(_info(6.0, 2.0), false, true)
	TestUtil.check(reserve_bar.tone == GaugeBar.Tone.STARVING and mass_bar.tone == GaugeBar.Tone.STARVING and g._reserve_state.text == Strings.t("gauges.starving") and g._reserve_state.theme_type_variation == &"StatStarving" and mass_bar.mark < 0.0, "far below the floor is red and says starving, with no death mark on the mass bar")

	# Starvation on and mass below the birth mass: starving; the red tick is at 0.25 x 4 / 8 = 0.125.
	g.show_bup(_info(3.0, 20.0), true, true)
	TestUtil.check(mass_bar.tone == GaugeBar.Tone.STARVING and reserve_bar.tone == GaugeBar.Tone.STARVING and is_equal_approx(mass_bar.mark, 0.125) and is_equal_approx(mass_bar.fraction, 0.375), "with starvation on, a bup below its birth mass is starving and the mass bar has its red tick at 0.125 (mark %.3f)" % mass_bar.mark)
	g.show_bup(_info(6.0, 20.0), true, true)
	TestUtil.check(mass_bar.tone == GaugeBar.Tone.NORMAL and is_equal_approx(mass_bar.mark, 0.125), "...and a bup at or above its birth mass is not, though the tick stays")

	# A dead bup: grey, no word, the figures as they were (reserve 2 would be starving if it were alive).
	g.show_bup(_info(3.0, 2.0), true, false)
	TestUtil.check(mass_bar.tone == GaugeBar.Tone.DEAD and reserve_bar.tone == GaugeBar.Tone.DEAD and g._reserve_state.text == "" and g._mass_value.text == "3.0" and g._reserve_value.text == "2", "a dead bup's bars are grey, with the numbers it died with")

	g.free()
	TestUtil.finish(self, "BUP GAUGES TESTS OK")
