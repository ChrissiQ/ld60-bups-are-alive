class_name GpuKernelsDraw
extends RefCounted
## The drawing's compute kernels (the bups' MultiMesh written on the GPU), apart from the
## simulation's (gpu/kernels_field.gd and the others) so they can change separately. GpuKernels.all() includes these; each gets its own
## gpu/shaders/<name>.glsl from tools/gen_gpu_shaders.gd, like the others.
##
## To add a kernel: build it in `register()` with GpuKernels.add(out, name, body, buffer_names, extra, local_size, TYPES)
## (the header, FUNCS and one declaration per buffer are added for you; binding = position in `buffer_names`). Buffers the simulation
## has (P, CNT, BUPS, BUPS_U, ...) take their types from GpuKernels.TYPES; a buffer of the drawing's own (the MultiMesh's, say) is
## declared in TYPES below, which `add` is given. The bup record and P are in gpu/gpu_layout.gd (P_MIN_LENGTH_PX to P_MAX_TRAIL_PX are the drawing's constants), and `add` declares the names a kernel uses.
## A kernel bound to a buffer the pool does not own (the MultiMesh's RD buffer) is set up on its own.

## The element type of each buffer only the drawing's kernels bind (name -> GLSL type).
## INST: the MultiMesh's instances (RenderingServer.multimesh_get_buffer_rd_rid, or a plain buffer in tools), 16 floats each as
## RenderingServer.multimesh_set_buffer takes them for 2D with colours and custom data: x.x, y.x, 0, origin.x | x.y, y.y, 0, origin.y |
## colour r, g, b, a | custom: length, width, margin, trail (what Dish.BUP_SHADER reads). Four vec4 per instance.
const TYPES := {"INST": "vec4"}

## Godot's Color.from_hsv (core/math/color.cpp, Color::set_hsv), in floats as there: the hue scaled to six sectors, wrapped as C's
## fmod wraps (keeping the sign), and the sector's channels. Colours are made here, not in dish.gd or genome.gd, because the picture is
## made on the GPU: this is the colour each bup gets.
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


## ---- The pooled world's drawing kernels. Their outputs are storage buffers laid out as the textures they stand for
## (the kernel framework binds buffers only): PAYLOAD one uvec4 a texel, IDTEX two words a texel, HAZEPIX and STEERPIX one RGBA8 word a cell
## (red in the low byte, the way `haze_bytes` and `steer_bytes` lay their bytes), THUMBS the atlas, one RGBA8 word a texel. ----

const THUMB_TILE := 64  ## a dish's thumbnail tile: THUMB_TILE x THUMB_TILE texels
const THUMB_ATLAS := 2048  ## the atlas's width and height in texels: THUMB_ATLAS / THUMB_TILE tiles a row, so D_MAX tiles fill it
const POOL_DRAW_TYPES := {
	"PAYLOAD": "uvec4", "IDTEX": "uint", "VIEW": "float", "VQ": "float", "HAZEPIX": "uint", "STEERPIX": "uint", "FAINTLO": "uint", "FAINTHI": "uint",
	"THUMBN": "uint", "THUMBMAX": "uint", "THUMBS": "uint",
}

