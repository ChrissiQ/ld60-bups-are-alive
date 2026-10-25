class_name GpuSim
extends RefCounted
## The simulation's whole step on the GPU (see AGENTS.md, "GPU path"): feed, diffusion, the plankton clouds,
## swimming and growing, uptake, death, division and mutation, compaction. The kernels are gpu/kernels.gd, imported from
## gpu/shaders/*.glsl; the bup record, P, CNT and PCNT are described at the top of gpu/kernels.gd.
##
## Two ways to run it:
## - a local RenderingDevice (`GpuSim.new()`: tools and tests; needs a window, not --headless): `run_steps` records, submits and waits;
## - the main RenderingDevice (`GpuSim.new(RenderingServer.get_rendering_device())`: the game): `is_main` is true, nothing here may
##   call submit() or sync(), and every call that touches the device is made on the render thread (RenderingServer.call_on_render_thread).
##   A batch is `prepare_steps(steps, plan)` (uploads: before any compute list is open, since the device refuses buffer updates while one
##   is) and then `record_steps(cl, steps, plan)` into a compute list the caller has begun.
## The public API below (signals, vars and functions without a leading underscore, as of Step 3.0) is frozen: add to it, do not change it.

signal buffers_rebuilt  ## load_state made new buffers: a kernel set up with make_external_kernel must be set up again

const STRIDE := 24  ## words per bup record (the layout is at the top of gpu/kernels.gd; the same as BupSim.export_state_bytes)
const RECORD_BYTES := STRIDE * 4
const NO_PICTURE := 3e38  ## px, py (words 22, 23) of a bup with no last picture: no trail (any value >= 1e30 means the same)
const CNT_WORDS := 16
const PCNT_WORDS := 8
const MAX_STEPS_PER_BATCH := 1024
const EV_PUFFS_CAPACITY := 65536
const EV_CELLS_CAPACITY := 1048576
const EVENT_SETS := 4  ## the family events of this many batches can be held at once (each batch writes set seq % EVENT_SETS; a set is
## written again only once its batch's events are in the CPU's records: about 4 frames after it ran)
const PUSH_CACHE_MOST := 4096

var rd: RenderingDevice
var is_main := false  ## true: the main RenderingDevice (record only, on the render thread; no submit/sync)
var kernels := {}
var bufs := {}
var n := 0  ## cells across the grid
var count := 0  ## bups at the load (the live count is CNT[0], on the device)
var capacity := 0  ## bup slots
var puff_capacity := 262144  ## slots for clouds
var entry_capacity := 0  ## places in the lists of clouds by square
var event_capacity := 0  ## births (and as many deaths) one batch's event lists hold: P[78] (the lists are Step 3B's)
var bins := 0  ## squares of the cloud lists
var bins_across := 1
var p := PackedFloat32Array()
var consts := {}
var spacing := 0.0
var origin := 0.0
var radius := 0.0
var delta := 20.0  ## the step's length (s) of the last batch: every entry of P that depends on it is set again for each batch
var diffusion := 0.0  ## the medium's diffusion coefficient (µm²/s)
var feed_per_second := 0.0  ## the feed (concentration per second)
var upkeep_scale := 1.0  ## the dish's upkeep factor (P[79])
var stationary := false  ## the dish has the stationary phase on (P[85]; the batch's plan says)
var death_puff := 0.0  ## what a death gives back at once, per unit of mass (P[63]): P[8], or 0 when the dish makes husks of its deaths (the batch's plan says)
var limit := 0  ## the most bups (P[60]): past it a random share dies each step
var has_clouds := false  ## whether any cloud has been loaded or sent, or deaths make them: until then the cloud kernels are not run
var has_events := false
var _k_total := 0.0  ## the diffusion of one step, D dt / cell²
var _scan_sizes := [0, 0, 0]
var _bin_sizes := [0, 0, 0]
var _puff_sizes := [0, 0, 0]
var _from_source := false
var loads := 0  ## how many times load_state has run: results recorded before a load belong to a state that is gone
var steps_recorded := 0  ## steps recorded since the load: the clouds' slots are compacted every 16th of them, counted across batches
var _push_cache := {}  ## (pa, pb, pc) -> the 16 bytes of the push constant
var _stats_groups := 1  ## groups of 256 the stats' first pass runs in


## `device` is the RenderingDevice to run on (null: make a local one). `from_source` compiles the kernels' text from gpu/kernels.gd
## at run time instead of loading the imported SPIR-V (for tools: the Metal driver compiles that for SPIR-V 1.6, the import for 1.4).
func _init(device: RenderingDevice = null, from_source := false) -> void:
	rd = device if device != null else RenderingServer.create_local_rendering_device()
	assert(rd != null, "no local rendering device (run with a window, not --headless)")
	is_main = device != null and device == RenderingServer.get_rendering_device()
	_from_source = from_source


func device_name() -> String:
	return rd.get_device_name()


func _make_kernel(kernel_name: String, def: Dictionary) -> void:
	var spirv: RDShaderSPIRV
	if _from_source:
		var text: String = def["source"]
		var sh := RDShaderSource.new()
		sh.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		sh.source_compute = text.substr(text.find("#[compute]\n") + "#[compute]\n".length())
		spirv = rd.shader_compile_spirv_from_source(sh)
		if spirv.compile_error_compute != "":
			print("SHADER ERROR in ", kernel_name, ":\n", spirv.compile_error_compute)
			assert(false)
	else:
		var file := load("res://gpu/shaders/%s.glsl" % kernel_name) as RDShaderFile
		assert(file != null, "missing shader gpu/shaders/%s.glsl (run tools/gen_gpu_shaders.gd, then --import)" % kernel_name)
		spirv = file.get_spirv()
	var shader := rd.shader_create_from_spirv(spirv)
	assert(shader.is_valid(), "shader %s was not created" % kernel_name)
	var local: int = def["local_size"]
	kernels[kernel_name] = {"shader": shader, "pipeline": rd.compute_pipeline_create(shader), "buffers": def["buffers"], "set": RID(), "local": local, "external": false}


