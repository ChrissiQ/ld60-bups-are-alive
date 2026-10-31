class_name GpuKernelsView
extends RefCounted
## The main device's kernels of the pooled world's picture: they read the payload the simulation publishes into a
## shared texture (one texel a bup of the main-view dish, GpuLayout.PL_*; its ids in a second texture, GpuLayout.IDT_*) and write the
## bups' MultiMesh (ViewRenderer, scripts/sim/view_renderer.gd), and answer the pointer's questions. They never run on the simulation's
## device. The textures are imported in a format other than the one the simulation made them in (RGBA32UI as RGBA32I, RG32UI as RG32I:
## see ViewRenderer), so the kernels read them as signed images and take the bits back as unsigned.
##
## view_build, every frame the camera or the payload changed:
## - view_mark: a thread a texel marks the bups whose quad reaches into the camera's rectangle (VMARK, 0 or 1);
## - view_scan_*: an exclusive prefix sum of the marks (VOFF), so a visible bup's instance is its place among the visible ones in the
##   dish's own order (the draw order is the payload's: where bups overlap the later still shows, and nothing flickers);
## - view_scatter: each visible bup's instance, as `render_bups` (gpu/kernels_draw.gd) writes one with no trail: its length and width
##   no less than the least footprint in screen pixels, a margin of a pixel, its colour;
## - view_tail: the instances past the visible ones, up to the slots drawn, written as nothing, and the visible count for the host.
## The questions (the pointer's pick, BupSim.pick_bup's rule; the nearest bup and how many are near; where the bups the rings follow are):
## view_pick, view_pick2, view_answer, after view_build in the same list.

## VP: the build's parameters, one word each (floats by their bits), written by the host before the list.
const VW_COUNT := 0  ## the payload's bups (texels read)
const VW_X0 := 1  ## the camera's rectangle in dish-local µm: left, top, right, bottom
const VW_Y0 := 2
const VW_X1 := 3
const VW_Y1 := 4
const VW_PIXEL := 5  ## µm to a screen pixel
const VW_SLOTS := 6  ## the instances drawn (the MultiMesh's visible instances): those past the visible bups are written as nothing
const VW_CAPACITY := 7  ## the instances the MultiMesh's buffer holds
const VW_PICK := 8  ## 1: answer the pick at VW_PICK_X, VW_PICK_Y (µm) within the slack VW_SLACK, and count the bups within VW_NEAR
const VW_PICK_X := 9
const VW_PICK_Y := 10
const VW_SLACK := 11
const VW_NEAR := 12
const VW_FINDS := 13  ## 1: find the bups VW_FIND (FINDS ids, the low word then the high; an unused one all ones)
const VW_FIND := 14
const FINDS := 2  ## the bups whose place is looked up a frame (the selected and the hovered: their rings)
const VW_WORDS := VW_FIND + 2 * FINDS

## VOUT: the build's answers, read back by the host a frame or two later.
const VO_VISIBLE := 0  ## the visible bups (instances written)
const VO_D2 := 1  ## the pick's least d² (float bits; all ones: none in reach)
const VO_INDEX := 2  ## the picked texel (all ones: none)
const VO_NEAREST := 3  ## the nearest bup's d² (float bits; all ones: no bups)
const VO_NEAR := 4  ## the bups within VW_NEAR of the pick's point
const VO_FOUND := 5  ## FINDS texels of the bups looked up (all ones: not in the payload)
const VO_PICKED := VO_FOUND + FINDS  ## the picked bup: id low, id high, x, y, length (µm)
const VO_PLACE_WORDS := 5
const VO_PLACES := VO_PICKED + VO_PLACE_WORDS  ## each found bup: id low, id high, x, y, length
const VO_WORDS := VO_PLACES + FINDS * VO_PLACE_WORDS

const TYPES := {"VP": "uint", "VMARK": "uint", "VOFF": "uint", "VSUMS": "uint", "VOFFS": "uint", "VPD": "uint", "VOUT": "uint", "INST": "vec4"}

## The image bindings of each kernel (binding -> the texture ViewRenderer binds there: "payload" or "ids"), past its storage buffers.
const IMAGE_BINDINGS := {
	"view_mark": {3: "payload"},
	"view_scatter": {5: "payload"},
	"view_pick": {4: "payload", 5: "ids"},
	"view_answer": {2: "payload", 3: "ids"},
}

const PAYLOAD_IMAGE := "uniform restrict readonly iimage2D PAYTEX;\n"
const IDS_IMAGE := "uniform restrict readonly iimage2D IDTEX;\n"

