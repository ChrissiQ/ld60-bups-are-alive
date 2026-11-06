class_name GpuKernelsClouds
extends RefCounted
## The plankton clouds (see gpu/kernels.gd for how a kernel is made and registered): the clouds and deposits the dish's own world sends,
## the clouds spreading and going to the grid, their shares of what the bups want, their lists by place, the compaction of their slots,
## and the clouds of the dead.

const CLOUD_FUNCS := """
// the clouds' concentration and gradient where a bup is, and the smallest sigma among the clouds that reach it (as the CPU's puff_probe)
void puffs_at(float x, float y, out float c, out float gx, out float gy, out float sigma) {
	c = 0.0; gx = 0.0; gy = 0.0; sigma = 1e18;
	int nb = int(P[P_BINS_ACROSS]); float bs = P[P_BIN_SIZE];
	int bx = clamp(int((x + P[P_ORIGIN]) / bs), 0, nb - 1), by = clamp(int((y + P[P_ORIGIN]) / bs), 0, nb - 1);
	uint b = uint(by * nb + bx);
	uint e0 = BINS[b], e1 = min(e0 + BINC[b], uint(P[P_ENTRY_CAPACITY]));
	for (uint e = e0; e < e1; e++) {
		vec4 r0 = ENTD[e * 2u], r1 = ENTD[e * 2u + 1u];  // x, y, mass, variance | reach^2, sigma, cloud index, 0
		float dx = x - r0.x, dy = y - r0.y, r2 = fma(dy, dy, dx * dx);  // (fma written out: the compiler contracted the old gathering code this way, and exp() magnifies a last-bit change in r2)
		if (r2 <= r1.x) {
			float v = r0.w;
			float ci = r0.z / (6.2831853 * v) * exp(-r2 * 0.5 / v);
			c += ci; gx -= ci * dx / v; gy -= ci * dy / v;
			sigma = min(sigma, r1.y);
		}
	}
}
"""

## New clouds and deposits come from the CPU (plankton bursts, sources) as events with the step they belong to.
## One thread, so the slots are taken in the events' order. A cloud that finds every slot taken goes onto the grid at once, as the CPU's
## add_puff does past MAX_CLOUDS (its deposit_gaussian, and deposit_xy if no cell takes any of it), and is counted in PCNT_TO_GRID.
const K_EV_PUFFS := """
void to_grid(float x, float y, float mass, float v) {
	int n = int(P[P_CELLS]); float sp = P[P_SPACING]; float area = sp * sp; float reach = 4.0 * sqrt(v);
	int x0 = max(0, int(floor((x - reach + P[P_ORIGIN]) / sp - 0.5))), x1 = min(n - 1, int(ceil((x + reach + P[P_ORIGIN]) / sp - 0.5)));
	int y0 = max(0, int(floor((y - reach + P[P_ORIGIN]) / sp - 0.5))), y1 = min(n - 1, int(ceil((y + reach + P[P_ORIGIN]) / sp - 0.5)));
	float sum = 0.0;
	for (int cy = y0; cy <= y1; cy++) for (int cx = x0; cx <= x1; cx++) {
		if (INSIDE[cy * n + cx] == 0) continue;
		float dx = (float(cx) + 0.5) * sp - P[P_ORIGIN] - x, dy = (float(cy) + 0.5) * sp - P[P_ORIGIN] - y;
		sum += exp(-(dx * dx + dy * dy) / (2.0 * v));
	}
	if (sum > 1e-12) {
		for (int cy = y0; cy <= y1; cy++) for (int cx = x0; cx <= x1; cx++) {
			if (INSIDE[cy * n + cx] == 0) continue;
			float dx = (float(cx) + 0.5) * sp - P[P_ORIGIN] - x, dy = (float(cy) + 0.5) * sp - P[P_ORIGIN] - y;
			CONC[cy * n + cx] += mass * exp(-(dx * dx + dy * dy) / (2.0 * v)) / sum / area;
		}
		return;
	}
	float fx = (x + P[P_ORIGIN]) / sp - 0.5, fy = (y + P[P_ORIGIN]) / sp - 0.5;
	int bx = int(floor(fx)), by = int(floor(fy));
	float tx = fx - float(bx), ty = fy - float(by);
	int cells[4]; float weights[4]; float kept = 0.0; int count = 0;
	for (int k = 0; k < 4; k++) {
		int cx = bx + (k & 1), cy = by + (k >> 1);
		if (cx < 0 || cy < 0 || cx >= n || cy >= n || INSIDE[cy * n + cx] == 0) continue;
		float w = ((k & 1) != 0 ? tx : 1.0 - tx) * ((k >> 1) != 0 ? ty : 1.0 - ty);
		cells[count] = cy * n + cx; weights[count] = w; kept += w; count++;
	}
	if (count == 0) return;
	if (kept <= 1e-9) { CONC[cells[0]] += mass / area; return; }
	for (int k = 0; k < count; k++) CONC[cells[k]] += mass * weights[k] / kept / area;
}
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	int st = int(pcs.pa);
	int start = EVR[st * 4], cnt = EVR[st * 4 + 1];
	uint slots = PCNT[PCNT_SLOTS], cap = uint(P[P_PUFF_CAPACITY]);
	for (int e = 0; e < cnt; e++) {
		if (slots >= cap) {
			uint qo = uint(start + e) * EV_PUFF_FLOATS;
			to_grid(EVP[qo], EVP[qo + 1], EVP[qo + 2], EVP[qo + 3]);
			PCNT[PCNT_TO_GRID] += 1u;
			continue;
		}
		uint q = uint(start + e) * EV_PUFF_FLOATS, o = slots * 8u;
		PUFF[o] = EVP[q]; PUFF[o + 1] = EVP[q + 1]; PUFF[o + 2] = EVP[q + 2]; PUFF[o + 3] = EVP[q + 3]; PUFF[o + 4] = EVP[q + 4];
		PUFF[o + 5] = 1.0; PUFF[o + 6] = 0.0; PUFF[o + 7] = 0.0;
		slots++;
	}
	PCNT[PCNT_SLOTS] = slots;
}
"""

