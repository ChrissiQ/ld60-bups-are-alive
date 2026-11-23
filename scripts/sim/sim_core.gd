class_name SimCore
extends RefCounted
## The pooled GPU world: every running dish's bups, fields, clouds and husks in one set of buffers on one local
## RenderingDevice, stepped together by the pooled kernels (gpu/kernels*.gd, `pool_*`). Synchronous, threadless and deterministic: a
## caller (the sim thread, a test, a tool) adds dishes, runs iterations and reads results; nothing here waits on anything but the
## device's own sync. A dish's run does not depend on what else is in the pool.
##
## The arena (SimArena) holds the buffers and grows them by 1.5 when an iteration's bound would pass 90% of one; a dish takes a row of
## the dish tables (DISHP, DSTATE), a segment of record slots (256-aligned, appended at the end and put in row order by the next step's
## compaction), a 256-aligned block of field cells and a run of cloud-list squares. An iteration (`run`) uploads the dishes' world events,
## records its steps in one compute list in the order of `_record_step` (life's `pool_*` kernels in kernels_life.gd's order), with the
## main dish's bups' picture after some of them when the plan asks for more than one picture (`_record_shot`), and after them the stats,
## the answers to the dishes' questions (`answer`) and the main dish's pictures (`publish`: into the next free shared texture), requests one read back of WORLD, DSTATE, STATS, the family events, the answers and the pictures' bytes (`_request`), then
## submits and syncs once. The pipette is its own zero-step pass (`pipette`, a retarget); a dish leaves by `remove_dish` (its blocks become
## padding at once, its clouds and husks empty slots) and comes back by `load_dish` from what `gather` read; `resize` and `set_params`
## change a running dish. Reads of parts of the buffers go through a right-sized copy (`read_parts`, `_request`).
##
## The shared textures: each publish has a number (`publish_seq`, never reused) that every texture it wrote holds, and the
## main side tells each use of a texture with the number it held (`texture_bound`). A texture is written again only once the main side has
## told of a newer publish of its kind in use, on a frame more than frame_queue_size + 1 frames before the newest frame it has told of: the
## main side's uses of a kind never go back to an older publish, so once it uses a newer one it never uses this one again, and its last use
## of it was on that frame or before. A texture never written is free. A texture holding the newest publish the main side has told of, or
## a newer one, is never written over, so a kind the main side does not use (tells nothing of) stops being published once its textures
## are all written, until it is used. Textures made afresh (a payload outgrown, another grid's size) are freed by the same rule, once the
## main side is done with them (`_free_retired`), never while it may still hold a view of them.

const D_MAX := GpuLayout.D_MAX
const RB := GpuLayout.RECORD_BYTES
const BLK := GpuLayout.BLK_SLOTS
const ENTRY_MARGIN := 1.25  ## room over the measured entries a cloud slot: the clouds spread, and each reaches more bins
const CLOUD_COMPACT_EVERY := 16  ## world steps between compactions of the clouds (a dish's own cadence is DS_STEP % 16)
const HUSK_CULL_EVERY := 32  ## world steps between culls of the husks (any cadence: a cull changes no dish)
const PRE_GROW_USE := 0.7  ## the share of the record slots in use at which pipette room is made ahead (`prepare_pipette_room`)
const EVENT_FLOOR := 32768  ## the event ring's least size (births, and as many deaths)
const EVENT_EXACT_MOST := 1 << 21  ## past this bound of an iteration's births the ring is sized from what the last iterations had
const MAX_STEPS := GpuLayout.MAX_STEPS_PER_BATCH
const MASS_SUM_MARGIN := 1.0e-3  ## the share the measured mass sum is raised by: the sums are float, in a fixed order, with a relative error far under this
const MASS_READ_ROWS := 16  ## the most running dishes whose mass sum is read from their own rows of STATS; with more, STATS is read up to the highest row
const ID_RING := WorldClient.WAITING_MOST + GpuLayout.PICTURES_MOST + 6  ## with `cpu_handover`, the payloads whose bups' ids `ids_at` can still give: a payload's ids are asked for after it has waited to be shown (at most WorldClient.WAITING_MOST publishes are ahead of it or behind it then), been shown and picked in, the pick read back (a frame or frame_queue_size frames) and the question drained between two iterations, in which the next iteration's pictures (GpuLayout.PICTURES_MOST) are published; the rest is room for a late frame
const TEXTURES := 10  ## shared textures of each of haze, steer and thumbnails (one publish an iteration at most): a publish's texture is held for 7 publishes at one publish a display frame (it waits to be shown, is shown, is superseded by the next, then frame_queue_size + 2 frames), so the rest is room for a late frame
const PAYLOAD_TEXTURES := WorldClient.WAITING_MOST + 8  ## shared textures of each of payload and ids: the main side holds at most WorldClient.WAITING_MOST + 6 (waiting, shown, superseded, then frame_queue_size + 2 frames), so an iteration's last picture always finds one; while the playout keeps pace (about one waiting when the next iteration's pictures are staged, a few more still held by the frames that drew them) the rest hold GpuLayout.PICTURES_MOST, and with fewer free an iteration publishes fewer pictures before its last
const HARD_BOUND_MOST := 1 << 18  ## the cloud (and husk) slots past which an iteration's room is estimated instead of bounded [placeholder: about 135 MB of cloud buffers at 516 B a slot]
const OVERFLOW_DEVICE := 1  ## `overflow()` bits: a kernel found a buffer full (WORLD's flag)
const OVERFLOW_BUDGET := 2  ## the room an iteration needed would pass the memory budget: it was refused, nothing ran
const SCRATCH_KEEP := 1 << 23  ## bytes: a read up to this goes through the kept scratch buffer; a larger one (a dish's records) through one made for it and freed after it, so no buffer outside the memory budget stays
const EVENT_READ_MARGIN := 1.25  ## the room over the most events a step of the last iterations had that an iteration reads back with its sync ...
const EVENT_READ_SLACK := 1024  ## ... and the events more (a step that had more has the rest read after)
const FIELD_SUBMIT_MS := 4.0  ## the most GPU time the field's diffusion rounds of a step are given in one submit: under half a display frame at 120 Hz, so the interface's frames get the card between submits [measured at 999 dishes of 300 µm in water, Apple Silicon, Metal: submits of about 4 ms gave a frame p95 of 8.7 ms, of about 9 ms 9.3 ms, the step's 140 ms of rounds in one submit 12.6-12.8 ms; the 4 ms submits cost 2-3% of the speed]
const COUNT_READ_MARGIN := 1.25  ## the share over a dish's births a step in its last iteration that `_expected_count` allows for each step to come

var rd: RenderingDevice
var limits: PoolLimits
var arena: SimArena
var world_seed := 1  ## a new dish's seed is drawn from this and its number when its spec has none
var next_number := 1  ## the number a pipette's new dish takes: past every number a dish of this game has had (numbers are never reused within a game: `begin_game`)
var errors: Array[String] = []  ## kernels that did not load or build, and the room the memory budget refused

var _own_device := false
var _made := {}  ## kernel name -> ShaderSet.create's entry
var _sets := {}  ## kernel name (with "|f" when the records are flipped) -> uniform set
var _flipped := false  ## the records' and block table's halves are swapped (BUPS2 holds the records now)
var _consts := {}
var _p := PackedFloat32Array()
var _delta := -1.0
var _dishes := {}  ## row -> CoreDish
var _world := PackedByteArray()  ## WORLD as read after the last sync (and as the host has written it since)
var _dstate := PackedByteArray()  ## DSTATE likewise
var _world_step := 0
var _overflow := 0  ## OVERFLOW_* bits, kept once seen (an overflow is never undone: a dish's run after one may depend on the others)
var _edits: Array = []  ## [row, WorldEdit] for the next batch
var _event_rows := {}  ## rows whose family events of the last iteration are in the ring
var _stats_fresh := false  ## STATS sample 0 is every running dish's current state
var version := 0  ## counts every change of what the pictures show (steps, edits made, a dish added, loaded, removed or resized, a pipette): a picture made at one version is the picture of every later one until it changes
var draw_refusal := ""  ## why the pictures are not being published (their buffers would pass the memory budget); "" while they are
var _mass_sum := {}  ## row -> the sum of the dish's bups' masses in STATS sample 0, while `_stats_fresh`
var _entries_peak := 0  ## the most list entries asked for since the last shrink check
var _entry_density := 0  ## the most entries a cloud slot in use had in the last iterations (decaying), from WORLD
var _entries_last := 0  ## the most list entries a step of the last iteration that made lists asked for
var _deaths_per_step := 0.0  ## the most deaths a step of the last iterations had (all dishes), for the clouds' headroom
var _births_per_step := 0.0
var _need_bytes := -1  ## the bytes the running dishes need (`need_bytes`), -1 when a dish came or went since it was worked out
var _leave_owed := false  ## a dish left and the arena has not yet given back what it held (`_give_back`)
var _last_steps := 0  ## the steps of the last iteration that stepped (a dish's DS_BIRTHS are that iteration's)
var _textures := {}  ## kind -> Array of `ring_of(kind)` texture RIDs (publish)
var _texture_seqs := {}  ## kind -> Array: the publish each texture holds (-1: never written)
var _texture_used := {}  ## kind -> Array: the last frame the main side told it used each texture on since it was last written
var _superseded := {}  ## kind -> Array: the frame on which the main side first told of a newer publish of the kind than each texture holds (-1: not yet)
var _seen_seq := {}  ## kind -> the newest publish of the kind the main side has told of
var _next_texture := {}  ## kind -> where the search for a free texture starts (the one after the last written)
var _frame := 0  ## the main side's frame count as last told
var _retired_textures: Array = []  ## {kind, rids, last_seq, last_use, made, moved_on} of each set of textures made afresh, freed once unused (`_free_retired`)
var textures_remade := {}  ## kind -> sets of textures made afresh so far, each kept until unused (for checks)
var publish_seq := 0  ## the number of the last publish that wrote a texture
var cpu_handover := false:  ## the main device cannot import this device's textures (Vulkan: every local device is a device of its own): `publish` makes no textures and keeps the bytes of what it publishes in `handed` for the host to carry to the main device (ViewRenderer.cpu_handover)
	set(v):
		cpu_handover = v
		if arena != null:
			arena.cpu_handover = v  # (the memory budget counts the textures of the path in use)
var handed := {}  ## with `cpu_handover`, the last publish's bytes: "payload" (the bups' used texels), "prev" (where each was in the picture before: GpuLayout.PV_*), "haze" and "steer" (RGBA8, a cell each), "thumbs" (the atlas's tile rows in use, with "thumb_rows" their number)
var handed_usec := 0  ## what taking the handed-over bytes has cost so far (microseconds, `_publish_take`), the publishes that handed bytes over and the bytes
var handed_calls := 0
var handed_bytes := 0
var _id_ring: Array = []  ## with `cpu_handover`, the ids of the last ID_RING payloads published, on this device only: {buffer: RID, seq: the publish (0: none), count: its texels}, the oldest overwritten first
var _id_ring_next := 0
var _id_ring_bytes := 0  ## each slot's size
var _temp_sets: Array[RID] = []  ## the copy kernels' sets of one publish
var _pic_dish: CoreDish = null  ## the dish the last bup picture was made of: a picture of another starts with no places before
var _pic_slot := 0  ## the slot of PAYLOAD, IDTEX and PREVXY the last bup picture was made in (`_picture_slots`)
var _moved_since_pic := true  ## steps ran (or bups were moved) since the last bup picture: the next one's places before are its bups' places in that picture; else that picture's own places before go on
var _profile: Variant = null  ## while `profile_steps` runs: kernel name -> Array of µs, each dispatch its own submit
var _scratch := RID()  ## where `read_parts` gathers what it reads (up to SCRATCH_KEEP bytes)
var _scratch_bytes := 0
var _husk_found := 0  ## the husks a read found past its bound, until a read is complete
var lone_field := false  ## checks only: a step runs the lone feed and diffusion passes (ping-pong, then pool_land_copy) in place of pool_fdiff (tools/gpu/fused_check.gd)
var _tile_rounds := PackedInt32Array()  ## the tiles of pool_fdiff that run in each round (a prefix of TILES)
var _split_usec := 0  ## the time `run`'s list spent in the field's own submits and waits (counted as the card's, not the recording's)
var _submit_usec_most := 0  ## the longest single submit and wait of `run`'s list (the screen's frames share the card with it)
var _round_tile_ms := 0.0  ## the GPU time of a diffusion round, a tile, as the field's own submits measured it (0: not known yet; `_record_step`)
var _tile_key := PackedInt32Array()  ## what TILES was built from: each dish's row, cells across and iterations
var _lists_marked := false  ## whether the step being recorded lists only the squares near a bup (`_marks_pay`)
const MARKS_BUPS_PER_CLOUD := 2  ## the marks pay while the record slots in use number under this many a cloud slot ...
const MARKS_SQUARES_PER_CLOUD := 100  ## ... and the squares number under this many a cloud slot
var list_margin_override := -1.0  ## checks only: -1 the squares round each bup a step can reach are listed when the marks pay (`_marks_pay`), else every square; -2 every square, with no marks; 0 or more that many squares round each bup; 1e8 or more every square of a dish
var lone_passes := false  ## checks only: a step runs the lone kernels in place of the fused passes, in the same order (tools/gpu/fused_check.gd)
var lone_order: Array = ["pool_ac_apply", "pool_conj_apply", "pool_life"]  ## what the lone passes run in place of pool_ac_conj_life and pool_donor_life (a check can change it to show that it would see a wrong order)


## A dish as the host knows it.
class CoreDish:
	var spec: DishSpec
	var grid: DishGrid
	var base := 0  ## its field block's first cell
	var cells := 0  ## the block's cells (n², 256-aligned)
	var bin_base := 0
	var bins := 0
	var bins_across := 0
	var iterations := 2
	var flags := 0  ## DP_FLAGS
	var cap := 0  ## DP_CAP
	var seed32 := 0


## `p_limits` null: PoolLimits' defaults. `from_source` (or the limits') compiles the kernels from GpuKernels.all() on the device. `device`
## null: a local device of the core's own, made on this thread (a local device is used only on the thread that made it).
func _init(p_limits: PoolLimits = null, from_source := false, device: RenderingDevice = null) -> void:
	limits = p_limits if p_limits != null else PoolLimits.new()
	rd = device if device != null else RenderingServer.create_local_rendering_device()
	_own_device = device == null
	assert(rd != null, "SimCore: no local rendering device (run with a window)")
	var defs := {}
	var all := GpuKernels.all()
	for kname: String in all:
		if kname.begins_with("pool_") or kname == "ev_deposits":
			defs[kname] = all[kname]
	var shaders := ShaderSet.from_source(defs) if (from_source or limits.from_source) else ShaderSet.imported(defs)
	_made = shaders.create(rd)
	errors.append_array(shaders.errors)
	for kname: String in defs:
		if not _made.has(kname) and not errors.any(func(e: String) -> bool: return e.begins_with(kname)):
			errors.append("%s: not made" % kname)
	_consts = SimConstants.build()
	arena = SimArena.new(rd, limits)
	_world = arena.zeros(GpuLayout.WD_WORDS * 4)
	_dstate = arena.zeros(D_MAX * GpuLayout.DS_WORDS * 4)
	_fill_p()
	arena.make_all(_table_bytes())
	_put_world_capacities()
	_set_next_id(1)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:  # (written out: the instance's own methods may be gone by now)
		for key: String in _sets:
			if (_sets[key] as RID).is_valid() and rd.uniform_set_is_valid(_sets[key]):
				rd.free_rid(_sets[key])
		for kind: String in _textures:
			for t: RID in _textures[kind]:
				rd.free_rid(t)
		if _scratch.is_valid():
			rd.free_rid(_scratch)
		for slot: Dictionary in _id_ring:
			rd.free_rid(slot["buffer"])
		if arena != null:
			arena.free_all()
		ShaderSet.free_all(rd, _made)
		if _own_device:
			rd.free()
		rd = null


## Frees every buffer, shader and texture, and the device if it is the core's own.
func release() -> void:
	if rd == null:
		return
	_free_sets()
	for kind: String in _textures:
		for t: RID in _textures[kind]:
			if t.is_valid():
				rd.free_rid(t)
	_textures.clear()
	for r: Dictionary in _retired_textures:
		for t: RID in r["rids"]:
			if t.is_valid():
				rd.free_rid(t)
	_retired_textures.clear()
	if _scratch.is_valid():
		rd.free_rid(_scratch)
		_scratch = RID()
	_free_id_ring()
	if arena != null:
		arena.free_all()
	ShaderSet.free_all(rd, _made)
	_made.clear()
	if _own_device:
		rd.free()
	rd = null


# ---- dishes --------------------------------------------------------------------------------------------------------------------------

## The id the next newborn of any dish gets: one counter for the whole world, from 1, never reused (`GpuLayout.WD_NEXT_ID_LO`).
func next_id() -> int:
	return _wd(GpuLayout.WD_NEXT_ID_LO) | (_wd(GpuLayout.WD_NEXT_ID_HI) << 32)


func _set_next_id(id: int) -> void:
	_set_wd(GpuLayout.WD_NEXT_ID_LO, id & 0xFFFFFFFF)
	_set_wd(GpuLayout.WD_NEXT_ID_HI, (id >> 32) & 0xFFFFFFFF)


## Adds a dish (its founders as its first segment, its field filled); returns its row, or -1 when there is no free row or it would pass
## the memory budget. `grid`: the dish's grid made already (DishGrid.make of the spec's size, resolution, patchiness and patch seed, which
## must then be set), so the caller can make it on another thread: the landscape of a big grid takes a while in script.
func add_dish(spec: DishSpec, grid: DishGrid = null) -> int:
	if spec.number > GpuLayout.EV_DISH_MASK:
		errors.append("dish number %d does not fit an event's %d bits" % [spec.number, GpuLayout.EV_DISH_BITS])
		return -1
	var row := _free_row()
	if row < 0:
		return -1
	var count := spec.founders.size() / RB
	var first := next_id()
	for i in count:  # (the founders take the world's next ids in their order; the caller's spec shows them)
		GpuLayout.set_id(spec.founders, i, first + i)
	var s := spec.copy()
	if s.seed == 0:
		s.seed = _derived_seed(s.number)
	if s.patch_seed == 0:
		s.patch_seed = hash([s.seed, 7]) & 0x7FFFFFFF
	if grid == null:
		grid = DishGrid.make(s.radius, s.resolution, s.patchiness, s.patch_seed)
	if not _make_room(row, s, grid, count):
		return -1
	_set_next_id(first + count)
	next_number = maxi(next_number, s.number + 1)
	var cd: CoreDish = _dishes[row]
	var conc := grid.filled(clampf(s.nutrient_density, 0.0, StartConditions.MAX_NUTRIENT_DENSITY) * Dish.CONCENTRATION_PER_DENSITY)
	var none := PackedFloat32Array()
	none.resize(grid.n * grid.n)
	_put_field(cd, conc, none, arena.zeros(grid.n * grid.n * 4), arena.zeros(grid.n * grid.n * 4))
	var ds := arena.zeros(GpuLayout.DS_WORDS * 4)
	ds.encode_u32(GpuLayout.DS_SEED * 4, cd.seed32)
	ds.encode_u32(GpuLayout.DS_STEP * 4, s.step)
	_put_segment(row, s.founders, ds)
	_stats_fresh = false
	version += 1
	return row


## Loads a dish that `gather` read (a thaw, a load): a new row (`at_row` when it is free, else the lowest free one), its segment at the
## end, its clouds and husks after the pool's, its run carrying on from its saved step. Returns the row, or -1.
func load_dish(blob: DishBlob, at_row := -1) -> int:
	var row := at_row if at_row >= 0 and at_row < D_MAX and not _dishes.has(at_row) else _free_row()
	if row < 0:
		return -1
	var s := DishSpec.from_dict(blob.spec)
	var grid := DishGrid.make(s.radius, s.resolution, s.patchiness, s.patch_seed)
	if not _make_room(row, s, grid, blob.count(), blob.clouds.size() / 8, blob.husks.size() / 8):
		return -1
	next_number = maxi(next_number, s.number + 1)
	var past := maxi(blob.dstate.decode_u32(GpuLayout.DS_WORLD_ID_LO * 4) | (blob.dstate.decode_u32(GpuLayout.DS_WORLD_ID_HI * 4) << 32), 1)
	for i in blob.count():  # (the counter goes past every id the dish held and every id the world had given when it was gathered)
		past = maxi(past, GpuLayout.id_of(blob.records, i) + 1)
	if past > next_id():
		_set_next_id(past)
	var cd: CoreDish = _dishes[row]
	_put_field(cd, blob.conc, blob.conc2, blob.dplo, blob.dphi)
	_put_segment(row, blob.records, blob.dstate)
	_append_slots("PUFF", GpuLayout.WD_CLOUD_SLOTS, blob.clouds, row)
	_append_slots("HUSK", GpuLayout.WD_HUSK_SLOTS, blob.husks, row)
	_stats_fresh = false
	version += 1
	_need_bytes = -1
	return row


