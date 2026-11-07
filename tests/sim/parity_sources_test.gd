extends SceneTree
## A source's output on the real pool: a source placed with Dish.place_source in a bare dish (no bups, no nutrient, no
## feed) at ParityGame.PLACE, the world run ten minutes, the pool read before and after (SimCore.gather) and the source's own count read
## from its DishWorld on the sim thread. Windowed only:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_sources_test.gd
##
## Expected values, written before the first run [derived unless marked]:
## The source gives rate / 60 x delta units a step (DishWorld._source_events). Its emitter keeps what it gave for up to EMIT_INTERVAL
## (60 s) and lets it go as a cloud, unless the grid is fine enough to hold the plume (sqrt(D x 60 s) >= half a cell), when it goes onto
## the grid at once; the fixture's total counted what the emitter keeps, so "what the source added" is the pool's gain plus what
## its emitter keeps.
## S  On a 3 mm dish (cells of 60 µm: sqrt(24 x 60) = 38 µm >= 30, straight onto the grid), rate 6 a minute, about 600 s at x600: the source
##    counts 6 / 60 x the world time that passed (within 1e-9 relative), and the pool gains 16 energy a unit of it within 1e-3 relative
##    (the deposits are fixed point, 2^-20 of a concentration unit a cell).
## B  On a 45 mm dish (cells of 900 µm: its releases are clouds), the same: the pool's gain plus the change in what the emitter keeps is
##    16 energy a unit of the count within 1e-3 relative, and the pool alone lags it by what the emitter keeps (at most a minute's worth).

var g: ParityGame


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_sources_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_sources_test")
		return
	await _source("S", 3000.0, 30)
	await _source("B", 45000.0, 31)
	TestUtil.finish(self, "OK parity_sources_test")


## The source's [emitted units, energy its emitter keeps] from its DishWorld on the sim thread.
func _count(d: Dish) -> Array:
	var row := d.row
	var thread: Variant = g.world.backend.get("thread")
	return await g.inspect(func(_core: SimCore, _rows: Dictionary) -> Array:
		var w: DishWorld = thread._worlds.get(row)
		if w == null or w._sources.is_empty():
			return [0.0, 0.0]
		var s: Dictionary = w._sources.values()[0]
		return [float(s["emitted"]), float(s["em_mass"])])


func _source(label: String, radius: float, number: int) -> void:
	var spec := DishSpec.new()
	spec.number = number
	spec.radius = radius
	spec.limit = 1000
	spec.seed = number
	spec.nutrient_density = 0.0
	var d: Dish = await g.add(spec)
	TestUtil.show(d.place_source(d.global_position + Vector2(500.0, 300.0), 6.0), "%s the source is placed" % label)
	await g.settle()
	var t0 := g.world.latest().sim_time
	var c0: Array = await _count(d)
	var before: DishBlob = await g.gather(d)
	await g.run_for(d, 600.0, 600.0)
	var t1 := g.world.latest().sim_time
	var c1: Array = await _count(d)
	var after: DishBlob = await g.gather(d)
	var units: float = c1[0] - c0[0]
	var want_units := 6.0 / 60.0 * (t1 - t0)
	var gain := ParityGame.total(after) - ParityGame.total(before)
	var kept: float = c1[1] - c0[1]
	var energy := units * Dish.NUTRIENT_ENERGY
	TestUtil.show(t1 - t0 >= 500.0 and absf(units - want_units) <= 1e-9 * want_units, "%s the source counts %.6f units over %.0f s (want %.6f)" % [label, units, t1 - t0, want_units])
	TestUtil.show(absf(gain + kept - energy) <= 1e-3 * energy and gain <= energy + 1e-3 * energy and energy - gain <= 60.0 * 6.0 / 60.0 * Dish.NUTRIENT_ENERGY + 1e-3 * energy, "%s the pool gains %.4f and the emitter keeps %.4f more: %.4f against %.4f emitted (%s)" % [label, gain, kept, gain + kept, energy, "clouds %d" % (after.clouds.size() / 8)])
	d.queue_free()
	await g.run_frames(3)
