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
## How a frame goes (3B): the dish's _advance_gpu asks steps_for(), runs its world for those steps on the CPU (plankton, sources: what
## they do to the field is recorded as events) and calls queue_batch, which records the batch at once (call_on_render_thread; the frame
## submits it: no submit or sync on the main device), with the frame's questions (pick, nearest, fractions, tracked bups), the reads of
## earlier batches' family events, and every HAZE_REFRESH_MSEC the field's copy. The getters ask their questions and answer from the
## last results; questions asked after the batch (or while paused) go out at the end of the frame. Every request's answers come back
## about two frames later through buffer_get_data_async into a queue that poll() empties on the main thread. A batch's births and
## deaths are read once its counts are known (two more frames) and applied to `sim` in batch order, each batch exactly once; a load
## (GpuSim.loads), or _pipeline_reset, drops everything in flight (export_to_cpu takes the unapplied events first:
## _take_unapplied_events). On a local device (tools) a request is submitted and waited for at once, and its results are read at once.
##
## Layouts (32-bit words; the GLSL is in gpu/kernels.gd, the constants GpuKernels.Q_*, OUT_*):
## - Lineage events (BupSim.apply_events): a birth is 16 words: id lo, id hi, parent lo, parent hi, step, divisions, mutations (uints),
##   speed, sense, metabolism, size_gene, hue, sat, val, harm (floats), 0; a death is 8 words: id lo, id hi, step, divisions (uints),
##   mass (float), 0, 0, 0. `step` is the step's place in the batch. Made by the `events` kernel after `finalize` and before `compact`,
##   in bup-index order, into event set seq % GpuSim.EVENT_SETS (buffers EVB, EVD: room for P[78] = GpuSim.event_capacity of each per
##   set); counters CNT[8..11] (gpu/kernels.gd).
## - Questions QIN: 0 pick asked, 1-2 the point, 3 slack, 4 µm per pixel; 5 nearest points asked (up to 4), 6 + 3s: x, y, near;
##   18 fractions asked (up to 4), 19 + 2f: gene index, threshold (the least float at or above it); 27 tracked (up to 8), 28 + 2t: id lo, hi.
## - Answers OUT: 0-15 CNT, 16-23 PCNT; from 32 QOUT: 0 the picked bup's index or 0xFFFFFFFF, 1 its d² (float bits), 2-25 its record,
##   26 the nearest d² (float bits) and 27 the count within `near` of point 0, 28-31 the counts for the 4 fractions, 36-227 the 8 tracked
##   records (24 words each; ids 0xFFFFFFFF where not found), 228-233 the nearest d² and count of points 1-3. Picks and nearest by
##   atomicMin on d² bits (they order like the floats, for d² >= 0), ties to the smaller index.
## - Stats samples from OUT word 272: 16 floats each: count, Σspeed, Σsense, Σmetabolism, Σsize_gene, Σ(1 - exp(-harm)), Σmutations,
##   step, 0...; sample 0 the state at the end of the frame's work, 1.. the batch's history samples. Reduced in groups of 256 and then in
##   one pass of fixed order, so a sample is the same every run. OUTK keeps each event set's OUT for finish_pending.

const SHADER_DIR := "res://gpu/shaders"

static var _checked := false
static var _available := false

const GENE_NAMES := ["speed", "sense", "metabolism", "size"]  ## BupSim's genes, in the record's order (words 8-11)
const SAME_POINT_PIXELS := 2.0  ## an answer about a point serves a question about another this many pixels away
const QUESTION_FRAMES := 2  ## a pick or nearest question is sent again for this many frames after it was last asked
const TRACK_FRAMES := 10  ## a tracked bup not asked for in this many frames is dropped
const FRACTION_FRAMES := 60  ## a fraction not asked for in this many frames is no longer asked
const MIRROR_ROOM := 64  ## the least a copy of the clouds asks for past the slots known to be in use
const MIRROR_MSEC := 100  ## the field's copy is refreshed this often (Dish.HAZE_REFRESH_MSEC) while the GPU's field changes

var sim: BupSim  ## the dish's CPU simulation: records, names, pins, and the dish's own random numbers
var gpu: GpuSim = null  ## (3B) the simulation on RenderingServer.get_rendering_device()

var record_usec := 0  ## how long the last request took to record (µs of CPU on the render thread): for timing
var apply_usec := 0  ## the time spent in BupSim.apply_events so far (µs): for timing
var _mutex := Mutex.new()
var _arrived := []  ## [kind, request id, batch seq, epoch, data] from the readbacks' callbacks (render thread), for poll()
var _epoch := 0  ## bumped by every load or reset: results of an older epoch are dropped
var _seen_loads := -1  ## the GpuSim.loads the pipeline was last reset for
var _rid := 0  ## the next request's id
var _requests := {}  ## request id -> the request, until its OUT arrives
var _seq := 0  ## the next batch's number
var _next_apply := 0  ## the next batch whose family events go into `sim`
var _batches := {}  ## batch number -> {set, steps, delta, start, times, head, asked, births, deaths, births_data, deaths_data, samples}
var _pending_reads := []  ## batches whose event counts are known and whose events are to be read with the next request
var _history_out := []
var _count := 0
var _count_known := false
var _stats := {}
var _overflows := {}
var _last_births := 0
var _event_rate := 0.0  ## births or deaths per step (the more of the two) lately: a batch is kept to half its event room by it
var _last_out_rid := -1
var _pick := []  ## [point, slack, µm per pixel, frame asked]
var _pick_answer := {}  ## {local, slack, id}
var _pixel_um := 1.0
var _near := []  ## [point, near, frame asked]
var _near_answers := []  ## [point, near, answer]
var _fractions := {}  ## [gene index, threshold] -> frame asked
var _fraction_answers := {}
var _tracked := {}  ## id -> frame asked
var _records := {}  ## id -> its last record (96 bytes)
var _gone := {}  ## id -> the last record of a tracked bup the GPU no longer has (it died): its place, until its death reaches the records
var _sent_questions := {}
var _erase := PackedFloat32Array()
var _held_puffs := PackedFloat32Array()  ## the dish's own clouds and deposits made while no batch ran, sent on their own
var _held_cells := PackedInt32Array()
var _held_amounts := PackedFloat32Array()
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
var _steps_cap := 1.0e9  ## the budget: the most steps a frame may take (see steps_for)
var _slow_frames := 0
var _last_advance_usec := 0
var _last_advance_frame := -10  ## the process frame of the last steps_for


