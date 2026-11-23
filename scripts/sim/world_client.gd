class_name WorldClient
extends RefCounted
## The main thread's one door to the simulation: every call turns into a command for the backend (SimBackend) and returns
## at once; what the simulation did comes back in snapshots (`latest`, and `snapshot_changed` from `poll`) and in replies (SimReply) that
## the caller polls each frame. Nothing here waits.
##
## Rows: a dish is named by a row this client hands out at once (the lowest free one); the dish appears in a later snapshot under it. A
## row is free again as soon as the dish is removed, frozen or refused, so a snapshot taken before that may still show the old dish under
## it: a DishState's `number` says which dish it is. A dish the simulation refuses (no room in the memory budget, no free row) is listed in
## a snapshot's timing["refused"], and in every later one until a snapshot that carried it is acknowledged: `poll` frees its row and emits
## `refused` once for it, by the snapshot that first carried it (timing["refused_seq"]; a backend without that key carries each refusal once).
##
## The main view's picture is played out on a clock of simulated time of its own (`Playout`), a little behind the newest publish that has
## arrived (`shown_payload`, `shown_share`): the picture shown is the first whose simulated time is at or past the clock, and the view draws
## each bup the share of the way from its place in the picture before to its place in that one that the clock has gone between the two
## pictures' times. The clock runs at the pace the publishes arrive at (simulated seconds a real second, smoothed), trimmed to keep it
## LEAD_SPANS arrivals' worth of simulated time behind the newest, so a picture that comes a little late is met by the lead and the bups
## move on every frame at an even speed instead of stopping at each picture and jumping at the next; each picture's time on screen comes
## from when the pictures really arrived. The display runs that lead behind the simulation. A publish at the same simulated time as the
## newest, of the same dish (a pass of no steps: the simulation carries that picture's places before into it), takes its place. At most
## WAITING_MOST wait past the one shown (the oldest of more are skipped), and a clock left far behind (SNAP_SPANS arrivals' worth) is
## brought up to the lead. Paused, the newest is shown, still (the share is 1). Publishes of a dish that is no longer the main view's
## (`set_view`) are dropped, waiting or arriving, and the clock starts again with the next.

const WAITING_MOST := GpuLayout.PICTURES_MOST + 2  ## publishes seen and not yet shown that the playout keeps: an iteration's burst and two more (SimCore.PAYLOAD_TEXTURES holds their textures)
const PICTURE_WINDOW_MSEC := 1000  ## how far back `picture_rate` counts

signal snapshot_changed(snap: Snapshot)
signal refused(row: int, why: String)

var backend: SimBackend
var _used := {}  ## client row -> true
var _epoch := 0  ## how many times a row was handed out (`_reserve`)
var _epochs := {}  ## client row -> the epoch of the dish it was last handed to: what that dish's snapshots and pictures carry (`epoch_of`)
var _last_seq := -1
var display_ms := 0.0  ## the display's frame (ms), from the screen's refresh rate, sent with every set_time for the governor's pacing (0: not known, no pacing)
var _playout := Playout.new()
var _view_row := -1  ## the main view's dish (`set_view`; -1: not told, nothing is dropped)
var _last_poll_usec := -1
var _new_pictures: Array = []  ## [msec, poll, sim time] of each frame that showed the main view a new publish, the last PICTURE_WINDOW_MSEC
var _arrivals: Array = []  ## msec of each publish that arrived, the last PICTURE_WINDOW_MSEC
var _known_publish := -1  ## the newest publish seen
var _refusals_taken := {}  ## row -> the snapshot that first carried the last refusal of it that was taken (timing["refused_seq"])
var _polls := 0  ## frames polled so far (the question latency counts in these)
var _asked := {}  ## row -> {bup id: [poll, snapshot seq, msec] of its first question not yet answered}
var _pick_latency := {"last": 0, "max": 0, "last_ms": 0.0}  ## frames and ms from a bup's first question to its first answer
var _paused := false  ## as the last `set_time` said


