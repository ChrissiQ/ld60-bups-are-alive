class_name ViewRenderer
extends RefCounted
## The main device's side of the pooled world's picture: it takes the textures the simulation publishes on its own
## device, draws the main-view dish's bups from the payload (`view_build`: gpu/kernels_view.gd) into a MultiMesh's buffer with no copy
## through the CPU, answers the pointer's questions on the payload, and gives the canvas the nutrient haze, the steering map and
## the thumbnails' atlas as textures. Main thread only (its device calls go through RenderingServer.call_on_render_thread, which runs
## them at once in this project, where the render thread is the main thread); `take_bound` may be called from any thread.
##
## Two ways to take the simulation's pictures, by driver (`cpu_handover`):
## - Metal and Direct3D 12 (one device of the system for every RenderingDevice): the simulation's textures are imported (below).
## - Vulkan (every local RenderingDevice is a VkDevice of its own, so a native handle of one means nothing on the main device): the
##   simulation reads back the bytes of what it published, only the part in use (SimCore.cpu_handover), and this side puts them
##   into textures of its own (the last section). `force_cpu_handover` or the user argument `--cpu-handover` takes this path on any driver.
##
## Imported textures (SimCore.TEXTURES of each kind, written by SimCore.publish after its sync):
## - The simulation hands over, for each kind, its textures' native handles (`driver_handles`, called on its own thread), their size and
##   a generation that changes whenever it made them afresh; `offer` says which of them it published last.
## - Each is imported in a different, view-compatible format (payload RGBA32UI as RGBA32I, ids RG32UI as RG32I, the RGBA8 pictures as
##   sRGB): on Metal `texture_create_from_extension` wraps a native texture of the same format without retaining it, and freeing the
##   wrapper would free the simulation's texture twice (a crash at exit); a different format makes the driver build a view with its own
##   count, which is safe to free.
## - A picture's Texture2DRD does not hold the import but a texture the main device made itself (`_owned`, the import's size and format),
##   into which the import is copied on the main device whenever a new publish is shown: the canvas makes a view of the texture it is
##   given (an sRGB read), and on Direct3D 12 a view of an imported texture is refused, as it has no allocation of its own. The
##   Texture2DRD reads the owned sRGB texture through a view in RGBA8 (the texture storage makes one for a format with an sRGB twin), so
##   the canvas reads its bytes as they are and filters them as the other pictures.
## - The simulation writes a texture again only once the main side last used it more than `frame_queue_size` + 1 frames ago, so the main
##   side tells it which texture of each kind it used on which frame (`take_bound`; SimCore.texture_bound), every frame, the payload's
##   included whether or not a build read it (so the simulation's count of frames moves on).
## - A generation's imports are freed once none was used for `frame_queue_size` + 1 frames.
##
## The CPU handover (`hand_over_picture`, `set_payload` with bytes): the simulation shares no textures, so there is nothing to reuse and
## nothing to tell it (`take_bound` stays empty). A picture's bytes go straight into its owned texture (`texture_update`; the atlas is
## as tall as its rows of tiles in use). The payload's and ids' bytes (the texels in use only) go into two storage buffers and the
## simulation's own copy kernel (`pool_copy_payload`) lays them into storage textures of this device (made again, larger, when the
## bups outgrow them), which the view kernels read through a view in the signed format as they read an import. A texture update has to
## be whole, so the buffers take the part in use and the kernel does the rest. Each handover is made on the render thread before the
## frame's compute lists.

const TEXTURES := SimCore.TEXTURES
const KINDS := ["payload", "ids", "haze", "steer", "thumbs"]
const PICTURE_KINDS := ["haze", "steer", "thumbs"]  ## RGBA8 pictures the canvas draws
const IMPORT_FORMATS := {
	"payload": RenderingDevice.DATA_FORMAT_R32G32B32A32_SINT,
	"ids": RenderingDevice.DATA_FORMAT_R32G32_SINT,
	"haze": RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB,
	"steer": RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB,
	"thumbs": RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB,
}
const KERNELS := ["view_count", "view_sums", "view_scatter", "view_tail", "view_pick", "view_pick2", "view_answer"]
const MIN_SLOTS := Dish.RENDER_MIN_CAPACITY
const NONE := 0xFFFFFFFF
const MAX_GROUPS := 4096  ## the most groups view_count and view_scatter run with (each a run of texels)

var rd: RenderingDevice
var frame_queue_size := 2
var errors: Array[String] = []
var profile := {}  ## on a local device with `profiling`: kernel name -> µs of its last dispatch (each its own submit, wall clock)
var profiling := false

## Density mode: the bups under their least footprint are not drawn as instances but
## added into per-pixel sums (GpuKernelsView.K_DENSITY_SPLAT), resolved into a picture (`density_texture`, each pixel the colour of one
## bup that covers it, the winner) that a quad the size of the camera's rectangle shows over the dish; a bup at or over its least
## footprint is drawn as a capsule, so there is no jump where a bup crosses. Set with `set_density`: the game's main view turns it on
## (DishDrawing._ensure_view); a view made for a tool or a test has it off, which draws every bup as a capsule.
var density := false
var density_taps := GpuKernelsView.DENSITY_BILINEAR  ## GpuKernelsView.DENSITY_NEAREST, DENSITY_BILINEAR or DENSITY_ROD (a footprint on one pixel, shared by four, or as a rod of two such)

var _local := false  ## a local device (tools): its work is submitted and waited for, not run with the frame
var _den_made := {}  ## the density kernels, made the first time density mode is switched on
var _den_buf := RID()  ## the per-pixel sums
var _den_tex := RID()  ## the resolved picture (RGBA8, straight alpha)
var _den_size := Vector2i.ZERO
var _den_valid := false  ## the picture holds a build made since the last `let_go` (before it, it holds some other dish's bups or nothing)
var _den_picture: Texture2DRD = null
var _large := {}  ## density mode: the last count read back of the bups the capsule path must draw: {count, key}
var _skipped_last := false  ## the last build left the capsule count out (`draw_into`: the next one counts them, so a bup that has grown large is found again)

