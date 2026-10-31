class_name SimThread
extends RefCounted
## The simulation's own thread: it makes the pooled world (SimCore, on a local RenderingDevice made on this
## thread, the only thread that ever touches it), keeps each dish's DishWorld (plankton, bloom, sources), drains the commands between
## iterations, asks the Governor how many steps to run, runs them (record, submit, sync), copies what it needs out of the device and hands
## it to the ResultWorker, publishes the main dish's pictures, and rests as the governor's duty says. It never touches the scene tree.
##
## Rows: the main thread names a dish by its client row (WorldClient hands them out); this thread maps each to the core's row, which the
## core picks itself, so a refused dish never puts the two out of step. Snapshots, PayloadInfo.row and ViewRequest.row are client rows.
##
## The loop:
##   drain commands (each handled at once: an edit lands at the sim clock when drained)
##   nothing owed (paused, or less than a step): if something changed, a pass of no steps (edits made, stats fresh, pictures, a
##     snapshot); then sleep until the next command
##   else: k = the governor's steps within the pool's room and the history samples; the dishes' world events for the window; run;
##     copy out DSTATE, STATS and the family events; publish; answer the questions asked; push to the worker; rest
##
## Shared textures: the core makes them on this device; `texture_handles` gives their native handles (for the main device to import,
## after a sync, which every publish has done), and `texture_bound` is how the main side says which texture it last bound on which frame,
## so the core never writes one it may still be reading.

const KIND_INSPECT := &"inspect"  ## tests and tools: args {call: Callable(core: SimCore, rows: Dictionary client -> core row)}; the reply's value is what it returns
const KIND_WORLD_SEED := &"world_seed"  ## args {seed}: the world's seed (new dishes' seeds are drawn from it and their number)
const FIELD_VIEW_MSEC := 100  ## the least real time between two field pictures (dish.gd's HAZE_REFRESH_MSEC)
const THUMBS_MSEC := 1000  ## the least real time between two thumbnail atlases
const ANSWER_MSEC := 100  ## the least real time between two answers to a dish's fraction questions
const SPEED_WINDOW_MSEC := 1000  ## the achieved speed is the world time over the real time of about this much
const REST_SLICE_USEC := 1000
const TEXTURE_KINDS := ["payload", "ids", "haze", "steer", "thumbs"]

var limits: PoolLimits
var store: Object = null  ## the LineageStore the worker writes (null: none)
var queue := CommandQueue.new()
var worker: ResultWorker
var governor := Governor.new()

var _thread := Thread.new()
var _state := Mutex.new()  ## guards the fields below it
var _stop := false
var _status := {"ready": false, "alive": false, "failed": false, "device": "", "errors": []}
var _bound: Array = []  ## [kind, index, frame] the main side reported, not yet given to the core
var _handles := {}  ## kind -> {generation, handles: Array (native handles), width, height, format}

# The sim thread's own (nothing else reads or writes them).
var _core: SimCore = null
var _rows := {}  ## client row -> core row
var _numbers := {}  ## client row -> dish number
var _worlds := {}  ## client row -> DishWorld
var _world_dirty := {}  ## client rows whose world copy must go out with the next snapshot
var _plankton_seen := {}  ## client row -> the plankton count the last copy had
var _had_bups := {}  ## client row -> true once it held a bup (an empty dish that never did is not extinct)
var _questions := {}  ## client row -> the questions asked (see WorldClient.ask)
var _answers := {}  ## client row -> {name: share}
var _answered_msec := {}  ## client row -> when its fractions were last answered
var _refused := {}  ## client row -> why, for the next snapshot
var _view: ViewRequest = null
var _view_dirty := false
var _field_msec := -1000000
var _thumbs_msec := -1000000
var _changed := true  ## a snapshot should go out even with no steps
var _speed_marks: Array = []  ## [msec, clock] of the last iterations
var _iterations := 0
var _payload: PayloadInfo = null
var _field_view: FieldViewInfo = null
var _field_version := 0
var _texture_rids := {}  ## kind -> the RIDs the handles were taken from
var _texture_generation := 0
var _births_per_step := 0.0
var _last_timing := {}


