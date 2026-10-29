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

	var failures := TestUtil.failures
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
	if a.history.fine["pop"].size() != b.history.fine["pop"].size(): failures.append("history length")
	if tracker.index != t2.index: failures.append("goal index")
	# A restored dish must keep running.
	b.advance(300.0)
	if b.population() == 0: failures.append("restored dish died immediately")
	# Garbage input is rejected without touching the dish.
	var c := Dish.new()
	root.add_child(c)
	if c.from_dict({"nope": 1}): failures.append("accepted garbage")
	# A save that cannot be read is refused without an error, and leaves the dish as it was: the bups in the old format (a list of
	# dictionaries), a block that does not decompress to its size, a block of the wrong size for a bup's record, and one cut short.
	var good: Dictionary = parsed["dish"]
	var before := b.population()
	var bad_old := good.duplicate()
	bad_old["cells"] = [{"pos": [0, 0]}]
	var bad_zstd := good.duplicate(true)
	bad_zstd["cells"]["raw"] = int(bad_zstd["cells"]["raw"]) + 96
	var bad_size := good.duplicate(true)
	bad_size["cells"] = DishCodec.pack_bytes(PackedByteArray([1, 2, 3]))
	var cut_short := good.duplicate(true)
	cut_short["lineage"]["z"] = str(cut_short["lineage"]["z"]).substr(0, 20)
	for bad: Dictionary in [bad_old, bad_zstd, bad_size, cut_short]:
		if b.from_dict(bad): failures.append("accepted a save it cannot read")
	if b.population() != before: failures.append("a refused save changed the dish")
	# The packed family records keep every record, with the names the player gave.
	var named_id := b.bup_ids()[0]
	b.rename_bup(named_id, "Zoë")
	var d2 := Dish.new()
	root.add_child(d2)
	b.moved_out[named_id] = 3  # (as a pipette leaves it: the bup went to dish 3)
	b.set_backend_setting(StartConditions.BACKEND_CPU)
	if not d2.from_dict(JSON.parse_string(JSON.stringify(b.to_dict()))) or d2.bup_name(named_id) != "Zoë" or d2.sim.record_count() != b.sim.record_count():
		failures.append("family records through a save (%d vs %d)" % [d2.sim.record_count(), b.sim.record_count()])
	if d2.moved_out.get(named_id, -1) != 3 or d2.backend.setting != StartConditions.BACKEND_CPU:
		failures.append("where the pipette's bups went, and the backend setting, through a save (%s, %s)" % [d2.moved_out, d2.backend.setting])
	# A save of another version is no save at all.
	if SaveGame.VERSION < 2: failures.append("the save version was not raised with the format")

	print("cells=%d nutrient=%.0f history=%d goal_index=%d" % [a.population(), a.field.total() / Dish.NUTRIENT_ENERGY, a.history.fine["pop"].size(), tracker.index])
	TestUtil.finish(self, "SAVE ROUNDTRIP OK")
