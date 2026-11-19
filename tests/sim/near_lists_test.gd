extends SceneTree
## The cloud lookup lists hold only the squares near bups, and a bup that reads a square that is not listed gets the same clouds from the
## cloud slots: the dishes after a run are byte for byte the same whatever is listed.
##
## Expected:
## - four runs of the same three dishes (radius 8 mm with two sources; radius 2 mm with conjugation, acetate and the acetate key; radius 20 mm
##   with three sources; 20 s steps, 600 steps) differ only in what is listed: every square of every dish
##   (`list_margin_override` 1e8), only the square of each bup (0), and the squares a bup can swim to in a step (the default, -1), and with no marks at all (-2: every square listed and the reads that have no code for an unlisted one). A read of
##   an unlisted square scans the cloud slots in index order with the same test and the same values as an entry has, so it sums what the
##   list would have, in the same order [derived]: the dumps of every row (records, field, clouds, husks, births, deaths, stats) are equal
##   in the four runs. A bup whose read took a different value would change its steering or its intake and with it every later step.
## - the probes (the field and the steering at 48 points over each dish, most of them far from every bup, so on unlisted squares) are in the
##   compared sums and equal in the four runs [derived: they read through the same fallback].
## - with every square listed no bup finds its square unlisted: WD_FALLBACKS stays 0 [derived]. With only the bups' own squares, a bup that
##   swam into the next square finds it unlisted: the count is above 0 (a swimming bup crosses a square of about 80 to 450 um in a few steps;
##   the three dishes hold hundreds of bups) [derived]; the figure is printed.
## - with the default margin the count is reported and need not be 0: the margin is the drift of a step plus four spreads of it at the
##   fastest speed a gene can reach, so a bup finds its square listed at any speed the genes allow [derived]; it is 0 when no bup was made
##   or moved further than that in a step.
## Windowed only.

const STEPS := 600


func _scenarios() -> Array:
	var a := Scenario.small(200, 8000.0)
	a.nutrient_density = 32.0
	a.bloom_density = 1.0
	a.with_flags({"stationary": true, "death_husks": true, "plankton_husks": true})
	a.sources = [[Vector2(1000, 500), 4.0], [Vector2(-3000, 2000), 2.0]]
	var b := Scenario.small(100, 2000.0)
	b.nutrient_density = 32.0
	b.bloom_density = 0.5
	b.seed_value = 2
	b.with_flags({"resolution": 200, "conjugation": true, "acetate": true, "key": true})
	var c := Scenario.small(300, 20000.0)
	c.nutrient_density = 32.0
	c.bloom_density = 1.0
	c.seed_value = 3
	c.with_flags({"plankton_husks": true, "stationary": true})
	c.sources = [[Vector2(5000, 5000), 3.0], [Vector2(-9000, 2000), 6.0], [Vector2(0, -12000), 1.0]]
	return [a, b, c]


## The md5 of every section of every row after STEPS steps with `margin` as the override, and the fallbacks counted.
func _run(margin: float) -> Dictionary:
	var h := SimHarness.make(_scenarios(), {"delta": 20.0})
	h.core.list_margin_override = margin
	h.step(STEPS, 20.0)
	var sums := {}
	for row in h.scenarios:
		var d: Dictionary = h.dump(row)
		for k in d:
			var v = d[k]
			var bytes: PackedByteArray = v if v is PackedByteArray else var_to_bytes(v)
			sums["%d %s" % [row, k]] = bytes.hex_encode().md5_text()
	# the field and the steering at points over each dish, on the lists of the last step (most of the points are far from every bup)
	for row in h.scenarios:
		var pts := PackedFloat32Array()
		var r: float = (h.scenarios[row] as Scenario).radius
		for i in 48:
			var t := float(i) * 0.6180339887 * TAU
			var rr := r * 0.9 * sqrt(float(i) / 48.0)
			pts.append_array(PackedFloat32Array([cos(t) * rr, sin(t) * rr, 30.0, 40.0]))
		sums["%d probe" % row] = h.core.probe(row, pts).to_byte_array().hex_encode().md5_text()
	h.core._read_back()
	var out := {"sums": sums, "misses": h.core._wd(GpuLayout.WD_FALLBACKS)}
	h.core.release()
	return out


func _same(a: Dictionary, b: Dictionary) -> int:
	var off := 0
	for k in a:
		if a[k] != b.get(k, ""):
			off += 1
			print("  differs: ", k)
	return off


func _init() -> void:
	if not SimHarness.begin(self, "near_lists_test", "the pooled core (SimCore)"):
		return
	SimConstants.apply()
	var every := _run(1e8)
	var own := _run(0.0)
	var rule := _run(-1.0)
	var all := _run(-2.0)
	var n: int = (every["sums"] as Dictionary).size()
	TestUtil.show(every["misses"] == 0, "with every square listed no bup reads an unlisted one (%d)" % every["misses"])
	TestUtil.show(own["misses"] > 0, "with only the bups' own squares listed, bups read unlisted ones (%d, so the scan of the cloud slots ran)" % own["misses"])
	print("default margin: %d bups read an unlisted square" % rule["misses"])
	var off_own := _same(every["sums"], own["sums"])
	var off_rule := _same(every["sums"], rule["sums"])
	TestUtil.show(off_own == 0, "own squares only: all %d sections equal to every-square-listed (%d differ)" % [n, off_own])
	TestUtil.show(off_rule == 0, "the default margin: all %d sections equal to every-square-listed (%d differ)" % [n, off_rule])
	var off_all := _same(every["sums"], all["sums"])
	TestUtil.show(off_all == 0, "no marks (every square listed, the reads without the unlisted-square code): all %d sections equal (%d differ)" % [n, off_all])
	TestUtil.show(all["misses"] == 0, "no marks: no bup reads an unlisted square (%d)" % all["misses"])
	TestUtil.finish(self, "OK near_lists_test")
