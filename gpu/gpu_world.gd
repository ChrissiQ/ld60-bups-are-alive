class_name GpuWorld
extends RefCounted
## The simulation on the GPU as the game's dish uses it: one GpuSim on the main
## RenderingDevice, batches of steps recorded on the render thread (never submitted or waited for: the frame does that), results that
## come back a few frames later through asynchronous readbacks, and the caches the dish reads every frame. The CPU's BupSim stays: it
## keeps the family records (built from the GPU's births and deaths with BupSim.apply_events), the random numbers of the dish's own
## world (plankton, sources), the names and the pins. Its NutrientField is a copy of the GPU's field, refreshed every
## Dish.HAZE_REFRESH_MSEC (NutrientField.import_packed), which the haze, the readouts and the steering read.
##
## The dish calls none of it while Dish.gpu_active is false (see the hooks in scripts/dish.gd).
##
## How a frame goes: the dish's _advance_gpu asks steps_for(), runs its world for those steps on the CPU (plankton, sources: what
## they do to the field is recorded as events) and calls queue_batch, which records the batch at once (call_on_render_thread; the frame
## submits it: no submit or sync on the main device), with the frame's questions (pick, nearest, fractions, tracked bups), the reads of
## earlier batches' family events, and every HAZE_REFRESH_MSEC the field's copy. The getters ask their questions and answer from the
## last results; questions asked after the batch (or while paused) go out at the end of the frame. Every request's answers come back
## about two frames later through buffer_get_data_async into a queue that poll() empties on the main thread. A batch's births and
## deaths are read once its counts are known (two more frames) and applied to `sim` in batch order, each batch exactly once; a load
## (GpuSim.loads), or reset_pipeline, drops everything in flight (export_to_cpu takes the unapplied events first:
## _take_unapplied_events). On a local device (tools) a request is submitted and waited for at once, and its results are read at once.
##
## Layouts: every word of the family events, the frame's questions (QIN) and answers (OUT) and the stats samples is named in
## gpu/gpu_layout.gd (GpuLayout). The family events (BupSim.apply_events) are made by the `events` kernel after `finalize` and before
## `compact`, in bup-index order, into event set seq % GpuLayout.EVENT_SETS (buffers EVB, EVD: room for GpuSim.event_capacity of each per
## set). Picks and nearest points are found by atomicMin on d² bits (they order like the floats, for d² >= 0), ties to the smaller index.
## A stats sample is reduced in groups of 256 and then in one pass of fixed order, so it is the same every run. OUTK keeps each event
## set's OUT for finish_pending.
##
## Its parts: `questions` (GpuQuestions: what the dish asks each frame and the last answers) and `budget` (GpuStepBudget: how many
## steps a frame may take); the rest here is the transfer between the backends and the pipeline of requests and readbacks.

static var _checked := false
static var _available := false

const MIRROR_ROOM := 64  ## the least a copy of the clouds asks for past the slots known to be in use
const MIRROR_MSEC := 100  ## the field's copy is refreshed this often (Dish.HAZE_REFRESH_MSEC) while the GPU's field changes
const BIRTH_BYTES := GpuLayout.BIRTH_WORDS * 4
const DEATH_BYTES := GpuLayout.DEATH_WORDS * 4
const OUT_BIRTHS := (GpuLayout.OUT_CNT + GpuLayout.CNT_BIRTHS) * 4  ## the byte in OUT of the batch's births (CNT_BIRTHS as it was at the end of its work)
const OUT_DEATHS := (GpuLayout.OUT_CNT + GpuLayout.CNT_DEATHS) * 4

var sim: BupSim  ## the dish's CPU simulation: records, names, pins, and the dish's own random numbers
var gpu: GpuSim = null  ## the simulation on RenderingServer.get_rendering_device()
var questions := GpuQuestions.new()
var budget := GpuStepBudget.new()

var record_usec := 0  ## how long the last request took to record (µs of CPU on the render thread): for timing
var apply_usec := 0  ## the time spent in BupSim.apply_events so far (µs): for timing
var _mutex := Mutex.new()
var _arrived := []  ## [kind, request id, batch seq, epoch, data] from the readbacks' callbacks (render thread), for poll()
var _epoch := 0  ## bumped by every load or reset: results of an older epoch are dropped
var _seen_loads := -1  ## the GpuSim.loads the pipeline was last reset for
var _rid := 0  ## the next request's id
var _requests := {}  ## request id -> its Request, until its OUT arrives
var _seq := 0  ## the next batch's number
var _next_apply := 0  ## the next batch whose family events go into `sim`
var _batches := {}  ## batch number -> its Batch, until its family events are in `sim`
var _pending_reads := []  ## batches whose event counts are known and whose events are to be read with the next request
var _history_out := []
var _count := 0
var _count_known := false
var _stats := {}
var _overflows := {}
var _last_births := 0
var _event_rate := 0.0  ## births or deaths per step (the more of the two) lately: a batch is kept to half its event room by it
var _last_out_rid := -1
var _erase := PackedFloat32Array()
var _held := GpuSim.WorldEvents.new()  ## the dish's own clouds and deposits made while no batch ran, sent on their own
var _touched_frame := -1
var _flush_pending := false
var _batch_frame := -1
var _clouds_sent := 0  ## clouds sent to the GPU so far (for the size of the field's copy)
var _clouds_at_head := 0  ## ... as of the last OUT read
var _last_pcnt := -1  ## cloud slots in use as of the last OUT read (-1: none read since the load)
var _mirror_room := MIRROR_ROOM  ## slots the field's copy asks for past the ones it knows of (the clouds of deaths since the last OUT read): grows when a copy came back short
var _changed := false  ## the GPU's field changed since its last copy was asked for
var _mirror_in_flight := false
var _mirror_msec := -1000000
var _mirror_parts := {}


