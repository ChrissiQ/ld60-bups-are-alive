extends SceneTree
## A submit and wait that takes over a second leaves the world as a short one does. Windowed, Metal only: Metal's fence wait gives up
## after one second and RenderingDevice.sync goes on, so the bytes read after such a submit are the staging's old ones unless the read-back
## is held to the completion mark. Direct3D 12 and Vulkan wait without a limit: there this test prints that it does not apply and passes.
## On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/long_submit_test.gd
##
## Expected values [derived: a dish gives the same in a pool as alone (a dish's blocks are its own), and a read-back the device had not
## finished is waited for and read again; so the same dish run the same iterations gives the same bytes whether its iteration took
## 0.3 s or over 1 s because of the heavy dish beside it. The iteration's length in steps is kept the same: a dish run in iterations
## of other lengths does not end as the same bytes]:
## - Dish X (15,000 founders, 1500 µm, limit 30,000, no flags) runs 20 steps, then one iteration of 1024 steps. Alone (R) that
##   iteration's longest submit and wait is under 1 s and nothing is found unfinished. With a heavy dish beside it (L: dish Y of 100,000
##   founders, 4000 µm, limit 200,000) the same iteration's longest submit is at least 1.0 s (the variant applied: `submit_usec_most`),
##   Metal's wait gave up, so unfinished is at least 1 on L's core, and its failure is "".
## - L ran all its 1024 steps (not refused, not failed), X's canonical dump in L equals R's word for word (diff "") and X has bups (a read
##   of zeros would have shown an extinct dish).

const K := 1024
const FORCED_USEC := 1000000


func _init() -> void:
	if not SimHarness.begin(self, "long_submit_test", "the pooled core (SimCore)"):
		return
	if RenderingServer.get_current_rendering_driver_name() != "metal":
		print("SKIP long_submit_test: does not apply on %s (its waits are not limited to one second); Metal only" % RenderingServer.get_current_rendering_driver_name())
		quit(0)
		return
	var x := Scenario.small(15000, 1500.0).seed(5)
	x.limit = 30000
	var y := Scenario.small(100000, 4000.0).seed(6)
	y.limit = 200000
	var alone := SimHarness.make([x.copy()]).step(20)
	var r: Dictionary = alone.step_whole(K)
	TestUtil.show(int(r["steps"]) == K and not r.get("failed", false) and alone.core.unfinished == 0, "alone, the %d steps ran in a submit of %d ms, nothing unfinished (%d)" % [K, int(r.get("submit_usec_most", 0)) / 1000, alone.core.unfinished])
	TestUtil.show(int(r.get("submit_usec_most", 0)) < FORCED_USEC, "...which is under the second Metal's wait gives up at")
	var long := SimHarness.make([x.copy(), y.copy()]).step(20)
	var res: Dictionary = long.step_whole(K)
	var most := int(res.get("submit_usec_most", 0))
	var core: Variant = long.core
	TestUtil.show(int(res["steps"]) == K and not res.get("failed", false) and core.failure == "", "beside the heavy dish the iteration ran its %d steps (%s)" % [K, res.get("refused", "")])
	TestUtil.show(most >= FORCED_USEC, "its longest submit and wait took %d ms: over the second Metal's wait gives up at" % (most / 1000))
	TestUtil.show(core.unfinished >= 1, "the sync was found unfinished and read again (unfinished %d)" % core.unfinished)
	TestUtil.show(long.count(0) > 0 and long.count(0) == alone.count(0), "dish X has bups: %d, as alone %d" % [long.count(0), alone.count(0)])
	var line := SimHarness.diff(long.dump(0), alone.dump(0))
	TestUtil.show(line == "", "dish X after the long iteration is dish X after the short one: %s" % (line if line != "" else "same"))
	long.core.release()
	alone.core.release()
	TestUtil.finish(self, "OK long_submit_test")
