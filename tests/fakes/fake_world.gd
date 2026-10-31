class_name FakeWorld
extends SimBackend
## A test double that keeps a small world on the main thread, for the game screen's tests (freezer_test, dishes_test): dishes in rows with
## their bups (ids and places; nothing moves, divides or dies unless a test says so), a real LineageStore, a clock that runs at the speed it
## is told, and the answers to a freeze, an unfreeze, a pipette (a retarget), a trash and a save as the simulation gives them. A
## snapshot is published at each `set_time` (the screen sends one a frame), with the history samples of the multiples of
## DishHistory.INTERVAL the clock crossed and the records of the bups each dish asks after. Each dish keeps a real DishWorld, so the sources and
## plankton the edits place come back in the snapshot's `worlds` as the simulation gives them; the field, the pictures and the probes are left
## out (a nutrient drop or an erase is only logged in `calls`). The tests that read a dish's bups, the game screens' and the title's use it
## as their one simulation double.
##
## A reply completes `reply_frames` set_times after its command (the simulation's come after its next iteration); a save's at once (the quit
## save waits for it). `refuse_next(kind)` refuses the next add, unfreeze, pipette or resize as the memory budget does;
## `refusing_iteration` stands the world still with a reason, as a refused iteration does. It extends SimBackend, not FakeSimBackend:
## WorldClient finds the family tree through a method named `lineage`, which FakeSimBackend's variable of that name rules out.

const START_CLOCK := 3661.0  ## s: the world's clock when the fake is made (the program has run a while before the game: not a multiple of INTERVAL)
const MAX_FRAME_SECONDS := 0.1  ## the longest frame the clock owes (Governor's)

var store := LineageStore.new()
var calls: Array[Dictionary] = []  ## {kind, args} in submit order
var reply_frames := 1
var frame_seconds := 1.0 / 60.0  ## the frame each set_time stands for (< 0: the real frame it reports)
var clock := START_CLOCK
var speed := 1.0
var paused := false
var refusing_iteration := ""
var device := "fake world"  ## what device_name() answers ("": a world with no device, which the record shows as CPU)
var means := {}  ## row -> the mean every statistic of that dish shows (1 when not set)

var _dishes := {}  ## row -> {number, spec: DishSpec, bups: {id: Vector2 (dish-local)}, next: the next id counter, had_bups, asked: ids, over: {id: {word: value}}, world: DishWorld, world_version, world_sent}
var _next_number := 1
var _seq := 0
var _snapshot := Snapshot.new()
var _pending: Array[Dictionary] = []  ## {reply, value, error, due}
var _refuse := {}  ## kind -> true: the next command of that kind is refused
var _refused := {}  ## row -> why, for the next snapshot
var _frame := 0


func _init() -> void:
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	_publish(clock)  # (a world that has been running has a snapshot before the game asks for anything)


func can_simulate() -> bool:
	return true


func device_name() -> String:
	return device


func latest() -> Snapshot:
	return _snapshot


func lineage() -> LineageStore:
	return store


func shutdown() -> void:
	for p in _pending:
		(p["reply"] as SimReply).complete(null, "shutdown")
	_pending.clear()


## The next command of `kind` (SimCommand.KIND_ADD_DISH, KIND_THAW, KIND_PIPETTE or KIND_RESIZE) is refused, as the memory budget refuses
## one (a refused resize leaves the dish as it was).
func refuse_next(kind: StringName) -> void:
	_refuse[kind] = true


func calls_of(kind: StringName) -> Array[Dictionary]:
	return calls.filter(func(c: Dictionary) -> bool: return c["kind"] == kind)


## The rows of the dishes in the world.
func rows() -> Array:
	return _dishes.keys()


## The row of the dish numbered `number` (-1: none).
func row_of(number: int) -> int:
	for row: int in _dishes:
		if _dishes[row]["number"] == number:
			return row
	return -1


## The ids of the bups in dish `row`.
func ids_in(row: int) -> PackedInt64Array:
	return PackedInt64Array(_dishes[row]["bups"].keys()) if _dishes.has(row) else PackedInt64Array()


