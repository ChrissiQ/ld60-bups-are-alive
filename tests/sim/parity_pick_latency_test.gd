extends SceneTree
## The hover ring shows within 3 frames of the pointer stopping, on the real pool at x10,000: a 100,000-bup dish (the
## goal-sized dish: 45 mm, filled at once) at ParityGame.PLACE, drawn by its Dish at the stage's fit, the pointer moved to a new place and
## resting there, the select tool's hover asked every frame as Main asks it (StageInput.update_pointer: clear_hover, then hover_at, before
## the dish's own frame). Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_pick_latency_test.gd
##
## Expected values [derived unless marked]:
## R  50 times: the pointer jumps to a random place within half the dish's radius (where bups are about 250 µm apart, so one lies within
##    the slack, 4 px of about 150 µm) and rests. The latency is the frames from the one the pointer moved in to the one whose hover
##    outlines a bup an answer to a question asked at the new place found (DishDrawing.pick takes only such an answer: until it comes the
##    hover outlines nothing), with its ring known (DishDrawing.ring_of): that frame draws the ring. The pick is asked in the move's frame
##    (the view's build), read back with buffer_get_data_async, whose callback comes as the main device begins the frame that reuses the
##    build's frame slot, frame_queue_size (2) frames later, after that frame's process: the hover takes it the frame after, 3 frames
##    after the move, every time (the bound: <= 3). The readback lag of each answer (ViewRenderer's frames drawn from asked to answered)
##    is printed beside it: 2 expected.
##    [measured, M1 Pro, Metal, 120 Hz: 2 frames in all 50 trials, readback lag 1 frame drawn: the callback comes in the next frame drawn,
##    not frame_queue_size frames later.]
##    Handed over as bytes (ViewRenderer.cpu_handover), the payload carries no ids: the answer names the picked texel and the simulation
##    gives its bup's id (WorldClient.ids_at), which it does between two of its iterations: up to an iteration more, Governor.T_ITER_MS of
##    steps and a publish's read (an allowance of 10 ms), and the hover takes the id a frame after. The bound there is 3 frames + 1 + that
##    time in frames of the run's mean length.
##    A trial whose answer finds no bup there is not counted (none expected; their number is printed).
##    At x10,000 a bup moves hundreds of µm a frame, so the bup found is not the one under the pointer a frame later: the ring follows the
##    bup found (its place in the payload drawn once the dish asks after it), and two answers a frame apart name different bups. The
##    latency is to a ring round a bup found at the new place, not to two answers agreeing.

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
	var lags: Array = []
	var empty := 0
	var slack := StageInput.PICK_SLACK_PIXELS * dish.pixel()
	var last := Vector2.INF
	var started := Time.get_ticks_usec()
	var frames_at := Engine.get_process_frames()
	for t in TRIALS:
		var at := dish.global_position + Vector2.from_angle(rng.randf() * TAU) * 0.5 * dish.radius * sqrt(rng.randf())
		while last.is_finite() and at.distance_to(last) <= 10.0 * Dish.HOVER_CLICK_PIXELS * dish.pixel():
			at = dish.global_position + Vector2.from_angle(rng.randf() * TAU) * 0.5 * dish.radius * sqrt(rng.randf())
		last = at
		var view := dish.drawing.view
		var moved := Engine.get_process_frames()
		var shown := -1
		for f in 30:
			dish.clear_hover()
			dish.hover_at(at, slack)
			if not dish._hover_waiting:
				var a: Dictionary = view.answer(true)
				lags.append(int(a.get("frame", -1)) - int(a.get("asked", 0)))
				if dish.hovered.bup < 0:
					shown = -2
				elif dish.drawing.ring_of(dish.hovered.bup) != null:
					shown = Engine.get_process_frames() - moved
				break
			await g.frame(10000.0, false)
		if shown == -2:
			empty += 1
		else:
			latencies.append(shown)
		for f in 5:
			await g.frame(10000.0, false)
	var worst: int = latencies.max() if not latencies.is_empty() else -1
	var frame_ms := (Time.get_ticks_usec() - started) / 1000.0 / maxi(1, Engine.get_process_frames() - frames_at)
	var bound := 3 + (1 + ceili((Governor.T_ITER_MS + 10.0) / frame_ms) if ViewRenderer.cpu_handover() else 0)
	var late := latencies.filter(func(l: int) -> bool: return l < 0 or l > bound).size()
	var snap := g.world.latest()
	print("     x10,000: achieved x%.0f, %d bups; ring latencies (frames) %s; readback lags (frames drawn, asked to answered) %s" % [snap.achieved_speed, dish.population(), latencies, lags])
	TestUtil.show(latencies.size() + empty == TRIALS and latencies.size() >= TRIALS - 2 and late == 0, "R the hover ring within %d frames of the pointer stopping (frames of %.1f ms): %d trials, worst %d frames, %d late, %d with no bup under the pointer" % [bound, frame_ms, latencies.size(), worst, late, empty])
	TestUtil.finish(self, "OK parity_pick_latency_test")
