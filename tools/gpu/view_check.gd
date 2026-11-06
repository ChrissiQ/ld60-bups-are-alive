extends SceneTree
## Checks of the pooled world's picture: ViewRenderer importing the shared textures SimCore publishes,
## drawing a real Dish's bups from them, the canvas reading them, the pick on the payload, and the transport under the real simulation.
## Windowed, through the lock, one at a time:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/view_check.gd -- picture
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/view_check.gd -- buildcost <bups>
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/view_check.gd -- soak <seconds> <bups> <zoom> [fitcost] [pace=<ms>] [bare]
##
## picture: a measured state (200,000 bups, seed 3, 90 mm, on the processor, paused) drawn by the single-dish path's Dish, then the same records loaded
##   into a SimCore (a local device on this thread), published, imported and drawn by the same Dish through ViewRenderer, at fit zoom and
##   20, 100 and 500 times it; each kind's import compared byte for byte with the simulation's texture; the haze and the payload read
##   through canvas shaders into a SubViewport; picks and near counts on the payload against BupSim's.
## buildcost: view_build's cost on a local device (no frame around it), wall clock around submit and sync, at fit zoom, 1.5 x, 20 x and
##   100 x, for a dish of `bups` (the soak's state, one step run): the whole build and each kernel in a submit of its own.
## soak: a SimCore on a thread of this script's own (SimThread is another script's) runs a dish of `bups` (18 s steps, as many
##   steps an iteration as fit T_ITER) and publishes after every iteration's sync; each payload's spare colour byte is stamped with its
##   number, and each haze's blue byte with its own (a submit of this script's own, before the main side is told), so the main side can
##   check every frame that the payload it draws from is one whole payload (a compute read of every texel), and every 30 frames that the
##   haze a canvas shader reads is one whole haze (the payload is an integer texture, which only the kernels read).
##   The first 20 s show a second dish of 3,000 bups that grows (its payload's textures are made afresh as it does), then the big one,
##   at `zoom` times fit; a hover pick every 90 frames; `fitcost` ends with 20 s at fit zoom with the bups shown and 20 s hidden.
##   `pace=<ms>`: an iteration starts no sooner than this after the last began (as the sim thread paces itself at low speeds), for the
##   share of iterations that publish at other iteration lengths, or (a long pace) a simulation that is nearly idle. `bare`: the main
##   side draws nothing of the dish and checks nothing (the frame the simulation's load alone leaves); `noverify`, `nocanvas`, `nohover`
##   leave out one check each, `nohaze` the dish's haze, `nodraw` the dish's bups from the view (to tell what a frame's time is spent on).
##   Each payload and haze is announced with SimCore's number of its publish, and the main side's uses go back to SimCore with it.
##
## Expected values, written before the first run:
## - picture against the single-dish path's [derived: the same capsule shader and footprint; the angle a half float (0.11 degrees at pi), the colour a
##   byte]: within a measured tolerance (mean absolute difference per channel <= 2/255 over the dish's disc, <= 0.1% of pixels over 16/255),
##   expected about 0.003/255 at fit, and the same lit pixels within 0.1%.
## - every import byte for byte the simulation's texture, the haze through the canvas byte for byte the simulation's haze [derived: a
##   view shares the texture's storage].
## - picks: the same id as BupSim.pick_bup in >= 99% of 400 points, near counts equal in >= 99% [derived: the payload's length is a half
##   float, so a bup at the edge of its reach may differ].
## - soak: 0 torn payloads and 0 canvas mismatches; interface p95 <= 1.15 x the display frame (9.6 ms at 120 Hz),
##   max <= 3 x (25 ms) after the first 2 s; RSS not growing (last third's mean within 5% of the middle third's); hover ring <= 3 frames
##   after the pick, 1 or 2 expected [derived: a readback a frame or two later with frame_queue_size 2].
## - share of iterations that publish a payload with SimCore.TEXTURES (8) textures at 120 Hz [derived from SimCore's reuse rule: at one
##   publish a frame a texture is held about 7 frames (shown the frame after its publish, superseded the next, then frame_queue_size + 2
##   frames, and the simulation hears of the main side's frames once an iteration)]: >= 99% at 8.33 ms iterations and longer.
## - view_build at 2M on screen about 1 ms [derived]; the draw at 2M fit zoom about 10 ms [measured], so
##   a frame at 2M fit zoom over 9.6 ms is expected and is reported apart (shown against hidden), not as the transport's.

const SEED := 3
const ZOOMS := [1.0, 20.0, 100.0, 500.0]
const ZOOM_NAMES := ["fit", "zoom20", "zoom100", "zoom500"]
const RADIUS := 90000.0
const STEP := 18.0
const T_ITER_MS := 25.0  ## [placeholder: the soak reports what it gives]

const STAMP_GLSL := """
#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, rgba32ui) uniform restrict uimage2D img;
layout(push_constant) uniform PC { uint stamp; uint w; uint n; uint pad; } pc;
void main() {
	uint k = gl_GlobalInvocationID.x;
	if (k >= pc.n) return;
	ivec2 at = ivec2(int(k % pc.w), int(k / pc.w));
	uvec4 v = imageLoad(img, at);
	v.w = (v.w & 0xFFFFFF00u) | pc.stamp;
	imageStore(img, at, v);
}
"""

const VERIFY_GLSL := """
#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, rgba32i) uniform restrict readonly iimage2D img;
layout(set = 0, binding = 1, std430) buffer O { uint bad; uint first_bad; } o;
layout(push_constant) uniform PC { uint stamp; uint w; uint n; uint pad; } pc;
void main() {
	uint k = gl_GlobalInvocationID.x;
	if (k >= pc.n) return;
	uint v = uint(imageLoad(img, ivec2(int(k % pc.w), int(k / pc.w))).w) & 255u;
	if (v != pc.stamp) { atomicAdd(o.bad, 1u); atomicMin(o.first_bad, k); }
}
"""

