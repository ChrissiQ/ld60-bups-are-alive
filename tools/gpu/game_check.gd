extends SceneTree
## The pooled world as the game drives it (windowed: the simulation runs on its own local device, the main device draws). The game screen
## itself (Main, free mode, on SimService's world: its WorldClient, sim thread and LineageStore) is run as the player runs it, its
## speed and pause set as its toolbar sets them; what the screen does is checked against the pool behind it (an `inspect` on the sim thread,
## with the world paused and settled, so the family tree has caught up with the pool).
## On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/game_check.gd -- <mode> [args]
## Modes:
##   smoke                          a few hundred frames at x10,000: the screen's figures do not jump, a selected bup's panel has its info
##   edits                          mid-game changes (resize, the limit, watched bups, the pipette and the question about the old dish:
##                                  freeze, thaw, trash; a save written and read through the game's codec and loaded again; the debug
##                                  log), in the game build
##   long [hours] [founders] [limit] [feed] [bloom]   x10,000 for `hours` sim-hours: frame times, memory, the population; MEM lines
##   perf [bups] [radius] [speed] [seconds]           a dish filled with `bups` at once, drawn, at `speed`: frame times, achieved speed
## Prints "GAME CHECK OK" or the failures. A SCRIPT ERROR anywhere while it runs fails it (a Logger counts them); an ERROR line Godot
## prints is a failure too: grep the output for them.
##
## Expected values of `edits`, written before the first run [derived unless marked]:
## - consistent (after each change, paused and settled): the pool's live ids of the dish are unique and equal the family tree's living
##   bups whose home is the dish.
## - resize to 8 mm: every bup inside 8 mm; back to 10 mm: consistent.
## - limit below the population: the limit becomes the population (Dish.change_limit), and 60 frames at x10,000 later the population is
##   at most 1% (+10) above it.
## - pipette (radius 3 mm at the middle, once the dish has 2,000 bups) as Main does it: source + receiver = the count before; every moved bup alive, its home the
##   receiver's number, its family chain unchanged; the receiver's DS_MOVED_IN and the source's DS_MOVED_OUT equal the bups moved; the
##   bups alive in the tree are the same ids; a founder's living descendants in the source plus the receiver are what they were;
##   the receiver's generation (its stats) is the mean of the moved bups' divisions within 1e-4 relative; a watched bup that moved
##   is on the receiver's watch list (Main moves it); LineageStore.export_dish of the receiver lists every ancestor of its bups (those the
##   source holds too); the question about the old dish is up. Left to the harness tests: the positions shifted, the other bups and dishes
##   untouched word for word and no death counted (round_trip_test, invariants_test).
## - "Freeze": the source leaves the running dishes for the freezer and its row the pool; the receiver's chains are unchanged. Thawed: a dish under the source's
##   number with the same bups, every chain of its bups as before the freeze, the tree's record count as before the freeze (no duplicate)
##   and the receiver's pins' holders unchanged.
## - A second pipette (from the receiver) answered "Trash": the old dish leaves for good; the new receiver's chains and its watched bups'
##   pins unchanged.
## - save: the main dish gathered by the world (save_all), written by DishCodec and SaveGame to a scratch file and read back: records,
##   grid, clouds, husks and DSTATE equal the blob's; loaded as a dish of the world again (Dish.load_blob), the pool holds those records
##   and that grid word for word (the run carried on bit for bit after a load is continuation_test and codec_continuation_test).

const MAX_FRAMES := 20000
const SAVE_PATH := "user://game_check_save.json"

var main: Node
var mode := "smoke"
var args: PackedStringArray
var frame_ms := PackedFloat64Array()
var _last_usec := 0
var g: ParityGame  ## perf's world (a dish filled at once, not the game screen's)
var script_errors := ScriptErrors.new()