func _init(p_limits: PoolLimits = null, p_store: Object = null) -> void:
	limits = p_limits if p_limits != null else PoolLimits.new()
	store = p_store
	worker = ResultWorker.new(store)


func start() -> void:
	worker.start()
	_thread.start(_run)


## Stops the loop, frees the device on its own thread, lets the worker finish what is queued, and joins both threads. Replies of commands
## that were never drained are completed with the error "shutdown".
func stop() -> void:
	_state.lock()
	_stop = true
	_state.unlock()
	queue.wake()
	worker.release_pushes()
	if _thread.is_started():
		_thread.wait_to_finish()
	worker.stop()
	for cmd in queue.drain():
		if cmd.reply != null:
			cmd.reply.complete(null, "shutdown")


func submit(cmd: SimCommand) -> void:
	queue.push(cmd)


## {ready, alive, failed, device, errors}: ready once the device and kernels are made (failed when they could not be); alive while the loop
## runs; errors: what went wrong since (a refused iteration, a command SimCore cannot do yet).
func status() -> Dictionary:
	_state.lock()
	var s := _status.duplicate(true)
	_state.unlock()
	return s


## The main side bound texture `index` of `kind` on its frame `frame` (see the header).
func texture_bound(kind: String, index: int, frame: int) -> void:
	_state.lock()
	_bound.append([kind, index, frame])
	_state.unlock()


## kind -> {generation, handles (native, for texture_create_from_extension), width, height, format}: the shared textures as last made.
func texture_handles() -> Dictionary:
	_state.lock()
	var h := _handles.duplicate(true)
	_state.unlock()
	return h


func _stopping() -> bool:
	_state.lock()
	var s := _stop
	_state.unlock()
	return s


func _set_status(key: String, value: Variant) -> void:
	_state.lock()
	_status[key] = value
	_state.unlock()


func _error(what: String) -> void:
	_state.lock()
	(_status["errors"] as Array).append(what)
	_state.unlock()
	push_warning("SimThread: " + what)


# ---- the loop ------------------------------------------------------------------------------------------------------------------------

func _run() -> void:
	_core = SimCore.new(limits)
	_set_status("device", _core.rd.get_device_name() if _core.rd != null else "")
	if not _core.errors.is_empty():
		for e in _core.errors:
			_error(e)
		_set_status("failed", true)
		_set_status("ready", true)
		_core.release()
		_core = null
		_refuse_all()
		return
	_set_status("ready", true)
	_set_status("alive", true)
	while not _stopping():
		for cmd in queue.drain():
			_handle(cmd)
		if _stopping():
			break
		_give_bound()
		var k := _plan_steps()
		if k <= 0:
			if _changed or _view_dirty:
				_quiet_pass()
			queue.wait()
			continue
		var busy := _iterate(k)
		_rest(governor.rest_ms(busy))
	_core.release()
	_core = null
	_set_status("alive", false)


## The world could not be made: every command that wants a reply is answered with an error until the thread is stopped.
func _refuse_all() -> void:
	while not _stopping():
		for cmd in queue.drain():
			if cmd.reply != null:
				cmd.reply.complete(null, "the simulation could not start")
		queue.wait()


## The steps of the next iteration (0: nothing owed).
func _plan_steps() -> int:
	var want := governor.owed_steps()
	if want <= 0 or _rows.is_empty():
		if _rows.is_empty() and want > 0:
			governor.skip(want)  # (an empty world's clock runs on: a dish added later joins at the world's time)
		return 0
	var d := governor.delta()
	var cap := mini(want, governor.steps_by_time())
	var room := _room_steps(cap)
	var samples := Governor.steps_for_samples(governor.clock, d, DishHistory.INTERVAL, GpuLayout.STATS_ITER_SAMPLES, Governor.MAX_STEPS)
	return governor.steps(room, samples)


## The most steps (up to `most`) whose room fits the memory budget: every dish's segment after k doublings (a bup divides at
## most once a step, never past its dish's cap), and the family events they can make.
func _room_steps(most: int) -> int:
	if _fits(most):
		return most
	var k := 1
	while k < most and _fits(k + 1):
		k += 1
	return k


