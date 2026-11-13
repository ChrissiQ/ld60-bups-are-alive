class_name GpuKernelsField
extends RefCounted
## The field's kernels and the bups' uptake from it (see gpu/kernels.gd for how a kernel is made and registered): the feed, the
## diffusion of the nutrient and of the acetate, the snapshot the bups read, swimming, the bups' demand on the cells and the clouds,
## the cells' shares, and what each bup takes and lets go.

const LOOKUP_FUNCS := """
void lookup(float s, float eps, out float f, out float along, out float across) {
	int ns = int(P[P_MOTION_NS]), ne = int(P[P_MOTION_NE]);
	float below = 1.0;
	if (s < P[P_MOTION_S0]) { below = s / P[P_MOTION_S0]; s = P[P_MOTION_S0]; }
	float x = clamp((log(s) - P[P_MOTION_LS0]) / P[P_MOTION_DLS], 0.0, float(ns - 1) - 1e-4);
	float y = clamp((log(max(eps, 1e-12)) - P[P_MOTION_LE0]) / P[P_MOTION_DLE], 0.0, float(ne - 1) - 1e-4);
	int i = int(x), j = int(y);
	float tx = x - float(i), ty = y - float(j);
	int k00 = i * ne + j, k10 = k00 + ne, k01 = k00 + 1, k11 = k10 + 1;
	float w00 = (1.0 - tx) * (1.0 - ty), w10 = tx * (1.0 - ty), w01 = (1.0 - tx) * ty, w11 = tx * ty;
	int o1 = ns * ne, o2 = 2 * ns * ne, o3 = 3 * ns * ne;
	f = below * (TABLE[k00] * w00 + TABLE[k10] * w10 + TABLE[k01] * w01 + TABLE[k11] * w11);
	along = TABLE[o1 + k00] * w00 + TABLE[o1 + k10] * w10 + TABLE[o1 + k01] * w01 + TABLE[o1 + k11] * w11;
	across = TABLE[o2 + k00] * w00 + TABLE[o2 + k10] * w10 + TABLE[o2 + k01] * w01 + TABLE[o2 + k11] * w11;
	if (below < 1.0) {
		float flatd = TABLE[o3 + j] * (1.0 - ty) + TABLE[o3 + j + 1] * ty;
		along = flatd + (along - flatd) * below;
		across = flatd + (across - flatd) * below;
	}
}
"""

