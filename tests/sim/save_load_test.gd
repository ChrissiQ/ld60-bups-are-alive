extends SceneTree
## The game's save and load on the real pool, through the simulation thread, the lineage store and the save file. Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/save_load_test.gd
##
## Expected values [derived from the code: `SimThread._save_all` is `SimCore.gather` plus the dish's world
## and its lineage export; DishCodec writes every block bit for bit; a thaw is `SimCore.load_dish` plus the world and the lineage import]:
## - (the stats section is excluded: a pass's scratch, zero in a dish that has not stepped since its load)
## - a dish with 40 bups, a source and plankton, run at x600 for a while and then paused, saved (`save_all`), written through
##   DishCodec and SaveGame to a scratch file, read back, the dish trashed and the saved one loaded (a thaw, as Main/Dish.load_blob do):
##   its canonical dump equals the one taken just before the save (CanonicalDump.diff == ""), a second save_all gives the same device
##   blocks (records, field, clouds, husks) and the same world (DishWorld.save), and the family tree answers for every living bup as it
##   did before (LineageStore.info equal, id by id).

const PATH := "user://save_load_test.json"
const PARTS := ["records", "conc", "conc2", "dplo", "dphi", "clouds", "husks"]


func _init() -> void:
	if not SimHarness.begin(self, "save_load_test", "the pooled core (SimCore)"):
		return
	_run()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	TestUtil.finish(self, "OK save_load_test")


func _wait(reply: SimReply) -> void:
	var until := Time.get_ticks_msec() + 20000
	while not reply.is_done() and Time.get_ticks_msec() < until:
		OS.delay_msec(5)


func _frames(thread: SimThread, frames: int, paused: bool) -> void:
	for f in frames:
		thread.submit(SimCommand.new(SimCommand.KIND_SET_TIME, {"speed": 600.0, "paused": paused, "real_dt": 1.0 / 60.0}))
		OS.delay_msec(16)


## After every command sent so far has been done and the results the worker holds have been applied.
func _settle(thread: SimThread) -> void:
	var r := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(_core: SimCore, _rows: Dictionary) -> int: return 0}, r))
	_wait(r)
	var until := Time.get_ticks_msec() + 5000
	while thread.worker.queued() > 0 and Time.get_ticks_msec() < until:
		OS.delay_msec(5)
	OS.delay_msec(100)


func _dump(thread: SimThread, client: int) -> Dictionary:
	var r := SimReply.new()
	thread.submit(SimCommand.new(SimThread.KIND_INSPECT, {"call": func(core: SimCore, rows: Dictionary) -> Variant:
		return core.canonical_dump(rows[client])}, r))
	_wait(r)
	return CanonicalDump.coerce(r.value())


func _save(thread: SimThread) -> Array:
	var r := SimReply.new()
	thread.submit(SimCommand.new(SimCommand.KIND_SAVE_ALL, {}, r))
	_wait(r)
	return r.value() if r.value() is Array else []


func _alive_ids(records: PackedByteArray) -> Array:
	var ids: Array = []
	for k in records.size() / GpuLayout.RECORD_BYTES:
		ids.append(GpuLayout.id_of(records, k))
	return ids


func _run() -> void:
	var store: Object = ClassDB.instantiate("LineageStore")
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	var thread := SimThread.new(PoolLimits.new(), store)
	thread.start()
	var until := Time.get_ticks_msec() + 20000
	while not thread.status()["ready"] and Time.get_ticks_msec() < until:
		OS.delay_msec(10)
	var spec := DishSpec.new()
	spec.number = 1
	spec.radius = 600.0
	spec.seed = 6
	spec.patchiness = 0.0
	spec.nutrient_density = 32.0
	spec.bloom_density = 2.0
	spec.founders = Scenario.small(40, 600.0).seed(77).founder_records(1)
	spec.world = {"sources": [{"pos": Vector2(100, 50), "rate": 6.0}], "plankton": [Vector2(-200, 100), Vector2(150, -250)]}
	thread.submit(SimCommand.new(SimCommand.KIND_ADD_DISH, {"row": 0, "spec": spec}))
	_frames(thread, 60, false)
	_frames(thread, 5, true)
	_settle(thread)
	var before := _dump(thread, 0)
	var first := _save(thread)
	TestUtil.show(first.size() == 1, "save_all gives the one dish (%d)" % first.size())
	if first.size() != 1:
		thread.stop()
		return
	var blob: DishBlob = first[0]
	TestUtil.show(blob.count() > 0, "the dish has bups to save (%d)" % blob.count())
	var ids := _alive_ids(blob.records)
	var infos := {}
	for id: int in ids:
		infos[id] = store.info(id)
	blob.host.merge({"history": DishHistory.new().write(), "watched": PackedInt64Array(), "nutrients_placed": 0})
	TestUtil.show(SaveGame.write({"dish": DishCodec.write_blob(blob), "goals": {}}, PATH), "the save file is written")
	var data := SaveGame.read(PATH)
	var back := DishCodec.read_blob(data.get("dish", {})) if not data.is_empty() else null
	TestUtil.show(back != null, "the save file reads back")
	if back == null:
		thread.stop()
		return
	thread.submit(SimCommand.new(SimCommand.KIND_REMOVE_DISH, {"row": 0}))
	_frames(thread, 5, true)
	_settle(thread)
	TestUtil.show(store.record_count() == 0, "the trashed dish leaves the store empty (%d records)" % store.record_count())
	thread.submit(SimCommand.new(SimCommand.KIND_THAW, {"row": 0, "blob": back}))
	_frames(thread, 5, true)
	_settle(thread)
	var after := _dump(thread, 0)
	# The stats words are the step's own scratch (the step pass writes them each step; a loaded dish has not stepped yet): not saved state.
	before.erase("stats")
	after.erase("stats")
	var line := CanonicalDump.diff(before, after)
	TestUtil.show(line == "", "the loaded dish's dump equals the one before the save: %s" % (line if line != "" else "same"))
	var second := _save(thread)
	TestUtil.show(second.size() == 1, "the loaded dish saves again")
	if second.size() == 1:
		var again: DishBlob = second[0]
		for part: String in PARTS:
			TestUtil.show(again.get(part) == blob.get(part), "a second save's %s equal the first's" % part)
		for key: String in blob.world:
			if again.world.get(key) != blob.world[key]:
				TestUtil.show(false, "the world's '%s' differs: %s against %s" % [key, str(blob.world[key]).left(80), str(again.world.get(key)).left(80)])
		var worlds_same: bool = again.world.size() == blob.world.size()
		TestUtil.show(worlds_same, "the world's saved keys are the same (%d, %d)" % [blob.world.size(), again.world.size()])
	var differing := 0
	var first_bad := ""
	for id: int in ids:
		var now: Dictionary = store.info(id)
		if now != infos[id]:
			differing += 1
			if first_bad == "":
				for k: String in infos[id]:
					if now.get(k) != infos[id][k]:
						first_bad = "id %d '%s': %s before, %s after" % [id, k, infos[id][k], now.get(k)]
						break
	TestUtil.show(differing == 0, "the family tree answers for all %d living bups as before (%d differ) %s" % [ids.size(), differing, first_bad])
	thread.stop()
