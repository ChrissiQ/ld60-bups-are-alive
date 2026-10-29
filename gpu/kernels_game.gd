class_name GpuKernelsGame
extends RefCounted
## The game's side (see gpu/kernels.gd for how a kernel is made and registered): the family events, the stats, the frame's questions
## and answers, the eraser and the field's copy. The words of the frame's questions (QIN) and answers (OUT) are in gpu/gpu_layout.gd.

## Before a batch: its counts of births and deaths start from 0.
const K_EV_BEGIN := """
void main() { if (gl_GlobalInvocationID.x == 0u) { CNT[CNT_BIRTHS] = 0u; CNT[CNT_DEATHS] = 0u; } }
"""

## The family events of a step (after `finalize`, before `compact`, which places the newborns: the same rule), one thread per bup, into
## event set `pcs.pb`, the step's place in the batch `pcs.pa`: each kept newborn is a birth at CNT_BIRTHS + its place among the newborns,
## each bup not kept a death at CNT_DEATHS + its place among those; so the order is the bups' order, whatever order the threads run in.
const K_EVENTS := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS]) return;
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

## After `copy`, before `setcount`: the step's births (those placed: CNT_NEXT_COUNT - CNT_SURVIVORS) and deaths (CNT_BUPS - CNT_SURVIVORS) are added to the batch's
## counts, which are kept for event set `pcs.pb` too.
const K_EV_COUNT := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;
	CNT[CNT_BIRTHS] += CNT[CNT_NEXT_COUNT] - CNT[CNT_SURVIVORS]; CNT[CNT_DEATHS] += CNT[CNT_BUPS] - CNT[CNT_SURVIVORS];
	uint s = uint(pcs.pb);
	EVN[s * 2u] = CNT[CNT_BIRTHS]; EVN[s * 2u + 1u] = CNT[CNT_DEATHS];
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
		OUT[o + ST_DONORS] = uint(sm[10 * 256] + 0.5);  // (the donors' count: of the bups now, as the CPU's population_stats, not of the last step)
		OUT[o + ST_KEY] = floatBitsToUint(sm[8 * 256]);  // (the key's count)
		OUT[o + ST_DIVISIONS] = floatBitsToUint(sm[9 * 256]);  // (the divisions' sum)
		for (uint k = ST_DIVISIONS + 1u; k < STATS_WORDS; k++) OUT[o + k] = 0u;
	}
}
"""

## The frame's answers start empty, and CNT and PCNT are copied (one thread per word of QOUT, and of the head).
const K_Q_CLEAR := """
void main() {
	uint t = gl_GlobalInvocationID.x;
	if (t < CNT_WORDS) OUT[OUT_CNT + t] = CNT[t];
	else if (t < CNT_WORDS + PCNT_WORDS) OUT[OUT_PCNT + t - CNT_WORDS] = PCNT[t - CNT_WORDS];
	if (t >= QOUT_WORDS) return;
	uint q = OUT_Q + t;
	uint v = 0u;
	if (t == QO_INDEX || t == QO_D2 || t == QO_NEAR) v = 0xFFFFFFFFu;  // (no pick; d² past any, for atomicMin)
	if (t >= QO_TRACKED && t < QO_TRACKED + TRACKED * ANSWER_WORDS) { uint w = (t - QO_TRACKED) % ANSWER_WORDS; if (w == R_ID_LO || w == R_ID_HI) v = 0xFFFFFFFFu; }  // (a tracked bup not found)
	if (t >= QO_NEAR_MORE && t < QO_NEAR_MORE + 2u * (NEAR_SLOTS - 1u) && (t - QO_NEAR_MORE) % 2u == 0u) v = 0xFFFFFFFFu;
	OUT[q] = v;
}
"""

## The pick (BupSim.pick_bup's rule: within half its drawn length plus the slack, the nearest; ties to the smaller index): the least d²
## by atomicMin on its bits (they order as the floats do, for d² >= 0), each bup's own kept in QD for the second pass.
const K_Q_PICK := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS] || QIN[Q_PICK] == 0u) return;
	uint b = i * RECORD_WORDS;
	float px = uintBitsToFloat(QIN[Q_PICK_X]), py = uintBitsToFloat(QIN[Q_PICK_Y]), slack = uintBitsToFloat(QIN[Q_SLACK]), pixel = uintBitsToFloat(QIN[Q_PIXEL]);
	float reach = 0.5 * max(BUPS[b + R_MASS] * P[P_MASS_UM], P[P_MIN_LENGTH_PX] * pixel) + slack;
	float dx = BUPS[b + R_X] - px, dy = BUPS[b + R_Y] - py;
	float d2 = dx * dx + dy * dy;
	uint bits = 0xFFFFFFFFu;
	if (d2 <= reach * reach) { bits = floatBitsToUint(d2); atomicMin(OUT[OUT_Q + QO_D2], bits); }
	QD[i] = bits;
}
"""