## A batch of steps queued and not yet applied to `sim`.
class Batch:
	var event_set := 0  ## the event set its family events go to (seq % GpuLayout.EVENT_SETS)
	var steps := 0
	var delta := 0.0  ## the step's length (s)
	var start := 0.0  ## the sim time at its start (s)
	var times := PackedFloat64Array()  ## the sim times of its history samples
	var head := false  ## its OUT has come back: births, deaths and samples are known
	var births := 0
	var deaths := 0
	var births_data: Variant = null  ## its births' events (PackedByteArray), once read
	var deaths_data: Variant = null
	var samples := []  ## its history samples (see _samples_from)


## One request recorded on the render thread: a batch or the dish's own events, the frame's questions, the eraser, the reads of earlier
## batches' family events, the field's copy.
class Request:
	var epoch := 0
	var loads := 0  ## GpuSim.loads when it was made: a request for a state replaced since is not recorded
	var rid := 0
	var seq := -1  ## its batch (-1: none)
	var samples := 0  ## the batch's history samples
	var reads := []  ## [batch, event set, births, deaths] each
	var plan := {}  ## the batch's plan for GpuSim.prepare_steps and record_steps ({}: no batch)
	var events := {}  ## the dish's own events sent on their own ({}: none)
	var questions := {}  ## GpuQuestions.questions()
	var qin := PackedByteArray()
	var erase := PackedFloat32Array()
	var mirror := 0  ## the cloud slots the field's copy reads (0: no copy)
	var clouds_sent := 0  ## _clouds_sent when it was made


## Whether the GPU path can run here: a main RenderingDevice exists (not headless, not the Compatibility renderer, not the web), every
## kernel's imported shader loaded without an error, and the device takes as many storage buffers per kernel as the largest binds.
## Worked out once. The most bups the device's dispatch limit allows is `most_bups()`.
static func available() -> bool:
	if _checked:
		return _available
	_checked = true
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return false
	var most_buffers := 0
	var all := GpuKernels.all()
	for kernel_name: String in all:
		if GpuSim.load_spirv(kernel_name) == null:
			return false
		most_buffers = maxi(most_buffers, all[kernel_name]["buffers"].size())
	for limit in [RenderingDevice.LIMIT_MAX_STORAGE_BUFFERS_PER_SHADER_STAGE, RenderingDevice.LIMIT_MAX_STORAGE_BUFFERS_PER_UNIFORM_SET]:
		var allowed := rd.limit_get(limit)
		if allowed > 0 and allowed < most_buffers:  # (Metal reports no limit as -1)
			return false
	# (the scans' groups are 256 threads wide and keep 256 words in shared memory; a device that cannot is not used)
	var group_size := rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X)
	var shared_bytes := rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_SHARED_MEMORY_SIZE)
	if (group_size > 0 and group_size < 256) or (shared_bytes > 0 and shared_bytes < 256 * 4):
		return false
	if most_bups() < StartConditions.DEFAULT_BUP_LIMIT:  # (a dish of the usual size must fit: see most_bups)
		return false
	_available = true
	return true


## The most bup slots a dish may ask the GPU for. `compact` and `copy` run one thread for each 16 bytes of the bups' buffer (six per bup), and
## a dispatch has at most LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X groups in a dimension (65,535 on Direct3D 12: about 700,000 bups in one row), so
## GpuSim.dispatch makes a grid of rows when it must; what is left is the GPU's memory (about 480 bytes a slot: 630 MB at 1,000,000, the
## most a dish holds), which this does not know. 0 when there is no device.
static func most_bups() -> int:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return 0
	return StartConditions.MAX_BUP_LIMIT * 4  # (room beyond the slider: the dish never asks for more than MAX_BUP_LIMIT)


## Keeps the dish's CPU simulation, which holds the records, the names, the pins and the dish's own random numbers.
## `local_device`: run on a local RenderingDevice of its own (tools and tests that have a window but do not use the main device: GpuSim.new()),
## instead of the main device that load_from_cpu makes `gpu` on.
func _init(cpu_sim: BupSim, local_device := false) -> void:
	sim = cpu_sim
	if local_device:
		gpu = GpuSim.new()


## CPU -> GPU: makes `gpu` if there is none (GpuSim.new(RenderingServer.get_rendering_device())), and loads it from the CPU:
## the bups (sim.export_state_bytes(), next id sim.get_next_id()), the field (field.export_packed(), export_owner(),
## export_fill_weights(), get_diffusion()), and `dish_params`: "radius", "limit", "seed", "upkeep_scale", "feed_per_second",
## "step_seconds". Then the CPU field records instead of changing (field.set_recording(true)) and the CPU's bups are cleared
## (the records stay). Runs on the render thread (RenderingServer.call_on_render_thread). Drops any result still in flight.
##
## The GPU's random stream is seeded from the dish's seed and one number from the CPU's stream (so that each load, after a switch, draws
## fresh noise instead of the same noise again from step 0; the CPU's stream is the dish's, and carries on).
## What does not cross, and why that is fine: the CPU's diffusion and feed accumulators, which only the CPU's own step moves (sim.step_world does not),
## so what they hold when the GPU takes over is still there, and still owed to the CPU's field, when the CPU takes over again.
## Ends with `reset_pipeline(bups)`.
func load_from_cpu(field: NutrientField, dish_params: Dictionary) -> void:
	var records := sim.export_state_bytes()
	var state := GpuSim.State.of_field(field, float(dish_params.get("radius", 0.0)), records, SimConstants.build())
	state.dish_seed = int(dish_params.get("seed", 1)) + int(sim.random_float() * 2147483647.0) * 0x9E3779B1
	state.acetate = sim.get_acetate().export_packed()["conc"]
	state.next_id = sim.get_next_id()
	state.limit = int(dish_params.get("limit", 0))
	state.upkeep = float(dish_params.get("upkeep_scale", 1.0))
	state.feed = float(dish_params.get("feed_per_second", 0.0))
	state.step = float(dish_params.get("step_seconds", 20.0))
	_transfer_call(func() -> void:
		if gpu == null:
			gpu = GpuSim.new(RenderingServer.get_rendering_device())
		gpu.load_state(state))
	field.set_recording(true)
	var answers := _answers_from_cpu(records, dish_params)  # (while the CPU still has the bups)
	sim.import_state_bytes(PackedByteArray())  # (the bups are the GPU's now; the family records stay)
	reset_pipeline(records.size() / GpuLayout.RECORD_BYTES)
	_take_answers(answers)


