class_name DishBackend
extends RefCounted
## Where one dish's bups run: the setting, and what Auto's rule keeps from frame to frame to decide it (how long it has wanted the
## GPU, how many frames it has wanted the processor, the correction to the cost model, the dish's turn to switch). `choose` is the
## whole decision, from the facts of the frame; the `Dish` carries it out (the GPU's world, the bups' state) and keeps the one fact
## about who holds the true bups (`gpu_on_cpu`). `BackendRule` has the numbers. The screen's scheduler (`Main`) reads and writes the
## fields marked for it.

enum Action {
	STAY,
	TO_GPU,
	TO_CPU,
	RELOAD,  ## stay on the GPU, which takes the CPU's bups back before it runs (a save or an edit has brought them over)
}

## What `choose` needs of the dish this frame.
class Facts:
	extends RefCounted
	var on_gpu := false  ## the bups are on the GPU now
	var available := false  ## the machine has a usable GPU and one that holds the dish's limit
	var state_on_cpu := false  ## the CPU's bups are the true ones just now (a save or an edit brought them over)
	var cells := 0  ## cells across the nutrient grid
	var moves := 0  ## BupSim.moves_for of the step
	var population := 0
	var clouds := 0  ## the plankton clouds in the dish

## The setting's value as StartConditions.BACKEND_*: where the bups are simulated. Changing it (the setup screen sets it with the dish's
## start, `set_setting` is for anything that changes it while the dish runs) takes effect at the next `advance`.
var setting := StartConditions.BACKEND_AUTO

# For the screen's scheduler (Main): what it writes ...
var measured_usec := 0.0  ## µs the processor really took the last frames this dish was advanced on it (a running average, set by the screen; 0 until it has been timed)
var switch_allowed := true  ## whether Auto's rule may move this dish between the processor and the GPU this frame (the screen lets one dish at a time, so each choice sees the load the last left)
var other_cpu_load := 0.0  ## µs per frame the other dishes on the processor are estimated to take (the screen sets it, so that Auto weighs the processor's whole load)
# ... and what it reads.
var cpu_cost_estimate := 0.0  ## µs the processor is estimated to need for one frame of this dish (the cost model's, at the last `choose`)
var switch_wanted := false  ## Auto's rule wants this dish moved and waits for its turn (kept until the dish is next advanced, which asks again), and ...
var switch_wanted_gpu := false  ## ... to the GPU (else to the processor)

var gpu_wanted_seconds := 0.0  ## real seconds in a row that the rule wanted the GPU
var cpu_votes := 0  ## frames in a row that Auto's rule wanted the processor while the GPU ran
var fresh := true  ## a dish just made or loaded (a new one, a save, one thawed): its first choice does not wait GPU_WAIT_SECONDS: the wait guards against a speed pressed in passing, which a loaded dish has not had
var _cpu_ratio := 1.0  ## what this machine's processor really takes per frame, as a multiple of the cost model's estimate (the model was fitted on one machine): Auto's rule uses the estimate times this
var _frame_estimate_usec := 0.0  ## the model's estimate for the frame `measured_usec` last timed
var _recent_frames := PackedFloat32Array()  ## the lengths of the last TYPICAL_FRAMES frames `choose` was asked for (real seconds, capped)
var _idle_seconds := 0.0  ## real seconds in a row on the processor with the GPU's buffers still held (see GPU_RELEASE_SECONDS)


## Sets the setting (StartConditions.BACKEND_*; anything else is Auto) and has the next `choose` ask again.
func set_setting(value: String) -> void:
	setting = value if value in StartConditions.BACKENDS else StartConditions.BACKEND_AUTO
	gpu_wanted_seconds = 0.0


## Whether the dish should give back the GPU's buffers, shaders and pipelines: it has run on the processor for GPU_RELEASE_SECONDS without
## the rule wanting the GPU again or a switch waiting (`held`: it still has them). Asked before `choose`, every frame, with the frame's length.
func idle_release(on_gpu: bool, held: bool, seconds: float) -> bool:
	if on_gpu or not held or gpu_wanted_seconds > 0.0 or switch_wanted:
		_idle_seconds = 0.0
		return false
	_idle_seconds += seconds
	if _idle_seconds < BackendRule.GPU_RELEASE_SECONDS:
		return false
	_idle_seconds = 0.0
	return true