## Bups born into dish `row` at the dish-local places `at`, children of `parent` (-1: founders); their ids.
func add_bups(row: int, at: Array, parent := -1) -> PackedInt64Array:
	var d: Dictionary = _dishes[row]
	var recs := PackedByteArray()
	var ids := PackedInt64Array()
	for p: Vector2 in at:
		var id := GpuLayout.make_id(d["number"], d["next"])
		d["next"] += 1
		recs.append_array(_record(id, p))
		d["bups"][id] = p
		ids.append(id)
	var births := SimCore.founder_births(recs)
	if parent >= 0:
		for i in ids.size():
			births.encode_u32((i * GpuLayout.BIRTH_WORDS + GpuLayout.EB_PARENT_LO) * 4, parent & 0xFFFFFFFF)
			births.encode_u32((i * GpuLayout.BIRTH_WORDS + GpuLayout.EB_PARENT_HI) * 4, (parent >> 32) & 0xFFFFFFFF)
	store.apply_events(births, PackedByteArray(), clock, 0.0)
	d["had_bups"] = true
	return ids


## Every bup of dish `row` dies (the dish dies out at the next snapshot).
func kill(row: int) -> void:
	var d: Dictionary = _dishes[row]
	var deaths := PackedByteArray()
	deaths.resize(d["bups"].size() * GpuLayout.DEATH_WORDS * 4)
	var i := 0
	for id: int in d["bups"]:
		deaths.encode_u32((i * GpuLayout.DEATH_WORDS + GpuLayout.ED_ID_LO) * 4, id & 0xFFFFFFFF)
		deaths.encode_u32((i * GpuLayout.DEATH_WORDS + GpuLayout.ED_ID_HI) * 4, (id >> 32) & 0xFFFFFFFF)
		i += 1
	store.apply_events(PackedByteArray(), deaths, clock, 0.0)
	d["bups"] = {}


## Dish `number` holds exactly `count` bups (made first if no dish has the number: in the lowest free row), each at a place of its own: what a
## test that wants "a dish with n bups" asks for. Returns its row.
func serve_dish(number: int, count: int) -> int:
	var row := row_of(number)
	if row < 0:
		row = 0
		while _dishes.has(row):
			row += 1
		var spec := DishSpec.new()
		spec.number = number
		_dishes[row] = _entry(spec, {}, 0)
		_next_number = maxi(_next_number, number + 1)
	var have := ids_in(row)
	if have.size() > count:
		kill_ids(row, have.slice(count))
	elif have.size() < count:
		var at := []
		for i in count - have.size():
			at.append(Vector2(10.0 * (have.size() + i), 0.0))
		add_bups(row, at)
	_publish(clock)
	return row


## The bups `ids` of dish `row` die.
func kill_ids(row: int, ids: PackedInt64Array) -> void:
	var d: Dictionary = _dishes[row]
	var deaths := PackedByteArray()
	deaths.resize(ids.size() * GpuLayout.DEATH_WORDS * 4)
	for i in ids.size():
		deaths.encode_u32((i * GpuLayout.DEATH_WORDS + GpuLayout.ED_ID_LO) * 4, ids[i] & 0xFFFFFFFF)
		deaths.encode_u32((i * GpuLayout.DEATH_WORDS + GpuLayout.ED_ID_HI) * 4, (ids[i] >> 32) & 0xFFFFFFFF)
		d["bups"].erase(ids[i])
	store.apply_events(PackedByteArray(), deaths, clock, 0.0)


## Bup `id` of dish `row` moves to the dish-local `at` (what a snapshot's answer says from the next one).
func move_bup(row: int, id: int, at: Vector2) -> void:
	_dishes[row]["bups"][id] = at


## Words of bup `id`'s record are set (`words`: GpuLayout.R_* -> value: the energy, the mass, a gene), as a snapshot's answer says them.
func edit_bup(row: int, id: int, words: Dictionary) -> void:
	var over: Dictionary = _dishes[row]["over"].get_or_add(id, {})
	over.merge(words, true)


## The DishWorld of dish `row`, which the world edits reach.
func world_of(row: int) -> DishWorld:
	return _dishes[row]["world"]


