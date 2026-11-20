extends SceneTree
## Run: godot --headless --path . -s tests/motion_table_test.gd
## The motion of fast playback (long steps, the coarse model) is read from a table measured from the real run-and-tumble
## swimming (scripts/motion_table.gd, made by tools/gen_motion_table.gd). This keeps the two from drifting apart:
##   1. every constant handed to the simulation is classed as a motion input or not, so a new one gets a decision;
##   2. the table carries hashes of what it was measured from (the constants, and the text of the swimming kernel,
##      GpuKernelsField.K_SWIM) and they must match what is there now; a kernel whose text cannot be found never matches;
##   3. the table has the shape the lookup counts on.
## What a hash cannot catch (a change in how the model works that the kernel's text does not show) is checked on the GPU by
## tests/sim/motion_test.gd, which runs the coarse model against the real one and checks the generator's calibration factor.
## A failure of 2 is fixed by running tools/gen_motion_table.gd (windowed, see its header) and committing the new table.

const Gen := preload("res://tools/gen_motion_table.gd")
const REGENERATE := "stale: run tools/gen_motion_table.gd (windowed: see its header)"
const RISING_S_MAX := 0.3  ## up to here the drift never falls with s; past it, at low eps, it declines from its peak (a measurement)
const MAX_DECLINE := 0.01  ## the most a row may fall below the one before, as a share of speed


func _init() -> void:
	_check_constants_are_classed()
	_check_table_is_current()
	_check_table_shape()
	_check_weak_gradient_fit()
	TestUtil.finish(self, "MOTION TABLE TESTS OK")


# ---- 1 and 2: what the table was measured from ----------------------------------------------------------

func _check_constants_are_classed() -> void:
	var built := SimConstants.build()
	var unclassed := []
	for key: String in built:
		var motion: bool = key in SimConstants.MOTION_INPUTS
		var other: bool = key in SimConstants.OTHER_CONSTANTS
		if motion == other:
			unclassed.append(key)
	TestUtil.check(unclassed.is_empty(), "every constant handed to the simulation is in exactly one of SimConstants.MOTION_INPUTS and OTHER_CONSTANTS (decide whether the real swimming reads it): %s" % [unclassed])
	var unknown := []
	for key: String in SimConstants.MOTION_INPUTS + SimConstants.OTHER_CONSTANTS:
		if not built.has(key):
			unknown.append(key)
	TestUtil.check(unknown.is_empty(), "the lists in SimConstants name only constants that exist: %s" % [unknown])


func _check_table_is_current() -> void:
	TestUtil.check(MotionFingerprint.constants_current(), "the motion table was measured from the constants of the swimming as they are now (%s)" % REGENERATE)
	TestUtil.check(MotionFingerprint.code_hash() != "", "the swimming kernel's text can be read (GpuKernelsField.K_SWIM is not empty)")
	TestUtil.check(MotionFingerprint.code_hash("") == "" and not MotionFingerprint.code_current(""), "a swimming kernel that is not there never matches the table")
	TestUtil.check(MotionFingerprint.code_hash("// a comment\nx") == MotionFingerprint.code_hash("x") and MotionFingerprint.code_hash("x") != MotionFingerprint.code_hash("y"), "the kernel's hash ignores comments and spacing and sees code")
	TestUtil.check(MotionFingerprint.code_current(), "the motion table was measured from the swimming kernel as it is now (%s)" % REGENERATE)


func _check_table_shape() -> void:
	var ns: int = MotionTable.S_AXIS.size()
	var ne: int = MotionTable.E_AXIS.size()
	TestUtil.check(ns >= 8 and ne >= 8 and MotionTable.DRIFT.size() == ns * ne and MotionTable.D_ALONG.size() == ns * ne and MotionTable.D_ACROSS.size() == ns * ne and MotionTable.D_FLAT.size() == ne, "the table's arrays agree in size (%d x %d)" % [ns, ne])
	if MotionTable.DRIFT.size() != ns * ne:
		return
	for axis: Array in [MotionTable.S_AXIS, MotionTable.E_AXIS]:
		var step: float = log(axis[1] / axis[0])
		var even := true
		for i in range(1, axis.size()):
			even = even and absf(log(axis[i] / axis[i - 1]) - step) < 0.01 * step
		TestUtil.check(even and step > 0.0, "an axis of the table is even in its logarithm (the kernel's lookup counts on it)")
	var rising := true
	var declining := true
	var bounded := true
	for i in ns:
		for j in ne:
			var k := i * ne + j
			rising = rising and (i == 0 or MotionTable.S_AXIS[i] > RISING_S_MAX or MotionTable.DRIFT[k] >= MotionTable.DRIFT[k - ne] - 1e-9)
			declining = declining and (i == 0 or MotionTable.DRIFT[k - ne] - MotionTable.DRIFT[k] <= MAX_DECLINE)
			bounded = bounded and MotionTable.DRIFT[k] >= 0.0 and MotionTable.DRIFT[k] < 0.3 and MotionTable.D_ALONG[k] > 0.0 and MotionTable.D_ACROSS[k] > 0.0
	TestUtil.check(rising, "a steeper slope never gives less drift up to s = %s" % RISING_S_MAX)
	TestUtil.check(declining, "beyond that the drift declines, where it does, by less than %s of speed from one row to the next" % MAX_DECLINE)
	TestUtil.check(bounded, "the table's drift is a share of speed under 0.3 and its diffusions are positive")


## Where the generator fits the drift (a straight line through zero in s, k(eps) * s), the table holds exactly that, and k falls with eps.
func _check_weak_gradient_fit() -> void:
	var ne: int = MotionTable.E_AXIS.size()
	var straight := true
	var falling := true
	var last_k := INF
	for j in ne:
		if MotionTable.E_AXIS[j] < Gen.FIT_EPS_MIN:
			continue
		var k: float = MotionTable.DRIFT[j] / MotionTable.S_AXIS[0]
		for i in MotionTable.S_AXIS.size():
			if MotionTable.S_AXIS[i] <= Gen.FIT_S_MAX:
				straight = straight and absf(MotionTable.DRIFT[i * ne + j] / MotionTable.S_AXIS[i] - k) <= 1e-4 * k
		falling = falling and k <= last_k
		last_k = k
	TestUtil.check(straight, "the drift is a straight line through zero in s where the generator fits one (eps from %s, s up to %s)" % [Gen.FIT_EPS_MIN, Gen.FIT_S_MAX])
	TestUtil.check(falling, "the slope of that line never rises with eps")
