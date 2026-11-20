class_name Governor
extends RefCounted
## How much the sim thread runs and when: the world step's length from the speed setting, the simulated time owed by
## the frames the interface has drawn, how many steps the next iteration takes, and how long the thread rests after one so the interface
## keeps its frame rate. Pure arithmetic: the caller gives every time (no clock is read here), so a test drives it with a fake one.
##
## - Step length: `step_length(speed) = min(MAX_STEP, speed / STEPS_PER_SECOND)`, from the speed alone, never from the frame.
## - Owed time: each frame adds `speed x min(paced real_dt, MAX_FRAME_SECONDS)` (nothing while paused); what is owed is kept to at most
##   OWED_ITERATIONS iterations' worth, so a slow machine drops time (the achieved speed shows it) instead of piling it up.
## - Pacing: once the display's frame is known (`frame`), a frame counts as a whole number of display frames: its length plus what earlier
##   frames left over, rounded to the nearest (a half down), the rest left over for the next. So the time owed is the real time within
##   half a display frame, and a frame whose end is off its display frame's by less than that owes exactly one display frame. Without it
##   the jitter of the frames' measured lengths (about 1 ms at 120 Hz) puts the whole steps owed by frames as long as a step at 0 in one
##   frame and 2 in the next whenever the owed time's fraction of a step sits near a whole step, and those frames show no new picture.
## - Steps of an iteration: as many as are owed, at most what fits T_ITER_MS at the measured cost of a step, MAX_STEPS, and the bounds
##   the caller gives (the room the pool can grow to, the history samples an iteration can hold).
## - Cost of a step: an iteration costs `fixed_ms + k x step_ms` (the wait, the read-backs and the tail do not depend on k), so one
##   iteration's time over its steps overstates a step by `fixed_ms / k`, and at k = 1 it stays above what lets k rise (T_ITER_MS over that
##   is 1). The two are learned apart from iterations of different k: the slope between an iteration and the one before it at another
##   k (`_ref_k`, `_ref_run`), weighted by how far apart the two k are. Until a slope is known the cost of a step is the iteration's time
##   over its steps. When no pair has been seen for PROBE_EVERY iterations the next one runs another k: half of the usual below it, or, at k = 1
##   or with no slope yet, more than it (up to what 2 x T_ITER_MS allows at the pessimistic cost), and only where the iteration would not be
##   split by frames anyway. T_ITER_MS bounds the steps' time alone; the fixed cost comes on top, so an iteration takes at most
##   `fixed_ms + T_ITER_MS` (plus the answer and publish the caller adds), and a probe up at most `fixed_ms + 2 x T_ITER_MS`.
## - Catch-up in single frames' worth: below MAX_STEP a display frame owes `frame_steps()` steps (1 at 120 Hz) and every iteration publishes
##   one picture the display shows for a frame. After a late iteration k > 1 frames' worth are owed; run as one merged iteration they give
##   one publish for k frames, so k - 1 frames show nothing new for good. When the sim keeps up (a frame's steps cost, on the slow mean, within a display frame,
##   resting included; one late iteration must not turn the split off just when it is needed, so this is not the fast EMA) and at most SPLIT_OWED_MOST frames' worth are owed (the pictures the display keeps: one shown and
##   WorldClient.WAITING_MOST waiting; more would be dropped there), an iteration takes one frame's worth, so each frame owed has its own
##   publish. Past either bound, or at MAX_STEP and above (a frame owes more than one iteration's worth anyway), the owed steps merge into one iteration
##   and a world that cannot keep up slows together. The steps' arithmetic does not depend on how they are grouped.
## - Duty: three frames in a row longer than SLOW_FRAME x the display's frame lower it by DUTY_DOWN; each frame within FAST_FRAME of it
##   raises it by DUTY_UP; after an iteration that kept the thread busy `busy` ms it rests `busy x (1 / duty - 1)` ms.

const MAX_STEP := Dish.MAX_STEP  ## s: the longest world step
const STEPS_PER_SECOND := 120.0  ## steps per simulated second at x1 (a step of 1/120 s)
const MAX_FRAME_SECONDS := 0.1  ## the longest frame the sim catches up on (Main.MAX_FRAME_SECONDS)
const T_ITER_MS := 50.0  ## [placeholder] the longest an iteration's steps should take (the fixed cost of an iteration is not counted)
const MAX_STEPS := GpuLayout.MAX_STEPS_PER_BATCH
const OWED_ITERATIONS := 2.0  ## the most time owed, in iterations of the most steps the governor allows now
const MEAN_WEIGHT := 0.02  ## the newest iteration's weight in the slow mean of a step's cost (about 50 iterations)
const KEEP_UP_SHARE := 1.0  ## of a display frame: the most a frame's steps may cost on average (with rest) for the sim to count as keeping up
const SPLIT_OWED_MOST := 3  ## frames' worth owed up to which catch-up runs frame by frame (the display keeps one shown and two waiting)
const OWED_TOLERANCE := 1e-6  ## of a step: what a sum of frame lengths may miss a whole step by and still owe it
const EMA_WEIGHT := 0.25  ## the newest iteration's weight in the cost of a step
const PROBE_EVERY := 16  ## iterations without a pair of different k after which the next one runs another k
const SLOPE_WEIGHT := 0.5  ## the weight of a slope between two k that differ by their whole size (weighted by the relative difference)
const SLOPE_MIN_SPREAD := 0.25  ## the relative difference of two k under which a first slope is not taken (the noise would be the slope)
const SLOW_FRAME := 1.15
const FAST_FRAME := 1.05
const SLOW_FRAMES := 3
const DUTY_DOWN := 0.9
const DUTY_UP := 1.05
const DUTY_MIN := 0.1

