extends SceneTree
## Run: godot --headless --path . -s tests/memory_mode_test.gd
## Low-memory mode and the memory setting, headless, over made-up machines (MemoryMode.machine) and FakeWorld.
## Expected values [derived from PoolLimits: MIN_PHYSICAL 3 GiB, MIN_FREE 1 GiB, BUDGET_SHARE 0.4,
## DISCRETE_BUDGET 2 GiB, ENOUGH_BUDGET 2 GiB, LOW_BUPS 500,000, LOW_DISHES 10, LOW_GRID 200]:
##  - class: 16 GiB with 8 free is enough (not low mode); 4 GiB with 3 free has a budget of 1.6 GiB, under the 2 GiB a dish of the largest size
##    needs: low (not below), low mode on; 2 GiB installed is below; 16 GiB with 0.5 GiB free is below; a discrete card on 16 GiB has 2 GiB: enough.
##  - the setting: Low is low mode on any machine; a number under 2 GB is low mode, 6 GB is not, and the ceiling is that number of GiB (never under
##    the 1 GiB floor); Auto's ceiling is `budget_for`; the running simulation's budget follows `set_memory`.
##  - limits: in low mode a bup limit goes to 500,000 and no further (a dish that holds 800,000 keeps 800,000 and cannot rise), the grid to 200,
##    the running dishes to 10 (an 11th add_dish returns null, a pipette is refused); outside it the interface's own ranges.
##  - a dish struck with a start over the limits is made inside them; goal mode's defaults are inside every limit.
##  - the notices: the below text with the free memory or the installed memory, the low text with 500,000, 10 and 200 x 200.
##  - the setting survives a save and a load of the preferences, and the reset puts Auto back.

const GIB := 1024 * 1024 * 1024


func _initialize() -> void:
	_run()


func _machine(physical_gib: float, free_gib: float, adapter := RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU) -> MachineMemory:
	return MachineMemory.from_report({"physical": int(physical_gib * GIB), "free": int(free_gib * GIB)}, "macOS", adapter)


func _run() -> void:
	if not root.is_node_ready():
		await process_frame
	SimConstants.apply()
	UserSettings.load_once()
	var real_path := UserSettings.path
	UserSettings.path = "user://memory_mode_test.cfg"
	UserSettings.reset()
	_classes()
	_setting()
	_limits_in_ranges()
	_notices()
	_saved()
	await _dishes()
	UserSettings.reset()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UserSettings.path))
	UserSettings.path = real_path
	MemoryMode.machine = null
	TestUtil.finish(self, "OK memory_mode_test")


func _classes() -> void:
	TestUtil.check(PoolLimits.classify(_machine(16, 8)) == PoolLimits.MACHINE_ENOUGH, "16 GiB with 8 free is enough")
	TestUtil.check(PoolLimits.classify(_machine(4, 3)) == PoolLimits.MACHINE_LOW, "4 GiB with 3 free is low")
	TestUtil.check(PoolLimits.classify(_machine(2, 1.5)) == PoolLimits.MACHINE_BELOW, "2 GiB installed is below")
	TestUtil.check(PoolLimits.classify(_machine(16, 0.5)) == PoolLimits.MACHINE_BELOW, "16 GiB with 0.5 free is below")
	TestUtil.check(PoolLimits.classify(_machine(16, 8, RenderingDevice.DEVICE_TYPE_DISCRETE_GPU)) == PoolLimits.MACHINE_ENOUGH, "a card with memory of its own on 16 GiB is enough (2 GiB)")
	MemoryMode.machine = _machine(16, 8)
	TestUtil.check(not MemoryMode.is_low() and not MemoryMode.is_below(), "enough: not low-memory mode")
	MemoryMode.machine = _machine(4, 3)
	TestUtil.check(MemoryMode.is_low() and not MemoryMode.is_below(), "low: low-memory mode, not below")
	MemoryMode.machine = _machine(2, 1.5)
	TestUtil.check(MemoryMode.is_low() and MemoryMode.is_below(), "below: low-memory mode and below")


func _setting() -> void:
	var m := _machine(16, 8)
	TestUtil.check(PoolLimits.ceiling_for(m, PoolLimits.MEMORY_AUTO, 0.0) == int(6.4 * GIB), "Auto: 0.4 of 16 GiB")
	TestUtil.check(PoolLimits.ceiling_for(m, PoolLimits.MEMORY_CUSTOM, 3.5) == int(3.5 * GIB), "a number: that many GiB")
	TestUtil.check(PoolLimits.ceiling_for(m, PoolLimits.MEMORY_CUSTOM, 0.2) == PoolLimits.BUDGET_FLOOR, "a number under the floor gives the floor")
	TestUtil.check(PoolLimits.ceiling_for(m, PoolLimits.MEMORY_CUSTOM, 0.0) == PoolLimits.budget_for(m), "no number chosen: Auto's")
	TestUtil.check(PoolLimits.is_low_memory(m, PoolLimits.MEMORY_LOW, 0.0), "Low is low mode on any machine")
	TestUtil.check(PoolLimits.is_low_memory(m, PoolLimits.MEMORY_CUSTOM, 1.5) and not PoolLimits.is_low_memory(m, PoolLimits.MEMORY_CUSTOM, 6.0), "a number under 2 GB is low mode, 6 GB is not")
	TestUtil.check(not PoolLimits.is_low_memory(m, PoolLimits.MEMORY_AUTO, 0.0), "Auto on an enough machine is not low mode")
	var limits := PoolLimits.new()
	limits.machine = m
	limits.set_memory(PoolLimits.MEMORY_CUSTOM, 3.0, 0, 0)
	TestUtil.check(limits.memory_budget_bytes == 3 * GIB, "set_memory: the budget becomes the number")
	MemoryMode.machine = m
	UserSettings.set_memory(PoolLimits.MEMORY_LOW, 0.0)
	TestUtil.check(MemoryMode.is_low(), "the setting Low turns low-memory mode on at once")
	UserSettings.set_memory(PoolLimits.MEMORY_AUTO, 0.0)
	TestUtil.check(not MemoryMode.is_low(), "Auto turns it off on an enough machine")


