class_name GpuKernelsLife
extends RefCounted
## The bups' lives (see gpu/kernels.gd for how a kernel is made and registered): conjugation, then division, death and mutation, the
## scans that give the kept bups and the newborns their places, the trim at the limit, and the move into those places.

## Division, death and mutation (after uptake), per bup. A bup dies of an empty reserve or by chance; one
## that has grown enough divides: the daughter, if not lethally mutated, is written into CHILD at the parent's index; SURV and KID mark
## who is kept and who has a child. A population that would pass the limit loses a random share each step (a random bup is replaced at
## each birth: the same). The share is what the step's growth is expected to carry over the limit: the last step's growth (CNT_GROWTH)
## added to the count now. Trimming only what is already over leaves the count a step's births above the limit.
const K_LIFE := """
float gamma_big(float shape, inout uint s) {
	float d = shape - 0.3333333, c = 1.0 / sqrt(9.0 * d);
	for (int it = 0; it < 64; it++) {
		float x = gauss(s);
		float v = 1.0 + c * x;
		if (v <= 0.0) continue;
		v = v * v * v;
		float u = max(u01(s), 1e-12);
		if (log(u) < 0.5 * x * x + d - d * v + d * log(v)) return d * v;
	}
	return d;
}
float gamma_(float shape, inout uint s) {
	if (shape < 1.0) { float g = gamma_big(shape + 1.0, s); return g * pow(max(u01(s), 1e-12), 1.0 / shape); }
	return gamma_big(shape, s);
}
int poisson(float mean, inout uint s) {
	float lim = exp(-mean); int count = 0; float p = u01(s);
	while (p > lim && count < 400) { count++; p *= u01(s); }
	return count;
}
void drift(inout float hue, inout float sat, inout float val, inout uint s) {  // (the colour is a neutral marker: every counted mutation moves it)
	hue = fract(hue + gauss(s) * P[P_HUE_STEP]); sat = clamp(sat + gauss(s) * P[P_SAT_STEP], 0.0, 1.0); val = clamp(val + gauss(s) * P[P_VAL_STEP], P[P_VAL_MIN], 1.0);
}
void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(P[P_CAPACITY])) return;
	uint n_now = CNT[CNT_BUPS];
	SURV[i] = 0u; KID[i] = 0u;
	if (i >= n_now) return;
	uint b = i * RECORD_WORDS;
	uint s = hash(hash(CNT[CNT_SEED] ^ (CNT[CNT_STEP] * 0x85EBCA6BU) ^ 777U) + i * 0x9E3779B9U);  // (this dish's stream, this step, this bup)
	float energy = BUPS[b + R_ENERGY], mass = BUPS[b + R_MASS], birth = BUPS[b + R_BIRTH_MASS], add_mass = P[P_ADD_MASS_FACTOR] * BUPS[b + R_SIZE] * BUPS[b + R_SIZE], rate = BUPS[b + R_MUTATOR], donor = BUPS[b + R_DONOR];
	int reach = int(BUPS[b + R_REACH] + 0.5);  // (the building size from the size gene; the mutation rate of this bup, which its daughter is made at)
	float trim = max(0.0, float(n_now) + float(CNT[CNT_GROWTH]) - P[P_LIMIT]) / float(n_now);
	bool natural;
	if (P[P_STATIONARY] > 0.5) {  // the stationary phase: a starving bup (at the growth floor) dies at a constant rate that grows with its metabolism, or when it has shrunk to a share of its birth mass
		natural = u01(s) < P[P_DEATH_CHANCE];
		if (!natural && energy <= P[P_MAINTENANCE_FLOOR]) natural = mass < P[P_STARVE_MIN_MASS_SHARE] * birth || u01(s) < 1.0 - exp(-P[P_STARVE_DEATH_RATE] * exp(P[P_STARVE_DEATH_EXPONENT] * BUPS[b + R_METABOLISM]) * P[P_DELTA]);
	} else {
		natural = energy <= 0.0 || u01(s) < P[P_DEATH_CHANCE];
	}
	bool trimmed = !natural && u01(s) < trim;  // (the same draws as one chain of `||`)
	if (trimmed) atomicAdd(CNT[CNT_TRIMMED], 1u);  // (counted, so that the growth the next trim expects leaves out the trim's own deaths)
	if (natural) BUPS[b + R_PY] = -2.0;  // (a death by starvation or chance, not a trim: `death_clouds` gives its body back; the record is gone after `copy`)
	if (natural || trimmed) return;
	SURV[i] = 1u;
	if (mass >= birth + add_mass) {
		float keep = clamp(0.5 + P[P_DIVISION_SPREAD] * gauss(s), 0.35, 0.65);
		float dm = mass * (1.0 - keep), de = energy * (1.0 - keep);
		mass *= keep; energy *= keep;
		BUPS[b + R_MASS] = mass; BUPS[b + R_ENERGY] = energy; BUPS[b + R_BIRTH_MASS] = mass;
		BUPS[b + R_DIVISIONS] += 1.0;  // (the cell left in the parent's place is a product of this division, whether or not the daughter lives)
		// the daughter's genome: the parent's, mutated
		float g[4] = float[4](BUPS[b + R_SPEED], BUPS[b + R_SENSE], BUPS[b + R_METABOLISM], BUPS[b + R_SIZE]);
		float hue = BUPS[b + R_HUE], sat = BUPS[b + R_SAT], val = BUPS[b + R_VAL], harm = BUPS[b + R_HARM], muts = BUPS[b + R_MUTATIONS];
		bool lethal = false;
		int traits = poisson(P[P_TRAIT_MUTATIONS] * rate, s);
		for (int t = 0; t < traits; t++) {
			int gene = int(u01(s) * 4.0) % 4;
			int lv = (reach >> (2 * gene)) & 3;
			float changed = clamp(g[gene] + gauss(s) * P[P_GENE_STEP + gene], P[P_GENE_MIN + gene], P[P_GENE_MAX + gene] * (lv == 0 ? 1.0 : (lv == 1 ? P[P_REACH_FACTOR_1] : (lv == 2 ? P[P_REACH_FACTOR_2] : P[P_REACH_FACTOR_3]))));
			if (changed != g[gene]) {
				g[gene] = changed; muts += 1.0;
				drift(hue, sat, val, s);
			}
		}
		int harmful = poisson(P[P_HARMFUL_MUTATIONS] * rate, s);
		for (int t = 0; t < harmful; t++) {
			if (u01(s) < P[P_LETHAL_FRACTION]) lethal = true;
			else harm = min(harm + gamma_(P[P_HARM_SHAPE], s) * P[P_MEAN_HARM] / P[P_HARM_SHAPE], P[P_MAX_HARM]);
			muts += 1.0;
			drift(hue, sat, val, s);
		}
		if (harm > 0.0) {
			int repairs = poisson(P[P_COMPENSATORY_MUTATIONS] * rate, s);
			for (int t = 0; t < repairs; t++) {
				harm = max(harm + log(max(u01(s), 1e-12)) * P[P_MEAN_REPAIR], 0.0);
				muts += 1.0;
				drift(hue, sat, val, s);
			}
		}
		// The mutation rate itself changes in jumps (see `mutate`): a new mutator allele sets it to one of three folds, an antimutator halves it.
		float mutator = rate, allele = u01(s);
		if (allele < P[P_MUTATOR_RATE]) {
			float pick = u01(s);
			mutator = max(mutator, pick < 0.2 ? P[P_MUTATOR_FOLD_WEAK] : (pick < 0.8 ? P[P_MUTATOR_FOLD_STRONG] : P[P_MUTATOR_FOLD_TOP]));
			muts += 1.0; drift(hue, sat, val, s);
		} else if (mutator > 1.0 && allele < P[P_MUTATOR_RATE] * (1.0 + P[P_MUTATOR_DOWN_SHARE])) {
			mutator = max(1.0, mutator * 0.5);
			muts += 1.0; drift(hue, sat, val, s);
		}
		float flip = u01(s);  // (the F factor integrates or leaves, rarely)
		float child_donor = donor > 0.5 ? (flip < P[P_DONOR_LOSS] ? 0.0 : 1.0) : (flip < P[P_DONOR_GAIN] ? 1.0 : 0.0);
		int child_reach = reach;  // (a rare mutation raises one gene's ceiling, up to three times)
		int key_now = (child_reach >> 8) & 3;  // (the acetate key: potentiated at a rate, then made by a potentiated line at another)
		if (key_now == 0 ? u01(s) < P[P_KEY_POTENTIATION_RATE] : (key_now == 1 && u01(s) < P[P_KEY_RATE])) { child_reach += 256; muts += 1.0; drift(hue, sat, val, s); }
		if (u01(s) < P[P_REACH_RATE]) {
			int gg = int(u01(s) * 4.0) % 4;
			if (((child_reach >> (2 * gg)) & 3) < 3) { child_reach += 1 << (2 * gg); muts += 1.0; drift(hue, sat, val, s); }
		}
		if (!lethal) {
			KID[i] = 1u;
			float a = u01(s) * 6.2831853, off = 0.5 * mass * P[P_MASS_UM];
			uint c = i * RECORD_WORDS;
			CHILD[c + R_ID_LO] = 0.0;  // (the id, R_ID_LO and R_ID_HI, is written by `compact` as integers)
			CHILD[c + R_X] = BUPS[b + R_X] + cos(a) * off; CHILD[c + R_Y] = BUPS[b + R_Y] + sin(a) * off;
			CHILD[c + R_DX] = 1.0; CHILD[c + R_DY] = 0.0;
			CHILD[c + R_ENERGY] = min(de, P[P_RESERVE_PER_MASS] * dm); CHILD[c + R_MASS] = dm; CHILD[c + R_BIRTH_MASS] = dm;
			CHILD[c + R_SPEED] = g[0]; CHILD[c + R_SENSE] = g[1]; CHILD[c + R_METABOLISM] = g[2]; CHILD[c + R_SIZE] = g[3];
			CHILD[c + R_REACH] = float(child_reach);
			CHILD[c + R_MUTATOR] = mutator;
			CHILD[c + R_DONOR] = child_donor;
			CHILD[c + R_HARM] = harm;
			CHILD[c + R_HUE] = hue; CHILD[c + R_SAT] = sat; CHILD[c + R_VAL] = val; CHILD[c + R_MUTATIONS] = muts; CHILD[c + R_DIVISIONS] = BUPS[b + R_DIVISIONS];
			CHILD[c + R_ID_HI] = 0.0; CHILD[c + R_PX] = 3e38; CHILD[c + R_PY] = 3e38;  // (no picture yet: no trail)
			CHILD[c + R_FAST] = -1.0; CHILD[c + R_SLOW] = 0.0; CHILD[c + R_NOISE] = 0.0; CHILD[c + R_TUMBLING] = 0.0;  // (no chemotaxis memory yet: a fast signal below 0 is none read)
		}
	}
}
"""