const K_EV_DEPOSITS := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	int st = int(pcs.pa);
	int start = EVR[st * 4 + 2], cnt = EVR[st * 4 + 3];
	for (int e = 0; e < cnt; e++) CONC[EVCC[start + e]] += EVCA[start + e];
}
"""

## What puts nutrient on the grid from many threads at once (the clouds that have spread to a cell, and the deaths' that find no slot): in fixed point,
## an exact sum whatever the order; `dep_apply` adds it to the field. Used by `puff_advance` and `death_clouds`.
const DEP_FUNCS := """
void add_dep(uint cell, float amount) { ADD_FIXED20(DPLO, DPHI, cell, amount) }
void deposit_xy(float x, float y, float mass) {
	int n = int(P[P_CELLS]); float sp = P[P_SPACING];
	float fx = (x + P[P_ORIGIN]) / sp - 0.5, fy = (y + P[P_ORIGIN]) / sp - 0.5;
	int x0 = int(floor(fx)), y0 = int(floor(fy));
	float tx = fx - float(x0), ty = fy - float(y0);
	int cells[4]; float weights[4]; float kept = 0.0; int count = 0;
	for (int k = 0; k < 4; k++) {
		int cx = x0 + (k & 1), cy = y0 + (k >> 1);
		if (cx < 0 || cy < 0 || cx >= n || cy >= n || INSIDE[cy * n + cx] == 0) continue;
		float w = ((k & 1) != 0 ? tx : 1.0 - tx) * ((k >> 1) != 0 ? ty : 1.0 - ty);
		cells[count] = cy * n + cx; weights[count] = w; kept += w; count++;
	}
	if (count == 0) return;
	if (kept <= 1e-9) { add_dep(uint(cells[0]), mass); return; }
	for (int k = 0; k < count; k++) add_dep(uint(cells[k]), mass * weights[k] / kept);
}
"""

## The clouds spread (as the CPU's advance_puffs): a cloud that has spread to about a cell is given to the grid, its nutrient over the cells
## it covers, and an eaten one is dropped. What goes to the grid is summed in fixed point (an exact sum whatever the order), then added.
const K_PUFF_ADVANCE := """
void main() {
	uint k = gl_GlobalInvocationID.x;
	if (k >= PCNT[PCNT_SLOTS]) return;
	uint o = k * 8u;
	if (PUFF[o + 5] < 0.5) return;
	float v = PUFF[o + 3] + P[P_CLOUD_SPREAD];
	PUFF[o + 3] = v;
	float mass = PUFF[o + 2];
	if (mass <= 1e-9) { PUFF[o + 5] = 0.0; return; }
	if (sqrt(v) >= P[P_HANDOVER]) {
		float x = PUFF[o], y = PUFF[o + 1];
		int n = int(P[P_CELLS]); float sp = P[P_SPACING]; float reach = 4.0 * sqrt(v);
		int x0 = max(0, int(floor((x - reach + P[P_ORIGIN]) / sp - 0.5))), x1 = min(n - 1, int(ceil((x + reach + P[P_ORIGIN]) / sp - 0.5)));
		int y0 = max(0, int(floor((y - reach + P[P_ORIGIN]) / sp - 0.5))), y1 = min(n - 1, int(ceil((y + reach + P[P_ORIGIN]) / sp - 0.5)));
		float sum = 0.0;
		for (int cy = y0; cy <= y1; cy++) for (int cx = x0; cx <= x1; cx++) {
			if (INSIDE[cy * n + cx] == 0) continue;
			float dx = (float(cx) + 0.5) * sp - P[P_ORIGIN] - x, dy = (float(cy) + 0.5) * sp - P[P_ORIGIN] - y;
			sum += exp(-(dx * dx + dy * dy) / (2.0 * v));
		}
		if (sum <= 1e-12) deposit_xy(x, y, mass);
		else {
			for (int cy = y0; cy <= y1; cy++) for (int cx = x0; cx <= x1; cx++) {
				if (INSIDE[cy * n + cx] == 0) continue;
				float dx = (float(cx) + 0.5) * sp - P[P_ORIGIN] - x, dy = (float(cy) + 0.5) * sp - P[P_ORIGIN] - y;
				add_dep(uint(cy * n + cx), mass * exp(-(dx * dx + dy * dy) / (2.0 * v)) / sum);
			}
		}
		PUFF[o + 5] = 0.0;
	}
}
"""

const K_DEP_APPLY := """
void main() {
	CELL_THREAD
	float m = FIX20(DPHI[i], DPLO[i]);
	if (m > 0.0) CONC[i] += m / (P[P_SPACING] * P[P_SPACING]);
	DPLO[i] = 0u; DPHI[i] = 0u;
}
"""

const K_PUFF_CLEAR := """
void main() { uint k = gl_GlobalInvocationID.x; if (k >= uint(P[P_PUFF_CAPACITY])) return; PDLO[k] = 0u; PDHI[k] = 0u; PSCALE[k] = 0.0; }
"""

## What bups wanted from each cloud, summed (exactly, in fixed point), is shared out in proportion if the cloud has less: each gets its share
## in `apply`, from the cloud as it was; then the clouds give it up.
const K_PUFF_SCALE := """
void main() {
	uint k = gl_GlobalInvocationID.x; if (k >= PCNT[PCNT_SLOTS]) return;
	float d = FIX20(PDHI[k], PDLO[k]);
	float mass = PUFF[k * 8u + 2u];
	PSCALE[k] = d > 0.0 ? min(1.0, mass / d) : 0.0;
}
"""

const K_PUFF_COMMIT := """
void main() {
	uint k = gl_GlobalInvocationID.x; if (k >= PCNT[PCNT_SLOTS]) return;
	float d = FIX20(PDHI[k], PDLO[k]);
	if (d > 0.0) PUFF[k * 8u + 2u] = max(PUFF[k * 8u + 2u] - d * PSCALE[k], 0.0);
}
"""

## The clouds filed by place, so that a read looks at one short list (the CPU's rebuild_hash): the dish is cut into squares half a cell across and
## each cloud is listed in every square its reach touches. Counted, summed, filled, and each list put in order (the order the threads ran in must
## not show in the sums of a read).
const K_BIN_CLEAR := """
void main() { uint b = gl_GlobalInvocationID.x; if (b >= uint(P[P_BINS])) return; BINC[b] = 0u; }
"""

const K_BIN_COUNT := """
void main() {
	uint k = gl_GlobalInvocationID.x; if (k >= PCNT[PCNT_SLOTS]) return;
	uint o = k * 8u;
	if (PUFF[o + 5] < 0.5) return;
	float mass = PUFF[o + 2], v = PUFF[o + 3], x = PUFF[o], y = PUFF[o + 1];
	float peak = mass / (6.2831853 * v);
	float cut = max(P[P_CLOUD_CUT] * PUFF[o + 4] * P[P_DETECTION_FLOOR], 1e-30);
	float reach = peak > cut ? sqrt(2.0 * v * log(peak / cut)) : 0.0;
	PUFF[o + 6] = reach * reach; PUFF[o + 7] = sqrt(v);
	int nb = int(P[P_BINS_ACROSS]); float bs = P[P_BIN_SIZE];
	int lx = clamp(int((x - reach + P[P_ORIGIN]) / bs), 0, nb - 1), hx = clamp(int((x + reach + P[P_ORIGIN]) / bs), 0, nb - 1);
	int ly = clamp(int((y - reach + P[P_ORIGIN]) / bs), 0, nb - 1), hy = clamp(int((y + reach + P[P_ORIGIN]) / bs), 0, nb - 1);
	for (int by = ly; by <= hy; by++) for (int bx = lx; bx <= hx; bx++) atomicAdd(BINC[by * nb + bx], 1u);
}
"""

const K_BIN_CURSOR := """
void main() { uint b = gl_GlobalInvocationID.x; if (b >= uint(P[P_BINS])) return; BCUR[b] = BINS[b]; }
"""

const K_BIN_SCATTER := """
void main() {
	uint k = gl_GlobalInvocationID.x; if (k >= PCNT[PCNT_SLOTS]) return;
	uint o = k * 8u;
	if (PUFF[o + 5] < 0.5) return;
	float x = PUFF[o], y = PUFF[o + 1], reach = sqrt(PUFF[o + 6]);
	int nb = int(P[P_BINS_ACROSS]); float bs = P[P_BIN_SIZE];
	int lx = clamp(int((x - reach + P[P_ORIGIN]) / bs), 0, nb - 1), hx = clamp(int((x + reach + P[P_ORIGIN]) / bs), 0, nb - 1);
	int ly = clamp(int((y - reach + P[P_ORIGIN]) / bs), 0, nb - 1), hy = clamp(int((y + reach + P[P_ORIGIN]) / bs), 0, nb - 1);
	for (int by = ly; by <= hy; by++) for (int bx = lx; bx <= hx; bx++) {
		uint pos = atomicAdd(BCUR[by * nb + bx], 1u);
		if (pos < uint(P[P_ENTRY_CAPACITY])) ENT[pos] = k;
		else atomicAdd(PCNT[PCNT_CUT], 1u);  // (the lists are full: this entry is cut, and counted)
	}
}
"""

const K_BIN_SORT := """
void main() {
	uint b = gl_GlobalInvocationID.x; if (b >= uint(P[P_BINS])) return;
	uint e0 = BINS[b], e1 = min(e0 + BINC[b], uint(P[P_ENTRY_CAPACITY]));
	for (uint a = e0 + 1u; a < e1; a++) {
		uint v = ENT[a]; uint j = a;
		while (j > e0 && ENT[j - 1u] > v) { ENT[j] = ENT[j - 1u]; j--; }
		ENT[j] = v;
	}
	// the clouds' records in list order, so that a read gathers nothing (the clouds do not change until the uptake is committed)
	for (uint e = e0; e < e1; e++) {
		uint k = ENT[e]; uint o = k * 8u;
		ENTD[e * 2u] = vec4(PUFF[o], PUFF[o + 1u], PUFF[o + 2u], PUFF[o + 3u]);
		ENTD[e * 2u + 1u] = vec4(PUFF[o + 6u], PUFF[o + 7u], float(k), 0.0);
	}
}
"""

## Dropping the clouds that have gone (handed to the grid or eaten): the places of those left, in order.
const K_PMARK := """
void main() { uint k = gl_GlobalInvocationID.x; if (k >= uint(P[P_PUFF_CAPACITY])) return; PAL[k] = (k < PCNT[PCNT_SLOTS] && PUFF[k * 8u + 5u] > 0.5) ? 1u : 0u; }
"""

const K_PCOMPACT := """
void main() {
	uint t = gl_GlobalInvocationID.x; uint k = t / 2u, part = t % 2u;
	if (k >= PCNT[PCNT_SLOTS]) return;
	if (PAL[k] == 1u) PUFF2_V[PEXC[k] * 2u + part] = PUFF_V[k * 2u + part];
}
"""

const K_PFINAL := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	uint n = PCNT[PCNT_SLOTS]; PCNT[PCNT_KEPT] = n > 0u ? PEXC[n - 1u] + PAL[n - 1u] : 0u; }
"""

