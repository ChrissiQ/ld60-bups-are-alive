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
## records its steps in one compute list in the order of tools/gpu/pool_rig.gd's header (life's `pool_*` kernels in kernels_life.gd's
## order), submits, syncs and reads back DSTATE and WORLD. The pipette is its own zero-step pass (`pipette`, a retarget); a dish leaves by
## `remove_dish` (its blocks become padding at once, its clouds and husks empty slots) and comes back by `load_dish` from what `gather`
## read; `resize` and `set_params` change a running dish. `publish` writes the main dish's pictures into the next free shared texture after
## the sync. Reads of parts of the buffers go through a right-sized copy (`read_parts`).
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
const CLOUD_COMPACT_EVERY := 16  ## world steps between compactions of the clouds (a dish's own cadence is DS_STEP % 16)
const HUSK_CULL_EVERY := 32  ## world steps between culls of the husks (any cadence: a cull changes no dish)
const EVENT_FLOOR := 32768  ## the event ring's least size (births, and as many deaths)
const EVENT_EXACT_MOST := 1 << 21  ## past this bound of an iteration's births the ring is sized from what the last iterations had
const MAX_STEPS := GpuLayout.MAX_STEPS_PER_BATCH
const TEXTURES := 8  ## shared textures of each kind: at one publish a display frame a texture is held about 6 frames (shown the frame after its publish, superseded the next, then frame_queue_size + 2 frames), the rest is room for a late frame
const HARD_BOUND_MOST := 1 << 18  ## the cloud (and husk) slots past which an iteration's room is estimated instead of bounded [placeholder: about 135 MB of cloud buffers at 516 B a slot]
const OVERFLOW_DEVICE := 1  ## `overflow()` bits: a kernel found a buffer full (WORLD's flag)
const OVERFLOW_BUDGET := 2  ## the room an iteration needed would pass the memory budget: it was refused, nothing ran
const SCRATCH_KEEP := 1 << 23  ## bytes: a read up to this goes through the kept scratch buffer; a larger one (a dish's records) through one made for it and freed after it, so no buffer outside the memory budget stays
const PROBES_MOST := 64  ## points a `probe` call answers

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
var _diffusion := -1.0
var _dishes := {}  ## row -> CoreDish
var _world := PackedByteArray()  ## WORLD as read after the last sync (and as the host has written it since)
var _dstate := PackedByteArray()  ## DSTATE likewise
var _world_step := 0
var _overflow := 0  ## OVERFLOW_* bits, kept once seen (an overflow is never undone: a dish's run after one may depend on the others)
var _edits: Array = []  ## [row, WorldEdit] for the next batch
var _event_rows := {}  ## rows whose family events of the last iteration are in the ring
var _stats_fresh := false  ## STATS sample 0 is every running dish's current state
var _deaths_per_step := 0.0  ## the most deaths a step of the last iterations had (all dishes), for the clouds' headroom
var _births_per_step := 0.0
var _textures := {}  ## kind -> Array of TEXTURES texture RIDs (publish)
var _texture_seqs := {}  ## kind -> Array: the publish each texture holds (-1: never written)
var _texture_used := {}  ## kind -> Array: the last frame the main side told it used each texture on since it was last written
var _superseded := {}  ## kind -> Array: the frame on which the main side first told of a newer publish of the kind than each texture holds (-1: not yet)
var _seen_seq := {}  ## kind -> the newest publish of the kind the main side has told of
var _next_texture := {}  ## kind -> where the search for a free texture starts (the one after the last written)
var _frame := 0  ## the main side's frame count as last told
var _retired_textures: Array = []  ## {kind, rids, last_seq, last_use, made, moved_on} of each set of textures made afresh, freed once unused (`_free_retired`)
var textures_remade := {}  ## kind -> sets of textures made afresh so far, each kept until unused (for checks)
var publish_seq := 0  ## the number of the last publish that wrote a texture
var _temp_sets: Array[RID] = []  ## the copy kernels' sets of one publish
var _profile: Variant = null  ## while `profile_steps` runs: kernel name -> Array of µs, each dispatch its own submit
var _scratch := RID()  ## where `read_parts` gathers what it reads (up to SCRATCH_KEEP bytes)
var _scratch_bytes := 0
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
	return ids


