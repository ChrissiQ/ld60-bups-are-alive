extends SceneTree
## The nutrient haze and the steering arcs and map on the real pool: the fixture state (tools/gpu/golden/parity) as a dish of the
## game's world (ParityGame.fixture_dish), paused, a Dish node drawing it; the pictures read back from the textures the dish draws (the
## world's published haze and steering map, as the main device imported them), the steering read as the selected bup's panel reads it.
## Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_draw_test.gd
##
## Expected values, written before the first run [derived unless marked]:
## L  The pool holds the fixture word for word.
## H  The haze the dish draws (the medium layer shown; Dish's look: DETECTION_FLOOR, 0.5 x 255 / sqrt(10 HALF_SATURATION), 0.45 x 255)
##    equals the fixture's haze_bytes: alpha within 1 in every cell, RGB equal wherever either alpha is above 0 (the bound: the float
##    view against the fixture's doubles moves a truncation by one at most).
## M  With bup 4, 10001 or 20000 selected (the medium hidden, so the map is what is drawn), the steering map the dish draws equals the
##    fixture's steer_<id>: alpha within STEER_ALPHA_TOLERANCE, RGB equal where alpha > 0. The fixture's maps were made with a different motion
##    table from the one the game ships, and the chance of steering (the alpha) is read from the table, so the alpha differs by the two
##    tables' difference (11 at most, measured).
## S  The 40 fixture bups of queries_info.txt, each selected in turn: Dish.bup_steering (the tracked answer's way and chance) within 1e-5
##    of the fixture's bup_steering in each of x, y and the chance.
## Paused, each answer is waited for with ParityGame.answer_now.

const STEER_ALPHA_TOLERANCE := 12  ## alpha units of 255: the measured worst 11 of the table difference, and one more

var g: ParityGame
var dish: Dish


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_draw_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_draw_test")
		return
	g.place = Vector2.ZERO
	var made: Array = await g.fixture_dish(1)
	dish = made[0]
	TestUtil.show(made[1] == "", "L the pool holds the fixture word for word%s" % ("" if made[1] == "" else ": " + made[1]))
	g.look_at(dish, 0.25)
	await g.wait_picture(dish)
	await g.answer_now()
	await _haze()
	await _steer_maps()
	await _steering()
	TestUtil.finish(self, "OK parity_draw_test")


## The bytes of the picture of `kind` the dish draws now, read on the main device ("" when there is none yet).
func _picture(kind: String) -> PackedByteArray:
	var tex: Texture2DRD = dish.drawing.view.texture(kind) if dish.drawing.view != null else null
	if tex == null or not tex.texture_rd_rid.is_valid():
		return PackedByteArray()
	var out := [PackedByteArray()]
	RenderingServer.call_on_render_thread(func() -> void: out[0] = RenderingServer.get_rendering_device().texture_get_data(tex.texture_rd_rid, 0))
	return out[0]


## Frames until the dish has been offered the newest publish of the field's pictures (haze and map), then two more (the import used).
func _newest_field() -> void:
	await g.wait_until(func() -> bool:
		var fv := g.world.latest().field_view
		return fv != null and dish.drawing._offered_field == fv.seq and dish.drawing._offered_steer == fv.steer_seq, 120)
	await g.run_frames(2)


func _compare(what: String, got: PackedByteArray, want: PackedByteArray, tolerance := 1) -> void:
	var cells := want.size() / 4
	var worst := 0
	var rgb_bad := 0
	var lit := 0
	for c in mini(cells, got.size() / 4):
		var ga := got[c * 4 + 3]
		var wa := want[c * 4 + 3]
		worst = maxi(worst, absi(ga - wa))
		lit += 1 if wa > 0 else 0
		if (ga > 0 or wa > 0) and (got[c * 4] != want[c * 4] or got[c * 4 + 1] != want[c * 4 + 1] or got[c * 4 + 2] != want[c * 4 + 2]):
			rgb_bad += 1
	TestUtil.show(got.size() == want.size() and worst <= tolerance and rgb_bad == 0 and lit > 0, "%s: %d bytes (the fixture %d), alpha off by at most %d, RGB differs in %d cells, %d cells lit" % [what, got.size(), want.size(), worst, rgb_bad, lit])


func _haze() -> void:
	await _newest_field()
	_compare("H the haze the dish draws against the fixture's haze_bytes", _picture("haze"), ParityGame.gz("haze_bytes.bin.gz"))


func _steer_maps() -> void:
	dish.show_layer(Dish.Layer.MEDIUM, false)
	for id: int in [4, 10001, 20000]:
		dish.selected.bup = ParityGame.pooled_id(dish.number, id)
		await g.answer_now()
		await g.answer_now()  # (the first brings the bup's record; the map for its speed and sense range is published after the view that asks it)
		await _newest_field()
		var info := dish.bup_info(dish.selected.bup)
		print("     bup %d: speed %s, sense range %s (the map's)" % [id, info.get("speed"), info.get("sense_range")])
		_compare("M the steering map of bup %d against the fixture's" % id, _picture("steer"), ParityGame.gz("steer_%d.bin.gz" % id), STEER_ALPHA_TOLERANCE)
	dish.show_layer(Dish.Layer.MEDIUM, true)


func _steering() -> void:
	var re := RegEx.create_from_string("^id (\\d+) index (\\d+)$")
	var id := -1
	var bups := 0
	var right := 0
	var worst := 0.0
	for line in ParityGame.text("queries_info.txt").split("\n"):
		var m := re.search(line)
		if m != null:
			id = int(m.get_string(1))
			continue
		var s := line.strip_edges()
		if id < 0 or not s.begins_with("steering Vector3("):
			continue
		var want: Vector3 = str_to_var(s.get_slice(" radius2", 0).trim_prefix("steering "))
		var pooled := ParityGame.pooled_id(dish.number, id)
		dish.selected.bup = pooled
		await g.answer_now()
		var got := dish.bup_steering(pooled)
		var tracked := ((dish._answers.get("steer", {}) as Dictionary).has(pooled))
		var off := maxf(absf(got.x - want.x), maxf(absf(got.y - want.y), absf(got.z - want.z)))
		worst = maxf(worst, off)
		bups += 1
		if tracked and off <= 1e-5:
			right += 1
		elif bups - right <= 5:
			print("     bup %d: steering %s (the fixture %s, answered %s)" % [id, got, want, tracked])
		id = -1
	TestUtil.show(bups == 40 and right == 40, "S the steering of the fixture's %d bups, each selected: %d within 1e-5 (worst %s)" % [bups, right, String.num_scientific(worst)])