func _make_kernels() -> void:
	var all := GpuKernels.all()
	for kernel_name: String in all:
		_make_kernel(kernel_name, all[kernel_name])


func _buf(buf_name: String, bytes: PackedByteArray) -> void:
	if bufs.has(buf_name):
		rd.free_rid(bufs[buf_name])
	if bytes.size() < 16:  # (a buffer is at least 16 bytes)
		bytes.resize(16)
	bufs[buf_name] = rd.storage_buffer_create(bytes.size(), bytes)


func _zeros(num_bytes: int) -> PackedByteArray:
	var z := PackedByteArray()
	z.resize(num_bytes)
	return z


## One of this simulation's buffers by its name in gpu/kernels.gd (TYPES), for a kernel or a readback of the caller's.
func buffer(buf_name: String) -> RID:
	assert(bufs.has(buf_name), "GpuSim has no buffer %s (is the state loaded?)" % buf_name)
	return bufs[buf_name]


## Loads a state.
## - the field: `cells_across`, `cell_spacing` (µm), `conc` (n*n concentrations), `owner` (NutrientField.export_owner()), `fill_weights`
##   (NutrientField.export_fill_weights(): what a feed adds to each cell per unit of concentration);
## - `dish_radius` (µm), `bups`: the records (STRIDE words each, BupSim.export_state_bytes()), `constants`: SimConstants.build();
## - `bup_limit`: the most bups (the buffers hold 5% more and a little; 0: as many as there are), `feed` (concentration per second),
##   `step_seconds` (the step's length until a batch says otherwise), `diffusion_coeff` (µm²/s, NutrientField.get_diffusion()),
## - `puffs`: the clouds, an Array of [x, y, mass, variance, cut] or a PackedFloat32Array of 5 floats each (NutrientField.export_packed());
## - `dish_seed`: the dish's seed, folded into every kernel's random numbers (CNT[7]); `upkeep`: the dish's upkeep factor (P[79]);
## - `next_id`: the id the next newborn gets (BupSim.get_next_id(); 0: one past the largest id in `bups`).
## Every buffer is made afresh, so kernels set up with make_external_kernel must be set up again (`buffers_rebuilt`).
func load_state(cells_across: int, cell_spacing: float, dish_radius: float, conc: PackedFloat32Array, owner: PackedInt32Array, bups: PackedByteArray, constants: Dictionary, bup_limit := 0, fill_weights := PackedFloat32Array(), feed := 0.0, step_seconds := 20.0, diffusion_coeff := 0.0, puffs: Variant = [], dish_seed := 1, upkeep := 1.0, next_id := 0) -> void:
	assert(bups.size() % RECORD_BYTES == 0, "bup records are %d bytes each" % RECORD_BYTES)
	n = cells_across
	spacing = cell_spacing
	radius = dish_radius
	origin = dish_radius
	count = bups.size() / RECORD_BYTES
	consts = constants
	delta = step_seconds
	diffusion = diffusion_coeff
	feed_per_second = feed
	upkeep_scale = upkeep
	limit = bup_limit if bup_limit > 0 else count
	capacity = ((int(limit * 1.05) + 1024 + 255) / 256) * 256
	event_capacity = maxi(32768, capacity / 4)
	var inside := PackedInt32Array()
	inside.resize(n * n)
	for i in n * n:
		inside[i] = 1 if owner[i] == i else 0
	var table := PackedFloat32Array()
	table.append_array(PackedFloat32Array(constants["motion_drift"]))
	table.append_array(PackedFloat32Array(constants["motion_d_along"]))
	table.append_array(PackedFloat32Array(constants["motion_d_across"]))
	table.append_array(PackedFloat32Array(constants["motion_d_flat"]))
	var full := bups.duplicate()
	full.resize(capacity * RECORD_BYTES)
	var weights := fill_weights
	if weights.is_empty():
		weights = PackedFloat32Array()
		weights.resize(n * n)
	var first_id := next_id
	if first_id <= 0:
		first_id = 1
		for i in count:
			first_id = maxi(first_id, id_of(bups, i) + 1)
	var cnt := _zeros(CNT_WORDS * 4)
	cnt.encode_u32(0, count)
	cnt.encode_u32(4 * 4, first_id & 0xFFFFFFFF)
	cnt.encode_u32(6 * 4, (first_id >> 32) & 0xFFFFFFFF)
	cnt.encode_u32(7 * 4, (dish_seed ^ (dish_seed >> 32)) & 0xFFFFFFFF)
	_buf("P", _zeros(128 * 4))
	_buf("BUPS", full)
	_buf("BUPS2", _zeros(capacity * RECORD_BYTES))
	_buf("CHILD", _zeros(capacity * RECORD_BYTES))
	_buf("WANT", _zeros(capacity * 4))
	_buf("CELLOF", _zeros(capacity * 4))
	_buf("CONC", conc.to_byte_array())
	_buf("EFF", _zeros(n * n * 4))
	_buf("OWNER", owner.to_byte_array())
	_buf("INSIDE", inside.to_byte_array())
	for nm in ["DLO", "DHI", "RLO", "RHI", "ALO", "AHI", "SCALE"]:
		_buf(nm, _zeros(n * n * 4))
	# (the same buffers under the names of their integer views: see TYPES in gpu/kernels.gd)
	bufs["BUPS_U"] = bufs["BUPS"]
	bufs["BUPS_V4U"] = bufs["BUPS"]
	bufs["BUPS2_V4U"] = bufs["BUPS2"]
	bufs["CHILD_U"] = bufs["CHILD"]
	bufs["CHILD_V4U"] = bufs["CHILD"]
	_buf("TABLE", table.to_byte_array())
	_buf("WGT", weights.to_byte_array())
	_buf("CNT", cnt)
	for nm in ["SURV", "KID", "EXCS", "EXCK"]:
		_buf(nm, _zeros(capacity * 4))
	_scan_sizes = [capacity, (capacity + 255) / 256, 0]
	_scan_sizes[2] = (_scan_sizes[1] + 255) / 256
	for nm in ["S1", "S1X"]:
		_buf(nm, _zeros(_scan_sizes[1] * 4))
	for nm in ["S2", "S2X"]:
		_buf(nm, _zeros(_scan_sizes[2] * 4))
	_buf("S3", _zeros(16))
	# the clouds
	var bin_size := 0.5 * spacing
	bins_across = maxi(1, ceili(2.0 * radius / bin_size) + 1)
	bins = bins_across * bins_across
	entry_capacity = puff_capacity * 12
	var pf := PackedFloat32Array()
	pf.resize(puff_capacity * 8)
	var clouds := 0
	if puffs is PackedFloat32Array:
		var packed: PackedFloat32Array = puffs
		clouds = mini(packed.size() / 5, puff_capacity)
		for k in clouds:
			for j in 5:
				pf[k * 8 + j] = packed[k * 5 + j]
			pf[k * 8 + 5] = 1.0
	else:
		var listed: Array = puffs
		clouds = mini(listed.size(), puff_capacity)
		for k in clouds:
			var one: Array = listed[k]
			for j in 5:
				pf[k * 8 + j] = float(one[j])
			pf[k * 8 + 5] = 1.0
	has_clouds = clouds > 0 or float(consts["death_release"]) > 0.0  # (the deaths' clouds)
	_buf("PUFF", pf.to_byte_array())
	_buf("PUFF2", _zeros(puff_capacity * 8 * 4))
	bufs["PUFF_V"] = bufs["PUFF"]
	bufs["PUFF2_V"] = bufs["PUFF2"]
	var pcnt := _zeros(PCNT_WORDS * 4)
	pcnt.encode_u32(0, clouds)
	_buf("PCNT", pcnt)
	for nm in ["PDLO", "PDHI", "PSCALE", "PAL", "PEXC"]:
		_buf(nm, _zeros(puff_capacity * 4))
	for nm in ["BINC", "BINS", "BCUR"]:
		_buf(nm, _zeros(bins * 4))
	_buf("ENT", _zeros(entry_capacity * 4))
	_buf("ENTD", _zeros(entry_capacity * 32))  # (two vec4 per entry)
	_buf("EVR", _zeros(MAX_STEPS_PER_BATCH * 4 * 4))
	_buf("EVP", _zeros(EV_PUFFS_CAPACITY * 6 * 4))
	_buf("EVCC", _zeros(EV_CELLS_CAPACITY * 4))
	_buf("EVCA", _zeros(EV_CELLS_CAPACITY * 4))
	_buf("DPLO", _zeros(n * n * 4))
	_buf("DPHI", _zeros(n * n * 4))
	_buf("WANTC", _zeros(capacity * 4))
	# the game's side (gpu/gpu_world.gd): events, the frame's questions and answers, stats, the eraser, the field's copy
	_buf("EVB", _zeros(EVENT_SETS * event_capacity * 16 * 4))
	_buf("EVD", _zeros(EVENT_SETS * event_capacity * 8 * 4))
	_buf("EVN", _zeros(EVENT_SETS * 2 * 4))
	_buf("QIN", _zeros(64 * 4))
	_buf("OUT", _zeros(GpuKernels.OUT_WORDS * 4))
	_buf("OUTK", _zeros(EVENT_SETS * GpuKernels.OUT_WORDS * 4))
	_stats_groups = (capacity + 255) / 256
	_buf("SPART", _zeros(_stats_groups * 8 * 4))
	_buf("ERASE", _zeros(GpuKernels.MAX_ERASE * 16))
	_buf("QD", _zeros(capacity * 4))
	_buf("MIRROR", _zeros((1 + puff_capacity * 5) * 4))
	_puff_sizes = [puff_capacity, (puff_capacity + 255) / 256, 0]
	_puff_sizes[2] = (_puff_sizes[1] + 255) / 256
	_bin_sizes = [bins, (bins + 255) / 256, 0]
	_bin_sizes[2] = (_bin_sizes[1] + 255) / 256
	for nm in ["PS1", "PS1X"]:
		_buf(nm, _zeros(_puff_sizes[1] * 4))
	for nm in ["PS2", "PS2X"]:
		_buf(nm, _zeros(_puff_sizes[2] * 4))
	_buf("PS3", _zeros(16))
	for nm in ["BS1", "BS1X"]:
		_buf(nm, _zeros(_bin_sizes[1] * 4))
	for nm in ["BS2", "BS2X"]:
		_buf(nm, _zeros(_bin_sizes[2] * 4))
	_buf("BS3", _zeros(16))
	if kernels.is_empty():
		_make_kernels()
	for kname: String in kernels:  # (the buffers were remade: so are the sets that bind them)
		var kern: Dictionary = kernels[kname]
		kern["set"] = RID()
		if kern["external"]:
			continue  # (its buffers are the caller's: see make_external_kernel)
		var names: Array = kern["buffers"]
		if not names.all(func(b: String) -> bool: return bufs.has(b)):
			continue  # (a kernel whose buffers come with each call, as `probe`, or a drawing kernel set up from outside)
		kern["set"] = _uniform_set(kern, names)
	_fill_params()
	_set_step(delta)
	steps_recorded = 0
	loads += 1
	buffers_rebuilt.emit()


