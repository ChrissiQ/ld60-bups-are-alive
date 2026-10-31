class_name GpuKernelsCore
extends RefCounted
## The pooled world's host operations as kernels (SimCore, scripts/sim/sim_core.gd; see gpu/kernels.gd for how a kernel is made): a
## dish's clouds and husks leaving with it, the field edits (a drop of nutrient, the eraser), the check that a step's next layout fits the
## record slots, the goals' question, and the copies of the published pictures into the shared textures.

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

## The eraser on dish row `pcs.pa` (NutrientField::erase_disc): a disc at (pcs.pb, pcs.pc) of radius ERASE's x and strength its y takes
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

## The goals' question (BupSim::fraction_with_gene_at_least) for dish row `pcs.pb`: how many of its bups hold record word `pcs.pa` (a gene,
## R_SPEED + g) at or above `pcs.pc` (the threshold as the host rounds it up to a float), counted into FRQ[0]. An integer count, so the
## share the host works out from it does not depend on the order the threads run in.
const K_FRACTION := """
void f(uint i, uint d, uint l) {
	if (d == uint(pcs.pb) && BUPS[i * RECORD_WORDS + uint(pcs.pa)] >= pcs.pc) atomicAdd(FRQ[0], 1u);
}
BUP_LOOP(f)
"""

## The published pictures into the shared textures (after the sync; the storage buffers are laid out as the textures): a thread a texel.
## `pcs.pa` is the texture's width, `pcs.pb` the texels written.
const K_COPY_PAYLOAD := """
layout(set = 0, binding = 2, rgba32ui) uniform restrict writeonly uimage2D PAYTEX;
layout(set = 0, binding = 3, rg32ui) uniform restrict writeonly uimage2D IDS;
void f(uint k) {
	uint w = uint(pcs.pa);
	ivec2 at = ivec2(int(k % w), int(k / w));
	imageStore(PAYTEX, at, PAYLOAD[k]);
	imageStore(IDS, at, uvec4(IDTEX[k * 2u + IDT_LO], IDTEX[k * 2u + IDT_HI], 0u, 0u));
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
	"pool_copy_payload": {2: "PAYTEX", 3: "IDS"},
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
	GpuKernels.add(out, "pool_slot_check", K_SLOT_CHECK, ["WORLD", "DNEXT", "DSTATE"], dn, 64, GpuKernelsLife.POOL_TYPES)
	GpuKernels.add(out, "pool_copy_payload", K_COPY_PAYLOAD, ["PAYLOAD", "IDTEX"], "", 64, GpuKernelsDraw.POOL_DRAW_TYPES)
	GpuKernels.add(out, "pool_copy_rgba8", K_COPY_RGBA8, ["PIX"], "", 64, t)
