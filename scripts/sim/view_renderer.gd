class_name ViewRenderer
extends RefCounted
## The main device's side of the pooled world's picture: it imports the textures the simulation publishes on its own
## device, draws the main-view dish's bups from the payload (`view_build`: gpu/kernels_view.gd) into a MultiMesh's buffer with no copy
## through the processor, answers the pointer's questions on the payload, and gives the canvas the nutrient haze, the steering map and
## the thumbnails' atlas as textures. Main thread only (its device calls go through RenderingServer.call_on_render_thread, which runs
## them at once in this project, where the render thread is the main thread); `take_bound` may be called from any thread.
##
## The textures (SimCore.TEXTURES of each kind, written by SimCore.publish after its sync):
## - The simulation hands over, for each kind, its textures' native handles (`driver_handles`, called on its own thread), their size and
##   a generation that changes whenever it made them afresh; `offer` says which of them it published last.
## - Each is imported in a different, view-compatible format (payload RGBA32UI as RGBA32I, ids RG32UI as RG32I, the RGBA8 pictures as
##   sRGB): on Metal `texture_create_from_extension` wraps a native texture of the same format without retaining it, and freeing the
##   wrapper would free the simulation's texture twice (a crash at exit); a different format makes the driver build a view with its own
##   count, which is safe to free. A picture's Texture2DRD reads its sRGB import through a view in RGBA8 (the texture storage makes one
##   for a format with an sRGB twin), so the canvas reads its bytes as they are and filters them as the single-dish path's pictures.
## - The simulation writes a texture again only once the main side last used it more than `frame_queue_size` + 1 frames ago, so the main
##   side tells it which texture of each kind it used on which frame (`take_bound`; SimCore.texture_bound), every frame, the payload's
##   included whether or not a build read it (so the simulation's count of frames moves on).
## - A generation's imports are freed once none was used for `frame_queue_size` + 1 frames.

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

var _local := false  ## a local device (tools): its work is submitted and waited for, not run with the frame

var _made := {}  ## kernel name -> ShaderSet.create's entry
var _bufs := {}  ## P, VP, VCOUNT, VOFFS, VPD, VOUT -> RID
var _texels := 0  ## the per-texel buffers' size
var _sets := {}  ## "kernel|index" -> uniform set
var _inst := RID()  ## the MultiMesh buffer the sets bind
var _imports := {}  ## kind -> {generation, size, rids: Array[RID] (imported), bound: Array[int] (the frame each was last used on), seqs: Array[int] (the publish each holds)}
var _retired: Array = []  ## {rids: Array[RID], last: frame last used}
var _shown := {}  ## kind -> the texture index published last
var _pictures := {}  ## kind -> Texture2DRD (for the canvas)
var _payload := PayloadInfo.new()
var _bound_mutex := Mutex.new()
var _bound: Array = []  ## [kind, index, frame] not yet taken
var _vp := PackedByteArray()
var _last_build := []  ## what the instances were last built from
var _visible := {}  ## the last visible count read back: {count, key}
var _pick_request: Variant = null  ## {local, slack, pixel_um, near, hover, seq}
var _pick_seq := 0
var _answers := {}  ## "hover" / "click" -> the last pick answer
var _follow: Array = []  ## ids whose place is looked up (at every build, and when the list changes)
var _follow_asked := false  ## the list changed since the last look-up
var _places := {}  ## id -> Vector3(x, y, length) from the last answer


## `device`: a local device to run on instead of the main one (tools: `build` there is submitted and waited for).
func _init(limits_frame_queue := 2, device: RenderingDevice = null) -> void:
	frame_queue_size = limits_frame_queue
	_local = device != null
	rd = device if _local else RenderingServer.get_rendering_device()
	if rd == null:
		errors.append("no main rendering device")
		return
	var defs := {}
	var all := GpuKernels.all()
	for kname: String in KERNELS:
		defs[kname] = all[kname]
	var shaders := ShaderSet.imported(defs)
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
		(_pictures[kind] as Texture2DRD).texture_rd_rid = _imports[kind]["rids"][index]


## The payload the simulation published last: its texture (and the ids' beside it), its bups and their dish.
func set_payload(info: PayloadInfo) -> void:
	if info == null or info.texture_index < 0:
		return
	offer("payload", info.texture_index, info.generation, info.handles, info.size, info.seq)
	offer("ids", info.texture_index, info.generation, info.id_handles, info.size, info.seq)
	_payload = info


func payload() -> PayloadInfo:
	return _payload


## Once a frame, before drawing: the textures in use this frame are noted for the simulation (`take_bound`) and retired imports nobody
## used for frame_queue_size + 1 frames are freed.
func tick() -> void:
	for kind: String in _shown:
		if kind == "payload" or kind == "ids" or _pictures.has(kind):
			_note_bound(kind, _shown[kind])
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
	if not PICTURE_KINDS.has(kind) or not _imports.has(kind):
		return null
	if not _pictures.has(kind):
		var t := Texture2DRD.new()
		t.texture_rd_rid = _imports[kind]["rids"][_shown.get(kind, 0)]
		_pictures[kind] = t
	return _pictures[kind]


