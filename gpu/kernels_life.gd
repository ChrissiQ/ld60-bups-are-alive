class_name GpuKernelsLife
extends RefCounted
## The bups' lives (see gpu/kernels.gd for how a kernel is made and registered): conjugation, then division, death and mutation, the
## scans that give the kept bups and the newborns their places, the trim at the limit, and the move into those places.

## Division, death and mutation (the CPU's `step` after uptake and `mutate`), per bup. A bup dies of an empty reserve or by chance; one
## that has grown enough divides: the daughter, if not lethally mutated, is written into CHILD at the parent's index; SURV and KID mark
## who is kept and who has a child. A population that would pass the limit loses a random share each step (the CPU replaces a random bup at
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
void drift(inout float hue, inout float sat, inout float val, inout uint s) {  // (the colour is a neutral marker: every counted mutation moves it, as the CPU's note_mutation)
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
		// The mutation rate itself changes in jumps (see the CPU's mutate): a new mutator allele sets it to one of three folds, an antimutator halves it.
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

## Conjugation (see the CPU's BupSim::conjugate). The donors (R_DONOR) go into a hashed table of the 20 µm cells they stand in, four slots a cell, and the
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
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS]) return;
	uint b = i * RECORD_WORDS;
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
