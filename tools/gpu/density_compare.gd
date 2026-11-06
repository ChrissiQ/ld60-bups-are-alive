extends SceneTree
## density mode (ViewRenderer.set_density) against the single-dish path's capsule look and the point path, drawn
## from the same paused states, with the cost of each. Windowed, through the lock, one at a time:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/density_compare.gd -- pack
##   ... -- sparse      (1,500 bups at fit zoom and 4 x: does every bup leave a lit pixel, in each look)
##   ... -- crossover   (a dense cluster of 200,000 bups at pixel sizes round the bups' least footprint: the picture across the crossover)
##   ... -- running     (2M at fit zoom with a simulation running on a thread of this script's own: capsule, winner, hidden)
##   ... -- cost        (view_build's cost at PACK_COUNTS at fit: capsule, rod, nearest, winner; no pictures)
##   ... -- smoke       (10,000 bups, fit zoom: that the kernels build and the looks draw)
## Env: PACK_COUNTS (comma list, default 10000,100000,1000000,2000000), PACK_OUT (the folder for the pictures and pack_<counts>.json, default
## tools/gpu/baseline/zoomed_out/density), RUN_SECONDS (running: seconds a phase, default 8).
##
## pack: for each count (a seeded state spread over the 90 mm dish, one step run, paused) and fit zoom and 20, 100 and 500 x
##   it (the closer ones centred on the densest 1 mm bin of the state): the picture of capsule (today), winner (density mode with bilinear taps), rod (two
##   bilinear splats along the bup's axis), point (a measured point path fed by the same view_build instances), the density's
##   nearest-tap variant and the bare dish, each frame
##   rebuilt (view_build every frame, as a running simulation makes it): the frame's interval (vsync off; median of 60 frames after 15)
##   with each look and with none (`hidden`), so a look's cost is its frame less hidden; view_build's cost
##   on a local device (wall clock around submit and sync, per kernel). The pictures compared: mean absolute difference per channel and
##   the share over 16/255 over the dish's disc, and over the lit pixels only (a pixel either picture differs from the bare dish in),
##   each density look against capsule, and point against capsule.
##
## Expected values, written before the first run:
## - density's view_build at 2M fit zoom about 3.1 ms of splat and resolve plus the capsule kernels' 1 ms [measured, 3.1 ms on a
##   local device with a buffer for the sums and no quad; the view kernels' cost on 2M is about 1 ms [derived]]. At fit zoom
##   every bup is small (375 µm a pixel), so the capsule kernels find nothing after the first build.
## - capsule frame at 2M fit zoom about 10 ms over hidden [measured, 10.1 ms]; point path about 27.7 ms [measured].
## - The running 2M fit zoom: 39.9 ms with the bups shown, 8.4 ms hidden [measured]. Density is expected to take the shown figure
##   down by about the capsule path's 10 ms less the splat's 3 ms: about 33 ms [derived: 39.9 - 10.1 + 3.1; the simulation's load is
##   unchanged], still over gate F's frame; the rest is the simulation sharing the GPU, which no drawing choice here changes.
## - density against capsule at fit zoom: within a measured tolerance (mean absolute difference per channel <= 2/255 over the dish's disc,
##   <= 0.1% of the disc's pixels over 16/255) [derived: the same least footprint, summed and resolved with coverage 1 - exp(-area); two
##   footprints on one pixel differ from the single-dish path's product of the two uncovered shares by the second-order term of the coverage]. Over the
##   lit pixels alone the figures are larger by the lit share's inverse; reported, not gated.
## - sparse: every in-frame bup has a lit pixel within one pixel of it in both looks [derived: the least footprint is 2 x 1 pixels, 1.8
##   pixel², and bilinear taps keep 1.8 pixel² of coverage a bup over four pixels, the weakest 0.45 pixel² a pixel: alpha 0.36].
## - crossover: no jump: the density picture's mean absolute difference over the lit pixels does not step up as the share of bups drawn as
##   capsules passes through 0 to 1 [derived: the footprint at the crossover is the capsule's; a step would show a wrong area or colour].
##   The share of capsules between the pixel sizes 0.4 and 2 µm is a figure to be read off the run [placeholder: not derived].

