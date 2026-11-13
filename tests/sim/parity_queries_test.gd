extends SceneTree
## The medium's readout under the pointer on the real pool: the fixture state (tools/gpu/golden/parity) as a dish of the game's world
## (ParityGame.fixture_dish), paused; the readout read as the select tool's Background mode reads it (Dish.nutrient_at, whose point the dish
## asks the world after). Windowed only:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_queries_test.gd
##
## Expected values, written before the first run [derived unless marked]:
## L  The pool holds the fixture word for word.
## Q  At the fixture's 50 medium points (medium_points.txt: field.read's concentration and gradient), Dish.nutrient_at's concentration is
##    the fixture's within 1e-4 relative (the bound; the probe sums the grid's bilinear read and the clouds in float32 where the
##    fixture was computed in doubles: the difference measured 1e-5), and its gradient's size within 1e-4 relative of the fixture's, or within 1e-12 /µm where
##    the fixture's is below 1e-8 (flat: a central difference of float rounding).
## Paused, each point's answer is waited for with ParityGame.answer_now.

var g: ParityGame


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_queries_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_queries_test")
		return
	g.place = Vector2.ZERO
	var made: Array = await g.fixture_dish(1)
	var dish: Dish = made[0]
	TestUtil.show(made[1] == "", "L the pool holds the fixture word for word%s" % ("" if made[1] == "" else ": " + made[1]))
	g.look_at(dish, 0.25)
	var re := RegEx.create_from_string("point (Vector2\\([^)]*\\)) read (Vector3\\([^)]*\\))")
	var points := 0
	var right := 0
	var worst_c := 0.0
	var worst_g := 0.0
	for line in ParityGame.text("medium_points.txt").split("\n"):
		var m := re.search(line)
		if m == null:
			continue
		points += 1
		var p: Vector2 = str_to_var(m.get_string(1))
		var want: Vector3 = str_to_var(m.get_string(2))
		dish.nutrient_at(g.place + p)
		await g.answer_now()
		var got := dish.nutrient_at(g.place + p)
		var c := float(got["concentration"])
		var size := (got["gradient"] as Vector2).length()
		var want_size := Vector2(want.y, want.z).length()
		var off_c := absf(c - want.x) / maxf(absf(want.x), 1e-30)
		var flat := want_size < 1e-8
		var off_g := absf(size - want_size) if flat else absf(size - want_size) / want_size
		worst_c = maxf(worst_c, off_c)
		worst_g = maxf(worst_g, off_g)
		if off_c <= 1e-4 and ((flat and off_g <= 1e-12) or (not flat and off_g <= 1e-4)):
			right += 1
		elif points - right <= 5:
			print("     point %s: concentration %s (the fixture %s), gradient %s (the fixture %s)" % [p, c, want.x, got["gradient"], Vector2(want.y, want.z)])
	TestUtil.show(points == 50 and right == 50, "Q the readout at the fixture's %d points: %d within bounds; concentration off by at most %s relative, the gradient's size by %s" % [points, right, String.num_scientific(worst_c), String.num_scientific(worst_g)])
	TestUtil.finish(self, "OK parity_queries_test")