## Counts the SCRIPT ERRORs Godot reports while the check runs (from any thread), so one fails the check.
class ScriptErrors extends Logger:
	var _mutex := Mutex.new()
	var _seen: Array = []

	func _log_error(function: String, file: String, line: int, code: String, _rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_SCRIPT:
			return
		_mutex.lock()
		_seen.append("%s (%s:%d %s)" % [code, file, line, function])
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> Array:
		_mutex.lock()
		var out := _seen.duplicate()
		_mutex.unlock()
		return out


func _initialize() -> void:
	OS.add_logger(script_errors)
	args = OS.get_cmdline_user_args()
	mode = args[0] if args.size() > 0 else "smoke"
	if DisplayServer.get_name() == "headless":
		print("SKIP game_check: needs a local GPU (not available headless)")
		quit(0)
		return
	SimConstants.apply()
	if mode == "perf":
		g = ParityGame.start(self, "game_check perf")
		if g == null:
			return
	else:
		main = TestUtil.game_screen(self, _start())
	_run()


func _start() -> StartConditions:
	var s := StartConditions.new()
	s.dish_radius = 10000.0
	s.bups = 250
	s.bup_limit = 100000
	s.nutrient_density = 32.0
	s.feed_density = 3.0
	s.bloom_density = 0.0
	if mode == "long":
		s.bups = int(args[2]) if args.size() > 2 else 250
		s.bup_limit = int(args[3]) if args.size() > 3 else 100000
		s.feed_density = float(args[4]) if args.size() > 4 else 0.0
		s.bloom_density = float(args[5]) if args.size() > 5 else 2.0
		s.dish_radius = 90000.0
		s.nutrient_density = 4.0 if s.feed_density <= 0.0 else 32.0
	s.spread_founders()
	return s


func _run() -> void:
	for i in 3600:  # (the script starts before the autoloads are ready: the screen's _ready, and its dish, come a few frames later)
		if main == null or (main.is_node_ready() and main.dish != null and main.dish.row >= 0):
			break
		await process_frame
	var w := WorldClient.shared()
	for i in 3600:
		var st: Dictionary = w.backend.status()
		if st.get("ready", false):
			break
		await process_frame
	print("refresh rate %.1f Hz, device %s, status %s" % [DisplayServer.screen_get_refresh_rate(), w.backend.device_name(), w.backend.status()])
	match mode:
		"smoke":
			await _smoke()
		"edits":
			await _edits()
		"long":
			await _long(float(args[1]) if args.size() > 1 else 60.0)
		"perf":
			await _perf(int(args[1]) if args.size() > 1 else 100000, float(args[2]) if args.size() > 2 else 45000.0, float(args[3]) if args.size() > 3 else 10000.0, float(args[4]) if args.size() > 4 else 30.0)
		_:
			TestUtil.show(false, "no mode named %s" % mode)
	if TestUtil.checks == 0:
		TestUtil.show(false, "the mode made its checks (a script error stops a mode before them)")
	var errors := script_errors.seen()
	TestUtil.show(errors.is_empty(), "no SCRIPT ERROR while the check ran (%d%s)" % [errors.size(), ": " + "; ".join(errors.slice(0, 3)) if not errors.is_empty() else ""])
	OS.remove_logger(script_errors)
	print("%d checks, %d failed" % [TestUtil.checks, TestUtil.failures.size()])
	TestUtil.finish(self, "GAME CHECK OK", "GAME CHECK FAILED:")


# ---- the frame, the speed, the world --------------------------------------------------------------------------------------------------

func frame() -> void:
	await process_frame
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		frame_ms.append((now - _last_usec) / 1000.0)
	_last_usec = now


func frames(n: int) -> void:
	for i in n:
		await frame()


## Play at `speed`, as the toolbar's buttons do (the play button brings back the last speed: the speed is set after it).
func play(speed: float) -> void:
	main.toolbar.set_paused(false)
	main._set_paused(false)
	main.sim_speed = speed
	main.achieved_speed = speed


func pause() -> void:
	main.toolbar.set_paused(true)
	main._set_paused(true)


func value_of(reply: SimReply) -> Variant:
	for i in MAX_FRAMES:
		if reply == null or reply.is_done():
			break
		await frame()
	return reply.value() if reply != null else null


func inspect(call: Callable) -> Variant:
	return await value_of(WorldClient.shared().inspect(call))


## The sim thread has done what was sent and the result worker what that queued; then the snapshot that shows it.
func settle() -> void:
	await inspect(func(_c: SimCore, _r: Dictionary) -> int: return 0)
	var thread: Variant = WorldClient.shared().backend.get("thread")
	for i in 600:
		if thread == null or thread.worker.queued() == 0:
			break
		await frame()
	await frames(4)


func gather(d: Dish) -> DishBlob:
	var row := d.row
	return await inspect(func(core: SimCore, rows: Dictionary) -> DishBlob: return core.gather(rows[row]) if rows.has(row) else null)


func dstate(d: Dish) -> PackedByteArray:
	var row := d.row
	return await inspect(func(core: SimCore, rows: Dictionary) -> PackedByteArray: return core.dstate_row(rows[row]) if rows.has(row) else PackedByteArray())


func live_ids(d: Dish) -> Array:
	var row := d.row
	var ids: PackedInt64Array = await inspect(func(core: SimCore, rows: Dictionary) -> PackedInt64Array: return core.live_ids(rows[row]) if rows.has(row) else PackedInt64Array())
	var out := Array(ids)
	out.sort()
	return out


static func _sorted(ids: PackedInt64Array) -> Array:
	var out := Array(ids)
	out.sort()
	return out


static func _unique(sorted_ids: Array) -> bool:
	for i in range(1, sorted_ids.size()):
		if sorted_ids[i] == sorted_ids[i - 1]:
			return false
	return true


## Paused and settled: the pool's live ids of the dish, unique, are the family tree's living bups whose home is the dish.
func consistent(label: String, d: Dish) -> void:
	await settle()
	var pool := await live_ids(d)
	var tree := _sorted(d.bup_ids())
	TestUtil.show(pool.size() > 0 and _unique(pool) and pool == tree, "%s: %d bups in the pool, ids unique, the family tree's living bups of dish %d are they (%d)" % [label, pool.size(), d.number, tree.size()])


func until_population(n: int, speed: float) -> void:
	play(speed)
	for i in MAX_FRAMES:
		if main.dish.population() >= n:
			break
		await frame()


static func _pct(values: PackedFloat64Array, share: float) -> float:
	if values.is_empty():
		return 0.0
	var s := values.duplicate()
	s.sort()
	return s[mini(s.size() - 1, int(share * s.size()))]


func report_frames(label: String) -> void:
	var snap := WorldClient.shared().latest()
	print("FRAMES %s: %d frames, frame ms p50 %.2f p95 %.2f p99 %.2f max %.2f, achieved x%.0f, timing %s" % [label, frame_ms.size(), _pct(frame_ms, 0.5), _pct(frame_ms, 0.95), _pct(frame_ms, 0.99), _pct(frame_ms, 1.0), snap.achieved_speed, snap.timing])


# ---- smoke ------------------------------------------------------------------------------------------------------------------------

func _smoke() -> void:
	await frames(5)
	var d: Dish = main.dish
	play(10000.0)
	var jumps := 0
	var last_pop := -1
	var no_info := 0
	var watched := 0
	for i in 400:
		await frame()
		var pop: int = d.population()
		if last_pop > 100 and absi(pop - last_pop) > 0.2 * last_pop:
			jumps += 1
		last_pop = pop
		if i % 100 == 50:
			var ids := d.bup_ids()
			d.selected.bup = ids[ids.size() / 2] if not ids.is_empty() else -1
		elif d.selected.bup >= 0 and d.has_bup(d.selected.bup):
			watched += 1
			no_info += 1 if d.bup_info(d.selected.bup).is_empty() else 0
	print("     smoke: %d bups at %.2f sim-h; the selected bup alive in %d frames, without its info in %d of them" % [d.population(), d.time / 3600.0, watched, no_info])
	TestUtil.show(d.population() > 250 and jumps == 0, "smoke: x10,000 runs (%d bups), the population never jumps by a fifth in a frame (%d)" % [d.population(), jumps])
	TestUtil.show(watched > 100 and no_info <= 0.1 * watched, "smoke: a selected bup's panel has its info in nearly every frame (missing in %d of %d: the answers come about every 0.1 s)" % [no_info, watched])
	report_frames("smoke")


# ---- edits (in the game build) -------------------------------------------------------------------------------------------------

func _edits() -> void:
	await frames(5)
	await until_population(2000, 10000.0)
	pause()
	var d: Dish = main.dish
	await consistent("start (%.2f sim-h)" % (d.time / 3600.0), d)

	main._resize_dish(d, 8000.0)
	await settle()
	var blob: DishBlob = await gather(d)
	var inside := true
	var f := blob.records.to_float32_array()
	for i in blob.count():
		inside = inside and Vector2(f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_X], f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_Y]).length() <= 8000.0
	TestUtil.show(d.radius == 8000.0 and float(blob.spec["radius"]) == 8000.0 and inside, "resize to 8 mm: the pool's dish is 8 mm, its %d bups all inside" % blob.count())
	await consistent("after the resize to 8 mm", d)
	main._resize_dish(d, 10000.0)
	await consistent("back to 10 mm", d)

	var pop: int = d.population()
	d.change_limit(1000)
	TestUtil.show(d.bup_limit == pop, "the limit below the population is the population (%d of %d)" % [d.bup_limit, pop])
	play(10000.0)
	await frames(60)
	pause()
	await settle()
	TestUtil.show(d.population() <= int(d.bup_limit * 1.01) + 10, "60 frames on, the population stays at the limit (%d of %d)" % [d.population(), d.bup_limit])
	d.change_limit(100000)
	await consistent("after the limit", d)
	await _pipettes(d)
	await _save(main.dish)
	var text := DebugLog.report(main.dish, main, {"sim_speed": 1.0, "achieved_speed": 1.0})
	var data: Variant = JSON.parse_string(text)
	TestUtil.show(data is Dictionary and data.has("selected"), "the debug log of the game screen is JSON with its sections (%d keys)" % (data.size() if data is Dictionary else -1))
	report_frames("edits")