const K_PCOPY := """
void main() { uint t = gl_GlobalInvocationID.x; if (t >= PCNT[PCNT_KEPT] * 2u) return; PUFF_V[t] = PUFF2_V[t]; }
"""

const K_PSETCOUNT := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	PCNT[PCNT_SLOTS] = PCNT[PCNT_KEPT];
}
"""

## For tests: the clouds' concentration, gradient and smallest sigma at points.
const K_PROBE := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= uint(pcs.pa)) return;
	float c, gx, gy, sg;
	puffs_at(PQ[i * 2u], PQ[i * 2u + 1u], c, gx, gy, sg);
	PR[i * 4u] = c; PR[i * 4u + 1u] = gx; PR[i * 4u + 2u] = gy; PR[i * 4u + 3u] = sg;
}
"""

## What a bup that died of starvation or chance gives back (not one the trim displaced at the limit, as the CPU's step does not for its Moran
## displacement): a cloud of P_DEATH_PUFF (death_release x cost_per_mass) per unit of its mass at its place, as the CPU's add_cloud of radius 0 does:
## a cloud of variance 100 µm² in the next free slots (slot = the number of slots in use + the number of bups that died before it, trimmed or not,
## so a trimmed one's slot is left empty, `alive` 0, until a compaction), a deposit on the grid if the grid is too fine for a cloud, the bup is in
## a rim cell (one whose centre is outside the dish: the CPU's `accepts`) or the slots are taken. After `finalize`, before `copy`: the dead bups' records are still where they were. `death_count` then takes the slots.
const K_DEATH_CLOUDS := """
void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= CNT[CNT_BUPS] || P[P_DEATH_PUFF] <= 0.0 || SURV[i] != 0u) return;
	uint b = i * RECORD_WORDS;
	uint slot = PCNT[PCNT_SLOTS] + (i - EXCS[i]);
	if (slot < uint(P[P_PUFF_CAPACITY])) { uint o = slot * 8u; PUFF[o + 5] = 0.0; }  // (empty unless this one is a cloud below)
	if (BUPS[b + R_PY] != -2.0) return;
	float mass = P[P_DEATH_PUFF] * BUPS[b + R_MASS], x = BUPS[b + R_X], y = BUPS[b + R_Y];
	int n = int(P[P_CELLS]); float sp = P[P_SPACING];
	int cx = clamp(int((x + P[P_ORIGIN]) / sp), 0, n - 1), cy = clamp(int((y + P[P_ORIGIN]) / sp), 0, n - 1);
	bool accepted = INSIDE[cy * n + cx] != 0 && x * x + y * y <= P[P_RADIUS] * P[P_RADIUS];
	if (slot < uint(P[P_PUFF_CAPACITY]) && 10.0 < P[P_HANDOVER] && accepted) {
		uint o = slot * 8u;
		PUFF[o] = x; PUFF[o + 1] = y; PUFF[o + 2] = mass; PUFF[o + 3] = 100.0; PUFF[o + 4] = 1.0;
		PUFF[o + 6] = 0.0; PUFF[o + 7] = 0.0; PUFF[o + 5] = 1.0;
	} else {
		deposit_xy(x, y, mass);
		if (slot >= uint(P[P_PUFF_CAPACITY])) atomicAdd(PCNT[PCNT_TO_GRID], 1u);
	}
}
"""

