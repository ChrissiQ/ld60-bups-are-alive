class_name GpuKernelsGame
extends RefCounted
## The game's side (see gpu/kernels.gd for how a kernel is made and registered): the family events, the stats, the frame's questions
## and answers, the eraser and the field's copy. The words of the frame's questions (QIN) and answers (OUT) are in gpu/gpu_layout.gd.

## The family events of a step (after `finalize`, before `compact`, which places the newborns: the same rule), one thread per bup, into
## event set `pcs.pb`, the step's place in the batch `pcs.pa`: each kept newborn is a birth at CNT_BIRTHS + its place among the newborns,
## each bup not kept a death at CNT_DEATHS + its place among those; so the order is the bups' order, whatever order the threads run in.
const K_EVENTS := """
void main() {
	BUP_THREAD
	uint cap = uint(P[P_EVENT_CAPACITY]), base = uint(pcs.pb) * cap, st = uint(pcs.pa);
	uint b = i * RECORD_WORDS;
	if (KID[i] == 1u && CNT[CNT_SURVIVORS] + EXCK[i] < uint(P[P_CAPACITY])) {  // (a newborn `compact` will place)
		uint slot = CNT[CNT_BIRTHS] + EXCK[i];
		if (slot < cap) {
			uint o = (base + slot) * BIRTH_WORDS, c = i * RECORD_WORDS;
			uint lo = CNT[CNT_NEXT_ID_LO] + EXCK[i];
			EVB[o + EB_ID_LO] = lo; EVB[o + EB_ID_HI] = CNT[CNT_NEXT_ID_HI] + (lo < CNT[CNT_NEXT_ID_LO] ? 1u : 0u);
			EVB[o + EB_PARENT_LO] = BUPS_U[b + R_ID_LO]; EVB[o + EB_PARENT_HI] = BUPS_U[b + R_ID_HI]; EVB[o + EB_STEP] = st;
			EVB[o + EB_DIVISIONS] = uint(uintBitsToFloat(CHILD_U[c + R_DIVISIONS])); EVB[o + EB_TRAITS] = (uint(uintBitsToFloat(CHILD_U[c + R_MUTATIONS])) & EV_LOW_MASK) | ((uint(uintBitsToFloat(CHILD_U[c + R_REACH]) + 0.5) & EV_REACH_MASK) << EV_REACH_SHIFT) | (uintBitsToFloat(CHILD_U[c + R_DONOR]) > 0.5 ? (1u << EV_DONOR_SHIFT) : 0u);
			EVB[o + EB_SPEED] = CHILD_U[c + R_SPEED]; EVB[o + EB_SENSE] = CHILD_U[c + R_SENSE]; EVB[o + EB_METABOLISM] = CHILD_U[c + R_METABOLISM]; EVB[o + EB_SIZE] = CHILD_U[c + R_SIZE];
			EVB[o + EB_HUE] = CHILD_U[c + R_HUE]; EVB[o + EB_SAT] = CHILD_U[c + R_SAT]; EVB[o + EB_VAL] = CHILD_U[c + R_VAL]; EVB[o + EB_HARM] = CHILD_U[c + R_HARM];
			EVB[o + EB_MUTATOR] = CHILD_U[c + R_MUTATOR];
		} else atomicAdd(CNT[CNT_BIRTHS_LOST], 1u);
	}
	if (SURV[i] == 0u) {
		uint slot = CNT[CNT_DEATHS] + (i - EXCS[i]);  // (the bups not kept before this one)
		if (slot < cap) {
			uint o = (base + slot) * DEATH_WORDS;
			EVD[o + ED_ID_LO] = BUPS_U[b + R_ID_LO]; EVD[o + ED_ID_HI] = BUPS_U[b + R_ID_HI]; EVD[o + ED_STEP] = st; EVD[o + ED_TRAITS] = (uint(uintBitsToFloat(BUPS_U[b + R_DIVISIONS])) & EV_LOW_MASK) | ((uint(uintBitsToFloat(BUPS_U[b + R_REACH]) + 0.5) & EV_REACH_MASK) << EV_REACH_SHIFT) | (uintBitsToFloat(BUPS_U[b + R_DONOR]) > 0.5 ? (1u << EV_DONOR_SHIFT) : 0u);
			EVD[o + ED_MASS] = BUPS_U[b + R_MASS]; EVD[o + ED_X] = BUPS_U[b + R_X]; EVD[o + ED_Y] = BUPS_U[b + R_Y];
			EVD[o + ED_GIVES] = uintBitsToFloat(BUPS_U[b + R_PY]) == -2.0 ? floatBitsToUint(P[P_DEATH_GIVE] * uintBitsToFloat(BUPS_U[b + R_MASS])) : 0u;  // (where it died and what it gives back: 0 for a trimmed one)
			EVD[o + ED_ENERGY] = BUPS_U[b + R_ENERGY]; EVD[o + ED_BIRTH_MASS] = BUPS_U[b + R_BIRTH_MASS];  // (its own energy, and the mass it was born with)
			EVD[o + ED_SPEED] = BUPS_U[b + R_SPEED]; EVD[o + ED_SENSE] = BUPS_U[b + R_SENSE]; EVD[o + ED_METABOLISM] = BUPS_U[b + R_METABOLISM]; EVD[o + ED_SIZE] = BUPS_U[b + R_SIZE];  // (its genes as it died)
		} else atomicAdd(CNT[CNT_DEATHS_LOST], 1u);
	}
}
"""

