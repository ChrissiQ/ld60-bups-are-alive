class_name SimArena
extends RefCounted
## The pooled world's buffers, by the unit each grows with: record slots, field cells, cloud-list squares, cloud slots,
## husk slots, cloud-list entries, family events; and the fixed ones (the tables, the scans' scratch, the world's events). A class grows by 1.5 (or to what
## is asked, if more) by copying what it holds into new buffers on the device; when 1.5 does not fit it grows once to the most that does, and
## a growth never makes a class smaller. A class shrinks, at most once a minute, when it has used less
## than a quarter of its slots for that long, and never below the most that was asked of it while it was little used (`asked`), so room made ahead
## for the next iterations' worst case is kept and a class shrinks only when the need itself has fallen. `changed` tells the core to make its
## uniform sets again. The field cells and squares are handed out in blocks from first-fit free lists.
##
## A remake (`_remake`) on a local device releases before it allocates: the buffers that are not kept are freed and flushed first, each kept
## buffer is made, copied and its old one freed and flushed, and the rest are made last, so the device never holds a class's old and new
## buffers together beyond one kept buffer's. `fits` checks the peak of that sequence, not only the final size. A device frees a buffer only when
## its commands are submitted and waited for (`_flush`), so without the flushes the old buffers would stay allocated until the next iteration ends.

const GROW := 1.5
## The most one buffer may take: the least any backend promises. Direct3D 12 documents 2048 MB as the largest resource (the C term of its
## resource-size limit: min(max(128, a quarter of the video memory), 2048) MB); Vulkan's `maxStorageBufferRange` is often 4 GiB - 1 and
## 1 GiB on older cards, and the size of a RenderingDevice buffer is a 32-bit integer; Metal's `maxBufferLength` is read from the device
## (at least 256 MB). A growth that would make a class's buffer bigger is refused like one that passes the memory budget (`fits`).
const BUFFER_MOST := 2 * 1024 * 1024 * 1024
const FILL := 0.9  ## a class grows when what is asked passes this share of it
const SHRINK_BELOW := 0.25
const SHRINK_EVERY_MSEC := 60000
const SHORT_SHRINK_MSEC := 10000  ## how long a class must have been little used before it shrinks while the machine is short of memory
const SCAN_SCRATCH := 4096  ## words of a grid scan's group sums (GpuKernels.scan_groups' most)
const SLOT_CLASSES := ["slot", "block", "bucket", "bucketbits"]  ## the classes `slot_cap` sizes
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
	"BMARK": ["bin", 4, false, 0], "BMARK2": ["bin", 4, false, 0], "BINDISH": ["bin", 4, true, 0xFF],
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
	"EDC": ["fixed", 16, false, 0], "EDA": ["fixed", 16, false, 0], "FRQ": ["fixed", GpuLayout.ANSWER_SETS * GpuLayout.FRACTIONS * 4, false, 0],
	"TQ": ["fixed", GpuLayout.TRACK_SETS * GpuLayout.TQ_WORDS * 4, false, 0], "TR": ["fixed", GpuLayout.TRACK_SETS * GpuLayout.TRACKED * GpuLayout.ANSWER_BYTES, false, 0],
	"SPQ": ["fixed", GpuLayout.ANSWER_SETS * GpuLayout.PROBES_MOST * 16, false, 0], "SPR": ["fixed", GpuLayout.ANSWER_SETS * GpuLayout.PROBES_MOST * GpuLayout.PROBE_FLOATS * 4, false, 0],
	"HVC": ["fixed", 16, false, 0], "HNQ": ["fixed", GpuLayout.ANSWER_SETS * GpuLayout.HUSK_QUERIES * 16, false, 0], "HNR": ["fixed", GpuLayout.ANSWER_SETS * GpuLayout.HUSK_QUERIES * GpuLayout.HN_WORDS * 4, false, 0],
}

## The pictures' buffers, made when something is first published: name -> [class, bytes a unit] (classes "slot texel": the main dish's
## payload texels, `picture_slots()` times over; "view": the pool's cells; "pixel": the main dish's cells; "fixed").
const DRAW_BUFFERS := {
	"PAYLOAD": ["slot texel", GpuLayout.PAYLOAD_BYTES], "IDTEX": ["slot texel", GpuLayout.IDT_BYTES], "PICN": ["fixed", GpuLayout.PICTURES_MOST * 4],
	"PREVXY": ["slot texel", GpuLayout.PV_BYTES], "SLOTHEAD": ["fixed", (GpuLayout.PICTURES_MOST + 1) * GpuLayout.SH_WORDS * 4],
	"VIEW": ["view", 4], "HAZEPIX": ["pixel", 4],
	"STEERPIX": ["pixel", 4], "FAINTLO": ["pixel", 4], "FAINTHI": ["pixel", 4], "VQ": ["fixed", 16],
	"THUMBN": ["fixed", D_MAX * GpuKernelsDraw.THUMB_TILE * GpuKernelsDraw.THUMB_TILE * 4], "THUMBMAX": ["fixed", D_MAX * 4],
	"THUMBS": ["fixed", GpuKernelsDraw.THUMB_ATLAS * GpuKernelsDraw.THUMB_ATLAS * 4],
}