## GPU -> CPU, stalling: reads the bups, the next id, the grid with what the last step's deaths put on it (their sum waits in
## DPLO/DPHI until the next step's `dep_apply`), the acetate and the live clouds (GpuSim's readbacks), applies every batch's events
## not yet applied, in order (finish_pending), then sim.import_state_bytes(...), field.import_packed(...), sim.set_next_id(the GPU's
## next id), and turns the field's recording off. Results of those batches that arrive later are ignored (by their sequence number).
##
## What the field has recorded since the last batch was queued (a drop or a burst of the dish's own world, not yet sent) is added to
## the grid and the clouds it reads back, so that nothing the player or the world did is lost. Then `reset_pipeline(bups)` as in
## load_from_cpu.
func export_to_cpu(field: NutrientField) -> void:
	assert(gpu != null, "GpuWorld.export_to_cpu: nothing was loaded")
	var read := {}
	_transfer_call(func() -> void:
		read["next_id"] = gpu.next_id()
		read["records"] = gpu.read_bups()
		read["conc"] = gpu.read_conc_settled()
		read["acetate"] = gpu.read_acetate()
		read["clouds"] = gpu.read_clouds())
	finish_pending()
	var conc: PackedFloat32Array = read["conc"]
	var clouds: PackedFloat32Array = read["clouds"]
	_apply_pending_erase(conc, clouds)
	var late_cells := field.take_recorded_cells()
	var late_amounts := field.take_recorded_amounts()
	for i in late_cells.size():
		conc[late_cells[i]] += late_amounts[i]
	clouds.append_array(field.take_recorded_puffs())
	field.set_recording(false)
	field.import_packed(conc, clouds)
	sim.get_acetate().import_packed(read["acetate"], PackedFloat32Array())
	sim.import_state_bytes(read["records"])
	sim.set_next_id(maxi(int(read["next_id"]), sim.get_next_id()))
	reset_pipeline(read["records"].size() / GpuLayout.RECORD_BYTES)
	_take_answers(_answers_from_cpu(read["records"]))  # (the dish may still ask here: a save leaves the GPU running, see Dish._gpu_on_cpu)


## The answers to what the dish asks every frame (the stats, and GpuQuestions.answers_from_cpu's: the fractions, the tracked bups'
## records, the last pick and nearest points), worked out on the CPU from its bups (`records`: sim.export_state_bytes()), for a load or
## an export: a load drops every answer still on its way, and without these the screen would show no stats, no fraction (a goal's hold
## would end) and no selected bup until the first readback. `dish_params` may name more to answer: "tracked" (ids) and "fractions"
## ([gene name, threshold] pairs) the dish shows; they are asked from now on as track() and fraction_with_gene_at_least() would.
func _answers_from_cpu(records: PackedByteArray, dish_params := {}) -> Dictionary:
	var answers := questions.answers_from_cpu(sim, records, dish_params, Engine.get_process_frames())
	answers["stats"] = sim.population_stats()
	return answers


## Takes the answers of _answers_from_cpu as the last ones known (after reset_pipeline).
func _take_answers(answers: Dictionary) -> void:
	_stats = answers["stats"]
	questions.take_answers(answers)


## Runs `work` where the device may be used: for the main device, on the render thread (RenderingServer.call_on_render_thread), and
## waits for it; a local device has no such thread, and `work` just runs.
func _transfer_call(work: Callable) -> void:
	if gpu != null and not gpu.is_main:
		work.call()
		return
	var finished := Semaphore.new()
	RenderingServer.call_on_render_thread(func() -> void:
		work.call()
		finished.post())
	finished.wait()  # (when the render thread is this one the callable has already run, and the wait is over at once)


## Queues a batch of steps for this frame and records it at once (on the render thread), with the questions asked lately, the
## reads of earlier batches' family events, and the field's copy when due. `plan`: "steps" (int), "delta" (s per step), "start_time"
## (s, at the batch's start), "events" ({"ranges", "puffs", "cells", "amounts"}: the clouds and deposits the dish's world made, per step,
## as GpuSim._upload_events takes them), "feed_per_second", "upkeep_scale", "limit", "history_steps" (PackedInt32Array: the steps after
## which a history sample is taken, ascending, at most GpuLayout.MAX_SAMPLES), "erase" (Array of [x, y, radius, strength]: discs to
## erase before the batch, as well as those given to erase_disc). Ask `steps_for` first: it says how many steps may be queued (0: none
## this frame).
func queue_batch(plan: Dictionary) -> void:
	assert(gpu != null, "GpuWorld.queue_batch: no GPU state (load_from_cpu first)")
	_sync_epoch()
	assert(can_queue(), "GpuWorld.queue_batch: the batch's event set is still in use (ask steps_for first)")
	for disc in plan.get("erase", []):
		_add_erase(disc[0], disc[1], disc[2], disc[3])
	_flush_now(plan)