## Whether the GPU path can run here: a main RenderingDevice exists (not headless, not the Compatibility renderer, not the web), every
## kernel's imported shader loaded without an error, and the device takes as many storage buffers per kernel as the largest binds.
## Worked out once. (3C may add to the checks; the most bups the device's dispatch limit allows is `most_bups()`.)
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
		var path := SHADER_DIR.path_join(kernel_name + ".glsl")
		if not ResourceLoader.exists(path):
			return false
		var file := load(path) as RDShaderFile
		if file == null or file.get_base_error() != "":
			return false
		var spirv := file.get_spirv()
		if spirv == null or spirv.compile_error_compute != "":
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


## (3C) CPU -> GPU: makes `gpu` if there is none (GpuSim.new(RenderingServer.get_rendering_device())), and loads it from the CPU:
## the bups (sim.export_state_bytes(), next id sim.get_next_id()), the field (field.export_packed(), export_owner(),
## export_fill_weights(), get_diffusion()), and `dish_params`: "radius", "limit", "seed", "upkeep_scale", "feed_per_second",
## "step_seconds". Then the CPU field records instead of changing (field.set_recording(true)) and the CPU's bups are cleared
## (the records stay). Runs on the render thread (RenderingServer.call_on_render_thread). Drops any result still in flight.
##
## The GPU's random stream is seeded from the dish's seed and one number from the CPU's stream (so that each load, after a switch, draws
## fresh noise instead of the same noise again from step 0; the CPU's stream is the dish's, and carries on).
## What does not cross, and why that is fine: the fine path's chemotaxis memory (the CPU re-primes in about `memory_long`: a known loss), and the CPU's diffusion and feed accumulators, which only the CPU's own step moves (sim.step_world does not),
## so what they hold when the GPU takes over is still there, and still owed to the CPU's field, when the CPU takes over again.
## Hooks of Step 3B, called when the world has them: `_pipeline_reset(bups: int)` (drop every result still in flight and every batch not yet
## recorded, start a new sequence, and take `bups` as the count until the next poll).
func load_from_cpu(field: NutrientField, dish_params: Dictionary) -> void:
	var records := sim.export_state_bytes()
	var packed := field.export_packed()
	var dish_seed := int(dish_params.get("seed", 1)) + int(sim.random_float() * 2147483647.0) * 0x9E3779B1
	var args := {
		"conc": packed["conc"], "acetate": sim.get_acetate().export_packed()["conc"], "puffs": packed["puffs"], "owner": field.export_owner(), "weights": field.export_fill_weights(),
		"n": field.get_size(), "spacing": field.get_spacing(), "diffusion": field.get_diffusion(),
		"records": records, "consts": SimConstants.build(), "next_id": sim.get_next_id(), "seed": dish_seed,
		"radius": float(dish_params.get("radius", 0.0)), "limit": int(dish_params.get("limit", 0)),
		"upkeep": float(dish_params.get("upkeep_scale", 1.0)), "feed": float(dish_params.get("feed_per_second", 0.0)),
		"step": float(dish_params.get("step_seconds", 20.0)),
	}
	_transfer_call(func() -> void:
		if gpu == null:
			gpu = GpuSim.new(RenderingServer.get_rendering_device())
		gpu.acetate = args["acetate"]
		gpu.load_state(args["n"], args["spacing"], args["radius"], args["conc"], args["owner"], args["records"], args["consts"], args["limit"], args["weights"], args["feed"], args["step"], args["diffusion"], args["puffs"], args["seed"], args["upkeep"], args["next_id"]))
	field.set_recording(true)
	var answers := _answers_from_cpu(records, dish_params)  # (while the CPU still has the bups)
	sim.import_state_bytes(PackedByteArray())  # (the bups are the GPU's now; the family records stay)
	if has_method("_pipeline_reset"):
		call("_pipeline_reset", records.size() / GpuSim.RECORD_BYTES)
	_take_answers(answers)