## The haze stamp: every texel's blue byte set to the haze's number (the soak's haze is a test pattern, not a picture).
const STAMP_RGBA8_GLSL := """
#version 450
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0, rgba8) uniform restrict image2D img;
layout(push_constant) uniform PC { uint stamp; uint w; uint h; uint pad; } pc;
void main() {
	ivec2 at = ivec2(gl_GlobalInvocationID.xy);
	if (at.x >= int(pc.w) || at.y >= int(pc.h)) return;
	vec4 v = imageLoad(img, at);
	v.b = float(pc.stamp) / 255.0;
	imageStore(img, at, v);
}
"""

## A picture through a canvas shader (a Sprite2D's), texel for texel at its texel's place (no blending, no filtering).
const CANVAS_RAW := """
shader_type canvas_item;
render_mode blend_disabled;
void fragment() { COLOR = texelFetch(TEXTURE, ivec2(UV * vec2(textureSize(TEXTURE, 0))), 0); }
"""

var sub: SubViewport
var camera: Camera2D
var dish: Dish
var fit := 0.0
var renderer: ViewRenderer
var out := {}

# soak: shared with the simulation's thread (under mtx)
var mtx := Mutex.new()
var stop := false
var sim_loop_done := false
var main_freed := false
var sim_done := false
var announce := {}  ## kind -> {index, generation, handles, size, seq, count, row}
var sim_stats := {}
var sim_thread: Thread
var soak_bups := 2000000
var pace_ms := 0.0
var bare := false
var skip: Array = []
var main_row_switch_at := 20.0
var want_big := false


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var a := OS.get_cmdline_user_args()
	print("VIEWCHECK device %s, refresh %.1f Hz, frame_queue_size %d" % [RenderingServer.get_rendering_device().get_device_name(), DisplayServer.screen_get_refresh_rate(DisplayServer.window_get_current_screen()), int(ProjectSettings.get_setting("rendering/rendering_device/vsync/frame_queue_size", 2))])
	match a[0] if a.size() > 0 else "":
		"picture":
			await _picture()
		"buildcost":
			_buildcost(int(a[1]) if a.size() > 1 else 2000000)
		"soak":
			for x: String in a.slice(4):
				if x.begins_with("pace="):
					pace_ms = float(x.substr(5))
				elif x == "bare":
					bare = true
				elif x in ["noverify", "nocanvas", "nohover", "nohaze", "nodraw"]:
					skip.append(x)
			print("VIEWCHECK soak options: pace %.1f ms, bare %s, skipped %s, textures %d" % [pace_ms, bare, skip, SimCore.TEXTURES])
			await _soak(float(a[1]) if a.size() > 1 else 60.0, int(a[2]) if a.size() > 2 else 2000000, float(a[3]) if a.size() > 3 else 20.0, a.has("fitcost"))
		_:
			print("usage: picture | soak <seconds> <bups> <zoom> [fitcost]")
	quit(0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


# ---- picture ------------------------------------------------------------------------------------------------------------------------

func _start(limit: int) -> StartConditions:
	var sc := StartConditions.new()
	sc.bups = 4
	sc.bup_limit = maxi(limit, 10)
	sc.dish_radius = RADIUS
	sc.nutrient_density = StartConditions.MAX_NUTRIENT_DENSITY
	sc.feed_density = StartConditions.MAX_FEED_DENSITY
	sc.sim_backend = StartConditions.BACKEND_CPU
	sc.tutorial = false
	sc.spread_founders()
	return sc


func _make_dish(parent: Node, n: int, limit: int) -> void:
	dish = Dish.new()
	parent.add_child(dish)
	dish.set_seed(SEED)
	dish.strike(_start(limit))
	var born_with := Cell.mass_to_add(Genome.founder())
	for i in n - dish.sim.bup_count():
		var grown := born_with * (1.0 + dish.sim.random_float())
		dish.sim.add_bup(dish.sim.random_point(dish.radius * 0.95), Genome.founder(), Dish.FOUNDER_ENERGY * dish.sim.random_float(), sqrt(grown), born_with, 0, Vector2.RIGHT)
	camera = Camera2D.new()
	parent.add_child(camera)
	var view := (parent as Viewport).get_visible_rect().size
	var room := minf(view.x * 0.5 - 40.0, view.y * 0.5 - 120.0)
	fit = clampf(room / dish.radius, 0.002, 1.0)
	var waited := 0
	while dish.drawing.bups_mesh == null and waited < 1200:
		await process_frame
		waited += 1
	dish.show_layer(Dish.Layer.MEDIUM, false)
	await _frames(5)


func _set_zoom(mult: float) -> void:
	camera.zoom = Vector2.ONE * fit * mult
	camera.position = dish.global_position


func _grab() -> Image:
	for f in 10:
		dish.flash = 0.0
		dish.refresh_drawing()
		await process_frame
	var img := sub.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img


static func _compare(a: Image, b: Image, disc_px: float) -> Dictionary:
	var da := a.get_data()
	var db := b.get_data()
	var w := a.get_width()
	var h := a.get_height()
	var r2 := disc_px * disc_px
	var sum := 0.0
	var n := 0
	var over := 0
	var maxd := 0
	for y in h:
		var dy := y + 0.5 - h * 0.5
		for x in w:
			var dx := x + 0.5 - w * 0.5
			if dx * dx + dy * dy > r2:
				continue
			var o := (y * w + x) * 4
			var worst := 0
			for c in 3:
				var d := absi(da[o + c] - db[o + c])
				sum += d
				worst = maxi(worst, d)
			n += 1
			if worst > 16:
				over += 1
			maxd = maxi(maxd, worst)
	return {"mean_abs": snappedf(sum / (3.0 * maxf(n, 1)), 0.0001), "share_over_16": float(over) / maxf(n, 1), "max": maxd, "pixels": n}


static func _lit(img: Image) -> int:
	var d := img.get_data()
	var lit := 0
	for j in range(0, d.size(), 4):
		if d[j] + d[j + 1] + d[j + 2] > 60:
			lit += 1
	return lit


func _picture() -> void:
	sub = SubViewport.new()
	sub.size = Vector2i(1280, 720)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sub)
	await _make_dish(sub, 200000, 200000)
	var today: Array[Image] = []
	var discs: Array[float] = []
	for i in ZOOMS.size():
		_set_zoom(ZOOMS[i])
		today.append(await _grab())
		discs.append(dish.radius * camera.zoom.x)
	var core := SimCore.new()
	print("SimCore errors: %s" % [core.errors])
	var spec := DishSpec.new()
	spec.number = 1
	spec.radius = dish.radius
	spec.limit = 400000
	spec.seed = SEED
	spec.nutrient_density = 32.0
	spec.founders = dish.sim.export_state_bytes()
	var row := core.add_dish(spec)
	core.run(0, STEP)
	var req := ViewRequest.new()
	req.row = row
	req.want_field_view = true
	req.want_thumbnails = true
	req.haze = Vector3(Cell.DETECTION_FLOOR, 0.5 * 255.0 / sqrt(10.0 * Cell.HALF_SATURATION), 0.45 * 255.0)
	var pub := core.publish(req)
	print("published %s, count %d" % [pub, core.count(row)])
	renderer = ViewRenderer.new()
	print("ViewRenderer errors: %s" % [renderer.errors])
	var info := _payload_info(core, row, pub["payload"], 1, 1)
	renderer.set_payload(info)
	for kind in ["haze", "steer", "thumbs"]:
		var rids: Array = core.textures(kind)
		renderer.offer(kind, pub[kind], 1, ViewRenderer.driver_handles(core.rd, rids), _size_of(core.rd, rids[0]))
	print("imports' errors: %s" % [renderer.errors])
	# each import against the simulation's texture
	var main_rd := RenderingServer.get_rendering_device()
	for kind in ["payload", "ids", "haze", "steer", "thumbs"]:
		var idx: int = pub["payload"] if kind == "ids" else pub[kind]
		var sim_bytes: PackedByteArray = core.rd.texture_get_data(core.textures(kind)[idx], 0)
		var main_bytes: PackedByteArray = main_rd.texture_get_data(renderer.imported_texture(kind, idx), 0)
		out["import_" + kind] = {"equal": sim_bytes == main_bytes, "bytes": sim_bytes.size(), "nonzero": sim_bytes.count(0) < sim_bytes.size()}
	# the same Dish drawn from the view
	dish.drawing.view = renderer
	for i in ZOOMS.size():
		_set_zoom(ZOOMS[i])
		var img := await _grab()
		out["view_vs_today_" + ZOOM_NAMES[i]] = _compare(img, today[i], discs[i])
		out["lit_" + ZOOM_NAMES[i]] = [_lit(today[i]), _lit(img)]
		if OS.get_environment("VIEW_OUT") != "":
			img.save_png(OS.get_environment("VIEW_OUT").path_join("view_" + ZOOM_NAMES[i] + ".png"))
			today[i].save_png(OS.get_environment("VIEW_OUT").path_join("today_" + ZOOM_NAMES[i] + ".png"))
	# the canvas's reads
	var haze_tex := renderer.texture("haze")
	var n := haze_tex.get_width()
	var haze_img := await _canvas(haze_tex, Vector2i(n, n))
	var sim_haze: PackedByteArray = core.rd.texture_get_data(core.textures("haze")[pub["haze"]], 0)
	if OS.get_environment("VIEW_OUT") != "":
		haze_img.save_png(OS.get_environment("VIEW_OUT").path_join("canvas_haze.png"))
		Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, sim_haze).save_png(OS.get_environment("VIEW_OUT").path_join("sim_haze.png"))
	out["canvas_haze"] = {"equal": haze_img.get_data() == sim_haze, "n": n, "lit": sim_haze.size() / 4 - _count_zero_alpha(sim_haze), "differ": _first_differences(haze_img.get_data(), sim_haze)}
	# picks against BupSim's
	_set_zoom(20.0)
	await _frames(3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var px := dish.pixel()
	var same := 0
	var hits := 0
	var near_same := 0
	var latency: Array = []
	var recs := dish.sim.export_state_bytes()
	for t in 400:
		var at := Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * dish.radius * 0.7 if t % 2 == 0 else _bup_at(rng, recs)
		var slack := 6.0 * px
		var seq := renderer.pick(at, slack, px, true, 20.0 * px)
		var asked := Engine.get_frames_drawn()
		while renderer.answer(true).get("seq", -1) != seq:
			await process_frame
		latency.append(Engine.get_frames_drawn() - asked)
		var a: Dictionary = renderer.answer(true)
		var want: int = dish.sim.pick_bup(at, slack, px)
		if want >= 0:
			hits += 1
		if a["id"] == want:
			same += 1
		var nc: Vector2 = dish.sim.nearest_and_count(at, 20.0 * px)
		if int(nc.y) == int(a["near"]) and absf(nc.x - float(a["nearest"])) <= 1e-3 * maxf(nc.x, 1.0):
			near_same += 1
	out["picks"] = {"points": 400, "hits_today": hits, "same_id": same, "near_same": near_same, "frames_to_answer": _summary(latency)}
	print("VIEWCHECK PICTURE " + JSON.stringify(out))
	dish.drawing.view = null
	renderer.release()
	await _frames(4)
	core.release()


static func _bup_at(rng: RandomNumberGenerator, recs: PackedByteArray) -> Vector2:
	var i := rng.randi_range(0, recs.size() / GpuLayout.RECORD_BYTES - 1)
	var o := i * GpuLayout.RECORD_BYTES
	return Vector2(recs.decode_float(o + GpuLayout.R_X * 4), recs.decode_float(o + GpuLayout.R_Y * 4)) + Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)) * 3.0