## What the pictures take besides DRAW_BUFFERS, as [class, bytes a unit] (the classes of DRAW_BUFFERS; "fixed": the bytes), by how the pictures
## reach the main device (`cpu_handover`, SimCore.cpu_handover). Both devices draw on the one graphics memory, so both are counted.
## "thumbs" is a fixed size, there once the thumbnails have been asked for (`thumbs`: with a second dish running).
## Shared textures: `SimCore.ring_of(kind)` of each kind on the simulation's device (the main device imports them without a copy), one of
## each haze, steer and thumbnail picture the main device draws, and the main device's per-texel buffer of the view kernels.
const TEXTURES_SHARED := [
	["texel", (GpuLayout.PAYLOAD_BYTES + GpuLayout.IDS_BYTES) * SimCore.PAYLOAD_TEXTURES],  # payload, and ids with the places before
	["texel", 4],  # ViewRenderer's VPD
	["pixel", 2 * 4 * (SimCore.TEXTURES + 1)],  # haze and steer
	["thumbs", GpuKernelsDraw.THUMB_ATLAS * GpuKernelsDraw.THUMB_ATLAS * 4 * (SimCore.TEXTURES + 1)],  # thumbnails
]
## Handed over as bytes (besides the extra slots of PAYLOAD, IDTEX and PREVXY, `picture_slots`): the simulation's copies of the last
## payloads' ids (SimCore.ID_RING of them), and on the main device the payload texture and the ids' texture (which holds the places before
## and no ids) with the buffers that fill them, the view kernels' buffer and the pictures it draws.
const TEXTURES_HANDED := [
	["texel", GpuLayout.IDT_BYTES * SimCore.ID_RING],  # the ids kept
	["texel", 2 * GpuLayout.PAYLOAD_BYTES + GpuLayout.IDS_BYTES + GpuLayout.PV_BYTES],  # textures and the staging buffers
	["texel", 4],  # ViewRenderer's VPD
	["pixel", 2 * 4],  # haze and steer, drawn
	["thumbs", GpuKernelsDraw.THUMB_ATLAS * GpuKernelsDraw.THUMB_ATLAS * 4],  # thumbnails, drawn
]

var rd: RenderingDevice
var limits: PoolLimits
var local := true  ## `rd` is a local device, which the arena may submit and wait for (`_flush`); never the main device, whose frame submits
var cpu_handover := false  ## the pictures reach the main device as bytes, not as shared textures: which textures are counted
var thumbs := false  ## the thumbnails' atlas has been asked for, so its textures are made and counted
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
var _event_shrink_to := 0  ## the ring's size `ensure_events` makes it at the next iteration's start (0: none)
var _texels := 0
var _pixels := 0
var _slots_made := 0  ## `picture_slots()` when the pictures' buffers were last made
var growths := {}  ## class -> how many times it grew (the debug log's pool figures)
var shrinks := {}  ## class -> how many times it was made smaller (a growth never counts here, and a shrink never counts as a growth)
var flushes := 0  ## submits and waits `_flush` made (a count for tests and the debug log; nothing counts per step)
var _remaking := false  ## inside `_remake`: buffers are released and not yet all made, so the memory watch is not read
var asked := {}  ## class ("slot", "cloud", "husk", "entry", "event") -> the most `ensure_*` was asked for it since it was last busy or shrunk: a shrink never goes below room for it


## `p_local` false for the main device (`SimCore` says so when it is given that device): the arena then remakes in the order a frame allows
## and never submits or waits.
func _init(device: RenderingDevice, p_limits: PoolLimits, p_local := true) -> void:
	rd = device
	limits = p_limits
	local = p_local


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
		"slot texel": return _texels * unit * picture_slots()
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


## Frees the buffer `nm` (and the names that alias it) without making another: for a buffer whose contents are not kept, released before
## the rest of its class is made so that its memory is free for them.
func _release(nm: String) -> void:
	var old: RID = bufs.get(nm, RID())
	if not old.is_valid():
		return
	rd.free_rid(old)
	bufs[nm] = RID()
	for alias_name: String in bufs.keys():
		if _aliases.get(alias_name, "") == nm:
			bufs[alias_name] = RID()