const K_DEATH_COUNT := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	if (P[P_DEATH_PUFF] <= 0.0) return;
	PCNT[PCNT_SLOTS] = min(PCNT[PCNT_SLOTS] + (CNT[CNT_BUPS] - CNT[CNT_SURVIVORS]), uint(P[P_PUFF_CAPACITY]));
}
"""


## ---- The pooled world's cloud kernels ----
## The pool's clouds are one PUFF array of every dish's: a cloud's word 5 is the float with the bits PUFF_ROW_BASE + its dish's row (0.0:
## no cloud), so `alive` stays `>= 0.5`, the row travels with the cloud through every copy and compaction, and no second array is read
## by the kernels that already read the record. (A separate PDISH array would cost 4 B a slot, a binding in every kernel that finds a cloud
## and a copy in the compaction, for the same information.) Slots are taken in the order (step, dish, rank), the dish's lone order, and a
## dish's own slot counter DS_CLOUD_SLOTS is virtual: raised by every append, and set to the dish's live clouds at its cadence, so
## whether a cloud finds room never depends on another dish. A dish's cells, bins and entries are in the pool's arrays at its own bases.
## The pool's physical cloud slots are WORLD[WD_PUFF_CAPACITY] (its list entries ENTRIES_PER_SLOT as many), its bins WORLD[WD_BINS]
## (uints: a float holds a count exactly only up to 2^24). WORLD[WD_CLOUD_SLOTS] is the physical top of PUFF. The events a step brings (EVR, EVP, EVCC, EVCA) are ordered by dish row; a cloud's
## EVP word 5 is its row word, and a cloud event whose word 4 (cut) is negative is a plankton husk (mass: its energy).
const ENTRIES_PER_SLOT := 12

const POOL_CLOUD_FUNCS := """
// the list of entries (a range of ENTD) of the square of dish d that holds a point
void bin_list(uint d, float x, float y, out uint e0, out uint e1) {
	int nb = int(DPU(d, DP_BINS_ACROSS)); float bs = DPF(d, DP_BIN_SIZE), org = DPF(d, DP_RADIUS);
	if (nb == 0) { e0 = 0u; e1 = 0u; return; }  // (a dish with no squares has no clouds)
	int bx = clamp(int((x + org) / bs), 0, nb - 1), by = clamp(int((y + org) / bs), 0, nb - 1);
	uint b = DPU(d, DP_BIN_BASE) + uint(by * nb + bx);
	e0 = BINS[b]; e1 = e0 + BINC[b];
}
// the clouds' concentration and gradient where a bup of dish d is, and the smallest sigma among the clouds that reach it
void puffs_at_d(uint d, float x, float y, out float c, out float gx, out float gy, out float sigma) {
	c = 0.0; gx = 0.0; gy = 0.0; sigma = 1e18;
	uint e0, e1; bin_list(d, x, y, e0, e1);
	for (uint e = e0; e < e1; e++) {
		vec4 r0 = ENTD[e * 2u], r1 = ENTD[e * 2u + 1u];  // x, y, mass, variance | reach^2, sigma, cloud index, 0
		float dx = x - r0.x, dy = y - r0.y, r2 = fma(dy, dy, dx * dx);
		if (r2 <= r1.x) {
			float v = r0.w;
			float ci = r0.z / (6.2831853 * v) * exp(-r2 * 0.5 / v);
			c += ci; gx -= ci * dx / v; gy -= ci * dy / v;
			sigma = min(sigma, r1.y);
		}
	}
}
"""

## Whether a point of dish d may hold a cloud, as the CPU's `accepts`: inside the dish, in a cell whose centre is inside.
const POOL_ACCEPT_FUNCS := """
bool accepts_d(uint d, float x, float y) {
	int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS);
	int cx = clamp(int((x + org) / sp), 0, n - 1), cy = clamp(int((y + org) / sp), 0, n - 1);
	return INSIDE[DPU(d, DP_FIELD_BASE) + uint(cy * n + cx)] != 0 && x * x + y * y <= org * org;
}
"""

## What puts nutrient on the pool's grid from many threads at once (the clouds that have spread to a cell, the deaths' that find no slot).
const POOL_DEP_FUNCS := POOL_ACCEPT_FUNCS + """
void add_dep(uint cell, float amount) { ADD_FIXED20(DPLO, DPHI, cell, amount) }
void deposit_xy_d(uint d, float x, float y, float mass) {
	int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS); uint base = DPU(d, DP_FIELD_BASE);
	float fx = (x + org) / sp - 0.5, fy = (y + org) / sp - 0.5;
	int x0 = int(floor(fx)), y0 = int(floor(fy));
	float tx = fx - float(x0), ty = fy - float(y0);
	int cells[4]; float weights[4]; float kept = 0.0; int count = 0;
	for (int k = 0; k < 4; k++) {
		int cx = x0 + (k & 1), cy = y0 + (k >> 1);
		if (cx < 0 || cy < 0 || cx >= n || cy >= n || INSIDE[base + uint(cy * n + cx)] == 0) continue;
		float w = ((k & 1) != 0 ? tx : 1.0 - tx) * ((k >> 1) != 0 ? ty : 1.0 - ty);
		cells[count] = cy * n + cx; weights[count] = w; kept += w; count++;
	}
	if (count == 0) return;
	if (kept <= 1e-9) { add_dep(base + uint(cells[0]), mass); return; }
	for (int k = 0; k < count; k++) add_dep(base + uint(cells[k]), mass * weights[k] / kept);
}
"""

## The events of step pcs.pa, one thread so that the slots are taken in the events' order (dish by dish). A cloud takes the next slot of the
## pool and of its dish's counter; one past its dish's quota goes onto the grid (as the single dish's past its capacity), and one that the
## pool's physical slots cannot hold goes onto the grid too and raises the overflow flag (the host sizes the slots so that it does not
## happen; when it does, the dish's run is no longer its run alone, and the flag stays). A plankton husk takes the next husk slot; past the
## dish's husk quota, or past the pool's husk slots (the overflow flag), its energy is given back at once, as the CPU's add_cloud would (a
## cloud of variance 100, or onto the grid where the dish does not accept one).
const K_POOL_EV_PUFFS := """
uint slots_g, cap_g;
// a point's nutrient onto the four cells about it (the CPU's deposit_xy), at once: one thread adds, in the events' order
void deposit_now_d(uint d, float x, float y, float mass) {
	int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS); uint base = DPU(d, DP_FIELD_BASE); float area = sp * sp;
	float fx = (x + org) / sp - 0.5, fy = (y + org) / sp - 0.5;
	int bx = int(floor(fx)), by = int(floor(fy));
	float tx = fx - float(bx), ty = fy - float(by);
	uint cells[4]; float weights[4]; float kept = 0.0; int count = 0;
	for (int k = 0; k < 4; k++) {
		int cx = bx + (k & 1), cy = by + (k >> 1);
		if (cx < 0 || cy < 0 || cx >= n || cy >= n || INSIDE[base + uint(cy * n + cx)] == 0) continue;
		float w = ((k & 1) != 0 ? tx : 1.0 - tx) * ((k >> 1) != 0 ? ty : 1.0 - ty);
		cells[count] = base + uint(cy * n + cx); weights[count] = w; kept += w; count++;
	}
	if (count == 0) return;
	if (kept <= 1e-9) { CONC[cells[0]] += mass / area; return; }
	for (int k = 0; k < count; k++) CONC[cells[k]] += mass * weights[k] / kept / area;
}
void to_grid_d(uint d, float x, float y, float mass, float v) {
	int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS); uint base = DPU(d, DP_FIELD_BASE); float area = sp * sp; float reach = 4.0 * sqrt(v);
	int x0 = max(0, int(floor((x - reach + org) / sp - 0.5))), x1 = min(n - 1, int(ceil((x + reach + org) / sp - 0.5)));
	int y0 = max(0, int(floor((y - reach + org) / sp - 0.5))), y1 = min(n - 1, int(ceil((y + reach + org) / sp - 0.5)));
	float sum = 0.0;
	for (int cy = y0; cy <= y1; cy++) for (int cx = x0; cx <= x1; cx++) {
		if (INSIDE[base + uint(cy * n + cx)] == 0) continue;
		float dx = (float(cx) + 0.5) * sp - org - x, dy = (float(cy) + 0.5) * sp - org - y;
		sum += exp(-(dx * dx + dy * dy) / (2.0 * v));
	}
	if (sum > 1e-12) {
		for (int cy = y0; cy <= y1; cy++) for (int cx = x0; cx <= x1; cx++) {
			if (INSIDE[base + uint(cy * n + cx)] == 0) continue;
			float dx = (float(cx) + 0.5) * sp - org - x, dy = (float(cy) + 0.5) * sp - org - y;
			CONC[base + uint(cy * n + cx)] += mass * exp(-(dx * dx + dy * dy) / (2.0 * v)) / sum / area;
		}
		return;
	}
	deposit_now_d(d, x, y, mass);
}
void put_cloud(uint d, float x, float y, float mass, float v, float cut) {
	uint q = DS(d, DS_CLOUD_SLOTS);
	if (q >= DPU(d, DP_CLOUD_QUOTA)) { to_grid_d(d, x, y, mass, v); DS(d, DS_CLOUDS_TO_GRID) += 1u; return; }
	if (slots_g >= cap_g) { WORLD[WD_OVERFLOW] = 1u; DS(d, DS_OVERFLOW) = 1u; to_grid_d(d, x, y, mass, v); return; }
	uint o = slots_g * 8u;
	PUFF[o] = x; PUFF[o + 1] = y; PUFF[o + 2] = mass; PUFF[o + 3] = v; PUFF[o + 4] = cut;
	PUFF[o + 5] = uintBitsToFloat(PUFF_ROW_BASE + d); PUFF[o + 6] = 0.0; PUFF[o + 7] = 0.0;
	slots_g++; DS(d, DS_CLOUD_SLOTS) = q + 1u;
}
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	int st = int(pcs.pa);
	int start = EVR[st * 4], cnt = EVR[st * 4 + 1];
	slots_g = WORLD[WD_CLOUD_SLOTS]; cap_g = WORLD[WD_PUFF_CAPACITY];
	uint husk_cap = WORLD[WD_HUSK_CAPACITY];
	for (int e = 0; e < cnt; e++) {
		uint q = uint(start + e) * EV_PUFF_FLOATS;
		uint d = floatBitsToUint(EVP[q + 5]) - PUFF_ROW_BASE;
		if (EVP[q + 4] < 0.0) {  // a plankton husk
			uint hv = DS(d, DS_HUSKS), hs = WORLD[WD_HUSK_SLOTS];
			bool quota_full = hv >= DPU(d, DP_HUSK_QUOTA);
			if (quota_full || hs >= husk_cap) {  // (as the CPU's add_cloud of radius 0: a cloud of variance 100, or onto the grid)
				if (!quota_full) { WORLD[WD_OVERFLOW] = 1u; DS(d, DS_OVERFLOW) = 1u; }
				if (accepts_d(d, EVP[q], EVP[q + 1]) && 10.0 < DPF(d, DP_HANDOVER)) put_cloud(d, EVP[q], EVP[q + 1], EVP[q + 2], 100.0, 1.0);
				else deposit_now_d(d, EVP[q], EVP[q + 1], EVP[q + 2]);
				continue;
			}
			uint o = hs * 8u;
			HUSK[o] = EVP[q]; HUSK[o + 1] = EVP[q + 1]; HUSK[o + 2] = EVP[q + 2]; HUSK[o + 3] = 0.0; HUSK[o + 4] = 0.0;
			HUSK[o + 5] = uintBitsToFloat(PUFF_ROW_BASE + d); HUSK[o + 6] = 1.0; HUSK[o + 7] = 0.0;
			WORLD[WD_HUSK_SLOTS] = hs + 1u; DS(d, DS_HUSKS) = hv + 1u;
			continue;
		}
		put_cloud(d, EVP[q], EVP[q + 1], EVP[q + 2], EVP[q + 3], EVP[q + 4]);
	}
	WORLD[WD_CLOUD_SLOTS] = slots_g;
}
"""

const K_POOL_PUFF_ADVANCE := """
void f(uint k) {
	uint o = k * 8u;
	if (PUFF[o + 5] < 0.5) return;
	uint d = floatBitsToUint(PUFF[o + 5]) - PUFF_ROW_BASE;
	float v = PUFF[o + 3] + P[P_CLOUD_SPREAD];
	PUFF[o + 3] = v;
	float mass = PUFF[o + 2];
	if (mass <= 1e-9) { PUFF[o + 5] = 0.0; return; }
	if (sqrt(v) >= DPF(d, DP_HANDOVER)) {
		float x = PUFF[o], y = PUFF[o + 1];
		int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS); uint base = DPU(d, DP_FIELD_BASE); float reach = 4.0 * sqrt(v);
		int x0 = max(0, int(floor((x - reach + org) / sp - 0.5))), x1 = min(n - 1, int(ceil((x + reach + org) / sp - 0.5)));
		int y0 = max(0, int(floor((y - reach + org) / sp - 0.5))), y1 = min(n - 1, int(ceil((y + reach + org) / sp - 0.5)));
		float sum = 0.0;
		for (int cy = y0; cy <= y1; cy++) for (int cx = x0; cx <= x1; cx++) {
			if (INSIDE[base + uint(cy * n + cx)] == 0) continue;
			float dx = (float(cx) + 0.5) * sp - org - x, dy = (float(cy) + 0.5) * sp - org - y;
			sum += exp(-(dx * dx + dy * dy) / (2.0 * v));
		}
		if (sum <= 1e-12) deposit_xy_d(d, x, y, mass);
		else {
			for (int cy = y0; cy <= y1; cy++) for (int cx = x0; cx <= x1; cx++) {
				if (INSIDE[base + uint(cy * n + cx)] == 0) continue;
				float dx = (float(cx) + 0.5) * sp - org - x, dy = (float(cy) + 0.5) * sp - org - y;
				add_dep(base + uint(cy * n + cx), mass * exp(-(dx * dx + dy * dy) / (2.0 * v)) / sum);
			}
		}
		PUFF[o + 5] = 0.0;
	}
}
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

