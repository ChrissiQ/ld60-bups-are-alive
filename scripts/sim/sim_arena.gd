class_name SimArena
extends RefCounted
## The pooled world's buffers, by the unit each grows with: record slots, field cells, cloud-list squares, cloud slots,
## husk slots, cloud-list entries, family events; and the fixed ones (the tables, the scans' scratch, the world's events). A class grows by 1.5 (or to what
## is asked, if more) by copying what it holds into new buffers on the device; it shrinks, at most once a minute, when it has used less
## than a quarter of its slots for that long, and never below the most that was asked of it while it was little used (`asked`), so room made ahead
## for the next iterations' worst case is kept and a class shrinks only when the need itself has fallen. `changed` tells the core to make its
## uniform sets again. The field cells and squares are handed out in blocks from first-fit free lists.

const GROW := 1.5
const FILL := 0.9  ## a class grows when what is asked passes this share of it
const SHRINK_BELOW := 0.25
const SHRINK_EVERY_MSEC := 60000
const SHORT_SHRINK_MSEC := 10000  ## how long a class must have been little used before it shrinks while the machine is short of memory
const SCAN_SCRATCH := 4096  ## words of a grid scan's group sums (GpuKernels.scan_groups' most)
const D_MAX := GpuLayout.D_MAX
const TILES_ACROSS_MOST := (StartConditions.MAX_NUTRIENT_RESOLUTION + GpuKernelsField.FIELD_TILE - 1) / GpuKernelsField.FIELD_TILE
const TILES_MOST := TILES_ACROSS_MOST * TILES_ACROSS_MOST  ## the field tiles of the biggest grid a dish has (pool_fdiff's TILES: a word a tile)