const K_FINALIZE := """
const float CAP_SIGMAS = 4.0;  // (how far short of the limit the trim aims, in standard deviations: 4 is over it about once in 30,000 steps)
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	uint n = CNT[CNT_BUPS];
	uint c = uint(P[P_CAPACITY]);
	uint surv = n > 0u ? EXCS[n - 1u] + SURV[n - 1u] : 0u;
	uint kids = n > 0u ? EXCK[n - 1u] + KID[n - 1u] : 0u;
	CNT[CNT_SURVIVORS] = surv; CNT[CNT_NEWBORN] = kids; CNT[CNT_NEXT_COUNT] = min(surv + kids, c);
	int natural = int(n - surv) - int(CNT[CNT_TRIMMED]);  // (the deaths that were not a trim)
	int growth = int(kids) - natural;
	// The count after a step is the limit plus (births - deaths) less what was expected of them: two independent counts of about
	// kids and natural, each Poisson, so the margin is CAP_SIGMAS of sqrt(2 (kids + natural)) and the count is not expected to reach the limit.
	float margin = CAP_SIGMAS * sqrt(2.0 * float(kids + uint(max(natural, 0))));
	CNT[CNT_GROWTH] = uint(max(float(growth), 0.0) + ceil(margin));
	CNT[CNT_TRIMMED] = 0u;
}
"""

const K_COMPACT := """
// One thread per 16 bytes (a bup is RECORD_VEC4 of them): a kept bup is copied to its new place, a newborn written after the kept ones, with
// its id (the next id plus the number of newborns before it: 64 bits in words R_ID_LO and R_ID_HI, with the carry).
void main() {
	// (a dispatch of more groups than one dimension allows (65,535 on some drivers: Direct3D 12) is a grid: the thread's number counts rows too)
	uint t = gl_GlobalInvocationID.x + gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 64u);
	uint i = t / RECORD_VEC4, part = t % RECORD_VEC4;
	if (i >= CNT[CNT_BUPS]) return;
	uint c = uint(P[P_CAPACITY]);
	if (SURV[i] == 1u) BUPS2_V4U[EXCS[i] * RECORD_VEC4 + part] = BUPS_V4U[i * RECORD_VEC4 + part];
	if (KID[i] == 1u) {
		uint slot = CNT[CNT_SURVIVORS] + EXCK[i];
		if (slot < c) {
			uvec4 v = CHILD_V4U[i * RECORD_VEC4 + part];
			uint lo = CNT[CNT_NEXT_ID_LO] + EXCK[i];
			if (part == R_ID_LO / 4u) v[R_ID_LO % 4u] = lo;
			if (part == R_ID_HI / 4u) v[R_ID_HI % 4u] = CNT[CNT_NEXT_ID_HI] + (lo < CNT[CNT_NEXT_ID_LO] ? 1u : 0u);
			BUPS2_V4U[slot * RECORD_VEC4 + part] = v;
		}
	}
}
"""

const K_COPY := """
void main() {
	uint t = gl_GlobalInvocationID.x + gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 64u); if (t >= CNT[CNT_NEXT_COUNT] * RECORD_VEC4) return;  // (a grid of groups when one row is not enough: see compact)
	BUPS_V4U[t] = BUPS2_V4U[t];
}
"""

const K_SETCOUNT := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;  // (one thread: a dispatch of 1 runs a whole group of 64)
	uint lo = CNT[CNT_NEXT_ID_LO] + CNT[CNT_NEWBORN]; if (lo < CNT[CNT_NEXT_ID_LO]) CNT[CNT_NEXT_ID_HI] += 1u; CNT[CNT_NEXT_ID_LO] = lo; CNT[CNT_BUPS] = CNT[CNT_NEXT_COUNT]; CNT[CNT_STEP] += 1u; }
