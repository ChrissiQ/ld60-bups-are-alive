extends SceneTree
## Run: godot --headless --path . -s tests/dish_world_test.gd
## Checks DishWorld against a step-by-step reference written in this test (plankton and emitters advanced one step at a time).
##
## Expected values, written before the first run (derived unless marked):
## - Setup: radius 20,000 um, bloom density 1 per mm2 a day = 1256.6 a day, so one arrival every 68.75 s, the first at t = 0.
##   100 windows of 30 steps of 20 s = 60,000 s: 873 arrivals (floor(60000 / 68.75) + 1).
## - With the same seed the draws come in the same order, so DishWorld's rows equal the reference's exactly.
## - Independent seeds: the arrivals are on a schedule, so their per-window counts are identical; the bursts are random (life 1800-5400 s,
##   per-window count about Poisson with mean 8.7 once the dish is full), so the mean per-window difference is within 3 SE of 0.
## - Three sources (12, 30, 7.5 a minute), diffusion 500, cell 400, handover 0.5: sqrt(500 * 60) = 173 < 200, so releases are puffs; the
##   first release is after 1 step (age 20 >= 5), then every 3 steps (age 60 >= 60): 1 + floor(2999 / 3) = 1000 releases a source over
##   3000 steps, the last at step 2998, so the mass let go is rate / 60 * 20 * 16 * 2998 of the 3000 steps' (the last 2 steps stay kept).
## - Cell 100: handover 50 < 173, so a deposit at each release; DishWorld gives one row a window, whose mass is the window's whole.
## - A checkpoint taken before a window and restored after it (a window the simulation refused) leaves the world as it was (its save, the
##   pending release of a moved source, the random state): the window asked again gives the same rows as the first time, and a twin world
##   that never had the refused window gives the same rows over the next 20 windows. The checkpoint holds the plankton without copying
##   them, so a world of 20,000 plankton checkpoints in about what a world of none does [measured: printed]; 1,000 worlds of 3 sources
##   each checkpoint in under 5 ms [placeholder limit].

const R := 20000.0
const DELTA := 20.0
const STEPS := 30
const WINDOWS := 100
const D := 500.0
const ENERGY := 16.0

var failures := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		print("FAIL: ", what)


## The per-step reference, in the dish's own order: the clock moves, the bloom and the burst check (_step_plankton), then the sources.
class Reference:
	var rng := RandomNumberGenerator.new()
	var time := 0.0
	var radius := R
	var bloom_per_day := 0.0
	var due := 0.0
	var burst_clock := 0.0
	var plankton: Array = []  # [pos, burst_at]
	var sources: Array = []  # [pos, rate, mass, age, lived]
	var spacing := 400.0
	var handover := 0.5
	var discs: Array = []  # [step, x, y]
	var puffs: Array = []  # [step, x, y, mass, var]
	var deposits: Array = []
	var step := 0

	func _init(seed: int) -> void:
		rng.seed = seed

	func tick(delta: float) -> void:
		step += 1
		time += delta
		if bloom_per_day > 0.0:
			var interval := 86400.0 / bloom_per_day
			var arrivals := 0
			while time >= due and arrivals < Dish.MAX_BLOOM_ARRIVALS_PER_STEP:
				if plankton.size() < Dish.MAX_PLANKTON:
					var a := rng.randf() * TAU
					var r := (radius - Dish.PLANKTON_DRAW_RADIUS) * sqrt(rng.randf())
					var pos := Vector2(r * cos(a), r * sin(a))
					var life: float = Dish.PLANKTON_MEAN_LIFE * (1.0 + Dish.PLANKTON_LIFE_SPREAD * (2.0 * rng.randf() - 1.0))
					rng.randf()
					plankton.append([pos, time + life])
				due += interval
				arrivals += 1
			if time >= due:
				due = time + interval
		burst_clock += delta
		if burst_clock >= Dish.BURST_CHECK_SECONDS:
			burst_clock = 0.0
			var kept: Array = []
			for p in plankton:
				if p[1] <= time:
					discs.append([step, p[0].x, p[0].y])
				else:
					kept.append(p)
			plankton = kept
		for s in sources:
			var energy: float = s[1] / 60.0 * delta * ENERGY
			if sqrt(D * 60.0) >= handover * spacing:
				deposits.append([step, s[0].x, s[0].y, energy])
				continue
			s[2] += energy
			s[3] += delta
			s[4] += delta
			if s[3] >= clampf(s[4], 5.0, 60.0):
				if s[2] > 0.0:
					puffs.append([step, s[0].x, s[0].y, s[2], maxf(D * s[3], 100.0)])
				s[2] = 0.0
				s[3] = 0.0