## Stats of the bups now, in two passes of fixed order (so a sample is the same every run): sums over groups of 256 bups into SPART,
## then one group sums those (`pcs.pa` of them) into OUT at word `pcs.pb`, with the step `pcs.pc`.
const K_STATS1 := """
const int SUMS = int(STATS_SUMS);
shared float sm[SUMS * 256];
void main() {
	uint i = gl_GlobalInvocationID.x, l = gl_LocalInvocationID.x;
	float v[SUMS];
	for (int k = 0; k < SUMS; k++) v[k] = 0.0;
	if (i < CNT[CNT_BUPS]) {
		uint b = i * RECORD_WORDS;
		float h = BUPS[b + R_HARM];
		v[0] = 1.0; v[1] = BUPS[b + R_SPEED]; v[2] = BUPS[b + R_SENSE]; v[3] = BUPS[b + R_METABOLISM]; v[4] = BUPS[b + R_SIZE];
		v[5] = h < 0.1 ? h * (1.0 - h * (0.5 - h * (0.16666667 - h * 0.041666668))) : 1.0 - exp(-h);  // (1 - exp(-h) without the loss of a small h's digits)
		v[6] = BUPS[b + R_MUTATIONS]; v[7] = BUPS[b + R_MUTATOR];
		v[8] = ((int(BUPS[b + R_REACH] + 0.5) >> 8) & 3) == 2 ? 1.0 : 0.0;  // (the bups with the acetate key)
		v[9] = BUPS[b + R_DIVISIONS];
		v[10] = BUPS[b + R_DONOR];  // (1 for a donor, 0 for the rest)
	}
	for (int k = 0; k < SUMS; k++) sm[k * 256 + int(l)] = v[k];
	barrier();
	for (uint half_ = 128u; half_ > 0u; half_ >>= 1u) {
		if (l < half_) for (int k = 0; k < SUMS; k++) sm[k * 256 + int(l)] += sm[k * 256 + int(l + half_)];
		barrier();
	}
	if (l == 0u) for (int k = 0; k < SUMS; k++) SPART[gl_WorkGroupID.x * STATS_SUMS + uint(k)] = sm[k * 256];
}
"""

const K_STATS2 := """
const int SUMS = int(STATS_SUMS);
shared float sm[SUMS * 256];
void main() {
	uint l = gl_LocalInvocationID.x, groups = uint(pcs.pa);
	float v[SUMS];
	for (int k = 0; k < SUMS; k++) v[k] = 0.0;
	for (uint g = l; g < groups; g += 256u) for (int k = 0; k < SUMS; k++) v[k] += SPART[g * STATS_SUMS + uint(k)];
	for (int k = 0; k < SUMS; k++) sm[k * 256 + int(l)] = v[k];
	barrier();
	for (uint half_ = 128u; half_ > 0u; half_ >>= 1u) {
		if (l < half_) for (int k = 0; k < SUMS; k++) sm[k * 256 + int(l)] += sm[k * 256 + int(l + half_)];
		barrier();
	}
	if (l == 0u) {
		uint o = uint(pcs.pb);
		OUT[o + ST_COUNT] = floatBitsToUint(float(CNT[CNT_BUPS]));  // (the count exactly, not summed)
		for (uint k = ST_SPEED; k <= ST_MUTATIONS; k++) OUT[o + k] = floatBitsToUint(sm[k * 256u]);  // (sums 1 to 6 are in the sample's order)
		OUT[o + ST_STEP] = floatBitsToUint(pcs.pc);
		OUT[o + ST_MUTATOR] = floatBitsToUint(sm[7 * 256]);  // (the mutator's sum)
		OUT[o + ST_DONORS] = uint(sm[10 * 256] + 0.5);  // (the donors' count: of the bups now, not of the last step)
		OUT[o + ST_KEY] = floatBitsToUint(sm[8 * 256]);  // (the key's count)
		OUT[o + ST_DIVISIONS] = floatBitsToUint(sm[9 * 256]);  // (the divisions' sum)
		for (uint k = ST_DIVISIONS + 1u; k < STATS_WORDS; k++) OUT[o + k] = 0u;
	}
}
"""

