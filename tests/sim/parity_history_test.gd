extends SceneTree
## The history's samples and their times on the real pool, and the history after a dish dies out: a
## struck dish at ParityGame.PLACE run at x10,000 and x1,000, its samples as the snapshots carry them and as its DishHistory keeps them;
## then every bup taken out with the pipette, the dish run on empty. Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_history_test.gd
##
## Expected values [derived unless marked]:
## The world's clock starts at 0 (a fresh run) and the dish is struck before it moves.
## T  At x10,000 a step is MAX_STEP, 20 s (Governor: min(20, speed / 120)), so the steps end on multiples of 20 s and each multiple of
##    DishHistory.INTERVAL (120 s) is a step's end: over about 2 sim-hours every sample's time is k x 120 s exactly (k = 1, 2, 3 ... with
##    none missing or twice), whatever the iterations' sizes, and the dish's history holds one sample for each.
## S  At x1,000 a step is 8.33 s: every sample is taken at the end of the step that crosses its multiple of 120 s, within a step after it
##    (in [k x 120, k x 120 + 8.34) s; a sum of 8.33 s steps may land a hair short of the multiple, which DishHistory.boundary_of counts
##    as crossing it within Governor.OWED_TOLERANCE of the interval), still one for each k.
## X  Every bup pipetted out (the dish's count 0, `extinct` emitted once): the samples go on every 120 s, pop 0, the traits held as they
##    last were (DishHistory.record), for 20 more minutes.

var g: ParityGame
var times: Array = []  ## every sample time of the dish the snapshots carried, in order
var dish: Dish


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_history_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_history_test")
		return
	var start := StartConditions.new()
	start.dish_radius = 10000.0
	start.bups = 200
	start.bup_limit = 20000
	start.nutrient_density = 32.0
	dish = await g.strike(start, 5)
	TestUtil.show(dish.time == 0.0, "the world's clock is at 0 when the dish is struck (%s)" % dish.time)
	g.look_at(dish, 0.05)
	g.world.snapshot_changed.connect(_on_snapshot)
	await g.run_for(dish, 7200.0, 10000.0)
	_check_exact("T x10,000", 0)
	var first_slow := times.size()
	await g.run_for(dish, 3600.0, 1000.0)
	_check_within("S x1,000", first_slow, 1000.0 / Governor.STEPS_PER_SECOND)
	await _extinct()
	TestUtil.finish(self, "OK parity_history_test")


func _on_snapshot(snap: Snapshot) -> void:
	if dish == null or dish.row < 0:
		return
	for s: Dictionary in snap.history.get(dish.row, []):
		if times.is_empty() or float(s["time"]) > float(times[-1]):
			times.append(float(s["time"]))


func _check_exact(label: String, from: int) -> void:
	var bad := 0
	for i in range(from, times.size()):
		if times[i] != (i + 1) * DishHistory.INTERVAL:
			bad += 1
			if bad <= 3:
				print("     sample %d at %s s (want %s)" % [i, times[i], (i + 1) * DishHistory.INTERVAL])
	TestUtil.show(times.size() - from >= 55 and bad == 0 and dish.history.fine["pop"].size() == times.size(), "%s: %d samples, %d not at k x 120 s exactly; the history holds %d" % [label, times.size() - from, bad, dish.history.fine["pop"].size()])


func _check_within(label: String, from: int, step: float) -> void:
	var bad := 0
	for i in range(from, times.size()):
		var due := (i + 1) * DishHistory.INTERVAL
		if times[i] < due - Governor.OWED_TOLERANCE * DishHistory.INTERVAL or times[i] >= due + step + 1e-6:
			bad += 1
			if bad <= 3:
				print("     sample %d at %s s (due %s, a step %.3f s)" % [i, times[i], due, step])
	TestUtil.show(times.size() - from >= 25 and bad == 0 and dish.history.fine["pop"].size() == times.size(), "%s: %d samples, %d not within a step after their multiple of 120 s; the history holds %d" % [label, times.size() - from, bad, dish.history.fine["pop"].size()])


func _extinct() -> void:
	var signalled := [0]
	dish.extinct.connect(func() -> void: signalled[0] += 1)
	var reply := dish.pipette(dish.global_position, dish.radius)
	var got: Variant = await g.reply_value(reply)
	await g.settle()
	TestUtil.show(got is Dictionary and int(got["moved"]) > 0 and dish.population() == 0, "X the pipette took every bup (%s moved; %d left)" % [got.get("moved") if got is Dictionary else got, dish.population()])
	var held: Dictionary = {}
	for series in DishHistory.TRAITS:
		held[series] = dish.history.fine[series][-1]
	var before := times.size()
	await g.run_for(dish, 1200.0, 10000.0)
	var empty_ok := times.size() - before >= 9
	for i in range(before, times.size()):
		var due := (i + 1) * DishHistory.INTERVAL
		empty_ok = empty_ok and times[i] >= due and times[i] < due + Dish.MAX_STEP + 1e-6
	var fine := dish.history.fine
	var n: int = fine["pop"].size()
	for k in range(n - (times.size() - before), n):
		if fine["pop"][k] != 0:
			empty_ok = false
		for series in DishHistory.TRAITS:
			if fine[series][k] != held[series]:
				empty_ok = false
	TestUtil.show(empty_ok and signalled[0] == 1, "X empty, the samples go on (%d more, the last at %s s), pop 0, the traits as they were; extinct signalled %d time(s)" % [times.size() - before, times[-1], signalled[0]])