const K_SWIM := """
void main() {
	BUP_RECORD_THREAD
	float x = BUPS[b + R_X], y = BUPS[b + R_Y], dx = BUPS[b + R_DX], dy = BUPS[b + R_DY];
	float energy = BUPS[b + R_ENERGY], mass = BUPS[b + R_MASS];
	float speed = BUPS[b + R_SPEED], sense = BUPS[b + R_SENSE], metab = BUPS[b + R_METABOLISM], drag = P[P_DRAG_UPKEEP] * BUPS[b + R_SPEED] * BUPS[b + R_SPEED], donor = BUPS[b + R_DONOR];  // (the drag cost from the speed gene)
	float delta = P[P_DELTA];
	uint s = hash(hash(CNT[CNT_SEED] ^ (CNT[CNT_STEP] * 0x85EBCA6BU) ^ 12345U) + i * 0x9E3779B9U);  // (this dish's stream, this step, this bup)
	float size = sqrt(mass);
	float srange = sense * sqrt(size / P[P_REFERENCE_SIZE]);
	float sense_k = P[P_GRADIENT_NOISE] * (P[P_REFERENCE_SENSE] / srange);
	float radius = P[P_RADIUS];
	float limit = radius - 0.5 * mass * P[P_MASS_UM];
	float nw2 = limit > 0.0 ? limit * limit : -1.0;
	float hx = 0.0, hy = 0.0, hl = 0.0; bool pending = false;
	float floor_c = P[P_DETECTION_FLOOR], noise_ref = P[P_NOISE_REFERENCE];
	// what it reads at the start, and from the clouds that reach it how finely to cut its step
	float c0, gx0, gy0; readf(x, y, c0, gx0, gy0);
	float pc, pgx, pgy, sig; puffs_at(x, y, pc, pgx, pgy, sig);
	c0 += pc; gx0 += pgx; gy0 += pgy;
	int moves = 0;
	bool fine = P[P_MOVES] > 0.5 && delta <= P[P_FINE_STEP];  // (a step as short as the fine step: it follows the individual run and tumble)
	if (P[P_MOVES] > 0.5 && !fine) {
		float structure = min(P[P_SPACING], 2.0 * sig);
		float sc = max(1.0, structure / max(P[P_MOTION_STRUCTURE], 1.0));
		moves = max(1, int(ceil(delta / (P[P_MOTION_STEP] * sc * sc))));
	}
	float sub = delta / float(max(moves, 1));
	for (int m = 0; m < moves; m++) {
		float c, gx, gy;
		if (m == 0) { c = c0; gx = gx0; gy = gy0; }
		else {
			readf(x, y, c, gx, gy);
			float qc, qgx, qgy, qs; puffs_at(x, y, qc, qgx, qgy, qs);
			c += qc; gx += qgx; gy += qgy;
		}
		float lx = gx / (floor_c + c), ly = gy / (floor_c + c);
		float glen = sqrt(lx * lx + ly * ly);
		float err = min(sense_k * sqrt(noise_ref / max(c, 1e-5)), 5.0);
		float f, along, across; lookup(speed * glen, err, f, along, across);
		float kick = 2.0 * speed * speed * sub;
		float up = gauss(s) * sqrt(along * kick);
		float side = gauss(s) * sqrt(across * kick);
		float sx = up, sy = side;
		if (glen > 1e-9) {
			float ux = lx / glen, uy = ly / glen;
			up += speed * f * sub;
			sx = ux * up - uy * side;
			sy = uy * up + ux * side;
		}
		x += sx; y += sy;
		float sl = sqrt(sx * sx + sy * sy);
		if (sl > 1e-6) { hx = sx; hy = sy; hl = sl; pending = true; }
		if (x * x + y * y > nw2) {
			float dist = sqrt(x * x + y * y);
			if (dist > limit && limit > 0.0) {
				float back = 2.0 * limit - dist;
				back = back < 0.5 * limit ? limit : back;
				x = x * back / dist; y = y * back / dist;
			}
			if (pending) { dx = hx / hl; dy = hy / hl; pending = false; }
			dist = sqrt(x * x + y * y);
			if (dist > limit) {
				float nx = x / dist, ny = y / dist;
				x = nx * limit; y = ny * limit;
				float dt = dx * nx + dy * ny;
				float ax = dx - nx * dt, ay = dy - ny * dt;
				float al = sqrt(ax * ax + ay * ay);
				if (al < 0.1) { float sg = u01(s) < 0.5 ? 1.0 : -1.0; ax = -ny * sg; ay = nx * sg; al = 1.0; }
				dx = ax / al; dy = ay / al;
			}
		}
	}
	if (pending) { dx = hx / hl; dy = hy / hl; }
	if (fine) {
		// It reads the nutrient where it is (on a log scale) and compares it with its own recent past, and tumbles less often while it improves; while
		// it tumbles it does not swim; a run bends a little by rotational diffusion.
		float memory = exp(-delta / P[P_MEMORY_SHORT]);
		float noise = BUPS[b + R_NOISE] * memory + sqrt(1.0 - memory * memory) * gauss(s);
		float signal = log(1.0 + c0 / floor_c);
		float fast = BUPS[b + R_FAST], slow = BUPS[b + R_SLOW];
		if (fast < 0.0) { fast = signal; slow = signal; }  // (none read yet)
		fast += (signal - fast) * (1.0 - memory);
		slow += (signal - slow) * (1.0 - exp(-delta / P[P_MEMORY_LONG]));
		float err_now = min(sense_k * sqrt(noise_ref / max(c0, 1e-5)), 5.0);
		float rate = P[P_TUMBLE_BASE] * clamp(1.0 - P[P_CHEMOTAXIS_GAIN] * (fast - slow + err_now * noise), P[P_TUMBLE_UP_FACTOR], 1.0);
		float tumbling = BUPS[b + R_TUMBLING];
		if (tumbling > 0.0) {
			tumbling -= delta;
		} else {
			float turn;
			if (u01(s) < rate * delta) {
				tumbling = P[P_TUMBLE_SECONDS];
				turn = gauss(s) * P[P_TUMBLE_TURN_SPREAD] + P[P_TUMBLE_TURN_MEAN];
				if (u01(s) >= 0.5) turn = -turn;
			} else {
				turn = gauss(s) * P[P_ROTATIONAL_DIFFUSION] * sqrt(delta);
			}
			float cs = cos(turn), sn = sin(turn);
			float ndx = dx * cs - dy * sn, ndy = dx * sn + dy * cs;
			float nl = sqrt(ndx * ndx + ndy * ndy);
			if (nl > 0.0) { dx = ndx / nl; dy = ndy / nl; } else { dx = ndx; dy = ndy; }
			x += dx * speed * delta; y += dy * speed * delta;
		}
		float dist = sqrt(x * x + y * y);
		if (dist > limit) {  // (the wall: it is turned along it, and slides until a tumble frees it)
			float nx = x / dist, ny = y / dist;
			x = nx * limit; y = ny * limit;
			float dt = dx * nx + dy * ny;
			float ax = dx - nx * dt, ay = dy - ny * dt;
			float al = sqrt(ax * ax + ay * ay);
			if (al < 0.1) { float sg = u01(s) < 0.5 ? 1.0 : -1.0; ax = -ny * sg; ay = nx * sg; al = 1.0; }
			dx = ax / al; dy = ay / al;
		}
		BUPS[b + R_FAST] = fast; BUPS[b + R_SLOW] = slow; BUPS[b + R_NOISE] = noise; BUPS[b + R_TUMBLING] = tumbling;
	} else {
		BUPS[b + R_FAST] = -1.0;  // (the signal memory isn't kept up while drifting)
	}
	BUPS[b + R_X] = x; BUPS[b + R_Y] = y; BUPS[b + R_DX] = dx; BUPS[b + R_DY] = dy;
	// then it pays its upkeep and grows (with the stationary phase on, a bup at the growth floor pays only the starving maintenance, from the
	// reserve and then from its body)
	if (P[P_STATIONARY] > 0.5 && energy <= P[P_MAINTENANCE_FLOOR]) {
		energy -= P[P_STARVE_COST] * mass * delta;
		if (energy < 0.0) { mass += energy / P[P_COST_PER_MASS]; energy = 0.0; }
		BUPS[b + R_ENERGY] = energy; BUPS[b + R_MASS] = mass;
		return;
	}
	float upkeep = P[P_UPKEEP_SCALE] * (P[P_BASE_UPKEEP] + P[P_MAINTENANCE_PER_MASS] * mass) + drag * size + P[P_SENSE_UPKEEP] * sense;
	energy -= upkeep * delta;
	if (energy > P[P_MAINTENANCE_FLOOR]) {
		int rl = int(BUPS[b + R_REACH] + 0.5);
		float raised = float((rl & 3) + ((rl >> 2) & 3) + ((rl >> 4) & 3) + ((rl >> 6) & 3));
		float grow = min(P[P_GROWTH_RATE] * metab * mass * delta * (donor > 0.5 ? 1.0 - P[P_DONOR_COST] : 1.0) * max(0.2, 1.0 - P[P_REACH_COST] * raised) * (((rl >> 8) & 3) == 2 ? 1.0 - P[P_KEY_COST] : 1.0), (energy - P[P_MAINTENANCE_FLOOR]) / P[P_COST_PER_MASS]);  // (a donor, and a bup with raised ceilings, give up a share of their growth)
		energy -= grow * P[P_COST_PER_MASS];
		mass += grow;
	}
	BUPS[b + R_ENERGY] = energy; BUPS[b + R_MASS] = mass;
}
"""