func _limits_in_ranges() -> void:
	MemoryMode.machine = _machine(16, 8)
	TestUtil.check(MemoryMode.max_bup_limit() == StartConditions.MAX_BUP_LIMIT and MemoryMode.max_resolution() == StartConditions.MAX_NUTRIENT_RESOLUTION and MemoryMode.max_dishes() == GpuLayout.D_MAX, "enough: the interface's own ranges")
	MemoryMode.machine = _machine(4, 3)
	TestUtil.check(MemoryMode.max_bup_limit() == 500000 and MemoryMode.max_bup_limit(100000) == 500000, "low: bup limit at most 500,000")
	TestUtil.check(MemoryMode.max_bup_limit(800000) == 800000, "a dish already over keeps what it has")
	TestUtil.check(MemoryMode.max_resolution() == 200 and MemoryMode.max_dishes() == 10, "low: grid 200, dishes 10")
	var start := StartConditions.new()
	start.bup_limit = 1500000
	start.nutrient_resolution = 400
	var d := Dish.new()
	root.add_child(d)
	d.strike(start)
	TestUtil.check(d.bup_limit == 500000 and d.resolution == 200, "a dish struck over the limits is made inside them")
	d.change_limit(900000)
	TestUtil.check(d.bup_limit == 500000, "change_limit stops at the most")
	d.bup_limit = 800000
	d.change_limit(900000)
	TestUtil.check(d.bup_limit == 800000, "a dish over the most cannot be raised")
	d.change_limit(300000)
	TestUtil.check(d.bup_limit == 300000, "and can be lowered")
	d.queue_free()
	var goal := StartConditions.new()
	TestUtil.check(goal.bup_limit <= 500000 and goal.nutrient_resolution <= 200, "goal mode's defaults are inside every limit")


func _notices() -> void:
	MemoryMode.machine = _machine(16, 0.5)
	var below := MemoryMode.below_text()
	TestUtil.check(below == "This computer has 0.5 GB of memory free; the game needs about 1 GB. It runs in low memory mode and may be slow.", "below text (free): " + below)
	MemoryMode.machine = _machine(2, 1.5)
	TestUtil.check(MemoryMode.below_text() == "This computer has 2 GB of memory; the game needs about 3 GB. It runs in low memory mode and may be slow.", "below text (installed): " + MemoryMode.below_text())
	TestUtil.check(MemoryMode.low_text() == "Low memory mode: dishes are limited to 500,000 bups, 10 dishes and 200 x 200 grid detail.", "low text: " + MemoryMode.low_text())
	TestUtil.check(MemoryMode.start_notices().size() == 2, "below: both notices")
	MemoryMode.machine = _machine(4, 3)
	TestUtil.check(MemoryMode.start_notices().size() == 1, "low but not below: the low notice only")
	MemoryMode.machine = _machine(16, 8)
	TestUtil.check(MemoryMode.start_notices().is_empty(), "enough: none")
	TestUtil.check(MemoryMode.gb_text(int(7.84 * GIB)) == "7.8 GB" and MemoryMode.gb_text(3 * GIB) == "3 GB", "sizes are GB with one decimal at most")


func _saved() -> void:
	UserSettings.set_memory(PoolLimits.MEMORY_CUSTOM, 3.5)
	UserSettings.memory_mode = PoolLimits.MEMORY_AUTO
	UserSettings.memory_gb = 0.0
	_read_back()
	TestUtil.check(UserSettings.memory_mode == PoolLimits.MEMORY_CUSTOM and is_equal_approx(UserSettings.memory_gb, 3.5), "the setting is read back from the file")
	UserSettings.set_memory(PoolLimits.MEMORY_LOW, 3.5)
	_read_back()
	TestUtil.check(UserSettings.memory_mode == PoolLimits.MEMORY_LOW and is_equal_approx(UserSettings.memory_gb, 3.5), "Low keeps the number")
	UserSettings.reset()
	TestUtil.check(UserSettings.memory_mode == PoolLimits.MEMORY_AUTO and UserSettings.memory_gb == 0.0, "the reset puts Auto back")


## Reads the scratch preferences file the way `load_once` does (which a headless run skips, so the player's own file is never read by a test).
func _read_back() -> void:
	var file := ConfigFile.new()
	TestUtil.check(file.load(UserSettings.path) == OK, "the preferences file was written")
	UserSettings.read_memory(file)


func _dishes() -> void:
	MemoryMode.machine = _machine(4, 3)
	root.get_node("SimService").use_backend(FakeWorld.new())
	var chosen := TestUtil.small_start()
	chosen.bups = 20
	var m: Node = TestUtil.game_screen(self, chosen)
	await process_frame
	await process_frame
	for i in 9:
		TestUtil.check(m.add_dish(chosen) != null, "dish %d is added" % (i + 2))
	TestUtil.check(m.dishes.size() == 10, "ten dishes run")
	TestUtil.check(m.add_dish(chosen) == null and m.dishes.size() == 10, "an 11th is refused in low mode")
	TestUtil.check(m.banner.text == Strings.t("banner.low_dish_limit", [10]), "and the banner says why: " + m.banner.text)
	m.pipette(Vector2.ZERO, 30.0)
	TestUtil.check(m.dishes.size() == 10 and m._pipette_pending.is_empty(), "the pipette is refused too")
	m.queue_free()
	await process_frame
