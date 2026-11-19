extends SceneTree
## A dish's medium is its own: what shares the pool, or was in it, does not change how a dish's nutrient and clouds spread.
##
## Expected values:
## - dish W (medium 1, water: the nutrient diffuses fastest; plankton bloom on, every flag on, seed 11,
##   40 founders, radius 600 µm) run alone, and the same dish (a) in a pool where a dish of a thick medium (`Biology.MEDIUM_THICKNESS`) was added
##   and removed before it, (b) beside a thick-medium dish added before it: after every 20 steps of 20 s (100 steps in all) the canonical
##   dumps differ nowhere (diff == "") [derived: a dish's cloud spread and diffusion k come from its own DISHP row].
## - the other way round: a thick-medium dish beside a water dish matches the same dish alone [derived, as above].
## - the test can tell the media apart: the water dish and the thick dish run alone differ (diff != "") [derived: another
##   diffusion cannot give the same field].
## Windowed only.

const STEPS := 100
const CHECK_EVERY := 20


static func _water() -> Scenario:
	var s := Scenario.small(40, 600.0).seed(11).with_all_flags()
	s.number = 1
	s.medium_thickness = 1.0
	s.bloom_density = 2.0
	return s


static func _thick() -> Scenario:
	var s := Scenario.small(30, 500.0).seed(23).with_all_flags()
	s.number = 2
	s.medium_thickness = Biology.MEDIUM_THICKNESS
	s.bloom_density = 2.0
	return s


## The dumps of `row` of `pool` after each CHECK_EVERY steps.
static func _run(pool: SimHarness, row: int) -> Array:
	var dumps: Array = []
	for k in STEPS / CHECK_EVERY:
		pool.step(CHECK_EVERY)
		dumps.append(pool.dump(row))
	return dumps


func _compare(what: String, lone: Array, other: Array) -> void:
	for k in lone.size():
		var line := SimHarness.diff(lone[k], other[k])
		TestUtil.show(line == "", "%s after %d steps: %s" % [what, (k + 1) * CHECK_EVERY, line if line != "" else "same"])
		if line != "":
			break


func _init() -> void:
	if not SimHarness.begin(self, "medium_isolation_test", "the pooled core (SimCore)"):
		return
	var lone_water := _run(SimHarness.make([_water()]), 0)
	var lone_thick := _run(SimHarness.make([_thick()]), 0)
	TestUtil.show(SimHarness.diff(lone_water.back(), lone_thick.back()) != "", "the two media are not the same run (water alone differs from the thick alone)")

	# (a) a thick-medium dish was in the pool first and has gone
	var a := SimHarness.make([_thick()])
	a.remove(0)
	var row_a := a.add(_water())
	_compare("water dish after a thick dish was added and removed", lone_water, _run(a, row_a))

	# (b) beside a thick-medium dish added first
	var b := SimHarness.make([_thick(), _water()])
	_compare("water dish beside a thick dish added first", lone_water, _run(b, 1))
	TestUtil.show(b.invariants().is_empty(), "invariants hold (water beside thick) %s" % ", ".join(b.invariants()))

	# (c) the thick dish beside a water dish added first
	var c := SimHarness.make([_water(), _thick()])
	_compare("thick dish beside a water dish added first", lone_thick, _run(c, 1))

	TestUtil.finish(self, "OK medium_isolation_test")
