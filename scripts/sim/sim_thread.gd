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
##   drain commands (each handled at once: an edit lands at the sim clock when drained); the pipettes whose new dish's grid is ready; the
##     grid of the main view's dish's next pipette started ahead on the worker pool
##   nothing owed (paused, or less than a step): if something changed, a pass of no steps (edits made, stats fresh, pictures, a
##     snapshot); then sleep until the next command (or, when that pass left the husks unread, until they may be read again)
##   else: k = the governor's steps within the pool's room and the history samples; the dishes' world events for the window; run;
##     answer the questions asked; copy out DSTATE, STATS and the family events; publish (with the asked-after bups' places); push to the
##     worker; rest. An iteration the memory budget refuses (nothing ran) puts the dishes' worlds back as they were before its events,
##     and the next tries are fewer steps, then one step at most every REFUSED_RETRY_MSEC (`_plan_steps`)
##
## Shared textures: the core makes them on this device; `texture_handles` gives their native handles (for the main device to import,
## after a sync, which every publish has done), and `texture_bound` is how the main side tells each texture it used, on which frame and
## holding which publish (PayloadInfo.seq, FieldViewInfo.seq), so the core never writes one it may still be reading (SimCore's header).

const KIND_INSPECT := &"inspect"  ## tests and tools: args {call: Callable(core: SimCore, rows: Dictionary client -> core row)}; the reply's value is what it returns
const KIND_WORLD_SEED := &"world_seed"  ## args {seed}: the world's seed (new dishes' seeds are drawn from it and their number)
const KIND_MEMORY := &"memory"  ## args {mode, gb}: the memory setting changed (WorldClient.set_memory)
const KIND_BEGIN_GAME := &"begin_game"  ## args {game_began}: a new game (WorldClient.begin_game): the numbers start again, the family tree's times count from it
const HUSK_VIEW_MSEC := 100  ## the least real time between two reads of the main dish's husks (dish.gd's HUSK_REFRESH_MSEC)
const FIELD_VIEW_MSEC := 100  ## the least real time between two field pictures (dish.gd's HAZE_REFRESH_MSEC)
const THUMBS_MSEC := 1000  ## the least real time between two thumbnail atlases
const ANSWER_MSEC := 100  ## the least real time between two answers to a dish's fraction questions
const SPEED_WINDOW_MSEC := 1000  ## the achieved speed is the world time over the real time of about this much
const REST_SLICE_USEC := 1000
const SPIN_SHARE := 0.5  ## with one step a frame, an iteration that fills at least this share of the display's frame keeps the thread spinning between frames
const REFUSED_RETRY_MSEC := 250  ## a world whose iteration of one step was refused is tried again after this long, or at once after a command that may make room
const TEXTURE_KINDS := ["payload", "ids", "haze", "steer", "thumbs"]
## The commands that may give a world over the memory budget room (fewer bups or dishes, a lower limit, a smaller dish; a test's budget).
const ROOM_KINDS := [SimCommand.KIND_REMOVE_DISH, SimCommand.KIND_FREEZE, SimCommand.KIND_RESIZE, SimCommand.KIND_SET_PARAMS, KIND_INSPECT]

var limits: PoolLimits
var store: Object = null  ## the LineageStore the worker writes (null: none)
var queue := CommandQueue.new()
var worker: ResultWorker
var governor := Governor.new()