## ---- The pooled world's field kernels: per dish row `d`. ----
## A dish's cells are one run of the pool's field buffers: its cell `l` (row-major in its grid) is the cell `DP_FIELD_BASE + l`, and OWNER,
## CELLOF, CELL2 and the cloud lists hold pool cells, never a dish's own index. The pool's cells in use (the bound of the cell kernels) are
## WORLD[WD_CELLS]; a dish's own geometry is in DISHP. The motion table, and every constant of the model, stay in P; no pooled kernel reads
## P's slots of a dish (cells, spacing, origin, radius, feed, handover, the bins, the capacities).
const POOL_READF := """
// the field's concentration (and its gradient) at a point of dish d, bilinear in the snapshot
void readf_d(uint d, float x, float y, out float c, out float gx, out float gy) {
	int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS);
	float fx = clamp((x + org) / sp - 0.5, 0.0, float(n) - 1.001);
	float fy = clamp((y + org) / sp - 0.5, 0.0, float(n) - 1.001);
	int x0 = int(fx), y0 = int(fy);
	float tx = fx - float(x0), ty = fy - float(y0);
	int i0 = int(DPU(d, DP_FIELD_BASE)) + y0 * n + x0;
	float c00 = EFF[i0], c10 = EFF[i0 + 1], c01 = EFF[i0 + n], c11 = EFF[i0 + n + 1];
	float top = c00 + (c10 - c00) * tx;
	float bottom = c01 + (c11 - c01) * tx;
	c = top + (bottom - top) * ty;
	gx = ((c10 - c00) + ((c11 - c01) - (c10 - c00)) * ty) / sp;
	gy = (bottom - top) / sp;
}
// the pool cell of dish d that holds a point
uint cell_at(uint d, float x, float y) {
	int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS);
	int ix = clamp(int((x + org) / sp), 0, n - 1), iy = clamp(int((y + org) / sp), 0, n - 1);
	return DPU(d, DP_FIELD_BASE) + uint(iy * n + ix);
}
"""

const POOL_READC := """
// the grid's concentration a bup at the point reads (bilinear in the snapshot), and how much of it is its own cell's (`own`, a pool cell)
void readc_d(uint d, float x, float y, int own, out float c, out float own_share) {
	int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS);
	float fx = clamp((x + org) / sp - 0.5, 0.0, float(n) - 1.001);
	float fy = clamp((y + org) / sp - 0.5, 0.0, float(n) - 1.001);
	int x0 = int(fx), y0 = int(fy);
	float tx = fx - float(x0), ty = fy - float(y0);
	int i0 = int(DPU(d, DP_FIELD_BASE)) + y0 * n + x0;
	float c00 = EFF[i0], c10 = EFF[i0 + 1], c01 = EFF[i0 + n], c11 = EFF[i0 + n + 1];
	float top = c00 + (c10 - c00) * tx;
	float bottom = c01 + (c11 - c01) * tx;
	c = top + (bottom - top) * ty;
	own_share = 0.0;
	if (OWNER[i0] == own) own_share += (1.0 - tx) * (1.0 - ty);
	if (OWNER[i0 + 1] == own) own_share += tx * (1.0 - ty);
	if (OWNER[i0 + n] == own) own_share += (1.0 - tx) * ty;
	if (OWNER[i0 + n + 1] == own) own_share += tx * ty;
}
"""

const K_POOL_CLEAR := """
void f(uint c, uint d, uint l) { DLO[c] = 0u; DHI[c] = 0u; RLO[c] = 0u; RHI[c] = 0u; ALO[c] = 0u; AHI[c] = 0u; }
CELL_LOOP(f, WORLD[WD_CELLS])
"""

const K_POOL_SNAPSHOT := """
void f(uint c, uint d, uint l) { int o = OWNER[c]; EFF[c] = o >= 0 ? CONC[o] : 0.0; }
CELL_LOOP(f, WORLD[WD_CELLS])
"""

const K_POOL_FEED := """
void f(uint c, uint d, uint l) { CONC[c] += DPF(d, DP_FEED) * WGT[c]; }
CELL_LOOP(f, WORLD[WD_CELLS])
"""