func _uniform_set(kern: Dictionary, rids: Array) -> RID:
	var uniforms: Array[RDUniform] = []
	for k in rids.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = k
		u.add_id(rids[k] if rids[k] is RID else bufs[rids[k]])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, kern["shader"], 0)


## Sets up a kernel of GpuKernels.all() whose buffers are not all this simulation's (the MultiMesh's RD buffer, say): `rids_by_binding`
## gives each binding of the kernel, in order, as a RID, or as the name of one of this simulation's buffers (a String). Then `dispatch`
## runs it like any other. Call it again after every `buffers_rebuilt` (and whenever one of the caller's buffers is remade).
func make_external_kernel(kernel_name: String, rids_by_binding: Array) -> void:
	if kernels.is_empty():
		_make_kernels()
	assert(kernels.has(kernel_name), "no kernel %s in GpuKernels.all()" % kernel_name)
	var kern: Dictionary = kernels[kernel_name]
	assert(rids_by_binding.size() == kern["buffers"].size(), "kernel %s binds %d buffers" % [kernel_name, kern["buffers"].size()])
	kern["external"] = true
	kern["set"] = _uniform_set(kern, rids_by_binding)


func _record_scan_chain(cl: int, prefix: String, sizes: Array) -> void:
	dispatch(cl, prefix + "0", sizes[0], float(sizes[0]))
	dispatch(cl, prefix + "1", sizes[1], float(sizes[1]))
	dispatch(cl, prefix + "2", sizes[2], float(sizes[2]))
	dispatch(cl, prefix + "a2", sizes[1], float(sizes[1]))
	dispatch(cl, prefix + "a1", sizes[0], float(sizes[0]))


