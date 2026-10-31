extends SceneTree
## Run: godot --headless --path . -s tests/governor_test.gd
## The Governor with a fake clock: the step length from the speed alone, the time owed,
## the steps of an iteration within T_ITER and the caller's bounds, the duty, the history samples.
##
## Expected values, written before the first run [derived from the Governor's constants: MAX_STEP 20 s, 120 steps a simulated
## second, T_ITER 25 ms (placeholder), frames capped at 0.1 s, owed time at most 2 iterations, duty -10% after 3 frames over 1.15 x the
## display frame and +5% for a frame within 1.05 x, EMA weight 0.25]:
##  - step_length: x1 = 1/120 s, x600 = 5 s, x2,400 = 20 s, x10,000 = 20 s, x0 = 0; and the governor's delta() after a frame of 1/60 s
##    and after one of 1/120 s is the same value at x1, x600 and x10,000.
##  - owed: at x1, one frame of 1/120 s owes 1 step; one of 1/240 s owes 0, two owe 1. Fed (N + 0.5) steps' time (N = 240) as N frames of
##    1/120 s and a half frame, or as 2N + 1 frames of 1/240 s, stepping whatever is owed after each frame with a fast step (0.5 ms), both
##    run exactly N steps. A frame of 1 s counts as 0.1 s (with a 0.5 ms step, so the cap of 2 x 50 steps of 1/120 s is above it). Paused, nothing is owed.
##  - steps: a step of 5 ms gives 5 steps an iteration (5 x 5 = 25 ms = T_ITER) with 100 owed; 30 ms gives 1; 0.001 ms gives 1,024
##    (MAX_STEPS); with room 3 it is 3, with samples 2 it is 2; nothing owed gives 0.
##  - the cap: at x10,000 with a 5 ms step (5 steps an iteration of 20 s), frames of 0.1 s (1,000 s each) owe at most 2 x 5 x 20 = 200 s;
##    after 3 such frames 2,800 s were dropped.
##  - advanced: from the initial cost (25 ms), an iteration of 10 steps in 50 ms makes it 25 + 0.25 x (5 - 25) = 20 ms; the clock moves
##    10 x delta.
##  - duty on a display of 8.333 ms: 2 frames of 10 ms leave it 1.0; a third makes it 0.9; a frame of 8.5 ms then makes it 0.945; rest
##    after 10 ms busy at 0.9 is 1.111 ms; at 1.0 it is 0; it never goes under 0.1.
##  - pacing, on a display of 1/120 s at x1: 1,200 frames whose ends sit 1/120 s apart plus a jitter drawn in +-1.5 ms (each frame's length
##    the difference of two ends) each run exactly one step, and the time owed in all is the real time within half a display frame
##    [derived: what is left over after a frame is its end's jitter less the first's, within 3 ms, under half a frame (4.17 ms)]; the
##    same frames with no display known leave some frames with no step [derived: the owed fraction starts on a whole step, so a frame
##    shorter than the one before steps 0]; 600 frames 0.8% longer than the display's run within one step of the real time's steps and
##    owe it within half a display frame [derived: a frame of two display frames every 63].
##  - history samples (interval 120 s): from 0 with 10 steps of 20 s, one sample after step index 5; from 100 s with 3 steps, after index 0;
##    at most 16 an iteration: from 0, steps of 20 s allow 101 steps (the 17th sample would fall after step index 101).

const EPS := 1e-9


func _init() -> void:
	_step_length()
	_owed()
	_steps()
	_cap()
	_advanced()
	_duty()
	_samples()
	_pacing()
	TestUtil.finish(self, "GOVERNOR TEST OK")


func _step_length() -> void:
	TestUtil.check(is_equal_approx(Governor.step_length(1.0), 1.0 / 120.0), "x1: 1/120 s (got %f)" % Governor.step_length(1.0))
	TestUtil.check(is_equal_approx(Governor.step_length(600.0), 5.0), "x600: 5 s")
	TestUtil.check(is_equal_approx(Governor.step_length(10000.0), 20.0), "x10,000: 20 s")
	TestUtil.check(is_equal_approx(Governor.step_length(2400.0), 20.0), "x2,400: 20 s")
	TestUtil.check(Governor.step_length(0.0) == 0.0, "x0: 0")
	for speed in [1.0, 600.0, 10000.0]:
		var a := Governor.new()
		a.set_time(speed, false, 1.0 / 60.0)
		var b := Governor.new()
		b.set_time(speed, false, 1.0 / 120.0)
		TestUtil.check(a.delta() == b.delta() and a.delta() == Governor.step_length(speed), "x%d: the same step with frames of 1/60 and 1/120 s" % int(speed))


