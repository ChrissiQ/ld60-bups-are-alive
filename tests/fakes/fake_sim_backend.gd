class_name FakeSimBackend
extends SimBackend
## The test double for the simulation seam: serves canned snapshots, completes replies on a script and keeps a log of every call. Never
## shipped. A test advances its frame clock with `tick()` (once per frame, as the game's `set_time` would be).
##
## Replies: `submit` completes a command's reply at once when its latency is 0, else after that many `tick()`s. A reply's value and
## latency come from the next `script_reply(kind, ...)` queued for that kind, else from `default_reply` and `reply_latency_frames`.
## Lineage: a test sets `lineage_store` to a `LineageStore` (or any object with `apply_events`) and `feed_lineage` forwards to it; with none set
## it only logs a "lineage_pending" call.

var simulates := true  ## what `can_simulate` answers (a UI test wants true; set false to see the CPU stub's face)
var reply_latency_frames := 0  ## frames a reply waits when nothing scripted says otherwise
var default_reply: Variant = {}  ## the value of an unscripted reply
var lineage_store: Object = null  ## the lineage seam: where `feed_lineage` sends events (and what `lineage()` answers, as WorldClient asks)
var calls: Array[Dictionary] = []  ## {kind, args, frame, reply (SimReply or null)} in submit order
var frame := 0
var started := false
var shut_down := false
var start_limits: RefCounted = null

var _snapshot := Snapshot.new()
var _scripts: Dictionary = {}  ## kind -> Array of {value, latency, error}
var _pending: Array[Dictionary] = []  ## {reply, value, error, due}


func can_simulate() -> bool:
	return simulates


func device_name() -> String:
	return "fake"


func start(limits: RefCounted) -> void:
	started = true
	start_limits = limits


func submit(cmd: SimCommand) -> void:
	calls.append({"kind": cmd.kind, "args": cmd.args, "frame": frame, "reply": cmd.reply})
	if cmd.reply == null:
		return
	var script: Dictionary = {"value": default_reply, "latency": reply_latency_frames, "error": ""}
	var queue: Array = _scripts.get(cmd.kind, [])
	if not queue.is_empty():
		script = queue.pop_front()
	if script["latency"] <= 0:
		cmd.reply.complete(script["value"], script["error"])
	else:
		_pending.append({"reply": cmd.reply, "value": script["value"], "error": script["error"], "due": frame + script["latency"]})


func latest() -> Snapshot:
	return _snapshot


func shutdown() -> void:
	shut_down = true
	for p in _pending:
		(p["reply"] as SimReply).complete(null, "shutdown")
	_pending.clear()


## The snapshot `latest` gives from now on.
func serve(snapshot: Snapshot) -> void:
	_snapshot = snapshot


## Queues the answer to the next command of `kind` that wants a reply: its value, the frames it waits (-1: `reply_latency_frames`) and an error.
func script_reply(kind: StringName, value: Variant, latency_frames := -1, error := "") -> void:
	if not _scripts.has(kind):
		_scripts[kind] = []
	_scripts[kind].append({"value": value, "latency": reply_latency_frames if latency_frames < 0 else latency_frames, "error": error})


## One frame passes: replies whose time has come are completed.
func tick() -> void:
	frame += 1
	var still: Array[Dictionary] = []
	for p in _pending:
		if p["due"] <= frame:
			(p["reply"] as SimReply).complete(p["value"], p["error"])
		else:
			still.append(p)
	_pending = still


## The calls of one kind, in order.
func calls_of(kind: StringName) -> Array[Dictionary]:
	return calls.filter(func(c: Dictionary) -> bool: return c["kind"] == kind)


func lineage() -> Object:
	return lineage_store


## Where a test hands the lineage of an iteration to the lineage seam (`lineage.apply_events`).
func feed_lineage(births: PackedByteArray, deaths: PackedByteArray, first_step_end: float, step_seconds: float) -> void:
	if lineage_store != null:
		lineage_store.apply_events(births, deaths, first_step_end, step_seconds)
	else:
		calls.append({"kind": &"lineage_pending", "args": {"births": births.size(), "deaths": deaths.size()}, "frame": frame, "reply": null})
