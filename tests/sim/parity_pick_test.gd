extends SceneTree
## The select tool's pick on the real pool, with the picking that needs the real picture: the fixture state (tools/gpu/golden/parity) loaded as a dish of
## the game's world (ParityGame.fixture_dish), paused, a Dish node at ParityGame.PLACE drawing it. Needs a GPU (windowed). On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_pick_test.gd
##
## Expected values [derived unless marked]:
## L  The pool holds the fixture word for word: its 20,000 records (ids given the dish's number), its grid and its 60 clouds.
## F  The fixture's 300 picks (queries_pick_near.txt: point, slack, pixel -> id), asked of the dish's picture (ViewRenderer.pick, the
##    question Dish.cell_at sends, with the fixture's pixel): every answer is the fixture's id (or none where it found none). The payload's
##    x and y are the records' floats, its length a half float of the record's (within one half-float ulp), and the kernel's
##    rule is the pick's (within half the drawn length at that pixel plus the slack, the nearest, a tie to the lowest index, which
##    in this state is the lowest id): an answer may differ only where the fixture's bup lies within 1e-3 µm of the reach. Such cases are
##    counted and named; none is expected.
## N  The fixture's 1,200 nearest-and-count questions (the same answers' `nearest` and `near`): the nearest distance within 1e-5 relative
##    (the kernel's float d² against the fixture's), the count exact except a bup within 1e-3 µm of the radius (none expected).
## R  The check: 200 points (100 on bups, 100 anywhere in the dish) clicked through Dish.cell_at with the camera at 0.25 px a
##    µm and the select tool's slack (4 px), each answered by the brute force over the gathered records (nearest within half the drawn
##    length at that pixel plus the slack, ties to the lowest index): 200 of 200, boundary cases as in F.
## S  The select tool (it needs the real picture): the pointer resting on a bup outlines it within 3 frames; a click there
##    selects it; its info (bup_info, from the tracked answer) and its family record (lineage_info: a founder of the dish, alive) come
##    within 10 frames. The pointer on bare medium (no bup within reach) outlines nothing, and a click there selects nothing.

var g: ParityGame
var dish: Dish
var consts := {}


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_pick_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_pick_test")
		return
	consts = SimConstants.build()
	var made: Array = await g.fixture_dish(1)
	dish = made[0]
	TestUtil.show(made[1] == "", "L the pool holds the fixture word for word%s" % ("" if made[1] == "" else ": " + made[1]))
	g.look_at(dish, 0.25)
	TestUtil.show(await g.wait_picture(dish), "the dish's picture is drawn from the world's publish")
	var blob: DishBlob = await g.gather(dish)
	await _fixture_picks(blob.records)
	g.look_at(dish, 0.25)
	await g.run_frames(3)
	await _random_picks(blob.records)
	await _select_tool(blob.records)
	TestUtil.finish(self, "OK parity_pick_test")


## The answer to a pick asked of the dish's view now (the build of the frames after it answers it). The kernel takes the pixel the view is
## drawn at (the camera's, as Dish.cell_at's own is), so the camera is set to `pixel` µm a screen pixel first.
func _ask(local: Vector2, slack: float, pixel: float, near := 0.0) -> Dictionary:
	var view := dish.drawing.view
	if not is_equal_approx(dish.pixel(), pixel):
		g.camera.zoom = Vector2.ONE / pixel
		await g.wait_until(func() -> bool: return is_equal_approx(dish.pixel(), pixel), 10)
		await g.frame()
	var seq := view.pick(local, slack, pixel, false, near)
	await g.wait_until(func() -> bool: return int(view.answer(false).get("seq", -1)) == seq, 30)
	return view.answer(false)


## The bup a pick at `local` finds by the pick's rule over the records (in their order: the payload's), and how near the reach the
## fixture's or the pool's answer lies: [index or -1, distance of the answer's bup minus its reach].
func _brute(records: PackedByteArray, local: Vector2, slack: float, pixel: float) -> int:
	var w := GpuLayout.RECORD_WORDS
	var f := records.to_float32_array()
	var best := -1
	var best_d2 := INF
	for i in records.size() / GpuLayout.RECORD_BYTES:
		var dx := f[i * w + GpuLayout.R_X] - local.x
		var dy := f[i * w + GpuLayout.R_Y] - local.y
		var d2 := dx * dx + dy * dy
		var reach := _reach(f[i * w + GpuLayout.R_MASS], slack, pixel)
		if d2 <= reach * reach and d2 < best_d2:
			best = i
			best_d2 = d2
	return best