## On the main thread: applies the results that have arrived, in batch order: lineage events into `sim` (apply_events, each batch
## once), the counts, the stats, the history samples, the answers to the questions, the field's copy (field.import_packed). Cheap when
## nothing has arrived; every getter below calls it once a frame.
func poll() -> void:
	_sync_epoch()
	_mutex.lock()
	var arrived := _arrived
	_arrived = []
	_mutex.unlock()
	for item: Array in arrived:
		var kind: String = item[0]
		var rid: int = item[1]
		var seq: int = item[2]
		if item[3] != _epoch:
			continue  # (from a state that has been replaced)
		var data: PackedByteArray = item[4]
		match kind:
			"out":
				_take_out(rid, data)
			"births":
				if _batches.has(seq):
					(_batches[seq] as Batch).births_data = data
			"deaths":
				if _batches.has(seq):
					(_batches[seq] as Batch).deaths_data = data
			"conc", "mirror":
				var parts: Dictionary = _mirror_parts.get(rid, {})
				parts[kind] = data
				_mirror_parts[rid] = parts
				if parts.size() == 2:
					_mirror_parts.erase(rid)
					_mirror_in_flight = false
					_import_mirror(parts["conc"], parts["mirror"])
	_apply_ready()
	if not _pending_reads.is_empty() and not _flush_pending:  # (their reads go out at the end of the frame, if no batch takes them first)
		_flush_pending = true
		_end_of_frame.call_deferred()


## The history samples that have arrived since the last call, in order: [{"time": float (sim seconds), "stats": Dictionary with
## BupSim.population_stats' keys}]. The dish records each with Dish._record_history_from.
func take_history_samples() -> Array:
	poll()
	var out := _history_out
	_history_out = []
	return out


## The population, as last read back (a few frames behind the GPU); the count at the load until the first readback. 0 also when
## nothing is known yet (no GPU state).
func bup_count() -> int:
	_touch()
	return _count if _count_known else 0


## Whether bup_count() is a real count (a state is loaded): the dish's extinct signal waits for it.
func count_known() -> bool:
	return _count_known


## The same keys as BupSim.population_stats (count, each gene's mean, harm, mutations, mutator, donor, key, generation), as last read back. Until the first
## readback after a load: the count, and the means as last known (0 if never).
func population_stats() -> Dictionary:
	_touch()
	if _stats.is_empty():
		var empty := {"count": _count, "harm": 0.0, "mutations": 0.0, "generation": 0.0, "mutator": 1.0, "donor": 0.0, "key": 0.0}
		for gene in GpuLayout.GENE_NAMES:
			empty[gene] = 0.0
		return empty
	return _stats


## The share of bups whose `gene` is at least `threshold` (BupSim.fraction_with_gene_at_least): registers the pair (up to 4, the
## least recently asked dropped) for the frame's questions and returns the last answer, 0.0 until there is one.
func fraction_with_gene_at_least(gene: String, threshold: float) -> float:
	_touch()
	return questions.ask_fraction(gene, threshold, Engine.get_process_frames())


## The bup under a point of the dish (BupSim.pick_bup's rule): asks for it in this frame's questions and returns the last answer for a
## point within 2 pixels of this one (with the same slack), else -1. The answer carries the bup's whole record, so a picked bup is tracked
## with no gap. A `hover` (the pointer is moving, the answer is a few frames old) is answered from a point
## GpuQuestions.HOVER_POINT_PIXELS away and whatever slack it was asked with (the slack changes with every step of a zoom); a click is exact.
func pick_bup(local: Vector2, slack: float, pixel_um: float, hover := false) -> int:
	_touch()
	return questions.ask_pick(local, slack, pixel_um, hover, Engine.get_process_frames())


## BupSim.nearest_and_count (the distance to the nearest bup, -1 if none, and how many lie within `near`): asks for it (up to 4 points
## a frame) and returns the last answer for a point within 2 pixels of this one with the same `near`, else the last answer with the same
## `near`, else (-1, 0).
func nearest_and_count(local: Vector2, near: float) -> Vector2:
	_touch()
	return questions.ask_nearest(local, near, Engine.get_process_frames())


## Keeps this bup's record coming back every frame (up to 8, the least recently asked dropped). The dish calls it every frame for each
## bup it shows (the selected and the hovered one); an id not asked for again for GpuQuestions.TRACK_FRAMES frames is dropped.
func track(id: int) -> void:
	_touch()
	questions.ask_track(id, Engine.get_process_frames())


## BupSim.bup_info for a tracked (or picked) bup, from its last record (sim.info_from_state); {} if it is not known or no longer alive.
func bup_info(id: int) -> Dictionary:
	_touch()
	var record := questions.record_of(id)
	return sim.info_from_state(record, 0) if not record.is_empty() else {}


## Where a tracked bup is (dish coordinates), from its last record; (0, 0) if it is not known.
func bup_pos(id: int) -> Vector2:
	_touch()
	var record := questions.last_record(id)
	return Vector2(record.decode_float(GpuLayout.R_X * 4), record.decode_float(GpuLayout.R_Y * 4)) if not record.is_empty() else Vector2.ZERO


## BupSim.bup_radius for a tracked bup: half the length it is drawn at, its own or the least that shows (0 if it is not known).
func bup_radius(id: int, pixel_um: float) -> float:
	_touch()
	var record := questions.last_record(id)
	if record.is_empty() or gpu == null:
		return 0.0
	return 0.5 * maxf(record.decode_float(GpuLayout.R_MASS * 4) * float(gpu.consts["mass_um"]), float(gpu.consts["min_length_px"]) * pixel_um)


## BupSim.bup_steering for a tracked bup: sim.steering_at(its place, its speed, its sense range) on the field's copy.
func bup_steering(id: int) -> Vector3:
	_touch()
	var record := questions.last_record(id)
	if record.is_empty() or gpu == null:
		return Vector3(0.0, 0.0, 0.5)
	return sim.steering_at(Vector2(record.decode_float(GpuLayout.R_X * 4), record.decode_float(GpuLayout.R_Y * 4)), record.decode_float(GpuLayout.R_SPEED * 4), _sense_range(record))


## BupSim.bup_steer_bytes for a tracked bup: field.steer_bytes(its speed, its sense range, max_alpha) on the field's copy; while its
## record is not known, a clear picture of the field's size (nothing tinted), so the dish can always make an image of it.
func bup_steer_bytes(id: int, max_alpha: float) -> PackedByteArray:
	_touch()
	var record := questions.last_record(id)
	var field := sim.get_field()
	if record.is_empty() or gpu == null:
		var clear := PackedByteArray()
		clear.resize(field.get_size() * field.get_size() * 4)
		return clear
	return field.steer_bytes(record.decode_float(GpuLayout.R_SPEED * 4), _sense_range(record), max_alpha)


