#include "bup_sim.h"

#include <godot_cpp/classes/worker_thread_pool.hpp>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <unordered_set>

using namespace godot;

namespace godot {
Params G;
}

namespace {
const char *GENE_NAMES[4] = { "speed", "sense", "metabolism", "size" };

int gene_index(const String &name) {
	for (int i = 0; i < 4; i++) {
		if (name == GENE_NAMES[i]) {
			return i;
		}
	}
	return -1;
}

double fposmod1(double v) {
	return v - std::floor(v);
}

// The words of the GPU's records and events (little-endian 32-bit words, as the GPU writes them).
const float NO_PICTURE = 3e38f; // px, py of a record with no last picture (any value from 1e30 up means the same)
const int BIRTH_WORDS = 16, DEATH_WORDS = 8;
void put_u32(uint8_t *record, int word, uint32_t v) { memcpy(record + word * 4, &v, 4); }
void put_f32(uint8_t *record, int word, float v) { memcpy(record + word * 4, &v, 4); }
uint32_t get_u32(const uint8_t *record, int word) {
	uint32_t v;
	memcpy(&v, record + word * 4, 4);
	return v;
}
float get_f32(const uint8_t *record, int word) {
	float v;
	memcpy(&v, record + word * 4, 4);
	return v;
}
int64_t get_id(const uint8_t *record, int lo_word, int hi_word) {
	return (int64_t)((uint64_t)get_u32(record, lo_word) | ((uint64_t)get_u32(record, hi_word) << 32));
}
} // namespace

void BupSim::_bind_methods() {
	ClassDB::bind_static_method("BupSim", D_METHOD("configure", "constants"), &BupSim::configure);
	ClassDB::bind_method(D_METHOD("reset", "dish_radius", "seed"), &BupSim::reset);
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &BupSim::set_seed);
	ClassDB::bind_method(D_METHOD("set_limit", "bup_limit"), &BupSim::set_limit);
	ClassDB::bind_method(D_METHOD("set_upkeep_scale", "scale"), &BupSim::set_upkeep_scale);
	ClassDB::bind_method(D_METHOD("set_husk_seconds", "seconds"), &BupSim::set_husk_seconds);
	ClassDB::bind_method(D_METHOD("husk_count"), &BupSim::husk_count);
	ClassDB::bind_method(D_METHOD("husks_export"), &BupSim::husks_export);
	ClassDB::bind_method(D_METHOD("husks_import", "saved"), &BupSim::husks_import);
	ClassDB::bind_method(D_METHOD("grow", "new_radius"), &BupSim::grow);
	ClassDB::bind_method(D_METHOD("shrink", "new_radius"), &BupSim::shrink);
	ClassDB::bind_method(D_METHOD("set_threads", "count"), &BupSim::set_threads);
	ClassDB::bind_method(D_METHOD("export_state"), &BupSim::export_state);
	ClassDB::bind_method(D_METHOD("export_state_bytes"), &BupSim::export_state_bytes);
	ClassDB::bind_method(D_METHOD("import_state_bytes", "state"), &BupSim::import_state_bytes);
	ClassDB::bind_method(D_METHOD("info_from_state", "state", "index"), &BupSim::info_from_state);
	ClassDB::bind_method(D_METHOD("apply_events", "births", "deaths", "first_step_end_seconds", "step_seconds"), &BupSim::apply_events);
	ClassDB::bind_method(D_METHOD("alive_ids"), &BupSim::alive_ids);
	ClassDB::bind_method(D_METHOD("step_world", "delta", "source_pos", "source_rates", "sim_time"), &BupSim::step_world, DEFVAL(-1.0));
	ClassDB::bind_method(D_METHOD("steering_at", "local", "speed", "sense_range"), &BupSim::steering_at);
	ClassDB::bind_method(D_METHOD("get_field"), &BupSim::get_field);
	ClassDB::bind_method(D_METHOD("random_float"), &BupSim::random_float);
	ClassDB::bind_method(D_METHOD("random_point", "reach"), &BupSim::random_point);
	ClassDB::bind_method(D_METHOD("add_bup", "pos", "genome", "energy", "size", "birth_mass", "generation", "dir", "id", "parent"), &BupSim::add_bup, DEFVAL(-1), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("set_time", "seconds"), &BupSim::set_time);
	ClassDB::bind_method(D_METHOD("has_record", "id"), &BupSim::has_record);
	ClassDB::bind_method(D_METHOD("record_count"), &BupSim::record_count);
	ClassDB::bind_method(D_METHOD("lineage_info", "id"), &BupSim::lineage_info);
	ClassDB::bind_method(D_METHOD("lineage_chain", "id"), &BupSim::lineage_chain);
	ClassDB::bind_method(D_METHOD("pin", "id"), &BupSim::pin);
	ClassDB::bind_method(D_METHOD("unpin", "id"), &BupSim::unpin);
	ClassDB::bind_method(D_METHOD("lineage_export"), &BupSim::lineage_export);
	ClassDB::bind_method(D_METHOD("lineage_import", "saved", "pinned"), &BupSim::lineage_import, DEFVAL(PackedInt64Array()));
	ClassDB::bind_method(D_METHOD("lineage_export_bytes"), &BupSim::lineage_export_bytes);
	ClassDB::bind_method(D_METHOD("lineage_import_bytes", "data", "pinned"), &BupSim::lineage_import_bytes, DEFVAL(PackedInt64Array()));
	ClassDB::bind_method(D_METHOD("get_next_id"), &BupSim::get_next_id);
	ClassDB::bind_method(D_METHOD("set_next_id", "value"), &BupSim::set_next_id);
	ClassDB::bind_method(D_METHOD("bup_count"), &BupSim::bup_count);
	ClassDB::bind_method(D_METHOD("has_bup", "id"), &BupSim::has_bup);
	ClassDB::bind_method(D_METHOD("bup_ids"), &BupSim::bup_ids);
	ClassDB::bind_method(D_METHOD("bup_info", "id"), &BupSim::bup_info);
	ClassDB::bind_method(D_METHOD("remove_bup", "id"), &BupSim::remove_bup);
	ClassDB::bind_method(D_METHOD("clear_bups"), &BupSim::clear_bups);
	ClassDB::bind_method(D_METHOD("set_bup_energy", "id", "energy"), &BupSim::set_bup_energy);
	ClassDB::bind_method(D_METHOD("set_bup_pos", "id", "pos"), &BupSim::set_bup_pos);
	ClassDB::bind_method(D_METHOD("bup_upkeep", "id"), &BupSim::bup_upkeep);
	ClassDB::bind_method(D_METHOD("bup_max_energy", "id"), &BupSim::bup_max_energy);
	ClassDB::bind_method(D_METHOD("bup_uptake", "id", "concentration", "delta"), &BupSim::bup_uptake);
	ClassDB::bind_method(D_METHOD("bup_pay_upkeep_and_grow", "id", "delta"), &BupSim::bup_pay_upkeep_and_grow);
	ClassDB::bind_method(D_METHOD("bup_eat", "id", "food_energy"), &BupSim::bup_eat);
	ClassDB::bind_method(D_METHOD("bup_ready", "id"), &BupSim::bup_ready);
	ClassDB::bind_method(D_METHOD("bup_split", "id", "keep"), &BupSim::bup_split);
	ClassDB::bind_method(D_METHOD("bup_tumble_rate", "id", "concentration", "delta", "noise"), &BupSim::bup_tumble_rate);
	ClassDB::bind_method(D_METHOD("moves_for", "delta"), &BupSim::moves_for);
	ClassDB::bind_method(D_METHOD("diffuse_pieces", "seconds"), &BupSim::diffuse_pieces);
	ClassDB::bind_method(D_METHOD("bup_sense_range", "id"), &BupSim::bup_sense_range);
	ClassDB::bind_method(D_METHOD("bup_estimate_error", "id", "concentration"), &BupSim::bup_estimate_error);
	ClassDB::bind_method(D_METHOD("bup_steering", "id"), &BupSim::bup_steering);
	ClassDB::bind_method(D_METHOD("bup_steer_bytes", "id", "max_alpha"), &BupSim::bup_steer_bytes);
	ClassDB::bind_method(D_METHOD("bup_radius", "id", "pixel_um"), &BupSim::bup_radius);
	ClassDB::bind_method(D_METHOD("bup_pos", "id"), &BupSim::bup_pos);
	ClassDB::bind_method(D_METHOD("set_custom_name", "id", "name"), &BupSim::set_custom_name);
	ClassDB::bind_method(D_METHOD("custom_name", "id"), &BupSim::custom_name);
	ClassDB::bind_method(D_METHOD("mutate_genome", "genome"), &BupSim::mutate_genome);
	ClassDB::bind_method(D_METHOD("sample_gamma", "shape"), &BupSim::sample_gamma);
	ClassDB::bind_method(D_METHOD("population_stats"), &BupSim::population_stats);
	ClassDB::bind_method(D_METHOD("fraction_with_gene_at_least", "name", "threshold"), &BupSim::fraction_with_gene_at_least);
	ClassDB::bind_method(D_METHOD("pick_bup", "local", "slack", "pixel_um"), &BupSim::pick_bup);
	ClassDB::bind_method(D_METHOD("nearest_and_count", "local", "radius"), &BupSim::nearest_and_count);
	ClassDB::bind_method(D_METHOD("step", "delta", "source_pos", "source_rates", "feed_per_second", "sim_time"), &BupSim::step, DEFVAL(-1.0));
	ClassDB::bind_method(D_METHOD("render_buffer", "pixel_um", "capacity"), &BupSim::render_buffer);
}

BupSim::BupSim() {
	field.instantiate();
}

String BupSim::configure(const Dictionary &constants) {
	String missing = G.load(constants);
	if (!missing.is_empty()) {
		ERR_PRINT("BupSim.configure: missing constants: " + missing);
	}
	return missing;
}