## Submits what was recorded and waits for it, so that what was freed is released and what was copied is done. Only on a local device: the
## main device's frame submits, and a call here would break it. This is the one place a remake waits on the device.
## A backend whose fence wait can time out (Metal's is one second) returns from `sync` with the work unfinished, so a flush there must have its
## completion confirmed before anything else is recorded (the same confirmation an iteration's wait needs); that check belongs here.
func _flush() -> void:
	if not local or rd == null:
		return
	flushes += 1
	rd.submit()
	rd.sync()


## Every buffer of `classes` at their new capacities, the kept ones copied. On a local device the old buffers are released before the new
## ones are made: (1) the buffers that are not kept are freed and flushed; (2) each kept buffer is made, copied into, its old one freed,
## and flushed; (3) the buffers that are not kept are made at their new size, and flushed. The device then holds at most the class's
## new total at the end and, before that, its other buffers plus the kept ones' old and new copies of one buffer (`_sequence_peak`).
## On the main device the buffers are made one by one and freed as they are replaced (the frame frees them later).
func _remake(classes: Array) -> void:
	_remaking = true
	if not local or rd == null:
		for nm: String in BUFFERS:
			var e: Array = BUFFERS[nm]
			if classes.has(e[0]):
				_make(nm, _bytes_of(nm), e[2])
		for nm: String in DRAW_BUFFERS:
			if bufs.has(nm) and classes.has(DRAW_BUFFERS[nm][0]):
				_make(nm, _bytes_of(nm), false)
		_remaking = false
		return
	var kept: Array[String] = []
	var scratch: Array[String] = []
	for nm: String in BUFFERS:
		var e: Array = BUFFERS[nm]
		if classes.has(e[0]):
			(kept if e[2] else scratch).append(nm)
	for nm: String in DRAW_BUFFERS:
		if bufs.has(nm) and classes.has(DRAW_BUFFERS[nm][0]):
			scratch.append(nm)
	for nm in scratch:
		_release(nm)
	_flush()
	for nm in kept:
		_make(nm, _bytes_of(nm), true)
		_flush()
	for nm in scratch:
		_make(nm, _bytes_of(nm), false)
	_flush()
	_remaking = false


## The slot capacity `ensure_slots(slots, most, reserve)` would make: the one now when `slots` are within FILL of it, the grown one when that
## fits the budget (by GROW, but not past room for `most` slots (0: no bound), the most the slots can ever need, or what is asked if that is
## more). When that does not fit: the capacity now if `slots` are within it (a growth never makes a class smaller), else the most that fits
## between what is asked and the grown one (`_most_that_fits`, with `reserve` kept for the classes that grow after the slots), 0 when not
## even what is asked fits.
func slot_cap_for(slots: int, most := 0, reserve := {}) -> int:
	var target := _slot_target(slots, most)
	if target == slot_cap or fits(target, 0, 0, 0, 0):
		return target
	if slots <= slot_cap:
		return slot_cap
	return _most_that_fits(_align(slots), target, GpuLayout.BLK_SLOTS,
			func(c: int) -> bool: return _fits(c, 0, 0, _reserved(reserve, "cloud"), _reserved(reserve, "husk"), _reserved(reserve, "event"), _reserved(reserve, "entry")),
			func(c: int) -> bool: return _fits(c, 0, 0, 0, 0))


## The capacity a growth for `slots` aims at: the one now when `slots` are within FILL of it, else GROW times it (not past room for `most`) or
## room for `slots`, whichever is more.
func _slot_target(slots: int, most: int) -> int:
	if slots <= int(FILL * slot_cap):
		return slot_cap
	var grown := int(slot_cap * GROW)
	if most > 0:
		grown = mini(grown, ceili(most / FILL))
	return _align(maxi(ceili(slots / FILL), grown))


## What `reserve` (`caps_for`'s capacities, or none) holds for class `cls`: the room a class that grows after the one being grown is asked for
## this iteration, which the growth leaves free.
static func _reserved(reserve: Dictionary, cls: String) -> int:
	return int(reserve.get(cls, 0))


## The largest capacity under `target` (`target` itself did not fit), a multiple of `unit`, that is at least `ask` and that `probe` takes
## (the budget with the room kept for the classes that grow next); when not even `ask` fits with that room, `ask` if `plain` takes it
## (the budget alone); else 0. One growth to the most that fits ends the growing against a budget: a class held at the most that fits is not
## made again for an ask a little over it, as a fit to the exact ask would be. `ask` is a multiple of `unit`.
func _most_that_fits(ask: int, target: int, unit: int, probe: Callable, plain: Callable) -> int:
	if ask >= target:
		return 0
	if not probe.call(ask):
		return ask if plain.call(ask) else 0
	var lo := ask / unit
	var hi := target / unit  # (`target` is known not to fit)
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if probe.call(mid * unit):
			lo = mid
		else:
			hi = mid
	return lo * unit


