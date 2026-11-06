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
## T  Textures made afresh are kept until the main side is done with them, then freed, never left behind (SimCore.textures_remade counts
##    them, retired_textures() the ones waiting). Dish 2 has 3,000 bups (two payload rows of 2,048) and a grid of 200 cells across, dish 1
##    40 bups and 100 cells, both with the medium shown: (1) once dish 1 is drawn (dish 2 was published while it was added) the payload has
##    been made afresh at least once (dish 2's two rows after dish 1's one); (2) the switch to dish 2 makes the haze and the steering map
##    afresh at least once more each (another grid size: how many times depends on how the views' requests fall between the publishes; the
##    payload's two rows hold dish 2 already), and after its 60 running frames none is waiting [derived: freed 2 x (frame_queue_size + 1)
##    = 6 frames after the main side tells of a newer publish of the kind, or of that many frames with no use at all]; (3) back on dish 1
##    the haze and the steering map are made afresh again (at least once each), and over the 80 or more paused frames after it (the main
##    side's frames free them while nothing is published) none is left waiting; dish 1's view then has a haze texture to draw (a valid RID).

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
	var b: Dish = await g.add(_spec(2, 3000, 12, 200))
	b.park()
	g.look_at(a, 0.5)
	TestUtil.show(await g.wait_picture(a), "U dish 1's picture is drawn")
	var retired_before: Array = await _retired()
	TestUtil.show(int(retired_before[0].get("payload", 0)) >= 1, "T the payload was made afresh for dish 2's two rows (%s)" % [retired_before[0]])
	a.park()
	b.unpark()
	g.look_at(b, 0.5)
	TestUtil.show(await g.wait_picture(b), "U dish 2's picture is drawn")
	await g.run_frames(60, 1.0, false)
	await g.settle()
	var retired_there: Array = await _retired()
	TestUtil.show(_made(retired_there, "haze") > _made(retired_before, "haze") and _made(retired_there, "steer") > _made(retired_before, "steer") and (retired_there[1] as Dictionary).is_empty(), "T the switch to dish 2 made the haze and the map afresh (%s, was %s); none waiting after 60 frames: %s" % [retired_there[0], retired_before[0], retired_there[1]])
	var mine := await g.gather(a)
	var theirs := await g.gather(b)
	var spot := _spot(theirs, mine)
	b.park()
	a.unpark()
	g.look_at(a, 0.5)
	a.clear_hover()
	var theirs_ids := {}
	for i in theirs.records.size() / GpuLayout.RECORD_BYTES:
		theirs_ids[GpuLayout.id_of(theirs.records, i)] = true
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
			if theirs_ids.has(id):
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
	await g.run_frames(40)
	var retired_back: Array = await _retired()
	var haze := a.drawing.view.texture("haze") if a.drawing.view != null else null
	TestUtil.show(_made(retired_back, "haze") > _made(retired_there, "haze") and _made(retired_back, "steer") > _made(retired_there, "steer") and (retired_back[1] as Dictionary).is_empty(), "T back on dish 1 the haze and the map were made afresh again (%s); none waiting after the paused frames: %s" % [retired_back[0], retired_back[1]])
	TestUtil.show(haze != null and haze.texture_rd_rid.is_valid(), "T dish 1's view has its haze to draw again (%s)" % [haze.texture_rd_rid if haze != null else "none"])
	TestUtil.finish(self, "OK park_view_test")


## The sets of textures of `kind` made afresh so far (SimCore.textures_remade).
static func _made(got: Array, kind: String) -> int:
	return int((got[0] as Dictionary).get(kind, 0))


## [SimCore.textures_remade, SimCore.retired_textures()] now.
func _retired() -> Array:
	var got: Array = await g.inspect(func(core: SimCore, _rows: Dictionary) -> Array: return [core.textures_remade.duplicate(true), core.retired_textures()])
	return got


static func _spec(number: int, bups: int, seed_value: int, resolution := 100) -> DishSpec:
	var s := Scenario.small(bups, 3000.0).seed(seed_value)
	s.resolution = resolution
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