"""

## Conjugation. The donors (R_DONOR) go into a hashed table of the 20 µm cells they stand in, four slots a cell, and the
## largest donor's half length is kept (CNT_DONOR_REACH); then each bup that is not a donor looks in the cells round it as far as a donor can be and still touch
## it (its own half length, the largest donor's and contact_um: 3 x 3 cells or fewer for the usual sizes) for a donor it touches (centres no farther apart than the
## two bodies' half lengths and contact_um) that transfers to it this step (a draw keyed by the pair and the step, so that the order the threads run in does not
## matter), takes the lowest-numbered one, and copies a run of its genes: the first, each next with the chance P_CONJ_CONTINUE. Only a recipient changes, and only
## itself, so there are no races. CNT_DONORS counts the donors of the step.
const CONJ_FUNCS := """
const uint DMASK = 65535u;
const float DCELL = 20.0;
uint dhash(int cx, int cy) { return hash(uint(cx) * 73856093u ^ uint(cy) * 19349663u) & DMASK; }
float keyed01(uint a, uint b, uint c) { uint h = hash(hash(hash(a ^ 0x9E3779B9u) + b * 0x85EBCA6Bu) ^ (c * 0xC2B2AE35u)); return (float(h >> 8) + 0.5) / 16777216.0; }
"""

const K_CONJ_CLEAR := """
void main() {
	uint t = gl_GlobalInvocationID.x;
	if (t < (DMASK + 1u) * 4u) DTAB[t] = 0xFFFFFFFFu;
	else if (t < (DMASK + 1u) * 4u + 2048u) DTAB[t] = 0u;  // (the bitmap of the buckets in use)
	if (t == 0u) { CNT[CNT_DONORS] = 0u; CNT[CNT_DONOR_REACH] = 0u; }
}
"""

const K_CONJ_INSERT := """
void main() {
	BUP_RECORD_THREAD
	if (BUPS[b + R_DONOR] < 0.5) return;
	atomicAdd(CNT[CNT_DONORS], 1u);
	atomicMax(CNT[CNT_DONOR_REACH], floatBitsToUint(0.5 * BUPS[b + R_MASS] * P[P_MASS_UM]));  // (a positive float's bits order as the float does)
	uint h = dhash(int(floor(BUPS[b + R_X] / DCELL)), int(floor(BUPS[b + R_Y] / DCELL)));
	atomicOr(DTAB[(DMASK + 1u) * 4u + (h >> 5u)], 1u << (h & 31u));
	for (uint s = 0u; s < 4u; s++) {
		if (atomicCompSwap(DTAB[h * 4u + s], 0xFFFFFFFFu, i) == 0xFFFFFFFFu) break;
	}
}
"""

const K_CONJ_APPLY := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS] || CNT[CNT_DONORS] == 0u) return;
	uint b = i * RECORD_WORDS;
	if (BUPS[b + R_DONOR] > 0.5) return;
	float x = BUPS[b + R_X], y = BUPS[b + R_Y];
	float rr = 0.5 * BUPS[b + R_MASS] * P[P_MASS_UM];
	float reach = uintBitsToFloat(CNT[CNT_DONOR_REACH]) + rr + P[P_CONTACT_UM];  // (the farthest a donor's centre can be and touch it)
	int x0 = int(floor((x - reach) / DCELL)), x1 = int(floor((x + reach) / DCELL)), y0 = int(floor((y - reach) / DCELL)), y1 = int(floor((y + reach) / DCELL));
	uint best = 0xFFFFFFFFu;
	for (int gx = x0; gx <= x1; gx++) for (int gy = y0; gy <= y1; gy++) {
		uint h = dhash(gx, gy);
		if ((DTAB[(DMASK + 1u) * 4u + (h >> 5u)] & (1u << (h & 31u))) == 0u) continue;  // (no donor in this bucket: the bitmap is small enough to stay in cache)
		for (uint s = 0u; s < 4u; s++) {
			uint d = DTAB[h * 4u + s];
			if (d == 0xFFFFFFFFu || d >= best) continue;
			uint db = d * RECORD_WORDS;
			float dx = BUPS[db + R_X] - x, dy = BUPS[db + R_Y] - y;
			float range = 0.5 * BUPS[db + R_MASS] * P[P_MASS_UM] + rr + P[P_CONTACT_UM];
			if (dx * dx + dy * dy > range * range) continue;
			if (keyed01(CNT[CNT_SEED] ^ CNT[CNT_STEP], i, d) < P[P_CONJ_CHANCE]) best = d;
		}
	}
	if (best == 0xFFFFFFFFu) return;
	int run = 1;
	for (int k = 0; k < 3; k++) {
		if (keyed01(CNT[CNT_SEED] ^ CNT[CNT_STEP] ^ 0x5bd1e995u, i * 4u + uint(k), best) < P[P_CONJ_CONTINUE]) run++; else break;
	}
	uint db = best * RECORD_WORDS;
	for (int g = 0; g < run; g++) BUPS[b + R_SPEED + uint(g)] = BUPS[db + R_SPEED + uint(g)];
	int mask = (1 << (2 * run)) - 1;  // (the raised ceilings of the genes that moved go with them)
	BUPS[b + R_REACH] = float((int(BUPS[b + R_REACH] + 0.5) & ~mask) | (int(BUPS[db + R_REACH] + 0.5) & mask));
}
"""


# ---- the pooled world: the same lives for every dish of the pool at once (see gpu/kernels.gd, POOL_FUNCS) ------------------------------
# A dish's bups are the segment of slots it occupies (BLKDISH, DS_START, DS_COUNT); its random streams, ranks, ids, limit and counters are
# its own (keyed by the bup's place l in its segment), so a dish's run is the same alone or among others. A step's order:
#   pool_conj_clear, pool_conj_count, pool_conj_scan_*, pool_conj_scatter, pool_conj_apply (conjugation)
#   pool_life (the host counts the donors in `pool_apply_count` and runs conjugation and life in `pool_ac_conj_life` and `pool_donor_life`),
#   pool_scan_s_* (SURV -> EXCS), pool_scan_k_* (KID -> EXCK), pool_finalize, pool_slot_check (kernels_core.gd)
#   (the death clouds read: SURV 0 for a bup not kept, R_PY -2 for one dead of starvation or chance, its rank among its dish's dead
#   l - (EXCS[i] - DN_SURV_BASE), the dish's dead DS_COUNT - DS_SURVIVORS)
#   pool_events, pool_blk_fill, pool_compact (into the other half), pool_setcount (pa 1), then the halves swap (GpuKernels.PING_PONG)
# and a batch begins with pool_ev_begin (kernels_game.gd). The pipette's retarget pass, at the head of a batch after pool_ev_begin:
#   pool_pip_mark, pool_scan_s_*, pool_pip_final, pool_slot_check, pool_pip_scatter, pool_blk_fill, pool_setcount (pa 0), the halves
#   swap, then the stats (pool_stats1, pool_stats2) over the new layout.
# Segments lie in the order of their dishes' rows: a compaction or a retarget places each running row's segment after the rows before
# it, so a segment the host writes anywhere (a new dish, a thaw) is in row order after the next pass.
# The scratch buffers these kernels add (uint words): DNEXT (the step's per-dish words DN_*, D_MAX + 1 rows of DN_WORDS: the last row's
# first word is the next layout's slots), CBKT (a slot each: a donor's bucket or NOT_DONOR), DCNT and DOFF (a word a bucket:
# conj_buckets(slots)), DBIT (a bit a bucket: the buckets that hold a donor), DLIST (a slot each: the donors by bucket), GSUM and GOFF (GpuKernels.scan_groups' most groups: a grid scan's
# sums and offsets).