// ---- random numbers -------------------------------------------------------------------------

int BupSim::poisson(double mean) {
	double limit = std::exp(-mean);
	int count = 0;
	double p = uniform();
	while (p > limit) {
		count++;
		p *= uniform();
	}
	return count;
}

// Marsaglia and Tsang, boosted for shape < 1.
double BupSim::gamma(double shape) {
	if (shape < 1.0) {
		return gamma(shape + 1.0) * std::pow(std::max(uniform(), 1e-12), 1.0 / shape);
	}
	double d = shape - 1.0 / 3.0, c = 1.0 / std::sqrt(9.0 * d);
	while (true) {
		double x = gaussian();
		double v = 1.0 + c * x;
		if (v <= 0.0) {
			continue;
		}
		v = v * v * v;
		double u = std::max(uniform(), 1e-12);
		if (std::log(u) < 0.5 * x * x + d - d * v + d * std::log(v)) {
			return d * v;
		}
	}
}

void BupSim::set_seed(int64_t seed) {
	rng.seed((uint64_t)seed * 2654435761ULL + 12345ULL);
}

void BupSim::reset(double dish_radius, int64_t seed) {
	radius = dish_radius;
	field->reset(dish_radius);
	bups.clear();
	records.clear();
	husks.clear();
	now_seconds = 0.0;
	bups.reserve(cap() + 16);
	next_id = 1;
	diffuse_accum = 0.0;
	feed_concentration = 0.0;
	if (seed >= 0) { // a negative seed keeps the random stream going, so a restart is a new game
		set_seed(seed);
	}
}

void BupSim::grow(double new_radius) {
	if (new_radius <= radius) {
		return;
	}
	radius = new_radius;
	field->resize(new_radius);
}

// The dish shrinks about its centre. A bup whose centre is past the new edge dies like any other death (so its family
// record is freed unless a living descendant or an open view still needs it); one straddling the edge is moved inside.
int BupSim::shrink(double new_radius) {
	if (new_radius >= radius || new_radius <= 0.0) {
		return 0;
	}
	radius = new_radius;
	field->resize(new_radius);
	husks.erase(std::remove_if(husks.begin(), husks.end(), [new_radius](const Husk &h) { return std::sqrt((double)h.x * h.x + (double)h.y * h.y) > new_radius; }), husks.end());
	size_t keep = 0;
	int culled = 0;
	for (size_t i = 0; i < bups.size(); i++) {
		if (std::sqrt((double)bups[i].x * bups[i].x + (double)bups[i].y * bups[i].y) > new_radius) {
			record_death(bups[i]);
			culled++;
			continue;
		}
		if (keep != i) {
			bups[keep] = bups[i];
		}
		keep_inside(bups[keep]);
		keep++;
	}
	bups.resize(keep);
	return culled;
}

Vector2 BupSim::random_point(double reach) {
	double a = uniform() * Math::TAU, r = reach * std::sqrt(uniform());
	return Vector2((float)(r * std::cos(a)), (float)(r * std::sin(a)));
}

int BupSim::cap() const {
	return limit > 0 ? limit : std::max((int)G.max_cells, (int)radius);
}

// ---- genomes and mutation -------------------------------------------------------------------

void BupSim::note_mutation(Genome &g) {
	g.mutations++;
	// Colour is a neutral marker, not a trait selection acts on: it drifts, so lineages grow apart in colour.
	// Hue wraps round the wheel; saturation and brightness stay within what shows up against the dark dish.
	g.hue = (float)fposmod1(g.hue + gaussian() * G.hue_step);
	g.sat = (float)std::clamp((double)g.sat + gaussian() * G.sat_step, 0.0, 1.0);
	g.val = (float)std::clamp((double)g.val + gaussian() * G.val_step, G.val_min, 1.0);
}

BupSim::Genome BupSim::mutate(const Genome &parent) {
	Genome g = parent;
	g.lethal = false;
	int traits = poisson(G.trait_mutations);
	for (int i = 0; i < traits; i++) {
		int gene = (int)(uniform() * 4.0) % 4;
		double changed = std::clamp((double)g.genes[gene] + gaussian() * G.gene_step[gene], G.gene_min[gene], G.gene_max[gene]);
		if ((float)changed != g.genes[gene]) { // a push against a bound changes nothing and is not counted
			g.genes[gene] = (float)changed;
			note_mutation(g);
		}
	}
	int harmful = poisson(G.harmful_mutations);
	for (int i = 0; i < harmful; i++) {
		if (uniform() < G.lethal_fraction) {
			g.lethal = true;
		} else {
			g.harm = (float)std::min((double)g.harm + gamma(G.harm_shape) * G.mean_harm / G.harm_shape, G.max_harm);
		}
		note_mutation(g);
	}
	if (g.harm > 0.0f) {
		int repairs = poisson(G.compensatory_mutations);
		for (int i = 0; i < repairs; i++) {
			g.harm = (float)std::max((double)g.harm + std::log(std::max(uniform(), 1e-12)) * G.mean_repair, 0.0);
			note_mutation(g);
		}
	}
	return g;
}

Dictionary BupSim::mutate_genome(const Dictionary &genome) {
	Genome parent;
	for (int i = 0; i < 4; i++) {
		parent.genes[i] = (float)(double)genome.get(GENE_NAMES[i], 0.0);
	}
	parent.hue = (float)(double)genome.get("hue", G.founder_hue);
	parent.sat = (float)(double)genome.get("sat", G.founder_sat);
	parent.val = (float)(double)genome.get("val", G.founder_val);
	parent.harm = (float)(double)genome.get("harm", 0.0);
	parent.mutations = (int)genome.get("mutations", 0);
	parent.lethal = false;
	Genome child = mutate(parent);
	Dictionary out;
	for (int i = 0; i < 4; i++) {
		out[GENE_NAMES[i]] = child.genes[i];
	}
	out["hue"] = child.hue;
	out["sat"] = child.sat;
	out["val"] = child.val;
	out["harm"] = child.harm;
	out["mutations"] = child.mutations;
	out["lethal"] = child.lethal;
	return out;
}

double BupSim::sample_gamma(double shape) {
	return gamma(shape);
}

// ---- bup bookkeeping ------------------------------------------------------------------------

void BupSim::derive(Bup &b) const {
	double size_gene = b.genes[3];
	b.add_mass = (float)(G.add_mass_factor * size_gene * size_gene);
	b.yield = (float)(std::exp(-(double)b.harm) / std::sqrt((double)b.genes[2]));
	b.drag_upkeep = (float)(G.drag_upkeep * (double)b.genes[0] * b.genes[0]);
}

int BupSim::find(int64_t id) const {
	for (size_t i = 0; i < bups.size(); i++) {
		if (bups[i].id == id) {
			return (int)i;
		}
	}
	return -1;
}

BupSim::Bup *BupSim::get(int64_t id) {
	int i = find(id);
	return i < 0 ? nullptr : &bups[i];
}

int64_t BupSim::add_bup(const Vector2 &pos, const Dictionary &genome, double energy, double size, double birth_mass, int generation, const Vector2 &dir, int64_t id, int64_t parent) {
	Bup b;
	if (id > 0 && !has_bup(id)) { // (every bup in `bups` has a living record: a look-up, not a search, so a big saved dish loads in time)
		b.id = id;
		next_id = std::max(next_id, id + 1);
	} else {
		b.id = next_id++;
	}
	b.x = pos.x;
	b.y = pos.y;
	Vector2 d = dir.length() > 1e-6f ? dir.normalized() : Vector2(1, 0);
	b.dx = d.x;
	b.dy = d.y;
	for (int i = 0; i < 4; i++) {
		b.genes[i] = (float)(double)genome.get(GENE_NAMES[i], 0.0);
	}
	b.hue = (float)(double)genome.get("hue", G.founder_hue);
	b.sat = (float)(double)genome.get("sat", G.founder_sat);  // (the usual saturation, for a genome built without one)
	b.val = (float)(double)genome.get("val", G.founder_val);
	b.harm = (float)(double)genome.get("harm", 0.0);
	b.mutations = (int)genome.get("mutations", 0);
	b.generation = generation;
	derive(b);
	b.birth_mass = (float)(birth_mass < 0.0 ? b.add_mass : birth_mass);
	b.mass = (float)(size < 0.0 ? b.birth_mass : size * size);
	b.energy = (float)std::min(energy, max_energy(b));
	bups.push_back(b);
	make_record(b, parent);
	return b.id;
}

// ---- family records ------------------------------------------------------------------------

void BupSim::make_record(const Bup &b, int64_t parent) {
	Record r;
	auto p = records.find(parent);
	if (p != records.end()) {
		r.parent = parent;
		p->second.holds++;
	}
	r.born = now_minutes();
	r.generation = b.generation;
	r.mutations = b.mutations;
	for (int g = 0; g < 4; g++) {
		r.genes[g] = b.genes[g];
	}
	r.hue = b.hue;
	r.sat = b.sat;
	r.val = b.val;
	r.harm = b.harm;
	records[b.id] = r;
}

// The bup has died: its record stays only if something living (or being looked at) still needs it.
void BupSim::record_death(const Bup &b) {
	auto it = records.find(b.id);
	if (it == records.end()) {
		return;
	}
	Record &r = it->second;
	r.alive = false;
	r.died = now_minutes();
	r.generation = b.generation;
	r.max_energy = (float)max_energy(b);
	free_if_unused(b.id);
}

// Frees a dead record nothing holds, and then the parents that leaves with nothing holding them.
void BupSim::free_if_unused(int64_t id) {
	while (id > 0) {
		auto it = records.find(id);
		if (it == records.end() || it->second.alive || it->second.holds > 0) {
			return;
		}
		int64_t parent = it->second.parent;
		records.erase(it);
		auto p = records.find(parent);
		if (p != records.end()) {
			p->second.holds--;
		}
		id = parent;
	}
}

