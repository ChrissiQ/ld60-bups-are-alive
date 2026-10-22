#pragma once
// The simulation core: the bups, their genomes and mutation, both forms of motion (real runs and
// tumbles at slow playback, drift-diffusion at fast playback), growth, uptake, division, death,
// and the dissolved nutrient they live in. GDScript (scripts/dish.gd) owns everything else:
// drawing, selection, sources, saving, goals. All lengths are µm, times seconds, and positions are
// relative to the dish centre.
#include "nutrient_field.h"
#include "params.h"

#include <limits>

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

// A random stream: splitmix64, with Marsaglia's polar method for normals (two independent normals per draw: one is
// returned, the other kept for the next call). The simulation has one of its own, and each chunk of bups that is moved in
// parallel gets another, seeded from it, so that a run comes out the same on any number of threads.
struct Rng {
	uint64_t state = 1;
	double spare = 0.0; // the second normal of the last polar draw, if `has_spare`
	bool has_spare = false;

	void seed(uint64_t value) {
		state = value;
		has_spare = false;
	}
	uint64_t next_bits() {
		state += 0x9E3779B97F4A7C15ULL;
		uint64_t z = state;
		z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
		z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
		return z ^ (z >> 31);
	}
	double uniform() { return (double)(next_bits() >> 11) * (1.0 / 9007199254740992.0); }
	double gaussian() {
		if (has_spare) {
			has_spare = false;
			return spare;
		}
		double u, v, s;
		do {
			u = 2.0 * uniform() - 1.0;
			v = 2.0 * uniform() - 1.0;
			s = u * u + v * v;
		} while (s >= 1.0 || s == 0.0);
		double scale = std::sqrt(-2.0 * std::log(s) / s);
		spare = v * scale;
		has_spare = true;
		return u * scale;
	}
};

class BupSim : public RefCounted {
	GDCLASS(BupSim, RefCounted)

	struct Bup {
		int64_t id = 0;
		float x = 0, y = 0, dx = 1, dy = 0;
		float px = std::numeric_limits<float>::quiet_NaN(), py = std::numeric_limits<float>::quiet_NaN(); // where it was in the last picture (none yet: NaN), for its trail
		float energy = 0, mass = 0, birth_mass = 0;
		int generation = 0;
		float genes[4] = { 0, 0, 0, 0 }; // speed, sense, metabolism, size
		float hue = 0, sat = 0, val = 0, harm = 0; // colour is hue, saturation and value (0..1 each)
		int mutations = 0;
		// derived from the genome
		float yield = 1, add_mass = 8, drag_upkeep = 0, effective_diffusion = 0;
		// chemotaxis state (slow playback)
		float fast = 0, slow = 0, noise = 0, tumbling = 0;
		bool primed = false;
	};
	struct Genome {
		float genes[4];
		float hue, sat, val, harm;
		int mutations;
		bool lethal;
	};

	// The family record of every bup that is alive, and of every dead one that still has a living
	// descendant or is being looked at (see `holds`). Dead bups are only ever in this table, never in
	// `bups`, so the simulation step never visits them. Times are whole minutes of simulation time.
	struct Record {
		int64_t parent = 0; // 0: a founder
		int born = 0, died = -1;
		int holds = 0; // records that name this one as their parent, plus pins: while any, a dead record stays
		int generation = 0, mutations = 0;
		float genes[4] = { 0, 0, 0, 0 };
		float hue = 0, sat = 0, val = 0, harm = 0;
		float max_energy = 0; // the reserve it could hold, as it was when it died
		String name; // what the player called it, if anything: it lives and goes with the record
		bool alive = true;
	};
	std::unordered_map<int64_t, Record> records;
	double now_seconds = 0.0;
	double upkeep_scale = 1.0; // multiplies the base and per-mass maintenance costs (a harsher dish)
	int now_minutes() const { return (int)(now_seconds / 60.0); }
	void make_record(const Bup &b, int64_t parent);
	void record_death(const Bup &b);
	void free_if_unused(int64_t id);
	Dictionary record_info(int64_t id, const Record &r) const;

	std::vector<Bup> bups;
	Ref<NutrientField> field;
	int64_t next_id = 1;
	Rng rng; // the simulation's own random stream
	double diffuse_accum = 0.0, feed_energy = 0.0;

	int64_t death_gap(double p);
	double uniform() { return rng.uniform(); }
	double gaussian() { return rng.gaussian(); }
	int poisson(double mean);
	double gamma(double shape);
	void note_mutation(Genome &g);
	Genome mutate(const Genome &parent);
	void derive(Bup &b);
	int find(int64_t id) const;
	Bup *get(int64_t id);

	double size_of(const Bup &b) const;
	double sense_range(const Bup &b) const;
	// The rules the step applies to a bup, in one place each: the single-bup functions the tests call use these
	// same ones, so what the tests check is what the simulation does.
	bool ready_to_divide(const Bup &b) const;
	void eat(Bup &b, double food_energy) const;
	Vector2 split_off(Bup &b, double keep_share); // the mother keeps `keep_share`; returns the daughter's mass and energy
	double body_radius(const Bup &b) const; // half the body's length, in µm
	double drawn_length(const Bup &b, double pixel_um) const; // the length it is drawn at: its own, but never less than shows on screen
	double drawn_width(double pixel_um) const;
	double upkeep(const Bup &b) const;
	double max_energy(const Bup &b) const;
	double uptake_wanted(const Bup &b, double concentration, double delta) const;
	double estimate_error(const Bup &b, double concentration) const;
	double tumble_rate(Bup &b, double concentration, double delta, double noise);
	double drift_fraction(const Bup &b, double log_gradient, double concentration, double noise) const;
	void pay_upkeep_and_grow(Bup &b, double delta); // one bup's step of living: it pays its upkeep from its reserve and grows with what is left
	void swim_by_runs(Bup &b, double delta, Rng &r);
	void keep_inside(Bup &b, Rng &r);
	void keep_inside(Bup &b) { keep_inside(b, rng); }