const DN_WORDS := 8  ## words of a dish's row of DNEXT
const DN_START := 0  ## the dish's first slot in the next layout
const DN_SIZE := 1  ## its segment's slots in the next layout (its count rounded up to whole blocks; 0 for a row not running)
const DN_SURV_BASE := 2  ## EXCS at the dish's first slot (the kept, or in a retarget the moved, bups of the dishes before it)
const DN_KID_BASE := 3  ## EXCK at the dish's first slot
const DN_BIRTH_BASE := 4  ## the event ring's place of the dish's first birth of the step
const DN_DEATH_BASE := 5  ## and of its first death
# (words 6 and 7 are spare)
const DN_TOTAL_WORD := GpuLayout.D_MAX * DN_WORDS  ## the word of DNEXT that holds the next layout's slots in use
const DNEXT_WORDS := (GpuLayout.D_MAX + 1) * DN_WORDS
const CONJ_MIN_BUCKETS := 65536  ## the fewest buckets of the donors' index
const POOL_ROWS_PER_THREAD := GpuLayout.D_MAX / 256  ## pool_finalize and pool_pip_final: one group of 256 threads over every row

## The scratch buffers' element types (for GpuKernels.add).
const POOL_TYPES := {"DNEXT": "uint", "CBKT": "uint", "DCNT": "uint", "DOFF": "uint", "DLIST": "uint", "GSUM": "uint", "GOFF": "uint", "DBIT": "uint"}


## The buckets of the donors' index for a pool of `slots` slots in use (the kernels work it out from WORLD[WD_SLOTS] the same way): a
## quarter of the next power of two, and at least CONJ_MIN_BUCKETS. DCNT and DOFF hold this many for the most slots the pool can have.
static func conj_buckets(slots: int) -> int:
	var p := 2
	while p < slots:
		p <<= 1
	return maxi(CONJ_MIN_BUCKETS, p >> 2)


## The GLSL of the DNEXT names and its lookup DN(d, word) (a kernel that uses DN binds DNEXT).
static func dn_funcs() -> String:
	var names := {
		"DN_WORDS": DN_WORDS, "DN_START": DN_START, "DN_SIZE": DN_SIZE, "DN_SURV_BASE": DN_SURV_BASE, "DN_KID_BASE": DN_KID_BASE,
		"DN_BIRTH_BASE": DN_BIRTH_BASE, "DN_DEATH_BASE": DN_DEATH_BASE,
		"DN_TOTAL_WORD": DN_TOTAL_WORD, "CONJ_MIN_BUCKETS": CONJ_MIN_BUCKETS, "POOL_ROWS_PER_THREAD": POOL_ROWS_PER_THREAD,
	}
	var text := ""
	for name: String in names:
		text += "const uint %s = %du;\n" % [name, names[name]]
	return text + "#define DN(d, w) DNEXT[(d) * DN_WORDS + (w)]\n"


## FLAG(d, f): flag f (a DPF_* bit) of dish row d (a kernel that uses it binds DISHP).
const FLAG_FUNC := "#define FLAG(d, f) ((DPU(d, DP_FLAGS) & (1u << (f))) != 0u)\n"


## A copy of `text` with `from` replaced by `to`, which must be there exactly once: the pooled kernels are the single-dish path's with their single
## dish's words replaced by the dish's own, so the model's arithmetic has one source.
static func swapped(text: String, from: String, to: String) -> String:
	assert(text.count(from) == 1, "pooled kernel: expected one '%s'" % from)
	return text.replace(from, to)


## `life` for each slot of the pool: SURV and KID 0 for every slot, then the single-dish path's division, death and mutation for each bup with its
## dish's stream, limit, growth and stationary flag; the energy ledger (LEDGER) takes what a death does not give back (the reserve and the
## body less P_DEATH_GIVE x the mass of a death by starvation or chance, all of a trimmed bup), a lethal daughter's share, and a
## daughter's reserve past what her mass holds.
static func pool_life() -> String:
	return pool_life_slot() + "SLOT_LOOP(life_slot)\n"


## `pool_life`'s function of one slot, life_slot(i, d, l), without its loop.
static func pool_life_slot() -> String:
	var t := swapped(K_LIFE, """void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= uint(P[P_CAPACITY])) return;
	uint n_now = CNT[CNT_BUPS];
	SURV[i] = 0u; KID[i] = 0u;
	if (i >= n_now) return;
	uint b = i * RECORD_WORDS;
	uint s = hash(hash(CNT[CNT_SEED] ^ (CNT[CNT_STEP] * 0x85EBCA6BU) ^ 777U) + i * 0x9E3779B9U);  // (this dish's stream, this step, this bup)""", """void life_slot(uint i, uint d, uint l) {
	SURV[i] = 0u; KID[i] = 0u;
	if (d == NO_DISH) return;
	uint n_now = DS(d, DS_COUNT);
	if (l >= n_now) return;
	uint b = i * RECORD_WORDS;
	uint s = DISH_STREAM(d, l, 777U);  // (this dish's stream, this step, this bup)""")
	t = swapped(t, "float(CNT[CNT_GROWTH]) - P[P_LIMIT]", "float(DS(d, DS_GROWTH)) - float(DPU(d, DP_LIMIT))")
	t = swapped(t, "if (P[P_STATIONARY] > 0.5)", "if (FLAG(d, DPF_STATIONARY))")
	t = swapped(t, "atomicAdd(CNT[CNT_TRIMMED], 1u)", "atomicAdd(DS(d, DS_TRIMMED), 1u)")
	t = swapped(t, "	if (natural || trimmed) return;", "	if (natural || trimmed) {\n\t\tLEDGER(d, LG_LIFE, energy + P[P_COST_PER_MASS] * mass - (natural && P[P_DEATH_GIVE] > 0.0 ? P[P_DEATH_GIVE] * mass : 0.0))\n\t\treturn;\n\t}")
	t = swapped(t, "		if (!lethal) {\n", "		LEDGER(d, LG_LIFE, lethal ? de + P[P_COST_PER_MASS] * dm : de - min(de, P[P_RESERVE_PER_MASS] * dm))\n		if (!lethal) {\n")
	assert(not t.contains("CNT["), "pool_life still reads CNT")
	return t


