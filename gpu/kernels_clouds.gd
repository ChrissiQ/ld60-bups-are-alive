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

## New clouds and deposits come from the CPU (plankton bursts, sources: see NutrientField.set_recording) as events with the step they belong to.
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