var _thread := Thread.new()
var _state := Mutex.new()  ## guards the fields below it
var _stop := false
var _status := {"ready": false, "alive": false, "failed": false, "device": "", "errors": []}
var _bound: Array = []  ## [kind, index, frame, seq] the main side reported, not yet given to the core
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
var _answers := {}  ## client row -> {fractions: {name: share}, tracked: {id: record bytes}, steer: {id: Vector3}, probes: PackedFloat32Array}
var _answered_msec := {}  ## client row -> when its questions were last answered
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
var _thumbs: ThumbsInfo = null  ## the newest thumbnails' atlas
var _husk_view: Dictionary = {}  ## Snapshot.husk_view as last read
var _husk_msec := -1000000
var _husks_owed := false  ## a publish left the husks unread (read at most every HUSK_VIEW_MSEC): with nothing owed, a pass reads them then
var _game_began := 0.0  ## s: the world time the game began at; the family tree's times count from it (WorldClient.begin_game)
var _texture_rids := {}  ## kind -> the RIDs the handles were taken from
var _texture_generation := 0
var _births_per_step := 0.0
var _last_timing := {}
var _last_events: Array = [0, 0]  ## the last iteration's births and deaths
var _refusal := ""  ## why the iterations are being refused (the memory budget), while they are; "" once one runs
var _refused_k := 0  ## the steps of the last iteration if it was refused (0: it ran)
var _retry_msec := -1  ## after a refused iteration of one step: when the next is tried (-1: not waiting to try)
var _pipettes: Array = []  ## pipettes waiting for their new dish's grid, made on the worker pool: {client, number, centre, radius, dest, reply, spec, made, task}
var _tick_usec := 0  ## when the last set_time command was drained
var _busy_ema := 0.0  ## ms: the iterations' busy time, smoothed
var _grids := {}  ## the grid a pipette from the main view's dish would give its new dish, made ahead on the worker pool (`_make_grid_ahead`): key (`_grid_key`) -> {task, made}
var _mass_um := 0.0  ## a bup's drawn length per unit of mass (SimConstants' mass_um)


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
## runs; errors: what went wrong since (a refused iteration, a command SimCore cannot do).
func status() -> Dictionary:
	_state.lock()
	var s := _status.duplicate(true)
	_state.unlock()
	return s


## The main side used texture `index` of `kind`, holding publish `seq`, on its frame `frame` (see the header).
func texture_bound(kind: String, index: int, frame: int, seq: int) -> void:
	_state.lock()
	_bound.append([kind, index, frame, seq])
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
	_mass_um = float(SimConstants.build()["mass_um"])
	_core.warm_up_pipette()
	limits.start_watch()
	while not _stopping():
		_watch_memory()
		for cmd in queue.drain():
			_handle(cmd)
		_finish_pipettes()
		_make_grid_ahead()
		if _stopping():
			break
		if _refusal == "" and _retry_msec < 0:
			_core.prepare_pipette_room()  # (between iterations and never while a pipette runs: both are this thread's)
		_give_bound()
		var k := _plan_steps()
		if k <= 0:
			if _changed or _view_dirty:
				_quiet_pass()
			var retry_at := _retry_msec if _retry_msec > Time.get_ticks_msec() else -1  # (a refused world's next try, still to come)
			if _husks_owed:
				_wait_for_command(_husk_msec + HUSK_VIEW_MSEC if retry_at < 0 else mini(_husk_msec + HUSK_VIEW_MSEC, retry_at))
				if Time.get_ticks_msec() >= _husk_msec + HUSK_VIEW_MSEC:
					_changed = true  # (a pass of no steps reads them; a command that came first is drained before it)
			elif retry_at >= 0:
				_wait_for_command(retry_at)
			else:
				_wait_for_tick()
			continue
		var busy := _iterate(k)
		_busy_ema = busy if _busy_ema == 0.0 else lerpf(_busy_ema, busy, 0.1)
		_rest(governor.rest_ms(busy))
	for p: Dictionary in _pipettes:
		WorkerThreadPool.wait_for_task_completion(p["task"])
		if p["reply"] != null:
			p["reply"].complete(null, "shutdown")
	_pipettes.clear()
	for key: Array in _grids:
		WorkerThreadPool.wait_for_task_completion(_grids[key]["task"])
	_grids.clear()
	_core.release()
	_core = null
	_set_status("alive", false)


## The memory watch's timer (once a loop, a clock compare): the working budget follows the free memory, and while the machine is short the
## arena gives back the classes it uses little after seconds, not a minute.
func _watch_memory() -> void:
	if limits.watch == null:
		return
	limits.watch.tick(Time.get_ticks_msec(), _core.arena.bytes_now())
	_core.arena.shrink_after_msec = SimArena.SHORT_SHRINK_MSEC if limits.watch.short else SimArena.SHRINK_EVERY_MSEC