## The first few pixels that differ, as [pixel, canvas bytes, simulation bytes], and how many differ.
static func _first_differences(a: PackedByteArray, b: PackedByteArray) -> Array:
	var notes: Array = []
	var count := 0
	for p in mini(a.size(), b.size()) / 4:
		if a.slice(p * 4, p * 4 + 4) != b.slice(p * 4, p * 4 + 4):
			count += 1
			if notes.size() < 6:
				notes.append([p, Array(a.slice(p * 4, p * 4 + 4)), Array(b.slice(p * 4, p * 4 + 4))])
	notes.append(count)
	return notes


static func _count_zero_alpha(rgba: PackedByteArray) -> int:
	var z := 0
	for j in range(3, rgba.size(), 4):
		if rgba[j] == 0:
			z += 1
	return z


func _canvas(tex: Texture2D, size: Vector2i) -> Image:
	var v := SubViewport.new()
	v.size = size
	v.transparent_bg = true
	v.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	v.add_child(_raw_sprite(tex, size))
	root.add_child(v)
	await _frames(4)
	var img := v.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	v.queue_free()
	return img


## A Sprite2D that shows `tex` through CANVAS_RAW over `size` pixels.
static func _raw_sprite(tex: Texture2D, size: Vector2i) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = tex
	sprite.scale = Vector2(size) / Vector2(tex.get_width(), tex.get_height())
	var m := ShaderMaterial.new()
	m.shader = Shader.new()
	m.shader.code = CANVAS_RAW
	sprite.material = m
	return sprite


