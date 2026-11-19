class_name GpuLayout
extends RefCounted
## The word layouts of the GPU path, in one place: the bup record, the family events, the counters (CNT, PCNT), the stats samples,
## the slots of P, and the sizes of the buffers they live in. Every word is a 32-bit word. GpuKernels.add()
## declares the names a kernel uses at the top of its GLSL (an int constant here as `const uint NAME = value;`, a slot of P as
## `const int P_<NAME> = slot;`), so the kernels, the host's pool code and the tools all read these. What belongs here: int constants (every one becomes a GLSL name), P_SLOTS, the record's one float marker (NO_PICTURE) and
## its genes' names (GENE_NAMES), and the static helpers that read and write a record's words; none of it may refer to another class.

# ---- the bup record (BUPS, BUPS2, CHILD; an exported state) ------------------------------------------------------------------
const RECORD_WORDS := 28
const RECORD_VEC4 := 7  ## the record in 16-byte pieces (RECORD_WORDS / 4): `compact` and `copy` move records as uvec4
const R_ID_LO := 0  ## the id's low 32 bits (uint bits; ids are read through the uint views)
const R_X := 1  ## where it is (µm from the dish's centre)
const R_Y := 2
const R_DX := 3  ## the way it faces (a unit vector)
const R_DY := 4
const R_ENERGY := 5  ## its reserve
const R_MASS := 6
const R_BIRTH_MASS := 7
const R_SPEED := 8  ## the four genes, in Genome.GENES' order (speed, sense, metabolism, size): R_SPEED + g is gene g
const R_SENSE := 9
const R_METABOLISM := 10
const R_SIZE := 11  ## the size gene (the building size is P_ADD_MASS_FACTOR x size²)
const R_REACH := 12  ## the raised gene ceilings (two bits a gene, speed the lowest) and the acetate key (bits 8-9), as a float
const R_MUTATOR := 13  ## the mutation rate, a multiple of the usual
const R_DONOR := 14  ## 1: it carries the F factor, 0: not (the drag cost is P_DRAG_UPKEEP x speed²)
const R_HARM := 15
const R_HUE := 16
const R_SAT := 17
const R_VAL := 18
const R_MUTATIONS := 19  ## a whole number as a float
const R_DIVISIONS := 20  ## a whole number as a float
const R_ID_HI := 21  ## the id's high 32 bits (uint bits)
const R_PX := 22  ## where it was in the last picture (>= 1e30: none; a newborn 3e38)
const R_PY := 23  ## (a bup that died of starvation or chance has -2 here from `life` until `copy`, for `death_clouds` and `events`)
const R_FAST := 24  ## the fine step's chemotaxis memory (a step as short as `fine_step` follows each run and tumble): the signal read lately (below 0: none read yet)
const R_SLOW := 25  ## ... and over a longer memory
const R_NOISE := 26  ## its receptor noise
const R_TUMBLING := 27  ## the seconds of tumble left
const ANSWER_WORDS := 24  ## the words of a record a pick's or a tracked bup's answer carries: all but the chemotaxis memory
const RECORD_BYTES := RECORD_WORDS * 4
const ANSWER_BYTES := ANSWER_WORDS * 4
const GENE_NAMES := ["speed", "sense", "metabolism", "size"]  ## the genes in the record's order: R_SPEED + g is GENE_NAMES[g]
const NO_PICTURE := 3e38  ## R_PX, R_PY of a bup with no last picture: no trail (any value >= 1e30 means the same)