const RADIUS := 90000.0
const STEP := 18.0
const T_ITER_MS := 25.0
const ZOOMS := [1.0, 20.0, 100.0, 500.0]
const ZOOM_NAMES := ["fit", "zoom20", "zoom100", "zoom500"]
const WARM := 15
const SAMPLE := 60
const VIEW := Vector2i(1280, 720)
const DENSITY_MODES := ["winner", "rod", "nearest"]  ## the density looks (each colours a pixel with a covering bup's colour): bilinear taps, a rod of two bilinear splats, one nearest tap
const LIT_DIFF := 2  ## a pixel is lit when a channel differs from the bare dish by this much or more
const BG := Color(0.09, 0.11, 0.15)

const POINT_SHADER := """
shader_type canvas_item;
uniform float pixel_um = 1.0;
varying vec4 body;
varying flat vec2 dir;
varying flat float psize;
void vertex() {
	body = INSTANCE_CUSTOM;
	vec2 ax = MODEL_MATRIX[0].xy;
	vec2 ay = MODEL_MATRIX[1].xy;
	float ql = length(ax), qw = length(ay);
	dir = ax / max(ql, 1e-9);
	psize = max(abs(dir.x) * ql + abs(dir.y) * qw, abs(dir.y) * ql + abs(dir.x) * qw) / pixel_um + 1.0;
	POINT_SIZE = psize;
	VERTEX = vec2(0.0);
}
void fragment() {
	vec2 pc = (POINT_COORD - vec2(0.5)) * psize;
	float along = dot(pc, dir);
	float across = dot(pc, vec2(-dir.y, dir.x));
	float total = (body.x + body.w) / pixel_um;
	float width = body.y / pixel_um;
	float half_straight = max(total * 0.5 - width * 0.5, 0.0);
	vec2 q = vec2(max(abs(along) - half_straight, 0.0), across);
	float d = length(q) - width * 0.5;
	COLOR.a *= clamp(0.5 - d / (abs(dir.x) + abs(dir.y)), 0.0, 1.0);
}
"""

var sub: SubViewport
var camera: Camera2D
var den_sprite: Sprite2D
var caps: MultiMeshInstance2D
var pts: MultiMeshInstance2D
var renderer: ViewRenderer
var mode := "hidden"
var COST_MODES := ["capsule", "winner", "rod", "nearest"]
var zoom := 1.0  ## screen pixels a µm (the camera's)
var cam_pos := Vector2.ZERO
var out := {}
var out_dir := ""

# running: shared with the simulation's thread (under mtx)
var mtx := Mutex.new()
var stop := false
var announce := {}
var run_spec: DishSpec
var sim_thread: Thread


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	out_dir = OS.get_environment("PACK_OUT") if OS.get_environment("PACK_OUT") != "" else ProjectSettings.globalize_path("res://tools/gpu/baseline/zoomed_out/density")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var a := OS.get_cmdline_user_args()
	print("DENSITY device %s, refresh %.1f Hz" % [RenderingServer.get_rendering_device().get_device_name(), DisplayServer.screen_get_refresh_rate(DisplayServer.window_get_current_screen())])
	_scene()
	match a[0] if a.size() > 0 else "":
		"pack":
			await _pack(_counts())
		"fit":
			await _pack(_counts(), [1.0])
		"smoke":
			await _pack([10000], [1.0])
		"cost":
			COST_MODES = ["capsule", "winner", "rod"]
			var fit := minf(VIEW.x * 0.5 - 40.0, VIEW.y * 0.5 - 120.0) / RADIUS
			for n: int in _counts():
				var spec := _spec(1, n, n, 0.9)
				var cost := _buildcost(spec, _densest(spec), fit, [1.0])
				print("DENSITY COST %s %s" % [_label(n), JSON.stringify(cost)])
		"sparse":
			await _sparse()
		"crossover":
			await _crossover()
		"running":
			await _running(float(OS.get_environment("RUN_SECONDS")) if OS.get_environment("RUN_SECONDS") != "" else 8.0)
		_:
			print("usage: pack | smoke | sparse | crossover | running")
	quit(0)