## What a dish is now, as a DishBlob (a blocking read): see DishBlob. The queued edits are made first, so a drop just before a freeze
## stays with the dish. Its clouds and husks are its live slots only, in pool order: every
## kernel passes a dead slot by, a dish's counters are virtual (DS_CLOUD_SLOTS and DS_HUSKS, recounted from the live slots at its own
## cadence) and the cloud lists keep the live clouds' order, so a dead slot carries nothing the dish's run reads (round_trip_test's
## continuation, checks it bit for bit).
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
	_run_list(func(cl: int) -> void:
		_disp(cl, "pool_ev_begin", D_MAX / 64)
		_disp(cl, "pool_pip_mark", bg, centre.x, centre.y, radius, pd)
		_scan(cl, "pool_scan_s", _wd(GpuLayout.WD_SLOTS))
		_disp(cl, "pool_pip_final", 1, centre.x, centre.y, radius, pd)
		_disp(cl, "pool_slot_check", 1)
		_disp(cl, "pool_pip_scatter", bg, centre.x, centre.y, radius, pd)
		_disp(cl, "pool_blk_fill", maxi(1, bg / 64))
		_disp(cl, "pool_setcount", D_MAX / 64, 0.0)
		_flipped = not _flipped
		_record_stats(cl, 0, 0))
	_read_back()
	_event_rows.clear()
	_stats_fresh = true
	var moved := _ds(dst, GpuLayout.DS_MOVED_IN)
	return {"new_row": dst, "moved": moved, "ids": _ids_from(_ds(dst, GpuLayout.DS_START) + before, moved)}


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


## Changes dish `row`'s size about its centre (Dish.resize_to, BupSim::grow and shrink, NutrientField::resize), and with `resolution` > 0
## its grid's most cells across: the dish is read whole, changed and loaded again under the same row (its segment, clouds and husks go to
## the pool's end, which changes no dish's run). The field is resampled onto the new grid as NutrientField::resize does (bilinear, in
## doubles, the deposits waiting folded in first; larger: scaled so no nutrient is lost; smaller: what is past the edge goes). Smaller:
## bups whose centre is past the new edge are gone, as deaths (their death events are returned for the family tree; they give nothing
## back, as any bup an edit removes), one straddling the edge is moved inside, and the clouds and husks past it go. The diffusion's k and
## passes follow the new grid. Returns {row, removed, deaths (death event bytes, GpuLayout.ED_*)}, or {} when the dish could not be loaded
## again within the budget (then it is back as it was, and `errors` says why).
func resize(row: int, new_radius: float, resolution := -1) -> Dictionary:
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


## A field of the old grid on the new one (NutrientField::resize): each inside cell of the new grid whose centre lies over the old grid
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


## A bup straddling the edge moved inside (BupSim::keep_inside): to `limit` from the middle along its own line, facing along the wall.
## Where it faced straight at the wall, it turns the way its id's lowest bit says (the C++ draws it from the dish's stream).
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
## tree then holds as its roots (the single-dish path's BupSim.add_bup made their records), born in dish number `number`.
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


## Sets dish `row`'s glucose grid (n² values, the dish's own cells).
func set_field(row: int, values: PackedFloat32Array) -> void:
	var cd: CoreDish = _dishes[row]
	assert(values.size() == cd.grid.n * cd.grid.n, "SimCore.set_field: %d values for a grid of %d" % [values.size(), cd.grid.n * cd.grid.n])
	var b := values.to_byte_array()
	rd.buffer_update(arena.buf("CONC"), cd.base * 4, b.size(), b)


# ---- the iteration ------------------------------------------------------------------------------------------------------------------

