class_name Scenario
extends RefCounted
## One dish of the pooled world as pure data: what the harness turns into a `DishSpec`. Builders: `goal()`, `big(n)`, `small(n, radius)`;
## `with_flags({...})` and `seed(s)` change it and return it, so calls chain.
##
## Flags (`FLAG_NAMES`, and "resolution" 100, 200 or 400 cells across): stationary phase, death husks, plankton husks, the acetate
## key, conjugation, acetate. A flag that is a gene (key, conjugation) is given to the founders: every fifth founder is a donor
## (conjugation) and every fifth, from the third, has the key (level 2). Positions come from `layout_seed` (the seed when 0), so two
## dishes can be laid over the same coordinates.

const FLAG_NAMES := ["stationary", "death_husks", "plankton_husks", "key", "conjugation", "acetate"]
const RESOLUTIONS := [100, 200, 400]
const FOUNDER_ENERGY := 50.0  ## a founder's reserve (model_test's `_cell` default)
const KEY_LEVEL_2_REACH := 2 << 8  ## the acetate key in the reach word (bits 8-9)

var label := ""
var number := 0  ## the dish's number (the id's high part); 0: the harness numbers the rows 1, 2, ...
var radius := 3000.0  ## µm
var resolution := 100  ## cells across
var limit := 1000
var bups := 20
var nutrient_density := 32.0
var feed_density := 0.0
var bloom_density := 0.0
var medium_thickness := 25.0
var flags := {}
var seed_value := 1
var layout_seed := 0
var step_start := 0  ## the dish's own step at its strike
var sources: Array = []  ## [Vector2 dish-local, rate]


## Goal mode's dish: `StartConditions.new()`'s values.
static func goal() -> Scenario:
	var start := StartConditions.new()
	var s := Scenario.new()
	s.label = "goal"
	s.radius = start.dish_radius
	s.limit = start.bup_limit
	s.bups = start.bups
	s.nutrient_density = start.nutrient_density
	s.feed_density = start.feed_density
	s.bloom_density = start.bloom_density
	s.resolution = start.nutrient_resolution
	return s


## A dish of 45 mm holding `n` bups at the start, with room to double.
static func big(n: int) -> Scenario:
	var s := goal()
	s.label = "big %d" % n
	s.bups = n
	s.limit = maxi(2 * n, StartConditions.DEFAULT_BUP_LIMIT)
	return s


## A dish of `radius` µm with `n` founders and room for twenty times as many.
static func small(n: int, p_radius: float) -> Scenario:
	var s := Scenario.new()
	s.label = "small %d" % n
	s.bups = n
	s.radius = p_radius
	s.limit = maxi(20 * n, 1000)
	return s


## Sets flags (a key of `FLAG_NAMES` to a bool, "resolution" to 100, 200 or 400). An unknown name is an error.
func with_flags(p_flags: Dictionary) -> Scenario:
	for k in p_flags:
		if k == "resolution":
			assert(int(p_flags[k]) in RESOLUTIONS, "Scenario: resolution must be 100, 200 or 400")
			resolution = int(p_flags[k])
		elif k in FLAG_NAMES:
			flags[k] = bool(p_flags[k])
		else:
			push_error("Scenario: no flag named %s" % k)
			assert(false)
	return self


func seed(s: int) -> Scenario:
	seed_value = s
	return self


func flag(p_name: String) -> bool:
	return bool(flags.get(p_name, false))


func copy() -> Scenario:
	var c := Scenario.new()
	for p in get_property_list():
		if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var v: Variant = get(p["name"])
			c.set(p["name"], v.duplicate(true) if v is Array or v is Dictionary else v)
	return c


## Every flag on, resolution as given.
func with_all_flags(p_resolution := 100) -> Scenario:
	var all := {"resolution": p_resolution}
	for f in FLAG_NAMES:
		all[f] = true
	return with_flags(all)