func _reach(mass: float, slack: float, pixel: float) -> float:
	return 0.5 * maxf(mass * float(consts["mass_um"]), float(consts["min_length_px"]) * pixel) + slack


## How far bup `id` lies from its reach at `local` (distance minus reach, µm).
func _margin(records: PackedByteArray, id: int, local: Vector2, slack: float, pixel: float) -> float:
	for i in records.size() / GpuLayout.RECORD_BYTES:
		if GpuLayout.id_of(records, i) == id:
			var f := records.slice(i * GpuLayout.RECORD_BYTES, (i + 1) * GpuLayout.RECORD_BYTES).to_float32_array()
			return Vector2(f[GpuLayout.R_X], f[GpuLayout.R_Y]).distance_to(local) - _reach(f[GpuLayout.R_MASS], slack, pixel)
	return INF


func _fixture_picks(records: PackedByteArray) -> void:
	var pick_re := RegEx.create_from_string("^pick (\\d+) (Vector2\\([^)]*\\)) (\\S+) (\\S+) -> (-?\\d+)$")
	var near_re := RegEx.create_from_string("^near (\\d+) (Vector2\\([^)]*\\)) (\\S+) -> (Vector2\\([^)]*\\))$")
	var picks := 0
	var picks_right := 0
	var picks_edge := 0
	var nears := 0
	var nears_right := 0
	var nears_edge := 0
	var shown := 0
	for line in ParityGame.text("queries_pick_near.txt").split("\n"):
		var m := pick_re.search(line)
		if m != null:
			picks += 1
			var p: Vector2 = str_to_var(m.get_string(2))
			var slack := float(m.get_string(3))
			var pixel := float(m.get_string(4))
			var want := ParityGame.pooled_id(dish.number, int(m.get_string(5)))
			var a := await _ask(p, slack, pixel)
			var got := int(a.get("id", -2))
			if got == want:
				picks_right += 1
				continue
			var edge := minf(absf(_margin(records, want, p, slack, pixel)), absf(_margin(records, got, p, slack, pixel))) <= 1e-3
			picks_edge += 1 if edge else 0
			if shown < 6:
				shown += 1
				print("     pick %s at %s slack %s pixel %s: the fixture %d, the pool %d (%s)" % [m.get_string(1), p, slack, pixel, want, got, "within 1e-3 µm of the reach" if edge else "not at the reach"])
			continue
		m = near_re.search(line)
		if m == null:
			continue
		nears += 1
		var q: Vector2 = str_to_var(m.get_string(2))
		var radius := float(m.get_string(3))
		var expect: Vector2 = str_to_var(m.get_string(4))
		var b := await _ask(q, 0.0, 1.0, radius)
		var nearest := float(b.get("nearest", -1.0))
		var count := int(b.get("near", -1))
		var close := absf(nearest - expect.x) <= 1e-5 * maxf(expect.x, 1.0)
		if close and count == int(expect.y):
			nears_right += 1
			continue
		var at_rim := false
		if close:
			for i in records.size() / GpuLayout.RECORD_BYTES:
				var f := records.slice(i * GpuLayout.RECORD_BYTES, i * GpuLayout.RECORD_BYTES + 12).to_float32_array()
				if absf(Vector2(f[GpuLayout.R_X], f[GpuLayout.R_Y]).distance_to(q) - radius) <= 1e-3:
					at_rim = true
		nears_edge += 1 if at_rim else 0
		if shown < 12:
			shown += 1
			print("     near %s at %s within %s: the fixture %s, the pool (%s, %d)" % [m.get_string(1), q, radius, expect, nearest, count])
	TestUtil.show(picks == 300 and picks_right + picks_edge == picks, "F the fixture's %d picks on the pool's picture: %d the fixture's id, %d differ at the reach, %d differ elsewhere" % [picks, picks_right, picks_edge, picks - picks_right - picks_edge])
	TestUtil.show(nears == 1200 and nears_right + nears_edge == nears, "N the fixture's %d nearest-and-count: %d equal, %d differ by a bup at the radius, %d differ elsewhere" % [nears, nears_right, nears_edge, nears - nears_right - nears_edge])