static func _size_of(rd: RenderingDevice, t: RID) -> Vector2i:
	var f := rd.texture_get_format(t)
	return Vector2i(f.width, f.height)


static func _payload_info(core: SimCore, row: int, index: int, generation: int, seq: int) -> PayloadInfo:
	var info := PayloadInfo.new()
	info.texture_index = index
	info.count = core.count(row)
	info.row = row
	info.generation = generation
	info.seq = seq
	info.handles = ViewRenderer.driver_handles(core.rd, core.textures("payload"))
	info.id_handles = ViewRenderer.driver_handles(core.rd, core.textures("ids"))
	info.size = _size_of(core.rd, core.textures("payload")[0])
	return info


## How many display refreshes passed with no new frame over `frames` (their times in ms): the refreshes their span holds less the frames.
static func _missed(frames: PackedFloat32Array) -> int:
	var period := 1000.0 / DisplayServer.screen_get_refresh_rate(DisplayServer.window_get_current_screen())
	var total := 0.0
	for f in frames:
		total += f
	return roundi(total / period) - frames.size()


static func _summary(v: Array) -> Dictionary:
	if v.is_empty():
		return {}
	var s := v.duplicate()
	s.sort()
	var total := 0.0
	for x in s:
		total += float(x)
	return {"n": s.size(), "mean": snappedf(total / s.size(), 0.001), "p50": s[s.size() / 2], "p95": s[mini(int(s.size() * 0.95), s.size() - 1)], "p99": s[mini(int(s.size() * 0.99), s.size() - 1)], "max": s[-1], "min": s[0]}


# ---- buildcost ---------------------------------------------------------------------------------------------------------------------

func _buildcost(bups: int) -> void:
	var dev := RenderingServer.create_local_rendering_device()
	var core := SimCore.new(null, false, dev)
	var row := core.add_dish(_soak_spec(1, bups, bups, 0.9))
	core.run(1, STEP)
	var req := ViewRequest.new()
	req.row = row
	var pub := core.publish(req)
	var view := ViewRenderer.new(2, dev)
	view.set_payload(_payload_info(core, row, pub["payload"], 1, 1))
	var capacity := ceili(bups * 1.05)
	var inst := dev.storage_buffer_create(capacity * 64)
	var screen := Vector2(1280, 720)
	var fit_scale := minf(screen.x * 0.5 - 40.0, screen.y * 0.5 - 120.0) / RADIUS
	var rows := {}
	for mult: float in [1.0, 1.5, 20.0, 100.0]:
		var px := 1.0 / (fit_scale * mult)
		var cam := Rect2(-screen * 0.5 * px, screen * px)
		var whole: Array = []
		for rep in 12:
			view.forget_build()
			var t0 := Time.get_ticks_usec()
			view.draw_into(cam, px, inst, capacity)
			whole.append((Time.get_ticks_usec() - t0) / 1000.0)
		view.profiling = true
		var kernels := {}
		for rep in 6:
			view.forget_build()
			view.draw_into(cam, px, inst, capacity)
			for k: String in view.profile:
				if not kernels.has(k):
					kernels[k] = []
				kernels[k].append(view.profile[k] / 1000.0)
		view.profiling = false
		var per := {}
		for k: String in kernels:
			per[k] = _summary(kernels[k])["p50"]
		rows["x%s" % str(mult)] = {"visible": view._visible.get("count", -1), "build_ms": _summary(whole), "kernel_ms_p50": per}
	print("VIEWCHECK BUILDCOST " + JSON.stringify({"bups": core.count(row), "errors": view.errors + core.errors, "rows": rows}))
	dev.free_rid(inst)
	view.release()
	core.release()
	dev.free()


# ---- soak ---------------------------------------------------------------------------------------------------------------------------

var _verify_shader := RID()
var _verify_pipeline := RID()
var _verify_bufs: Array[RID] = []
var _verify_sets := {}  ## imported RID -> [set for buffer 0, set for buffer 1]
var _verified := 0
var _torn_frames := 0
var _torn_texels := 0
var _torn_notes: Array = []
var _canvas_checks := 0
var _canvas_bad := 0
var _canvas_notes: Array = []
var _shown_stamps: Array = []  ## the haze stamps shown in the last frames