var _made := {}  ## kernel name -> ShaderSet.create's entry
var _bufs := {}  ## P, VP, VCOUNT, VOFFS, VPD, VOUT -> RID
var _texels := 0  ## the per-texel buffers' size
var _sets := {}  ## "kernel|index" -> uniform set
var _inst := RID()  ## the MultiMesh buffer the sets bind
var _imports := {}  ## kind -> {generation, size, rids: Array[RID] (imported), bound: Array[int] (the frame each was last used on), seqs: Array[int] (the publish each holds)}
var _retired: Array = []  ## {rids: Array[RID], last: frame last used}
var _owned := {}  ## picture kind -> {rid: the main device's own texture the canvas shows, size}
var _hand_pictures := {}  ## kind -> true once a picture was handed over as bytes (CPU handover)
var _shown := {}  ## kind -> the texture index published last
var _pictures := {}  ## kind -> Texture2DRD (for the canvas)
var _payload := PayloadInfo.new()
var _bound_mutex := Mutex.new()
var _bound: Array = []  ## [kind, index, frame] not yet taken
var _vp := PackedByteArray()
var _last_build := []  ## what the instances were last built from
var _visible := {}  ## the last visible count read back: {count, key, bups (the payload's count at that build)}
var _pick_request: Variant = null  ## {local, slack, pixel_um, near, hover, seq}
var _pick_seq := 0
var _answers := {}  ## "hover" / "click" -> the last pick answer
var _follow: Array = []  ## ids whose place is looked up (at every build, and when the list changes)
var _follow_asked := false  ## the list changed since the last look-up
var _places := {}  ## id -> Vector3(x, y, length) from the last answer
var _epoch := 0  ## counts `let_go`s: an answer to a build from before the last one is dropped
static var force_cpu_handover := false  ## checks and tools: take the CPU handover whatever the driver (also `--cpu-handover` as a user argument of the run)
static var _vulkan := -1  ## 1 when the main device is Vulkan (read once)
var _ho := {}  ## the CPU handover's payload and ids: {rows, bases, views, stages (the buffers the bytes go into), set}
var _ho_generation := 0
var _copy_made := {}  ## the copy kernel (staging buffers into the payload's textures), made with the first payload handed over
static var _copy_defs := {}
static var _defs := {}  ## KERNELS' definitions (GpuKernels.all's), taken by the first view made
static var _den_defs := {}  ## GpuKernelsView.DENSITY_KERNELS' definitions, taken by the first view that switches density mode on


## `device`: a local device to run on instead of the main one (tools: `build` there is submitted and waited for).
func _init(limits_frame_queue := 2, device: RenderingDevice = null) -> void:
	frame_queue_size = limits_frame_queue
	_local = device != null
	rd = device if _local else RenderingServer.get_rendering_device()
	if rd == null:
		errors.append("no main rendering device")
		return
	_take_defs()
	var shaders := ShaderSet.imported(_defs)
	_on_device(func() -> void: _made = shaders.create(rd))
	errors.append_array(shaders.errors)
	for kname: String in KERNELS:
		if not _made.has(kname) and not errors.any(func(e: String) -> bool: return e.begins_with(kname)):
			errors.append("%s: not made" % kname)
	_vp.resize(GpuKernelsView.VW_WORDS * 4)
	_on_device(_make_constants)


## Whether the bups can be drawn here (a main device and every kernel made).
func can_draw() -> bool:
	return rd != null and _made.size() == KERNELS.size()


## Density mode on or off (`taps`: GpuKernelsView.DENSITY_NEAREST, DENSITY_BILINEAR or DENSITY_ROD). The density kernels are made the first time it is
## switched on; if they do not build, `density_ready` stays false and the capsule drawing goes on whatever the switch says.
## The view's and the density mode's kernel definitions, taken once a run and together (GpuKernels.all writes every kernel's text, about
## 17 ms [measured, M1 Pro]: not once a dish, and not once for each of the two sets).
static func _take_defs() -> void:
	if not _defs.is_empty():
		return
	var all := GpuKernels.all()
	for kname: String in KERNELS:
		_defs[kname] = all[kname]
	for kname: String in GpuKernelsView.DENSITY_KERNELS:
		_den_defs[kname] = all[kname]
	_copy_defs["pool_copy_payload"] = all["pool_copy_payload"]


func set_density(on: bool, taps := GpuKernelsView.DENSITY_BILINEAR) -> void:
	density = on
	density_taps = taps
	if not on or rd == null or not _den_made.is_empty():
		return
	_take_defs()
	var shaders := ShaderSet.imported(_den_defs)
	_on_device(func() -> void: _den_made = shaders.create(rd))
	errors.append_array(shaders.errors)
	if _den_made.size() != GpuKernelsView.DENSITY_KERNELS.size():
		_on_device(_free_density_kernels)


## Whether density mode is on and its kernels are made.
func density_ready() -> bool:
	return density and _den_made.size() == GpuKernelsView.DENSITY_KERNELS.size()


## The density picture's size in pixels: the camera's rectangle over the pixel (zero before the first build in density mode).
func density_size() -> Vector2i:
	return _den_size


## The density picture for the canvas (null before the first build in density mode): one texel a screen pixel, its (0, 0) at the camera
## rectangle's top left, so a quad of `density_size()` texels scaled by the pixel at the rectangle's position shows it as drawn. Straight
## alpha, over the dish and under the capsules.
func density_texture() -> Texture2DRD:
	if not _den_valid or not _den_tex.is_valid():
		return null
	if _den_picture == null:
		_den_picture = Texture2DRD.new()
	_den_picture.texture_rd_rid = _den_tex
	return _den_picture