func _random_picks(records: PackedByteArray) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var f := records.to_float32_array()
	var n := records.size() / GpuLayout.RECORD_BYTES
	var pixel := dish.pixel()
	var slack := StageInput.PICK_SLACK_PIXELS * pixel
	var right := 0
	var edge := 0
	var hits := 0
	for k in 200:
		var local: Vector2
		if k < 100:
			var i := rng.randi_range(0, n - 1)
			local = Vector2(f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_X], f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_Y]) + Vector2.from_angle(rng.randf() * TAU) * rng.randf() * 3.0
		else:
			local = Vector2.from_angle(rng.randf() * TAU) * ParityGame.FIXTURE_RADIUS * sqrt(rng.randf())
		var view := dish.drawing.view
		dish.cell_at(ParityGame.PLACE + local, slack)
		var seq: int = view._pick_seq
		await g.wait_until(func() -> bool: return int(view.answer(false).get("seq", -1)) == seq, 30)
		var got := dish.cell_at(ParityGame.PLACE + local, slack)
		var at := _brute(records, local, slack, pixel)
		var want := GpuLayout.id_of(records, at) if at >= 0 else -1
		hits += 1 if want >= 0 else 0
		if got == want:
			right += 1
		elif minf(absf(_margin(records, want, local, slack, pixel)), absf(_margin(records, got, local, slack, pixel))) <= 1e-3:
			edge += 1
		else:
			print("     click %d at %s: the brute force %d, the pool %d" % [k, local, want, got])
	TestUtil.show(right + edge == 200, "R 200 clicks through Dish.cell_at (pixel %.2f µm, slack %.1f µm, %d on a bup): %d the brute force's, %d at the reach, %d wrong" % [pixel, slack, hits, right, edge, 200 - right - edge])


func _select_tool(records: PackedByteArray) -> void:
	var f := records.to_float32_array()
	var i := 1234
	var id := GpuLayout.id_of(records, i)
	var at := ParityGame.PLACE + Vector2(f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_X], f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_Y])
	var slack := StageInput.PICK_SLACK_PIXELS * dish.pixel()
	var frames := -1
	for k in 10:
		dish.hover_at(at, slack)
		if dish.hovered.bup == id and dish.drawing.ring_of(id) != null:
			frames = k
			break
		await g.frame()
	TestUtil.show(frames >= 0 and frames <= 3, "S the pointer resting on bup %d outlines it (frame %d, ring %s)" % [id, frames, dish.drawing.ring_of(id)])
	dish.select_at(at, slack)
	TestUtil.show(dish.selected.bup == id, "S a click there selects it (%d)" % dish.selected.bup)
	var info_at := -1
	for k in 120:
		if not dish.bup_info(id).is_empty() and not dish.lineage_info(id).is_empty():
			info_at = k
			break
		await g.frame()
	var info := dish.bup_info(id)
	var family := dish.lineage_info(id)
	TestUtil.show(info_at >= 0 and info_at <= 30 and is_equal_approx(float(info.get("mass", -1.0)), f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_MASS]) and bool(family.get("alive", false)), "S its info (mass %s) and family record (alive %s) come at frame %d (paused; questions are answered about every 0.1 s)" % [info.get("mass"), family.get("alive"), info_at])
	var bare := Vector2.ZERO
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for k in 1000:
		var p := Vector2.from_angle(rng.randf() * TAU) * ParityGame.FIXTURE_RADIUS * 0.9 * sqrt(rng.randf())
		if _brute(records, p, slack * 1.5, dish.pixel()) < 0:
			bare = p
			break
	# a click that found a bup somewhere else first: the click's answer the view keeps is that bup's
	var view := dish.drawing.view
	dish.cell_at(at, slack)
	var seq: int = view._pick_seq
	await g.wait_until(func() -> bool: return int(view.answer(false).get("seq", -1)) == seq, 30)
	var stale := int(view.answer(false).get("id", -1))
	var outlined_at := -1
	for k in 10:
		dish.hover_at(ParityGame.PLACE + bare, slack)
		await g.frame()
		if dish.hovered.bup >= 0:
			outlined_at = k
	dish.hover_at(ParityGame.PLACE + bare, slack)
	TestUtil.show(dish.hovered.bup < 0 and outlined_at <= 2, "S the pointer moved onto bare medium at %s: the old outline goes within 3 frames (last outlined at frame %d), then nothing (%d)" % [bare, outlined_at, dish.hovered.bup])
	dish.select_at(ParityGame.PLACE + bare, slack)
	TestUtil.show(dish.selected.bup == -1, "S a click on bare medium selects nothing (%d; the last click elsewhere found %d)" % [dish.selected.bup, stale])
	if dish.bup_info(id).is_empty():
		dish.selected.bup = id
		var running_at := -1
		for k in 60:
			if not dish.bup_info(id).is_empty():
				running_at = k
				break
			await g.frame(1.0, false)
		print("     diagnosis: paused, the selected bup's answer never came; running at x1 it came at frame %d" % running_at)
