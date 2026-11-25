extends SceneTree
## A read-back the device had not finished is never used (SimCore's completion mark). Windowed, on any backend: the fault is handed to
## `run` by a hook (`fault_stale_reads`: the next marked reads come back as zeros, as a timed-out wait leaves them), so no backend has to be slow.
##
## Expected values [derived: a read whose tail is not the mark of its list is thrown away, the device is waited for and the read repeated,
## so the world carries on as if the fault never was; a read that never carries the mark fails the world and gives nothing]:
## - Two worlds made alike (40 founders, 600 µm, every flag, a bloom) run 40 steps. World A then runs 20 more straight. World B runs the
##   20 with fault_stale_reads = 1, so the iteration's own read-back is the stale one. Afterwards on B: failure is "", unfinished is 1, the
##   fault is spent (0), the iteration ran its 20 steps (steps 20, not failed), the dish has bups (no dish is extinct: zeros read as a count
##   of 0), the births and deaths estimates (_births_per_step, _deaths_per_step) and the step (DS_STEP) are A's, and the canonical dump
##   equals A's word for word (diff "").
## - A blocking read (a dump, read through `read_parts`) with fault_stale_reads = 1 on B counts one more unfinished sync (2) and gives the
##   dump it gave before.
## - A flush (SimArena._flush, which waits for a completion mark of its own) with fault_stale_reads = 1 counts one more unfinished sync (3),
##   spends the fault and leaves the world not failed.
## - A fault that does not end (fault_stale_reads = 1 << 30) on a third world C, run one iteration: after about CONFIRM_LIMIT_MSEC (30 s,
##   not under 29 s and under 40 s) `run` gives {steps 0, failed true}, failure names the device and the wait, C's host copy of DSTATE is
##   byte for byte what it was before the iteration (nothing of the stale read was taken), and a second `run` gives the same failure at
##   once (under 1 s).

const N := 40
const M := 20


func _init() -> void:
	if not SimHarness.begin(self, "stale_read_test", "the pooled core (SimCore)"):
		return
	var s := Scenario.small(40, 600.0).seed(31).with_all_flags()
	s.bloom_density = 2.0
	var a := SimHarness.make([s.copy()]).step(N).step(M)
	var b := SimHarness.make([s.copy()]).step(N)
	var core: Variant = b.core
	TestUtil.show(core.failure == "" and core.unfinished == 0, "before the fault: no failure and no unfinished sync (%d)" % core.unfinished)
	core.fault_stale_reads = 1
	var res: Dictionary = b.step_whole(M)
	TestUtil.show(core.failure == "" and not res.get("failed", false) and int(res["steps"]) == M, "the faulted iteration ran its %d steps and the world did not fail (%s)" % [M, res.get("refused", "")])
	TestUtil.show(core.unfinished == 1 and core.fault_stale_reads == 0, "one unfinished sync was found and the fault is spent (unfinished %d, fault left %d)" % [core.unfinished, core.fault_stale_reads])
	TestUtil.show(b.count(0) > 0 and b.count(0) == a.count(0), "the dish is not extinct: %d bups, as the straight run's %d" % [b.count(0), a.count(0)])
	TestUtil.show(core._births_per_step == a.core._births_per_step and core._deaths_per_step == a.core._deaths_per_step, "the births and deaths estimates are the straight run's (%s, %s against %s, %s)" % [core._births_per_step, core._deaths_per_step, a.core._births_per_step, a.core._deaths_per_step])
	var da: Dictionary = a.dump(0)
	var db: Dictionary = b.dump(0)
	var line := SimHarness.diff(da, db)
	TestUtil.show(line == "", "the world after the faulted iteration is the straight run's: %s" % (line if line != "" else "same"))
	core.fault_stale_reads = 1
	var again: Dictionary = b.dump(0)
	TestUtil.show(core.unfinished == 2 and core.fault_stale_reads == 0 and SimHarness.diff(da, again) == "", "a stale blocking read is read again (unfinished %d) and gives the same dump" % core.unfinished)
	core.fault_stale_reads = 1
	var flushed_before: int = core.unfinished
	core.arena._flush()
	TestUtil.show(core.unfinished == flushed_before + 1 and core.fault_stale_reads == 0 and core.failure == "", "a stale flush is confirmed again (unfinished %d, failure '%s')" % [core.unfinished, core.failure])
	a.core.release()
	b.core.release()
	_never_finished(s)
	TestUtil.finish(self, "OK stale_read_test")


func _never_finished(s: Scenario) -> void:
	var c := SimHarness.make([s.copy()]).step(N)
	var core: Variant = c.core
	var dstate_before: PackedByteArray = core._dstate.duplicate()
	var limit: int = load(SimHarness.SIM_CORE_PATH).CONFIRM_LIMIT_MSEC
	core.fault_stale_reads = 1 << 30
	var began := Time.get_ticks_msec()
	var res: Dictionary = c.step_whole(M)
	var waited := Time.get_ticks_msec() - began
	TestUtil.show(bool(res.get("failed", false)) and int(res["steps"]) == 0 and core.failure != "", "a read that never carries the mark fails the world: %s" % core.failure)
	TestUtil.show(waited >= limit - 1000 and waited < limit + 10000, "...after the bound (%d ms; the limit is %d)" % [waited, limit])
	TestUtil.show(core._dstate == dstate_before, "...and nothing of the stale read was taken: DSTATE as the host holds it is what it was")
	began = Time.get_ticks_msec()
	var next: Dictionary = c.step_whole(M)
	TestUtil.show(bool(next.get("failed", false)) and Time.get_ticks_msec() - began < 1000, "...and a later iteration gives the failure at once (%d ms)" % (Time.get_ticks_msec() - began))
	core.release()
