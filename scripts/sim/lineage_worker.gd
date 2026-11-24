class_name LineageWorker
extends RefCounted
## The family tree's own thread: the one thread that writes the LineageStore (apply_events, export_dish, release_dish, import_bytes,
## retarget_ids, discard_frozen: the store's header). The sim thread queues each iteration's family events here (`push_events`), and between
## them the lineage steps of a dish added, a freeze, a thaw, a pipette, a resize, a trash, a dish leaving and a save (`push_op`), so they all
## run in the order the sim thread asked them; a reply that needs the store (a freeze's blob, a save's) is completed by its step here.
##
## Nothing waits on this thread but the sim thread, and only when the queue holds MAX_BYTES of events: the snapshots (ResultWorker) and the
## main thread go on while it works through a long step such as a freeze's export and release. The store therefore runs behind the snapshots
## by what is queued here. Each push returns a ticket (the count of items pushed so far) and `done` counts the items finished, so whoever
## holds a ticket can tell whether the store has taken that step yet (Snapshot.lineage_ticket, a pipette's reply).

## The most bytes of family events the queue holds before the sim thread waits: about 4 s of events of a world of two 2-million-bup dishes,
## so a freeze's export and release of such a dish on a slower machine does not stop the simulation. [derived, not measured: one iteration of
## theirs took 14-44 ms to apply in one call on an NVIDIA card, Direct3D 12, at about 2 ms for APPLY_PART events, so up to about 90,000
## events of about 60 bytes; at 20 iterations a second (Governor.T_ITER_MS) that is about 110 MB a second]
const MAX_BYTES := 512 * 1024 * 1024
const PUSH_WAIT_USEC := 200
const APPLY_PART := 4096  ## the most family events one LineageStore.apply_events call takes (`apply_in_parts`): about a couple of ms of the store's lock at the measured cost of an event

var store: Object = null  ## the LineageStore (null: no lineage is kept; the steps still run, and complete their replies)

var _thread := Thread.new()
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _items: Array[Dictionary] = []  ## {call: Callable(store), bytes: int}
var _bytes := 0  ## the event bytes of the items queued or under way
var _pushed := 0  ## items pushed, in all (an item's ticket)
var _done := 0  ## items finished, in all
var _stop := false
var _released := false  ## pushes no longer wait for room (shutdown)
var _events_ms := 0.0  ## ms the last iteration's events took to apply
var _applied_time := 0.0  ## the world time of the last iteration whose events are applied


func _init(p_store: Object = null) -> void:
	store = p_store


func start() -> void:
	_thread.start(_run)


## Stops after every queued item is done (each reply is completed), then joins the thread.
func stop() -> void:
	_mutex.lock()
	_stop = true
	_released = true
	_mutex.unlock()
	_semaphore.post()
	if _thread.is_started():
		_thread.wait_to_finish()


## From now on a push never waits for room (the sim thread must not hang on a full queue while it is being shut down).
func release_pushes() -> void:
	_mutex.lock()
	_released = true
	_mutex.unlock()


## Queues an iteration's family events (`first_step_end`, `step_s`: the game's times, as apply_events takes them) and the time the store
## is at after them. Waits while the queue holds MAX_BYTES (a queue that is empty takes any). Returns the item's ticket.
func push_events(births: PackedByteArray, deaths: PackedByteArray, first_step_end: float, step_s: float, time: float) -> int:
	var bytes := births.size() + deaths.size()
	var call := func(st: Object) -> void:
		if st == null:
			return
		var t0 := Time.get_ticks_usec()
		if bytes > 0:
			apply_in_parts(st, births, deaths, first_step_end, step_s)
		st.set_time(time)
		_mutex.lock()
		_events_ms = (Time.get_ticks_usec() - t0) / 1000.0
		_applied_time = time
		_mutex.unlock()
	while true:
		_mutex.lock()
		if _released or _bytes == 0 or _bytes + bytes <= MAX_BYTES:
			var ticket := _append(call, bytes)
			_mutex.unlock()
			_semaphore.post()
			return ticket
		_mutex.unlock()
		OS.delay_usec(PUSH_WAIT_USEC)
	return -1