bool BupSim::pin(int64_t id) {
	auto it = records.find(id);
	if (it == records.end()) {
		return false;
	}
	it->second.holds++;
	return true;
}

void BupSim::unpin(int64_t id) {
	auto it = records.find(id);
	if (it != records.end() && it->second.holds > 0) {
		it->second.holds--;
		free_if_unused(id);
	}
}

Dictionary BupSim::record_info(int64_t id, const Record &r) const {
	Dictionary out;
	out["id"] = id;
	out["parent"] = r.parent;
	out["alive"] = r.alive;
	out["born"] = r.born;
	out["died"] = r.alive ? -1 : r.died;
	out["generation"] = r.generation;
	out["speed"] = r.genes[0];
	out["sense"] = r.genes[1];
	out["metabolism"] = r.genes[2];
	out["size_gene"] = r.genes[3];
	out["hue"] = r.hue;
	out["sat"] = r.sat;
	out["val"] = r.val;
	out["harm"] = r.harm;
	out["mutations"] = r.mutations;
	out["max_energy"] = r.max_energy;
	out["name"] = r.name;
	return out;
}

// What is known of a bup, alive or dead (empty if its record has been freed).
Dictionary BupSim::lineage_info(int64_t id) const {
	auto it = records.find(id);
	if (it == records.end()) {
		return Dictionary();
	}
	Dictionary out = record_info(id, it->second);
	int i = it->second.alive ? find(id) : -1;
	if (i >= 0) { // alive: the figures that change as it lives are the current ones
		out["generation"] = bups[i].generation;
		out["max_energy"] = max_energy(bups[i]);
	}
	return out;
}

// The family line that led to this bup: its oldest known ancestor first, the bup itself last.
PackedInt64Array BupSim::lineage_chain(int64_t id) const {
	std::vector<int64_t> up;
	while (id > 0) {
		auto it = records.find(id);
		if (it == records.end()) {
			break;
		}
		up.push_back(id);
		id = it->second.parent;
	}
	PackedInt64Array out;
	out.resize((int64_t)up.size());
	for (size_t k = 0; k < up.size(); k++) {
		out.set((int64_t)k, up[up.size() - 1 - k]);
	}
	return out;
}

Array BupSim::lineage_export() const {
	Array out;
	for (const auto &entry : records) {
		out.push_back(record_info(entry.first, entry.second));
	}
	return out;
}

// A saved game's records: they replace those of the same numbers, and the counts that keep a dead
// record are worked out again from the parents.
void BupSim::lineage_import(const Array &saved, const PackedInt64Array &pinned) {
	std::unordered_set<int64_t> living; // (looked up, not searched for: a big dish has as many records as bups)
	living.reserve(bups.size());
	for (const Bup &b : bups) {
		living.insert(b.id);
	}
	for (int i = 0; i < saved.size(); i++) {
		Dictionary d = saved[i];
		int64_t id = (int64_t)(double)d.get("id", 0);
		if (id <= 0) {
			continue;
		}
		Record r;
		r.parent = (int64_t)(double)d.get("parent", 0);
		r.born = (int)(double)d.get("born", 0);
		r.died = (int)(double)d.get("died", -1);
		r.generation = (int)(double)d.get("generation", 0);
		r.mutations = (int)(double)d.get("mutations", 0);
		r.genes[0] = (float)(double)d.get("speed", 0.0);
		r.genes[1] = (float)(double)d.get("sense", 0.0);
		r.genes[2] = (float)(double)d.get("metabolism", 0.0);
		r.genes[3] = (float)(double)d.get("size_gene", 0.0);
		r.hue = (float)(double)d.get("hue", G.founder_hue);
		r.sat = (float)(double)d.get("sat", G.founder_sat);
		r.val = (float)(double)d.get("val", G.founder_val);
		r.harm = (float)(double)d.get("harm", 0.0);
		r.max_energy = (float)(double)d.get("max_energy", 0.0);
		r.name = d.get("name", String());
		r.alive = living.count(id) > 0;
		if (r.alive) {
			r.died = -1;
		}
		records[id] = r;
	}
	finish_lineage_import(pinned);
}

// After a save's records are in: the counts that keep a dead record are worked out again from the parents, the watched ones are
// pinned, and the dead records nothing holds are let go.
void BupSim::finish_lineage_import(const PackedInt64Array &pinned) {
	for (auto &entry : records) {
		entry.second.holds = 0;
	}
	for (auto &entry : records) {
		auto p = records.find(entry.second.parent);
		if (p == records.end()) {
			entry.second.parent = 0;
		} else {
			p->second.holds++;
		}
	}
	for (int i = 0; i < pinned.size(); i++) { // (before the pruning below, so a dead bup that is being watched survives it)
		pin(pinned[i]);
	}
	std::vector<int64_t> loose;
	for (const auto &entry : records) {
		if (!entry.second.alive && entry.second.holds == 0) {
			loose.push_back(entry.first);
		}
	}
	for (int64_t id : loose) {
		free_if_unused(id);
	}
}

namespace {
template <typename T>
void put(uint8_t *&at, T value) {
	memcpy(at, &value, sizeof(T));
	at += sizeof(T);
}
template <typename T>
T take(const uint8_t *&at) {
	T value;
	memcpy(&value, at, sizeof(T));
	at += sizeof(T);
	return value;
}
} // namespace

PackedByteArray BupSim::lineage_export_bytes() const {
	int64_t names = 0, name_bytes = 0;
	for (const auto &entry : records) {
		if (!entry.second.name.is_empty()) {
			names++;
			name_bytes += entry.second.name.utf8().length();
		}
	}
	PackedByteArray out;
	out.resize(4 + (int64_t)records.size() * LINEAGE_BYTES + 4 + names * 12 + name_bytes);
	uint8_t *at = out.ptrw();
	put<uint32_t>(at, (uint32_t)records.size());
	for (const auto &entry : records) {
		const Record &r = entry.second;
		put<int64_t>(at, entry.first);
		put<int64_t>(at, r.parent);
		put<int32_t>(at, r.born);
		put<int32_t>(at, r.died);
		put<int32_t>(at, r.generation);
		put<int32_t>(at, r.mutations);
		for (int g = 0; g < 4; g++) {
			put<float>(at, r.genes[g]);
		}
		put<float>(at, r.hue);
		put<float>(at, r.sat);
		put<float>(at, r.val);
		put<float>(at, r.harm);
		put<float>(at, r.max_energy);
	}
	put<uint32_t>(at, (uint32_t)names);
	for (const auto &entry : records) {
		if (entry.second.name.is_empty()) {
			continue;
		}
		CharString utf8 = entry.second.name.utf8();
		put<int64_t>(at, entry.first);
		put<uint32_t>(at, (uint32_t)utf8.length());
		memcpy(at, utf8.get_data(), utf8.length());
		at += utf8.length();
	}
	return out;
}

void BupSim::lineage_import_bytes(const PackedByteArray &data, const PackedInt64Array &pinned) {
	ERR_FAIL_COND_MSG(data.size() < 8, "BupSim.lineage_import_bytes: too short");
	const uint8_t *begin = data.ptr();
	const uint8_t *end = begin + data.size();
	const uint8_t *at = begin;
	uint32_t count = take<uint32_t>(at);
	ERR_FAIL_COND_MSG((int64_t)count * LINEAGE_BYTES + 8 > data.size(), "BupSim.lineage_import_bytes: fewer records than it says");
	std::unordered_set<int64_t> living; // (looked up, not searched for: a big dish has as many records as bups)
	living.reserve(bups.size());
	for (const Bup &b : bups) {
		living.insert(b.id);
	}
	records.reserve(records.size() + count);
	for (uint32_t i = 0; i < count; i++) {
		int64_t id = take<int64_t>(at);
		Record r;
		r.parent = take<int64_t>(at);
		r.born = take<int32_t>(at);
		r.died = take<int32_t>(at);
		r.generation = take<int32_t>(at);
		r.mutations = take<int32_t>(at);
		for (int g = 0; g < 4; g++) {
			r.genes[g] = take<float>(at);
		}
		r.hue = take<float>(at);
		r.sat = take<float>(at);
		r.val = take<float>(at);
		r.harm = take<float>(at);
		r.max_energy = take<float>(at);
		r.alive = living.count(id) > 0;
		if (r.alive) {
			r.died = -1;
		}
		if (id > 0) {
			records[id] = r;
		}
	}
	uint32_t names = take<uint32_t>(at);
	for (uint32_t i = 0; i < names; i++) {
		ERR_FAIL_COND_MSG(end - at < 12, "BupSim.lineage_import_bytes: names cut short");
		int64_t id = take<int64_t>(at);
		uint32_t length = take<uint32_t>(at);
		ERR_FAIL_COND_MSG((int64_t)(end - at) < (int64_t)length, "BupSim.lineage_import_bytes: a name is cut short");
		auto found = records.find(id);
		if (found != records.end()) {
			found->second.name = String::utf8((const char *)at, (int)length);
		}
		at += length;
	}
	finish_lineage_import(pinned);
}

PackedInt64Array BupSim::bup_ids() const {
	PackedInt64Array out;
	out.resize((int64_t)bups.size());
	for (size_t i = 0; i < bups.size(); i++) {
		out.set((int64_t)i, bups[i].id);
	}
	return out;
}

void BupSim::remove_bup(int64_t id) {
	int i = find(id);
	if (i >= 0) {
		Bup gone = bups[i];
		bups.erase(bups.begin() + i);
		record_death(gone);
	}
}

void BupSim::set_bup_energy(int64_t id, double energy) {
	if (Bup *b = get(id)) {
		b->energy = (float)energy;
	}
}