## The entries of P that do not depend on the step's length (those are set by _set_step).
func _fill_params() -> void:
	p.resize(128)
	p.fill(0.0)
	p[0] = count
	p[1] = n
	p[2] = spacing
	p[3] = origin
	p[4] = radius
	var names_to_index := {"detection_floor": 9, "noise_reference": 10, "gradient_noise": 11, "reference_sense": 12, "reference_size": 13, "mass_um": 14, "base_upkeep": 16, "maintenance_per_mass": 17, "sense_upkeep": 18, "maintenance_floor": 19, "growth_rate": 20, "cost_per_mass": 21, "reserve_per_mass": 22, "uptake_per_size": 23, "half_saturation": 24,
		"trait_mutations": 32, "harmful_mutations": 33, "compensatory_mutations": 34, "lethal_fraction": 35, "harm_shape": 36, "mean_harm": 37, "mean_repair": 38, "max_harm": 39,
		"hue_step": 40, "sat_step": 41, "val_step": 42, "val_min": 43, "add_mass_factor": 56, "drag_upkeep": 57, "division_spread": 58,
		"min_length_px": 74, "width": 75, "min_width_px": 76, "max_trail_px": 77,
		"mutator_rate": 80, "mutator_down_share": 81, "mutator_fold_weak": 82, "mutator_fold_strong": 83, "mutator_fold_top": 84,
		"starve_death_rate": 87, "starve_death_exponent": 88, "starve_min_mass_share": 89}
	for key in names_to_index:
		p[names_to_index[key]] = float(consts[key])
	p[86] = float(consts["starve_maintenance"]) * float(consts["cost_per_mass"])
	p[8] = float(consts["death_release"]) * float(consts["cost_per_mass"])  # (what a death gives back per unit of the body's mass)
	death_puff = p[8]
	var s_axis: Array = consts["motion_s"]
	var e_axis: Array = consts["motion_e"]
	p[25] = s_axis.size()
	p[26] = e_axis.size()
	p[27] = log(float(s_axis[0]))
	p[28] = (log(float(s_axis[-1])) - log(float(s_axis[0]))) / (s_axis.size() - 1)
	p[29] = log(float(e_axis[0]))
	p[30] = (log(float(e_axis[-1])) - log(float(e_axis[0]))) / (e_axis.size() - 1)
	p[31] = float(s_axis[0])
	for g in 4:
		p[44 + g] = float(consts["gene_min"][g])
		p[48 + g] = float(consts["gene_max"][g])
		p[52 + g] = float(consts["gene_step"][g])
	p[62] = capacity
	p[64] = float(consts["cloud_handover"]) * spacing
	p[65] = float(consts["cloud_cut"])
	p[66] = 0.5 * spacing
	p[67] = bins_across
	p[68] = float(consts["motion_step"])
	p[69] = float(consts["motion_structure"])
	p[71] = puff_capacity
	p[72] = entry_capacity
	p[73] = bins
	p[78] = event_capacity


func moves_for(step_seconds: float) -> int:
	var scale := maxf(1.0, spacing / float(consts["motion_structure"]))
	return maxi(1, ceili(step_seconds / (float(consts["motion_step"]) * scale * scale)))