func _counts() -> Array:
	var c: Array = []
	var env := OS.get_environment("PACK_COUNTS")
	for s in (env if env != "" else "10000,100000,1000000,2000000").split(","):
		c.append(int(s))
	return c


func _frames(n: int) -> void:
	for i in n:
		await process_frame


# ---- the scene -----------------------------------------------------------------------------------------------------------------------

func _scene() -> void:
	sub = SubViewport.new()
	sub.size = VIEW
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sub)
	camera = Camera2D.new()
	sub.add_child(camera)
	var disc := Polygon2D.new()
	var ring := PackedVector2Array()
	for i in 256:
		ring.append(Vector2.from_angle(TAU * i / 256.0) * RADIUS)
	disc.polygon = ring
	disc.color = BG
	sub.add_child(disc)
	den_sprite = Sprite2D.new()
	den_sprite.centered = false
	den_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	den_sprite.visible = false
	sub.add_child(den_sprite)
	var capacity := ceili(2000000 * 1.05)
	caps = _mesh_node(false, capacity)
	pts = _mesh_node(true, capacity)
	sub.add_child(caps)
	sub.add_child(pts)


func _mesh_node(points: bool, capacity: int) -> MultiMeshInstance2D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	if points:
		var am := ArrayMesh.new()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2.ZERO])
		am.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
		mm.mesh = am
	else:
		var q := QuadMesh.new()
		q.size = Vector2.ONE
		mm.mesh = q
	mm.instance_count = capacity
	mm.custom_aabb = AABB(Vector3(-RADIUS, -RADIUS, -1.0), Vector3(2.0 * RADIUS, 2.0 * RADIUS, 2.0))
	var node := MultiMeshInstance2D.new()
	node.multimesh = mm
	var m := ShaderMaterial.new()
	m.shader = Shader.new()
	m.shader.code = POINT_SHADER if points else Dish.BUP_SHADER
	if not points:
		m.set_shader_parameter("fade_pixels", Dish.TRAIL_FADE_PIXELS)
	node.material = m
	node.visible = false
	return node


func _view(centre: Vector2, z: float) -> void:
	cam_pos = centre
	zoom = z
	camera.position = centre
	camera.zoom = Vector2.ONE * z
	(pts.material as ShaderMaterial).set_shader_parameter("pixel_um", 1.0 / z)


func _camera_rect() -> Rect2:
	var size := Vector2(VIEW) / zoom
	return Rect2(cam_pos - size * 0.5, size)


## The look: "capsule" (today), "winner" (density mode, bilinear taps), "rod" (density as two bilinear splats along the axis), "nearest" (density with
## nearest taps), "point", or "hidden" (the bare dish).
func _apply_mode(m: String) -> void:
	mode = m
	renderer.set_density(m in DENSITY_MODES, _taps(m))
	caps.visible = m == "capsule" or m in DENSITY_MODES
	pts.visible = m == "point"
	den_sprite.visible = m in DENSITY_MODES


static func _taps(m: String) -> int:
	match m:
		"nearest":
			return GpuKernelsView.DENSITY_NEAREST
		"rod":
			return GpuKernelsView.DENSITY_ROD
	return GpuKernelsView.DENSITY_BILINEAR