void BupSim::set_bup_pos(int64_t id, const Vector2 &pos) {
	if (Bup *b = get(id)) {
		b->x = pos.x;
		b->y = pos.y;
	}
}

Dictionary BupSim::bup_info(int64_t id) const {
	int i = find(id);
	if (i < 0) {
		return Dictionary();
	}
	return info_of(bups[i]);
}

Dictionary BupSim::info_of(const Bup &b) const {
	Dictionary out;
	out["id"] = b.id;
	out["pos"] = Vector2(b.x, b.y);
	out["dir"] = Vector2(b.dx, b.dy);
	out["energy"] = b.energy;
	out["max_energy"] = max_energy(b);
	auto record = records.find(b.id);
	out["born"] = record == records.end() ? 0 : record->second.born;
	out["mass"] = b.mass;
	out["birth_mass"] = b.birth_mass;
	out["size"] = size_of(b);
	out["length"] = b.mass * G.mass_um;
	out["generation"] = b.generation;
	out["speed"] = b.genes[0];
	out["sense"] = b.genes[1];
	out["metabolism"] = b.genes[2];
	out["size_gene"] = b.genes[3];
	out["hue"] = b.hue;
	out["sat"] = b.sat;
	out["val"] = b.val;
	out["harm"] = b.harm;
	out["mutations"] = b.mutations;
	out["upkeep"] = upkeep(b);
	out["steering"] = steering_of(b.x, b.y, b.genes[0], sense_range(b)).z;
	return out;
}

// ---- the biology of one bup -----------------------------------------------------------------

double BupSim::size_of(const Bup &b) const {
	return std::sqrt((double)b.mass);
}

double BupSim::sense_range(const Bup &b) const {
	return b.genes[1] * std::sqrt(size_of(b) / G.reference_size);
}

bool BupSim::ready_to_divide(const Bup &b) const {
	return b.mass >= b.birth_mass + b.add_mass;
}

void BupSim::eat(Bup &b, double food_energy) const {
	b.energy = (float)std::min((double)b.energy + food_energy * b.yield, max_energy(b));
}

Vector2 BupSim::split_off(Bup &b, double keep_share) {
	Vector2 daughter((float)(b.mass * (1.0 - keep_share)), (float)(b.energy * (1.0 - keep_share)));
	b.mass = (float)(b.mass * keep_share);
	b.energy = (float)(b.energy * keep_share);
	b.birth_mass = b.mass;
	return daughter;
}

double BupSim::body_radius(const Bup &b) const {
	return 0.5 * b.mass * G.mass_um;
}

// A bup is drawn at its true size, unless that is too small to see: then it is drawn at the least that shows
// (so far out, every bup is the same small mark, and at true-size zoom nothing changes). Each bup on its own.
double BupSim::drawn_length(const Bup &b, double pixel_um) const {
	return std::max(2.0 * body_radius(b), G.min_length_px * pixel_um);
}

double BupSim::drawn_width(double pixel_um) const {
	return std::max((double)G.width, G.min_width_px * pixel_um);
}

double BupSim::upkeep(const Bup &b) const {
	return upkeep_scale * (G.base_upkeep + G.maintenance_per_mass * b.mass) + b.drag_upkeep * size_of(b) + G.sense_upkeep * b.genes[1];
}

double BupSim::max_energy(const Bup &b) const {
	return G.reserve_per_mass * b.mass;
}

double BupSim::uptake_wanted(const Bup &b, double concentration, double delta) const {
	double wanted = G.uptake_per_size * size_of(b) * b.genes[2] * concentration / (G.half_saturation + concentration) * delta;
	return std::min(wanted, std::max(max_energy(b) - b.energy, 0.0) / b.yield);
}

double BupSim::estimate_error(const Bup &b, double concentration) const {
	return sense_error(sense_range(b), concentration);
}

double BupSim::tumble_rate(Bup &b, double concentration, double delta, double noise) {
	double memory = std::exp(-delta / G.memory_short);
	b.noise = (float)(b.noise * memory + std::sqrt(1.0 - memory * memory) * noise);
	double signal = std::log(1.0 + concentration / G.detection_floor);
	if (!b.primed) {
		b.fast = (float)signal;
		b.slow = (float)signal;
		b.primed = true;
	}
	b.fast += (float)((signal - b.fast) * (1.0 - memory));
	b.slow += (float)((signal - b.slow) * (1.0 - std::exp(-delta / G.memory_long)));
	return G.tumble_base * std::clamp(1.0 - G.chemotaxis_gain * ((double)b.fast - b.slow + estimate_error(b, concentration) * b.noise), G.tumble_up_factor, 1.0);
}

void BupSim::pay_upkeep_and_grow(Bup &b, double delta) {
	b.energy -= (float)(upkeep(b) * delta);
	if (b.energy <= G.maintenance_floor) {
		return;
	}
	double grow = std::min(G.growth_rate * b.genes[2] * b.mass * delta, (b.energy - G.maintenance_floor) / G.cost_per_mass);
	b.energy -= (float)(grow * G.cost_per_mass);
	b.mass += (float)grow;
}

// Run and tumble: a bup knows nothing of where food is. It senses the concentration where it is
// (on a log scale), compares it with its own recent past, and tumbles less often while it improves.
void BupSim::swim_by_runs(Bup &b, double delta, Rng &r) {
	double c, gx, gy;
	field->read_snapshot_xy(b.x, b.y, c, gx, gy);
	double rate = tumble_rate(b, c, delta, r.gaussian());
	if (b.tumbling > 0.0f) { // while tumbling a bup doesn't swim
		b.tumbling -= (float)delta;
		return;
	}
	double dx = b.dx, dy = b.dy;
	if (r.uniform() < rate * delta) {
		b.tumbling = (float)G.tumble_seconds;
		double turn = r.gaussian() * G.tumble_turn_spread + G.tumble_turn_mean;
		if (r.uniform() >= 0.5) {
			turn = -turn;
		}
		double cs = std::cos(turn), sn = std::sin(turn);
		double nx = dx * cs - dy * sn, ny = dx * sn + dy * cs;
		dx = nx;
		dy = ny;
	} else {
		double turn = r.gaussian() * G.rotational_diffusion * std::sqrt(delta);
		double cs = std::cos(turn), sn = std::sin(turn);
		double nx = dx * cs - dy * sn, ny = dx * sn + dy * cs;
		dx = nx;
		dy = ny;
	}
	double len = std::sqrt(dx * dx + dy * dy);
	if (len > 0.0) {
		dx /= len;
		dy /= len;
	}
	b.dx = (float)dx;
	b.dy = (float)dy;
	b.x += (float)(dx * b.genes[0] * delta);
	b.y += (float)(dy * b.genes[0] * delta);
}

// The wall: a swimmer that reaches it is turned along it, and slides until a tumble frees it.
void BupSim::keep_inside(Bup &b, Rng &r) {
	double limit = radius - body_radius(b);
	double dist = std::sqrt((double)b.x * b.x + (double)b.y * b.y);
	if (dist <= limit) {
		return;
	}
	double nx = b.x / dist, ny = b.y / dist;
	b.x = (float)(nx * limit);
	b.y = (float)(ny * limit);
	double dot = b.dx * nx + b.dy * ny;
	double ax = b.dx - nx * dot, ay = b.dy - ny * dot;
	double al = std::sqrt(ax * ax + ay * ay);
	if (al < 0.1) {
		double s = r.uniform() < 0.5 ? 1.0 : -1.0;
		ax = -ny * s;
		ay = nx * s;
		al = 1.0;
	}
	b.dx = (float)(ax / al);
	b.dy = (float)(ay / al);
}

// ---- single-bup operations for the tests ---------------------------------------------------

#define WITH_BUP(id, fallback) \
	int _i = find(id); \
	if (_i < 0) { \
		return fallback; \
	} \
	const Bup &b = bups[_i];

double BupSim::bup_upkeep(int64_t id) const { WITH_BUP(id, 0.0) return upkeep(b); }
double BupSim::bup_max_energy(int64_t id) const { WITH_BUP(id, 0.0) return max_energy(b); }
double BupSim::bup_uptake(int64_t id, double concentration, double delta) const { WITH_BUP(id, 0.0) return uptake_wanted(b, concentration, delta); }
double BupSim::bup_sense_range(int64_t id) const { WITH_BUP(id, 0.0) return sense_range(b); }
double BupSim::bup_estimate_error(int64_t id, double concentration) const { WITH_BUP(id, 0.0) return estimate_error(b, concentration); }

// Which way this bup's drift tends (the unit vector up the gradient where it is) and how surely it goes that way: the
// chance that it ends up further up the slope after a minute of swimming (steering_chance), 0.5 when it cannot tell,
// up to 1.
Vector3 BupSim::bup_steering(int64_t id) const {
	WITH_BUP(id, Vector3(0, 0, 0.5))
	return steering_of(b.x, b.y, b.genes[0], sense_range(b));
}

// The same for any swimmer of this speed and sense range at a point (for a bup that lives on the GPU).
Vector3 BupSim::steering_at(const Vector2 &local, double speed, double sense_range) const {
	return steering_of(local.x, local.y, speed, sense_range);
}

Vector3 BupSim::steering_of(double x, double y, double speed, double sense_range) const {
	double c, gx, gy;
	field->read_xy(x, y, c, gx, gy);
	double glen = std::sqrt(gx * gx + gy * gy);
	double chance = steering_chance(speed, sense_range, c, glen);
	return glen > 1e-12 ? Vector3((float)(gx / glen), (float)(gy / glen), (float)chance) : Vector3(0, 0, 0.5);
}