## Takes a dish out of the world at once: its blocks become padding (the next step's compaction closes the gap), its clouds and husks
## empty slots, its field block and squares free, its queued edits dropped (its row may be another dish's before the next batch).
## Returns the ids of its live bups (for LineageStore.release_dish).
func remove_dish(row: int) -> PackedInt64Array:
	var ids := live_ids(row)
	var cd: CoreDish = _dishes.get(row)
	if cd == null:
		return ids
	_edits = _edits.filter(func(pair: Array) -> bool: return pair[0] != row)
	var start := _ds(row, GpuLayout.DS_START)
	var count := _ds(row, GpuLayout.DS_COUNT)
	var blocks := (count + BLK - 1) / BLK
	if blocks > 0:
		var none := PackedByteArray()
		none.resize(blocks * 4)
		none.fill(0xFF)
		rd.buffer_update(arena.buf(_cur("BLKDISH")), (start / BLK) * 4, none.size(), none)
	_run_list(func(cl: int) -> void: _disp(cl, "pool_row_clear", _groups(maxi(_wd(GpuLayout.WD_CLOUD_SLOTS), _wd(GpuLayout.WD_HUSK_SLOTS))), float(row)))
	var cells := PackedByteArray()
	cells.resize(cd.cells * 4)
	cells.fill(0xFF)
	rd.buffer_update(arena.buf("CELLDISH"), cd.base * 4, cells.size(), cells)
	arena.free_cells(cd.base, cd.cells)
	var squares := PackedByteArray()
	squares.resize(cd.bins * 4)
	squares.fill(0xFF)
	rd.buffer_update(arena.buf("BINDISH"), cd.bin_base * 4, squares.size(), squares)
	arena.free_bins(cd.bin_base, cd.bins)
	_dishes.erase(row)
	_event_rows.erase(row)
	var zero := arena.zeros(GpuLayout.DP_WORDS * 4)
	rd.buffer_update(arena.buf("DISHP"), row * GpuLayout.DP_WORDS * 4, zero.size(), zero)
	var dz := arena.zeros(GpuLayout.DS_WORDS * 4)
	_set_ds_row(row, dz)
	_set_wd(GpuLayout.WD_CELLS, arena.cell_top)
	_set_wd(GpuLayout.WD_BINS, arena.bin_top)
	_stats_fresh = false
	version += 1
	_need_bytes = -1
	_leave_owed = true
	return ids


## What a dish is now, as a DishBlob (a blocking read): see DishBlob. The queued edits are made first, so a drop just before a freeze
## stays with the dish. Its clouds and husks are its live slots only, in pool order, not the dead slots too: every
## kernel passes a dead slot by, a dish's counters are virtual (DS_CLOUD_SLOTS and DS_HUSKS, recounted from the live slots at its own
## cadence) and the cloud lists keep the live clouds' order, so a dead slot carries nothing the dish's run reads (tests/sim/continuation_test.gd checks it bit for bit).
func gather(row: int) -> DishBlob:
	_apply_edits()
	var cd: CoreDish = _dishes[row]
	var blob := DishBlob.new()
	blob.spec = cd.spec.to_dict()
	blob.dstate = _dstate.slice(row * GpuLayout.DS_WORDS * 4, (row + 1) * GpuLayout.DS_WORDS * 4)
	blob.dstate.encode_u32(GpuLayout.DS_WORLD_ID_LO * 4, next_id() & 0xFFFFFFFF)
	blob.dstate.encode_u32(GpuLayout.DS_WORLD_ID_HI * 4, (next_id() >> 32) & 0xFFFFFFFF)
	var got := read_parts(_field_parts(cd) + [_records_part(row)])
	blob.conc = (got[0] as PackedByteArray).to_float32_array()
	blob.conc2 = (got[1] as PackedByteArray).to_float32_array()
	blob.dplo = got[2]
	blob.dphi = got[3]
	blob.records = got[4]
	var slots := _slots_of(row)
	blob.clouds = slots[0]
	blob.husks = slots[1]
	return blob


## `gather`, then `remove_dish`.
func freeze(row: int) -> DishBlob:
	var blob := gather(row)
	remove_dish(row)
	return blob


func thaw(blob: DishBlob) -> int:
	return load_dish(blob)


## The pipette's retarget: the bups of dish `row` within `radius` of `centre` (dish-local) move, with their ids and every
## word but their place (shifted by -centre), to `dest`: a row, a DishSpec for a new dish, or null for a new dish like the source (its
## size, grid, limit and settings, fresh medium, `next_number`). A pass of its own: no step, no draw, no event; the stats after it
## count the moved bups in the destination. Returns {new_row, moved, ids} ({} when the destination could not be made or the room for
## the move would pass the memory budget: then nothing moved, a destination made for it is gone again, and `errors` says so; nothing
## ran, so OVERFLOW_BUDGET is not set). `grid`: a new destination's grid made already (see `add_dish`).
func pipette(row: int, centre: Vector2, radius: float, dest: Variant = null, grid: DishGrid = null) -> Dictionary:
	var dst := -1
	var made := false
	if dest is int:
		dst = dest
		if not _dishes.has(dst):
			return {}
	else:
		if not _dishes.has(row):
			return {}
		var spec: DishSpec = dest if dest is DishSpec else receiver_spec(row)
		spec.founders = PackedByteArray()
		dst = add_dish(spec, grid)
		made = dst >= 0
	if dst < 0 or dst == row or not _dishes.has(row):
		if made:
			remove_dish(dst)
		return {}
	_apply_edits()
	var need := _wd(GpuLayout.WD_SLOTS) + _align(_ds(row, GpuLayout.DS_COUNT)) + BLK
	if not arena.ensure_slots(need):
		_after_growth()
		if made:
			remove_dish(dst)
		errors.append("SimCore: a pipette of %d bups needs %d record slots, past the memory budget: refused" % [_ds(row, GpuLayout.DS_COUNT), need])
		push_warning(errors[-1])
		return {}
	_after_growth()
	var before := _ds(dst, GpuLayout.DS_COUNT)
	var pd := float(row + dst * D_MAX)
	var bg := _bup_groups()
	_run_list(func(cl: int) -> void: _record_pipette(cl, bg, centre, radius, pd))
	_read_back()
	_event_rows.clear()
	_mark_stats_fresh()
	version += 1
	var moved := _ds(dst, GpuLayout.DS_MOVED_IN)
	return {"new_row": dst, "moved": moved, "ids": _ids_from(_ds(dst, GpuLayout.DS_START) + before, moved)}


## The pipette's retarget pass as one list's dispatches.
func _record_pipette(cl: int, bg: int, centre: Vector2, radius: float, pd: float) -> void:
	_disp(cl, "pool_ev_begin", D_MAX / 64)
	_disp(cl, "pool_pip_mark", bg, centre.x, centre.y, radius, pd)
	_scan(cl, "pool_scan_s", _wd(GpuLayout.WD_SLOTS))
	_disp(cl, "pool_pip_final", 1, centre.x, centre.y, radius, pd)
	_disp(cl, "pool_slot_check", 1)
	_disp(cl, "pool_pip_scatter", bg, centre.x, centre.y, radius, pd)
	_disp(cl, "pool_blk_fill", maxi(1, bg / 64))
	_disp(cl, "pool_setcount", D_MAX / 64, 0.0)
	_flipped = not _flipped
	_record_stats(cl, 0, 0)


## Runs the pipette's pass (twice, so each half of the records has been bound) on a world with no dish, so its first real use builds no
## pipeline, uniform set or buffer binding (a first dispatch of a kernel costs far more than the rest). Only for a core with no dish: with
## none there is no bup to mark and no row to change, and the pair of flips leaves the halves as they were.
func warm_up_pipette() -> void:
	if not _dishes.is_empty():
		return
	for half in 2:
		_run_list(func(cl: int) -> void: _record_pipette(cl, _bup_groups(), Vector2.ZERO, 0.0, 0.0))


## Pipette room made ahead (called between iterations, never inside a pipette). A pipette needs the world's slots plus a whole copy of
## the dish it takes from, which is up to twice what the dish needs to run, and growing the pool inside it cost ~40 ms of a ~55 ms pass
## [measured, M1 Pro]. Rule: once the world's slots are at PRE_GROW_USE (0.7) of the capacity, the capacity is grown (the
## same `ensure_slots` path and its sizes) for the largest dish's pipette, but only when that fits the budget and leaves the buffers at
## no more than PoolLimits.WARN_FRACTION of it (so it neither reaches the warning nor takes room later growths may need); otherwise
## nothing is done and nothing is said: the pipette then grows it itself, or is refused. A growth the running of the dishes
## needs anyway (`_ensure_room`) is not changed: this only grows the same class earlier, so a refusal of the running cannot come from it
## sooner than by the room it holds, which the share keeps under the warning. Returns whether it grew.
func prepare_pipette_room() -> bool:
	var used := _wd(GpuLayout.WD_SLOTS)
	if used < PRE_GROW_USE * arena.slot_cap:
		return false
	var biggest := 0
	for row: int in _dishes:
		biggest = maxi(biggest, _align(_ds(row, GpuLayout.DS_COUNT)))
	if not arena.pre_grow_slots(used + biggest + BLK, PoolLimits.WARN_FRACTION):
		return false
	_after_growth()
	return true


## Changes a running dish's settings from its next step: `params` may hold feed_density (units to each mm² an hour), upkeep,
## limit and flags (DP_FLAGS bits the dish asks for, as DishSpec.flags; the core keeps its own). Its spec takes them (so `gather` keeps
## them) and its DISHP row is written again. The cap (the slots it may fill) follows the limit but never drops below the bups it has now:
## a limit under the count is reached by the trim, step by step, as in a dish struck with it; no bup is cut. Returns the keys it did not
## change (bloom_density and anything else that is not the core's).
func set_params(row: int, params: Dictionary) -> Array:
	if not _dishes.has(row):
		return params.keys()
	var cd: CoreDish = _dishes[row]
	var rest: Array = []
	for key: String in params:
		match key:
			"feed_density":
				cd.spec.feed_density = clampf(float(params[key]), 0.0, StartConditions.MAX_FEED_DENSITY)
			"upkeep":
				cd.spec.upkeep = float(params[key])
			"limit":
				cd.spec.limit = maxi(int(params[key]), 1)
			"flags":
				cd.spec.flags = int(params[key])
			_:
				rest.append(key)
	cd.cap = maxi(cap_for(cd.spec.limit), _align(count(row)))
	cd.flags = cd.spec.flags | (1 << GpuLayout.DPF_RUNNING) | (1 << GpuLayout.DPF_ACETATE)
	_put_dishp(row)
	return rest


## The slots dish `row` may fill (DP_CAP).
func cap_of(row: int) -> int:
	return (_dishes[row] as CoreDish).cap if _dishes.has(row) else 0


## A new dish's cap for a limit: the limit and 5%, and a block's worth more, in whole blocks.
static func cap_for(limit: int) -> int:
	return ((int(limit * 1.05) + 1024 + 255) / 256) * 256


## Changes dish `row`'s size about its centre (Dish.resize_to), and with `resolution` > 0
## its grid's most cells across: the dish is read whole, changed and loaded again under the same row (its segment, clouds and husks go to
## the pool's end, which changes no dish's run). The field is resampled onto the new grid (bilinear, in
## doubles, the deposits waiting folded in first; larger: scaled so no nutrient is lost; smaller: what is past the edge goes). Smaller:
## bups whose centre is past the new edge are gone, as deaths (their death events are returned for the family tree; they give nothing
## back, as any bup an edit removes), one straddling the edge is moved inside, and the clouds and husks past it go. The diffusion's k and
## passes follow the new grid. Returns {row, removed, deaths (death event bytes, GpuLayout.ED_*)}, or {} when the dish could not be loaded
## again within the budget (then it is back as it was, and `errors` says why).
func resize(row: int, new_radius: float, resolution := -1) -> Dictionary:
	_moved_since_pic = true  # (bups past the new edge are moved inside it)
	if not _dishes.has(row):
		return {}
	var cd: CoreDish = _dishes[row]
	var res := resolution if resolution > 0 else cd.spec.resolution
	if is_equal_approx(new_radius, cd.spec.radius) and res == cd.spec.resolution:
		return {"row": row, "removed": 0, "deaths": PackedByteArray()}
	var blob := gather(row)
	var made := _resized(blob, cd.grid, new_radius, res)
	remove_dish(row)
	if load_dish(made["blob"], row) != row:
		load_dish(blob, row)
		errors.append("SimCore: a resize of dish %d to %.0f um was refused (the memory budget)" % [cd.spec.number, new_radius])
		push_warning(errors[-1])
		return {}
	return {"row": row, "removed": made["removed"], "deaths": made["deaths"]}


## `blob` with its dish `new_radius` µm across its middle and `res` cells across at most (see `resize`): {blob, removed, deaths}.
func _resized(blob: DishBlob, old: DishGrid, new_radius: float, res: int) -> Dictionary:
	var spec := DishSpec.from_dict(blob.spec)
	spec.radius = new_radius
	spec.resolution = res
	var grid := DishGrid.make(new_radius, res, spec.patchiness, spec.patch_seed)
	var out := DishBlob.new()
	out.spec = spec.to_dict()
	out.world = blob.world
	out.host = blob.host
	var settled := blob.conc.duplicate()
	var cell_area := old.spacing * old.spacing
	for c in settled.size():
		var lo := blob.dplo.decode_u32(c * 4)
		var hi := blob.dphi.decode_u32(c * 4)
		if lo != 0 or hi != 0:
			settled[c] = settled[c] + (float(hi) * 4096.0 + float(lo) * 9.5367431640625e-7) / cell_area
	var shrinking := new_radius < old.radius
	out.conc = _resample(settled, old, grid, shrinking)
	out.conc2 = _resample(blob.conc2, old, grid, shrinking)
	out.dplo = arena.zeros(grid.n * grid.n * 4)
	out.dphi = arena.zeros(grid.n * grid.n * 4)
	var deaths := PackedByteArray()
	var removed := 0
	out.records = blob.records
	if shrinking:
		var kept := PackedByteArray()
		var mass_um := float(_consts["mass_um"])
		for i in blob.count():
			var rec := blob.records.slice(i * RB, (i + 1) * RB)
			var x := float(rec.decode_float(GpuLayout.R_X * 4))
			var y := float(rec.decode_float(GpuLayout.R_Y * 4))
			var dist := sqrt(x * x + y * y)
			if dist > new_radius:
				deaths.append_array(death_event(rec, spec.number))
				removed += 1
				continue
			_keep_inside(rec, new_radius - 0.5 * rec.decode_float(GpuLayout.R_MASS * 4) * mass_um, dist)
			kept.append_array(rec)
		out.records = kept
	out.clouds = blob.clouds
	out.husks = blob.husks
	var ds := blob.dstate.duplicate()
	if shrinking:
		var r2 := new_radius * new_radius
		out.clouds = _within(blob.clouds, func(x: float, y: float) -> bool: return x * x + y * y <= r2)
		out.husks = _within(blob.husks, func(x: float, y: float) -> bool: return sqrt(x * x + y * y) <= new_radius)
		for pair in [[GpuLayout.DS_CLOUD_SLOTS, (blob.clouds.size() - out.clouds.size()) / 8], [GpuLayout.DS_HUSKS, (blob.husks.size() - out.husks.size()) / 8]]:
			ds.encode_u32(pair[0] * 4, maxi(0, ds.decode_u32(pair[0] * 4) - pair[1]))
	out.dstate = ds
	return {"blob": out, "removed": removed, "deaths": deaths}


## A field of the old grid on the new one: each inside cell of the new grid whose centre lies over the old grid
## takes the old values there, bilinear, in doubles; the rest are 0. Larger: scaled so the total is what it was.
static func _resample(values: PackedFloat32Array, old: DishGrid, grid: DishGrid, shrinking: bool) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(grid.n * grid.n)
	var old_total := 0.0
	for v in values:
		old_total += v
	old_total *= old.spacing * old.spacing
	if old_total <= 0.0 or values.is_empty():
		return out
	var on := old.n
	for y in grid.n:
		for x in grid.n:
			var i := y * grid.n + x
			if grid.inside[i] == 0:
				continue
			var cx := (x + 0.5) * grid.spacing - grid.radius
			var cy := (y + 0.5) * grid.spacing - grid.radius
			var fx := (cx + old.radius) / old.spacing - 0.5
			var fy := (cy + old.radius) / old.spacing - 0.5
			if fx < -0.5 or fy < -0.5 or fx > on - 0.5 or fy > on - 0.5:
				continue
			fx = clampf(fx, 0.0, on - 1.001)
			fy = clampf(fy, 0.0, on - 1.001)
			var x0 := int(fx)
			var y0 := int(fy)
			var tx := fx - x0
			var ty := fy - y0
			var j := y0 * on + x0
			var top := values[j] + (values[j + 1] - values[j]) * tx
			var bottom := values[j + on] + (values[j + on + 1] - values[j + on]) * tx
			out[i] = top + (bottom - top) * ty
	if not shrinking:
		var new_total := 0.0
		for v in out:
			new_total += v
		new_total *= grid.spacing * grid.spacing
		if new_total > 0.0:
			var scale := PackedFloat32Array([old_total / new_total])[0]
			for i in out.size():
				out[i] = out[i] * scale
	return out


## A bup straddling the edge moved inside: to `limit` from the middle along its own line, facing along the wall.
## Where it faced straight at the wall, it turns the way its id's lowest bit says (drawn from the dish's stream).
static func _keep_inside(rec: PackedByteArray, limit: float, dist: float) -> void:
	if dist <= limit:
		return
	var x := float(rec.decode_float(GpuLayout.R_X * 4))
	var y := float(rec.decode_float(GpuLayout.R_Y * 4))
	var nx := x / dist
	var ny := y / dist
	rec.encode_float(GpuLayout.R_X * 4, nx * limit)
	rec.encode_float(GpuLayout.R_Y * 4, ny * limit)
	var dx := float(rec.decode_float(GpuLayout.R_DX * 4))
	var dy := float(rec.decode_float(GpuLayout.R_DY * 4))
	var dot := dx * nx + dy * ny
	var ax := dx - nx * dot
	var ay := dy - ny * dot
	var al := sqrt(ax * ax + ay * ay)
	if al < 0.1:
		var sgn := 1.0 if (rec.decode_u32(GpuLayout.R_ID_LO * 4) & 1) == 0 else -1.0
		ax = -ny * sgn
		ay = nx * sgn
		al = 1.0
	rec.encode_float(GpuLayout.R_DX * 4, ax / al)
	rec.encode_float(GpuLayout.R_DY * 4, ay / al)


## The slots (8 floats each) whose place `keep` says yes to.
static func _within(slots: PackedFloat32Array, keep: Callable) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for k in slots.size() / 8:
		if keep.call(float(slots[k * 8]), float(slots[k * 8 + 1])):
			out.append_array(slots.slice(k * 8, k * 8 + 8))
	return out


## A death event (GpuLayout's ED_* words, step 0 of its batch) for a bup an edit removed in dish number `number`: it gives nothing back.
static func death_event(rec: PackedByteArray, number: int) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(GpuLayout.DEATH_WORDS * 4)
	var w := func(word: int) -> float: return rec.decode_float(word * 4)
	e.encode_u32(GpuLayout.ED_ID_LO * 4, rec.decode_u32(GpuLayout.R_ID_LO * 4))
	e.encode_u32(GpuLayout.ED_ID_HI * 4, rec.decode_u32(GpuLayout.R_ID_HI * 4))
	e.encode_u32(GpuLayout.ED_STEP * 4, number << GpuLayout.EV_DISH_SHIFT)
	e.encode_u32(GpuLayout.ED_TRAITS * 4, _traits(int(w.call(GpuLayout.R_DIVISIONS)), w.call(GpuLayout.R_REACH), w.call(GpuLayout.R_DONOR)))
	for pair in [[GpuLayout.ED_MASS, GpuLayout.R_MASS], [GpuLayout.ED_X, GpuLayout.R_X], [GpuLayout.ED_Y, GpuLayout.R_Y], [GpuLayout.ED_ENERGY, GpuLayout.R_ENERGY],
			[GpuLayout.ED_BIRTH_MASS, GpuLayout.R_BIRTH_MASS]]:
		e.encode_u32(pair[0] * 4, rec.decode_u32(pair[1] * 4))
	for g in 4:
		e.encode_u32((GpuLayout.ED_SPEED + g) * 4, rec.decode_u32((GpuLayout.R_SPEED + g) * 4))
	return e


