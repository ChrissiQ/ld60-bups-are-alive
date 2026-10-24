#pragma once
// Every number the native simulation uses comes from GDScript, once, as a Dictionary built by
// scripts/sim_constants.gd from scripts/biology.gd, cell.gd, genome.gd and dish.gd. This file only
// names them: it defines no value of its own, so there is a single home for each constant.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#define BUP_PARAMS(X) \
	X(diffusion) X(field_target_spacing) X(field_min_across) X(field_max_across) \
	X(nutrient_energy) X(max_cells) X(motion_step) X(motion_structure) X(cloud_handover) X(cloud_cut) X(steering_window) X(fine_step) X(diffuse_interval) X(diffuse_accuracy) \
	X(division_spread) X(death_rate) X(death_release) \
	X(growth_rate) X(cost_per_mass) X(reserve_per_mass) X(maintenance_floor) X(base_upkeep) \
	X(maintenance_per_mass) X(drag_upkeep) X(sense_upkeep) X(uptake_per_size) X(half_saturation) \
	X(detection_floor) X(noise_reference) X(gradient_noise) X(reference_sense) X(reference_size) \
	X(mass_um) X(width) X(tumble_base) X(chemotaxis_gain) X(tumble_up_factor) X(tumble_seconds) \
	X(tumble_turn_mean) X(tumble_turn_spread) X(rotational_diffusion) X(memory_short) X(memory_long) \
	X(trait_mutations) X(harmful_mutations) \
	X(compensatory_mutations) X(lethal_fraction) X(harm_shape) X(mean_harm) X(mean_repair) \
	X(max_harm) X(hue_step) X(sat_step) X(val_step) X(val_min) X(add_mass_factor) X(min_length_px) X(min_width_px) \
	X(founder_hue) X(founder_sat) X(founder_val) X(max_trail_px)

namespace godot {

// The natural logarithm to about 1e-6, without a call to the maths library (which, twice for every bup in every sub-step of
// the coarse motion, was the biggest single cost). For finite x > 0: the exponent comes out of the number's bits and the
// logarithm of what is left, in [1, 2), from the series of 2 atanh((m - 1) / (m + 1)).
inline double fast_log(double x) {
	uint64_t bits;
	memcpy(&bits, &x, sizeof(bits));
	int exponent = (int)((bits >> 52) & 0x7FF) - 1023;
	bits = (bits & 0x000FFFFFFFFFFFFFULL) | 0x3FF0000000000000ULL;
	double m;
	memcpy(&m, &bits, sizeof(m));
	double t = (m - 1.0) / (m + 1.0), t2 = t * t;
	double series = 2.0 * t * (1.0 + t2 * (1.0 / 3.0 + t2 * (1.0 / 5.0 + t2 * (1.0 / 7.0 + t2 * (1.0 / 9.0)))));
	return exponent * 0.6931471805599453 + series;
}

// exp(x) for x <= 0 to about 2e-5 (relative), without the maths library: 2^(x log2 e), the whole part as an exponent and the
// rest by the series of 2^f.
inline double fast_exp(double x) {
	if (x < -700.0) {
		return 0.0;
	}
	double t = x * 1.4426950408889634;
	double whole = std::floor(t);
	double f = t - whole;
	double p = 1.0 + f * (0.6931471805599453 + f * (0.2402265069591007 + f * (0.0555041086648216 + f * (0.0096181291076285 + f * (0.0013333558146428 + f * 0.0001540353039338)))));
	uint64_t bits = (uint64_t)((int64_t)whole + 1023) << 52;
	double scale;
	memcpy(&scale, &bits, sizeof(scale));
	return p * scale;
}

// How a swimmer moves over many runs and tumbles at once (the coarse model of long steps), measured from the real
// run-and-tumble model by tools/gen_motion_table.gd and handed over in scripts/motion_table.gd. Everything is a function
// of two numbers: s, the swimmer's speed times the log-gradient of the nutrient (how steep a slope it faces, in its own
// units), and eps, the error in its estimate of that slope (see sense_error). Tabulated on lattices even in log s and log
// eps, and read by bilinear interpolation in the logs. `drift` is the mean speed up the slope as a share of swim speed;
// `d_along` and `d_across` the diffusion along and across it, per speed squared; `d_flat` the diffusion with no slope.
struct MotionTable {
	int ns = 0, ne = 0;
	std::vector<double> s_axis, e_axis, drift, d_along, d_across, d_flat;
	double ls0 = 0, dls = 1, le0 = 0, dle = 1;