## A random scenario for the "other dishes" of a test, from `rng` (so the others are the same in every run that seeds it alike).
static func random_other(rng: RandomNumberGenerator, with_flags_on := true) -> Scenario:
	var s := Scenario.small(rng.randi_range(5, 200), rng.randf_range(300.0, 3000.0))
	s.label = "other"
	s.seed_value = rng.randi_range(1, 1000000)
	s.nutrient_density = rng.randf_range(4.0, 64.0)
	s.bloom_density = rng.randf_range(0.0, 4.0)
	if with_flags_on:
		var f := {"resolution": RESOLUTIONS[rng.randi_range(0, RESOLUTIONS.size() - 1)]}
		for name in FLAG_NAMES:
			f[name] = rng.randf() < 0.5
		s.with_flags(f)
	return s


## The DP_FLAGS bits this scenario sets (the bit masks of GpuLayout.DPF_*; DPF_RUNNING and the rest are the core's).
func dish_flags() -> int:
	var bits := 0
	if flag("stationary"):
		bits |= 1 << GpuLayout.DPF_STATIONARY
	if flag("death_husks"):
		bits |= 1 << GpuLayout.DPF_DEATH_HUSKS
	if flag("plankton_husks"):
		bits |= 1 << GpuLayout.DPF_PLANKTON_HUSKS
	if flag("acetate"):
		bits |= 1 << GpuLayout.DPF_ACETATE
	return bits


## The founders as records (GpuLayout.RECORD_WORDS words each, ids from `dish_number`), placed uniformly inside 90% of the rim.
func founder_records(dish_number: int) -> PackedByteArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = (layout_seed if layout_seed != 0 else seed_value) * 7919 + 17
	var founder := Genome.founder()
	var born: float = Cell.mass_to_add(founder)
	var out := PackedByteArray()
	out.resize(bups * GpuLayout.RECORD_BYTES)
	for i in bups:
		var o := i * GpuLayout.RECORD_BYTES
		var at := Vector2.from_angle(rng.randf() * TAU) * (0.9 * radius * sqrt(rng.randf()))
		var dir := Vector2.from_angle(rng.randf() * TAU)
		GpuLayout.set_id(out, i, GpuLayout.make_id(dish_number, i + 1))
		out.encode_float(o + GpuLayout.R_X * 4, at.x)
		out.encode_float(o + GpuLayout.R_Y * 4, at.y)
		out.encode_float(o + GpuLayout.R_DX * 4, dir.x)
		out.encode_float(o + GpuLayout.R_DY * 4, dir.y)
		out.encode_float(o + GpuLayout.R_ENERGY * 4, FOUNDER_ENERGY)
		out.encode_float(o + GpuLayout.R_MASS * 4, born)
		out.encode_float(o + GpuLayout.R_BIRTH_MASS * 4, born)
		for g in GpuLayout.GENE_NAMES.size():
			out.encode_float(o + (GpuLayout.R_SPEED + g) * 4, founder[GpuLayout.GENE_NAMES[g]])
		var reach := KEY_LEVEL_2_REACH if flag("key") and i % 5 == 2 else 0
		out.encode_float(o + GpuLayout.R_REACH * 4, float(reach))
		out.encode_float(o + GpuLayout.R_MUTATOR * 4, 1.0)
		out.encode_float(o + GpuLayout.R_DONOR * 4, 1.0 if flag("conjugation") and i % 5 == 0 else 0.0)
		out.encode_float(o + GpuLayout.R_HUE * 4, founder["hue"])
		out.encode_float(o + GpuLayout.R_SAT * 4, founder["sat"])
		out.encode_float(o + GpuLayout.R_VAL * 4, founder["val"])
		out.encode_float(o + GpuLayout.R_PX * 4, GpuLayout.NO_PICTURE)
		out.encode_float(o + GpuLayout.R_PY * 4, GpuLayout.NO_PICTURE)
		out.encode_float(o + GpuLayout.R_FAST * 4, -1.0)
	return out
