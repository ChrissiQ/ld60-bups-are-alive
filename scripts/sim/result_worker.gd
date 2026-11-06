class_name ResultWorker
extends RefCounted
## The second thread of the simulation: it takes what each iteration read back (the sim thread copies the raw bytes and
## hands them over at once, then records the next batch), applies the family events to the LineageStore, decodes the stats, builds the
## next Snapshot and swaps it in under a mutex. The lineage steps of a pipette, a freeze, a trash, a thaw and a save come as operations
## queued between the iterations, so they run in event order; a reply that waits on one is completed by it.
##
## The queue holds at most MAX_ITERATIONS iterations: a slow worker makes the sim thread wait, never the interface. What a snapshot
## carries that happens once (history samples, a publish, a dish world's new copy, a refused dish) stays in every snapshot until the main thread
## acknowledges a snapshot that carried it (`ack`), so a snapshot the main thread never looked at loses nothing.

const MAX_ITERATIONS := 2
const PUSH_WAIT_USEC := 200

var store: Object = null  ## the LineageStore (null: no lineage is kept)
var lineage_usec := 0  ## µs spent applying lineage, in all

var _thread := Thread.new()
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _items: Array[Dictionary] = []
var _iterations := 0  ## iterations in `_items`
var _stop := false
var _released := false  ## pushes no longer wait for room (shutdown)

var _snap_mutex := Mutex.new()
var _snapshot := Snapshot.new()
var _acked := 0

## Worker-thread state.
var _seq := 0
var _history := {}  ## row -> Array of {time, stats, seq}
var _worlds := {}  ## row -> [DishWorldCopy, seq]
var _row_numbers := {}  ## row -> the world number of the dish whose samples and copy `_history` and `_worlds` hold for it (a row reused by another dish starts clean)
var _refused := {}  ## row -> [why, seq]
var _payloads: Array = []  ## [PayloadInfo, seq] of each publish not yet acknowledged, oldest first
var _payload_seq := -1  ## the publish last listed


func _init(p_store: Object = null) -> void:
	store = p_store


func start() -> void:
	_thread.start(_run)


## Stops after every queued item is done, then joins the thread.
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


## Queues an iteration's results (see SimThread._results for the keys). Waits while MAX_ITERATIONS are queued. Returns false when the
## worker is shutting down and dropped it.
func push_iteration(item: Dictionary) -> bool:
	while true:
		_mutex.lock()
		if _stop:
			_mutex.unlock()
			return false
		if _iterations < MAX_ITERATIONS or _released:
			item["kind"] = "iteration"
			_items.append(item)
			_iterations += 1
			_mutex.unlock()
			_semaphore.post()
			return true
		_mutex.unlock()
		OS.delay_usec(PUSH_WAIT_USEC)
	return false


## Queues `call(store)` to run after everything queued before it (a lineage step, a reply's completion).
func push_op(call: Callable) -> void:
	_mutex.lock()
	_items.append({"kind": "op", "call": call})
	_mutex.unlock()
	_semaphore.post()


func queued() -> int:
	_mutex.lock()
	var n := _items.size()
	_mutex.unlock()
	return n


## The newest snapshot (never waits on the worker beyond the swap).
func latest() -> Snapshot:
	_snap_mutex.lock()
	var s := _snapshot
	_snap_mutex.unlock()
	return s


## The main thread has taken the snapshot `seq` and what it carried: later snapshots carry only what came after it.
func ack(seq: int) -> void:
	_snap_mutex.lock()
	_acked = maxi(_acked, seq)
	_snap_mutex.unlock()


func _run() -> void:
	while true:
		_semaphore.wait()
		while true:
			_mutex.lock()
			if _items.is_empty():
				var done := _stop
				_mutex.unlock()
				if done:
					return
				break
			var item: Dictionary = _items.pop_front()
			if item["kind"] == "iteration":
				_iterations -= 1
			_mutex.unlock()
			if item["kind"] == "op":
				(item["call"] as Callable).call(store)
			else:
				_iteration(item)