## Birth events (GpuLayout's EB_* words, step 0, no parent) for records the pool never saw born: a new dish's founders, which the family
## tree then holds as its roots, born in dish number `number`.
static func founder_births(recs: PackedByteArray, number: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(recs.size() / RB * GpuLayout.BIRTH_WORDS * 4)
	for i in recs.size() / RB:
		var o := i * RB
		var e := i * GpuLayout.BIRTH_WORDS * 4
		var w := func(word: int) -> float: return recs.decode_float(o + word * 4)
		out.encode_u32(e + GpuLayout.EB_ID_LO * 4, recs.decode_u32(o + GpuLayout.R_ID_LO * 4))
		out.encode_u32(e + GpuLayout.EB_ID_HI * 4, recs.decode_u32(o + GpuLayout.R_ID_HI * 4))
		out.encode_u32(e + GpuLayout.EB_STEP * 4, GpuLayout.event_step_word(0, number))
		out.encode_u32(e + GpuLayout.EB_DIVISIONS * 4, int(w.call(GpuLayout.R_DIVISIONS)))
		out.encode_u32(e + GpuLayout.EB_TRAITS * 4, _traits(int(w.call(GpuLayout.R_MUTATIONS)), w.call(GpuLayout.R_REACH), w.call(GpuLayout.R_DONOR)))
		for pair in [[GpuLayout.EB_SPEED, GpuLayout.R_SPEED], [GpuLayout.EB_SENSE, GpuLayout.R_SENSE], [GpuLayout.EB_METABOLISM, GpuLayout.R_METABOLISM],
				[GpuLayout.EB_SIZE, GpuLayout.R_SIZE], [GpuLayout.EB_HUE, GpuLayout.R_HUE], [GpuLayout.EB_SAT, GpuLayout.R_SAT], [GpuLayout.EB_VAL, GpuLayout.R_VAL],
				[GpuLayout.EB_HARM, GpuLayout.R_HARM], [GpuLayout.EB_MUTATOR, GpuLayout.R_MUTATOR]]:
			out.encode_u32(e + pair[0] * 4, recs.decode_u32(o + pair[1] * 4))
	return out


## An event's traits word (the `events` kernel's): `low` (mutations in a birth, divisions in a death) in the low 20 bits, the reach word
## above them, the F factor at bit 30.
static func _traits(low: int, reach: float, donor: float) -> int:
	return (low & GpuLayout.EV_LOW_MASK) | ((int(reach + 0.5) & GpuLayout.EV_REACH_MASK) << GpuLayout.EV_REACH_SHIFT) | ((1 << GpuLayout.EV_DONOR_SHIFT) if donor > 0.5 else 0)


## An edit of dish `row`'s field (WorldEdit.DROP, ERASE), made before the next batch. Returns false for an edit that is the dish's
## DishWorld's (the host applies those).
func queue_edit(row: int, e: WorldEdit) -> bool:
	if not e.is_field_edit() or not _dishes.has(row):
		return false
	_edits.append([row, e])
	return true


## Whether edits are queued: the next list makes them, so what the pictures show changes with it.
func edits_pending() -> bool:
	return not _edits.is_empty()


## Sets dish `row`'s glucose grid (n² values, the dish's own cells).
func set_field(row: int, values: PackedFloat32Array) -> void:
	var cd: CoreDish = _dishes[row]
	version += 1
	assert(values.size() == cd.grid.n * cd.grid.n, "SimCore.set_field: %d values for a grid of %d" % [values.size(), cd.grid.n * cd.grid.n])
	var b := values.to_byte_array()
	rd.buffer_update(arena.buf("CONC"), cd.base * 4, b.size(), b)


# ---- the iteration ------------------------------------------------------------------------------------------------------------------

## `steps` steps of `delta` seconds of every running dish, and what is asked of the state after them, in one submit and one wait (with the
## field's own submits and waits before it when a step's diffusion rounds are split, `_record_step`): the
## steps are recorded, then the stats, the answers to `plan.questions` (`answer`'s) and the pictures of `plan.view` (`publish`'s), in one
## compute list; one read back (`_request`) takes WORLD, DSTATE, STATS, the family events, the answers and what the pictures hand over;
## submit; sync. `plan` (IterationPlan) carries each dish's world events, the history samples, the questions and the view. Returns {steps,
## overflow, record_usec, gpu_usec, stats (STATS up to the highest running row), births and deaths (the steps' family events: EVB's and
## EVD's bytes in use), answers (`answer`'s), published (`publish`'s), answer_usec and publish_usec (the host's time on the answers and on
## the pictures, before the list and after the sync), read_usec (on the read back), refused (why the steps did not run, or "")}; steps 0 when the room the steps need would pass the memory budget
## (OVERFLOW_BUDGET is set, `errors` and `refused` say so, no step ran; the questions are answered and the pictures published all the same). With no
## steps and no plan, the queued edits are made and the stats refreshed, and nothing else. An overflow a kernel finds (WORLD's flag) is not
## undone: the iteration cannot be done again from what the host holds (the records and fields change in place on the device), so
## `overflow()` keeps it and the kernels keep every read and write inside the buffers.
func run(steps: int, delta: float, plan: Variant = null) -> Dictionary:
	_apply_edits()
	if steps <= 0 and plan == null:
		if not _stats_fresh:
			_refresh_stats()
		return {"steps": 0, "overflow": _overflow}
	steps = clampi(steps, 0, MAX_STEPS)
	var history := PackedByteArray()
	var refused := ""
	if steps > 0:
		if not _stats_fresh:
			_refresh_stats()  # (the births the iteration can have are bounded from the dishes' masses as they are now)
		_set_step(delta)
		_sync_tiles()
		var events: Dictionary = plan.events if plan != null and plan.get("events") != null else {}
		history = plan.history_flags if plan != null and plan.get("history_flags") != null else PackedByteArray()
		var ev := _world_events(steps, events)
		if _ensure_room(steps, ev):
			_upload_events(ev)
		else:
			refused = errors[-1] if not errors.is_empty() else "the room the steps need"
			steps = 0
	var t_ask := Time.get_ticks_usec()
	var questions: Array = plan.questions if plan != null and plan.get("questions") is Array else []
	var view: ViewRequest = plan.view if plan != null and plan.get("view") is ViewRequest else null
	var staged := _answers_stage(questions)
	var husk_row := view.row if view != null and view.want_husks and _dishes.has(view.row) else -1
	var husk_most := _husk_most(husk_row) if husk_row >= 0 else 0
	if husk_most > 0:
		arena.put_small("HVC", arena.zeros(16))
	var t_pub := Time.get_ticks_usec()
	var pictures: int = plan.pictures if plan != null and plan.get("pictures") is int else 1
	var pub := _publish_stage(view, _expected_count(view.row, steps) if view != null and _dishes.has(view.row) else 0, steps, pictures)
	if steps > 0:
		version += 1
		_moved_since_pic = true  # (set before the pictures are recorded: the last picture follows the steps)
	var shots: Array = pub.get("shots", [])
	var answer_usec := t_pub - t_ask
	var publish_usec := Time.get_ticks_usec() - t_pub
	var stats := steps > 0 or not _stats_fresh
	var t0 := Time.get_ticks_usec()
	_split_usec = 0
	_submit_usec_most = 0
	if stats or not (staged["sets"] as Array).is_empty() or not pub.is_empty() or husk_most > 0:
		var cl := rd.compute_list_begin()
		if steps > 0:
			_disp(cl, "pool_ev_begin", D_MAX / 64)
			var samples := 0
			var shot := 0
			for s in steps:
				cl = _record_step(cl, s)
				if s < history.size() and history[s] != 0 and samples < GpuLayout.STATS_ITER_SAMPLES:
					samples += 1
					_record_stats(cl, samples, s)
				if shot < shots.size() and int(shots[shot]["step"]) == s + 1:
					_record_shot(cl, pub, shots[shot])
					shot += 1
		if stats:
			_record_stats(cl, 0, maxi(steps - 1, 0))
		_answers_record(cl, staged)
		_publish_record(cl, pub)
		if husk_most > 0:  # (the dish's live husks after the steps, packed into HUSK2, the cull's scratch, which no later kernel of the list uses)
			_disp(cl, "pool_husk_view", _groups(maxi(_wd(GpuLayout.WD_HUSK_SLOTS), 64)), float(husk_row))
		rd.compute_list_end()
	var parts: Array = [["WORLD", "WORLD", 0, int(arena.sizes["WORLD"])], ["DSTATE", "DSTATE", 0, int(arena.sizes["DSTATE"])],
		["STATS", "STATS", 0, _top_row() * GpuLayout.STATS_DISH_WORDS * 4]]
	if steps > 0:
		parts.append(["EVB", "EVB", 0, _expected_events(_births_per_step, steps) * GpuLayout.BIRTH_WORDS * 4])
		parts.append(["EVD", "EVD", 0, _expected_events(_deaths_per_step, steps) * GpuLayout.DEATH_WORDS * 4])
	parts.append_array(_answers_parts(staged))
	if husk_most > 0:
		parts.append(["HVC", "HVC", 0, 4])
		parts.append(["HUSK2", "HUSK2", 0, husk_most * 32])
	var direct: Array = []
	_publish_parts(pub, parts, direct)
	var reads := _request(parts, direct)
	var t1 := Time.get_ticks_usec()
	rd.submit()
	rd.sync()
	var t2 := Time.get_ticks_usec()
	var got := _take(reads)
	_apply_read_back(got["WORLD"], got["DSTATE"])
	if stats:
		_mark_stats_fresh(got["STATS"])
	_submit_usec_most = maxi(_submit_usec_most, t2 - t1)
	var out := {"steps": steps, "record_usec": t1 - t0 - _split_usec, "gpu_usec": t2 - t1 + _split_usec, "submit_usec_most": _submit_usec_most, "stats": got["STATS"], "births": PackedByteArray(), "deaths": PackedByteArray()}
	var deaths := 0
	var births := 0
	if steps > 0:
		_event_rows.clear()
		for row: int in _dishes:
			_event_rows[row] = true
			deaths += _ds(row, GpuLayout.DS_DEATHS)
			births += _ds(row, GpuLayout.DS_BIRTHS)
		out["births"] = _events_read(got["EVB"], "EVB", mini(births, arena.event_cap) * GpuLayout.BIRTH_WORDS * 4)
		out["deaths"] = _events_read(got["EVD"], "EVD", mini(deaths, arena.event_cap) * GpuLayout.DEATH_WORDS * 4)
		_deaths_per_step = maxf(float(deaths) / steps, _deaths_per_step * 0.9)
		_births_per_step = maxf(float(births) / steps, _births_per_step * 0.9)
		_last_steps = steps
	var read_usec := Time.get_ticks_usec() - t2
	var t_took := Time.get_ticks_usec()
	out["answers"] = _answers_take(staged, got)
	var t_pub_took := Time.get_ticks_usec()
	out["published"] = _publish_take(pub, got)
	if husk_row >= 0:
		out["husk_list"] = _husk_list(husk_most, got.get("HVC", PackedByteArray()), got.get("HUSK2", PackedByteArray()))
	out["answer_usec"] = answer_usec + t_pub_took - t_took
	out["publish_usec"] = publish_usec + Time.get_ticks_usec() - t_pub_took
	out["read_usec"] = read_usec
	if _leave_owed:
		_give_back(steps > 0)
	if steps > 0:
		arena.maybe_shrink(_wd(GpuLayout.WD_SLOTS), _wd(GpuLayout.WD_CLOUD_SLOTS), _wd(GpuLayout.WD_HUSK_SLOTS), _entries_peak, maxi(births, deaths))
		_entries_peak = 0
		if arena.changed:
			_after_growth()
	out["overflow"] = _overflow
	out["refused"] = refused
	return out


## The family events read back with an iteration (`head`: the first bytes of `buffer`, as many as were expected) made up to `bytes`, the
## rest read now when the steps had more than expected.
func _events_read(head: PackedByteArray, buffer: String, bytes: int) -> PackedByteArray:
	if head.size() >= bytes:
		return head.slice(0, bytes)
	var out := head.duplicate()
	out.append_array(read_parts([[buffer, head.size(), bytes - head.size()]])[0])
	return out


## The family events of one kind an iteration of `steps` steps is expected to have, read back with it (the most a step of the last
## iterations had, `per_step`, with EVENT_READ_MARGIN of room and EVENT_READ_SLACK more), never past the ring.
func _expected_events(per_step: float, steps: int) -> int:
	return mini(arena.event_cap, ceili(EVENT_READ_MARGIN * per_step * steps) + EVENT_READ_SLACK)


## How many bups dish `row` is expected to hold after `steps` more steps, before they run (the pictures' buffers are made for it, and on the
## byte path that much of the payload is read back with the iteration): its count now, its births a step in the last iteration that
## stepped with COUNT_READ_MARGIN of room, a sixteenth of its count and a row of texels, never past its cap. A dish that outgrows the
## buffers is not drawn that time (`_publish_take`); one that outgrows the read has the rest read after.
func _expected_count(row: int, steps: int) -> int:
	var n := count(row)
	if steps <= 0:
		return n
	var per_step := float(_ds(row, GpuLayout.DS_BIRTHS)) / maxi(_last_steps, 1)
	return mini((_dishes[row] as CoreDish).cap, n + ceili(COUNT_READ_MARGIN * per_step * steps) + n / 16 + GpuLayout.PAYLOAD_TEX_WIDTH)


## The highest running dish row + 1 (0 with none).
func _top_row() -> int:
	var top := 0
	for row: int in _dishes:
		top = maxi(top, row + 1)
	return top


## For timing (tools/gpu/gpu_lab.gd): `steps` steps as `run` records them, but each dispatch in a submit of its own, timed by the wall
## clock around its submit and sync. Returns kernel name -> Array of µs (one entry a dispatch) and "_noop" -> the same for a one-thread
## kernel (the round trip to take off). The results are the same as `run`'s; only the time differs.
func profile_steps(steps: int, delta: float, plan: Variant = null) -> Dictionary:
	_apply_edits()
	if not _stats_fresh:
		_refresh_stats()
	_set_step(delta)
	_sync_tiles()
	var events: Dictionary = plan.events if plan != null and plan.get("events") != null else {}
	var ev := _world_events(steps, events)
	if not _ensure_room(steps, ev):
		return {}
	_upload_events(ev)
	_profile = {}
	for k in 20:
		_disp(-1, "pool_slot_check", 1)
	_profile["_noop"] = _profile["pool_slot_check"]
	_profile.erase("pool_slot_check")
	_disp(-1, "pool_ev_begin", D_MAX / 64)
	for s in steps:
		var _cl := _record_step(-1, s)
	_record_stats(-1, 0, steps - 1)
	var out: Dictionary = _profile
	_profile = null
	_read_back()
	_event_rows.clear()
	for row: int in _dishes:
		_event_rows[row] = true
	_mark_stats_fresh()
	return out


## Builds TILES for pool_fdiff: a word a tile of every dish (its row in the upper 16 bits, the tile's number in the lower), the dishes with the
## most rounds first, so the tiles that have a round r to run are a prefix; `_tile_rounds[r]` is that prefix's length. Uploaded only when a
## dish's row, size or iterations changed. Called after `_set_step`, before the compute list is begun.
func _sync_tiles() -> void:
	var rows := _dishes.keys()
	rows.sort()
	var key := PackedInt32Array()
	for row: int in rows:
		var cd: CoreDish = _dishes[row]
		key.append(row)
		key.append(cd.grid.n)
		key.append(cd.iterations)
	if key == _tile_key and not _tile_rounds.is_empty():
		return
	_tile_key = key
	rows.sort_custom(func(a: int, b: int) -> bool:
		var ra := GpuKernelsField.field_rounds((_dishes[a] as CoreDish).iterations)
		var rb := GpuKernelsField.field_rounds((_dishes[b] as CoreDish).iterations)
		return ra > rb or (ra == rb and a < b))
	var words := PackedInt32Array()
	_tile_rounds = PackedInt32Array()
	var counts := []
	for row: int in rows:
		var cd: CoreDish = _dishes[row]
		var across := GpuKernelsField.tiles_across(cd.grid.n)
		for t in across * across:
			words.append((row << 16) | t)
		counts.append([GpuKernelsField.field_rounds(cd.iterations), across * across])
	var most_rounds := 0
	for c in counts:
		most_rounds = maxi(most_rounds, c[0])
	_tile_rounds.resize(most_rounds)
	for r in most_rounds:
		var n := 0
		for c in counts:
			if c[0] > r:
				n += c[1]
		_tile_rounds[r] = n
	if words.is_empty():
		return
	var bytes := words.to_byte_array()
	rd.buffer_update(arena.buf("TILES"), 0, bytes.size(), bytes)


## The step `s` of a batch, in the order of kernels_life.gd's header, recorded into list `cl` (-1: each dispatch its own submit, for
## `profile_steps`). Returns the list the rest of the batch goes into: the field's diffusion rounds are split into submits of at most
## FIELD_SUBMIT_MS each by the time a round's tile was measured to take (many dishes of many rounds, small ones in water, make a step
## of a hundred ms or more of them, 999 dishes of 300 µm about 140 ms, which in one submit leaves the interface's frames late), and each
## split ends the list, submits, waits and begins a new one.
func _record_step(cl: int, s: int) -> int:
	_lists_marked = _marks_pay()
	var bg := _bup_groups()
	var cg := _groups(arena.cell_top)
	var hg := _groups(maxi(_wd(GpuLayout.WD_CLOUD_SLOTS), 64))
	var kg := _groups(maxi(_wd(GpuLayout.WD_HUSK_SLOTS), 64))
	var slots := maxi(_wd(GpuLayout.WD_SLOTS), BLK)
	_disp(cl, "pool_ev_puffs", 1, float(s))
	_disp(cl, "ev_deposits", 1, float(s))
	if lone_field:
		_disp(cl, "pool_feed", cg)
		var most := 0
		for row: int in _dishes:
			most = maxi(most, (_dishes[row] as CoreDish).iterations)
		for pass_i in most:
			var bound := 0
			for row: int in _dishes:
				var cd: CoreDish = _dishes[row]
				if cd.iterations > pass_i:
					bound = maxi(bound, cd.base + cd.cells)
			var ab := "a" if pass_i % 2 == 0 else "b"
			_disp(cl, "pool_diffuse_" + ab, _groups(bound), float(pass_i), float(bound))
			_disp(cl, "pool_diffuse2_" + ab, _groups(bound), float(pass_i), float(bound))
		_disp(cl, "pool_land_copy", cg)
	else:
		var tiles := 0  ## the tiles recorded since the last submit, and whether all of them are diffusion rounds (the first submit holds the step's kernels before them)
		var rounds_only := false
		for r in _tile_rounds.size():
			if cl >= 0 and tiles > 0 and (_round_tile_ms <= 0.0 or (tiles + _tile_rounds[r]) * _round_tile_ms > FIELD_SUBMIT_MS):
				var t0 := Time.get_ticks_usec()
				rd.compute_list_end()
				rd.submit()
				rd.sync()
				var waited := Time.get_ticks_usec() - t0
				_split_usec += waited
				_submit_usec_most = maxi(_submit_usec_most, waited)
				if rounds_only:
					var per := waited / 1000.0 / tiles
					_round_tile_ms = per if _round_tile_ms <= 0.0 else lerpf(_round_tile_ms, per, 0.25)
				cl = rd.compute_list_begin()
				tiles = 0
				rounds_only = true
			_disp(cl, "pool_fdiff", _tile_rounds[r], float(r), float(_tile_rounds[r]))
			tiles += _tile_rounds[r]
	_disp(cl, "pool_puff_advance", hg)
	_disp(cl, "pool_dep_land", cg)
	_disp(cl, "pool_snapshot", cg)
	_record_lists(cl, hg)
	if lone_field:
		_disp(cl, "pool_clear", cg)
	_disp(cl, "pool_puff_clear", hg)
	var reads := "" if _lists_marked else "_all"
	for kname: String in (["pool_swim", "pool_demand"] if lone_passes else ["pool_swim_demand"]):
		_disp(cl, kname + reads, bg)
	if _lists_marked:
		_disp(cl, "pool_bin_misses", bg)
	_disp(cl, "pool_cells", cg)
	_disp(cl, "pool_puff_scale", hg)
	var buckets := GpuKernelsLife.conj_buckets(slots)
	_disp(cl, "pool_conj_clear", maxi(bg, _groups(buckets)))
	for kname: String in (["pool_apply", "pool_conj_count"] if lone_passes else ["pool_apply_count"]):
		_disp(cl, kname if kname == "pool_conj_count" else kname + reads, bg)
	_disp(cl, "pool_puff_commit", hg)
	_disp(cl, "pool_ac_cells", cg)
	_scan(cl, "pool_conj_scan", buckets)
	_disp(cl, "pool_conj_scatter", bg)
	if lone_passes:
		for kname: String in lone_order:
			_disp(cl, kname, bg)
	else:
		_disp(cl, "pool_ac_conj_life", bg)
		_disp(cl, "pool_donor_life", maxi(1, bg / 16))
	_scan(cl, "pool_scan_s", slots)
	_scan(cl, "pool_scan_k", slots)
	_disp(cl, "pool_finalize", 1)
	_disp(cl, "pool_slot_check", 1)
	_disp(cl, "pool_death_bases", 1)
	_disp(cl, "pool_husk_spawn", bg)
	_disp(cl, "pool_death_clouds", bg)
	_disp(cl, "pool_death_count", D_MAX / 64)
	_disp(cl, "pool_husk_age", kg)
	_scan(cl, "pool_hl", maxi(_wd(GpuLayout.WD_HUSK_SLOTS), 64))
	_disp(cl, "pool_husk_leak", kg)
	_disp(cl, "pool_husk_leak_count", 1)
	_disp(cl, "pool_cloud_live", hg)
	_disp(cl, "pool_husk_live", kg)
	_disp(cl, "pool_cloud_cadence", D_MAX / 64)
	_disp(cl, "pool_events", bg, float(s), 0.0)
	_disp(cl, "pool_blk_fill", maxi(1, bg / 64))
	_disp(cl, "pool_compact", bg)
	_disp(cl, "pool_setcount", D_MAX / 64, 1.0)
	_flipped = not _flipped
	if _world_step % CLOUD_COMPACT_EVERY == CLOUD_COMPACT_EVERY - 1:
		var hint := maxi(_wd(GpuLayout.WD_CLOUD_SLOTS), 64)
		_disp(cl, "pool_pmark", hg)
		_scan(cl, "pool_pf", hint)
		_disp(cl, "pool_pcompact", _groups(hint * 2))
		_disp(cl, "pool_pcopy", _groups(hint * 2))
		_disp(cl, "pool_psetcount", 1)
	if _world_step % HUSK_CULL_EVERY == HUSK_CULL_EVERY - 1:
		var hint := maxi(_wd(GpuLayout.WD_HUSK_SLOTS), 64)
		_disp(cl, "pool_husk_mark", kg)
		_scan(cl, "pool_hc", hint)
		_disp(cl, "pool_husk_compact", kg)
		_disp(cl, "pool_husk_copy", _groups(hint * 8))
		_disp(cl, "pool_husk_set_count", 1)
	_world_step += 1
	return cl


## The clouds' lookup lists made afresh from the clouds as they are (every step makes them before anything reads them; the words a cloud
## keeps for them, its reach and sigma, are worked out from its mass and spread alone), for the squares near a bup only when the marks pay
## (`_marks_pay`): the squares are marked (each bup's own, widened by `_list_margin_um()` or by `list_margin_override`), and the count and the
## scatter skip the rest; otherwise every square is listed.
func _record_lists(cl: int, hg: int) -> void:
	var bins := maxi(arena.bin_top, 1)
	_disp(cl, "pool_bin_clear", _groups(bins), 0.0 if _lists_marked else 1.0)
	if _lists_marked:
		_disp(cl, "pool_bin_mark", _bup_groups())
		var reach := _list_margin_um()
		_disp(cl, "pool_bin_wide_x", _groups(bins), reach, list_margin_override)
		_disp(cl, "pool_bin_wide_y", _groups(bins), reach, list_margin_override)
	_disp(cl, "pool_bin_count", hg)
	_scan(cl, "pool_bn", bins)
	_disp(cl, "pool_bin_cut", D_MAX / 64)
	_scan(cl, "pool_bn", bins)
	_disp(cl, "pool_bin_room", D_MAX / 64)
	_disp(cl, "pool_bin_cursor", _groups(bins))
	_disp(cl, "pool_bin_scatter", hg)
	_disp(cl, "pool_bin_sort", _groups(bins))


## Whether the lists of the coming step list only the squares near a bup. The marking passes cost a pass over every square and the
## reads that can meet an unlisted square carry the code for it, which a dense dish (many bups to a cloud) or a dish of many squares
## and few clouds pays for and does not get back: when the marks do not pay, every square is listed, with no marking
## passes, and the reads are the ones without that code. Either way a read sums what the list would; only the work differs. Judged from
## the counts of the last read-back, so a step after a change may use the other mode: no result depends on it.
func _marks_pay() -> bool:
	if list_margin_override >= 0.0:
		return true
	if list_margin_override < -1.5:
		return false
	var clouds := _wd(GpuLayout.WD_CLOUD_SLOTS)
	return _wd(GpuLayout.WD_SLOTS) < MARKS_BUPS_PER_CLOUD * clouds and arena.bin_top <= MARKS_SQUARES_PER_CLOUD * clouds


## How far a bup is taken to be able to get from where it was at the start of a step, in µm: `0.25 v delta + 4 v sqrt(3 delta)`, v the
## fastest speed any gene can reach (the speed gene's bound with every raise): the squares that far round each bup are listed. A read
## past it takes its clouds from the cloud slots, so this sets the cost of the lists, not what a bup reads.
func _list_margin_um() -> float:
	var vmax := float((_consts["gene_max"] as Array)[0]) * float(_consts["reach_factor_3"])
	var delta := maxf(_delta, 0.0)
	return 0.25 * vmax * delta + 4.0 * vmax * sqrt(3.0 * delta)


## The per-dish stats over the layout now into sample `sample` of each running dish's STATS row, taken after step `step` of the batch.
func _record_stats(cl: int, sample: int, step: int) -> void:
	_disp(cl, "pool_stats1", maxi(1, _bup_groups() / 4))
	_disp(cl, "pool_stats2", 64, 0.0, float(sample), float(step))


func _refresh_stats() -> void:
	_run_list(func(cl: int) -> void: _record_stats(cl, 0, 0))
	_mark_stats_fresh()


## STATS sample 0 holds every running dish's state now: its mass sums are taken, for `births_series`, from `stats` (STATS up to the
## highest running row, as an iteration reads it back), or read now when it is not given.
func _mark_stats_fresh(stats := PackedByteArray()) -> void:
	_stats_fresh = true
	_mass_sum.clear()
	if _dishes.is_empty():
		return
	var top := _top_row()
	var bulk := stats if stats.size() >= top * GpuLayout.STATS_DISH_WORDS * 4 else PackedByteArray()
	if bulk.is_empty() and _dishes.size() > MASS_READ_ROWS:
		bulk = rd.buffer_get_data(arena.buf("STATS"), 0, top * GpuLayout.STATS_DISH_WORDS * 4)
	for row: int in _dishes:
		var at := (row * GpuLayout.STATS_DISH_WORDS + GpuLayout.ST_MASS) * 4
		if bulk.is_empty():
			_mass_sum[row] = rd.buffer_get_data(arena.buf("STATS"), at, 4).decode_float(0)
		else:
			_mass_sum[row] = bulk.decode_float(at)


# ---- the world's events ------------------------------------------------------------------------------------------------------------

## Each running dish's DishWorld rows (plan.events[row]: discs, puffs, deposits and husks, step n of the window 1-based, a pending row 0)
## as the batch's EVR, EVP, EVCC and EVCA: per step, the dishes in row order, each dish's plankton (discs or husks) then its sources'
## clouds; a disc, a cloud and a deposit become clouds or cells as the field's rules decide.
func _world_events(steps: int, events: Dictionary) -> Dictionary:
	var per_step: Array = []
	per_step.resize(steps)
	var rows: Array = _dishes.keys()
	rows.sort()
	for row: int in rows:
		if not events.has(row):
			continue
		var cd: CoreDish = _dishes[row]
		var g := cd.grid
		var word := _row_word(row)
		var ev: Dictionary = events[row]
		var handover := float(_consts["cloud_handover"]) * g.spacing
		var buckets := {}
		var take := func(key: String, stride: int) -> void:
			var a: PackedFloat64Array = ev.get(key, PackedFloat64Array())
			for k in a.size() / stride:
				var st := clampi(int(a[k * stride]) - 1, 0, steps - 1)
				if not buckets.has(st):
					buckets[st] = {"puffs": PackedFloat32Array(), "cells": PackedInt32Array(), "amounts": PackedFloat32Array()}
				var b: Dictionary = buckets[st]
				var x := a[k * stride + 1]
				var y := a[k * stride + 2]
				match key:
					"discs":
						var r := a[k * stride + 4]
						var v := maxf(0.25 * r * r, DishGrid.MIN_CLOUD_VARIANCE)
						if not g.accepts(x, y) or sqrt(v) >= handover:
							g.deposit_disc(x, y, r, a[k * stride + 3], cd.base, b["cells"], b["amounts"])
						else:
							b["puffs"].append_array(PackedFloat32Array([x, y, a[k * stride + 3], v, 1.0, word]))
					"husks":
						b["puffs"].append_array(PackedFloat32Array([x, y, a[k * stride + 3], 0.0, -1.0, word]))
					"puffs":
						if g.accepts(x, y):
							b["puffs"].append_array(PackedFloat32Array([x, y, a[k * stride + 3], a[k * stride + 4], 0.001, word]))
						else:
							g.deposit_xy(x, y, a[k * stride + 3], cd.base, b["cells"], b["amounts"])
					"deposits":
						g.deposit_xy(x, y, a[k * stride + 3], cd.base, b["cells"], b["amounts"])
		take.call("discs", DishWorld.STRIDE_DISC)
		take.call("husks", DishWorld.STRIDE_HUSK)
		take.call("puffs", DishWorld.STRIDE_PUFF)
		take.call("deposits", DishWorld.STRIDE_DEPOSIT)
		for st: int in buckets:
			if per_step[st] == null:
				per_step[st] = []
			per_step[st].append(buckets[st])
	var ranges := PackedInt32Array()
	var puffs := PackedFloat32Array()
	var cells := PackedInt32Array()
	var amounts := PackedFloat32Array()
	for st in steps:
		var first := puffs.size() / GpuLayout.EV_PUFF_FLOATS
		var first_cell := cells.size()
		if per_step[st] != null:
			for b: Dictionary in per_step[st]:
				puffs.append_array(b["puffs"])
				cells.append_array(b["cells"])
				amounts.append_array(b["amounts"])
		ranges.append_array(PackedInt32Array([first, puffs.size() / GpuLayout.EV_PUFF_FLOATS - first, first_cell, cells.size() - first_cell]))
	assert(puffs.size() / GpuLayout.EV_PUFF_FLOATS <= GpuLayout.EV_PUFFS_CAPACITY and cells.size() <= GpuLayout.EV_CELLS_CAPACITY, "SimCore: an iteration's world events pass the event buffers")
	return {"ranges": ranges, "puffs": puffs, "cells": cells, "amounts": amounts}


func _upload_events(ev: Dictionary) -> void:
	for pair in [["EVR", ev["ranges"]], ["EVP", ev["puffs"]], ["EVCC", ev["cells"]], ["EVCA", ev["amounts"]]]:
		var bytes: PackedByteArray = pair[1].to_byte_array()
		if bytes.size() > 0:
			rd.buffer_update(arena.buf(pair[0]), 0, bytes.size(), bytes)


# ---- room ---------------------------------------------------------------------------------------------------------------------------

## The most a bup's mass can grow in one step of `delta` seconds, as a factor: it grows by GROWTH_RATE x metabolism x mass x delta, the
## metabolism gene at most its range's top with all three ceiling raises (Genome.REACH_FACTOR_3), less what the raises cost (REACH_COST each;
## a donor, the acetate key and a starving bup give up more, never less), and by no more than its reserve pays for. With the game's constants
## and a step of 20 s (the longest) it is 1 + (ln 2 / 2400 s) x (2.0 x 1.5) x 0.85 x 20 s = 1.0147.
static func growth_factor_max(delta: float) -> float:
	var metabolism_top: float = Genome.GENES["metabolism"][1] * Genome.REACH_FACTOR_3
	return 1.0 + Cell.GROWTH_RATE * metabolism_top * maxf(0.2, 1.0 - Genome.REACH_COST * 3.0) * maxf(delta, 0.0)


## The least mass a bup that divides has: it divides only when its mass is at least its birth mass plus ADD_MASS_FACTOR x its size gene
## squared, so at least that, with the size gene at the bottom of its range: 0.5 x 2.0^2 = 2.
static func division_mass_min() -> float:
	var size_least: float = Genome.GENES["size"][0]
	return Cell.ADD_MASS_FACTOR * size_least * size_least


## The most bups a dish of `count` bups holds at the start of each of `steps` steps and after the last (`steps` + 1 numbers, the first
## `count`), when the sum of their masses is `mass` (negative: not known) and the dish keeps at most `cap`. The bound is the bups' mass and
## nothing else, because a bup divides only above a mass and mass does not appear from nowhere:
##   - A division splits a mass in two (the parent keeps a share and the daughter has the rest, or is lost), and a bup's mass grows at most
##     by `growth_factor_max` a step, so the dish's total mass at the start of step j is at most mass x G^j (it falls with starvation and deaths).
##   - A bup divides at most once a step, and only with at least `division_mass_min` of mass, so the births of step j are at most the bups
##     there are, and at most that total mass over that least mass: min(N_j, mass x G^j / 2).
##   - So N_(j+1) <= N_j + min(N_j, mass x G^j / 2), and at most `cap`.
## The bound a bup's own doubling gives (N_(j+1) <= 2 N_j) is what holds without the mass; with it a dish whose bups weigh about 7 on
## average (3.5 times the least that divides) can at most double twice and then add 3.5 times its bups a step, so 14 steps from 5,000 bups
## are at most about 240,000, not 82 million. A bup that has just divided could divide again in the very next step at the longest step
## (it needs 1.4% more mass and the fastest growth gives 1.5%), so no bound from the time between divisions holds at the speeds where
## the step is longest; the mass bound does.
static func births_series(count: int, mass: float, cap: int, steps: int, delta: float) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(steps + 1)
	var n := mini(count, cap)
	out[0] = n
	var total := mass * (1.0 + MASS_SUM_MARGIN)
	var g := growth_factor_max(delta)
	var least := division_mass_min()
	for j in steps:
		var births := n
		if mass >= 0.0:
			births = mini(n, int(minf(total / least, 4.0e18)))
			total *= g
		n = mini(cap, n + births)
		out[j + 1] = n
	return out


## The step length (seconds) an iteration's room is worked out for: the one set, or the longest there is while none is.
func step_length() -> float:
	return _delta if _delta > 0.0 else Governor.MAX_STEP


## The mass sum of dish `row` at the start of an iteration, or -1.0 when it is not known (the dish is not in the last STATS sample).
func mass_of(row: int) -> float:
	return float(_mass_sum[row]) if _stats_fresh and _mass_sum.has(row) else -1.0


## The bytes the buffers and the pictures' textures would take at what the running dishes need: what they use and the room their next
## growth asks for (`room_needed` over the last iteration's steps), whatever the pool holds now. Worked out again when a dish came or went.
func need_bytes() -> int:
	if _need_bytes < 0:
		_need_bytes = arena.need_bytes(room_needed(maxi(_last_steps, 1), 0, true))
	return _need_bytes


## Gives back what a dish that left held, without the wait of the ordinary shrink (`SimArena.give_back`), after the iteration or pass that
## read its state back. The slots of the dish stay in the world's count until a step closes the gap, so a pass of no steps gives back
## the rest and the order stands until a step has run.
func _give_back(stepped: bool) -> void:
	var blocked := arena.give_back(room_needed(maxi(_last_steps, 1), 0, true), {"slots": _wd(GpuLayout.WD_SLOTS), "clouds": _wd(GpuLayout.WD_CLOUD_SLOTS), "husks": _wd(GpuLayout.WD_HUSK_SLOTS)})
	_leave_owed = blocked and not stepped
	if arena.changed:
		_after_growth()


## What the running dishes need of each class for an iteration of `steps` steps with `world_clouds` clouds brought by the world's events
## (`_ensure_room` grows to it): "slots" (their segments after the steps), "most" (the slots they can never pass), "events" (the ring, with
## "events_most" its growth bound and "events_asked" what a refusal names), "clouds", "husks", "entry_clouds" (the cloud slots the
## lists are sized for) and "entries_density". `stale_mass` takes a dish's mass from the last sample even when an edit or a dish leaving has
## made the sample not current (an estimate of the need, not the room an iteration is given).
func room_needed(steps: int, world_clouds: int, stale_mass: bool) -> Dictionary:
	var need := 0
	var most := 0
	var bound := 0
	var counted := 0
	var delta := step_length()
	for row: int in _dishes:
		var cd: CoreDish = _dishes[row]
		var n := _ds(row, GpuLayout.DS_COUNT)
		counted += n
		var mass := float(_mass_sum[row]) if stale_mass and _mass_sum.has(row) else mass_of(row)
		var series := births_series(n, mass, cd.cap, steps, delta)
		need += _align(series[steps])
		most += _align(maxi(cd.cap, n))
		for j in steps:
			bound += series[j]
	var exact := bound < EVENT_EXACT_MOST
	var events := bound if exact else mini(bound, maxi(EVENT_EXACT_MOST, int(4.0 * maxf(_births_per_step, _deaths_per_step) * steps)))
	var husks_most := _wd(GpuLayout.WD_HUSK_SLOTS) + bound + world_clouds
	var pieces_a_step := mini(GpuKernelsHusks.HUSK_PIECES, int(maxf(_delta, 0.0) / (Biology.HUSK_SECONDS / 4.0)) + 1)
	var clouds_most := _wd(GpuLayout.WD_CLOUD_SLOTS) + bound + world_clouds + husks_most * mini(GpuKernelsHusks.HUSK_PIECES, steps * pieces_a_step)
	var clouds := clouds_most
	var husks := husks_most
	if not exact or clouds_most > HARD_BOUND_MOST:
		var per_step := maxf(_deaths_per_step * 2.0, float(counted) / 50.0) + 1024.0
		var window := mini(steps, CLOUD_COMPACT_EVERY) + 1
		clouds = _wd(GpuLayout.WD_CLOUD_SLOTS) + int(per_step * window) + world_clouds + _wd(GpuLayout.WD_HUSK_SLOTS) * window
		husks = _wd(GpuLayout.WD_HUSK_SLOTS) + int(per_step * (mini(steps, HUSK_CULL_EVERY) + 1)) + world_clouds
	var entry_clouds := 0
	if _entry_density > 0:
		entry_clouds = mini(clouds, _wd(GpuLayout.WD_CLOUD_SLOTS) + int(maxf(_deaths_per_step * 2.0, float(counted) / 50.0) * (mini(steps, CLOUD_COMPACT_EVERY) + 1)) + world_clouds + _wd(GpuLayout.WD_HUSK_SLOTS) * (mini(steps, CLOUD_COMPACT_EVERY) + 1))
	return {"slots": need, "most": most, "events": maxi(events, EVENT_FLOOR), "events_most": maxi(bound, EVENT_FLOOR), "events_asked": events,
		"clouds": clouds, "husks": husks, "entry_clouds": entry_clouds, "entries_density": ceili(_entry_density * ENTRY_MARGIN)}


## Grows what an iteration of `steps` steps could pass: the record slots to the bound of every dish's segment after `steps` steps
## (`births_series`: a bup divides at most once a step and only with mass to divide, and never past its dish's cap); the event ring to the bound of
## its births; the clouds and husks, while that bound is small (under EVENT_EXACT_MOST, and the slots under HARD_BOUND_MOST), to a hard bound:
## each step's deaths are at most its bups (the same bound), each death and plankton husk makes at most a cloud or a husk, and each husk lets
## go at most min(12, steps x (delta / a quarter of its life + 1)) pieces; past it, to an estimate of what the steps until the next
## compaction append (a kernel that finds a buffer full raises the overflow flag and keeps inside it). The ring, when it is sized from
## what the last iterations had, still grows only to the bound. False, with OVERFLOW_BUDGET set and the reason in `errors`, when the room
## would pass the memory budget.
func _ensure_room(steps: int, ev: Dictionary) -> bool:
	var world_clouds: int = (ev["puffs"] as PackedFloat32Array).size() / GpuLayout.EV_PUFF_FLOATS
	var room := room_needed(steps, world_clouds, false)
	_need_bytes = arena.need_bytes(room)
	var refused: Array[String] = []
	if not arena.ensure_slots(maxi(room["slots"], _wd(GpuLayout.WD_SLOTS)), maxi(room["most"], _wd(GpuLayout.WD_SLOTS))):
		refused.append("record slots %d" % maxi(room["slots"], _wd(GpuLayout.WD_SLOTS)))
	var grown := arena.ensure_events(room["events"], room["events_most"])
	if grown < 0:
		refused.append("events %d" % room["events_asked"])
	elif grown > 0:
		_p[GpuLayout.p_slot("event_capacity")] = arena.event_cap
		_upload_p()
	if not arena.ensure_clouds(room["clouds"]):
		refused.append("cloud slots %d" % room["clouds"])
	if not arena.ensure_husks(room["husks"]):
		refused.append("husk slots %d" % room["husks"])
	# The cloud lists' entries: the density the bin scan measured (entries a cloud slot in use) with ENTRY_MARGIN room, over the slots the
	# iteration is expected to use (the estimate, not the hard bound, which can be many times the clouds there are). When the budget has
	# no room for them the lists keep what they have: the kernel cuts what does not fit and raises the overflow flag.
	if _entry_density > 0:
		arena.ensure_entries(SimArena.entries_for(mini(room["entry_clouds"], arena.cloud_cap), ceili(_entry_density * ENTRY_MARGIN)))
	_after_growth()
	if refused.is_empty():
		return true
	_refuse("an iteration of %d steps needs %s, past the memory budget of %d bytes" % [steps, ", ".join(refused), limits.memory_budget_bytes])
	return false


## The budget refused the room something needs: OVERFLOW_BUDGET is set for good and the reason kept in `errors` (and pushed as an error),
## once while the same room is refused again and again.
func _refuse(why: String) -> void:
	_overflow |= OVERFLOW_BUDGET
	if not errors.is_empty() and errors[-1] == "SimCore: " + why:
		return
	errors.append("SimCore: " + why)
	push_error("SimCore: " + why)


## After the arena made new buffers: the uniform sets are made again, and WORLD learns the capacities.
func _after_growth() -> void:
	if not arena.changed:
		return
	arena.changed = false
	_free_sets()
	_put_world_capacities()


func _put_world_capacities() -> void:
	_set_wd(GpuLayout.WD_SLOT_CAPACITY, arena.slot_cap)
	_set_wd(GpuLayout.WD_PUFF_CAPACITY, arena.cloud_cap)
	_set_wd(GpuLayout.WD_HUSK_CAPACITY, arena.husk_cap)
	_set_wd(GpuLayout.WD_ENTRY_CAPACITY, arena.entry_cap)


## A row's field block, squares and table rows; false when the arena cannot hold them within the budget.
func _make_room(row: int, s: DishSpec, grid: DishGrid, count: int, clouds := 0, husks := 0) -> bool:
	var cells := _align(grid.n * grid.n)
	var bins_across := maxi(1, ceili(2.0 * s.radius / (0.5 * grid.spacing)) + 1)
	var bins := bins_across * bins_across
	if not arena.fits(_wd(GpuLayout.WD_SLOTS) + _align(count) + (_align(s.limit) if count > 0 else 0), cells, bins, _wd(GpuLayout.WD_CLOUD_SLOTS) + clouds, _wd(GpuLayout.WD_HUSK_SLOTS) + husks):
		return false
	if not arena.ensure_slots(_wd(GpuLayout.WD_SLOTS) + _align(count)) or not arena.ensure_clouds(_wd(GpuLayout.WD_CLOUD_SLOTS) + clouds + 1024) \
			or not arena.ensure_husks(_wd(GpuLayout.WD_HUSK_SLOTS) + husks + 1024):
		_after_growth()
		return false
	var cd := CoreDish.new()
	cd.spec = s
	cd.grid = grid
	cd.cells = cells
	cd.base = arena.alloc_cells(cells)
	cd.bins_across = bins_across
	cd.bins = bins
	cd.bin_base = arena.alloc_bins(bins)
	cd.cap = cap_for(s.limit)
	cd.flags = s.flags | (1 << GpuLayout.DPF_RUNNING) | (1 << GpuLayout.DPF_ACETATE)
	cd.seed32 = (s.seed ^ (s.seed >> 32)) & 0xFFFFFFFF
	_after_growth()
	_dishes[row] = cd
	_put_dishp(row)
	var celldish := PackedInt32Array()
	celldish.resize(cells)
	celldish.fill(-1)
	for c in grid.n * grid.n:
		celldish[c] = row
	var b := celldish.to_byte_array()
	rd.buffer_update(arena.buf("CELLDISH"), cd.base * 4, b.size(), b)
	var squares := PackedInt32Array()
	squares.resize(bins)
	squares.fill(row)
	var sq := squares.to_byte_array()
	rd.buffer_update(arena.buf("BINDISH"), cd.bin_base * 4, sq.size(), sq)
	_set_wd(GpuLayout.WD_CELLS, arena.cell_top)
	_set_wd(GpuLayout.WD_BINS, arena.bin_top)
	return true


## The dish's grid: its cells, the acetate's, the deposits waiting, the owners (pool cells), the inside marks and the feed's weights.
func _put_field(cd: CoreDish, conc: PackedFloat32Array, conc2: PackedFloat32Array, dplo: PackedByteArray, dphi: PackedByteArray) -> void:
	var g := cd.grid
	var owner := PackedInt32Array()
	owner.resize(g.n * g.n)
	for c in g.n * g.n:
		owner[c] = g.owner[c] + cd.base if g.owner[c] >= 0 else -1
	for pair in [["CONC", conc.to_byte_array()], ["CONC2", conc2.to_byte_array()], ["DPLO", dplo], ["DPHI", dphi], ["OWNER", owner.to_byte_array()],
			["INSIDE", g.inside.to_byte_array()], ["WGT", g.weights.to_byte_array()]]:
		var bytes: PackedByteArray = pair[1]
		rd.buffer_update(arena.buf(pair[0]), cd.base * 4, bytes.size(), bytes)


## The dish's records at the end of the slots in use, its blocks in the block table, its DSTATE row (with the segment's start and count).
func _put_segment(row: int, recs: PackedByteArray, ds: PackedByteArray) -> void:
	var count := recs.size() / RB
	var start := _wd(GpuLayout.WD_SLOTS)
	var d := ds.duplicate()
	d.encode_u32(GpuLayout.DS_START * 4, start)
	d.encode_u32(GpuLayout.DS_COUNT * 4, count)
	_set_ds_row(row, d)
	if count == 0:
		return
	rd.buffer_update(arena.buf(_cur("BUPS")), start * RB, recs.size(), recs)
	var blocks := (count + BLK - 1) / BLK
	var blk := PackedInt32Array()
	blk.resize(blocks)
	blk.fill(row)
	var b := blk.to_byte_array()
	rd.buffer_update(arena.buf(_cur("BLKDISH")), (start / BLK) * 4, b.size(), b)
	_set_wd(GpuLayout.WD_SLOTS, start + blocks * BLK)


## Clouds or husks (8 floats each, word 5 any) after the pool's, stamped with `row`'s word.
func _append_slots(buf_name: String, top_word: int, slots: PackedFloat32Array, row: int) -> void:
	var m := slots.size() / 8
	if m == 0:
		return
	var bytes := slots.to_byte_array()
	for k in m:
		bytes.encode_u32((k * 8 + 5) * 4, GpuLayout.PUFF_ROW_BASE + row)
	var top := _wd(top_word)
	rd.buffer_update(arena.buf(buf_name), top * 32, bytes.size(), bytes)
	_set_wd(top_word, top + m)


## The live clouds and husks of `row` in pool order, word 5 made 1.0: [clouds, husks].
func _slots_of(row: int) -> Array:
	var got := read_parts([["PUFF", 0, _wd(GpuLayout.WD_CLOUD_SLOTS) * 32], ["HUSK", 0, _wd(GpuLayout.WD_HUSK_SLOTS) * 32]])
	var word := GpuLayout.PUFF_ROW_BASE + row
	var out: Array = []
	for kind in 2:
		var raw: PackedByteArray = got[kind]
		var f := raw.to_float32_array()
		var mine := PackedFloat32Array()
		for k in raw.size() / 32:
			if raw.decode_u32((k * 8 + 5) * 4) != word:
				continue
			if kind == 1 and (f[k * 8 + 6] < 0.5 or int(f[k * 8 + 4]) >= GpuKernelsHusks.HUSK_PIECES):
				continue
			for j in 8:
				mine.append(1.0 if j == 5 else f[k * 8 + j])
		out.append(mine)
	return out


# ---- edits --------------------------------------------------------------------------------------------------------------------------

func _apply_edits() -> void:
	if _edits.is_empty():
		return
	for pair: Array in _edits:
		var row: int = pair[0]
		var e: WorldEdit = pair[1]
		if not _dishes.has(row):
			continue
		var cd: CoreDish = _dishes[row]
		if e.kind == WorldEdit.Kind.DROP:
			var x := e.position.x
			var y := e.position.y
			var v := maxf(0.25 * e.radius * e.radius, DishGrid.MIN_CLOUD_VARIANCE)
			if cd.grid.accepts(x, y) and sqrt(v) < float(_consts["cloud_handover"]) * cd.grid.spacing and _drop_cloud(row, x, y, e.amount, v):
				continue
			var cells := PackedInt32Array()
			var amounts := PackedFloat32Array()
			cd.grid.deposit_disc(x, y, e.radius, e.amount, cd.base, cells, amounts)
			if cells.is_empty():
				continue
			arena.put_small("EDC", cells.to_byte_array())
			arena.put_small("EDA", amounts.to_byte_array())
			_free_sets_using(["EDC", "EDA"])
			_run_list(func(cl: int) -> void: _disp(cl, "pool_edit_cells", 1, float(cells.size())))
		else:
			arena.put_small("EDA", PackedFloat32Array([e.radius, e.amount]).to_byte_array())
			_free_sets_using(["EDA"])
			_run_list(func(cl: int) -> void:
				_disp(cl, "pool_erase_cells", _groups(arena.cell_top), float(row), e.position.x, e.position.y)
				_disp(cl, "pool_erase_puffs", _groups(maxi(_wd(GpuLayout.WD_CLOUD_SLOTS), 64)), float(row), e.position.x, e.position.y))
	_edits.clear()
	_stats_fresh = false
	version += 1


## A dropped dose as a cloud of dish `row` (variance `v`, cut 1, as a plankton's burst: `_world_events`' discs), taken as the world's
## events are, by `pool_ev_puffs` (its dish's next cloud slot, or the grid past the dish's quota), from a one-row EVR and EVP of its own:
## the batch writes its own after. The clouds' lists are made again with it, so the pictures and the probes show it at once, while the
## world is paused too; the next step makes them afresh before it reads them, so this changes nothing a dish does (the count of entries a
## list cut, which the remake would count twice, is put back). False, with nothing done, when the memory budget has no room for another
## cloud slot (the dose then goes onto the grid).
func _drop_cloud(row: int, x: float, y: float, energy: float, v: float) -> bool:
	if not arena.ensure_clouds(_wd(GpuLayout.WD_CLOUD_SLOTS) + 1):
		return false
	_after_growth()
	var ranges := PackedInt32Array([0, 1, 0, 0]).to_byte_array()
	var cloud := PackedFloat32Array([x, y, energy, v, 1.0, _row_word(row)]).to_byte_array()
	rd.buffer_update(arena.buf("EVR"), 0, ranges.size(), ranges)
	rd.buffer_update(arena.buf("EVP"), 0, cloud.size(), cloud)
	var cut := {}
	for r: int in _dishes:
		cut[r] = _ds(r, GpuLayout.DS_ENTRIES_CUT)
	_run_list(func(cl: int) -> void:
		_disp(cl, "pool_ev_puffs", 1, 0.0)
		var hg := _groups(maxi(_wd(GpuLayout.WD_CLOUD_SLOTS) + 1, 64))
		_record_lists(cl, hg)
		_disp(cl, "pool_puff_clear", hg))  # (the lists hold the clouds' masses as they are now: nothing is left of a commit to put back)
	for r: int in cut:
		if _ds(r, GpuLayout.DS_ENTRIES_CUT) != cut[r]:
			var ds := dstate_row(r)
			ds.encode_u32(GpuLayout.DS_ENTRIES_CUT * 4, cut[r])
			_set_ds_row(r, ds)
	return true


# ---- reading --------------------------------------------------------------------------------------------------------------------------

func running_rows() -> Array:
	var rows: Array = _dishes.keys()
	rows.sort()
	return rows


func spec_of(row: int) -> DishSpec:
	return (_dishes[row] as CoreDish).spec if _dishes.has(row) else null


func count(row: int) -> int:
	return _ds(row, GpuLayout.DS_COUNT)


## The OVERFLOW_* bits seen so far (0: no buffer was ever full and no room was ever refused). Once set they stay.
func overflow() -> int:
	return _overflow


## The dish's DSTATE row as read after the last sync.
func dstate_row(row: int) -> PackedByteArray:
	return _dstate.slice(row * GpuLayout.DS_WORDS * 4, (row + 1) * GpuLayout.DS_WORDS * 4)


func world_word(word: int) -> int:
	return _wd(word)


## The dish's records in its segment's order.
func records(row: int) -> PackedByteArray:
	return read_parts([_records_part(row)])[0]


## The ids of the dish's bups in its segment's order (8 bytes a bup read back, not the records).
func live_ids(row: int) -> PackedInt64Array:
	if not _dishes.has(row):
		return PackedInt64Array()
	return _ids_from(_ds(row, GpuLayout.DS_START), _ds(row, GpuLayout.DS_COUNT))


## The ids of `n` records from slot `first` on: `pool_ids` writes them to CHILD's start (free between iterations), read as 64-bit ints.
func _ids_from(first: int, n: int) -> PackedInt64Array:
	if n <= 0:
		return PackedInt64Array()
	_run_list(func(cl: int) -> void: _disp(cl, "pool_ids", _groups(n), float(first), float(n)))
	return (read_parts([["CHILD", 0, n * 8]])[0] as PackedByteArray).to_int64_array()


## [name, offset, bytes] of the dish's records, for `read_parts`.
func _records_part(row: int) -> Array:
	return [_cur("BUPS"), _ds(row, GpuLayout.DS_START) * RB, _ds(row, GpuLayout.DS_COUNT) * RB] if _dishes.has(row) else ["BUPS", 0, 0]


## The dish's glucose, acetate and waiting deposits (CONC, CONC2, DPLO, DPHI), for `read_parts`.
func _field_parts(cd: CoreDish) -> Array:
	var bytes := cd.grid.n * cd.grid.n * 4
	return [["CONC", cd.base * 4, bytes], ["CONC2", cd.base * 4, bytes], ["DPLO", cd.base * 4, bytes], ["DPHI", cd.base * 4, bytes]]


## Parts of the buffers in one read back ([buffer name, byte offset, bytes] each; the records' and block table's names are the physical
## ones, `_cur`'s): each part is copied on the device into one scratch buffer, which is read back once. Reading a part of a big buffer
## straight back costs about what the whole buffer does (the device's staging is the buffer's size: 1 MB of a 128 MB buffer took 5.0 ms,
## against 0.74 ms copied out first [measured, M1 Pro]). Returns the parts' bytes in order.
func read_parts(parts: Array) -> Array:
	var total := 0
	for p: Array in parts:
		total += int(p[2])
	var out: Array = []
	if total == 0:
		for p: Array in parts:
			out.append(PackedByteArray())
		return out
	var scratch := _scratch_for(total)
	var at := 0
	for p: Array in parts:
		if int(p[2]) > 0:
			rd.buffer_copy(arena.buf(p[0]), scratch, int(p[1]), at, int(p[2]))
		at += int(p[2])
	var data := rd.buffer_get_data(scratch, 0, total)
	if scratch != _scratch:
		rd.free_rid(scratch)
	at = 0
	for p: Array in parts:
		out.append(data.slice(at, at + int(p[2])))
		at += int(p[2])
	return out


## A buffer of at least `total` bytes to gather reads in: the kept scratch (made larger when it must), or past SCRATCH_KEEP one made for
## the read, which its reader frees.
func _scratch_for(total: int) -> RID:
	if total > SCRATCH_KEEP:
		return rd.storage_buffer_create(total)
	if total > _scratch_bytes:
		if _scratch.is_valid():
			rd.free_rid(_scratch)
		_scratch_bytes = clampi(int(_scratch_bytes * 1.5), total, SCRATCH_KEEP)
		_scratch = rd.storage_buffer_create(_scratch_bytes)
	return _scratch


## Reads the next submit's sync completes, without a wait of their own: `parts` ([key, buffer name, byte offset, bytes] each) are copied,
## where the commands stand, into the scratch buffer, which one request reads back (as `read_parts` gathers them), so each part is its
## buffer as the commands recorded before left it; `direct` parts (the same form) are each requested straight from their buffer, for a
## part that is most of a buffer of its own. `_take` gives the bytes after the sync; nothing else may read through the scratch in between.
func _request(parts: Array, direct: Array) -> Dictionary:
	var reads := {"parts": parts, "direct": direct, "got": {}, "total": 0, "scratch": RID()}
	var total := 0
	for p: Array in parts:
		total += int(p[3])
	reads["total"] = total
	if total > 0:
		var scratch := _scratch_for(total)
		var at := 0
		for p: Array in parts:
			if int(p[3]) > 0:
				rd.buffer_copy(arena.buf(p[1]), scratch, int(p[2]), at, int(p[3]))
			at += int(p[3])
		reads["scratch"] = scratch
		rd.buffer_get_data_async(scratch, _read_in.bind(reads, ""), 0, total)
	for p: Array in direct:
		if int(p[3]) > 0:
			rd.buffer_get_data_async(arena.buf(p[1]), _read_in.bind(reads, String(p[0])), int(p[2]), int(p[3]))
	return reads


func _read_in(data: PackedByteArray, reads: Dictionary, key: String) -> void:
	(reads["got"] as Dictionary)[key] = data


## The bytes of `_request`'s parts once the sync that ran them is done: key -> bytes (empty for a part of none). A part whose request did
## not complete with the sync (none is expected to) is read with a wait.
func _take(reads: Dictionary) -> Dictionary:
	var got: Dictionary = reads["got"]
	var out := {}
	var total: int = reads["total"]
	var data := PackedByteArray()
	if total > 0:
		var scratch: RID = reads["scratch"]
		data = got.get("", PackedByteArray())
		if data.size() < total:
			data = rd.buffer_get_data(scratch, 0, total)
		if scratch != _scratch:
			rd.free_rid(scratch)
	var at := 0
	for p: Array in reads["parts"]:
		out[p[0]] = data.slice(at, at + int(p[3])) if int(p[3]) > 0 else PackedByteArray()
		at += int(p[3])
	for p: Array in reads["direct"]:
		var bytes := int(p[3])
		var d: PackedByteArray = got.get(String(p[0]), PackedByteArray())
		if bytes > 0 and d.size() < bytes:
			d = rd.buffer_get_data(arena.buf(p[1]), int(p[2]), bytes)
		out[p[0]] = d if bytes > 0 else PackedByteArray()
	return out


## What a dish is, word for word, for comparing two runs (tests/sim/canonical_dump.gd's sections): its records; its field (the glucose,
## the acetate, the deposits waiting); its live clouds and husks in pool order (word 5 1.0); its DSTATE row (the start 0: it is the pool's);
## its family events of the last iteration in ring order (births by the id's dish number, deaths by ED_STEP's); its stats now.
func canonical_dump(row: int) -> Dictionary:
	if not _stats_fresh:
		_refresh_stats()
	var cd: CoreDish = _dishes[row]
	var got := read_parts(_field_parts(cd) + [_records_part(row), ["STATS", row * GpuLayout.STATS_DISH_WORDS * 4, GpuLayout.STATS_WORDS * 4]])
	var field := PackedByteArray()
	for k in 4:
		field.append_array(got[k])
	var ds := dstate_row(row)
	ds.encode_u32(GpuLayout.DS_START * 4, 0)
	var ev := _events_of(row)
	var slots := _slots_of(row)
	return {
		"records": got[4],
		"field": field,
		"clouds": (slots[0] as PackedFloat32Array).to_byte_array(),
		"husks": (slots[1] as PackedFloat32Array).to_byte_array(),
		"dstate": ds,
		"births": ev[0],
		"deaths": ev[1],
		"stats": got[5],
	}


# ---- answers --------------------------------------------------------------------------------------------------------------------------

## The questions dishes ask, answered in one list from the state as it is when the list runs (`run` records them after the steps of its
## list): `questions` holds for each dish {key (the caller's name for it), row, fractions: {name: [gene (a name of GpuLayout.GENE_NAMES),
## threshold]} (up to GpuLayout.FRACTIONS), tracked: ids (up to GpuLayout.TRACKED), probes: PackedFloat32Array (x, y, speed, sense range a
## point, dish-local µm), husks: PackedFloat32Array (x, y, reach a place, dish-local µm, up to GpuLayout.HUSK_QUERIES), steer (default true:
## the steering at each tracked bup found)}. Returns key -> {fractions: {name: share}, tracked: {id: record bytes (`track`'s)}, steer: {id:
## Vector3 (the way up the gradient at the bup, x and y, and its chance of steering up it, for its own speed and sense range)}, probes:
## PackedFloat32Array (`probe`'s, for the points asked), husks: Array of {at: Vector2, reach, found (`husk_near`'s)}}. A dish whose
## questions need the device takes a set of the question buffers (GpuLayout.ANSWER_SETS, set 0 the publish's); one that finds none left
## is not answered (its key is not in the result) and asks again. A blocking read.
func answer(questions: Array) -> Dictionary:
	var staged := _answers_stage(questions)
	var got := {}
	if not (staged["sets"] as Array).is_empty():
		var cl := rd.compute_list_begin()
		_answers_record(cl, staged)
		rd.compute_list_end()
		var reads := _request(_answers_parts(staged), [])
		rd.submit()
		rd.sync()
		got = _take(reads)
	return _answers_take(staged, got)


## The share of dish `row`'s bups whose `gene` (a name of GpuLayout.GENE_NAMES) is at least `threshold` (`answer`'s; a blocking read).
## The kernel counts the records' float genes at or above the least float that is not below `threshold`, which is the same as comparing
## each float gene with `threshold` itself.
func fraction_with_gene_at_least(row: int, gene: String, threshold: float) -> float:
	var a: Dictionary = answer([{"key": 0, "row": row, "fractions": {"share": [gene, threshold]}}]).get(0, {})
	return float((a.get("fractions", {}) as Dictionary).get("share", 0.0))


## The records of the tracked bups `ids` (up to GpuLayout.TRACKED) of dish `row`, searched only in its segment (`answer`'s; a blocking
## read): id -> its first GpuLayout.ANSWER_BYTES bytes (everything but the chemotaxis memory). An id not in the dish (dead, never there, or
## in another dish) is left out.
func track(row: int, ids: PackedInt64Array) -> Dictionary:
	var a: Dictionary = answer([{"key": 0, "row": row, "tracked": ids, "steer": false}]).get(0, {})
	return a.get("tracked", {})


## The field and the steering at points of dish `row` (`pool_probe_full`, on the field and the cloud lists of the last step; `answer`'s, a
## blocking read): `points` holds x, y, speed, sense range for each point (up to GpuLayout.PROBES_MOST; dish-local µm). Returns for each
## point GpuLayout.PROBE_FLOATS floats: the unit direction up the gradient (x, y), the chance of steering up it for a bup of that speed and
## sense range (0.5 where there is no gradient), the nutrient concentration there (the grid's and the clouds') and the gradient's size
## (concentration per µm).
func probe(row: int, points: PackedFloat32Array) -> PackedFloat32Array:
	var a: Dictionary = answer([{"key": 0, "row": row, "probes": points}]).get(0, {})
	return a.get("probes", PackedFloat32Array())


## For each place of dish `row` (`places`: x, y, reach, up to GpuLayout.HUSK_QUERIES; dish-local µm), the nearest live husk within reach
## as PackedFloat32Array([x, y, energy, age, pieces let go]), or an empty one for none (`answer`'s; a blocking read).
func husk_near(row: int, places: PackedFloat32Array) -> Array:
	var a: Dictionary = answer([{"key": 0, "row": row, "husks": places}]).get(0, {})
	return (a.get("husks", []) as Array).map(func(h: Dictionary) -> PackedFloat32Array: return h["found"])


## Before the list: each dish's questions as what its kernels need, the dishes that need the device in a set of their own (from 1; set 0 is
## the publish's) with the set's buffers filled (FRQ counts from 0, the tracked ids in TQ and none in TR, the asked points in SPQ after
## the tracked bups' places, the husk places in HNQ and none in HNR). {sets: [entry], plain: [entry]} (plain: answered without the
## device); a dish past the last set is in neither.
func _answers_stage(questions: Array) -> Dictionary:
	var sets: Array = []
	var plain: Array = []
	for q: Dictionary in questions:
		var row: int = q.get("row", -1)
		var e := {"key": q.get("key", row), "row": row, "set": -1, "names": [], "genes": [], "thresholds": [], "ids": PackedInt64Array(),
			"steer": bool(q.get("steer", true)), "tracked_points": 0, "asked": 0, "places": PackedFloat32Array(), "husks": 0}
		var places := PackedFloat32Array(q.get("husks", PackedFloat32Array()))
		e["husks"] = mini(places.size() / 3, GpuLayout.HUSK_QUERIES)
		e["places"] = places.slice(0, e["husks"] * 3)
		var fr: Dictionary = q.get("fractions", {})
		for name: Variant in fr:
			if (e["names"] as Array).size() >= GpuLayout.FRACTIONS:
				break
			var f: Array = fr[name]
			e["names"].append(name)
			e["genes"].append(GpuLayout.GENE_NAMES.find(String(f[0])))
			e["thresholds"].append(float(f[1]))
		if not _dishes.has(row):
			plain.append(e)
			continue
		var ids := PackedInt64Array(q.get("tracked", PackedInt64Array()))
		e["ids"] = ids.slice(0, GpuLayout.TRACKED)
		e["tracked_points"] = (e["ids"] as PackedInt64Array).size() if e["steer"] else 0
		var asked := PackedFloat32Array(q.get("probes", PackedFloat32Array()))
		e["asked"] = mini(asked.size() / 4, GpuLayout.PROBES_MOST - int(e["tracked_points"]))
		var device: bool = (e["genes"] as Array).any(func(g: int) -> bool: return g >= 0) or not (e["ids"] as PackedInt64Array).is_empty() or int(e["asked"]) > 0 or int(e["husks"]) > 0
		if not device:
			plain.append(e)
			continue
		if sets.size() + 1 >= GpuLayout.ANSWER_SETS:
			continue  # (no set left: the dish is answered in a later list)
		var s := sets.size() + 1
		e["set"] = s
		if not (e["ids"] as PackedInt64Array).is_empty():
			_put_track(e["ids"], s)
		if int(e["asked"]) > 0:
			var pb := asked.slice(0, int(e["asked"]) * 4).to_byte_array()
			rd.buffer_update(arena.buf("SPQ"), (s * GpuLayout.PROBES_MOST + int(e["tracked_points"])) * 16, pb.size(), pb)
		if int(e["husks"]) > 0:
			var hq := PackedFloat32Array()
			var none := PackedInt32Array()
			for k in int(e["husks"]):
				hq.append_array(PackedFloat32Array([places[k * 3], places[k * 3 + 1], places[k * 3 + 2], 0.0]))
				var a := PackedInt32Array()
				a.resize(GpuLayout.HN_WORDS)
				a[0] = -1
				none.append_array(a)
			var qb := hq.to_byte_array()
			var nb := none.to_byte_array()
			var at := s * GpuLayout.HUSK_QUERIES
			rd.buffer_update(arena.buf("HNQ"), at * 16, qb.size(), qb)
			rd.buffer_update(arena.buf("HNR"), at * GpuLayout.HN_WORDS * 4, nb.size(), nb)
		sets.append(e)
	if not sets.is_empty():
		var zeros := arena.zeros(GpuLayout.ANSWER_SETS * GpuLayout.FRACTIONS * 4)
		rd.buffer_update(arena.buf("FRQ"), 0, zeros.size(), zeros)
	return {"sets": sets, "plain": plain}


## The answers' kernels for the staged sets, into the open list `cl`. Each bounds its loop by what the device holds when it runs (the
## dish's segment, the slots in use), so the counts the host knows before the steps size only the dispatch.
func _answers_record(cl: int, staged: Dictionary) -> void:
	for e: Dictionary in staged["sets"]:
		var s: int = e["set"]
		var row: int = e["row"]
		var genes: Array = e["genes"]
		for i in genes.size():
			if int(genes[i]) >= 0:
				_disp(cl, "pool_fraction", _bup_groups(), float(GpuLayout.R_SPEED + int(genes[i])), float(row), _float_at_least(float(e["thresholds"][i])), float(s * GpuLayout.FRACTIONS + i))
		if not (e["ids"] as PackedInt64Array).is_empty():
			_disp_track(cl, row, s)
			if e["steer"]:
				_disp(cl, "pool_track_points", 1, float(s))
		var points: int = int(e["tracked_points"]) + int(e["asked"])
		if points > 0:
			_disp(cl, "pool_probe_full", 1, float(points), float(row), float(_consts["steering_window"]), float(s))
			_disp(cl, "pool_probe_slots", points, float(points), float(row), float(_consts["steering_window"]), float(s))
		if int(e["husks"]) > 0:
			var kg := _groups(maxi(_wd(GpuLayout.WD_HUSK_SLOTS), 64))
			_disp(cl, "pool_husk_near", kg, float(row), float(e["husks"]), float(s))
			_disp(cl, "pool_husk_near2", kg, float(row), float(e["husks"]), float(s))
			_disp(cl, "pool_husk_near3", 1, float(row), float(e["husks"]), float(s))


## The parts of the question buffers the staged sets' answers are in, for `_request`.
func _answers_parts(staged: Dictionary) -> Array:
	var top := 0
	for e: Dictionary in staged["sets"]:
		top = maxi(top, int(e["set"]) + 1)
	if top == 0:
		return []
	return [["FRQ", "FRQ", 0, top * GpuLayout.FRACTIONS * 4], ["TR", "TR", 0, top * GpuLayout.TRACKED * GpuLayout.ANSWER_BYTES],
		["SPR", "SPR", 0, top * GpuLayout.PROBES_MOST * GpuLayout.PROBE_FLOATS * 4], ["HNR", "HNR", 0, top * GpuLayout.HUSK_QUERIES * GpuLayout.HN_WORDS * 4]]


## After the sync (and the read back of DSTATE, so a share is of the dish's bups then): each staged dish's answer, by its key.
func _answers_take(staged: Dictionary, got: Dictionary) -> Dictionary:
	var out := {}
	for e: Dictionary in staged["plain"] + staged["sets"]:
		var s: int = e["set"]
		var n := count(e["row"]) if _dishes.has(e["row"]) else 0
		var shares := {}
		var names: Array = e["names"]
		for i in names.size():
			var share := 0.0
			if s >= 0 and int(e["genes"][i]) >= 0 and n > 0:
				share = float((got["FRQ"] as PackedByteArray).decode_u32((s * GpuLayout.FRACTIONS + i) * 4)) / n
			shares[names[i]] = share
		var ids: PackedInt64Array = e["ids"]
		var tracked := {}
		var steer := {}
		var probes := PackedFloat32Array()
		if s >= 0:
			var tr_bytes := GpuLayout.TRACKED * GpuLayout.ANSWER_BYTES
			tracked = _took_track(ids, (got["TR"] as PackedByteArray).slice(s * tr_bytes, (s + 1) * tr_bytes))
			var pf := GpuLayout.PROBE_FLOATS
			var spr := (got["SPR"] as PackedByteArray).slice(s * GpuLayout.PROBES_MOST * pf * 4, (s + 1) * GpuLayout.PROBES_MOST * pf * 4).to_float32_array()
			if e["steer"]:
				for t in ids.size():
					if tracked.has(ids[t]):
						steer[ids[t]] = Vector3(spr[t * pf], spr[t * pf + 1], spr[t * pf + 2])
			var first: int = e["tracked_points"]
			probes = spr.slice(first * pf, (first + int(e["asked"])) * pf)
		var husks: Array = []
		var places: PackedFloat32Array = e["places"]
		for k in int(e["husks"]):
			var found := PackedFloat32Array()
			if s >= 0:
				var a := ((s * GpuLayout.HUSK_QUERIES + k) * GpuLayout.HN_WORDS) * 4
				var hn: PackedByteArray = got["HNR"]
				if hn.decode_u32(a + 4) != 0:
					found = hn.slice(a + 8, a + 28).to_float32_array()
			husks.append({"at": Vector2(places[k * 3], places[k * 3 + 1]), "reach": places[k * 3 + 2], "found": found})
		out[e["key"]] = {"fractions": shares, "tracked": tracked, "steer": steer, "probes": probes, "husks": husks}
	return out


## Set `which`'s tracked ids (TQ) and an answer of none for each (TR), before the list that runs `pool_track`.
func _put_track(ids: PackedInt64Array, which: int) -> void:
	var n := mini(ids.size(), GpuLayout.TRACKED)
	var q := arena.zeros(GpuLayout.TQ_WORDS * 4)
	q.encode_u32(0, n)
	for t in n:
		q.encode_u32((1 + 2 * t) * 4, ids[t] & 0xFFFFFFFF)
		q.encode_u32((2 + 2 * t) * 4, (ids[t] >> 32) & 0xFFFFFFFF)
	rd.buffer_update(arena.buf("TQ"), which * GpuLayout.TQ_WORDS * 4, q.size(), q)
	var none := arena.zeros(GpuLayout.TRACKED * GpuLayout.ANSWER_BYTES)
	for t in GpuLayout.TRACKED:
		none.encode_u32(t * GpuLayout.ANSWER_BYTES + GpuLayout.R_ID_LO * 4, 0xFFFFFFFF)
		none.encode_u32(t * GpuLayout.ANSWER_BYTES + GpuLayout.R_ID_HI * 4, 0xFFFFFFFF)
	rd.buffer_update(arena.buf("TR"), which * none.size(), none.size(), none)


## `pool_track` of set `which` over dish `row`'s segment as the device has it when it runs (dispatched for the count the host knows: the
## loop is bounded on the device).
func _disp_track(cl: int, row: int, which: int) -> void:
	_disp(cl, "pool_track", _groups(maxi(count(row), 64)), float(row), float(which))


## The slots the next `n` bup pictures are made in, in the order they are recorded, each [its slot, the slot of the picture before it]:
## the slots in turn (SimArena.picture_slots), so a picture never writes the slot of the picture before it, which it finds its bups'
## places before in, and the byte path's pictures of one iteration (at most GpuLayout.PICTURES_MOST) never write each other's. Every
## list that records a picture is submitted, so the slots follow the pictures as they run.
func _picture_slots(n: int) -> Array:
	var out: Array = []
	var slots := arena.picture_slots()
	for i in n:
		var before := _pic_slot % slots
		_pic_slot = (before + 1) % slots
		out.append([_pic_slot, before])
	return out


## `pool_track_picture` of set `which`, after the bup picture in slot `slot` (`room` texels a slot) in the same list: its answers carry
## where each bup was in the picture before (GpuLayout.R_PX, R_PY).
func _disp_track_picture(cl: int, row: int, which: int, slot: int, room: int) -> void:
	_disp(cl, "pool_track_picture", _groups(maxi(count(row), 64)), float(row), float(which), float(slot), float(room))


## The answers `pool_track` wrote (`got`: the set's TR, read after the list's sync): id -> record bytes, the ids found only.
func _took_track(ids: PackedInt64Array, got: PackedByteArray) -> Dictionary:
	var out := {}
	var n := mini(ids.size(), GpuLayout.TRACKED)
	for t in mini(n, got.size() / GpuLayout.ANSWER_BYTES):
		var answer := got.slice(t * GpuLayout.ANSWER_BYTES, (t + 1) * GpuLayout.ANSWER_BYTES)
		if _answer_id(answer) == ids[t]:
			out[ids[t]] = answer
	return out


static func _answer_id(answer: PackedByteArray) -> int:
	return answer.decode_u32(GpuLayout.R_ID_LO * 4) | (answer.decode_u32(GpuLayout.R_ID_HI * 4) << 32)


## Dish `row`'s live husks (alive, with a piece not yet let go: what the cull keeps) as 2D MultiMesh transforms, 8 floats each (a unit
## basis, the husk's place in the dish), in no set order: `pool_husk_view` packs them into HUSK2 (the cull's scratch, free between steps),
## read back in one right-sized read (the dish's husk counter bounds them; a second read when it did not). The list is run by that read
## and not by a submit and sync of its own: one wait for the card, not two.
func husk_view(row: int) -> PackedFloat32Array:
	var most := _husk_most(row)
	if most <= 0:
		return PackedFloat32Array()
	_husk_dispatch(row)
	var got := read_parts([["HVC", 0, 4], ["HUSK2", 0, most * 32]])
	var n := (got[0] as PackedByteArray).decode_u32(0)
	if n > most:
		got[1] = read_parts([["HUSK2", 0, n * 32]])[0]
	_husk_found = 0
	return (got[1] as PackedByteArray).slice(0, n * 32).to_float32_array()


## The most husks dish `row` can have to show: its husk counter (never past the slots in use), or what a read found it had when that
## passed the counter.
func _husk_most(row: int) -> int:
	if not _dishes.has(row):
		return 0
	return mini(maxi(_ds(row, GpuLayout.DS_HUSKS), _husk_found), _wd(GpuLayout.WD_HUSK_SLOTS))


## Records `pool_husk_view` for dish `row` (HVC counts them), not yet submitted.
func _husk_dispatch(row: int) -> void:
	arena.put_small("HVC", arena.zeros(16))
	var cl := rd.compute_list_begin()
	_disp(cl, "pool_husk_view", _groups(_wd(GpuLayout.WD_HUSK_SLOTS)), float(row))
	rd.compute_list_end()


## The list a run's read of `most` husks found (SimCore.run, `view.want_husks`): the transforms, or null when the dish had more than `most`
## by then (its husks grew in the steps; the next read is made for that many).
func _husk_list(most: int, count: PackedByteArray, list: PackedByteArray) -> Variant:
	if most <= 0:
		return PackedFloat32Array()
	var n := count.decode_u32(0)
	if n > most:
		_husk_found = n
		return null
	_husk_found = 0
	return list.slice(0, n * 32).to_float32_array()


## The least float (32-bit) that is not below `x`.
static func _float_at_least(x: float) -> float:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, x)
	var f := b.decode_float(0)
	if f < x:
		var bits := b.decode_u32(0)
		if f == 0.0:
			bits = 1
		elif f > 0.0:
			bits += 1
		else:
			bits -= 1
		b.encode_u32(0, bits)
	return b.decode_float(0)