## Whether the simulation hands its pictures over as bytes (SimCore.cpu_handover) rather than as shared textures: on Vulkan, where every
## local device is a device of its own and a native handle of one means nothing on the main device; elsewhere only when
## `force_cpu_handover` or the user argument `--cpu-handover` says so. Read on the main thread.
static func cpu_handover() -> bool:
	if _vulkan < 0:
		_vulkan = 1 if RenderingServer.get_current_rendering_driver_name() == "vulkan" else 0
	return force_cpu_handover or _vulkan == 1 or OS.get_cmdline_user_args().has("--cpu-handover")


## The native handles of a simulation's textures, for `offer`. Call it on the simulation device's own thread.
static func driver_handles(sim_rd: RenderingDevice, rids: Array) -> PackedInt64Array:
	var out := PackedInt64Array()
	for t: RID in rids:
		out.append(sim_rd.get_driver_resource(RenderingDevice.DRIVER_RESOURCE_TEXTURE, t, 0))
	return out


## The simulation published texture `index` of `kind` (`handles`: all TEXTURES of the kind, of `generation`, each `size`; `seq` the
## publish's number, which `take_bound` gives back with each use). A new generation is imported here and the old one freed once it is no
## longer in use.
func offer(kind: String, index: int, generation: int, handles: PackedInt64Array, size: Vector2i, seq := -1) -> void:
	if rd == null or index < 0:
		return
	var cur: Dictionary = _imports.get(kind, {})
	if cur.is_empty() or cur["generation"] != generation:
		if handles.size() != TEXTURES:
			return
		if not cur.is_empty():
			_retire(kind)
		_on_device(_import.bind(kind, generation, handles, size))
	if not _imports.has(kind):
		return
	var was: int = _shown.get(kind, -1)
	if was >= 0 and was != index:
		_note_bound(kind, was)  # (used until this frame)
	_shown[kind] = index
	_imports[kind]["seqs"][index] = seq
	if _pictures.has(kind):
		_on_device(_update_picture.bind(kind))


## The payload the simulation published last: its texture (and the ids' beside it), its bups and their dish.
func set_payload(info: PayloadInfo) -> void:
	if info == null or info.texture_index < 0:
		return
	if info.handles.is_empty():  # (handed over as bytes: SimCore.cpu_handover)
		_payload = info
		var t := Time.get_ticks_usec()
		_on_device(_hand_payload.bind(info))
		_count_handover(Time.get_ticks_usec() - t, info.bytes.size() + info.id_bytes.size())
		return
	offer("payload", info.texture_index, info.generation, info.handles, info.size, info.seq)
	offer("ids", info.texture_index, info.generation, info.id_handles, info.size, info.seq)
	_payload = info


func payload() -> PayloadInfo:
	return _payload


## The picture `kind` (haze, steer or thumbs) handed over as `bytes` of `size` texels (RGBA8, as the shared texture would hold them),
## publish `seq`: it goes into the texture the canvas shows, made again when the size changed. The thumbnails' atlas is as tall as its
## rows of tiles in use.
func hand_over_picture(kind: String, bytes: PackedByteArray, size: Vector2i, seq := -1) -> void:
	if rd == null or bytes.size() != size.x * size.y * 4:
		return
	_hand_pictures[kind] = true
	var t := Time.get_ticks_usec()
	_on_device(_hand_picture.bind(kind, bytes, size))
	_count_handover(Time.get_ticks_usec() - t, bytes.size())


## What the byte handover has cost this side so far (main thread): microseconds spent in its device calls, handovers made, bytes taken.
static var handover_usec := 0
static var handover_calls := 0
static var handover_bytes := 0


func _count_handover(usec: int, bytes: int) -> void:
	handover_usec += usec
	handover_calls += 1
	handover_bytes += bytes


## Once a frame, before drawing: the textures in use this frame are noted for the simulation (`take_bound`) and retired imports nobody
## used for frame_queue_size + 1 frames are freed.
func tick() -> void:
	if not _ho.is_empty() or not _hand_pictures.is_empty():
		_free_retired()
		return  # (nothing of the simulation's is in use: there is nothing to tell it)
	for kind: String in _shown:
		if kind == "payload" or kind == "ids" or _pictures.has(kind):
			_note_bound(kind, _shown[kind])
	_free_retired()


## Retired textures nobody used for frame_queue_size + 1 frames are freed.
func _free_retired() -> void:
	var now := Engine.get_frames_drawn()
	var keep: Array = []
	for r: Dictionary in _retired:
		if now - int(r["last"]) > frame_queue_size + 1:
			_on_device(_free_textures.bind(r["rids"]))
		else:
			keep.append(r)
	_retired = keep


## The textures used and the frame each was used on since the last call: [kind, index, frame, seq] each (seq: the number of the publish
## that texture held, as `offer` was told; -1 unknown), for SimCore.texture_bound (the ids' are the payload's index: the simulation reuses
## them together).
func take_bound() -> Array:
	_bound_mutex.lock()
	var out := _bound
	_bound = []
	_bound_mutex.unlock()
	return out


## A texture of `kind` (haze, steer, thumbs) that always shows the latest published picture, for the canvas; null until one is published.
## (The payload and ids are integer textures, which a Texture2DRD cannot hold: the kernels read them.)
func texture(kind: String) -> Texture2DRD:
	if not PICTURE_KINDS.has(kind) or not (_imports.has(kind) or _hand_pictures.has(kind)):
		return null
	if not _pictures.has(kind):
		var t := Texture2DRD.new()
		_pictures[kind] = t
		if _hand_pictures.has(kind):
			t.texture_rd_rid = _owned.get(kind, {}).get("rid", RID())
		else:
			_on_device(_update_picture.bind(kind))
	return _pictures[kind]


