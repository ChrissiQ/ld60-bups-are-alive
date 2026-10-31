extends SceneTree
## The family-event stream of one run on the GPU path, for the lineage replay: a scenario of tools/gpu/world_tools.gd through the game's
## path (Dish.advance -> GpuWorld on the main RenderingDevice, the processor's BupSim keeping the records from the GPU's events), the
## events caught as GpuWorld hands them to BupSim.apply_events.
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/capture_lineage.gd -- <scenario> <seed> <hours> <traits 0|1> <out prefix>
##   traits 1: 200 founders are donors with raised ceilings and the acetate key (the births' packed word carries both).
##   (tools/gpu/capture_lineage.sh runs the two streams that are kept)
##
## Files, <prefix> = tools/gpu/golden/lineage_<scenario>_seed<seed>[_traits]:
##   <prefix>_initial.bin  BupSim.lineage_export_bytes() of the dish before its first event (the founders' records).
##   <prefix>_events.bin   the operations on the store in order, little-endian, gzip-compressed (FileAccess.open_compressed with
##                         COMPRESSION_GZIP; read it back the same way). Each operation starts with a u8 kind:
##                           0 batch: f64 first_step_end, f64 step_seconds, u32 births_bytes, u32 deaths_bytes, then the births
##                             (GpuLayout.BIRTH_WORDS words each) and the deaths (GpuLayout.DEATH_WORDS words each), the arguments
##                             of BupSim.apply_events;
##                           1 pin: s64 id (BupSim.pin);
##                           2 name: s64 id, u32 byte length, UTF-8 (BupSim.set_custom_name).
##   <prefix>_final.bin    BupSim.lineage_export_bytes() after the last operation.
##   <prefix>_final.txt    key=value lines: records (record_count), alive (count of alive_ids), next_id, pinned (ids, space-separated),
##                         ops, batches, births, deaths, sim_seconds, scenario, seed, traits.
## Replaying the stream into a store that starts from _initial.bin must give _final.bin's records. Compare them by id, not by byte:
## the order of the records in a lineage_export_bytes block is not stable. In _initial.bin a record with died < 0 is alive (the founders);
## BupSim.lineage_import_bytes takes a record as alive only when a bup with that id is in the sim. The stream differs from run to run
## (the GPU's batches depend on the frames' timing): each capture is self-consistent, and one capture is the one kept.

const Tools := preload("res://tools/gpu/world_tools.gd")


## A GpuWorld that keeps the arguments of every apply_events call it makes (the same two places the base class has).
class CaptureWorld extends GpuWorld:
	var ops: Array = []
	var batch_count := 0
	var birth_total := 0
	var death_total := 0

	func _apply_ready() -> void:
		while _batches.has(_next_apply):
			var batch = _batches[_next_apply]
			if not batch.head:
				return
			if batch.births > 0 and batch.births_data == null:
				return
			if batch.deaths > 0 and batch.deaths_data == null:
				return
			_history_out.append_array(batch.samples)
			if batch.births > 0 or batch.deaths > 0:
				var births: PackedByteArray = batch.births_data if batch.births_data != null else PackedByteArray()
				var deaths: PackedByteArray = batch.deaths_data if batch.deaths_data != null else PackedByteArray()
				_apply(births, deaths, batch.start + batch.delta, batch.delta)
				applied_events += batch.births + batch.deaths
			_batches.erase(_next_apply)
			_next_apply += 1

	func finish_pending() -> void:
		for events: Dictionary in _take_unapplied_events():
			_apply(events["births"], events["deaths"], events["first_step_end"], events["step_seconds"])

	func _birth_id(births: PackedByteArray, i: int) -> int:
		return births.decode_u32(i * GpuWorld.BIRTH_BYTES + GpuLayout.EB_ID_LO * 4) | (births.decode_u32(i * GpuWorld.BIRTH_BYTES + GpuLayout.EB_ID_HI * 4) << 32)

	func _apply(births: PackedByteArray, deaths: PackedByteArray, first_step_end: float, step_seconds: float) -> void:
		ops.append({"kind": 0, "end": first_step_end, "step": step_seconds, "births": births, "deaths": deaths})
		sim.apply_events(births, deaths, first_step_end, step_seconds)
		batch_count += 1
		birth_total += births.size() / GpuWorld.BIRTH_BYTES
		death_total += deaths.size() / GpuWorld.DEATH_BYTES
		if batch_count == 5 and births.size() >= 2 * GpuWorld.BIRTH_BYTES:  # (pins and a name part-way: the first and the last birth of this batch)
			var first := _birth_id(births, 0)
			var last := _birth_id(births, births.size() / GpuWorld.BIRTH_BYTES - 1)
			for id in [first, last]:
				if sim.pin(id):
					ops.append({"kind": 1, "id": id})
			sim.set_custom_name(first, "Kept")
			ops.append({"kind": 2, "id": first, "name": "Kept"})