# ---- the family events (EVB, EVD) --------------------------------------------------------------------------------
const BIRTH_WORDS := 16
const EB_ID_LO := 0
const EB_ID_HI := 1
const EB_PARENT_LO := 2
const EB_PARENT_HI := 3
const EB_STEP := 4  ## the step's place in its batch (from 0) in the low EV_STEP_BITS, the dish it was born in above (EV_DISH_SHIFT)
const EB_DIVISIONS := 5  ## uint
const EB_TRAITS := 6  ## uint: the mutations in the low 20 bits, the reach word in bits 20-29, the F factor in bit 30 (EV_*)
const EB_SPEED := 7  ## floats from here: the four genes in the record's order
const EB_SENSE := 8
const EB_METABOLISM := 9
const EB_SIZE := 10
const EB_HUE := 11
const EB_SAT := 12
const EB_VAL := 13
const EB_HARM := 14
const EB_MUTATOR := 15
const DEATH_WORDS := 14
const ED_ID_LO := 0
const ED_ID_HI := 1
const ED_STEP := 2
const ED_TRAITS := 3  ## uint: the divisions in the low 20 bits, the reach word in bits 20-29, the F factor in bit 30 (as it was when it died)
const ED_MASS := 4  ## floats from here
const ED_X := 5
const ED_Y := 6
const ED_GIVES := 7  ## the nutrient energy it gives back (0 for one the trim displaced)
const ED_ENERGY := 8  ## its own reserve
const ED_BIRTH_MASS := 9
const ED_SPEED := 10  ## the four genes as it died, in the record's order (a conjugation can have changed them since its birth)
const ED_SENSE := 11
const ED_METABOLISM := 12
const ED_SIZE := 13
const EV_LOW_MASK := 0xFFFFF  ## a traits word's low 20 bits (mutations in a birth, divisions in a death)
const EV_REACH_SHIFT := 20
const EV_REACH_MASK := 0x3FF  ## the reach word's ten bits, above the low 20
const EV_DONOR_SHIFT := 30  ## the F factor's bit
const EV_PUFF_FLOATS := 6  ## a cloud among the clouds the dish's own world sends (EVP): x, y, mass, variance, cut, a spare 0
const EVENT_SETS := 4  ## the family events of this many batches can be held at once (each batch writes set seq % EVENT_SETS; a set is
## written again only once its batch's events are in the lineage records: about 4 frames after it ran)
const MAX_STEPS_PER_BATCH := 1024  ## the steps of one batch (EVR: four ints a step)
const EV_PUFFS_CAPACITY := 65536  ## the clouds the dish's own world can send in one batch (EVP)
const EV_CELLS_CAPACITY := 1048576  ## the deposits on cells it can send in one batch (EVCC, EVCA)

# ---- the counters (CNT, PCNT) ---------------------------------------------------------------------------------------------------------
const CNT_BUPS := 0  ## the bups now
const CNT_SURVIVORS := 1  ## the bups kept by this step's `life`
const CNT_NEXT_COUNT := 3  ## the bups after this step (survivors and newborns, up to the capacity)
const CNT_NEXT_ID_LO := 4  ## the next id's low and high words
const CNT_STEP := 5  ## the step number (for the random streams)
const CNT_NEXT_ID_HI := 6
const CNT_SEED := 7  ## the dish's seed
const CNT_BIRTHS := 8  ## births this batch
const CNT_DEATHS := 9  ## deaths this batch
const CNT_BIRTHS_LOST := 10  ## births that found no event slot, since the load
const CNT_DEATHS_LOST := 11  ## deaths that found no event slot, since the load
const CNT_GROWTH := 12  ## what the trim at the limit expects the next step to add (see `finalize`)
const CNT_TRIMMED := 13  ## bups trimmed so far this step (`life` adds, `finalize` reads and clears)
const CNT_DONOR_REACH := 14  ## the largest donor's half length this step, as float bits (`conj_insert`), for how far a recipient looks
const CNT_DONORS := 15  ## the donors of the step (`conj_insert`)
const PCNT_SLOTS := 0  ## cloud slots in use

# ---- what a frame asks for and edits ----------------------------------------------------------------------------------------------------
const FRACTIONS := 4
const TRACKED := 8
const MAX_ERASE := 64  ## eraser discs in one frame (ERASE: x, y, radius, strength each)