## Diffusion: one kernel per direction of the ping-pong, dispatched for pass p = pcs.pa over the first pcs.pb cells of the
## pool, which the host orders by iteration count (most first) so that the cells that still need pass p are a prefix (the end of a block of
## 256-aligned cells, which a float holds exactly up to 2^32). A dish whose own
## (even) count is done returns at once: its field is already in CONC where its lone run would leave it. The acetate's passes are
## skipped for a dish without the second food (its field is all zeros, which diffuse to zeros exactly).
const K_POOL_DIFFUSE := """
void f(uint c, uint d, uint l) {
	if (uint(pcs.pa) >= DPU(d, DP_ITERATIONS)) return;
	ACETATE_SKIP
	if (INSIDE[c] == 0) { DST[c] = SRC[c]; return; }
	int n = int(DPU(d, DP_CELLS));
	int x = int(l) % n, y = int(l) / n;
	float v = SRC[c], acc = 0.0, k = DPF(d, DP_K);
	if (x > 0 && INSIDE[c - 1u] != 0) acc += SRC[c - 1u] - v;
	if (x < n - 1 && INSIDE[c + 1u] != 0) acc += SRC[c + 1u] - v;
	if (y > 0 && INSIDE[c - uint(n)] != 0) acc += SRC[c - uint(n)] - v;
	if (y < n - 1 && INSIDE[c + uint(n)] != 0) acc += SRC[c + uint(n)] - v;
	DST[c] = v + k * acc;
}
CELL_LOOP(f, uint(pcs.pb))
"""

## The fused field pass: the feed and the diffusion's sub-iterations of both fields in shared-memory tiles with a halo, in place of
## pool_feed and the ping-pong of pool_diffuse_a/b and pool_diffuse2_a/b (which stay, for the checks that run them alone and for
## `SimCore.lone_field`). Per cell the arithmetic is the same, in the same order (the feed added to the cell as the first thing the first
## sub-iteration reads, then left, right, up, down, `v + k * acc`, a cell outside the dish copied); a halo cell is computed again by the
## tiles that share it from the same words, so its value is the same in each. A tile is FIELD_TILE cells square and a round of m sub-iterations
## (at most FIELD_HALO) reads a halo of m cells round it and writes only the tile, so a dish takes `field_rounds(iterations)` rounds, the
## rounds' m adding up to its iterations (`round_steps`). A round reads the A buffers (CONC, CONC2) when it is even and the B buffers (EFF,
## CONC2B) when it is odd, and writes the other: a dish's rounds are always an odd number, so the diffusion always ends in B, and the
## kernels that follow read the acetate there (pool_apply, pool_ac_cells, which writes CONC2 again) and pool_dep_land puts the glucose from
## EFF into CONC with the deposits. A dish without the second food has its acetate copied A to B in its first round (the second food's
## kernels read B). `TILES` holds a word a tile of the dishes running, those with the most rounds first: the dish's row in the upper 16
## bits and the tile's number in the dish in the lower; pcs.pa is the round, pcs.pb the tiles that still have a round to run.
const FIELD_TILE := 16
const FIELD_HALO := 3
const FIELD_GROUP := 256

## The rounds a dish of `iterations` (even) sub-iterations takes: the fewest of at most FIELD_HALO each, made odd.
static func field_rounds(iterations: int) -> int:
	var r := (iterations + FIELD_HALO - 1) / FIELD_HALO
	return r if r % 2 == 1 else r + 1


## The sub-iterations of round `r` of a dish of `iterations`: an even share of them, 1 to FIELD_HALO.
static func round_steps(iterations: int, r: int) -> int:
	var rounds := field_rounds(iterations)
	return (iterations * (r + 1)) / rounds - (iterations * r) / rounds


## The tiles across a dish of `n` cells across.
static func tiles_across(n: int) -> int:
	return (n + FIELD_TILE - 1) / FIELD_TILE


