extends SceneTree
## The cloud lists' count and scatter agree on every square: the scatter tries to enter exactly as many clouds in a square as the count
## counted for it.
##
## Expected:
## - the count and the scatter take a cloud's squares from the same value (the square root of the reach word the count stored) and run the
##   same arithmetic on it, so in every square of the dish the entries the scatter attempted (the cursor's advance, BCUR - BINS) equal the
##   count (BINC) [derived]. With no bin cut (DS_ENTRIES_CUT 0) and no overflow the count is not changed between the two, so this holds for
##   every square of every step; a square where they differ leaves which cloud a full square drops to the order the threads ran in.
## - the dish is the one a long game reaches (90 mm radius, limit 2,000,000, 4 founders, nutrient 32, bloom 1.0, stationary phase, death husks
##   and plankton husks, 20 s steps), run to step 3,600 and then checked after each of steps 3,600 to 3,800 (about 150,000 to 200,000 bups,
##   40,401 squares, 0.87 to 0.89 million entries a step) [measured]. With a count that takes its squares from the reach before it is squared, 16 squares in
##   4 of those 201 steps differ (12 with more attempts than counted, 4 with fewer; steps 3,634, 3,748, 3,758 and 3,769) [measured],
##   so the window holds boundary cases.
## Windowed only.

const FROM := 3600
const TO := 3800


func _init() -> void:
	if not SimHarness.begin(self, "list_agreement_test", "the pooled core (SimCore)"):
		return
	SimConstants.apply()
	var s := Scenario.new()
	s.radius = 90000.0
	s.limit = 2000000
	s.bups = 4
	s.nutrient_density = 32.0
	s.bloom_density = 1.0
	s.with_flags({"stationary": true, "death_husks": true, "plankton_husks": true})
	var h := SimHarness.make([s], {"delta": 20.0})
	var row: int = h.scenarios.keys()[0]
	var core = h.core
	var done := 0
	while done < FROM - 1:
		var chunk := mini(FROM - 1 - done, 20)
		h.step(chunk, 20.0)
		done += chunk
	var checked := 0
	var squares_off := 0
	var steps_off := 0
	var cut := 0
	var overflow := 0
	while done < TO:
		h.step(1, 20.0)
		done += 1
		var cd = core._dishes[row]
		var base: int = cd.bin_base
		var n: int = cd.bins_across * cd.bins_across
		var got: Array = core.read_parts([["BINS", base * 4, n * 4], ["BINC", base * 4, n * 4], ["BCUR", base * 4, n * 4]])
		var off := 0
		for b in n:
			var attempts: int = (got[2] as PackedByteArray).decode_u32(b * 4) - (got[0] as PackedByteArray).decode_u32(b * 4)
			var counted: int = (got[1] as PackedByteArray).decode_u32(b * 4)
			checked += counted
			if attempts != counted:
				off += 1
		squares_off += off
		steps_off += 1 if off > 0 else 0
		cut += core._ds(row, GpuLayout.DS_ENTRIES_CUT)
		overflow += int(core.overflow())
	TestUtil.show(overflow == 0, "no overflow in steps %d to %d" % [FROM, TO])
	TestUtil.show(cut == 0, "no bin was cut (%d entries)" % cut)
	TestUtil.show(squares_off == 0, "the scatter's attempts equal the count in every square (%d entries checked; %d squares in %d steps differ)" % [checked, squares_off, steps_off])
	core.release()
	TestUtil.finish(self, "OK list_agreement_test")