func _soak(seconds: float, bups: int, zoom: float, fitcost: bool) -> void:
	soak_bups = bups
	var main_rd := RenderingServer.get_rendering_device()
	# the game's Dish, drawn from the view (its own simulation holds 4 bups and is never advanced)
	await _make_dish(root, 4, bups)
	dish.show_layer(Dish.Layer.MEDIUM, true)
	_set_zoom(zoom)
	renderer = ViewRenderer.new(int(ProjectSettings.get_setting("rendering/rendering_device/vsync/frame_queue_size", 2)))
	print("ViewRenderer errors: %s" % [renderer.errors])
	if bare or skip.has("nohaze"):
		dish.show_layer(Dish.Layer.MEDIUM, false)
	if not bare and not skip.has("nodraw"):
		dish.drawing.view = renderer
	RenderingServer.call_on_render_thread(func() -> void:
		var s := RDShaderSource.new()
		s.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		s.source_compute = VERIFY_GLSL
		var spirv := main_rd.shader_compile_spirv_from_source(s)
		_verify_shader = main_rd.shader_create_from_spirv(spirv)
		_verify_pipeline = main_rd.compute_pipeline_create(_verify_shader)
		for b in 2:
			_verify_bufs.append(main_rd.storage_buffer_create(8)))
	# the canvas's read of the payload
	var cv := SubViewport.new()
	cv.size = Vector2i(64, 64)
	cv.render_target_update_mode = SubViewport.UPDATE_DISABLED  # (drawn once every 30 frames, for the check)
	var haze_sprite: Sprite2D = null
	root.add_child(cv)
	sim_thread = Thread.new()
	sim_thread.start(_sim_main)
	# wait for the first payload
	var waited := 0
	while waited < 20000:
		mtx.lock()
		var has: bool = announce.has("payload")
		mtx.unlock()
		if has:
			break
		await process_frame
		waited += 1
	var frame_ms := PackedFloat32Array()
	var frame_at := PackedFloat32Array()
	var mem_log: Array = []
	var hover_latency: Array = []
	var hover_hits := 0
	var hover_rings := 0
	var pending_pick := -1
	var pick_asked := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var t0 := Time.get_ticks_usec()
	var last := t0
	var last_seq := -1
	var phase := "small"
	var fit_phase := ""  ## "", then "shown" and "hidden" (fitcost: 20 s each at fit zoom after the soak)
	var fit_rows := {"shown": [], "hidden": []}
	var mem_next := 0.0
	var frames := 0
	while true:
		await process_frame
		frames += 1
		var now := Time.get_ticks_usec()
		var t := (now - t0) / 1e6
		frame_ms.append((now - last) / 1000.0)
		frame_at.append(t)
		last = now
		if phase == "small" and t >= main_row_switch_at:
			phase = "big"
			mtx.lock()
			want_big = true
			mtx.unlock()
		# what the simulation published
		mtx.lock()
		var ann := announce.duplicate(true)
		mtx.unlock()
		if ann.has("payload") and ann["payload"]["seq"] != last_seq:
			var p: Dictionary = ann["payload"]
			last_seq = p["seq"]
			var info := PayloadInfo.new()
			info.texture_index = p["index"]
			info.count = p["count"]
			info.row = p["row"]
			info.generation = p["generation"]
			info.seq = p["seq"]
			info.handles = p["handles"]
			info.id_handles = ann["ids"]["handles"]
			info.size = p["size"]
			renderer.set_payload(info)
		for kind in ["haze", "steer", "thumbs"]:
			if ann.has(kind):
				renderer.offer(kind, ann[kind]["index"], ann[kind]["generation"], ann[kind]["handles"], ann[kind]["size"], int(ann[kind].get("seq", -1)))
		if bare or skip.has("nodraw"):
			renderer.tick()
		if bare:
			if t >= seconds:
				break
			continue
		# the payload's stamp, checked every frame by compute; the haze's every 30 frames through the canvas
		var shown := renderer.payload()
		if shown.texture_index >= 0 and not skip.has("noverify"):
			var texels := shown.size.x * shown.size.y
			var rid := renderer.imported_texture("payload", shown.texture_index)
			RenderingServer.call_on_render_thread(_verify.bind(main_rd, rid, shown.seq & 255, texels, frames % 2, "ms %d gen %d index %d seq %d frame %d" % [Time.get_ticks_msec(), shown.generation, shown.texture_index, shown.seq, Engine.get_frames_drawn()]))
		if ann.has("haze") and not skip.has("nocanvas"):
			_shown_stamps.append(int(ann["haze"]["seq"]) & 255)
			if _shown_stamps.size() > 8:
				_shown_stamps.pop_front()
			if haze_sprite == null:
				haze_sprite = _raw_sprite(renderer.texture("haze"), cv.size)
				cv.add_child(haze_sprite)
			if frames % 30 == 28:
				cv.render_target_update_mode = SubViewport.UPDATE_ONCE
			if frames % 30 == 0:
				var vt := RenderingServer.texture_get_rd_texture(cv.get_texture().get_rid())
				main_rd.texture_get_data_async(vt, 0, _on_canvas.bind(_shown_stamps.duplicate()))
		# hover: the pointer stops somewhere on screen every 90 frames
		if pending_pick >= 0 and renderer.answer(true).get("seq", -1) == pending_pick:
			var a: Dictionary = renderer.answer(true)
			hover_latency.append(Engine.get_frames_drawn() - pick_asked)
			pending_pick = -1
			if a["id"] >= 0:
				hover_hits += 1
				dish.hovered.bup = a["id"]
				if dish.drawing.view_ring(a["id"]) != null:
					hover_rings += 1
		if frames % 90 == 0 and pending_pick < 0 and shown.texture_index >= 0 and not skip.has("nohover"):
			var view_rect := dish.get_global_transform_with_canvas().affine_inverse() * dish.get_viewport_rect()
			var at := view_rect.position + view_rect.size * Vector2(rng.randf_range(0.2, 0.8), rng.randf_range(0.2, 0.8))
			pending_pick = renderer.pick(at, 6.0 * dish.pixel(), dish.pixel(), true, 20.0 * dish.pixel())
			pick_asked = Engine.get_frames_drawn()
		if t >= mem_next:
			mem_next += 30.0
			var o := []
			OS.execute("ps", ["-o", "rss=", "-p", str(OS.get_process_id())], o)
			mem_log.append([snappedf(t, 0.1), int(str(o[0]).strip_edges()) / 1024.0, main_rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL) / 1048576.0])
			print("VIEWCHECK t=%.0f rss %.0f MB main_rd %.0f MB verified %d torn %d canvas %d/%d" % [t, mem_log[-1][1], mem_log[-1][2], _verified, _torn_frames, _canvas_checks, _canvas_bad])
		if t >= seconds and fitcost:
			# 20 s at fit zoom with the bups shown, then 20 s hidden (the simulation runs on); the first second of each is left out
			if fit_phase == "":
				fit_phase = "shown"
				_set_zoom(1.0)
			elif fit_phase == "shown" and t >= seconds + 20.0:
				fit_phase = "hidden"
				dish.show_layer(Dish.Layer.BUPS, false)
			elif fit_phase == "hidden" and t >= seconds + 40.0:
				break
			if fmod(t - seconds, 20.0) >= 1.0:
				fit_rows[fit_phase].append(frame_ms[-1])
			continue
		if t >= seconds:
			break
	# the frames after the first 2 s, before any fit-zoom part
	var steady := PackedFloat32Array()
	var small_phase: Array = []
	var big_phase: Array = []
	for i in frame_ms.size():
		if frame_at[i] >= 2.0 and frame_at[i] < seconds:
			steady.append(frame_ms[i])
			if frame_at[i] < main_row_switch_at:
				small_phase.append(frame_ms[i])
			elif frame_at[i] >= main_row_switch_at + 2.0:
				big_phase.append(frame_ms[i])
	var slow: Array = []
	var over := 0
	for i in frame_ms.size():
		if frame_at[i] >= 2.0 and frame_at[i] < seconds and frame_ms[i] > 12.5:
			over += 1
			if slow.size() < 40:
				slow.append("t=%.1f %.1f" % [frame_at[i], frame_ms[i]])
	mtx.lock()
	stop = true
	mtx.unlock()
	while true:
		mtx.lock()
		var done := sim_loop_done
		mtx.unlock()
		if done:
			break
		await process_frame
	await _frames(6)
	var result := {
		"seconds": seconds, "bups": bups, "zoom": zoom, "frames": frame_ms.size(),
		"frame_ms_steady": _summary(Array(steady)), "vsyncs_missed_steady": _missed(steady), "frame_ms_small_dish": _summary(small_phase), "frame_ms_big_dish": _summary(big_phase), "bare": bare, "skipped": skip,
		"frames_over_12_5_ms": over, "first_over_12_5_ms": slow,
		"verified_frames": _verified, "torn_frames": _torn_frames, "torn_texels": _torn_texels, "torn_notes": _torn_notes,
		"canvas_checks": _canvas_checks, "canvas_bad": _canvas_bad, "canvas_notes": _canvas_notes,
		"hover": {"picks": hover_latency.size(), "hits": hover_hits, "rings_drawn_at_answer": hover_rings, "frames": _summary(hover_latency)},
		"memory": mem_log, "renderer_errors": renderer.errors,
	}
	if fitcost:
		result["fit_shown"] = _summary(fit_rows["shown"])
		result["fit_hidden"] = _summary(fit_rows["hidden"])
	# nothing may draw with the imports once they are freed: the dish and the canvas check let go of them first
	dish.drawing.view = null
	dish.queue_redraw()
	if haze_sprite != null:
		haze_sprite.queue_free()
	await _frames(4)
	renderer.release()
	RenderingServer.call_on_render_thread(func() -> void:
		main_rd.free_rid(_verify_shader)
		for b: RID in _verify_bufs:
			main_rd.free_rid(b))
	await _frames(4)
	mtx.lock()
	main_freed = true
	mtx.unlock()
	while true:
		mtx.lock()
		var sd := sim_done
		mtx.unlock()
		if sd:
			break
		await process_frame
	sim_thread.wait_to_finish()
	result["sim"] = sim_stats
	print("VIEWCHECK SOAK " + JSON.stringify(result))


