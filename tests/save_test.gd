extends SceneTree
## Run: godot --headless --path . -s tests/save_test.gd
## Round-trips a dish and goal tracker through JSON text, in memory only
## (never touches the real user:// save).

func _init() -> void:
	var a := Dish.new()
	root.add_child(a)
	a.rng.seed = 7
	a.strike()
	a.food_rate = 9.0
	var tracker := GoalTracker.new()
	for i in 600:
		a.step(1.0 / 30.0)
		tracker.update(a, 1.0 / 30.0)

	var text := JSON.stringify({"dish": a.to_dict(), "goals": tracker.to_dict()})
	var parsed: Dictionary = JSON.parse_string(text)

	var b := Dish.new()
	root.add_child(b)
	var ok := b.from_dict(parsed["dish"])
	var t2 := GoalTracker.new()
	t2.from_dict(parsed["goals"])

	var failures := []
	if not ok: failures.append("from_dict returned false")
	if a.cells.size() != b.cells.size(): failures.append("cell count %d vs %d" % [a.cells.size(), b.cells.size()])
	if a.food.size() != b.food.size(): failures.append("food count")
	if absf(a.time - b.time) > 0.001: failures.append("time")
	if a.food_rate != b.food_rate: failures.append("food_rate")
	for g in Genome.GENES:
		if absf(a.mean_gene(g) - b.mean_gene(g)) > 0.001: failures.append("mean %s" % g)
	if absf(a.mean_mutations() - b.mean_mutations()) > 0.001: failures.append("mutations")
	if a.history["pop"].size() != b.history["pop"].size(): failures.append("history length")
	if tracker.index != t2.index: failures.append("goal index")
	# A restored dish must keep running.
	for i in 90: b.step(1.0 / 30.0)
	if b.cells.is_empty(): failures.append("restored dish died immediately")
	# Garbage input is rejected without touching the dish.
	var c := Dish.new()
	root.add_child(c)
	if c.from_dict({"nope": 1}): failures.append("accepted garbage")

	print("cells=%d food=%d history=%d goal_index=%d" % [a.cells.size(), a.food.size(), a.history["pop"].size(), tracker.index])
	if failures.is_empty():
		print("SAVE ROUNDTRIP OK")
	else:
		print("FAILED: ", failures)
	quit(0 if failures.is_empty() else 1)