## Room for `slots` record slots; false when that would pass the budget. `most` (0: none) is what the slots can never pass, so a growth by
## GROW stops short of room for more than that. `reserve` (`caps_for`, or none): what the classes that grow after the slots are asked for, so
## a growth to the most that fits leaves it. Never makes the slots smaller.
func ensure_slots(slots: int, most := 0, reserve := {}) -> bool:
	asked["slot"] = maxi(int(asked.get("slot", 0)), slots)
	var want := slot_cap_for(slots, most, reserve)
	if want == 0:
		return false
	if want > slot_cap:
		_grow_slots(want)
	return true


func _grow_slots(want: int) -> void:
	slot_cap = want
	_grew("slot")
	_remake(SLOT_CLASSES)


## Room for `slots` record slots made ahead of the need: grown only when the buffers afterwards hold at most `share` of the budget
## (so the growth never takes the room a later one may need, or reaches the warning), else nothing is done. True when it grew. The growth
## is by GROW or, when that does not fit, to what is asked (this is called every pass, so it does not search for the most that fits).
func pre_grow_slots(slots: int, share: float) -> bool:
	var want := _slot_target(slots, 0)
	if want == slot_cap:
		return false
	if not fits(want, 0, 0, 0, 0):
		want = _align(slots)
		if want <= slot_cap or not fits(want, 0, 0, 0, 0):
			return false
	if estimate_bytes(want, cell_cap, bin_cap, cloud_cap, husk_cap) > share * limits.memory_budget_bytes:
		return false
	asked["slot"] = maxi(int(asked.get("slot", 0)), slots)
	_grow_slots(want)
	return true


## Room for `clouds` cloud slots; false when that would pass the budget. A growth that does not fit by GROW goes to the most that fits
## (`_most_that_fits`, keeping `reserve`'s husks and entries free) and never makes the class smaller.
func ensure_clouds(clouds: int, reserve := {}) -> bool:
	asked["cloud"] = maxi(int(asked.get("cloud", 0)), clouds)
	if clouds <= int(FILL * cloud_cap):
		return true
	var want := maxi(ceili(clouds / FILL), int(cloud_cap * GROW))
	if not fits(0, 0, 0, want, 0):
		if clouds <= cloud_cap:
			return true
		want = _most_that_fits(clouds, want, 1,
				func(c: int) -> bool: return _fits(0, 0, 0, c, _reserved(reserve, "husk"), 0, _reserved(reserve, "entry")),
				func(c: int) -> bool: return _fits(0, 0, 0, c, 0))
		if want == 0:
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
## lists that do not fit and raises the overflow flag). A growth that does not fit by GROW goes to the most that fits and never makes the
## class smaller.
func ensure_entries(entries: int) -> bool:
	asked["entry"] = maxi(int(asked.get("entry", 0)), entries)
	if entries <= int(FILL * entry_cap):
		return true
	var want := maxi(ceili(entries / FILL), int(entry_cap * GROW))
	if not fits(0, 0, 0, 0, 0, 0, want):
		if entries <= entry_cap:
			return true
		want = _most_that_fits(entries, want, 1,
				func(c: int) -> bool: return _fits(0, 0, 0, 0, 0, 0, c),
				func(c: int) -> bool: return _fits(0, 0, 0, 0, 0, 0, c))
		if want == 0:
			return false
	entry_cap = want
	_grew("entry")
	_remake(["entry"])
	return true


## Room for `husks` husk slots; false when that would pass the budget. A growth that does not fit by GROW goes to the most that fits
## (keeping `reserve`'s entries free) and never makes the class smaller.
func ensure_husks(husks: int, reserve := {}) -> bool:
	asked["husk"] = maxi(int(asked.get("husk", 0)), husks)
	if husks <= int(FILL * husk_cap):
		return true
	var want := maxi(ceili(husks / FILL), int(husk_cap * GROW))
	if not fits(0, 0, 0, 0, want):
		if husks <= husk_cap:
			return true
		want = _most_that_fits(husks, want, 1,
				func(c: int) -> bool: return _fits(0, 0, 0, 0, c, 0, _reserved(reserve, "entry")),
				func(c: int) -> bool: return _fits(0, 0, 0, 0, c))
		if want == 0:
			return false
	husk_cap = want
	_grew("husk")
	_remake(["husk"])
	return true


