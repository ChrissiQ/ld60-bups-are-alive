class_name SimHarness
extends RefCounted
## The test harness over the pooled GPU world: scenarios in, canonical dumps and invariant failures out.
##
## It reaches another script's classes (`SimCore`, `PoolLimits`, `DishSpec`, `WorldEdit`, `IterationPlan`, `DishBlob`) only through
## `load()` of their paths after `ResourceLoader.exists`, and holds what they return untyped, so every test parses before the pooled core
## exists. `begin` is the one gate every sim test calls first:
##   - headless (no GPU): prints "SKIP <test>: needs a local GPU" and quits 0 (never "OK");
##   - windowed and no `SimCore` yet: prints "FAIL <test>: no SimCore yet" and quits 1;
##   - otherwise returns true and the test runs on a local `RenderingDevice`.
## The core's method names below are what the pooled core gives (`add_dish`, `run`, `pipette`, `remove_dish`, `queue_edit`,
## `canonical_dump`); `TYPE_PATHS` are the core's files. Every chunk of steps checks that WORLD's overflow flag stayed 0 (a failed check, so
## the test fails). `SEED_SHIFT_ARG` on the command line (`-- seed_shift=N`) adds N to every scenario's seed, so a test runs on other seeds.
##
## Expected values (derived): `diff` of a dump with itself is ""; `make` returns null (and prints SKIP) without a device;
## `step(n)` advances every row by n steps of `delta` seconds in chunks of `CHUNK` (so a plan never outgrows the core's
## per-iteration limit), with each row's `DishWorld` events in the plan.

const SIM_CORE_PATH := "res://scripts/sim/sim_core.gd"
const TYPE_PATHS := {
	"PoolLimits": "res://scripts/sim/pool_limits.gd",
	"DishSpec": "res://scripts/sim/dish_spec.gd",
	"WorldEdit": "res://scripts/sim/world_edit.gd",
	"IterationPlan": "res://scripts/sim/iteration_plan.gd",
	"DishBlob": "res://scripts/sim/dish_blob.gd",
}
const CHUNK := 20  ## steps per call of the core's `run`
const SEED_SHIFT_ARG := "seed_shift="
const DEFAULT_DELTA := 20.0
const NUTRIENT_ENERGY := 16.0  ## the energy in one unit of nutrient (DishWorld's default)

var core: Variant = null  ## the SimCore
var scenarios: Dictionary = {}  ## row -> Scenario
var options: Dictionary = {}
var _delta := DEFAULT_DELTA
var _worlds: Dictionary = {}  ## row -> DishWorld
var _steps_done: Dictionary = {}  ## row -> steps run so far
var tallies: Dictionary = {}  ## row -> {births, deaths, moved_in, moved_out}, filled when options["tally"]


static func core_exists() -> bool:
	return ResourceLoader.exists(SIM_CORE_PATH)


static func device_available() -> bool:
	return DisplayServer.get_name() != "headless"


## The gate of every sim test (see the header). Returns true when the test may run its body.
static func begin(tree: SceneTree, test_name: String, enabled_by: String) -> bool:
	if not device_available():
		print("SKIP %s: needs a local GPU (not available headless), enabled by %s" % [test_name, enabled_by])
		tree.quit(0)
		return false
	if not core_exists():
		print("FAIL %s: no SimCore yet" % test_name)
		tree.quit(1)
		return false
	return true


## A skipped stub: prints the reason, quits 0.
static func skip(tree: SceneTree, test_name: String, reason: String, enabled_by: String) -> void:
	print("SKIP %s: %s, enabled by %s" % [test_name, reason, enabled_by])
	tree.quit(0)


static func make(p_scenarios: Array, opts := {}) -> SimHarness:
	if not device_available() or not core_exists():
		print("SKIP SimHarness.make: no local device or no SimCore")
		return null
	var h := SimHarness.new()
	h.options = opts
	h._delta = float(opts.get("delta", DEFAULT_DELTA))
	var limits: Variant = h._new_type("PoolLimits")
	h.core = load(SIM_CORE_PATH).new(limits, opts.get("from_source", false))
	for s in p_scenarios:
		h.add(s)
	return h


