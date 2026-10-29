extends SceneTree
## The GPU path's questions against the CPU's answers on the same state: 20,000 bups with varied genomes (some on exactly the same spot,
## for ties) loaded onto the main RenderingDevice, asked through GpuWorld as the dish asks (no steps run: the questions go out at the end
## of each frame, as while paused), and the same asked of a CPU BupSim that imported the same records. pick_bup and the counts of
## nearest_and_count must be equal, the nearest distance within 1e-5 relative (float on the GPU, double on the CPU), population_stats
## and fraction_with_gene_at_least within 1e-5 relative. Then three tracked bups (bup_pos, bup_radius, bup_info against the CPU's), and
## the eraser (GpuWorld.erase_disc on the GPU's grid and clouds against NutrientField.erase_disc on a copy of the same field).
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/queries_check.gd [-- points]

const RADIUS := 3000.0
const BUPS := 20000
const ROUND_FRAMES := 4  ## frames a round of questions is asked before its answers are read (they come back in about 2)

var world: GpuWorld
var ref: BupSim
var rng := RandomNumberGenerator.new()
var points := 300
var round_index := 0
var frame_in_round := 0
var pick_q := []  ## [point, slack, pixel]
var near_q := []  ## [[point, near], ...]
var failures := 0
var checked := {"pick": 0, "pick_hit": 0, "near": 0, "fraction": 0}
var fractions := []  ## [gene, threshold]
var finishing := 0
var phase := "rounds"
var phase_frame := 0
var tracked: Array = []
var copy_field: NutrientField


func _check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		if failures <= 20:
			print("FAIL " + what)


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		points = int(a[0])
	SimConstants.apply()
	rng.seed = 7
	var sim := BupSim.new()
	sim.reset(RADIUS, 5)
	sim.set_limit(BUPS + 1000)
	var spots := []
	for i in BUPS:
		var g := Genome.founder()
		g["speed"] = 10.0 + 40.0 * sim.random_float()
		g["sense"] = 20.0 + 100.0 * sim.random_float()
		g["metabolism"] = 0.6 + 0.8 * sim.random_float()
		g["size"] = 3.0 + 2.0 * sim.random_float()
		g["harm"] = 0.0 if i % 3 == 0 else 0.3 * sim.random_float() * sim.random_float()
		g["mutations"] = int(10.0 * sim.random_float())
		var born := Cell.mass_to_add(g)
		var at: Vector2 = sim.random_point(RADIUS * 0.95) if i < BUPS - 50 else spots[i % 97]  # (the last 50 on the spot of another: ties)
		spots.append(at)
		sim.add_bup(at, g, 30.0, sqrt(born * (1.0 + sim.random_float())), born, i % 5, Vector2.RIGHT)
	var nutrient := sim.get_field()
	nutrient.fill(0.002)
	for k in 60:  # (clouds, for the eraser)
		nutrient.add_cloud(sim.random_point(RADIUS * 0.8), 20.0, 2000.0 + 100.0 * k)
	var state := sim.export_state_bytes()
	ref = BupSim.new()
	ref.reset(RADIUS, 5)
	ref.set_limit(BUPS + 1000)
	ref.import_state_bytes(state)
	world = GpuWorld.new(sim)
	world.gpu = GpuSim.new(RenderingServer.get_rendering_device())
	var field := sim.get_field()
	var packed := field.export_packed()
	var gpu := world.gpu
	var loaded := GpuSim.State.of_field(field, RADIUS, state, SimConstants.build())
	loaded.limit = BUPS + 1000
	loaded.dish_seed = 5
	loaded.next_id = sim.get_next_id()
	RenderingServer.call_on_render_thread(func() -> void:
		gpu.load_state(loaded))
	sim.import_state_bytes(PackedByteArray())
	copy_field = ref.get_field()
	copy_field.import_packed(packed["conc"], packed["puffs"])
	print("field: %d clouds" % ((packed["puffs"] as PackedFloat32Array).size() / 5))
	# fractions at a gene's own value (the float threshold boundary) and at round numbers
	var words := state.to_float32_array()
	fractions = [["speed", 30.0], ["sense", float(words[GpuLayout.R_SENSE + GpuLayout.RECORD_WORDS * 17])], ["metabolism", float(words[GpuLayout.R_METABOLISM + GpuLayout.RECORD_WORDS * 123]) + 1e-12], ["size", 4.2]]
	print("state: %d bups, the GPU's %s" % [BUPS, world.device_name()])


