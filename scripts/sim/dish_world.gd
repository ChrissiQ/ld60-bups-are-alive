class_name DishWorld
extends RefCounted
## A dish's world as the simulation thread keeps it: the plankton (floating, then bursting), the bloom that adds them, the sources and
## their emitters, and the random generator whose state is saved. Everything is in the dish's own coordinates (µm from its centre).
## `events` answers a window of steps with the clouds, deposits and husks it puts into the medium, each stamped with its step, and costs
## time in the events of the window, not in its steps. It touches no node, no scene and no `Strings`, so it can live on a thread.
##
## The rules of its events:
## the bloom's arrivals are on a steady schedule and each draws its place, its life and its shape in that order; the plankton are looked
## over every BURST_CHECK_SECONDS of simulated time and burst at the first look at or after their time; a source's emitter lets go of
## what it kept when its age reaches clamp(lived, 5, EMIT_INTERVAL).

const STRIDE_DISC := 5  ## a row of `discs`: step, x, y, energy, disc radius (a plankton's burst: the field's add_cloud)
const STRIDE_PUFF := 5  ## a row of `puffs`: step, x, y, mass, variance (an emitter's release as a cloud: add_puff with cut 0.001)
const STRIDE_DEPOSIT := 4  ## a row of `deposits`: step, x, y, mass (an emitter's release straight onto the grid)
const STRIDE_HUSK := 4  ## a row of `husks`: step, x, y, energy (a plankton's burst when plankton leave husks)

const EMIT_INTERVAL := 60.0  ## s: the longest an emitter keeps what a steady source gives
const EMIT_FIRST := 5.0  ## s: the least it waits, so a new source shows soon
const MIN_CLOUD_VARIANCE := 100.0  ## µm²: no cloud is thinner than 10 µm across

var time := 0.0  ## sim seconds: where the last window ended
var radius := 0.0  ## µm: the dish's
var bloom_density := 0.0  ## plankton in each mm² every sim-day
var plankton_husks := false  ## a plankton that bursts leaves a husk instead of a cloud
var diffusion := 0.0  ## µm²/s: the medium's, for the emitters' clouds
var handover_len := 0.0  ## µm: a cloud this wide (sigma) goes to the grid; the cloud handover times the grid's cell
var nutrient_energy := 16.0  ## the energy in one unit of nutrient

var rng := RandomNumberGenerator.new()

var _plankton: Array = []  ## sorted by burst_at: {pos: Vector2, born_at, burst_at, units, shape}
var _sources: Dictionary = {}  ## id -> {pos: Vector2, rate, emitted, em_mass, em_age, em_lived, em_live (an emitter holds something)}
var _next_source := 1
var _bloom_due := 0.0
var _burst_clock := 0.0  ## sim seconds since the plankton were last looked over for bursts
var _pending: Dictionary = {}  ## the rows edits made (a removed source's release), handed out with the next window at step 0
var _plankton_shared := false  ## a `checkpoint` holds `_plankton` as it is: the next arrival puts the plankton into a new array


func _init(p_radius: float = 1000.0, p_seed: int = 1) -> void:
	radius = p_radius
	rng.seed = p_seed


## The medium the emitters work in. `spacing` is the grid's cell, `cloud_handover` the share of it a cloud may be before the grid takes it.
func set_medium(p_diffusion: float, p_spacing: float, p_cloud_handover: float, p_nutrient_energy: float) -> void:
	diffusion = p_diffusion
	handover_len = p_cloud_handover * p_spacing
	nutrient_energy = p_nutrient_energy


func bloom_per_day() -> float:
	return bloom_density * PI * pow(radius / StartConditions.UM_PER_MM, 2)


## Sets the bloom. Turning it on from off makes the first arrival due now.
func set_bloom(density: float) -> void:
	if density > 0.0 and bloom_density <= 0.0:
		_bloom_due = time
	bloom_density = clampf(density, 0.0, StartConditions.MAX_BLOOM_DENSITY)


func plankton_count() -> int:
	return _plankton.size()


func source_count() -> int:
	return _sources.size()


