extends SceneTree
## A dish's picture after it was out of the main view (Dish.park, unpark), on the real pool: while it was away the world published the
## other dish into the shared textures its view last drew from, so until the world publishes it again its view must draw nothing and
## answer no pick, never a pick on the other dish's bups. Windowed only:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/park_view_test.gd
##
## Expected values, written before the first run [derived from the textures' reuse rule: SimCore.TEXTURES (8) of a kind, each written again
## once the main side has used a newer one; 60 frames of x1 publish the other dish far more than 8 times]:
## U  Dish 1 (40 founders) in view, then parked; dish 2 (2,000 founders) in view for 60 running frames, then paused and parked; dish 1
##    back in view. Over the next 40 frames the pointer rests, in dish 1's coordinates, where dish 2's first bups lie (a place more than
##    100 µm from each of dish 1's bups): no answer of dish 1's view names a bup of dish 2, and none names a bup at all (dish 1 has none
##    there). Its view draws nothing until dish 1's own payload is taken (its payload's count is 0 or its row is dish 1's).
## O  The pointer then on one of dish 1's own bups finds it within 40 frames (the pick works after the return).

var g: ParityGame


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "park_view_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK park_view_test")
		return
	var a: Dish = await g.add(_spec(1, 40, 11))
	g.place = ParityGame.PLACE + Vector2(4.0e5, 0.0)  # (well apart from dish 1)
	var b: Dish = await g.add(_spec(2, 2000, 12))
	b.park()
	g.look_at(a, 0.5)
	TestUtil.show(await g.wait_picture(a), "U dish 1's picture is drawn")
	a.park()
	b.unpark()
	g.look_at(b, 0.5)
	TestUtil.show(await g.wait_picture(b), "U dish 2's picture is drawn")
	await g.run_frames(60, 1.0, false)
	await g.settle()
	var mine := await g.gather(a)
	var theirs := await g.gather(b)
	var spot := _spot(theirs, mine)
	b.park()
	a.unpark()
	g.look_at(a, 0.5)
	a.clear_hover()
	var foreign: Array = []
	var any_bup := 0
	var drew_stale := 0
	for f in 40:
		a.hover_at(a.global_position + spot, 4.0)
		await g.frame()
		var view := a.drawing.view
		if view == null:
			continue
		var answer: Dictionary = view.answer(true)
		var id := int(answer.get("id", -1))
		if id >= 0:
			any_bup += 1
			if GpuLayout.id_dish_number(id) != 1:
				foreign.append(id)
		var p := view.payload()
		if p.count > 0 and p.row != a.row:
			drew_stale += 1
	TestUtil.show(foreign.is_empty(), "U no answer names dish 2's bups after dish 1 comes back (%d did: %s)" % [foreign.size(), foreign.slice(0, 5)])
	TestUtil.show(any_bup == 0, "U no answer names a bup where dish 1 has none (%d did)" % any_bup)
	TestUtil.show(drew_stale == 0, "U the view draws no payload but dish 1's (%d frames did)" % drew_stale)
	var own := Vector2(mine.records.decode_float(GpuLayout.R_X * 4), mine.records.decode_float(GpuLayout.R_Y * 4))
	var own_id := GpuLayout.id_of(mine.records, 0)
	var found := false
	for f in 40:
		a.hover_at(a.global_position + own, 4.0)
		await g.frame()
		if a.hovered.bup == own_id:
			found = true
			break
	TestUtil.show(found, "O the pointer on dish 1's own bup %d finds it (hovered %d)" % [own_id, a.hovered.bup])
	TestUtil.finish(self, "OK park_view_test")


static func _spec(number: int, bups: int, seed_value: int) -> DishSpec:
	var s := Scenario.small(bups, 3000.0).seed(seed_value)
	var spec := DishSpec.new()
	spec.number = number
	spec.radius = s.radius
	spec.resolution = s.resolution
	spec.limit = s.limit
	spec.seed = s.seed_value
	spec.nutrient_density = s.nutrient_density
	spec.founders = s.founder_records(number)
	return spec


## A place (dish-local) of one of `theirs`' first bups (the payload's first texels, where a view that still drew `mine`'s count would look)
## more than 100 µm from every bup of `mine`.
static func _spot(theirs: DishBlob, mine: DishBlob) -> Vector2:
	for i in mini(mine.count(), theirs.count()):
		var o := i * GpuLayout.RECORD_BYTES
		var p := Vector2(theirs.records.decode_float(o + GpuLayout.R_X * 4), theirs.records.decode_float(o + GpuLayout.R_Y * 4))
		var clear := true
		for k in mine.count():
			var q := k * GpuLayout.RECORD_BYTES
			clear = clear and p.distance_to(Vector2(mine.records.decode_float(q + GpuLayout.R_X * 4), mine.records.decode_float(q + GpuLayout.R_Y * 4))) > 100.0
		if clear:
			return p
	return Vector2.ZERO