## (3C) GPU -> CPU, stalling: reads CNT, the bups, CONC and the live clouds (buffer_get_data), applies every batch's events not yet
## applied, in order (sim.apply_events), then sim.import_state_bytes(...), field.import_packed(...), sim.set_next_id(the GPU's next
## id), and turns the field's recording off. Results of those batches that arrive later are ignored (by their sequence number).
##
## What the field has recorded since the last batch was queued (a drop or a burst of the dish's own world, not yet sent) is added to
## the grid and the clouds it reads back, so that nothing the player or the world did is lost.
## Hooks of Step 3B, called when the world has them: `_take_unapplied_events() -> Array` (finish whatever is in flight or queued, so that
## every batch has been recorded and has run, and return the event sets lineage has not seen yet, in batch order, as
## {"births": PackedByteArray, "deaths": PackedByteArray, "first_step_end": float (s), "step_seconds": float}, each handed out once),
## then `_pipeline_reset(bups)` as in load_from_cpu.
func export_to_cpu(field: NutrientField) -> void:
	assert(gpu != null, "GpuWorld.export_to_cpu: nothing was loaded")
	var read := {}
	_transfer_call(func() -> void:
		var rd := gpu.rd
		var cnt := rd.buffer_get_data(gpu.buffer("CNT"))
		var live := cnt.decode_u32(0)
		read["next_id"] = cnt.decode_u32(4 * 4) | (cnt.decode_u32(6 * 4) << 32)
		read["records"] = rd.buffer_get_data(gpu.buffer("BUPS"), 0, live * GpuSim.RECORD_BYTES) if live > 0 else PackedByteArray()  # (a size of 0 would read the whole buffer)
		read["conc"] = rd.buffer_get_data(gpu.buffer("CONC")).to_float32_array()
		read["acetate"] = rd.buffer_get_data(gpu.buffer("CONC2")).to_float32_array()
		var slots := rd.buffer_get_data(gpu.buffer("PCNT")).decode_u32(0)
		read["slots"] = rd.buffer_get_data(gpu.buffer("PUFF"), 0, slots * 32).to_float32_array() if slots > 0 else PackedFloat32Array())
	var sets: Array = []
	if has_method("_take_unapplied_events"):
		sets = call("_take_unapplied_events")
	elif gpu.is_main:
		push_error("GpuWorld.export_to_cpu: this world has no _take_unapplied_events (Step 3B): the lineage events of the batches not yet applied are lost")
	for batch: Dictionary in sets:
		sim.apply_events(batch["births"], batch["deaths"], batch["first_step_end"], batch["step_seconds"])
	var conc: PackedFloat32Array = read["conc"]
	var raw: PackedFloat32Array = read["slots"]
	var clouds := PackedFloat32Array()
	clouds.resize(raw.size() / 8 * 5)
	var kept := 0
	for k in raw.size() / 8:
		var o := k * 8
		if raw[o + 5] > 0.5:  # (a slot whose cloud has gone to the grid is not alive)
			var w := kept * 5
			clouds[w] = raw[o]; clouds[w + 1] = raw[o + 1]; clouds[w + 2] = raw[o + 2]; clouds[w + 3] = raw[o + 3]; clouds[w + 4] = raw[o + 4]
			kept += 1
	clouds.resize(kept * 5)
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
	if has_method("_pipeline_reset"):
		call("_pipeline_reset", read["records"].size() / GpuSim.RECORD_BYTES)
	_take_answers(_answers_from_cpu(read["records"]))  # (the dish may still ask here: a save leaves the GPU running, see Dish._gpu_on_cpu)


## The answers to what the dish asks every frame (the stats, the fractions, the tracked bups' records, the last pick and nearest points),
## worked out on the CPU from its bups (`records`: sim.export_state_bytes()), for a load or an export: a load drops every answer still on
## its way, and without these the screen would show no stats, no fraction (a goal's hold would end) and no selected bup until the
## first readback. `dish_params` may name more to answer: "tracked" (ids) and "fractions" ([gene name, threshold] pairs) the dish
## shows; they are asked from now on as track() and fraction_with_gene_at_least() would.
func _answers_from_cpu(records: PackedByteArray, dish_params := {}) -> Dictionary:
	var frame := Engine.get_process_frames()
	for id: int in dish_params.get("tracked", []):
		if id >= 0:
			_tracked[id] = frame
	for pair: Array in dish_params.get("fractions", []):
		var g := GENE_NAMES.find(pair[0])
		if g >= 0:
			_fractions[[g, pair[1]]] = frame
	while _tracked.size() > GpuKernels.TRACKED:  # (the room QIN has, as track() and fraction_with_gene_at_least() keep it)
		_tracked.erase(_oldest(_tracked))
	while _fractions.size() > GpuKernels.FRACTIONS:
		_fractions.erase(_oldest(_fractions))
	var out :={"stats": sim.population_stats(), "fractions": {}, "records": {}, "near": []}
	for key: Array in _fractions:
		out["fractions"][key] = sim.fraction_with_gene_at_least(GENE_NAMES[key[0]], key[1])
	var wanted: Array = _tracked.keys()
	if not _pick.is_empty():
		var picked := sim.pick_bup(_pick[0], _pick[1], _pick[2])
		out["pick"] = {"local": _pick[0], "slack": _pick[1], "id": picked}
		wanted.append(picked)
	for asked: Array in _near:
		out["near"].append([asked[0], asked[1], sim.nearest_and_count(asked[0], asked[1])])
	if not wanted.is_empty():
		var ids := sim.bup_ids()  # (in the records' order)
		for id: int in wanted:
			var i := ids.find(id) if id >= 0 else -1
			if i >= 0 and GpuSim.id_of(records, i) == id:
				out["records"][id] = records.slice(i * GpuSim.RECORD_BYTES, (i + 1) * GpuSim.RECORD_BYTES)
	return out


## Takes the answers of _answers_from_cpu as the last ones known (after _pipeline_reset).
func _take_answers(answers: Dictionary) -> void:
	_stats = answers["stats"]
	_fraction_answers.merge(answers["fractions"], true)
	_records.merge(answers["records"], true)
	if answers.has("pick"):
		_pick_answer = answers["pick"]
	_near_answers = answers["near"]


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


## (3B) Queues a batch of steps for this frame and records it at once (on the render thread), with the questions asked lately, the
## reads of earlier batches' family events, and the field's copy when due. `plan`: "steps" (int), "delta" (s per step), "start_time"
## (s, at the batch's start), "events" ({"ranges", "puffs", "cells", "amounts"}: the clouds and deposits the dish's world made, per step,
## as GpuSim._upload_events takes them), "feed_per_second", "upkeep_scale", "limit", "history_steps" (PackedInt32Array: the steps after
## which a history sample is taken, ascending, at most GpuKernels.MAX_SAMPLES), "erase" (Array of [x, y, radius, strength]: discs to
## erase before the batch, as well as those given to erase_disc). Ask `steps_for` first: it says how many steps may be queued (0: none
## this frame).
func queue_batch(plan: Dictionary) -> void:
	assert(gpu != null, "GpuWorld.queue_batch: no GPU state (load_from_cpu first)")
	_sync_epoch()
	assert(can_queue(), "GpuWorld.queue_batch: the batch's event set is still in use (ask steps_for first)")
	for disc in plan.get("erase", []):
		_add_erase(disc[0], disc[1], disc[2], disc[3])
	_flush_now(plan)


## (3B) On the main thread: applies the results that have arrived, in batch order: lineage events into `sim` (apply_events, each batch
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
			"births", "deaths":
				if _batches.has(seq):
					_batches[seq][kind + "_data"] = data
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