func _fits(k: int) -> bool:
	var slots := 0
	var events := 0
	for client: int in _rows:
		var cr: int = _rows[client]
		var n := _core.count(cr)
		var cap := _cap_of(_core.spec_of(cr).limit)
		slots += _align(mini(cap, n << mini(k, 30)))
		for j in k:
			events += mini(cap, n << mini(j, 30))
			if events >= SimCore.EVENT_EXACT_MOST:
				break
	if events >= SimCore.EVENT_EXACT_MOST:
		events = maxi(SimCore.EVENT_EXACT_MOST, int(4.0 * _births_per_step * k))
	return _core.arena.fits(maxi(slots, _core.world_word(GpuLayout.WD_SLOTS)), 0, 0, 0, 0, maxi(events, SimCore.EVENT_FLOOR))


## SimCore's cap of a dish (DP_CAP): its limit and 5%, and a block's worth more, in whole blocks.
static func _cap_of(limit: int) -> int:
	return ((int(limit * 1.05) + 1024 + 255) / 256) * 256


static func _align(v: int) -> int:
	return ((v + GpuLayout.BLK_SLOTS - 1) / GpuLayout.BLK_SLOTS) * GpuLayout.BLK_SLOTS


## One iteration of `k` steps. Returns the ms the thread was busy with it.
func _iterate(k: int) -> float:
	var d := governor.delta()
	var t0 := governor.clock
	var plan := IterationPlan.new()
	plan.k = k
	plan.delta = d
	var sampled := Governor.sample_steps(t0, k, d, DishHistory.INTERVAL, GpuLayout.STATS_ITER_SAMPLES)
	var flags := PackedByteArray()
	flags.resize(k)
	for j in sampled:
		flags[j] = 1
	plan.history_flags = flags
	var times := PackedFloat64Array()
	for j in k:
		times.append(t0 + (j + 1) * d)
	plan.step_times = times
	var bursts := {}
	for client: int in _rows:
		var ev: Dictionary = (_worlds[client] as DishWorld).events(t0, k, d)
		plan.events[_rows[client]] = ev
		if (ev["discs"] as PackedFloat64Array).size() > 0 or (ev["husks"] as PackedFloat64Array).size() > 0:
			bursts[client] = true
	var start := Time.get_ticks_usec()
	var res: Dictionary = _core.run(k, d, plan)
	var ran: int = res["steps"]
	var run_ms := (Time.get_ticks_usec() - start) / 1000.0
	governor.advanced(ran, d, run_ms)
	if ran == 0:
		_error("an iteration of %d steps was refused (%s)" % [k, _core.errors[-1] if not _core.errors.is_empty() else "?"])
	_iterations += 1
	for client: int in bursts:
		_world_dirty[client] = true
	var samples: Array = []
	for i in sampled.size():
		samples.append([i + 1, t0 + (sampled[i] + 1) * d])
	var item := _results(ran, d, t0, samples if ran > 0 else [])
	var busy := (Time.get_ticks_usec() - start) / 1000.0
	_last_timing = {
		"iteration_ms": busy, "steps": ran, "step_ms_ema": governor.step_ms_ema, "duty": governor.duty,
		"sync_ms": float(res.get("gpu_usec", 0)) / 1000.0, "record_ms": float(res.get("record_usec", 0)) / 1000.0,
		"publish_ms": item["publish_ms"], "readback_ms": item["readback_ms"], "rest_ms": governor.rest_ms(busy),
	}
	item["timing"] = _timing()
	worker.push_iteration(item)
	_changed = false
	return busy


## A pass of no steps: the queued edits are made, the stats are current, the pictures go out, and a snapshot shows what the commands did.
func _quiet_pass() -> void:
	_core.run(0, governor.delta())
	var item := _results(0, governor.delta(), governor.clock, [])
	item["timing"] = _timing()
	worker.push_iteration(item)
	_changed = false


