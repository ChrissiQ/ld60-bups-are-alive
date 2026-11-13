extends SceneTree
## The cloud lists' entry buffer does not run out before the cloud slots do.
##
## Expected, written before the first run:
## - scenario D seed 6 of the ensemble (tools/gpu/world_tools.gd) is the dish that overflowed: on the code that sized the entries 12 a cloud
##   slot the pool's overflow flag rose at step 1080 with 5,775 bups and 10,134 of 24,576 cloud slots used (a cloud of that dish reaches up to
##   56 bins, measured). Here it is run 1,200 steps of 20 s: the clouds' reach (a handover-wide sigma, 6.5 sigma each way, over bins half a
##   cell wide) needs more than 12 entries each [derived], so the entries must have grown with them: the pool's overflow flag stays 0, the
##   dish cut no bin (DS_ENTRIES_CUT 0), and the entry buffers hold more than 12 a cloud slot, the proof the clouds needed them.
## Windowed only.

const Tools := preload("res://tools/gpu/world_tools.gd")
const STEPS := 1200


func _init() -> void:
	if not SimHarness.begin(self, "cloud_entries_test", "SimCore"):
		return
	SimConstants.apply()
	var h := SimHarness.make([Tools.scenario("D", 6)], {"delta": 20.0})
	h.step(STEPS)
	var core = h.core
	var slots: int = core._wd(GpuLayout.WD_CLOUD_SLOTS)
	var entries: int = core._wd(GpuLayout.WD_ENTRY_CAPACITY)
	var cut: int = core._ds(0, GpuLayout.DS_ENTRIES_CUT)
	TestUtil.show(int(core.overflow()) == 0, "no overflow after %d steps (%d cloud slots in use)" % [STEPS, slots])
	TestUtil.show(cut == 0, "the dish's lists were not cut (%d entries)" % cut)
	TestUtil.show(entries > GpuKernelsClouds.ENTRIES_PER_SLOT * core.arena.cloud_cap, "the entry buffers grew past 12 a cloud slot (%d entries, %d cloud slots)" % [entries, core.arena.cloud_cap])
	core.release()
	TestUtil.finish(self, "OK cloud_entries_test")