const K_Q_PICK2 := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS] || QIN[Q_PICK] == 0u) return;
	if (QD[i] != 0xFFFFFFFFu && QD[i] == OUT[OUT_Q + QO_D2]) atomicMin(OUT[OUT_Q + QO_INDEX], i);
}
"""

## The picked bup's record (ANSWER_WORDS threads), and every tracked bup's (one thread per bup: the one with that id copies its record).
const K_Q_RECORD := """
void main() {
	uint t = gl_GlobalInvocationID.x; if (t >= ANSWER_WORDS) return;
	uint k = OUT[OUT_Q + QO_INDEX];
	if (k != 0xFFFFFFFFu) OUT[OUT_Q + QO_RECORD + t] = BUPS_U[k * RECORD_WORDS + t];
}
"""

const K_Q_TRACK := """
void main() {
	uint i = gl_GlobalInvocationID.x; if (i >= CNT[CNT_BUPS]) return;
	uint n = QIN[Q_TRACK]; if (n == 0u) return;
	uint b = i * RECORD_WORDS, lo = BUPS_U[b + R_ID_LO], hi = BUPS_U[b + R_ID_HI];
	for (uint t = 0u; t < n; t++) {
		if (QIN[Q_TRACK_FIRST + 2u * t] == lo && QIN[Q_TRACK_FIRST + 1u + 2u * t] == hi) {
			uint o = OUT_Q + QO_TRACKED + t * ANSWER_WORDS;
			for (uint w = 0u; w < ANSWER_WORDS; w++) OUT[o + w] = BUPS_U[b + w];
		}
	}
}
"""

## The nearest bup and the count within `near` for each nearest slot, and the count at or above each fraction's threshold: summed (and the
## least found) in each group of 256 first, then one atomic per group.
const K_Q_SCAN := """
shared uint smin[NEAR_SLOTS * 256u];
shared uint scnt[(NEAR_SLOTS + FRACTIONS) * 256u];
void main() {
	uint i = gl_GlobalInvocationID.x, l = gl_LocalInvocationID.x;
	uint nn = QIN[Q_NEAR], nf = QIN[Q_FRAC];
	bool live = i < CNT[CNT_BUPS];
	uint b = i * RECORD_WORDS;
	float x = live ? BUPS[b + R_X] : 0.0, y = live ? BUPS[b + R_Y] : 0.0;
	for (uint s = 0u; s < NEAR_SLOTS; s++) {
		uint m = 0xFFFFFFFFu, c = 0u;
		if (live && s < nn) {
			float qx = uintBitsToFloat(QIN[Q_NEAR_FIRST + 3u * s]), qy = uintBitsToFloat(QIN[Q_NEAR_FIRST + 1u + 3u * s]), near = uintBitsToFloat(QIN[Q_NEAR_FIRST + 2u + 3u * s]);
			float dx = x - qx, dy = y - qy, d2 = dx * dx + dy * dy;
			m = floatBitsToUint(d2);
			c = d2 <= near * near ? 1u : 0u;
		}
		smin[s * 256u + l] = m; scnt[s * 256u + l] = c;
	}
	for (uint f = 0u; f < FRACTIONS; f++) {
		uint c = 0u;
		if (live && f < nf) c = BUPS[b + R_SPEED + QIN[Q_FRAC_FIRST + 2u * f]] >= uintBitsToFloat(QIN[Q_FRAC_FIRST + 1u + 2u * f]) ? 1u : 0u;
		scnt[(NEAR_SLOTS + f) * 256u + l] = c;
	}
	barrier();
	for (uint half_ = 128u; half_ > 0u; half_ >>= 1u) {
		if (l < half_) {
			for (uint s = 0u; s < NEAR_SLOTS; s++) smin[s * 256u + l] = min(smin[s * 256u + l], smin[s * 256u + l + half_]);
			for (uint k = 0u; k < NEAR_SLOTS + FRACTIONS; k++) scnt[k * 256u + l] += scnt[k * 256u + l + half_];
		}
		barrier();
	}
	if (l == 0u) {
		for (uint s = 0u; s < nn; s++) {
			uint od = s == 0u ? OUT_Q + QO_NEAR : OUT_Q + QO_NEAR_MORE + 2u * (s - 1u);
			if (smin[s * 256u] != 0xFFFFFFFFu) atomicMin(OUT[od], smin[s * 256u]);
			if (scnt[s * 256u] > 0u) atomicAdd(OUT[od + 1u], scnt[s * 256u]);
		}
		for (uint f = 0u; f < nf; f++) if (scnt[(NEAR_SLOTS + f) * 256u] > 0u) atomicAdd(OUT[OUT_Q + QO_FRAC + f], scnt[(NEAR_SLOTS + f) * 256u]);
	}
}
"""

## The eraser (NutrientField::erase_disc): each disc of ERASE (x, y, radius, strength; `pcs.pa` of them, in order) takes from the cells
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

## A copy of OUT's first `pcs.pa` words to OUTK from word `pcs.pb` (the batch's event set's copy).
const K_OUT_KEEP := """
void main() { uint t = gl_GlobalInvocationID.x; if (t >= uint(pcs.pa)) return; OUTK[uint(pcs.pb) + t] = OUT[t]; }
"""

## The field's copy for the CPU (NutrientField.import_packed): MIRROR[0] the slots in use, then 5 floats per slot for the first `pcs.pa`
## slots (x, y, mass, variance, cut; all 0 for a slot that holds no cloud, which import_packed passes over).
const K_MIRROR := """
void main() {
	uint k = gl_GlobalInvocationID.x; if (k >= uint(pcs.pa)) return;
	if (k == 0u) MIRROR[0] = float(PCNT[PCNT_SLOTS]);
	uint o = 1u + k * 5u, q = k * 8u;
	bool live = k < PCNT[PCNT_SLOTS] && PUFF[q + 5u] > 0.5;
	MIRROR[o] = live ? PUFF[q] : 0.0; MIRROR[o + 1u] = live ? PUFF[q + 1u] : 0.0; MIRROR[o + 2u] = live ? PUFF[q + 2u] : 0.0;
	MIRROR[o + 3u] = live ? PUFF[q + 3u] : 0.0; MIRROR[o + 4u] = live ? PUFF[q + 4u] : 0.0;
}
"""


## Adds these kernels to `out` (see GpuKernels.all()).
static func register(out: Dictionary) -> void:
	GpuKernels.add(out, "ev_begin", K_EV_BEGIN, ["CNT"])
	GpuKernels.add(out, "events", K_EVENTS, ["P", "CNT", "BUPS_U", "CHILD_U", "SURV", "KID", "EXCS", "EXCK", "EVB", "EVD"])
	GpuKernels.add(out, "ev_count", K_EV_COUNT, ["CNT", "EVN"])
	GpuKernels.add(out, "stats1", K_STATS1, ["CNT", "BUPS", "SPART"], "", 256)
	GpuKernels.add(out, "stats2", K_STATS2, ["CNT", "SPART", "OUT"], "", 256)
	GpuKernels.add(out, "q_clear", K_Q_CLEAR, ["CNT", "PCNT", "OUT"])
	GpuKernels.add(out, "q_pick", K_Q_PICK, ["P", "CNT", "BUPS", "QIN", "QD", "OUT"])
	GpuKernels.add(out, "q_pick2", K_Q_PICK2, ["CNT", "QIN", "QD", "OUT"])
	GpuKernels.add(out, "q_record", K_Q_RECORD, ["BUPS_U", "OUT"])
	GpuKernels.add(out, "q_track", K_Q_TRACK, ["CNT", "BUPS_U", "QIN", "OUT"])
	GpuKernels.add(out, "q_scan", K_Q_SCAN, ["CNT", "BUPS", "QIN", "OUT"], "", 256)
	GpuKernels.add(out, "erase_cells", K_ERASE_CELLS, ["P", "INSIDE", "CONC", "ERASE"])
	GpuKernels.add(out, "erase_puffs", K_ERASE_PUFFS, ["PCNT", "PUFF", "ERASE"])
	GpuKernels.add(out, "mirror", K_MIRROR, ["PCNT", "PUFF", "MIRROR"])
	GpuKernels.add(out, "out_keep", K_OUT_KEEP, ["OUT", "OUTK"])
