class_name SimConstants
extends RefCounted
## The native simulation (native/src) defines no numbers of its own. Every constant it uses is
## gathered here from the scripts that document it (biology.gd, cell.gd, genome.gd, dish.gd) and
## handed over once. Add a constant to the native code by adding it to this dictionary and to
## native/src/params.h, never by writing the value in C++.

## Every constant in build() is one of these two lists, and the test (tests/motion_table_test.gd) fails for one that is in
## neither. This is how a new constant gets a decision: does the real run-and-tumble swimming read it? The coarse motion of
## long steps is measured from that swimming (scripts/motion_table.gd, made by tools/gen_motion_table.gd), so a change to
## any of the first list makes the table stale, and the test says so (see MotionFingerprint).
const MOTION_INPUTS := [
	"tumble_base", "chemotaxis_gain", "tumble_up_factor", "tumble_seconds", "tumble_turn_mean", "tumble_turn_spread",
	"rotational_diffusion", "memory_short", "memory_long",
]
## The rest, and why none of them is a motion input: the table is measured per unit of speed and as a function of the
## slope a swimmer faces (speed times the log-gradient) and the error of its estimate of it, so what makes either of
## those (the gradient and sense constants, the detection floor, which the measurement keeps far below) is not an input
## but a way of reading the table; and nothing else touches swimming.
const OTHER_CONSTANTS := [
	"detection_floor", "noise_reference", "gradient_noise", "reference_sense", "reference_size", "motion_step", "motion_structure", "cloud_handover", "cloud_cut", "steering_window", "fine_step",
	"diffusion", "field_target_spacing", "field_min_across", "field_max_across", "nutrient_energy", "max_cells",
	"diffuse_interval", "diffuse_accuracy", "division_spread", "death_rate", "death_release", "growth_rate", "cost_per_mass", "reserve_per_mass",
	"maintenance_floor", "base_upkeep", "maintenance_per_mass", "drag_upkeep", "sense_upkeep", "uptake_per_size",
	"half_saturation", "mass_um", "width", "trait_mutations", "harmful_mutations", "compensatory_mutations", "mutator_rate", "mutator_down_share", "mutator_fold_weak", "mutator_fold_strong", "mutator_fold_top",
	"lethal_fraction", "harm_shape", "mean_harm", "mean_repair", "max_harm", "hue_step", "sat_step", "val_step", "val_min",
	"add_mass_factor", "min_length_px", "min_width_px", "max_trail_px", "founder_hue", "founder_sat", "founder_val",
	"gene_min", "gene_max", "gene_step", "motion_s", "motion_e", "motion_drift", "motion_d_along", "motion_d_across",
	"motion_d_flat",
]

static var _applied := false


## Configures the native simulation; safe to call as often as you like.
static func apply() -> void:
	if _applied:
		return
	var missing := BupSim.configure(build())
	if not missing.is_empty():  # (an assert would vanish from an exported game, and the sim would run on with zeros)
		push_error("native constants missing: %s" % missing)
		assert(false, "native constants missing: %s" % missing)
		return
	_applied = true
	if OS.is_debug_build() and not MotionFingerprint.constants_current():  # (the full check, with the native sources, is in the tests)
		push_error("the motion table is stale: a constant of the real swimming has changed since it was measured (run tools/gen_motion_table.gd)")


