class_name CannedWorld
extends SimBackend
## A test backend for screens that read a dish's bups: it can simulate, keeps a real LineageStore behind `lineage()` (which
## FakeSimBackend lacks: its `lineage` is a property, so `WorldClient.lineage()` finds no method) and serves one snapshot with
## `bups` bups in row 0 (dish number `number`), each tracked, so `Dish.bup_ids()` and `bup_info()` answer. Commands are logged
## in `calls` and their replies completed empty.

const BIRTH_BYTES := GpuLayout.BIRTH_WORDS * 4

var store := LineageStore.new()
var calls: Array[SimCommand] = []
var _snapshot := Snapshot.new()
var _seq := 0


func _init() -> void:
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)


func can_simulate() -> bool:
	return true


func device_name() -> String:
	return "test device"


func submit(cmd: SimCommand) -> void:
	calls.append(cmd)
	if cmd.reply != null:
		cmd.reply.complete(null)


func latest() -> Snapshot:
	return _snapshot


func lineage() -> LineageStore:
	return store


## Founders ids 1..bups of dish `number` are born (as the world's first iteration reports them) and a snapshot of them is served, new
## to the clients' next poll.
func serve_dish(number: int, bups: int) -> void:
	var births := PackedByteArray()
	var first := GpuLayout.make_id(number, 1)
	for i in bups:
		var e := PackedByteArray()
		e.resize(BIRTH_BYTES)
		var id := GpuLayout.make_id(number, i + 1)
		e.encode_u32(GpuLayout.EB_ID_LO * 4, id & 0xFFFFFFFF)
		e.encode_u32(GpuLayout.EB_ID_HI * 4, id >> 32)
		births.append_array(e)
	store.apply_events(births, PackedByteArray(), 0.0, 1.0)
	var snap := FakeScenes.snapshot(1, bups, 0)
	_seq += 1
	snap.seq = _seq
	(snap.dishes[0] as DishState).number = number
	var recs := FakeScenes.records(bups, first)
	var by_id := {}
	for i in bups:
		by_id[first + i] = recs.slice(i * GpuLayout.RECORD_BYTES, i * GpuLayout.RECORD_BYTES + GpuLayout.ANSWER_BYTES)
	snap.answers[0] = {"tracked": by_id, "probes": PackedFloat32Array(), "steer": {}}
	_snapshot = snap