## Every entry of P that depends on the step's length (5-7 the motion's sub-steps, 59 the chance of death, 61 the feed, 70 the clouds'
## spread, and the diffusion's k), and the batch's own (60 the limit, 79 the upkeep factor), for steps of `step_seconds`; then P is
## uploaded. `swim` false: the bups do not move (for tests of the other parts).
func _set_step(step_seconds: float, swim := true) -> void:
	delta = step_seconds
	var moves := moves_for(delta) if swim else 0
	p[5] = delta
	p[6] = moves
	p[7] = delta / maxf(moves, 1)
	p[59] = minf(float(consts["death_rate"]) * delta, 1.0)
	p[60] = limit
	p[61] = feed_per_second * delta
	p[70] = 2.0 * diffusion * delta
	p[63] = death_puff
	p[85] = 1.0 if stationary else 0.0
	p[79] = upkeep_scale
	_k_total = diffusion * delta / (spacing * spacing)
	var pb := p.to_byte_array()
	rd.buffer_update(bufs["P"], 0, pb.size(), pb)


## Records one kernel: `threads` threads (in groups of its local size), the push constant (pa, pb, 0, 0), and a barrier after it.
var _max_groups_x := -1  ## the device's most groups in one dimension of a dispatch (read once)


func dispatch(cl: int, kernel_name: String, threads: int, pa := 0.0, pb := 0.0) -> void:
	dispatch3(cl, kernel_name, threads, pa, pb, 0.0)


## `dispatch` with the push constant's third float as well (pa, pb, pc, 0). The push constants' bytes are kept for reuse (a frame records
## hundreds of dispatches).
func dispatch3(cl: int, kernel_name: String, threads: int, pa: float, pb: float, pc: float) -> void:
	var kern: Dictionary = kernels[kernel_name]
	rd.compute_list_bind_compute_pipeline(cl, kern["pipeline"])
	rd.compute_list_bind_uniform_set(cl, kern["set"], 0)
	var key := Vector3(pa, pb, pc)
	var bytes: PackedByteArray = _push_cache.get(key, PackedByteArray())
	if bytes.is_empty():
		if _push_cache.size() >= PUSH_CACHE_MOST:
			_push_cache.clear()
		bytes = PackedFloat32Array([pa, pb, pc, 0.0]).to_byte_array()
		_push_cache[key] = bytes
	rd.compute_list_set_push_constant(cl, bytes, 16)
	var local: int = kern["local"]
	var groups := (threads + local - 1) / local
	if _max_groups_x < 0:
		_max_groups_x = rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X)
		if _max_groups_x <= 0:
			_max_groups_x = 0x7FFFFFFF
	if groups > _max_groups_x:  # (more groups than one dimension allows, 65,535 on some drivers: a grid of rows; only the kernels that count their threads through both dimensions, compact and copy, are dispatched with so many)
		rd.compute_list_dispatch(cl, _max_groups_x, (groups + _max_groups_x - 1) / _max_groups_x, 1)
	else:
		rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


## Diffusion by explicit sub-steps with k <= 0.2 each, `k_total` (D dt / cell²) in all.
func _record_diffusion(cl: int, k_total: float) -> void:
	var iterations := maxi(2, 2 * ceili(k_total / 0.4))  # (an even number, so that the result ends up where it started)
	for it in iterations / 2:
		dispatch(cl, "diffuse_a", n * n, 0.0, k_total / iterations)
		dispatch(cl, "diffuse_b", n * n, 0.0, k_total / iterations)


## After the nutrient has diffused: the clouds spread and some go to the grid, the grid is copied for the bups to read, the clouds are filed by place.
func _record_after_diffusion(cl: int) -> void:
	if has_clouds:
		dispatch(cl, "puff_advance", puff_capacity)
		dispatch(cl, "dep_apply", n * n)
	dispatch(cl, "snapshot", n * n)
	if has_clouds:
		dispatch(cl, "bin_clear", bins)
		dispatch(cl, "bin_count", puff_capacity)
		_record_scan_chain(cl, "bn", _bin_sizes)
		dispatch(cl, "bin_cursor", bins)
		dispatch(cl, "bin_scatter", puff_capacity)
		dispatch(cl, "bin_sort", bins)
	dispatch(cl, "clear", n * n)
	if has_clouds:
		dispatch(cl, "puff_clear", puff_capacity)


func _record_bups(cl: int) -> void:
	dispatch(cl, "swim", capacity)
	dispatch(cl, "demand", capacity)
	dispatch(cl, "cells", n * n)
	if has_clouds:
		dispatch(cl, "puff_scale", puff_capacity)
	dispatch(cl, "apply", capacity)
	if has_clouds:
		dispatch(cl, "puff_commit", puff_capacity)


## Drops the clouds that are gone (handed to the grid, or eaten): the places of the others, in order.
func _record_puff_compaction(cl: int) -> void:
	dispatch(cl, "pmark", puff_capacity)
	_record_scan_chain(cl, "pf", _puff_sizes)
	dispatch(cl, "pcompact", puff_capacity * 2)
	dispatch(cl, "pfinal", 1)
	dispatch(cl, "pcopy", puff_capacity * 2)
	dispatch(cl, "psetcount", 1)


## Division, death and mutation, then the bups' new places; the step's family events go to event set `event_set` (`step`: its place in
## the batch).
func _record_life(cl: int, step := 0, event_set := 0) -> void:
	dispatch(cl, "life", capacity)
	var c: int = _scan_sizes[0]
	var n1: int = _scan_sizes[1]
	var n2: int = _scan_sizes[2]
	for which in ["s", "k"]:
		dispatch(cl, "scan0_" + which, c, float(c))
		dispatch(cl, "scan1", n1, float(n1))
		dispatch(cl, "scan2", n2, float(n2))
		dispatch(cl, "add2", n1, float(n1))
		dispatch(cl, "add1_" + which, c, float(c))
	dispatch(cl, "finalize", 1)
	if has_clouds:
		dispatch(cl, "death_clouds", capacity)
		dispatch(cl, "death_count", 1)
	dispatch(cl, "events", capacity, float(step), float(event_set))
	dispatch(cl, "compact", capacity * 6)
	dispatch(cl, "copy", capacity * 6)
	dispatch(cl, "ev_count", 1, 0.0, float(event_set))
	dispatch(cl, "setcount", 1)


