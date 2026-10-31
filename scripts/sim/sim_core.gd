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
## read. `publish` writes the main dish's pictures into the next free shared texture after the sync.

const D_MAX := GpuLayout.D_MAX
const RB := GpuLayout.RECORD_BYTES
const BLK := GpuLayout.BLK_SLOTS
const CLOUD_COMPACT_EVERY := 16  ## world steps between compactions of the clouds (a dish's own cadence is DS_STEP % 16)
const HUSK_CULL_EVERY := 32  ## world steps between culls of the husks (any cadence: a cull changes no dish)
const EVENT_FLOOR := 32768  ## the event ring's least size (births, and as many deaths)
const EVENT_EXACT_MOST := 1 << 21  ## past this bound of an iteration's births the ring is sized from what the last iterations had
const MAX_STEPS := GpuLayout.MAX_STEPS_PER_BATCH
const TEXTURES := 4  ## shared textures of each kind

var rd: RenderingDevice
var limits: PoolLimits
var arena: SimArena
var world_seed := 1  ## a new dish's seed is drawn from this and its number when its spec has none
var errors: Array[String] = []  ## kernels that did not load or build

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
var _overflow := 0  ## WORLD's overflow flag, kept once seen
var _edits: Array = []  ## [row, WorldEdit] for the next batch
var _event_rows := {}  ## rows whose family events of the last iteration are in the ring
var _stats_fresh := false  ## STATS sample 0 is every running dish's current state
var _deaths_per_step := 0.0  ## the most deaths a step of the last iterations had (all dishes), for the clouds' headroom
var _births_per_step := 0.0
var _textures := {}  ## kind -> Array of TEXTURES texture RIDs (publish)
var _texture_frames := {}  ## kind -> Array of the frame each texture was last bound on the main side (the host tells: `texture_bound`)
var _published := {}  ## kind -> index of the texture published last
var _frame := 0  ## the main side's frame count as last told
var _temp_sets: Array[RID] = []  ## the copy kernels' sets of one publish
var _profile: Variant = null  ## while `profile_steps` runs: kernel name -> Array of µs, each dispatch its own submit


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


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:  # (written out: the instance's own methods may be gone by now)
		for key: String in _sets:
			if (_sets[key] as RID).is_valid() and rd.uniform_set_is_valid(_sets[key]):
				rd.free_rid(_sets[key])
		for kind: String in _textures:
			for t: RID in _textures[kind]:
				rd.free_rid(t)
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
	if arena != null:
		arena.free_all()
	ShaderSet.free_all(rd, _made)
	_made.clear()
	if _own_device:
		rd.free()
	rd = null


# ---- dishes --------------------------------------------------------------------------------------------------------------------------

## Adds a dish (its founders as its first segment, its field filled); returns its row, or -1 when there is no free row or it would pass
## the memory budget.
func add_dish(spec: DishSpec) -> int:
	var row := _free_row()
	if row < 0:
		return -1
	var s := spec.copy()
	if s.seed == 0:
		s.seed = _derived_seed(s.number)
	if s.patch_seed == 0:
		s.patch_seed = hash([s.seed, 7]) & 0x7FFFFFFF
	var grid := DishGrid.make(s.radius, s.resolution, s.patchiness, s.patch_seed)
	var count := s.founders.size() / RB
	if not _make_room(row, s, grid, count):
		return -1
	var cd: CoreDish = _dishes[row]
	var conc := grid.filled(clampf(s.nutrient_density, 0.0, StartConditions.MAX_NUTRIENT_DENSITY) * Dish.CONCENTRATION_PER_DENSITY)
	var none := PackedFloat32Array()
	none.resize(grid.n * grid.n)
	_put_field(cd, conc, none, arena.zeros(grid.n * grid.n * 4), arena.zeros(grid.n * grid.n * 4))
	var next_id := GpuLayout.make_id(s.number, 1)
	for i in count:
		next_id = maxi(next_id, GpuLayout.id_of(s.founders, i) + 1)
	var ds := arena.zeros(GpuLayout.DS_WORDS * 4)
	ds.encode_u32(GpuLayout.DS_NEXT_ID_LO * 4, next_id & 0xFFFFFFFF)
	ds.encode_u32(GpuLayout.DS_NEXT_ID_HI * 4, (next_id >> 32) & 0xFFFFFFFF)
	ds.encode_u32(GpuLayout.DS_SEED * 4, cd.seed32)
	ds.encode_u32(GpuLayout.DS_STEP * 4, s.step)
	_put_segment(row, s.founders, ds)
	_stats_fresh = false
	return row