## The world of dish `row` was changed through `world_of` (as a burst or a thousand sources placed at once): the next snapshot carries a new copy.
func touch_world(row: int) -> void:
	_dishes[row]["world_version"] += 1


## Where bup `id` of dish `row` is (dish-local).
func place_of(row: int, id: int) -> Vector2:
	return _dishes[row]["bups"][id]


func submit(cmd: SimCommand) -> void:
	calls.append({"kind": cmd.kind, "args": cmd.args})
	var a := cmd.args
	match cmd.kind:
		SimCommand.KIND_ADD_DISH:
			_add(int(a["row"]), a["spec"])
		SimCommand.KIND_REMOVE_DISH:
			_remove(int(a["row"]))
		SimCommand.KIND_FREEZE:
			_answer(cmd.reply, _freeze(int(a["row"])))
		SimCommand.KIND_THAW:
			_thaw(int(a["row"]), a["blob"])
		SimCommand.KIND_PIPETTE:
			_pipette(int(a["row"]), a["centre"], float(a["radius"]), int(a["new_row"]), cmd.reply)
		SimCommand.KIND_SET_TIME:
			_set_time(float(a["speed"]), bool(a["paused"]), float(a["real_dt"]))
		SimCommand.KIND_ASK:
			if _dishes.has(int(a["row"])):
				_dishes[int(a["row"])]["asked"] = Array(a["questions"].get("tracked", []))
		SimCommand.KIND_SAVE_ALL:
			cmd.reply.complete(_save_all())
		SimCommand.KIND_EDIT_WORLD:
			_edit_world(int(a["row"]), a["edit"])
		SimCommand.KIND_RESIZE:
			if _refuse.erase(SimCommand.KIND_RESIZE):
				_answer(cmd.reply, null, "past the memory budget")
			else:
				_answer(cmd.reply, _resize(int(a["row"]), float(a["radius"])))
		SimCommand.KIND_SET_PARAMS:
			_set_params(int(a["row"]), a["params"])
		_:
			if cmd.reply != null:
				cmd.reply.complete(null)


func _edit_world(row: int, e: WorldEdit) -> void:
	if not _dishes.has(row) or e.is_field_edit():
		return
	var d: Dictionary = _dishes[row]
	(d["world"] as DishWorld).apply(e.as_world_op())
	d["world_version"] += 1


## The dish's new radius: the bups past a smaller dish's edge die. The reply as SimCore.resize gives it.
func _resize(row: int, radius: float) -> Variant:
	if not _dishes.has(row):
		return null
	var d: Dictionary = _dishes[row]
	(d["spec"] as DishSpec).radius = radius
	var out := PackedInt64Array()
	for id: int in d["bups"]:
		if (d["bups"][id] as Vector2).length() > radius:
			out.append(id)
	kill_ids(row, out)
	(d["world"] as DishWorld).radius = radius
	d["world_version"] += 1
	return {"row": row, "removed": out.size()}


func _set_params(row: int, params: Dictionary) -> void:
	if not _dishes.has(row):
		return
	var spec: DishSpec = _dishes[row]["spec"]
	for key: String in params:
		if key in spec:
			spec.set(key, params[key])
	if params.has("bloom_density"):
		(_dishes[row]["world"] as DishWorld).set_bloom(float(params["bloom_density"]))


func _answer(reply: SimReply, value: Variant, error := "") -> void:
	if reply == null:
		return
	if reply_frames <= 0:
		reply.complete(value, error)
	else:
		_pending.append({"reply": reply, "value": value, "error": error, "due": _frame + reply_frames})


func _add(row: int, spec: DishSpec) -> void:
	if _refuse.erase(SimCommand.KIND_ADD_DISH):
		_refused[row] = "past the memory budget"
		return
	var bups := {}
	var top := 0
	for i in spec.founders.size() / GpuLayout.RECORD_BYTES:
		var id := GpuLayout.id_of(spec.founders, i)
		var o := i * GpuLayout.RECORD_BYTES
		bups[id] = Vector2(spec.founders.decode_float(o + GpuLayout.R_X * 4), spec.founders.decode_float(o + GpuLayout.R_Y * 4))
		top = maxi(top, GpuLayout.id_counter(id))
	_dishes[row] = _entry(spec.copy(), bups, top)
	_next_number = maxi(_next_number, spec.number + 1)
	if spec.founders.size() > 0:
		store.apply_events(SimCore.founder_births(spec.founders), PackedByteArray(), clock, 0.0)


