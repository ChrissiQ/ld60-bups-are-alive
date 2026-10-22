extends SceneTree
## Run: godot --headless --path . -s tests/save_test.gd
## Round-trips a dish and goal tracker through JSON text, in memory only
## (never touches the real user:// save).

func _init() -> void:
	var a := Dish.new()
	root.add_child(a)
	a.set_seed(7)
	a.strike()
	a.feed_density = 9.0
	a.place_source(a.global_position + Vector2(50, 30), 4.0)
	var tracker := GoalTracker.new()
	for i in 240:  # two hours of simulation time
		a.advance(30.0)
		tracker.update(a, 30.0)

	var text := JSON.stringify({"dish": a.to_dict(), "goals": tracker.to_dict()})
	var parsed: Dictionary = JSON.parse_string(text)

	var b := Dish.new()
	root.add_child(b)
	var ok := b.from_dict(parsed["dish"])
	var t2 := GoalTracker.new()
	t2.from_dict(parsed["goals"])

	var failures := []
	if not ok: failures.append("from_dict returned false")
	if a.population() != b.population(): failures.append("cell count %d vs %d" % [a.population(), b.population()])
	if absf(a.time - b.time) > 0.001: failures.append("time")
	if a.feed_density != b.feed_density: failures.append("feed_density")
	var stats_a := a.population_stats()
	var stats_b := b.population_stats()
	for key: String in Genome.LABELED + ["mutations", "harm"]:
		if absf(stats_a[key] - stats_b[key]) > 0.001: failures.append("mean %s" % key)
	if b.sources.size() != 1 or absf(b.sources[0].rate - 4.0) > 0.001 or absf(b.sources[0].emitted - a.sources[0].emitted) > 0.01 or b.sources[0].pos.distance_to(a.sources[0].pos) > 0.01: failures.append("nutrient source")
	if absf(a.field.total() - b.field.total()) > 0.01 * maxf(a.field.total(), 1.0): failures.append("dissolved nutrient")
	var a_ids := a.bup_ids()
	var b_ids := b.bup_ids()
	for i in mini(a_ids.size(), b_ids.size()):
		if absf(a.bup_info(a_ids[i])["mass"] - b.bup_info(b_ids[i])["mass"]) > 0.0001: failures.append("body size of cell %d" % i)
	if a.history["pop"].size() != b.history["pop"].size(): failures.append("history length")
	if tracker.index != t2.index: failures.append("goal index")
	# A restored dish must keep running.
	b.advance(300.0)
	if b.population() == 0: failures.append("restored dish died immediately")
	# Garbage input is rejected without touching the dish.
	var c := Dish.new()
	root.add_child(c)
	if c.from_dict({"nope": 1}): failures.append("accepted garbage")

	print("cells=%d nutrient=%.0f history=%d goal_index=%d" % [a.population(), a.field.total() / Dish.NUTRIENT_ENERGY, a.history["pop"].size(), tracker.index])
	if failures.is_empty():
		print("SAVE ROUNDTRIP OK")
	else:
		print("FAILED: ", failures)
	quit(0 if failures.is_empty() else 1)
