extends SceneTree
## Run: godot --headless --path . -s tests/pause_menu_test.gd
## Checks the pause menu's record of how a free-mode dish started: the rows show the start conditions, the rows at their defaults are hidden, the device row
## names the device the world simulates on (read when the menu opens, "CPU" when the world names none), the GPU setting's row is never shown
## (hidden: the world always runs on the GPU), and the quit button's words.
## The world is a FakeWorld, whose `device` is what the menu reads.


func _initialize() -> void:
	var fake := TestUtil.use_fake_world(self)
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(5)
	dish.strike(TestUtil.small_start())
	for i in 3:
		await process_frame
	var menu: PauseMenu = load("res://scenes/pause_menu.tscn").instantiate()
	root.add_child(menu)
	await process_frame

	# Started with limit 5,000, detail 200, thickness 10 and starvation set against the default: those rows show, and the ones that are at their defaults (both husk switches) and the GPU setting's do not.
	var start := StartConditions.new()
	start.bup_limit = 5000
	start.nutrient_resolution = 200
	start.medium_thickness = 10.0
	start.stationary_phase = not StartConditions.new().stationary_phase
	fake.device = "Test GPU"
	menu.open(dish, true, start)
	TestUtil.check(menu.initial_panel.visible, "free mode with a start shows the record")
	TestUtil.check(menu.initial_limit.value_label.text == "5,000" and menu.initial_limit.name_label.text == Strings.t("pause.record_bup_limit"), "the limit row reads 5,000 ('%s')" % menu.initial_limit.value_label.text)
	TestUtil.check(menu.initial_detail.visible and menu.initial_detail.value_label.text == "200" + Strings.t("pause.cells_across") and menu.initial_detail.name_label.text == Strings.t("pause.record_nutrient_detail"), "the detail row reads 200 across ('%s')" % menu.initial_detail.value_label.text)
	TestUtil.check(menu.initial_thickness.visible and menu.initial_thickness.value_label.text == "10" + Strings.t("pause.times_water") and menu.initial_thickness.name_label.text == Strings.t("pause.record_medium_thickness"), "the thickness row reads 10 x water ('%s')" % menu.initial_thickness.value_label.text)
	TestUtil.check(menu.initial_stationary.visible and menu.initial_stationary.value_label.text == Strings.t("pause.stationary_value" if start.stationary_phase else "pause.stationary_off_value") and menu.initial_stationary.name_label.text == Strings.t("pause.record_stationary"), "the starvation row shows its value")
	TestUtil.check(not menu.initial_husks.visible and not menu.initial_plankton_husks.visible, "the husk rows are hidden at their defaults")
	TestUtil.check(menu.initial_running.visible and menu.initial_running.name_label.text == Strings.t("pause.record_device") and menu.initial_running.value_label.text == "Test GPU", "the device row names the world's device ('%s')" % menu.initial_running.value_label.text)

	# Defaults: the detail, thickness and starvation rows hide.
	menu.open(dish, true, StartConditions.new())
	TestUtil.check(not menu.initial_detail.visible and not menu.initial_thickness.visible and not menu.initial_stationary.visible, "rows at their defaults are hidden")

	# The device is read each time the menu opens, and a world with no device is the CPU.
	fake.device = ""
	menu.open(dish, true, start)
	TestUtil.check(menu.initial_running.value_label.text == Strings.t("pause.running_cpu") and Strings.t("pause.running_cpu") == "CPU", "a world with no device says CPU ('%s')" % menu.initial_running.value_label.text)
	fake.device = "Other GPU"
	menu.open(dish, true, start)
	TestUtil.check(menu.initial_running.value_label.text == "Other GPU", "...and the device is read again when the menu opens")

	# The switches that are not at their defaults show, with their rows.
	var more := StartConditions.new()
	more.death_husks = not more.death_husks
	more.plankton_husks = not more.plankton_husks
	menu.open(dish, true, more)
	TestUtil.check(menu.initial_husks.visible and menu.initial_plankton_husks.visible and menu.initial_husks.value_label.text == Strings.t("pause.husks_value" if more.death_husks else "pause.husks_off_value"), "the husk rows show when those were set against the default")

	# The record belongs to free mode with a start; the quit button's words say whether the game is saved.
	TestUtil.check(menu.quit_button.text == Strings.t("pause.quit"), "free mode's quit button reads '%s'" % menu.quit_button.text)
	menu.open(dish, false, null)
	TestUtil.check(not menu.initial_panel.visible and menu.quit_button.text == Strings.t("pause.save_quit"), "goal mode has no record and its quit button saves ('%s')" % menu.quit_button.text)
	menu.open(dish, true, null)
	TestUtil.check(not menu.initial_panel.visible, "free mode without a start has no record")

	menu.free()
	dish.free()
	TestUtil.finish(self, "PAUSE MENU TESTS OK")