## Loads a dish that `gather` read (a thaw, a load): a new row, its segment at the end, its clouds and husks after the pool's, its run
## carrying on from its saved step. Returns the row, or -1.
func load_dish(blob: DishBlob) -> int:
	var row := _free_row()
	if row < 0:
		return -1
	var s := DishSpec.from_dict(blob.spec)
	var grid := DishGrid.make(s.radius, s.resolution, s.patchiness, s.patch_seed)
	if not _make_room(row, s, grid, blob.count(), blob.clouds.size() / 8, blob.husks.size() / 8):
		return -1
	var cd: CoreDish = _dishes[row]
	_put_field(cd, blob.conc, blob.conc2, blob.dplo, blob.dphi)
	_put_segment(row, blob.records, blob.dstate)
	_append_slots("PUFF", GpuLayout.WD_CLOUD_SLOTS, blob.clouds, row)
	_append_slots("HUSK", GpuLayout.WD_HUSK_SLOTS, blob.husks, row)
	_stats_fresh = false
	return row


## Takes a dish out of the world at once: its blocks become padding (the next step's compaction closes the gap), its clouds and husks
## empty slots, its field block and squares free. Returns the ids of its live bups (for LineageStore.release_dish).
func remove_dish(row: int) -> PackedInt64Array:
	var ids := live_ids(row)
	var cd: CoreDish = _dishes.get(row)
	if cd == null:
		return ids
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