## (3B) The history samples that have arrived since the last call, in order: [{"time": float (sim seconds), "stats": Dictionary with
## BupSim.population_stats' keys}]. The dish records each with Dish._record_history_from.
func take_history_samples() -> Array:
	poll()
	var out := _history_out
	_history_out = []
	return out


## (3B) The population, as last read back (a few frames behind the GPU); the count at the load until the first readback. 0 also when
## nothing is known yet (no GPU state).
func bup_count() -> int:
	_touch()
	return _count if _count_known else 0


## Whether bup_count() is a real count (a state is loaded): the dish's extinct signal waits for it.
func count_known() -> bool:
	return _count_known


## (3B) The same keys as BupSim.population_stats (count, each gene's mean, harm, mutations), as last read back. Until the first
## readback after a load: the count, and the means as last known (0 if never).
func population_stats() -> Dictionary:
	_touch()
	if _stats.is_empty():
		var empty := {"count": _count, "harm": 0.0, "mutations": 0.0, "generation": 0.0}
		for gene in GENE_NAMES:
			empty[gene] = 0.0
		return empty
	return _stats


## (3B) The share of bups whose `gene` is at least `threshold` (BupSim.fraction_with_gene_at_least): registers the pair (up to 4, the
## least recently asked dropped) for the frame's questions and returns the last answer, 0.0 until there is one.
func fraction_with_gene_at_least(gene: String, threshold: float) -> float:
	_touch()
	var g := GENE_NAMES.find(gene)
	if g < 0:
		return 0.0
	var key := [g, threshold]
	_fractions[key] = Engine.get_process_frames()
	if _fractions.size() > GpuKernels.FRACTIONS:
		_fractions.erase(_oldest(_fractions))
	return _fraction_answers.get(key, 0.0)


## (3B) The bup under a point of the dish (BupSim.pick_bup's rule): asks for it in this frame's questions and returns the last answer for a
## point within 2 pixels of this one (with the same slack), else -1. The answer carries the bup's whole record, so a picked bup is tracked
## with no gap.
func pick_bup(local: Vector2, slack: float, pixel_um: float) -> int:
	_touch()
	_pick = [local, slack, pixel_um, Engine.get_process_frames()]
	_pixel_um = pixel_um
	if _pick_answer.is_empty() or _pick_answer["slack"] != slack:
		return -1
	if (_pick_answer["local"] as Vector2).distance_to(local) > SAME_POINT_PIXELS * pixel_um:
		return -1
	return _pick_answer["id"]


## (3B) BupSim.nearest_and_count (the distance to the nearest bup, -1 if none, and how many lie within `near`): asks for it (up to 4 points
## a frame) and returns the last answer for a point within 2 pixels of this one with the same `near`, else the last answer with the same
## `near`, else (-1, 0).
func nearest_and_count(local: Vector2, near: float) -> Vector2:
	_touch()
	var frame := Engine.get_process_frames()
	var found := false
	for asked: Array in _near:
		if asked[1] == near and (asked[0] as Vector2).distance_to(local) <= SAME_POINT_PIXELS * _pixel_um:
			asked[0] = local
			asked[2] = frame
			found = true
			break
	if not found:
		_near.append([local, near, frame])
		if _near.size() > GpuKernels.NEAR_SLOTS:
			_near.pop_front()
	var fallback := Vector2(-1.0, 0.0)
	for answer: Array in _near_answers:
		if answer[1] != near:
			continue
		if (answer[0] as Vector2).distance_to(local) <= SAME_POINT_PIXELS * _pixel_um:
			return answer[2]
		fallback = answer[2]
	return fallback


## (3B) Keeps this bup's record coming back every frame (up to 8, the least recently asked dropped). The dish calls it every frame for each
## bup it shows (the selected and the hovered one); an id not asked for again for TRACK_FRAMES frames is dropped.
func track(id: int) -> void:
	_touch()
	if id < 0:
		return
	_tracked[id] = Engine.get_process_frames()
	if _tracked.size() > GpuKernels.TRACKED:
		_tracked.erase(_oldest(_tracked))


## (3B) BupSim.bup_info for a tracked (or picked) bup, from its last record (sim.info_from_state); {} if it is not known or no longer alive.
func bup_info(id: int) -> Dictionary:
	_touch()
	var record: PackedByteArray = _records.get(id, PackedByteArray())
	return sim.info_from_state(record, 0) if not record.is_empty() else {}


## (3B) Where a tracked bup is (dish coordinates), from its last record; (0, 0) if it is not known.
func bup_pos(id: int) -> Vector2:
	_touch()
	var record := _last_record(id)
	return Vector2(record.decode_float(4), record.decode_float(8)) if not record.is_empty() else Vector2.ZERO


## (3B) BupSim.bup_radius for a tracked bup: half the length it is drawn at, its own or the least that shows (0 if it is not known).
func bup_radius(id: int, pixel_um: float) -> float:
	_touch()
	var record := _last_record(id)
	if record.is_empty() or gpu == null:
		return 0.0
	return 0.5 * maxf(record.decode_float(6 * 4) * float(gpu.consts["mass_um"]), float(gpu.consts["min_length_px"]) * pixel_um)


## (3B) BupSim.bup_steering for a tracked bup: sim.steering_at(its place, its speed, its sense range) on the field's copy.
func bup_steering(id: int) -> Vector3:
	_touch()
	var record := _last_record(id)
	if record.is_empty() or gpu == null:
		return Vector3(0.0, 0.0, 0.5)
	return sim.steering_at(Vector2(record.decode_float(4), record.decode_float(8)), record.decode_float(8 * 4), _sense_range(record))


## (3B) BupSim.bup_steer_bytes for a tracked bup: field.steer_bytes(its speed, its sense range, max_alpha) on the field's copy; while its
## record is not known, a clear picture of the field's size (nothing tinted), so the dish can always make an image of it.
func bup_steer_bytes(id: int, max_alpha: float) -> PackedByteArray:
	_touch()
	var record := _last_record(id)
	var field := sim.get_field()
	if record.is_empty() or gpu == null:
		var clear := PackedByteArray()
		clear.resize(field.get_size() * field.get_size() * 4)
		return clear
	return field.steer_bytes(record.decode_float(8 * 4), _sense_range(record), max_alpha)


