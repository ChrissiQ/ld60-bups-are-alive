extends SceneTree
## Run: godot --headless --path . -s tests/pool_limits_test.gd
## The pool's memory budget worked out from what a machine reports (PoolLimits.budget_for), headless. Expected values, written before the first run:
## [derived from BUDGET_SHARE 0.4, BUDGET_AVAILABLE_SHARE 0.7, BUDGET_FLOOR 1 GiB, BUDGET_SEPARATE_CAP 4 GiB]
##  - 16 GiB physical, 12 GiB available, shared memory: 0.4 x 16 = 6.4 GiB (0.7 x 12 = 8.4 is more);
##  - 16 GiB physical, 6 GiB available, shared: 0.7 x 6 = 4.2 GiB; 8 GiB physical, 8 GiB available: 3.2 GiB;
##  - 64 GiB physical and available, shared: 25.6 GiB, and with memory of its own: the 4 GiB cap;
##  - 2 GiB physical, shared: 0.8 GiB, up to the 1 GiB floor; available 0.5 GiB: the floor too;
##  - nothing reported (-1, -1): the floor; physical but no availability: the share of physical;
##  - `PoolLimits.new()` keeps the 6 GiB the tests set their own budgets from; the warning is at WARN_FRACTION of whatever budget is set.
const GIB := 1024 * 1024 * 1024


func _init() -> void:
	TestUtil.check(_near(PoolLimits.budget_for(16 * GIB, 12 * GIB, true), 6.4 * GIB), "16 GiB with 12 free: 6.4 GiB")
	TestUtil.check(_near(PoolLimits.budget_for(16 * GIB, 6 * GIB, true), 4.2 * GIB), "16 GiB with 6 free: 4.2 GiB")
	TestUtil.check(_near(PoolLimits.budget_for(8 * GIB, 8 * GIB, true), 3.2 * GIB), "8 GiB: 3.2 GiB")
	TestUtil.check(_near(PoolLimits.budget_for(64 * GIB, 64 * GIB, true), 25.6 * GIB), "64 GiB shared: 25.6 GiB")
	TestUtil.check(PoolLimits.budget_for(64 * GIB, 64 * GIB, false) == 4 * GIB, "memory of its own: the 4 GiB cap")
	TestUtil.check(PoolLimits.budget_for(2 * GIB, 2 * GIB, true) == GIB, "2 GiB: the floor")
	TestUtil.check(PoolLimits.budget_for(16 * GIB, GIB / 2, true) == GIB, "little available: the floor")
	TestUtil.check(PoolLimits.budget_for(-1, -1, true) == GIB, "nothing reported: the floor")
	TestUtil.check(_near(PoolLimits.budget_for(16 * GIB, -1, true), 6.4 * GIB), "no availability: the share of physical")
	TestUtil.check(PoolLimits.new().memory_budget_bytes == 6 * GIB, "the tests' default budget is unchanged")
	TestUtil.check(PoolLimits.from_settings().memory_budget_bytes >= PoolLimits.BUDGET_FLOOR, "from_settings gives at least the floor")
	TestUtil.check(PoolLimits.warning_state({"memory_fraction": 0.9}) == PoolLimits.WARN_NEAR and PoolLimits.warning_state({"memory_fraction": 0.89}) == "", "the warning stays at 0.9")
	TestUtil.finish(self, "OK pool_limits_test")


func _near(a: int, b: float) -> bool:
	return absf(float(a) - b) <= 1.0