func _owed() -> void:
	var g := Governor.new()
	g.set_time(1.0, false, 1.0 / 120.0)
	TestUtil.check(g.owed_steps() == 1, "x1: a frame of 1/120 s owes a step (got %d)" % g.owed_steps())
	g = Governor.new()
	g.set_time(1.0, false, 1.0 / 240.0)
	TestUtil.check(g.owed_steps() == 0, "x1: a frame of 1/240 s owes no whole step")
	g.set_time(1.0, false, 1.0 / 240.0)
	TestUtil.check(g.owed_steps() == 1, "x1: two frames of 1/240 s owe a step")
	const N := 240
	var at120 := _run_frames(1.0 / 120.0, N, 0.5)
	var at240 := _run_frames(1.0 / 240.0, 2 * N, 1.0)
	TestUtil.check(at120 == N and at240 == N, "(N + 0.5) steps' time in frames of 1/120 and of 1/240 s run N = %d steps (got %d, %d)" % [N, at120, at240])
	g = Governor.new()
	g.step_ms_ema = 0.5
	g.set_time(1.0, false, 1.0)
	TestUtil.check(is_equal_approx(g.owed(), 0.1), "a frame of 1 s counts as 0.1 s (owed %f)" % g.owed())
	g.set_time(1.0, true, 1.0 / 120.0)
	TestUtil.check(g.owed() == 0.0 and g.owed_steps() == 0, "paused: nothing owed")


## Feeds `frames` frames of `dt` and then one of `last_fraction` x dt at x1, running what is owed after each frame (a step of 0.5 ms):
## the steps run.
func _run_frames(dt: float, frames: int, last_fraction: float) -> int:
	var g := Governor.new()
	g.step_ms_ema = 0.5
	var ran := 0
	for f in frames + 1:
		g.set_time(1.0, false, dt if f < frames else dt * last_fraction)
		var k := g.steps()
		if k > 0:
			g.advanced(k, g.delta(), 0.5 * k)
			ran += k
	return ran


func _steps() -> void:
	var g := Governor.new()
	g.set_time(1.0, false, 0.0)
	TestUtil.check(g.steps() == 0, "nothing owed: 0 steps")
	g.target = 100.0 * g.delta() + 1e-6
	g.step_ms_ema = 5.0
	TestUtil.check(g.steps() == 5, "a 5 ms step: 5 steps hold T_ITER (got %d)" % g.steps())
	g.step_ms_ema = 30.0
	TestUtil.check(g.steps() == 1, "a 30 ms step: 1 step (got %d)" % g.steps())
	g.step_ms_ema = 0.001
	g.target = 5000.0 * g.delta()
	TestUtil.check(g.steps() == Governor.MAX_STEPS, "a step of 1 µs: MAX_STEPS (got %d)" % g.steps())
	TestUtil.check(g.steps(3) == 3, "room for 3 steps: 3")
	TestUtil.check(g.steps(Governor.MAX_STEPS, 2) == 2, "samples allow 2 steps: 2")


func _cap() -> void:
	var g := Governor.new()
	g.step_ms_ema = 5.0
	for i in 3:
		g.set_time(10000.0, false, 0.1)
	TestUtil.check(is_equal_approx(g.owed(), 200.0), "x10,000 with 5 steps an iteration: at most 200 s owed (got %f)" % g.owed())
	TestUtil.check(is_equal_approx(g.dropped, 2800.0), "x10,000: 2,800 s dropped over 3 frames of 0.1 s (got %f)" % g.dropped)


func _advanced() -> void:
	var g := Governor.new()
	g.set_time(10000.0, false, 0.1)
	var d := g.delta()
	g.advanced(10, d, 50.0)
	TestUtil.check(is_equal_approx(g.step_ms_ema, 20.0), "the step's cost: 25 + 0.25 x (5 - 25) = 20 ms (got %f)" % g.step_ms_ema)
	TestUtil.check(is_equal_approx(g.clock, 10.0 * d) and g.steps_total == 10, "the clock moved 10 steps")