## The chains of `ids` in the family tree.
static func _chains(store: Object, ids: Array) -> Dictionary:
	var out := {}
	for id: int in ids:
		out[id] = store.chain(id)
	return out


static func _same_chains(store: Object, before: Dictionary) -> int:
	var differ := 0
	for id: int in before:
		if store.chain(id) != before[id]:
			differ += 1
	return differ


## The ids of the dish's bups within `r` of its middle (the pool's records).
func _within(d: Dish, r: float) -> Array:
	var blob: DishBlob = await gather(d)
	var f := blob.records.to_float32_array()
	var out: Array = []
	for i in blob.count():
		if Vector2(f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_X], f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_Y]).length() <= r:
			out.append(GpuLayout.id_of(blob.records, i))
	return out


## Main's pipette from `source` (its middle, radius r): waits for its answer and the question about the old dish. Returns the receiver.
func _pipette(source: Dish, r: float) -> Dish:
	main.pipette(source.global_position, r)
	for i in 3000:
		if main._pipette_pending.is_empty() and main._old_dish != null:
			break
		await frame()
	await settle()
	return main.dish if main.dish != source else null


func _pipettes(source: Dish) -> void:
	var store: Object = WorldClient.shared().lineage()
	var ids_before := _sorted(source.bup_ids())
	var chains := _chains(store, ids_before)
	var lines := {}  ## the oldest known ancestor -> its living descendants here
	for id: int in chains:
		var oldest: int = (chains[id] as PackedInt64Array)[0]
		lines[oldest] = int(lines.get(oldest, 0)) + 1
	var founder: int = lines.keys()[0]
	for oldest: int in lines:
		if lines[oldest] > lines[founder]:
			founder = oldest
	var descendants_before: int = store.living_descendants_of(PackedInt64Array([founder]), source.number)[0]
	var count_before := source.population()
	var watched_ids: Array = (await _within(source, 2500.0)).slice(0, 3) + ids_before.slice(0, 1)
	for id: int in watched_ids:
		source.watch_bup(id)
	var source_number := source.number  # (a frozen dish's node is freed)
	var receiver := await _pipette(source, 3000.0)
	TestUtil.show(receiver != null and main._old_dish == source and main.old_dish_dialog.visible, "the pipette made dish %s and asks about the old dish" % (receiver.number if receiver != null else -1))
	if receiver == null:
		return
	var moved := _sorted(receiver.bup_ids())
	var left := _sorted(source.bup_ids())
	var union := moved + left
	union.sort()
	var home_ok := true
	for id: int in moved:
		var info: Dictionary = store.info(id)
		home_ok = home_ok and info.get("alive", false) and int(info.get("home", -1)) == receiver.number
	var ds_r := await dstate(receiver)
	var ds_s := await dstate(source)
	var moved_in := ds_r.decode_u32(GpuLayout.DS_MOVED_IN * 4)
	var moved_out := ds_s.decode_u32(GpuLayout.DS_MOVED_OUT * 4)
	TestUtil.show(source.population() + receiver.population() == count_before and union == ids_before and moved_in == moved.size() and moved_out == moved.size(), "%d moved, %d left of %d; the same ids alive; DS_MOVED_IN %d, DS_MOVED_OUT %d" % [moved.size(), left.size(), count_before, moved_in, moved_out])
	TestUtil.show(home_ok and _same_chains(store, chains) == 0, "every moved bup alive, its home dish %d, every chain unchanged (%d differ)" % [receiver.number, _same_chains(store, chains)])
	var after: int = store.living_descendants_of(PackedInt64Array([founder]), source.number)[0] + store.living_descendants_of(PackedInt64Array([founder]), receiver.number)[0]
	TestUtil.show(after == descendants_before, "founder %d's living descendants, the source's and the receiver's, are %d (were %d)" % [founder, after, descendants_before])
	var rb: DishBlob = await gather(receiver)
	var div := 0.0
	for i in rb.count():
		div += rb.records.decode_float((i * GpuLayout.RECORD_WORDS + GpuLayout.R_DIVISIONS) * 4)
	div /= maxi(rb.count(), 1)
	var gen: float = receiver.population_stats()["generation"]
	TestUtil.show(absf(gen - div) <= 1e-4 * maxf(div, 1.0), "the receiver's generation %.5f is its bups' mean divisions %.5f" % [gen, div])
	var exported: Dictionary = store.export_dish(receiver.number, PackedInt64Array(moved))
	var listed := {}
	for id: int in exported.get("ids", PackedInt64Array()):
		listed[id] = true
	var missing := 0
	for id: int in moved:
		for a: int in store.chain(id):
			missing += 0 if listed.has(a) else 1
	TestUtil.show(missing == 0, "the receiver's export holds every ancestor of its bups, the source's shared ones too (%d records, %d missing)" % [listed.size(), missing])
	var moved_watch := watched_ids.filter(func(id: int) -> bool: return moved.has(id))
	TestUtil.show(moved_watch.size() >= 3 and moved_watch.all(func(id: int) -> bool: return receiver.is_watched(id) and not source.is_watched(id)), "the watched bups that moved (%d) are watched in the receiver" % moved_watch.size())
	var receiver_chains := _chains(store, moved)
	var source_chains := _chains(store, left)
	var holds_before := {}
	for id: int in receiver.watched:
		holds_before[id] = store.holds(id)
	var records_before: int = store.record_count()

	var source_row := source.row
	main._answer_old_dish("freeze")
	for i in 600:
		if not main.freezer_shelf.entries.is_empty() and not main._waits(main.freezer_shelf.entries[0]):
			break
		await frame()
	pause()
	await settle()
	TestUtil.show(main.dishes.all(func(dd: Dish) -> bool: return dd.number != source_number) and main.freezer_shelf.entries.size() == 1 and _same_chains(store, receiver_chains) == 0, "frozen, the source left the running dishes; the receiver's chains unchanged")
	var pool_rows: Array = await inspect(func(core: SimCore, rows: Dictionary) -> Array: return [rows.has(source_row), core.running_rows().size()])
	TestUtil.show(not pool_rows[0] and pool_rows[1] == main.dishes.size(), "the frozen dish's row left the pool (still mapped %s; %d dishes run in the pool, %d on the screen)" % [pool_rows[0], pool_rows[1], main.dishes.size()])
	var entry: Dictionary = main.freezer_shelf.entries[0]
	main.thaw(entry)
	for i in 600:
		if main._thawing.is_empty():
			break
		await frame()
	await settle()
	var thawed: Dish = null
	for dd: Dish in main.dishes:
		if dd.number == source_number:
			thawed = dd
	var holds_ok := true
	for id: int in holds_before:
		holds_ok = holds_ok and store.holds(id) == holds_before[id]
	TestUtil.show(thawed != null and _sorted(thawed.bup_ids()) == left and _same_chains(store, source_chains) == 0 and store.record_count() == records_before and holds_ok, "thawed under number %d with its %d bups, every chain as before the freeze, %d records (were %d), the receiver's pins unchanged %s" % [source_number, thawed.population() if thawed != null else -1, store.record_count(), records_before, holds_ok])
	if thawed != null:
		await consistent("the thawed dish", thawed)
	await consistent("the receiver", receiver)

	main.set_main_dish(receiver)
	await frames(3)
	for id: int in (await _within(receiver, 1500.0)).slice(0, 3):
		receiver.watch_bup(id)
	var second := await _pipette(receiver, 2000.0)
	TestUtil.show(second != null, "a second pipette from dish %d made dish %d" % [receiver.number, second.number if second != null else -1])
	if second == null:
		return
	var second_ids := _sorted(second.bup_ids())
	var second_chains := _chains(store, second_ids)
	var pins := {}
	for id: int in second.watched:
		pins[id] = store.holds(id)
	var receiver_number := receiver.number
	main._answer_old_dish("trash")
	await frames(5)
	pause()
	await settle()
	var pins_ok := true
	for id: int in pins:  # (holds counts the record's children too, which births and deaths change: a pin keeps it at 1 or more)
		pins_ok = pins_ok and store.has_record(id) and store.holds(id) >= 1 and second.is_watched(id)
	TestUtil.show(main.dishes.all(func(dd: Dish) -> bool: return dd.number != receiver_number) and _same_chains(store, second_chains) == 0 and pins_ok and pins.size() >= 3, "the old dish trashed; the new receiver's %d chains unchanged, its %d watched bups' pins intact" % [second_ids.size(), pins.size()])
	await consistent("after the trash", second)


