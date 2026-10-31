class_name Governor
extends RefCounted
## How much the sim thread runs and when: the world step's length from the speed setting, the simulated time owed by
## the frames the interface has drawn, how many steps the next iteration takes, and how long the thread rests after one so the interface
## keeps its frame rate. Pure arithmetic: the caller gives every time (no clock is read here), so a test drives it with a fake one.
##
## - Step length: `step_length(speed) = min(MAX_STEP, speed / STEPS_PER_SECOND)`, from the speed alone, never from the frame.
## - Owed time: each frame adds `speed x min(real_dt, MAX_FRAME_SECONDS)` (nothing while paused); what is owed is kept to at most
##   OWED_ITERATIONS iterations' worth, so a slow machine drops time (the achieved speed shows it) instead of piling it up.
## - Steps of an iteration: as many as are owed, at most what fits T_ITER_MS at the measured cost of a step, MAX_STEPS, and the bounds
##   the caller gives (the room the pool can grow to, the history samples an iteration can hold).
## - Duty: three frames in a row longer than SLOW_FRAME x the display's frame lower it by DUTY_DOWN; each frame within FAST_FRAME of it
##   raises it by DUTY_UP; after an iteration that kept the thread busy `busy` ms it rests `busy x (1 / duty - 1)` ms.

const MAX_STEP := Dish.MAX_STEP  ## s: the longest world step
const STEPS_PER_SECOND := 60.0  ## steps per simulated second at x1 (a step of 1/60 s)
const MAX_FRAME_SECONDS := 0.1  ## the longest frame the sim catches up on (Main.MAX_FRAME_SECONDS)
const T_ITER_MS := 25.0  ## [placeholder, fixed by a soak on the real sim] the longest an iteration's steps should take
const MAX_STEPS := GpuLayout.MAX_STEPS_PER_BATCH
const OWED_ITERATIONS := 2.0  ## the most time owed, in iterations of the most steps the governor allows now
const OWED_TOLERANCE := 1e-6  ## of a step: what a sum of frame lengths may miss a whole step by and still owe it
const EMA_WEIGHT := 0.25  ## the newest iteration's weight in the cost of a step
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
var step_ms_ema := T_ITER_MS  ## ms: the cost of a step, as the iterations measured it (starts at one step an iteration)
var duty := 1.0
var dropped := 0.0  ## s of owed time dropped by the cap, in all
var _slow := 0


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
		return
	target += speed * clampf(real_dt, 0.0, MAX_FRAME_SECONDS)
	var most := OWED_ITERATIONS * float(steps_by_time()) * delta()
	if target - clock > most:
		dropped += target - clock - most
		target = clock + most


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
func steps_by_time() -> int:
	return clampi(int(floor(T_ITER_MS / maxf(step_ms_ema, 1e-3))), 1, MAX_STEPS)


## The steps of the next iteration: the owed ones, within the time bound and the caller's bounds (`room`: the most the pool can grow for;
## `samples`: the most the history samples allow). 0 when nothing whole is owed.
func steps(room: int = MAX_STEPS, samples: int = MAX_STEPS) -> int:
	var k := owed_steps()
	if k <= 0:
		return 0
	return maxi(1, mini(mini(k, steps_by_time()), mini(room, samples)))


## An iteration ran `k` steps of `step_delta` seconds and took `busy_ms` (record, submit, sync): the clock moves on and the cost of a
## step is learned.
func advanced(k: int, step_delta: float, busy_ms: float) -> void:
	if k <= 0:
		return
	clock += k * step_delta
	steps_total += k
	if target < clock:
		target = clock
	var per := busy_ms / k
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
func frame(frame_ms: float, display_ms: float) -> void:
	if display_ms <= 0.0:
		return
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