var speed := 1.0
var paused := true
var target := 0.0  ## s: the world time the frames have asked for
var clock := 0.0  ## s: the world time the steps have reached
var steps_total := 0  ## the world steps run so far
var step_ms_ema := T_ITER_MS  ## ms: the cost of a step, as the iterations measured it (starts at one step an iteration; once a slope is known, the slope)
var fixed_ms := 0.0  ## ms: the cost of an iteration that does not depend on its steps (0 until a slope is known)
var slope_known := false
var _ref_k := 0  ## the steps of the iteration the next one is compared with
var _ref_run := 0.0  ## ms: its time (smoothed over the iterations since at the same k)
var _since_pair := 0  ## iterations since a slope was taken
var step_ms_mean := T_ITER_MS  ## ms: the cost of a step on a slow mean (MEAN_WEIGHT): what `keeping_up` reads
var duty := 1.0
var dropped := 0.0  ## s of owed time dropped by the cap, in all
var display_ms := 0.0  ## the display's frame (ms), as `frame` was last told; 0: not known (no pacing)
var _slow := 0
var _pace_carry := 0.0  ## s: the real time the paced frames have left over (within half a display frame)


## The world step's length at `p_speed` (s).
static func step_length(p_speed: float) -> float:
	return minf(MAX_STEP, maxf(p_speed, 0.0) / STEPS_PER_SECOND)


## The step length now.
func delta() -> float:
	return step_length(speed)


## A frame of `real_dt` seconds at `p_speed` (paused: no time owed). The time owed is then capped (see the header).
func set_time(p_speed: float, p_paused: bool, real_dt: float) -> void:
	speed = maxf(p_speed, 0.0)
	paused = p_paused
	if paused or speed <= 0.0:
		target = clock
		_pace_carry = 0.0
		return
	target += speed * clampf(paced(real_dt), 0.0, MAX_FRAME_SECONDS)
	var most := OWED_ITERATIONS * float(steps_by_cost()) * delta()
	if target - clock > most:
		dropped += target - clock - most
		target = clock + most


## A frame's real length (s) as the time it owes (see Pacing in the header).
func paced(real_dt: float) -> float:
	var period := display_ms / 1000.0
	if period <= 0.0:
		return real_dt
	var all := real_dt + _pace_carry
	var out := maxf(ceilf(all / period - 0.5 - OWED_TOLERANCE), 0.0) * period
	_pace_carry = all - out
	return out


## The simulated time owed (s).
func owed() -> float:
	return maxf(target - clock, 0.0)


## The whole steps owed.
func owed_steps() -> int:
	var d := delta()
	if paused or d <= 0.0:
		return 0
	return int(floor(owed() / d + OWED_TOLERANCE))


## The most steps an iteration may take by time alone: T_ITER at the measured cost of a step, at least one, at most MAX_STEPS.
func steps_by_cost() -> int:
	return clampi(int(floor(T_ITER_MS / maxf(step_ms_ema, 1e-3))), 1, MAX_STEPS)


## The most steps the next iteration may take by time: `steps_by_cost`, or the other k of a probe when one is due (see the header).
func steps_by_time() -> int:
	var k := steps_by_cost()
	if _since_pair < PROBE_EVERY or not _may_probe():
		return k
	if slope_known and k >= 2:
		return maxi(1, k / 2)
	if slope_known:
		return k
	return clampi(maxi(k + 1, int(floor(2.0 * T_ITER_MS / maxf(step_ms_ema, 1e-3)))), 1, MAX_STEPS)


## A probe changes k, which splits nothing: not while a display frame's own steps are what the iteration is (below MAX_STEP, within the split).
func _may_probe() -> bool:
	var each := frame_steps()
	return each == 0 or owed_steps() > SPLIT_OWED_MOST * each


## The steps of the next iteration: the owed ones, within the time bound and the caller's bounds (`room`: the most the pool can grow for;
## `samples`: the most the history samples allow). 0 when nothing whole is owed.
func steps(room: int = MAX_STEPS, samples: int = MAX_STEPS) -> int:
	var k := owed_steps()
	if k <= 0:
		return 0
	var each := frame_steps()
	if each > 0 and k > each and k <= SPLIT_OWED_MOST * each and keeping_up(each):
		k = each
	return maxi(1, mini(mini(k, steps_by_time()), mini(room, samples)))


