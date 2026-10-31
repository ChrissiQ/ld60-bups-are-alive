class_name GpuKernelsHusks
extends RefCounted
## The pooled world's husks (the CPU's are native/src/bup_husks.cpp): what a death leaves with the dish's death husks on,
## and what a plankton leaves with plankton husks on, and their slow leak. A husk is 8 floats in HUSK (every dish's together): x, y, the
## nutrient it holds, its age, the pieces already let go, the dish's row word (PUFF_ROW_BASE + row, as a cloud's), alive (1.0 or 0.0), 0.
## WORLD[WD_HUSK_SLOTS] is the physical top; a dish's own count is DS_HUSKS, which the dish's husk quota (DP_HUSK_QUOTA) bounds.
## The spawn of a plankton husk is in `pool_ev_puffs` (kernels_clouds.gd), the husks of deaths in `pool_husk_spawn` below. The leak makes
## the dish's clouds, in slots the step reserves after the deaths': `pool_husk_age` finds how many pieces each husk lets go, the scan `hl`
## orders them, `pool_husk_leak` writes them. A piece is a cloud of variance 100 and cut 1 where the husk is (a deposit on the grid when the
## dish hands over below that width); it raises its dish's cloud counter but is not held back by the cloud quota, as the husk quota already
## bounds what leaks. The cull (mark, scan `hc`, copy, copy back, count) runs at a cadence the host sets.
##
## Buffers of this file's own, which the host allocates (kernels_clouds.gd names CBASE and CLIVE): HUSK and HUSK2 (floats, 8 a husk), HDUE
## (the pieces due now, a husk's), HEXC (their exclusive scan), HAL (alive marks), HKEEP (kept before a husk), HSUM and HOFF (scan scratch).
## The husk slots' number is a physical capacity the host gives (HUSK's length / 8).

const HUSK_PIECES := 12

const HUSK_FUNCS := """
const float HUSK_SECONDS = %s;
const int HUSK_PIECES = %d;
float husk_share(int k) {
	float share = exp(-0.25 * float(k)) - exp(-0.25 * float(k + 1));
	return k == HUSK_PIECES - 1 ? share + exp(-0.25 * float(HUSK_PIECES)) : share;
}
"""

const K_AGE := """
void f(uint k) {
	uint o = k * 8u;
	HDUE[k] = 0u;
	if (HUSK[o + 6u] < 0.5) return;
	float quarter = HUSK_SECONDS / 4.0;
	float age = HUSK[o + 3u] + P[P_DELTA];
	int n = int(HUSK[o + 4u]), was = n;
	while (n < HUSK_PIECES && age >= (float(n) + 0.5) * quarter) n++;
	HUSK[o + 3u] = age; HUSK[o + 4u] = float(n);
	HDUE[k] = uint(n - was);
}
GRID_LOOP(f, WORLD[WD_HUSK_SLOTS])
"""

const K_LEAK := """
void f(uint k) {
	uint due = HDUE[k];
	if (due == 0u) return;
	uint o = k * 8u;
	uint d = floatBitsToUint(HUSK[o + 5u]) - PUFF_ROW_BASE;
	int first = int(HUSK[o + 4u]) - int(due);
	float x = HUSK[o], y = HUSK[o + 1u], energy = HUSK[o + 2u];
	uint at = WORLD[WD_CLOUD_SLOTS] + HEXC[k];
	atomicAdd(DS(d, DS_CLOUD_SLOTS), due);
	for (uint j = 0u; j < due; j++) {
		float mass = energy * husk_share(first + int(j));
		uint slot = at + j;
		if (slot >= uint(P[P_PUFF_CAPACITY])) { WORLD[WD_OVERFLOW] = 1u; DS(d, DS_OVERFLOW) = 1u; deposit_xy_d(d, x, y, mass); continue; }
		uint q = slot * 8u;
		if (10.0 < DPF(d, DP_HANDOVER)) {
			PUFF[q] = x; PUFF[q + 1u] = y; PUFF[q + 2u] = mass; PUFF[q + 3u] = 100.0; PUFF[q + 4u] = 1.0;
			PUFF[q + 5u] = uintBitsToFloat(PUFF_ROW_BASE + d); PUFF[q + 6u] = 0.0; PUFF[q + 7u] = 0.0;
		} else {
			PUFF[q + 5u] = 0.0;
			deposit_xy_d(d, x, y, mass);
		}
	}
}
GRID_LOOP(f, WORLD[WD_HUSK_SLOTS])
"""

