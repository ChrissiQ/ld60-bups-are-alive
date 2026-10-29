extends SceneTree
## The acceptance of the GPU's picture of the bups against the CPU's.
##   godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/draw_check.gd -- <bups> <out_dir> [time] > out.txt
## (out_dir gets the screenshots: not the user-data folder, which the game shares)
## A. Numbers (a local device): one state loaded into the CPU's BupSim and into a GpuSim; BupSim.render_buffer(px, cap) against the
##    render kernel (GpuDraw into a plain buffer) for three pictures: the first with a capacity past the count (zero slots), then
##    every bup moved (trails) and a picture with fewer slots than bups, then moved again and drawn in full (the bups left out of the
##    second picture must have no trail). Every float within 2e-5 relative (see `compare`), colours within 1/255, and the GPU's notes
##    of where each bup was drawn (record words 22, 23) equal the CPU's.
## B. Pictures (the main device, through the dish): the same state drawn by Dish's CPU path and by its GPU path
##    (gpu_world.draw_bups into the MultiMesh's RD buffer); both screenshots saved and compared pixel by pixel, the first picture
##    (with trails) and a later one (none), and the MultiMesh's buffer read back against render_buffer.
## C. ("time") What the render kernel costs: local device, wall time of submit and sync, for some sizes; and the dish's frame time
##    with the GPU path drawing every frame into a MultiMesh at a 1,000,000-bup capacity.
## GPU_FROM_SOURCE=1 compiles the kernels from GpuKernels.all() instead of the imported files.

const REL := 2e-5
const COLOUR_TOL := 1.0 / 255.0

var fails := 0
var out_dir := ""
var from_source := OS.get_environment("GPU_FROM_SOURCE") == "1"


## A GpuWorld whose count is set by the check.
class CountedWorld extends GpuWorld:
	var known := 0

	func bup_count() -> int:
		return known


func _initialize() -> void:
	_run.call_deferred()


var passes := 0


func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if ok:
		passes += 1
	if not ok:
		fails += 1


func _make_dish(n: int, rad: float, seed_value: int, bup_limit := 2000000) -> Dish:
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(seed_value)
	var sc := StartConditions.new()
	sc.bups = 250; sc.bup_limit = bup_limit; sc.dish_radius = rad; sc.nutrient_resolution = 100; sc.nutrient_density = 4.0
	sc.spread_founders()
	dish.strike(sc)
	var sim := dish.sim
	while dish.population() < n:
		var g := Genome.founder()
		var born := Cell.mass_to_add(g)
		sim.add_bup(sim.random_point(rad * 0.95), g, Dish.FOUNDER_ENERGY, sqrt(born * 1.5) * randf_range(0.5, 3.0), born, 0, Vector2.from_angle(randf() * TAU))
	return dish


## The records of `dish` with colours spread over every sector of the hue (and a few edge values), some grey, and for the trails:
## a third with no last picture, a third drawn last a little way off (less than its length: no trail), a third far off (a trail,
## some longer than the longest drawn).
func _crafted(dish: Dish, rng: RandomNumberGenerator, near_um: float, far_um: float) -> PackedByteArray:
	var rec := dish.sim.export_state_bytes()
	var count := rec.size() / GpuLayout.RECORD_BYTES
	var edges := [0.0, 1.0 / 6.0, 2.0 / 6.0, 0.5, 4.0 / 6.0, 5.0 / 6.0, 0.99999994]
	for i in count:
		var o := i * GpuLayout.RECORD_BYTES
		var hue := rng.randf() if i % 50 != 0 else float(edges[(i / 50) % edges.size()])
		rec.encode_float(o + 16 * 4, hue)
		rec.encode_float(o + 17 * 4, 0.0 if i % 13 == 0 else rng.randf())
		rec.encode_float(o + 18 * 4, rng.randf_range(0.2, 1.0))
		var x := rec.decode_float(o + 4)
		var y := rec.decode_float(o + 8)
		match i % 3:
			0:
				rec.encode_float(o + 22 * 4, GpuLayout.NO_PICTURE)
				rec.encode_float(o + 23 * 4, GpuLayout.NO_PICTURE)
			1:
				var a := rng.randf() * TAU
				rec.encode_float(o + 22 * 4, x + cos(a) * near_um)
				rec.encode_float(o + 23 * 4, y + sin(a) * near_um)
			2:
				var a := rng.randf() * TAU
				var d := rng.randf_range(0.2, 1.0) * far_um
				rec.encode_float(o + 22 * 4, x + cos(a) * d)
				rec.encode_float(o + 23 * 4, y + sin(a) * d)
	return rec