## Each dish's counts after `life` and the scans, and the next layout (one group of 256 threads, POOL_ROWS_PER_THREAD rows each): for a
## running row its kept bups and newborns (from the scans at its first and last slot), the count after the step (up to DP_CAP), what
## the trim expects of the next step (the single-dish path's `finalize`), its births and deaths; then over every row in row
## order the next layout's starts (segments of whole blocks) and the event ring's places of each dish's births and deaths this step
## (after every event of the iteration so far: the sum of DS_BIRTHS and DS_DEATHS over the rows), and the next layout's slots in use.
const K_POOL_FINALIZE := """
const float CAP_SIGMAS = 4.0;  // (as `finalize`)
shared uint sh_size[256], sh_births[256], sh_deaths[256], sh_tb[256], sh_td[256];
void main() {
	if (gl_WorkGroupID.x != 0u) return;
	uint t = gl_LocalInvocationID.x;
	uint size[POOL_ROWS_PER_THREAD], births[POOL_ROWS_PER_THREAD], deaths[POOL_ROWS_PER_THREAD];
	uint my_size = 0u, my_births = 0u, my_deaths = 0u, tb = 0u, td = 0u;
	for (uint r = 0u; r < POOL_ROWS_PER_THREAD; r++) {
		uint d = t * POOL_ROWS_PER_THREAD + r;
		size[r] = 0u; births[r] = 0u; deaths[r] = 0u;
		tb += DS(d, DS_BIRTHS); td += DS(d, DS_DEATHS);
		if (!FLAG(d, DPF_RUNNING)) continue;
		uint n = DS(d, DS_COUNT), start = DS(d, DS_START);
		uint surv = 0u, kids = 0u;
		if (n > 0u) {
			uint last = start + n - 1u;
			DN(d, DN_SURV_BASE) = EXCS[start]; DN(d, DN_KID_BASE) = EXCK[start];
			surv = EXCS[last] + SURV[last] - EXCS[start];
			kids = EXCK[last] + KID[last] - EXCK[start];
		}
		uint next = min(surv + kids, DPU(d, DP_CAP));
		DS(d, DS_SURVIVORS) = surv; DS(d, DS_NEWBORN) = kids; DS(d, DS_NEXT_COUNT) = next;
		int natural = int(n - surv) - int(DS(d, DS_TRIMMED));
		int growth = int(kids) - natural;
		float margin = CAP_SIGMAS * sqrt(2.0 * float(kids + uint(max(natural, 0))));
		DS(d, DS_GROWTH) = uint(max(float(growth), 0.0) + ceil(margin));
		births[r] = next - surv; deaths[r] = n - surv;
		DS(d, DS_TRIMMED) = 0u;
		size[r] = (next + BLK_SLOTS - 1u) & ~(BLK_SLOTS - 1u);
		my_size += size[r]; my_births += births[r]; my_deaths += deaths[r];
	}
	sh_size[t] = my_size; sh_births[t] = my_births; sh_deaths[t] = my_deaths; sh_tb[t] = tb; sh_td[t] = td;
	barrier();
	for (uint off = 1u; off < 256u; off <<= 1u) {
		uint a = t >= off ? sh_size[t - off] : 0u, bb = t >= off ? sh_births[t - off] : 0u, c = t >= off ? sh_deaths[t - off] : 0u;
		uint e = t >= off ? sh_tb[t - off] : 0u, f = t >= off ? sh_td[t - off] : 0u;
		barrier();
		sh_size[t] += a; sh_births[t] += bb; sh_deaths[t] += c; sh_tb[t] += e; sh_td[t] += f;
		barrier();
	}
	uint at = sh_size[t] - my_size, bat = sh_tb[255] + sh_births[t] - my_births, dat = sh_td[255] + sh_deaths[t] - my_deaths;
	for (uint r = 0u; r < POOL_ROWS_PER_THREAD; r++) {
		uint d = t * POOL_ROWS_PER_THREAD + r;
		DN(d, DN_START) = at; DN(d, DN_SIZE) = size[r]; DN(d, DN_BIRTH_BASE) = bat; DN(d, DN_DEATH_BASE) = dat;
		at += size[r]; bat += births[r]; dat += deaths[r];
		if (FLAG(d, DPF_RUNNING)) { DS(d, DS_BIRTHS) += births[r]; DS(d, DS_DEATHS) += deaths[r]; }
	}
	if (t == 255u) DNEXT[DN_TOTAL_WORD] = sh_size[255];
}
"""

## The block table of the next layout (into BLKDISH2, the other half's): each block of the next layout's slots belongs to the last row whose
## next start is at or before it (the starts rise with the row), if it lies inside that row's segment.
const K_POOL_BLK_FILL := """
void blk_fill(uint k) {
	uint at = k << BLK_SHIFT, lo = 0u, hi = D_MAX - 1u;
	while (lo < hi) { uint mid = (lo + hi + 1u) >> 1u; if (DN(mid, DN_START) <= at) lo = mid; else hi = mid - 1u; }
	BLKDISH2[k] = at < DN(lo, DN_START) + DN(lo, DN_SIZE) ? lo : NO_DISH;
}
GRID_LOOP(blk_fill, DNEXT[DN_TOTAL_WORD] >> BLK_SHIFT)
"""

## `compact` for the pool (one thread per 16 bytes of a record of the layout now, into the other half): a kept bup goes to its dish's
## next start plus its rank among the dish's kept ones, a newborn the dish places after them, with its id (the world's next id plus its
## rank among every newborn of the pool, in slot order: 64 bits in R_ID_LO and R_ID_HI, with the carry). Nothing is placed at or past the dish's next count
## (DP_CAP's cut of the newborns, and `pool_slot_check`'s of a layout past the slots).
const K_POOL_COMPACT := """
void compact_piece(uint t) {
	uint i = t / RECORD_VEC4, part = t % RECORD_VEC4;
	uint d = BLKDISH[i >> BLK_SHIFT];
	if (d == NO_DISH || i - DS(d, DS_START) >= DS(d, DS_COUNT)) return;
	uint next = DS(d, DS_NEXT_COUNT);
	if (SURV[i] == 1u) {
		uint rank = EXCS[i] - DN(d, DN_SURV_BASE);
		if (rank < next) BUPS2_V4U[(DN(d, DN_START) + rank) * RECORD_VEC4 + part] = BUPS_V4U[i * RECORD_VEC4 + part];
	}
	if (KID[i] == 1u) {
		uint k = EXCK[i] - DN(d, DN_KID_BASE), place = DS(d, DS_SURVIVORS) + k;
		if (place < next) {
			uvec4 v = CHILD_V4U[i * RECORD_VEC4 + part];
			uint lo = WORLD[WD_NEXT_ID_LO] + EXCK[i];
			if (part == R_ID_LO / 4u) v[R_ID_LO % 4u] = lo;
			if (part == R_ID_HI / 4u) v[R_ID_HI % 4u] = WORLD[WD_NEXT_ID_HI] + (lo < WORLD[WD_NEXT_ID_LO] ? 1u : 0u);
			BUPS2_V4U[(DN(d, DN_START) + place) * RECORD_VEC4 + part] = v;
		}
	}
}
GRID_LOOP(compact_piece, WORLD[WD_SLOTS] * RECORD_VEC4)
"""

## After a compaction (pa 1: a step) or a retarget (pa 0): each running row takes the next layout's start and count, a step also its
## step; a step also the world's next id (past every newborn of the pool, placed or not); the pool its slots in use.
const K_POOL_SETCOUNT := """
void setcount_row(uint d) {
	if (d == 0u) {
		if (pcs.pa > 0.5) {  // (the newborns of the whole pool: the scan's last value and last flag, over the slots of the step that ran)
			uint n = WORLD[WD_SLOTS], kids = n > 0u ? EXCK[n - 1u] + KID[n - 1u] : 0u;
			uint lo = WORLD[WD_NEXT_ID_LO] + kids;
			if (lo < WORLD[WD_NEXT_ID_LO]) WORLD[WD_NEXT_ID_HI] += 1u;
			WORLD[WD_NEXT_ID_LO] = lo;
		}
		WORLD[WD_SLOTS] = DNEXT[DN_TOTAL_WORD];
	}
	if (!FLAG(d, DPF_RUNNING)) return;
	DS(d, DS_START) = DN(d, DN_START); DS(d, DS_COUNT) = DS(d, DS_NEXT_COUNT);
	if (pcs.pa > 0.5) {
		DS(d, DS_STEP) += 1u;
	}
}
GRID_LOOP(setcount_row, D_MAX)
"""

