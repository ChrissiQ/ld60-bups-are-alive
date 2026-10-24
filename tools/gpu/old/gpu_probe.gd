extends SceneTree
## godot --path <proj> --rendering-driver <metal|vulkan|d3d12> --position 6000,6000 -s gpu_probe.gd
const BUP_GLSL := """
#[compute]
#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, std430) buffer Pos { vec2 p[]; } pos;
layout(set = 0, binding = 1, std430) buffer Rng { uint s[]; } rng;
layout(set = 0, binding = 2, std430) readonly buffer Field { float c[]; } fld;
layout(set = 0, binding = 3, std430) readonly buffer Table { vec4 t[]; } tab;
layout(push_constant) uniform P { int n; int cells; float spacing; float origin; float dt; float radius; } pc;
uint hash(uint x) { x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16; return x; }
float u01(inout uint s) { s = hash(s + 0x9e3779b9U); return (float(s >> 8) + 0.5) / 16777216.0; }
float gauss(inout uint s) { float a = u01(s), b = u01(s); return sqrt(-2.0 * log(a)) * cos(6.2831853 * b); }
float cell(int ix, int iy) { ix = clamp(ix, 0, pc.cells - 1); iy = clamp(iy, 0, pc.cells - 1); return fld.c[iy * pc.cells + ix]; }
void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(pc.n)) return;
	vec2 x = pos.p[i]; uint s = rng.s[i];
	float fx = (x.x + pc.origin) / pc.spacing - 0.5, fy = (x.y + pc.origin) / pc.spacing - 0.5;
	int x0 = int(floor(fx)), y0 = int(floor(fy)); float tx = fx - float(x0), ty = fy - float(y0);
	float c00 = cell(x0, y0), c10 = cell(x0 + 1, y0), c01 = cell(x0, y0 + 1), c11 = cell(x0 + 1, y0 + 1);
	float top = c00 + (c10 - c00) * tx, bot = c01 + (c11 - c01) * tx;
	float c = top + (bot - top) * ty;
	vec2 g = vec2(((c10 - c00) + ((c11 - c01) - (c10 - c00)) * ty), bot - top) / pc.spacing;
	float glen = length(g / (0.001 + c));
	int ti = clamp(int(glen * 8.0), 0, 255);
	vec4 m = tab.t[ti];
	float kick = 2.0 * 25.0 * pc.dt;
	float up = gauss(s) * sqrt(m.y * kick), side = gauss(s) * sqrt(m.z * kick);
	vec2 u = glen > 1e-9 ? normalize(g) : vec2(1, 0);
	up += 5.0 * m.x * pc.dt;
	x += u * up + vec2(-u.y, u.x) * side;
	float d = length(x); if (d > pc.radius) x *= (2.0 * pc.radius - d) / d;
	pos.p[i] = x; rng.s[i] = s;
}
"""
const DIFF_GLSL := """
#[compute]
#version 450
layout(local_size_x = 16, local_size_y = 16) in;
layout(set = 0, binding = 0, std430) readonly buffer A { float a[]; } src;
layout(set = 0, binding = 1, std430) buffer B { float b[]; } dst;
layout(push_constant) uniform P { int n; float k; } pc;
void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy); if (p.x >= pc.n || p.y >= pc.n) return;
	int i = p.y * pc.n + p.x;
	float c = src.a[i];
	float l = src.a[p.y * pc.n + max(p.x - 1, 0)], r = src.a[p.y * pc.n + min(p.x + 1, pc.n - 1)];
	float u = src.a[max(p.y - 1, 0) * pc.n + p.x], d = src.a[min(p.y + 1, pc.n - 1) * pc.n + p.x];
	dst.b[i] = c + pc.k * (l + r + u + d - 4.0 * c);
}
"""
var rd: RenderingDevice
func shader(src: String) -> RID:
	var s := RDShaderSource.new(); s.language = RenderingDevice.SHADER_LANGUAGE_GLSL; s.source_compute = src.replace("#[compute]", "")
	var spirv := rd.shader_compile_spirv_from_source(s)
	if spirv.compile_error_compute != "": push_error(spirv.compile_error_compute); print("COMPILE ERROR: ", spirv.compile_error_compute); quit(1)
	return rd.shader_create_from_spirv(spirv)
func sbuf(bytes: PackedByteArray) -> RID: return rd.storage_buffer_create(bytes.size(), bytes)
func uset(sh: RID, bufs: Array) -> RID:
	var us: Array[RDUniform] = []
	for i in bufs.size():
		var u := RDUniform.new(); u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding = i; u.add_id(bufs[i]); us.append(u)
	return rd.uniform_set_create(us, sh, 0)