func _iteration(item: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var steps: int = item["steps"]
	if store != null and steps > 0:
		var births: PackedByteArray = item["births"]
		var deaths: PackedByteArray = item["deaths"]
		var began := float(item.get("game_began", 0.0))  # (the family tree's times are the game's: SimThread, WorldClient.begin_game)
		if births.size() > 0 or deaths.size() > 0:
			store.apply_events(births, deaths, float(item["t0"]) + float(item["delta"]) - began, float(item["delta"]))
		store.set_time(float(item["sim_time"]) - began)
	var lineage_us := Time.get_ticks_usec() - t0
	lineage_usec += lineage_us
	_snap_mutex.lock()
	var acked := _acked
	_snap_mutex.unlock()
	_seq += 1
	_drop_acked(acked)
	var snap := Snapshot.new()
	snap.seq = _seq
	snap.sim_time = item["sim_time"]
	snap.achieved_speed = item["achieved"]
	snap.paused = item["paused"]
	var stats: PackedByteArray = item["stats"]
	for r: Dictionary in item["rows"]:
		var row: int = r["row"]
		var ds := DishState.new()
		ds.number = r["number"]
		if _row_numbers.get(row, ds.number) != ds.number:
			_history.erase(row)
			_worlds.erase(row)
		_row_numbers[row] = ds.number
		ds.count = r["count"]
		ds.stats = stats_at(stats, r["core_row"], 0)
		ds.stats["count"] = ds.count
		ds.fractions = r["fractions"]
		ds.extinct = r["extinct"]
		ds.overflow = r["lost"]
		ds.cloud_count = r["clouds"]
		ds.husk_count = r["husks"]
		snap.dishes[row] = ds
		snap.answers[row] = r.get("answers", {"tracked": {}, "steer": {}, "probes": PackedFloat32Array(), "husks": []})
		for s: Array in item["samples"]:
			if not _history.has(row):
				_history[row] = []
			_history[row].append({"time": s[1], "stats": stats_at(stats, r["core_row"], s[0]), "seq": _seq})
	var worlds: Dictionary = item["worlds"]
	for row: int in worlds:
		_worlds[row] = [worlds[row], _seq]
	var refused: Dictionary = item["refused"]
	for row: int in refused:
		_refused[row] = [refused[row], _seq]
	for row: int in _history:
		snap.history[row] = (_history[row] as Array).map(func(h: Dictionary) -> Dictionary: return {"time": h["time"], "stats": h["stats"]})
	for row: int in _worlds:
		snap.worlds[row] = _worlds[row][0]
	var published: PayloadInfo = item["payload"]
	if published != null and published.seq > _payload_seq:
		_payload_seq = published.seq
		_payloads.append([published, _seq])
	snap.payloads = _payloads.map(func(p: Array) -> PayloadInfo: return p[0])
	snap.payload = published
	snap.field_view = item["field_view"]
	snap.husk_view = item.get("husk_view", {})
	snap.thumbs = item.get("thumbs")
	snap.totals = DishState.aggregate(snap.dishes)
	var timing: Dictionary = (item["timing"] as Dictionary).duplicate()
	timing["lineage_ms"] = lineage_us / 1000.0
	timing["worker_queue"] = queued()
	var refusals := {}
	var refusal_seqs := {}
	for row: int in _refused:
		refusals[row] = _refused[row][0]
		refusal_seqs[row] = _refused[row][1]
	timing["refused"] = refusals
	timing["refused_seq"] = refusal_seqs  # (the snapshot that first carried each: one refusal comes in every snapshot until acknowledged)
	snap.timing = timing
	_snap_mutex.lock()
	_snapshot = snap
	_snap_mutex.unlock()


func _drop_acked(acked: int) -> void:
	for row: int in _history.keys():
		var kept: Array = (_history[row] as Array).filter(func(h: Dictionary) -> bool: return int(h["seq"]) > acked)
		if kept.is_empty():
			_history.erase(row)
		else:
			_history[row] = kept
	for row: int in _worlds.keys():
		if int(_worlds[row][1]) <= acked:
			_worlds.erase(row)
	for row: int in _refused.keys():
		if int(_refused[row][1]) <= acked:
			_refused.erase(row)
	_payloads = _payloads.filter(func(p: Array) -> bool: return int(p[1]) > acked)


## Stats sample `sample` of core row `core_row` in a read of STATS from row 0, as BupSim.population_stats' dictionary (DishState.STATS_KEYS).
static func stats_at(stats: PackedByteArray, core_row: int, sample: int) -> Dictionary:
	var o := (core_row * GpuLayout.STATS_DISH_WORDS + sample * GpuLayout.STATS_WORDS) * 4
	var out := {}
	if o + GpuLayout.STATS_WORDS * 4 > stats.size():
		for k: String in DishState.STATS_KEYS:
			out[k] = 0 if k == "count" else 0.0
		return out
	var count := int(stats.decode_float(o + GpuLayout.ST_COUNT * 4))
	var per := 1.0 / maxf(count, 1)
	out["count"] = count
	for g in 4:
		out[GpuLayout.GENE_NAMES[g]] = stats.decode_float(o + (GpuLayout.ST_SPEED + g) * 4) * per
	out["harm"] = stats.decode_float(o + GpuLayout.ST_HARM * 4) * per
	out["mutations"] = stats.decode_float(o + GpuLayout.ST_MUTATIONS * 4) * per
	out["mutator"] = stats.decode_float(o + GpuLayout.ST_MUTATOR * 4) * per
	out["donor"] = float(stats.decode_u32(o + GpuLayout.ST_DONORS * 4)) * per
	out["key"] = stats.decode_float(o + GpuLayout.ST_KEY * 4) * per
	out["generation"] = stats.decode_float(o + GpuLayout.ST_DIVISIONS * 4) * per
	return out