## Conjugation for the pool. The single-dish path's rule (see CONJ_FUNCS above): a recipient takes, of the donors of its dish that touch it and transfer
## to it this step (a draw keyed by the dish's step and the two bups' places in their dish), the one with the lowest place. That is a
## least value, the same in whatever order the donors are listed, so the donors' index need not be sorted within a bucket: it is a count
## of the donors in each bucket of (dish, 20 µm cell), a scan, and a scatter, with no overflow (CBKT keeps each donor's bucket between
## the count and the scatter; DLIST is the donors by bucket, bucket b's from DOFF[b] - DCNT[b] up to DOFF[b] after the scatter).
## DBIT has a bit for each bucket that holds a donor (a word a 32 buckets: 64 KB for 2M slots), which a recipient reads before the
## bucket's count, so the many recipients near no donor touch a small table that stays in the cache instead of DCNT.
const POOL_CONJ_FUNCS := """
const uint NOT_DONOR = 0xFFFFFFFFu;
uint conj_mask() { return CONJ_BUCKETS - 1u; }
uint dbucket(uint d, int cx, int cy, uint mask) { return hash(uint(cx) * 73856093u ^ uint(cy) * 19349663u ^ d * 83492791u) & mask; }
"""

## WORLD[WD_SLOTS]'s count of buckets as a GLSL expression (conj_buckets()).
const CONJ_BUCKETS_EXPR := "max(CONJ_MIN_BUCKETS, (2u << uint(findMSB(max(WORLD[WD_SLOTS], 2u) - 1u))) >> 2u)"

const K_POOL_CONJ_CLEAR := """
void conj_clear(uint k) {
	if (k < CONJ_BUCKETS) DCNT[k] = 0u;
	if (k < CONJ_BUCKETS / 32u) DBIT[k] = 0u;
	if (k < D_MAX) { DS(k, DS_DONORS) = 0u; DS(k, DS_DONOR_REACH) = 0u; }
}
GRID_LOOP(conj_clear, max(CONJ_BUCKETS, D_MAX))
"""

const K_POOL_CONJ_COUNT := """
void conj_count(uint i, uint d, uint l) {
	uint b = i * RECORD_WORDS;
	if (BUPS[b + R_DONOR] < 0.5) { CBKT[i] = NOT_DONOR; return; }
	atomicAdd(DS(d, DS_DONORS), 1u);
	atomicMax(DS(d, DS_DONOR_REACH), floatBitsToUint(0.5 * BUPS[b + R_MASS] * P[P_MASS_UM]));  // (a positive float's bits order as the float does)
	uint h = dbucket(d, int(floor(BUPS[b + R_X] / DCELL)), int(floor(BUPS[b + R_Y] / DCELL)), conj_mask());
	CBKT[i] = h;
	atomicAdd(DCNT[h], 1u);
	atomicOr(DBIT[h >> 5u], 1u << (h & 31u));
}
BUP_LOOP(conj_count)
"""

const K_POOL_CONJ_SCATTER := """
void conj_scatter(uint i, uint d, uint l) {
	if (DS(d, DS_DONORS) == 0u) return;
	uint h = CBKT[i];
	if (h != NOT_DONOR) DLIST[atomicAdd(DOFF[h], 1u)] = i;
}
BUP_LOOP(conj_scatter)
"""

const K_POOL_CONJ_APPLY := """
void conj_apply(uint i, uint d, uint l) {
	if (DS(d, DS_DONORS) == 0u) return;
	uint b = i * RECORD_WORDS;
	if (BUPS[b + R_DONOR] > 0.5) return;
	float x = BUPS[b + R_X], y = BUPS[b + R_Y];
	float rr = 0.5 * BUPS[b + R_MASS] * P[P_MASS_UM];
	float reach = uintBitsToFloat(DS(d, DS_DONOR_REACH)) + rr + P[P_CONTACT_UM];  // (the farthest a donor's centre can be and touch it)
	int x0 = int(floor((x - reach) / DCELL)), x1 = int(floor((x + reach) / DCELL)), y0 = int(floor((y - reach) / DCELL)), y1 = int(floor((y + reach) / DCELL));
	uint start = DS(d, DS_START), key = DISH_KEY(d), mask = conj_mask(), best = NOT_DONOR;
	for (int gx = x0; gx <= x1; gx++) for (int gy = y0; gy <= y1; gy++) {
		uint h = dbucket(d, gx, gy, mask);
		if ((DBIT[h >> 5u] & (1u << (h & 31u))) == 0u) continue;
		uint n = DCNT[h];
		if (n == 0u) continue;
		uint end = DOFF[h];
		for (uint k = end - n; k < end; k++) {
			uint j = DLIST[k];
			if (BLKDISH[j >> BLK_SHIFT] != d) continue;  // (another dish's donor in the same bucket)
			uint lj = j - start;
			if (lj >= best) continue;
			uint db = j * RECORD_WORDS;
			float dx = BUPS[db + R_X] - x, dy = BUPS[db + R_Y] - y;
			float range = 0.5 * BUPS[db + R_MASS] * P[P_MASS_UM] + rr + P[P_CONTACT_UM];
			if (dx * dx + dy * dy > range * range) continue;
			if (keyed01(key, l, lj) < P[P_CONJ_CHANCE]) best = lj;
		}
	}
	if (best == NOT_DONOR) return;
	int run = 1;
	for (int k = 0; k < 3; k++) {
		if (keyed01(key ^ 0x5bd1e995u, l * 4u + uint(k), best) < P[P_CONJ_CONTINUE]) run++; else break;
	}
	uint db = (start + best) * RECORD_WORDS;
	for (int g = 0; g < run; g++) BUPS[b + R_SPEED + uint(g)] = BUPS[db + R_SPEED + uint(g)];
	int mask_ = (1 << (2 * run)) - 1;  // (the raised ceilings of the genes that moved go with them)
	BUPS[b + R_REACH] = float((int(BUPS[b + R_REACH] + 0.5) & ~mask_) | (int(BUPS[db + R_REACH] + 0.5) & mask_));
}
BUP_LOOP(conj_apply)
"""

## `pool_ac_apply`, `pool_conj_apply` and `pool_life` in one pass over the slots (what the step runs; the three kernels stay for the checks
## that run them alone), with `pool_donor_life` after it: each record is read once for all three. A bup takes up its acetate first, as it
## would in the pass before, since a recipient's metabolism, which sets its yield, may then change; then conjugation, which reads only the
## donors' genes, places and masses; then its life. Only a donor's record is read by another thread (a recipient's), and a donor's life
## changes its mass, so the donors (those of the donors' index, CBKT) live in `pool_donor_life`, after every recipient has read them.
static func pool_ac_conj_life() -> String:
	return loop_function(GpuKernelsField.K_POOL_AC_APPLY, "f", "ac_apply") + loop_function(K_POOL_CONJ_APPLY, "conj_apply", "conj_apply") + pool_life_slot() + """
void ac_conj_life(uint i, uint d, uint l) {
	if (d != NO_DISH && l < DS(d, DS_COUNT)) {
		ac_apply(i, d, l);
		conj_apply(i, d, l);
		if (CBKT[i] != NOT_DONOR) return;
	}
	life_slot(i, d, l);
}
SLOT_LOOP(ac_conj_life)
"""


## The donors' lives, after `pool_ac_conj_life`: every donor is in DLIST once, and the scatter leaves the last bucket's DOFF at their number.
static func pool_donor_life() -> String:
	return pool_life_slot() + """
void donor_life(uint k) {
	uint i = DLIST[k], d = BLKDISH[i >> BLK_SHIFT];
	life_slot(i, d, i - DS(d, DS_START));
}
GRID_LOOP(donor_life, DOFF[CONJ_BUCKETS - 1u])
"""