## Room for `events` births (and deaths) in an iteration: 1 when the ring was made again, 0 when it was big enough, -1 when it would
## pass the budget. A growth by GROW stops at `most` (0: none), the most an iteration can have, or at `events` when that is more. A ring
## `maybe_shrink` found little used for a minute is made smaller first, here, where the last iteration's events have been read and the
## next's not yet written, when the room asked for now fits it.
func ensure_events(events: int, most := 0) -> int:
	asked["event"] = maxi(int(asked.get("event", 0)), events)
	var made := 0
	if _event_shrink_to > 0:
		if _event_shrink_to < event_cap and events <= _event_shrink_to:
			event_cap = _event_shrink_to
			_shrank("event")
			_remake(["event"])
			made = 1
		_event_shrink_to = 0
	if events <= event_cap:
		return made
	var grown := int(event_cap * GROW)
	if most > 0:
		grown = mini(grown, most)
	var want := maxi(events, grown)
	if not fits(0, 0, 0, 0, 0, want):
		want = events
		if not fits(0, 0, 0, 0, 0, want):
			return -1
	event_cap = want
	_grew("event")
	_remake(["event"])
	return 1


## The pictures' buffers for a payload of `texels` and a field of `pixels` cells; false, and they stay as they are, when making them or
## the textures that go with them (`texture_bytes`) would pass the memory budget (they are counted in it with the rest: `estimate_bytes`). The payload's room grows ahead of the bups,
## by GROW and from `PoolLimits.PAYLOAD_ROWS` rows, but not past room for `most_texels` (0: no bound; the most the dish can hold) or what
## is asked if that is more, and to what is asked when the room ahead would pass the budget: a growth makes the shared textures anew
## (`SimCore.publish`), which takes the best part of a frame on some drivers, so it must come a handful of times as a dish grows and not
## once for each row of bups. Only the buffers whose size changed are made again.
func ensure_draw(texels: int, pixels: int, most_texels := 0, with_thumbs := false) -> bool:
	var new_thumbs := thumbs or with_thumbs
	var grow := not bufs.has("PAYLOAD") or texels > _texels or pixels > _pixels or new_thumbs != thumbs or _slots_made != picture_slots()
	if not grow:
		return true
	if limits.watch != null:
		limits.watch.before_growth(Time.get_ticks_msec(), bytes_now())
	var others := bytes_now() - draw_bytes_now()
	var want := maxi(texels, _texels)
	var new_pixels := maxi(pixels, _pixels)
	if texels > _texels:
		var width := GpuLayout.PAYLOAD_TEX_WIDTH
		var ahead := maxi(int(_texels * GROW), limits.payload_rows * width)
		if most_texels > 0:
			ahead = mini(ahead, most_texels)
		ahead = ((ahead + width - 1) / width) * width
		if ahead > want and others + draw_bytes(ahead, new_pixels, cell_cap, new_thumbs) <= limits.memory_budget_bytes:
			want = ahead
	if others + draw_bytes(want, new_pixels, cell_cap, new_thumbs) > limits.memory_budget_bytes:
		return false
	_texels = want
	_pixels = new_pixels
	thumbs = new_thumbs
	_slots_made = picture_slots()
	_grew("draw")
	var remade: Array[String] = []
	for nm: String in DRAW_BUFFERS:
		var bytes := maxi(16, ((_bytes_of(nm) + 15) / 16) * 16)
		if bufs.has(nm) and int(sizes.get(nm, 0)) == bytes:
			continue
		remade.append(nm)
	_remaking = true
	if local and rd != null:  # (none of them is kept: the old ones are released and flushed before the new ones are made)
		for nm in remade:
			_release(nm)
		_flush()
	for nm in remade:
		_make(nm, maxi(16, ((_bytes_of(nm) + 15) / 16) * 16), false)
	if local and rd != null:
		_flush()
	_remaking = false
	return true


## The rows of payload texels the pictures' buffers hold in a slot (what the shared textures are as tall as at least).
func draw_rows() -> int:
	return _texels / GpuLayout.PAYLOAD_TEX_WIDTH


## The pictures PAYLOAD, IDTEX and PREVXY hold, a slot each, and the slot of the picture before them, which the next picture finds its bups'
## places before in (SimCore._picture_slots): on the byte path every bup picture of an iteration is read back after its one sync, so each
## needs its own (GpuLayout.PICTURES_MOST) besides that one; a shared texture is written in the list right after its picture, so one slot
## serves besides it.
func picture_slots() -> int:
	return GpuLayout.PICTURES_MOST + 1 if cpu_handover else 2