# ---- the stats samples (STATS; uint words, floats by their bits) ------------------------------------------------------------------------
const STATS_WORDS := 16
const ST_COUNT := 0  ## floats: the count
const ST_SPEED := 1  ## the sums of the genes (ST_SPEED + g is gene g's)
const ST_SENSE := 2
const ST_METABOLISM := 3
const ST_SIZE := 4
const ST_HARM := 5  ## Σ(1 - exp(-harm))
const ST_MUTATIONS := 6
const ST_STEP := 7  ## the step of the batch it was taken after
const ST_MUTATOR := 8
const ST_DONORS := 9  ## a uint: the donors
const ST_KEY := 10  ## the bups with the acetate key
const ST_DIVISIONS := 11  ## (12-15 are 0)
const STATS_SUMS := 11  ## the sums `stats1` makes for each group of 256 bups (SPART): count, the genes, harm, mutations, mutator, key, divisions, donors

# ---- the pooled world: ids, blocks, the dish tables, the payload ---------------------------------------------------------
# The bup record above is the pool's record too: it has no dish word. A bup's dish is the segment it occupies (BLKDISH, DS_START).
# DISHP and DSTATE are tables of D_MAX rows, one per dish; a row is addressed by the dish's row, never by its number.
const D_MAX := 1024  ## rows of DISHP and DSTATE (the running dishes)
const NO_DISH := 0xFFFFFFFF  ## a row that is no dish (a block of no dish in BLKDISH, a bup that stays in PIPDST)

## Ids are one world-wide counter: positive (bit 63 is 0), sequential from 1 at a new game, never reused, and independent of every dish. A
## bup keeps its id through a pipette. Which dish a bup is in comes from where it sits (its segment), never from the id. The world's next id
## is WORLD[WD_NEXT_ID_LO], WORLD[WD_NEXT_ID_HI].
const ID_MAX := 0x7FFFFFFFFFFFFFFF  ## the largest id (2^63 - 1)

## The block table: BLKDISH[slot >> BLK_SHIFT] is the dish row of each block of BLK_SLOTS slots, or NO_DISH (for both halves of the records' ping-pong pair, as BLKDISH and BLKDISH2).
const BLK_SLOTS := 256
const BLK_SHIFT := 8
const PIPDST_WORDS := 1  ## the pipette's scratch: one uint a slot (the destination row, NO_DISH: stays), apart from the record

## An event's step word (ED_STEP of a death, EB_STEP of a birth): the step's place in its batch in the low EV_STEP_BITS, the number of the dish
## whose segment the bup was in (a newborn: the dish it was born in) above.
const EV_STEP_BITS := 13
const EV_STEP_MASK := 0x1FFF
const EV_DISH_SHIFT := 13
const EV_DISH_BITS := 19
const EV_DISH_MASK := 0x7FFFF

const PROBE_FLOATS := 5  ## a point's answer (SPR, `pool_probe_full`): the way up the gradient (x, y, a unit vector), the chance of steering up it, the concentration, the gradient's size
const HUSK_QUERIES := 4  ## the places one `husk_near` call asks about (HNQ: x, y, reach, a spare 0 each)
const HN_WORDS := 8  ## a husk question's answer (HNR, uint words): the nearest's squared distance (float bits; 0xFFFFFFFF none), its slot + 1 (0 none), then its x, y, energy, age and pieces let go (float bits), a spare 0
const PUFF_ROW_BASE := 0x3F800000  ## a cloud's word 5 (and its event's) is the float whose bits are this plus its dish's row: 1.0 and up, so "alive" stays `>= 0.5` and 0.0 is a free slot (no denormals, which a copy through a float register could flush)