## Whether a place is known for this bup (it is tracked or was picked, and its record has come back; or it died since and its last
## place is kept): until then bup_pos is (0, 0), so the dish draws nothing for it.
func knows(id: int) -> bool:
	return _records.has(id) or _gone.has(id)


func _last_record(id: int) -> PackedByteArray:
	return _records.get(id, _gone.get(id, PackedByteArray()))


## (3B) The eraser on the GPU path: erases the disc from the field's copy at once (what is seen, and the amount returned: energy taken, as
## NutrientField.erase_disc) and from the GPU's field before its next step (recorded this frame, also while paused).
func erase_disc(local: Vector2, disc_radius: float, strength: float) -> float:
	_touch()
	_add_erase(local.x, local.y, disc_radius, strength)
	return sim.get_field().erase_disc(local, disc_radius, strength)


## (3B) How many of the `wanted` steps of this frame may be queued (the budget): the frame's length is
## measured from one call to the next; three frames in a row longer than 1.15 times the display's frame cut the steps a frame may take by
## a fifth, a frame shorter than 1.05 times raises them by a tenth (at least one), up to `wanted`. And no more than half the batch's room
## for births and deaths (GpuSim.event_capacity) at the rate they came lately (1.5 times it; 2% of the bups a step until a batch has
## been read: at least one step). 0 when the event set the batch would write is still waiting to be read (rare: the GPU or the
## readbacks are behind), so nothing is queued this frame.
func steps_for(wanted: int) -> int:
	_sync_epoch()
	var now := Time.get_ticks_usec()
	var target := 1e6 / _frame_rate()
	var since := now - _last_advance_usec
	var frame := Engine.get_process_frames()
	if _last_advance_usec > 0 and frame == _last_advance_frame + 1:  # (the frame just past ran steps: its length is their cost, however long. Frames between without any were a pause or a menu. A length limit here let a frame too slow (a million bups take ~8 ms a step) hold every step it asked for: 260 ms frames)
		if since > 1.15 * target:
			_slow_frames += 1
			if _slow_frames >= 3:
				_steps_cap = maxf(1.0, _steps_cap * 0.8)
				_slow_frames = 0
		else:
			_slow_frames = 0
			if since < 1.05 * target:
				_steps_cap = maxf(_steps_cap * 1.1, _steps_cap + 1.0)
	_steps_cap = clampf(_steps_cap, 1.0, float(maxi(wanted, 1)))
	_last_advance_usec = now
	_last_advance_frame = frame
	if gpu == null or not can_queue():
		return 0
	var steps := mini(wanted, int(_steps_cap))
	steps = mini(steps, maxi(1, int(0.5 * gpu.event_capacity / maxf(1.5 * _event_rate, 1.0))))
	return clampi(steps, 0, GpuSim.MAX_STEPS_PER_BATCH)


## Whether a batch can be queued now: the event set it would write (seq % EVENT_SETS) is free, its last batch applied (or dropped with a
## load). (Not merely asked for: the stalling reads of _take_unapplied_events read every pending batch's set again.)
func can_queue() -> bool:
	var older := _seq - GpuSim.EVENT_SETS
	return older < 0 or not _batches.has(older)


## The batches queued whose family events are not yet in `sim`.
func pending_batches() -> int:
	return _batches.size()


## (for the debug log) The same as overflows().
func overflow_counts() -> Dictionary:
	return _overflows


## What found no room on the GPU since the load, as last read back: clouds sent to the grid for want of a slot, entries cut from the
## lists of clouds by place, births and deaths that found no event slot (each of those leaves a hole in the family records).
func overflows() -> Dictionary:
	return _overflows


## Stalls until every batch queued so far is done, reads their family events and history samples straight from the GPU, and applies
## them in order (events into `sim`, samples to take_history_samples). Results of those batches that arrive later are ignored. For
## tools; export_to_cpu (3C) takes the events instead with _take_unapplied_events. After it, `sim`'s records are those of the GPU's
## state.
func finish_pending() -> void:
	for events: Dictionary in _take_unapplied_events():
		sim.apply_events(events["births"], events["deaths"], events["first_step_end"], events["step_seconds"])


## (for 3C's export_to_cpu) Stalls until every batch queued so far is done and returns the family events of every batch not yet applied
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
		sets[seq] = _batches[seq]["set"]
	var got := {}
	RenderingServer.call_on_render_thread(_read_batches_now.bind(sets, got))
	if got.size() != seqs.size():
		push_error("GpuWorld: the stalling reads did not come back on this thread (a separate render thread?); %d batches' family events are lost" % seqs.size())
	for seq: int in seqs:
		if not got.has(seq):
			continue
		var batch: Dictionary = _batches[seq]
		_history_out.append_array(_samples_from(got[seq]["head"], batch))
		var delta: float = batch["delta"]
		out.append({"births": got[seq]["births"], "deaths": got[seq]["deaths"], "first_step_end": batch["start"] + delta, "step_seconds": delta})
	_batches.clear()
	_pending_reads.clear()
	_next_apply = _seq
	return out


## Drops every batch in flight without applying its events (their births and deaths are then missing from `sim`'s records): only for a
## state about to be replaced whose records do not matter. A new load drops them by itself.
func drop_pending() -> void:
	_batches.clear()
	_next_apply = _seq


## Records a frame's work now, without waiting for the end of the frame: what queue_batch does, without a batch (tools).
func flush() -> void:
	_sync_epoch()
	_flush_now({})


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
	var questions := _questions()
	var work := questions != _sent_questions or not _erase.is_empty() or not _pending_reads.is_empty() or _mirror_due()
	if not work and _batch_frame != Engine.get_process_frames():
		var field := sim.get_field()
		_held_puffs = field.take_recorded_puffs()
		_held_cells = field.take_recorded_cells()
		_held_amounts = field.take_recorded_amounts()
		work = not _held_puffs.is_empty() or not _held_cells.is_empty()
	if work:
		_flush_now({})