## Whether a place is known for this bup (it is tracked or was picked, and its record has come back; or it died since and its last
## place is kept): until then bup_pos is (0, 0), so the dish draws nothing for it.
func knows(id: int) -> bool:
	return questions.knows(id)


## The eraser on the GPU path: erases the disc from the field's copy at once (what is seen, and the amount returned: energy taken, as
## NutrientField.erase_disc) and from the GPU's field before its next step (recorded this frame, also while paused).
func erase_disc(local: Vector2, disc_radius: float, strength: float) -> float:
	_touch()
	_add_erase(local.x, local.y, disc_radius, strength)
	return sim.get_field().erase_disc(local, disc_radius, strength)


## How many of the `wanted` steps of this frame may be queued: no more than the budget allows (GpuStepBudget, from the frames'
## lengths), and no more than half the batch's room for births and deaths (GpuSim.event_capacity) at the rate they came lately (1.5
## times it; 2% of the bups a step until a batch has been read: at least one step). 0 when the event set the batch would write is still
## waiting to be read (rare: the GPU or the readbacks are behind), so nothing is queued this frame.
func steps_for(wanted: int) -> int:
	_sync_epoch()
	var allowed := budget.allow(wanted, Time.get_ticks_usec(), Engine.get_process_frames(), _frame_rate())
	if gpu == null or not can_queue():
		return 0
	var steps := mini(wanted, allowed)
	steps = mini(steps, maxi(1, int(0.5 * gpu.event_capacity / maxf(1.5 * _event_rate, 1.0))))
	return clampi(steps, 0, GpuLayout.MAX_STEPS_PER_BATCH)


## Whether a batch can be queued now: the event set it would write (seq % EVENT_SETS) is free, its last batch applied (or dropped with a
## load). (Not merely asked for: the stalling reads of _take_unapplied_events read every pending batch's set again.)
func can_queue() -> bool:
	var older := _seq - GpuLayout.EVENT_SETS
	return older < 0 or not _batches.has(older)


## The batches queued whose family events are not yet in `sim`.
func pending_batches() -> int:
	return _batches.size()


## What found no room on the GPU since the load, as last read back: clouds sent to the grid for want of a slot, entries cut from the
## lists of clouds by place, births and deaths that found no event slot (each of those leaves a hole in the family records).
func overflows() -> Dictionary:
	return _overflows


## Stalls until every batch queued so far is done, reads their family events and history samples straight from the GPU, and applies
## them in order (events into `sim`, samples to take_history_samples; the events from _take_unapplied_events). Results of those
## batches that arrive later are ignored. After it, `sim`'s records are those of the GPU's state (export_to_cpu, and tools).
func finish_pending() -> void:
	for events: Dictionary in _take_unapplied_events():
		sim.apply_events(events["births"], events["deaths"], events["first_step_end"], events["step_seconds"])


## (for export_to_cpu) Stalls until every batch queued so far is done and returns the family events of every batch not yet applied
## to `sim`, in batch order, each once: [{"births": PackedByteArray, "deaths": PackedByteArray, "first_step_end": float, "step_seconds":
## float}] (BupSim.apply_events' arguments). Their history samples go to take_history_samples: after a switch to the CPU, the dish must
## record those (take_history_samples -> _record_history_from) before its first CPU step, or they come out of order later. Results of
## those batches that arrive later are ignored. Needs the render thread to be the main thread (the project's default thread model): the
## reads are made on it, stalling.
func _take_unapplied_events() -> Array:
	poll()
	var out := []
	var seqs: Array = _batches.keys()
	seqs.sort()
	if seqs.is_empty():
		return out
	var sets := {}
	for seq: int in seqs:
		sets[seq] = (_batches[seq] as Batch).event_set
	var got := {}
	RenderingServer.call_on_render_thread(_read_batches_now.bind(sets, got))
	if got.size() != seqs.size():
		push_error("GpuWorld: the stalling reads did not come back on this thread (a separate render thread?); %d batches' family events are lost" % seqs.size())
	for seq: int in seqs:
		if not got.has(seq):
			continue
		var batch: Batch = _batches[seq]
		_history_out.append_array(_samples_from(got[seq]["head"], batch))
		out.append({"births": got[seq]["births"], "deaths": got[seq]["deaths"], "first_step_end": batch.start + batch.delta, "step_seconds": batch.delta})
	_batches.clear()
	_pending_reads.clear()
	_next_apply = _seq
	return out


# ---- inside --------------------------------------------------------------------------------------------------------------------

## Once a frame, from the getters: the results that have arrived, and a look at the end of the frame for questions to send.
func _touch() -> void:
	var frame := Engine.get_process_frames()
	if frame == _touched_frame:
		return
	_touched_frame = frame
	poll()
	if not _flush_pending:
		_flush_pending = true
		_end_of_frame.call_deferred()


## At the end of the frame: sends what is waiting (new questions, erasing, event reads, the dish's own events while no batch ran, the
## field's copy) if anything is.
func _end_of_frame() -> void:
	_flush_pending = false
	if gpu == null:
		return
	_sync_epoch()
	var q := questions.questions(Engine.get_process_frames())
	var work := questions.differ_from_sent(q) or not _erase.is_empty() or not _pending_reads.is_empty() or _mirror_due()
	if not work and _batch_frame != Engine.get_process_frames():
		_held = GpuSim.WorldEvents.new()
		_held.add_step(sim.get_field())
		work = not _held.is_empty()
	if work:
		_flush_now({})