## The world could not be made: every command that wants a reply is answered with an error until the thread is stopped.
func _refuse_all() -> void:
	while not _stopping():
		for cmd in queue.drain():
			if cmd.reply != null:
				cmd.reply.complete(null, "the simulation could not start")
		queue.wait()


## The steps of the next iteration (0: nothing owed). After a refused iteration (the memory budget: SimCore.run ran nothing) the next asks
## for half its steps; after a refused iteration of one step none is tried until REFUSED_RETRY_MSEC has passed or a command that may
## make room was drained (`_handle`), and that try is of one step: a world that stays over the budget is tried a few times a second, not
## once a loop.
func _plan_steps() -> int:
	var want := governor.owed_steps()
	if want <= 0 or _rows.is_empty():
		if _rows.is_empty() and want > 0:
			governor.skip(want)  # (an empty world's clock runs on: a dish added later joins at the world's time)
		return 0
	if _retry_msec >= 0:
		if Time.get_ticks_msec() < _retry_msec:
			return 0
		_retry_msec = -1
		want = 1  # (one step first: the room it needs is the least an iteration can need)
	elif _refused_k > 1:
		want = mini(want, _refused_k / 2)
	var d := governor.delta()
	var cap := mini(want, governor.steps_by_time())
	var room := _room_steps(cap)
	var samples := Governor.steps_for_samples(governor.clock, d, DishHistory.INTERVAL, GpuLayout.STATS_ITER_SAMPLES, room)
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
		var cap := _core.cap_of(cr)
		slots += _align(mini(cap, n << mini(k, 30)))
		for j in k:
			events += mini(cap, n << mini(j, 30))
			if events >= SimCore.EVENT_EXACT_MOST:
				break
	if events >= SimCore.EVENT_EXACT_MOST:
		events = maxi(SimCore.EVENT_EXACT_MOST, int(4.0 * _births_per_step * k))
	return _core.arena.fits(maxi(slots, _core.world_word(GpuLayout.WD_SLOTS)), 0, 0, 0, 0, maxi(events, SimCore.EVENT_FLOOR))


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
	var before := {}  ## client row -> its world before the window (DishWorld.checkpoint)
	for client: int in _rows:
		var w: DishWorld = _worlds[client]
		before[client] = w.checkpoint()
		var ev: Dictionary = w.events(t0, k, d)
		plan.events[_rows[client]] = ev
		if (ev["discs"] as PackedFloat64Array).size() > 0 or (ev["husks"] as PackedFloat64Array).size() > 0:
			bursts[client] = true
	var start := Time.get_ticks_usec()
	var res: Dictionary = _core.run(k, d, plan)
	var ran: int = res["steps"]
	var run_ms := (Time.get_ticks_usec() - start) / 1000.0
	governor.advanced(ran, d, run_ms)
	if ran == 0:
		for client: int in before:  # (nothing ran: the window's bursts, releases and arrivals are owed to the next one, as if never asked)
			(_worlds[client] as DishWorld).restore(before[client])
		bursts.clear()
		var why := "an iteration of %d steps was refused (%s)" % [k, _core.errors[-1] if not _core.errors.is_empty() else "?"]
		if _refusal == "":
			_error(why)  # (once while it lasts: the next iterations ask for the same room and are refused alike)
		_refusal = why
		_refused_k = k
		if k <= 1:
			_retry_msec = Time.get_ticks_msec() + REFUSED_RETRY_MSEC
	else:
		_refusal = ""
		_refused_k = 0
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
		"publish_ms": item["publish_ms"], "readback_ms": item["readback_ms"], "answer_ms": item["answer_ms"],
		"rest_ms": governor.rest_ms(busy), "run_ms": run_ms,
		"births": _last_events[0], "deaths": _last_events[1],
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
	var t_answer := Time.get_ticks_usec()
	_answer()  # (before the rows, which carry the answers: a pass answers what was asked before it)
	var answer_ms := (Time.get_ticks_usec() - t_answer) / 1000.0
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
			"fractions": (_answers.get(client, {}) as Dictionary).get("fractions", {}),
			"answers": _answers_of(client),
		})
	var parts: Array = [["STATS", top * GpuLayout.STATS_DISH_WORDS * 4]]
	if steps > 0:
		_births_per_step = maxf(float(births) / steps, _births_per_step * 0.9)
		var cap := _core.arena.event_cap
		parts.append(["EVB", mini(births, cap) * GpuLayout.BIRTH_WORDS * 4])
		parts.append(["EVD", mini(deaths, cap) * GpuLayout.DEATH_WORDS * 4])
	var got := _read(parts)
	var stats: PackedByteArray = got[0]
	var eb: PackedByteArray = got[1] if steps > 0 else PackedByteArray()
	var ed: PackedByteArray = got[2] if steps > 0 else PackedByteArray()
	_last_events = [births if steps > 0 else 0, deaths if steps > 0 else 0]
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
	return {
		"steps": steps, "delta": d, "t0": t0, "sim_time": governor.clock, "achieved": _achieved(), "paused": governor.paused,
		"births": eb, "deaths": ed, "rows": rows, "stats": stats, "samples": samples, "worlds": worlds, "refused": refused,
		"payload": _payload, "field_view": _field_view, "thumbs": _thumbs, "husk_view": _husk_view, "readback_ms": readback_ms,
		"publish_ms": (Time.get_ticks_usec() - t_pub) / 1000.0, "answer_ms": answer_ms, "game_began": _game_began,
	}