## The energy ledger on or off (WORLD[WD_LEDGER]; off in the game): while on, the kernels add each running dish's energy flows into its
## DSTATE words DS_LEDGER... (see `ledger_of`); turning it on starts every running dish's sums from 0.
func keep_ledger(on: bool) -> void:
	_set_wd(GpuLayout.WD_LEDGER, 1 if on else 0)
	if not on:
		return
	for row: int in _dishes:
		var ds := dstate_row(row)
		for w in 2 * GpuLayout.LG_TERMS:
			ds.encode_u32((GpuLayout.DS_LEDGER + w) * 4, 0)
		_set_ds_row(row, ds)


## A dish's energy ledger from its DSTATE row (`dstate_row`, or a dump's "dstate"): term LG_* -> the sum since the ledger was turned on.
static func ledger_of(dstate: PackedByteArray) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for t in GpuLayout.LG_TERMS:
		var lo := dstate.decode_u32((GpuLayout.DS_LEDGER + 2 * t) * 4)
		var hi := dstate.decode_u32((GpuLayout.DS_LEDGER + 2 * t + 1) * 4)
		out.append((float(hi) * 4294967296.0 + float(lo)) / 1048576.0)
	return out


## The ring's events of dish `row` from the last iteration: [births, deaths] as bytes.
func _events_of(row: int) -> Array:
	var births := PackedByteArray()
	var deaths := PackedByteArray()
	if not _event_rows.has(row):
		return [births, deaths]
	var number := (_dishes[row] as CoreDish).spec.number
	var tb := 0
	var td := 0
	for r: int in D_MAX:
		tb += _ds(r, GpuLayout.DS_BIRTHS)
		td += _ds(r, GpuLayout.DS_DEATHS)
	tb = mini(tb, arena.event_cap)
	td = mini(td, arena.event_cap)
	var bw := GpuLayout.BIRTH_WORDS * 4
	var dw := GpuLayout.DEATH_WORDS * 4
	var got := read_parts([["EVB", 0, tb * bw], ["EVD", 0, td * dw]])
	if tb > 0:
		var eb: PackedByteArray = got[0]
		for k in tb:
			if GpuLayout.event_dish_number(eb.decode_u32(k * bw + GpuLayout.EB_STEP * 4)) == number:
				births.append_array(eb.slice(k * bw, (k + 1) * bw))
	if td > 0:
		var ed: PackedByteArray = got[1]
		for k in td:
			if GpuLayout.event_dish_number(ed.decode_u32(k * dw + GpuLayout.ED_STEP * 4)) == number:
				deaths.append_array(ed.slice(k * dw, (k + 1) * dw))
	return [births, deaths]