const K_POOL_DEP_APPLY := """
void f(uint c, uint d, uint l) {
	float m = FIX20(DPHI[c], DPLO[c]);
	float sp = DPF(d, DP_SPACING);
	if (m > 0.0) CONC[c] += m / (sp * sp);
	DPLO[c] = 0u; DPHI[c] = 0u;
}
CELL_LOOP(f, WORLD[WD_CELLS])
"""

const K_POOL_PUFF_CLEAR := """
void f(uint k) { PDLO[k] = 0u; PDHI[k] = 0u; PSCALE[k] = 0.0; }
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

const K_POOL_PUFF_SCALE := """
void f(uint k) {
	float d = FIX20(PDHI[k], PDLO[k]);
	float mass = PUFF[k * 8u + 2u];
	PSCALE[k] = d > 0.0 ? min(1.0, mass / d) : 0.0;
}
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

const K_POOL_PUFF_COMMIT := """
void f(uint k) {
	float d = FIX20(PDHI[k], PDLO[k]);
	if (d > 0.0) PUFF[k * 8u + 2u] = max(PUFF[k * 8u + 2u] - d * PSCALE[k], 0.0);
}
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

const K_POOL_BIN_CLEAR := """
void f(uint b) { BINC[b] = 0u; }
GRID_LOOP(f, WORLD[WD_BINS])
"""

const K_POOL_BIN_COUNT := """
void f(uint k) {
	uint o = k * 8u;
	if (PUFF[o + 5] < 0.5) return;
	uint d = floatBitsToUint(PUFF[o + 5]) - PUFF_ROW_BASE;
	float mass = PUFF[o + 2], v = PUFF[o + 3], x = PUFF[o], y = PUFF[o + 1];
	float peak = mass / (6.2831853 * v);
	float cut = max(P[P_CLOUD_CUT] * PUFF[o + 4] * P[P_DETECTION_FLOOR], 1e-30);
	float reach = peak > cut ? sqrt(2.0 * v * log(peak / cut)) : 0.0;
	PUFF[o + 6] = reach * reach; PUFF[o + 7] = sqrt(v);
	int nb = int(DPU(d, DP_BINS_ACROSS)); float bs = DPF(d, DP_BIN_SIZE), org = DPF(d, DP_RADIUS); uint base = DPU(d, DP_BIN_BASE);
	int lx = clamp(int((x - reach + org) / bs), 0, nb - 1), hx = clamp(int((x + reach + org) / bs), 0, nb - 1);
	int ly = clamp(int((y - reach + org) / bs), 0, nb - 1), hy = clamp(int((y + reach + org) / bs), 0, nb - 1);
	for (int by = ly; by <= hy; by++) for (int bx = lx; bx <= hx; bx++) atomicAdd(BINC[base + uint(by * nb + bx)], 1u);
}
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

## After the scan of the bins' counts: each dish keeps its lists whole, bin by bin, up to its entry quota (ENTRIES_PER_SLOT a cloud slot of
## its own quota), counted from its own first entry. The bins are in order and their ends only grow, so the first bin that does not fit
## and every bin after it are cut: a thread a dish finds that first bin by bisection (none: nothing more to do) and empties the rest,
## counting the entries dropped in DS_ENTRIES_CUT. A bin whose count is zeroed gets no entries in the scatter and reads as empty. Then the
## counts are scanned again (`pool_bn`), so a dish's entries start where the cut lists of the dishes before it end, and `pool_bin_room`
## cuts, the same way, the bins whose end passes the pool's physical entries (nothing is written out of bounds) and raises the overflow
## flag. Without an overflow a dish's lists are its own alone: neither the cut nor the room depends on another dish's clouds. With one,
## the flag stays (the host cannot do the iteration again: the clouds change in place).
const BIN_CUT_FUNCS := """
// the first of the dish's nbins bins (from base) whose end passes `limit` (counted from `from`), nbins when none does
uint first_past(uint base, uint nbins, uint from, uint limit) {
	uint last = base + nbins - 1u;
	if (BINS[last] + BINC[last] - from <= limit) return nbins;
	uint lo = 0u, hi = nbins - 1u;
	while (lo < hi) {
		uint mid = (lo + hi) >> 1u;
		if (BINS[base + mid] + BINC[base + mid] - from > limit) hi = mid; else lo = mid + 1u;
	}
	return lo;
}
// empties the dish's bins from the first whose end passes `limit` (counted from `from`, or from its first entry when `own`); the entries dropped
uint cut_from(uint d, bool own, uint limit) {
	if (((DPU(d, DP_FLAGS) >> DPF_RUNNING) & 1u) == 0u) return 0u;
	uint base = DPU(d, DP_BIN_BASE), nbins = DPU(d, DP_BINS_ACROSS) * DPU(d, DP_BINS_ACROSS);
	if (nbins == 0u) return 0u;
	uint cut = first_past(base, nbins, own ? BINS[base] : 0u, limit);
	uint dropped = 0u;
	for (uint b = base + cut; b < base + nbins; b++) { dropped += BINC[b]; BINC[b] = 0u; }
	return dropped;
}
"""

const K_POOL_BIN_CUT := """
void f(uint d) { DS(d, DS_ENTRIES_CUT) += cut_from(d, true, ENTRIES_PER_SLOT * DPU(d, DP_CLOUD_QUOTA)); }
GRID_LOOP(f, D_MAX)
"""