## What the worker needs of the state now (bytes and plain values only: it never touches the device).
func _results(steps: int, d: float, t0: float, samples: Array) -> Dictionary:
	var t_read := Time.get_ticks_usec()
	var rows: Array = []
	var births := 0
	var deaths := 0
	var top := 0
	for client: int in _rows:
		var cr: int = _rows[client]
		var ds := _core.dstate_row(cr)
		var count := ds.decode_u32(GpuLayout.DS_COUNT * 4)
		if count > 0:
			_had_bups[client] = true
		births += ds.decode_u32(GpuLayout.DS_BIRTHS * 4)
		deaths += ds.decode_u32(GpuLayout.DS_DEATHS * 4)
		top = maxi(top, cr + 1)
		rows.append({
			"row": client, "core_row": cr, "number": _numbers[client], "count": count,
			"clouds": ds.decode_u32(GpuLayout.DS_CLOUD_SLOTS * 4), "husks": ds.decode_u32(GpuLayout.DS_HUSKS * 4),
			"lost": ds.decode_u32(GpuLayout.DS_BIRTHS_LOST * 4), "extinct": _had_bups.get(client, false) and count == 0,
			"fractions": _answers.get(client, {}),
		})
	var eb := PackedByteArray()
	var ed := PackedByteArray()
	if steps > 0:
		_births_per_step = maxf(float(births) / steps, _births_per_step * 0.9)
		var cap := _core.arena.event_cap
		if mini(births, cap) > 0:
			eb = _core.rd.buffer_get_data(_core.arena.buf("EVB"), 0, mini(births, cap) * GpuLayout.BIRTH_WORDS * 4)
		if mini(deaths, cap) > 0:
			ed = _core.rd.buffer_get_data(_core.arena.buf("EVD"), 0, mini(deaths, cap) * GpuLayout.DEATH_WORDS * 4)
	var stats := PackedByteArray()
	if top > 0:
		stats = _core.rd.buffer_get_data(_core.arena.buf("STATS"), 0, top * GpuLayout.STATS_DISH_WORDS * 4)
	var readback_ms := (Time.get_ticks_usec() - t_read) / 1000.0
	var worlds := {}
	for client: int in _rows:
		var w: DishWorld = _worlds[client]
		if _world_dirty.has(client) or w.plankton_count() != int(_plankton_seen.get(client, -1)):
			worlds[client] = _copy_world(w)
			_plankton_seen[client] = w.plankton_count()
	_world_dirty.clear()
	var refused := _refused
	_refused = {}
	var t_pub := Time.get_ticks_usec()
	_publish()
	_answer()
	return {
		"steps": steps, "delta": d, "t0": t0, "sim_time": governor.clock, "achieved": _achieved(), "paused": governor.paused,
		"births": eb, "deaths": ed, "rows": rows, "stats": stats, "samples": samples, "worlds": worlds, "refused": refused,
		"payload": _payload, "field_view": _field_view, "readback_ms": readback_ms, "publish_ms": (Time.get_ticks_usec() - t_pub) / 1000.0,
	}


func _timing() -> Dictionary:
	var t := _last_timing.duplicate()
	t["owed_s"] = governor.owed()
	t["dropped_s"] = governor.dropped
	t["steps_total"] = governor.steps_total
	t["clock"] = governor.clock
	t["delta"] = governor.delta()
	t["iterations"] = _iterations
	t["device"] = _status.get("device", "")
	return t


## The world time over the real time across about the last SPEED_WINDOW_MSEC of iterations (0 while paused).
func _achieved() -> float:
	var now := Time.get_ticks_msec()
	_speed_marks.append([now, governor.clock])
	while _speed_marks.size() > 2 and now - int(_speed_marks[1][0]) >= SPEED_WINDOW_MSEC:
		_speed_marks.pop_front()
	if governor.paused or _speed_marks.size() < 2:
		return 0.0
	var first: Array = _speed_marks[0]
	var span := (now - int(first[0])) / 1000.0
	return (governor.clock - float(first[1])) / span if span > 0.0 else 0.0


func _rest(ms: float) -> void:
	var until := Time.get_ticks_usec() + int(ms * 1000.0)
	while Time.get_ticks_usec() < until and not _stopping():
		OS.delay_usec(mini(REST_SLICE_USEC, maxi(until - Time.get_ticks_usec(), 1)))


# ---- publishing and answers ----------------------------------------------------------------------------------------------------------

func _give_bound() -> void:
	_state.lock()
	var bound := _bound
	_bound = []
	_state.unlock()
	for b: Array in bound:
		_core.texture_bound(b[0], b[1], b[2])