## The first `bytes` of each buffer in `parts` ([name, bytes]), in one right-sized read (SimCore.read_parts).
func _read(parts: Array) -> Array:
	return _core.read_parts(parts.map(func(p: Array) -> Array: return [p[0], 0, p[1]]))


func _timing() -> Dictionary:
	var t := _last_timing.duplicate()
	t["owed_s"] = governor.owed()
	t["dropped_s"] = governor.dropped
	t["steps_total"] = governor.steps_total
	t["clock"] = governor.clock
	t["delta"] = governor.delta()
	t["iterations"] = _iterations
	t["device"] = _status.get("device", "")
	t["refused_iteration"] = _refusal
	t["pool"] = _core.arena.report()
	t["memory_fraction"] = _core.arena.memory_fraction()
	t["machine"] = limits.watch.report() if limits.watch != null else {}
	t["next_growth_bytes"] = _core.arena.next_growth_bytes()
	t["overflow"] = _core.overflow()
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


## Sleeps until the real time `until_msec`, a command or the stop, whichever comes first.
func _wait_for_command(until_msec: int) -> void:
	while Time.get_ticks_msec() < until_msec and queue.size() == 0 and not _stopping():
		OS.delay_usec(REST_SLICE_USEC)


## Nothing is owed: waits for the next command (the interface's frame). With one step a frame and iterations that fill much of it the
## thread spins in place of the block, up to two frames: a thread that sleeps between iterations runs the next one's GPU wait slower
## (a one-step sync of about 4.3 ms against about 3.0 ms).
func _wait_for_tick() -> void:
	if not governor.paused and governor.display_ms > 0.0 and governor.frame_steps() > 0 and _busy_ema >= SPIN_SHARE * governor.display_ms:
		var deadline := _tick_usec + 2 * int(governor.display_ms * 1000.0)
		while queue.size() == 0 and Time.get_ticks_usec() < deadline and not _stopping():
			pass
	queue.wait()


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
		_core.texture_bound(b[0], b[1], b[2], b[3])


