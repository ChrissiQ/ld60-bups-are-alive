class_name ParityGame
extends RefCounted
## The game's own stack on the real pooled world, for the windowed parity tests (tests/sim/parity_*_test.gd):
## SimService's world (GpuSimBackend, its sim thread and LineageStore), Dish nodes in the tree drawing from the shared
## textures, a camera, and the frames the game's Main would give them. A test drives a Dish as the screen does (strike, edits, picks) and
## reads the pool behind it through `inspect` (a call on the sim thread between iterations).
##
## - A dish sits at `place`: PLACE by default, away from the world's origin (as Main's second slot), so every world-to-dish conversion is
##   exercised. A test comparing reads with a fixture to 1e-4 puts it at the origin (Main's first slot): a world coordinate is a float32,
##   whose step at 4e5 µm is 0.03 µm, which moves a read on a cloud's flank by up to 0.2% (measured: point (1524, 247) of the fixture).
## - `frame` tells the world the speed and pause each frame (Main._advance_world's call) with a frame of 1/60 s.
## - `settle` waits until the sim thread has drained what was sent and the result worker has done what that queued (the LineageStore lags
##   the pool by the worker's queue): a check of the store against the pool is made paused and settled.
## - `fixture_dish` loads the queries_check state (tools/gpu/golden/parity: 20,000 bups, its nutrient grid and 60 clouds, radius 3000,
##   100 cells across) as a dish of the world, paused, and checks that the pool holds it word for word before any test reads it.
## - `total` is the dish's nutrient as NutrientField::total counted it: the grid and the deposits waiting for it (energy: concentration
##   times the cell's area) and the live clouds' mass.

const FIXTURES := "res://tools/gpu/golden/parity/"
const FIXTURE_RADIUS := 3000.0
const FIXTURE_SEED := 5
const FIXTURE_BUPS := 20000
const PLACE := Vector2(4.0e5, 0.0)  ## the dish's centre in the world (Main.DISH_SPACING along: its second slot)
const FRAME := 1.0 / 60.0
const WAIT_FRAMES := 3600

var tree: SceneTree
var world: WorldClient
var camera: Camera2D
var holder: Node2D  ## the nodes a test adds (added to the root while the test starts: the root takes no child later)
var frames := 0
var place := PLACE  ## where the next dish is put


## The gate (SimHarness.begin: headless prints SKIP and quits) and the world. Null when the test must stop.
static func start(p_tree: SceneTree, test_name: String) -> ParityGame:
	if not SimHarness.begin(p_tree, test_name, "the pooled world"):
		return null
	SimConstants.apply()
	var g := ParityGame.new()
	g.tree = p_tree
	g.world = WorldClient.shared()
	g.holder = Node2D.new()
	p_tree.root.add_child(g.holder)
	g.camera = Camera2D.new()
	g.holder.add_child(g.camera)
	return g


## Waits for the sim thread to be ready (the world's device made and its kernels built). False when it failed.
func world_ready() -> bool:
	await tree.process_frame
	camera.make_current()
	var backend: Variant = world.backend
	for i in WAIT_FRAMES:
		var st: Dictionary = backend.status()
		if st.get("ready", false):
			return st.get("alive", false)
		await frame()
	return false


## One frame: the world is told the speed and whether it stands still, as Main does once a frame.
func frame(speed := 1.0, paused := true) -> void:
	world.set_time(speed, paused, FRAME)
	await tree.process_frame
	frames += 1


func run_frames(n: int, speed := 1.0, paused := true) -> void:
	for i in n:
		await frame(speed, paused)


## Frames at `speed` until the dish's clock (its newest snapshot's: what the screen has seen) passes `seconds` more, then paused and settled.
## The world runs no faster than its iterations allow, whatever the frames claim, so a test waits for the world's time, not for frames.
func run_for(d: Dish, seconds: float, speed: float) -> void:
	var until := d.time + seconds
	for i in WAIT_FRAMES * 4:
		if d.time >= until:
			break
		await frame(speed, false)
	await settle()


## Frames (paused unless `speed` > 0 and `paused` false) until `done` returns true; false when `most` frames pass first.
func wait_until(done: Callable, most := WAIT_FRAMES, speed := 1.0, paused := true) -> bool:
	for i in most:
		if done.call():
			return true
		await frame(speed, paused)
	return done.call()


## The value of a reply, frames passing (paused) until it is done.
func reply_value(reply: SimReply, speed := 1.0, paused := true) -> Variant:
	if reply == null:
		return null
	for i in WAIT_FRAMES:
		if reply.is_done():
			break
		await frame(speed, paused)
	return reply.value()