## DISHP[d]: host to device, uploaded when changed. Floats and uints by their bits; words 23-31 are spare.
const DP_WORDS := 32
const DP_FIELD_BASE := 0  ## uint: the 256-aligned base of the dish's cells in each field buffer
const DP_CELLS := 1  ## uint: cells across
const DP_SPACING := 2  ## float: a cell's width (µm)
const DP_RADIUS := 3  ## float: the dish's radius (µm), also the origin: a grid coordinate is (x + radius) / spacing
const DP_HANDOVER := 4  ## float: a cloud this wide goes to the grid
const DP_BIN_BASE := 5  ## uint: the first of the dish's cloud-list squares in the pool
const DP_BINS_ACROSS := 6  ## uint
const DP_BIN_SIZE := 7  ## float
const DP_FEED := 8  ## float: the feed of one step (the feed per second times the step, worked out on the host)
const DP_UPKEEP_SCALE := 9  ## float
const DP_LIMIT := 10  ## uint: the most bups
const DP_CAP := 11  ## uint: the hard cap c_d, the newborn cutoff
const DP_FLAGS := 12  ## uint: DPF_* bits
const DP_K_TOTAL := 13  ## float: the diffusion's whole k
const DP_K := 14  ## float: its k in one sub-iteration
const DP_ITERATIONS := 15  ## uint: the sub-iterations (always even)
const DP_CLOUD_QUOTA := 16  ## uint
const DP_HUSK_QUOTA := 17  ## uint
const DP_NUMBER := 18  ## uint: the dish's number (the number events carry, EV_DISH_SHIFT)
const DP_SEED := 19  ## uint: the initial seed of a new or loaded dish (the running copy is DS_SEED)
const DP_STEP := 20  ## uint: the initial step of a new or loaded dish (the running copy is DS_STEP)
const DP_NOISE_REFERENCE := 21  ## float: the dish's receptor-noise scale for chemotaxis
const DP_CLOUD_SPREAD := 22  ## float: a cloud's spread in a step (2 D dt, D the dish's own diffusion: the medium is a dish's, not the pool's)
const DPF_STATIONARY := 0  ## the bits of DP_FLAGS (the bit's place, not its mask)
const DPF_DEATH_HUSKS := 1
const DPF_PLANKTON_HUSKS := 2
const DPF_RUNNING := 3  ## (bit 4 is spare: a dish leaves at once, `SimCore.remove_dish`, its blocks padding and its row cleared)
const DPF_MAIN_VIEW := 5
const DPF_ACETATE := 6
const DPF_COUNT := 6

## DSTATE[d]: device-owned, read back each iteration. Uints; words 24-31 are the energy ledger.
const DS_WORDS := 32
const DS_START := 0  ## the first slot of the dish's segment
const DS_COUNT := 1
const DS_SURVIVORS := 2
const DS_NEWBORN := 3
const DS_NEXT_COUNT := 4
const DS_WORLD_ID_LO := 5  ## the world's next id when the dish was gathered (a DishBlob's only: the device does not keep it, the world has the counter)
const DS_WORLD_ID_HI := 6
const DS_SEED := 7
const DS_STEP := 8  ## the dish's own step, from 0 at its strike
const DS_GROWTH := 9
const DS_TRIMMED := 10
const DS_DONORS := 11
const DS_DONOR_REACH := 12  ## float bits
const DS_BIRTHS := 13  ## this iteration
const DS_DEATHS := 14
const DS_BIRTHS_LOST := 15
const DS_DEATHS_LOST := 16
const DS_MOVED_IN := 17  ## the bups a pipette's retarget pass moved in and out (written only by that pass, zeroed at the start of each batch)
const DS_MOVED_OUT := 18
const DS_CLOUD_SLOTS := 19  ## the virtual cloud counter
const DS_CLOUDS_TO_GRID := 20
const DS_ENTRIES_CUT := 21
const DS_HUSKS := 22
const DS_OVERFLOW := 23  ## the physical-overflow flag
const DS_LEDGER := 24  ## the energy ledger, while WORLD[WD_LEDGER] is on: term LG_* in words DS_LEDGER + 2 x term (low) and + 1 (high), a sum in 2^-20 units
const LG_UPKEEP := 0  ## the ledger's terms: the upkeep paid (and a starving bup's maintenance)
const LG_UPTAKE := 1  ## food taken (glucose and acetate) less what the reserves gained, where that is more (a yield below 1, a full reserve)
const LG_MADE := 2  ## energy made: the acetate let go (besides the gain, not taken from it), and a reserve's gain past the food taken (a yield above 1)
const LG_LIFE := 3  ## a death's reserve and body less what it gives back; a lethal daughter's share; a daughter's reserve past what she can hold
const LG_TERMS := 4