func _publish() -> void:
	if _view == null or not _rows.has(_view.row):
		_view_dirty = false
		_husks_owed = false
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
	v.track = PackedInt64Array((_questions.get(_view.row, {}) as Dictionary).get("tracked", []))
	_give_bound()
	var out := _core.publish(v)
	_take_handles()
	_husks_owed = _view.want_husks and not (now - _husk_msec >= HUSK_VIEW_MSEC or _view_dirty)
	if _view.want_husks and not _husks_owed:
		_husk_msec = now
		_husk_view = {"row": _view.row, "version": int(_husk_view.get("version", 0)) + 1, "transforms": _core.husk_view(v.row)}
	if out.has("payload"):
		var p := PayloadInfo.new()
		p.texture_index = out["payload"]
		p.count = _core.count(v.row)
		p.sim_time = governor.clock
		p.row = _view.row
		p.generation = int((_handles.get("payload", {}) as Dictionary).get("generation", 0))
		p.seq = _core.publish_seq
		p.places = _places(out.get("tracked", {}))
		_payload = p
	if out.has("haze") or out.has("steer"):
		_field_msec = now
		_field_version += 1
		var f := FieldViewInfo.new()  # (a new one: the snapshots hand the last one out to the main thread)
		var s := _core.spec_of(v.row)
		f.n = DishGrid.cells_across(s.radius, s.resolution)
		var same := _field_view != null and _field_view.n == f.n  # (a kind not written this time keeps its last picture, of the same grid)
		f.texture_index = out.get("haze", _field_view.texture_index if same else -1)
		f.seq = _core.publish_seq if out.has("haze") else (_field_view.seq if same else 0)
		f.steer_index = out.get("steer", _field_view.steer_index if same else -1)
		f.steer_seq = _core.publish_seq if out.has("steer") else (_field_view.steer_seq if same else 0)
		f.version = _field_version
		_field_view = f
	if out.has("thumbs"):
		_thumbs_msec = now
		var t := ThumbsInfo.new()  # (a new one: the snapshots hand the last one out to the main thread)
		t.texture_index = out["thumbs"]
		t.seq = _core.publish_seq
		t.version = (_thumbs.version if _thumbs != null else 0) + 1
		t.tiles = _rows.duplicate()
		_thumbs = t
	_view_dirty = false


## Where the bups the main view's dish asks after (its selected and hovered: WorldClient.ask's "tracked") are in the payload just published
## (`found`: SimCore.publish's "tracked", looked up in the publish's own list): id -> Vector3(x, y, drawn length in µm), dish-local. The
## camera's follow and the rings take a bup's place from the payload they draw, so neither lags the picture.
func _places(found: Dictionary) -> Dictionary:
	var out := {}
	for id: int in found:
		var r: PackedByteArray = found[id]
		out[id] = Vector3(r.decode_float(GpuLayout.R_X * 4), r.decode_float(GpuLayout.R_Y * 4), r.decode_float(GpuLayout.R_MASS * 4) * _mass_um)
	return out


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


## The questions asked (WorldClient.ask), at most every ANSWER_MSEC a dish: the shares ("fractions": name -> [gene, threshold]), the
## tracked bups' records ("tracked": ids, up to GpuLayout.TRACKED) with the steering at each one's place for its speed and sense range,
## and the field at points ("probes": [x, y, speed, sense range] each, dish-local).
func _answer() -> void:
	var now := Time.get_ticks_msec()
	for client: int in _questions:
		if not _rows.has(client) or now - int(_answered_msec.get(client, -1000000)) < ANSWER_MSEC:
			continue
		var q: Dictionary = _questions[client]
		if q.is_empty():
			_answers.erase(client)
			continue
		_answered_msec[client] = now
		var cr: int = _rows[client]
		var shares := {}
		var fr: Dictionary = q.get("fractions", {})
		for name: Variant in fr:
			var f: Array = fr[name]
			shares[name] = _core.fraction_with_gene_at_least(cr, String(f[0]), float(f[1]))
		var tracked := _core.track(cr, PackedInt64Array(q.get("tracked", [])))
		var points := PackedFloat32Array()
		var ids: Array = tracked.keys()
		for id: int in ids:
			var r: PackedByteArray = tracked[id]
			points.append_array(PackedFloat32Array([r.decode_float(GpuLayout.R_X * 4), r.decode_float(GpuLayout.R_Y * 4), r.decode_float(GpuLayout.R_SPEED * 4), _core.sense_range_of(r)]))
		var asked := PackedFloat32Array()
		for p: Variant in q.get("probes", []):
			asked.append_array(PackedFloat32Array(p))
		points.append_array(asked.slice(0, (SimCore.PROBES_MOST - ids.size()) * 4))
		var got := _core.probe(cr, points)
		var steer := {}
		var pf := GpuLayout.PROBE_FLOATS
		for k in ids.size():
			steer[ids[k]] = Vector3(got[k * pf], got[k * pf + 1], got[k * pf + 2])
		var places := PackedFloat32Array()
		for h: Variant in (q.get("husks", []) as Array).slice(0, GpuLayout.HUSK_QUERIES):
			places.append_array(PackedFloat32Array(h))
		var husks: Array = []
		var found := _core.husk_near(cr, places)
		for k in found.size():
			husks.append({"at": Vector2(places[k * 3], places[k * 3 + 1]), "reach": places[k * 3 + 2], "found": found[k]})
		_answers[client] = {"fractions": shares, "tracked": tracked, "steer": steer, "probes": got.slice(ids.size() * pf), "husks": husks}


