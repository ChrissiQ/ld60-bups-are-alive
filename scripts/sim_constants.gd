class_name SimConstants
extends RefCounted
## The native simulation (native/src) defines no numbers of its own. Every constant it uses is
## gathered here from the scripts that document it (biology.gd, cell.gd, genome.gd, dish.gd) and
## handed over once. Add a constant to the native code by adding it to this dictionary and to
## native/src/params.h, never by writing the value in C++.

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
		"fine_step": Dish.FINE_STEP,
		"diffuse_interval": Dish.DIFFUSE_INTERVAL,
		"division_spread": Dish.DIVISION_SPREAD,
		"death_rate": Biology.DEATH_PER_SECOND,
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
		"memory_efficiency": Cell.MEMORY_EFFICIENCY,
		"mean_cos_turn": Cell.MEAN_COS_TURN,
		"signal_cos": Cell.SIGNAL_COS,
		"drift_half": Cell.DRIFT_HALF,
		"drift_noise": Cell.DRIFT_NOISE,
		"max_drift_fraction": Biology.MAX_DRIFT_FRACTION,
		"run_seconds": Biology.RUN_SECONDS,
		"trait_mutations": Genome.TRAIT_MUTATIONS,
		"harmful_mutations": Genome.HARMFUL_MUTATIONS,
		"compensatory_mutations": Genome.COMPENSATORY_MUTATIONS,
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
	}