const K_POOL_FDIFF := """
#define TW FIELD_TILE_N
#define HL FIELD_HALO_N
#define SW (TW + 2 * HL)
#define SN (SW * SW)
shared float sg[2 * SN];
shared float sa[2 * SN];
shared uint si[SN];
void main() {
	if (gl_WorkGroupID.x >= uint(pcs.pb)) return;
	uint t = TILES[gl_WorkGroupID.x];
	uint d = t >> 16u, ti = t & 0xFFFFu;
	uint iters = DPU(d, DP_ITERATIONS);
	uint rounds = (iters + 2u) / 3u;
	if ((rounds & 1u) == 0u) rounds += 1u;
	uint r = uint(pcs.pa);
	if (r >= rounds) return;
	uint m = (iters * (r + 1u)) / rounds - (iters * r) / rounds;
	int n = int(DPU(d, DP_CELLS));
	uint base = DPU(d, DP_FIELD_BASE);
	int tpa = (n + TW - 1) / TW;
	int x0 = (int(ti) % tpa) * TW, y0 = (int(ti) / tpa) * TW;
	float k = DPF(d, DP_K), feed = DPF(d, DP_FEED);
	bool ac = ((DPU(d, DP_FLAGS) >> DPF_ACETATE) & 1u) != 0u;
	bool odd = (r & 1u) != 0u;
	uint lid = gl_LocalInvocationID.x;
	for (uint i = lid; i < uint(SN); i += FIELD_GROUP_N) {
		int gx = x0 + int(i) % SW - HL, gy = y0 + int(i) / SW - HL;
		float g = 0.0, a = 0.0;
		uint s = 0u;
		if (gx >= 0 && gx < n && gy >= 0 && gy < n) {
			uint c = base + uint(gy * n + gx);
			s = uint(INSIDE[c]);
			if (odd) {
				g = EFF[c];
				if (ac) a = CONC2B[c];
			} else {
				g = CONC[c];
				g += feed * WGT[c];
				if (ac) a = CONC2[c];
			}
		}
		sg[i] = g; sa[i] = a; si[i] = s;
	}
	barrier();
	uint p = 0u;
	for (uint it = 0u; it < m; it++) {
		uint so = p * uint(SN), dso = (1u - p) * uint(SN);
		for (uint i = lid; i < uint(SN); i += FIELD_GROUP_N) {
			int lx = int(i) % SW, ly = int(i) / SW;
			int gx = x0 + lx - HL, gy = y0 + ly - HL;
			float v = sg[so + i], va = sa[so + i];
			float ov = v, ova = va;
			if (si[i] != 0u) {
				float acc = 0.0, acca = 0.0;
				if (gx > 0 && lx > 0 && si[i - 1u] != 0u) { acc += sg[so + i - 1u] - v; acca += sa[so + i - 1u] - va; }
				if (gx < n - 1 && lx < SW - 1 && si[i + 1u] != 0u) { acc += sg[so + i + 1u] - v; acca += sa[so + i + 1u] - va; }
				if (gy > 0 && ly > 0 && si[i - uint(SW)] != 0u) { acc += sg[so + i - uint(SW)] - v; acca += sa[so + i - uint(SW)] - va; }
				if (gy < n - 1 && ly < SW - 1 && si[i + uint(SW)] != 0u) { acc += sg[so + i + uint(SW)] - v; acca += sa[so + i + uint(SW)] - va; }
				ov = v + k * acc;
				ova = va + k * acca;
			}
			sg[dso + i] = ov; sa[dso + i] = ova;
		}
		barrier();
		p = 1u - p;
	}
	for (uint o = lid; o < uint(TW * TW); o += FIELD_GROUP_N) {
		int gx = x0 + int(o) % TW, gy = y0 + int(o) / TW;
		if (gx < n && gy < n) {
			uint c = base + uint(gy * n + gx);
			uint i = uint(HL + int(o) / TW) * uint(SW) + uint(HL + int(o) % TW) + p * uint(SN);
			if (odd) {
				CONC[c] = sg[i];
				if (ac) CONC2[c] = sa[i];
			} else {
				EFF[c] = sg[i];
				if (ac) CONC2B[c] = sa[i];
				else CONC2B[c] = CONC2[c];
			}
		}
	}
}
"""

## The glucose that the diffusion left in EFF, with the deposits waiting added, into CONC (pool_dep_apply when the glucose was left in CONC),
## and the deposits cleared (a pair of words already zero is not written).
const K_POOL_DEP_LAND := """
void f(uint c, uint d, uint l) {
	float v = EFF[c];
	uint lo = DPLO[c], hi = DPHI[c];
	if (lo != 0u || hi != 0u) {
		float m = FIX20(hi, lo);
		float sp = DPF(d, DP_SPACING);
		if (m > 0.0) v += m / (sp * sp);
		DPLO[c] = 0u; DPHI[c] = 0u;
	}
	CONC[c] = v;
}
CELL_LOOP(f, WORLD[WD_CELLS])
"""

## What the lone diffusion passes (SimCore.lone_field, for checks) do to leave the pool where the fused pass does: both fields' B buffers hold
## the diffused values.
const K_POOL_LAND_COPY := """
void f(uint c, uint d, uint l) { EFF[c] = CONC[c]; CONC2B[c] = CONC2[c]; }
CELL_LOOP(f, WORLD[WD_CELLS])
"""

const K_POOL_DEMAND := """
void add_fixed(uint cell, float w, int which) { // what is wanted (0), what is read (1) and the own cell's share of it (2), summed per cell
	if (which == 0) ADD_FIXED30(DLO, DHI, cell, w)
	else if (which == 1) ADD_FIXED30(RLO, RHI, cell, w)
	else ADD_FIXED30(ALO, AHI, cell, w)
}
void add_puff_demand(uint k, float mass) { ADD_FIXED20(PDLO, PDHI, k, mass) }
void f(uint i, uint d, uint l) {
	uint b = i * RECORD_WORDS;
	float x = BUPS[b + R_X], y = BUPS[b + R_Y], energy = BUPS[b + R_ENERGY], mass = BUPS[b + R_MASS], metab = BUPS[b + R_METABOLISM], yld = exp(-BUPS[b + R_HARM]) / sqrt(BUPS[b + R_METABOLISM]);
	float max_e = P[P_RESERVE_PER_MASS] * mass;
	WANT[i] = -1.0; WANTC[i] = 0.0; CELLOF[i] = -1;
	if (energy < max_e) {
		int o = OWNER[cell_at(d, x, y)];
		float cg = 0.0, own_share = 0.0;
		if (o >= 0) readc_d(d, x, y, o, cg, own_share);
		float cc, pgx, pgy, psig; puffs_at_d(d, x, y, cc, pgx, pgy, psig);
		float ct = cg + cc;
		if (ct > 0.0) {
			float rate = P[P_UPTAKE_PER_SIZE] * sqrt(mass) * metab;
			float room = max(max_e - energy, 0.0) / yld;
			float w = min(rate * ct / (P[P_HALF_SATURATION] + ct) * P[P_DELTA], room);
			if (w > 0.0) {
				float wg = cc > 0.0 ? w * cg / ct : w;
				float wc = w - wg;
				if (o >= 0 && CONC[o] > 0.0 && wg > 0.0) {
					WANT[i] = wg; CELLOF[i] = o;
					add_fixed(uint(o), wg, 0);
					add_fixed(uint(o), wg * min(cg / CONC[o], 8.0), 1);
					add_fixed(uint(o), wg * own_share, 2);
				}
				if (wc > 0.0 && cc > 0.0) {
					WANTC[i] = wc;
					uint e0, e1; bin_list(d, x, y, e0, e1);
					for (uint e = e0; e < e1; e++) {
						vec4 r0 = ENTD[e * 2u], r1 = ENTD[e * 2u + 1u];
						float ddx = x - r0.x, ddy = y - r0.y, r2 = fma(ddy, ddy, ddx * ddx);
						if (r2 <= r1.x) {
							uint k = uint(r1.z);
							float ci = r0.z / (6.2831853 * r0.w) * exp(-r2 * 0.5 / r0.w);
							add_puff_demand(k, wc * ci / cc);
						}
					}
				}
			}
		}
	}
}
BUP_LOOP(f)
"""