## A save through the game's codec and a load: what the world gathers comes back word for word.
func _save(d: Dish) -> void:
	pause()
	await settle()
	var blobs: Variant = await value_of(WorldClient.shared().save_all())
	var blob: DishBlob = null
	for b: DishBlob in (blobs if blobs is Array else []):
		if b.number() == d.number:
			blob = b
	TestUtil.show(blob != null, "save_all gathers the main dish %d" % d.number)
	if blob == null:
		return
	blob.host.merge(d.host_part(), true)
	SaveGame.write({"dish": DishCodec.write_blob(blob), "goals": main.tracker.to_dict()}, SAVE_PATH)
	var data := SaveGame.read(SAVE_PATH)
	var back: DishBlob = DishCodec.read_blob(data.get("dish", {})) if data.has("dish") else null
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	var same := back != null and back.records == blob.records and back.conc == blob.conc and back.clouds == blob.clouds and back.husks == blob.husks and back.dstate == blob.dstate and back.conc2 == blob.conc2
	TestUtil.show(same, "the save written and read back holds the gathered dish word for word (%d bups)" % blob.count())
	if back == null:
		return
	var loaded := Dish.new()
	main.add_child(loaded)
	loaded.load_blob(back)
	for i in 600:
		if loaded._state != null:
			break
		await frame()
	await settle()
	var got: DishBlob = await gather(loaded)
	TestUtil.show(got != null and got.records == back.records and got.conc == back.conc and got.clouds == back.clouds, "loaded again, the pool holds its records, grid and clouds word for word")
	loaded.queue_free()
	await frames(3)