## `call(core: SimCore, rows: client row -> core row)` on the sim thread between iterations; its value.
func inspect(call: Callable) -> Variant:
	return await reply_value(world.inspect(call))


## Waits until the sim thread has done everything sent before and the result worker has nothing queued, then a few frames (the
## snapshot that shows it).
func settle(speed := 1.0, paused := true) -> void:
	await reply_value(world.inspect(func(_core: SimCore, _rows: Dictionary) -> int: return 0), speed, paused)
	var thread: Variant = world.backend.get("thread")
	for i in WAIT_FRAMES:
		if thread == null or thread.worker.queued() == 0:
			break
		await frame(speed, paused)
	await run_frames(3, speed, paused)


## Paused, the answers to a dish's questions (WorldClient.ask: tracked bups, probes, husks) reach a snapshot only with the pass after the
## one that made them (SimThread._results lists the answers before `_answer` makes new ones), and a paused world makes a pass only when a
## command comes. A frame (Dish._process sends what it asks), then two passes of no steps (an `inspect` each): the snapshot then carries
## the answers to what the dish asks now.
func answer_now() -> void:
	await frame()
	for k in 2:
		await reply_value(world.inspect(func(_core: SimCore, _rows: Dictionary) -> int: return 0))
	await run_frames(2)


## A Dish node at PLACE, in the tree, struck from `start` with `seed_value` (paused), once a snapshot shows it.
func strike(start: StartConditions, seed_value := 1, number := 1) -> Dish:
	var d := Dish.new()
	d.number = number
	holder.add_child(d)
	d.global_position = place
	d.set_seed(seed_value)
	d.strike(start)
	await wait_shown(d)
	return d


## A Dish node at PLACE for a dish this test adds to the world itself (`spec`: founders, grid, settings), as `strike` makes one.
func add(spec: DishSpec) -> Dish:
	var d := Dish.new()
	d.number = spec.number
	holder.add_child(d)
	d.global_position = place
	d.radius = spec.radius
	d.resolution = spec.resolution
	d.bup_limit = spec.limit
	d.feed_density = spec.feed_density
	d.bloom_density = spec.bloom_density
	d.upkeep_factor = spec.upkeep
	d.medium_thickness = spec.medium_thickness
	d.patch_seed = spec.patch_seed
	d.death_husks = (spec.flags >> GpuLayout.DPF_DEATH_HUSKS) & 1 == 1
	d.plankton_husks = (spec.flags >> GpuLayout.DPF_PLANKTON_HUSKS) & 1 == 1
	d.stationary_phase = (spec.flags >> GpuLayout.DPF_STATIONARY) & 1 == 1
	d.row = world.add_dish(spec)
	d.begin_at(world.latest().sim_time)
	await wait_shown(d)
	return d


## Frames until a snapshot shows the dish (its state).
func wait_shown(d: Dish) -> bool:
	return await wait_until(func() -> bool: return d._state != null and d.row >= 0)


## Frames until the dish's picture is drawn from a publish of the world at its present time (the view made, the shown payload the
## dish's and at least as new as the snapshot's clock).
func wait_picture(d: Dish) -> bool:
	return await wait_until(func() -> bool:
		var p := world.shown_payload()
		return d.drawing.view != null and p != null and p.row == d.row and p.sim_time >= world.latest().sim_time and d.drawing.view.payload().seq == p.seq)


## The camera on the dish: centred, `zoom` screen pixels to the µm.
func look_at(d: Dish, zoom: float) -> void:
	camera.position = d.global_position
	camera.zoom = Vector2.ONE * zoom


## The dish as the pool holds it now (SimCore.gather: a blocking read on the sim thread).
func gather(d: Dish) -> DishBlob:
	var row := d.row
	return await inspect(func(core: SimCore, rows: Dictionary) -> DishBlob: return core.gather(rows[row]) if rows.has(row) else null)


## The core's row of a dish (-1 when the world does not run it).
func core_row(d: Dish) -> int:
	var row := d.row
	return await inspect(func(_core: SimCore, rows: Dictionary) -> int: return rows.get(row, -1))


## The nutrient in a gathered dish, in energy: the grid and the deposits waiting for it (each cell's concentration times its area) and
## the live clouds' mass (NutrientField::total).
static func total(blob: DishBlob) -> float:
	return grid_total(blob) + clouds_total(blob)


static func grid_total(blob: DishBlob) -> float:
	var n := int(sqrt(blob.conc.size()))
	var spacing := 2.0 * float(blob.spec["radius"]) / n
	var sum := 0.0
	for c in blob.conc.size():
		sum += blob.conc[c] + deposit(blob, c)
	return sum * spacing * spacing


