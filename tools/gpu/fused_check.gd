extends SceneTree
## The step's fused passes against the lone kernels they stand for (SimCore.lone_passes): pool_swim_demand against pool_swim then
## pool_demand, pool_apply_count against pool_apply then pool_conj_count, and pool_ac_conj_life with pool_donor_life against pool_ac_apply,
## pool_conj_apply then pool_life, every other kernel the same, in the same order. Windowed, through the lock. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/fused_check.gd [-- seed_shift=N]
##
## Expected values [derived]: on each of three states (400 donors and recipients packed in a 100 µm dish
## with food enough to divide and the donors' genes set apart from the others', so transfers happen and show; a 20 mm dish (a 400 µm grid, so a plankton's burst is a cloud, not cells) with the
## bloom at its most and scarce food, so plankton clouds and
## starvation's death clouds; the stationary phase on scarce food), STEPS steps of 20 s (two hours: past the cloud compactions and husk
## culls, and the first divisions) give 0 differing words between the two at every BATCH-th step (records, field, clouds, husks, DSTATE
## but the start, the events of the last batch, the stats; the canonical dumps' hashes equal): a fused pass calls the lone kernels' own functions for a bup in their order, and
## a donor lives only after every recipient has read it, as the lone pool_life after pool_conj_apply. The energy ledger is off (the lone
## kernels have none; it is not compared). The one known way they could part is the compiler contracting the same arithmetic differently in
## the two texts (seen in pool_puff_advance): that would show as a few ulps and is reported, not allowed. To show the check can see
## an error, the donors' state run with pool_life before pool_conj_apply must differ.
##
## The fused field pass (pool_fdiff, SimCore.lone_field) is compared the same way against pool_feed, the ping-pong of pool_diffuse_a/b and
## pool_diffuse2_a/b and pool_land_copy, in a pool of dishes with 2, 4 and 62 iterations (3000 µm at 100 cells across, 3000 µm at 400, 150 µm
## at 100) one of them without the second food: 0 differing words at every BATCH-th step of STEPS, as the same arithmetic in the same order
## gives the same words ("fields" in the output). GPU_FROM_SOURCE=1 compiles the kernels from source.

const STEPS := 360
const BATCH := 60

var fails := 0


func _initialize() -> void:
	var donors := Scenario.small(400, 100.0).with_flags({"conjugation": true}).seed(61)
	donors.nutrient_density = StartConditions.MAX_NUTRIENT_DENSITY
	donors.feed_density = StartConditions.MAX_FEED_DENSITY
	var clouds := Scenario.small(300, 20000.0).seed(62)
	clouds.bloom_density = StartConditions.MAX_BLOOM_DENSITY
	clouds.nutrient_density = 2.0
	var stationary := Scenario.small(300, 1500.0).with_flags({"stationary": true}).seed(63)
	stationary.nutrient_density = 2.0
	for pair in [["donors", donors], ["clouds", clouds], ["stationary", stationary]]:
		_compare(pair[0], pair[1])
	_compare_fields()
	var fused := _made(donors)
	var wrong := _made(donors)
	wrong.core.lone_passes = true
	wrong.core.lone_order = ["pool_ac_apply", "pool_life", "pool_conj_apply"]
	fused.step(STEPS)
	wrong.step(STEPS)
	var line := SimHarness.diff(fused.dump(0), wrong.dump(0))
	_ok(line != "", "the donors' state with pool_life before pool_conj_apply differs (%s)" % (line if line != "" else "no difference: the check cannot see this error"))
	fused.core.release()
	wrong.core.release()
	print("OK fused_check" if fails == 0 else "FAILED fused_check: %d" % fails)
	quit(0 if fails == 0 else 1)