const K_LEAK_COUNT := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	uint n = WORLD[WD_HUSK_SLOTS];
	if (n > 0u) WORLD[WD_CLOUD_SLOTS] += HEXC[n - 1u] + HDUE[n - 1u];
}
"""

## The husks of this step's deaths: a dish's first `husk_room` deaths (by rank, as in `pool_death_clouds`) take the slots its base gives. A
## trimmed bup (its record's y is not -2) and a death with no energy left leave an empty slot.
const K_SPAWN := """
void f(uint i, uint d, uint l) {
	if (SURV[i] != 0u) return;
	uint rank = l - (EXCS[i] - EXCS[DS(d, DS_START)]);
	if (rank >= husk_room(d)) return;
	uint slot = WORLD[WD_HUSK_SLOTS] + CBASE[D_MAX + 1u + d] + rank;
	if (slot >= uint(HUSK.length()) / 8u) { WORLD[WD_OVERFLOW] = 1u; DS(d, DS_OVERFLOW) = 1u; return; }
	uint b = i * RECORD_WORDS, o = slot * 8u;
	float energy = BUPS[b + R_ENERGY];
	bool real = BUPS[b + R_PY] == -2.0 && energy > 0.0;
	HUSK[o] = BUPS[b + R_X]; HUSK[o + 1u] = BUPS[b + R_Y]; HUSK[o + 2u] = energy; HUSK[o + 3u] = 0.0; HUSK[o + 4u] = 0.0;
	HUSK[o + 5u] = uintBitsToFloat(PUFF_ROW_BASE + d); HUSK[o + 6u] = real ? 1.0 : 0.0; HUSK[o + 7u] = 0.0;
}
BUP_LOOP(f)
"""

## The cull: a husk that has let its last piece go (next = HUSK_PIECES), or never held one, leaves. Stable, so the husks keep their order.
const K_MARK := """
void f(uint k) {
	uint o = k * 8u;
	bool live = HUSK[o + 6u] > 0.5 && int(HUSK[o + 4u]) < HUSK_PIECES;
	HAL[k] = live ? 1u : 0u;
	if (!live) HUSK[o + 6u] = 0.0;
}
GRID_LOOP(f, WORLD[WD_HUSK_SLOTS])
"""

const K_COMPACT := """
void f(uint k) {
	if (HAL[k] == 0u) return;
	uint o = k * 8u, q = HKEEP[k] * 8u;
	for (uint w = 0u; w < 8u; w++) HUSK2[q + w] = HUSK[o + w];
}
GRID_LOOP(f, WORLD[WD_HUSK_SLOTS])
"""

const K_COPY := """
void f(uint t) { HUSK[t] = HUSK2[t]; }
GRID_LOOP(f, kept_count() * 8u)
"""

## The new top, and the dishes' counts as they stand after it: zeroed, then summed by the husks themselves.
const K_SET_COUNT := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;
	uint n = WORLD[WD_HUSK_SLOTS];
	WORLD[WD_HUSK_SLOTS] = n > 0u ? HKEEP[n - 1u] + HAL[n - 1u] : 0u;
	for (uint d = 0u; d < D_MAX; d++) DS(d, DS_HUSKS) = 0u;
}
"""

const K_RECOUNT := """
void f(uint k) {
	if (HUSK[k * 8u + 6u] < 0.5) return;
	atomicAdd(DS(floatBitsToUint(HUSK[k * 8u + 5u]) - PUFF_ROW_BASE, DS_HUSKS), 1u);
}
GRID_LOOP(f, WORLD[WD_HUSK_SLOTS])
"""


static func register(out: Dictionary) -> void:
	var types := {"HUSK": "float", "HUSK2": "float", "HDUE": "uint", "HEXC": "uint", "HAL": "uint", "HKEEP": "uint", "CBASE": "uint"}
	var funcs: String = HUSK_FUNCS % [str(Biology.HUSK_SECONDS), HUSK_PIECES]
	var fixed := GpuKernels.FIXED_FUNCS
	var dep := GpuKernelsClouds.POOL_DEP_FUNCS
	var world := ["P", "WORLD", "DSTATE", "DISHP"]
	GpuKernels.add(out, "pool_husk_age", K_AGE, ["P", "WORLD", "HUSK", "HDUE"], funcs, 64, types)
	GpuKernels.add_grid_scan(out, "pool_hl", "HDUE", "HEXC", "HSUM", "HOFF", "WORLD[WD_HUSK_SLOTS]", ["WORLD"])
	GpuKernels.add(out, "pool_husk_leak", K_LEAK, world + ["HUSK", "HDUE", "HEXC", "PUFF", "INSIDE", "DPLO", "DPHI"], funcs + fixed + dep, 64, types)
	GpuKernels.add(out, "pool_husk_leak_count", K_LEAK_COUNT, ["WORLD", "HDUE", "HEXC"], "", 64, types)
	GpuKernels.add(out, "pool_husk_spawn", K_SPAWN, world + ["BLKDISH", "BUPS", "SURV", "EXCS", "HUSK", "CBASE"], GpuKernelsClouds.DEATH_FUNCS, 64, types)
	GpuKernels.add(out, "pool_husk_mark", K_MARK, ["P", "WORLD", "HUSK", "HAL"], funcs, 64, types)
	GpuKernels.add_grid_scan(out, "pool_hc", "HAL", "HKEEP", "HSUM", "HOFF", "WORLD[WD_HUSK_SLOTS]", ["WORLD"])
	GpuKernels.add(out, "pool_husk_compact", K_COMPACT, ["WORLD", "HUSK", "HUSK2", "HAL", "HKEEP"], "", 64, types)
	GpuKernels.add(out, "pool_husk_copy", K_COPY.replace("kept_count()", "(WORLD[WD_HUSK_SLOTS] > 0u ? HKEEP[WORLD[WD_HUSK_SLOTS] - 1u] + HAL[WORLD[WD_HUSK_SLOTS] - 1u] : 0u)"), ["WORLD", "HUSK", "HUSK2", "HAL", "HKEEP"], "", 64, types)
	GpuKernels.add(out, "pool_husk_set_count", K_SET_COUNT, ["WORLD", "DSTATE", "HAL", "HKEEP"], "", 64, types)
	GpuKernels.add(out, "pool_husk_recount", K_RECOUNT, ["WORLD", "DSTATE", "HUSK"], "", 64, types)
