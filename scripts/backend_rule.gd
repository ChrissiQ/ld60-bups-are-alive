class_name BackendRule
extends RefCounted
## Auto's rule for where a dish's bups run, from numbers alone: the thresholds, the cost models fitted to measurements, and the
## functions that turn them into an answer. Nothing here holds a dish's state (`DishBackend` does) or touches a node, so the rule can
## be tested and asked again after anything changes.


## The measurements behind the rule are in tools/gpu/switch_check.gd's bench mode.
const AUTO_CPU_UP_USEC := 6000.0  ## Auto: the processor is left for the GPU once its steps for one frame are estimated to take more than this (two thirds of Main.FRAME_BUDGET_USEC: the picture and the rest of the frame need the remainder) ...
const AUTO_CPU_DOWN_USEC := 3000.0  ## ... and taken back when they come below this (the gap is the hysteresis: a colony hovering about one threshold does not flip every few seconds)
const CPU_RATIO_MIN := 0.5  ## how far the cost model's estimate may be corrected by what the processor really took (below and above 1)
const CPU_RATIO_MAX := 8.0
const CPU_RATIO_SMOOTHING := 0.1  ## how much of each frame's measured-to-estimated ratio is taken in
const AUTO_MIN_POPULATION := 1  ## below this many bups (none) Auto stays on the processor: there is nothing to move. A nearly empty dish can still cost the processor most of a frame (the grid, the clouds, the nine steps), and the rule's cost test is what decides, so a small colony at x10,000 goes to the GPU as soon as the processor could not hold the speed
const GPU_WAIT_SECONDS := 0.5  ## real seconds in a row that the rule wants the GPU before it takes over: a speed button pressed in passing, or a hitch, does not move the whole state. Counted in time, not frames: a frame costs most where the dish is heaviest, so a count of frames would be longest exactly there (a frame counts at most the 0.1 s the frames are capped at)
const GPU_RELEASE_SECONDS := 60.0  ## real seconds a dish that has handed back to the processor keeps its GPU buffers and pipelines (about 0.2 GB a dish at the usual limit) before giving them back. Building them again costs a stall, so a dish that goes back and forth keeps them; one that has stayed on the processor this long is not coming straight back
const AUTO_DOWN_FRAMES := 10  ## frames in a row that Auto's rule must want the processor before the GPU lets go (the GPU's count of bups arrives a few frames after a load; the setting does not wait)
const STEPS_AT_TOP_SPEED := 9  ## steps a frame takes at x10,000 at 60 frames a second (one frame is 167 s; the step is 18.5 s): what a step this long stands for when the caller does not say how many a frame holds
const TOP_SPEED_STEP := 17.5  ## a step this long or longer is taken for a frame of several steps (x10,000 at 60 Hz: 18.5 s), shorter ones for a frame of one (x1,000: 16.7 s). A guess: `advance` knows, and passes `steps`
const RULE_FRAME_SECONDS := 1.0 / 60.0  ## the frame Auto's costs are for: a frame's steps are scaled to one this long (the frame just past may be any length: a 120 Hz display's, or one a switch held up, whose many steps would otherwise make the processor look slower than it is and switch straight back)
## Measured on the M1 Pro (full `Dish.advance`, the mean over many frames, which is what `measured_usec` averages: 369 points, dishes of
## 20, 45 and 90 mm radius, nutrient detail 100 and 400, 0, 600 and 6,000 clouds, 40 to 60,000 bups; mean error 5.5%): microseconds
## for one step by the processor, from the cells across `c`, the share of a step that solves the diffusion `f = min(1, d / DIFFUSE_INTERVAL)`,
## the motion sub-steps `m` (BupSim.moves_for), the bups `n`, the step's length `d` in seconds and the clouds `k`:
## -2.8 + 0.000857 c² + f (154.3 + 0.003648 c²) + n (0.02992 + 0.007878 m + 0.000426 d) + 0.2355 n / (1 + n / 1000)
## + k (0.009221 + 0.03929 f) + 2.93e-6 k n. The term in n / (1 + n / 1000) is what the first thousand bups cost beyond the line
## (a small colony is dearer each than a crowd). By the GPU, measured in the game's own pipeline (a real Dish drawing, hovered and
## asked its statistics every frame, vsync off, `k` steps a frame forced, the frame's time against its steps, dishes of 20, 45 and 90 mm
## and 100 and 400 cells, 1,000 to 170,000 bups; the frames the GPU bounds, not those inside the engine's own ~3 ms frame, which hide it;
## 121 points, rms error 7%, worst 20%; tools/gpu/game_check.gd gpufit): the frame is 950 + 0.015 n µs and each step
## 244 + 0.0020 c² + n (0.0060 + 0.0016 m) + 0.045 k.
## The frame's share (drawing, the readbacks and queries, the batch's events) is GPU_FRAME_USEC and GPU_FRAME_USEC_PER_BUP. Past the
## measured range (170,000 bups, 3,000 clouds, up to the 1,000,000 bups a dish may hold) the rule extrapolates the lines (a 400,000-bup
## dish measured 48 ms for nine steps against 41 ms from the lines, its clouds being a hundred thousand by the end), and the
## processor's cost is linear in the bups by construction.
const CPU_STEP_MODEL := [-2.8, 0.000857, 154.3, 0.003648, 0.02992, 0.2355, 0.007878, 0.000426, 0.009221, 0.03929, 0.00000293]
const GPU_STEP_MODEL := [244.0, 0.0020, 0.0060, 0.0016, 0.045]
const GPU_FRAME_USEC := 950.0  ## what a frame on the GPU costs besides its steps: the fixed part ...
const GPU_FRAME_USEC_PER_BUP := 0.015  ## ... and the part for each bup (every one is drawn, the frame's questions look at every slot, and the batch's births and deaths are read back). The intercept of a GPU-bound frame's time against its steps (tools/gpu/game_check.gd gpufit); a frame shorter than the engine's own (~3 ms on the M1 Pro) hides it, so for a small crowd it is the GPU's time and not what the frame shows