func _init() -> void:
	rd = RenderingServer.create_local_rendering_device()
	if rd == null: print("NO LOCAL RENDERING DEVICE"); quit(1); return
	print("GPU: ", rd.get_device_name(), " | driver ", RenderingServer.get_current_rendering_driver_name())
	# ---- bups
	for cfg in [[100000, 100], [100000, 400], [1000000, 400]]:
		var n: int = cfg[0]; var cells: int = cfg[1]
		var pos := PackedFloat32Array(); pos.resize(n * 2)
		var rng := PackedInt32Array(); rng.resize(n)
		for i in n: pos[i * 2] = randf_range(-80000, 80000); pos[i * 2 + 1] = randf_range(-80000, 80000) * 0.1; rng[i] = randi()
		var fld := PackedFloat32Array(); fld.resize(cells * cells)
		for i in fld.size(): fld[i] = randf()
		var tab := PackedFloat32Array(); tab.resize(256 * 4); for i in tab.size(): tab[i] = randf()
		var sh := shader(BUP_GLSL)
		var b0 := sbuf(pos.to_byte_array()); var b1 := sbuf(rng.to_byte_array()); var b2 := sbuf(fld.to_byte_array()); var b3 := sbuf(tab.to_byte_array())
		var us := uset(sh, [b0, b1, b2, b3]); var pl := rd.compute_pipeline_create(sh)
		var pc := PackedFloat32Array([0, 0, 0, 0, 0, 0]); var pci := pc.to_byte_array(); pci.encode_s32(0, n); pci.encode_s32(4, cells); pci.encode_float(8, 180000.0 / cells); pci.encode_float(12, 90000.0); pci.encode_float(16, 1.0); pci.encode_float(20, 90000.0)
		for sub in [1, 8, 64]:
			var steps := 20
			var t0 := Time.get_ticks_usec()
			var cl := rd.compute_list_begin(); rd.compute_list_bind_compute_pipeline(cl, pl); rd.compute_list_bind_uniform_set(cl, us, 0); rd.compute_list_set_push_constant(cl, pci, pci.size())
			for k in steps * sub:
				rd.compute_list_dispatch(cl, (n + 63) / 64, 1, 1); rd.compute_list_add_barrier(cl)
			rd.compute_list_end(); rd.submit(); rd.sync()
			var dt := float(Time.get_ticks_usec() - t0) / steps
			print("bups n=%d field=%d²: %d sub-steps/step -> %.0f us per step (GPU, no readback)" % [n, cells, sub, dt])
		# readback of every bup position
		var t1 := Time.get_ticks_usec(); for k in 10: rd.buffer_get_data(b0)
		print("  readback of %d positions: %.0f us" % [n, float(Time.get_ticks_usec() - t1) / 10])
	# ---- diffusion
	for cells in [100, 400, 1000, 2000]:
		var a := PackedFloat32Array(); a.resize(cells * cells); for i in a.size(): a[i] = randf()
		var sh := shader(DIFF_GLSL); var A := sbuf(a.to_byte_array()); var B := sbuf(a.to_byte_array())
		var u1 := uset(sh, [A, B]); var u2 := uset(sh, [B, A]); var pl := rd.compute_pipeline_create(sh)
		var pc := PackedByteArray(); pc.resize(8); pc.encode_s32(0, cells); pc.encode_float(4, 0.2)
		var iters := 50
		var t0 := Time.get_ticks_usec()
		var cl := rd.compute_list_begin(); rd.compute_list_bind_compute_pipeline(cl, pl); rd.compute_list_set_push_constant(cl, pc, 8)
		for k in iters:
			rd.compute_list_bind_uniform_set(cl, u1 if k % 2 == 0 else u2, 0); rd.compute_list_dispatch(cl, (cells + 15) / 16, (cells + 15) / 16, 1); rd.compute_list_add_barrier(cl)
		rd.compute_list_end(); rd.submit(); rd.sync()
		print("diffusion %d² explicit: %.1f us per iteration" % [cells, float(Time.get_ticks_usec() - t0) / iters])
	# ---- round trip
	var tiny := sbuf(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])); var sh2 := shader(DIFF_GLSL)
	var t2 := Time.get_ticks_usec()
	for k in 50:
		rd.submit(); rd.sync(); rd.buffer_get_data(tiny)
	print("submit+sync+tiny readback: %.0f us" % [float(Time.get_ticks_usec() - t2) / 50])
	quit(0)