## Builds the view's instances for this frame (`force`: whatever the last build was) and puts the density picture where the camera is.
func _draw_frame(force: bool) -> void:
	renderer.tick()
	if mode == "hidden":
		return
	if force:
		renderer.forget_build()
	var rect := _camera_rect()
	var node := pts if mode == "point" else caps
	var mm := node.multimesh
	renderer.draw_into(rect, 1.0 / zoom, RenderingServer.multimesh_get_buffer_rd_rid(mm.get_rid()), mm.instance_count, mm.get_rid())
	if den_sprite.visible:
		var tex := renderer.density_texture()
		if tex != null:
			den_sprite.texture = tex
			den_sprite.position = rect.position
			den_sprite.scale = Vector2.ONE / zoom


func _settle(force: bool, n := 6) -> void:
	for i in n:
		_draw_frame(force)
		await process_frame


func _grab() -> Image:
	var img := sub.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img


func _measure(force: bool) -> Dictionary:
	var ms: Array = []
	var last := Time.get_ticks_usec()
	for i in WARM + SAMPLE:
		_draw_frame(force)
		await process_frame
		var now := Time.get_ticks_usec()
		if i >= WARM:
			ms.append((now - last) / 1000.0)
		last = now
	return {"frame_ms": _summary(ms)}


# ---- states --------------------------------------------------------------------------------------------------------------------------

## A dish of `n` bups (limit `limit`): the founder's genes over `spread` of a 90 mm dish, reserves from none to full,
## masses 0.8 to 1.6 of the birth mass.
static func _spec(number: int, n: int, limit: int, spread: float) -> DishSpec:
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
	var hues := RandomNumberGenerator.new()  ## its own stream, so the positions above do not move
	hues.seed = 3000000 + number
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
		f[o + GpuLayout.R_HUE] = hues.randf()
		f[o + GpuLayout.R_SAT] = hues.randf_range(0.6, 1.0)
		f[o + GpuLayout.R_VAL] = hues.randf_range(0.7, 1.0)
	var recs := f.to_byte_array()
	for i in n:
		GpuLayout.set_id(recs, i, (i + 1))
	spec.founders = recs
	return spec


## The middle of the densest 1 mm bin of a state's bups.
static func _densest(spec: DishSpec) -> Vector2:
	var f := spec.founders.to_float32_array()
	var n := f.size() / GpuLayout.RECORD_WORDS
	var side := 181
	var bins := PackedInt32Array()
	bins.resize(side * side)
	var best := 0
	var best_bin := 0
	for i in n:
		var o := i * GpuLayout.RECORD_WORDS
		var bx := clampi(int((f[o + GpuLayout.R_X] + RADIUS) / 1000.0), 0, side - 1)
		var by := clampi(int((f[o + GpuLayout.R_Y] + RADIUS) / 1000.0), 0, side - 1)
		var k := by * side + bx
		bins[k] += 1
		if bins[k] > best:
			best = bins[k]
			best_bin = k
	return Vector2((best_bin % side) * 1000.0 + 500.0 - RADIUS, (best_bin / side) * 1000.0 + 500.0 - RADIUS)


static func _positions(spec: DishSpec) -> PackedVector2Array:
	var f := spec.founders.to_float32_array()
	var n := f.size() / GpuLayout.RECORD_WORDS
	var p := PackedVector2Array()
	p.resize(n)
	for i in n:
		p[i] = Vector2(f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_X], f[i * GpuLayout.RECORD_WORDS + GpuLayout.R_Y])
	return p


static func _payload_info(core: SimCore, row: int, index: int, generation: int, seq: int) -> PayloadInfo:
	var info := PayloadInfo.new()
	info.texture_index = index
	info.count = core.count(row)
	info.row = row
	info.generation = generation
	info.seq = seq
	info.handles = ViewRenderer.driver_handles(core.rd, core.textures("payload"))
	info.id_handles = ViewRenderer.driver_handles(core.rd, core.textures("ids"))
	var f := core.rd.texture_get_format(core.textures("payload")[0])
	info.size = Vector2i(f.width, f.height)
	return info


static func _frame_queue() -> int:
	return int(ProjectSettings.get_setting("rendering/rendering_device/vsync/frame_queue_size", 2))


