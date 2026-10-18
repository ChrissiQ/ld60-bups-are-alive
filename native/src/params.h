#pragma once
// Every number the native simulation uses comes from GDScript, once, as a Dictionary built by
// scripts/sim_constants.gd from scripts/biology.gd, cell.gd, genome.gd and dish.gd. This file only
// names them: it defines no value of its own, so there is a single home for each constant.
#include <algorithm>
#include <cmath>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#define BUP_PARAMS(X) \
	X(diffusion) X(field_target_spacing) X(field_min_across) X(field_max_across) \
	X(nutrient_energy) X(max_cells) X(motion_step) X(fine_step) X(diffuse_interval) \
	X(division_spread) X(death_rate) \
	X(growth_rate) X(cost_per_mass) X(reserve_per_mass) X(maintenance_floor) X(base_upkeep) \
	X(maintenance_per_mass) X(drag_upkeep) X(sense_upkeep) X(uptake_per_size) X(half_saturation) \
	X(detection_floor) X(noise_reference) X(gradient_noise) X(reference_sense) X(reference_size) \
	X(mass_um) X(width) X(tumble_base) X(chemotaxis_gain) X(tumble_up_factor) X(tumble_seconds) \
	X(tumble_turn_mean) X(tumble_turn_spread) X(rotational_diffusion) X(memory_short) X(memory_long) \
	X(memory_efficiency) X(mean_cos_turn) X(signal_cos) X(drift_half) X(drift_noise) \
	X(max_drift_fraction) X(run_seconds) X(trait_mutations) X(harmful_mutations) \
	X(compensatory_mutations) X(lethal_fraction) X(harm_shape) X(mean_harm) X(mean_repair) \
	X(max_harm) X(hue_step) X(sat_step) X(val_step) X(val_min) X(add_mass_factor) X(min_length_px) X(min_width_px) \
	X(founder_hue) X(founder_sat) X(founder_val)

namespace godot {

struct Params {
#define X(n) double n = 0.0;
	BUP_PARAMS(X)
#undef X
	double gene_min[4] = { 0, 0, 0, 0 }, gene_max[4] = { 0, 0, 0, 0 }, gene_step[4] = { 0, 0, 0, 0 };
	bool loaded = false;

	// Returns the names of any constants missing from the dictionary (empty when all were present).
	String load(const Dictionary &d) {
		String missing;
#define X(n) \
	if (d.has(#n)) { n = (double)d[#n]; } else { missing += String(#n) + " "; }
		BUP_PARAMS(X)
#undef X
		Array mins = d.get("gene_min", Array()), maxs = d.get("gene_max", Array()), steps = d.get("gene_step", Array());
		if (mins.size() == 4 && maxs.size() == 4 && steps.size() == 4) {
			for (int i = 0; i < 4; i++) {
				gene_min[i] = mins[i];
				gene_max[i] = maxs[i];
				gene_step[i] = steps[i];
			}
		} else {
			missing += "gene_min/gene_max/gene_step ";
		}
		loaded = missing.is_empty();
		return missing;
	}
};

extern Params G; // set by BupSim.configure(); read by every native class

// How well a bup reads the medium (Berg & Purcell): the error in its estimate of the change in
// concentration falls with the receptor array (the sense range) and with the square root of the concentration.
inline double sense_error(double sense_range, double c) {
	return std::min(G.gradient_noise * (G.reference_sense / sense_range) * std::sqrt(G.noise_reference / std::max(c, 1e-5)), 5.0);
}

// The drift a bup registers per unit of log-gradient and per unit of speed (see BupSim::drift_fraction).
inline double drift_gain() {
	return (G.memory_long - G.memory_short) * G.memory_efficiency * G.signal_cos;
}

// Signal over noise of the coarse model's up-gradient drift, for a swimmer of this speed and sense range at a
// point with this concentration and gradient. Its normal CDF is the chance a step's drift goes up the slope.
inline double steering_snr(double speed, double sense_range, double c, double gradient) {
	return speed * gradient / (G.detection_floor + c) * drift_gain() / (G.drift_noise * sense_error(sense_range, c));
}

} // namespace godot