## The main device's import of texture `index` of `kind` as it holds the bytes (for checks: RID() when there is none).
func imported_texture(kind: String, index: int) -> RID:
	if _hand_pictures.has(kind):
		return _owned.get(kind, {}).get("rid", RID())
	if not _imports.has(kind) or index < 0 or index >= TEXTURES:
		return RID()
	return _imports[kind]["rids"][index]


## Where dish row `row`'s tile lies in the thumbnails' atlas (texels).
static func thumbnail_region(row: int) -> Rect2:
	var tile := GpuKernelsDraw.THUMB_TILE
	var across := GpuKernelsDraw.THUMB_ATLAS / tile
	return Rect2((row % across) * tile, (row / across) * tile, tile, tile)


# ---- the bups ------------------------------------------------------------------------------------------------------------------------

## Draws the payload's bups into `multimesh` (a 2D MultiMesh with colours and custom data, Dish.BUP_SHADER's): those whose quad reaches
## into `camera` (dish-local µm) at `pixel_um` µm to a pixel, in the dish's order, each at least the least footprint. Its visible instances
## are the visible bups, from the count the last build for this view read back (half again, to a power of two), or the payload's every bup
## until the count for a new view is back, so no visible bup is ever left out. Rebuilt when the camera, the scale or the payload changed,
## or a question is asked.
func draw_frame(camera: Rect2, pixel_um: float, multimesh: RID) -> void:
	if not can_draw() or not _imports.has("payload") or not multimesh.is_valid():
		return
	var capacity := RenderingServer.multimesh_get_instance_count(multimesh)
	var target := RenderingServer.multimesh_get_buffer_rd_rid(multimesh)
	draw_into(camera, pixel_um, target, capacity, multimesh)


## `draw_frame` into `target`, a storage buffer of `capacity` instances on this renderer's device (the MultiMesh's, or a tool's: then
## `multimesh` is RID() and nothing is told the visible count).
func draw_into(camera: Rect2, pixel_um: float, target: RID, capacity: int, multimesh := RID()) -> void:
	if capacity <= 0 or not target.is_valid() or not _imports.has("payload") or not _shown.has("payload"):
		return  # (no payload yet, or none since `let_go`: a question asked waits for one)
	var count := mini(_payload.count, _imports["payload"]["size"].x * _imports["payload"]["size"].y)
	var dens := density_ready()
	var mode := density_taps if dens else 0
	var den_size := Vector2i(maxi(ceili(camera.size.x / pixel_um - 0.001), 1), maxi(ceili(camera.size.y / pixel_um - 0.001), 1)) if dens else Vector2i.ZERO
	var view_key := [camera, pixel_um, _payload.row, _imports["payload"]["generation"], mode]
	var slots := count
	# (the last count is used while the bups have not grown by more than the half it is rounded up by: a burst of births draws them all)
	if not _visible.is_empty() and _visible["key"] == view_key and count - int(_visible["bups"]) <= int(_visible["count"]) / 2:
		slots = mini(count, maxi(MIN_SLOTS, nearest_po2(int(_visible["count"]) + int(_visible["count"]) / 2)))
	slots = mini(maxi(slots, mini(MIN_SLOTS, capacity)), capacity)
	var build := [view_key, _payload.seq, _shown["payload"], slots, target]
	# (density mode: the capsule kernels need not run while the last build of this view found no bup to draw as a capsule)
	var skip: bool = dens and not _skipped_last and not _large.is_empty() and _large["key"] == view_key and int(_large["count"]) == 0
	var rebuild: bool = build != _last_build
	var asking: bool = _pick_request != null or (not _follow.is_empty() and (rebuild or _follow_asked))
	if not rebuild and not asking:
		return
	_last_build = build
	if rebuild:
		_skipped_last = skip
		_den_valid = _den_valid or dens
	if rebuild and multimesh.is_valid():
		RenderingServer.multimesh_set_visible_instances(multimesh, slots)
	var pick: Variant = _pick_request
	_pick_request = null
	_follow_asked = false
	_put_vp(count, camera, pixel_um, slots, capacity, pick, mode, den_size)
	_on_device(_build.bind(count, target, _shown["payload"], pick, view_key, rebuild, den_size, skip))


## The next `draw_frame` builds the instances again even if nothing it knows of changed (the layer was hidden, a tool's timing).
func forget_build() -> void:
	_last_build = []


## Asks which bup is at `local` (dish-local µm): the pick's rule (within half its drawn length at `pixel_um` plus `slack`, the
## nearest), on the payload, and how many bups lie within `near` of it and how far the nearest is. The answer comes back a frame or two
## later (`answer`); `hover` keeps the hover's answer apart from a click's. Returns the question's number.
func pick(local: Vector2, slack: float, pixel_um: float, hover := false, near := 0.0) -> int:
	_pick_seq += 1
	_pick_request = {"local": local, "slack": slack, "pixel_um": pixel_um, "near": near, "hover": hover, "seq": _pick_seq, "asked": Engine.get_frames_drawn()}
	return _pick_seq


## The last answer to a pick (`hover` or a click's): {seq, id (-1: none), pos, length, nearest (-1: no bups), near, asked, frame}; empty
## before the first.
func answer(hover := false) -> Dictionary:
	return _answers.get("hover" if hover else "click", {})


## The nearest bup's distance from the last hover pick's point and how many bups lie within its `near`.
func near_count() -> Vector2:
	var a: Dictionary = answer(true)
	if a.is_empty():
		return Vector2(-1.0, 0.0)
	return Vector2(a["nearest"], a["near"])


## The bups (at most GpuKernelsView.FINDS: the selected and the hovered) whose places every build looks up, for their rings.
func follow(ids: Array) -> void:
	var wanted := ids.slice(0, GpuKernelsView.FINDS)
	if wanted != _follow:
		_follow = wanted
		_follow_asked = true