## The questions to send now: the pick asked lately, the nearest points, the fractions, the tracked ids (each still asked within its
## few frames).
func _questions() -> Dictionary:
	var frame := Engine.get_process_frames()
	var q := {"pick": [], "near": [], "fractions": [], "tracked": []}
	if not _pick.is_empty() and frame - int(_pick[3]) <= QUESTION_FRAMES:
		q["pick"] = [_pick[0], _pick[1], _pick[2]]
	for asked: Array in _near:
		if frame - int(asked[2]) <= QUESTION_FRAMES:
			q["near"].append([asked[0], asked[1]])
	for key: Array in _fractions:
		if frame - int(_fractions[key]) <= FRACTION_FRAMES:
			q["fractions"].append(key)
	for id: int in _tracked.keys():
		if frame - int(_tracked[id]) <= TRACK_FRAMES:
			q["tracked"].append(id)
		else:
			_tracked.erase(id)
			_gone.erase(id)
			if _pick_answer.get("id", -1) != id:
				_records.erase(id)
	return q


## Assembles one request (the batch of `plan` if it has steps, or the held events of the dish's own world, the questions, the erasing,
## the event reads, the field's copy) and records it on the render thread.
func _flush_now(plan: Dictionary) -> void:
	if gpu == null:
		return
	var frame := Engine.get_process_frames()
	var request := {"epoch": _epoch, "loads": gpu.loads, "seq": -1, "rid": _rid, "samples": 0}
	_rid += 1
	# the family events of earlier batches whose counts are known: read before this batch can write their set again
	var reads := []
	for seq: int in _pending_reads:
		if _batches.has(seq):
			var b: Dictionary = _batches[seq]
			reads.append([seq, b["set"], b["births"], b["deaths"]])
			b["asked"] = true
	_pending_reads.clear()
	request["reads"] = reads
	var steps: int = plan.get("steps", 0)
	if steps > 0:
		var seq := _seq
		_seq += 1
		var history: PackedInt32Array = plan.get("history_steps", PackedInt32Array())
		assert(history.size() <= GpuKernels.MAX_SAMPLES)
		var event_set := seq % GpuSim.EVENT_SETS
		var delta: float = plan["delta"]
		var start: float = plan.get("start_time", 0.0)
		var times := PackedFloat64Array()
		for k in history:
			times.append(start + (k + 1) * delta)
		_batches[seq] = {"set": event_set, "steps": steps, "delta": delta, "start": start, "times": times, "head": false, "asked": false, "births": 0, "deaths": 0}
		var gpu_plan := plan.duplicate()
		gpu_plan["event_set"] = event_set
		gpu_plan["history_steps"] = history
		request["seq"] = seq
		request["plan"] = gpu_plan
		request["samples"] = history.size()
		var events: Dictionary = plan.get("events", {})
		_clouds_sent += (events.get("puffs", PackedFloat32Array()) as PackedFloat32Array).size() / 6
		_batch_frame = frame
		_changed = true
	elif not _held_puffs.is_empty() or not _held_cells.is_empty():
		var puffs := PackedFloat32Array()
		for j in _held_puffs.size() / 5:
			puffs.append_array(PackedFloat32Array([_held_puffs[j * 5], _held_puffs[j * 5 + 1], _held_puffs[j * 5 + 2], _held_puffs[j * 5 + 3], _held_puffs[j * 5 + 4], 0.0]))
		request["events"] = {"ranges": PackedInt32Array([0, puffs.size() / 6, 0, _held_cells.size()]), "puffs": puffs, "cells": _held_cells, "amounts": _held_amounts}
		_clouds_sent += puffs.size() / 6
		_changed = true
	_held_puffs = PackedFloat32Array()
	_held_cells = PackedInt32Array()
	_held_amounts = PackedFloat32Array()
	# the questions
	var q := _questions()
	_sent_questions = q
	request["questions"] = q
	request["qin"] = _qin(q)
	request["erase"] = _erase
	if not _erase.is_empty():
		_changed = true
	_erase = PackedFloat32Array()
	# the field's copy
	request["mirror"] = 0
	if _mirror_due():
		request["mirror"] = mini(gpu.puff_capacity, _last_pcnt + (_clouds_sent - _clouds_at_head) + _mirror_room)
		_mirror_in_flight = true
		_mirror_msec = Time.get_ticks_msec()
		_changed = false
	request["clouds_sent"] = _clouds_sent
	_requests[request["rid"]] = request
	RenderingServer.call_on_render_thread(_record.bind(request))


## On the render thread: records one request (see _flush_now) and asks for its results. Touches only `gpu` and the request.
func _record(request: Dictionary) -> void:
	if gpu == null or gpu.loads != request["loads"]:
		return  # (the state was replaced since: its results would be dropped anyway)
	var started := Time.get_ticks_usec()
	var rd := gpu.rd
	var epoch: int = request["epoch"]
	var rid: int = request["rid"]
	for read: Array in request["reads"]:
		var seq: int = read[0]
		var base: int = read[1] * gpu.event_capacity
		if read[2] > 0:
			_read(gpu.buffer("EVB"), base * 64, read[2] * 64, ["births", rid, seq, epoch])
		if read[3] > 0:
			_read(gpu.buffer("EVD"), base * 32, read[3] * 32, ["deaths", rid, seq, epoch])
	var plan: Dictionary = request.get("plan", {})
	var steps: int = plan.get("steps", 0)
	if steps > 0:
		gpu.prepare_steps(steps, plan)
	elif request.has("events"):
		gpu.prepare_events(request["events"])
	var erase: PackedFloat32Array = request["erase"]
	gpu.prepare_frame(request["qin"], erase)
	var q: Dictionary = request["questions"]
	var cl := rd.compute_list_begin()
	gpu.record_erase(cl, erase.size() / 4)
	if steps > 0:
		gpu.record_steps(cl, steps, plan)
	elif request.has("events"):
		gpu.record_events(cl)
	gpu.record_frame(cl, not q["pick"].is_empty(), not q["near"].is_empty() or not q["fractions"].is_empty(), not q["tracked"].is_empty())
	var words: int = GpuKernels.OUT_STATS + GpuKernels.STATS_WORDS * (1 + int(request["samples"]))
	if steps > 0:
		gpu.record_keep(cl, plan["event_set"], words)
	var slots: int = request["mirror"]
	if slots > 0:
		gpu.record_mirror(cl, slots)
	rd.compute_list_end()
	if not gpu.is_main:
		rd.submit()  # (a local device: tools)
		rd.sync()
	_read(gpu.buffer("OUT"), 0, words * 4, ["out", rid, request["seq"], epoch])
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
	var words := GpuKernels.OUT_WORDS
	for seq: int in sets:
		var event_set: int = sets[seq]
		var head := rd.buffer_get_data(gpu.buffer("OUTK"), event_set * words * 4, words * 4)
		var births := mini(head.decode_u32(8 * 4), gpu.event_capacity)
		var deaths := mini(head.decode_u32(9 * 4), gpu.event_capacity)
		var base: int = event_set * gpu.event_capacity
		got[seq] = {
			"head": head,
			"births": rd.buffer_get_data(gpu.buffer("EVB"), base * 64, births * 64) if births > 0 else PackedByteArray(),
			"deaths": rd.buffer_get_data(gpu.buffer("EVD"), base * 32, deaths * 32) if deaths > 0 else PackedByteArray(),
		}