## The bytes the pictures take for a payload of `texels`, a field of `pixels` cells and a pool of `cells` field cells: their buffers and
## the textures made for the main device (`texture_bytes`).
func draw_bytes(texels: int, pixels: int, cells: int, with_thumbs := false) -> int:
	var total := texture_bytes(texels, pixels, thumbs or with_thumbs)
	for nm: String in DRAW_BUFFERS:
		var e: Array = DRAW_BUFFERS[nm]
		var unit: int = e[1]
		match e[0]:
			"slot texel": total += texels * unit * picture_slots()
			"view": total += cells * unit
			"pixel": total += pixels * unit
			_: total += unit
	return total


## The bytes of the textures (and the buffers beside them) the pictures take on the path in use, for a payload of `texels` and a field
## of `pixels` cells (the thumbnails' atlas with `with_thumbs`).
func texture_bytes(texels: int, pixels: int, with_thumbs := false) -> int:
	var total := 0
	for e: Array in (TEXTURES_HANDED if cpu_handover else TEXTURES_SHARED):
		match e[0]:
			"texel": total += texels * int(e[1])
			"pixel": total += pixels * int(e[1])
			"thumbs": total += int(e[1]) if with_thumbs else 0
			_: total += int(e[1])
	return total


## The bytes the pictures hold now: their buffers and textures (0 before anything is published).
func draw_bytes_now() -> int:
	var total := texture_bytes(_texels, _pixels, thumbs) if bufs.has("PAYLOAD") else 0
	for nm: String in DRAW_BUFFERS:
		total += int(sizes.get(nm, 0))
	return total


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


## Whether the pool with these capacities (slots, clouds, husks, events and entries: the most of these and the pool's current ones; cells and bins: more than
## the pool's current ones) stays within the memory budget and no single buffer passes `BUFFER_MOST`, and the device never holds more than the
## budget while the remake is made (`_sequence_peak`). The memory watch is read here, before room is made, and never inside a remake:
## `_remaking` is true from a remake's first release to its last flush, so a reading cannot fall in between.
func fits(slots: int, cells: int, bins: int, clouds: int, husks: int, events := 0, entries := 0) -> bool:
	if limits.watch != null and not _remaking:
		limits.watch.before_growth(Time.get_ticks_msec(), bytes_now())  # (the free memory is read again before room is made, at most once a second)
	return _fits(slots, cells, bins, clouds, husks, events, entries)


## `fits` without the watch's reading (the searches for the most that fits call it many times after one reading).
func _fits(slots: int, cells: int, bins: int, clouds: int, husks: int, events := 0, entries := 0) -> bool:
	var cloud_room := maxi(clouds, cloud_cap)
	var want := [maxi(slots, slot_cap), cell_cap + cells, bin_cap + bins, cloud_room, maxi(husks, husk_cap), maxi(events, event_cap), maxi(entries, maxi(entry_cap, GpuKernelsClouds.ENTRIES_PER_SLOT * cloud_room))]
	return largest_buffer_bytes(want[0], want[1], want[2], want[3], want[4], want[5], want[6]) <= BUFFER_MOST \
			and estimate_bytes(want[0], want[1], want[2], want[3], want[4], want[5], want[6]) <= limits.memory_budget_bytes \
			and _sequence_peak(want) <= limits.memory_budget_bytes


## The most the device holds during one `_remake` of the classes whose capacity differs in `want` (slots, cells, bins, clouds, husks,
## events, entries), in `_remake`'s order on a local device: the bytes held now less the not-kept buffers (freed first); then, for each kept buffer,
## the bytes so far plus its new copy (its old one still held); and last the new total. 0 where nothing is remade or the device is the main
## one, whose frame frees a buffer later (the final total, which `_fits` checks, is then the figure that matters).
func _sequence_peak(want: Array) -> int:
	var classes: Array = []
	if want[0] != slot_cap:
		classes.append_array(SLOT_CLASSES)
	if want[1] != cell_cap:
		classes.append_array(["cell", "view"])
	if want[2] != bin_cap:
		classes.append("bin")
	if want[3] != cloud_cap:
		classes.append("cloud")
	if want[4] != husk_cap:
		classes.append("husk")
	if want[5] != event_cap:
		classes.append("event")
	if want[6] != entry_cap:
		classes.append("entry")
	if classes.is_empty() or not local or rd == null:
		return 0
	var running := estimate_bytes(slot_cap, cell_cap, bin_cap, cloud_cap, husk_cap, event_cap, entry_cap)
	var kept: Array = []  # [bytes now, bytes then] of each kept buffer, in `_remake`'s order
	var scratch_new := 0
	for nm: String in BUFFERS:
		var e: Array = BUFFERS[nm]
		if not classes.has(e[0]):
			continue
		var now_bytes := _buffer_bytes(nm, slot_cap, cell_cap, bin_cap, cloud_cap, husk_cap, event_cap, entry_cap)
		var then_bytes := _buffer_bytes(nm, want[0], want[1], want[2], want[3], want[4], want[5], want[6])
		if e[2]:
			kept.append([now_bytes, then_bytes])
		else:
			running -= now_bytes
			scratch_new += then_bytes
	for nm: String in DRAW_BUFFERS:
		if bufs.has(nm) and classes.has(DRAW_BUFFERS[nm][0]):
			running -= int(sizes.get(nm, 0))
			scratch_new += int(want[1]) * int(DRAW_BUFFERS[nm][1])  # (the only one of them a remake of these classes makes: "view", a unit a cell)
	var peak := running
	for pair: Array in kept:
		peak = maxi(peak, running + int(pair[1]))
		running += int(pair[1]) - int(pair[0])
	return maxi(peak, running + scratch_new)