	// Moving the bups is the bulk of a step and each bup's move depends only on its own state and on the (not yet changed)
	// nutrient field, so it is done in chunks of bups, in parallel. A chunk's random numbers come from its own stream
	// (seeded from one draw of the simulation's), so the result does not depend on how many threads there are.
	static constexpr int SWIM_CHUNK = 512;
	struct SwimJob {
		BupSim *sim;
		double delta, sub; // the step, and one of its motion sub-steps
		bool fine; // runs and tumbles (a short step), or drift-diffusion
		int moves; // sub-steps
		uint64_t seed;
	};
	static void run_swim_chunk(void *job, uint32_t chunk);
	void swim_chunk(const SwimJob &job, uint32_t chunk);
	void drift_chunk(const SwimJob &job, size_t first, size_t last, Rng &r);
	int threads = 0; // 0: as many as the machine has; 1: just this one (the results are the same)
	int cap() const;
	int limit = 0; // the most bups the dish holds; 0 means the default for its radius
	double radius = 300.0;

protected:
	static void _bind_methods();

public:
	BupSim();
	static String configure(const Dictionary &constants);
	void reset(double dish_radius, int64_t seed);
	void set_seed(int64_t seed);
	void set_limit(int bup_limit) { limit = bup_limit; }
	void set_upkeep_scale(double scale) { upkeep_scale = scale; }
	void set_threads(int count) { threads = count; }
	void grow(double new_radius); // a larger dish; the bups and the nutrient stay
	int shrink(double new_radius); // a smaller dish about the same centre: bups past the new edge die (the number is returned), the nutrient there goes
	Ref<NutrientField> get_field() const { return field; }
	double random_float() { return uniform(); }
	Vector2 random_point(double reach);

	// `id` < 0 gives the bup the next number in birth order; a saved game passes the bup's own number back
	int64_t add_bup(const Vector2 &pos, const Dictionary &genome, double energy, double size, double birth_mass, int generation, const Vector2 &dir, int64_t id = -1, int64_t parent = 0);
	int64_t get_next_id() const { return next_id; }
	void set_next_id(int64_t value) { next_id = std::max(value, next_id); }
	int bup_count() const { return (int)bups.size(); }
	bool has_bup(int64_t id) const {
		auto it = records.find(id);
		return it != records.end() && it->second.alive;
	}
	PackedInt64Array bup_ids() const;
	Dictionary bup_info(int64_t id) const;
	void remove_bup(int64_t id);
	void clear_bups() {
		bups.clear();
		records.clear();
	}
	void set_time(double seconds) { now_seconds = seconds; }
	bool has_record(int64_t id) const { return records.count(id) > 0; }
	int record_count() const { return (int)records.size(); }
	Dictionary lineage_info(int64_t id) const;
	PackedInt64Array lineage_chain(int64_t id) const;
	bool pin(int64_t id);
	void unpin(int64_t id);
	Array lineage_export() const;
	void lineage_import(const Array &saved, const PackedInt64Array &pinned = PackedInt64Array()); // `pinned`: ids to keep a hold on, whatever else is pruned
	void set_bup_energy(int64_t id, double energy);
	void set_bup_pos(int64_t id, const Vector2 &pos);

	// single-bup operations, for the tests that pin the biology
	double bup_upkeep(int64_t id) const;
	double bup_max_energy(int64_t id) const;
	double bup_uptake(int64_t id, double concentration, double delta) const;
	void bup_pay_upkeep_and_grow(int64_t id, double delta);
	void bup_eat(int64_t id, double food_energy);
	bool bup_ready(int64_t id) const;
	Vector2 bup_split(int64_t id, double keep);
	double bup_tumble_rate(int64_t id, double concentration, double delta, double noise);
	double bup_sense_range(int64_t id) const;
	Vector3 bup_steering(int64_t id) const;
	PackedByteArray bup_steer_bytes(int64_t id, double max_alpha) const;
	double bup_radius(int64_t id, double pixel_um) const; // half the length it is drawn at: its own, or the least that shows
	Dictionary mutate_genome(const Dictionary &genome);
	double sample_gamma(double shape);

	Dictionary population_stats() const; // the count and the averages the readouts show, in one pass over the bups
	double fraction_with_gene_at_least(const String &name, double threshold) const;
	int64_t pick_bup(const Vector2 &local, double slack, double pixel_um) const;
	Vector2 nearest_and_count(const Vector2 &local, double near) const;

	void step(double delta, const PackedVector2Array &source_pos, const PackedFloat32Array &source_rates, double feed_per_minute, double sim_time = -1.0);
	PackedFloat32Array render_buffer(double pixel_um, int capacity); // (it also notes where each bup was drawn, so the next picture can draw its trail)
	Vector2 bup_pos(int64_t id) const;
	void set_custom_name(int64_t id, const String &name);
	String custom_name(int64_t id) const;
};

} // namespace godot