## The main-view dish's records as picture words, one thread a texel of dish row `pcs.pa`'s bups, for the whole last row of the texture
## and no further than the `pcs.pb` texels the buffers hold (the count is DSTATE's when the kernel runs, after the steps of its list,
## which the host does not know when it sizes them): a dead bup (the marker R_PY = -2 that `life` leaves until `compact`) and the texels
## past the dish's bups are zero (length 0: nothing drawn). The length is the body's true length, with no minimum and no trail; the angle
## is where it faces.
const K_POOL_PAYLOAD := COLOUR_FUNCS + """
uint byte_of(float v) { return uint(clamp(v * 255.0 + 0.5, 0.0, 255.0)); }
void f(uint k) {
	uint d = uint(pcs.pa);
	uvec4 px = uvec4(0u);
	uint lo = 0u, hi = 0u;
	if (k < DS(d, DS_COUNT)) {
		uint b = (DS(d, DS_START) + k) * RECORD_WORDS;
		if (BUPS[b + R_PY] != -2.0) {
			px[PL_X] = floatBitsToUint(BUPS[b + R_X]);
			px[PL_Y] = floatBitsToUint(BUPS[b + R_Y]);
			px[PL_SHAPE] = packHalf2x16(vec2(BUPS[b + R_MASS] * P[P_MASS_UM], atan(BUPS[b + R_DY], BUPS[b + R_DX])));
			vec3 col = from_hsv(BUPS[b + R_HUE], BUPS[b + R_SAT], BUPS[b + R_VAL]);
			px[PL_COLOR] = (byte_of(col.r) << PL_RED_SHIFT) | (byte_of(col.g) << PL_GREEN_SHIFT) | (byte_of(col.b) << PL_BLUE_SHIFT);
			lo = BUPS_U[b + R_ID_LO]; hi = BUPS_U[b + R_ID_HI];
		}
	}
	PAYLOAD[k] = px;
	IDTEX[k * 2u + IDT_LO] = lo; IDTEX[k * 2u + IDT_HI] = hi;
}
GRID_LOOP(f, min(((DS(uint(pcs.pa), DS_COUNT) + PAYLOAD_TEX_WIDTH - 1u) / PAYLOAD_TEX_WIDTH) * PAYLOAD_TEX_WIDTH, uint(pcs.pb)))
"""

## The field picture of dish row `pcs.pa`, the nutrient on the grid and the clouds' (summed by `pool_view_faint`: FAINTLO, FAINTHI), as
## VIEW: the concentration at the cell's centre. VIEW is indexed by pool cell.
const K_POOL_VIEW := """
void f(uint l) {
	uint d = uint(pcs.pa), c = DPU(d, DP_FIELD_BASE) + l;
	float v = CONC[c];
	if (INSIDE[c] != 0) v += FIX30(FAINTHI[l], FAINTLO[l]) / FAINT_UNIT;
	VIEW[c] = v;
}
GRID_LOOP(f, DPU(uint(pcs.pa), DP_CELLS) * DPU(uint(pcs.pa), DP_CELLS))
"""

## The clouds of dish row `pcs.pa`, every one, for the picture alone (no list is read): each adds its concentration at the centres of the cells
## its reach covers (a cloud with no reach, which no bup can sense and no list holds, the block of cells round it), into a sum a cell of the
## dish (FAINTLO, FAINTHI: fixed point, FAINT_UNIT x 2^30 to the unit of concentration, wide enough for a strong cloud and fine
## to well under the detection floor, so the order the threads run in does not matter). A cloud made since the lists were last built
## (its sigma word is still 0) is not yet in the picture.
const FAINT_UNIT := 4096.0

const K_POOL_VIEW_FAINT_CLEAR := """
void f(uint l) { FAINTLO[l] = 0u; FAINTHI[l] = 0u; }
GRID_LOOP(f, DPU(uint(pcs.pa), DP_CELLS) * DPU(uint(pcs.pa), DP_CELLS))
"""