## The bytes the buffers and the pictures' textures take at these capacities.
func estimate_bytes(slots: int, cells: int, bins: int, clouds: int, husks: int, events := -1, entries := -1) -> int:
	if events < 0:
		events = event_cap
	if entries < 0:
		entries = maxi(entry_cap, GpuKernelsClouds.ENTRIES_PER_SLOT * clouds)
	var total := 0
	for nm: String in BUFFERS:
		total += _buffer_bytes(nm, slots, cells, bins, clouds, husks, events, entries)
	return total + draw_bytes_now()


## The bytes of buffer `nm` at these capacities.
func _buffer_bytes(nm: String, slots: int, cells: int, bins: int, clouds: int, husks: int, events: int, entries: int) -> int:
	var e: Array = BUFFERS[nm]
	var unit: int = e[1]
	match e[0]:
		"slot": return slots * unit
		"block": return (slots / GpuLayout.BLK_SLOTS + 1) * unit
		"bucket": return GpuKernelsLife.conj_buckets(slots) * unit
		"bucketbits": return (GpuKernelsLife.conj_buckets(slots) / 32 + 1) * unit
		"cell": return cells * unit
		"bin": return bins * unit
		"cloud": return clouds * unit
		"husk": return husks * unit
		"entry": return entries * unit
		"event": return events * unit
	return sizes.get(nm, unit)


## The bytes of the biggest single buffer at these capacities (`estimate_bytes`' arguments): what `BUFFER_MOST` bounds.
func largest_buffer_bytes(slots: int, cells: int, bins: int, clouds: int, husks: int, events: int, entries: int) -> int:
	var most := 0
	for nm: String in BUFFERS:
		most = maxi(most, _buffer_bytes(nm, slots, cells, bins, clouds, husks, events, entries))
	return most


## The bytes the buffers and the pictures' textures take now.
func bytes_now() -> int:
	var total := texture_bytes(_texels, _pixels, thumbs) if bufs.has("PAYLOAD") else 0
	for nm: String in sizes:
		total += sizes[nm]
	return total


## The share of the memory budget the buffers hold now.
func memory_fraction() -> float:
	return float(bytes_now()) / maxf(float(limits.memory_budget_bytes), 1.0)


## The capacities the running dishes' need (`SimCore.room_needed`) asks for, the way the `ensure_*` calls would make them: by class,
## room over FILL of what is asked, never under the limits' starting sizes; the entries follow the clouds and the ring's is what is asked.
func caps_for(room: Dictionary) -> Dictionary:
	var clouds := maxi(ceili(int(room["clouds"]) / FILL), limits.cloud_slots)
	var entries := 0
	if int(room["entries_density"]) > 0:
		entries = ceili(entries_for(mini(int(room["entry_clouds"]), clouds), int(room["entries_density"])) / FILL)
	return {"slot": _align(maxi(ceili(int(room["slots"]) / FILL), limits.world_slots)), "cloud": clouds, "husk": maxi(ceili(int(room["husks"]) / FILL), limits.husk_slots),
		"entry": maxi(entries, GpuKernelsClouds.ENTRIES_PER_SLOT * clouds), "event": int(room["events"])}


## The bytes the buffers and the pictures' textures would take at the capacities the running dishes need (`caps_for`): what is in use and
## the room its next growth asks for, whatever the classes hold now. The share of the budget this is, is what the memory warning measures.
func need_bytes(room: Dictionary) -> int:
	var caps := caps_for(room)
	return estimate_bytes(caps["slot"], cell_cap, bin_cap, caps["cloud"], caps["husk"], caps["event"], caps["entry"])