## Opens a paused state on the main device: a SimCore (its own device, sharing the textures), one step run, published, imported.
func _open(spec: DishSpec) -> SimCore:
	var core := SimCore.new()
	if not core.errors.is_empty():
		print("SimCore errors: %s" % [core.errors])
	var row := core.add_dish(spec)
	core.run(1, STEP)
	var req := ViewRequest.new()
	req.row = row
	var pub := core.publish(req)
	renderer = ViewRenderer.new(_frame_queue())
	renderer.set_density(true)
	renderer.set_density(false)
	print("ViewRenderer errors: %s, count %d" % [renderer.errors, core.count(row)])
	renderer.set_payload(_payload_info(core, row, pub["payload"], 1, 1))
	return core


func _close(core: SimCore) -> void:
	den_sprite.texture = null
	renderer.release()
	await _frames(6)
	core.release()
	await _frames(2)


# ---- pictures compared ---------------------------------------------------------------------------------------------------------------

## `a` against `b` over a disc of `disc_px` round the middle: the mean absolute difference per channel and the share of pixels over
## 16/255, over all of it and over the lit pixels (a pixel either picture differs from `bg` in by LIT_DIFF or more); and the lit counts.
static func _diff(a: Image, b: Image, bg: Image, disc_px: float) -> Dictionary:
	var da := a.get_data()
	var db := b.get_data()
	var dg := bg.get_data()
	var w := a.get_width()
	var h := a.get_height()
	var r2 := disc_px * disc_px
	var n := 0
	var sum := 0
	var over := 0
	var lit_a := 0
	var lit_b := 0
	var lit_u := 0
	var lit_sum := 0
	var lit_over := 0
	for y in h:
		var dy := y + 0.5 - h * 0.5
		for x in w:
			var dx := x + 0.5 - w * 0.5
			if dx * dx + dy * dy > r2:
				continue
			var o := (y * w + x) * 4
			var s := 0
			var worst := 0
			var wa := 0
			var wb := 0
			for c in 3:
				var d := absi(da[o + c] - db[o + c])
				s += d
				worst = maxi(worst, d)
				wa = maxi(wa, absi(da[o + c] - dg[o + c]))
				wb = maxi(wb, absi(db[o + c] - dg[o + c]))
			n += 1
			sum += s
			if worst > 16:
				over += 1
			var la := wa >= LIT_DIFF
			var lb := wb >= LIT_DIFF
			lit_a += 1 if la else 0
			lit_b += 1 if lb else 0
			if la or lb:
				lit_u += 1
				lit_sum += s
				if worst > 16:
					lit_over += 1
	return {
		"mean_abs_disc": snappedf(sum / (3.0 * maxf(n, 1)), 0.0001),
		"share_over_16_disc": snappedf(float(over) / maxf(n, 1), 0.000001),
		"mean_abs_lit": snappedf(lit_sum / (3.0 * maxf(lit_u, 1)), 0.001),
		"share_over_16_lit": snappedf(float(lit_over) / maxf(lit_u, 1), 0.0001),
		"lit_a": lit_a, "lit_b": lit_b, "lit_union": lit_u, "disc_pixels": n,
	}


static func _summary(v: Array) -> Dictionary:
	if v.is_empty():
		return {}
	var s := v.duplicate()
	s.sort()
	var total := 0.0
	for x in s:
		total += float(x)
	return {"n": s.size(), "mean": snappedf(total / s.size(), 0.001), "p50": snappedf(s[s.size() / 2], 0.001), "p95": snappedf(s[mini(int(s.size() * 0.95), s.size() - 1)], 0.001), "max": snappedf(s[-1], 0.001)}


static func _label(n: int) -> String:
	if n >= 1000000:
		return "%dm" % (n / 1000000)
	return "%dk" % (n / 1000)


# ---- pack ----------------------------------------------------------------------------------------------------------------------------

