class_name GpuKernelsCore
extends RefCounted
## The pooled world's host operations as kernels (SimCore, scripts/sim/sim_core.gd; see gpu/kernels.gd for how a kernel is made): a
## dish's clouds and husks leaving with it, the field edits (a drop of nutrient, the eraser), the check that a step's next layout fits the
## record slots, the goals' question, the ids of a run of records, the tracked bups' records and their places as probe points, and the
## copies of the published pictures into the shared textures.

## The clouds and husks of dish row `pcs.pa` leave the pool (its row is about to be another dish's): their slots become empty, and the
## next compaction or cull drops them.
const K_ROW_CLEAR := """
void f(uint k) {
	uint word = PUFF_ROW_BASE + uint(pcs.pa);
	if (k < WORLD[WD_CLOUD_SLOTS] && floatBitsToUint(PUFF[k * 8u + 5u]) == word) PUFF[k * 8u + 5u] = 0.0;
	if (k < WORLD[WD_HUSK_SLOTS] && floatBitsToUint(HUSK[k * 8u + 5u]) == word) { HUSK[k * 8u + 5u] = 0.0; HUSK[k * 8u + 6u] = 0.0; }
}
GRID_LOOP(f, max(WORLD[WD_CLOUD_SLOTS], WORLD[WD_HUSK_SLOTS]))
"""