func _submit() -> void:
	assert(not is_main, "submit/sync only on a local device: on the main device the frame submits what was recorded")
	rd.submit()
	rd.sync()


## The core of one step with the bups where they are (no feed, division or death): for comparing the pieces with the CPU's. The
## diffusion is `diffuse_pieces` pieces of k = `k_per_piece` (D dt / cell² each) here, not the coefficient given to load_state.
func run(step_seconds: float, k_per_piece: float, diffuse_pieces: int, swim := true) -> void:
	_set_step(step_seconds, swim)
	var cl := rd.compute_list_begin()
	_record_diffusion(cl, k_per_piece * diffuse_pieces)
	_record_after_diffusion(cl)
	_record_bups(cl)
	rd.compute_list_end()
	_submit()


## Many steps of the core in one submit, for timing.
func run_many(steps: int, step_seconds: float, k_per_piece: float, diffuse_pieces: int, swim := true) -> void:
	_set_step(step_seconds, swim)
	var cl := rd.compute_list_begin()
	for step in steps:
		_record_diffusion(cl, k_per_piece * diffuse_pieces)
		_record_after_diffusion(cl)
		_record_bups(cl)
	rd.compute_list_end()
	_submit()


## What comes in from outside during a batch of steps: `events` has "ranges" (4 ints per step: first cloud, clouds, first deposit, deposits),
## "puffs" (6 floats each: x, y, mass, variance, cut, 0) and "cells" / "amounts" (a cell and a concentration to add).
func _upload_events(steps: int, events: Dictionary) -> void:
	has_events = not events.is_empty()
	if not has_events:
		return
	var ranges: PackedInt32Array = events["ranges"]
	assert(ranges.size() >= steps * 4 and steps <= MAX_STEPS_PER_BATCH)
	var rb := ranges.to_byte_array()
	rd.buffer_update(bufs["EVR"], 0, rb.size(), rb)
	var pf: PackedFloat32Array = events["puffs"]
	if pf.size() > 0:
		assert(pf.size() / 6 <= EV_PUFFS_CAPACITY)
		var pb := pf.to_byte_array()
		rd.buffer_update(bufs["EVP"], 0, pb.size(), pb)
		has_clouds = true
	var cc: PackedInt32Array = events["cells"]
	if cc.size() > 0:
		assert(cc.size() <= EV_CELLS_CAPACITY)
		var cb := cc.to_byte_array()
		rd.buffer_update(bufs["EVCC"], 0, cb.size(), cb)
		var ab := PackedFloat32Array(events["amounts"]).to_byte_array()
		rd.buffer_update(bufs["EVCA"], 0, ab.size(), ab)


## The uploads of a batch of `steps` steps, made before its compute list is begun (the device refuses buffer updates while a list is
## open). `plan` (every key optional): "delta" (the step's length, s: every entry of P that depends on it is set from it),
## "feed_per_second", "upkeep_scale", "death_puff", "stationary", "limit", "events" (see _upload_events). What is not given stays as it was.
func prepare_steps(steps: int, plan := {}) -> void:
	assert(steps <= MAX_STEPS_PER_BATCH)
	feed_per_second = float(plan.get("feed_per_second", feed_per_second))
	upkeep_scale = float(plan.get("upkeep_scale", upkeep_scale))
	death_puff = float(plan.get("death_puff", death_puff))
	stationary = bool(plan.get("stationary", stationary))
	limit = int(plan.get("limit", limit))
	_set_step(float(plan.get("delta", delta)))
	_upload_events(steps, plan.get("events", {}))


## Records `steps` whole steps (feed, diffusion, clouds, swimming and growing, uptake, death, division and mutation, compaction) into the
## compute list `cl`, which the caller has begun and will end; nothing is submitted. `prepare_steps(steps, plan)` must come first, with
## the same plan, outside any compute list. Also records each step's family events into event set `plan["event_set"]` (default 0; its
## counts start from 0), and after each step listed in `plan["history_steps"]` (ascending) a stats sample into OUT (sample 1, 2, ...).
func record_steps(cl: int, steps: int, plan := {}) -> void:
	var event_set: int = plan.get("event_set", 0)
	var history: PackedInt32Array = plan.get("history_steps", PackedInt32Array())
	var sample := 0
	dispatch(cl, "ev_begin", 1)
	for step in steps:
		if has_events:
			dispatch(cl, "ev_puffs", 1, float(step))
			dispatch(cl, "ev_deposits", 1, float(step))
		dispatch(cl, "feed", n * n)
		_record_diffusion(cl, _k_total)
		_record_after_diffusion(cl)
		_record_bups(cl)
		_record_life(cl, step, event_set)
		if has_clouds and (steps_recorded + step) % 16 == 15:  # (counted across batches: the game's are a few steps each, and a count within the batch never reached 15, so the slots of spent clouds were never freed and, once all were used, every burst went to the grid)
			_record_puff_compaction(cl)
		while sample < history.size() and history[sample] == step:
			sample += 1
			record_stats(cl, sample, step)
	steps_recorded += steps