func _pack(counts: Array, mults := ZOOMS) -> void:
	var fit := minf(VIEW.x * 0.5 - 40.0, VIEW.y * 0.5 - 120.0) / RADIUS
	var rows := {}
	for n: int in counts:
		var spec := _spec(1, n, n, 0.9)
		var centre := _densest(spec)
		var cost := _buildcost(spec, centre, fit, mults)
		var core := _open(spec)
		await _frames(3)
		for zi in mults.size():
			var z: float = fit * mults[zi]
			_view(Vector2.ZERO if zi == 0 else centre, z)
			var key := "%s_%s" % [_label(n), ZOOM_NAMES[ZOOMS.find(mults[zi])]]
			var row := {"zoom_px_per_um": z, "centre": [cam_pos.x, cam_pos.y]}
			var imgs := {}
			for m: String in ["hidden", "capsule", "winner", "rod", "nearest", "point"]:
				_apply_mode(m)
				await _settle(true)
				imgs[m] = _grab()
				row[m] = await _measure(true)
				if m in ["capsule", "winner", "rod", "point"]:
					imgs[m].save_png(out_dir.path_join("%s_%s.png" % [key, m]))
			var disc := RADIUS * z
			row["rod_vs_capsule"] = _diff(imgs["rod"], imgs["capsule"], imgs["hidden"], disc)
			row["nearest_vs_capsule"] = _diff(imgs["nearest"], imgs["capsule"], imgs["hidden"], disc)
			row["point_vs_capsule"] = _diff(imgs["point"], imgs["capsule"], imgs["hidden"], disc)
			row["winner_vs_capsule"] = _diff(imgs["winner"], imgs["capsule"], imgs["hidden"], disc)
			row["build"] = cost.get(ZOOM_NAMES[ZOOMS.find(mults[zi])], {})
			row["visible_density"] = renderer._visible.get("count", -1)
			row["large_density"] = renderer._large.get("count", -1)
			rows[key] = row
			print("DENSITY PACK %s %s" % [key, JSON.stringify(row)])
		await _close(core)
	out["rows"] = rows
	var labels: Array = counts.map(_label)
	var f := FileAccess.open(out_dir.path_join("pack_%s.json" % "_".join(labels)), FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "\t"))
	f.close()


## view_build's cost on a local device (no frame around it) for each look at each zoom of the pack.
func _buildcost(spec: DishSpec, centre: Vector2, fit: float, mults: Array) -> Dictionary:
	var dev := RenderingServer.create_local_rendering_device()
	var core := SimCore.new(null, false, dev)
	var row := core.add_dish(spec)
	core.run(1, STEP)
	var req := ViewRequest.new()
	req.row = row
	var pub := core.publish(req)
	var view := ViewRenderer.new(2, dev)
	view.set_density(true)
	view.set_payload(_payload_info(core, row, pub["payload"], 1, 1))
	var n := core.count(row)
	var capacity := ceili(n * 1.05)
	var inst := dev.storage_buffer_create(capacity * 64)
	var result := {}
	for zi in mults.size():
		var z: float = fit * mults[zi]
		var px := 1.0 / z
		var c := Vector2.ZERO if zi == 0 else centre
		var cam := Rect2(c - Vector2(VIEW) * 0.5 * px, Vector2(VIEW) * px)
		var per_mode := {}
		for m: String in COST_MODES:
			view.set_density(m != "capsule", _taps(m))
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
				per[k] = _summary(kernels[k]).get("p50", 0.0)
			per_mode[m] = {"build_ms": _summary(whole), "kernel_ms_p50": per, "visible": view._visible.get("count", -1), "large": view._large.get("count", -1)}
		result[ZOOM_NAMES[ZOOMS.find(mults[zi])]] = per_mode
	if not (view.errors + core.errors).is_empty():
		print("DENSITY buildcost errors: %s" % [view.errors + core.errors])
	dev.free_rid(inst)
	view.release()
	core.release()
	dev.free()
	return result


# ---- sparse --------------------------------------------------------------------------------------------------------------------------