func _publish() -> void:
	if _view == null or not _rows.has(_view.row):
		_view_dirty = false
		return
	var now := Time.get_ticks_msec()
	var v := ViewRequest.new()
	v.row = _rows[_view.row]
	v.camera = _view.camera
	v.pixel_um = _view.pixel_um
	v.steer = _view.steer
	v.haze = _view.haze
	v.steer_alpha = _view.steer_alpha
	v.want_field_view = _view.want_field_view and (now - _field_msec >= FIELD_VIEW_MSEC or _view_dirty)
	v.want_thumbnails = _view.want_thumbnails and now - _thumbs_msec >= THUMBS_MSEC
	_give_bound()
	var out := _core.publish(v)
	_take_handles()
	if out.has("payload"):
		var p := PayloadInfo.new()
		p.texture_index = out["payload"]
		p.count = _core.count(v.row)
		p.sim_time = governor.clock
		p.row = _view.row
		p.generation = int((_handles.get("payload", {}) as Dictionary).get("generation", 0))
		p.seq = _iterations
		_payload = p
	if out.has("haze"):
		_field_msec = now
		_field_version += 1
		var f := FieldViewInfo.new()
		f.texture_index = out["haze"]
		var s := _core.spec_of(v.row)
		f.n = DishGrid.cells_across(s.radius, s.resolution)
		f.version = _field_version
		_field_view = f
	if out.has("thumbs"):
		_thumbs_msec = now
	_view_dirty = false


## The native handles of every shared texture the core has made, taken again when a kind was made anew.
func _take_handles() -> void:
	for kind: String in TEXTURE_KINDS:
		var rids: Array = _core.textures(kind)
		if rids.is_empty() or rids == _texture_rids.get(kind, []):
			continue
		_texture_rids[kind] = rids.duplicate()
		_texture_generation += 1
		var fmt := _core.rd.texture_get_format(rids[0])
		var handles: Array = []
		for rid: RID in rids:
			handles.append(_core.rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_TEXTURE, rid, 0))
		_state.lock()
		_handles[kind] = {"generation": _texture_generation, "handles": handles, "width": fmt.width, "height": fmt.height, "format": fmt.format}
		_state.unlock()


## The shares asked for (ask's "fractions": name -> [gene, threshold]), at most every ANSWER_MSEC a dish.
func _answer() -> void:
	var now := Time.get_ticks_msec()
	for client: int in _questions:
		if not _rows.has(client):
			continue
		var fr: Dictionary = (_questions[client] as Dictionary).get("fractions", {})
		if fr.is_empty() or now - int(_answered_msec.get(client, -1000000)) < ANSWER_MSEC:
			continue
		_answered_msec[client] = now
		var out := {}
		for name: Variant in fr:
			var q: Array = fr[name]
			out[name] = _core.fraction_with_gene_at_least(_rows[client], String(q[0]), float(q[1]))
		_answers[client] = out


static func _copy_world(w: DishWorld) -> DishWorldCopy:
	var c := w.copy()
	var out := DishWorldCopy.new()
	out.version = Time.get_ticks_usec()
	out.plankton = c["plankton"]
	var sources: Array = []
	var ss: Dictionary = c["sources"]
	for id: int in ss:
		sources.append({"id": id, "pos": ss[id]["pos"], "rate": ss[id]["rate"]})
	out.sources = sources
	return out


# ---- commands ------------------------------------------------------------------------------------------------------------------------

