extends SceneTree
## Run: godot --headless --path . -s tests/genome_ribbon_test.gd
## Checks the genome map (GenomeRibbon, GenomeSlot) from a bup's info: the loci in the order of Genome.LOCI, each band in its allele's shade with its value beside it, the empty bands of a
## bup without the F factor or the acetate key, raised ceilings, mutator alleles, the hover names and the click. The map reads only an info dictionary, so no simulation is involved.


func _info() -> Dictionary:
	return {"speed": 20.0, "sense": 50.0, "metabolism": 1.0, "size_gene": 4.0, "mutator": 1.0, "donor": false, "reach": 0}


func _initialize() -> void:
	var ribbon := GenomeRibbon.new()
	root.add_child(ribbon)
	await process_frame
	var slots: Dictionary = ribbon._slots
	var values: Dictionary = ribbon._values

	# Derived: seven loci, a band and a value label each, in Genome.LOCI's order (the donor's F factor first, the acetate key last).
	TestUtil.check(Genome.LOCI == ["donor", "speed", "sense", "metabolism", "size", "mutator", "key"], "the loci are in the order a donor transfers them")
	TestUtil.check(ribbon.get_child_count() == 14 and ribbon.columns == 2, "a band and a value for each of the seven loci")
	var order_ok := true
	for i in Genome.LOCI.size():
		order_ok = order_ok and ribbon.get_child(2 * i) == slots[Genome.LOCI[i]] and ribbon.get_child(2 * i + 1) == values[Genome.LOCI[i]]
	TestUtil.check(order_ok, "the bands run down the bar in that order")
	TestUtil.check((slots["donor"] as GenomeSlot).top and not (slots["donor"] as GenomeSlot).bottom and (slots["key"] as GenomeSlot).bottom and not (slots["speed"] as GenomeSlot).top, "the first band and the last round off the chromosome")
	TestUtil.check((slots["speed"] as GenomeSlot).symbol == Strings.t("genome.symbol_speed") and (slots["key"] as GenomeSlot).symbol == "acs", "each band carries its gene's symbol")

	# The founder: no F factor, no key; the rest are there. Values formatted with the gene's decimals (speed 0, sense 0, metabolism up to 2, size 1; String.num drops a trailing zero, so 1.0 and not 1.00), the mutator as a fold.
	ribbon.show_bup(_info())
	TestUtil.check(not (slots["donor"] as GenomeSlot).present and not (slots["key"] as GenomeSlot).present, "a bup without the F factor or the key has empty bands there")
	var expect := {"donor": "no", "speed": "20", "sense": "50", "metabolism": "1.0", "size": "4.0", "mutator": "x1.0", "key": "no"}
	for locus: String in expect:
		TestUtil.check((values[locus] as Label).text == expect[locus], "%s reads '%s' (got '%s')" % [locus, expect[locus], (values[locus] as Label).text])
	for locus in ["speed", "sense", "metabolism", "size", "mutator"]:
		TestUtil.check((slots[locus] as GenomeSlot).present, "%s band is there" % locus)

	# The shade is where the allele sits in the gene's range: the bottom of the range is 0, the top 1 (derived from the definition).
	var spec: Array = Genome.GENES["speed"]
	var low := _info()
	low["speed"] = spec[0]
	ribbon.show_bup(low)
	var dim: float = (slots["speed"] as GenomeSlot).shade
	var high := _info()
	high["speed"] = spec[1]
	ribbon.show_bup(high)
	TestUtil.check(is_zero_approx(dim) and is_equal_approx((slots["speed"] as GenomeSlot).shade, 1.0), "a band is dim at the bottom of its gene's range and bright at the top (%.2f, %.2f)" % [dim, (slots["speed"] as GenomeSlot).shade])

	# A donor: the band is there, fully bright, and reads yes.
	var donor := _info()
	donor["donor"] = true
	ribbon.show_bup(donor)
	TestUtil.check((slots["donor"] as GenomeSlot).present and is_equal_approx((slots["donor"] as GenomeSlot).shade, 1.0) and (values["donor"] as Label).text == "yes", "a donor has its F factor band, bright")

	# The key's levels are in bits 8-9 of the reach word: 1 primed (half shade), 2 the key (full shade).
	var primed := _info()
	primed["reach"] = 1 << 8
	ribbon.show_bup(primed)
	TestUtil.check((slots["key"] as GenomeSlot).present and is_equal_approx((slots["key"] as GenomeSlot).shade, 0.5) and (values["key"] as Label).text == "primed", "a primed line has a half-bright key band")
	var keyed := _info()
	keyed["reach"] = 2 << 8
	ribbon.show_bup(keyed)
	TestUtil.check(is_equal_approx((slots["key"] as GenomeSlot).shade, 1.0) and (values["key"] as Label).text == "yes", "the key is a full band")

	# Raised ceilings are two bits a gene, speed lowest, metabolism third: speed raised twice, metabolism three times.
	var raised := _info()
	raised["reach"] = 2 | (3 << 4)
	ribbon.show_bup(raised)
	TestUtil.check((values["speed"] as Label).text == "20 +2" and (values["metabolism"] as Label).text == "1.0 +3" and (values["sense"] as Label).text == "50", "a raised ceiling is shown beside the value ('%s', '%s')" % [(values["speed"] as Label).text, (values["metabolism"] as Label).text])

	# Mutators: a fold of 10 is the mutY-like allele and is named; 100 is mutS/L-like; 12 is nearest to 10 on the log scale; 1 has no name.
	for case in [[10.0, "x10  " + Strings.t("genes.allele_muty")], [100.0, "x100  " + Strings.t("genes.allele_muts")], [12.0, "x12  " + Strings.t("genes.allele_muty")], [1.0, "x1.0"]]:
		var mut := _info()
		mut["mutator"] = case[0]
		ribbon.show_bup(mut)
		TestUtil.check((values["mutator"] as Label).text == case[1], "a mutator of fold %s reads '%s' (got '%s')" % [case[0], case[1], (values["mutator"] as Label).text])
	TestUtil.check(is_equal_approx((slots["mutator"] as GenomeSlot).shade, Genome.allele_fraction("mutator", 1.0)) and (slots["mutator"] as GenomeSlot).shade >= 0.0, "the mutator's shade is on the log scale")

	# Tips: the hover name and the click only when asked (the card that follows the pointer has neither).
	ribbon.show_bup(_info(), true)
	var speed_slot: GenomeSlot = slots["speed"]
	TestUtil.check(speed_slot.tooltip_text == Strings.t("genome.name_speed") and speed_slot.mouse_filter == Control.MOUSE_FILTER_STOP, "with tips a band has its name and takes the click")
	ribbon.show_bup(_info(), false)
	TestUtil.check(speed_slot.tooltip_text == "" and speed_slot.mouse_filter == Control.MOUSE_FILTER_IGNORE, "without tips it has neither")

	var asked := []
	ribbon.entry_requested.connect(func(id: String) -> void: asked.append(id))
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	speed_slot._gui_input(click)
	TestUtil.check(asked == [Encyclopedia.entry_for_locus("speed")], "a click on a band asks for its gene's entry (%s)" % [asked])

	ribbon.free()
	TestUtil.finish(self, "GENOME RIBBON TESTS OK")