func _entry(spec: DishSpec, bups: Dictionary, top: int) -> Dictionary:
	var world := DishWorld.new(spec.radius, maxi(spec.seed, 1))
	world.set_bloom(spec.bloom_density)
	return {"number": spec.number, "spec": spec, "bups": bups, "next": top + 1, "had_bups": not bups.is_empty(), "asked": [], "over": {}, "world": world, "world_version": 1, "world_sent": 0}


func _live(row: int) -> PackedInt64Array:
	return PackedInt64Array(_dishes[row]["bups"].keys())


func _remove(row: int) -> void:
	if not _dishes.has(row):
		return
	store.release_dish(_dishes[row]["number"], _live(row), int(clock / 60.0))
	_dishes.erase(row)


## The dish as the simulation gathers it: its records and a DSTATE that counts them, an empty field of its grid's size and a world at the
## clock (what DishCodec needs to read it back), and its part of the family tree.
func _blob(row: int) -> DishBlob:
	var d: Dictionary = _dishes[row]
	var spec: DishSpec = d["spec"]
	var blob := DishBlob.new()
	blob.spec = spec.to_dict()
	for id: int in d["bups"]:
		blob.records.append_array(_record(id, d["bups"][id], d["over"].get(id, {})))
	blob.dstate.resize(GpuLayout.DS_WORDS * 4)
	blob.dstate.encode_u32(GpuLayout.DS_COUNT * 4, d["bups"].size())
	var cells := DishGrid.cells_across(spec.radius, spec.resolution)
	blob.conc.resize(cells * cells)
	blob.conc2.resize(cells * cells)
	blob.dplo.resize(cells * cells * 4)
	blob.dphi.resize(cells * cells * 4)
	var w := DishWorld.new(spec.radius, maxi(spec.seed, 1))
	w.time = clock
	w.set_bloom(spec.bloom_density)
	blob.world = w.save()
	var ex: Dictionary = store.export_dish(d["number"], _live(row))
	blob.host["lineage"] = ex["bytes"]
	blob.host["lineage_ids"] = ex["ids"]
	return blob


func _freeze(row: int) -> Variant:
	if not _dishes.has(row):
		return null
	var blob := _blob(row)
	store.release_dish(_dishes[row]["number"], _live(row), int(clock / 60.0), blob.host["lineage_ids"])
	_dishes.erase(row)
	return blob


func _thaw(row: int, blob: DishBlob) -> void:
	if _refuse.erase(SimCommand.KIND_THAW):
		_refused[row] = "past the memory budget"
		return
	var spec := DishSpec.from_dict(blob.spec)
	var bups := {}
	var top := 0
	for i in blob.count():
		var id := GpuLayout.id_of(blob.records, i)
		var o := i * GpuLayout.RECORD_BYTES
		bups[id] = Vector2(blob.records.decode_float(o + GpuLayout.R_X * 4), blob.records.decode_float(o + GpuLayout.R_Y * 4))
		top = maxi(top, GpuLayout.id_counter(id))
	_dishes[row] = _entry(spec, bups, top)
	_next_number = maxi(_next_number, spec.number + 1)
	var data: PackedByteArray = blob.host.get("lineage", PackedByteArray())
	if data.size() > 0:
		store.import_bytes(data, PackedInt64Array(blob.host.get("watched", [])), PackedInt64Array(bups.keys()), spec.number)


