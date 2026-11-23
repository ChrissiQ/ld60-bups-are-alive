class_name FrameRecord
extends RefCounted
## A rolling record of the last few seconds of frames and of the simulation's iterations, always on, which the F12 log
## (`DebugLog`) and the F3 overlay (`TimingOverlay`) read. It lives in fixed rings (nothing is allocated per frame) and costs a few
## clock reads a frame whatever the number of dishes.
##
## A frame is stamped when the last node's `_process` ends (`Stamp`, from the `DebugHotkey` autoload). Its length is the time from
## the previous frame's stamp to this one's, so it holds this frame's whole process step and the previous frame's drawing and wait for
## the display; its process time runs from `process_frame` to its stamp. Its parts are noted by the code that runs them: the
## poll of the world (`note_poll`), the game screen's own `_process` (`note_main`) and the family-tree look-ups of the frame
## (`note_look`); what the game screen's children took is the rest of the process time after its own `_process`.

const CAPACITY := 2400  ## frames kept (ten seconds at 240 Hz)
const ITERATION_CAPACITY := 1200  ## iterations kept
const WINDOW_MSEC := 10000  ## how far back the log looks
const LATE_FRAMES := 1.5  ## a frame is late when longer than this many display frames
const TOP := 5  ## the longest frames the log lists

## Flags of a frame.
const POINTER_STAGE := 1  ## the pointer was over the stage
const POINTER_DISH := 2  ## ...and over the dish
const HOVER_CARD := 4  ## a hover card showed
const SELECTION := 8  ## something was selected
const NEW_PICTURE := 16  ## a new simulation picture arrived

static var _at := PackedFloat64Array()  ## when each frame was stamped (ms)
static var _length := PackedFloat32Array()  ## frame length (ms)
static var _process := PackedFloat32Array()  ## process time (ms)
static var _poll := PackedFloat32Array()  ## the world's poll and snapshot (ms)
static var _own := PackedFloat32Array()  ## the game screen's own `_process` (ms)
static var _children := PackedFloat32Array()  ## the rest of the process step after the game screen's own `_process` (ms)
static var _look := PackedFloat32Array()  ## family-tree look-ups (`Dish.has_record`) in the frame (ms)
static var _flags := PackedInt32Array()
static var _head := 0  ## where the next frame goes
static var _count := 0

static var _it_at := PackedFloat64Array()
static var _it := PackedFloat32Array()  ## 4 figures an iteration: iteration_ms, sync_ms, submit_ms_most, step_cost_ms
static var _it_head := 0
static var _it_count := 0
static var _last_iteration := -1

static var _start_usec := 0  ## when this frame's process step began
static var _last_stamp_usec := 0
static var _poll_usec := 0
static var _own_usec := 0
static var _own_end_usec := 0
static var _look_usec := 0
static var _flags_now := 0


## Stamps the end of each frame's process step (it runs after every other node's `_process`).
class Stamp:
	extends Node

	func _ready() -> void:
		process_priority = 1 << 30
		get_tree().process_frame.connect(FrameRecord.begin)

	func _process(_delta: float) -> void:
		FrameRecord.end()


static func _allocate() -> void:
	if _at.size() == CAPACITY:
		return
	_at.resize(CAPACITY)
	_length.resize(CAPACITY)
	_process.resize(CAPACITY)
	_poll.resize(CAPACITY)
	_own.resize(CAPACITY)
	_children.resize(CAPACITY)
	_look.resize(CAPACITY)
	_flags.resize(CAPACITY)
	_it_at.resize(ITERATION_CAPACITY)
	_it.resize(ITERATION_CAPACITY * 4)


## Forgets everything (a test starts from nothing).
static func clear() -> void:
	_allocate()
	_head = 0
	_count = 0
	_it_head = 0
	_it_count = 0
	_last_iteration = -1
	_last_stamp_usec = 0


static func begin() -> void:
	_start_usec = Time.get_ticks_usec()
	_poll_usec = 0
	_own_usec = 0
	_own_end_usec = 0
	_look_usec = 0
	_flags_now = 0


static func note_poll(since_usec: int) -> void:
	_poll_usec += Time.get_ticks_usec() - since_usec


## The game screen's `_process` began at `since_usec` and ends now with `flags`.
static func note_main(since_usec: int, flags: int) -> void:
	_own_end_usec = Time.get_ticks_usec()
	_own_usec = _own_end_usec - since_usec
	_flags_now |= flags


static func note_look(since_usec: int) -> void:
	_look_usec += Time.get_ticks_usec() - since_usec


static func note_flag(flag: int) -> void:
	_flags_now |= flag


static func end() -> void:
	_allocate()
	var now := Time.get_ticks_usec()
	if _last_stamp_usec > 0 and _start_usec > 0:
		var i := _head
		_at[i] = now / 1000.0
		_length[i] = (now - _last_stamp_usec) / 1000.0
		_process[i] = (now - _start_usec) / 1000.0
		_poll[i] = _poll_usec / 1000.0
		_own[i] = _own_usec / 1000.0
		_children[i] = (now - _own_end_usec) / 1000.0 if _own_end_usec > 0 else 0.0
		_look[i] = _look_usec / 1000.0
		_flags[i] = _flags_now
		_head = (i + 1) % CAPACITY
		_count = mini(_count + 1, CAPACITY)
	_last_stamp_usec = now
	var world := WorldClient.shared()
	if world != null:
		var timing: Dictionary = world.latest().timing
		var n := int(timing.get("iterations", 0))
		if n != _last_iteration:
			if _last_iteration >= 0:
				_it_at[_it_head] = now / 1000.0
				_it[_it_head * 4] = float(timing.get("iteration_ms", 0.0))
				_it[_it_head * 4 + 1] = float(timing.get("sync_ms", 0.0))
				_it[_it_head * 4 + 2] = float(timing.get("submit_ms_most", 0.0))
				_it[_it_head * 4 + 3] = float(timing.get("step_cost_ms", 0.0))
				_it_head = (_it_head + 1) % ITERATION_CAPACITY
				_it_count = mini(_it_count + 1, ITERATION_CAPACITY)
			_last_iteration = n