## Where a followed bup was in the last payload drawn: Vector3(x, y, its length in µm), or null when it is not in it.
func place_of(id: int) -> Variant:
	return _places.get(id, null)


# ---- the device's side (render thread) ------------------------------------------------------------------------------------------------

func _on_device(work: Callable) -> void:
	if _local:
		work.call()
	else:
		RenderingServer.call_on_render_thread(work)


func _make_constants() -> void:
	var consts := SimConstants.build()
	var p := PackedFloat32Array()
	p.resize(GpuLayout.P_WORDS)
	for nm: String in ["mass_um", "min_length_px", "width", "min_width_px"]:
		p[GpuLayout.p_slot(nm)] = float(consts[nm])
	_bufs["P"] = rd.storage_buffer_create(p.size() * 4, p.to_byte_array())
	_bufs["VP"] = rd.storage_buffer_create(GpuKernelsView.VW_WORDS * 4)
	_bufs["VOUT"] = rd.storage_buffer_create(GpuKernelsView.VO_WORDS * 4)
	_bufs["VCOUNT"] = rd.storage_buffer_create(MAX_GROUPS * 4)
	_bufs["VOFFS"] = rd.storage_buffer_create(MAX_GROUPS * 4)


func _import(kind: String, generation: int, handles: PackedInt64Array, size: Vector2i) -> void:
	var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	if not PICTURE_KINDS.has(kind):
		usage |= RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var rids: Array[RID] = []
	for h in handles:
		var t := rd.texture_create_from_extension(RenderingDevice.TEXTURE_TYPE_2D, IMPORT_FORMATS[kind], RenderingDevice.TEXTURE_SAMPLES_1, usage, h, size.x, size.y, 1, 1)
		if not t.is_valid():
			errors.append("%s: texture %d of generation %d was not imported" % [kind, rids.size(), generation])
		rids.append(t)
	var bound: Array[int] = []
	bound.resize(TEXTURES)
	bound.fill(-1000)
	var seqs: Array[int] = []
	seqs.resize(TEXTURES)
	seqs.fill(-1)
	_imports[kind] = {"generation": generation, "size": size, "rids": rids, "bound": bound, "seqs": seqs}
	if kind == "payload" or kind == "ids":
		_free_sets()
	if kind == "payload":
		_ensure_texels(size.x * size.y)


## The main device's own texture for picture `kind` of `size` (made again when the size changed: the old one is freed once no frame in
## flight can use it), which the canvas shows.
func _own_picture(kind: String, size: Vector2i) -> RID:
	var own: Dictionary = _owned.get(kind, {})
	if not own.is_empty() and own["size"] == size:
		return own["rid"]
	if not own.is_empty():
		_retired.append({"rids": [own["rid"]], "last": Engine.get_frames_drawn()})
	var format := RDTextureFormat.new()
	format.format = IMPORT_FORMATS[kind]
	format.width = size.x
	format.height = size.y
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB)
	format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	var made := rd.texture_create(format, RDTextureView.new())
	if not made.is_valid():
		errors.append("%s: the picture's own texture was not made" % kind)
		_owned.erase(kind)
		return RID()
	_owned[kind] = {"rid": made, "size": size}
	if _pictures.has(kind):
		(_pictures[kind] as Texture2DRD).texture_rd_rid = made
	return made


func _hand_picture(kind: String, bytes: PackedByteArray, size: Vector2i) -> void:
	var made := _own_picture(kind, size)
	if made.is_valid():
		rd.texture_update(made, 0, bytes)


## The payload's and ids' bytes into the textures the view kernels read: the bytes go into two storage buffers (only the texels in use),
## and the simulation's own copy kernel lays them into storage textures of the main device's own, which the kernels read through a view
## in the signed format (as the imports are). Made again, larger, when the bups outgrow them.
func _hand_payload(info: PayloadInfo) -> void:
	var w := GpuLayout.PAYLOAD_TEX_WIDTH
	var texels := info.bytes.size() / GpuLayout.PAYLOAD_BYTES
	var rows := maxi(1, (texels + w - 1) / w)
	if _copy_made.is_empty():
		_take_defs()
		var shaders := ShaderSet.imported(_copy_defs)
		_copy_made = shaders.create(rd)
		errors.append_array(shaders.errors)
	if _copy_made.is_empty():
		return
	if _ho.is_empty() or int(_ho["rows"]) < rows:
		_make_handover(maxi(rows, int(int(_ho.get("rows", 0)) * 1.5)))
		if _ho.is_empty():
			return
	if texels > 0:
		rd.buffer_update(_ho["stages"][0], 0, info.bytes.size(), info.bytes)
		rd.buffer_update(_ho["stages"][1], 0, info.id_bytes.size(), info.id_bytes)
		var k: Dictionary = _copy_made["pool_copy_payload"]
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, k["pipeline"])
		rd.compute_list_bind_uniform_set(cl, _ho["set"], 0)
		rd.compute_list_set_push_constant(cl, PackedFloat32Array([float(w), float(texels), 0.0, 0.0]).to_byte_array(), 16)
		rd.compute_list_dispatch(cl, clampi(ceili(texels / 64.0), 1, 16384), 1, 1)
		rd.compute_list_add_barrier(cl)
		rd.compute_list_end()
	for kind: String in ["payload", "ids"]:
		_shown[kind] = 0
		_imports[kind]["seqs"][0] = info.seq