## Queues `call(store)` to run after everything queued before it (a lineage step, a reply's completion). Never waits. Returns its ticket.
func push_op(call: Callable) -> int:
	_mutex.lock()
	var ticket := _append(call, 0)
	_mutex.unlock()
	_semaphore.post()
	return ticket


## The ticket of the last item pushed: every lineage step asked for so far is done once `done()` reaches it.
func pushed() -> int:
	_mutex.lock()
	var n := _pushed
	_mutex.unlock()
	return n


## How many items are finished, in all (an item whose ticket is at most this is done).
func done() -> int:
	_mutex.lock()
	var n := _done
	_mutex.unlock()
	return n


## Items queued or under way.
func queued() -> int:
	_mutex.lock()
	var n := _pushed - _done
	_mutex.unlock()
	return n


## {queue (items queued or under way), bytes (their event bytes), events_ms (the last iteration's events), time (the world time the store is
## at)}: for the snapshot's timing.
func figures() -> Dictionary:
	_mutex.lock()
	var f := {"queue": _pushed - _done, "bytes": _bytes, "events_ms": _events_ms, "time": _applied_time}
	_mutex.unlock()
	return f


func _append(call: Callable, bytes: int) -> int:
	_pushed += 1
	_bytes += bytes
	_items.append({"call": call, "bytes": bytes})
	return _pushed


func _run() -> void:
	while true:
		_semaphore.wait()
		while true:
			_mutex.lock()
			if _items.is_empty():
				var finished := _stop
				_mutex.unlock()
				if finished:
					return
				break
			var item: Dictionary = _items.pop_front()
			_mutex.unlock()
			(item["call"] as Callable).call(store)
			_mutex.lock()
			_done += 1
			_bytes -= int(item["bytes"])
			_mutex.unlock()


## The family events of an iteration into `store` (LineageStore.apply_events), in calls of at most APPLY_PART events: the store holds its
## lock through a call, and the main thread looks a bup up in it every frame (the info panel's and the hover card's bup), so one call
## for a 2-million-bup dish's tens of thousands of events made the frame that asked wait tens of ms. The events are in the order of their
## steps (`step` words, GpuLayout.EB_STEP and ED_STEP), and the store adds a step's births before its deaths and a step's births or
## deaths in any order among themselves, so each call takes part of one step's births, or part of its deaths, in that order: the
## store ends as one call would leave it.
static func apply_in_parts(st: Object, births: PackedByteArray, deaths: PackedByteArray, first_step_end: float, step_s: float) -> void:
	var birth_bytes := GpuLayout.BIRTH_WORDS * 4
	var death_bytes := GpuLayout.DEATH_WORDS * 4
	var born := births.size() / birth_bytes
	var died := deaths.size() / death_bytes
	var none := PackedByteArray()
	var bi := 0
	var di := 0
	while bi < born or di < died:
		var step := GpuLayout.EV_STEP_MASK + 1
		if bi < born:
			step = births.decode_u32(bi * birth_bytes + GpuLayout.EB_STEP * 4) & GpuLayout.EV_STEP_MASK
		if di < died:
			step = mini(step, deaths.decode_u32(di * death_bytes + GpuLayout.ED_STEP * 4) & GpuLayout.EV_STEP_MASK)
		var b_end := _step_end(births, birth_bytes, GpuLayout.EB_STEP, bi, born, step)
		var d_end := _step_end(deaths, death_bytes, GpuLayout.ED_STEP, di, died, step)
		while bi < b_end:
			var to := mini(bi + APPLY_PART, b_end)
			st.apply_events(births.slice(bi * birth_bytes, to * birth_bytes), none, first_step_end, step_s)
			bi = to
		while di < d_end:
			var to := mini(di + APPLY_PART, d_end)
			st.apply_events(none, deaths.slice(di * death_bytes, to * death_bytes), first_step_end, step_s)
			di = to


## The first event at or past `from` (of `count`, each `bytes` long, its step in word `word`) whose step is past `step`: a halving
## search, as the events are in the order of their steps.
static func _step_end(events: PackedByteArray, bytes: int, word: int, from: int, count: int, step: int) -> int:
	var lo := from
	var hi := count
	while lo < hi:
		var mid := (lo + hi) >> 1
		if (events.decode_u32(mid * bytes + word * 4) & GpuLayout.EV_STEP_MASK) <= step:
			lo = mid + 1
		else:
			hi = mid
	return lo