## A texel's place in the textures, its words, and the parameters as floats.
const VIEW_FUNCS := """
ivec2 texel_at(uint k) { return ivec2(int(k % PAYLOAD_TEX_WIDTH), int(k / PAYLOAD_TEX_WIDTH)); }
uvec4 payload_at(uint k) { return uvec4(imageLoad(PAYTEX, texel_at(k))); }
float vpf(uint w) { return uintBitsToFloat(VP[w]); }
"""

## Half the reach of a bup's quad from its middle along either axis: half the drawn length (no less than the least footprint) and the
## pixel of margin round it, or half the drawn width and its margin if that is more.
const K_MARK := """
void f(uint k) {
	uvec4 px = payload_at(k);
	vec2 shape = unpackHalf2x16(px[PL_SHAPE]);
	uint keep = 0u;
	if (shape.x > 0.0) {
		float pixel = vpf(VW_PIXEL);
		float half_reach = 0.5 * max(max(shape.x, P[P_MIN_LENGTH_PX] * pixel), max(P[P_WIDTH], P[P_MIN_WIDTH_PX] * pixel)) + pixel;
		float x = uintBitsToFloat(px[PL_X]), y = uintBitsToFloat(px[PL_Y]);
		if (x + half_reach >= vpf(VW_X0) && x - half_reach <= vpf(VW_X1) && y + half_reach >= vpf(VW_Y0) && y - half_reach <= vpf(VW_Y1)) keep = 1u;
	}
	VMARK[k] = keep;
}
GRID_LOOP(f, VP[VW_COUNT])
"""

const K_SCATTER := """
void f(uint k) {
	if (VMARK[k] == 0u) return;
	uint j = VOFF[k];
	if (j >= VP[VW_CAPACITY]) return;
	uvec4 px = payload_at(k);
	vec2 shape = unpackHalf2x16(px[PL_SHAPE]);
	float pixel = vpf(VW_PIXEL);
	float len = max(shape.x, P[P_MIN_LENGTH_PX] * pixel);
	float width = max(P[P_WIDTH], P[P_MIN_WIDTH_PX] * pixel);
	float margin = pixel;
	float ux = cos(shape.y), uy = sin(shape.y);
	float ql = len + 2.0 * margin, qw = width + 2.0 * margin;
	uint c = px[PL_COLOR];
	INST[j * 4u] = vec4(ux * ql, -uy * qw, 0.0, uintBitsToFloat(px[PL_X]));
	INST[j * 4u + 1u] = vec4(uy * ql, ux * qw, 0.0, uintBitsToFloat(px[PL_Y]));
	INST[j * 4u + 2u] = vec4(vec3(float((c >> PL_RED_SHIFT) & 255u), float((c >> PL_GREEN_SHIFT) & 255u), float((c >> PL_BLUE_SHIFT) & 255u)) / 255.0, 1.0);
	INST[j * 4u + 3u] = vec4(len, width, margin, 0.0);
}
GRID_LOOP(f, VP[VW_COUNT])
"""

const K_TAIL := """
void f(uint j) {
	uint n = VP[VW_COUNT];
	uint total = n == 0u ? 0u : VOFF[n - 1u] + VMARK[n - 1u];
	if (j == 0u) VOUT[VO_VISIBLE] = total;
	if (j < total || j >= VP[VW_CAPACITY]) return;
	INST[j * 4u] = vec4(0.0); INST[j * 4u + 1u] = vec4(0.0); INST[j * 4u + 2u] = vec4(0.0); INST[j * 4u + 3u] = vec4(0.0);
}
GRID_LOOP(f, max(VP[VW_SLOTS], 1u))
"""

## The pick (BupSim.pick_bup's rule, as q_pick: within half its drawn length plus the slack, the nearest; ties to the first in the
## payload's order): the least d² by atomicMin on its bits (they order as the floats do for d² >= 0), each texel's own kept in VPD for
## view_pick2; the nearest bup and the count within VW_NEAR (BupSim::nearest_and_count); and the texels of the bups looked up by id.
const K_PICK := """
void f(uint k) {
	uvec4 px = payload_at(k);
	vec2 shape = unpackHalf2x16(px[PL_SHAPE]);
	uint bits = 0xFFFFFFFFu;
	if (shape.x > 0.0) {
		if (VP[VW_PICK] != 0u) {
			float pixel = vpf(VW_PIXEL);
			float reach = 0.5 * max(shape.x, P[P_MIN_LENGTH_PX] * pixel) + vpf(VW_SLACK);
			float dx = uintBitsToFloat(px[PL_X]) - vpf(VW_PICK_X), dy = uintBitsToFloat(px[PL_Y]) - vpf(VW_PICK_Y);
			float d2 = dx * dx + dy * dy;
			if (d2 <= reach * reach) { bits = floatBitsToUint(d2); atomicMin(VOUT[VO_D2], bits); }
			atomicMin(VOUT[VO_NEAREST], floatBitsToUint(d2));
			float near = vpf(VW_NEAR);
			if (d2 <= near * near) atomicAdd(VOUT[VO_NEAR], 1u);
		}
		if (VP[VW_FINDS] != 0u) {
			uvec2 id = uvec2(imageLoad(IDTEX, texel_at(k)).xy);
			for (uint s = 0u; s < FINDS; s++) {
				if (id.x == VP[VW_FIND + 2u * s + IDT_LO] && id.y == VP[VW_FIND + 2u * s + IDT_HI]) VOUT[VO_FOUND + s] = k;
			}
		}
	}
	VPD[k] = bits;
}
GRID_LOOP(f, VP[VW_COUNT])
"""