func _verify(main_rd: RenderingDevice, tex: RID, stamp: int, texels: int, slot: int, note: String) -> void:
	if not tex.is_valid():
		return
	if not _verify_sets.has(tex):
		var sets := []
		for b in 2:
			var u0 := RDUniform.new()
			u0.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u0.binding = 0
			u0.add_id(tex)
			var u1 := RDUniform.new()
			u1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u1.binding = 1
			u1.add_id(_verify_bufs[b])
			sets.append(main_rd.uniform_set_create([u0, u1], _verify_shader, 0))
		_verify_sets[tex] = sets
	main_rd.buffer_update(_verify_bufs[slot], 0, 8, PackedInt32Array([0, -1]).to_byte_array())
	var cl := main_rd.compute_list_begin()
	main_rd.compute_list_bind_compute_pipeline(cl, _verify_pipeline)
	main_rd.compute_list_bind_uniform_set(cl, _verify_sets[tex][slot], 0)
	main_rd.compute_list_set_push_constant(cl, PackedInt32Array([stamp, GpuLayout.PAYLOAD_TEX_WIDTH, texels, 0]).to_byte_array(), 16)
	main_rd.compute_list_dispatch(cl, (texels + 63) / 64, 1, 1)
	main_rd.compute_list_end()
	main_rd.buffer_get_data_async(_verify_bufs[slot], _on_verified.bind(stamp, texels, note), 0, 8)


func _on_verified(data: PackedByteArray, stamp: int, texels: int, note: String) -> void:
	_verified += 1
	var bad := data.decode_u32(0)
	if bad > 0:
		_torn_frames += 1
		_torn_texels += bad
		if _torn_notes.size() < 20:
			_torn_notes.append("stamp %d (%s): %d of %d texels differ, first at %d" % [stamp, note, bad, texels, data.decode_u32(4)])