# ---- long, perf -------------------------------------------------------------------------------------------------------------------

func _mem_line(label: String, window: PackedFloat64Array) -> void:
	var d: Dish = main.dish
	var rd := RenderingServer.get_rendering_device()
	print("MEM %s: %.1f sim-h, bups %d, clouds %d, husks %d, plankton %d: frame ms p50 %.2f p95 %.2f p99 %.2f max %.2f, achieved x%.0f, main buffers %.1f MB, video %.1f MB, static %.1f MB, history %d/%d, records %d" % [label, d.time / 3600.0, d.population(), d._state.cloud_count if d._state != null else 0, d.husk_count(), d.plankton.size(), _pct(window, 0.5), _pct(window, 0.95), _pct(window, 0.99), _pct(window, 1.0), WorldClient.shared().latest().achieved_speed, rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS) / 1048576.0, Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, OS.get_static_memory_usage() / 1048576.0, d.history.fine["pop"].size(), d.history.whole["pop"].size(), WorldClient.shared().lineage().record_count()])


func _long(hours: float) -> void:
	await frames(5)
	var d: Dish = main.dish
	play(10000.0)
	var window := PackedFloat64Array()
	var started := Time.get_ticks_msec()
	var n := 0
	while d.time < hours * 3600.0 and n < 10000000:
		await frame()
		n += 1
		if frame_ms.size() > 0:
			window.append(frame_ms[-1])
		if n % 1200 == 0:
			_mem_line("long", window)
			window.clear()
	_mem_line("long end", window)
	print("     %.1f sim-hours in %.0f s of real time" % [hours, (Time.get_ticks_msec() - started) / 1000.0])
	pause()
	await consistent("after %.0f sim-hours" % hours, d)
	var overflow: int = await inspect(func(core: SimCore, _r: Dictionary) -> int: return core.overflow())
	TestUtil.show(overflow == 0, "nothing lost for want of room in %.0f sim-hours (overflow %d)" % [hours, overflow])
	report_frames("long")