## `steps` steps of `delta` seconds of every running dish, in one submit: record, submit, sync, read back DSTATE and WORLD. `plan`
## (IterationPlan) carries each dish's world events and the history samples. Returns {steps, overflow, record_usec, gpu_usec}; steps 0
## when the room the iteration needs would pass the memory budget (OVERFLOW_BUDGET is set, `errors` says so, nothing ran). An overflow a
## kernel finds (WORLD's flag) is not undone: the iteration cannot be done again from what the host holds (the records and fields change
## in place on the device), so `overflow()` keeps it and the kernels keep every read and write inside the buffers.
func run(steps: int, delta: float, plan: Variant = null) -> Dictionary:
	_apply_edits()
	if steps <= 0:
		if not _stats_fresh:
			_refresh_stats()
		return {"steps": 0, "overflow": _overflow}
	steps = mini(steps, MAX_STEPS)
	_set_step(delta)
	var events: Dictionary = plan.events if plan != null and plan.get("events") != null else {}
	var history: PackedByteArray = plan.history_flags if plan != null and plan.get("history_flags") != null else PackedByteArray()
	var ev := _world_events(steps, events)
	if not _ensure_room(steps, ev):
		return {"steps": 0, "overflow": _overflow}
	_upload_events(ev)
	var t0 := Time.get_ticks_usec()
	var cl := rd.compute_list_begin()
	_disp(cl, "pool_ev_begin", D_MAX / 64)
	var samples := 0
	for s in steps:
		_record_step(cl, s)
		if s < history.size() and history[s] != 0 and samples < GpuLayout.STATS_ITER_SAMPLES:
			samples += 1
			_record_stats(cl, samples, s)
	_record_stats(cl, 0, steps - 1)
	rd.compute_list_end()
	var t1 := Time.get_ticks_usec()
	rd.submit()
	rd.sync()
	var t2 := Time.get_ticks_usec()
	_read_back()
	_event_rows.clear()
	var deaths := 0
	var births := 0
	for row: int in _dishes:
		_event_rows[row] = true
		deaths += _ds(row, GpuLayout.DS_DEATHS)
		births += _ds(row, GpuLayout.DS_BIRTHS)
	_deaths_per_step = maxf(float(deaths) / steps, _deaths_per_step * 0.9)
	_births_per_step = maxf(float(births) / steps, _births_per_step * 0.9)
	_stats_fresh = true
	arena.maybe_shrink(_wd(GpuLayout.WD_SLOTS), _wd(GpuLayout.WD_CLOUD_SLOTS), _wd(GpuLayout.WD_HUSK_SLOTS))
	if arena.changed:
		_after_growth()
	return {"steps": steps, "overflow": _overflow, "record_usec": t1 - t0, "gpu_usec": t2 - t1}


## For timing (tools/gpu/core_perf.gd): `steps` steps as `run` records them, but each dispatch in a submit of its own, timed by the wall
## clock around its submit and sync. Returns kernel name -> Array of µs (one entry a dispatch) and "_noop" -> the same for a one-thread
## kernel (the round trip to take off). The results are the same as `run`'s; only the time differs.
func profile_steps(steps: int, delta: float, plan: Variant = null) -> Dictionary:
	_apply_edits()
	_set_step(delta)
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
		_record_step(-1, s)
	_record_stats(-1, 0, steps - 1)
	var out: Dictionary = _profile
	_profile = null
	_read_back()
	_event_rows.clear()
	for row: int in _dishes:
		_event_rows[row] = true
	_stats_fresh = true
	return out


## The step `s` of a batch, in the order of tools/gpu/pool_rig.gd's header.
func _record_step(cl: int, s: int) -> void:
	var bg := _bup_groups()
	var cg := _groups(arena.cell_top)
	var hg := _groups(maxi(_wd(GpuLayout.WD_CLOUD_SLOTS), 64))
	var kg := _groups(maxi(_wd(GpuLayout.WD_HUSK_SLOTS), 64))
	var slots := maxi(_wd(GpuLayout.WD_SLOTS), BLK)
	_disp(cl, "pool_ev_puffs", 1, float(s))
	_disp(cl, "ev_deposits", 1, float(s))
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
	_disp(cl, "pool_puff_advance", hg)
	_disp(cl, "pool_dep_apply", cg)
	_disp(cl, "pool_snapshot", cg)
	_record_lists(cl, hg)
	_disp(cl, "pool_clear", cg)
	_disp(cl, "pool_puff_clear", hg)
	for kname: String in (["pool_swim", "pool_demand"] if lone_passes else ["pool_swim_demand"]):
		_disp(cl, kname, bg)
	_disp(cl, "pool_cells", cg)
	_disp(cl, "pool_puff_scale", hg)
	var buckets := GpuKernelsLife.conj_buckets(slots)
	_disp(cl, "pool_conj_clear", maxi(bg, _groups(buckets)))
	for kname: String in (["pool_apply", "pool_conj_count"] if lone_passes else ["pool_apply_count"]):
		_disp(cl, kname, bg)
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