PackedByteArray BupSim::bup_steer_bytes(int64_t id, double max_alpha) const {
	WITH_BUP(id, PackedByteArray())
	return field->steer_bytes(b.genes[0], sense_range(b), max_alpha);
}
double BupSim::bup_radius(int64_t id, double pixel_um) const { WITH_BUP(id, 0.0) return 0.5 * drawn_length(b, pixel_um); }
bool BupSim::bup_ready(int64_t id) const { WITH_BUP(id, false) return ready_to_divide(b); }

void BupSim::bup_pay_upkeep_and_grow(int64_t id, double delta) {
	if (Bup *b = get(id)) {
		pay_upkeep_and_grow(*b, delta);
	}
}

void BupSim::bup_eat(int64_t id, double food_energy) {
	if (Bup *b = get(id)) {
		eat(*b, food_energy);
	}
}

Vector2 BupSim::bup_split(int64_t id, double keep) {
	Bup *b = get(id);
	if (!b) {
		return Vector2();
	}
	return split_off(*b, keep);
}

double BupSim::bup_tumble_rate(int64_t id, double concentration, double delta, double noise) {
	Bup *b = get(id);
	return b ? tumble_rate(*b, concentration, delta, noise) : 0.0;
}

// ---- statistics and picking ----------------------------------------------------------------

Dictionary BupSim::population_stats() const {
	double genes[4] = { 0, 0, 0, 0 }, harm = 0.0, mutations = 0.0;
	for (const Bup &b : bups) {
		for (int g = 0; g < 4; g++) {
			genes[g] += b.genes[g];
		}
		harm += 1.0 - std::exp(-(double)b.harm); // the share of food yield lost to harm
		mutations += b.mutations;
	}
	double n = bups.empty() ? 1.0 : (double)bups.size();
	Dictionary out;
	out["count"] = (int)bups.size();
	for (int g = 0; g < 4; g++) {
		out[GENE_NAMES[g]] = genes[g] / n;
	}
	out["harm"] = harm / n;
	out["mutations"] = mutations / n;
	return out;
}

double BupSim::fraction_with_gene_at_least(const String &name, double threshold) const {
	int g = gene_index(name);
	if (g < 0 || bups.empty()) {
		return 0.0;
	}
	int n = 0;
	for (const Bup &b : bups) {
		n += b.genes[g] >= threshold ? 1 : 0;
	}
	return (double)n / bups.size();
}

int64_t BupSim::pick_bup(const Vector2 &local, double slack, double pixel_um) const {
	int64_t best = -1;
	double best_d2 = 1e300;
	for (const Bup &b : bups) {
		double reach = 0.5 * drawn_length(b, pixel_um) + slack;
		double dx = b.x - local.x, dy = b.y - local.y;
		double d2 = dx * dx + dy * dy;
		if (d2 <= reach * reach && d2 < best_d2) {
			best = b.id;
			best_d2 = d2;
		}
	}
	return best;
}

// The distance to the nearest bup (-1 when there are none) and how many bups lie within `near`.
Vector2 BupSim::nearest_and_count(const Vector2 &local, double near) const {
	double nearest_sq = -1.0, near_sq = near * near;
	int count = 0;
	for (const Bup &b : bups) {
		double dx = b.x - local.x, dy = b.y - local.y;
		double d_sq = dx * dx + dy * dy;
		if (nearest_sq < 0.0 || d_sq < nearest_sq) {
			nearest_sq = d_sq;
		}
		if (d_sq <= near_sq) {
			count++;
		}
	}
	return Vector2(nearest_sq < 0.0 ? -1.0f : (float)std::sqrt(nearest_sq), (float)count);
}

// Every bup as 24 floats: id, x, y, dx, dy, energy, mass, birth_mass, speed, sense, metabolism, size, yield, add_mass, drag_upkeep, harm,
// hue, sat, val, mutations, generation, parent id (0: not kept here), 2 spare.
PackedFloat32Array BupSim::export_state() const {
	PackedFloat32Array out;
	out.resize((int64_t)bups.size() * 24);
	float *w = out.ptrw();
	for (size_t i = 0; i < bups.size(); i++) {
		const Bup &b = bups[i];
		float *p = w + i * 24;
		p[0] = (float)b.id;
		p[1] = b.x;
		p[2] = b.y;
		p[3] = b.dx;
		p[4] = b.dy;
		p[5] = b.energy;
		p[6] = b.mass;
		p[7] = b.birth_mass;
		p[8] = b.genes[0];
		p[9] = b.genes[1];
		p[10] = b.genes[2];
		p[11] = b.genes[3];
		p[12] = b.yield;
		p[13] = b.add_mass;
		p[14] = b.drag_upkeep;
		p[15] = b.harm;
		p[16] = b.hue;
		p[17] = b.sat;
		p[18] = b.val;
		p[19] = (float)b.mutations;
		p[20] = (float)b.generation;
		p[21] = 0.0f;
		p[22] = 0.0f;
		p[23] = 0.0f;
	}
	return out;
}

// ---- the GPU simulation's records and events ------------------------------------------------

// Every bup as the GPU simulation's record (gpu/kernels.gd): 24 32-bit words, 0 the id's low word, 1-20 x, y, dx, dy, energy, mass,
// birth_mass, speed, sense, metabolism, size, yield, add_mass, drag_upkeep, harm, hue, sat, val, mutations, generation (floats),
// 21 the id's high word, 22-23 where it was in the last picture (NO_PICTURE if nowhere yet).
PackedByteArray BupSim::export_state_bytes() const {
	PackedByteArray out;
	out.resize((int64_t)bups.size() * STATE_WORDS * 4);
	uint8_t *w = out.ptrw();
	for (size_t i = 0; i < bups.size(); i++) {
		const Bup &b = bups[i];
		uint8_t *r = w + i * STATE_WORDS * 4;
		const float words[20] = { b.x, b.y, b.dx, b.dy, b.energy, b.mass, b.birth_mass, b.genes[0], b.genes[1], b.genes[2], b.genes[3], b.yield,
			b.add_mass, b.drag_upkeep, b.harm, b.hue, b.sat, b.val, (float)b.mutations, (float)b.generation };
		put_u32(r, 0, (uint32_t)((uint64_t)b.id & 0xFFFFFFFFULL));
		for (int k = 0; k < 20; k++) {
			put_f32(r, 1 + k, words[k]);
		}
		put_u32(r, 21, (uint32_t)((uint64_t)b.id >> 32));
		put_f32(r, 22, std::isnan(b.px) ? NO_PICTURE : b.px);
		put_f32(r, 23, std::isnan(b.py) ? NO_PICTURE : b.py);
	}
	return out;
}

BupSim::Bup BupSim::bup_from_record(const uint8_t *record) const {
	Bup b;
	b.id = get_id(record, 0, 21);
	b.x = get_f32(record, 1);
	b.y = get_f32(record, 2);
	b.dx = get_f32(record, 3);
	b.dy = get_f32(record, 4);
	b.energy = get_f32(record, 5);
	b.mass = get_f32(record, 6);
	b.birth_mass = get_f32(record, 7);
	for (int g = 0; g < 4; g++) {
		b.genes[g] = get_f32(record, 8 + g);
	}
	b.harm = get_f32(record, 15);
	b.hue = get_f32(record, 16);
	b.sat = get_f32(record, 17);
	b.val = get_f32(record, 18);
	b.mutations = (int)get_f32(record, 19);
	b.generation = (int)get_f32(record, 20);
	float px = get_f32(record, 22), py = get_f32(record, 23);
	b.px = px >= 1e30f ? std::numeric_limits<float>::quiet_NaN() : px;
	b.py = py >= 1e30f ? std::numeric_limits<float>::quiet_NaN() : py;
	derive(b); // (yield, add_mass and drag_upkeep, as the CPU works them out)
	return b;
}

// The bups become those of the records (as export_state_bytes makes them); the family records are left as they are (on the GPU path
// they are kept up by apply_events, which must have been given every birth and death up to this state first). The swimmers' memory
// of the slow playback starts afresh. The next id never goes back past an id in the state.
void BupSim::import_state_bytes(const PackedByteArray &state) {
	ERR_FAIL_COND_MSG(state.size() % (STATE_WORDS * 4) != 0, "BupSim.import_state_bytes: not a whole number of 96-byte records");
	size_t count = (size_t)state.size() / (STATE_WORDS * 4);
	const uint8_t *r = state.ptr();
	bups.clear();
	bups.reserve(count);
	int64_t largest = 0;
	for (size_t i = 0; i < count; i++) {
		bups.push_back(bup_from_record(r + i * STATE_WORDS * 4));
		largest = std::max(largest, bups.back().id);
	}
	next_id = std::max(next_id, largest + 1);
}

// What bup_info would say of the bup in record `index` of `state` (its birth from the records, its steering from the field as it is).
Dictionary BupSim::info_from_state(const PackedByteArray &state, int index) const {
	ERR_FAIL_COND_V_MSG(state.size() % (STATE_WORDS * 4) != 0, Dictionary(), "BupSim.info_from_state: not a whole number of 96-byte records");
	if (index < 0 || (int64_t)index >= state.size() / (STATE_WORDS * 4)) {
		return Dictionary();
	}
	return info_of(bup_from_record(state.ptr() + (size_t)index * STATE_WORDS * 4));
}