# ---- publish ------------------------------------------------------------------------------------------------------------------------

## The main dish's pictures into the next free shared texture of each kind: its payload and ids (its bups as they are), and when asked
## its field's haze and steering pictures and every dish's thumbnail. Only a free texture is written (see the header); a kind with none is
## not published this time. Every texture written holds this publish's number, `publish_seq` after the call. Returns kind -> the texture
## index written, and with a payload written and `view.track` ids asked, "tracked": those bups' records as the payload has them (as `track`
## gives them, looked up in the same list). A list of its own, one submit and one wait; `run` records the same after the steps of its list
## (`_publish_stage`, `_publish_record`, `_publish_parts`, `_publish_take`).
func publish(view: ViewRequest, _targets: Variant = null) -> Dictionary:
	var pub := _publish_stage(view, count(view.row) if view != null and _dishes.has(view.row) else 0)
	if pub.is_empty():
		return {}
	var cl := rd.compute_list_begin()
	_publish_record(cl, pub)
	rd.compute_list_end()
	var parts: Array = []
	var direct: Array = []
	_publish_parts(pub, parts, direct)
	var reads := _request(parts, direct)
	rd.submit()
	rd.sync()
	return _publish_take(pub, _take(reads))


## Before the list: the pictures' buffers made for `expect` bups (the count the dish is expected to have when the kernels run: they write
## no further than the buffers hold), the free textures chosen and the small buffers the kernels read filled. {} when nothing is
## published (none of the dish, its buffers past the memory budget, no texture free). With `steps` steps before the pictures and
## `pictures` > 1, up to `pictures` - 1 bup pictures more are made within the steps ("shots", `_record_shot`): `pictures` pictures in
## all at evenly spaced steps, the last after the last step, fewer when fewer textures are free (the last picture's is chosen first).
func _publish_stage(view: ViewRequest, expect: int, steps := 0, pictures := 1) -> Dictionary:
	if view == null or not _dishes.has(view.row):
		return {}
	if not (view.want_payload or view.want_field_view or view.want_thumbnails):
		return {}
	var row := view.row
	var cd: CoreDish = _dishes[row]
	var width := GpuLayout.PAYLOAD_TEX_WIDTH
	var rows := maxi(1, (expect + width - 1) / width)
	var texels := rows * width
	var drawn := arena.ensure_draw(texels, cd.grid.n * cd.grid.n, ((cd.cap + width - 1) / width) * width, view.want_thumbnails)
	if not drawn and expect > count(row):  # (room for the steps' births would pass the budget: the buffers are made for the count now, and a dish that grows past it in the steps is not drawn that time)
		expect = count(row)
		rows = maxi(1, (expect + width - 1) / width)
		texels = rows * width
		drawn = arena.ensure_draw(texels, cd.grid.n * cd.grid.n, ((cd.cap + width - 1) / width) * width, view.want_thumbnails)
	_after_growth()
	if not drawn:
		var why := "SimCore: the pictures' buffers for %d bups and a field of %d cells would pass the memory budget of %d bytes: not published" % [expect, cd.grid.n * cd.grid.n, limits.memory_budget_bytes]
		if draw_refusal == "":
			errors.append(why)  # (once while it lasts: the thread reports it as the refused iteration, so the game shows the memory banner)
		draw_refusal = why
		return {}
	draw_refusal = ""
	_free_retired()
	var nn := cd.grid.n
	var w: int
	var fw: int
	var sw: int
	var tw: int
	if cpu_handover:  # (no textures: the picture is read from the buffers it is laid out in, and the index is only the sign of "written")
		w = 0 if view.want_payload else -1
		fw = 0 if view.want_field_view else -1
		sw = fw
		tw = 0 if view.want_thumbnails else -1
	else:
		w = _free_texture("payload", Vector2i(width, maxi(rows, arena.draw_rows()))) if view.want_payload else -1  # (as tall as the buffers' room: made anew only when that grows)
		fw = _free_texture("haze", Vector2i(nn, nn)) if view.want_field_view else -1
		sw = _free_texture("steer", Vector2i(nn, nn)) if view.want_field_view else -1
		tw = _free_texture("thumbs", Vector2i(GpuKernelsDraw.THUMB_ATLAS, GpuKernelsDraw.THUMB_ATLAS)) if view.want_thumbnails else -1
	if w < 0 and fw < 0 and sw < 0 and tw < 0:
		return {}
	if fw >= 0 or sw >= 0:
		arena.put_small("VQ", PackedFloat32Array([view.steer.x, view.steer.y, view.steer_alpha, float(_consts["steering_window"])]).to_byte_array())
		_free_sets_using(["VQ"])
	if w >= 0 and _pic_dish != cd:  # (the slots hold another dish's pictures, or none: this dish's first picture has no places before)
		arena.put_small("SLOTHEAD", arena.zeros((GpuLayout.PICTURES_MOST + 1) * GpuLayout.SH_WORDS * 4))
		_pic_dish = cd
		_moved_since_pic = true
	var tracking := w >= 0 and not view.track.is_empty() and count(row) > 0
	if tracking:
		_put_track(view.track, 0)
	var room := arena.draw_rows() * width
	var shots: Array = []
	var slot := 0
	var before := 0
	if w >= 0:
		var taken: Array = [w]
		for j in mini(mini(pictures, GpuLayout.PICTURES_MOST), steps) - 1:
			var i := j + 1 if cpu_handover else _free_texture("payload", Vector2i(width, maxi(rows, arena.draw_rows())), taken)
			if i < 0:
				break
			taken.append(i)
			shots.append({"w": i, "count_at": j + 1, "set": GpuLayout.ANSWER_SETS + j})
		var slots := _picture_slots(shots.size() + 1)
		for j in shots.size():
			var shot: Dictionary = shots[j]
			shot["slot"] = slots[j][0]
			shot["before"] = slots[j][1]
			shot["step"] = ((j + 1) * steps) / (shots.size() + 1)
			shot["expect"] = mini(mini(_expected_count(row, shot["step"]), expect), room)
			if tracking:
				_put_track(view.track, shot["set"])
		arena.put_small("PICN", arena.zeros(GpuLayout.PICTURES_MOST * 4))
		slot = slots[-1][0]
		before = slots[-1][1]
	return {"view": view, "row": row, "texels": texels, "room": room, "expect": mini(expect, room), "nn": nn, "w": w, "fw": fw, "sw": sw,
		"tw": tw, "tracking": tracking, "shots": shots, "slot": slot, "before": before}