## The clouds' lookup lists made afresh from the clouds as they are (every step makes them before anything reads them; the words a cloud
## keeps for them, its reach and sigma, are worked out from its mass and spread alone).
func _record_lists(cl: int, hg: int) -> void:
	var bins := maxi(arena.bin_top, 1)
	_disp(cl, "pool_bin_clear", _groups(bins))
	_disp(cl, "pool_bin_count", hg)
	_scan(cl, "pool_bn", bins)
	_disp(cl, "pool_bin_cut", D_MAX / 64)
	_scan(cl, "pool_bn", bins)
	_disp(cl, "pool_bin_room", D_MAX / 64)
	_disp(cl, "pool_bin_cursor", _groups(bins))
	_disp(cl, "pool_bin_scatter", hg)
	_disp(cl, "pool_bin_sort", _groups(bins))


## The per-dish stats over the layout now into sample `sample` of each running dish's STATS row, taken after step `step` of the batch.
func _record_stats(cl: int, sample: int, step: int) -> void:
	_disp(cl, "pool_stats1", maxi(1, _bup_groups() / 4))
	_disp(cl, "pool_stats2", 64, 0.0, float(sample), float(step))


func _refresh_stats() -> void:
	_run_list(func(cl: int) -> void: _record_stats(cl, 0, 0))
	_stats_fresh = true


# ---- the world's events ------------------------------------------------------------------------------------------------------------

## Each running dish's DishWorld rows (plan.events[row]: discs, puffs, deposits and husks, step n of the window 1-based, a pending row 0)
## as the batch's EVR, EVP, EVCC and EVCA: per step, the dishes in row order, each dish's plankton (discs or husks) then its sources'
## clouds; a disc, a cloud and a deposit become clouds or cells as NutrientField's add_cloud, release_emitter and deposit_xy decide.
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

## Grows what an iteration of `steps` steps could pass: the record slots to the bound of every dish's segment after
## `steps` doublings (a bup divides at most once a step, and never past its dish's cap); the event ring to the bound of its births; the
## clouds and husks, while that bound is small (under EVENT_EXACT_MOST, and the slots under HARD_BOUND_MOST), to a hard bound: each
## step's deaths are at most its bups (the same bound), each death and plankton husk makes at most a cloud or a husk, and each husk lets go
## at most min(12, steps x (delta / a quarter of its life + 1)) pieces; past it, to an estimate of what the steps until the next
## compaction append (a kernel that finds a buffer full raises the overflow flag and keeps inside it). False, with OVERFLOW_BUDGET set and
## the reason in `errors`, when the room would pass the memory budget.
func _ensure_room(steps: int, ev: Dictionary) -> bool:
	var need := 0
	var bound := 0
	var counted := 0
	for row: int in _dishes:
		var cd: CoreDish = _dishes[row]
		var n := _ds(row, GpuLayout.DS_COUNT)
		counted += n
		need += _align(mini(cd.cap, n << mini(steps, 30)))
		var b := 0
		for j in steps:
			b += mini(cd.cap, n << mini(j, 30))
			if b >= EVENT_EXACT_MOST:
				break
		bound += b
	var refused: Array[String] = []
	if not arena.ensure_slots(maxi(need, _wd(GpuLayout.WD_SLOTS))):
		refused.append("record slots %d" % maxi(need, _wd(GpuLayout.WD_SLOTS)))
	var exact := bound < EVENT_EXACT_MOST
	var events := bound if exact else maxi(EVENT_EXACT_MOST, int(4.0 * maxf(_births_per_step, _deaths_per_step) * steps))
	var grown := arena.ensure_events(maxi(events, EVENT_FLOOR))
	if grown < 0:
		refused.append("events %d" % events)
	elif grown > 0:
		_p[GpuLayout.p_slot("event_capacity")] = arena.event_cap
		_upload_p()
	var world_clouds: int = (ev["puffs"] as PackedFloat32Array).size() / GpuLayout.EV_PUFF_FLOATS
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
	if not arena.ensure_clouds(clouds):
		refused.append("cloud slots %d" % clouds)
	if not arena.ensure_husks(husks):
		refused.append("husk slots %d" % husks)
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
	if _diffusion < 0.0:
		_diffusion = s.diffusion()
	assert(is_equal_approx(_diffusion, s.diffusion()), "SimCore: the dishes of a pool share the medium")
	_put_dishp(row)
	var celldish := PackedInt32Array()
	celldish.resize(cells)
	celldish.fill(-1)
	for c in grid.n * grid.n:
		celldish[c] = row
	var b := celldish.to_byte_array()
	rd.buffer_update(arena.buf("CELLDISH"), cd.base * 4, b.size(), b)
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
		_record_lists(cl, _groups(maxi(_wd(GpuLayout.WD_CLOUD_SLOTS) + 1, 64))))
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
	var scratch := _scratch
	if total > SCRATCH_KEEP:
		scratch = rd.storage_buffer_create(total)
	elif total > _scratch_bytes:
		if _scratch.is_valid():
			rd.free_rid(_scratch)
		_scratch_bytes = clampi(int(_scratch_bytes * 1.5), total, SCRATCH_KEEP)
		_scratch = rd.storage_buffer_create(_scratch_bytes)
		scratch = _scratch
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