func _perf(bups: int, radius: float, speed: float, seconds: float) -> void:
	if not await g.world_ready():
		TestUtil.show(false, "the world's device was made")
		return
	var gates: GDScript = load("res://tests/sim/perf_gates_test.gd")
	var d: Dish = await g.add(gates.filled_spec(bups, radius))
	var view := g.camera.get_viewport_rect().size
	g.look_at(d, minf(view.x, view.y) * 0.5 / radius)
	await g.wait_picture(d)
	for i in 120:
		await g.frame(speed, false)
	frame_ms.clear()
	_last_usec = 0
	var t0 := Time.get_ticks_msec()
	var w0 := d.time
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		d.hover_at(d.global_position, StageInput.PICK_SLACK_PIXELS * d.pixel())
		await g.frame(speed, false)
		var now := Time.get_ticks_usec()
		if _last_usec > 0:
			frame_ms.append((now - _last_usec) / 1000.0)
		_last_usec = now
	var real := (Time.get_ticks_msec() - t0) / 1000.0
	TestUtil.show(frame_ms.size() > 0 and d.time > w0, "perf: the dish ran and was drawn (%d frames)" % frame_ms.size())
	print("PERF bups=%d (%d at the end) radius=%.0f speed=x%.0f: frame ms p50 %.2f p95 %.2f p99 %.2f max %.2f, achieved x%.0f over %.0f s, timing %s" % [bups, d.population(), radius, speed, _pct(frame_ms, 0.5), _pct(frame_ms, 0.95), _pct(frame_ms, 0.99), _pct(frame_ms, 1.0), (d.time - w0) / real, real, g.world.latest().timing])