func _handle(cmd: SimCommand) -> void:
	var a := cmd.args
	match cmd.kind:
		SimCommand.KIND_SET_TIME:
			governor.set_time(float(a.get("speed", 1.0)), bool(a.get("paused", false)), float(a.get("real_dt", 0.0)))
			governor.frame(float(a.get("real_dt", 0.0)) * 1000.0, float(a.get("display_ms", 0.0)))
			if governor.paused:
				_speed_marks.clear()
			return
		SimCommand.KIND_ADD_DISH:
			_add_dish(int(a["row"]), a["spec"])
		SimCommand.KIND_REMOVE_DISH:
			_remove_dish(int(a["row"]))
		SimCommand.KIND_FREEZE:
			_freeze(int(a["row"]), cmd.reply)
		SimCommand.KIND_THAW:
			_thaw(int(a["row"]), a["blob"])
		SimCommand.KIND_PIPETTE:
			_pipette(int(a["row"]), a["centre"], float(a["radius"]), int(a["new_row"]), cmd.reply)
		SimCommand.KIND_RESIZE:
			_unsupported(cmd, "resize")
		SimCommand.KIND_SET_PARAMS:
			_set_params(int(a["row"]), a["params"])
		SimCommand.KIND_EDIT_WORLD:
			_edit(int(a["row"]), a["edit"])
		SimCommand.KIND_SET_VIEW:
			_view = a["view"]
			_view_dirty = true
		SimCommand.KIND_ASK:
			_questions[int(a["row"])] = a["questions"]
			_answered_msec.erase(int(a["row"]))
		SimCommand.KIND_SAVE_ALL:
			_save_all(cmd.reply)
		KIND_WORLD_SEED:
			_core.world_seed = int(a["seed"])
		KIND_INSPECT:
			var value: Variant = (a["call"] as Callable).call(_core, _rows.duplicate())
			if cmd.reply != null:
				cmd.reply.complete(value)
		_:
			_unsupported(cmd, String(cmd.kind))
	_changed = true


func _unsupported(cmd: SimCommand, what: String) -> void:
	_error("%s: not supported by SimCore yet" % what)
	if cmd.reply != null:
		cmd.reply.complete(null, "%s: not supported by SimCore yet" % what)


func _add_dish(client: int, spec: DishSpec) -> void:
	var cr := _core.add_dish(spec)
	if cr < 0:
		_refused[client] = _core.errors[-1] if not _core.errors.is_empty() else "no free row"
		return
	_map(client, cr)
	_worlds[client] = _new_world(_core.spec_of(cr), spec.world)
	_had_bups[client] = spec.founders.size() > 0


func _map(client: int, cr: int) -> void:
	_rows[client] = cr
	_numbers[client] = _core.spec_of(cr).number
	_world_dirty[client] = true


func _unmap(client: int) -> void:
	for d: Dictionary in [_rows, _numbers, _worlds, _world_dirty, _plankton_seen, _had_bups, _questions, _answers, _answered_msec]:
		d.erase(client)


## A dish's world at the world's time: its medium (the grid's cell), its bloom, and what its spec starts it with ({sources: [{pos, rate}],
## plankton: [Vector2]}).
func _new_world(s: DishSpec, start: Dictionary) -> DishWorld:
	var w := DishWorld.new(s.radius, s.seed)
	w.set_medium(s.diffusion(), 2.0 * s.radius / DishGrid.cells_across(s.radius, s.resolution), Dish.CLOUD_HANDOVER, Dish.NUTRIENT_ENERGY)
	w.plankton_husks = ((s.flags >> GpuLayout.DPF_PLANKTON_HUSKS) & 1) == 1
	w.time = governor.clock
	w.set_bloom(s.bloom_density)
	for src: Dictionary in start.get("sources", []):
		w.apply({"op": "add_source", "pos": src["pos"], "rate": src["rate"]})
	for p: Vector2 in start.get("plankton", []):
		w.apply({"op": "add_plankton", "pos": p})
	return w


func _minutes() -> int:
	return int(governor.clock / 60.0)


func _remove_dish(client: int) -> void:
	if not _rows.has(client):
		return
	var number: int = _numbers[client]
	var live := _core.remove_dish(_rows[client])
	_unmap(client)
	var minutes := _minutes()
	worker.push_op(func(st: Object) -> void:
		if st != null:
			st.release_dish(number, live, minutes))


## Freeze: the dish is read whole and leaves the world; then, after the events before it, the worker exports its lineage into the
## blob and releases the dish from the store, and completes the reply with the blob.
func _freeze(client: int, reply: SimReply) -> void:
	if not _rows.has(client):
		if reply != null:
			reply.complete(null, "no such dish")
		return
	var number: int = _numbers[client]
	var cr: int = _rows[client]
	var blob := _core.gather(cr)
	var live := _core.remove_dish(cr)
	blob.world = (_worlds[client] as DishWorld).save()
	_unmap(client)
	var minutes := _minutes()
	worker.push_op(func(st: Object) -> void:
		if st != null:
			var ex: Dictionary = st.export_dish(number, live)
			blob.host["lineage"] = ex["bytes"]
			blob.host["lineage_ids"] = ex["ids"]
			st.release_dish(number, live, minutes, ex["ids"])
		if reply != null:
			reply.complete(blob))