const K_POOL_VIEW_FAINT := """
// an amount (at most 2^34 FAINT_UNIT) added to a sum in fixed point whole: the part over 4 to the high word, the rest to the low
#define ADD_FIXED_WIDE(LO, HI, cell, amount) { float a_ = amount; float h_ = floor(a_ * 0.25); float r_ = a_ - h_ * 4.0; if (h_ > 0.0) atomicAdd(HI[cell], uint(h_)); ADD64(LO, HI, cell, uint(r_ * 1073741824.0)) }
void f(uint k) {
	uint o = k * 8u, d = uint(pcs.pa);
	if (PUFF[o + 5] < 0.5 || floatBitsToUint(PUFF[o + 5]) - PUFF_ROW_BASE != d) return;
	if (PUFF[o + 7] <= 0.0) return;  // (not yet looked at by the lists)
	// the mass the cloud had when the step's lists were built: what the commit took off it is put back
	float dm = FIX20(PDHI[k], PDLO[k]);
	float x = PUFF[o], y = PUFF[o + 1], mass = PUFF[o + 2] + (dm > 0.0 ? dm * PSCALE[k] : 0.0), v = PUFF[o + 3];
	if (!(mass > 0.0) || !(v > 0.0)) return;
	int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS); uint base = DPU(d, DP_FIELD_BASE);
	float reach = PUFF[o + 6] > 0.0 ? sqrt(PUFF[o + 6]) : 0.0;
	int x0 = max(0, int(floor((x - reach + org) / sp - 0.5))), x1 = min(n - 1, int(ceil((x + reach + org) / sp - 0.5)));
	int y0 = max(0, int(floor((y - reach + org) / sp - 0.5))), y1 = min(n - 1, int(ceil((y + reach + org) / sp - 0.5)));
	for (int cy = y0; cy <= y1; cy++) for (int cx = x0; cx <= x1; cx++) {
		uint l = uint(cy * n + cx);
		if (INSIDE[base + l] == 0) continue;
		float dx = (float(cx) + 0.5) * sp - org - x, dy = (float(cy) + 0.5) * sp - org - y;
		float c = mass / (6.2831853 * v) * exp(-(dx * dx + dy * dy) * 0.5 / v) * FAINT_UNIT;
		ADD_FIXED_WIDE(FAINTLO, FAINTHI, l, c)
	}
}
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

## The nutrient picture of dish row `pcs.pa`: `pcs.pb` visible_above, `pcs.pc` alpha_scale, `pcs.pd` max_alpha.
const K_POOL_HAZE := """
void f(uint l) {
	uint d = uint(pcs.pa);
	float c = VIEW[DPU(d, DP_FIELD_BASE) + l];
	uint px = 0u;
	if (c > pcs.pb) px = 230u | (191u << 8) | (77u << 16) | (uint(min(sqrt(c) * pcs.pc, pcs.pd)) << 24);
	HAZEPIX[l] = px;
}
GRID_LOOP(f, DPU(uint(pcs.pa), DP_CELLS) * DPU(uint(pcs.pa), DP_CELLS))
"""

## The steering picture of dish row `pcs.pa`: VQ holds the swimmer's speed, its sense range, max_alpha and the
## steering window.
const K_POOL_STEER_MAP := """
float view_cell(uint base, uint n, int ix, int iy) {
	int o = OWNER[base + uint(iy) * n + uint(ix)];
	return o < 0 ? 0.0 : VIEW[uint(o)];
}
void f(uint l) {
	uint d = uint(pcs.pa), n = DPU(d, DP_CELLS), base = DPU(d, DP_FIELD_BASE);
	uint px = 0u;
	if (INSIDE[base + l] != 0) {
		int ni = int(n), x = int(l % n), y = int(l / n);
		int xm = max(x - 1, 0), xp = min(x + 1, ni - 1), ym = max(y - 1, 0), yp = min(y + 1, ni - 1);
		float sp = DPF(d, DP_SPACING);
		float gx = (view_cell(base, n, xp, y) - view_cell(base, n, xm, y)) / (float(xp - xm) * sp);
		float gy = (view_cell(base, n, x, yp) - view_cell(base, n, x, ym)) / (float(yp - ym) * sp);
		float reliable = 2.0 * steering_chance_d(d, VQ[0], VQ[1], VIEW[base + l], sqrt(gx * gx + gy * gy), VQ[3]) - 1.0;
		px = 90u | (190u << 8) | (255u << 16) | (uint(clamp(reliable * VQ[2], 0.0, 255.0)) << 24);
	}
	STEERPIX[l] = px;
}
GRID_LOOP(f, DPU(uint(pcs.pa), DP_CELLS) * DPU(uint(pcs.pa), DP_CELLS))
"""

## The thumbnails' density tiles: a count of the bups in each texel of each dish's tile, the most in any texel of the tile,
## then the tile's texels as white with the alpha the square root of the count over the most (so a sparse dish still shows). THUMBN is
## D_MAX x THUMB_TILE² counts; THUMBMAX one word a row.
const K_POOL_THUMB_CLEAR := """
void f(uint k) { THUMBN[k] = 0u; if (k < D_MAX) THUMBMAX[k] = 0u; }
GRID_LOOP(f, D_MAX * THUMB_TILE * THUMB_TILE)
"""

const K_POOL_THUMB_SPLAT := """
void f(uint i, uint d, uint l) {
	uint b = i * RECORD_WORDS;
	if (BUPS[b + R_PY] == -2.0) return;
	float r = DPF(d, DP_RADIUS), scale = float(THUMB_TILE) / (2.0 * r);
	uint tx = uint(clamp(int((BUPS[b + R_X] + r) * scale), 0, int(THUMB_TILE) - 1));
	uint ty = uint(clamp(int((BUPS[b + R_Y] + r) * scale), 0, int(THUMB_TILE) - 1));
	uint n = atomicAdd(THUMBN[(d * THUMB_TILE + ty) * THUMB_TILE + tx], 1u) + 1u;
	atomicMax(THUMBMAX[d], n);
}
BUP_LOOP(f)
"""

const K_POOL_THUMB_RESOLVE := """
void f(uint k) {
	uint d = k / (THUMB_TILE * THUMB_TILE), t = k % (THUMB_TILE * THUMB_TILE), tx = t % THUMB_TILE, ty = t / THUMB_TILE;
	uint most = THUMBMAX[d], n = THUMBN[k];
	uint alpha = most == 0u ? 0u : uint(clamp(sqrt(float(n) / float(most)) * 255.0 + 0.5, 0.0, 255.0));
	uint across = THUMB_ATLAS / THUMB_TILE;
	THUMBS[((d / across) * THUMB_TILE + ty) * THUMB_ATLAS + (d % across) * THUMB_TILE + tx] = alpha == 0u ? 0u : (255u | (255u << 8) | (255u << 16) | (alpha << 24));
}
GRID_LOOP(f, D_MAX * THUMB_TILE * THUMB_TILE)
"""


static func _register_pool(out: Dictionary) -> void:
	var tile := "const uint THUMB_TILE = %du;\nconst uint THUMB_ATLAS = %du;\n" % [THUMB_TILE, THUMB_ATLAS]
	var view_buffers := ["DISHP", "OWNER", "INSIDE", "VIEW"]
	assert(GpuLayout.D_MAX == (THUMB_ATLAS / THUMB_TILE) * (THUMB_ATLAS / THUMB_TILE), "the atlas holds one tile a dish row")
	GpuKernels.add(out, "pool_payload", K_POOL_PAYLOAD, ["P", "DSTATE", "BUPS", "BUPS_U", "PAYLOAD", "IDTEX"], "", 64, POOL_DRAW_TYPES)
	var faint := "const float FAINT_UNIT = %.1f;\n" % FAINT_UNIT + GpuKernels.FIXED_FUNCS
	GpuKernels.add(out, "pool_view_faint_clear", K_POOL_VIEW_FAINT_CLEAR, ["DISHP", "FAINTLO", "FAINTHI"], "", 64, POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_view_faint", K_POOL_VIEW_FAINT, ["WORLD", "DISHP", "PUFF", "PDLO", "PDHI", "PSCALE", "INSIDE", "FAINTLO", "FAINTHI"], faint, 64, POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_view", K_POOL_VIEW, ["DISHP", "CONC", "INSIDE", "VIEW", "FAINTLO", "FAINTHI"], faint, 64, POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_haze", K_POOL_HAZE, ["DISHP", "VIEW", "HAZEPIX"], "", 64, POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_steer_map", K_POOL_STEER_MAP, ["P", "TABLE", "DISHP", "OWNER", "INSIDE", "VIEW", "VQ", "STEERPIX"],
		GpuKernelsField.LOOKUP_FUNCS + GpuKernelsClouds.POOL_STEER_FUNCS, 64, POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_thumb_clear", K_POOL_THUMB_CLEAR, ["THUMBN", "THUMBMAX"], tile, 64, POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_thumb_splat", K_POOL_THUMB_SPLAT, ["WORLD", "BLKDISH", "DSTATE", "DISHP", "BUPS", "THUMBN", "THUMBMAX"], tile, 64, POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_thumb_resolve", K_POOL_THUMB_RESOLVE, ["THUMBN", "THUMBMAX", "THUMBS"], tile, 64, POOL_DRAW_TYPES)


## Adds the drawing's kernels to `out` (see GpuKernels.all()).
static func register(out: Dictionary) -> void:
	_register_pool(out)
