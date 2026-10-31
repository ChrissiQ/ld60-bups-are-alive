extends SceneTree
# Dispatches one trivial compute kernel on a local RenderingDevice and checks the readback.
# Expected (derived): out[i] = i * 3 + 1 for i in 0..63, so the sum is 3 * 2016 + 64 = 6112.
# Prints "COMPUTE_PROBE OK" on a match, "COMPUTE_PROBE FAIL: <why>" otherwise.
# Needs a renderer (not --headless): on Linux CI run under xvfb-run with lavapipe.

const COUNT := 64
const SOURCE := """#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, std430) buffer Out { uint v[]; } o;
void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= 64u) return;
	o.v[i] = i * 3u + 1u;
}
"""


func _init() -> void:
	var ok := _run()
	quit(0 if ok else 1)


func _run() -> bool:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("COMPUTE_PROBE FAIL: no local RenderingDevice")
		return false
	print("device: ", rd.get_device_name())
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = SOURCE
	var spirv := rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		print("COMPUTE_PROBE FAIL: compile: ", spirv.compile_error_compute)
		return false
	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		print("COMPUTE_PROBE FAIL: shader_create")
		return false
	var buf := rd.storage_buffer_create(COUNT * 4, PackedByteArray())
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 0
	u.add_id(buf)
	var set_rid := rd.uniform_set_create([u], shader, 0)
	var pipe := rd.compute_pipeline_create(shader)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipe)
	rd.compute_list_bind_uniform_set(cl, set_rid, 0)
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var out := rd.buffer_get_data(buf).to_int32_array()
	var sum := 0
	for i in COUNT:
		if out[i] != i * 3 + 1:
			print("COMPUTE_PROBE FAIL: out[", i, "] = ", out[i], ", expected ", i * 3 + 1)
			return false
		sum += out[i]
	print("sum ", sum, " expected 6112")
	print("COMPUTE_PROBE OK")
	return sum == 6112