## WORLD: one row of the world's totals (uints).
const WD_WORDS := 16
const WD_SLOTS := 0  ## the slots in use (the sum of the aligned segment lengths)
const WD_CLOUD_SLOTS := 1
const WD_HUSK_SLOTS := 2
const WD_ITERATION_STEP := 3  ## the iteration's step index
const WD_OVERFLOW := 4
const WD_CELLS := 5  ## the field cells in use (the bound of the cell kernels)
const WD_BINS := 6  ## the cloud-list squares in use
const WD_PUFF_CAPACITY := 7  ## the physical cloud slots (PUFF holds 8 floats a slot)
const WD_HUSK_CAPACITY := 8  ## the physical husk slots (HUSK holds 8 floats a slot; a kernel does not read a buffer's length, which Metal's translation of the SPIR-V cannot bind)
const WD_SLOT_CAPACITY := 9  ## the physical record slots (BUPS, BUPS2 and CHILD hold this many records)
const WD_LEDGER := 10  ## 1: the kernels keep the energy ledger (DS_LEDGER), for tests; 0: they do not (the game)
const WD_NEXT_ID_LO := 11  ## the id the next newborn of any dish gets (64 bits: low word; a step takes its newborns' ids by their rank in the pool's scan)
const WD_NEXT_ID_HI := 12
const WD_ENTRY_CAPACITY := 13  ## the physical list entries (ENT holds a word and ENTD two vec4s each): the room of `pool_bin_room`, set by the host
const WD_ENTRIES_PEAK := 14  ## the most entries the lists asked for (before the room's cut) since the host last read it and set it to 0
const WD_ENTRY_DENSITY := 15  ## the most entries a cloud slot in use averaged at the same time (rounded up), reset with WD_ENTRIES_PEAK

## The payload textures (a bup's picture, written sim-side after `finalize`): PAYLOAD (RGBA32UI, PAYLOAD_TEX_WIDTH wide) and the ids (RG32UI).
const PL_WORDS := 4
const PL_X := 0  ## float bits
const PL_Y := 1
const PL_SHAPE := 2  ## packHalf2x16(length µm, angle radians)
const PL_COLOR := 3  ## red, green, blue in bytes from PL_RED_SHIFT, PL_GREEN_SHIFT, PL_BLUE_SHIFT; the low byte is spare
const PL_RED_SHIFT := 24
const PL_GREEN_SHIFT := 16
const PL_BLUE_SHIFT := 8
const PAYLOAD_BYTES := PL_WORDS * 4
const IDT_WORDS := 2  ## the id texture: the id's low and high words
const IDT_LO := 0
const IDT_HI := 1
const IDT_BYTES := IDT_WORDS * 4
const PAYLOAD_TEX_WIDTH := 2048  ## a texture's width: a dish's n bups take ceil(n / 2048) rows

## STATS per dish: D_MAX rows of one sample for the state at the end plus STATS_ITER_SAMPLES for the iteration's steps (sample words: ST_*).
const STATS_ITER_SAMPLES := 16
const STATS_DISH_WORDS := STATS_WORDS * (1 + STATS_ITER_SAMPLES)


# ---- P (the parameters, floats) -------------------------------------------------------------------------------------------------------
const P_WORDS := 128