## name -> [class, bytes a unit, kept when it grows, fill (0 or 0xFF)]. A class's units: slots, blocks (slots / 256 + 1), buckets
## (GpuKernelsLife.conj_buckets(slots)), cells, bins, clouds, husks, entries, events, or 1 for a fixed buffer (its bytes).
const BUFFERS := {
	"BUPS": ["slot", GpuLayout.RECORD_BYTES, true, 0], "BUPS2": ["slot", GpuLayout.RECORD_BYTES, true, 0], "CHILD": ["slot", GpuLayout.RECORD_BYTES, false, 0],
	"SURV": ["slot", 4, false, 0], "KID": ["slot", 4, false, 0], "EXCS": ["slot", 4, false, 0], "EXCK": ["slot", 4, false, 0],
	"WANT": ["slot", 4, false, 0], "CELLOF": ["slot", 4, false, 0], "WANTC": ["slot", 4, false, 0], "WANT2": ["slot", 4, false, 0],
	"CELL2": ["slot", 4, false, 0], "CLOUDC": ["slot", 4, false, 0], "CBKT": ["slot", 4, false, 0], "DLIST": ["slot", 4, false, 0], "PIPDST": ["slot", 4, false, 0],
	"BLKDISH": ["block", 4, true, 0xFF], "BLKDISH2": ["block", 4, true, 0xFF], "SPART": ["block", GpuLayout.STATS_SUMS * 4, false, 0],
	"DCNT": ["bucket", 4, false, 0], "DOFF": ["bucket", 4, false, 0], "DBIT": ["bucketbits", 4, false, 0],
	"CONC": ["cell", 4, true, 0], "EFF": ["cell", 4, false, 0], "CONC2": ["cell", 4, true, 0], "CONC2B": ["cell", 4, false, 0],
	"OWNER": ["cell", 4, true, 0xFF], "INSIDE": ["cell", 4, true, 0], "WGT": ["cell", 4, true, 0], "CELLDISH": ["cell", 4, true, 0xFF],
	"DLO": ["cell", 4, false, 0], "DHI": ["cell", 4, false, 0], "RLO": ["cell", 4, false, 0], "RHI": ["cell", 4, false, 0],
	"ALO": ["cell", 4, false, 0], "AHI": ["cell", 4, false, 0], "SCALE": ["cell", 4, false, 0], "SCALE2": ["cell", 4, false, 0],
	"AWLO": ["cell", 4, true, 0], "AWHI": ["cell", 4, true, 0], "ADLO": ["cell", 4, true, 0], "ADHI": ["cell", 4, true, 0],
	"DPLO": ["cell", 4, true, 0], "DPHI": ["cell", 4, true, 0],
	"BINC": ["bin", 4, false, 0], "BINS": ["bin", 4, false, 0], "BCUR": ["bin", 4, false, 0],
	"PUFF": ["cloud", 32, true, 0], "PUFF2": ["cloud", 32, false, 0], "PDLO": ["cloud", 4, false, 0], "PDHI": ["cloud", 4, false, 0],
	"PSCALE": ["cloud", 4, false, 0], "PAL": ["cloud", 4, false, 0], "PEXC": ["cloud", 4, false, 0],
	"ENT": ["entry", 4, false, 0], "ENTD": ["entry", 32, false, 0],
	"HUSK": ["husk", 32, true, 0], "HUSK2": ["husk", 32, false, 0], "HDUE": ["husk", 4, false, 0], "HEXC": ["husk", 4, false, 0],
	"HAL": ["husk", 4, false, 0], "HKEEP": ["husk", 4, false, 0],
	"EVB": ["event", GpuLayout.BIRTH_WORDS * 4, false, 0], "EVD": ["event", GpuLayout.DEATH_WORDS * 4, false, 0],
	"P": ["fixed", GpuLayout.P_WORDS * 4, true, 0], "TABLE": ["fixed", 16, true, 0], "WORLD": ["fixed", GpuLayout.WD_WORDS * 4, true, 0],
	"DISHP": ["fixed", D_MAX * GpuLayout.DP_WORDS * 4, true, 0], "DSTATE": ["fixed", D_MAX * GpuLayout.DS_WORDS * 4, true, 0],
	"DNEXT": ["fixed", GpuKernelsLife.DNEXT_WORDS * 4, true, 0], "CBASE": ["fixed", (2 * D_MAX + 2) * 4, false, 0],
	"CLIVE": ["fixed", 2 * D_MAX * 4, true, 0], "STATS": ["fixed", D_MAX * GpuLayout.STATS_DISH_WORDS * 4, true, 0],
	"GSUM": ["fixed", SCAN_SCRATCH * 4, false, 0], "GOFF": ["fixed", SCAN_SCRATCH * 4, false, 0], "BSUM": ["fixed", SCAN_SCRATCH * 4, false, 0],
	"BOFF": ["fixed", SCAN_SCRATCH * 4, false, 0], "PSUM": ["fixed", SCAN_SCRATCH * 4, false, 0], "POFF": ["fixed", SCAN_SCRATCH * 4, false, 0],
	"HSUM": ["fixed", SCAN_SCRATCH * 4, false, 0], "HOFF": ["fixed", SCAN_SCRATCH * 4, false, 0],
	"EVR": ["fixed", GpuLayout.MAX_STEPS_PER_BATCH * 16, false, 0], "EVP": ["fixed", GpuLayout.EV_PUFFS_CAPACITY * GpuLayout.EV_PUFF_FLOATS * 4, false, 0],
	"EVCC": ["fixed", GpuLayout.EV_CELLS_CAPACITY * 4, false, 0], "EVCA": ["fixed", GpuLayout.EV_CELLS_CAPACITY * 4, false, 0],
	"TILES": ["fixed", D_MAX * TILES_MOST * 4, false, 0],
	"EDC": ["fixed", 16, false, 0], "EDA": ["fixed", 16, false, 0], "FRQ": ["fixed", 16, false, 0],
	"TQ": ["fixed", (1 + 2 * GpuLayout.TRACKED) * 4, false, 0], "TR": ["fixed", GpuLayout.TRACKED * GpuLayout.ANSWER_WORDS * 4, false, 0],
	"SPQ": ["fixed", SimCore.PROBES_MOST * 16, false, 0], "SPR": ["fixed", SimCore.PROBES_MOST * GpuLayout.PROBE_FLOATS * 4, false, 0],
	"HVC": ["fixed", 16, false, 0], "HNQ": ["fixed", GpuLayout.HUSK_QUERIES * 16, false, 0], "HNR": ["fixed", GpuLayout.HUSK_QUERIES * GpuLayout.HN_WORDS * 4, false, 0],
}