## Chooses where the bups run for this frame, from the setting (on, off, automatic), `step_delta` (judged by BackendRule.rule_step, so one
## stray short frame does not count as a short step, though a whole frame's steps run as asked), `steps` (how many of them the frame holds,
## if the caller knows: `advance` does; 0 guesses from the length; Auto's costs take them scaled to a frame of RULE_FRAME_SECONDS by the
## length of the frame just past, `real`) and the dish's facts. The processor takes over at once when the setting or the machine says so;
## when only Auto's rule says so, after AUTO_DOWN_FRAMES frames of it saying so (the GPU's count of bups reaches the dish a few frames
## after a load), or at once while a save or an edit has the bups on the CPU. The GPU takes over only after GPU_WAIT_SECONDS of real time
## in a row of the rule wanting it, except for a dish just made or loaded (`fresh`), which goes at once when the rule wants it. Asked
## again on every frame, so a resize, a new limit, a new speed or a new setting is re-evaluated at once. A switch Auto's rule wants but
## whose turn has not come (`switch_allowed`) is only noted in `switch_wanted`.
func choose(step_delta: float, steps: int, real: float, facts: Facts) -> Action:
	var typical := 0.0
	if steps > 0 and real > 0.0:
		_recent_frames.append(real)
		if _recent_frames.size() > BackendRule.TYPICAL_FRAMES:
			_recent_frames = _recent_frames.slice(_recent_frames.size() - BackendRule.TYPICAL_FRAMES)
		typical = BackendRule.typical_frame(_recent_frames)
	var rule_delta := BackendRule.rule_step(step_delta, steps, real, typical)  # (the rule is judged on this; the steps that run keep step_delta)
	var allowed := setting != StartConditions.BACKEND_CPU
	var rule_steps := steps
	if steps > 0 and real > 0.0:
		rule_steps = maxi(1, roundi(steps * BackendRule.RULE_FRAME_SECONDS / real))  # (the same work per real second, whichever backend ran the last frame and however long it took)
	var frame_estimate := BackendRule.frame_costs(rule_delta, facts.cells, facts.moves, facts.population, steps, facts.clouds).x  # (for the frame as it really was: what `measured_usec` measures)
	if not facts.on_gpu and measured_usec > 0.0 and _frame_estimate_usec > 0.0:
		_cpu_ratio = lerpf(_cpu_ratio, clampf(measured_usec / _frame_estimate_usec, BackendRule.CPU_RATIO_MIN, BackendRule.CPU_RATIO_MAX), BackendRule.CPU_RATIO_SMOOTHING)
	_frame_estimate_usec = frame_estimate
	cpu_cost_estimate = BackendRule.frame_costs(rule_delta, facts.cells, facts.moves, facts.population, rule_steps, facts.clouds).x * _cpu_ratio
	var wants := BackendRule.wants_gpu(setting, rule_delta, facts.moves, facts.cells, facts.population, facts.on_gpu, facts.available, rule_steps, facts.clouds, other_cpu_load, _cpu_ratio)
	gpu_wanted_seconds = gpu_wanted_seconds + (real if real > 0.0 else BackendRule.RULE_FRAME_SECONDS) if wants else 0.0  # (no frame length, as when a tool calls this directly: a frame of the rule's)
	if not wants:
		fresh = false  # (a small dish: it waits like any other when it grows)
	switch_wanted = false
	if facts.on_gpu:
		cpu_votes = 0 if wants else cpu_votes + 1
		var rule_only := allowed and facts.available  # (what is left to say 'no' is Auto's rule: it must say so for a while)
		var settled := cpu_votes >= BackendRule.AUTO_DOWN_FRAMES or facts.state_on_cpu  # (bups a save or an edit brought over are the true ones, and so is their count: nothing to wait for)
		if not wants and (not rule_only or settled):
			if rule_only and setting == StartConditions.BACKEND_AUTO and not switch_allowed:
				switch_wanted = true  # (Auto's rule wants the processor: it waits its turn)
				switch_wanted_gpu = false
				return Action.RELOAD if facts.state_on_cpu else Action.STAY  # (it stays on the GPU until its turn, so the GPU runs the true bups meanwhile)
			cpu_votes = 0
			if rule_only:
				gpu_wanted_seconds = 0.0  # (Auto's rule let go: it must want the GPU for as long again before the GPU takes over)
			return Action.TO_CPU
		return Action.RELOAD if facts.state_on_cpu else Action.STAY
	if wants and (gpu_wanted_seconds >= BackendRule.GPU_WAIT_SECONDS - 1.0e-6 or fresh):
		if setting == StartConditions.BACKEND_AUTO and not switch_allowed:
			switch_wanted = true  # (Auto's rule wants the GPU: it waits its turn)
			switch_wanted_gpu = true
			return Action.STAY
		fresh = false
		cpu_votes = 0
		return Action.TO_GPU
	return Action.STAY


## What decides where the dish runs, for the debug log: the setting, how long the rule has wanted the GPU, whether Auto's one-switch-at-a-time
## turn is this dish's and whether it is waiting for it, the cost model's estimate and the timed cost of a frame on the processor (what
## the dishes' turns are budgeted by), and the processor load of the other dishes the rule adds.
func debug() -> Dictionary:
	return {
		"setting": setting,
		"gpu_wanted_seconds": gpu_wanted_seconds,
		"cpu_votes": cpu_votes,
		"switch_allowed": switch_allowed,
		"switch_wanted": switch_wanted,
		"switch_wanted_gpu": switch_wanted_gpu,
		"cpu_cost_estimate_usec": cpu_cost_estimate,
		"measured_usec": measured_usec,
		"other_cpu_load_usec": other_cpu_load,
	}