const TYPICAL_FRAMES := 5  ## the recent frames whose median length is the usual frame (rule_step)


## The frames of `frame_seconds` that make GPU_WAIT_SECONDS (for tools and tests that call `Dish._choose_backend` once a frame).
static func wait_frames(frame_seconds: float) -> int:
	return ceili(GPU_WAIT_SECONDS / frame_seconds - 1.0e-6)


## Estimated microseconds the steps of one frame take on the processor and on the GPU, as (cpu, gpu): `moves` the motion sub-steps of
## a step (BupSim.moves_for(step_delta)), `step_delta` its length, `steps` how many steps the frame holds (0, when not known: the
## length says, STEPS_AT_TOP_SPEED at TOP_SPEED_STEP or longer, else one).
static func frame_costs(step_delta: float, cells_across: int, moves: int, population: int, frame_steps := 0, clouds := 0) -> Vector2:
	var steps := float(frame_steps if frame_steps > 0 else (STEPS_AT_TOP_SPEED if step_delta >= TOP_SPEED_STEP else 1))
	var cells_squared := float(cells_across) * cells_across
	var diffuse_share := minf(1.0, step_delta / Dish.DIFFUSE_INTERVAL)
	var n := float(population)
	var cpu: float = CPU_STEP_MODEL[0] + CPU_STEP_MODEL[1] * cells_squared + diffuse_share * (CPU_STEP_MODEL[2] + CPU_STEP_MODEL[3] * cells_squared) + n * (CPU_STEP_MODEL[4] + CPU_STEP_MODEL[6] * moves + CPU_STEP_MODEL[7] * step_delta) + CPU_STEP_MODEL[5] * n / (1.0 + n / 1000.0) + clouds * (CPU_STEP_MODEL[8] + CPU_STEP_MODEL[9] * diffuse_share) + CPU_STEP_MODEL[10] * clouds * n
	var gpu: float = GPU_STEP_MODEL[0] + GPU_STEP_MODEL[1] * cells_squared + population * (GPU_STEP_MODEL[2] + GPU_STEP_MODEL[3] * moves) + GPU_STEP_MODEL[4] * clouds
	return Vector2(steps * cpu, GPU_FRAME_USEC + GPU_FRAME_USEC_PER_BUP * population + steps * gpu)


## The median of the recent frames' lengths (0 for none).
static func typical_frame(frames: PackedFloat32Array) -> float:
	if frames.is_empty():
		return 0.0
	var sorted := frames.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


## The step the backend rule is judged on. A step is the playback speed times the frame's length, and only the speed is the player's:
## one short frame (a stray 1.8 ms one at x100 makes a 0.18 s step) must not make the rule judge another speed and restart the takeover
## count. So a one-step frame is judged as the same speed over the usual frame (`typical`, from `typical_frame`); pressing x1 is judged
## at once, and a hitch (a long frame) does not make x1 faster. Frames of several steps are taken as they are, and without the frame's
## length or its steps the step is taken as given.
static func rule_step(step_delta: float, steps: int, real: float, typical: float) -> float:
	if steps != 1 or real <= 0.0 or typical <= 0.0:
		return step_delta
	return step_delta * typical / real


## The backend rule, as a function of what it depends on alone (so that it can be tested and re-asked after anything changes): whether the
## GPU should run these steps. `setting` is a StartConditions.BACKEND_*; `step_delta` this frame's step; `moves` BupSim.moves_for of it;
## `frame_steps` how many steps the frame holds (0: guess), `clouds` the plankton clouds in the dish (NutrientField.puff_count());
## `running_gpu` where the bups are now (Auto keeps the GPU until the processor would manage with room to spare, which is
## the hysteresis); `gpu_ok` whether the machine has a usable GPU and one that holds `limit` bups. It does not wait for GPU_WAIT_SECONDS:
## `DishBackend.choose` does.
## - off: never; on: whenever it can; auto: when the processor's estimated time for the frame is above AUTO_CPU_UP_USEC (AUTO_CPU_DOWN_USEC
##   once the GPU is running) and the GPU's is less, with at least AUTO_MIN_POPULATION bups. The processor's time for the frame is this dish's plus
##   `other_cpu_usec`, what the other dishes still on the processor are estimated to take (several dishes share one frame: it is their total that must fit).
static func wants_gpu(setting: String, step_delta: float, moves: int, cells_across: int, population: int, running_gpu: bool, gpu_ok: bool, frame_steps := 0, clouds := 0, other_cpu_usec := 0.0, cpu_ratio := 1.0) -> bool:
	if not gpu_ok or setting == StartConditions.BACKEND_CPU:
		return false
	if setting == StartConditions.BACKEND_GPU:
		return true
	if population < AUTO_MIN_POPULATION:
		return false
	var costs := frame_costs(step_delta, cells_across, moves, population, frame_steps, clouds)
	return costs.x * cpu_ratio + other_cpu_usec > (AUTO_CPU_DOWN_USEC if running_gpu else AUTO_CPU_UP_USEC) and costs.y < costs.x


## Whether the GPU can run a dish at all: the machine has a usable one (GpuWorld.available()) and it holds `limit` bups (`most` is
## GpuWorld.most_bups()).
static func usable(gpu_available: bool, limit: int, most: int) -> bool:
	return gpu_available and limit <= most