## The pictures' buffers, made when something is first published: name -> [class, bytes a unit] (classes "texel": the main dish's payload
## texels; "view": the pool's cells; "pixel": the main dish's cells; "fixed").
const DRAW_BUFFERS := {
	"PAYLOAD": ["texel", GpuLayout.PAYLOAD_BYTES], "IDTEX": ["texel", GpuLayout.IDT_BYTES], "VIEW": ["view", 4], "HAZEPIX": ["pixel", 4],
	"STEERPIX": ["pixel", 4], "VQ": ["fixed", 16],
	"THUMBN": ["fixed", D_MAX * GpuKernelsDraw.THUMB_TILE * GpuKernelsDraw.THUMB_TILE * 4], "THUMBMAX": ["fixed", D_MAX * 4],
	"THUMBS": ["fixed", GpuKernelsDraw.THUMB_ATLAS * GpuKernelsDraw.THUMB_ATLAS * 4],
}

var rd: RenderingDevice
var limits: PoolLimits
var bufs := {}  ## physical name -> RID (an alias maps a name to another's RID)
var sizes := {}  ## name -> bytes
var slot_cap := 0
var cell_cap := 0
var bin_cap := 0
var cloud_cap := 0
var husk_cap := 0
var entry_cap := 0  ## the cloud lists' entries: at least ENTRIES_PER_SLOT a cloud slot, more when the lists have asked for more
var event_cap := 0
var cell_top := 0  ## the end of the last field block in use
var bin_top := 0
var changed := false  ## buffers were made again since the core last looked
var shrink_after_msec := SHRINK_EVERY_MSEC  ## how long a class must have been little used before it shrinks (a check sets it lower)
var _cell_free: Array = []  ## [start, size] blocks below cell_top
var _bin_free: Array = []
var _low_since := {}  ## class -> msec since which it has used less than SHRINK_BELOW
var _texels := 0
var _pixels := 0
var growths := {}  ## class -> how many times it grew (the debug log's pool figures)
var asked := {}  ## class ("slot", "cloud", "husk", "entry") -> the most `ensure_*` was asked for it since it was last busy or shrunk: a shrink never goes below room for it


func _init(device: RenderingDevice, p_limits: PoolLimits) -> void:
	rd = device
	limits = p_limits