func _on_canvas(data: PackedByteArray, stamps: Array) -> void:
	_canvas_checks += 1
	var seen := {}
	for p in 64 * 64:
		seen[data[p * 4 + 2]] = true
	if seen.size() != 1 or not stamps.has(seen.keys()[0]):
		_canvas_bad += 1
		if _canvas_notes.size() < 20:
			_canvas_notes.append("stamps seen %s, shown lately %s" % [seen.keys(), stamps])


# ---- the simulation's thread (this script's own: SimThread is another script's) --------------------------------------------------------

func _sim_main() -> void:
	var core := SimCore.new()
	var sim_errors := core.errors.duplicate()
	var big := _soak_spec(1, soak_bups, soak_bups, 0.9)
	var small := _soak_spec(2, 3000, 60000, 0.3)
	var row_big := core.add_dish(big)
	var row_small := core.add_dish(small)
	var stamp_shader := RID()
	var stamp_pipeline := RID()
	var s := RDShaderSource.new()
	s.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	s.source_compute = STAMP_GLSL
	var spirv := core.rd.shader_compile_spirv_from_source(s)
	if spirv.compile_error_compute != "":
		sim_errors.append(spirv.compile_error_compute)
	stamp_shader = core.rd.shader_create_from_spirv(spirv)
	stamp_pipeline = core.rd.compute_pipeline_create(stamp_shader)
	var stamp_sets := {}
	var s8 := RDShaderSource.new()
	s8.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	s8.source_compute = STAMP_RGBA8_GLSL
	var spirv8 := core.rd.shader_compile_spirv_from_source(s8)
	if spirv8.compile_error_compute != "":
		sim_errors.append(spirv8.compile_error_compute)
	var stamp8_shader := core.rd.shader_create_from_spirv(spirv8)
	var stamp8_pipeline := core.rd.compute_pipeline_create(stamp8_shader)
	var gens := {}  ## kind -> [rids, generation]
	var iterations := 0
	var publishes := 0
	var field_publishes := 0
	var remakes := 0
	var remake_log: Array = []
	var step_ms := 20.0
	var it_ms: Array = []
	var run_ms: Array = []
	var pub_ms: Array = []
	var stamp_ms: Array = []
	var pub_gaps: Array = []
	var last_pub := Time.get_ticks_msec()
	var last_field := 0
	var last_thumbs := 0
	var share_by_phase := {"small": [0, 0], "big": [0, 0]}
	var last_start := 0
	while true:
		mtx.lock()
		var st := stop
		var big_now := want_big
		mtx.unlock()
		if st:
			break
		var row := row_big if big_now else row_small
		for b: Array in renderer.take_bound():
			core.texture_bound(b[0], b[1], b[2], b[3])
		var k := clampi(int(T_ITER_MS / maxf(step_ms, 0.1)), 1, 64)
		if pace_ms > 0.0:
			k = 1
			if not it_ms.is_empty():
				var wait := int(pace_ms * 1000.0) - (Time.get_ticks_usec() - last_start)
				if wait > 0:
					OS.delay_usec(wait)
		var t_it := Time.get_ticks_usec()
		last_start = t_it
		var res := core.run(k, STEP)
		var t_run := Time.get_ticks_usec()
		if int(res.get("steps", 0)) > 0:
			step_ms = 0.8 * step_ms + 0.2 * float(res["gpu_usec"]) / 1000.0 / int(res["steps"])
		var req := ViewRequest.new()
		req.row = row
		var now_ms := Time.get_ticks_msec()
		req.want_field_view = now_ms - last_field >= Dish.HAZE_REFRESH_MSEC
		req.want_thumbnails = now_ms - last_thumbs >= 1000
		req.haze = Vector3(Cell.DETECTION_FLOOR, 0.5 * 255.0 / sqrt(10.0 * Cell.HALF_SATURATION), 0.45 * 255.0)
		var pub := core.publish(req)
		var t_pub := Time.get_ticks_usec()
		if pub.has("haze"):
			last_field = now_ms
			field_publishes += 1
		if pub.has("thumbs"):
			last_thumbs = now_ms
		var t_stamp := t_pub
		var ann := {}
		for kind: String in pub:
			var rids: Array = core.textures(kind)
			if not gens.has(kind) or gens[kind][0] != rids:
				gens[kind] = [rids.duplicate(), int(gens.get(kind, [[], 0])[1]) + 1]
				if kind == "payload" and int(gens[kind][1]) > 1:
					remakes += 1
					remake_log.append("ms %d gen %d" % [Time.get_ticks_msec(), gens[kind][1]])
				if kind == "payload":
					gens["ids"] = [core.textures("ids").duplicate(), gens[kind][1]]
			ann[kind] = {"index": pub[kind], "generation": gens[kind][1], "handles": ViewRenderer.driver_handles(core.rd, gens[kind][0]), "size": _size_of(core.rd, rids[0]), "seq": core.publish_seq}
		if pub.has("haze"):
			var haze_seq := core.publish_seq
			var htex: RID = core.textures("haze")[pub["haze"]]
			var hsize: Vector2i = ann["haze"]["size"]
			if not stamp_sets.has(htex) or not core.rd.uniform_set_is_valid(stamp_sets[htex]):
				var u := RDUniform.new()
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.binding = 0
				u.add_id(htex)
				stamp_sets[htex] = core.rd.uniform_set_create([u], stamp8_shader, 0)
			var cl := core.rd.compute_list_begin()
			core.rd.compute_list_bind_compute_pipeline(cl, stamp8_pipeline)
			core.rd.compute_list_bind_uniform_set(cl, stamp_sets[htex], 0)
			core.rd.compute_list_set_push_constant(cl, PackedInt32Array([haze_seq & 255, hsize.x, hsize.y, 0]).to_byte_array(), 16)
			core.rd.compute_list_dispatch(cl, (hsize.x + 7) / 8, (hsize.y + 7) / 8, 1)
			core.rd.compute_list_end()
			core.rd.submit()
			core.rd.sync()
		if pub.has("payload"):
			var seq := core.publish_seq
			var tex: RID = core.textures("payload")[pub["payload"]]
			var size: Vector2i = ann["payload"]["size"]
			if not stamp_sets.has(tex) or not core.rd.uniform_set_is_valid(stamp_sets[tex]):
				var u := RDUniform.new()
				u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				u.binding = 0
				u.add_id(tex)
				stamp_sets[tex] = core.rd.uniform_set_create([u], stamp_shader, 0)
			var texels := size.x * size.y
			var cl := core.rd.compute_list_begin()
			core.rd.compute_list_bind_compute_pipeline(cl, stamp_pipeline)
			core.rd.compute_list_bind_uniform_set(cl, stamp_sets[tex], 0)
			core.rd.compute_list_set_push_constant(cl, PackedInt32Array([seq & 255, size.x, texels, 0]).to_byte_array(), 16)
			core.rd.compute_list_dispatch(cl, (texels + 63) / 64, 1, 1)
			core.rd.compute_list_end()
			core.rd.submit()
			core.rd.sync()
			t_stamp = Time.get_ticks_usec()
			ann["payload"]["count"] = core.count(row)
			ann["payload"]["row"] = row
			ann["ids"] = {"handles": ViewRenderer.driver_handles(core.rd, gens["ids"][0])}
			publishes += 1
			var n_ms := Time.get_ticks_msec()
			pub_gaps.append(n_ms - last_pub)
			last_pub = n_ms
		var phase := "big" if big_now else "small"
		share_by_phase[phase][0] += 1
		if pub.has("payload"):
			share_by_phase[phase][1] += 1
		mtx.lock()
		for kind: String in ann:
			announce[kind] = ann[kind]
		mtx.unlock()
		iterations += 1
		var t_end := Time.get_ticks_usec()
		it_ms.append((t_end - t_it) / 1000.0)
		run_ms.append((t_run - t_it) / 1000.0)
		pub_ms.append((t_pub - t_run) / 1000.0)
		if pub.has("payload"):
			stamp_ms.append((t_stamp - t_pub) / 1000.0)
		if iterations % 500 == 0:
			print("VIEWCHECK sim iterations %d publishes %d count big %d small %d step_ms %.2f k %d overflow %d" % [iterations, publishes, core.count(row_big), core.count(row_small), step_ms, k, core.overflow()])
	var it_tail: Array = it_ms.slice(it_ms.size() / 2)
	mtx.lock()
	sim_stats = {
		"iterations": iterations, "payload_publishes": publishes, "share": snappedf(float(publishes) / maxi(iterations, 1), 0.0001),
		"share_small_phase": share_by_phase["small"], "share_big_phase": share_by_phase["big"],
		"pace_ms": pace_ms, "field_publishes": field_publishes, "payload_remakes": remakes, "remake_log": remake_log, "iteration_ms": _summary(it_tail), "run_ms": _summary(run_ms.slice(run_ms.size() / 2)),
		"publish_ms": _summary(pub_ms.slice(pub_ms.size() / 2)), "stamp_ms": _summary(stamp_ms.slice(stamp_ms.size() / 2)), "publish_gap_ms": _summary(pub_gaps.slice(pub_gaps.size() / 2)),
		"count_big": core.count(row_big), "count_small": core.count(row_small), "overflow": core.overflow(), "errors": sim_errors + core.errors,
		"sim_memory_mb": core.rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL) / 1048576.0,
	}
	sim_loop_done = true
	mtx.unlock()
	while true:
		mtx.lock()
		var mf := main_freed
		mtx.unlock()
		if mf:
			break
		OS.delay_msec(5)
	for t: RID in stamp_sets:
		if core.rd.uniform_set_is_valid(stamp_sets[t]):
			core.rd.free_rid(stamp_sets[t])
	core.rd.free_rid(stamp_shader)
	core.rd.free_rid(stamp8_shader)
	core.release()
	mtx.lock()
	sim_done = true
	mtx.unlock()