const K_POOL_BIN_ROOM := """
void f(uint d) {
	if (cut_from(d, false, ENTRIES_PER_SLOT * WORLD[WD_PUFF_CAPACITY]) > 0u) { WORLD[WD_OVERFLOW] = 1u; DS(d, DS_OVERFLOW) = 1u; }
}
GRID_LOOP(f, D_MAX)
"""

const K_POOL_BIN_CURSOR := """
void f(uint b) { BCUR[b] = BINS[b]; }
GRID_LOOP(f, WORLD[WD_BINS])
"""

const K_POOL_BIN_SCATTER := """
void f(uint k) {
	uint o = k * 8u;
	if (PUFF[o + 5] < 0.5) return;
	uint d = floatBitsToUint(PUFF[o + 5]) - PUFF_ROW_BASE;
	float x = PUFF[o], y = PUFF[o + 1], reach = sqrt(PUFF[o + 6]);
	int nb = int(DPU(d, DP_BINS_ACROSS)); float bs = DPF(d, DP_BIN_SIZE), org = DPF(d, DP_RADIUS); uint base = DPU(d, DP_BIN_BASE);
	int lx = clamp(int((x - reach + org) / bs), 0, nb - 1), hx = clamp(int((x + reach + org) / bs), 0, nb - 1);
	int ly = clamp(int((y - reach + org) / bs), 0, nb - 1), hy = clamp(int((y + reach + org) / bs), 0, nb - 1);
	for (int by = ly; by <= hy; by++) for (int bx = lx; bx <= hx; bx++) {
		uint b = base + uint(by * nb + bx);
		uint pos = atomicAdd(BCUR[b], 1u);
		if (pos < BINS[b] + BINC[b]) ENT[pos] = k;  // (a cut bin has a count of 0: no entry)
	}
}
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

const K_POOL_BIN_SORT := """
void f(uint b) {
	uint e0 = BINS[b], e1 = e0 + BINC[b];
	for (uint a = e0 + 1u; a < e1; a++) {
		uint v = ENT[a]; uint j = a;
		while (j > e0 && ENT[j - 1u] > v) { ENT[j] = ENT[j - 1u]; j--; }
		ENT[j] = v;
	}
	for (uint e = e0; e < e1; e++) {
		uint k = ENT[e]; uint o = k * 8u;
		ENTD[e * 2u] = vec4(PUFF[o], PUFF[o + 1u], PUFF[o + 2u], PUFF[o + 3u]);
		ENTD[e * 2u + 1u] = vec4(PUFF[o + 6u], PUFF[o + 7u], float(k), 0.0);
	}
}
GRID_LOOP(f, WORLD[WD_BINS])
"""

## The compaction of the pool's clouds, a stable one (every dish's order is kept): mark, scan (pf), copy the kept to PUFF2, copy back, set
## the top. The host runs it every 16 world steps. Every step, after the deaths' clouds and the husks' pieces and before the dishes' steps
## are counted (`pool_setcount`), `pool_cloud_live` (and `pool_husk_live`, kernels_husks.gd) count in CLIVE (zero between steps: a dish's
## clouds at CLIVE[row], its husks at CLIVE[D_MAX + row]) the live clouds and husks of each dish whose own step is at its cadence
## (DS_STEP % 16 == 15: the single dish's compaction after its step 15, 31, ... counted from its load), and `pool_cloud_cadence` makes
## them the dish's virtual counters DS_CLOUD_SLOTS and DS_HUSKS. So when a compaction or a cull frees the pool's slots never changes
## what a dish does.
const K_POOL_PMARK := """
void f(uint k) { PAL[k] = PUFF[k * 8u + 5u] > 0.5 ? 1u : 0u; }
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

const K_POOL_PCOMPACT := """
void f(uint t) {
	uint k = t / 2u, part = t % 2u;
	if (PAL[k] == 1u) PUFF2_V[PEXC[k] * 2u + part] = PUFF_V[k * 2u + part];
}
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS] * 2u)
"""

const K_POOL_PCOPY := """
void f(uint t) { PUFF_V[t] = PUFF2_V[t]; }
GRID_LOOP(f, kept_pieces())
"""

const K_POOL_PSETCOUNT := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	uint n = WORLD[WD_CLOUD_SLOTS];
	WORLD[WD_CLOUD_SLOTS] = n > 0u ? PEXC[n - 1u] + PAL[n - 1u] : 0u;
}
"""

const K_POOL_CLOUD_LIVE := """
void f(uint k) {
	if (PUFF[k * 8u + 5u] < 0.5) return;
	uint d = floatBitsToUint(PUFF[k * 8u + 5u]) - PUFF_ROW_BASE;
	if (DS(d, DS_STEP) % 16u == 15u) atomicAdd(CLIVE[d], 1u);
}
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

## A thread a dish row (D_MAX of them, most not running).
const K_POOL_CLOUD_CADENCE := """
void f(uint d) {
	if (((DPU(d, DP_FLAGS) >> DPF_RUNNING) & 1u) == 0u) return;
	if (DS(d, DS_STEP) % 16u == 15u) { DS(d, DS_CLOUD_SLOTS) = CLIVE[d]; DS(d, DS_HUSKS) = CLIVE[D_MAX + d]; CLIVE[d] = 0u; CLIVE[D_MAX + d] = 0u; }
}
GRID_LOOP(f, D_MAX)
"""

const K_POOL_PROBE := """
void f(uint i) {
	float c, gx, gy, sg;
	puffs_at_d(uint(pcs.pb), PQ[i * 2u], PQ[i * 2u + 1u], c, gx, gy, sg);
	PR[i * 4u] = c; PR[i * 4u + 1u] = gx; PR[i * 4u + 2u] = gy; PR[i * 4u + 3u] = sg;
}
GRID_LOOP(f, uint(pcs.pa))
"""

## The chance of steering up a slope (params.h `steering_chance`), for dish `d` (its receptor-noise scale is its own): from the motion table
## (LOOKUP_FUNCS must come with it, and the buffers P and TABLE). `window` is the steering window in seconds, which is a constant of
## SimConstants and no slot of P: the caller passes it. erf by the Chebyshev fit of Numerical Recipes' erfc (fractional error under 1.2e-7).
const POOL_STEER_FUNCS := """
float erfc_fit(float x) {
	float z = abs(x), t = 1.0 / (1.0 + 0.5 * z);
	float r = t * exp(-z * z - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))));
	return x >= 0.0 ? r : 2.0 - r;
}
float steering_chance_d(uint d, float speed, float sense_range, float c, float gradient, float window) {
	float s = speed * gradient / (P[P_DETECTION_FLOOR] + c);
	float eps = min(P[P_GRADIENT_NOISE] * (P[P_REFERENCE_SENSE] / sense_range) * sqrt(DPF(d, DP_NOISE_REFERENCE) / max(c, 1e-5)), 5.0);
	float f, along, across;
	lookup(s, eps, f, along, across);
	float z = f * sqrt(window / (2.0 * max(along, 1e-6)));
	return 0.5 * erfc_fit(-z * 0.70710678);
}
"""

## The full point answer of dish row `pcs.pb` for `pcs.pa` queries (SPQ: x, y, speed, sense range; SPR, PROBE_FLOATS a point: the unit
## direction up the gradient, the chance of steering up it, the concentration, the gradient's size; `pcs.pc` the steering window):
## The steering readout and the hover card's nutrient, from the grid snapshot and the clouds as the single dish reads them. No gradient
## (1e-12 or less) gives (0, 0, 0.5).
const K_POOL_PROBE_FULL := """
void f(uint i) {
	uint d = uint(pcs.pb);
	float x = SPQ[i * 4u], y = SPQ[i * 4u + 1u], speed = SPQ[i * 4u + 2u], sense_range = SPQ[i * 4u + 3u];
	float c, gx, gy, pc, pgx, pgy, sg;
	readf_d(d, x, y, c, gx, gy);
	puffs_at_d(d, x, y, pc, pgx, pgy, sg);
	c += pc; gx += pgx; gy += pgy;
	float glen = sqrt(gx * gx + gy * gy);
	vec3 answer = vec3(0.0, 0.0, 0.5);
	if (glen > 1e-12) answer = vec3(gx / glen, gy / glen, steering_chance_d(d, speed, sense_range, c, glen, pcs.pc));
	uint o = i * PROBE_FLOATS;
	SPR[o] = answer.x; SPR[o + 1u] = answer.y; SPR[o + 2u] = answer.z; SPR[o + 3u] = c; SPR[o + 4u] = glen;
}
GRID_LOOP(f, uint(pcs.pa))
"""