## The ring's indices of the frames stamped in the `window_msec` up to `until_msec`, oldest first.
static func _indices(until_msec: float, window_msec: float) -> Array:
	var out := []
	for k in _count:
		var i := (_head - _count + k + CAPACITY) % CAPACITY
		var at := _at[i]
		if at <= until_msec and until_msec - at <= window_msec:
			out.append(i)
	return out


static func _quantile(sorted: Array, q: float) -> float:
	return float(sorted[mini(int(q * sorted.size()), sorted.size() - 1)]) if not sorted.is_empty() else 0.0


static func _spread(values: Array) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	return {"p50": _quantile(sorted, 0.5), "p95": _quantile(sorted, 0.95), "p99": _quantile(sorted, 0.99), "max": float(sorted[-1]) if not sorted.is_empty() else 0.0}


## The p95 of the process time (ms) of the frames in the last `window_msec` (0: none).
static func process_p95(window_msec: float) -> float:
	var values := []
	for i: int in _indices(Time.get_ticks_usec() / 1000.0, window_msec):
		values.append(_process[i])
	values.sort()
	return _quantile(values, 0.95)


## The frames of the last WINDOW_MSEC before `key_usec` (0: now) for the log, judged against `display_ms` (0: 60 Hz).
static func recent_frames(display_ms: float, key_usec := 0) -> Dictionary:
	var key_msec := (key_usec if key_usec > 0 else Time.get_ticks_usec()) / 1000.0
	var limit := LATE_FRAMES * (display_ms if display_ms > 0.0 else 1000.0 / 60.0)
	var indices := _indices(key_msec, WINDOW_MSEC)
	var lengths := []
	var columns := {"process": [], "poll": [], "main_own": [], "main_children": [], "family_tree_lookup": []}
	var late := 0
	var late_slow := 0
	var slow_limit := display_ms if display_ms > 0.0 else 1000.0 / 60.0
	for i: int in indices:
		lengths.append(_length[i])
		columns["process"].append(_process[i])
		columns["poll"].append(_poll[i])
		columns["main_own"].append(_own[i])
		columns["main_children"].append(_children[i])
		columns["family_tree_lookup"].append(_look[i])
		if _length[i] > limit:
			late += 1
			if _process[i] > slow_limit:
				late_slow += 1
	var out := {"frames": indices.size(), "window_s": WINDOW_MSEC / 1000.0, "late_limit_ms": limit, "late": late, "late_share": float(late) / indices.size() if not indices.is_empty() else 0.0, "frame_ms": _spread(lengths)}
	for key: String in columns:
		out[key + "_ms"] = _spread(columns[key])
	var parts_p95 := {}
	for key: String in ["poll", "main_own", "main_children", "family_tree_lookup"]:
		parts_p95[key] = out[key + "_ms"]["p95"]
	out["parts_p95_ms"] = parts_p95
	indices.sort_custom(func(a: int, b: int) -> bool: return _length[a] > _length[b])
	var top := []
	for k in mini(TOP, indices.size()):
		var i: int = indices[k]
		var f: int = _flags[i]
		top.append({
			"seconds_before_key": (key_msec - _at[i]) / 1000.0, "frame_ms": _length[i], "process_ms": _process[i], "poll_ms": _poll[i], "main_own_ms": _own[i],
			"main_children_ms": _children[i], "family_tree_lookup_ms": _look[i], "pointer_over_stage": f & POINTER_STAGE != 0, "pointer_over_dish": f & POINTER_DISH != 0,
			"hover_card": f & HOVER_CARD != 0, "selection": f & SELECTION != 0, "new_picture": f & NEW_PICTURE != 0,
		})
	out["longest"] = top
	out["late_with_long_process_share"] = float(late_slow) / late if late > 0 else 0.0
	return out


## The iterations the newest timings reported in the last WINDOW_MSEC before `key_usec` (0: now).
static func recent_iterations(key_usec := 0) -> Dictionary:
	var key_msec := (key_usec if key_usec > 0 else Time.get_ticks_usec()) / 1000.0
	var columns := [[], [], [], []]
	var n := 0
	for k in _it_count:
		var i := (_it_head - _it_count + k + ITERATION_CAPACITY) % ITERATION_CAPACITY
		if _it_at[i] <= key_msec and key_msec - _it_at[i] <= WINDOW_MSEC:
			n += 1
			for c in 4:
				columns[c].append(_it[i * 4 + c])
	var names := ["iteration_ms", "sync_ms", "submit_ms_most", "step_cost_ms"]
	var out := {"iterations": n}
	for c in 4:
		out[names[c]] = _spread(columns[c])
	return out