func _sparse() -> void:
	var spec := _spec(1, 1500, 1500, 0.9)
	var pos := _positions(spec)
	var core := _open(spec)
	await _frames(3)
	var fit := minf(VIEW.x * 0.5 - 40.0, VIEW.y * 0.5 - 120.0) / RADIUS
	var rows := {}
	for mult: float in [1.0, 4.0]:
		var z := fit * mult
		_view(Vector2.ZERO, z)
		var imgs := {}
		for m: String in ["hidden", "capsule", "winner", "rod", "nearest", "point"]:
			_apply_mode(m)
			await _settle(true)
			imgs[m] = _grab()
		var row := {"zoom_px_per_um": z}
		for m: String in ["capsule", "winner", "rod", "nearest", "point"]:
			row[m] = _sparse_count(imgs[m], imgs["hidden"], pos, z)
		rows["x%s" % str(mult)] = row
		print("DENSITY SPARSE x%s %s" % [str(mult), JSON.stringify(row)])
	out["sparse"] = rows
	await _close(core)


## Lit pixels, and how many of the bups inside the frame have a lit pixel within one pixel of where they are.
func _sparse_count(img: Image, bg: Image, pos: PackedVector2Array, z: float) -> Dictionary:
	var d := img.get_data()
	var g := bg.get_data()
	var w := img.get_width()
	var h := img.get_height()
	var lit := PackedByteArray()
	lit.resize(w * h)
	var n_lit := 0
	for k in w * h:
		var o := k * 4
		if maxi(maxi(absi(d[o] - g[o]), absi(d[o + 1] - g[o + 1])), absi(d[o + 2] - g[o + 2])) >= LIT_DIFF:
			lit[k] = 1
			n_lit += 1
	var inside := 0
	var seen := 0
	for p in pos:
		var px := (p - cam_pos) * z + Vector2(w, h) * 0.5
		var ix := int(floor(px.x))
		var iy := int(floor(px.y))
		if ix < 1 or iy < 1 or ix >= w - 1 or iy >= h - 1:
			continue
		inside += 1
		var found := false
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if lit[(iy + dy) * w + ix + dx] == 1:
					found = true
		if found:
			seen += 1
	return {"bups_in_frame": inside, "with_lit_pixel": seen, "lit_pixels": n_lit, "lit_per_bup": snappedf(float(n_lit) / maxf(inside, 1), 0.01)}


# ---- crossover -----------------------------------------------------------------------------------------------------------------------

func _crossover() -> void:
	var spec := _spec(1, 200000, 200000, 500.0 / RADIUS)
	var core := _open(spec)
	await _frames(3)
	var rows := {}
	for z: float in [0.4, 0.5, 0.65, 0.8, 1.0, 1.25, 1.6]:
		_view(Vector2.ZERO, z)
		var imgs := {}
		for m: String in ["hidden", "capsule", "winner", "rod", "nearest"]:
			_apply_mode(m)
			await _settle(true)
			imgs[m] = _grab()
			if m == "winner":
				var large: int = renderer._large.get("count", -1)
				rows["z%s" % str(z)] = {"pixel_um": snappedf(1.0 / z, 0.001), "large": large}
		var row: Dictionary = rows["z%s" % str(z)]
		var disc := RADIUS * z
		row["winner_vs_capsule"] = _diff(imgs["winner"], imgs["capsule"], imgs["hidden"], disc)
		row["rod_vs_capsule"] = _diff(imgs["rod"], imgs["capsule"], imgs["hidden"], disc)
		row["nearest_vs_capsule"] = _diff(imgs["nearest"], imgs["capsule"], imgs["hidden"], disc)
		if OS.get_environment("CROSS_PNG") != "":
			imgs["capsule"].save_png(out_dir.path_join("cross_%s_capsule.png" % str(z)))
			imgs["winner"].save_png(out_dir.path_join("cross_%s_winner.png" % str(z)))
		print("DENSITY CROSSOVER z%s %s" % [str(z), JSON.stringify(row)])
	out["crossover"] = rows
	await _close(core)


