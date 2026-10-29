class_name GpuStepBudget
extends RefCounted
## The most steps a frame of the GPU path may take (GpuWorld.steps_for's budget). The frame's length is measured from one call to the
## next: three frames in a row longer than 1.15 times the display's frame cut it by a fifth, a frame shorter than 1.05 times raises it
## by a tenth (at least one), up to the most steps asked for lately. Needs no device: the caller gives the time, the frame and the rate.

const WANTED_REF_DECAY := 0.97  ## per call: about half a second at 60 frames a second

var steps_cap := 1.0e9  ## the budget: the most steps a frame may take
var _slow_frames := 0
var _wanted_ref := 1.0  ## the most steps a frame has asked for lately (decays slowly)
var _last_usec := 0
var _last_frame := -10  ## the process frame of the last call


## Process frame `frame`, at `now_usec` on a display of `frame_rate` frames a second, asks for `wanted` steps: the most it may take.
func allow(wanted: int, now_usec: int, frame: int, frame_rate: float) -> int:
	var target := 1e6 / frame_rate
	var since := now_usec - _last_usec
	if _last_usec > 0 and frame == _last_frame + 1:  # (the frame just past ran steps: its length is their cost, however long. Frames between without any were a pause or a menu. A length limit here let a frame too slow (a million bups take ~8 ms a step) hold every step it asked for: 260 ms frames)
		if since > 1.15 * target:
			_slow_frames += 1
			if _slow_frames >= 3:
				steps_cap = maxf(1.0, steps_cap * 0.8)
				_slow_frames = 0
		else:
			_slow_frames = 0
			if since < 1.05 * target:
				steps_cap = maxf(steps_cap * 1.1, steps_cap + 1.0)
	_wanted_ref = maxf(float(wanted), _wanted_ref * WANTED_REF_DECAY)  # (the most asked for lately: with several dishes a dish is asked for a few seconds one frame and a whole frame's the next, and one small request must not take what the budget has learned down to it)
	steps_cap = clampf(steps_cap, 1.0, maxf(_wanted_ref, 1.0))
	_last_usec = now_usec
	_last_frame = frame
	return int(steps_cap)