func _make_handover(rows: int) -> void:
	_free_handover()
	var w := GpuLayout.PAYLOAD_TEX_WIDTH
	var bases: Array[RID] = []
	var views: Array[RID] = []
	for kind: String in ["payload", "ids"]:
		var unsigned := RenderingDevice.DATA_FORMAT_R32G32B32A32_UINT if kind == "payload" else RenderingDevice.DATA_FORMAT_R32G32_UINT
		var format := RDTextureFormat.new()
		format.format = unsigned
		format.width = w
		format.height = rows
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		format.add_shareable_format(unsigned)  # (the list must hold the texture's own format)
		format.add_shareable_format(IMPORT_FORMATS[kind])
		var base := rd.texture_create(format, RDTextureView.new())
		var view := RDTextureView.new()
		view.format_override = IMPORT_FORMATS[kind]
		var shared := rd.texture_create_shared(view, base) if base.is_valid() else RID()
		if not shared.is_valid():
			errors.append("%s: the handover's texture was not made" % kind)
			for r: RID in bases + [base]:
				if r.is_valid():
					rd.free_rid(r)
			return
		bases.append(base)
		views.append(shared)
	var stages: Array[RID] = [rd.storage_buffer_create(rows * w * GpuLayout.PAYLOAD_BYTES), rd.storage_buffer_create(rows * w * GpuLayout.IDT_BYTES)]
	var k: Dictionary = _copy_made["pool_copy_payload"]
	var uniforms: Array[RDUniform] = []
	for b in 2:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = b
		u.add_id(stages[b])
		uniforms.append(u)
	for b in 2:  # (the copy kernel writes the unsigned textures themselves)
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = 2 + b
		u.add_id(bases[b])
		uniforms.append(u)
	_ho = {"rows": rows, "bases": bases, "views": views, "stages": stages, "set": rd.uniform_set_create(uniforms, k["shader"], 0)}
	_ho_generation += 1
	var bound: Array[int] = []
	bound.resize(TEXTURES)
	bound.fill(-1000)
	var seqs: Array[int] = []
	seqs.resize(TEXTURES)
	seqs.fill(-1)
	for kind: String in ["payload", "ids"]:
		var view_rids: Array[RID] = []
		view_rids.resize(TEXTURES)
		view_rids.fill(views[0 if kind == "payload" else 1])
		_imports[kind] = {"generation": _ho_generation, "size": Vector2i(w, rows), "rids": view_rids, "bound": bound.duplicate(), "seqs": seqs.duplicate()}
	_free_sets()
	_ensure_texels(w * rows)


func _free_handover() -> void:
	if _ho.is_empty():
		return
	_free_sets()
	if rd.uniform_set_is_valid(_ho["set"]):
		rd.free_rid(_ho["set"])
	for r: RID in _ho["views"] + _ho["bases"] + _ho["stages"]:
		if r.is_valid():
			rd.free_rid(r)
	_ho = {}