func _pipette(row: int, centre: Vector2, radius: float, dest: int, reply: SimReply) -> void:
	if not _dishes.has(row):
		_refused[dest] = "no such dish"
		_answer(reply, null, "no such dish")
		return
	if _refuse.erase(SimCommand.KIND_PIPETTE):
		_refused[dest] = "past the memory budget"
		_answer(reply, null, "past the memory budget")
		return
	var source: Dictionary = _dishes[row]
	var number := _next_number
	_next_number += 1
	var spec := (source["spec"] as DishSpec).copy()
	spec.number = number
	spec.founders = PackedByteArray()
	var moved := {}
	var ids := PackedInt64Array()
	var top := 0
	for id: int in source["bups"].keys():
		var at: Vector2 = source["bups"][id]
		if at.distance_to(centre) <= radius:
			moved[id] = at - centre
			ids.append(id)
			source["bups"].erase(id)
			top = maxi(top, GpuLayout.id_counter(id))
	_dishes[dest] = _entry(spec, moved, top)
	store.retarget_ids(ids, number)
	_answer(reply, {"new_row": dest, "number": number, "moved": ids.size(), "ids": ids})


func _save_all() -> Array:
	var rows := _dishes.keys()
	rows.sort()
	return rows.map(func(row: int) -> DishBlob: return _blob(row))


func _set_time(p_speed: float, p_paused: bool, real_dt: float) -> void:
	speed = p_speed
	paused = p_paused
	var t0 := clock
	if not paused and refusing_iteration == "":
		clock += speed * minf(frame_seconds if frame_seconds >= 0.0 else real_dt, MAX_FRAME_SECONDS)
	_frame += 1
	var still: Array[Dictionary] = []
	for p in _pending:
		if p["due"] <= _frame:
			(p["reply"] as SimReply).complete(p["value"], p["error"])
		else:
			still.append(p)
	_pending = still
	_publish(t0)


func _publish(t0: float) -> void:
	var snap := Snapshot.new()
	_seq += 1
	snap.seq = _seq
	snap.sim_time = clock
	snap.achieved_speed = 0.0 if paused or refusing_iteration != "" else speed
	snap.paused = paused
	for row: int in _dishes:
		var d: Dictionary = _dishes[row]
		var count: int = d["bups"].size()
		var ds := FakeScenes.dish_state(d["number"], count, float(means.get(row, 1.0)))
		ds.extinct = d["had_bups"] and count == 0
		snap.dishes[row] = ds
		var samples: Array = []
		for b in range(DishHistory.boundary_of(t0) + 1, DishHistory.boundary_of(clock) + 1):
			samples.append({"time": b * DishHistory.INTERVAL, "stats": FakeScenes.stats(count)})
		snap.history[row] = samples
		var tracked := {}
		for id: int in d["asked"]:
			if d["bups"].has(id):
				tracked[id] = _record(id, d["bups"][id], d["over"].get(id, {})).slice(0, GpuLayout.ANSWER_BYTES)
		snap.answers[row] = {"tracked": tracked, "steer": {}, "probes": PackedFloat32Array()}
		if d["world_version"] != d["world_sent"]:
			d["world_sent"] = d["world_version"]
			snap.worlds[row] = _copy_of(d["world"], d["world_version"])
	snap.totals = DishState.aggregate(snap.dishes)
	snap.timing = {"refused": _refused, "refused_iteration": refusing_iteration}
	_refused = {}
	_snapshot = snap


## A bup's record at the dish-local `at`, with the founder's genes.
static func _copy_of(w: DishWorld, version: int) -> DishWorldCopy:
	var c := w.copy()
	var out := DishWorldCopy.new()
	out.version = version
	out.plankton = c["plankton"]
	for id: int in c["sources"]:
		out.sources.append({"id": id, "pos": c["sources"][id]["pos"], "rate": c["sources"][id]["rate"]})
	return out


static func _record(id: int, at: Vector2, over := {}) -> PackedByteArray:
	var words := {
		GpuLayout.R_X: at.x, GpuLayout.R_Y: at.y, GpuLayout.R_DX: 1.0,
		GpuLayout.R_SPEED: 10.0, GpuLayout.R_SENSE: 1.0, GpuLayout.R_METABOLISM: 1.0, GpuLayout.R_SIZE: 1.0,
		GpuLayout.R_ENERGY: 5.0, GpuLayout.R_MASS: 1.0, GpuLayout.R_BIRTH_MASS: 1.0, GpuLayout.R_MUTATOR: 1.0,
	}
	words.merge(over, true)
	return FakeScenes.record(id, words)