const K_POOL_CELLS := """
float neglog1m(float x) { // -ln(1 - x)
	if (x < 0.01) return x * (1.0 + x * (0.5 + x * (0.33333333 + x * 0.25)));
	return -log(1.0 - x);
}
void share(uint i, uint d) {
	float dm = FIX30(DHI[i], DLO[i]); // what the bups there wanted
	SCALE[i] = 0.0;
	float c0 = CONC[i];
	if (dm <= 0.0 || c0 <= 0.0) return;
	float rho = FIX30(RHI[i], RLO[i]) / dm; // the concentration they read, as a share of this cell's
	float al = max(FIX30(AHI[i], ALO[i]) / dm, 0.02); // and how much of what they read is this cell's
	float ct = max(rho * c0, 1e-12);
	float sp = DPF(d, DP_SPACING);
	float area = sp * sp;
	float k = P[P_HALF_SATURATION];
	float y = dm * (k + ct) / (area * ct);
	float lo = 0.0, hi = min(min(dm / area, c0 * 0.999999), ct * 0.999999 / al);
	if (hi + (k / al) * neglog1m(al * hi / ct) <= y) {
		lo = hi;
	} else {
		for (int it = 0; it < 32; it++) {
			float mid = 0.5 * (lo + hi);
			if (mid + (k / al) * neglog1m(al * mid / ct) < y) lo = mid; else hi = mid;
		}
		lo = 0.5 * (lo + hi);
	}
	SCALE[i] = lo * area / dm;
	CONC[i] = c0 - lo;
}
// only an owner cell holds sums (a bup's cell is always its owner), so this is where they are left at zero for the next step's demand
// (a step has no separate clearing pass); a word already zero is not written
void f(uint i, uint d, uint l) {
	if (OWNER[i] != int(i)) return;
	share(i, d);
	if (DLO[i] != 0u) DLO[i] = 0u;
	if (DHI[i] != 0u) DHI[i] = 0u;
	if (RLO[i] != 0u) RLO[i] = 0u;
	if (RHI[i] != 0u) RHI[i] = 0u;
	if (ALO[i] != 0u) ALO[i] = 0u;
	if (AHI[i] != 0u) AHI[i] = 0u;
}
CELL_LOOP(f, WORLD[WD_CELLS])
"""

const K_POOL_APPLY := """
void add_fixed2(uint cell, float w, int which) { // the acetate wanted (0) and let go (1), summed per cell
	if (which == 0) ADD_FIXED30(AWLO, AWHI, cell, w)
	else ADD_FIXED30(ADLO, ADHI, cell, w)
}
void f(uint i, uint d, uint l) {
	uint b = i * RECORD_WORDS;
	float wg = WANT[i], wc = WANTC[i];
	float mass = BUPS[b + R_MASS], yld = exp(-BUPS[b + R_HARM]) / sqrt(BUPS[b + R_METABOLISM]);
	float max_e = P[P_RESERVE_PER_MASS] * mass;
	float energy = BUPS[b + R_ENERGY];
	float x = BUPS[b + R_X], y = BUPS[b + R_Y];
	int o = OWNER[cell_at(d, x, y)];
	WANT2[i] = 0.0;
	if (wg > 0.0 || wc > 0.0) {
		float got = wg > 0.0 ? wg * SCALE[CELLOF[i]] : 0.0;
		if (wc > 0.0) {
			float cc, pgx, pgy, psig; puffs_at_d(d, x, y, cc, pgx, pgy, psig);
			uint e0, e1; bin_list(d, x, y, e0, e1);
			for (uint e = e0; e < e1; e++) {
				vec4 r0 = ENTD[e * 2u], r1 = ENTD[e * 2u + 1u];
				float ddx = x - r0.x, ddy = y - r0.y, r2 = fma(ddy, ddy, ddx * ddx);
				if (r2 <= r1.x) {
					uint k = uint(r1.z);
					float ci = r0.z / (6.2831853 * r0.w) * exp(-r2 * 0.5 / r0.w);
					got += wc * ci / cc * PSCALE[k];
				}
			}
		}
		float let_go = 0.0;
		if (got > 0.0 && mass > 0.0 && o >= 0) {
			float per_hour = got * yld / (P[P_COST_PER_MASS] * mass * P[P_DELTA]) * 3600.0;
			let_go = got * min(0.5, P[P_ACETATE_SLOPE] * max(0.0, per_hour - P[P_ACETATE_THRESHOLD]));
			if (let_go > 0.0) add_fixed2(uint(o), let_go, 1);
		}
		float before = energy;
		energy = min(energy + got * yld, max_e);
		float lost = got - (energy - before);
		LEDGER(d, LG_UPTAKE, lost)
		LEDGER(d, LG_MADE, -lost)
		LEDGER(d, LG_MADE, let_go)
	}
	float room = max_e - energy;
	if (o >= 0 && room > 0.0 && CONC2B[o] > 0.0) {
		float ca = CONC2B[o], cg = max(CONC[o], 0.0);
		float rate = P[P_ACETATE_UPTAKE] * (((int(BUPS[b + R_REACH] + 0.5) >> 8) & 3) == 2 ? P[P_KEY_FACTOR] : 1.0) * P[P_UPTAKE_PER_SIZE] * sqrt(mass) * BUPS[b + R_METABOLISM];
		float w2 = min(rate * ca / (P[P_HALF_SATURATION] + ca) * (P[P_HALF_SATURATION] / (P[P_HALF_SATURATION] + cg)) * P[P_DELTA], room / yld);
		if (w2 > 0.0) {
			WANT2[i] = w2; CELL2[i] = o;
			add_fixed2(uint(o), w2, 0);
		}
	}
	BUPS[b + R_ENERGY] = energy;
}
BUP_LOOP(f)
"""