func _new_type(type_name: String) -> Variant:
	var path: String = TYPE_PATHS[type_name]
	if not ResourceLoader.exists(path):
		push_error("SimHarness: %s is not there yet" % type_name)
		return null
	return load(path).new()


## Adds a dish; returns its row.
func add(given: Scenario) -> int:
	var s := given.copy()
	s.seed_value += seed_shift()
	var number := s.number if s.number != 0 else scenarios.size() + 1
	var spec: Variant = _new_type("DishSpec")
	spec.number = number
	spec.radius = s.radius
	spec.resolution = s.resolution
	spec.limit = s.limit
	spec.seed = s.seed_value
	spec.flags = s.dish_flags()
	spec.nutrient_density = s.nutrient_density
	spec.feed_density = s.feed_density
	spec.bloom_density = s.bloom_density
	spec.medium_thickness = s.medium_thickness
	spec.founders = s.founder_records(number)
	var row: int = core.add_dish(spec)
	scenarios[row] = s
	_steps_done[row] = s.step_start
	_worlds[row] = _world_for(s, number)
	tallies[row] = {"births": 0, "deaths": 0, "moved_in": 0, "moved_out": 0}
	return row


## What `-- seed_shift=N` asks (0 without it).
static func seed_shift() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(SEED_SHIFT_ARG):
			return int(a.substr(SEED_SHIFT_ARG.length()))
	return 0


func _world_for(s: Scenario, _number: int) -> DishWorld:
	var w := DishWorld.new(s.radius, s.seed_value)
	w.set_medium(Biology.WATER_DIFFUSION / s.medium_thickness, 2.0 * s.radius / s.resolution, 0.5, NUTRIENT_ENERGY)
	w.plankton_husks = s.flag("plankton_husks")
	w.set_bloom(s.bloom_density)
	for src in s.sources:
		w.apply({"op": "add_source", "pos": src[0], "rate": src[1]})
	return w


func remove(row: int) -> SimHarness:
	core.remove_dish(row)
	scenarios.erase(row)
	_worlds.erase(row)
	_steps_done.erase(row)
	return self


func count(row: int) -> int:
	return int(dstate(row)[GpuLayout.DS_COUNT])


## The dish's DS_* words (uints) as an array of ints.
func dstate(row: int) -> PackedInt64Array:
	var bytes: PackedByteArray = core.canonical_dump(row)["dstate"]
	var out := PackedInt64Array()
	for i in bytes.size() / 4:
		out.append(bytes.decode_u32(i * 4))
	return out


## n steps of `delta` seconds (the harness's, unless given), in chunks; deterministic.
func step(n: int, delta := -1.0) -> SimHarness:
	var d := delta if delta > 0.0 else _delta
	var left := n
	while left > 0:
		var chunk := mini(left, CHUNK)
		var plan: Variant = _new_type("IterationPlan")
		plan.delta = d
		plan.events = {}
		for row in scenarios:
			plan.events[row] = _worlds[row].events(_steps_done[row] * d, chunk, d)
			_steps_done[row] += chunk
		core.run(chunk, d, plan)
		TestUtil.check(int(core.overflow()) == 0, "WORLD.overflow is %d after a run" % int(core.overflow()))
		if options.get("tally", false):
			_tally()
		left -= chunk
	return self


func _tally() -> void:
	for row in scenarios:
		var ds := dstate(row)
		var t: Dictionary = tallies[row]
		t["births"] += ds[GpuLayout.DS_BIRTHS]
		t["deaths"] += ds[GpuLayout.DS_DEATHS]
		t["moved_in"] += ds[GpuLayout.DS_MOVED_IN]
		t["moved_out"] += ds[GpuLayout.DS_MOVED_OUT]


