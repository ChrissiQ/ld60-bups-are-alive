extends SceneTree
## The second food on the GPU path: acetate put in a bup-free dish crosses to the GPU with the switch, spreads there like the nutrient (the same
## diffusion), keeps its total, and comes back to the CPU (a save reads it back). Then with bups: the total stays near what the CPU gives.
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/acetate_check.gd

const Tools := preload("res://tools/gpu/world_tools.gd")

var failures := 0


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		failures += 1


func _peak(field: NutrientField) -> float:
	var peak := 0.0
	for v: float in field.values():
		peak = maxf(peak, v)
	return peak


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var dish := Tools.make_dish(self, "B", 1)
	dish.clear_bups()
	var spacing := dish.field.get_spacing()
	dish.acetate.deposit(Vector2.ZERO, 1000.0 * spacing * spacing)
	var total0: float = dish.acetate.total()
	var peak0 := _peak(dish.acetate)
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	var frames := 0
	while not dish.gpu_active and frames < 600:
		dish.advance(1000.0 / 6.0)
		frames += 1
		await process_frame
	_check(dish.gpu_active, "the dish runs on the GPU (after %d frames)" % frames)
	for i in 120:
		dish.advance(1000.0 / 6.0)
		await process_frame
	var saved := dish.to_dict()  # (reads the GPU's field back)
	var copy := Dish.new()
	root.add_child(copy)
	copy.process_mode = Node.PROCESS_MODE_DISABLED
	var loaded := copy.from_dict(saved)
	_check(loaded, "the save loads")
	var total1: float = copy.acetate.total()
	var peak1 := _peak(copy.acetate)
	_check(absf(total1 / total0 - 1.0) < 1e-3, "the acetate keeps its total on the GPU (%.2f of %.2f)" % [total1, total0])
	_check(peak1 < 0.9 * peak0 and peak1 > 0.0, "it has spread there (peak %.3f of %.3f)" % [peak1, peak0])
	Tools.release(dish)
	print("ACETATE CHECK %s" % ("OK" if failures == 0 else "FAILED"))
	quit(failures)
