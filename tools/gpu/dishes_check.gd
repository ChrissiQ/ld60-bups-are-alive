extends SceneTree
## Several dishes on the game screen, windowed: a second and third dish run beside the main one (one of them on the GPU), the strip's thumbnails are drawn,
## and a screenshot of the screen is written for a look.
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/dishes_check.gd -- <out_png>

var failures := 0


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		failures += 1


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
	var m: Node = TestUtil.free_game(start)
	root.add_child(m)
	await process_frame
	m.toolbar.set_paused(false)
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
	_check(m.dishes.size() == 3 and m.dish_strip.visible, "three dishes, the strip shows")
	_check(second.population() > 0 and third.population() > 0, "the others have bups (%d, %d)" % [second.population(), third.population()])
	var image := m.get_viewport().get_texture().get_image()
	var path := OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "dishes.png"
	image.save_png(path)
	var k := 0
	for entry in m.dish_strip._entries:
		entry["viewport"].get_texture().get_image().save_png(path.replace(".png", "_thumb%d.png" % k))
		k += 1
	m.set_main_dish(third)
	for i in 30:
		await process_frame
	_check(m.dish == third, "the third is the main view")
	print("DISHES CHECK %s" % ("OK" if failures == 0 else "FAILED"))
	quit(failures)