## What waits in cell `c`'s deposits (a concentration: FIX20 of DPHI and DPLO).
static func deposit(blob: DishBlob, c: int) -> float:
	if blob.dplo.size() < (c + 1) * 4:
		return 0.0
	return float(blob.dphi.decode_u32(c * 4)) * 4096.0 + float(blob.dplo.decode_u32(c * 4)) * 9.5367431640625e-7


static func clouds_total(blob: DishBlob) -> float:
	var sum := 0.0
	for k in blob.clouds.size() / 8:
		sum += blob.clouds[k * 8 + 2]
	return sum


## The cells across the gathered dish's grid and their spacing.
static func grid_of(blob: DishBlob) -> Vector2:
	var n := int(sqrt(blob.conc.size()))
	return Vector2(n, 2.0 * float(blob.spec["radius"]) / n)


# ---- the fixture ---------------------------------------------------------------------------------------------------------------

static func gz(file: String) -> PackedByteArray:
	var f := FileAccess.open_compressed(FIXTURES + file, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	return f.get_buffer(f.get_length()) if f != null else PackedByteArray()


static func text(file: String) -> String:
	return FileAccess.get_file_as_string(FIXTURES + file)


## The fixture's id `id` (the CPU dish's, a bare counter) as the id it has in dish `number` of the pool.
static func pooled_id(number: int, id: int) -> int:
	return GpuLayout.make_id(number, id) if id >= 0 else -1


## The fixture's records with every id given dish `number`'s high part (the counters kept).
static func fixture_records(number: int) -> PackedByteArray:
	var recs := gz("state_records.bin.gz")
	for i in recs.size() / GpuLayout.RECORD_BYTES:
		GpuLayout.set_id(recs, i, pooled_id(number, GpuLayout.id_of(recs, i) & ((1 << GpuLayout.ID_COUNTER_BITS) - 1)))
	return recs


## The fixture's clouds as pool slots (x, y, mass, variance, cut; the row word and the list words the core fills).
static func fixture_clouds() -> PackedFloat32Array:
	var five := gz("state_field_puffs.bin.gz").to_float32_array()
	var out := PackedFloat32Array()
	for k in five.size() / 5:
		out.append_array(five.slice(k * 5, k * 5 + 5))
		out.append_array(PackedFloat32Array([1.0, 0.0, 0.0]))
	return out


## The fixture's state as dish `number` (paused): its 20,000 bups as founders (so the LineageStore has their records), no feed, no bloom,
## its grid and clouds put in its field block, the field's picture of the reads and the clouds' lists made as a step makes them. Returns
## the Dish and a line naming what is not as the fixture holds it ("" when the pool holds it word for word).
func fixture_dish(number := 1) -> Array:
	var spec := DishSpec.new()
	spec.number = number
	spec.radius = FIXTURE_RADIUS
	spec.resolution = StartConditions.MIN_NUTRIENT_RESOLUTION
	spec.limit = FIXTURE_BUPS + 1000
	spec.seed = FIXTURE_SEED
	spec.nutrient_density = 0.0
	spec.feed_density = 0.0
	spec.bloom_density = 0.0
	spec.founders = fixture_records(number)
	var d: Dish = await add(spec)
	var conc := gz("state_field_conc.bin.gz").to_float32_array()
	var clouds := fixture_clouds()
	var row := d.row
	await inspect(func(core: SimCore, rows: Dictionary) -> int:
		var cr: int = rows[row]
		core.set_field(cr, conc)
		core._append_slots("PUFF", GpuLayout.WD_CLOUD_SLOTS, clouds, cr)
		var ds := core.dstate_row(cr)
		ds.encode_u32(GpuLayout.DS_CLOUD_SLOTS * 4, clouds.size() / 8)
		core._set_ds_row(cr, ds)
		core._run_list(func(cl: int) -> void:
			core._disp(cl, "pool_snapshot", SimCore._groups(core.arena.cell_top))
			core._record_lists(cl, SimCore._groups(maxi(core._wd(GpuLayout.WD_CLOUD_SLOTS), 64))))
		return 0)
	var blob: DishBlob = await gather(d)
	var problem := ""
	if blob == null:
		problem = "no dish"
	elif blob.records != spec.founders:
		problem = "records differ (%d bytes against %d)" % [blob.records.size(), spec.founders.size()]
	elif blob.conc != conc:
		problem = "the grid differs"
	elif blob.clouds.size() != clouds.size():
		problem = "%d clouds, the fixture %d" % [blob.clouds.size() / 8, clouds.size() / 8]
	else:
		for k in clouds.size() / 8:
			for j in 5:
				if blob.clouds[k * 8 + j] != clouds[k * 8 + j]:
					problem = "cloud %d word %d differs" % [k, j]
	return [d, problem]