# ---- running -------------------------------------------------------------------------------------------------------------------------

func _sim_main() -> void:
	var core := SimCore.new()
	var row := core.add_dish(run_spec)
	var gens := {}
	var step_ms := 20.0
	var seq := 0
	while true:
		mtx.lock()
		var st := stop
		var r := renderer
		mtx.unlock()
		if st:
			break
		if r != null:
			for b: Array in r.take_bound():
				core.texture_bound(b[0], b[1], b[2], b[3])
		var k := clampi(int(T_ITER_MS / maxf(step_ms, 0.1)), 1, 64)
		var res := core.run(k, STEP)
		if int(res.get("steps", 0)) > 0:
			step_ms = 0.8 * step_ms + 0.2 * float(res["gpu_usec"]) / 1000.0 / int(res["steps"])
		var req := ViewRequest.new()
		req.row = row
		var pub := core.publish(req)
		if not pub.has("payload"):  # (no free texture this time: nothing published, nothing to announce)
			OS.delay_msec(1)
			continue
		var rids: Array = core.textures("payload")
		if not gens.has("payload") or gens["payload"][0] != rids:
			gens["payload"] = [rids.duplicate(), int(gens.get("payload", [[], 0])[1]) + 1]
		var info := _payload_info(core, row, pub["payload"], gens["payload"][1], core.publish_seq)
		mtx.lock()
		announce = {"info": info}
		mtx.unlock()
		seq += 1
	core.release()


## 2M bups at fit zoom with a simulation running on a thread: each look for RUN_SECONDS, the frames' intervals and how many payloads the
## simulation published meanwhile. Measured at the same state: 39.9 ms shown, 8.4 hidden.
func _running(seconds: float) -> void:
	run_spec = _spec(1, 2000000, 2000000, 0.9)
	var fit := minf(VIEW.x * 0.5 - 40.0, VIEW.y * 0.5 - 120.0) / RADIUS
	_view(Vector2.ZERO, fit)
	sim_thread = Thread.new()
	sim_thread.start(_sim_main)
	var waited := 0
	while waited < 20000:
		mtx.lock()
		var has := announce.has("info")
		mtx.unlock()
		if has:
			break
		await process_frame
		waited += 1
	renderer = ViewRenderer.new(_frame_queue())
	renderer.set_density(true)
	print("ViewRenderer errors: %s" % [renderer.errors])
	var last_seq := -1
	var phases := {}
	var order := ["capsule", "winner", "hidden"]
	for pi in order.size():
		var m: String = order[pi]
		_apply_mode(m)
		var ms: Array = []
		var seen := 0
		var t0 := Time.get_ticks_usec()
		var last := t0
		while (Time.get_ticks_usec() - t0) / 1e6 < seconds + 2.0:
			mtx.lock()
			var info: PayloadInfo = announce["info"]
			mtx.unlock()
			if info.seq != last_seq:
				last_seq = info.seq
				renderer.set_payload(info)
				if (Time.get_ticks_usec() - t0) / 1e6 >= 2.0:
					seen += 1
			_draw_frame(false)
			await process_frame
			var now := Time.get_ticks_usec()
			if (now - t0) / 1e6 >= 2.0:
				ms.append((now - last) / 1000.0)
			last = now
		phases["%d_%s" % [pi, m]] = {"frame_ms": _summary(ms), "publishes_per_s": snappedf(seen / seconds, 0.1), "visible": renderer._visible.get("count", -1), "large": renderer._large.get("count", -1)}
		print("DENSITY RUNNING %d_%s %s" % [pi, m, JSON.stringify(phases["%d_%s" % [pi, m]])])
	out["running"] = phases
	den_sprite.texture = null
	renderer.release()
	await _frames(6)
	mtx.lock()
	stop = true
	mtx.unlock()
	sim_thread.wait_to_finish()
	print("DENSITY RUNNING DONE")
