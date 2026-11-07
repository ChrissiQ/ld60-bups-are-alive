extends SceneTree
## The harness's own checks: they run headless (no GPU, no SimCore needed) and print OK.
##
## Expected values, written before the first run (derived unless marked):
## - `diff` of a dump with itself is ""; with one word of record 3 changed to R_ENERGY's place it is a line naming "record 3" and
##   "R_ENERGY"; with DS_MOVED_IN changed it names "DS_MOVED_IN"; with the picture words (R_PX, R_PY) changed and nothing else it is "".
## - a dump whose records are longer than the other's says "length".
## - `Scenario.small(10, 500)`: 10 records of RECORD_BYTES, ids 1..10, every bup inside 0.9 x 500 µm, genes the founder's
##   (speed 20, sense 50, metabolism 1, size 4), birth mass = Cell.mass_to_add(founder) = 0.5 x 4 x 4 = 8, mass = birth mass x (1 + u), u in [0, 1) (the game's random phase: 8 to 16, below the division mass 16), reserve Dish.FOUNDER_ENERGY but no more than the body holds (Cell.RESERVE_PER_MASS x mass), no donors.
## - `with_flags({"conjugation": true})`: records 0, 5 are donors (R_DONOR 1.0), 1 is not; `{"key": true}`: record 2 has reach 2<<8.
## - `dish_flags` sets exactly the DPF bits of the flags given (stationary -> bit DPF_STATIONARY...).
## - two scenarios with the same layout_seed and different seeds have identical positions; with different layout seeds, not.
## - `Scenario.goal()` holds StartConditions.new()'s radius and limit; an unknown flag name is refused (the assert is not run here,
##   so only the known names are checked against FLAG_NAMES).
## - every tests/sim/*_test.gd loads as a script (parses).

func _init() -> void:
	_diff_checks()
	_scenario_checks()
	_every_test_parses()
	TestUtil.finish(self, "OK harness_test: diff names words, scenarios build, every sim test parses")


func _dump_of(scenario: Scenario) -> Dictionary:
	return CanonicalDump.make({"records": scenario.founder_records(1), "dstate": PackedByteArray(), "stats": PackedByteArray()})


func _diff_checks() -> void:
	var s := Scenario.small(10, 500.0)
	var a := _dump_of(s)
	TestUtil.check(SimHarness.diff(a, _dump_of(s)) == "", "a dump has no difference from itself")
	var b := _dump_of(s)
	b["records"].encode_float(3 * GpuLayout.RECORD_BYTES + GpuLayout.R_ENERGY * 4, 49.0)
	var line := SimHarness.diff(a, b)
	TestUtil.check("record 3" in line and "R_ENERGY" in line, "diff names record 3 and R_ENERGY: '%s'" % line)
	var c := _dump_of(s)
	c["records"].encode_float(GpuLayout.R_PX * 4, 12.0)
	c["records"].encode_float(9 * GpuLayout.RECORD_BYTES + GpuLayout.R_PY * 4, 12.0)
	c["records"] = CanonicalDump.mask_pictures(c["records"])
	TestUtil.check(SimHarness.diff(a, c) == "", "R_PX and R_PY are masked")
	var d1 := CanonicalDump.make({"dstate": _words(GpuLayout.DS_WORDS)})
	var d2 := CanonicalDump.make({"dstate": _words(GpuLayout.DS_WORDS)})
	d2["dstate"].encode_u32(GpuLayout.DS_MOVED_IN * 4, 5)
	TestUtil.check("DS_MOVED_IN" in SimHarness.diff(d1, d2), "diff names DS_MOVED_IN: '%s'" % SimHarness.diff(d1, d2))
	var e := _dump_of(s)
	e["records"] = e["records"].slice(0, GpuLayout.RECORD_BYTES * 9)
	TestUtil.check("length" in SimHarness.diff(a, e), "a shorter record list is a length difference: '%s'" % SimHarness.diff(a, e))
	var f := _dump_of(s)
	f["records"].encode_u32(7 * GpuLayout.RECORD_BYTES + GpuLayout.R_ID_LO * 4, 99)
	TestUtil.check("record 7" in SimHarness.diff(a, f), "diff finds a word late in a long list")