## Thaw or load: the dish comes back at the world's time, and the worker merges its lineage into the store (an idempotent merge).
func _thaw(client: int, blob: DishBlob) -> void:
	var cr := _core.load_dish(blob)
	if cr < 0:
		_refused[client] = _core.errors[-1] if not _core.errors.is_empty() else "no free row"
		return
	_map(client, cr)
	var w: DishWorld
	if blob.world.is_empty():
		w = _new_world(_core.spec_of(cr), {})
	else:
		w = DishWorld.new()
		w.load_blob(blob.world, governor.clock)
	_worlds[client] = w
	var live := _ids_of(blob.records)
	_had_bups[client] = live.size() > 0
	var number: int = _numbers[client]
	var data: PackedByteArray = blob.host.get("lineage", PackedByteArray())
	var watched := PackedInt64Array(blob.host.get("watched", []))
	worker.push_op(func(st: Object) -> void:
		if st != null and data.size() > 0:
			st.import_bytes(data, watched, live, number))


## The pipette's retarget into a new dish like the source, at client row `dest`. The reply ({new_row, number, moved, ids})
## comes from the worker after the store has the moved bups' new home, in event order.
func _pipette(client: int, centre: Vector2, radius: float, dest: int, reply: SimReply) -> void:
	if not _rows.has(client):
		_refused[dest] = "no such dish"
		if reply != null:
			reply.complete(null, "no such dish")
		return
	var res := _core.pipette(_rows[client], centre, radius)
	if res.is_empty():
		_refused[dest] = _core.errors[-1] if not _core.errors.is_empty() else "the pipette was refused"
		if reply != null:
			reply.complete(null, _refused[dest])
		return
	var nr: int = res["new_row"]
	_map(dest, nr)
	var spec := _core.spec_of(nr)
	_worlds[dest] = _new_world(spec, {})
	var moved: int = res["moved"]
	_had_bups[dest] = moved > 0
	var ids: PackedInt64Array = res["ids"]
	var number := spec.number
	worker.push_op(func(st: Object) -> void:
		if st != null and ids.size() > 0:
			st.retarget_ids(ids, number)
		if reply != null:
			reply.complete({"new_row": dest, "number": number, "moved": moved, "ids": ids}))


## What SimCore can change of a running dish: its world's bloom. Feed, upkeep, limit and flags have no SimCore call yet.
func _set_params(client: int, params: Dictionary) -> void:
	if not _rows.has(client):
		return
	var rest := params.keys()
	if params.has("bloom_density"):
		(_worlds[client] as DishWorld).set_bloom(float(params["bloom_density"]))
		rest.erase("bloom_density")
	if not rest.is_empty():
		_error("set_params %s: not supported by SimCore yet" % [rest])


func _edit(client: int, e: WorldEdit) -> void:
	if not _rows.has(client):
		return
	if e.is_field_edit():
		_core.queue_edit(_rows[client], e)
	else:
		(_worlds[client] as DishWorld).apply(e.as_world_op())
		_world_dirty[client] = true


## Every running dish read whole (and kept running), its lineage exported (no claims: the dish runs on), the blobs in client-row order.
func _save_all(reply: SimReply) -> void:
	var blobs: Array = []
	var clients: Array = _rows.keys()
	clients.sort()
	for client: int in clients:
		var blob := _core.gather(_rows[client])
		blob.world = (_worlds[client] as DishWorld).save()
		var live := _ids_of(blob.records)
		var number: int = _numbers[client]
		blobs.append(blob)
		worker.push_op(func(st: Object) -> void:
			if st != null:
				var ex: Dictionary = st.export_dish(number, live)
				blob.host["lineage"] = ex["bytes"]
				blob.host["lineage_ids"] = ex["ids"])
	worker.push_op(func(_st: Object) -> void:
		if reply != null:
			reply.complete(blobs))


static func _ids_of(records: PackedByteArray) -> PackedInt64Array:
	var ids := PackedInt64Array()
	ids.resize(records.size() / GpuLayout.RECORD_BYTES)
	for i in ids.size():
		ids[i] = GpuLayout.id_of(records, i)
	return ids
