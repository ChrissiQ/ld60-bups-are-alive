extends SceneTree
## Several dishes on the game screen, windowed: a second and third dish run beside the main one (one of them on the GPU), the strip's thumbnails are drawn,
## and a screenshot of the screen is written for a look.
## On macOS:
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/dishes_check.gd -- <out_png>

func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var start := StartConditions.new()
	start.bups = 300
	start.nutrient_density = 32.0
	start.dish_radius = 5000.0
	start.bup_limit = 30000
	start.spread_founders()
	var m: Node = TestUtil.game_screen(self, start)
	for i in 3600:  # (the screen's _ready, its dish and the world's device come a few frames after the script starts)
		if m.is_node_ready() and m.dish != null and m.dish.row >= 0:
			break
		await process_frame
	for i in 3600:
		if WorldClient.shared().backend.status().get("ready", false):
			break
		await process_frame
	m.toolbar.set_paused(false)
	m._set_paused(false)
	m.sim_speed = 3000.0
	var second: Dish = m.add_dish(start)
	var third_start := StartConditions.new()
	third_start.bups = 100
	third_start.dish_radius = 3000.0
	third_start.nutrient_density = 8.0
	third_start.spread_founders()
	var third: Dish = m.add_dish(third_start)
	for i in 240:
		await process_frame
	TestUtil.show(m.dishes.size() == 3 and m.dish_strip.visible, "three dishes, the strip shows")
	TestUtil.show(second.population() > 0 and third.population() > 0, "the others have bups (%d, %d)" % [second.population(), third.population()])
	var image := m.get_viewport().get_texture().get_image()
	var path := OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "dishes.png"
	image.save_png(path)
	for k in m.dishes.size():
		var tile: Image = m.dish_strip.picture_of(m.dishes[k])
		if tile != null:
			tile.save_png(path.replace(".png", "_thumb%d.png" % k))
	m.set_main_dish(third)
	for i in 30:
		await process_frame
	TestUtil.show(m.dish == third, "the third is the main view")
	print("DISHES CHECK %s" % ("OK" if TestUtil.failures.is_empty() else "FAILED"))
	quit(TestUtil.failures.size())