## The eraser: each disc of ERASE (x, y, radius, strength; `pcs.pa` of them, in order) takes from the cells
## inside the dish whose centres lie within it, and from the clouds whose centres do, the share strength * (1 - d / radius).
const K_ERASE_CELLS := """
void main() {
	uint i = gl_GlobalInvocationID.x; int n = int(P[P_CELLS]);
	if (i >= uint(n * n) || INSIDE[i] == 0) return;
	float cx = (float(int(i) % n) + 0.5) * P[P_SPACING] - P[P_ORIGIN], cy = (float(int(i) / n) + 0.5) * P[P_SPACING] - P[P_ORIGIN];
	float c = CONC[i];
	for (int e = 0; e < int(pcs.pa); e++) {
		vec4 d = ERASE[e];
		float dist = sqrt((cx - d.x) * (cx - d.x) + (cy - d.y) * (cy - d.y));
		if (dist < d.z) c -= c * d.w * (1.0 - dist / d.z);
	}
	CONC[i] = c;
}
"""

const K_ERASE_PUFFS := """
void main() {
	uint k = gl_GlobalInvocationID.x; if (k >= PCNT[PCNT_SLOTS]) return;
	uint o = k * 8u;
	if (PUFF[o + 5u] < 0.5) return;
	float m = PUFF[o + 2u];
	for (int e = 0; e < int(pcs.pa); e++) {
		vec4 d = ERASE[e];
		float dist = sqrt((PUFF[o] - d.x) * (PUFF[o] - d.x) + (PUFF[o + 1u] - d.y) * (PUFF[o + 1u] - d.y));
		if (dist < d.z) m -= m * d.w * (1.0 - dist / d.z);
	}
	PUFF[o + 2u] = m;
}
"""


# ---- the pooled world (see gpu/kernels_life.gd, "the pooled world", for the step's order and DNEXT) -----------------------------------

## Before a batch: every dish's births, deaths and moves of the batch start from 0 (before a retarget pass, which counts its moves).
const K_POOL_EV_BEGIN := """
void ev_begin(uint d) { DS(d, DS_BIRTHS) = 0u; DS(d, DS_DEATHS) = 0u; DS(d, DS_MOVED_IN) = 0u; DS(d, DS_MOVED_OUT) = 0u; }
GRID_LOOP(ev_begin, D_MAX)
"""


## `events` for the pool (after pool_finalize, before pool_compact), one pass over the bups: a dish's births and deaths of the step go to
## the event ring from the places pool_finalize gave the dish, in the order of its bups; a birth and a death carry the number of the dish they happened
## in; a newborn's id is the world's next id plus its rank among the pool's newborns.
static func pool_events() -> String:
	var t := GpuKernelsLife.swapped(K_EVENTS, "void main() {\n\tBUP_THREAD\n", "void event_bup(uint i, uint d, uint l) {\n\tuint kid = EXCK[i] - DN(d, DN_KID_BASE);\n")
	t = GpuKernelsLife.swapped(t, "CNT[CNT_SURVIVORS] + EXCK[i] < uint(P[P_CAPACITY])", "DS(d, DS_SURVIVORS) + kid < DS(d, DS_NEXT_COUNT)")  # (DP_CAP's cut, and pool_slot_check's)
	t = GpuKernelsLife.swapped(t, "CNT[CNT_BIRTHS] + EXCK[i]", "DN(d, DN_BIRTH_BASE) + kid")
	t = GpuKernelsLife.swapped(t, "CNT[CNT_NEXT_ID_LO] + EXCK[i]", "WORLD[WD_NEXT_ID_LO] + EXCK[i]")
	t = GpuKernelsLife.swapped(t, "CNT[CNT_NEXT_ID_HI] + (lo < CNT[CNT_NEXT_ID_LO]", "WORLD[WD_NEXT_ID_HI] + (lo < WORLD[WD_NEXT_ID_LO]")
	t = GpuKernelsLife.swapped(t, "atomicAdd(CNT[CNT_BIRTHS_LOST], 1u)", "atomicAdd(DS(d, DS_BIRTHS_LOST), 1u)")
	t = GpuKernelsLife.swapped(t, "CNT[CNT_DEATHS] + (i - EXCS[i])", "DN(d, DN_DEATH_BASE) + (l - (EXCS[i] - DN(d, DN_SURV_BASE)))")
	t = GpuKernelsLife.swapped(t, "EVB[o + EB_STEP] = st;", "EVB[o + EB_STEP] = (DPU(d, DP_NUMBER) << EV_DISH_SHIFT) | (st & EV_STEP_MASK);")
	t = GpuKernelsLife.swapped(t, "EVD[o + ED_STEP] = st;", "EVD[o + ED_STEP] = (DPU(d, DP_NUMBER) << EV_DISH_SHIFT) | (st & EV_STEP_MASK);")
	t = GpuKernelsLife.swapped(t, "atomicAdd(CNT[CNT_DEATHS_LOST], 1u)", "atomicAdd(DS(d, DS_DEATHS_LOST), 1u)")
	assert(not t.contains("CNT["), "pool_events must not read CNT")
	return t + "BUP_LOOP(event_bup)\n"