## The steps a display frame owes while steps are shorter than MAX_STEP (STEPS_PER_SECOND x the frame, at least 1); 0 when that does not hold
## or the display's frame is not known.
func frame_steps() -> int:
	if display_ms <= 0.0 or delta() >= MAX_STEP or delta() <= 0.0:
		return 0
	return maxi(1, roundi(STEPS_PER_SECOND * display_ms / 1000.0))


## Whether `n` steps, on the slow mean of what the iterations measured and with the duty's rest, cost within KEEP_UP_SHARE of a display frame.
func keeping_up(n: int) -> bool:
	return float(n) * step_ms_mean / maxf(duty, DUTY_MIN) <= KEEP_UP_SHARE * display_ms


## An iteration ran `k` steps of `step_delta` seconds and took `busy_ms` (record, submit, sync): the clock moves on and the cost of a
## step is learned.
func advanced(k: int, step_delta: float, busy_ms: float) -> void:
	if k <= 0:
		return
	clock += k * step_delta
	steps_total += k
	if target < clock:
		target = clock
	var probed := _since_pair >= PROBE_EVERY
	_learn(k, busy_ms)
	if probed:
		_since_pair = 0  # (the iteration that was due to probe was the probe, whether or not it gave a slope: the next runs the usual k)


## One iteration of `k` steps took `run_ms`: the slope against the iteration before at another k, or the time per step while none is known.
func _learn(k: int, run_ms: float) -> void:
	var per := run_ms / k
	step_ms_mean += MEAN_WEIGHT * (per - step_ms_mean)
	_since_pair += 1
	if _ref_k > 0 and k != _ref_k:
		var rel := absf(float(k - _ref_k)) / float(maxi(k, _ref_k))
		var s := (run_ms - _ref_run) / float(k - _ref_k)
		if s > 0.0 and (slope_known or rel >= SLOPE_MIN_SPREAD):
			s = minf(s, minf(per, _ref_run / float(_ref_k)))  # (a fixed cost is not negative)
			step_ms_ema = s if not slope_known else step_ms_ema + SLOPE_WEIGHT * rel * (s - step_ms_ema)
			slope_known = true
			_since_pair = 0
		_ref_k = k
		_ref_run = run_ms
	elif _ref_k == k:
		_ref_run += EMA_WEIGHT * (run_ms - _ref_run)
	else:
		_ref_k = k
		_ref_run = run_ms
	if slope_known:
		fixed_ms = maxf(0.0, _ref_run - step_ms_ema * float(_ref_k))
	else:
		step_ms_ema = per if step_ms_ema <= 0.0 else step_ms_ema + EMA_WEIGHT * (per - step_ms_ema)


## The clock moves on `k` steps with nothing run (a world with no dish): nothing is learned about a step's cost.
func skip(k: int) -> void:
	if k <= 0:
		return
	clock += k * delta()
	steps_total += k
	if target < clock:
		target = clock


## The interface drew a frame of `frame_ms` on a display whose frame is `display_ms`: the duty follows (see the header).
func frame(frame_ms: float, p_display_ms: float) -> void:
	if p_display_ms <= 0.0:
		return
	display_ms = p_display_ms
	if frame_ms > SLOW_FRAME * display_ms:
		_slow += 1
		if _slow >= SLOW_FRAMES:
			duty = maxf(DUTY_MIN, duty * DUTY_DOWN)
			_slow = 0
		return
	_slow = 0
	if frame_ms <= FAST_FRAME * display_ms:
		duty = minf(1.0, duty * DUTY_UP)


## How long the thread rests after an iteration that kept it busy `busy_ms` (ms).
func rest_ms(busy_ms: float) -> float:
	return maxf(busy_ms, 0.0) * (1.0 / duty - 1.0)


## The steps of an iteration starting at world time `t0` with steps of `step_delta` after which a history sample falls due (a step whose end
## crosses a multiple of `interval`), the first `most` of them: their 0-based indices among `k` steps.
static func sample_steps(t0: float, k: int, step_delta: float, interval: float, most: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if interval <= 0.0:
		return out
	var before := floori(t0 / interval + OWED_TOLERANCE)
	for j in k:
		var now := floori((t0 + (j + 1) * step_delta) / interval + OWED_TOLERANCE)
		if now > before:
			if out.size() >= most:
				break
			out.append(j)
			before = now
	return out


## The most steps from `t0` before more than `most` history samples fall due (the bound that keeps an iteration's samples in its STATS rows).
static func steps_for_samples(t0: float, step_delta: float, interval: float, most: int, limit: int) -> int:
	if interval <= 0.0 or step_delta <= 0.0:
		return limit
	var before := floori(t0 / interval + OWED_TOLERANCE)
	var count := 0
	for j in limit:
		var now := floori((t0 + (j + 1) * step_delta) / interval + OWED_TOLERANCE)
		if now > before:
			count += 1
			before = now
			if count > most:
				return j
	return limit
