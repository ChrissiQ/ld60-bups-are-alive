class_name WorldClient
extends RefCounted
## The main thread's one door to the simulation: every call turns into a command for the backend (SimBackend) and returns
## at once; what the simulation did comes back in snapshots (`latest`, and `snapshot_changed` from `poll`) and in replies (SimReply) that
## the caller polls each frame. Nothing here waits.
##
## Rows: a dish is named by a row this client hands out at once (the lowest free one); the dish appears in a later snapshot under it. A
## row is free again as soon as the dish is removed, frozen or refused, so a snapshot taken before that may still show the old dish under
## it: a DishState's `number` says which dish it is. A dish the simulation refuses (no room in the memory budget, no free row) is listed in
## a snapshot's timing["refused"]: `poll` frees its row and emits `refused`.

signal snapshot_changed(snap: Snapshot)
signal refused(row: int, why: String)

var backend: SimBackend
var _used := {}  ## client row -> true
var _last_seq := -1
var _display_ms := 0.0


func _init(p_backend: SimBackend) -> void:
	backend = p_backend
	var hz := DisplayServer.screen_get_refresh_rate()
	_display_ms = 1000.0 / hz if hz > 0.0 else 1000.0 / 60.0


## Adds a dish; its row now (-1 when every row is taken). The dish's founders, seed and world are in `spec` (`spec.world`: {sources:
## [{pos, rate}], plankton: [Vector2]}).
func add_dish(spec: DishSpec) -> int:
	var row := _reserve()
	if row >= 0:
		_send(SimCommand.KIND_ADD_DISH, {"row": row, "spec": spec.copy()})
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
		_send(SimCommand.KIND_THAW, {"row": row, "blob": blob})
	return row


## The bups of dish `row` within `radius` µm of `centre` (dish-local) move, alive and with their ids, into a new dish like it. The reply's
## value: {new_row, number (the new dish's), moved, ids}; null with an error when it was refused (the row it held is free again).
func pipette(row: int, centre: Vector2, radius: float) -> SimReply:
	var dest := _reserve()
	if dest < 0:
		var r := SimReply.new()
		r.complete(null, "no free row")
		return r
	return _send(SimCommand.KIND_PIPETTE, {"row": row, "centre": centre, "radius": radius, "new_row": dest}, true)


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
	_send(SimCommand.KIND_SET_TIME, {"speed": speed, "paused": paused, "real_dt": real_dt, "display_ms": _display_ms})


## The dish in the main view (`row`), its camera and scale, and which pictures it wants.
func set_view(row: int, view: ViewRequest) -> void:
	var v := ViewRequest.new()
	v.row = row
	v.camera = view.camera
	v.pixel_um = view.pixel_um
	v.want_field_view = view.want_field_view
	v.want_thumbnails = view.want_thumbnails
	v.steer = view.steer
	v.haze = view.haze
	v.steer_alpha = view.steer_alpha
	_send(SimCommand.KIND_SET_VIEW, {"row": row, "view": v})


## The questions about dish `row`, kept until asked again and answered every tenth of a second or so: {"fractions": {name: [gene,
## threshold]}} (the share of bups whose gene is at least the threshold, in the dish's DishState.fractions under the same name), "tracked":
## ids (up to GpuLayout.TRACKED: their records and the steering at each, in the snapshot's answers), "probes": [x, y, speed, sense range]
## points (dish-local: the way up the gradient there, the chance of steering up it, the concentration).
func ask(row: int, questions: Dictionary) -> void:
	_send(SimCommand.KIND_ASK, {"row": row, "questions": questions.duplicate(true)})


## Every running dish as a DishBlob (each with its own lineage), in row order; the dishes run on.
func save_all() -> SimReply:
	return _send(SimCommand.KIND_SAVE_ALL, {}, true)


## The world's seed (a new dish's seed is drawn from it and its number when its spec has none).
func set_world_seed(seed_value: int) -> void:
	_send(SimThread.KIND_WORLD_SEED, {"seed": seed_value})


## Tests and tools: `call(core: SimCore, rows: client row -> core row)` runs on the sim thread between iterations; the reply's value is what
## it returns. Never for the game.
func inspect(call: Callable) -> SimReply:
	return _send(SimThread.KIND_INSPECT, {"call": call}, true)


func latest() -> Snapshot:
	return backend.latest()


## Once a frame on the main thread: a newer snapshot is acknowledged and emitted, and the rows of refused dishes are freed.
func poll() -> void:
	var snap := backend.latest()
	if snap == null or snap.seq <= 0 or snap.seq == _last_seq:
		return
	_last_seq = snap.seq
	if backend.has_method("ack"):
		backend.ack(snap.seq)
	var gone: Dictionary = snap.timing.get("refused", {})
	for row: int in gone:
		_used.erase(row)
		refused.emit(row, String(gone[row]))
	snapshot_changed.emit(snap)


## The main side bound texture `index` of `kind` on its frame `frame`: the simulation will not write it again until it is safely done.
func texture_bound(kind: String, index: int, frame: int) -> void:
	if backend.has_method("texture_bound"):
		backend.texture_bound(kind, index, frame)


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
			return row
	return -1


func _send(kind: StringName, args: Dictionary, wants_reply := false) -> SimReply:
	var reply: SimReply = SimReply.new() if wants_reply else null
	backend.submit(SimCommand.new(kind, args, reply))
	return reply