var dish: Dish
var world: CaptureWorld
var per_frame := 1000.0 / 6.0  # (x10,000 at 60 frames a second)
var hours := 3
var seed_value := 1
var scenario := "B"
var traits := false
var prefix := ""
var phase := 0
var waited := 0
var wait_started := 0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	scenario = a[0]; seed_value = int(a[1]); hours = int(a[2]); traits = a[3] == "1"; prefix = a[4]
	SimConstants.apply()
	dish = Tools.make_dish(self, scenario, seed_value)
	if traits:
		var genome := Genome.founder()
		genome["donor"] = true
		genome["reach"] = 0x0D | (2 << 8)
		for i in 200:
			dish.add_bup(Vector2(randf_range(-1000.0, 1000.0), randf_range(-1000.0, 1000.0)), genome, 30.0)
	_write(prefix + "_initial.bin", dish.sim.lineage_export_bytes())
	world = CaptureWorld.new(dish.sim)
	var params := dish._gpu_params()
	params["seed"] = seed_value
	params["step_seconds"] = 20.0
	world.load_from_cpu(dish.field, params)
	dish.gpu_world = world
	dish.set_backend_setting(StartConditions.BACKEND_GPU)
	dish.gpu_active = true
	var founders: PackedInt64Array = dish.sim.alive_ids()
	for i in 2:  # (two founders pinned from the start)
		if dish.sim.pin(founders[i]):
			world.ops.append({"kind": 1, "id": founders[i]})


func _write(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _finish() -> void:
	world.finish_pending()
	var f := FileAccess.open_compressed(prefix + "_events.bin", FileAccess.WRITE, FileAccess.COMPRESSION_GZIP)
	f.big_endian = false
	for op: Dictionary in world.ops:
		f.store_8(op["kind"])
		match op["kind"]:
			0:
				f.store_double(op["end"])
				f.store_double(op["step"])
				f.store_32((op["births"] as PackedByteArray).size())
				f.store_32((op["deaths"] as PackedByteArray).size())
				f.store_buffer(op["births"])
				f.store_buffer(op["deaths"])
			1:
				f.store_64(op["id"])
			2:
				var bytes: PackedByteArray = (op["name"] as String).to_utf8_buffer()
				f.store_64(op["id"])
				f.store_32(bytes.size())
				f.store_buffer(bytes)
	f.close()
	_write(prefix + "_final.bin", dish.sim.lineage_export_bytes())
	var pinned := []
	for op: Dictionary in world.ops:
		if op["kind"] == 1:
			pinned.append(str(op["id"]))
	var t := FileAccess.open(prefix + "_final.txt", FileAccess.WRITE)
	t.store_string("records=%d\nalive=%d\nnext_id=%d\npinned=%s\nops=%d\nbatches=%d\nbirths=%d\ndeaths=%d\nsim_seconds=%.1f\nscenario=%s\nseed=%d\ntraits=%d\n" % [dish.sim.record_count(), dish.sim.alive_ids().size(), dish.sim.get_next_id(), " ".join(pinned), world.ops.size(), world.batch_count, world.birth_total, world.death_total, dish.time, scenario, seed_value, 1 if traits else 0])
	t.close()
	print("LINEAGE CAPTURE %s: %d ops, %d batches, %d births, %d deaths, %d records, overflows %s" % [prefix, world.ops.size(), world.batch_count, world.birth_total, world.death_total, dish.sim.record_count(), str(Tools.overflows(world.gpu))])


func _process(_delta: float) -> bool:
	match phase:
		0:
			dish.advance(minf(per_frame, hours * 3600.0 - dish.time))
			if dish.time >= hours * 3600.0 - 1e-6:
				phase = 1
				wait_started = Time.get_ticks_msec()
		1:
			world.bup_count()
			world.poll()
			waited += 1
			if (world.pending_batches() == 0 and not world._changed and not world._mirror_in_flight) or (waited > 60 and Time.get_ticks_msec() - wait_started > 3000):
				_finish()
				phase = 2
				waited = 0
		2:
			waited += 1
			if waited == 2:
				Tools.release(dish)
			if waited > 4:
				dish.queue_free()
				return true
	return false