## A bup picture within the steps of the list `cl` (`shot`: one of `_publish_stage`'s "shots"), after the step it was chosen for: the
## payload of the dish as the device has it then, into its own shared texture (or, on the byte path, its own slot of PAYLOAD and IDTEX),
## its count into PICN and its tracked bups into its own set of TR.
func _record_shot(cl: int, pub: Dictionary, shot: Dictionary) -> void:
	var row: int = pub["row"]
	var room: int = pub["room"]
	_disp(cl, "pool_payload", _groups(pub["texels"]), float(row), float(room), float(shot["slot"]), float(int(shot["count_at"]) + 8 * int(shot["before"])))
	if not cpu_handover:
		var w: int = shot["w"]
		_copy(cl, "pool_copy_payload", {"PAYTEX": _textures["payload"][w], "IDS": _textures["ids"][w]}, GpuLayout.PAYLOAD_TEX_WIDTH, room, float(row), float(shot["slot"]))
	if pub["tracking"]:
		_disp_track_picture(cl, row, shot["set"], shot["slot"], room)


## The pictures' kernels into the open list `cl` (nothing for a `pub` of {}). The payload and its copy run over the dish's bups as the
## device has them then, within the buffers' room.
func _publish_record(cl: int, pub: Dictionary) -> void:
	if pub.is_empty():
		return
	var row: int = pub["row"]
	var view: ViewRequest = pub["view"]
	var nn: int = pub["nn"]
	var room: int = pub["room"]
	if pub["w"] >= 0:
		var same := 0 if _moved_since_pic else 64  # (no step since the picture before: its motion goes on)
		_moved_since_pic = false
		_disp(cl, "pool_payload", _groups(pub["texels"]), float(row), float(room), float(pub["slot"]), float(8 * int(pub["before"]) + same))
		if not cpu_handover:
			var w: int = pub["w"]
			_copy(cl, "pool_copy_payload", {"PAYTEX": _textures["payload"][w], "IDS": _textures["ids"][w]}, GpuLayout.PAYLOAD_TEX_WIDTH, room, float(row), float(pub["slot"]))
	if pub["tracking"]:
		_disp_track_picture(cl, row, 0, pub["slot"], room)
	if pub["fw"] >= 0 or pub["sw"] >= 0:
		_disp(cl, "pool_view_faint_clear", _groups(nn * nn), float(row))
		_disp(cl, "pool_view_faint", _groups(maxi(_wd(GpuLayout.WD_CLOUD_SLOTS), 64)), float(row))
		_disp(cl, "pool_view", _groups(nn * nn), float(row))
	if pub["fw"] >= 0:
		_disp(cl, "pool_haze", _groups(nn * nn), float(row), view.haze.x, view.haze.y, view.haze.z)
		if not cpu_handover:
			_copy_pix(cl, "HAZEPIX", _textures["haze"][pub["fw"]], nn, nn * nn)
	if pub["sw"] >= 0:
		_disp(cl, "pool_steer_map", _groups(nn * nn), float(row))
		if not cpu_handover:
			_copy_pix(cl, "STEERPIX", _textures["steer"][pub["sw"]], nn, nn * nn)
	if pub["tw"] >= 0:
		var tiles := D_MAX * GpuKernelsDraw.THUMB_TILE * GpuKernelsDraw.THUMB_TILE
		_disp(cl, "pool_thumb_clear", _groups(tiles))
		_disp(cl, "pool_thumb_splat", _bup_groups())
		_disp(cl, "pool_thumb_resolve", _groups(tiles))
		if not cpu_handover:
			_copy_pix(cl, "THUMBS", _textures["thumbs"][pub["tw"]], GpuKernelsDraw.THUMB_ATLAS, GpuKernelsDraw.THUMB_ATLAS * GpuKernelsDraw.THUMB_ATLAS)