## Nutrient dropped on cells (EDC: pool cells, EDA: concentrations, `pcs.pa` of them), one thread, in order (a cell may come twice).
const K_EDIT_CELLS := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;
	for (uint k = 0u; k < uint(pcs.pa); k++) CONC[uint(EDC[k])] += EDA[k];
}
"""

## The eraser on dish row `pcs.pa` a disc at (pcs.pb, pcs.pc) of radius ERASE's x and strength its y takes
## from each cell inside the dish whose centre lies within it, and from each of the dish's clouds whose centre does, the share
## strength x (1 - d / radius).
const K_ERASE_CELLS := """
void f(uint c, uint d, uint l) {
	if (d != uint(pcs.pa) || INSIDE[c] == 0) return;
	int n = int(DPU(d, DP_CELLS)); float sp = DPF(d, DP_SPACING), org = DPF(d, DP_RADIUS);
	float cx = (float(int(l) % n) + 0.5) * sp - org, cy = (float(int(l) / n) + 0.5) * sp - org;
	float r = EDA[0], s = EDA[1];
	float dist = sqrt((cx - pcs.pb) * (cx - pcs.pb) + (cy - pcs.pc) * (cy - pcs.pc));
	if (dist < r) CONC[c] -= CONC[c] * s * (1.0 - dist / r);
}
CELL_LOOP(f, WORLD[WD_CELLS])
"""

const K_ERASE_PUFFS := """
void f(uint k) {
	uint o = k * 8u;
	if (floatBitsToUint(PUFF[o + 5u]) != PUFF_ROW_BASE + uint(pcs.pa)) return;
	float r = EDA[0], s = EDA[1];
	float dist = sqrt((PUFF[o] - pcs.pb) * (PUFF[o] - pcs.pb) + (PUFF[o + 1u] - pcs.pc) * (PUFF[o + 1u] - pcs.pc));
	if (dist < r) PUFF[o + 2u] -= PUFF[o + 2u] * s * (1.0 - dist / r);
}
GRID_LOOP(f, WORLD[WD_CLOUD_SLOTS])
"""

## After pool_finalize or pool_pip_final: the next layout must fit the record slots (WD_SLOT_CAPACITY). The host's bound keeps it so; if
## it ever does not, this raises the overflow flag and cuts every segment that passes the capacity down to what is left of it (a dish
## past it keeps none), so that the block table, the compaction or the retarget and every later loop stay inside the buffers (they place
## a dish's bups only below its DS_NEXT_COUNT). The bups cut are lost, without events: the flag stays, the run is not the dishes' own.
const K_SLOT_CHECK := """
void main() {
	if (gl_GlobalInvocationID.x != 0u) return;
	uint total = DNEXT[DN_TOTAL_WORD], cap = WORLD[WD_SLOT_CAPACITY] & ~(BLK_SLOTS - 1u);
	if (total <= cap) return;
	WORLD[WD_OVERFLOW] = 1u;
	for (uint d = 0u; d < D_MAX; d++) {
		uint at = DN(d, DN_START), size = DN(d, DN_SIZE), room = at < cap ? cap - at : 0u;
		if (size <= room) continue;
		DN(d, DN_SIZE) = room; DS(d, DS_NEXT_COUNT) = min(DS(d, DS_NEXT_COUNT), room); DS(d, DS_OVERFLOW) = 1u;
	}
	DNEXT[DN_TOTAL_WORD] = cap;
}
"""

## The goals' question for dish row `pcs.pb`: how many of its bups hold record word `pcs.pa` (a gene,
## R_SPEED + g) at or above `pcs.pc` (the threshold as the host rounds it up to a float), counted into FRQ[`pcs.pd`]. An integer count, so
## the share the host works out from it does not depend on the order the threads run in.
const K_FRACTION := """
void f(uint i, uint d, uint l) {
	if (d == uint(pcs.pb) && BUPS[i * RECORD_WORDS + uint(pcs.pa)] >= pcs.pc) atomicAdd(FRQ[uint(pcs.pd)], 1u);
}
BUP_LOOP(f)
"""

## The ids of `pcs.pb` records from slot `pcs.pa` on, as (low word, high word) pairs from CHILD's start: what SimCore reads for a dish's
## live ids and a pipette's moved ids (8 bytes a bup instead of its record). CHILD holds a step's newborns only within the step, so between
## iterations it is free.
const K_IDS := """
void f(uint k) {
	uint b = (uint(pcs.pa) + k) * RECORD_WORDS;
	CHILD_U[k * 2u] = BUPS_U[b + R_ID_LO];
	CHILD_U[k * 2u + 1u] = BUPS_U[b + R_ID_HI];
}
GRID_LOOP(f, uint(pcs.pb))
"""

## The tracked bups' records of set `pcs.pb` among dish row `pcs.pa`'s bups (its segment as DSTATE has it when the kernel runs, so it may
## follow the steps in their list, and only that dish's bups are found). The set's TQ words: how many ids (up to TRACKED), then each id's
## low and high word. The bup with an id copies its first ANSWER_WORDS words into the set's TR (ANSWER_WORDS words an id, in TQ's order);
## the host fills TR's id words with 0xFFFFFFFF first, and they stay so where the id is not found.
const K_TRACK := """
void f(uint k) {
	uint d = uint(pcs.pa), q = uint(pcs.pb) * TQ_WORDS, r = uint(pcs.pb) * TRACKED * ANSWER_WORDS;
	uint n = min(TQ[q], TRACKED);
	uint b = (DS(d, DS_START) + k) * RECORD_WORDS, lo = BUPS_U[b + R_ID_LO], hi = BUPS_U[b + R_ID_HI];
	for (uint t = 0u; t < n; t++) {
		if (TQ[q + 1u + 2u * t] == lo && TQ[q + 2u + 2u * t] == hi) {
			for (uint w = 0u; w < ANSWER_WORDS; w++) TR[r + t * ANSWER_WORDS + w] = BUPS_U[b + w];
			BEFORE
		}
	}
}
GRID_LOOP(f, DS(uint(pcs.pa), DS_COUNT))
"""

## `pool_track` for a bup picture just made (`pool_payload` of slot `pcs.pc`, `pcs.pd` texels a slot, in the same list): an answer's R_PX
## and R_PY are where the bup was in the picture before, as the picture's PREVXY has it, so the main side can draw its rings and follow it
## where it draws the bup.
const TRACK_BEFORE := "if (k < uint(pcs.pd)) { uint v = (uint(pcs.pc) * uint(pcs.pd) + k) * PV_WORDS; TR[r + t * ANSWER_WORDS + R_PX] = PREVXY[v]; TR[r + t * ANSWER_WORDS + R_PY] = PREVXY[v + 1u]; }"

## After `pool_track` of set `pcs.pa`: each tracked bup as a point of the set's probes (SPQ, the first TRACKED points of the set: x, y,
## speed, sense range), so `pool_probe_full` in the same list gives the steering at each. The sense range is the bup's sense gene times the
## root of its size (the root of its mass) over the reference size, as the swim reads it. An id not found is a point at the dish's centre
## whose answer the host does not read.
const K_TRACK_POINTS := """
void f(uint t) {
	uint s = uint(pcs.pa), q = s * TQ_WORDS, r = (s * TRACKED + t) * ANSWER_WORDS, o = (s * PROBES_MOST + t) * 4u;
	bool found = TR[r + R_ID_LO] == TQ[q + 1u + 2u * t] && TR[r + R_ID_HI] == TQ[q + 2u + 2u * t];
	float mass = max(uintBitsToFloat(TR[r + R_MASS]), 0.0);
	SPQ[o] = found ? uintBitsToFloat(TR[r + R_X]) : 0.0;
	SPQ[o + 1u] = found ? uintBitsToFloat(TR[r + R_Y]) : 0.0;
	SPQ[o + 2u] = found ? uintBitsToFloat(TR[r + R_SPEED]) : 0.0;
	SPQ[o + 3u] = found ? uintBitsToFloat(TR[r + R_SENSE]) * sqrt(sqrt(mass) / P[P_REFERENCE_SIZE]) : 1.0;
}
GRID_LOOP(f, min(TQ[uint(pcs.pa) * TQ_WORDS], TRACKED))
"""

## The published pictures into the shared textures (the storage buffers are laid out as the textures): a thread a texel. `pcs.pa` is the
## texture's width, `pcs.pb` the texels written; for the payload, at most those and `pcs.pc` the dish row whose payload it is: the rows
## `pool_payload` wrote, from the count DSTATE has when the kernel runs (the payload may follow the steps in their list), from slot `pcs.pd`
## (`pcs.pb` texels a slot). The ids texture takes each bup's id and its place in the picture before (GpuLayout.IDS_*).
const K_COPY_PAYLOAD := """
layout(set = 0, binding = 4, rgba32ui) uniform restrict writeonly uimage2D PAYTEX;
layout(set = 0, binding = 5, rgba32ui) uniform restrict writeonly uimage2D IDS;
void f(uint k) {
	uint w = uint(pcs.pa);
	ivec2 at = ivec2(int(k % w), int(k / w));
	uint o = uint(pcs.pd) * uint(pcs.pb) + k;
	imageStore(PAYTEX, at, PAYLOAD[o]);
	imageStore(IDS, at, uvec4(IDTEX[o * IDT_WORDS + IDT_LO], IDTEX[o * IDT_WORDS + IDT_HI], PREVXY[o * PV_WORDS], PREVXY[o * PV_WORDS + 1u]));
}
GRID_LOOP(f, min(((DS(uint(pcs.pc), DS_COUNT) + PAYLOAD_TEX_WIDTH - 1u) / PAYLOAD_TEX_WIDTH) * PAYLOAD_TEX_WIDTH, uint(pcs.pb)))
"""

## The payload and the places before, for the main device's copy of what the simulation handed over as bytes (ViewRenderer): the same,
## with no ids (the ids texture's id words are 0). `pcs.pc` 0: no places before were handed over, and each bup's is its place in the payload.
const K_COPY_HANDED := """
layout(set = 0, binding = 2, rgba32ui) uniform restrict writeonly uimage2D PAYTEX;
layout(set = 0, binding = 3, rgba32ui) uniform restrict writeonly uimage2D IDS;
void f(uint k) {
	uint w = uint(pcs.pa);
	ivec2 at = ivec2(int(k % w), int(k / w));
	imageStore(PAYTEX, at, PAYLOAD[k]);
	uvec2 was = pcs.pc > 0.5 ? uvec2(PREVXY[k * PV_WORDS], PREVXY[k * PV_WORDS + 1u]) : uvec2(PAYLOAD[k][PL_X], PAYLOAD[k][PL_Y]);
	imageStore(IDS, at, uvec4(0u, 0u, was));
}
GRID_LOOP(f, uint(pcs.pb))
"""

const K_COPY_RGBA8 := """
layout(set = 0, binding = 1, rgba8) uniform restrict writeonly image2D PIC;
void f(uint k) {
	uint w = uint(pcs.pa), px = PIX[k];
	imageStore(PIC, ivec2(int(k % w), int(k / w)), vec4(float(px & 255u), float((px >> 8) & 255u), float((px >> 16) & 255u), float(px >> 24)) / 255.0);
}
GRID_LOOP(f, uint(pcs.pb))
"""

## The image bindings of the copy kernels (binding -> the name SimCore binds a texture by), past their storage buffers.
const IMAGE_BINDINGS := {
	"pool_copy_payload": {4: "PAYTEX", 5: "IDS"},
	"pool_copy_handed": {2: "PAYTEX", 3: "IDS"},
	"pool_copy_rgba8": {1: "PIC"},
}


static func register(out: Dictionary) -> void:
	var dn := GpuKernelsLife.dn_funcs()
	var t := {"EDC": "int", "EDA": "float", "HUSK": "float", "PIX": "uint"}
	GpuKernels.add(out, "pool_row_clear", K_ROW_CLEAR, ["WORLD", "PUFF", "HUSK"], "", 64, t)
	GpuKernels.add(out, "pool_edit_cells", K_EDIT_CELLS, ["CONC", "EDC", "EDA"], "", 64, t)
	GpuKernels.add(out, "pool_erase_cells", K_ERASE_CELLS, ["WORLD", "CELLDISH", "DISHP", "INSIDE", "CONC", "EDA"], "", 64, t)
	GpuKernels.add(out, "pool_erase_puffs", K_ERASE_PUFFS, ["WORLD", "PUFF", "EDA"], "", 64, t)
	GpuKernels.add(out, "pool_fraction", K_FRACTION, ["WORLD", "BLKDISH", "DSTATE", "BUPS", "FRQ"], "", 64, {"FRQ": "uint"})
	GpuKernels.add(out, "pool_ids", K_IDS, ["BUPS_U", "CHILD_U"])
	GpuKernels.add(out, "pool_track", K_TRACK.replace("\n\t\t\tBEFORE", ""), ["DSTATE", "BUPS_U", "TQ", "TR"], "", 64, {"TQ": "uint", "TR": "uint"})
	GpuKernels.add(out, "pool_track_picture", K_TRACK.replace("BEFORE", TRACK_BEFORE), ["DSTATE", "BUPS_U", "TQ", "TR", "PREVXY"], "", 64,
		{"TQ": "uint", "TR": "uint", "PREVXY": "uint"})
	GpuKernels.add(out, "pool_track_points", K_TRACK_POINTS, ["P", "TQ", "TR", "SPQ"], "", 64, {"TQ": "uint", "TR": "uint", "SPQ": "float"})
	GpuKernels.add(out, "pool_slot_check", K_SLOT_CHECK, ["WORLD", "DNEXT", "DSTATE"], dn, 64, GpuKernelsLife.POOL_TYPES)
	GpuKernels.add(out, "pool_copy_payload", K_COPY_PAYLOAD, ["DSTATE", "PAYLOAD", "IDTEX", "PREVXY"], "", 64, GpuKernelsDraw.POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_copy_handed", K_COPY_HANDED, ["PAYLOAD", "PREVXY"], "", 64, GpuKernelsDraw.POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_copy_rgba8", K_COPY_RGBA8, ["PIX"], "", 64, t)