// The family records of a batch of GPU steps (little-endian 32-bit words):
//   a birth, 16 words: id lo, id hi, parent lo, parent hi, step, generation, mutations (uints), speed, sense, metabolism, size, hue, sat,
//     val, harm (floats), 0;
//   a death, 8 words: id lo, id hi, step, generation (uints), mass, x, y, the nutrient energy it gives back (floats; 0 for one that does not:
//     a trimmed one). With husks on, the last three make the husk.
// `step` is the step's place in the batch (from 0), and step k ended at first_step_end_seconds + k * step_seconds, which is when its
// records are stamped. Each list is in the order of its steps. Step by step, the births are recorded and then the deaths (a bup never
// divides and dies in the same step, except one displaced at the limit after dividing, which is held by its daughter either way).
// The bups themselves are not touched. A birth whose id already has a record (a batch given twice) is passed over. The next id is
// kept past every id born.
void BupSim::apply_events(const PackedByteArray &births, const PackedByteArray &deaths, double first_step_end_seconds, double step_seconds) {
	ERR_FAIL_COND_MSG(births.size() % (BIRTH_WORDS * 4) != 0, "BupSim.apply_events: births are 64 bytes each");
	ERR_FAIL_COND_MSG(deaths.size() % (DEATH_WORDS * 4) != 0, "BupSim.apply_events: deaths are 32 bytes each");
	const int64_t born_count = births.size() / (BIRTH_WORDS * 4), died_count = deaths.size() / (DEATH_WORDS * 4);
	const uint8_t *bp = births.ptr(), *dp = deaths.ptr();
	const double now_before = now_seconds; // (the dish's clock is ahead of the batch: it is put back afterwards)
	int64_t bi = 0, di = 0;
	while (bi < born_count || di < died_count) {
		uint32_t step = UINT32_MAX;
		if (bi < born_count) {
			step = get_u32(bp + bi * BIRTH_WORDS * 4, 4);
		}
		if (di < died_count) {
			step = std::min(step, get_u32(dp + di * DEATH_WORDS * 4, 2));
		}
		now_seconds = first_step_end_seconds + step * step_seconds;
		for (; bi < born_count && get_u32(bp + bi * BIRTH_WORDS * 4, 4) == step; bi++) {
			const uint8_t *e = bp + bi * BIRTH_WORDS * 4;
			Bup b;
			b.id = get_id(e, 0, 1);
			if (records.count(b.id) > 0) {
				continue;
			}
			b.generation = (int)get_u32(e, 5);
			b.mutations = (int)get_u32(e, 6);
			for (int g = 0; g < 4; g++) {
				b.genes[g] = get_f32(e, 7 + g);
			}
			b.hue = get_f32(e, 11);
			b.sat = get_f32(e, 12);
			b.val = get_f32(e, 13);
			b.harm = get_f32(e, 14);
			make_record(b, get_id(e, 2, 3));
			next_id = std::max(next_id, b.id + 1); // (a bup added here later never takes a number the GPU has given)
		}
		for (; di < died_count && get_u32(dp + di * DEATH_WORDS * 4, 2) == step; di++) {
			const uint8_t *e = dp + di * DEATH_WORDS * 4;
			Bup b;
			b.id = get_id(e, 0, 1);
			b.generation = (int)get_u32(e, 3);
			b.mass = get_f32(e, 4);
			record_death(b);
			if (husk_seconds > 0.0 && get_f32(e, 7) > 0.0f) {
				add_husk(get_f32(e, 5), get_f32(e, 6), get_f32(e, 7));
			}
		}
	}
	now_seconds = now_before;
}

// The ids of the living bups from their records, in order (bup_ids, for when the bups are on the GPU).
PackedInt64Array BupSim::alive_ids() const {
	std::vector<int64_t> ids;
	ids.reserve(records.size());
	for (const auto &entry : records) {
		if (entry.second.alive) {
			ids.push_back(entry.first);
		}
	}
	std::sort(ids.begin(), ids.end());
	PackedInt64Array out;
	out.resize((int64_t)ids.size());
	if (!ids.empty()) {
		memcpy(out.ptrw(), ids.data(), ids.size() * sizeof(int64_t));
	}
	return out;
}

// ---- the step ------------------------------------------------------------------------------

// How many chances of probability `p` pass before the next success (geometric): the gap to the next bup that dies.
int64_t BupSim::death_gap(double p) {
	if (p <= 0.0) {
		return INT64_MAX;
	}
	double gap = std::floor(std::log(std::max(uniform(), 1e-300)) / std::log1p(-std::min(p, 1.0 - 1e-12)));
	return gap >= 9.0e18 ? INT64_MAX : (int64_t)gap;
}

void BupSim::run_swim_chunk(void *job, uint32_t chunk) {
	const SwimJob *j = (const SwimJob *)job;
	j->sim->swim_chunk(*j, chunk);
}

// Moves the bups of one chunk, and has each pay its upkeep and grow. Touches nothing but those bups (and its own random stream), and only
// reads the field's snapshot, so chunks can run at the same time.
void BupSim::swim_chunk(const SwimJob &job, uint32_t chunk) {
	size_t first = (size_t)chunk * SWIM_CHUNK, last = std::min(first + SWIM_CHUNK, bups.size());
	Rng r;
	r.seed(job.seed + (uint64_t)(chunk + 1) * 0xD1B54A32D192ED03ULL);
	r.next_bits(); // (so that streams from nearby seeds are well apart)
	for (int block = 0; block < uptake_blocks; block++) {
		uptake_lists[(size_t)chunk * uptake_blocks + block].clear();
	}
	if (job.fine) {
		for (size_t i = first; i < last; i++) {
			Bup &b = bups[i];
			swim_by_runs(b, job.sub, r);
			keep_inside(b, r);
			pay_upkeep_and_grow(b, job.delta);
			if (clouds_now) {
				field->cloud_share_xy(b.x, b.y, shares[i]);
			}
			note_uptake(chunk, i);
		}
		return;
	}
	drift_chunk(job, first, last, r);
	for (size_t i = first; i < last; i++) {
		pay_upkeep_and_grow(bups[i], job.delta);
		if (clouds_now) {
			field->cloud_share_xy(bups[i].x, bups[i].y, shares[i]);
		}
		note_uptake(chunk, i);
	}
}

// Files a bup under the cell it takes nutrient from, if it has room for any.
void BupSim::note_uptake(uint32_t chunk, size_t i) {
	Bup &b = bups[i];
	grid_got[i] = -1.0;
	cloud_want[i] = 0.0;
	double full = max_energy(b);
	if (b.energy < (float)full) {
		int cell = field->uptake_cell_xy(b.x, b.y);
		if (cell >= 0) {
			Eater e;
			e.bup = (int)i;
			e.cell = cell;
			e.x = b.x;
			e.y = b.y;
			e.rate = G.uptake_per_size * size_of(b) * b.genes[2];
			e.room = std::max(full - b.energy, 0.0) / b.yield;
			e.clouds = clouds_now ? shares[i].total : 0.0;
			uptake_lists[(size_t)chunk * uptake_blocks + (cell / field->get_size()) / uptake_rows].push_back(e);
		}
	}
}

void BupSim::run_uptake_block(void *job, uint32_t block) {
	const UptakeJob *j = (const UptakeJob *)job;
	j->sim->uptake_block(j->delta, block);
}

// The bups filed under the cells of one block of rows take from them: cell by cell, each cell's bups in the order they are in.
void BupSim::uptake_block(double delta, uint32_t block) {
	const int n = field->get_size();
	const int chunks = ((int)bups.size() + SWIM_CHUNK - 1) / SWIM_CHUNK;
	size_t total = 0;
	for (int chunk = 0; chunk < chunks; chunk++) {
		total += uptake_lists[(size_t)chunk * uptake_blocks + block].size();
	}
	if (total == 0) {
		return;
	}
	const int first_cell = (int)block * uptake_rows * n;
	const int cells = std::min(uptake_rows, n - (int)block * uptake_rows) * n;
	thread_local std::vector<int> start;
	thread_local std::vector<Eater> sorted;
	start.assign((size_t)cells + 1, 0);
	sorted.resize(total);
	for (int chunk = 0; chunk < chunks; chunk++) {
		for (const Eater &e : uptake_lists[(size_t)chunk * uptake_blocks + block]) {
			start[(size_t)(e.cell - first_cell) + 1]++;
		}
	}
	for (int c = 0; c < cells; c++) {
		start[(size_t)c + 1] += start[(size_t)c];
	}
	for (int chunk = 0; chunk < chunks; chunk++) { // (chunks in order, bups in order in them: so each cell's are in the order they are in)
		for (const Eater &e : uptake_lists[(size_t)chunk * uptake_blocks + block]) {
			sorted[(size_t)start[(size_t)(e.cell - first_cell)]++] = e;
		}
	}
	for (const Eater &e : sorted) {
		double from_grid = field->uptake_concentration_xy(e.x, e.y, e.cell);
		double concentration = from_grid + e.clouds;
		double wanted = std::min(e.rate * concentration / (G.half_saturation + concentration) * delta, e.room); // (as uptake_wanted)
		if (wanted <= 0.0) {
			continue;
		}
		if (e.clouds <= 0.0) {
			grid_got[e.bup] = field->take_cell(e.cell, wanted);
		} else {
			grid_got[e.bup] = field->take_cell(e.cell, wanted * from_grid / concentration);
			cloud_want[e.bup] = wanted * e.clouds / concentration;
		}
	}
}