## What a death gives back (the single dish's death_clouds, per dish). The dishes' death slots follow the step's other appends in the dish
## order: `pool_death_bases` (one thread over the rows) gives each dish the first of the deaths' slots, in CBASE (the clouds') and CBASE
## from D_MAX + 1 (the husks'). A dish with death husks makes husks of its first deaths up to the room its quota leaves (`husk_room`) and
## clouds of the rest; a dish without gives every death back as a cloud. A death's rank is its place among its dish's deaths, trimmed ones
## counted (a trimmed one's slot stays empty, as the single dish's).
const DEATH_FUNCS := """
uint deaths_of(uint d) { return DS(d, DS_COUNT) - DS(d, DS_SURVIVORS); }
uint husk_room(uint d) {
	if (((DPU(d, DP_FLAGS) >> DPF_DEATH_HUSKS) & 1u) == 0u) return 0u;
	uint hv = DS(d, DS_HUSKS), q = DPU(d, DP_HUSK_QUOTA);
	return hv < q ? min(q - hv, deaths_of(d)) : 0u;
}
"""

## One group of 256 threads, four dish rows a thread: each row's clouds and husks, an exclusive scan of them in shared memory (integers,
## so the bases do not depend on the order the threads run in).
const K_POOL_DEATH_BASES := """
shared uint cs[256];
shared uint hs[256];
void main() {
	if (gl_WorkGroupID.x != 0u) return;
	uint t = gl_LocalInvocationID.x;
	uint c4[4], h4[4], csum = 0u, hsum = 0u;
	for (uint j = 0u; j < 4u; j++) {
		uint d = t * 4u + j, c = 0u, h = 0u;
		if (((DPU(d, DP_FLAGS) >> DPF_RUNNING) & 1u) != 0u) {
			h = husk_room(d);
			if (P[P_DEATH_GIVE] > 0.0) c = deaths_of(d) - h;
		}
		c4[j] = c; h4[j] = h; csum += c; hsum += h;
	}
	cs[t] = csum; hs[t] = hsum;
	barrier();
	for (uint off = 1u; off < 256u; off <<= 1u) {
		uint a = t >= off ? cs[t - off] : 0u, b = t >= off ? hs[t - off] : 0u;
		barrier();
		cs[t] += a; hs[t] += b;
		barrier();
	}
	uint cloud_at = cs[t] - csum, husk_at = hs[t] - hsum;
	for (uint j = 0u; j < 4u; j++) {
		uint d = t * 4u + j;
		CBASE[d] = cloud_at; CBASE[D_MAX + 1u + d] = husk_at;
		cloud_at += c4[j]; husk_at += h4[j];
	}
	if (t == 255u) { CBASE[D_MAX] = cs[255]; CBASE[2u * D_MAX + 1u] = hs[255]; }
}
"""

const K_POOL_DEATH_CLOUDS := """
void f(uint i, uint d, uint l) {
	if (SURV[i] != 0u || P[P_DEATH_GIVE] <= 0.0) return;
	uint rank = l - (EXCS[i] - EXCS[DS(d, DS_START)]);
	uint room = husk_room(d);
	if (rank < room) return;
	uint cr = rank - room;
	uint b = i * RECORD_WORDS;
	uint quota = DPU(d, DP_CLOUD_QUOTA);
	uint vslot = DS(d, DS_CLOUD_SLOTS) + cr;
	uint pslot = WORLD[WD_CLOUD_SLOTS] + CBASE[d] + cr;
	bool phys = pslot < WORLD[WD_PUFF_CAPACITY];
	if (phys) PUFF[pslot * 8u + 5u] = 0.0;  // (empty unless this one is a cloud below)
	if (BUPS[b + R_PY] != -2.0) return;
	float mass = P[P_DEATH_GIVE] * BUPS[b + R_MASS], x = BUPS[b + R_X], y = BUPS[b + R_Y];
	if (vslot < quota && phys && 10.0 < DPF(d, DP_HANDOVER) && accepts_d(d, x, y)) {
		uint o = pslot * 8u;
		PUFF[o] = x; PUFF[o + 1] = y; PUFF[o + 2] = mass; PUFF[o + 3] = 100.0; PUFF[o + 4] = 1.0;
		PUFF[o + 6] = 0.0; PUFF[o + 7] = 0.0; PUFF[o + 5] = uintBitsToFloat(PUFF_ROW_BASE + d);
	} else {
		deposit_xy_d(d, x, y, mass);
		if (vslot >= quota) atomicAdd(DS(d, DS_CLOUDS_TO_GRID), 1u);
		if (!phys) { WORLD[WD_OVERFLOW] = 1u; DS(d, DS_OVERFLOW) = 1u; }
	}
}
BUP_LOOP(f)
"""

## After the deaths' clouds and husks: the dishes' counters take them in, and the pool's tops (never past the physical slots: a death
## whose slot lay past them raised the overflow flag and went onto the grid).
const K_POOL_DEATH_COUNT := """
void f(uint d) {
	bool give = P[P_DEATH_GIVE] > 0.0;
	if (d == 0u) {
		if (give) WORLD[WD_CLOUD_SLOTS] = min(WORLD[WD_CLOUD_SLOTS] + CBASE[D_MAX], WORLD[WD_PUFF_CAPACITY]);
		WORLD[WD_HUSK_SLOTS] = min(WORLD[WD_HUSK_SLOTS] + CBASE[2u * D_MAX + 1u], WORLD[WD_HUSK_CAPACITY]);
	}
	if (((DPU(d, DP_FLAGS) >> DPF_RUNNING) & 1u) == 0u) return;
	uint room = husk_room(d);
	if (give) DS(d, DS_CLOUD_SLOTS) = min(DS(d, DS_CLOUD_SLOTS) + deaths_of(d) - room, DPU(d, DP_CLOUD_QUOTA));
	DS(d, DS_HUSKS) += room;
}
GRID_LOOP(f, D_MAX)
"""