## Moves every bup of a block of records (the same displacement for the same index, given the same seed).
func _moved(rec: PackedByteArray, seed_value: int, far_um: float) -> PackedByteArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out := rec.duplicate()
	for i in out.size() / GpuLayout.RECORD_BYTES:
		var o := i * GpuLayout.RECORD_BYTES
		var a := rng.randf() * TAU
		var d := rng.randf() * far_um if i % 4 != 0 else rng.randf() * 0.5  # (a quarter barely move: no trail)
		out.encode_float(o + 4, out.decode_float(o + 4) + cos(a) * d)
		out.encode_float(o + 8, out.decode_float(o + 8) + sin(a) * d)
	return out


func _load(gpu: GpuSim, dish: Dish, rec: PackedByteArray) -> void:
	var field := dish.field
	var state := GpuSim.State.of_grid(field, dish.radius, rec, SimConstants.build())
	state.limit = maxi(rec.size() / GpuLayout.RECORD_BYTES, 1000)
	gpu.load_state(state)


func _gpu_picture(gpu: GpuSim, cap: int, pixel_um: float) -> PackedFloat32Array:
	var buf := gpu.rd.storage_buffer_create(cap * 64)
	GpuDraw.of(gpu).draw(gpu, buf, cap, pixel_um)
	var out := gpu.rd.buffer_get_data(buf).to_float32_array()
	gpu.rd.free_rid(buf)
	return out


## Compares two pictures: transform and custom floats within REL of the larger magnitude, or (for a component near zero, such as the
## sine part of an axis that is nearly straight) within REL of the instance's own scale (its quad's length); colours within COLOUR_TOL.
func compare(label: String, cpu: PackedFloat32Array, gpu: PackedFloat32Array, live: int) -> void:
	if cpu.size() != gpu.size():
		check(false, "%s: sizes %d (CPU) and %d (GPU)" % [label, cpu.size(), gpu.size()])
		return
	var worst_rel := 0.0
	var worst_at := -1
	var worst_colour := 0.0
	var by_scale := 0
	var bad := 0
	var trails := 0
	var zero_bad := 0
	for s in cpu.size() / 16:
		var o := s * 16
		if s >= live:
			for j in 16:
				if gpu[o + j] != 0.0:
					zero_bad += 1
			continue
		if cpu[o + 15] > 0.0:
			trails += 1
		var scale := maxf(absf(cpu[o + 12]) + absf(cpu[o + 15]), absf(cpu[o + 13]))
		for j in 16:
			var a := cpu[o + j]
			var b := gpu[o + j]
			if j >= 8 and j < 12:
				var dc := absf(a - b)
				worst_colour = maxf(worst_colour, dc)
				if dc > COLOUR_TOL:
					bad += 1
					if bad <= 5:
						print("    %s slot %d colour word %d: CPU %f GPU %f" % [label, s, j, a, b])
				continue
			var diff := absf(a - b)
			var mag := maxf(absf(a), absf(b))
			var rel := diff / mag if mag > 0.0 else 0.0
			if diff <= REL * mag:
				if rel > worst_rel:
					worst_rel = rel
					worst_at = o + j
				continue
			if diff <= REL * scale:
				by_scale += 1
				continue
			bad += 1
			if bad <= 5:
				print("    %s slot %d word %d: CPU %.9f GPU %.9f (rel %s, scale %f)" % [label, s, j, a, b, rel, scale])
	print("  %s: %d slots, %d live, %d with trails; largest relative difference %s (slot %d word %d), %d near-zero components within REL of their instance's scale, largest colour difference %.6f (%.3f/255)" % [label, cpu.size() / 16, live, trails, worst_rel, worst_at / 16, worst_at % 16, by_scale, worst_colour, worst_colour * 255.0])
	check(bad == 0 and zero_bad == 0, "%s: every float within %s, colours within 1/255, slots past the count all zero (%d wrong, %d non-zero past the count)" % [label, REL, bad, zero_bad])