## The frame's answers (OUT) of request `rid`.
func _take_out(rid: int, data: PackedByteArray) -> void:
	var request: Dictionary = _requests.get(rid, {})
	_requests.erase(rid)
	if request.is_empty():
		return
	if rid >= _last_out_rid:  # (the answers of an older request than the newest read are stale; its batch still needs its head below)
		_take_answers_from_out(rid, data, request)
	var seq: int = request["seq"]
	if seq >= 0 and _batches.has(seq):
		var batch: Dictionary = _batches[seq]
		batch["births"] = mini(data.decode_u32(8 * 4), gpu.event_capacity)
		batch["deaths"] = mini(data.decode_u32(9 * 4), gpu.event_capacity)
		batch["samples"] = _samples_from(data, batch)
		batch["head"] = true
		_last_births = data.decode_u32(8 * 4)
		var per_step := maxf(data.decode_u32(8 * 4), data.decode_u32(9 * 4)) / maxf(batch["steps"], 1)
		_event_rate = maxf(per_step, 0.8 * _event_rate)  # (up at once, down slowly)
		if batch["births"] > 0 or batch["deaths"] > 0:
			_pending_reads.append(seq)
		else:
			batch["asked"] = true


## What the newest OUT says: the counts, the stats and the answers to the questions asked with it.
func _take_answers_from_out(rid: int, data: PackedByteArray, request: Dictionary) -> void:
	_last_out_rid = rid
	var count := data.decode_u32(0)
	_count = count
	_count_known = true
	_last_pcnt = data.decode_u32(16 * 4)
	_clouds_at_head = request["clouds_sent"]
	_overflows = {"clouds_to_grid": data.decode_u32(18 * 4), "list_entries_cut": data.decode_u32(19 * 4), "births_lost": data.decode_u32(10 * 4), "deaths_lost": data.decode_u32(11 * 4)}
	_stats = _stats_at(data, 0)
	var q: Dictionary = request["questions"]
	var o := GpuKernels.OUT_Q * 4
	if not q["pick"].is_empty():
		var index := data.decode_u32(o)
		var id := -1
		if index != 0xFFFFFFFF:
			var record := data.slice(o + 8, o + 8 + GpuSim.RECORD_BYTES)
			id = GpuSim.id_of(record, 0)
			_records[id] = record
		_pick_answer = {"local": q["pick"][0], "slack": q["pick"][1], "id": id}
	var near: Array = q["near"]
	for s in near.size():
		var w := o + (26 * 4 if s == 0 else (228 + 2 * (s - 1)) * 4)
		var bits := data.decode_u32(w)
		var value := Vector2(-1.0 if bits == 0xFFFFFFFF else sqrt(data.decode_float(w)), float(data.decode_u32(w + 4)))
		var key_local: Vector2 = near[s][0]
		var key_near: float = near[s][1]
		for k in range(_near_answers.size() - 1, -1, -1):
			if _near_answers[k][1] == key_near and (_near_answers[k][0] as Vector2).distance_to(key_local) <= SAME_POINT_PIXELS * _pixel_um:
				_near_answers.remove_at(k)
		_near_answers.append([key_local, key_near, value])
		if _near_answers.size() > 2 * GpuKernels.NEAR_SLOTS:
			_near_answers.pop_front()
	var fractions: Array = q["fractions"]
	for f in fractions.size():
		_fraction_answers[fractions[f]] = float(data.decode_u32(o + (28 + f) * 4)) / count if count > 0 else 0.0
	var tracked: Array = q["tracked"]
	for t in tracked.size():
		var w := o + (36 + 24 * t) * 4
		var id: int = tracked[t]
		if data.decode_u32(w) == 0xFFFFFFFF and data.decode_u32(w + 21 * 4) == 0xFFFFFFFF:
			if _records.has(id):
				_gone[id] = _records[id]  # (not found: no longer alive. Its place is kept: its record says it lives until its death is applied, a few frames on)
			_records.erase(id)
		else:
			_records[id] = data.slice(w, w + GpuSim.RECORD_BYTES)

## The batch's history samples in an OUT (as _take_out or finish_pending read it).
func _samples_from(data: PackedByteArray, batch: Dictionary) -> Array:
	var out := []
	var times: PackedFloat64Array = batch["times"]
	for j in times.size():
		out.append({"time": times[j], "stats": _stats_at(data, j + 1)})
	return out