## Assembles one request (the batch of `plan` if it has steps, or the held events of the dish's own world, the questions, the erasing,
## the event reads, the field's copy) and records it on the render thread.
func _flush_now(plan: Dictionary) -> void:
	if gpu == null:
		return
	var frame := Engine.get_process_frames()
	var request := Request.new()
	request.epoch = _epoch
	request.loads = gpu.loads
	request.rid = _rid
	_rid += 1
	# the family events of earlier batches whose counts are known: read before this batch can write their set again
	for seq: int in _pending_reads:
		if _batches.has(seq):
			var b: Batch = _batches[seq]
			request.reads.append([seq, b.event_set, b.births, b.deaths])
	_pending_reads.clear()
	var steps: int = plan.get("steps", 0)
	if steps > 0:
		var seq := _seq
		_seq += 1
		var history: PackedInt32Array = plan.get("history_steps", PackedInt32Array())
		assert(history.size() <= GpuLayout.MAX_SAMPLES)
		var batch := Batch.new()
		batch.event_set = seq % GpuLayout.EVENT_SETS
		batch.steps = steps
		batch.delta = plan["delta"]
		batch.start = plan.get("start_time", 0.0)
		for k in history:
			batch.times.append(batch.start + (k + 1) * batch.delta)
		_batches[seq] = batch
		var gpu_plan := plan.duplicate()
		gpu_plan["event_set"] = batch.event_set
		gpu_plan["history_steps"] = history
		request.seq = seq
		request.plan = gpu_plan
		request.samples = history.size()
		var events: Dictionary = plan.get("events", {})
		_clouds_sent += (events.get("puffs", PackedFloat32Array()) as PackedFloat32Array).size() / GpuLayout.EV_PUFF_FLOATS
		_batch_frame = frame
		_changed = true
	elif not _held.is_empty():
		request.events = _held.as_dict()
		_clouds_sent += _held.cloud_count()
		_changed = true
	_held = GpuSim.WorldEvents.new()
	# the questions
	var q := questions.questions(frame)
	questions.mark_sent(q)
	request.questions = q
	request.qin = GpuQuestions.qin(q)
	request.erase = _erase
	if not _erase.is_empty():
		_changed = true
	_erase = PackedFloat32Array()
	# the field's copy
	if _mirror_due():
		request.mirror = mini(gpu.puff_capacity, _last_pcnt + (_clouds_sent - _clouds_at_head) + _mirror_room)
		_mirror_in_flight = true
		_mirror_msec = Time.get_ticks_msec()
		_changed = false
	request.clouds_sent = _clouds_sent
	_requests[request.rid] = request
	RenderingServer.call_on_render_thread(_record.bind(request))


## On the render thread: records one request (see _flush_now) and asks for its results. Touches only `gpu` and the request.
func _record(request: Request) -> void:
	if gpu == null or gpu.loads != request.loads:
		return  # (the state was replaced since: its results would be dropped anyway)
	var started := Time.get_ticks_usec()
	var rd := gpu.rd
	var epoch := request.epoch
	var rid := request.rid
	for read: Array in request.reads:
		var seq: int = read[0]
		var base: int = read[1] * gpu.event_capacity
		if read[2] > 0:
			_read(gpu.buffer("EVB"), base * BIRTH_BYTES, read[2] * BIRTH_BYTES, ["births", rid, seq, epoch])
		if read[3] > 0:
			_read(gpu.buffer("EVD"), base * DEATH_BYTES, read[3] * DEATH_BYTES, ["deaths", rid, seq, epoch])
	var plan := request.plan
	var steps: int = plan.get("steps", 0)
	if steps > 0:
		gpu.prepare_steps(steps, plan)
	elif not request.events.is_empty():
		gpu.prepare_events(request.events)
	var erase := request.erase
	gpu.prepare_frame(request.qin, erase)
	var q := request.questions
	var cl := rd.compute_list_begin()
	gpu.record_erase(cl, erase.size() / 4)
	if steps > 0:
		gpu.record_steps(cl, steps, plan)
	elif not request.events.is_empty():
		gpu.record_events(cl)
	gpu.record_frame(cl, not q["pick"].is_empty(), not q["near"].is_empty() or not q["fractions"].is_empty(), not q["tracked"].is_empty())
	var words: int = GpuLayout.OUT_STATS + GpuLayout.STATS_WORDS * (1 + request.samples)
	if steps > 0:
		gpu.record_keep(cl, plan["event_set"], words)
	var slots := request.mirror
	if slots > 0:
		gpu.record_mirror(cl, slots)
	rd.compute_list_end()
	if not gpu.is_main:
		rd.submit()  # (a local device: tools)
		rd.sync()
	_read(gpu.buffer("OUT"), 0, words * 4, ["out", rid, request.seq, epoch])
	if slots > 0:
		_read(gpu.buffer("CONC"), 0, gpu.n * gpu.n * 4, ["conc", rid, -1, epoch])
		_read(gpu.buffer("MIRROR"), 0, (1 + slots * 5) * 4, ["mirror", rid, -1, epoch])
	record_usec = Time.get_ticks_usec() - started


## Reads part of a buffer for poll(): on the main device asynchronously (the data as it is at this point of the frame's work, a few
## frames later), on a local device at once (everything recorded has been waited for). `tag`: [kind, request id, batch, epoch].
func _read(buffer: RID, offset: int, size: int, tag: Array) -> void:
	if gpu.is_main:
		gpu.rd.buffer_get_data_async(buffer, _on_data.bind(tag[0], tag[1], tag[2], tag[3]), offset, size)
	else:
		_on_data(gpu.rd.buffer_get_data(buffer, offset, size), tag[0], tag[1], tag[2], tag[3])


## A readback's callback (on the render thread): queued for poll().
func _on_data(data: PackedByteArray, kind: String, rid: int, seq: int, epoch: int) -> void:
	_mutex.lock()
	_arrived.append([kind, rid, seq, epoch, data])
	_mutex.unlock()