## The share of dish `row`'s bups whose `gene` (a name of GpuLayout.GENE_NAMES) is at least `threshold` (BupSim's
## fraction_with_gene_at_least, goal 2's input; a blocking read). The kernel counts the records' float genes at or above the least float
## that is not below `threshold`, which is the same as comparing each float gene with `threshold` itself.
func fraction_with_gene_at_least(row: int, gene: String, threshold: float) -> float:
	var g := GpuLayout.GENE_NAMES.find(gene)
	var n := count(row) if _dishes.has(row) else 0
	if g < 0 or n == 0:
		return 0.0
	arena.put_small("FRQ", arena.zeros(16))
	_run_list(func(cl: int) -> void: _disp(cl, "pool_fraction", _bup_groups(), float(GpuLayout.R_SPEED + g), float(row), _float_at_least(threshold)))
	return float(rd.buffer_get_data(arena.buf("FRQ"), 0, 4).decode_u32(0)) / n


## The records of the tracked bups `ids` (up to GpuLayout.TRACKED) of dish `row`, searched only in its segment (a blocking read): id ->
## its first GpuLayout.ANSWER_BYTES bytes (everything but the chemotaxis memory). An id not in the dish (dead, never there, or in another
## dish) is left out.
func track(row: int, ids: PackedInt64Array) -> Dictionary:
	var n := mini(ids.size(), GpuLayout.TRACKED)
	if n == 0 or not _dishes.has(row) or count(row) == 0:
		return {}
	_put_track(ids)
	_run_list(func(cl: int) -> void: _disp_track(cl, row))
	return _took_track(ids)


## The tracked bups' question (TQ) and an answer of none for each (TR), before the list that runs `pool_track`.
func _put_track(ids: PackedInt64Array) -> void:
	var n := mini(ids.size(), GpuLayout.TRACKED)
	var q := arena.zeros((1 + 2 * GpuLayout.TRACKED) * 4)
	q.encode_u32(0, n)
	for t in n:
		q.encode_u32((1 + 2 * t) * 4, ids[t] & 0xFFFFFFFF)
		q.encode_u32((2 + 2 * t) * 4, (ids[t] >> 32) & 0xFFFFFFFF)
	rd.buffer_update(arena.buf("TQ"), 0, q.size(), q)
	var none := arena.zeros(GpuLayout.TRACKED * GpuLayout.ANSWER_BYTES)
	for t in GpuLayout.TRACKED:
		none.encode_u32(t * GpuLayout.ANSWER_BYTES + GpuLayout.R_ID_LO * 4, 0xFFFFFFFF)
		none.encode_u32(t * GpuLayout.ANSWER_BYTES + GpuLayout.R_ID_HI * 4, 0xFFFFFFFF)
	rd.buffer_update(arena.buf("TR"), 0, none.size(), none)


func _disp_track(cl: int, row: int) -> void:
	var m := count(row)
	_disp(cl, "pool_track", _groups(m), float(_ds(row, GpuLayout.DS_START)), float(m))


## The answers `pool_track` wrote, after the list's sync (TR is small: read straight back): id -> record bytes, the ids found only.
func _took_track(ids: PackedInt64Array) -> Dictionary:
	var out := {}
	var n := mini(ids.size(), GpuLayout.TRACKED)
	var got := rd.buffer_get_data(arena.buf("TR"), 0, n * GpuLayout.ANSWER_BYTES)
	for t in n:
		var answer := got.slice(t * GpuLayout.ANSWER_BYTES, (t + 1) * GpuLayout.ANSWER_BYTES)
		if _answer_id(answer) == ids[t]:
			out[ids[t]] = answer
	return out