## An edit of the world. `op`: "add_source" (pos, rate; returns its id), "remove_source" (id), "move_source" (id, pos), "set_rate" (id, rate),
## "add_plankton" (pos; returns whether it was added), "remove_plankton" (pos, radius). A source that goes or moves lets go of what its
## emitter kept, in the next window's rows at step 0.
func apply(edit: Dictionary) -> Variant:
	match edit.get("op", ""):
		"add_source":
			var id := _next_source
			_next_source += 1
			_sources[id] = {"pos": edit["pos"], "rate": float(edit["rate"]), "emitted": 0.0, "em_mass": 0.0, "em_age": 0.0, "em_lived": 0.0}
			return id
		"remove_source":
			if _sources.has(edit["id"]):
				_release(_sources[edit["id"]], 0, true)
				_sources.erase(edit["id"])
		"move_source":
			if _sources.has(edit["id"]):
				var s: Dictionary = _sources[edit["id"]]
				_release(s, 0, true)
				s["pos"] = edit["pos"]
				s["em_lived"] = 0.0
		"set_rate":
			if _sources.has(edit["id"]):
				_sources[edit["id"]]["rate"] = float(edit["rate"])
		"add_plankton":
			if _plankton.size() >= Dish.MAX_PLANKTON:
				return false
			_add_plankton(edit["pos"], time)
			return true
		"remove_plankton":
			var keep: Array = []
			for p in _plankton:
				if (p["pos"] as Vector2).distance_to(edit["pos"]) > float(edit["radius"]):
					keep.append(p)
			_plankton = keep
	return null


## The clouds, deposits and husks the window puts into the medium: `steps` steps of `delta` seconds after `t0`. Step n (1-based) ends at
## t0 + n * delta, which is the time at the end of step n. Returns {"discs", "puffs", "deposits", "husks"} (flat
## PackedFloat64Arrays, row layouts above), in step order within each.
func events(t0: float, steps: int, delta: float) -> Dictionary:
	time = t0
	var out := {
		"discs": PackedFloat64Array(),
		"puffs": PackedFloat64Array(),
		"deposits": PackedFloat64Array(),
		"husks": PackedFloat64Array(),
	}
	for key in _pending:
		out[key].append_array(_pending[key])
	_pending = {}
	if steps <= 0 or delta <= 0.0:
		return out
	_plankton_events(t0, steps, delta, out)
	for s in _sources.values():
		_source_events(s, steps, delta, out)
	time = t0 + steps * delta
	return out


## What `events` changes, kept so `restore` can put it back (a window the simulation then refused never happened). Cheap enough for every
## window: the plankton are held as they are (a plankton's entry is never changed, and an arrival after this copies the list first), each
## source's emitter is copied.
func checkpoint() -> Dictionary:
	_plankton_shared = true
	var sources := {}
	for id: int in _sources:
		sources[id] = (_sources[id] as Dictionary).duplicate()
	return {"time": time, "plankton": _plankton, "sources": sources, "bloom_due": _bloom_due, "burst_clock": _burst_clock, "pending": _pending,
		"rng_state": rng.state}


## Back to a `checkpoint` taken before the windows since (no edit may come between them).
func restore(saved: Dictionary) -> void:
	time = saved["time"]
	_plankton = saved["plankton"]
	_plankton_shared = true
	_sources = saved["sources"]
	_bloom_due = saved["bloom_due"]
	_burst_clock = saved["burst_clock"]
	_pending = saved["pending"]
	rng.state = saved["rng_state"]