## The GPU's notes of where each bup was drawn (words 22, 23) against the CPU's.
func compare_places(label: String, cpu_rec: PackedByteArray, gpu_rec: PackedByteArray) -> void:
	var bad := 0
	var n := mini(cpu_rec.size(), gpu_rec.size()) / GpuLayout.RECORD_BYTES
	for i in n:
		for w in [22, 23]:
			var a := cpu_rec.decode_float(i * GpuLayout.RECORD_BYTES + w * 4)
			var b := gpu_rec.decode_float(i * GpuLayout.RECORD_BYTES + w * 4)
			if a != b:
				bad += 1
				if bad <= 3:
					print("    %s bup %d word %d: CPU %f GPU %f" % [label, i, w, a, b])
	check(bad == 0 and cpu_rec.size() == gpu_rec.size(), "%s: the last picture's place (words 22, 23) of every bup equals the CPU's (%d differ of %d)" % [label, bad, n * 2])


func part_a(n: int) -> void:
	print("== A: numbers, %d bups, local device" % n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	seed(7)
	var dish := _make_dish(n, 3000.0, 3)
	var rec := _crafted(dish, rng, 0.3, 400.0)
	dish.sim.import_state_bytes(rec)
	var gpu := GpuSim.new(null, from_source)
	print("GPU: ", gpu.device_name(), " | kernels from source: ", from_source)
	_load(gpu, dish, rec)
	var count := rec.size() / GpuLayout.RECORD_BYTES
	# 1: true size (fine pixels), more slots than bups
	var px1 := 0.05
	var cap1 := count + 37
	compare("picture 1 (%.2f um/px, %d slots)" % [px1, cap1], dish.sim.render_buffer(px1, cap1), _gpu_picture(gpu, cap1, px1), count)
	compare_places("picture 1", dish.sim.export_state_bytes(), gpu.read_bups())
	# 2: every bup moved; coarse pixels (most drawn at the least that shows), fewer slots than bups
	var cpu_rec := _moved(dish.sim.export_state_bytes(), 21, 300.0)
	var gpu_rec := _moved(gpu.read_bups(), 21, 300.0)
	dish.sim.import_state_bytes(cpu_rec)
	_load(gpu, dish, gpu_rec)  # (new buffers: buffers_rebuilt, so the kernel's set is made again)
	var px2 := 8.0
	var cap2 := count - 100
	compare("picture 2 (moved, %.2f um/px, %d slots)" % [px2, cap2], dish.sim.render_buffer(px2, cap2), _gpu_picture(gpu, cap2, px2), cap2)
	compare_places("picture 2", dish.sim.export_state_bytes(), gpu.read_bups())
	# 3: moved again, all drawn: the 100 left out of picture 2 have no last place, so no trail
	cpu_rec = _moved(dish.sim.export_state_bytes(), 22, 300.0)
	gpu_rec = _moved(gpu.read_bups(), 22, 300.0)
	dish.sim.import_state_bytes(cpu_rec)
	_load(gpu, dish, gpu_rec)
	var px3 := 1.5
	var cpu3 := dish.sim.render_buffer(px3, cap1)
	var gpu3 := _gpu_picture(gpu, cap1, px3)
	compare("picture 3 (moved again, %.2f um/px, %d slots)" % [px3, cap1], cpu3, gpu3, count)
	var left_out_trails := 0
	for s in range(cap2, count):
		if gpu3[s * 16 + 15] != 0.0 or cpu3[s * 16 + 15] != 0.0:
			left_out_trails += 1
	check(left_out_trails == 0, "picture 3: the 100 bups left out of picture 2 are drawn with no trail (%d with one)" % left_out_trails)
	compare_places("picture 3", dish.sim.export_state_bytes(), gpu.read_bups())
	dish.queue_free()


## Every pixel of two screenshots: how many differ by more than 2/255 in a channel, and the largest difference.
func compare_images(label: String, a: Image, b: Image) -> void:
	if a.get_size() != b.get_size():
		check(false, "%s: sizes differ" % label)
		return
	var differ := 0
	var worst := 0.0
	var covered := 0
	var bg := a.get_pixel(2, 2)
	for y in a.get_height():
		for x in a.get_width():
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			var d := maxf(maxf(absf(p.r - q.r), absf(p.g - q.g)), absf(p.b - q.b))
			worst = maxf(worst, d)
			if d > 2.0 / 255.0:
				differ += 1
			if not p.is_equal_approx(bg):
				covered += 1
	print("  %s: %d pixels differ by more than 2/255 (of %d not background), largest difference %.4f (%.1f/255)" % [label, differ, covered, worst, worst * 255.0])
	check(differ == 0, "%s: the CPU's and the GPU's screenshots are the same" % label)


func part_b(n: int) -> void:
	print("== B: pictures through the dish, %d bups, main device" % n)
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		check(false, "B: no main RenderingDevice")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 12
	seed(8)
	var dish := _make_dish(n, 3000.0, 4)
	dish.position = Vector2(640, 360)
	dish.scale = Vector2.ONE * (340.0 / 3000.0)
	var rec := _crafted(dish, rng, 0.3, 250.0)
	# the CPU path
	dish.sim.import_state_bytes(rec)
	dish.drawing.stale = true
	dish.flash = 0.0  # (the new dish's lightning: it fades in real time, so it would differ between the two screenshots)
	await process_frame
	await RenderingServer.frame_post_draw
	var cpu1 := root.get_texture().get_image()
	for f in 2:
		await process_frame
		await RenderingServer.frame_post_draw
	var cpu3 := root.get_texture().get_image()
	cpu1.save_png(out_dir.path_join("cpu_first.png"))
	cpu3.save_png(out_dir.path_join("cpu_later.png"))
	var pixel := dish.pixel()
	dish.sim.import_state_bytes(rec)
	# the GPU path: the same state on the main device, the dish's GPU branch drawing
	var gpu := GpuSim.new(rd, from_source)
	check(gpu.is_main, "B: GpuSim on the main device (is_main)")
	_load(gpu, dish, rec)
	var reference := dish.sim.render_buffer(pixel, gpu.capacity)
	var world := CountedWorld.new(dish.sim)
	world.gpu = gpu
	world.known = rec.size() / GpuLayout.RECORD_BYTES
	dish.gpu_world = world
	dish.gpu_active = true
	dish.flash = 0.0
	await process_frame
	await RenderingServer.frame_post_draw
	var gpu1 := root.get_texture().get_image()
	var mm := dish.drawing.bups_mesh.multimesh
	print("  GPU path: MultiMesh instance_count %d (GPU capacity %d), visible %d" % [mm.instance_count, gpu.capacity, mm.visible_instance_count])
	compare("B: the MultiMesh's buffer after the GPU path's first picture", reference, RenderingServer.multimesh_get_buffer(mm.get_rid()), rec.size() / GpuLayout.RECORD_BYTES)
	for f in 2:
		await process_frame
		await RenderingServer.frame_post_draw
	var gpu3 := root.get_texture().get_image()
	gpu1.save_png(out_dir.path_join("gpu_first.png"))
	gpu3.save_png(out_dir.path_join("gpu_later.png"))
	compare_images("B: first picture (trails)", cpu1, gpu1)
	compare_images("B: later picture (still, no trails)", cpu3, gpu3)
	dish.gpu_active = false
	dish.gpu_world = null
	dish.queue_free()
	await process_frame


func _time_local(live: int, cap: int, slots := 0) -> void:
	var dish := _make_dish(mini(live, 2000), 45000.0, 5, cap)
	var one := dish.sim.export_state_bytes()
	var rec := PackedByteArray()
	while rec.size() < live * GpuLayout.RECORD_BYTES:
		rec.append_array(one)
	rec.resize(live * GpuLayout.RECORD_BYTES)
	var gpu := GpuSim.new(null, from_source)
	var field := dish.field
	var state := GpuSim.State.of_grid(field, dish.radius, rec, SimConstants.build())
	state.limit = cap
	gpu.load_state(state)
	var buf := gpu.rd.storage_buffer_create(gpu.capacity * 64)
	var draw := GpuDraw.of(gpu)
	var times := []
	for r in 12:
		var t0 := Time.get_ticks_usec()
		draw.draw(gpu, buf, slots if slots > 0 else gpu.capacity, 5.0)
		times.append(Time.get_ticks_usec() - t0)
	times = times.slice(2)
	times.sort()
	print("  local device, %d bups in %d slots: %d drawn: render kernel (submit + sync) median %d us, min %d, max %d" % [live, gpu.capacity, slots if slots > 0 else gpu.capacity, times[times.size() / 2], times[0], times[-1]])
	gpu.rd.free_rid(buf)
	dish.queue_free()


func part_c() -> void:
	print("== C: cost")
	for cfg in [[20000, 20000], [100000, 100000], [200000, 200000], [1000000, 1000000], [1000, 1000000], [1000, 1000000, 2048]]:
		_time_local(cfg[0], cfg[1], cfg[2] if cfg.size() > 2 else 0)
	# the dish's frame with the GPU path drawing every frame, at a 1M capacity: few bups and many
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for live in [1000, 1000000]:
		var dish := _make_dish(mini(live, 2000), 45000.0, 6, 1000000)
		dish.position = Vector2(640, 360)
		dish.scale = Vector2.ONE * (340.0 / 45000.0)
		var one := dish.sim.export_state_bytes()
		var rec := PackedByteArray()
		while rec.size() < live * GpuLayout.RECORD_BYTES:
			rec.append_array(one)
		rec.resize(live * GpuLayout.RECORD_BYTES)
		for mode in ["cpu", "gpu"]:
			if mode == "gpu":
				var gpu := GpuSim.new(RenderingServer.get_rendering_device(), from_source)
				var field := dish.field
				var state := GpuSim.State.of_grid(field, dish.radius, rec, SimConstants.build())
				state.limit = 1000000
				gpu.load_state(state)
				var world := CountedWorld.new(dish.sim)
				world.gpu = gpu
				world.known = live
				dish.gpu_world = world
				dish.gpu_active = true
			else:
				dish.sim.import_state_bytes(rec)
			var times := []
			for f in 60:
				dish.drawing.stale = true  # (a new picture every frame, as when time moves)
				await process_frame
				var t0 := Time.get_ticks_usec()
				await RenderingServer.frame_post_draw
				await process_frame
				times.append(Time.get_ticks_usec() - t0)
			times = times.slice(10)
			times.sort()
			print("  dish frame, %s path, %d bups, MultiMesh %d slots (%d drawn): median %d us, min %d, max %d (frame to frame, vsync off)" % [mode, live, dish.drawing.bups_mesh.multimesh.instance_count, dish.drawing.bups_mesh.multimesh.visible_instance_count, times[times.size() / 2], times[0], times[-1]])
		dish.gpu_active = false
		dish.gpu_world = null
		dish.queue_free()
		await process_frame


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: ... -s tools/gpu/draw_check.gd -- <bups> <out_dir> [time]")
		quit(1)
		return
	var n := int(args[0])
	out_dir = args[1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	SimConstants.apply()
	part_a(n)
	await part_b(n)
	if args.size() > 2 and args[2] == "time":
		await part_c()
	const EXPECTED := 11  # (the checks parts A and B make: fewer means a part stopped on an error)
	if passes + fails < EXPECTED:
		fails += 1
		print("FAIL only %d of the %d checks ran" % [passes + fails - 1, EXPECTED])
	print("SUMMARY draw_check: %s (%d passed)" % ["OK" if fails == 0 else "%d FAILED" % fails, passes])
	quit(0 if fails == 0 else 1)