## The slots of P: name -> [slot, kind] (an "array" [slot, kind, length]). In the GLSL each is `P_` and its name in capitals. Kinds:
## "const" SimConstants.build()'s value of the same name, set at the load; "array" that constant's list (one slot per gene); "dish" set
## at the load from the dish and the buffers; "batch" set for every batch (they depend on the step's length or on the batch's plan).
const P_SLOTS := {
	"count": [0, "dish"],  # the bups at the load
	"cells": [1, "dish"],  # cells across the grid
	"spacing": [2, "dish"],  # a cell's width (µm)
	"origin": [3, "dish"],  # the dish's radius: a point's grid coordinate is (x + origin) / spacing
	"radius": [4, "dish"],
	"delta": [5, "batch"],  # the step (s)
	"moves": [6, "batch"],  # the motion's sub-steps (0: the bups do not swim)
	"sub": [7, "batch"],  # the length of one
	"death_give": [8, "dish"],  # what a death gives back per unit of the body's mass (death_release x cost_per_mass)
	"detection_floor": [9, "const"],
	"noise_reference": [10, "const"],
	"gradient_noise": [11, "const"],
	"reference_sense": [12, "const"],
	"reference_size": [13, "const"],
	"mass_um": [14, "const"],
	"base_upkeep": [16, "const"],
	"maintenance_per_mass": [17, "const"],
	"sense_upkeep": [18, "const"],
	"maintenance_floor": [19, "const"],
	"growth_rate": [20, "const"],
	"cost_per_mass": [21, "const"],
	"reserve_per_mass": [22, "const"],
	"uptake_per_size": [23, "const"],
	"half_saturation": [24, "const"],
	"motion_ns": [25, "dish"],  # the motion table's axes: points on the slope axis,
	"motion_ne": [26, "dish"],  # on the error axis,
	"motion_ls0": [27, "dish"],  # the log of the first slope and the log step,
	"motion_dls": [28, "dish"],
	"motion_le0": [29, "dish"],  # the log of the first error and the log step,
	"motion_dle": [30, "dish"],
	"motion_s0": [31, "dish"],  # and the first slope
	"trait_mutations": [32, "const"],
	"harmful_mutations": [33, "const"],
	"compensatory_mutations": [34, "const"],
	"lethal_fraction": [35, "const"],
	"harm_shape": [36, "const"],
	"mean_harm": [37, "const"],
	"mean_repair": [38, "const"],
	"max_harm": [39, "const"],
	"hue_step": [40, "const"],
	"sat_step": [41, "const"],
	"val_step": [42, "const"],
	"val_min": [43, "const"],
	"gene_min": [44, "array", 4],
	"gene_max": [48, "array", 4],
	"gene_step": [52, "array", 4],
	"add_mass_factor": [56, "const"],
	"drag_upkeep": [57, "const"],
	"division_spread": [58, "const"],
	"death_chance": [59, "batch"],  # the chance of death in a step
	"limit": [60, "batch"],  # the most bups: past it a random share dies each step
	"feed": [61, "batch"],  # the feed per step (concentration)
	"capacity": [62, "dish"],  # bup slots
	"death_puff": [63, "batch"],  # what a death gives back at once, as a cloud, per unit of mass: P_DEATH_GIVE, or 0 with husks on
	"handover": [64, "dish"],  # a cloud this wide goes to the grid (cloud_handover x spacing)
	"cloud_cut": [65, "const"],
	"bin_size": [66, "dish"],  # the squares of the cloud lists (half a cell)
	"bins_across": [67, "dish"],
	"motion_step": [68, "const"],
	"motion_structure": [69, "const"],
	"puff_capacity": [71, "dish"],  # cloud slots
	"entry_capacity": [72, "dish"],  # places in the lists of clouds by square
	"bins": [73, "dish"],
	"min_length_px": [74, "const"],  # the drawing's
	"width": [75, "const"],
	"min_width_px": [76, "const"],
	"max_trail_px": [77, "const"],
	"event_capacity": [78, "dish"],  # births, and deaths, an event set holds
	"upkeep_scale": [79, "batch"],  # the dish's upkeep factor
	"mutator_rate": [80, "const"],
	"mutator_down_share": [81, "const"],
	"mutator_fold_weak": [82, "const"],
	"mutator_fold_strong": [83, "const"],
	"mutator_fold_top": [84, "const"],
	"stationary": [85, "batch"],  # 1: the stationary phase is on
	"starve_cost": [86, "dish"],  # starve_maintenance x cost_per_mass
	"starve_death_rate": [87, "const"],
	"starve_death_exponent": [88, "const"],
	"starve_min_mass_share": [89, "const"],
	"donor_gain": [90, "const"],
	"donor_cost": [91, "const"],
	"donor_loss": [92, "const"],
	"contact_um": [93, "const"],
	"conj_chance": [94, "batch"],  # the chance that a touching donor and recipient transfer in a step
	"conj_continue": [95, "const"],
	"reach_rate": [96, "const"],
	"reach_cost": [97, "const"],
	"reach_factor_1": [98, "const"],
	"reach_factor_2": [99, "const"],
	"reach_factor_3": [100, "const"],
	"acetate_slope": [101, "const"],
	"acetate_threshold": [102, "const"],
	"acetate_uptake": [103, "const"],
	"key_potentiation_rate": [104, "const"],
	"key_rate": [105, "const"],
	"key_factor": [106, "const"],
	"key_cost": [107, "const"],
	"fine_step": [108, "const"],
	"tumble_base": [109, "const"],
	"chemotaxis_gain": [110, "const"],
	"tumble_up_factor": [111, "const"],
	"tumble_seconds": [112, "const"],
	"tumble_turn_mean": [113, "const"],
	"tumble_turn_spread": [114, "const"],
	"rotational_diffusion": [115, "const"],
	"memory_short": [116, "const"],
	"memory_long": [117, "const"],
}


