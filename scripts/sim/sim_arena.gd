class_name SimArena
extends RefCounted
## The pooled world's buffers, by the unit each grows with: record slots, field cells, cloud-list squares, cloud slots,
## husk slots, family events; and the fixed ones (the tables, the scans' scratch, the world's events). A class grows by 1.5 (or to what
## is asked, if more) by copying what it holds into new buffers on the device; it shrinks, at most once a minute, when it has used less
## than a quarter of its slots for that long. `changed` tells the core to make its uniform sets again. The field cells and squares are
## handed out in blocks from first-fit free lists.

const GROW := 1.5
const FILL := 0.9  ## a class grows when what is asked passes this share of it
const SHRINK_BELOW := 0.25
const SHRINK_EVERY_MSEC := 60000
const SCAN_SCRATCH := 4096  ## words of a grid scan's group sums (GpuKernels.scan_groups' most)
const D_MAX := GpuLayout.D_MAX

## name -> [class, bytes a unit, kept when it grows, fill (0 or 0xFF)]. A class's units: slots, blocks (slots / 256 + 1), buckets
## (GpuKernelsLife.conj_buckets(slots)), cells, bins, clouds, husks, events, or 1 for a fixed buffer (its bytes).
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
	"ENT": ["cloud", GpuKernelsClouds.ENTRIES_PER_SLOT * 4, false, 0], "ENTD": ["cloud", GpuKernelsClouds.ENTRIES_PER_SLOT * 32, false, 0],
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
	"EDC": ["fixed", 16, false, 0], "EDA": ["fixed", 16, false, 0], "FRQ": ["fixed", 16, false, 0],
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


## Room for `slots` record slots; false when that would pass the budget.
func ensure_slots(slots: int) -> bool:
	if slots <= int(FILL * slot_cap):
		return true
	var want := _align(maxi(ceili(slots / FILL), int(slot_cap * GROW)))
	if not fits(want, 0, 0, 0, 0):
		want = _align(slots)
		if not fits(want, 0, 0, 0, 0):
			return false
	slot_cap = want
	_remake(["slot", "block", "bucket", "bucketbits"])
	return true


## Room for `clouds` cloud slots; false when that would pass the budget.
func ensure_clouds(clouds: int) -> bool:
	if clouds <= int(FILL * cloud_cap):
		return true
	var want := maxi(ceili(clouds / FILL), int(cloud_cap * GROW))
	if not fits(0, 0, 0, want, 0):
		want = clouds
		if not fits(0, 0, 0, want, 0):
			return false
	cloud_cap = want
	_remake(["cloud"])
	return true


## Room for `husks` husk slots; false when that would pass the budget.
func ensure_husks(husks: int) -> bool:
	if husks <= int(FILL * husk_cap):
		return true
	var want := maxi(ceili(husks / FILL), int(husk_cap * GROW))
	if not fits(0, 0, 0, 0, want):
		want = husks
		if not fits(0, 0, 0, 0, want):
			return false
	husk_cap = want
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
	_remake(["event"])
	return 1


## The pictures' buffers for a payload of `texels` and a field of `pixels` cells.
func ensure_draw(texels: int, pixels: int) -> void:
	var grow := not bufs.has("PAYLOAD") or texels > _texels or pixels > _pixels
	if not grow:
		return
	_texels = maxi(texels, _texels)
	_pixels = maxi(pixels, _pixels)
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


## Whether the pool with these capacities (slots, clouds, husks and events: the most of these and the single-dish path's; cells and bins: more than
## the single-dish path's) stays within the memory budget.
func fits(slots: int, cells: int, bins: int, clouds: int, husks: int, events := 0) -> bool:
	return estimate_bytes(maxi(slots, slot_cap), cell_cap + cells, bin_cap + bins, maxi(clouds, cloud_cap), maxi(husks, husk_cap), maxi(events, event_cap)) <= limits.memory_budget_bytes


## The bytes the buffers take at these capacities.
func estimate_bytes(slots: int, cells: int, bins: int, clouds: int, husks: int, events := -1) -> int:
	if events < 0:
		events = event_cap
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
			"event": total += events * unit
			_: total += sizes.get(nm, unit)
	return total


## The bytes the buffers take now.
func bytes_now() -> int:
	var total := 0
	for nm: String in sizes:
		total += sizes[nm]
	return total


## Shrinks a class that has used less than a quarter of its slots for a minute (at least to the limits' size, at most once a minute).
func maybe_shrink(slots: int, clouds: int, husks: int) -> void:
	var now := Time.get_ticks_msec()
	for pair in [["slot", slots, slot_cap, limits.world_slots], ["cloud", clouds, cloud_cap, limits.cloud_slots], ["husk", husks, husk_cap, limits.husk_slots]]:
		var cls: String = pair[0]
		var used: int = pair[1]
		var cap: int = pair[2]
		var least: int = pair[3]
		if used >= SHRINK_BELOW * cap or cap <= least:
			_low_since.erase(cls)
			continue
		if not _low_since.has(cls):
			_low_since[cls] = now
			continue
		if now - int(_low_since[cls]) < shrink_after_msec:
			continue
		_low_since[cls] = now
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