## Stats sample `sample` of an OUT as BupSim.population_stats' dictionary.
func _stats_at(data: PackedByteArray, sample: int) -> Dictionary:
	var o := (GpuKernels.OUT_STATS + GpuKernels.STATS_WORDS * sample) * 4
	var count := int(data.decode_float(o))
	var per := 1.0 / maxf(count, 1)
	var out := {"count": count}
	for g in 4:
		out[GENE_NAMES[g]] = data.decode_float(o + (1 + g) * 4) * per
	out["harm"] = data.decode_float(o + 5 * 4) * per
	out["mutations"] = data.decode_float(o + 6 * 4) * per
	out["mutator"] = data.decode_float(o + 8 * 4) * per
	out["donor"] = float(data.decode_u32(o + 9 * 4)) * per
	out["key"] = data.decode_float(o + 10 * 4) * per
	out["generation"] = data.decode_float(o + 11 * 4) * per
	return out


## Applies, in batch order, every batch whose results are all here: its history samples, then its family events (BupSim.apply_events).
func _apply_ready() -> void:
	while _batches.has(_next_apply):
		var batch: Dictionary = _batches[_next_apply]
		if not batch["head"]:
			return
		if batch["births"] > 0 and not batch.has("births_data"):
			return
		if batch["deaths"] > 0 and not batch.has("deaths_data"):
			return
		_history_out.append_array(batch["samples"])
		var delta: float = batch["delta"]
		if batch["births"] > 0 or batch["deaths"] > 0:
			var started := Time.get_ticks_usec()
			sim.apply_events(batch.get("births_data", PackedByteArray()), batch.get("deaths_data", PackedByteArray()), batch["start"] + delta, delta)
			apply_usec += Time.get_ticks_usec() - started
		_batches.erase(_next_apply)
		_next_apply += 1


## A load (GpuSim.loads changed) makes every result in flight stale: they are dropped, and the counts start from the loaded state.
func _sync_epoch() -> void:
	if gpu == null or gpu.loads == _seen_loads:
		return
	if not _batches.is_empty():
		push_warning("GpuWorld: a new state was loaded with %d batches' family events not applied (_take_unapplied_events first)" % _batches.size())
	_pipeline_reset(gpu.count)


## (for 3C, right after load_from_cpu) Drops every result in flight and every batch not yet applied (their events are lost: take them
## first with _take_unapplied_events), starts afresh, and takes `bups` as the count until the first readback.
func _pipeline_reset(bups: int) -> void:
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
	_records.clear()
	_gone.clear()
	_pick_answer = {}
	_near_answers.clear()
	_fraction_answers.clear()
	_sent_questions = {}
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
	if _erase.size() >= GpuKernels.MAX_ERASE * 4:
		return  # (more than a frame's worth: the brush moves a few times a frame at most)
	_erase.append_array(PackedFloat32Array([x, y, disc_radius, strength]))


## QIN's words for the questions `q` (GpuKernels' layout).
func _qin(q: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(GpuKernels.QIN_WORDS * 4)
	if not q["pick"].is_empty():
		var at: Vector2 = q["pick"][0]
		b.encode_u32(0, 1)
		b.encode_float(4, at.x)
		b.encode_float(8, at.y)
		b.encode_float(12, q["pick"][1])
		b.encode_float(16, q["pick"][2])
	var near: Array = q["near"]
	b.encode_u32(GpuKernels.Q_NEAR * 4, near.size())
	for s in near.size():
		var w := (GpuKernels.Q_NEAR + 1 + 3 * s) * 4
		b.encode_float(w, near[s][0].x)
		b.encode_float(w + 4, near[s][0].y)
		b.encode_float(w + 8, near[s][1])
	var fractions: Array = q["fractions"]
	b.encode_u32(GpuKernels.Q_FRAC * 4, fractions.size())
	for f in fractions.size():
		var w := (GpuKernels.Q_FRAC + 1 + 2 * f) * 4
		b.encode_u32(w, fractions[f][0])
		b.encode_u32(w + 4, _float_at_least(fractions[f][1]))
	var tracked: Array = q["tracked"]
	b.encode_u32(GpuKernels.Q_TRACK * 4, tracked.size())
	for t in tracked.size():
		var w := (GpuKernels.Q_TRACK + 1 + 2 * t) * 4
		b.encode_u32(w, tracked[t] & 0xFFFFFFFF)
		b.encode_u32(w + 4, (tracked[t] >> 32) & 0xFFFFFFFF)
	return b


## The bits of the least 32-bit float at or above `value`: a float gene g is >= value (a double, as the CPU compares) exactly when it
## is >= that float.
static func _float_at_least(value: float) -> int:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, value)
	var bits := b.decode_u32(0)
	if b.decode_float(0) < value:
		bits = bits + 1 if b.decode_float(0) >= 0.0 else bits - 1
	return bits


## The sense range of a record's bup (BupSim's: sense * sqrt(sqrt(mass) / reference_size)).
func _sense_range(record: PackedByteArray) -> float:
	return record.decode_float(9 * 4) * sqrt(sqrt(record.decode_float(6 * 4)) / float(gpu.consts["reference_size"]))


func _frame_rate() -> float:
	if Engine.max_fps > 0:
		return Engine.max_fps
	var rate := DisplayServer.screen_get_refresh_rate()
	return rate if rate > 0.0 else 60.0


static func _oldest(asked: Dictionary) -> Variant:
	var oldest: Variant = null
	for key: Variant in asked:
		if oldest == null or asked[key] < asked[oldest]:
			oldest = key
	return oldest


## (3A) Records the render kernel for this frame: writes `instance_count` instances of the MultiMesh whose RD buffer is `multimesh`
## (RenderingServer.multimesh_get_buffer_rd_rid) from the bups (a port of BupSim.render_buffer: 16 floats each; slots past the count
## all zero; trails from words 22/23 of the records), at `pixel_um` µm to the pixel. Never through multimesh.buffer or the
## per-instance setters (a CPU copy would overwrite the GPU's).
func draw_bups(multimesh: RID, instance_count: int, pixel_um: float) -> void:
	if gpu == null:
		return
	GpuDraw.of(gpu).draw(gpu, multimesh, instance_count, pixel_um)


## The GPU's name, for the debug log and the pause menu's record of the settings ("" when there is none).
func device_name() -> String:
	if gpu != null:
		return gpu.device_name()
	var rd := RenderingServer.get_rendering_device()
	return rd.get_device_name() if rd != null else ""