const K_POOL_AC_CELLS := """
void f(uint i, uint d, uint l) {
	float dm = FIX30(AWHI[i], AWLO[i]);
	float dep = FIX30(ADHI[i], ADLO[i]);
	float sp = DPF(d, DP_SPACING);
	float area = sp * sp;
	float c = CONC2B[i];
	float s = 0.0;
	if (dm > 0.0 && c > 0.0) {
		s = min(1.0, c * area / dm);
		c = max(c - dm * s / area, 0.0);
	}
	SCALE2[i] = s;
	CONC2[i] = c + dep / area;
	AWLO[i] = 0u; AWHI[i] = 0u; ADLO[i] = 0u; ADHI[i] = 0u;
}
CELL_LOOP(f, WORLD[WD_CELLS])
"""

const K_POOL_AC_APPLY := """
void f(uint i, uint d, uint l) {
	float w = WANT2[i];
	if (w <= 0.0) return;
	uint b = i * RECORD_WORDS;
	float before = BUPS[b + R_ENERGY];
	BUPS[b + R_ENERGY] = min(BUPS[b + R_ENERGY] + w * SCALE2[CELL2[i]] * exp(-BUPS[b + R_HARM]) / sqrt(BUPS[b + R_METABOLISM]), P[P_RESERVE_PER_MASS] * BUPS[b + R_MASS]);
	float lost = w * SCALE2[CELL2[i]] - (BUPS[b + R_ENERGY] - before);
	LEDGER(d, LG_UPTAKE, lost)
	LEDGER(d, LG_MADE, -lost)
}
BUP_LOOP(f)
"""

## Swimming is the single dish's kernel with the dish's own words in place of P's dish slots, its stream from DISH_STREAM, and the dish's
## fields and clouds read through `readf_d` and `puffs_at_d`.
static func _pooled_swim() -> String:
	var body := K_SWIM
	body = body.replace("void main() {\n\tBUP_RECORD_THREAD", "void f(uint i, uint d, uint l) {\n\tuint b = i * RECORD_WORDS;")
	body = body.replace("uint s = hash(hash(CNT[CNT_SEED] ^ (CNT[CNT_STEP] * 0x85EBCA6BU) ^ 12345U) + i * 0x9E3779B9U);", "uint s = DISH_STREAM(d, l, 12345U);")
	body = body.replace("readf(", "readf_d(d, ").replace("puffs_at(", "puffs_at_d(d, ")
	body = body.replace("P[P_RADIUS]", "DPF(d, DP_RADIUS)").replace("P[P_SPACING]", "DPF(d, DP_SPACING)")
	body = body.replace("P[P_UPKEEP_SCALE]", "DPF(d, DP_UPKEEP_SCALE)").replace("P[P_NOISE_REFERENCE]", "DPF(d, DP_NOISE_REFERENCE)")
	body = body.replace("P[P_STATIONARY] > 0.5", "((DPU(d, DP_FLAGS) >> DPF_STATIONARY) & 1u) != 0u")
	assert(body.ends_with("}\n") and not body.contains("BUP_RECORD_THREAD") and not body.contains("CNT["), "swim: the body must end with the loop's closing brace")
	return body + "BUP_LOOP(f)\n"


## `pool_swim` and `pool_demand` in one pass over the bups (what the step runs; the two kernels stay for the checks that run them alone):
## a bup's demand reads only its own record, which only its own swim writes, and the field's snapshot and the clouds' lists, which
## swimming leaves alone. The energy ledger's upkeep (LG_UPKEEP) is what its reserve and body (at COST_PER_MASS) lost in the swim: the
## upkeep, or a starving bup's maintenance (its growth only moves reserve into body). A bup that wants of the clouds keeps what it read of
## them in CLOUDC for `pool_apply_count`, which would read the same lists at the same place.
static func pool_swim_demand() -> String:
	var demand := GpuKernelsLife.swapped(K_POOL_DEMAND, "WANTC[i] = wc;", "WANTC[i] = wc; CLOUDC[i] = cc;")
	return GpuKernelsLife.loop_function(_pooled_swim(), "f", "swim") + GpuKernelsLife.loop_function(demand, "f", "demand") + """
void swim_demand(uint i, uint d, uint l) {
	uint b = i * RECORD_WORDS;
	float energy0 = BUPS[b + R_ENERGY], mass0 = BUPS[b + R_MASS];
	swim(i, d, l);
	float lost = (energy0 - BUPS[b + R_ENERGY]) + P[P_COST_PER_MASS] * (mass0 - BUPS[b + R_MASS]);
	LEDGER(d, LG_UPKEEP, lost)
	LEDGER(d, LG_MADE, -lost)
	demand(i, d, l);
}
BUP_LOOP(swim_demand)
"""