## The slot of P named `slot_name` (a key of P_SLOTS).
static func p_slot(slot_name: String) -> int:
	assert(P_SLOTS.has(slot_name), "GpuLayout: P has no slot %s" % slot_name)
	return P_SLOTS[slot_name][0]


## The id of record `i` in a block of records (R_ID_LO and R_ID_HI).
static func id_of(records: PackedByteArray, i: int) -> int:
	return records.decode_u32(i * RECORD_BYTES + R_ID_LO * 4) | (records.decode_u32(i * RECORD_BYTES + R_ID_HI * 4) << 32)


## Gives record `i` the id `id`.
static func set_id(records: PackedByteArray, i: int, id: int) -> void:
	records.encode_u32(i * RECORD_BYTES + R_ID_LO * 4, id & 0xFFFFFFFF)
	records.encode_u32(i * RECORD_BYTES + R_ID_HI * 4, (id >> 32) & 0xFFFFFFFF)


## A whole record from the first ANSWER_WORDS words of one (what a pick or a tracked bup's answer holds): its chemotaxis memory is none read yet.
static func whole_record(answer: PackedByteArray) -> PackedByteArray:
	var record := answer.duplicate()
	record.resize(RECORD_BYTES)
	record.encode_float(R_FAST * 4, -1.0)
	return record


## An event's step word: `step` in its batch and the number of the dish the bup was in.
static func event_step_word(step: int, dish_number: int) -> int:
	return (dish_number << EV_DISH_SHIFT) | (step & EV_STEP_MASK)


## The step's place in the batch from an event's step word.
static func event_step(word: int) -> int:
	return word & EV_STEP_MASK


## The dish number from an event's step word.
static func event_dish_number(word: int) -> int:
	return (word >> EV_DISH_SHIFT) & EV_DISH_MASK