func _duty() -> void:
	var g := Governor.new()
	var display := 8.333
	g.frame(10.0, display)
	g.frame(10.0, display)
	TestUtil.check(g.duty == 1.0, "two slow frames leave the duty at 1.0")
	g.frame(10.0, display)
	TestUtil.check(is_equal_approx(g.duty, 0.9), "a third slow frame: 0.9 (got %f)" % g.duty)
	TestUtil.check(is_equal_approx(g.rest_ms(10.0), 10.0 * (1.0 / 0.9 - 1.0)), "rest after 10 ms busy at 0.9: 1.111 ms (got %f)" % g.rest_ms(10.0))
	g.frame(8.5, display)
	TestUtil.check(is_equal_approx(g.duty, 0.945), "a frame within 1.05: x1.05 (got %f)" % g.duty)
	var h := Governor.new()
	TestUtil.check(h.rest_ms(10.0) == 0.0, "no rest at duty 1.0")
	for i in 300:
		h.frame(100.0, display)
	TestUtil.check(is_equal_approx(h.duty, Governor.DUTY_MIN), "the duty stops at 0.1 (got %f)" % h.duty)


func _samples() -> void:
	var a := Governor.sample_steps(0.0, 10, 20.0, 120.0, 16)
	TestUtil.check(a == PackedInt32Array([5]), "from 0, 10 steps of 20 s: a sample after step index 5 (got %s)" % [a])
	var b := Governor.sample_steps(100.0, 3, 20.0, 120.0, 16)
	TestUtil.check(b == PackedInt32Array([0]), "from 100 s: after step index 0 (got %s)" % [b])
	var most := Governor.steps_for_samples(0.0, 20.0, 120.0, 16, Governor.MAX_STEPS)
	TestUtil.check(most == 101, "16 samples allow 101 steps of 20 s from 0 (got %d)" % most)
	TestUtil.check(Governor.sample_steps(0.0, most, 20.0, 120.0, 16).size() == 16, "and those steps hold 16 samples")


func _pacing() -> void:
	const FRAMES := 1200
	var period := 1.0 / 120.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var g := Governor.new()
	g.step_ms_ema = 0.5
	var plain := Governor.new()
	plain.step_ms_ema = 0.5
	var last_jitter := 0.0
	var real := 0.0
	var single := 0
	var plain_none := 0
	for f in FRAMES:
		var jitter := rng.randf_range(-0.0015, 0.0015)
		var dt := period + jitter - last_jitter
		last_jitter = jitter
		real += dt
		if _paced_frame(g, dt, period) == 1:
			single += 1
		plain.set_time(1.0, false, dt)
		var kp := plain.steps()
		if kp == 0:
			plain_none += 1
		plain.advanced(kp, plain.delta(), 0.5 * kp)
	TestUtil.check(single == FRAMES, "pacing: %d jittered frames of a 1/120 s display each run one step (%d did)" % [FRAMES, single])
	TestUtil.check(absf(g.target - real) <= 0.5 * period, "pacing: the time owed is the real time within half a frame (off by %.3f ms)" % ((g.target - real) * 1000.0))
	TestUtil.check(plain_none > 0, "without a display known, some of the same frames run no step (%d)" % plain_none)
	var slow := Governor.new()
	slow.step_ms_ema = 0.5
	var ran := 0
	real = 0.0
	for f in 600:
		var dt := 1.008 * period
		real += dt
		ran += _paced_frame(slow, dt, period)
	TestUtil.check(absf(slow.target - real) <= 0.5 * period and absi(ran - int(floor(real / period))) <= 1, "pacing: frames 0.8%% long owe the real time within half a frame (off by %.3f ms; %d steps for %.2f)" % [(slow.target - real) * 1000.0, ran, real / period])


## One frame of `dt` on a display of `period` (s) at x1, as the sim thread hands it to the governor; runs what is owed and returns the steps.
func _paced_frame(g: Governor, dt: float, period: float) -> int:
	g.frame(dt * 1000.0, period * 1000.0)
	g.set_time(1.0, false, dt)
	var k := g.steps()
	g.advanced(k, g.delta(), 0.5 * k)
	return k