// The walk of a step that spans many runs, for the bups first..last: what a run-and-tumble swimmer averages to over many
// runs is a drift up the gradient plus a random walk, both of which the real model measures (see MotionTable in
// params.h; the table is made by tools/gen_motion_table.gd). Each sub-step a bup reads the nutrient where it is, works
// out how steep a slope it faces and how well it can read it, looks up its drift and its diffusion along and across the
// slope, takes that step, and is kept inside the wall (a step that crosses it is reflected, as in a reflecting boundary
// where a crowd stays even; the exact wall of the fine model, with its sliding, is used only to turn the bup).
// The sub-steps go across all the bups in turn, rather than all of one bup's after another: each bup's step is a chain
// of dependent work (read the field, divide, square root, look up), and with several bups in turn the processor can
// overlap those chains. What stays the same for a bup for the whole step is worked out once, the heading is only put in
// the bup when the wall needs it (and at the end), and the wall is first tested without a square root.
void BupSim::drift_chunk(const SwimJob &job, size_t first, size_t last, Rng &r) {
	struct Lane {
		float x, y;
		double sense_k, speed, near_wall2;
		double hx, hy, hl; // the latest displacement long enough to set a heading, not yet put in the bup's dx, dy
		double sub; // this bup's sub-step: finer where a young cloud is within reach of it (see moves_for_structure)
		double c0, gx0, gy0; // what it reads at the start of the step, which its first sub-step uses (it reads again after each move)
		int moves;
		bool pending;
	};
	const size_t count = last - first;
	std::vector<Lane> lanes(count);
	const double floor_c = G.detection_floor, noise_ref = G.noise_reference;
	const MotionTable &motion = G.motion;
	const double spacing = field->get_spacing();
	int max_moves = 1;
	for (size_t i = 0; i < count; i++) {
		Bup &b = bups[first + i];
		b.primed = false; // (the signal memory isn't kept up while drifting)
		Lane &l = lanes[i];
		l.x = b.x;
		l.y = b.y;
		l.sense_k = G.gradient_noise * (G.reference_sense / sense_range(b));
		l.speed = b.genes[0];
		double limit = radius - body_radius(b);
		l.near_wall2 = limit > 0.0 ? limit * limit * (1.0 - 1e-9) : -1.0; // (any bup nearer the wall than this gets the exact test)
		l.hx = l.hy = l.hl = 0.0;
		l.pending = false;
		double cloud_sigma;
		field->probe_snapshot_xy(l.x, l.y, l.c0, l.gx0, l.gy0, cloud_sigma);
		l.moves = moves_for_structure(job.delta, std::min(spacing, 2.0 * cloud_sigma));
		l.sub = job.delta / l.moves;
		max_moves = std::max(max_moves, l.moves);
	}
	for (int m = 0; m < max_moves; m++) {
		for (size_t i = 0; i < count; i++) {
			Lane &l = lanes[i];
			if (m >= l.moves) {
				continue;
			}
			double c, gx, gy;
			if (m == 0) {
				c = l.c0;
				gx = l.gx0;
				gy = l.gy0;
			} else {
				field->read_snapshot_xy(l.x, l.y, c, gx, gy);
			}
			double lx = gx / (floor_c + c), ly = gy / (floor_c + c);
			double glen = std::sqrt(lx * lx + ly * ly);
			double error = std::min(l.sense_k * std::sqrt(noise_ref / std::max(c, 1e-5)), 5.0);
			double f, along, across;
			motion.lookup(l.speed * glen, error, f, along, across);
			double kick = 2.0 * l.speed * l.speed * l.sub, up = r.gaussian() * std::sqrt(along * kick), side = r.gaussian() * std::sqrt(across * kick);
			double sx = up, sy = side;
			if (glen > 1e-9) { // along the slope and across it; with none, in any direction
				double ux = lx / glen, uy = ly / glen;
				up += l.speed * f * l.sub;
				sx = ux * up - uy * side;
				sy = uy * up + ux * side;
			}
			l.x += (float)sx;
			l.y += (float)sy;
			double sl = std::sqrt(sx * sx + sy * sy);
			if (sl > 1e-6) {
				l.hx = sx;
				l.hy = sy;
				l.hl = sl;
				l.pending = true;
			}
			if ((double)l.x * l.x + (double)l.y * l.y > l.near_wall2) { // at the wall: the exact test and the turn, on the bup itself
				Bup &b = bups[first + i];
				double limit = radius - body_radius(b), dist = std::sqrt((double)l.x * l.x + (double)l.y * l.y);
				if (dist > limit && limit > 0.0) { // a step across the wall comes back by as much as it went over (or to the wall, if that is too far in)
					double back = 2.0 * limit - dist;
					back = back < 0.5 * limit ? limit : back;
					l.x = (float)(l.x * back / dist);
					l.y = (float)(l.y * back / dist);
				}
				b.x = l.x;
				b.y = l.y;
				if (l.pending) {
					b.dx = (float)(l.hx / l.hl);
					b.dy = (float)(l.hy / l.hl);
					l.pending = false;
				}
				keep_inside(b, r);
				l.x = b.x;
				l.y = b.y;
			}
		}
	}
	for (size_t i = 0; i < count; i++) {
		Bup &b = bups[first + i];
		const Lane &l = lanes[i];
		b.x = l.x;
		b.y = l.y;
		if (l.pending) {
			b.dx = (float)(l.hx / l.hl);
			b.dy = (float)(l.hy / l.hl);
		}
	}
}


// How many sub-steps a step of the coarse motion is cut into (each reads the nutrient where the bup is, and moves it). The
// longest sub-step is MOTION_STEP on a fine grid. The nutrient has no structure finer than a grid cell, or than a plankton
// cloud (motion_structure), so on a coarser grid a bup that moves a short way across a cell learns nothing from a
// second look, and the sub-step may grow as the square of the cell (a bup's displacement goes as the square root of
// time): the same distance moved, in the field's own units, as on the fine grid. Measured against the shorter sub-steps
// in a field of plankton clouds, that leaves the nutrient the bups end up in within 0.4% (none lost at 90 mm; the same
// sub-step length at 40 mm cost 1.1%, at 20 mm 5%, which is why it is not simply longer).
// How many pieces a long stretch of diffusion is solved in. The solver is implicit and stable at any length, but a long
// piece spreads a sharp patch a little less faithfully, by an amount that goes with D dt / cell^2 (how far the
// nutrient spreads in the piece, in cells): measured against pieces of 5 s, that is 0.3-0.5% of a plankton cloud's peak
// on grids of 200 µm and finer, 0.01-0.03% at 600 µm and nothing beyond. So a piece is cut when that number is above
// diffuse_accuracy, and in no case below the interval.
int BupSim::diffuse_pieces(double seconds) const {
	double spacing = field->get_spacing();
	int by_interval = std::max(1, (int)std::ceil(seconds / G.diffuse_interval - 1e-9));
	int by_accuracy = std::max(1, (int)std::ceil(field->get_diffusion() * seconds / (spacing * spacing) / std::max(G.diffuse_accuracy, 1e-9) - 1e-9));
	return std::min(by_interval, by_accuracy);
}

int BupSim::moves_for(double delta) const {
	return moves_for_structure(delta, field->get_spacing());
}

// The same for a place where the nutrient has structure this fine (a cell of the grid, or a young cloud, if that is finer).
int BupSim::moves_for_structure(double delta, double structure) const {
	double scale = std::max(1.0, structure / std::max(G.motion_structure, 1.0));
	return std::max(1, (int)std::ceil(delta / (G.motion_step * scale * scale)));
}

void BupSim::emit_sources(double delta, const PackedVector2Array &source_pos, const PackedFloat32Array &source_rates) {
	int sources = (int)std::min(source_pos.size(), source_rates.size());
	field->begin_emissions();
	for (int i = 0; i < sources; i++) {
		field->emit_xy(source_pos[i].x, source_pos[i].y, source_rates[i] / 60.0 * delta * G.nutrient_energy, delta);
	}
	field->end_emissions();
}

// Only the sources' part of a step (no feed, diffusion, clouds or bups): what the dish's own world does while the GPU runs the rest.
static const int HUSK_PIECES = 12;
static const size_t MAX_HUSKS = 200000; // past this a death gives its nutrient back at once (as the clouds past MAX_CLOUDS go to the grid)

// The share of a husk's nutrient that leaks in piece k: what an exponential leak lets go in the k-th quarter of a lifetime, and in the last
// piece what is left after the HUSK_PIECES quarters.
static double husk_share(int k) {
	double share = std::exp(-0.25 * k) - std::exp(-0.25 * (k + 1));
	return k == HUSK_PIECES - 1 ? share + std::exp(-0.25 * HUSK_PIECES) : share;
}

void BupSim::add_husk(float x, float y, float energy) {
	if (husks.size() >= MAX_HUSKS) {
		field->add_cloud(Vector2(x, y), 0.0, energy);
		return;
	}
	husks.push_back({ x, y, energy, 0.0, 0 });
}

void BupSim::advance_husks(double delta) {
	if (husks.empty()) {
		return;
	}
	const double quarter = husk_seconds / 4.0;
	size_t i = 0;
	while (i < husks.size()) {
		Husk &h = husks[i];
		h.age += delta;
		while (h.next < HUSK_PIECES && h.age >= (h.next + 0.5) * quarter) {
			field->add_cloud(Vector2(h.x, h.y), 0.0, h.energy * husk_share(h.next));
			h.next++;
		}
		if (h.next >= HUSK_PIECES) {
			h = husks.back();
			husks.pop_back();
		} else {
			i++;
		}
	}
}

PackedFloat64Array BupSim::husks_export() const {
	PackedFloat64Array out;
	out.resize((int64_t)husks.size() * 5);
	double *w = out.ptrw();
	for (size_t i = 0; i < husks.size(); i++) {
		const Husk &h = husks[i];
		w[i * 5] = h.x;
		w[i * 5 + 1] = h.y;
		w[i * 5 + 2] = h.energy;
		w[i * 5 + 3] = h.age;
		w[i * 5 + 4] = h.next;
	}
	return out;
}

void BupSim::husks_import(const PackedFloat64Array &saved) {
	husks.clear();
	const double *r = saved.ptr();
	for (int64_t i = 0; i + 4 < saved.size(); i += 5) {
		husks.push_back({ (float)r[i], (float)r[i + 1], (float)r[i + 2], r[i + 3], (int)r[i + 4] });
	}
}

void BupSim::step_world(double delta, const PackedVector2Array &source_pos, const PackedFloat32Array &source_rates, double sim_time) {
	if (sim_time >= 0.0) {
		now_seconds = sim_time;
	}
	emit_sources(delta, source_pos, source_rates);
	advance_husks(delta);
}

