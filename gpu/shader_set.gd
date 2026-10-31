class_name ShaderSet
extends RefCounted
## The compute kernels a simulation runs, apart from any device: for each kernel its SPIR-V (the imported gpu/shaders/<name>.glsl) or,
## from source (for tools), its GLSL text, the buffers it binds in order, and its threads per group. A device is bound to the thread that
## made it, so the shaders are made on it only in `create`, on that thread (and GLSL is compiled there). `uniform_set` binds a kernel's
## buffers by name: views (GpuKernels.VIEWS) bind the buffer they view, and the ping-pong groups named in `flipped`
## (GpuKernels.PING_PONG) bind the other half of each pair, so a pass over the other half needs no copy.

const SHADER_DIR := "res://gpu/shaders"

## name -> {"spirv": RDShaderSPIRV (null from source), "source": the GLSL ("" when imported), "buffers": Array, "local_size": int}
var kernels := {}
var errors: Array[String] = []  ## kernels that could not be loaded (missing or broken imports)


## The imported SPIR-V of the kernels `defs` (GpuKernels.all() when empty): load on the main thread, hand to the device's thread.
static func imported(defs: Dictionary = {}) -> ShaderSet:
	var shaders := ShaderSet.new()
	var all := defs if not defs.is_empty() else GpuKernels.all()
	for kernel_name: String in all:
		var def: Dictionary = all[kernel_name]
		var spirv := load_spirv(kernel_name)
		if spirv == null:
			shaders.errors.append("missing or broken shader %s/%s.glsl (run tools/gen_gpu_shaders.gd, then --import)" % [SHADER_DIR, kernel_name])
		shaders.kernels[kernel_name] = {"spirv": spirv, "source": "", "buffers": def["buffers"], "local_size": def["local_size"]}
	return shaders


## The kernels `defs` (GpuKernels.all(), or kernels made with GpuKernels.add) as GLSL, compiled on the device by `create`.
static func from_source(defs: Dictionary) -> ShaderSet:
	var shaders := ShaderSet.new()
	for kernel_name: String in defs:
		var def: Dictionary = defs[kernel_name]
		var text: String = def["source"]
		shaders.kernels[kernel_name] = {"spirv": null, "source": text.substr(text.find("#[compute]\n") + "#[compute]\n".length()), "buffers": def["buffers"], "local_size": def["local_size"]}
	return shaders


## The imported SPIR-V of kernel `kernel_name`, or null when it is missing or did not compile.
static func load_spirv(kernel_name: String) -> RDShaderSPIRV:
	var path := SHADER_DIR.path_join(kernel_name + ".glsl")
	if not ResourceLoader.exists(path):
		return null
	var file := load(path) as RDShaderFile
	if file == null or file.get_base_error() != "":
		return null
	var spirv := file.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		return null
	return spirv


## The kernels made on `rd` (call it on the device's own thread): name -> {"shader", "pipeline": RIDs, "buffers", "local"}. A kernel that
## does not compile or load is left out and its error added to `errors`.
func create(rd: RenderingDevice) -> Dictionary:
	var made := {}
	for kernel_name: String in kernels:
		var k: Dictionary = kernels[kernel_name]
		var spirv: RDShaderSPIRV = k["spirv"]
		if spirv == null and k["source"] != "":
			var sh := RDShaderSource.new()
			sh.language = RenderingDevice.SHADER_LANGUAGE_GLSL
			sh.source_compute = k["source"]
			spirv = rd.shader_compile_spirv_from_source(sh)
			if spirv.compile_error_compute != "":
				errors.append("%s: %s" % [kernel_name, spirv.compile_error_compute])
				continue
		if spirv == null:
			continue
		var shader := rd.shader_create_from_spirv(spirv, kernel_name)
		if not shader.is_valid():
			errors.append("%s: the shader was not created" % kernel_name)
			continue
		var pipeline := rd.compute_pipeline_create(shader)
		if not pipeline.is_valid():  # (the driver's own compile, Metal's from the SPIR-V, can fail where the GLSL compiled)
			errors.append("%s: the pipeline was not created" % kernel_name)
			rd.free_rid(shader)
			continue
		made[kernel_name] = {"shader": shader, "pipeline": pipeline, "buffers": k["buffers"], "local": k["local_size"]}
	return made


## A uniform set for `kernel` (one of `create`'s): each binding gets the buffer of `rids` (buffer name -> RID, the first half of each
## ping-pong pair under its own name) that GpuKernels.physical names for it with the groups `flipped`.
static func uniform_set(rd: RenderingDevice, kernel: Dictionary, rids: Dictionary, flipped: Array = []) -> RID:
	var uniforms: Array[RDUniform] = []
	var names: Array = kernel["buffers"]
	for k in names.size():
		var buffer_name := GpuKernels.physical(names[k], flipped)
		assert(rids.has(buffer_name), "no buffer %s for binding %s" % [buffer_name, names[k]])
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = k
		u.add_id(rids[buffer_name])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, kernel["shader"], 0)


## Frees the shaders `create` made (their pipelines and uniform sets go with them).
static func free_all(rd: RenderingDevice, made: Dictionary) -> void:
	for kernel_name: String in made:
		rd.free_rid(made[kernel_name]["shader"])