static func zeros(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	return b


func buf(nm: String) -> RID:
	return bufs[nm]


## Every buffer at the limits' sizes; `contents`: the fixed buffers' first contents (P, TABLE).
func make_all(contents: Dictionary) -> void:
	slot_cap = _align(limits.world_slots)
	cell_cap = _align(limits.field_cells)
	bin_cap = maxi(limits.bins, 256)
	cloud_cap = maxi(limits.cloud_slots, 256)
	husk_cap = maxi(limits.husk_slots, 256)
	entry_cap = GpuKernelsClouds.ENTRIES_PER_SLOT * cloud_cap
	event_cap = SimCore.EVENT_FLOOR
	for nm: String in BUFFERS:
		_make(nm, _bytes_of(nm), false)
	for nm: String in contents:
		var b: PackedByteArray = contents[nm]
		if b.size() > sizes[nm]:
			_make_sized(nm, b.size(), false)
		rd.buffer_update(bufs[nm], 0, b.size(), b)
	changed = true


func _bytes_of(nm: String) -> int:
	var e: Array = BUFFERS[nm] if BUFFERS.has(nm) else DRAW_BUFFERS[nm]
	var unit: int = e[1]
	match e[0]:
		"slot": return slot_cap * unit
		"block": return (slot_cap / GpuLayout.BLK_SLOTS + 1) * unit
		"bucket": return GpuKernelsLife.conj_buckets(slot_cap) * unit
		"bucketbits": return (GpuKernelsLife.conj_buckets(slot_cap) / 32 + 1) * unit
		"cell": return cell_cap * unit
		"bin": return bin_cap * unit
		"cloud": return cloud_cap * unit
		"entry": return entry_cap * unit
		"husk": return husk_cap * unit
		"event": return event_cap * unit
		"texel": return _texels * unit
		"view": return cell_cap * unit
		"pixel": return _pixels * unit
	return unit


func _make(nm: String, n_bytes: int, keep: bool) -> void:
	_make_sized(nm, n_bytes, keep)


## Makes `nm` anew with `n_bytes` (at least 16, whole words), filled with its fill byte, and when `keep` with what the old one held copied
## into its start.
func _make_sized(nm: String, n_bytes: int, keep: bool) -> void:
	n_bytes = maxi(16, ((n_bytes + 15) / 16) * 16)
	var e: Array = BUFFERS[nm] if BUFFERS.has(nm) else DRAW_BUFFERS[nm]
	var fill: int = e[3] if e.size() > 3 else 0
	var rid := rd.storage_buffer_create(n_bytes)
	if fill == 0:
		rd.buffer_clear(rid, 0, n_bytes)
	else:
		var pattern := PackedByteArray()
		pattern.resize(n_bytes)
		pattern.fill(fill)
		rd.buffer_update(rid, 0, n_bytes, pattern)
	var old: RID = bufs.get(nm, RID())
	if old.is_valid():
		if keep:
			rd.buffer_copy(old, rid, 0, 0, mini(sizes[nm], n_bytes))
		rd.free_rid(old)
	bufs[nm] = rid
	sizes[nm] = n_bytes
	for alias_name: String in bufs.keys():
		if _aliases.get(alias_name, "") == nm:
			bufs[alias_name] = rid
	changed = true


## Every buffer of `classes` at their new capacities, the kept ones copied.
func _remake(classes: Array) -> void:
	for nm: String in BUFFERS:
		var e: Array = BUFFERS[nm]
		if classes.has(e[0]):
			_make(nm, _bytes_of(nm), e[2])
	for nm: String in DRAW_BUFFERS:
		if bufs.has(nm) and classes.has(DRAW_BUFFERS[nm][0]):
			_make(nm, _bytes_of(nm), false)


## The slot capacity `ensure_slots(slots)` would make: the one now when `slots` are within FILL of it, the grown one when that fits the
## budget (by GROW or what is asked, else just what is asked), 0 when none does.
func slot_cap_for(slots: int) -> int:
	if slots <= int(FILL * slot_cap):
		return slot_cap
	var want := _align(maxi(ceili(slots / FILL), int(slot_cap * GROW)))
	if not fits(want, 0, 0, 0, 0):
		want = _align(slots)
		if not fits(want, 0, 0, 0, 0):
			return 0
	return want


## Room for `slots` record slots; false when that would pass the budget.
func ensure_slots(slots: int) -> bool:
	asked["slot"] = maxi(int(asked.get("slot", 0)), slots)
	var want := slot_cap_for(slots)
	if want == 0:
		return false
	if want != slot_cap:
		slot_cap = want
		_grew("slot")
		_remake(["slot", "block", "bucket", "bucketbits"])
	return true


## Room for `slots` record slots made ahead of the need: grown only when the buffers afterwards hold at most `share` of the budget
## (so the growth never takes the room a later one may need, or reaches the warning), else nothing is done. True when it grew.
func pre_grow_slots(slots: int, share: float) -> bool:
	var want := slot_cap_for(slots)
	if want == 0 or want == slot_cap:
		return false
	if estimate_bytes(want, cell_cap, bin_cap, cloud_cap, husk_cap) > share * limits.memory_budget_bytes:
		return false
	return ensure_slots(slots)


## Room for `clouds` cloud slots; false when that would pass the budget.
func ensure_clouds(clouds: int) -> bool:
	asked["cloud"] = maxi(int(asked.get("cloud", 0)), clouds)
	if clouds <= int(FILL * cloud_cap):
		return true
	var want := maxi(ceili(clouds / FILL), int(cloud_cap * GROW))
	if not fits(0, 0, 0, want, 0):
		want = clouds
		if not fits(0, 0, 0, want, 0):
			return false
	cloud_cap = want
	entry_cap = maxi(entry_cap, GpuKernelsClouds.ENTRIES_PER_SLOT * cloud_cap)
	_grew("cloud")
	_remake(["cloud", "entry"])
	return true


## The entries the lists need for `slots` cloud slots at `density` entries a slot (what the bin scan measured, with room to grow).
static func entries_for(slots: int, density: int) -> int:
	return maxi(GpuKernelsClouds.ENTRIES_PER_SLOT, density) * slots


## Room for `entries` list entries; false when growing would pass the budget (the lists then keep what they have: the kernel cuts the
## lists that do not fit and raises the overflow flag).
func ensure_entries(entries: int) -> bool:
	asked["entry"] = maxi(int(asked.get("entry", 0)), entries)
	if entries <= int(FILL * entry_cap):
		return true
	var want := maxi(ceili(entries / FILL), int(entry_cap * GROW))
	if not fits(0, 0, 0, 0, 0, 0, want):
		want = entries
		if not fits(0, 0, 0, 0, 0, 0, want):
			return false
	entry_cap = want
	_grew("entry")
	_remake(["entry"])
	return true


## Room for `husks` husk slots; false when that would pass the budget.
func ensure_husks(husks: int) -> bool:
	asked["husk"] = maxi(int(asked.get("husk", 0)), husks)
	if husks <= int(FILL * husk_cap):
		return true
	var want := maxi(ceili(husks / FILL), int(husk_cap * GROW))
	if not fits(0, 0, 0, 0, want):
		want = husks
		if not fits(0, 0, 0, 0, want):
			return false
	husk_cap = want
	_grew("husk")
	_remake(["husk"])
	return true


## Room for `events` births (and deaths) in an iteration: 1 when the ring was made again, 0 when it was big enough, -1 when it would
## pass the budget.
func ensure_events(events: int) -> int:
	if events <= event_cap:
		return 0
	var want := maxi(events, int(event_cap * GROW))
	if not fits(0, 0, 0, 0, 0, want):
		want = events
		if not fits(0, 0, 0, 0, 0, want):
			return -1
	event_cap = want
	_grew("event")
	_remake(["event"])
	return 1


## The pictures' buffers for a payload of `texels` and a field of `pixels` cells.
func ensure_draw(texels: int, pixels: int) -> void:
	var grow := not bufs.has("PAYLOAD") or texels > _texels or pixels > _pixels
	if not grow:
		return
	_texels = maxi(texels, _texels)
	_pixels = maxi(pixels, _pixels)
	_grew("draw")
	for nm: String in DRAW_BUFFERS:
		_make(nm, _bytes_of(nm), false)


## Writes `bytes` to the small fixed buffer `nm`, making it larger first when it must be.
func put_small(nm: String, bytes: PackedByteArray) -> void:
	if bytes.size() > sizes.get(nm, 0):
		_make_sized(nm, bytes.size() * 2, false)
	rd.buffer_update(bufs[nm], 0, bytes.size(), bytes)


var _aliases := {}


## `nm` binds what `target` binds (a copy kernel's one source, say).
func alias(nm: String, target: String) -> void:
	_aliases[nm] = target
	bufs[nm] = bufs[target]


## A block of `cells` field cells (256-aligned); grows the cell buffers when the free list has none.
func alloc_cells(cells: int) -> int:
	var at := _take(_cell_free, cells)
	if at < 0:
		at = cell_top
		cell_top += cells
		if cell_top > cell_cap:
			_grew("cell")
			cell_cap = _align(maxi(cell_top, int(cell_cap * GROW)))
			_remake(["cell", "view"])
	return at


func free_cells(at: int, cells: int) -> void:
	_give(_cell_free, at, cells)
	cell_top = _trim(_cell_free, cell_top)


func alloc_bins(n: int) -> int:
	var at := _take(_bin_free, n)
	if at < 0:
		at = bin_top
		bin_top += n
		if bin_top > bin_cap:
			_grew("bin")
			bin_cap = maxi(bin_top, int(bin_cap * GROW))
			_remake(["bin"])
	return at


func free_bins(at: int, n: int) -> void:
	_give(_bin_free, at, n)
	bin_top = _trim(_bin_free, bin_top)


## First fit: the start of a free block of `size` (the block shrinks by it), or -1.
static func _take(free: Array, size: int) -> int:
	for k in free.size():
		var b: Array = free[k]
		if b[1] >= size:
			var at: int = b[0]
			if b[1] == size:
				free.remove_at(k)
			else:
				free[k] = [b[0] + size, b[1] - size]
			return at
	return -1


## A freed block back into the list (kept in order, neighbours merged).
static func _give(free: Array, at: int, size: int) -> void:
	free.append([at, size])
	free.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var k := 0
	while k + 1 < free.size():
		if free[k][0] + free[k][1] == free[k + 1][0]:
			free[k] = [free[k][0], free[k][1] + free[k + 1][1]]
			free.remove_at(k + 1)
		else:
			k += 1


## The new top after a free: a free block that ends at the top is given back.
static func _trim(free: Array, top: int) -> int:
	if not free.is_empty() and free[-1][0] + free[-1][1] == top:
		var t: int = free[-1][0]
		free.remove_at(free.size() - 1)
		return t
	return top


## Whether the pool with these capacities (slots, clouds, husks, events and entries: the most of these and the single-dish path's; cells and bins: more than
## the single-dish path's) stays within the memory budget.
func fits(slots: int, cells: int, bins: int, clouds: int, husks: int, events := 0, entries := 0) -> bool:
	if limits.watch != null:
		limits.watch.before_growth(Time.get_ticks_msec(), bytes_now())  # (the free memory is read again before room is made, at most once a second)
	var cloud_room := maxi(clouds, cloud_cap)
	return estimate_bytes(maxi(slots, slot_cap), cell_cap + cells, bin_cap + bins, cloud_room, maxi(husks, husk_cap), maxi(events, event_cap), maxi(entries, maxi(entry_cap, GpuKernelsClouds.ENTRIES_PER_SLOT * cloud_room))) <= limits.memory_budget_bytes


## The bytes the buffers take at these capacities.
func estimate_bytes(slots: int, cells: int, bins: int, clouds: int, husks: int, events := -1, entries := -1) -> int:
	if events < 0:
		events = event_cap
	if entries < 0:
		entries = maxi(entry_cap, GpuKernelsClouds.ENTRIES_PER_SLOT * clouds)
	var total := 0
	for nm: String in BUFFERS:
		var e: Array = BUFFERS[nm]
		var unit: int = e[1]
		match e[0]:
			"slot": total += slots * unit
			"block": total += (slots / GpuLayout.BLK_SLOTS + 1) * unit
			"bucket": total += GpuKernelsLife.conj_buckets(slots) * unit
			"bucketbits": total += (GpuKernelsLife.conj_buckets(slots) / 32 + 1) * unit
			"cell": total += cells * unit
			"bin": total += bins * unit
			"cloud": total += clouds * unit
			"husk": total += husks * unit
			"entry": total += entries * unit
			"event": total += events * unit
			_: total += sizes.get(nm, unit)
	return total


## The bytes the buffers take now.
func bytes_now() -> int:
	var total := 0
	for nm: String in sizes:
		total += sizes[nm]
	return total


## The share of the memory budget the buffers hold now.
func memory_fraction() -> float:
	return float(bytes_now()) / maxf(float(limits.memory_budget_bytes), 1.0)


## The bytes the record slots' next growth would add (by GROW, as `ensure_slots` grows them first).
func next_growth_bytes() -> int:
	return estimate_bytes(_align(int(slot_cap * GROW)), cell_cap, bin_cap, cloud_cap, husk_cap) - estimate_bytes(slot_cap, cell_cap, bin_cap, cloud_cap, husk_cap)


## The capacities, the bytes held, the budget, the share of it held, the next growth's bytes and the growths so far (for the debug log).
func report() -> Dictionary:
	return {"fraction": memory_fraction(), "next_growth_bytes": next_growth_bytes(), "slots": slot_cap, "cells": cell_cap, "bins": bin_cap, "clouds": cloud_cap, "husks": husk_cap, "entries": entry_cap, "events": event_cap,
		"bytes": bytes_now(), "budget_bytes": limits.memory_budget_bytes, "growths": growths.duplicate()}


func _grew(klass: String) -> void:
	growths[klass] = int(growths.get(klass, 0)) + 1


## Shrinks a class that has used less than a quarter of its slots for a minute (at least to the limits' size and to the room for what
## most `ensure_*` asked of it in that time, so the next iteration does not grow it back; at most once a minute).
func maybe_shrink(slots: int, clouds: int, husks: int, entries := 0) -> void:
	var now := Time.get_ticks_msec()
	for pair in [["slot", slots, slot_cap, limits.world_slots], ["cloud", clouds, cloud_cap, limits.cloud_slots], ["husk", husks, husk_cap, limits.husk_slots], ["entry", entries, entry_cap, 0]]:
		var cls: String = pair[0]
		var used: int = pair[1]
		var cap: int = pair[2]
		var floor_cap: int = GpuKernelsClouds.ENTRIES_PER_SLOT * cloud_cap if cls == "entry" else int(pair[3])  # (the entries' floor follows the clouds, which may have shrunk just now)
		var least: int = maxi(floor_cap, ceili(int(asked.get(cls, 0)) / FILL))
		if cls == "slot":
			least = _align(least)
		if used >= SHRINK_BELOW * cap or cap <= least:
			_low_since.erase(cls)
			asked[cls] = 0
			continue
		if not _low_since.has(cls):
			_low_since[cls] = now
			asked[cls] = 0
			continue
		if now - int(_low_since[cls]) < shrink_after_msec:
			continue
		_low_since[cls] = now
		asked[cls] = 0
		var to := maxi(least, used * 2)
		match cls:
			"slot":
				slot_cap = _align(to)
				_remake(["slot", "block", "bucket", "bucketbits"])
			"cloud":
				cloud_cap = to
				_remake(["cloud"])
			"husk":
				husk_cap = to
				_remake(["husk"])
			"entry":
				entry_cap = to
				_remake(["entry"])


func free_all() -> void:
	var freed := {}
	for nm: String in bufs:
		var r: RID = bufs[nm]
		if r.is_valid() and not freed.has(r.get_id()):
			freed[r.get_id()] = true
			rd.free_rid(r)
	bufs.clear()
	sizes.clear()


static func _align(v: int) -> int:
	return ((v + GpuLayout.BLK_SLOTS - 1) / GpuLayout.BLK_SLOTS) * GpuLayout.BLK_SLOTS