func _words(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n * 4)
	return out


func _scenario_checks() -> void:
	var s := Scenario.small(10, 500.0)
	var r := s.founder_records(1)
	TestUtil.check(r.size() == 10 * GpuLayout.RECORD_BYTES, "10 founders make 10 records")
	var rim_ok := true
	for i in 10:
		TestUtil.check(GpuLayout.id_of(r, i) == (i + 1), "founder %d's id" % i)
		var o := i * GpuLayout.RECORD_BYTES
		var at := Vector2(r.decode_float(o + GpuLayout.R_X * 4), r.decode_float(o + GpuLayout.R_Y * 4))
		rim_ok = rim_ok and at.length() <= 0.9 * 500.0 + 0.01
		TestUtil.check(r.decode_float(o + GpuLayout.R_SPEED * 4) == 20.0 and r.decode_float(o + GpuLayout.R_SENSE * 4) == 50.0, "founder %d's genes" % i)
		var m := r.decode_float(o + GpuLayout.R_MASS * 4)
		TestUtil.check(m >= 8.0 and m < 16.0 and is_equal_approx(r.decode_float(o + GpuLayout.R_BIRTH_MASS * 4), 8.0), "founder %d's mass" % i)
		TestUtil.check(r.decode_float(o + GpuLayout.R_ENERGY * 4) == minf(Dish.FOUNDER_ENERGY, Cell.RESERVE_PER_MASS * r.decode_float(o + GpuLayout.R_MASS * 4)), "founder %d's reserve" % i)
		TestUtil.check(r.decode_float(o + GpuLayout.R_DONOR * 4) == 0.0, "founder %d is no donor" % i)
	TestUtil.check(rim_ok, "founders lie inside 0.9 of the radius")
	var conj := Scenario.small(10, 500.0).with_flags({"conjugation": true, "key": true}).founder_records(1)
	TestUtil.check(conj.decode_float(0 * GpuLayout.RECORD_BYTES + GpuLayout.R_DONOR * 4) == 1.0, "record 0 is a donor")
	TestUtil.check(conj.decode_float(1 * GpuLayout.RECORD_BYTES + GpuLayout.R_DONOR * 4) == 0.0, "record 1 is not")
	TestUtil.check(conj.decode_float(5 * GpuLayout.RECORD_BYTES + GpuLayout.R_DONOR * 4) == 1.0, "record 5 is a donor")
	TestUtil.check(conj.decode_float(2 * GpuLayout.RECORD_BYTES + GpuLayout.R_REACH * 4) == float(2 << 8), "record 2 has the key")
	var flagged := Scenario.small(5, 300.0).with_flags({"stationary": true, "acetate": true})
	TestUtil.check(flagged.dish_flags() == ((1 << GpuLayout.DPF_STATIONARY) | (1 << GpuLayout.DPF_ACETATE)), "dish_flags: stationary and acetate only")
	var p := Scenario.small(10, 500.0)
	p.layout_seed = 5
	var q := Scenario.small(10, 500.0).seed(99)
	q.layout_seed = 5
	TestUtil.check(p.founder_records(1) == q.founder_records(1), "the same layout seed gives the same positions")
	q.layout_seed = 6
	TestUtil.check(p.founder_records(1) != q.founder_records(1), "another layout seed gives other positions")
	var g := Scenario.goal()
	var start := StartConditions.new()
	TestUtil.check(g.radius == start.dish_radius and g.limit == start.bup_limit, "goal() holds the goal dish's values")
	TestUtil.check(Scenario.big(1000).copy().bups == 1000, "copy keeps the bups")
	TestUtil.check(Scenario.FLAG_NAMES.size() == 6, "six flags")


func _every_test_parses() -> void:
	for f in DirAccess.get_files_at("res://tests/sim"):
		if f.ends_with(".gd"):
			var script := load("res://tests/sim/" + f)
			TestUtil.check(script is GDScript and (script as GDScript).can_instantiate(), "%s loads and parses" % f)
