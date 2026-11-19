extends SceneTree
## Run: godot --headless --path . -s tests/memory_mode_test.gd
## Low-memory mode, headless, over made-up machines (MemoryMode.machine) and FakeWorld.
## Expected values [derived from PoolLimits: MIN_PHYSICAL 3 GiB, MIN_FREE 1 GiB, BUDGET_SHARE 0.4,
## DISCRETE_BUDGET 2 GiB, ENOUGH_BUDGET 3 GiB, LOW_BUPS 500,000, LOW_DISHES 10, LOW_GRID 200]:
##  - class: 16 GiB with 8 free is enough (not low mode); 4 GiB with 3 free has a budget of 1.6 GiB, under the 3 GiB a dish of the largest size
##    needs: low (not below), low mode on; 2 GiB installed is below; 16 GiB with 0.5 GiB free is below; a discrete card whose size is not known on 16 GiB has 2 GiB: low.
##  - low-memory mode follows the machine alone: nothing the player sets turns it on or off.
##  - limits: in low mode a bup limit goes to 500,000 and no further (a dish that holds 800,000 keeps 800,000 and cannot rise), the grid to 200,
##    the running dishes to 10 (an 11th add_dish returns null, a pipette is refused); outside it the interface's own ranges.
##  - a dish struck with a start over the limits is made inside them; goal mode's defaults are inside every limit.
##  - the notices: the below text with the free memory or the installed memory, the low text with 500,000, 10 and 200 x 200.

const GIB := 1024 * 1024 * 1024


func _initialize() -> void:
	_run()


func _machine(physical_gib: float, free_gib: float, adapter := RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU) -> MachineMemory:
	return MachineMemory.from_report({"physical": int(physical_gib * GIB), "free": int(free_gib * GIB)}, "macOS", adapter)


func _run() -> void:
	if not root.is_node_ready():
		await process_frame
	SimConstants.apply()
	_classes()
	_limits_in_ranges()
	_notices()
	_no_pool()
	await _dishes()
	MemoryMode.machine = null
	TestUtil.finish(self, "OK memory_mode_test")


func _classes() -> void:
	TestUtil.check(PoolLimits.classify(_machine(16, 8)) == PoolLimits.MACHINE_ENOUGH, "16 GiB with 8 free is enough")
	TestUtil.check(PoolLimits.classify(_machine(4, 3)) == PoolLimits.MACHINE_LOW, "4 GiB with 3 free is low")
	TestUtil.check(PoolLimits.classify(_machine(2, 1.5)) == PoolLimits.MACHINE_BELOW, "2 GiB installed is below")
	TestUtil.check(PoolLimits.classify(_machine(16, 0.5)) == PoolLimits.MACHINE_BELOW, "16 GiB with 0.5 free is below")
	TestUtil.check(PoolLimits.classify(_machine(16, 8, RenderingDevice.DEVICE_TYPE_DISCRETE_GPU)) == PoolLimits.MACHINE_LOW, "a card with memory of its own of unknown size on 16 GiB is low (2 GiB)")
	var card := _machine(16, 8, RenderingDevice.DEVICE_TYPE_DISCRETE_GPU)
	card.card_dedicated = 2 * GIB
	TestUtil.check(PoolLimits.classify(card) == PoolLimits.MACHINE_LOW, "a 2 GiB card has 1.5 GiB: low")
	card.card_dedicated = 8 * GIB
	TestUtil.check(PoolLimits.classify(card) == PoolLimits.MACHINE_ENOUGH, "an 8 GiB card: enough")
	MemoryMode.machine = _machine(16, 8)
	TestUtil.check(not MemoryMode.is_low() and not MemoryMode.is_below(), "enough: not low-memory mode")
	MemoryMode.machine = _machine(4, 3)
	TestUtil.check(MemoryMode.is_low() and not MemoryMode.is_below(), "low: low-memory mode, not below")
	MemoryMode.machine = _machine(2, 1.5)
	TestUtil.check(MemoryMode.is_low() and MemoryMode.is_below(), "below: low-memory mode and below")


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


func _no_pool() -> void:
	var service: Node = root.get_node("SimService")
	var stub := FakeSimBackend.new()
	stub.simulates = false
	service.use_backend(stub)
	MemoryMode.machine = null
	TestUtil.check(not MemoryMode.is_low() and not MemoryMode.is_below() and MemoryMode.start_notices().is_empty(), "nothing can simulate: no memory class and no notices")
	TestUtil.check(MemoryMode.max_bup_limit() == StartConditions.MAX_BUP_LIMIT and MemoryMode.max_resolution() == StartConditions.MAX_NUTRIENT_RESOLUTION and MemoryMode.max_dishes() == GpuLayout.D_MAX, "and the interface's own ranges")
	service.use_backend(FakeSimBackend.new())
	TestUtil.check(not MemoryMode.is_low() and MemoryMode.machine == null, "and with no rendering device even a backend that simulates has no class (a headless run)")
	MemoryMode.machine = _machine(4, 3)
	TestUtil.check(MemoryMode.is_low(), "a machine set explicitly is still judged")
	MemoryMode.machine = null


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
