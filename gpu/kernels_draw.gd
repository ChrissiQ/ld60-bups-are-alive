class_name GpuKernelsDraw
extends RefCounted
## The drawing's compute kernels (the bups' MultiMesh written on the GPU: see gpu/gpu_draw.gd), apart from the
## simulation's in gpu/kernels.gd so the two can change separately. GpuKernels.all() includes these; each gets its own
## gpu/shaders/<name>.glsl from tools/gen_gpu_shaders.gd, like the others.
##
## To add a kernel: build it in `all()` with GpuKernels.add(out, name, body, buffer_names, extra, local_size)
## (the header, FUNCS and one declaration per buffer are added for you; binding = position in `buffer_names`). Buffers the simulation
## has (P, CNT, BUPS, BUPS_U, ...) take their types from GpuKernels.TYPES; a buffer of the drawing's own (the MultiMesh's, say) is
## declared in TYPES below. The bup record and P are described at the top of gpu/kernels.gd (P[74..77] are the drawing's constants).
## A kernel bound to a buffer GpuSim does not own (the MultiMesh's RD buffer) is set up with GpuSim.make_external_kernel().

## The element type of each buffer only the drawing's kernels bind (name -> GLSL type).
## INST: the MultiMesh's instances (RenderingServer.multimesh_get_buffer_rd_rid, or a plain buffer in tools), 16 floats each as
## RenderingServer.multimesh_set_buffer takes them for 2D with colours and custom data: x.x, y.x, 0, origin.x | x.y, y.y, 0, origin.y |
## colour r, g, b, a | custom: length, width, margin, trail (what Dish.BUP_SHADER reads). Four vec4 per instance.
const TYPES := {"INST": "vec4"}

## Godot's Color.from_hsv (core/math/color.cpp, Color::set_hsv), in floats as there: the hue scaled to six sectors, wrapped as C's
## fmod wraps (keeping the sign), and the sector's channels. Colours are made here, not in dish.gd or genome.gd, because the picture is
## made on the GPU: this is the same colour BupSim.render_buffer gives each bup.
const COLOUR_FUNCS := """
vec3 from_hsv(float h, float s, float v) {
	if (s == 0.0) return vec3(v);
	h *= 6.0;
	h = h - 6.0 * trunc(h / 6.0);
	int i = int(floor(h));
	float f = h - float(i);
	float p = v * (1.0 - s), q = v * (1.0 - s * f), t = v * (1.0 - s * (1.0 - f));
	if (i == 0) return vec3(v, t, p);
	if (i == 1) return vec3(q, v, p);
	if (i == 2) return vec3(p, v, t);
	if (i == 3) return vec3(p, q, v);
	if (i == 4) return vec3(t, p, v);
	return vec3(v, p, q);
}
"""

## A port of BupSim::render_buffer (native/src/bup_sim.cpp): one thread per MultiMesh slot, push constant pa = µm per pixel,
## pb = the slots in the picture. A bup is drawn at its true length unless that is under P[74] pixels, a streak back to where it was
## in the last picture (words 22, 23; >= 1e30: none) when it has moved farther than its length (at most P[77] pixels), and its own
## colour. Slots past the live count are all zero (drawn as nothing); a bup past the picture's slots is not drawn and keeps no place,
## so it gets no trail from the gap. Every bup drawn notes where it was (words 22, 23), for the next picture's trail. Words 22 and 23
## never feed the simulation, so drawing does not change a run.
const K_RENDER_BUPS := """
void main() {
	uint i = gl_GlobalInvocationID.x;
	uint slots = uint(pcs.pb);
	uint live = CNT[0];
	if (i >= slots) {
		if (i < live) { BUPS[i * 24u + 22u] = 3e38; BUPS[i * 24u + 23u] = 3e38; }
		return;
	}
	if (i >= live) {
		INST[i * 4u] = vec4(0.0); INST[i * 4u + 1u] = vec4(0.0); INST[i * 4u + 2u] = vec4(0.0); INST[i * 4u + 3u] = vec4(0.0);
		return;
	}
	uint b = i * 24u;
	float pixel_um = pcs.pa;
	float x = BUPS[b + 1u], y = BUPS[b + 2u];
	float len = max(BUPS[b + 6u] * P[14], P[74] * pixel_um);
	float width = max(P[75], P[76] * pixel_um);
	float margin = pixel_um;
	float ux = BUPS[b + 3u], uy = BUPS[b + 4u], trail = 0.0;
	float ox = BUPS[b + 22u], oy = BUPS[b + 23u];
	if (ox < 1e30) {
		float mx = x - ox, my = y - oy;
		float moved = sqrt(mx * mx + my * my);
		if (moved > len) {
			ux = mx / moved;
			uy = my / moved;
			trail = min(moved, P[77] * pixel_um);
		}
	}
	BUPS[b + 22u] = x;
	BUPS[b + 23u] = y;
	float ql = len + trail + 2.0 * margin, qw = width + 2.0 * margin;
	INST[i * 4u] = vec4(ux * ql, -uy * qw, 0.0, x - ux * trail * 0.5);
	INST[i * 4u + 1u] = vec4(uy * ql, ux * qw, 0.0, y - uy * trail * 0.5);
	INST[i * 4u + 2u] = vec4(from_hsv(BUPS[b + 16u], BUPS[b + 17u], BUPS[b + 18u]), 1.0);
	INST[i * 4u + 3u] = vec4(len, width, margin, trail);
}
"""


## The drawing's kernels, in the form of GpuKernels.all().
static func all() -> Dictionary:
	var out := {}
	GpuKernels.add(out, "render_bups", K_RENDER_BUPS, ["P", "CNT", "BUPS", "INST"], COLOUR_FUNCS)
	return out