## On the render thread, stalling: each batch's kept OUT, births and deaths (finish_pending).
func _read_batches_now(sets: Dictionary, got: Dictionary) -> void:
	if gpu == null:
		return
	var rd := gpu.rd
	var words := GpuLayout.OUT_WORDS
	for seq: int in sets:
		var event_set: int = sets[seq]
		var head := rd.buffer_get_data(gpu.buffer("OUTK"), event_set * words * 4, words * 4)
		var births := mini(head.decode_u32(OUT_BIRTHS), gpu.event_capacity)
		var deaths := mini(head.decode_u32(OUT_DEATHS), gpu.event_capacity)
		var base: int = event_set * gpu.event_capacity
		got[seq] = {
			"head": head,
			"births": rd.buffer_get_data(gpu.buffer("EVB"), base * BIRTH_BYTES, births * BIRTH_BYTES) if births > 0 else PackedByteArray(),
			"deaths": rd.buffer_get_data(gpu.buffer("EVD"), base * DEATH_BYTES, deaths * DEATH_BYTES) if deaths > 0 else PackedByteArray(),
		}


## The frame's answers (OUT) of request `rid`.
func _take_out(rid: int, data: PackedByteArray) -> void:
	var request: Request = _requests.get(rid)
	_requests.erase(rid)
	if request == null:
		return
	if rid >= _last_out_rid:  # (the answers of an older request than the newest read are stale; its batch still needs its head below)
		_take_answers_from_out(rid, data, request)
	var seq := request.seq
	if seq >= 0 and _batches.has(seq):
		var batch: Batch = _batches[seq]
		batch.births = mini(data.decode_u32(OUT_BIRTHS), gpu.event_capacity)
		batch.deaths = mini(data.decode_u32(OUT_DEATHS), gpu.event_capacity)
		batch.samples = _samples_from(data, batch)
		batch.head = true
		_last_births = data.decode_u32(OUT_BIRTHS)
		var per_step := maxf(data.decode_u32(OUT_BIRTHS), data.decode_u32(OUT_DEATHS)) / maxf(batch.steps, 1)
		_event_rate = maxf(per_step, 0.8 * _event_rate)  # (up at once, down slowly)
		if batch.births > 0 or batch.deaths > 0:
			_pending_reads.append(seq)


## What the newest OUT says: the counts, the stats and the answers to the questions asked with it.
func _take_answers_from_out(rid: int, data: PackedByteArray, request: Request) -> void:
	_last_out_rid = rid
	var count := data.decode_u32((GpuLayout.OUT_CNT + GpuLayout.CNT_BUPS) * 4)
	_count = count
	_count_known = true
	_last_pcnt = data.decode_u32((GpuLayout.OUT_PCNT + GpuLayout.PCNT_SLOTS) * 4)
	_clouds_at_head = request.clouds_sent
	_overflows = {
		"clouds_to_grid": data.decode_u32((GpuLayout.OUT_PCNT + GpuLayout.PCNT_TO_GRID) * 4), "list_entries_cut": data.decode_u32((GpuLayout.OUT_PCNT + GpuLayout.PCNT_CUT) * 4),
		"births_lost": data.decode_u32((GpuLayout.OUT_CNT + GpuLayout.CNT_BIRTHS_LOST) * 4), "deaths_lost": data.decode_u32((GpuLayout.OUT_CNT + GpuLayout.CNT_DEATHS_LOST) * 4)}
	_stats = _stats_at(data, 0)
	questions.take_out(data, request.questions, count)


## The batch's history samples in an OUT (as _take_out or finish_pending read it).
func _samples_from(data: PackedByteArray, batch: Batch) -> Array:
	var out := []
	for j in batch.times.size():
		out.append({"time": batch.times[j], "stats": _stats_at(data, j + 1)})
	return out


## Stats sample `sample` of an OUT as BupSim.population_stats' dictionary.
func _stats_at(data: PackedByteArray, sample: int) -> Dictionary:
	var o := (GpuLayout.OUT_STATS + GpuLayout.STATS_WORDS * sample) * 4
	var count := int(data.decode_float(o + GpuLayout.ST_COUNT * 4))
	var per := 1.0 / maxf(count, 1)
	var out := {"count": count}
	for g in 4:
		out[GpuLayout.GENE_NAMES[g]] = data.decode_float(o + (GpuLayout.ST_SPEED + g) * 4) * per
	out["harm"] = data.decode_float(o + GpuLayout.ST_HARM * 4) * per
	out["mutations"] = data.decode_float(o + GpuLayout.ST_MUTATIONS * 4) * per
	out["mutator"] = data.decode_float(o + GpuLayout.ST_MUTATOR * 4) * per
	out["donor"] = float(data.decode_u32(o + GpuLayout.ST_DONORS * 4)) * per
	out["key"] = data.decode_float(o + GpuLayout.ST_KEY * 4) * per
	out["generation"] = data.decode_float(o + GpuLayout.ST_DIVISIONS * 4) * per
	return out


## Applies, in batch order, every batch whose results are all here: its history samples, then its family events (BupSim.apply_events).
func _apply_ready() -> void:
	while _batches.has(_next_apply):
		var batch: Batch = _batches[_next_apply]
		if not batch.head:
			return
		if batch.births > 0 and batch.births_data == null:
			return
		if batch.deaths > 0 and batch.deaths_data == null:
			return
		_history_out.append_array(batch.samples)
		if batch.births > 0 or batch.deaths > 0:
			var started := Time.get_ticks_usec()
			var births: PackedByteArray = batch.births_data if batch.births_data != null else PackedByteArray()
			var deaths: PackedByteArray = batch.deaths_data if batch.deaths_data != null else PackedByteArray()
			sim.apply_events(births, deaths, batch.start + batch.delta, batch.delta)
			apply_usec += Time.get_ticks_usec() - started
		_batches.erase(_next_apply)
		_next_apply += 1