static func _answer_id(answer: PackedByteArray) -> int:
	return answer.decode_u32(GpuLayout.R_ID_LO * 4) | (answer.decode_u32(GpuLayout.R_ID_HI * 4) << 32)


## The field and the steering at points of dish `row` (`pool_probe_full`, on the field and the cloud lists of the last step): `points` holds
## x, y, speed, sense range for each point (up to PROBES_MOST; dish-local µm). Returns for each point GpuLayout.PROBE_FLOATS floats: the
## unit direction up the gradient (x, y), the chance of steering up it for a bup of that speed and sense range (0.5 where there is no
## gradient), the nutrient concentration there (the grid's and the clouds') and the gradient's size (concentration per µm).
func probe(row: int, points: PackedFloat32Array) -> PackedFloat32Array:
	var n := mini(points.size() / 4, PROBES_MOST)
	if n == 0 or not _dishes.has(row):
		return PackedFloat32Array()
	var q := points.slice(0, n * 4).to_byte_array()
	rd.buffer_update(arena.buf("SPQ"), 0, q.size(), q)
	_run_list(func(cl: int) -> void: _disp(cl, "pool_probe_full", 1, float(n), float(row), float(_consts["steering_window"])))
	return (read_parts([["SPR", 0, n * GpuLayout.PROBE_FLOATS * 4]])[0] as PackedByteArray).to_float32_array()


## Dish `row`'s live husks (alive, with a piece not yet let go: what the cull keeps) as 2D MultiMesh transforms, 8 floats each (a unit
## basis, the husk's place in the dish), in no set order: `pool_husk_view` packs them into HUSK2 (the cull's scratch, free between steps),
## read back in one right-sized read (the dish's husk counter bounds them; a second read when it did not).
func husk_view(row: int) -> PackedFloat32Array:
	var most := mini(_ds(row, GpuLayout.DS_HUSKS), _wd(GpuLayout.WD_HUSK_SLOTS)) if _dishes.has(row) else 0
	if most <= 0:
		return PackedFloat32Array()
	arena.put_small("HVC", arena.zeros(16))
	_run_list(func(cl: int) -> void: _disp(cl, "pool_husk_view", _groups(_wd(GpuLayout.WD_HUSK_SLOTS)), float(row)), false)
	var got := read_parts([["HVC", 0, 4], ["HUSK2", 0, most * 32]])
	var n := (got[0] as PackedByteArray).decode_u32(0)
	if n > most:
		got[1] = read_parts([["HUSK2", 0, n * 32]])[0]
	return (got[1] as PackedByteArray).slice(0, n * 32).to_float32_array()


## For each place of dish `row` (`places`: x, y, reach, up to GpuLayout.HUSK_QUERIES; dish-local µm), the nearest live husk within reach
## (BupSim::husk_near): PackedFloat32Array([x, y, energy, age, pieces let go]), or an empty one for none.
func husk_near(row: int, places: PackedFloat32Array) -> Array:
	var n := mini(places.size() / 3, GpuLayout.HUSK_QUERIES)
	var out: Array = []
	if n == 0 or not _dishes.has(row) or _wd(GpuLayout.WD_HUSK_SLOTS) == 0:
		for k in n:
			out.append(PackedFloat32Array())
		return out
	var q := PackedFloat32Array()
	var none := PackedInt32Array()
	for k in n:
		q.append_array(PackedFloat32Array([places[k * 3], places[k * 3 + 1], places[k * 3 + 2], 0.0]))
		var answer := PackedInt32Array()
		answer.resize(GpuLayout.HN_WORDS)
		answer[0] = -1
		none.append_array(answer)
	var qb := q.to_byte_array()
	var nb := none.to_byte_array()
	rd.buffer_update(arena.buf("HNQ"), 0, qb.size(), qb)
	rd.buffer_update(arena.buf("HNR"), 0, nb.size(), nb)
	var kg := _groups(_wd(GpuLayout.WD_HUSK_SLOTS))
	_run_list(func(cl: int) -> void:
		_disp(cl, "pool_husk_near", kg, float(row), float(n))
		_disp(cl, "pool_husk_near2", kg, float(row), float(n))
		_disp(cl, "pool_husk_near3", 1, float(row), float(n)), false)
	var got: PackedByteArray = read_parts([["HNR", 0, n * GpuLayout.HN_WORDS * 4]])[0]
	for k in n:
		var a := k * GpuLayout.HN_WORDS * 4
		out.append(got.slice(a + 8, a + 28).to_float32_array() if got.decode_u32(a + 4) != 0 else PackedFloat32Array())
	return out