	// Returns false if the arrays don't make a table (the sizes disagree, or an axis is too short or not rising).
	bool set(const Array &s, const Array &e, const Array &f, const Array &along, const Array &across, const Array &flat) {
		ns = (int)s.size();
		ne = (int)e.size();
		if (ns < 2 || ne < 2 || f.size() != ns * ne || along.size() != ns * ne || across.size() != ns * ne || flat.size() != ne) {
			return false;
		}
		auto copy = [](const Array &a) {
			std::vector<double> v((size_t)a.size());
			for (int i = 0; i < a.size(); i++) {
				v[(size_t)i] = (double)a[i];
			}
			return v;
		};
		s_axis = copy(s);
		e_axis = copy(e);
		drift = copy(f);
		d_along = copy(along);
		d_across = copy(across);
		d_flat = copy(flat);
		if (!(s_axis[0] > 0.0 && s_axis[ns - 1] > s_axis[0] && e_axis[0] > 0.0 && e_axis[ne - 1] > e_axis[0])) {
			return false;
		}
		ls0 = std::log(s_axis[0]);
		dls = (std::log(s_axis[ns - 1]) - ls0) / (ns - 1);
		le0 = std::log(e_axis[0]);
		dle = (std::log(e_axis[ne - 1]) - le0) / (ne - 1);
		return true;
	}

	// Below the smallest tabulated s the drift falls linearly to nothing and the diffusion to the no-slope value
	// (a flat medium is the s = 0 row); beyond the table in s or eps, the nearest edge.
	inline void lookup(double s, double eps, double &f, double &along, double &across) const {
		double below = 1.0;
		if (s < s_axis[0]) {
			below = s / s_axis[0];
			s = s_axis[0];
		}
		double x = std::clamp((fast_log(s) - ls0) / dls, 0.0, (double)(ns - 1) - 1e-9);
		double y = std::clamp((fast_log(std::max(eps, 1e-12)) - le0) / dle, 0.0, (double)(ne - 1) - 1e-9);
		int i = (int)x, j = (int)y;
		double tx = x - i, ty = y - j;
		int k00 = i * ne + j, k10 = k00 + ne, k01 = k00 + 1, k11 = k10 + 1;
		double w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty;
		f = below * (drift[k00] * w00 + drift[k10] * w10 + drift[k01] * w01 + drift[k11] * w11);
		along = d_along[k00] * w00 + d_along[k10] * w10 + d_along[k01] * w01 + d_along[k11] * w11;
		across = d_across[k00] * w00 + d_across[k10] * w10 + d_across[k01] * w01 + d_across[k11] * w11;
		if (below < 1.0) {
			double flat = d_flat[j] * (1 - ty) + d_flat[j + 1] * ty;
			along = flat + (along - flat) * below;
			across = flat + (across - flat) * below;
		}
	}
};

struct Params {
#define X(n) double n = 0.0;
	BUP_PARAMS(X)
#undef X
	double gene_min[4] = { 0, 0, 0, 0 }, gene_max[4] = { 0, 0, 0, 0 }, gene_step[4] = { 0, 0, 0, 0 };
	MotionTable motion;
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
		if (!motion.set(d.get("motion_s", Array()), d.get("motion_e", Array()), d.get("motion_drift", Array()), d.get("motion_d_along", Array()), d.get("motion_d_across", Array()), d.get("motion_d_flat", Array()))) {
			missing += "motion_s/motion_e/motion_drift/motion_d_along/motion_d_across/motion_d_flat ";
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

// How surely a swimmer of this speed and sense range goes up the slope where the concentration is c and its gradient is
// `gradient`: the chance that, after steering_window seconds of swimming, it is further up the slope than it started (0.5
// when it cannot tell, up to 1). From the motion table: along the slope it moves a mean F v T with a variance of 2 D v^2 T
// (F the drift as a share of speed, D the diffusion per speed squared), so the chance is the normal distribution's at
// F sqrt(T / 2 D).
inline double steering_chance(double speed, double sense_range, double c, double gradient) {
	double s = speed * gradient / (G.detection_floor + c);
	double f, along, across;
	G.motion.lookup(s, sense_error(sense_range, c), f, along, across);
	double z = f * std::sqrt(G.steering_window / (2.0 * std::max(along, 1e-6)));
	return 0.5 * (1.0 + std::erf(z / std::sqrt(2.0)));
}

} // namespace godot