## A load (GpuSim.loads changed) makes every result in flight stale: they are dropped, and the counts start from the loaded state.
func _sync_epoch() -> void:
	if gpu == null or gpu.loads == _seen_loads:
		return
	if not _batches.is_empty():
		push_warning("GpuWorld: a new state was loaded with %d batches' family events not applied (_take_unapplied_events first)" % _batches.size())
	reset_pipeline(gpu.count)


## Drops every result in flight and every batch not yet applied (their events are lost: take them
## first with _take_unapplied_events), starts afresh, and takes `bups` as the count until the first readback.
func reset_pipeline(bups: int) -> void:
	if gpu != null:
		_seen_loads = gpu.loads
	_epoch += 1
	_batches.clear()
	_next_apply = _seq
	_pending_reads.clear()
	_requests.clear()
	_count = bups
	_count_known = true
	if not _stats.is_empty():
		_stats["count"] = bups
	questions.reset()
	_mirror_parts.clear()
	_mirror_in_flight = false
	_changed = false
	_last_pcnt = -1
	_mirror_room = MIRROR_ROOM
	_last_births = 0
	_event_rate = 0.02 * bups


func _mirror_due() -> bool:
	return _changed and not _mirror_in_flight and _last_pcnt >= 0 and Time.get_ticks_msec() - _mirror_msec >= MIRROR_MSEC


func _import_mirror(conc: PackedByteArray, mirror: PackedByteArray) -> void:
	var field := sim.get_field()
	var floats := conc.to_float32_array()
	if floats.size() != field.get_size() * field.get_size():
		return  # (the field was remade since)
	var clouds := mirror.to_float32_array()
	var copied := (clouds.size() - 1) / 5
	var in_use := int(clouds[0])
	if in_use > copied:
		_mirror_room += in_use - copied  # (deaths since the last OUT read made clouds past the slots asked for: ask for room for them, and again soon)
		_changed = true
	field.import_packed(floats, clouds.slice(1))


## The erasing the GPU has not run yet (discs asked since the last batch), done to a copy read back from it, as the erase kernels would: the
## field on the CPU already lost it when it was asked, and the copy read back must not give it back.
func _apply_pending_erase(conc: PackedFloat32Array, clouds: PackedFloat32Array) -> void:
	var n := gpu.n
	for e in _erase.size() / 4:
		var x := _erase[e * 4]
		var y := _erase[e * 4 + 1]
		var reach := _erase[e * 4 + 2]
		var strength := _erase[e * 4 + 3]
		for i in n * n:
			var dx := (float(i % n) + 0.5) * gpu.spacing - gpu.origin - x
			var dy := (float(i / n) + 0.5) * gpu.spacing - gpu.origin - y
			var dist := sqrt(dx * dx + dy * dy)
			if dist < reach:
				conc[i] -= conc[i] * strength * (1.0 - dist / reach)
		for k in clouds.size() / 5:
			var dist := Vector2(clouds[k * 5] - x, clouds[k * 5 + 1] - y).length()
			if dist < reach:
				clouds[k * 5 + 2] -= clouds[k * 5 + 2] * strength * (1.0 - dist / reach)
	_erase = PackedFloat32Array()


func _add_erase(x: float, y: float, disc_radius: float, strength: float) -> void:
	if _erase.size() >= GpuLayout.MAX_ERASE * 4:
		return  # (more than a frame's worth: the brush moves a few times a frame at most)
	_erase.append_array(PackedFloat32Array([x, y, disc_radius, strength]))


## The sense range of a record's bup (BupSim's: sense * sqrt(sqrt(mass) / reference_size)).
func _sense_range(record: PackedByteArray) -> float:
	return record.decode_float(GpuLayout.R_SENSE * 4) * sqrt(sqrt(record.decode_float(GpuLayout.R_MASS * 4)) / float(gpu.consts["reference_size"]))


func _frame_rate() -> float:
	if Engine.max_fps > 0:
		return Engine.max_fps
	var rate := DisplayServer.screen_get_refresh_rate()
	return rate if rate > 0.0 else 60.0


## Records the render kernel for this frame: writes `instance_count` instances of the MultiMesh whose RD buffer is `multimesh`
## (RenderingServer.multimesh_get_buffer_rd_rid) from the bups (a port of BupSim.render_buffer: 16 floats each; slots past the count
## all zero; trails from R_PX, R_PY of the records), at `pixel_um` µm to the pixel. Never through multimesh.buffer or the
## per-instance setters (a CPU copy would overwrite the GPU's).
func draw_bups(multimesh: RID, instance_count: int, pixel_um: float) -> void:
	if gpu == null:
		return
	GpuDraw.of(gpu).draw(gpu, multimesh, instance_count, pixel_um)


## Whether the simulation is on the main RenderingDevice: the only one the bups' picture can be drawn from (a world on a local device, as the
## tools make, is not drawn), and the one a dish gives back when it goes.
func holds_main_device() -> bool:
	return gpu != null and gpu.is_main


## Gives back the main device's buffers, shaders and pipelines (on the render thread); `load_from_cpu` makes them afresh when they are wanted
## later. Nothing happens for a world that does not hold the main device.
func release_device() -> void:
	if not holds_main_device():
		return
	var held := gpu
	gpu = null
	RenderingServer.call_on_render_thread(held.release)


## What the drawing needs of the simulation (see DishDrawing.draw_bups_gpu): whether there is a picture to draw, the bup slots, the bups at the load,
## and the count of loads (a load of the state is a new picture too).
func can_draw() -> bool:
	return holds_main_device() and gpu.capacity > 0


func draw_capacity() -> int:
	return gpu.capacity


func draw_count() -> int:
	return gpu.count


func draw_generation() -> int:
	return GpuDraw.of(gpu).generation


## The GPU's name, for the debug log and the pause menu's record of the settings ("" when there is none).
func device_name() -> String:
	if gpu != null:
		return gpu.device_name()
	var rd := RenderingServer.get_rendering_device()
	return rd.get_device_name() if rd != null else ""