## The main view's playout on its own clock of simulated time (see the header). `step` once a frame with the publishes that arrived, the
## frame's real length and whether the game is paused; then `shown` and `share` are the frame's.
class Playout:
	extends RefCounted
	const LEAD_SPANS := 2.0  ## the lead the clock keeps behind the newest publish, on average, in arrivals' worth of simulated time: an arrival up to twice the usual time apart is met without a stop
	const SNAP_SPANS := 4.0  ## a clock further behind than this many arrivals' worth (the usual, or this arrival's if more) is brought up to the lead (after a stall or a hitch)
	const PACE_WEIGHT := 0.2  ## the weight of the newest arrival in the smoothed pace and span
	const TRIM := 0.5  ## how hard the pace is trimmed toward the lead, set at each arrival and held to the next (an even speed between them): the rate is the pace times 1 + TRIM x (lead - its aim) / its aim ...
	const TRIM_MOST := 0.5  ## ... at most this far from the pace either way
	const DT_MOST := 0.25  ## s: the most one frame moves the clock (a long hitch does not run it past the pictures)

	var shown: PayloadInfo = null  ## the picture shown this frame
	var share := 1.0  ## how far between the picture before and `shown` the clock is this frame
	var skipped := 0  ## publishes passed without being shown, so far
	var snaps := 0  ## times the clock was brought up to the lead, so far (a jump of the drawing)
	var last_dt := 0.0  ## the real length the last step moved the clock by (s)
	var clock := -1.0  ## simulated s (-1: none yet)
	var queue: Array = []  ## publishes not yet passed, oldest first: the first is the one shown
	var pace := 0.0  ## simulated s a real s that the publishes arrive at: the smoothed span over the smoothed time between arrivals (a mean of each arrival's own ratio would run fast when the times vary)
	var interval := 0.0  ## real s between arrivals, smoothed
	var span := 0.0  ## simulated s between arrivals, smoothed
	var per := 1.0  ## publishes an arrival brings, smoothed
	var rate := 0.0  ## simulated s a real s the clock runs at until the next arrival
	var before := -1.0  ## the simulated time of the picture before the one shown (-1: none)
	var _since_arrival := 0.0  ## real s since the last arrival
	var _last_t := -1.0  ## the newest simulated time that arrived
	var _fresh := true  ## no arrival yet to measure the next from (the start, a pause, a dish switch)

	## The playout starts again (another dish, or none).
	func reset() -> void:
		clock = -1.0
		queue = []
		before = -1.0
		_last_t = -1.0
		_fresh = true

	## One frame: `arrived` the publishes that came (oldest first), `dt` the frame's real length (s).
	func step(arrived: Array, dt: float, paused: bool) -> void:
		dt = clampf(dt, 0.0, DT_MOST)
		last_dt = dt
		_since_arrival += dt
		var came := 0
		for p: PayloadInfo in arrived:
			if not queue.is_empty() and p.sim_time <= (queue[-1] as PayloadInfo).sim_time:
				if p.sim_time == (queue[-1] as PayloadInfo).sim_time:
					queue[-1] = p  # (a pass of no steps: the same moment again)
				continue
			queue.append(p)
			came += 1
		if came > 0:
			var newest := (queue[-1] as PayloadInfo).sim_time
			var gone := newest - _last_t if _last_t >= 0.0 else 0.0
			if not _fresh and not paused and _last_t >= 0.0 and _since_arrival > 0.0:
				span = gone if span <= 0.0 else lerpf(span, gone, PACE_WEIGHT)
				interval = _since_arrival if interval <= 0.0 else lerpf(interval, _since_arrival, PACE_WEIGHT)
				pace = span / interval
				per = lerpf(per, float(came), PACE_WEIGHT)
			_last_t = newest
			_since_arrival = 0.0
			_fresh = paused
			if clock >= 0.0 and span > 0.0:
				# (the lead's aim just after an arrival: LEAD_SPANS arrivals' worth on average over the time to the next, so half an arrival's
				# worth more; never more than WAITING_MOST - 1 publishes' worth, which the queue holds with the one shown and room for one more)
				var aim := minf((LEAD_SPANS + 0.5) * span, (WorldClient.WAITING_MOST - 1) * span / maxf(per, 1.0))
				var lead := newest - clock
				if lead > SNAP_SPANS * maxf(span, gone):  # (one arrival may bring several steps at once, the governor's probe of the step's cost: the trim catches that up without a jump)
					clock = newest - aim
					lead = aim
					snaps += 1
				rate = pace * (1.0 + clampf(TRIM * (lead - aim) / aim, -TRIM_MOST, TRIM_MOST))
		if paused:
			_fresh = true
		if queue.is_empty():
			return
		var last := (queue[-1] as PayloadInfo).sim_time
		if clock < 0.0 or paused:
			clock = last
		else:
			clock = minf(clock + dt * rate, last)
		while queue.size() > 1 and ((queue[0] as PayloadInfo).sim_time < clock or queue.size() > WorldClient.WAITING_MOST + 1):
			var gone_by := queue.pop_front() as PayloadInfo
			if gone_by != shown and not paused:
				skipped += 1
			before = gone_by.sim_time
			clock = maxf(clock, before)
		shown = queue[0]
		var t := shown.sim_time
		share = 1.0 if paused or before < 0.0 or t <= before else clampf((clock - before) / (t - before), 0.0, 1.0)


