extends SceneTree
## The husks' layer (every husk drawn, what can be pointed at is what is drawn) on the real pool: a dish with plankton
## husks on at ParityGame.PLACE, given husks through the world's own events (an IterationPlan's "husks" rows on the sim thread), drawn by
## its DishDrawing and pointed at with the select tool's hover. Windowed only:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_husks_test.gd
##
## Expected values, written before the first run [derived unless marked]:
## 1  One husk of 50 energy: the husks' multimesh draws 1 instance, and the dish counts 1 (DishState.husk_count), within 3 s of frames.
## M  199,999 more (200,000): the multimesh draws 200,000 and the dish counts 200,000 (the picture is the whole list, never a share).
## H  The Husks layer hidden: none drawn, and the pointer resting on the first husk's place outlines none (Dish.looks_at_husks is false);
##    shown again, the pointer there outlines that husk within 3 s of frames (its answer comes with the dish's questions).

var g: ParityGame
var dish: Dish


func _initialize() -> void:
	_run()


func _run() -> void:
	g = ParityGame.start(self, "parity_husks_test")
	if g == null:
		return
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_husks_test")
		return
	var spec := DishSpec.new()
	spec.number = 1
	spec.radius = 45000.0
	spec.limit = 1000
	spec.seed = 3
	spec.nutrient_density = 0.0
	spec.flags = 1 << GpuLayout.DPF_PLANKTON_HUSKS
	dish = await g.add(spec)
	g.look_at(dish, 0.01)
	var first := Vector2(1234.0, -567.0)
	await _put(PackedFloat64Array([1.0, first.x, first.y, 50.0]))
	var one := await g.wait_until(func() -> bool: return dish.drawing.husks_drawn() == 1 and dish.husk_count() == 1, 180)
	TestUtil.show(one, "1 one husk: %d drawn, the dish counts %d" % [dish.drawing.husks_drawn(), dish.husk_count()])
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for chunk in 4:
		var rows := PackedFloat64Array()
		for k in (49999 if chunk == 0 else 50000):
			var p := Vector2.from_angle(rng.randf() * TAU) * 0.9 * spec.radius * sqrt(rng.randf())
			rows.append_array(PackedFloat64Array([1.0, p.x, p.y, 50.0]))
		await _put(rows)
	var many := await g.wait_until(func() -> bool: return dish.drawing.husks_drawn() == 200000 and dish.husk_count() == 200000, 600)
	TestUtil.show(many, "M 200,000 husks: %d drawn, the dish counts %d" % [dish.drawing.husks_drawn(), dish.husk_count()])
	dish.show_layer(Dish.Layer.HUSKS, false)
	var hidden_seen := false
	for k in 30:
		dish.hover_at(dish.global_position + first, 0.0)
		await g.frame()
		hidden_seen = hidden_seen or dish.hovered.husk != Dish.NO_HUSK
	TestUtil.show(dish.drawing.husks_drawn() == 0 and not hidden_seen and not dish.looks_at_husks(), "H the layer hidden: %d drawn, the pointer on a husk outlines none (%s)" % [dish.drawing.husks_drawn(), hidden_seen])
	dish.show_layer(Dish.Layer.HUSKS, true)
	var found := await g.wait_until(func() -> bool:
		dish.hover_at(dish.global_position + first, 0.0)
		return dish.hovered.husk != Dish.NO_HUSK and dish.hovered.husk.distance_to(first) < 0.01, 180)
	TestUtil.show(found and dish.drawing.husks_drawn() == 200000, "H shown again: the pointer on the husk outlines it (%s), %d drawn" % [dish.hovered.husk, dish.drawing.husks_drawn()])
	TestUtil.finish(self, "OK parity_husks_test")


## Husks put into the dish as its world's events of one step (rows: step, x, y, energy), run on the sim thread.
func _put(rows: PackedFloat64Array) -> void:
	var row := dish.row
	await g.inspect(func(core: SimCore, map: Dictionary) -> int:
		var plan := IterationPlan.new()
		plan.events = {map[row]: {"discs": PackedFloat64Array(), "husks": rows, "puffs": PackedFloat64Array(), "deposits": PackedFloat64Array()}}
		core.run(1, Dish.MAX_STEP, plan)
		return 0)