void BupSim::step(double delta, const PackedVector2Array &source_pos, const PackedFloat32Array &source_rates, double feed_per_second, double sim_time) {
	if (sim_time >= 0.0) {
		now_seconds = sim_time;
	}
	emit_sources(delta, source_pos, source_rates);
	advance_husks(delta);
	feed_concentration += feed_per_second * delta;
	diffuse_accum += delta;
	if (diffuse_accum >= G.diffuse_interval) {
		field->fill(feed_concentration);
		feed_concentration = 0.0;
		int pieces = diffuse_pieces(diffuse_accum);
		for (int piece = 0; piece < pieces; piece++) {
			field->diffuse(diffuse_accum / pieces);
		}
		diffuse_accum = 0.0;
	}

	// First every bup moves, pays its upkeep and grows, in parallel (see SwimJob), each reading the nutrient as it is at the start of
	// the step. Then, one at a time, they take up nutrient, die and divide.
	SwimJob job;
	job.sim = this;
	job.delta = delta;
	job.fine = delta <= G.fine_step;
	job.moves = job.fine ? 1 : moves_for(delta);
	job.sub = delta / job.moves;
	job.seed = rng.next_bits();
	field->advance_puffs(delta);
	field->snapshot();
	clouds_now = field->puff_count() > 0;
	if (clouds_now) {
		shares.resize(bups.size());
	}
	int chunks = ((int)bups.size() + SWIM_CHUNK - 1) / SWIM_CHUNK;
	int across = field->get_size();
	uptake_rows = std::max(1, (across + 47) / 48);
	uptake_blocks = (across + uptake_rows - 1) / uptake_rows;
	uptake_lists.resize((size_t)chunks * uptake_blocks);
	grid_got.resize(bups.size());
	cloud_want.resize(bups.size());
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	if (threads == 1 || chunks <= 1 || pool == nullptr) {
		for (int chunk = 0; chunk < chunks; chunk++) {
			swim_chunk(job, (uint32_t)chunk);
		}
	} else {
		WorkerThreadPool::GroupID group = pool->add_native_group_task(&BupSim::run_swim_chunk, &job, chunks, threads > 1 ? threads : -1, true, "bups swim");
		pool->wait_for_group_task_completion(group);
	}
	UptakeJob uptake_job = { this, delta };
	if (threads == 1 || uptake_blocks <= 1 || pool == nullptr || bups.size() < 4000) {
		for (int block = 0; block < uptake_blocks; block++) {
			uptake_block(delta, (uint32_t)block);
		}
	} else {
		WorkerThreadPool::GroupID group = pool->add_native_group_task(&BupSim::run_uptake_block, &uptake_job, uptake_blocks, threads > 1 ? threads : -1, true, "bups eat");
		pool->wait_for_group_task_completion(group);
	}

	size_t keep = 0;
	std::vector<Bup> newborn;
	struct DeathCloud {
		float x, y, energy;
	};
	std::vector<DeathCloud> death_clouds;
	// Each bup that has energy left has the same small chance of dying of something else this step. Rather than a random
	// number for each, the number of such bups until the next death is drawn (the gaps between independent chances of p are
	// geometric): the same odds for every bup, and one draw for each death instead of one for each bup.
	const double death_chance = G.death_rate * delta;
	int64_t until_death = death_gap(death_chance);
	for (size_t i = 0; i < bups.size(); i++) {
		Bup &b = bups[i];
		if (grid_got[i] >= 0.0) { // (the cell's part of the uptake is done; the clouds' is taken here, one bup after another, as they hold thousands of times what a bup takes in a step)
			double got = grid_got[i];
			if (cloud_want[i] > 0.0) {
				got += field->take_from_clouds(b.x, b.y, cloud_want[i], shares[i].total, shares[i]);
			}
			eat(b, got);
		}
		bool dies = b.energy <= 0.0f;
		if (!dies && until_death-- == 0) {
			dies = true;
			until_death = death_gap(death_chance);
		}
		if (dies) {
			record_death(b);
			if (G.death_release > 0.0) { // (what its body was made of goes back to the medium, as a cloud once the step is done)
				death_clouds.push_back({ b.x, b.y, (float)(G.death_release * G.cost_per_mass * b.mass) });
			}
			continue; // died
		}
		if (ready_to_divide(b)) {
			double keep_share = std::clamp(0.5 + G.division_spread * gaussian(), 0.35, 0.65);
			Vector2 daughter = split_off(b, keep_share);
			double daughter_mass = daughter.x, daughter_energy = daughter.y;
			Genome parent = { { b.genes[0], b.genes[1], b.genes[2], b.genes[3] }, b.hue, b.sat, b.val, b.harm, b.mutations, false };
			Genome child_genome = mutate(parent);
			if (!child_genome.lethal) { // a lethal daughter is never born; the parent still paid for her
				Bup child;
				child.id = next_id++;
				for (int g = 0; g < 4; g++) {
					child.genes[g] = child_genome.genes[g];
				}
				child.hue = child_genome.hue;
				child.sat = child_genome.sat;
				child.val = child_genome.val;
				child.harm = child_genome.harm;
				child.mutations = child_genome.mutations;
				derive(child);
				child.mass = (float)daughter_mass;
				child.birth_mass = child.mass;
				child.energy = (float)std::min(daughter_energy, max_energy(child));
				child.generation = b.generation + 1;
				double a = uniform() * Math::TAU, off = body_radius(b);
				child.x = b.x + (float)(std::cos(a) * off);
				child.y = b.y + (float)(std::sin(a) * off);
				child.dx = 1.0f;
				child.dy = 0.0f;
				b.generation += 1;
				make_record(child, b.id);
				newborn.push_back(child);
			}
		}
		if (keep != i) {
			bups[keep] = b;
		}
		keep++;
	}
	bups.resize(keep);
	for (const DeathCloud &c : death_clouds) { // (after the loop: a cloud made in it would be found by the bups after it, and the clouds' lookup rebuilt for each)
		if (husk_seconds > 0.0) {
			add_husk(c.x, c.y, c.energy);
		} else {
			field->add_cloud(Vector2(c.x, c.y), 0.0, c.energy);
		}
	}
	// At the carrying limit a birth takes the place of a random bup, so reproduction (not a blocked
	// birth) is still what wins: numbers hold steady and the fitter lineage spreads (a Moran process).
	int limit = cap();
	int excess = (int)bups.size() + (int)newborn.size() - limit;
	while (excess > 0 && !bups.empty()) {
		size_t displaced = (size_t)(uniform() * bups.size());
		record_death(bups[displaced]);
		bups[displaced] = bups.back();
		bups.pop_back();
		excess--;
	}
	for (const Bup &child : newborn) {
		bups.push_back(child);
	}
}

// ---- drawing -------------------------------------------------------------------------------

Vector2 BupSim::bup_pos(int64_t id) const {
	int i = find(id);
	return i < 0 ? Vector2() : Vector2(bups[i].x, bups[i].y);
}

void BupSim::set_custom_name(int64_t id, const String &name) {
	auto it = records.find(id);
	if (it != records.end()) {
		it->second.name = name;
	}
}

String BupSim::custom_name(int64_t id) const {
	auto it = records.find(id);
	return it == records.end() ? String() : it->second.name;
}

// One instance for each bup, for the MultiMesh. A bup that has moved farther than its own length since the last picture
// is drawn as a streak: the body at its place now, and a tail fading back to where it was then. Picture after picture the
// streaks join up, so a fast bup reads as one object leaving a path, not as a scatter of separate dots.
PackedFloat32Array BupSim::render_buffer(double pixel_um, int capacity) {
	double margin = pixel_um; // a pixel all round
	const int stride = 16; // transform (8) + colour (4) + custom data (4)
	PackedFloat32Array out;
	out.resize((int64_t)capacity * stride);
	float *w = out.ptrw();
	std::fill(w, w + (size_t)capacity * stride, 0.0f);
	int n = std::min(capacity, (int)bups.size());
	for (int i = n; i < (int)bups.size(); i++) { // not drawn this time: no trail from this picture's gap when they are
		bups[i].px = bups[i].py = std::numeric_limits<float>::quiet_NaN();
	}
	for (int i = 0; i < n; i++) {
		Bup &b = bups[i];
		float *p = w + (size_t)i * stride;
		double length = drawn_length(b, pixel_um), width = drawn_width(pixel_um);
		// The trail: back along the way it came since the last picture (none for a new bup, or one that has hardly moved).
		double ux = b.dx, uy = b.dy, trail = 0.0;
		if (!std::isnan(b.px)) {
			double mx = (double)b.x - b.px, my = (double)b.y - b.py;
			double moved = std::sqrt(mx * mx + my * my);
			if (moved > length) {
				ux = mx / moved;
				uy = my / moved;
				trail = std::min(moved, G.max_trail_px * pixel_um);
			}
		}
		b.px = b.x;
		b.py = b.y;
		// The quad is the body (and its trail) plus a margin all round (about a pixel), so that a body thinner than a
		// pixel still covers some pixel centres; the shader draws the exact capsule inside it. Its middle is half a
		// trail behind the body.
		double quad_length = length + trail + 2.0 * margin, quad_width = width + 2.0 * margin;
		p[0] = (float)(ux * quad_length);
		p[1] = (float)(-uy * quad_width);
		p[3] = (float)(b.x - ux * trail * 0.5);
		p[4] = (float)(uy * quad_length);
		p[5] = (float)(ux * quad_width);
		p[7] = (float)(b.y - uy * trail * 0.5);
		// colour: the bup's own hue, saturation and value
		Color c = Color::from_hsv(b.hue, b.sat, b.val);
		p[8] = c.r;
		p[9] = c.g;
		p[10] = c.b;
		p[11] = 1.0f;
		p[12] = (float)length; // the body, for the shader that draws the capsule
		p[13] = (float)width;
		p[14] = (float)margin;
		p[15] = (float)trail;
	}
	return out;
}