## Adds these kernels to `out` (see GpuKernels.all()).
static func register(out: Dictionary) -> void:
	var cell_b := ["P", "WORLD", "CELLDISH", "DISHP"]
	var bup_b := ["P", "WORLD", "BLKDISH", "DSTATE", "DISHP"]
	var fixed := GpuKernels.FIXED_FUNCS
	GpuKernels.add(out, "pool_feed", K_POOL_FEED, cell_b + ["CONC", "WGT"])
	GpuKernels.add(out, "pool_clear", K_POOL_CLEAR, cell_b + ["DLO", "DHI", "RLO", "RHI", "ALO", "AHI"])
	GpuKernels.add(out, "pool_snapshot", K_POOL_SNAPSHOT, cell_b + ["CONC", "OWNER", "EFF"])
	GpuKernels.add(out, "pool_swim", _pooled_swim(), bup_b + ["BUPS", "EFF", "TABLE", "ENTD", "BINS", "BINC"], POOL_READF + LOOKUP_FUNCS + GpuKernelsClouds.POOL_CLOUD_FUNCS)
	GpuKernels.add(out, "pool_demand", K_POOL_DEMAND, bup_b + ["BUPS", "EFF", "OWNER", "CONC", "WANT", "WANTC", "CELLOF", "DLO", "DHI", "RLO", "RHI", "ALO", "AHI", "ENTD", "BINS", "BINC", "PDLO", "PDHI"], fixed + POOL_READF + POOL_READC + GpuKernelsClouds.POOL_CLOUD_FUNCS)
	GpuKernels.add(out, "pool_swim_demand", pool_swim_demand(), bup_b + ["BUPS", "EFF", "TABLE", "OWNER", "CONC", "WANT", "WANTC", "CLOUDC", "CELLOF", "DLO", "DHI", "RLO", "RHI", "ALO", "AHI", "ENTD", "BINS", "BINC", "PDLO", "PDHI"],
		fixed + POOL_READF + POOL_READC + LOOKUP_FUNCS + GpuKernelsClouds.POOL_CLOUD_FUNCS)
	GpuKernels.add(out, "pool_cells", K_POOL_CELLS, cell_b + ["CONC", "OWNER", "DLO", "DHI", "RLO", "RHI", "ALO", "AHI", "SCALE"], fixed)
	GpuKernels.add(out, "pool_apply", K_POOL_APPLY, bup_b + ["BUPS", "EFF", "WANT", "WANTC", "CELLOF", "SCALE", "ENTD", "BINS", "BINC", "PSCALE", "OWNER", "CONC", "CONC2B", "WANT2", "CELL2", "AWLO", "AWHI", "ADLO", "ADHI"], fixed + POOL_READF + GpuKernelsClouds.POOL_CLOUD_FUNCS)
	GpuKernels.add(out, "pool_ac_cells", K_POOL_AC_CELLS, cell_b + ["CONC2", "CONC2B", "AWLO", "AWHI", "ADLO", "ADHI", "SCALE2"], fixed)
	GpuKernels.add(out, "pool_ac_apply", K_POOL_AC_APPLY, bup_b + ["BUPS", "WANT2", "CELL2", "SCALE2"])
	GpuKernels.add(out, "pool_dep_land", K_POOL_DEP_LAND, cell_b + ["EFF", "CONC", "DPLO", "DPHI"], fixed)
	GpuKernels.add(out, "pool_land_copy", K_POOL_LAND_COPY, cell_b + ["CONC", "EFF", "CONC2", "CONC2B"])
	var fdiff := K_POOL_FDIFF.replace("FIELD_TILE_N", str(FIELD_TILE)).replace("FIELD_HALO_N", str(FIELD_HALO)).replace("FIELD_GROUP_N", str(FIELD_GROUP) + "u")
	GpuKernels.add(out, "pool_fdiff", fdiff, ["DISHP", "TILES", "INSIDE", "CONC", "EFF", "WGT", "CONC2", "CONC2B"], "", FIELD_GROUP)
	var no_skip := ""
	var ac_skip := "if (((DPU(d, DP_FLAGS) >> DPF_ACETATE) & 1u) == 0u) return;"
	for pass_kind in [["pool_diffuse_a", "CONC", "EFF", no_skip], ["pool_diffuse_b", "EFF", "CONC", no_skip], ["pool_diffuse2_a", "CONC2", "CONC2B", ac_skip], ["pool_diffuse2_b", "CONC2B", "CONC2", ac_skip]]:
		var text := K_POOL_DIFFUSE.replace("SRC", pass_kind[1]).replace("DST", pass_kind[2]).replace("ACETATE_SKIP", pass_kind[3])
		GpuKernels.add(out, pass_kind[0], text, ["CELLDISH", "DISHP", "INSIDE", pass_kind[1], pass_kind[2]])