## A bup's sense range from its record's words (GpuWorld's `_sense_range`, RecordCodec's): its sense gene times the root of its size (the
## root of its mass) over the reference size.
func sense_range_of(answer: PackedByteArray) -> float:
	var mass := answer.decode_float(GpuLayout.R_MASS * 4)
	return answer.decode_float(GpuLayout.R_SENSE * 4) * sqrt(sqrt(maxf(mass, 0.0)) / float(_consts["reference_size"]))


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

## The main dish's pictures into the next free shared texture of each kind, after the iteration's sync: its payload and
## ids (bups after the last step), and when asked its field's haze and steering pictures and every dish's thumbnail. Only a free texture is
## written (see the header); a kind with none is not published this time. Every texture written holds this publish's number, `publish_seq`
## after the call. Returns kind -> the texture index written, and with a payload written and `view.track` ids asked, "tracked": those bups'
## records as the payload has them (as `track` gives them, looked up in the same list).
func publish(view: ViewRequest, _targets: Variant = null) -> Dictionary:
	var out := {}
	if view == null or not _dishes.has(view.row):
		return out
	var row := view.row
	var cd: CoreDish = _dishes[row]
	var n := _ds(row, GpuLayout.DS_COUNT)
	var rows := maxi(1, (n + GpuLayout.PAYLOAD_TEX_WIDTH - 1) / GpuLayout.PAYLOAD_TEX_WIDTH)
	var texels := rows * GpuLayout.PAYLOAD_TEX_WIDTH
	arena.ensure_draw(texels, cd.grid.n * cd.grid.n)
	_after_growth()
	_free_retired()
	var w := _free_texture("payload", Vector2i(GpuLayout.PAYLOAD_TEX_WIDTH, rows))
	var nn := cd.grid.n
	var fw := _free_texture("haze", Vector2i(nn, nn)) if view.want_field_view else -1
	var sw := _free_texture("steer", Vector2i(nn, nn)) if view.want_field_view else -1
	var tw := _free_texture("thumbs", Vector2i(GpuKernelsDraw.THUMB_ATLAS, GpuKernelsDraw.THUMB_ATLAS)) if view.want_thumbnails else -1
	if w < 0 and fw < 0 and sw < 0 and tw < 0:
		return out
	if fw >= 0 or sw >= 0:
		arena.put_small("VQ", PackedFloat32Array([view.steer.x, view.steer.y, view.steer_alpha, float(_consts["steering_window"])]).to_byte_array())
		_free_sets_using(["VQ"])
	var tracking := w >= 0 and not view.track.is_empty() and n > 0
	if tracking:
		_put_track(view.track)
	_run_list(func(cl: int) -> void:
		if w >= 0:
			_disp(cl, "pool_payload", _groups(texels), float(row))
			_copy(cl, "pool_copy_payload", {"PAYTEX": _textures["payload"][w], "IDS": _textures["ids"][w]}, GpuLayout.PAYLOAD_TEX_WIDTH, texels)
		if tracking:
			_disp_track(cl, row)
		if fw >= 0 or sw >= 0:
			_disp(cl, "pool_view", _groups(nn * nn), float(row))
		if fw >= 0:
			_disp(cl, "pool_haze", _groups(nn * nn), float(row), view.haze.x, view.haze.y, view.haze.z)
			_copy_pix(cl, "HAZEPIX", _textures["haze"][fw], nn, nn * nn)
		if sw >= 0:
			_disp(cl, "pool_steer_map", _groups(nn * nn), float(row))
			_copy_pix(cl, "STEERPIX", _textures["steer"][sw], nn, nn * nn)
		if tw >= 0:
			var tiles := D_MAX * GpuKernelsDraw.THUMB_TILE * GpuKernelsDraw.THUMB_TILE
			_disp(cl, "pool_thumb_clear", _groups(tiles))
			_disp(cl, "pool_thumb_splat", _bup_groups())
			_disp(cl, "pool_thumb_resolve", _groups(tiles))
			_copy_pix(cl, "THUMBS", _textures["thumbs"][tw], GpuKernelsDraw.THUMB_ATLAS, GpuKernelsDraw.THUMB_ATLAS * GpuKernelsDraw.THUMB_ATLAS), false)
	for t: RID in _temp_sets:
		if rd.uniform_set_is_valid(t):
			rd.free_rid(t)
	_temp_sets.clear()
	for pair in [["payload", w], ["haze", fw], ["steer", sw], ["thumbs", tw]]:
		if pair[1] >= 0:
			out[pair[0]] = pair[1]
	if out.is_empty():
		return out
	publish_seq += 1
	for kind: String in out:
		var i: int = out[kind]
		_texture_seqs[kind][i] = publish_seq
		_texture_used[kind][i] = -1
		_superseded[kind][i] = -1
		_next_texture[kind] = (i + 1) % TEXTURES
	if tracking:
		out["tracked"] = _took_track(view.track)
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
	if not _texture_seqs.has(kind) or index < 0 or index >= TEXTURES:
		return
	var seqs: Array = _texture_seqs[kind]
	_texture_used[kind][index] = maxi(int(_texture_used[kind][index]), frame)
	if seq <= int(_seen_seq.get(kind, -1)):
		return
	_seen_seq[kind] = seq
	var gone: Array = _superseded[kind]
	for i in TEXTURES:
		if int(seqs[i]) >= 0 and int(seqs[i]) < seq and int(gone[i]) < 0:
			gone[i] = frame