## Copies the picture of `kind` shown now into the texture the canvas shows (made first, or again when the import's size changed).
func _update_picture(kind: String) -> void:
	if not _imports.has(kind) or not _pictures.has(kind):
		return
	var size: Vector2i = _imports[kind]["size"]
	var source: RID = _imports[kind]["rids"][_shown.get(kind, 0)]
	if not source.is_valid():
		return
	var own: Dictionary = _owned.get(kind, {})
	if own.is_empty() or own["size"] != size:
		if not own.is_empty():
			_retired.append({"rids": [own["rid"]], "last": Engine.get_frames_drawn()})
		var format := RDTextureFormat.new()
		format.format = IMPORT_FORMATS[kind]
		format.width = size.x
		format.height = size.y
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB)
		format.add_shareable_format(RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
		var made := rd.texture_create(format, RDTextureView.new())
		if not made.is_valid():
			errors.append("%s: the picture's own texture was not made" % kind)
			_owned.erase(kind)
			return
		own = {"rid": made, "size": size}
		_owned[kind] = own
		(_pictures[kind] as Texture2DRD).texture_rd_rid = made
	rd.texture_copy(source, own["rid"], Vector3.ZERO, Vector3.ZERO, Vector3(size.x, size.y, 1.0), 0, 0, 0, 0)


func _retire(kind: String) -> void:
	var cur: Dictionary = _imports[kind]
	var last := -1000
	for f: int in cur["bound"]:
		last = maxi(last, f)
	_retired.append({"rids": cur["rids"], "last": maxi(last, Engine.get_frames_drawn())})
	_imports.erase(kind)
	_shown.erase(kind)
	if kind == "payload" or kind == "ids":
		_on_device(_free_sets)


func _free_textures(rids: Array) -> void:
	for t: RID in rids:
		if t.is_valid() and rd.texture_is_valid(t):
			rd.free_rid(t)


func _note_bound(kind: String, index: int) -> void:
	var frame := Engine.get_frames_drawn()
	var seq := -1
	if _imports.has(kind):
		_imports[kind]["bound"][index] = frame
		seq = _imports[kind]["seqs"][index]
	if kind == "ids":
		return
	_bound_mutex.lock()
	_bound.append([kind, index, frame, seq])
	_bound_mutex.unlock()


func _ensure_texels(texels: int) -> void:
	if texels <= _texels:
		return
	_free_sets()
	for nm in ["VPD"]:
		if _bufs.has(nm):
			rd.free_rid(_bufs[nm])
		_bufs[nm] = rd.storage_buffer_create(texels * 4)
	_texels = texels


func _put_vp(count: int, camera: Rect2, pixel_um: float, slots: int, capacity: int, pick: Variant, mode := 0, den_size := Vector2i.ZERO) -> void:
	var put_u := func(w: int, v: int) -> void: _vp.encode_u32(w * 4, v)
	var put_f := func(w: int, v: float) -> void: _vp.encode_float(w * 4, v)
	put_u.call(GpuKernelsView.VW_COUNT, count)
	put_f.call(GpuKernelsView.VW_X0, camera.position.x)
	put_f.call(GpuKernelsView.VW_Y0, camera.position.y)
	put_f.call(GpuKernelsView.VW_X1, camera.end.x)
	put_f.call(GpuKernelsView.VW_Y1, camera.end.y)
	put_f.call(GpuKernelsView.VW_PIXEL, pixel_um)
	put_u.call(GpuKernelsView.VW_SLOTS, slots)
	put_u.call(GpuKernelsView.VW_CAPACITY, capacity)
	put_u.call(GpuKernelsView.VW_PICK, 1 if pick != null else 0)
	if pick != null:
		put_f.call(GpuKernelsView.VW_PICK_X, pick["local"].x)
		put_f.call(GpuKernelsView.VW_PICK_Y, pick["local"].y)
		put_f.call(GpuKernelsView.VW_SLACK, pick["slack"])
		put_f.call(GpuKernelsView.VW_NEAR, pick["near"])
	put_u.call(GpuKernelsView.VW_DENSITY, mode)
	put_u.call(GpuKernelsView.VW_DEN_W, den_size.x)
	put_u.call(GpuKernelsView.VW_DEN_H, den_size.y)
	put_u.call(GpuKernelsView.VW_FINDS, 0 if _follow.is_empty() else 1)
	for s in GpuKernelsView.FINDS:
		var id: int = _follow[s] if s < _follow.size() and _follow[s] >= 0 else -1
		put_u.call(GpuKernelsView.VW_FIND + 2 * s + GpuLayout.IDT_LO, id & NONE)
		put_u.call(GpuKernelsView.VW_FIND + 2 * s + GpuLayout.IDT_HI, (id >> 32) & NONE)


func _build(count: int, target: RID, index: int, pick: Variant, view_key: Array, rebuild: bool, den_size := Vector2i.ZERO, skip := false) -> void:
	if target != _inst:
		_free_sets()
		_inst = target
	var dens := den_size.x > 0
	if dens:
		_ensure_density(den_size)
	rd.buffer_update(_bufs["VP"], 0, _vp.size(), _vp)
	var asking: bool = pick != null or not _follow.is_empty()
	if asking:
		var init := PackedInt32Array()
		init.resize(GpuKernelsView.VO_WORDS)
		init.fill(-1)
		init[GpuKernelsView.VO_NEAR] = 0
		rd.buffer_update(_bufs["VOUT"], 0, init.size() * 4, init.to_byte_array())
	var groups := GpuKernels.bup_groups(count)
	var runs := mini(GpuKernels.scan_groups(maxi(count, 1)), MAX_GROUPS)
	var cl := -1 if profiling and _local else rd.compute_list_begin()
	if rebuild:
		if dens:
			_dispatch(cl, "density_clear", index, GpuKernels.bup_groups(den_size.x * den_size.y * GpuKernelsView.DENSITY_WORDS))
			_dispatch(cl, "density_splat", index, groups)
			_dispatch(cl, "density_resolve", index, GpuKernels.bup_groups(den_size.x * den_size.y))
		if skip:
			_dispatch(cl, "view_tail", index, GpuKernels.bup_groups(_vp.decode_u32(GpuKernelsView.VW_SLOTS * 4)), 0.0)
		else:
			_dispatch(cl, "view_count", index, runs)
			_dispatch(cl, "view_sums", index, 1, float(runs))
			_dispatch(cl, "view_scatter", index, runs)
			_dispatch(cl, "view_tail", index, GpuKernels.bup_groups(_vp.decode_u32(GpuKernelsView.VW_SLOTS * 4)), float(runs))
	if asking:
		_dispatch(cl, "view_pick", index, groups)
		_dispatch(cl, "view_pick2", index, groups)
		_dispatch(cl, "view_answer", index, 1)
	if cl >= 0:
		rd.compute_list_end()
	if _local:
		rd.submit()
		rd.sync()
		_on_answer(rd.buffer_get_data(_bufs["VOUT"], 0, GpuKernelsView.VO_WORDS * 4), view_key if rebuild else [], pick, asking, dens, -1, count)
	else:
		rd.buffer_get_data_async(_bufs["VOUT"], _on_answer.bind(view_key if rebuild else [], pick, asking, dens, _epoch, count), 0, GpuKernelsView.VO_WORDS * 4)


## `cl` -1: (profiling on a local device) the kernel in a list and a submit of its own, timed.
func _dispatch(cl: int, kname: String, index: int, groups: int, pa := 0.0) -> void:
	if cl < 0:
		var t0 := Time.get_ticks_usec()
		var own := rd.compute_list_begin()
		_dispatch(own, kname, index, groups, pa)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		profile[kname] = Time.get_ticks_usec() - t0
		return
	var k: Dictionary = _kernel(kname)
	rd.compute_list_bind_compute_pipeline(cl, k["pipeline"])
	rd.compute_list_bind_uniform_set(cl, _set_of(kname, index), 0)
	rd.compute_list_set_push_constant(cl, PackedFloat32Array([pa, 0.0, 0.0, 0.0]).to_byte_array(), 16)
	rd.compute_list_dispatch(cl, maxi(groups, 1), 1, 1)
	rd.compute_list_add_barrier(cl)


func _kernel(kname: String) -> Dictionary:
	return _made[kname] if _made.has(kname) else _den_made[kname]


func _set_of(kname: String, index: int) -> RID:
	var key := "%s|%d" % [kname, index]
	var s: RID = _sets.get(key, RID())
	if s.is_valid() and rd.uniform_set_is_valid(s):
		return s
	var k: Dictionary = _kernel(kname)
	var uniforms: Array[RDUniform] = []
	var names: Array = k["buffers"]
	for b in names.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = b
		u.add_id(_inst if names[b] == "INST" else (_den_buf if names[b] == "DEN" else _bufs[names[b]]))
		uniforms.append(u)
	var images: Dictionary = GpuKernelsView.IMAGE_BINDINGS.get(kname, {})
	for b: int in images:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = b
		u.add_id(_den_tex if images[b] == "density" else _imports[images[b]]["rids"][index])
		uniforms.append(u)
	s = rd.uniform_set_create(uniforms, k["shader"], 0)
	_sets[key] = s
	return s


## The sums and the picture for a camera rectangle of `size` pixels (made afresh when it changes; the old picture is freed once no frame
## in flight can use it).
func _ensure_density(size: Vector2i) -> void:
	if size == _den_size and _den_tex.is_valid():
		return
	_free_sets()
	if _den_tex.is_valid():
		_retired.append({"rids": [_den_tex], "last": Engine.get_frames_drawn()})
	if _den_buf.is_valid():
		rd.free_rid(_den_buf)
	_den_buf = rd.storage_buffer_create(size.x * size.y * GpuKernelsView.DENSITY_WORDS * 4)
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width = size.x
	format.height = size.y
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_den_tex = rd.texture_create(format, RDTextureView.new())
	_den_size = size
	if _den_picture != null:
		_den_picture.texture_rd_rid = _den_tex


func _free_density_kernels() -> void:
	ShaderSet.free_all(rd, _den_made)
	_den_made.clear()


func _free_sets() -> void:
	for key: String in _sets:
		var s: RID = _sets[key]
		if s.is_valid() and rd.uniform_set_is_valid(s):
			rd.free_rid(s)
	_sets.clear()


## `view_key` empty: the build drew nothing (it only answered), so its visible count is not one.
func _on_answer(data: PackedByteArray, view_key: Array, pick: Variant, asked: bool, dens := false, epoch := -1, bups := 0) -> void:
	if epoch >= 0 and epoch != _epoch:
		return  # (asked before `let_go`: of a payload this view no longer holds)
	var w := func(word: int) -> int: return data.decode_u32(word * 4)
	var f := func(word: int) -> float: return data.decode_float(word * 4)
	if not view_key.is_empty():
		_visible = {"count": w.call(GpuKernelsView.VO_VISIBLE), "key": view_key, "bups": bups}
		if dens:
			_large = {"count": w.call(GpuKernelsView.VO_LARGE), "key": view_key}
	if not asked:
		return
	var places := {}
	for s in GpuKernelsView.FINDS:
		if w.call(GpuKernelsView.VO_FOUND + s) == NONE:
			continue
		var at := GpuKernelsView.VO_PLACES + s * GpuKernelsView.VO_PLACE_WORDS
		var id: int = w.call(at) | (w.call(at + 1) << 32)
		places[id] = Vector3(f.call(at + 2), f.call(at + 3), f.call(at + 4))
	_places = places
	if pick == null:
		return
	var id := -1
	var pos := Vector2.ZERO
	var length := 0.0
	if w.call(GpuKernelsView.VO_INDEX) != NONE:
		var at := GpuKernelsView.VO_PICKED
		id = w.call(at) | (w.call(at + 1) << 32)
		pos = Vector2(f.call(at + 2), f.call(at + 3))
		length = f.call(at + 4)
	var nearest_bits: int = w.call(GpuKernelsView.VO_NEAREST)
	_answers["hover" if pick["hover"] else "click"] = {
		"seq": pick["seq"], "id": id, "pos": pos, "length": length, "nearest": -1.0 if nearest_bits == NONE else sqrt(f.call(GpuKernelsView.VO_NEAREST)),
		"near": w.call(GpuKernelsView.VO_NEAR), "asked": pick["asked"], "frame": Engine.get_frames_drawn(),
	}


## The dish left the main view: every import is given back now, and the payload and the answers with them, so the view draws nothing
## and answers no pick until the world publishes the dish again (the textures it last drew from have since held the other dishes'
## pictures, and the world may have made them afresh; it frees its old ones once the main side has stopped using them, SimCore's
## header). The kernels and buffers stay; the next `offer` imports afresh.
func let_go() -> void:
	if rd == null:
		return
	var rids: Array = []
	for kind: String in _imports:
		rids.append_array(_imports[kind]["rids"])
	for r: Dictionary in _retired:
		rids.append_array(r["rids"])
	for kind: String in _owned:
		rids.append(_owned[kind]["rid"])
	_owned.clear()
	_imports.clear()
	_retired.clear()
	_shown.clear()
	_pictures.clear()
	_hand_pictures.clear()
	_payload = PayloadInfo.new()
	_last_build = []
	_visible = {}
	_large = {}
	_den_valid = false
	_answers.clear()
	_places.clear()
	_pick_request = null
	_epoch += 1
	_on_device(func() -> void:
		_free_sets()
		_free_handover()
		_free_textures(rids))


## Frees every texture, buffer and shader this made. Call it before the simulation frees its textures, and once nothing draws with
## `texture`'s textures any more (they wrap the imports freed here).
func release() -> void:
	if rd == null:
		return
	_pictures.clear()
	_den_picture = null
	_on_device(_release_now)


func _release_now() -> void:
	_free_sets()
	_free_handover()
	ShaderSet.free_all(rd, _copy_made)
	_copy_made.clear()
	if _den_tex.is_valid():
		_free_textures([_den_tex])
	if _den_buf.is_valid():
		rd.free_rid(_den_buf)
	_den_tex = RID()
	_den_buf = RID()
	_free_density_kernels()
	for r: Dictionary in _retired:
		_free_textures(r["rids"])
	_retired.clear()
	for kind: String in _owned:
		_free_textures([_owned[kind]["rid"]])
	_owned.clear()
	for kind: String in _imports:
		_free_textures(_imports[kind]["rids"])
	_imports.clear()
	for nm: String in _bufs:
		rd.free_rid(_bufs[nm])
	_bufs.clear()
	ShaderSet.free_all(rd, _made)
	_made.clear()
	rd = null
