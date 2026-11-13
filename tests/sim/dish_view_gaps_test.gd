extends SceneTree
## A Dish on the screen over the real world (SimService's GPU backend, the main device drawing): its steering map and its husks as the
## player sees them. Needs a GPU (windowed). On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/dish_view_gaps_test.gd
##
## Expected values, written before the first run [derived from the code's rules]:
## V  A 3 mm dish (death and plankton husks on, 30 founders, paused) given 300 plankton husks: within 3 s of frames the view is made, the
##    husks' multimesh draws 300 instances, and instance k's transform has a unit basis and an origin among the 300 husks' places; with the
##    Medium layer hidden and a founder selected, the steering map is still asked for and the view's "steer" texture, which the dish draws
##    the map from, exists (a valid RID); the Husks layer hidden, none is drawn.
##    The main thread's time to take a new list of 200,000 husks into the multimesh [measured].
## P  The select tool over a husk (the hover at its place) finds it within 3 s, and its details say 50 / 16 = 3.125 units held.


func _initialize() -> void:
	_run()


func _run() -> void:
	if not SimHarness.begin(self, "dish_view_gaps_test", "the dish's pictures"):
		return
	SimConstants.apply()
	var start := TestUtil.small_start()
	start.dish_radius = 3000.0
	start.bup_limit = 3000
	start.bups = 30
	start.death_husks = true
	start.plankton_husks = true
	var d := Dish.new()
	root.add_child(d)
	var camera := Camera2D.new()
	camera.zoom = Vector2.ONE * 0.1
	root.add_child(camera)
	await process_frame
	camera.make_current()
	d.strike(start)
	var rows := PackedFloat64Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var places: Array = []
	for k in 300:
		var p := Vector2.from_angle(rng.randf() * TAU) * 2500.0 * sqrt(rng.randf())
		rows.append_array(PackedFloat64Array([1.0, p.x, p.y, 50.0]))
		places.append(p)
	var made := d.world.inspect(func(core: SimCore, map: Dictionary) -> int:
		var plan := IterationPlan.new()
		plan.events = {map[d.row]: {"discs": PackedFloat64Array(), "husks": rows, "puffs": PackedFloat64Array(), "deposits": PackedFloat64Array()}}
		core.run(1, 20.0, plan)
		return core.husk_view(map[d.row]).size() / 8)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000 and (d.drawing.husks_drawn() < 300 or d.drawing.view == null):
		d.world.set_time(1.0, true, 1.0 / 60.0)
		await process_frame
	var mm := d.drawing.husks_mesh.multimesh
	var at_places := 0
	var unit := true
	for k in mini(mm.visible_instance_count, 300):
		var tr := mm.get_instance_transform_2d(k)
		unit = unit and tr.x == Vector2(1, 0) and tr.y == Vector2(0, 1)
		for p: Vector2 in places:
			if p.distance_to(tr.origin) < 0.01:
				at_places += 1
				break
	TestUtil.show(made.value() == 300 and d.drawing.view != null and d.drawing.husks_drawn() == 300 and unit and at_places == 300, "V the husks are drawn: %d of %s, %d at a husk's place, unit bases %s, view %s" % [d.drawing.husks_drawn(), made.value(), at_places, unit, d.drawing.view != null])
	d.show_layer(Dish.Layer.MEDIUM, false)
	d.selected.bup = (1)
	t0 = Time.get_ticks_msec()
	var steer: Texture2DRD = null
	while Time.get_ticks_msec() - t0 < 3000 and (steer == null or not steer.texture_rd_rid.is_valid()):
		d.world.set_time(1.0, true, 1.0 / 60.0)
		await process_frame
		steer = d.drawing.view.texture("steer") if d.drawing.view != null else null
	TestUtil.show(steer != null and steer.texture_rd_rid.is_valid(), "V with the medium hidden and a bup selected, the steering map's texture is there to draw (%s)" % [steer.texture_rd_rid if steer != null else "none"])
	var husk: Vector2 = places[5]
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000 and d.hovered.husk == Dish.NO_HUSK:
		d.hover_at(d.global_position + husk)
		d.world.set_time(1.0, true, 1.0 / 60.0)
		await process_frame
	var details := d.husk_details(d.hovered.husk) if d.hovered.husk != Dish.NO_HUSK else {}
	TestUtil.show(d.hovered.husk.distance_to(husk) < 0.01 and absf(float(details.get("units", -1.0)) - 50.0 / 16.0) < 1e-4, "P the pointer over a husk finds it, holding %s units (want 3.125)" % [details.get("units", "none")])
	var many := PackedFloat32Array()
	many.resize(200000 * 8)
	var spent: Array = []
	for k in 5:
		var t1 := Time.get_ticks_usec()
		d.drawing.refresh_husks({"row": d.row, "version": 1000000 + k, "transforms": many})
		spent.append((Time.get_ticks_usec() - t1) / 1000.0)
		await process_frame
	spent.sort()
	print("V [measured] the main thread's part of a new list of 200,000 husks (refresh_husks: the buffer's copy and upload): median %.2f ms (min %.2f, max %.2f)" % [spent[2], spent[0], spent[4]])
	d.show_layer(Dish.Layer.HUSKS, false)
	await process_frame
	TestUtil.show(d.drawing.husks_drawn() == 0, "V with the Husks layer hidden none is drawn")
	d.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	TestUtil.finish(self, "OK dish_view_gaps_test")