## What the pictures read back, added to `parts` and `direct` (`_request`'s): the tracked bups' records (set 0 of TR) and, with
## `cpu_handover`, what is handed over, each straight from the buffer it was written in, only the part in use (the payload and the places
## before as far as the dish is expected to reach, the atlas's tile rows of the dishes in the pool).
func _publish_parts(pub: Dictionary, parts: Array, direct: Array) -> void:
	if pub.is_empty():
		return
	var tracked := mini((pub["view"] as ViewRequest).track.size(), GpuLayout.TRACKED) * GpuLayout.ANSWER_BYTES
	if pub["tracking"]:
		parts.append(["TR0", "TR", 0, tracked])
	var shots: Array = pub["shots"]
	if not shots.is_empty():
		parts.append(["PICN", "PICN", 0, GpuLayout.PICTURES_MOST * 4])
	for shot: Dictionary in shots:
		if pub["tracking"]:
			parts.append(["TR%d" % shot["set"], "TR", int(shot["set"]) * GpuLayout.TRACKED * GpuLayout.ANSWER_BYTES, tracked])
		if cpu_handover:
			direct.append(["payload%d" % shot["slot"], "PAYLOAD", int(shot["slot"]) * int(pub["room"]) * GpuLayout.PAYLOAD_BYTES, int(shot["expect"]) * GpuLayout.PAYLOAD_BYTES])
			direct.append(["prev%d" % shot["slot"], "PREVXY", int(shot["slot"]) * int(pub["room"]) * GpuLayout.PV_BYTES, int(shot["expect"]) * GpuLayout.PV_BYTES])
	if not cpu_handover:
		return
	var nn: int = pub["nn"]
	if pub["w"] >= 0:
		var first := int(pub["slot"]) * int(pub["room"])
		direct.append(["payload", "PAYLOAD", first * GpuLayout.PAYLOAD_BYTES, int(pub["expect"]) * GpuLayout.PAYLOAD_BYTES])
		direct.append(["prev", "PREVXY", first * GpuLayout.PV_BYTES, int(pub["expect"]) * GpuLayout.PV_BYTES])
	if pub["fw"] >= 0:
		direct.append(["haze", "HAZEPIX", 0, nn * nn * 4])
	if pub["sw"] >= 0:
		direct.append(["steer", "STEERPIX", 0, nn * nn * 4])
	if pub["tw"] >= 0:
		direct.append(["thumbs", "THUMBS", 0, _thumb_rows() * GpuKernelsDraw.THUMB_TILE * GpuKernelsDraw.THUMB_ATLAS * 4])


## The rows of the thumbnails' atlas that hold a running dish's tile.
func _thumb_rows() -> int:
	var most := 0
	for row: int in _dishes:
		most = maxi(most, row)
	return most / (GpuKernelsDraw.THUMB_ATLAS / GpuKernelsDraw.THUMB_TILE) + 1


## After the sync (and the read back of DSTATE): what `publish` returns, from what the list wrote and `got` (`_take`'s). With
## `cpu_handover` the handed-over bytes go to `handed`: the payload's texels of the dish's bups now and their places before (read on, with a
## wait, past what was expected), the pictures' pixels and the atlas's rows in use. A dish that outgrew the pictures' buffers in the steps is drawn only in
## part, so its payload is not published this time (the next is made for its count). The bup pictures made within the steps come first,
## each a publish of its own with its own number, in "shots": {step (the steps run before it), payload (its texture index), count,
## bytes and prev (with `cpu_handover`), tracked}, oldest first; the rest of the dictionary is the last publish's.
func _publish_take(pub: Dictionary, got: Dictionary) -> Dictionary:
	var out := {}
	if pub.is_empty():
		return out
	var started := Time.get_ticks_usec()
	for t: RID in _temp_sets:
		if rd.uniform_set_is_valid(t):
			rd.free_rid(t)
	_temp_sets.clear()
	var view: ViewRequest = pub["view"]
	var taken_shots: Array = []
	var counts: PackedByteArray = got.get("PICN", PackedByteArray())
	for shot: Dictionary in pub["shots"]:
		var at: int = int(shot["count_at"]) * 4
		var c := counts.decode_u32(at) if counts.size() >= at + 4 else -1
		if c < 0 or c > int(pub["room"]):
			continue  # (outgrew the buffers by then: drawn only in part)
		var taken := {"step": shot["step"], "payload": shot["w"], "count": c}
		if cpu_handover:
			taken["bytes"] = _handed_part(got, "payload%d" % shot["slot"], "PAYLOAD", int(shot["slot"]) * int(pub["room"]), c, GpuLayout.PAYLOAD_BYTES)
			taken["prev"] = _handed_part(got, "prev%d" % shot["slot"], "PREVXY", int(shot["slot"]) * int(pub["room"]), c, GpuLayout.PV_BYTES)
			handed_bytes += c * (GpuLayout.PAYLOAD_BYTES + GpuLayout.PV_BYTES)
		publish_seq += 1
		taken["seq"] = publish_seq
		if cpu_handover:
			_keep_ids(c, int(shot["slot"]) * int(pub["room"]))
		else:
			var i: int = shot["w"]
			_texture_seqs["payload"][i] = publish_seq
			_texture_used["payload"][i] = -1
			_superseded["payload"][i] = -1
		if pub["tracking"]:
			taken["tracked"] = _took_track(view.track, got.get("TR%d" % shot["set"], PackedByteArray()))
		taken_shots.append(taken)
	var n := count(pub["row"])
	var w: int = pub["w"] if n <= int(pub["room"]) else -1
	if cpu_handover:
		handed = {}
		if w >= 0:
			handed["payload"] = _handed_part(got, "payload", "PAYLOAD", int(pub["slot"]) * int(pub["room"]), n, GpuLayout.PAYLOAD_BYTES)
			handed["prev"] = _handed_part(got, "prev", "PREVXY", int(pub["slot"]) * int(pub["room"]), n, GpuLayout.PV_BYTES)
		if pub["fw"] >= 0:
			handed["haze"] = got.get("haze", PackedByteArray())
		if pub["sw"] >= 0:
			handed["steer"] = got.get("steer", PackedByteArray())
		if pub["tw"] >= 0:
			handed["thumbs"] = got.get("thumbs", PackedByteArray())
			handed["thumb_rows"] = _thumb_rows()
		var total := 0
		for kind: String in ["payload", "prev", "haze", "steer", "thumbs"]:
			total += (handed.get(kind, PackedByteArray()) as PackedByteArray).size()
		if total > 0 or not taken_shots.is_empty():
			handed_usec += Time.get_ticks_usec() - started
			handed_calls += 1
			handed_bytes += total
	for pair: Array in [["payload", w], ["haze", pub["fw"]], ["steer", pub["sw"]], ["thumbs", pub["tw"]]]:
		if int(pair[1]) >= 0:
			out[pair[0]] = pair[1]
	if not taken_shots.is_empty():
		out["shots"] = taken_shots
	if out.is_empty() or out.keys() == ["shots"]:
		return out
	publish_seq += 1
	if cpu_handover and out.has("payload"):
		_keep_ids(n, int(pub["slot"]) * int(pub["room"]))
	for kind: String in out:
		if cpu_handover:
			break
		if kind == "shots":
			continue
		var i: int = out[kind]
		_texture_seqs[kind][i] = publish_seq
		_texture_used[kind][i] = -1
		_superseded[kind][i] = -1
		_next_texture[kind] = (i + 1) % ring_of(kind)
	if pub["tracking"] and w >= 0:
		out["tracked"] = _took_track(view.track, got.get("TR0", PackedByteArray()))
	return out


## With `cpu_handover`: `n` texels of `unit` bytes of buffer `buffer` from texel `first` (a picture's slot), from the read `name` of `got`
## (`_take`'s), which holds as many as the dish was expected to reach: those past it are read now, with a wait.
func _handed_part(got: Dictionary, name: String, buffer: String, first: int, n: int, unit: int) -> PackedByteArray:
	var part: PackedByteArray = got.get(name, PackedByteArray())
	var bytes := n * unit
	if part.size() >= bytes:
		return part.slice(0, bytes)
	part.append_array(rd.buffer_get_data(arena.buf(buffer), first * unit + part.size(), bytes - part.size()))
	return part


## With `cpu_handover`: the ids of the payload just published (number `publish_seq`, from texel `first` of IDTEX: its slot) copied, on this
## device, into the ring's next slot.
func _keep_ids(n: int, first := 0) -> void:
	var need := arena.draw_rows() * GpuLayout.PAYLOAD_TEX_WIDTH * GpuLayout.IDT_BYTES  # (a slot of IDTEX)
	if _id_ring.is_empty() or need > _id_ring_bytes:
		_free_id_ring()
		_id_ring_bytes = need
		for i in ID_RING:
			_id_ring.append({"buffer": rd.storage_buffer_create(need), "seq": 0, "count": 0})
	var slot: Dictionary = _id_ring[_id_ring_next]
	_id_ring_next = (_id_ring_next + 1) % ID_RING
	slot["seq"] = publish_seq
	slot["count"] = n
	if n > 0:
		rd.buffer_copy(arena.buf("IDTEX"), slot["buffer"], first * GpuLayout.IDT_BYTES, 0, n * GpuLayout.IDT_BYTES)


func _free_id_ring() -> void:
	for slot: Dictionary in _id_ring:
		rd.free_rid(slot["buffer"])
	_id_ring.clear()
	_id_ring_next = 0
	_id_ring_bytes = 0


## With `cpu_handover`: the ids of the bups at texels `indices` of payload number `seq`, as the payload held them (-1 for a texel or a
## payload this no longer holds: the last ID_RING payloads are kept).
func ids_at(seq: int, indices: PackedInt32Array) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(indices.size())
	out.fill(-1)
	for slot: Dictionary in _id_ring:
		if int(slot["seq"]) != seq:
			continue
		for i in indices.size():
			var k := indices[i]
			if k >= 0 and k < int(slot["count"]):
				var bytes := rd.buffer_get_data(slot["buffer"], k * GpuLayout.IDT_BYTES, GpuLayout.IDT_BYTES)
				out[i] = bytes.decode_u32(GpuLayout.IDT_LO * 4) | (bytes.decode_u32(GpuLayout.IDT_HI * 4) << 32)
	return out