func _new_round() -> void:
	var pixel: float = [0.5, 2.0, 20.0][round_index % 3]
	var slack: float = [0.0, 3.0][round_index % 2]
	var at: Vector2
	if round_index % 2 == 0:  # (near a bup: a hit, mostly)
		var info: Dictionary = ref.bup_info(ref.bup_ids()[rng.randi_range(0, BUPS - 1)])
		at = info["pos"] + Vector2(rng.randf_range(-2.0, 2.0), rng.randf_range(-2.0, 2.0))
	else:
		at = Vector2(rng.randf_range(-RADIUS, RADIUS), rng.randf_range(-RADIUS, RADIUS))
	pick_q = [at, slack, pixel]
	near_q = []
	for s in GpuLayout.NEAR_SLOTS:
		near_q.append([Vector2(rng.randf_range(-RADIUS, RADIUS), rng.randf_range(-RADIUS, RADIUS)), [0.0, 60.0, 300.0, 1000.0][s]])


func _ask() -> void:
	world.pick_bup(pick_q[0], pick_q[1], pick_q[2])
	for q: Array in near_q:
		world.nearest_and_count(q[0], q[1])
	for f: Array in fractions:
		world.fraction_with_gene_at_least(f[0], f[1])


func _compare_round() -> void:
	var gpu_pick := world.pick_bup(pick_q[0], pick_q[1], pick_q[2])
	var cpu_pick := ref.pick_bup(pick_q[0], pick_q[1], pick_q[2])
	checked["pick"] += 1
	if cpu_pick >= 0:
		checked["pick_hit"] += 1
	if gpu_pick != cpu_pick:
		var d_gpu := ref.bup_pos(gpu_pick).distance_squared_to(pick_q[0]) if gpu_pick >= 0 else -1.0
		var d_cpu := ref.bup_pos(cpu_pick).distance_squared_to(pick_q[0]) if cpu_pick >= 0 else -1.0
		_check(false, "pick at %s slack %.1f pixel %.1f: GPU %d (d² %.6f) CPU %d (d² %.6f)" % [pick_q[0], pick_q[1], pick_q[2], gpu_pick, d_gpu, cpu_pick, d_cpu])
	elif gpu_pick >= 0:
		var info := world.bup_info(gpu_pick)
		var cpu_info := ref.bup_info(gpu_pick)
		_check(info.get("pos") == cpu_info.get("pos") and info.get("mass") == cpu_info.get("mass"), "the picked bup's record (bup_info) %s vs %s" % [info.get("pos"), cpu_info.get("pos")])
	for q: Array in near_q:
		var g := world.nearest_and_count(q[0], q[1])
		var c := ref.nearest_and_count(q[0], q[1])
		checked["near"] += 1
		_check(g.y == c.y and absf(g.x - c.x) <= 1e-5 * maxf(c.x, 1.0), "nearest_and_count at %s near %.0f: GPU %s CPU %s" % [q[0], q[1], g, c])


func _compare_totals() -> void:
	var g := world.population_stats()
	var c := ref.population_stats()
	_check(g["count"] == c["count"], "population_stats count GPU %d CPU %d" % [g["count"], c["count"]])
	for key: String in ["speed", "sense", "metabolism", "size", "harm", "mutations"]:
		var rel := absf(g[key] - c[key]) / maxf(absf(c[key]), 1e-30)
		print("stats %-10s GPU %.7f CPU %.7f rel %s" % [key, g[key], c[key], str(rel)])
		_check(rel <= 1e-5, "population_stats %s: GPU %.8f CPU %.8f" % [key, g[key], c[key]])
	for f: Array in fractions:
		var gf := world.fraction_with_gene_at_least(f[0], f[1])
		var cf := ref.fraction_with_gene_at_least(f[0], f[1])
		checked["fraction"] += 1
		print("fraction %-10s >= %.9f GPU %.6f CPU %.6f" % [f[0], f[1], gf, cf])
		_check(cf > 0.0 and cf < 1.0, "fraction %s >= %f: the CPU's %f is all or none, so it tests nothing (0 is also the GPU's answer before one comes back)" % [f[0], f[1], cf])
		_check(absf(gf - cf) <= 1e-5 * maxf(cf, 1e-30) or gf == cf, "fraction %s >= %f: GPU %f CPU %f" % [f[0], f[1], gf, cf])