## A stats sample of the bups as they are now into OUT, as sample `sample` (0: the frame's; 1..: the batch's history samples), marked as
## taken after step `step` of the batch.
func record_stats(cl: int, sample: int, step := -1) -> void:
	assert(sample <= GpuKernels.MAX_SAMPLES)
	dispatch(cl, "stats1", _stats_groups * 256)
	dispatch3(cl, "stats2", 256, float(_stats_groups), float(GpuKernels.OUT_STATS + GpuKernels.STATS_WORDS * sample), float(step))


## The uploads of a frame's questions and eraser discs (before any compute list is open): `qin` the QIN words (GpuKernels' layout),
## `erase` 4 floats per disc (x, y, radius, strength), at most GpuKernels.MAX_ERASE discs.
func prepare_frame(qin: PackedByteArray, erase := PackedFloat32Array()) -> void:
	assert(qin.size() <= 64 * 4 and erase.size() <= GpuKernels.MAX_ERASE * 4)
	if not qin.is_empty():
		rd.buffer_update(bufs["QIN"], 0, qin.size(), qin)
	if not erase.is_empty():
		var eb := erase.to_byte_array()
		rd.buffer_update(bufs["ERASE"], 0, eb.size(), eb)


## The eraser's `discs` discs (uploaded by prepare_frame): from the cells and from the clouds.
func record_erase(cl: int, discs: int) -> void:
	if discs <= 0:
		return
	dispatch(cl, "erase_cells", n * n, float(discs))
	if has_clouds:
		dispatch(cl, "erase_puffs", puff_capacity, float(discs))


## The clouds and deposits of `events` (one step's worth, at step 0: the dish's own while no steps run, a drop while paused, say), uploaded
## by prepare_events, recorded on their own.
func prepare_events(events: Dictionary) -> void:
	_upload_events(1, events)


func record_events(cl: int) -> void:
	if has_events:
		dispatch(cl, "ev_puffs", 1, 0.0)
		dispatch(cl, "ev_deposits", 1, 0.0)


## The end of a frame's work: OUT's head (CNT, PCNT) and its questions cleared, the frame's stats sample (sample 0), and the answers to
## the questions uploaded by prepare_frame (`pick`: whether a pick was asked, `scan`: whether a nearest or a fraction was, `track`: whether
## any bup is tracked).
func record_frame(cl: int, pick: bool, scan: bool, track: bool) -> void:
	dispatch(cl, "q_clear", GpuKernels.QOUT_WORDS)
	record_stats(cl, 0)
	if pick:
		dispatch(cl, "q_pick", capacity)
		dispatch(cl, "q_pick2", capacity)
		dispatch(cl, "q_record", 24)
	if scan:
		dispatch(cl, "q_scan", capacity)
	if track:
		dispatch(cl, "q_track", capacity)


## Keeps OUT's first `words` words as event set `event_set`'s copy in OUTK (after record_frame, for a batch).
func record_keep(cl: int, event_set: int, words: int) -> void:
	dispatch(cl, "out_keep", words, float(words), float(event_set * GpuKernels.OUT_WORDS))


## The field's copy: MIRROR gets the first `slots` cloud slots (see the `mirror` kernel). Read CONC and MIRROR after it.
func record_mirror(cl: int, slots: int) -> void:
	dispatch(cl, "mirror", maxi(slots, 1), float(maxi(slots, 1)))


## Whole steps of the current length, as many as asked, in one submit, waiting for them (a local device only: tools and tests).
func run_steps(steps: int, events := {}) -> void:
	prepare_steps(steps, {"events": events})
	var cl := rd.compute_list_begin()
	record_steps(cl, steps)
	rd.compute_list_end()
	_submit()


## Time each kernel on its own (microseconds per dispatch, over `reps` dispatches in one submit; the state is not reset, so it is only for timing).
func profile(reps := 20) -> Dictionary:
	_set_step(delta)
	var out := {}
	var plan := {}
	if has_clouds:
		plan.merge({"puff_advance": puff_capacity, "dep_apply": n * n, "bin_clear": bins, "bin_count": puff_capacity, "bin_cursor": bins, "bin_scatter": puff_capacity, "bin_sort": bins, "puff_clear": puff_capacity, "puff_scale": puff_capacity, "puff_commit": puff_capacity})
	plan.merge({"feed": n * n, "diffuse_a": n * n, "snapshot": n * n, "clear": n * n, "swim": capacity, "demand": capacity, "cells": n * n, "apply": capacity, "life": capacity, "scan0_s": capacity, "compact": capacity * 6, "copy": capacity * 6})
	for kname in plan:
		var cl := rd.compute_list_begin()
		var t0 := Time.get_ticks_usec()
		for r in reps:
			dispatch(cl, kname, plan[kname], float(capacity), 0.1)
		rd.compute_list_end()
		_submit()
		out[kname] = float(Time.get_ticks_usec() - t0) / reps
	out["diffuse_a"] = out["diffuse_a"] * maxi(2, 2 * ceili(_k_total / 0.4))
	out["scans"] = out["scan0_s"] * 2.0 * 1.4  # (two scans: the first level is nearly all of each)
	return out


## Files the clouds by place (as at the start of a step), for tests.
func build_index() -> void:
	has_clouds = true
	var cl := rd.compute_list_begin()
	dispatch(cl, "bin_clear", bins)
	dispatch(cl, "bin_count", puff_capacity)
	_record_scan_chain(cl, "bn", _bin_sizes)
	dispatch(cl, "bin_cursor", bins)
	dispatch(cl, "bin_scatter", puff_capacity)
	dispatch(cl, "bin_sort", bins)
	rd.compute_list_end()
	_submit()