## `pool_apply` and `pool_conj_count` in one pass over the bups (what the step runs, after `pool_conj_clear`): the donors' index needs only
## their places, masses and flags, which nothing after swimming changes, so it is counted while `pool_apply` has the record. What a bup read
## of the clouds is `pool_swim_demand`'s (CLOUDC): the same lists at the same place.
static func pool_apply_count() -> String:
	var apply := swapped(GpuKernelsField.K_POOL_APPLY, "float cc, pgx, pgy, psig; puffs_at_d(d, x, y, cc, pgx, pgy, psig);", "float cc = CLOUDC[i];")
	return loop_function(apply, "f", "apply_bup") + loop_function(K_POOL_CONJ_COUNT, "conj_count", "conj_count") \
		+ "void apply_count(uint i, uint d, uint l) { apply_bup(i, d, l); conj_count(i, d, l); }\nBUP_LOOP(apply_count)\n"


## A pooled kernel's text that ends `BUP_LOOP(fn)` without that loop, its function `fn` renamed `to`: a part of a kernel that runs
## several parts for each bup.
static func loop_function(text: String, fn: String, to: String) -> String:
	assert(text.ends_with("BUP_LOOP(%s)\n" % fn), "pooled kernel: expected it to end with BUP_LOOP(%s)" % fn)
	return swapped(text.trim_suffix("BUP_LOOP(%s)\n" % fn), "void %s(uint i, uint d, uint l) {" % fn, "void %s(uint i, uint d, uint l) {" % to)


## The pipette's retarget: the bups of the source dish inside a disc move to the destination dish, with their ids, genes and
## everything else but their place, shifted by the disc's centre (the destination's middle); no step, no draw, no event. The push constant
## of every pass: pa, pb the disc's centre and pc its radius (µm, the source dish's own coordinates), pd the rows (source + destination
## x D_MAX). pool_pip_mark marks the moved bups (SURV 1, PIPDST their destination); after the scan of SURV, pool_pip_final gives every
## running row its next layout (the source less the moved, the destination with them after its own bups) and counts the move (DS_MOVED_OUT,
## DS_MOVED_IN), and pool_pip_scatter repacks the pool into the other half (placing no bup at or past its new dish's next count: see
## pool_slot_check). Ids are not touched: the world's counter is the dishes' alike.
const PIP_FUNCS := """
uint pip_src() { return uint(pcs.pd) % D_MAX; }
uint pip_dst() { return uint(pcs.pd) / D_MAX; }
"""

const K_POOL_PIP_MARK := """
void pip_mark(uint i, uint d, uint l) {
	bool moved = false;
	uint b = i * RECORD_WORDS;
	if (d == pip_src() && l < DS(d, DS_COUNT)) {
		float dx = uintBitsToFloat(BUPS_U[b + R_X]) - pcs.pa, dy = uintBitsToFloat(BUPS_U[b + R_Y]) - pcs.pb;
		moved = dx * dx + dy * dy <= pcs.pc * pcs.pc;
	}
	SURV[i] = moved ? 1u : 0u;
	PIPDST[i] = moved ? pip_dst() : NO_DISH;
}
SLOT_LOOP(pip_mark)
"""

const K_POOL_PIP_FINAL := """
shared uint sh_size[256];
void main() {
	if (gl_WorkGroupID.x != 0u) return;
	uint t = gl_LocalInvocationID.x, src = pip_src(), dst = pip_dst();
	uint moved = 0u, n_src = DS(src, DS_COUNT), first = DS(src, DS_START);
	if (n_src > 0u) { uint last = first + n_src - 1u; moved = EXCS[last] + SURV[last] - EXCS[first]; }
	uint size[POOL_ROWS_PER_THREAD], my_size = 0u;
	for (uint r = 0u; r < POOL_ROWS_PER_THREAD; r++) {
		uint d = t * POOL_ROWS_PER_THREAD + r;
		size[r] = 0u;
		if (!FLAG(d, DPF_RUNNING)) continue;
		uint next = DS(d, DS_COUNT);
		if (d == src) { next -= moved; DN(d, DN_SURV_BASE) = n_src > 0u ? EXCS[first] : 0u; DS(d, DS_MOVED_OUT) += moved; }
		if (d == dst) {
			next += moved; DS(d, DS_MOVED_IN) += moved;
		}
		DS(d, DS_NEXT_COUNT) = next;
		size[r] = (next + BLK_SLOTS - 1u) & ~(BLK_SLOTS - 1u);
		my_size += size[r];
	}
	sh_size[t] = my_size;
	barrier();
	for (uint off = 1u; off < 256u; off <<= 1u) {
		uint a = t >= off ? sh_size[t - off] : 0u;
		barrier();
		sh_size[t] += a;
		barrier();
	}
	uint at = sh_size[t] - my_size;
	for (uint r = 0u; r < POOL_ROWS_PER_THREAD; r++) {
		uint d = t * POOL_ROWS_PER_THREAD + r;
		DN(d, DN_START) = at; DN(d, DN_SIZE) = size[r];
		at += size[r];
	}
	if (t == 255u) DNEXT[DN_TOTAL_WORD] = sh_size[255];
}
"""

const K_POOL_PIP_SCATTER := """
void pip_piece(uint t) {
	uint i = t / RECORD_VEC4, part = t % RECORD_VEC4;
	uint d = BLKDISH[i >> BLK_SHIFT];
	if (d == NO_DISH) return;
	uint l = i - DS(d, DS_START);
	if (l >= DS(d, DS_COUNT)) return;
	uvec4 v = BUPS_V4U[i * RECORD_VEC4 + part];
	uint t_ = d, at = l;  // (the dish the bup is in after the pass, and its place there)
	if (d == pip_src()) {
		uint before = EXCS[i] - DN(d, DN_SURV_BASE);  // (the moved bups before this one in the dish)
		if (SURV[i] == 1u) {
			t_ = pip_dst();
			at = DS(t_, DS_COUNT) + before;
			if (part == R_X / 4u) { v[R_X % 4u] = floatBitsToUint(uintBitsToFloat(v[R_X % 4u]) - pcs.pa); v[R_Y % 4u] = floatBitsToUint(uintBitsToFloat(v[R_Y % 4u]) - pcs.pb); }
		} else {
			at = l - before;
		}
	}
	if (at < DS(t_, DS_NEXT_COUNT)) BUPS2_V4U[(DN(t_, DN_START) + at) * RECORD_VEC4 + part] = v;
}
GRID_LOOP(pip_piece, WORLD[WD_SLOTS] * RECORD_VEC4)
"""


