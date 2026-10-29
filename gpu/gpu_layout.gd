class_name GpuLayout
extends RefCounted
## The word layouts of the GPU path, in one place: the bup record, the family events, the counters (CNT, PCNT), the frame's questions
## (QIN) and answers (OUT), the slots of P, and the sizes of the buffers they live in. Every word is a 32-bit word. GpuKernels.add()
## declares the names a kernel uses at the top of its GLSL (an int constant here as `const uint NAME = value;`, a slot of P as
## `const int P_<NAME> = slot;`), so the kernels, gpu/gpu_sim.gd, gpu/gpu_world.gd and the tools all read these. The C++ side (BupSim's
## export_state_bytes, bup_from_record, apply_events) has its own literals: tests/gpu_layout_test.gd checks it against this table word
## by word. What belongs here: int constants (every one becomes a GLSL name), P_SLOTS, the record's one float marker (NO_PICTURE), and
## the static helpers that read and write a record's words; none of it may refer to another class.

# ---- the bup record (BUPS, BUPS2, CHILD; BupSim.export_state_bytes) ------------------------------------------------------------------
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
const R_FAST := 24  ## the fine path's chemotaxis memory: the signal read lately (below 0: none read yet)
const R_SLOW := 25  ## ... and over a longer memory
const R_NOISE := 26  ## its receptor noise
const R_TUMBLING := 27  ## the seconds of tumble left
const ANSWER_WORDS := 24  ## the words of a record a pick's or a tracked bup's answer carries: all but the chemotaxis memory
const RECORD_BYTES := RECORD_WORDS * 4
const ANSWER_BYTES := ANSWER_WORDS * 4
const NO_PICTURE := 3e38  ## R_PX, R_PY of a bup with no last picture: no trail (any value >= 1e30 means the same)

# ---- the family events (EVB, EVD; BupSim.apply_events) --------------------------------------------------------------------------------
const BIRTH_WORDS := 16
const EB_ID_LO := 0
const EB_ID_HI := 1
const EB_PARENT_LO := 2
const EB_PARENT_HI := 3
const EB_STEP := 4  ## the step's place in its batch (from 0)
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
const EV_PUFF_FLOATS := 6  ## a cloud among the clouds the dish's own world sends (EVP; GpuSim.WorldEvents): x, y, mass, variance, cut, a spare 0
const EVENT_SETS := 4  ## the family events of this many batches can be held at once (each batch writes set seq % EVENT_SETS; a set is
## written again only once its batch's events are in the CPU's records: about 4 frames after it ran)
const MAX_STEPS_PER_BATCH := 1024  ## the steps of one batch (EVR: four ints a step)
const EV_PUFFS_CAPACITY := 65536  ## the clouds the dish's own world can send in one batch (EVP)
const EV_CELLS_CAPACITY := 1048576  ## the deposits on cells it can send in one batch (EVCC, EVCA)

# ---- the counters (CNT, PCNT) ---------------------------------------------------------------------------------------------------------
const CNT_WORDS := 16
const CNT_BUPS := 0  ## the bups now
const CNT_SURVIVORS := 1  ## the bups kept by this step's `life`
const CNT_NEWBORN := 2
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
const PCNT_WORDS := 8
const PCNT_SLOTS := 0  ## cloud slots in use
const PCNT_KEPT := 1  ## slots after compaction
const PCNT_TO_GRID := 2  ## clouds that found no slot and went onto the grid, since the load
const PCNT_CUT := 3  ## list entries cut because the lists were full, since the load

# ---- the frame's questions (QIN; floats by their bits) --------------------------------------------------------------------------------
const QIN_WORDS := 44
const Q_PICK := 0  ## 1: a pick is asked
const Q_PICK_X := 1  ## the point
const Q_PICK_Y := 2
const Q_SLACK := 3
const Q_PIXEL := 4  ## µm per pixel
const Q_NEAR := 5  ## how many nearest points are asked (up to NEAR_SLOTS)
const Q_NEAR_FIRST := 6  ## then 3 words a point: x, y, near
const Q_FRAC := 18  ## how many fractions are asked (up to FRACTIONS)
const Q_FRAC_FIRST := 19  ## then 2 words each: the gene's index (R_SPEED + it is the gene's word), the threshold's bits
const Q_TRACK := 27  ## how many bups are tracked (up to TRACKED)
const Q_TRACK_FIRST := 28  ## then 2 words each: the id's lo and hi words
const NEAR_SLOTS := 4
const FRACTIONS := 4
const TRACKED := 8
const MAX_ERASE := 64  ## eraser discs in one frame (ERASE: x, y, radius, strength each)

# ---- the frame's answers (OUT; uint words, floats by their bits) ----------------------------------------------------------------------
const OUT_CNT := 0  ## CNT as it was at the end of the frame's work (CNT_WORDS words)
const OUT_PCNT := 16  ## PCNT likewise (PCNT_WORDS words; 24-31 spare)
const OUT_Q := 32  ## the answers to the questions (QOUT_WORDS words), QO_* from here
const QO_INDEX := 0  ## the picked bup's index, or 0xFFFFFFFF
const QO_D2 := 1  ## its d² (float bits)
const QO_RECORD := 2  ## its record (ANSWER_WORDS words)
const QO_NEAR := 26  ## the nearest d² of point 0 (float bits; 0xFFFFFFFF: no bups), then how many lie within its `near`
const QO_FRAC := 28  ## the counts for the FRACTIONS fractions (32-35 spare)
const QO_TRACKED := 36  ## the TRACKED records (ANSWER_WORDS words each; ids 0xFFFFFFFF where not found)
const QO_NEAR_MORE := 228  ## the nearest d² and count of points 1 to NEAR_SLOTS - 1, two words each
const QOUT_WORDS := 240
const OUT_STATS := OUT_Q + QOUT_WORDS  ## the stats samples (STATS_WORDS each): sample 0 the state at the end of the frame's work, 1.. those of its batch
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
const MAX_SAMPLES := 256  ## history samples one batch can take (1024 steps of 20 s make 171)
const OUT_WORDS := OUT_STATS + STATS_WORDS * (1 + MAX_SAMPLES)

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
	"cloud_spread": [70, "batch"],  # a cloud's spread in a step (2 D dt)
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
