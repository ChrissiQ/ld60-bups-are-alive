extends SceneTree
## The hover ring shows within 3 frames of the pointer stopping, on the real pool at x10,000: a 100,000-bup dish (the
## goal-sized dish: 45 mm, filled at once) at ParityGame.PLACE, drawn by its Dish at the stage's fit, the pointer moved to a new place and
## resting there, the select tool's hover asked every frame as Main asks it. Windowed only:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_pick_latency_test.gd
##
## Expected values, written before the first run [derived unless marked]:
## R  50 times: the pointer jumps to a random place within half the dish's radius (where bups are about 250 µm apart, so one lies within
##    the slack, 4 px of about 150 µm) and rests; from the frame it moved, the ring is drawn round a bup the hover found there (an answer to
##    a pick asked at the new place, ViewRenderer.answer(true), and DishDrawing.ring_of of its id) within 3 frames, every time: the pick is
##    asked in the frame's build (Dish._process after the hover) and read back a frame or two later (ring <= 3 frames).
##    A trial whose answer finds no bup there is not counted (none expected; their number is printed).

const BUPS := 100000
const TRIALS := 50

var g: ParityGame
var dish: Dish


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_pick_latency_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_pick_latency_test")
		return
	var gates: GDScript = load("res://tests/sim/perf_gates_test.gd")
	var spec: DishSpec = gates.filled_spec(BUPS, 45000.0)
	dish = await g.add(spec)
	var view_size := g.camera.get_viewport_rect().size
	g.look_at(dish, minf(view_size.x, view_size.y) * 0.5 / dish.radius)
	await g.wait_picture(dish)
	for k in 120:
		await g.frame(10000.0, false)
	var rng := RandomNumberGenerator.new()
	rng.seed = 16
	var latencies: Array = []
	var empty := 0
	var slack := StageInput.PICK_SLACK_PIXELS * dish.pixel()
	for t in TRIALS:
		var at := dish.global_position + Vector2.from_angle(rng.randf() * TAU) * 0.5 * dish.radius * sqrt(rng.randf())
		var view := dish.drawing.view
		var first_seq: int = view._pick_seq + 1
		var shown := -1
		for f in 30:
			dish.hover_at(at, slack)
			await g.frame(10000.0, false)
			var a: Dictionary = view.answer(true)
			if int(a.get("seq", -1)) < first_seq:
				continue
			if int(a["id"]) < 0:
				shown = -2
				break
			if dish.hovered.bup == int(a["id"]) and dish.drawing.ring_of(dish.hovered.bup) != null:
				shown = f + 1
				break
		if shown == -2:
			empty += 1
		else:
			latencies.append(shown)
		for f in 5:
			await g.frame(10000.0, false)
	var worst: int = latencies.max() if not latencies.is_empty() else -1
	var late := latencies.filter(func(l: int) -> bool: return l < 0 or l > 3).size()
	var snap := g.world.latest()
	print("     x10,000: achieved x%.0f, %d bups; ring latencies (frames) %s" % [snap.achieved_speed, dish.population(), latencies])
	TestUtil.show(latencies.size() + empty == TRIALS and latencies.size() >= TRIALS - 2 and late == 0, "R the hover ring within 3 frames of the pointer stopping: %d trials, worst %d frames, %d late, %d with no bup under the pointer" % [latencies.size(), worst, late, empty])
	TestUtil.finish(self, "OK parity_pick_latency_test")