func edit(row: int, e: Variant) -> SimHarness:
	core.queue_edit(row, e)
	return self


func set_field(row: int, values: PackedFloat32Array) -> SimHarness:
	core.set_field(row, values)
	return self


## The pipette's retarget into a new dish like the source (its size, grid and limit; a world with nothing in it): returns the number moved;
## the new dish's row is `last_pipette_row`.
var last_pipette_row := -1


func pipette(row: int, centre: Vector2, radius: float) -> int:
	var reply: Dictionary = core.pipette(row, centre, radius)
	if reply.is_empty():
		return 0
	last_pipette_row = int(reply["new_row"])
	var s := Scenario.small(0, scenarios[row].radius)
	s.resolution = scenarios[row].resolution
	s.limit = scenarios[row].limit
	scenarios[last_pipette_row] = s
	_steps_done[last_pipette_row] = _steps_done[row]
	_worlds[last_pipette_row] = _world_for(s, 0)
	_worlds[last_pipette_row].time = _worlds[row].time
	tallies[last_pipette_row] = {"births": 0, "deaths": 0, "moved_in": 0, "moved_out": 0}
	return int(reply["moved"])


## Freezes the dish: the blob carries the dish's world (DishWorld.save()) and the harness's own record of it, which `thaw` restores.
func freeze(row: int) -> Variant:
	var blob: Variant = core.freeze(row)
	blob.world = _worlds[row].save()
	blob.host = {"scenario": scenarios[row], "steps_done": _steps_done[row]}
	scenarios.erase(row)
	_worlds.erase(row)
	_steps_done.erase(row)
	return blob


func thaw(blob: Variant) -> int:
	var row := int(core.thaw(blob))
	if row >= 0 and blob.host.has("scenario"):
		scenarios[row] = blob.host["scenario"]
		_steps_done[row] = blob.host["steps_done"]
		var w := DishWorld.new()
		w.load_blob(blob.world, float(blob.world["time"]))
		_worlds[row] = w
		tallies[row] = {"births": 0, "deaths": 0, "moved_in": 0, "moved_out": 0}
	return row


func dump(row: int) -> Dictionary:
	return CanonicalDump.coerce(core.canonical_dump(row))


func dump_all() -> Dictionary:
	var out := {}
	for row in scenarios:
		out[row] = dump(row)
	return out


## The checks; empty when all hold: count balance, unique ids, bups inside the rim, DSTATE's count equal to a recount of the live records.
func invariants() -> PackedStringArray:
	var bad := PackedStringArray()
	if int(core.overflow()) != 0:
		bad.append("WORLD.overflow is %d" % int(core.overflow()))
	for row in scenarios:
		var s: Scenario = scenarios[row]
		var d := dump(row)
		var recs: PackedByteArray = d["records"]
		var n := recs.size() / GpuLayout.RECORD_BYTES
		var ds := dstate(row)
		if n != ds[GpuLayout.DS_COUNT]:
			bad.append("row %d: DS_COUNT %d but %d records" % [row, ds[GpuLayout.DS_COUNT], n])
		var seen := {}
		for i in n:
			var id := GpuLayout.id_of(recs, i)
			if seen.has(id):
				bad.append("row %d: id %d twice" % [row, id])
				break
			seen[id] = true
		for i in n:
			var o := i * GpuLayout.RECORD_BYTES
			var at := Vector2(recs.decode_float(o + GpuLayout.R_X * 4), recs.decode_float(o + GpuLayout.R_Y * 4))
			if at.length() > s.radius * 1.0001:
				bad.append("row %d: record %d at %.1f µm outside the rim %.1f" % [row, i, at.length(), s.radius])
				break
		if n > s.limit:
			bad.append("row %d: %d bups over the limit %d" % [row, n, s.limit])
	return bad


## "" or the first differing word, named from GpuLayout (see CanonicalDump).
static func diff(a: Dictionary, b: Dictionary) -> String:
	return CanonicalDump.diff(a, b)