## What a dish is now, as a DishBlob (a blocking read): see DishBlob.
func gather(row: int) -> DishBlob:
	var cd: CoreDish = _dishes[row]
	var blob := DishBlob.new()
	blob.spec = cd.spec.to_dict()
	blob.dstate = _dstate.slice(row * GpuLayout.DS_WORDS * 4, (row + 1) * GpuLayout.DS_WORDS * 4)
	blob.records = records(row)
	var n2 := cd.grid.n * cd.grid.n
	blob.conc = rd.buffer_get_data(arena.buf("CONC"), cd.base * 4, n2 * 4).to_float32_array()
	blob.conc2 = rd.buffer_get_data(arena.buf("CONC2"), cd.base * 4, n2 * 4).to_float32_array()
	blob.dplo = rd.buffer_get_data(arena.buf("DPLO"), cd.base * 4, n2 * 4)
	blob.dphi = rd.buffer_get_data(arena.buf("DPHI"), cd.base * 4, n2 * 4)
	blob.clouds = _slots_of(row, "PUFF", GpuLayout.WD_CLOUD_SLOTS, false)
	blob.husks = _slots_of(row, "HUSK", GpuLayout.WD_HUSK_SLOTS, true)
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
## size, grid, limit and settings, fresh medium, the next number). A pass of its own: no step, no draw, no event; the stats after it
## count the moved bups in the destination. Returns {new_row, moved, ids} ({} when the destination could not be made).
func pipette(row: int, centre: Vector2, radius: float, dest: Variant = null) -> Dictionary:
	var dst := -1
	if dest is int:
		dst = dest
	else:
		var spec: DishSpec = dest if dest is DishSpec else _receiver_spec(row)
		spec.founders = PackedByteArray()
		dst = add_dish(spec)
	if dst < 0 or dst == row:
		return {}
	_apply_edits()
	var need := _wd(GpuLayout.WD_SLOTS) + _align(_ds(row, GpuLayout.DS_COUNT)) + BLK
	if not arena.ensure_slots(need):
		return {}
	_after_growth()
	var before := _ds(dst, GpuLayout.DS_COUNT)
	var pd := float(row + dst * D_MAX)
	var bg := _bup_groups()
	_run_list(func(cl: int) -> void:
		_disp(cl, "pool_ev_begin", D_MAX / 64)
		_disp(cl, "pool_pip_mark", bg, centre.x, centre.y, radius, pd)
		_disp(cl, "pool_pip_max", bg, centre.x, centre.y, radius, pd)
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
	var ids := PackedInt64Array()
	if moved > 0:
		var recs := rd.buffer_get_data(arena.buf(_cur("BUPS")), (_ds(dst, GpuLayout.DS_START) + before) * RB, moved * RB)
		for i in moved:
			ids.append(GpuLayout.id_of(recs, i))
	return {"new_row": dst, "moved": moved, "ids": ids}


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
## (IterationPlan) carries each dish's world events and the history samples. Returns {steps, overflow, record_usec, gpu_usec}.
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
	_ensure_room(steps, ev)
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
	_ensure_room(steps, ev)
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
	var bins := maxi(arena.bin_top, 1)
	_disp(cl, "pool_bin_clear", _groups(bins))
	_disp(cl, "pool_bin_count", hg)
	_scan(cl, "pool_bn", bins)
	_disp(cl, "pool_bin_cut", D_MAX / 64)
	_disp(cl, "pool_bin_cursor", _groups(bins))
	_disp(cl, "pool_bin_scatter", hg)
	_disp(cl, "pool_bin_sort", _groups(bins))
	_disp(cl, "pool_clear", cg)
	_disp(cl, "pool_puff_clear", hg)
	_disp(cl, "pool_swim", bg)
	_disp(cl, "pool_demand", bg)
	_disp(cl, "pool_cells", cg)
	_disp(cl, "pool_puff_scale", hg)
	_disp(cl, "pool_apply", bg)
	_disp(cl, "pool_puff_commit", hg)
	_disp(cl, "pool_ac_cells", cg)
	_disp(cl, "pool_ac_apply", bg)
	var buckets := GpuKernelsLife.conj_buckets(slots)
	_disp(cl, "pool_conj_clear", maxi(bg, _groups(buckets)))
	_disp(cl, "pool_conj_count", bg)
	_scan(cl, "pool_conj_scan", buckets)
	_disp(cl, "pool_conj_scatter", bg)
	_disp(cl, "pool_conj_apply", bg)
	_disp(cl, "pool_life", bg)
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
## `steps` doublings (a bup divides at most once a step, and never past its dish's cap), the event ring to the bound of its births, the
## clouds and husks to their tops and what the steps until their next compaction can append.
func _ensure_room(steps: int, ev: Dictionary) -> void:
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
	arena.ensure_slots(maxi(need, _wd(GpuLayout.WD_SLOTS)))
	var events := bound if bound < EVENT_EXACT_MOST else maxi(EVENT_EXACT_MOST, int(4.0 * maxf(_births_per_step, _deaths_per_step) * steps))
	if arena.ensure_events(maxi(events, EVENT_FLOOR)):
		_p[GpuLayout.p_slot("event_capacity")] = arena.event_cap
		_upload_p()
	var per_step := maxf(_deaths_per_step * 2.0, float(counted) / 50.0) + 1024.0
	var window := mini(steps, CLOUD_COMPACT_EVERY) + 1
	var world_clouds: int = (ev["puffs"] as PackedFloat32Array).size() / GpuLayout.EV_PUFF_FLOATS
	var appends := int(per_step * window) + world_clouds + _wd(GpuLayout.WD_HUSK_SLOTS) * window
	arena.ensure_clouds(_wd(GpuLayout.WD_CLOUD_SLOTS) + appends)
	arena.ensure_husks(_wd(GpuLayout.WD_HUSK_SLOTS) + int(per_step * (mini(steps, HUSK_CULL_EVERY) + 1)) + world_clouds)
	_after_growth()


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
	if not arena.ensure_slots(_wd(GpuLayout.WD_SLOTS) + _align(count)):
		return false
	arena.ensure_clouds(_wd(GpuLayout.WD_CLOUD_SLOTS) + clouds + 1024)
	arena.ensure_husks(_wd(GpuLayout.WD_HUSK_SLOTS) + husks + 1024)
	var cd := CoreDish.new()
	cd.spec = s
	cd.grid = grid
	cd.cells = cells
	cd.base = arena.alloc_cells(cells)
	cd.bins_across = bins_across
	cd.bins = bins
	cd.bin_base = arena.alloc_bins(bins)
	cd.cap = ((int(s.limit * 1.05) + 1024 + 255) / 256) * 256
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


## The live clouds (or husks) of `row` in pool order, word 5 made 1.0.
func _slots_of(row: int, buf_name: String, top_word: int, husks: bool) -> PackedFloat32Array:
	var top := _wd(top_word)
	var out := PackedFloat32Array()
	if top == 0:
		return out
	var raw := rd.buffer_get_data(arena.buf(buf_name), 0, top * 32)
	var word := GpuLayout.PUFF_ROW_BASE + row
	var f := raw.to_float32_array()
	for k in top:
		if raw.decode_u32((k * 8 + 5) * 4) != word:
			continue
		if husks and (f[k * 8 + 6] < 0.5 or int(f[k * 8 + 4]) >= GpuKernelsHusks.HUSK_PIECES):
			continue
		for j in 8:
			out.append(1.0 if j == 5 else f[k * 8 + j])
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
			var cells := PackedInt32Array()
			var amounts := PackedFloat32Array()
			cd.grid.deposit_xy(e.position.x, e.position.y, e.amount, cd.base, cells, amounts)
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


# ---- reading --------------------------------------------------------------------------------------------------------------------------

func running_rows() -> Array:
	var rows: Array = _dishes.keys()
	rows.sort()
	return rows


func spec_of(row: int) -> DishSpec:
	return (_dishes[row] as CoreDish).spec if _dishes.has(row) else null


func count(row: int) -> int:
	return _ds(row, GpuLayout.DS_COUNT)


## WORLD's overflow flag as read after the iterations so far (0: no physical overflow ever).
func overflow() -> int:
	return _overflow


## The dish's DSTATE row as read after the last sync.
func dstate_row(row: int) -> PackedByteArray:
	return _dstate.slice(row * GpuLayout.DS_WORDS * 4, (row + 1) * GpuLayout.DS_WORDS * 4)


func world_word(word: int) -> int:
	return _wd(word)


## The dish's records in its segment's order.
func records(row: int) -> PackedByteArray:
	var n := _ds(row, GpuLayout.DS_COUNT)
	if n == 0:
		return PackedByteArray()
	return rd.buffer_get_data(arena.buf(_cur("BUPS")), _ds(row, GpuLayout.DS_START) * RB, n * RB)


func live_ids(row: int) -> PackedInt64Array:
	var recs := records(row) if _dishes.has(row) else PackedByteArray()
	var ids := PackedInt64Array()
	for i in recs.size() / RB:
		ids.append(GpuLayout.id_of(recs, i))
	return ids


## What a dish is, word for word, for comparing two runs (tests/sim/canonical_dump.gd's sections): its records; its field (the glucose,
## the acetate, the deposits waiting); its live clouds and husks in pool order (word 5 1.0); its DSTATE row (the start 0: it is the pool's);
## its family events of the last iteration in ring order (births by the id's dish number, deaths by ED_STEP's); its stats now.
func canonical_dump(row: int) -> Dictionary:
	if not _stats_fresh:
		_refresh_stats()
	var cd: CoreDish = _dishes[row]
	var n2 := cd.grid.n * cd.grid.n
	var field := PackedByteArray()
	for nm in ["CONC", "CONC2", "DPLO", "DPHI"]:
		field.append_array(rd.buffer_get_data(arena.buf(nm), cd.base * 4, n2 * 4))
	var ds := dstate_row(row)
	ds.encode_u32(GpuLayout.DS_START * 4, 0)
	var ev := _events_of(row)
	return {
		"records": records(row),
		"field": field,
		"clouds": _slots_of(row, "PUFF", GpuLayout.WD_CLOUD_SLOTS, false).to_byte_array(),
		"husks": _slots_of(row, "HUSK", GpuLayout.WD_HUSK_SLOTS, true).to_byte_array(),
		"dstate": ds,
		"births": ev[0],
		"deaths": ev[1],
		"stats": rd.buffer_get_data(arena.buf("STATS"), row * GpuLayout.STATS_DISH_WORDS * 4, GpuLayout.STATS_WORDS * 4),
	}


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
	if tb > 0:
		var eb := rd.buffer_get_data(arena.buf("EVB"), 0, tb * bw)
		for k in tb:
			if (eb.decode_u32(k * bw + GpuLayout.EB_ID_HI * 4) >> GpuLayout.ID_HI_DISH_SHIFT) == number:
				births.append_array(eb.slice(k * bw, (k + 1) * bw))
	if td > 0:
		var ed := rd.buffer_get_data(arena.buf("EVD"), 0, td * dw)
		for k in td:
			if GpuLayout.death_dish_number(ed.decode_u32(k * dw + GpuLayout.ED_STEP * 4)) == number:
				deaths.append_array(ed.slice(k * dw, (k + 1) * dw))
	return [births, deaths]


# ---- publish ------------------------------------------------------------------------------------------------------------------------

## The main dish's pictures into the next free shared texture of each kind, after the iteration's sync: its payload and
## ids (bups after the last step), and when asked its field's haze and steering pictures and every dish's thumbnail. A texture is written
## only if the main side last bound it more than frame_queue_size + 1 frames ago (`texture_bound`); a kind with no free texture is not
## published this time. Returns kind -> the texture index written.
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
	var w := _free_texture("payload", Vector2i(GpuLayout.PAYLOAD_TEX_WIDTH, rows))
	var nn := cd.grid.n
	var fw := _free_texture("haze", Vector2i(nn, nn)) if view.want_field_view else -1
	var sw := _free_texture("steer", Vector2i(nn, nn)) if view.want_field_view else -1
	var tw := _free_texture("thumbs", Vector2i(GpuKernelsDraw.THUMB_ATLAS, GpuKernelsDraw.THUMB_ATLAS)) if view.want_thumbnails else -1
	if fw >= 0 or sw >= 0:
		arena.put_small("VQ", PackedFloat32Array([view.steer.x, view.steer.y, view.steer_alpha, float(_consts["steering_window"])]).to_byte_array())
		_free_sets_using(["VQ"])
	_run_list(func(cl: int) -> void:
		if w >= 0:
			_disp(cl, "pool_payload", _groups(texels), float(row))
			_copy(cl, "pool_copy_payload", {"PAYTEX": _textures["payload"][w], "IDS": _textures["ids"][w]}, GpuLayout.PAYLOAD_TEX_WIDTH, texels)
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
			_copy_pix(cl, "THUMBS", _textures["thumbs"][tw], GpuKernelsDraw.THUMB_ATLAS, GpuKernelsDraw.THUMB_ATLAS * GpuKernelsDraw.THUMB_ATLAS))
	for t: RID in _temp_sets:
		if rd.uniform_set_is_valid(t):
			rd.free_rid(t)
	_temp_sets.clear()
	for pair in [["payload", w], ["haze", fw], ["steer", sw], ["thumbs", tw]]:
		if pair[1] >= 0:
			_published[pair[0]] = pair[1]
			out[pair[0]] = pair[1]
	return out


## The main side bound texture `index` of `kind` on its frame `frame` (it tells the core, so a texture it may still read is not written).
func texture_bound(kind: String, index: int, frame: int) -> void:
	_frame = maxi(_frame, frame)
	if _texture_frames.has(kind):
		_texture_frames[kind][index] = frame


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
	var last: int = _published.get(kind, -1)
	for k in TEXTURES:
		var i := (last + 1 + k) % TEXTURES
		if i == last:
			continue
		if _frame - int(_texture_frames[kind][i]) > limits.frame_queue_size + 1:
			return i
	return -1


func _make_textures(kind: String, size: Vector2i) -> void:
	for t: RID in _textures.get(kind, []):
		if t.is_valid():
			rd.free_rid(t)
	_free_sets()
	var fmt := RDTextureFormat.new()
	fmt.width = size.x
	fmt.height = size.y
	fmt.format = {"payload": RenderingDevice.DATA_FORMAT_R32G32B32A32_UINT, "ids": RenderingDevice.DATA_FORMAT_R32G32_UINT}.get(kind, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var made: Array = []
	var frames: Array = []
	for k in TEXTURES:
		made.append(rd.texture_create(fmt, RDTextureView.new()))
		frames.append(-1000)
	_textures[kind] = made
	_texture_frames[kind] = frames
	_published.erase(kind)


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


func _run_list(rec: Callable) -> void:
	var cl := rd.compute_list_begin()
	rec.call(cl)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
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


## A new dish for a pipette's bups: the source's size, grid, limit and settings, a fresh medium, the next number.
func _receiver_spec(row: int) -> DishSpec:
	var s := (_dishes[row] as CoreDish).spec.copy()
	var most := 0
	for r: int in _dishes:
		most = maxi(most, (_dishes[r] as CoreDish).spec.number)
	s.number = most + 1
	s.seed = 0
	s.patch_seed = 0
	s.step = 0
	s.world = {}
	return s