const K_PICK2 := """
void f(uint k) {
	if (VPD[k] != 0xFFFFFFFFu && VPD[k] == VOUT[VO_D2]) atomicMin(VOUT[VO_INDEX], k);
}
GRID_LOOP(f, VP[VW_PICK] != 0u ? VP[VW_COUNT] : 0u)
"""

## The picked bup's and the found bups' ids, places and lengths (one thread).
const K_ANSWER := """
void place(uint k, uint at) {
	if (k == 0xFFFFFFFFu) return;
	uvec4 px = payload_at(k);
	uvec2 id = uvec2(imageLoad(IDTEX, texel_at(k)).xy);
	VOUT[at] = id.x; VOUT[at + 1u] = id.y; VOUT[at + 2u] = px[PL_X]; VOUT[at + 3u] = px[PL_Y];
	VOUT[at + 4u] = floatBitsToUint(unpackHalf2x16(px[PL_SHAPE]).x);
}
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;
	place(VOUT[VO_INDEX], VO_PICKED);
	for (uint s = 0u; s < FINDS; s++) place(VOUT[VO_FOUND + s], VO_PLACES + s * VO_PLACE_WORDS);
}
"""


## The names the kernels share, as GLSL constants.
static func declarations() -> String:
	var text := ""
	var constants: Dictionary = (load("res://gpu/kernels_view.gd") as Script).get_script_constant_map()
	var names: Array = constants.keys()
	names.sort()
	for name: String in names:
		if (name.begins_with("VW_") or name.begins_with("VO_") or name == "FINDS") and constants[name] is int:
			text += "const uint %s = %du;\n" % [name, constants[name]]
	return text


## A kernel's image declarations at the bindings IMAGE_BINDINGS gives it.
static func _images(kernel_name: String) -> String:
	var text := ""
	var bindings: Dictionary = IMAGE_BINDINGS.get(kernel_name, {})
	for b: int in bindings:
		var which: String = bindings[b]
		text += "layout(set = 0, binding = %d, %s) %s" % [b, "rgba32i" if which == "payload" else "rg32i", PAYLOAD_IMAGE if which == "payload" else IDS_IMAGE]
	return text


static func register(out: Dictionary) -> void:
	var head := declarations()
	var add := func(kernel_name: String, body: String, buffers: Array) -> void:
		GpuKernels.add(out, kernel_name, body, buffers, head + _images(kernel_name) + (VIEW_FUNCS if IMAGE_BINDINGS.has(kernel_name) else ""), 64, TYPES)
	add.call("view_mark", K_MARK, ["P", "VP", "VMARK"])
	# (the grid scan of gpu/kernels.gd, over the marks, with the count read from VP)
	var scan := {"SRC": "VMARK", "DST": "VOFF", "SUMS": "VSUMS", "OFFS": "VOFFS", "COUNT": "VP[VW_COUNT]"}
	GpuKernels.add(out, "view_scan_chunks", GpuKernels._fill(GpuKernels.K_GSCAN_CHUNKS, scan), ["VP", "VMARK", "VOFF", "VSUMS"], head, 256, TYPES)
	GpuKernels.add(out, "view_scan_sums", GpuKernels._fill(GpuKernels.K_GSCAN_SUMS, scan), ["VSUMS", "VOFFS"], "", 256, TYPES)
	GpuKernels.add(out, "view_scan_add", GpuKernels._fill(GpuKernels.K_GSCAN_ADD, scan), ["VP", "VOFF", "VOFFS"], head, 256, TYPES)
	add.call("view_scatter", K_SCATTER, ["P", "VP", "VMARK", "VOFF", "INST"])
	GpuKernels.add(out, "view_tail", K_TAIL, ["VP", "VMARK", "VOFF", "INST", "VOUT"], head, 64, TYPES)
	add.call("view_pick", K_PICK, ["P", "VP", "VPD", "VOUT"])
	GpuKernels.add(out, "view_pick2", K_PICK2, ["VP", "VPD", "VOUT"], head, 64, TYPES)
	add.call("view_answer", K_ANSWER, ["VP", "VOUT"])