func _plankton_events(t0: float, steps: int, delta: float, out: Dictionary) -> void:
	var t_end := t0 + steps * delta
	var interval := 86400.0 / bloom_per_day() if bloom_density > 0.0 else INF
	var period := maxi(1, ceili(Dish.BURST_CHECK_SECONDS / delta))  ## steps between look-overs
	var first_check := maxi(1, ceili((Dish.BURST_CHECK_SECONDS - _burst_clock) / delta))  ## the first look-over's step: they are on a grid of `period` steps from it, whether or not anything is due
	var next_check := first_check
	var cur := 1  ## the first step not yet handled
	while cur <= steps:
		var arrival := steps + 1
		if bloom_density > 0.0 and _bloom_due <= t_end:
			arrival = maxi(cur, ceili((_bloom_due - t0) / delta))
		var burst := steps + 1
		if not _plankton.is_empty() and _plankton[0]["burst_at"] <= t_end:
			var need := maxi(cur, ceili((float(_plankton[0]["burst_at"]) - t0) / delta))
			burst = next_check + maxi(0, ceili(float(need - next_check) / period)) * period
		var n := mini(arrival, burst)
		if n > steps:
			break
		var now := t0 + n * delta
		if arrival == n:
			var arrivals := 0
			while now >= _bloom_due and arrivals < Dish.MAX_BLOOM_ARRIVALS_PER_STEP:
				if _plankton.size() < Dish.MAX_PLANKTON:
					_add_plankton(_random_spot(), now)
				_bloom_due += interval
				arrivals += 1
			if now >= _bloom_due:  # (far behind, say the rate was just raised a great deal: start over from now)
				_bloom_due = now + interval
		if burst == n:
			var gone := 0
			while gone < _plankton.size() and _plankton[gone]["burst_at"] <= now:
				var p: Dictionary = _plankton[gone]
				var at: Vector2 = p["pos"]
				var energy: float = p["units"] * nutrient_energy
				if plankton_husks:
					out["husks"].append_array(PackedFloat64Array([n, at.x, at.y, energy]))
				else:
					out["discs"].append_array(PackedFloat64Array([n, at.x, at.y, energy, Dish.PLANKTON_PATCH_RADIUS]))
				gone += 1
			_plankton = _plankton.slice(gone)
			_plankton_shared = false  # (a new array, which no checkpoint holds)
			next_check = n + period
		cur = n + 1
	if first_check <= steps:  # the clock since the last look-over
		_burst_clock = ((steps - first_check) % period) * delta
	else:
		_burst_clock += steps * delta


func _random_spot() -> Vector2:
	var reach := radius - Dish.PLANKTON_DRAW_RADIUS
	var a := rng.randf() * TAU
	var r := reach * sqrt(rng.randf())
	return Vector2(r * cos(a), r * sin(a))


func _add_plankton(pos: Vector2, now: float) -> void:
	var life: float = Dish.PLANKTON_MEAN_LIFE * (1.0 + Dish.PLANKTON_LIFE_SPREAD * (2.0 * rng.randf() - 1.0))
	var p := {"pos": pos, "born_at": now, "burst_at": now + life, "units": Dish.PLANKTON_UNITS, "shape": rng.randf() * TAU}
	if _plankton_shared:
		_plankton = _plankton.duplicate()
		_plankton_shared = false
	var lo := 0  ## (after the others with the same time: bursts in the order they were made)
	var hi := _plankton.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if _plankton[mid]["burst_at"] <= p["burst_at"]:
			lo = mid + 1
		else:
			hi = mid
	_plankton.insert(lo, p)


## The sources' emission over a window of equal steps. A source gives rate / 60 * delta * nutrient_energy a step.
func _source_events(s: Dictionary, steps: int, delta: float, out: Dictionary) -> void:
	var energy: float = s["rate"] / 60.0 * delta * nutrient_energy
	s["emitted"] += s["rate"] / 60.0 * delta * steps
	if sqrt(diffusion * EMIT_INTERVAL) >= handover_len:  # a grid fine enough to hold the plume: onto it, as one row at the window's middle
		if energy > 0.0:
			var at: Vector2 = s["pos"]
			out["deposits"].append_array(PackedFloat64Array([maxi(1, (steps + 1) / 2), at.x, at.y, energy * steps]))
		return
	var n := 0  ## steps done of this window
	while n < steps:
		var age: float = s["em_age"]
		var lived: float = s["em_lived"]
		var due := _steps_to_release(age, lived, delta)
		if n + due > steps:  # no release in what is left of the window
			var rest := steps - n
			s["em_mass"] += energy * rest
			s["em_age"] = age + rest * delta
			s["em_lived"] = lived + rest * delta
			return
		n += due
		s["em_mass"] += energy * due
		s["em_age"] = age + due * delta
		s["em_lived"] = lived + due * delta
		_release(s, n, false, out)