## For timing: the kernels in this order (a name with "chain:" in front is a scan chain: "chain:bn", "chain:pf"), `reps` times in one submit; microseconds per round.
func time_sequence(names: Array, reps := 10) -> float:
	_set_step(delta)
	var sizes := {"bin_clear": bins, "bin_cursor": bins, "bin_sort": bins, "dep_apply": n * n, "snapshot": n * n, "clear": n * n, "cells": n * n, "feed": n * n, "diffuse_a": n * n, "diffuse_b": n * n}
	var cl := rd.compute_list_begin()
	var t0 := Time.get_ticks_usec()
	for r in reps:
		for nm in names:
			if nm.begins_with("chain:"):
				_record_scan_chain(cl, nm.substr(6), _bin_sizes if nm == "chain:bn" else _puff_sizes)
			else:
				var threads: int = sizes.get(nm, 0)
				if threads == 0:
					threads = capacity if nm in ["swim", "demand", "apply", "life"] else puff_capacity
				dispatch(cl, nm, threads)
	rd.compute_list_end()
	_submit()
	return float(Time.get_ticks_usec() - t0) / reps


## [entries in all lists, most in one square, squares with any]: how crowded the lists of clouds by place are.
func bin_stats() -> Array:
	var counts_by_bin := rd.buffer_get_data(bufs["BINC"]).to_int32_array()
	var total := 0
	var biggest := 0
	var used := 0
	for c in counts_by_bin:
		total += c
		biggest = maxi(biggest, c)
		if c > 0:
			used += 1
	return [total, biggest, used, counts_by_bin.size()]


## For tests: x, y of each point in, [concentration, gradient x, gradient y, smallest sigma] of the clouds there out.
func probe(points: PackedFloat32Array) -> PackedFloat32Array:
	var m := points.size() / 2
	_buf("PQ", points.to_byte_array())
	_buf("PR", _zeros(m * 16))
	var kern: Dictionary = kernels["probe"]
	kern["set"] = _uniform_set(kern, kern["buffers"])
	var cl := rd.compute_list_begin()
	dispatch(cl, "probe", m, float(m))
	rd.compute_list_end()
	_submit()
	return rd.buffer_get_data(bufs["PR"]).to_float32_array()


## Frees every buffer, set, pipeline and shader this simulation made (on the device's thread; for a GpuSim no longer used).
func release() -> void:
	for kname: String in kernels:
		var kern: Dictionary = kernels[kname]
		if kern["set"].is_valid() and rd.uniform_set_is_valid(kern["set"]):
			rd.free_rid(kern["set"])
		rd.free_rid(kern["pipeline"])
		rd.free_rid(kern["shader"])
	kernels.clear()
	var freed := {}
	for buf_name: String in bufs:
		var rid: RID = bufs[buf_name]
		if not freed.has(rid):
			freed[rid] = true
			rd.free_rid(rid)
	bufs.clear()


# ---- readbacks (they stall the device: tools, tests, and deliberate stalls only) ------------------------------------------------

## The clouds that are there: [x, y, mass, variance, cut] each.
func read_puffs() -> Array:
	var raw := rd.buffer_get_data(bufs["PUFF"]).to_float32_array()
	var slots := rd.buffer_get_data(bufs["PCNT"]).decode_u32(0)
	var out := []
	for k in slots:
		if raw[k * 8 + 5] > 0.5:
			out.append([raw[k * 8], raw[k * 8 + 1], raw[k * 8 + 2], raw[k * 8 + 3], raw[k * 8 + 4]])
	return out


## CNT as ints (see gpu/kernels.gd: 0 the bups now, 4/6 the next id's lo/hi words, 7 the seed, ...).
func counts() -> PackedInt32Array:
	return rd.buffer_get_data(bufs["CNT"]).to_int32_array()


## The id the next newborn gets.
func next_id() -> int:
	var c := rd.buffer_get_data(bufs["CNT"])
	return c.decode_u32(4 * 4) | (c.decode_u32(6 * 4) << 32)


## What was lost or moved for want of room, since the load: clouds that found no slot (they went onto the grid), entries cut from the
## full lists of clouds by place, and births and deaths that found no event slot (Step 3B's lists).
func overflows() -> Dictionary:
	var c := rd.buffer_get_data(bufs["CNT"])
	var pc := rd.buffer_get_data(bufs["PCNT"])
	return {"clouds_to_grid": pc.decode_u32(2 * 4), "list_entries_cut": pc.decode_u32(3 * 4), "births_lost": c.decode_u32(10 * 4), "deaths_lost": c.decode_u32(11 * 4)}


## The bups' records (STRIDE words each, in order): read floats with `.to_float32_array()` and ids with `id_of`.
func read_bups() -> PackedByteArray:
	var live := counts()[0]
	return rd.buffer_get_data(bufs["BUPS"], 0, live * RECORD_BYTES) if live > 0 else PackedByteArray()  # (a size of 0 would read the whole buffer)


func read_conc() -> PackedFloat32Array:
	return rd.buffer_get_data(bufs["CONC"]).to_float32_array()


## The id of record `i` in a block of records (words 0 and 21).
static func id_of(records: PackedByteArray, i: int) -> int:
	return records.decode_u32(i * RECORD_BYTES) | (records.decode_u32(i * RECORD_BYTES + 21 * 4) << 32)


## Gives record `i` the id `id`.
static func set_id(records: PackedByteArray, i: int, id: int) -> void:
	records.encode_u32(i * RECORD_BYTES, id & 0xFFFFFFFF)
	records.encode_u32(i * RECORD_BYTES + 21 * 4, (id >> 32) & 0xFFFFFFFF)