## The shared textures of `kind` ("payload", "ids", "haze", "steer", "thumbs"), for the main side to import.
func textures(kind: String) -> Array:
	return _textures.get(kind, [])


func _free_texture(kind: String, size: Vector2i) -> int:
	var remake := not _textures.has(kind)
	if not remake:
		var f := rd.texture_get_format(_textures[kind][0])
		remake = f.width != size.x or f.height < size.y
	if remake:
		_make_textures(kind, size)
		if kind == "payload":
			_make_textures("ids", size)
	var start: int = _next_texture.get(kind, 0)
	for k in TEXTURES:
		var i := (start + k) % TEXTURES
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
	fmt.format = {"payload": RenderingDevice.DATA_FORMAT_R32G32B32A32_UINT, "ids": RenderingDevice.DATA_FORMAT_R32G32_UINT}.get(kind, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var made: Array = []
	for k in TEXTURES:
		made.append(rd.texture_create(fmt, RDTextureView.new()))
	_textures[kind] = made
	for table: Dictionary in [_texture_seqs, _texture_used, _superseded]:
		var a: Array = []
		a.resize(TEXTURES)
		a.fill(-1)
		table[kind] = a
	_next_texture[kind] = 0


## Textures made afresh (`_make_textures`) may still be imported on the main side (a view of them, which on some drivers does not keep them
## alive), so they are freed only once it no longer uses them (`_free_retired`), even those it never told a use of (it may have imported
## them and drawn from them on a frame it has not told of yet).
func _retire_textures(kind: String, rids: Array) -> void:
	var last_seq := -1
	var last_use := -1
	for i in TEXTURES:
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


## A copy kernel with image bindings: its storage buffers by name, its images from `images`.
func _copy(cl: int, kname: String, images: Dictionary, width: int, texels: int) -> void:
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
	rd.compute_list_set_push_constant(cl, PackedFloat32Array([float(width), float(texels), 0.0, 0.0]).to_byte_array(), 16)
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
	put.call("cloud_spread", 2.0 * maxf(_diffusion, 0.0) * delta)
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
	var k_total := _diffusion * delta / (g.spacing * g.spacing)
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
	u.call(GpuLayout.DP_ITERATIONS, cd.iterations)
	u.call(GpuLayout.DP_CLOUD_QUOTA, s.cloud_quota)
	u.call(GpuLayout.DP_HUSK_QUOTA, s.husk_quota)
	u.call(GpuLayout.DP_NUMBER, s.number)
	u.call(GpuLayout.DP_SEED, cd.seed32)
	u.call(GpuLayout.DP_STEP, s.step)
	fl.call(GpuLayout.DP_NOISE_REFERENCE, float(_consts["noise_reference"]))
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
	_world = rd.buffer_get_data(arena.buf("WORLD"))
	_dstate = rd.buffer_get_data(arena.buf("DSTATE"))
	_overflow |= _wd(GpuLayout.WD_OVERFLOW)


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