## Adds these kernels to `out` (see GpuKernels.all()).
static func register(out: Dictionary) -> void:
	GpuKernels.add(out, "life", K_LIFE, ["P", "CNT", "BUPS", "CHILD", "SURV", "KID"])
	GpuKernels.add(out, "scan0_s", GpuKernels.K_SCAN.replace("SRC", "SURV").replace("DST", "EXCS").replace("SUMS", "S1"), ["SURV", "EXCS", "S1"], "", 256)
	GpuKernels.add(out, "scan0_k", GpuKernels.K_SCAN.replace("SRC", "KID").replace("DST", "EXCK").replace("SUMS", "S1"), ["KID", "EXCK", "S1"], "", 256)
	GpuKernels.add(out, "scan1", GpuKernels.K_SCAN.replace("SRC", "S1").replace("DST", "S1X").replace("SUMS", "S2"), ["S1", "S1X", "S2"], "", 256)
	GpuKernels.add(out, "scan2", GpuKernels.K_SCAN.replace("SRC", "S2").replace("DST", "S2X").replace("SUMS", "S3"), ["S2", "S2X", "S3"], "", 256)
	GpuKernels.add(out, "add2", GpuKernels.K_ADD.replace("DST", "S1X").replace("ADDEND", "S2X"), ["S1X", "S2X"], "", 256)
	GpuKernels.add(out, "add1_s", GpuKernels.K_ADD.replace("DST", "EXCS").replace("ADDEND", "S1X"), ["EXCS", "S1X"], "", 256)
	GpuKernels.add(out, "add1_k", GpuKernels.K_ADD.replace("DST", "EXCK").replace("ADDEND", "S1X"), ["EXCK", "S1X"], "", 256)
	GpuKernels.add(out, "finalize", K_FINALIZE, ["P", "CNT", "SURV", "KID", "EXCS", "EXCK"])
	GpuKernels.add(out, "compact", K_COMPACT, ["P", "CNT", "BUPS_V4U", "BUPS2_V4U", "CHILD_V4U", "SURV", "KID", "EXCS", "EXCK"])
	GpuKernels.add(out, "copy", K_COPY, ["CNT", "BUPS_V4U", "BUPS2_V4U"])
	GpuKernels.add(out, "setcount", K_SETCOUNT, ["CNT"])
	GpuKernels.add(out, "conj_clear", K_CONJ_CLEAR, ["CNT", "DTAB"], CONJ_FUNCS)
	GpuKernels.add(out, "conj_insert", K_CONJ_INSERT, ["P", "CNT", "BUPS", "DTAB"], CONJ_FUNCS)
	GpuKernels.add(out, "conj_apply", K_CONJ_APPLY, ["P", "CNT", "BUPS", "DTAB"], CONJ_FUNCS)
	_register_pool(out)


## The pooled world's kernels (see "the pooled world" above).
static func _register_pool(out: Dictionary) -> void:
	assert(GpuLayout.R_X / 4 == GpuLayout.R_Y / 4 and GpuLayout.D_MAX % 256 == 0, "pool_pip_scatter shifts x and y in one piece; pool_finalize splits the rows over 256 threads")
	var dn := dn_funcs()
	var conj := CONJ_FUNCS + dn + "#define CONJ_BUCKETS (%s)\n" % CONJ_BUCKETS_EXPR + POOL_CONJ_FUNCS
	var t := POOL_TYPES
	GpuKernels.add(out, "pool_conj_clear", K_POOL_CONJ_CLEAR, ["WORLD", "DSTATE", "DCNT", "DBIT"], dn + "#define CONJ_BUCKETS (%s)\n" % CONJ_BUCKETS_EXPR, 64, t)
	GpuKernels.add(out, "pool_conj_count", K_POOL_CONJ_COUNT, ["P", "BUPS", "WORLD", "BLKDISH", "DSTATE", "CBKT", "DCNT", "DBIT"], conj, 64, t)
	GpuKernels.add_grid_scan(out, "pool_conj_scan", "DCNT", "DOFF", "GSUM", "GOFF", CONJ_BUCKETS_EXPR.replace("CONJ_MIN_BUCKETS", "%du" % CONJ_MIN_BUCKETS), ["WORLD"])
	GpuKernels.add(out, "pool_conj_scatter", K_POOL_CONJ_SCATTER, ["WORLD", "BLKDISH", "DSTATE", "CBKT", "DOFF", "DLIST"], conj, 64, t)
	GpuKernels.add(out, "pool_conj_apply", K_POOL_CONJ_APPLY, ["P", "BUPS", "WORLD", "BLKDISH", "DSTATE", "DCNT", "DOFF", "DLIST", "DBIT"], conj, 64, t)
	GpuKernels.add(out, "pool_apply_count", pool_apply_count(), ["P", "WORLD", "BLKDISH", "DSTATE", "DISHP", "BUPS", "EFF", "WANT", "WANTC", "CELLOF", "SCALE", "ENTD", "BINS", "BINC", "PSCALE", "OWNER", "CONC", "CONC2B", "WANT2", "CELL2", "AWLO", "AWHI", "ADLO", "ADHI", "CLOUDC", "CBKT", "DCNT", "DBIT"],
		GpuKernels.FIXED_FUNCS + GpuKernelsField.POOL_READF + GpuKernelsClouds.POOL_CLOUD_FUNCS + conj, 64, t)
	GpuKernels.add(out, "pool_ac_conj_life", pool_ac_conj_life(), ["P", "BUPS", "CHILD", "SURV", "KID", "WORLD", "BLKDISH", "DSTATE", "DISHP", "WANT2", "CELL2", "SCALE2", "CBKT", "DCNT", "DOFF", "DLIST", "DBIT"], conj + FLAG_FUNC, 64, t)
	GpuKernels.add(out, "pool_donor_life", pool_donor_life(), ["P", "BUPS", "CHILD", "SURV", "KID", "WORLD", "BLKDISH", "DSTATE", "DISHP", "DOFF", "DLIST"], conj + FLAG_FUNC, 64, t)
	GpuKernels.add(out, "pool_life", pool_life(), ["P", "BUPS", "CHILD", "SURV", "KID", "WORLD", "BLKDISH", "DSTATE", "DISHP"], FLAG_FUNC)
	GpuKernels.add_grid_scan(out, "pool_scan_s", "SURV", "EXCS", "GSUM", "GOFF", "WORLD[WD_SLOTS]", ["WORLD"])
	GpuKernels.add_grid_scan(out, "pool_scan_k", "KID", "EXCK", "GSUM", "GOFF", "WORLD[WD_SLOTS]", ["WORLD"])
	GpuKernels.add(out, "pool_finalize", K_POOL_FINALIZE, ["SURV", "KID", "EXCS", "EXCK", "DSTATE", "DISHP", "DNEXT"], dn + FLAG_FUNC, 256, t)
	GpuKernels.add(out, "pool_blk_fill", K_POOL_BLK_FILL, ["DNEXT", "BLKDISH2"], dn, 64, t)
	GpuKernels.add(out, "pool_compact", K_POOL_COMPACT, ["BUPS_V4U", "BUPS2_V4U", "CHILD_V4U", "SURV", "KID", "EXCS", "EXCK", "WORLD", "BLKDISH", "DSTATE", "DNEXT"], dn, 64, t)
	GpuKernels.add(out, "pool_setcount", K_POOL_SETCOUNT, ["KID", "EXCK", "WORLD", "DSTATE", "DISHP", "DNEXT"], dn + FLAG_FUNC, 64, t)
	GpuKernels.add(out, "pool_pip_mark", K_POOL_PIP_MARK, ["BUPS_U", "SURV", "PIPDST", "WORLD", "BLKDISH", "DSTATE", "DNEXT"], dn + PIP_FUNCS, 64, t)
	GpuKernels.add(out, "pool_pip_final", K_POOL_PIP_FINAL, ["SURV", "EXCS", "DSTATE", "DISHP", "DNEXT"], dn + FLAG_FUNC + PIP_FUNCS, 256, t)
	GpuKernels.add(out, "pool_pip_scatter", K_POOL_PIP_SCATTER, ["BUPS_V4U", "BUPS2_V4U", "SURV", "EXCS", "WORLD", "BLKDISH", "DSTATE", "DNEXT"], dn + PIP_FUNCS, 64, t)