## The game's world: the SimService autoload's (null where it is not there). Reached through the tree, not the autoload's name, so the
## scripts that use it compile before the autoloads exist (a script a static initializer loads, a tool).
static func shared() -> WorldClient:
	var tree := Engine.get_main_loop() as SceneTree
	var service: Node = tree.root.get_node_or_null(^"SimService") if tree != null else null
	return service.world() if service != null else null


func _init(p_backend: SimBackend) -> void:
	backend = p_backend
	var hz := DisplayServer.screen_get_refresh_rate()
	display_ms = 1000.0 / hz if hz > 0.0 else 1000.0 / 60.0


## Adds a dish; its row now (-1 when every row is taken). The dish's founders, seed and world are in `spec` (`spec.world`: {sources:
## [{pos, rate}], plankton: [Vector2]}).
func add_dish(spec: DishSpec) -> int:
	var row := _reserve()
	if row >= 0:
		_send(SimCommand.KIND_ADD_DISH, {"row": row, "epoch": _epochs[row], "spec": spec.copy()})
	return row


## Trash: the dish leaves the world and the store keeps only what other dishes still need of its lineage.
func remove_dish(row: int) -> void:
	_send(SimCommand.KIND_REMOVE_DISH, {"row": row})
	_used.erase(row)


## The dish leaves the world; the reply's value is its DishBlob (with its lineage in `host["lineage"]`).
func freeze(row: int) -> SimReply:
	var r := _send(SimCommand.KIND_FREEZE, {"row": row}, true)
	_used.erase(row)
	return r


## A frozen or saved dish comes back at the world's time; its row now.
func thaw(blob: DishBlob) -> int:
	var row := _reserve()
	if row >= 0:
		_send(SimCommand.KIND_THAW, {"row": row, "epoch": _epochs[row], "blob": blob})
	return row


## The bups of dish `row` within `radius` µm of `centre` (dish-local) move, alive and with their ids, into a new dish like it. The reply's
## value: {new_row, number (the new dish's), moved, ids}; null with an error when it was refused (the row it held is free again).
func pipette(row: int, centre: Vector2, radius: float) -> SimReply:
	var dest := _reserve()
	if dest < 0:
		var r := SimReply.new()
		r.complete(null, "no free row")
		return r
	return _send(SimCommand.KIND_PIPETTE, {"row": row, "centre": centre, "radius": radius, "new_row": dest, "epoch": _epochs[dest]}, true)


## The dish's new size about its centre (µm), and with `resolution` > 0 its grid's most cells across (SimCore.resize). The reply's value:
## {row, removed (the bups past a smaller dish's edge, which died)}; null with an error when the memory budget refused it.
func resize(row: int, radius: float, resolution := -1) -> SimReply:
	return _send(SimCommand.KIND_RESIZE, {"row": row, "radius": radius, "resolution": resolution}, true)