func _world(seed: int, density: float, cell: float) -> DishWorld:
	var w := DishWorld.new(R, seed)
	w.set_medium(D, cell, 0.5, ENERGY)
	w.set_bloom(density)
	return w


func _rows(flat: PackedFloat64Array, stride: int, offset: int) -> Array:
	var rows: Array = []
	for i in range(0, flat.size(), stride):
		var row := [int(flat[i]) + offset]
		for k in range(1, stride):
			row.append(flat[i + k])
		rows.append(row)
	return rows


func _sorted(rows: Array) -> Array:
	var r := rows.duplicate()
	r.sort_custom(func(x, y): return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	return r


func _same_rows(a: Array, b: Array, cols: int) -> bool:
	a = _sorted(a)
	b = _sorted(b)
	if a.size() != b.size():
		return false
	for i in a.size():
		for k in cols:
			if absf(float(a[i][k]) - float(b[i][k])) > 1e-6 * maxf(1.0, absf(float(b[i][k]))):
				return false
	return true


func _initialize() -> void:
	_test_same_seed()
	_test_statistics()
	_test_deposit_mode()
	_test_split_and_save()
	_test_edits()
	_test_checkpoint()
	_test_cost()
	if failures == 0:
		print("dish_world_test OK")
	quit(1 if failures > 0 else 0)


func _sources_for(w: DishWorld, ref: Reference) -> void:
	for spec in [[Vector2(100, 50), 12.0], [Vector2(-3000, 800), 30.0], [Vector2(0, -9000), 7.5]]:
		w.apply({"op": "add_source", "pos": spec[0], "rate": spec[1]})
		ref.sources.append([spec[0], spec[1], 0.0, 0.0, 0.0])


func _test_same_seed() -> void:
	var w := _world(7, 1.0, 400.0)
	var ref := Reference.new(7)
	ref.bloom_per_day = w.bloom_per_day()
	_sources_for(w, ref)
	var discs: Array = []
	var puffs: Array = []
	var arrivals := 0
	for k in WINDOWS:
		var before := w.plankton_count()
		var ev := w.events(k * STEPS * DELTA, STEPS, DELTA)
		discs.append_array(_rows(ev["discs"], DishWorld.STRIDE_DISC, k * STEPS))
		puffs.append_array(_rows(ev["puffs"], DishWorld.STRIDE_PUFF, k * STEPS))
		arrivals += w.plankton_count() - before + ev["discs"].size() / DishWorld.STRIDE_DISC
		for i in STEPS:
			ref.tick(DELTA)
	check(arrivals == 873, "arrivals over 60,000 s: %d, derived 873" % arrivals)
	check(discs.size() == ref.discs.size() and discs.size() > 700, "bursts: %d, reference %d" % [discs.size(), ref.discs.size()])
	check(_same_rows(discs, ref.discs, 3), "burst rows equal the reference's (step, x, y)")
	check(puffs.size() == 3000, "puffs: %d, derived 3000" % puffs.size())
	check(_same_rows(puffs, ref.puffs.map(func(r): return r), 5), "puff rows equal the reference's (step, x, y, mass, variance)")
	var mass := 0.0
	for r in puffs:
		mass += r[3]
	var want := (12.0 + 30.0 + 7.5) / 60.0 * DELTA * ENERGY * 2998.0
	check(absf(mass - want) < 1e-6 * want, "mass let go %f, derived %f" % [mass, want])


func _test_statistics() -> void:
	var a := _world(11, 1.0, 400.0)
	var b := Reference.new(23)
	b.bloom_per_day = a.bloom_per_day()
	var bur_d: Array = []
	for k in WINDOWS:
		var ev := a.events(k * STEPS * DELTA, STEPS, DELTA)
		var before_b := b.discs.size()
		for i in STEPS:
			b.tick(DELTA)
		bur_d.append(float(ev["discs"].size() / DishWorld.STRIDE_DISC) - float(b.discs.size() - before_b))
	var mean := 0.0
	for x in bur_d:
		mean += x
	mean /= bur_d.size()
	var v := 0.0
	for x in bur_d:
		v += (x - mean) * (x - mean)
	var se := sqrt(v / (bur_d.size() - 1) / bur_d.size())
	print("burst-count difference per window: mean %.3f, SE %.3f" % [mean, se])
	check(absf(mean) <= 3.0 * se, "independent seeds: mean burst-count difference %f, SE %f" % [mean, se])
	check(se > 0.0, "the bursts are random (SE %f)" % se)


func _test_deposit_mode() -> void:
	var w := _world(3, 0.0, 100.0)
	var ref := Reference.new(3)
	ref.spacing = 100.0
	_sources_for(w, ref)
	var dep := PackedFloat64Array()
	for k in 10:
		dep.append_array(w.events(k * STEPS * DELTA, STEPS, DELTA)["deposits"])
		for i in STEPS:
			ref.tick(DELTA)
	check(dep.size() == 10 * 3 * DishWorld.STRIDE_DEPOSIT, "deposit rows: %d, derived one a window a source" % (dep.size() / DishWorld.STRIDE_DEPOSIT))
	var m := 0.0
	for i in range(3, dep.size(), DishWorld.STRIDE_DEPOSIT):
		m += dep[i]
	var m_ref := 0.0
	for r in ref.deposits:
		m_ref += r[3]
	check(absf(m - m_ref) < 1e-6 * m_ref, "deposited mass %f, reference %f" % [m, m_ref])


func _test_split_and_save() -> void:
	var whole := _world(5, 1.0, 400.0)
	var split := _world(5, 1.0, 400.0)
	var dummy := Reference.new(0)
	_sources_for(whole, dummy)
	_sources_for(split, dummy)
	var e1 := whole.events(0.0, 3000, DELTA)
	var rows_split: Array = []
	var puff_split: Array = []
	var done := 0
	var saved: Dictionary = {}
	var chunks := [7, 31, 1, 100, 233]
	var i := 0
	while done < 3000:
		var n: int = mini(chunks[i % chunks.size()], 3000 - done)
		var ev := split.events(done * DELTA, n, DELTA)
		rows_split.append_array(_rows(ev["discs"], DishWorld.STRIDE_DISC, done))
		puff_split.append_array(_rows(ev["puffs"], DishWorld.STRIDE_PUFF, done))
		done += n
		i += 1
		if done >= 1500 and saved.is_empty():
			saved = split.save()
	check(_same_rows(_rows(e1["discs"], DishWorld.STRIDE_DISC, 0), rows_split, 3), "bursts do not depend on how the steps are cut into windows")
	check(_same_rows(_rows(e1["puffs"], DishWorld.STRIDE_PUFF, 0), puff_split, 5), "puffs do not depend on how the steps are cut into windows")
	# a save at `saved.time`, loaded 1000 s later, carries on with the same rows (times shifted)
	var t_saved: float = saved["time"]
	var a := DishWorld.new(1.0, 1)
	var b := DishWorld.new(1.0, 1)
	a.load_blob(saved, t_saved)
	b.load_blob(saved, t_saved + 1000.0)
	var ea := a.events(t_saved, 600, DELTA)
	var eb := b.events(t_saved + 1000.0, 600, DELTA)
	check(ea["discs"] == eb["discs"] and ea["puffs"] == eb["puffs"] and ea["discs"].size() > 0, "a world loaded at a later time carries on the same (rng state, shifted times)")
	var tail: Array = []
	tail.append_array(_rows(ea["discs"], DishWorld.STRIDE_DISC, int(t_saved / DELTA)))
	var want := rows_split.filter(func(r): return r[0] > int(t_saved / DELTA) and r[0] <= int(t_saved / DELTA) + 600)
	check(_same_rows(tail, want, 3), "a loaded save continues as the world it was saved from")


func _test_edits() -> void:
	var w := DishWorld.new(R, 9)
	w.set_medium(D, 400.0, 0.5, ENERGY)
	var id: int = w.apply({"op": "add_source", "pos": Vector2(10, 10), "rate": 12.0})
	var ev := w.events(0.0, 1, DELTA)  # one step: age 20 >= 5, released
	check(ev["puffs"].size() == DishWorld.STRIDE_PUFF, "a new source lets go after its first step")
	w.events(DELTA, 1, DELTA)  # kept: 12/60*20*16 = 64
	w.apply({"op": "remove_source", "id": id})
	var ev2 := w.events(2.0 * DELTA, 1, DELTA)
	check(ev2["puffs"].size() == DishWorld.STRIDE_PUFF and absf(ev2["puffs"][3] - 64.0) < 1e-9 and ev2["puffs"][0] == 0.0, "a removed source lets go of what it kept (64), at step 0 of the next window")
	check(w.source_count() == 0, "the source is gone")
	var fresh: Variant = w.apply({"op": "add_plankton", "pos": Vector2(0, 0)})
	check(fresh == true and w.plankton_count() == 1, "a plankton placed by hand")
	var c := w.copy()
	check(c["plankton"].size() == 1 and c["sources"].is_empty(), "copy holds the plankton and sources")
	w.apply({"op": "remove_plankton", "pos": Vector2(1, 1), "radius": 5.0})
	check(w.plankton_count() == 0, "a plankton removed by the eraser")
	# a bloom switched on far behind starts over instead of flooding: due long ago, a step of 1 s
	var f := _world(2, 0.0, 400.0)
	f.set_bloom(10.0)
	var before := f.plankton_count()
	f.events(1.0e6, 3, 1.0e5)  # (arrivals every 6.9 s, a step of 100,000 s: more than the cap would let in)
	check(f.plankton_count() - before <= 3 * Dish.MAX_BLOOM_ARRIVALS_PER_STEP, "a bloom far behind is capped a step")


func _test_checkpoint() -> void:
	var w := _world(13, 1.0, 400.0)
	var twin := _world(13, 1.0, 400.0)
	var dummy := Reference.new(0)
	_sources_for(w, dummy)
	_sources_for(twin, dummy)
	for k in 20:
		w.events(k * STEPS * DELTA, STEPS, DELTA)
		twin.events(k * STEPS * DELTA, STEPS, DELTA)
	for world: DishWorld in [w, twin]:
		world.apply({"op": "move_source", "id": 1, "pos": Vector2(500, 500)})  # (its release waits for the next window, at step 0)
	var t := 20 * STEPS * DELTA
	var saved := w.save()
	var cp := w.checkpoint()
	var refused := w.events(t, STEPS, DELTA)
	w.restore(cp)
	check(w.save() == saved, "a restored checkpoint leaves the world as it was before the window")
	var again := w.events(t, STEPS, DELTA)
	check(again == refused and (refused["puffs"] as PackedFloat64Array).size() > 0 and (refused["discs"] as PackedFloat64Array).size() + w.plankton_count() > 0, "the window asked again gives the same rows (the moved source's release among them)")
	var same := again == twin.events(t, STEPS, DELTA)
	for k in range(21, 41):
		var cp2 := w.checkpoint()  # (one a window, as the sim thread takes them, none restored)
		same = same and cp2.size() > 0 and w.events(k * STEPS * DELTA, STEPS, DELTA) == twin.events(k * STEPS * DELTA, STEPS, DELTA)
	check(same and w.save() == twin.save(), "after a refused window the world goes on as one that never had it, over 20 more windows")
	var crowded := _world(14, 0.0, 400.0)
	for i in Dish.MAX_PLANKTON:
		crowded.apply({"op": "add_plankton", "pos": Vector2(i % 100, i / 100)})
	var t0 := Time.get_ticks_usec()
	for i in 100:
		crowded.checkpoint()
	var crowded_us := (Time.get_ticks_usec() - t0) / 100.0
	var many: Array = []
	for i in 1000:
		var m := _world(100 + i, 0.0, 400.0)
		_sources_for(m, dummy)
		many.append(m)
	t0 = Time.get_ticks_usec()
	for m: DishWorld in many:
		m.checkpoint()
	var many_us := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for m: DishWorld in many:
		m.events(0.0, STEPS, DELTA)
	var window_us := Time.get_ticks_usec() - t0
	var bare: Array = []
	for i in 1000:
		bare.append(_world(2000 + i, 1.0, 400.0))
	t0 = Time.get_ticks_usec()
	for m: DishWorld in bare:
		m.checkpoint()
	var bare_us := Time.get_ticks_usec() - t0
	print("checkpoint: a world of %d plankton %.1f us; 1,000 worlds of 3 sources %d us (their window of %d steps: %d us); 1,000 worlds with no source %d us [measured]" % [crowded.plankton_count(), crowded_us, many_us, STEPS, window_us, bare_us])
	check(many_us < 5000, "1,000 worlds of 3 sources checkpoint in %d us (placeholder limit 5,000)" % many_us)


func _test_cost() -> void:
	var w := _world(4, 0.0, 400.0)
	var t0 := Time.get_ticks_usec()
	w.events(0.0, 1000000, DELTA)
	var us := Time.get_ticks_usec() - t0
	print("empty world, 1,000,000 steps: %d us" % us)
	check(us < 50000, "an empty world over 1,000,000 steps takes %d us (placeholder limit 50,000)" % us)