func _process(_delta: float) -> bool:
	if finishing > 0:
		finishing += 1
		if finishing == 3:
			RenderingServer.call_on_render_thread(world.gpu.release)
		return finishing > 6
	if phase == "rounds" and round_index >= points:
		phase = "track"
		phase_frame = 0
		var ids := ref.bup_ids()
		tracked = [ids[3], ids[BUPS / 2], ids[BUPS - 1]]
	if phase == "track":
		for id: int in tracked:
			world.track(id)
		phase_frame += 1
		if phase_frame < ROUND_FRAMES:
			return false
		for id: int in tracked:
			var gi := world.bup_info(id)
			var ci := ref.bup_info(id)
			var same := not gi.is_empty()
			for key: String in ["pos", "dir", "energy", "mass", "birth_mass", "divisions", "speed", "sense", "metabolism", "size_gene", "hue", "harm", "mutations", "upkeep", "max_energy", "steering"]:
				same = same and gi.get(key) == ci.get(key)
			_check(same, "tracked bup %d: bup_info GPU %s CPU %s" % [id, str(gi), str(ci)])
			_check(world.bup_pos(id) == ref.bup_pos(id), "tracked bup %d: bup_pos GPU %s CPU %s" % [id, world.bup_pos(id), ref.bup_pos(id)])
			_check(absf(world.bup_radius(id, 2.0) - ref.bup_radius(id, 2.0)) <= 1e-6 * ref.bup_radius(id, 2.0), "tracked bup %d: bup_radius GPU %f CPU %f" % [id, world.bup_radius(id, 2.0), ref.bup_radius(id, 2.0)])
			_check(world.bup_steering(id).is_equal_approx(ref.bup_steering(id)), "tracked bup %d: bup_steering GPU %s CPU %s" % [id, world.bup_steering(id), ref.bup_steering(id)])
		print("tracked %s: compared" % str(tracked))
		phase = "erase"
		phase_frame = 0
	if phase == "erase":
		if phase_frame == 0:
			for k in 3:
				var at := Vector2(rng.randf_range(-RADIUS * 0.6, RADIUS * 0.6), rng.randf_range(-RADIUS * 0.6, RADIUS * 0.6))
				world.erase_disc(at, 600.0, 0.9)
				copy_field.erase_disc(at, 600.0, 0.9)
		phase_frame += 1
		if phase_frame < ROUND_FRAMES:
			world.bup_count()  # (a getter a frame, as the dish's drawing calls one: the erasing goes out at the end of the frame)
			return false
		var gpu := world.gpu
		var got := []
		RenderingServer.call_on_render_thread(func() -> void: got.append(gpu.read_conc()); got.append(gpu.read_puffs()))
		var conc: PackedFloat32Array = got[0]
		var cpu_conc: PackedFloat32Array = copy_field.export_packed()["conc"]
		var worst := 0.0
		var top := 0.0
		var g_total := 0.0
		var c_total := 0.0
		for i in conc.size():
			worst = maxf(worst, absf(conc[i] - cpu_conc[i]))
			top = maxf(top, cpu_conc[i])
			g_total += conc[i]
			c_total += cpu_conc[i]
		var g_mass := 0.0
		for cloud: Array in got[1]:
			g_mass += cloud[2]
		var cpu_puffs: PackedFloat32Array = copy_field.export_packed()["puffs"]
		var c_mass := 0.0
		for k in cpu_puffs.size() / 5:
			c_mass += cpu_puffs[k * 5 + 2]
		print("erase: grid total GPU %.6f CPU %.6f, largest cell difference %s of the largest; clouds' mass GPU %.4f CPU %.4f" % [g_total, c_total, str(worst / top), g_mass, c_mass])
		_check(worst <= 1e-6 * top and absf(g_mass - c_mass) <= 1e-5 * c_mass and absf(g_total - c_total) <= 1e-5 * c_total, "erase_disc on the GPU against the CPU's")
		phase = "totals"
	if phase == "totals":
		_compare_totals()
		print("checked %s" % str(checked))
		_check(checked["pick_hit"] > 0 and checked["fraction"] == fractions.size(), "some picks hit a bup (%d) and every fraction was compared" % checked["pick_hit"])
		print("QUERIES CHECK " + ("OK" if failures == 0 else "FAILED (%d)" % failures))
		finishing = 1
		return false
	if phase != "rounds":
		return false
	if frame_in_round == 0:
		_new_round()
	_ask()
	frame_in_round += 1
	if frame_in_round >= ROUND_FRAMES:
		_compare_round()
		frame_in_round = 0
		round_index += 1
	return false