## Changes a running dish's settings from its next step (`params`: bloom_density, feed_density, upkeep, limit, flags: DishSpec's names).
func set_params(row: int, params: Dictionary) -> void:
	_send(SimCommand.KIND_SET_PARAMS, {"row": row, "params": params.duplicate()})


## Places or removes a source, plankton, a drop of nutrient or an erasing disc (dish-local).
func edit_world(row: int, e: WorldEdit) -> void:
	var c := WorldEdit.new()
	c.kind = e.kind
	c.position = e.position
	c.amount = e.amount
	c.radius = e.radius
	c.id = e.id
	_send(SimCommand.KIND_EDIT_WORLD, {"row": row, "edit": c})


## Once a frame: the speed, whether the game is paused, and the frame's real length (s). The simulation owes speed x the frame (capped)
## and steps by the speed's step length, never by the frame's; the frame's length also sets its duty.
func set_time(speed: float, paused: bool, real_dt: float) -> void:
	_paused = paused
	_send(SimCommand.KIND_SET_TIME, {"speed": speed, "paused": paused, "real_dt": real_dt, "display_ms": display_ms})


## The dish in the main view (`row`), its camera and scale, and which pictures it wants.
func set_view(row: int, view: ViewRequest) -> void:
	if row != _view_row:
		_view_row = row
		_playout.queue = _of_row(_playout.queue, row)
		if _playout.queue.is_empty():
			_playout.reset()
	var v := ViewRequest.new()
	v.row = row
	v.camera = view.camera
	v.pixel_um = view.pixel_um
	v.fresh = view.fresh
	v.want_field_view = view.want_field_view
	v.want_thumbnails = view.want_thumbnails
	v.want_husks = view.want_husks
	v.steer = view.steer
	v.haze = view.haze
	v.steer_alpha = view.steer_alpha
	_send(SimCommand.KIND_SET_VIEW, {"row": row, "view": v})


## The questions about dish `row`, kept until asked again and answered every tenth of a second or so: {"fractions": {name: [gene,
## threshold]}} (up to GpuLayout.FRACTIONS: the share of bups whose gene is at least the threshold, in the dish's DishState.fractions under
## the same name), "tracked":
## ids (up to GpuLayout.TRACKED: their records and the steering at each, in the snapshot's answers), "probes": [x, y, speed, sense range]
## points (dish-local: the way up the gradient there, the chance of steering up it, the concentration, the gradient's size), "husks":
## [x, y, reach] places (dish-local, up to GpuLayout.HUSK_QUERIES: the nearest live husk within reach of each).
func ask(row: int, questions: Dictionary) -> void:
	var waiting: Dictionary = _asked.get(row, {})
	var now_asked: Array = questions.get("tracked", [])
	for id in now_asked:
		if not waiting.has(id):
			waiting[id] = [_polls, _last_seq, Time.get_ticks_msec()]
	for id in waiting.keys():
		if not now_asked.has(id):
			waiting.erase(id)  # (no longer asked: not answered, not timed)
	_asked[row] = waiting
	_send(SimCommand.KIND_ASK, {"row": row, "questions": questions.duplicate(true)})


## Frames, and the last and the longest, from a bup's first question to the first answer about it (the pick latency of the debug log).
func pick_latency() -> Dictionary:
	return _pick_latency.duplicate()


## Every running dish as a DishBlob (each with its own lineage), in row order; the dishes run on.
func save_all() -> SimReply:
	return _send(SimCommand.KIND_SAVE_ALL, {}, true)


## A new game begins (sent before its first dish is asked for): the dishes' numbers start again past the running dishes' (from 1 when
## none runs), and the family tree's times count from `game_began` (the world time the game began at: Main.game_began), so a bup's birth
## and death read on the game's clock, and a loaded game's go on from the times its save kept.
func begin_game(game_began: float) -> void:
	_send(SimThread.KIND_BEGIN_GAME, {"game_began": game_began})