## The main device's import of texture `index` of `kind` as it holds the bytes (for checks: RID() when there is none).
func imported_texture(kind: String, index: int) -> RID:
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
	if capacity <= 0 or not target.is_valid():
		return
	var count := mini(_payload.count, _imports["payload"]["size"].x * _imports["payload"]["size"].y)
	var view_key := [camera, pixel_um, _payload.row, _imports["payload"]["generation"]]
	var slots := count
	if not _visible.is_empty() and _visible["key"] == view_key:
		slots = mini(count, maxi(MIN_SLOTS, nearest_po2(int(_visible["count"]) + int(_visible["count"]) / 2)))
	slots = mini(maxi(slots, mini(MIN_SLOTS, capacity)), capacity)
	var build := [view_key, _payload.seq, _shown["payload"], slots, target]
	var rebuild: bool = build != _last_build
	var asking: bool = _pick_request != null or (not _follow.is_empty() and (rebuild or _follow_asked))
	if not rebuild and not asking:
		return
	_last_build = build
	if rebuild and multimesh.is_valid():
		RenderingServer.multimesh_set_visible_instances(multimesh, slots)
	var pick: Variant = _pick_request
	_pick_request = null
	_follow_asked = false
	_put_vp(count, camera, pixel_um, slots, capacity, pick)
	_on_device(_build.bind(count, target, _shown["payload"], pick, view_key, rebuild))


## The next `draw_frame` builds the instances again even if nothing it knows of changed (the layer was hidden, a tool's timing).
func forget_build() -> void:
	_last_build = []


## Asks which bup is at `local` (dish-local µm): BupSim.pick_bup's rule (within half its drawn length at `pixel_um` plus `slack`, the
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


## The nearest bup's distance from the last hover pick's point and how many bups lie within its `near` (BupSim.nearest_and_count).
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


func _put_vp(count: int, camera: Rect2, pixel_um: float, slots: int, capacity: int, pick: Variant) -> void:
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
	put_u.call(GpuKernelsView.VW_FINDS, 0 if _follow.is_empty() else 1)
	for s in GpuKernelsView.FINDS:
		var id: int = _follow[s] if s < _follow.size() and _follow[s] >= 0 else -1
		put_u.call(GpuKernelsView.VW_FIND + 2 * s + GpuLayout.IDT_LO, id & NONE)
		put_u.call(GpuKernelsView.VW_FIND + 2 * s + GpuLayout.IDT_HI, (id >> 32) & NONE)


func _build(count: int, target: RID, index: int, pick: Variant, view_key: Array, rebuild: bool) -> void:
	if target != _inst:
		_free_sets()
		_inst = target
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
		_on_answer(rd.buffer_get_data(_bufs["VOUT"], 0, GpuKernelsView.VO_WORDS * 4), view_key if rebuild else [], pick, asking)
	else:
		rd.buffer_get_data_async(_bufs["VOUT"], _on_answer.bind(view_key if rebuild else [], pick, asking), 0, GpuKernelsView.VO_WORDS * 4)


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
	var k: Dictionary = _made[kname]
	rd.compute_list_bind_compute_pipeline(cl, k["pipeline"])
	rd.compute_list_bind_uniform_set(cl, _set_of(kname, index), 0)
	rd.compute_list_set_push_constant(cl, PackedFloat32Array([pa, 0.0, 0.0, 0.0]).to_byte_array(), 16)
	rd.compute_list_dispatch(cl, maxi(groups, 1), 1, 1)
	rd.compute_list_add_barrier(cl)


func _set_of(kname: String, index: int) -> RID:
	var key := "%s|%d" % [kname, index]
	var s: RID = _sets.get(key, RID())
	if s.is_valid() and rd.uniform_set_is_valid(s):
		return s
	var k: Dictionary = _made[kname]
	var uniforms: Array[RDUniform] = []
	var names: Array = k["buffers"]
	for b in names.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = b
		u.add_id(_inst if names[b] == "INST" else _bufs[names[b]])
		uniforms.append(u)
	var images: Dictionary = GpuKernelsView.IMAGE_BINDINGS.get(kname, {})
	for b: int in images:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = b
		u.add_id(_imports[images[b]]["rids"][index])
		uniforms.append(u)
	s = rd.uniform_set_create(uniforms, k["shader"], 0)
	_sets[key] = s
	return s


func _free_sets() -> void:
	for key: String in _sets:
		var s: RID = _sets[key]
		if s.is_valid() and rd.uniform_set_is_valid(s):
			rd.free_rid(s)
	_sets.clear()


## `view_key` empty: the build drew nothing (it only answered), so its visible count is not one.
func _on_answer(data: PackedByteArray, view_key: Array, pick: Variant, asked: bool) -> void:
	var w := func(word: int) -> int: return data.decode_u32(word * 4)
	var f := func(word: int) -> float: return data.decode_float(word * 4)
	if not view_key.is_empty():
		_visible = {"count": w.call(GpuKernelsView.VO_VISIBLE), "key": view_key}
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


## Frees every texture, buffer and shader this made. Call it before the simulation frees its textures, and once nothing draws with
## `texture`'s textures any more (they wrap the imports freed here).
func release() -> void:
	if rd == null:
		return
	_pictures.clear()
	_on_device(_release_now)


func _release_now() -> void:
	_free_sets()
	for r: Dictionary in _retired:
		_free_textures(r["rids"])
	_retired.clear()
	for kind: String in _imports:
		_free_textures(_imports[kind]["rids"])
	_imports.clear()
	for nm: String in _bufs:
		rd.free_rid(_bufs[nm])
	_bufs.clear()
	ShaderSet.free_all(rd, _made)
	_made.clear()
	rd = null