static func build() -> Dictionary:
	var gene_min := []
	var gene_max := []
	var gene_step := []
	for gene in Genome.GENES:  # the native code indexes genes in this order
		gene_min.append(Genome.GENES[gene][0])
		gene_max.append(Genome.GENES[gene][1])
		gene_step.append(Genome.GENES[gene][2])
	return {
		"diffusion": Biology.NUTRIENT_DIFFUSION,
		"field_target_spacing": Dish.FIELD_TARGET_SPACING,
		"field_min_across": Dish.FIELD_MIN_ACROSS,
		"field_max_across": Dish.FIELD_MAX_ACROSS,
		"nutrient_energy": Dish.NUTRIENT_ENERGY,
		"max_cells": Dish.MAX_CELLS,
		"motion_step": Dish.MOTION_STEP,
		"motion_structure": Dish.MOTION_STRUCTURE,
		"cloud_handover": Dish.CLOUD_HANDOVER,
		"cloud_cut": Dish.CLOUD_CUT,
		"steering_window": Dish.STEERING_WINDOW,
		"fine_step": Dish.FINE_STEP,
		"diffuse_interval": Dish.DIFFUSE_INTERVAL,
		"diffuse_accuracy": Dish.DIFFUSE_ACCURACY,
		"division_spread": Dish.DIVISION_SPREAD,
		"death_rate": Biology.DEATH_PER_SECOND,
		"death_release": Biology.DEATH_RELEASE,
		"growth_rate": Cell.GROWTH_RATE,
		"cost_per_mass": Cell.COST_PER_MASS,
		"reserve_per_mass": Cell.RESERVE_PER_MASS,
		"maintenance_floor": Cell.MAINTENANCE_FLOOR,
		"base_upkeep": Cell.BASE_UPKEEP,
		"maintenance_per_mass": Cell.MAINTENANCE_PER_MASS,
		"drag_upkeep": Cell.DRAG_UPKEEP,
		"sense_upkeep": Cell.SENSE_UPKEEP,
		"uptake_per_size": Cell.UPTAKE_PER_SIZE,
		"half_saturation": Cell.HALF_SATURATION,
		"detection_floor": Cell.DETECTION_FLOOR,
		"noise_reference": Cell.NOISE_REFERENCE_CONC,
		"gradient_noise": Cell.GRADIENT_NOISE,
		"reference_sense": Cell.REFERENCE_SENSE,
		"reference_size": Cell.REFERENCE_SIZE,
		"mass_um": Cell.MASS_UM,
		"width": Biology.WIDTH,
		"tumble_base": Cell.TUMBLE_BASE,
		"chemotaxis_gain": Cell.CHEMOTAXIS_GAIN,
		"tumble_up_factor": Biology.TUMBLE_UP_FACTOR,
		"tumble_seconds": Biology.TUMBLE_SECONDS,
		"tumble_turn_mean": Biology.TUMBLE_TURN_MEAN,
		"tumble_turn_spread": Biology.TUMBLE_TURN_SPREAD,
		"rotational_diffusion": Biology.ROTATIONAL_DIFFUSION,
		"memory_short": Biology.MEMORY_SHORT,
		"memory_long": Biology.MEMORY_LONG,
		"trait_mutations": Genome.TRAIT_MUTATIONS,
		"harmful_mutations": Genome.HARMFUL_MUTATIONS,
		"compensatory_mutations": Genome.COMPENSATORY_MUTATIONS,
		"mutator_rate": Genome.MUTATOR_RATE,
		"mutator_down_share": Genome.MUTATOR_DOWN_SHARE,
		"mutator_fold_weak": Genome.MUTATOR_FOLD_WEAK,
		"mutator_fold_strong": Genome.MUTATOR_FOLD_STRONG,
		"mutator_fold_top": Genome.MUTATOR_FOLD_TOP,
		"lethal_fraction": Genome.LETHAL_FRACTION,
		"harm_shape": Genome.HARM_SHAPE,
		"mean_harm": Genome.MEAN_HARM,
		"mean_repair": Genome.MEAN_REPAIR,
		"max_harm": Genome.MAX_HARM,
		"min_length_px": Cell.MIN_VISIBLE_LENGTH_PX,
		"min_width_px": Cell.MIN_VISIBLE_WIDTH_PX,
		"max_trail_px": Dish.MAX_TRAIL_PIXELS,
		"founder_hue": Genome.founder()["hue"],
		"founder_sat": Genome.founder()["sat"],
		"founder_val": Genome.founder()["val"],
		"hue_step": Genome.HUE_STEP,
		"sat_step": Genome.SAT_STEP,
		"val_step": Genome.VAL_STEP,
		"val_min": Genome.VAL_MIN,
		"add_mass_factor": Cell.ADD_MASS_FACTOR,
		"gene_min": gene_min,
		"gene_max": gene_max,
		"gene_step": gene_step,
		"motion_s": MotionTable.S_AXIS,
		"motion_e": MotionTable.E_AXIS,
		"motion_drift": MotionTable.DRIFT,
		"motion_d_along": MotionTable.D_ALONG,
		"motion_d_across": MotionTable.D_ACROSS,
		"motion_d_flat": MotionTable.D_FLAT,
	}