## The world's seed (a new dish's seed is drawn from it and its number when its spec has none).
func set_world_seed(seed_value: int) -> void:
	_send(SimThread.KIND_WORLD_SEED, {"seed": seed_value})


## The ids of the bups at texels `indices` of the payload published as number `seq` (PayloadInfo.seq), when the pictures are handed over
## as bytes and so carry no ids: the reply's value is a PackedInt64Array, an id each, -1 for a texel of a payload the simulation no longer
## holds (it keeps the last SimCore.ID_RING).
func ids_at(seq: int, indices: PackedInt32Array) -> SimReply:
	return _send(SimThread.KIND_IDS_AT, {"seq": seq, "indices": indices}, true)


## Tests and tools: `call(core: SimCore, rows: client row -> core row)` runs on the sim thread between iterations; the reply's value is what
## it returns. Never for the game.
func inspect(call: Callable) -> SimReply:
	return _send(SimThread.KIND_INSPECT, {"call": call}, true)


func latest() -> Snapshot:
	return backend.latest()


## How far the drawing runs behind the newest publish that arrived: {sim_s (simulated time between the clock and it), ms (that at the
## pace the publishes arrive at), pictures (the publishes waiting past the one shown, and the share of the shown one still to go)}.
func lag() -> Dictionary:
	var q := _playout.queue
	if q.is_empty() or _playout.clock < 0.0:
		return {"sim_s": 0.0, "ms": 0.0, "pictures": 0.0}
	var sim_s: float = (q[-1] as PayloadInfo).sim_time - _playout.clock
	return {"sim_s": sim_s, "ms": 1000.0 * sim_s / _playout.pace if _playout.pace > 0.0 else 0.0, "pictures": float(q.size() - 1) + (1.0 - _playout.share)}


## The main view's picture this frame (null before the first publish): see the header.
func shown_payload() -> PayloadInfo:
	return _playout.shown


## How far the view draws the bups this frame from their places in the picture before (0) to their places in the one shown (1): see the
## header. 1 while paused or before the first publish.
func shown_share() -> float:
	return 1.0 if _paused or _playout.shown == null else _playout.share


## Once a frame on the main thread: a newer snapshot is acknowledged and emitted, the rows of refused dishes are freed, and the playout
## moves on a frame.
func poll() -> void:
	_polls += 1
	var snap := backend.latest()
	var arrived: Array = []
	if snap != null and snap.seq > 0 and snap.seq != _last_seq:
		var published: Array = snap.payloads if not snap.payloads.is_empty() else ([snap.payload] if snap.payload != null else [])
		for p: PayloadInfo in published:
			if p.seq > _known_publish:
				arrived.append(p)
				_known_publish = p.seq
	arrived = _of_row(arrived, _view_row)
	var usec := Time.get_ticks_usec()
	var dt := (usec - _last_poll_usec) / 1e6 if _last_poll_usec >= 0 else 0.0
	_last_poll_usec = usec
	var was := _playout.shown
	_playout.step(arrived, dt, _paused)
	var now := Time.get_ticks_msec()
	for _p: PayloadInfo in arrived:
		_arrivals.append(now)
	if _playout.shown != null and _playout.shown != was:
		_new_pictures.append([now, _polls, _playout.shown.sim_time])
		FrameRecord.note_flag(FrameRecord.NEW_PICTURE)
	_forget_pictures(now)
	if snap == null or snap.seq <= 0 or snap.seq == _last_seq:
		return
	_last_seq = snap.seq
	if backend.has_method("ack"):
		backend.ack(snap.seq)
	_time_answers(snap)
	var gone: Dictionary = snap.timing.get("refused", {})
	var first_carried: Dictionary = snap.timing.get("refused_seq", {})
	for row: int in gone:
		var at := int(first_carried.get(row, snap.seq))
		if at <= int(_refusals_taken.get(row, -1)):
			continue  # (taken from an earlier snapshot: the row may be another dish's by now)
		_refusals_taken[row] = at
		_used.erase(row)
		refused.emit(row, String(gone[row]))
	snapshot_changed.emit(snap)