## What a snapshot answers for a dish (Snapshot.answers' row).
func _answers_of(client: int) -> Dictionary:
	var a: Dictionary = _answers.get(client, {})
	return {"tracked": a.get("tracked", {}), "steer": a.get("steer", {}), "probes": a.get("probes", PackedFloat32Array()), "husks": a.get("husks", [])}


static func _copy_world(w: DishWorld) -> DishWorldCopy:
	var c := w.copy()
	var out := DishWorldCopy.new()
	out.version = Time.get_ticks_usec()
	out.time = c["time"]
	out.plankton = c["plankton"]
	var sources: Array = []
	var ss: Dictionary = c["sources"]
	for id: int in ss:
		sources.append({"id": id, "pos": ss[id]["pos"], "rate": ss[id]["rate"], "emitted": ss[id]["emitted"]})
	out.sources = sources
	return out


# ---- commands ------------------------------------------------------------------------------------------------------------------------

func _handle(cmd: SimCommand) -> void:
	var a := cmd.args
	match cmd.kind:
		SimCommand.KIND_SET_TIME:
			_tick_usec = Time.get_ticks_usec()
			governor.frame(float(a.get("real_dt", 0.0)) * 1000.0, float(a.get("display_ms", 0.0)))
			governor.set_time(float(a.get("speed", 1.0)), bool(a.get("paused", false)), float(a.get("real_dt", 0.0)))
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
			_resize(int(a["row"]), float(a["radius"]), int(a.get("resolution", -1)), cmd.reply)
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
		KIND_MEMORY:
			limits.set_memory(String(a["mode"]), float(a["gb"]), Time.get_ticks_msec(), _core.arena.bytes_now())
		KIND_BEGIN_GAME:
			_core.begin_game()
			_game_began = float(a["game_began"])
		KIND_INSPECT:
			var value: Variant = (a["call"] as Callable).call(_core, _rows.duplicate())
			if cmd.reply != null:
				cmd.reply.complete(value)
		_:
			_unsupported(cmd, String(cmd.kind))
	if cmd.kind in ROOM_KINDS and _retry_msec > 0:
		_retry_msec = 0  # (a refused world is tried again at once: this may have made room)
	_changed = true


func _unsupported(cmd: SimCommand, what: String) -> void:
	_error("%s: not a command the simulation thread knows" % what)
	if cmd.reply != null:
		cmd.reply.complete(null, "%s: not a command the simulation thread knows" % what)


func _add_dish(client: int, spec: DishSpec) -> void:
	var cr := _core.add_dish(spec)
	if cr < 0:
		_refused[client] = _core.errors[-1] if not _core.errors.is_empty() else "no free row"
		return
	_map(client, cr)
	_worlds[client] = _new_world(_core.spec_of(cr), spec.world)
	_had_bups[client] = spec.founders.size() > 0
	if spec.founders.size() > 0:
		var births := SimCore.founder_births(spec.founders, spec.number)
		var now := governor.clock - _game_began
		var founders := spec.founders  # (the core gave them the world's ids)
		var names := spec.founder_names
		worker.push_op(func(st: Object) -> void:
			if st != null:
				st.apply_events(births, PackedByteArray(), now, 0.0)
				for i in mini(names.size(), founders.size() / GpuLayout.RECORD_BYTES):
					if names[i] != "":
						st.set_custom_name(GpuLayout.id_of(founders, i), BupNames.clean(names[i])))


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


