#include "bup_sim.h"

#include <godot_cpp/classes/worker_thread_pool.hpp>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>

#include <algorithm>
#include <cmath>

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
} // namespace

void BupSim::_bind_methods() {
	ClassDB::bind_static_method("BupSim", D_METHOD("configure", "constants"), &BupSim::configure);
	ClassDB::bind_method(D_METHOD("reset", "dish_radius", "seed"), &BupSim::reset);
	ClassDB::bind_method(D_METHOD("set_seed", "seed"), &BupSim::set_seed);
	ClassDB::bind_method(D_METHOD("set_limit", "bup_limit"), &BupSim::set_limit);
	ClassDB::bind_method(D_METHOD("set_upkeep_scale", "scale"), &BupSim::set_upkeep_scale);
	ClassDB::bind_method(D_METHOD("grow", "new_radius"), &BupSim::grow);
	ClassDB::bind_method(D_METHOD("shrink", "new_radius"), &BupSim::shrink);
	ClassDB::bind_method(D_METHOD("set_threads", "count"), &BupSim::set_threads);
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
	ClassDB::bind_method(D_METHOD("bup_sense_range", "id"), &BupSim::bup_sense_range);
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
	ClassDB::bind_method(D_METHOD("step", "delta", "source_pos", "source_rates", "feed_per_minute", "sim_time"), &BupSim::step, DEFVAL(-1.0));
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
	now_seconds = 0.0;
	bups.reserve(cap() + 16);
	next_id = 1;
	diffuse_accum = 0.0;
	feed_energy = 0.0;
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

void BupSim::derive(Bup &b) {
	double size_gene = b.genes[3];
	b.add_mass = (float)(G.add_mass_factor * size_gene * size_gene);
	b.yield = (float)(std::exp(-(double)b.harm) / std::sqrt((double)b.genes[2]));
	b.drag_upkeep = (float)(G.drag_upkeep * (double)b.genes[0] * b.genes[0]);
	b.effective_diffusion = (float)((double)b.genes[0] * b.genes[0] * G.run_seconds / (2.0 * (1.0 - G.mean_cos_turn)));
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
	if (id > 0 && find(id) < 0) {
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
		r.alive = find(id) >= 0;
		if (r.alive) {
			r.died = -1;
		}
		records[id] = r;
	}
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
	Dictionary out;
	int i = find(id);
	if (i < 0) {
		return out;
	}
	const Bup &b = bups[i];
	out["id"] = b.id;
	out["pos"] = Vector2(b.x, b.y);
	out["dir"] = Vector2(b.dx, b.dy);
	out["energy"] = b.energy;
	out["max_energy"] = max_energy(b);
	auto record = records.find(id);
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
	out["steering"] = bup_steering(id).z;
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

double BupSim::drift_fraction(const Bup &b, double log_gradient, double concentration, double noise) const {
	double registered = b.genes[0] * log_gradient * drift_gain();
	return G.max_drift_fraction * std::tanh((registered + estimate_error(b, concentration) * G.drift_noise * noise) / G.drift_half);
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

// Which way this bup's drift tends (the unit vector up the gradient where it is) and the chance that a step of it
// goes that way rather than down the slope: 0.5 when it cannot tell, up to 1.
Vector3 BupSim::bup_steering(int64_t id) const {
	WITH_BUP(id, Vector3(0, 0, 0.5))
	double c, gx, gy;
	field->read_xy(b.x, b.y, c, gx, gy);
	double glen = std::sqrt(gx * gx + gy * gy);
	double chance = 0.5 * (1.0 + std::erf(steering_snr(b.genes[0], sense_range(b), c, glen) / std::sqrt(2.0)));
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
	if (job.fine) {
		for (size_t i = first; i < last; i++) {
			Bup &b = bups[i];
			swim_by_runs(b, job.sub, r);
			keep_inside(b, r);
			pay_upkeep_and_grow(b, job.delta);
		}
		return;
	}
	drift_chunk(job, first, last, r);
	for (size_t i = first; i < last; i++) {
		pay_upkeep_and_grow(bups[i], job.delta);
	}
}

// The walk of a step that spans many runs, for the bups first..last: what a run-and-tumble swimmer averages to is a
// random walk with the swimmer's effective diffusion, plus a drift up the gradient. Each sub-step a bup reads the nutrient
// where it is, takes a Gaussian step of the diffusion's size, and adds the drift (the fraction of its speed it registers
// from the log-gradient, with the noise of its senses), and is kept inside the wall. The sub-steps go across all the bups
// in turn, rather than all of one bup's after another: each bup's step is a chain of dependent work (read the field,
// divide, square root, tanh), and with several bups in turn the processor can overlap those chains. What stays the same
// for a bup for the whole step is worked out once, the heading is only put in the bup when the wall needs it (and at the
// end), and the wall is first tested without a square root.
void BupSim::drift_chunk(const SwimJob &job, size_t first, size_t last, Rng &r) {
	struct Lane {
		float x, y;
		double spread, sense_k, speed, near_wall2;
		double hx, hy, hl; // the latest displacement long enough to set a heading, not yet put in the bup's dx, dy
		bool pending;
	};
	const size_t count = last - first;
	std::vector<Lane> lanes(count);
	const double floor_c = G.detection_floor, max_drift = G.max_drift_fraction, drift_noise = G.drift_noise, drift_half = G.drift_half;
	const double noise_ref = G.noise_reference, gain = drift_gain(), sub = job.sub;
	for (size_t i = 0; i < count; i++) {
		Bup &b = bups[first + i];
		b.primed = false; // (the signal memory isn't kept up while drifting)
		Lane &l = lanes[i];
		l.x = b.x;
		l.y = b.y;
		l.spread = std::sqrt(2.0 * (double)b.effective_diffusion * sub);
		l.sense_k = G.gradient_noise * (G.reference_sense / sense_range(b));
		l.speed = b.genes[0];
		double limit = radius - body_radius(b);
		l.near_wall2 = limit > 0.0 ? limit * limit * (1.0 - 1e-9) : -1.0; // (any bup nearer the wall than this gets the exact test)
		l.hx = l.hy = l.hl = 0.0;
		l.pending = false;
	}
	for (int m = 0; m < job.moves; m++) {
		for (size_t i = 0; i < count; i++) {
			Lane &l = lanes[i];
			double c, gx, gy;
			field->read_snapshot_xy(l.x, l.y, c, gx, gy);
			double lx = gx / (floor_c + c), ly = gy / (floor_c + c);
			double sx = r.gaussian() * l.spread, sy = r.gaussian() * l.spread;
			double glen = std::sqrt(lx * lx + ly * ly);
			if (glen > 1e-9) {
				double error = std::min(l.sense_k * std::sqrt(noise_ref / std::max(c, 1e-5)), 5.0);
				double fraction = max_drift * std::tanh((l.speed * glen * gain + error * drift_noise * r.gaussian()) / drift_half);
				double drift = l.speed * fraction * sub / glen;
				sx += lx * drift;
				sy += ly * drift;
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


void BupSim::step(double delta, const PackedVector2Array &source_pos, const PackedFloat32Array &source_rates, double feed_per_minute, double sim_time) {
	if (sim_time >= 0.0) {
		now_seconds = sim_time;
	}
	int sources = (int)std::min(source_pos.size(), source_rates.size());
	for (int i = 0; i < sources; i++) {
		field->deposit_xy(source_pos[i].x, source_pos[i].y, source_rates[i] / 60.0 * delta * G.nutrient_energy);
	}
	feed_energy += feed_per_minute / 60.0 * G.nutrient_energy * delta;
	diffuse_accum += delta;
	if (diffuse_accum >= G.diffuse_interval) {
		field->fill(feed_energy);
		feed_energy = 0.0;
		field->diffuse(diffuse_accum);
		diffuse_accum = 0.0;
	}

	// First every bup moves, pays its upkeep and grows, in parallel (see SwimJob), each reading the nutrient as it is at the start of
	// the step. Then, one at a time, they take up nutrient, die and divide.
	SwimJob job;
	job.sim = this;
	job.delta = delta;
	job.fine = delta <= G.fine_step;
	job.moves = job.fine ? 1 : std::max(1, (int)std::ceil(delta / G.motion_step));
	job.sub = delta / job.moves;
	job.seed = rng.next_bits();
	field->snapshot();
	int chunks = ((int)bups.size() + SWIM_CHUNK - 1) / SWIM_CHUNK;
	WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
	if (threads == 1 || chunks <= 1 || pool == nullptr) {
		for (int chunk = 0; chunk < chunks; chunk++) {
			swim_chunk(job, (uint32_t)chunk);
		}
	} else {
		WorkerThreadPool::GroupID group = pool->add_native_group_task(&BupSim::run_swim_chunk, &job, chunks, threads > 1 ? threads : -1, true, "bups swim");
		pool->wait_for_group_task_completion(group);
	}

	size_t keep = 0;
	std::vector<Bup> newborn;
	// Each bup that has energy left has the same small chance of dying of something else this step. Rather than a random
	// number for each, the number of such bups until the next death is drawn (the gaps between independent chances of p are
	// geometric): the same odds for every bup, and one draw for each death instead of one for each bup.
	const double death_chance = G.death_rate * delta;
	int64_t until_death = death_gap(death_chance);
	for (size_t i = 0; i < bups.size(); i++) {
		Bup &b = bups[i];
		{ // take up nutrient from the medium where the bup is
			double wanted = uptake_wanted(b, field->concentration_xy(b.x, b.y), delta);
			if (wanted > 0.0) {
				double got = field->take_xy(b.x, b.y, wanted);
				eat(b, got);
			}
		}
		bool dies = b.energy <= 0.0f;
		if (!dies && until_death-- == 0) {
			dies = true;
			until_death = death_gap(death_chance);
		}
		if (dies) {
			record_death(b);
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