## Gives back at once what a dish that left held: each class that holds more than GROW times the room the running dishes need
## (`room`: `SimCore.room_needed`) is made smaller to that, never under what is in use (`used`: slots, clouds, husks, as the world counts
## them; the slots of a dish that left count until a step closes the gap, so `blocked` is true while they are above the room the dishes
## need) and never under the limits' sizes. The wait of `maybe_shrink` is skipped: it is there for numbers that swing, and these have not.
## Returns true when the slots held up the rest (the caller tries again after the next step).
func give_back(room: Dictionary, used: Dictionary) -> bool:
	var caps := caps_for(room)
	var floor_slots := _align(int(used["slots"]))
	var slots := maxi(_align(ceili(int(caps["slot"]) * GROW)), _align(ceili(floor_slots / FILL)))
	var remake: Array = []
	if slots < slot_cap:
		slot_cap = slots
		remake.append_array(SLOT_CLASSES)
		_shrank("slot")
	var clouds := maxi(int(caps["cloud"] * GROW), ceili(int(used["clouds"]) / FILL))
	if clouds < cloud_cap:
		cloud_cap = clouds
		remake.append("cloud")
		_shrank("cloud")
	var husks := maxi(int(caps["husk"] * GROW), ceili(int(used["husks"]) / FILL))
	if husks < husk_cap:
		husk_cap = husks
		remake.append("husk")
		_shrank("husk")
	var entries := maxi(int(caps["entry"] * GROW), GpuKernelsClouds.ENTRIES_PER_SLOT * cloud_cap)
	if entries < entry_cap:
		entry_cap = entries
		remake.append("entry")
		_shrank("entry")
	if int(caps["event"] * GROW) < event_cap:
		_event_shrink_to = maxi(int(caps["event"] * GROW), SimCore.EVENT_FLOOR)
	if not remake.is_empty():
		_remake(remake)
	for cls: String in ["slot", "cloud", "husk", "entry", "event"]:
		asked[cls] = 0
		_low_since.erase(cls)
	return floor_slots > int(caps["slot"] * FILL)


## The bytes the record slots' next growth would add (by GROW, as `ensure_slots` grows them first).
func next_growth_bytes() -> int:
	return estimate_bytes(_align(int(slot_cap * GROW)), cell_cap, bin_cap, cloud_cap, husk_cap) - estimate_bytes(slot_cap, cell_cap, bin_cap, cloud_cap, husk_cap)


## The capacities, the bytes held, the budget, the share of it held, the next growth's bytes and the growths and shrinks so far (for the debug log).
func report() -> Dictionary:
	return {"fraction": memory_fraction(), "next_growth_bytes": next_growth_bytes(), "slots": slot_cap, "cells": cell_cap, "bins": bin_cap, "clouds": cloud_cap, "husks": husk_cap, "entries": entry_cap, "events": event_cap,
		"bytes": bytes_now(), "budget_bytes": limits.memory_budget_bytes, "growths": growths.duplicate(), "shrinks": shrinks.duplicate()}


func _grew(klass: String) -> void:
	growths[klass] = int(growths.get(klass, 0)) + 1


func _shrank(klass: String) -> void:
	shrinks[klass] = int(shrinks.get(klass, 0)) + 1


## Shrinks a class that has used less than a quarter of its slots for a minute (at least to the limits' size and to the room for what
## most `ensure_*` asked of it in that time, so the next iteration does not grow it back; at most once a minute). `events` is the most the
## ring held in an iteration (births or deaths): the ring is the one class not made smaller here but at the start of the next iteration
## (`ensure_events`), as the last iteration's events are still to be read from it.
func maybe_shrink(slots: int, clouds: int, husks: int, entries := 0, events := 0) -> void:
	var now := Time.get_ticks_msec()
	for pair in [["slot", slots, slot_cap, limits.world_slots], ["cloud", clouds, cloud_cap, limits.cloud_slots], ["husk", husks, husk_cap, limits.husk_slots], ["entry", entries, entry_cap, 0], ["event", events, event_cap, SimCore.EVENT_FLOOR]]:
		var cls: String = pair[0]
		var used: int = pair[1]
		var cap: int = pair[2]
		var floor_cap: int = GpuKernelsClouds.ENTRIES_PER_SLOT * cloud_cap if cls == "entry" else int(pair[3])  # (the entries' floor follows the clouds, which may have shrunk just now)
		var least: int = maxi(floor_cap, int(asked.get(cls, 0)) if cls == "event" else ceili(int(asked.get(cls, 0)) / FILL))  # (the ring is asked for exactly what it must hold)
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
				_shrank(cls)
				_remake(SLOT_CLASSES)
			"cloud":
				cloud_cap = to
				_shrank(cls)
				_remake(["cloud"])
			"husk":
				husk_cap = to
				_shrank(cls)
				_remake(["husk"])
			"entry":
				entry_cap = to
				_shrank(cls)
				_remake(["entry"])
			"event":
				_event_shrink_to = to


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