## The game's time in whole minutes (the family tree's).
func _minutes() -> int:
	return int((governor.clock - _game_began) / 60.0)


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
	var live := _core.live_ids(cr)
	_had_bups[client] = live.size() > 0
	var number: int = _numbers[client]
	var data: PackedByteArray = blob.host.get("lineage", PackedByteArray())
	var watched := PackedInt64Array(blob.host.get("watched", []))
	worker.push_op(func(st: Object) -> void:
		if st != null and data.size() > 0:
			st.import_bytes(data, watched, live, number))


## The pipette's retarget into a new dish like the source, at client row `dest`. The new dish's grid (its landscape takes a while
## in script: 135 ms for 100 cells across) is the one made ahead for the main view's dish when it is that one (`_make_grid_ahead`), or else
## made on the worker pool now while the dishes run on; the retarget is the first thing done once it is ready, between iterations. The reply
## ({new_row, number, moved, ids, pass_ms}) comes from the worker after the store has the moved bups' new home, in event order; a command about the
## source drained before then (a freeze, a trash) is done first.
func _pipette(client: int, centre: Vector2, radius: float, dest: int, reply: SimReply) -> void:
	if not _rows.has(client):
		_refused[dest] = "no such dish"
		if reply != null:
			reply.complete(null, "no such dish")
		return
	var spec := _core.receiver_spec(_rows[client])
	var key := _grid_key(spec)
	var ahead: Dictionary = _grids.get(key, {})
	_grids.erase(key)
	if ahead.is_empty():
		ahead = _grid_task(spec)
	_pipettes.append({"client": client, "number": _numbers[client], "centre": centre, "radius": radius, "dest": dest, "reply": reply, "spec": spec, "made": ahead["made"], "task": ahead["task"]})


static func _grid_key(s: DishSpec) -> Array:
	return [s.radius, s.resolution, s.patchiness, s.patch_seed]


## {task, made}: `spec`'s grid being made on the worker pool (made["grid"] once the task is done).
func _grid_task(spec: DishSpec) -> Dictionary:
	var made := {}
	var task := WorkerThreadPool.add_task(func() -> void:
		made["grid"] = DishGrid.make(spec.radius, spec.resolution, spec.patchiness, spec.patch_seed)
		queue.wake())
	return {"task": task, "made": made}


## Makes ahead, on the worker pool, the grid a pipette from the main view's dish would give its new dish now (SimCore.receiver_spec's
## size, settings and next number), so the pipette's retarget need not wait for it. One is made at a time; a grid no longer the one a
## pipette would take (another dish took the number, the dish was resized, another dish came into view) is dropped once made.
func _make_grid_ahead() -> void:
	var busy := false
	for key: Array in _grids.keys():
		if WorkerThreadPool.is_task_completed(_grids[key]["task"]):
			continue
		busy = true
	if busy or _view == null or not _rows.has(_view.row):
		return
	var spec := _core.receiver_spec(_rows[_view.row], false)
	var key := _grid_key(spec)
	for old: Array in _grids.keys():
		if old != key:
			WorkerThreadPool.wait_for_task_completion(_grids[old]["task"])
			_grids.erase(old)
	if not _grids.has(key):
		_grids[key] = _grid_task(spec)


## The pipettes whose new dish's grid is ready, done now in the order they were asked.
func _finish_pipettes() -> void:
	while not _pipettes.is_empty() and WorkerThreadPool.is_task_completed(_pipettes[0]["task"]):
		var p: Dictionary = _pipettes.pop_front()
		WorkerThreadPool.wait_for_task_completion(p["task"])
		_retarget(p["client"], p["number"], p["centre"], p["radius"], p["dest"], p["reply"], p["spec"], p["made"]["grid"])
		_changed = true