## The harness of one dish of `s`; when its founders carry the F factor, the donors' genes are set apart from the others' (speed x 1.5,
## sense x 0.6, metabolism x 1.2) before the first step, so that a transfer changes what the recipient is.
static func _made(s: Scenario) -> SimHarness:
	var h := SimHarness.make([s], {"from_source": OS.get_environment("GPU_FROM_SOURCE") == "1"})
	if not s.flag("conjugation"):
		return h
	var core: SimCore = h.core
	var recs := core.records(0)
	for i in recs.size() / GpuLayout.RECORD_BYTES:
		var o := i * GpuLayout.RECORD_BYTES
		if recs.decode_float(o + GpuLayout.R_DONOR * 4) > 0.5:
			for pair in [[GpuLayout.R_SPEED, 1.5], [GpuLayout.R_SENSE, 0.6], [GpuLayout.R_METABOLISM, 1.2]]:
				recs.encode_float(o + pair[0] * 4, recs.decode_float(o + pair[0] * 4) * pair[1])
	var start := core.dstate_row(0).decode_u32(GpuLayout.DS_START * 4)
	core.rd.buffer_update(core.arena.buf(core._cur("BUPS")), start * GpuLayout.RECORD_BYTES, recs.size(), recs)
	return h


func _compare(label: String, s: Scenario) -> void:
	var fused := _made(s)
	var lone := _made(s)
	lone.core.lone_passes = true
	var births := 0
	var deaths := 0
	for b in STEPS / BATCH:
		for c in BATCH / SimHarness.CHUNK:
			fused.step(SimHarness.CHUNK)
			lone.step(SimHarness.CHUNK)
			var ds := fused.dstate(0)
			births += ds[GpuLayout.DS_BIRTHS]
			deaths += ds[GpuLayout.DS_DEATHS]
		var a := fused.dump(0)
		var z := lone.dump(0)
		var line := SimHarness.diff(a, z)
		print("%s after %d steps: %d bups (%d births, %d deaths so far), %d donors, %d clouds, %d husks; hashes %s %s" % [label, (b + 1) * BATCH,
			fused.count(0), births, deaths, fused.dstate(0)[GpuLayout.DS_DONORS], (a["clouds"] as PackedByteArray).size() / 32,
			(a["husks"] as PackedByteArray).size() / 32, _hash(a), _hash(z)])
		_ok(line == "", "%s, %d steps: the fused passes equal the lone kernels%s" % [label, (b + 1) * BATCH, ": " + line if line != "" else ""])
	_ok(fused.core.overflow() == 0 and lone.core.overflow() == 0, "%s: no overflow" % label)
	fused.core.release()
	lone.core.release()


func _compare_fields() -> void:
	var mix := []
	for i in 2:
		mix.append(Scenario.small(300, 3000.0).seed(70 + i))
	var small := Scenario.small(300, 150.0).seed(72)
	small.nutrient_density = 40.0
	mix.append(small)
	mix.append(Scenario.small(300, 3000.0).with_flags({"resolution": 400}).seed(73))
	var blooms := Scenario.small(300, 3000.0).seed(74)
	blooms.bloom_density = StartConditions.MAX_BLOOM_DENSITY
	mix.append(blooms)
	var fused := SimHarness.make(mix, {"from_source": OS.get_environment("GPU_FROM_SOURCE") == "1"})
	var lone := SimHarness.make(mix, {"from_source": OS.get_environment("GPU_FROM_SOURCE") == "1"})
	lone.core.lone_field = true
	for b in STEPS / BATCH:
		for c in BATCH / SimHarness.CHUNK:
			fused.step(SimHarness.CHUNK)
			lone.step(SimHarness.CHUNK)
		for row in mix.size():
			var line := SimHarness.diff(fused.dump(row), lone.dump(row))
			_ok(line == "", "fields, dish %d, %d steps: the fused field pass equals the lone passes%s" % [row, (b + 1) * BATCH, ": " + line if line != "" else ""])
	var its := []
	for row in fused.core._dishes:
		its.append(fused.core._dishes[row].iterations)
	print("fields: iterations of the dishes ", its)
	_ok(fused.core.overflow() == 0 and lone.core.overflow() == 0, "fields: no overflow")
	fused.core.release()
	lone.core.release()


static func _hash(d: Dictionary) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for section: String in CanonicalDump.SECTIONS:
		var b: PackedByteArray = d.get(section, PackedByteArray())
		if b.size() > 0:
			ctx.update(b)
	return ctx.finish().hex_encode().substr(0, 12)


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		fails += 1
