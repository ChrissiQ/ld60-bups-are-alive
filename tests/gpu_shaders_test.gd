extends SceneTree
## Run: godot --headless --path . -s tests/gpu_shaders_test.gd
## The GPU kernels are written in gpu/kernels*.gd (GpuKernels.all()), turned into gpu/shaders/<name>.glsl by tools/gen_gpu_shaders.gd, and imported (to
## SPIR-V) by the editor's importer. This checks, for every kernel, that the file exists and is what the generator would write now,
## that it declares each of its buffers, and that it compiled: the importer reports success even when the shader has an error, so
## the error is read from the imported resource.
## An edit of a kernel needs both steps (a headless -s run does not import):
const REGENERATE := "stale: run  /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s tools/gen_gpu_shaders.gd  and then  --headless --path . --import"


func _init() -> void:
	var all := GpuKernels.all()
	TestUtil.check(not all.is_empty(), "GpuKernels.all() lists no kernels")
	for kernel_name: String in all:
		_check_kernel(kernel_name, all[kernel_name])
	for f in DirAccess.get_files_at("res://gpu/shaders"):
		if f.get_extension() == "glsl":
			TestUtil.check(all.has(f.get_basename()), "gpu/shaders/%s has no kernel in GpuKernels.all() (delete it and its .import)" % f)
	TestUtil.finish(self, "GPU SHADERS TEST OK")


func _check_kernel(kernel_name: String, def: Dictionary) -> void:
	var path := "res://gpu/shaders/%s.glsl" % kernel_name
	if not FileAccess.file_exists(path):
		TestUtil.check(false, "%s: missing (%s)" % [path, REGENERATE])
		return
	var text := FileAccess.get_file_as_string(path)
	TestUtil.check(text == def["source"], "%s: differs from what GpuKernels.all() generates (%s)" % [path, REGENERATE])
	TestUtil.check(text.contains("#[compute]"), "%s: has no #[compute] line" % path)
	for b: String in def["buffers"]:
		TestUtil.check(text.contains("buffer B_%s " % b), "%s: does not declare buffer %s" % [path, b])
	var file := load(path) as RDShaderFile
	if file == null:
		TestUtil.check(false, "%s: did not import as a RDShaderFile (%s)" % [path, REGENERATE])
		return
	TestUtil.check(file.get_base_error() == "", "%s: import error: %s" % [path, file.get_base_error()])
	var spirv := file.get_spirv()
	TestUtil.check(spirv != null and spirv.compile_error_compute == "", "%s: compile error: %s" % [path, spirv.compile_error_compute if spirv != null else "no SPIR-V"])