static func _register_pool(out: Dictionary) -> void:
	var types := {"CBASE": "uint", "CLIVE": "uint", "HUSK": "float"}
	var fixed := GpuKernels.FIXED_FUNCS
	var world := ["WORLD", "DSTATE", "DISHP"]
	var cells := ["WORLD", "CELLDISH", "DISHP"]
	GpuKernels.add(out, "pool_ev_puffs", K_POOL_EV_PUFFS, world + ["PUFF", "EVR", "EVP", "CONC", "INSIDE", "HUSK"], POOL_ACCEPT_FUNCS, 64, types)
	GpuKernels.add(out, "pool_puff_advance", K_POOL_PUFF_ADVANCE, ["P", "WORLD", "DISHP", "PUFF", "INSIDE", "DPLO", "DPHI"], fixed + POOL_DEP_FUNCS)
	GpuKernels.add(out, "pool_dep_apply", K_POOL_DEP_APPLY, cells + ["CONC", "DPLO", "DPHI"], fixed)
	GpuKernels.add(out, "pool_puff_clear", K_POOL_PUFF_CLEAR, ["WORLD", "PDLO", "PDHI", "PSCALE"])
	GpuKernels.add(out, "pool_puff_scale", K_POOL_PUFF_SCALE, ["WORLD", "PUFF", "PDLO", "PDHI", "PSCALE"], fixed)
	GpuKernels.add(out, "pool_puff_commit", K_POOL_PUFF_COMMIT, ["WORLD", "PUFF", "PDLO", "PDHI", "PSCALE"], fixed)
	GpuKernels.add(out, "pool_bin_clear", K_POOL_BIN_CLEAR, ["WORLD", "BINC"])
	GpuKernels.add(out, "pool_bin_count", K_POOL_BIN_COUNT, ["P", "WORLD", "DISHP", "PUFF", "BINC"])
	GpuKernels.add_grid_scan(out, "pool_bn", "BINC", "BINS", "BSUM", "BOFF", "WORLD[WD_BINS]", ["WORLD"])
	var cut := "const uint ENTRIES_PER_SLOT = %du;\n" % ENTRIES_PER_SLOT + BIN_CUT_FUNCS
	GpuKernels.add(out, "pool_bin_cut", K_POOL_BIN_CUT, ["WORLD", "DSTATE", "DISHP", "BINS", "BINC"], cut)
	GpuKernels.add(out, "pool_bin_room", K_POOL_BIN_ROOM, ["WORLD", "DSTATE", "DISHP", "BINS", "BINC"], cut)
	GpuKernels.add(out, "pool_bin_cursor", K_POOL_BIN_CURSOR, ["WORLD", "BINS", "BCUR"])
	GpuKernels.add(out, "pool_bin_scatter", K_POOL_BIN_SCATTER, ["WORLD", "DISHP", "PUFF", "BINS", "BINC", "BCUR", "ENT"])
	GpuKernels.add(out, "pool_bin_sort", K_POOL_BIN_SORT, ["WORLD", "PUFF", "BINS", "BINC", "ENT", "ENTD"])
	GpuKernels.add(out, "pool_pmark", K_POOL_PMARK, ["WORLD", "PUFF", "PAL"])
	GpuKernels.add_grid_scan(out, "pool_pf", "PAL", "PEXC", "PSUM", "POFF", "WORLD[WD_CLOUD_SLOTS]", ["WORLD"])
	GpuKernels.add(out, "pool_pcompact", K_POOL_PCOMPACT, ["WORLD", "PAL", "PEXC", "PUFF_V", "PUFF2_V"])
	GpuKernels.add(out, "pool_pcopy", K_POOL_PCOPY.replace("kept_pieces()", "(WORLD[WD_CLOUD_SLOTS] > 0u ? (PEXC[WORLD[WD_CLOUD_SLOTS] - 1u] + PAL[WORLD[WD_CLOUD_SLOTS] - 1u]) * 2u : 0u)"), ["WORLD", "PAL", "PEXC", "PUFF_V", "PUFF2_V"])
	GpuKernels.add(out, "pool_psetcount", K_POOL_PSETCOUNT, ["WORLD", "PAL", "PEXC"])
	GpuKernels.add(out, "pool_cloud_live", K_POOL_CLOUD_LIVE, ["WORLD", "DSTATE", "PUFF", "CLIVE"], "", 64, types)
	GpuKernels.add(out, "pool_cloud_cadence", K_POOL_CLOUD_CADENCE, ["DSTATE", "DISHP", "CLIVE"], "", 64, types)
	GpuKernels.add(out, "pool_probe", K_POOL_PROBE, ["DISHP", "ENTD", "BINS", "BINC", "PQ", "PR"], POOL_CLOUD_FUNCS)
	GpuKernels.add(out, "pool_probe_full", K_POOL_PROBE_FULL, ["P", "TABLE", "DISHP", "EFF", "ENTD", "BINS", "BINC", "SPQ", "SPR"],
		GpuKernelsField.POOL_READF + GpuKernelsField.LOOKUP_FUNCS + POOL_CLOUD_FUNCS + POOL_STEER_FUNCS, 64, {"SPQ": "float", "SPR": "float"})
	assert(GpuLayout.D_MAX == 1024, "pool_death_bases takes four rows a thread of one group of 256")
	GpuKernels.add(out, "pool_death_bases", K_POOL_DEATH_BASES, ["P", "DSTATE", "DISHP", "CBASE"], DEATH_FUNCS, 256, types)
	GpuKernels.add(out, "pool_death_clouds", K_POOL_DEATH_CLOUDS, ["P", "WORLD", "BLKDISH", "DSTATE", "DISHP", "BUPS", "SURV", "EXCS", "PUFF", "INSIDE", "DPLO", "DPHI", "CBASE"], fixed + POOL_DEP_FUNCS + DEATH_FUNCS, 64, types)
	GpuKernels.add(out, "pool_death_count", K_POOL_DEATH_COUNT, ["P", "WORLD", "DSTATE", "DISHP", "CBASE"], DEATH_FUNCS, 64, types)


## Adds these kernels to `out` (see GpuKernels.all()).
static func register(out: Dictionary) -> void:
	GpuKernels.add(out, "ev_puffs", K_EV_PUFFS, ["P", "PCNT", "PUFF", "EVR", "EVP", "CONC", "INSIDE"])
	GpuKernels.add(out, "ev_deposits", K_EV_DEPOSITS, ["P", "CONC", "EVR", "EVCC", "EVCA"])
	GpuKernels.add(out, "puff_advance", K_PUFF_ADVANCE, ["P", "PCNT", "PUFF", "INSIDE", "DPLO", "DPHI"], GpuKernels.FIXED_FUNCS + DEP_FUNCS)
	GpuKernels.add(out, "dep_apply", K_DEP_APPLY, ["P", "CONC", "DPLO", "DPHI"], GpuKernels.FIXED_FUNCS)
	GpuKernels.add(out, "puff_clear", K_PUFF_CLEAR, ["P", "PDLO", "PDHI", "PSCALE"])
	GpuKernels.add(out, "puff_scale", K_PUFF_SCALE, ["PCNT", "PUFF", "PDLO", "PDHI", "PSCALE"], GpuKernels.FIXED_FUNCS)
	GpuKernels.add(out, "puff_commit", K_PUFF_COMMIT, ["PCNT", "PUFF", "PDLO", "PDHI", "PSCALE"], GpuKernels.FIXED_FUNCS)
	GpuKernels.add(out, "bin_clear", K_BIN_CLEAR, ["P", "BINC"])
	GpuKernels.add(out, "bin_count", K_BIN_COUNT, ["P", "PCNT", "PUFF", "BINC"])
	GpuKernels.add(out, "bin_cursor", K_BIN_CURSOR, ["P", "BINS", "BCUR"])
	GpuKernels.add(out, "bin_scatter", K_BIN_SCATTER, ["P", "PCNT", "PUFF", "BCUR", "ENT"])
	GpuKernels.add(out, "bin_sort", K_BIN_SORT, ["P", "PUFF", "BINS", "BINC", "ENT", "ENTD"])
	GpuKernels.add_scan_chain(out, "bn", "BINC", "BINS", "BS1", "BS1X", "BS2", "BS2X", "BS3")
	GpuKernels.add(out, "pmark", K_PMARK, ["P", "PCNT", "PUFF", "PAL"])
	GpuKernels.add_scan_chain(out, "pf", "PAL", "PEXC", "PS1", "PS1X", "PS2", "PS2X", "PS3")
	GpuKernels.add(out, "pcompact", K_PCOMPACT, ["PCNT", "PAL", "PEXC", "PUFF_V", "PUFF2_V"])
	GpuKernels.add(out, "pfinal", K_PFINAL, ["PCNT", "PAL", "PEXC"])
	GpuKernels.add(out, "pcopy", K_PCOPY, ["PCNT", "PUFF_V", "PUFF2_V"])
	GpuKernels.add(out, "psetcount", K_PSETCOUNT, ["PCNT"])
	GpuKernels.add(out, "probe", K_PROBE, ["P", "ENTD", "BINS", "BINC", "PQ", "PR"], CLOUD_FUNCS)
	GpuKernels.add(out, "death_clouds", K_DEATH_CLOUDS, ["P", "CNT", "PCNT", "BUPS", "SURV", "EXCS", "PUFF", "INSIDE", "DPLO", "DPHI"], GpuKernels.FIXED_FUNCS + DEP_FUNCS)
	GpuKernels.add(out, "death_count", K_DEATH_COUNT, ["P", "CNT", "PCNT"])
	_register_pool(out)