func _retarget(client: int, asked_number: int, centre: Vector2, radius: float, dest: int, reply: SimReply, spec: DishSpec, grid: DishGrid) -> void:
	# The client row can have been freed and given to another dish while the grid was made: the pipette is of the dish it was asked of.
	if not _rows.has(client) or _numbers.get(client, -1) != asked_number:
		_refused[dest] = "no such dish"
		if reply != null:
			reply.complete(null, "no such dish")
		return
	var t0 := Time.get_ticks_usec()
	var res := _core.pipette(_rows[client], centre, radius, spec, grid)
	var pass_ms := (Time.get_ticks_usec() - t0) / 1000.0
	if res.is_empty():
		_refused[dest] = _core.errors[-1] if not _core.errors.is_empty() else "the pipette was refused"
		if reply != null:
			reply.complete(null, _refused[dest])
		return
	var nr: int = res["new_row"]
	_map(dest, nr)
	var made_spec := _core.spec_of(nr)
	_worlds[dest] = _new_world(made_spec, {})
	var moved: int = res["moved"]
	_had_bups[dest] = moved > 0
	var ids: PackedInt64Array = res["ids"]
	var number := made_spec.number
	worker.push_op(func(st: Object) -> void:
		if st != null and ids.size() > 0:
			st.retarget_ids(ids, number)
		if reply != null:
			reply.complete({"new_row": dest, "number": number, "moved": moved, "ids": ids, "pass_ms": pass_ms}))


## A running dish's settings: the bloom is its world's; the feed, upkeep, limit and flags the core's (SimCore.set_params), and the flags'
## plankton husks the world's too.
func _set_params(client: int, params: Dictionary) -> void:
	if not _rows.has(client):
		return
	var w: DishWorld = _worlds[client]
	var core_params := params.duplicate()
	if params.has("bloom_density"):
		w.set_bloom(float(params["bloom_density"]))
		core_params.erase("bloom_density")
	if params.has("flags"):
		w.plankton_husks = ((int(params["flags"]) >> GpuLayout.DPF_PLANKTON_HUSKS) & 1) == 1
	var rest := _core.set_params(_rows[client], core_params)
	if not rest.is_empty():
		_error("set_params %s: no such setting" % [rest])


## A running dish's new size (and, with `resolution` > 0, its grid's most cells across): SimCore.resize, its world's size and medium, and
## when smaller its sources and plankton past the new edge gone; the bups the edge passed died, so their deaths go to the family tree in
## event order. The reply: {row, removed}, or an error when the budget refused it (the dish is then as it was).
func _resize(client: int, radius: float, resolution: int, reply: SimReply) -> void:
	if not _rows.has(client):
		if reply != null:
			reply.complete(null, "no such dish")
		return
	var res := _core.resize(_rows[client], radius, resolution)
	if res.is_empty():
		_error(_core.errors[-1] if not _core.errors.is_empty() else "the resize was refused")
		if reply != null:
			reply.complete(null, _core.errors[-1] if not _core.errors.is_empty() else "the resize was refused")
		return
	var s := _core.spec_of(_rows[client])
	var w: DishWorld = _worlds[client]
	if radius < w.radius:
		var c := w.copy()
		var sources: Dictionary = c["sources"]
		for id: int in sources:
			if (sources[id]["pos"] as Vector2).length() > radius:
				w.apply({"op": "remove_source", "id": id})
		for p: Dictionary in c["plankton"]:
			if (p["pos"] as Vector2).length() > radius:
				w.apply({"op": "remove_plankton", "pos": p["pos"], "radius": 0.0})
	w.radius = radius
	w.set_medium(s.diffusion(), 2.0 * radius / DishGrid.cells_across(radius, s.resolution), Dish.CLOUD_HANDOVER, Dish.NUTRIENT_ENERGY)
	_world_dirty[client] = true
	var deaths: PackedByteArray = res["deaths"]
	var now := governor.clock - _game_began
	worker.push_op(func(st: Object) -> void:
		if st != null and deaths.size() > 0:
			st.apply_events(PackedByteArray(), deaths, now, 0.0)
		if reply != null:
			reply.complete({"row": client, "removed": res["removed"]}))


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
		var live := _core.live_ids(_rows[client])
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