## The fewest steps n >= 1 after which `age + n * delta >= clamp(lived + n * delta, EMIT_FIRST, EMIT_INTERVAL)`.
static func _steps_to_release(age: float, lived: float, delta: float) -> int:
	var n_cap := maxi(1, ceili((EMIT_INTERVAL - age) / delta))
	if age >= lived:  # (a fresh emitter: age and lived grow together, so it waits for the first release time only)
		return mini(n_cap, maxi(1, ceili((EMIT_FIRST - age) / delta)))
	return n_cap


## The release of an emitter's remaining nutrient. `into_pending` puts the row in the next window's (an edit's release), at step 0.
func _release(s: Dictionary, step: int, into_pending: bool, out: Dictionary = {}) -> void:
	if s["em_mass"] > 0.0:
		var at: Vector2 = s["pos"]
		var v := maxf(diffusion * s["em_age"], MIN_CLOUD_VARIANCE)
		var row := PackedFloat64Array([step, at.x, at.y, s["em_mass"], v])
		var target := out
		if into_pending:
			for key in ["discs", "puffs", "deposits", "husks"]:
				if not _pending.has(key):
					_pending[key] = PackedFloat64Array()
			target = _pending
		if sqrt(diffusion * EMIT_INTERVAL) >= handover_len:
			target["deposits"].append_array(PackedFloat64Array([step, at.x, at.y, s["em_mass"]]))
		else:
			target["puffs"].append_array(row)
	s["em_mass"] = 0.0
	s["em_age"] = 0.0


## A read-only copy of what the main thread needs: {time, radius, bloom_density, plankton: [{pos, born_at, burst_at, units, shape}], sources: {id: {pos, rate, emitted}}}.
func copy() -> Dictionary:
	var ps: Array = []
	for p in _plankton:
		ps.append(p.duplicate())
	var ss := {}
	for id in _sources:
		var s: Dictionary = _sources[id]
		ss[id] = {"pos": s["pos"], "rate": s["rate"], "emitted": s["emitted"]}
	return {"time": time, "radius": radius, "bloom_density": bloom_density, "plankton": ps, "sources": ss}


## Everything, as plain data (emitters keep what they hold; the generator's seed and state).
func save() -> Dictionary:
	var ps: Array = []
	for p in _plankton:
		ps.append(p.duplicate())
	var ss := {}
	for id in _sources:
		ss[id] = (_sources[id] as Dictionary).duplicate()
	return {
		"time": time, "radius": radius, "bloom_density": bloom_density, "plankton_husks": plankton_husks,
		"diffusion": diffusion, "handover_len": handover_len, "nutrient_energy": nutrient_energy,
		"plankton": ps, "sources": ss, "next_source": _next_source, "bloom_due": _bloom_due, "burst_clock": _burst_clock,
		"rng_seed": rng.seed, "rng_state": rng.state,
	}


## Restores a `save` at `world_time`: the plankton's and the bloom's times move on by the time away (the frozen time is not simulated).
func load_blob(blob: Dictionary, world_time: float) -> void:
	var shift := world_time - float(blob["time"])
	time = world_time
	radius = blob["radius"]
	bloom_density = blob["bloom_density"]
	plankton_husks = blob["plankton_husks"]
	diffusion = blob["diffusion"]
	handover_len = blob["handover_len"]
	nutrient_energy = blob["nutrient_energy"]
	_plankton = []
	for p in blob["plankton"]:
		var q: Dictionary = p.duplicate()
		q["born_at"] += shift
		q["burst_at"] += shift
		_plankton.append(q)
	_sources = {}
	for id in blob["sources"]:
		_sources[id] = (blob["sources"][id] as Dictionary).duplicate()
	_next_source = blob["next_source"]
	_bloom_due = float(blob["bloom_due"]) + shift
	_burst_clock = blob["burst_clock"]
	_pending = {}
	rng.seed = blob["rng_seed"]
	rng.state = blob["rng_state"]