## How often the main view's picture changed in the last PICTURE_WINDOW_MSEC: {shown (new pictures shown), published (publishes that
## arrived; more than shown when some were skipped), longest_hold_frames (the most frames one picture stayed up, the one up now
## included), sim_s_per_picture (the mean simulated time between them), skipped (publishes the playout passed without showing, so far),
## lag (`lag`)}.
func picture_rate() -> Dictionary:
	_forget_pictures(Time.get_ticks_msec())
	var longest := 0
	for i in range(1, _new_pictures.size()):
		longest = maxi(longest, int(_new_pictures[i][1]) - int(_new_pictures[i - 1][1]))
	if not _new_pictures.is_empty():
		longest = maxi(longest, _polls - int(_new_pictures[-1][1]))
	var per := 0.0
	if _new_pictures.size() > 1:
		per = (float(_new_pictures[-1][2]) - float(_new_pictures[0][2])) / (_new_pictures.size() - 1)
	return {"shown": _new_pictures.size(), "published": _arrivals.size(), "longest_hold_frames": longest, "sim_s_per_picture": per,
		"skipped": _playout.skipped, "lag": lag()}


## The publishes of `pictures` that are of dish `row` (all of them for a row of -1).
static func _of_row(pictures: Array, row: int) -> Array:
	return pictures if row < 0 else pictures.filter(func(p: PayloadInfo) -> bool: return p.row == row)


func _forget_pictures(now: int) -> void:
	while not _new_pictures.is_empty() and now - int(_new_pictures[0][0]) > PICTURE_WINDOW_MSEC:
		_new_pictures.pop_front()
	while not _arrivals.is_empty() and now - int(_arrivals[0]) > PICTURE_WINDOW_MSEC:
		_arrivals.pop_front()


## Times the answers of `snap` (a snapshot taken after a question was sent: its seq is past the one current then) against the questions waiting.
func _time_answers(snap: Snapshot) -> void:
	for row: int in snap.answers:
		var waiting: Dictionary = _asked.get(row, {})
		if waiting.is_empty():
			continue
		var answered: Dictionary = (snap.answers[row] as Dictionary).get("tracked", {})
		for id in answered.keys():
			if not waiting.has(id) or snap.seq <= int(waiting[id][1]):
				continue
			var frames := _polls - int(waiting[id][0])
			_pick_latency["last"] = frames
			_pick_latency["max"] = maxi(int(_pick_latency["max"]), frames)
			_pick_latency["last_ms"] = Time.get_ticks_msec() - float(waiting[id][2])
			waiting.erase(id)


## The main side used texture `index` of `kind`, holding publish `seq` (PayloadInfo.seq, FieldViewInfo.seq), on its frame `frame`: every
## use is told, every frame, so the simulation writes a texture again only once it is safely done with (SimCore's header).
func texture_bound(kind: String, index: int, frame: int, seq: int) -> void:
	if backend.has_method("texture_bound"):
		backend.texture_bound(kind, index, frame, seq)


## The family tree (a LineageStore; null when the backend keeps none).
func lineage() -> Object:
	return backend.lineage() if backend.has_method("lineage") else null


## The rows handed out and not yet given back.
func rows() -> Array:
	var r := _used.keys()
	r.sort()
	return r


func _reserve() -> int:
	for row in GpuLayout.D_MAX:
		if not _used.has(row):
			_used[row] = true
			_epoch += 1
			_epochs[row] = _epoch
			return row
	return -1


## Which dish holds a row now: each time a row is handed out its epoch is new, and the simulation stamps the states and pictures it makes of the
## dish with the epoch it was given. A snapshot or a picture made before the dish was added (or of the dish that held the row before) carries
## another epoch, and a dish ignores it, though its row and its number may be the same (the menu's backdrop is dish 1 of a new game).
func epoch_of(row: int) -> int:
	return int(_epochs.get(row, 0))


func _send(kind: StringName, args: Dictionary, wants_reply := false) -> SimReply:
	var reply: SimReply = SimReply.new() if wants_reply else null
	backend.submit(SimCommand.new(kind, args, reply))
	return reply