## `stats1` for the pool: the sums of each block of BLK_SLOTS slots (a block is one dish's) into SPART at the block's place.
static func pool_stats1() -> String:
	var t := GpuKernelsLife.swapped(K_STATS1, "void main() {\n\tuint i = gl_GlobalInvocationID.x, l = gl_LocalInvocationID.x;", "void stats_block(uint blk, uint d) {\n\tuint l = gl_LocalInvocationID.x, i = (blk << BLK_SHIFT) + l;")
	t = GpuKernelsLife.swapped(t, "if (i < CNT[CNT_BUPS]) {", "if (d != NO_DISH && i - DS(d, DS_START) < DS(d, DS_COUNT)) {")
	t = GpuKernelsLife.swapped(t, "SPART[gl_WorkGroupID.x * STATS_SUMS", "SPART[blk * STATS_SUMS")
	assert(not t.contains("CNT["), "pool_stats1 must not read CNT")
	return t + "BLOCK_LOOP(stats_block)\n"


## `stats2` for the pool: one group for each running dish sums its blocks' partial sums in the order of its bups, as the template
## K_STATS2 does for one dish, into the dish's row of STATS as sample `pcs.pb` (STATS_WORDS words each, STATS_DISH_WORDS a dish), taken after step
## `pcs.pc`. Only the blocks the dish's bups fill are summed, so a dish's sums are its own alone.
static func pool_stats2() -> String:
	var t := GpuKernelsLife.swapped(K_STATS2, "void main() {\n\tuint l = gl_LocalInvocationID.x, groups = uint(pcs.pa);", "void stats_dish(uint d) {\n\tuint l = gl_LocalInvocationID.x, first = DS(d, DS_START) >> BLK_SHIFT, groups = (DS(d, DS_COUNT) + BLK_SLOTS - 1u) >> BLK_SHIFT;")
	t = GpuKernelsLife.swapped(t, "SPART[g * STATS_SUMS", "SPART[(first + g) * STATS_SUMS")
	t = GpuKernelsLife.swapped(t, "uint o = uint(pcs.pb);", "uint o = d * STATS_DISH_WORDS + uint(pcs.pb) * STATS_WORDS;")
	t = GpuKernelsLife.swapped(t, "float(CNT[CNT_BUPS])", "float(DS(d, DS_COUNT))")
	t = t.replace("OUT[", "STATS[")
	assert(not t.contains("CNT[") and not t.contains("OUT["), "pool_stats2 must not read CNT or write OUT")
	return t + "void main() {\n\tfor (uint d = gl_WorkGroupID.x; d < D_MAX; d += gl_NumWorkGroups.x) {\n\t\tif (FLAG(d, DPF_RUNNING)) stats_dish(d);\n\t\tbarrier();\n\t}\n}\n"


## Adds these kernels to `out` (see GpuKernels.all()).
static func register(out: Dictionary) -> void:
	var dn := GpuKernelsLife.dn_funcs() + GpuKernelsLife.FLAG_FUNC
	GpuKernels.add(out, "pool_ev_begin", K_POOL_EV_BEGIN, ["DSTATE"])
	GpuKernels.add(out, "pool_events", pool_events(), ["P", "BUPS_U", "CHILD_U", "SURV", "KID", "EXCS", "EXCK", "EVB", "EVD", "WORLD", "BLKDISH", "DSTATE", "DISHP", "DNEXT"], dn, 64, GpuKernelsLife.POOL_TYPES)
	GpuKernels.add(out, "pool_stats1", pool_stats1(), ["BUPS", "SPART", "WORLD", "BLKDISH", "DSTATE"], "", 256)
	GpuKernels.add(out, "pool_stats2", pool_stats2(), ["SPART", "STATS", "DSTATE", "DISHP"], GpuKernelsLife.FLAG_FUNC, 256, {"STATS": "uint"})