## A dish of `n` bups (limit `limit`) with the state of tools/gpu/core_perf.gd: the founder's genes over `spread` of a 90 mm dish, reserves
## from none to full, masses 0.8 to 1.6 of the birth mass.
func _soak_spec(number: int, n: int, limit: int, spread: float) -> DishSpec:
	var spec := DishSpec.new()
	spec.number = number
	spec.radius = RADIUS
	spec.resolution = 100
	spec.limit = limit
	spec.seed = 412556622 + number
	spec.nutrient_density = 32.0
	spec.feed_density = 20.0
	var founder := Scenario.small(1, RADIUS).founder_records(number).to_float32_array()
	var f := PackedFloat32Array(founder)
	while f.size() < n * GpuLayout.RECORD_WORDS:
		f.append_array(f.slice(0, mini(f.size(), n * GpuLayout.RECORD_WORDS - f.size())))
	var rng := RandomNumberGenerator.new()
	rng.seed = 2000000 + number
	var born := founder[GpuLayout.R_BIRTH_MASS]
	var per := float(SimConstants.build()["reserve_per_mass"])
	for i in n:
		var o := i * GpuLayout.RECORD_WORDS
		var a := rng.randf() * TAU
		var r := RADIUS * spread * sqrt(rng.randf())
		f[o + GpuLayout.R_X] = r * cos(a)
		f[o + GpuLayout.R_Y] = r * sin(a)
		var h := rng.randf() * TAU
		f[o + GpuLayout.R_DX] = cos(h)
		f[o + GpuLayout.R_DY] = sin(h)
		var mass := born * rng.randf_range(0.8, 1.6)
		f[o + GpuLayout.R_MASS] = mass
		f[o + GpuLayout.R_ENERGY] = mass * per * rng.randf()
	var recs := f.to_byte_array()
	for i in n:
		GpuLayout.set_id(recs, i, (i + 1))
	spec.founders = recs
	return spec