## The main side used texture `index` of `kind`, holding publish `seq`, on its frame `frame` (see the header: every use is told, with the
## number of the publish it held). A use always counts as a use of texture `index`, whatever the number says (a texture still told of is
## never free); the number counts only as the newest publish in use (none when seq < 0).
func texture_bound(kind: String, index: int, frame: int, seq: int) -> void:
	_frame = maxi(_frame, frame)
	for r: Dictionary in _retired_textures:
		if r["kind"] != kind:
			continue
		if seq < 0 or seq <= int(r["last_seq"]):  # (a use of the set made afresh since, or one whose publish is not known: counted as one)
			r["last_use"] = maxi(int(r["last_use"]), frame)
		elif int(r["moved_on"]) < 0:
			r["moved_on"] = frame
	if not _retired_textures.is_empty():
		_free_retired()  # (a paused world publishes nothing for a while: the main side's frames still let them go)
	if not _texture_seqs.has(kind) or index < 0 or index >= ring_of(kind):
		return
	var seqs: Array = _texture_seqs[kind]
	_texture_used[kind][index] = maxi(int(_texture_used[kind][index]), frame)
	if seq <= int(_seen_seq.get(kind, -1)):
		return
	_seen_seq[kind] = seq
	var gone: Array = _superseded[kind]
	for i in ring_of(kind):
		if int(seqs[i]) >= 0 and int(seqs[i]) < seq and int(gone[i]) < 0:
			gone[i] = frame


## The shared textures of `kind` ("payload", "ids", "haze", "steer", "thumbs"), for the main side to import.
func textures(kind: String) -> Array:
	return _textures.get(kind, [])


## How many shared textures of `kind` there are (PAYLOAD_TEXTURES for the bups' payload and ids, TEXTURES for the rest).
static func ring_of(kind: String) -> int:
	return PAYLOAD_TEXTURES if kind == "payload" or kind == "ids" else TEXTURES


## A free texture of `kind` (-1: none), not one of `taken` (indices chosen for this publish already), made anew at `size` first if the
## kind's are smaller.
func _free_texture(kind: String, size: Vector2i, taken: Array = []) -> int:
	var remake := not _textures.has(kind)
	if not remake:
		var f := rd.texture_get_format(_textures[kind][0])
		remake = f.width != size.x or f.height < size.y
	if remake:
		_make_textures(kind, size)
		if kind == "payload":
			_make_textures("ids", size)
	var start: int = _next_texture.get(kind, 0)
	var ring := ring_of(kind)
	for k in ring:
		var i := (start + k) % ring
		if taken.has(i):
			continue
		if int(_texture_seqs[kind][i]) < 0:
			return i
		var gone := int(_superseded[kind][i])
		if gone >= 0 and _frame - maxi(gone, int(_texture_used[kind][i])) > limits.frame_queue_size + 1:
			return i
	return -1


func _make_textures(kind: String, size: Vector2i) -> void:
	if _textures.has(kind):
		var old: Array = _textures[kind]
		if kind == "payload" and _textures.has("ids"):  # (the ids go with the payload: the main side tells only the payload's uses)
			old = old + _textures["ids"]
			_textures.erase("ids")
		_retire_textures(kind, old)
	_free_sets()
	var fmt := RDTextureFormat.new()
	fmt.width = size.x
	fmt.height = size.y
	fmt.format = {"payload": RenderingDevice.DATA_FORMAT_R32G32B32A32_UINT, "ids": RenderingDevice.DATA_FORMAT_R32G32B32A32_UINT}.get(kind, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var made: Array = []
	for k in ring_of(kind):
		made.append(rd.texture_create(fmt, RDTextureView.new()))
	_textures[kind] = made
	for table: Dictionary in [_texture_seqs, _texture_used, _superseded]:
		var a: Array = []
		a.resize(ring_of(kind))
		a.fill(-1)
		table[kind] = a
	_next_texture[kind] = 0


## Textures made afresh (`_make_textures`) may still be imported on the main side (a view of them, which on some drivers does not keep them
## alive), so they are freed only once it no longer uses them (`_free_retired`), even those it never told a use of (it may have imported
## them and drawn from them on a frame it has not told of yet).
func _retire_textures(kind: String, rids: Array) -> void:
	var last_seq := -1
	var last_use := -1
	for i in ring_of(kind):
		last_seq = maxi(last_seq, int(_texture_seqs[kind][i]))
		last_use = maxi(last_use, int(_texture_used[kind][i]))
	_retired_textures.append({"kind": kind, "rids": rids, "last_seq": last_seq, "last_use": last_use, "made": _frame, "moved_on": -1})
	textures_remade[kind] = int(textures_remade.get(kind, 0)) + 1


## Frees the textures made afresh that the main side is done with: it told of a newer publish of the kind in use (its uses never go back to
## an older one) and of no use of these for twice frame_queue_size + 1 frames (its view frees an import frame_queue_size + 1 frames after
## its last use, and its device lets go of it once the frames in flight are done); or it has told of as many frames since without ever
## using them. A world whose main side tells of no frame (a tool that does not) keeps them until `release`.
func _free_retired() -> void:
	var wait := 2 * (limits.frame_queue_size + 1)
	var keep: Array = []
	for r: Dictionary in _retired_textures:
		var used := int(r["last_use"])
		var done := (int(r["moved_on"]) >= 0 and _frame - maxi(int(r["moved_on"]), used) > wait) or (used < 0 and _frame - int(r["made"]) > wait)
		if not done:
			keep.append(r)
			continue
		for t: RID in r["rids"]:
			if t.is_valid():
				rd.free_rid(t)
	_retired_textures = keep


## The textures made afresh and not yet freed (for checks): {kind: sets}.
func retired_textures() -> Dictionary:
	var out := {}
	for r: Dictionary in _retired_textures:
		out[r["kind"]] = int(out.get(r["kind"], 0)) + 1
	return out


## Whether a haze or map set made afresh is waiting for the screen to move on from it, and no newer publish of its kind exists for the
## screen to move on to: one publish is owed (the screen leaves a set only by drawing a newer publish, which a paused world makes only
## when asked).
func retired_await_publish() -> bool:
	for r: Dictionary in _retired_textures:
		var kind: String = r["kind"]
		if (kind != "haze" and kind != "steer") or int(r["moved_on"]) >= 0:
			continue
		var newest := -1
		for s: Variant in _texture_seqs[kind]:
			newest = maxi(newest, int(s))
		if newest <= int(r["last_seq"]):
			return true
	return false


## A copy kernel with image bindings: its storage buffers by name, its images from `images`; `pc` and `pd` its third and fourth push constants.
func _copy(cl: int, kname: String, images: Dictionary, width: int, texels: int, pc := 0.0, pd := 0.0) -> void:
	var k: Dictionary = _made[kname]
	var uniforms: Array[RDUniform] = []
	var names: Array = k["buffers"]
	for b in names.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = b
		u.add_id(arena.buf(names[b]))
		uniforms.append(u)
	var bindings: Dictionary = GpuKernelsCore.IMAGE_BINDINGS[kname]
	for b: int in bindings:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = b
		u.add_id(images[bindings[b]])
		uniforms.append(u)
	var set_rid := rd.uniform_set_create(uniforms, k["shader"], 0)
	rd.compute_list_bind_compute_pipeline(cl, k["pipeline"])
	rd.compute_list_bind_uniform_set(cl, set_rid, 0)
	rd.compute_list_set_push_constant(cl, PackedFloat32Array([float(width), float(texels), pc, pd]).to_byte_array(), 16)
	rd.compute_list_dispatch(cl, _groups(texels), 1, 1)
	rd.compute_list_add_barrier(cl)
	_temp_sets.append(set_rid)


func _copy_pix(cl: int, src: String, texture: RID, width: int, texels: int) -> void:
	arena.alias("PIX", src)
	_copy(cl, "pool_copy_rgba8", {"PIC": texture}, width, texels)


# ---- the parameters -----------------------------------------------------------------------------------------------------------------

## P's slots that do not depend on the step: the constants, and the event ring's size.
func _fill_p() -> void:
	_p.resize(GpuLayout.P_WORDS)
	_p.fill(0.0)
	for slot_name: String in GpuLayout.P_SLOTS:
		var entry: Array = GpuLayout.P_SLOTS[slot_name]
		if entry[1] == "const":
			_p[entry[0]] = float(_consts[slot_name])
		elif entry[1] == "array":
			for k: int in entry[2]:
				_p[entry[0] + k] = float(_consts[slot_name][k])
	var put := func(nm: String, v: float) -> void: _p[GpuLayout.p_slot(nm)] = v
	put.call("starve_cost", float(_consts["starve_maintenance"]) * float(_consts["cost_per_mass"]))
	put.call("death_give", float(_consts["death_release"]) * float(_consts["cost_per_mass"]))
	var s_axis: Array = _consts["motion_s"]
	var e_axis: Array = _consts["motion_e"]
	put.call("motion_ns", s_axis.size())
	put.call("motion_ne", e_axis.size())
	put.call("motion_ls0", log(float(s_axis[0])))
	put.call("motion_dls", (log(float(s_axis[-1])) - log(float(s_axis[0]))) / (s_axis.size() - 1))
	put.call("motion_le0", log(float(e_axis[0])))
	put.call("motion_dle", (log(float(e_axis[-1])) - log(float(e_axis[0]))) / (e_axis.size() - 1))
	put.call("motion_s0", float(s_axis[0]))
	put.call("event_capacity", float(EVENT_FLOOR))


## The step's length: P's batch slots and every dish's DISHP row (the feed of a step, the diffusion's k and passes).
func _set_step(delta: float) -> void:
	if is_equal_approx(delta, _delta):
		return
	_delta = delta
	var put := func(nm: String, v: float) -> void: _p[GpuLayout.p_slot(nm)] = v
	put.call("delta", delta)
	put.call("moves", 1.0)
	put.call("sub", delta)
	put.call("death_chance", minf(float(_consts["death_rate"]) * delta, 1.0))
	put.call("death_puff", _p[GpuLayout.p_slot("death_give")])
	put.call("conj_chance", 1.0 - exp(-float(_consts["conj_rate"]) * delta))
	_upload_p()
	for row: int in _dishes:
		_put_dishp(row)


func _upload_p() -> void:
	var pb := _p.to_byte_array()
	rd.buffer_update(arena.buf("P"), 0, pb.size(), pb)


func _put_dishp(row: int) -> void:
	var cd: CoreDish = _dishes[row]
	var s := cd.spec
	var g := cd.grid
	var delta := _delta if _delta > 0.0 else Dish.MAX_STEP
	var diffusion := s.diffusion()  # the dish's own medium
	var k_total := diffusion * delta / (g.spacing * g.spacing)
	cd.iterations = maxi(2, 2 * ceili(k_total / 0.4))
	var dp := arena.zeros(GpuLayout.DP_WORDS * 4)
	var u := func(w: int, v: int) -> void: dp.encode_u32(w * 4, v)
	var fl := func(w: int, v: float) -> void: dp.encode_float(w * 4, v)
	u.call(GpuLayout.DP_FIELD_BASE, cd.base)
	u.call(GpuLayout.DP_CELLS, g.n)
	fl.call(GpuLayout.DP_SPACING, g.spacing)
	fl.call(GpuLayout.DP_RADIUS, s.radius)
	fl.call(GpuLayout.DP_HANDOVER, float(_consts["cloud_handover"]) * g.spacing)
	u.call(GpuLayout.DP_BIN_BASE, cd.bin_base)
	u.call(GpuLayout.DP_BINS_ACROSS, cd.bins_across)
	fl.call(GpuLayout.DP_BIN_SIZE, 0.5 * g.spacing)
	fl.call(GpuLayout.DP_FEED, Dish.feed_per_second(s.feed_density) * delta)
	fl.call(GpuLayout.DP_UPKEEP_SCALE, s.upkeep)
	u.call(GpuLayout.DP_LIMIT, s.limit)
	u.call(GpuLayout.DP_CAP, cd.cap)
	u.call(GpuLayout.DP_FLAGS, cd.flags)
	fl.call(GpuLayout.DP_K_TOTAL, k_total)
	fl.call(GpuLayout.DP_K, k_total / cd.iterations)
	fl.call(GpuLayout.DP_CLOUD_SPREAD, 2.0 * diffusion * delta)
	u.call(GpuLayout.DP_ITERATIONS, cd.iterations)
	u.call(GpuLayout.DP_CLOUD_QUOTA, s.cloud_quota)
	u.call(GpuLayout.DP_HUSK_QUOTA, s.husk_quota)
	u.call(GpuLayout.DP_NUMBER, s.number)
	u.call(GpuLayout.DP_SEED, cd.seed32)
	u.call(GpuLayout.DP_STEP, s.step)
	fl.call(GpuLayout.DP_NOISE_REFERENCE, s.noise_reference if s.noise_reference >= 0.0 else float(_consts["noise_reference"]))
	rd.buffer_update(arena.buf("DISHP"), row * GpuLayout.DP_WORDS * 4, dp.size(), dp)


## The sizes of the buffers that do not grow (bytes), and the motion table's contents.
func _table_bytes() -> Dictionary:
	var table := PackedFloat32Array()
	for nm in ["motion_drift", "motion_d_along", "motion_d_across", "motion_d_flat"]:
		table.append_array(PackedFloat32Array(_consts[nm]))
	return {"P": _p.to_byte_array(), "TABLE": table.to_byte_array()}


# ---- recording ----------------------------------------------------------------------------------------------------------------------

func _disp(cl: int, kname: String, groups: int, pa := 0.0, pb := 0.0, pc := 0.0, pd := 0.0) -> void:
	var key := kname + ("|f" if _flipped else "")
	var set_rid: RID = _sets.get(key, RID())
	if not set_rid.is_valid():
		assert(_made.has(kname), "SimCore: no kernel %s (%s)" % [kname, ", ".join(errors)])
		set_rid = ShaderSet.uniform_set(rd, _made[kname], arena.bufs, ["records"] if _flipped else [])
		_sets[key] = set_rid
	if _profile != null:
		var own := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(own, _made[kname]["pipeline"])
		rd.compute_list_bind_uniform_set(own, set_rid, 0)
		rd.compute_list_set_push_constant(own, PackedFloat32Array([pa, pb, pc, pd]).to_byte_array(), 16)
		rd.compute_list_dispatch(own, maxi(groups, 1), 1, 1)
		rd.compute_list_end()
		var t0 := Time.get_ticks_usec()
		rd.submit()
		rd.sync()
		if not _profile.has(kname):
			_profile[kname] = []
		_profile[kname].append(Time.get_ticks_usec() - t0)
		return
	rd.compute_list_bind_compute_pipeline(cl, _made[kname]["pipeline"])
	rd.compute_list_bind_uniform_set(cl, set_rid, 0)
	rd.compute_list_set_push_constant(cl, PackedFloat32Array([pa, pb, pc, pd]).to_byte_array(), 16)
	rd.compute_list_dispatch(cl, maxi(groups, 1), 1, 1)
	rd.compute_list_add_barrier(cl)


## A grid scan (GpuKernels.add_grid_scan) over about `elements` elements.
func _scan(cl: int, prefix: String, elements: int) -> void:
	var g := GpuKernels.scan_groups(elements)
	_disp(cl, prefix + "_chunks", g)
	_disp(cl, prefix + "_sums", 1, float(g))
	_disp(cl, prefix + "_add", g)


## Records `rec(compute list)`, submits and syncs; then reads WORLD and DSTATE back, unless `read_back` is false (a list that writes
## neither, as the pictures' is).
func _run_list(rec: Callable, read_back := true) -> void:
	var cl := rd.compute_list_begin()
	rec.call(cl)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	if read_back:
		_read_back()


func _read_back() -> void:
	_apply_read_back(rd.buffer_get_data(arena.buf("WORLD")), rd.buffer_get_data(arena.buf("DSTATE")))


## WORLD and DSTATE as read after a sync become the host's (`_world`, `_dstate`), with what the host takes from them.
func _apply_read_back(world: PackedByteArray, dstate: PackedByteArray) -> void:
	_world = world
	_dstate = dstate
	_overflow |= _wd(GpuLayout.WD_OVERFLOW)
	var peak := _wd(GpuLayout.WD_ENTRIES_PEAK)
	if peak > 0:  # (what the lists asked for: the kernel keeps the most since it was last set to 0, and the host takes it here)
		_entries_last = peak
		_entries_peak = maxi(_entries_peak, peak)
		_entry_density = maxi(_wd(GpuLayout.WD_ENTRY_DENSITY), int(_entry_density * 0.9))  # (falls by a tenth an iteration, as the deaths do)
		_set_wd(GpuLayout.WD_ENTRIES_PEAK, 0)
		_set_wd(GpuLayout.WD_ENTRY_DENSITY, 0)


## What the kernels' loops run over now, beside the capacities of `SimArena.report` (for the debug log): the record slots, cloud slots
## and husk slots in use (the dead among them are counted until the next compaction), the cloud lists' entries, the field cells and
## list squares given out, and the field's tiles in each of a step's rounds.
func in_use() -> Dictionary:
	return {"slots": _wd(GpuLayout.WD_SLOTS), "clouds": _wd(GpuLayout.WD_CLOUD_SLOTS), "husks": _wd(GpuLayout.WD_HUSK_SLOTS), "entries": _entries_last,
		"entries_a_cloud": _entry_density, "cells": arena.cell_top, "bins": arena.bin_top, "field_rounds": Array(_tile_rounds)}


func _free_sets() -> void:
	for key: String in _sets:
		var s: RID = _sets[key]
		if s.is_valid() and rd.uniform_set_is_valid(s):
			rd.free_rid(s)
	_sets.clear()


## Frees the sets of the kernels that bind any of `names` (their buffer was made again).
func _free_sets_using(names: Array) -> void:
	for key: String in _sets.keys():
		var kname: String = key.split("|")[0]
		if not _made.has(kname):
			continue
		var bound: Array = _made[kname]["buffers"]
		if names.any(func(nm: String) -> bool: return bound.has(nm)):
			var s: RID = _sets[key]
			if s.is_valid() and rd.uniform_set_is_valid(s):
				rd.free_rid(s)
			_sets.erase(key)


# ---- small helpers ------------------------------------------------------------------------------------------------------------------

## The physical name of the records' or block table's half in use.
func _cur(nm: String) -> String:
	return GpuKernels.physical(nm, ["records"] if _flipped else [])


func _bup_groups() -> int:
	return GpuKernels.bup_groups(maxi(_wd(GpuLayout.WD_SLOTS), BLK))


## Groups of 64 threads for a grid-stride loop over `items` (a thread an item, at most 16,384 groups).
static func _groups(items: int) -> int:
	return clampi(ceili(items / 64.0), 1, 16384)


static func _align(v: int) -> int:
	return ((v + BLK - 1) / BLK) * BLK


static func _row_word(row: int) -> float:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, GpuLayout.PUFF_ROW_BASE + row)
	return b.decode_float(0)


func _ds(row: int, word: int) -> int:
	return _dstate.decode_u32((row * GpuLayout.DS_WORDS + word) * 4)


func _wd(word: int) -> int:
	return _world.decode_u32(word * 4)


func _set_wd(word: int, value: int) -> void:
	_world.encode_u32(word * 4, value)
	var b := arena.zeros(4)
	b.encode_u32(0, value)
	rd.buffer_update(arena.buf("WORLD"), word * 4, 4, b)


func _set_ds_row(row: int, ds: PackedByteArray) -> void:
	for i in GpuLayout.DS_WORDS:
		_dstate.encode_u32((row * GpuLayout.DS_WORDS + i) * 4, ds.decode_u32(i * 4))
	rd.buffer_update(arena.buf("DSTATE"), row * GpuLayout.DS_WORDS * 4, GpuLayout.DS_WORDS * 4, ds)


func _free_row() -> int:
	for row in D_MAX:
		if not _dishes.has(row):
			return row
	return -1


func _derived_seed(number: int) -> int:
	var h := hash([world_seed, number])
	return h if h != 0 else 1


## A new game begins in this world: the dishes' numbers start again past the running dishes' (1 when none runs), so numbers stay unique
## within a game and a game's first pipette makes dish 2; with no dish running the ids start again from 1.
func begin_game() -> void:
	next_number = 1
	if _dishes.is_empty():
		_set_next_id(1)
	for row: int in _dishes:
		next_number = maxi(next_number, (_dishes[row] as CoreDish).spec.number + 1)


## A new dish for a pipette's bups: the source's size, grid, limit and settings, a fresh medium, the next number (`next_number`: past
## every dish this game has had, running, frozen or gone; taken now, so a dish added before this one is made does not take it), its seed
## and its landscape's seed drawn as `add_dish` would. `take` false: the spec the next one would have, the number not taken.
func receiver_spec(row: int, take := true) -> DishSpec:
	var s := (_dishes[row] as CoreDish).spec.copy()
	s.number = next_number
	if take:
		next_number += 1
	s.seed = _derived_seed(s.number)
	s.patch_seed = hash([s.seed, 7]) & 0x7FFFFFFF
	s.step = 0
	s.world = {}
	return s
