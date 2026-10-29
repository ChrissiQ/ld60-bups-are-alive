#include "nutrient_field.h"

#include "parallel.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

void NutrientField::_bind_methods() {
	ClassDB::bind_static_method("NutrientField", D_METHOD("size_for", "dish_radius"), &NutrientField::size_for);
	ClassDB::bind_method(D_METHOD("size_for_radius", "dish_radius"), &NutrientField::size_for_radius);
	ClassDB::bind_method(D_METHOD("set_max_across", "across"), &NutrientField::set_max_across);
	ClassDB::bind_method(D_METHOD("get_max_across"), &NutrientField::get_max_across);
	ClassDB::bind_method(D_METHOD("set_diffusion", "d"), &NutrientField::set_diffusion);
	ClassDB::bind_method(D_METHOD("get_diffusion"), &NutrientField::get_diffusion);
	ClassDB::bind_method(D_METHOD("reset", "dish_radius"), &NutrientField::reset);
	ClassDB::bind_method(D_METHOD("resize", "dish_radius"), &NutrientField::resize);
	ClassDB::bind_method(D_METHOD("get_size"), &NutrientField::get_size);
	ClassDB::bind_method(D_METHOD("get_spacing"), &NutrientField::get_spacing);
	ClassDB::bind_method(D_METHOD("accepts", "local"), &NutrientField::accepts);
	ClassDB::bind_method(D_METHOD("deposit", "local", "energy"), &NutrientField::deposit);
	ClassDB::bind_method(D_METHOD("deposit_disc", "local", "radius", "energy"), &NutrientField::deposit_disc);
	ClassDB::bind_method(D_METHOD("add_cloud", "local", "radius", "energy"), &NutrientField::add_cloud);
	ClassDB::bind_method(D_METHOD("advance_puffs", "dt"), &NutrientField::advance_puffs);
	ClassDB::bind_method(D_METHOD("flush_emitters"), &NutrientField::flush_emitters);
	ClassDB::bind_method(D_METHOD("puff_count"), &NutrientField::puff_count);
	ClassDB::bind_method(D_METHOD("puffs_export"), &NutrientField::puffs_export);
	ClassDB::bind_method(D_METHOD("puffs_import", "saved"), &NutrientField::puffs_import);
	ClassDB::bind_method(D_METHOD("min_cloud_sigma", "x", "y"), &NutrientField::min_cloud_sigma);
	ClassDB::bind_method(D_METHOD("erase_disc", "local", "radius", "strength"), &NutrientField::erase_disc);
	ClassDB::bind_method(D_METHOD("sample", "local"), &NutrientField::sample);
	ClassDB::bind_method(D_METHOD("read", "local"), &NutrientField::read);
	ClassDB::bind_method(D_METHOD("gradient", "local"), &NutrientField::gradient);
	ClassDB::bind_method(D_METHOD("take", "local", "energy"), &NutrientField::take);
	ClassDB::bind_method(D_METHOD("fill", "concentration"), &NutrientField::fill);
	ClassDB::bind_method(D_METHOD("set_patchiness", "amplitude", "largest_patch_um", "seed"), &NutrientField::set_patchiness);
	ClassDB::bind_method(D_METHOD("diffuse", "dt"), &NutrientField::diffuse);
	ClassDB::bind_method(D_METHOD("total"), &NutrientField::total);
	ClassDB::bind_method(D_METHOD("is_empty"), &NutrientField::is_empty);
	ClassDB::bind_method(D_METHOD("values"), &NutrientField::values);
	ClassDB::bind_method(D_METHOD("export_owner"), &NutrientField::export_owner);
	ClassDB::bind_method(D_METHOD("export_packed"), &NutrientField::export_packed);
	ClassDB::bind_method(D_METHOD("import_packed", "conc", "puffs"), &NutrientField::import_packed);
	ClassDB::bind_method(D_METHOD("export_fill_weights"), &NutrientField::export_fill_weights);
	ClassDB::bind_method(D_METHOD("set_recording", "on"), &NutrientField::set_recording);
	ClassDB::bind_method(D_METHOD("take_recorded_puffs"), &NutrientField::take_recorded_puffs);
	ClassDB::bind_method(D_METHOD("take_recorded_cells"), &NutrientField::take_recorded_cells);
	ClassDB::bind_method(D_METHOD("take_recorded_amounts"), &NutrientField::take_recorded_amounts);
	ClassDB::bind_method(D_METHOD("cell_centre", "i"), &NutrientField::cell_centre);
	ClassDB::bind_method(D_METHOD("haze_bytes", "visible_above", "alpha_scale", "max_alpha"), &NutrientField::haze_bytes);
	ClassDB::bind_method(D_METHOD("steer_bytes", "speed", "sense_range", "max_alpha"), &NutrientField::steer_bytes);
	ClassDB::bind_method(D_METHOD("load_values", "saved"), &NutrientField::load_values);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "size"), "", "get_size");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "spacing"), "", "get_spacing");
}

int NutrientField::size_for(double dish_radius) {
	int wanted = (int)std::ceil(2.0 * dish_radius / G.field_target_spacing);
	return std::clamp(wanted, (int)G.field_min_across, (int)G.field_max_across);
}

int NutrientField::size_for_radius(double dish_radius) const {
	int wanted = (int)std::ceil(2.0 * dish_radius / G.field_target_spacing);
	return std::clamp(wanted, (int)G.field_min_across, std::max(get_max_across(), (int)G.field_min_across));
}

void NutrientField::reset(double dish_radius) {
	build(dish_radius, size_for_radius(dish_radius));
}

void NutrientField::build(double dish_radius, int cells_across) {
	puffs.clear();
	emitters.clear();
	hash_dirty = true;
	radius = dish_radius;
	origin = dish_radius;
	n = cells_across;
	spacing = 2.0 * dish_radius / n;
	conc.assign((size_t)n * n, 0.0f);
	inside.assign((size_t)n * n, 0);
	fill_weights_valid = false;
	inside_count = 0;
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) {
			double cx = (x + 0.5) * spacing - origin, cy = (y + 0.5) * spacing - origin;
			if (std::sqrt(cx * cx + cy * cy) <= radius) {
				inside[(size_t)y * n + x] = 1;
				inside_count++;
			}
		}
	}
	owner.assign((size_t)n * n, -1);
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) {
			size_t i = (size_t)y * n + x;
			owner[i] = inside[i] ? (int)i : nearest_inside(x, y);
		}
	}
}

// The dish changes size: the nutrient stays where it is, on the new grid. Each new cell takes the old field's
// (smoothed) value at its centre. A larger dish is then scaled to hold exactly the nutrient there was; a smaller one
// keeps the concentration where it was, and the nutrient past the new edge is gone.
void NutrientField::resize(double dish_radius) {
	bool shrinking = dish_radius < radius;
	flush_emitters(); // (reset below forgets the sources' kept-back nutrient: let it go into the field first, so it is not lost)
	std::vector<float> old_conc = conc;
	int old_n = n;
	double old_spacing = spacing, old_origin = origin, old_total = grid_total();
	std::vector<Puff> kept_clouds = puffs;
	reset(dish_radius);
	for (const Puff &p : kept_clouds) { // the clouds stay where they are (the ones past a smaller dish's edge go with the nutrient there)
		if (p.x * p.x + p.y * p.y <= radius * radius) {
			puffs.push_back(p);
		}
	}
	hash_dirty = true;
	if (old_total <= 0.0 || old_conc.empty()) {
		return;
	}
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) {
			int i = y * n + x;
			if (!inside[i]) {
				continue;
			}
			double cx = (x + 0.5) * spacing - origin, cy = (y + 0.5) * spacing - origin;
			double fx = (cx + old_origin) / old_spacing - 0.5, fy = (cy + old_origin) / old_spacing - 0.5;
			if (fx < -0.5 || fy < -0.5 || fx > old_n - 0.5 || fy > old_n - 0.5) {
				continue; // outside the old dish
			}
			fx = std::clamp(fx, 0.0, old_n - 1.001);
			fy = std::clamp(fy, 0.0, old_n - 1.001);
			int x0 = (int)fx, y0 = (int)fy;
			double tx = fx - x0, ty = fy - y0;
			int j = y0 * old_n + x0;
			double top = old_conc[j] + (old_conc[j + 1] - old_conc[j]) * tx;
			double bottom = old_conc[j + old_n] + (old_conc[j + old_n + 1] - old_conc[j + old_n]) * tx;
			conc[i] = (float)(top + (bottom - top) * ty);
		}
	}
	double new_total = grid_total();
	if (!shrinking && new_total > 0.0) {
		float scale = (float)(old_total / new_total);
		for (float &c : conc) {
			c *= scale;
		}
	}
}

// A cell counts as inside the dish when its centre is, so the thin band of cells that straddle the rim
// with their centres beyond it holds no nutrient. A bup against the wall can be in one of those, so it
// takes the nearest cell that is inside: its food, and what it senses, is that cell's.
int NutrientField::nearest_inside(int ix, int iy) const {
	int best = -1, best_d = 1 << 30;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			int nx = ix + dx, ny = iy + dy;
			if (nx < 0 || ny < 0 || nx >= n || ny >= n || !inside[(size_t)ny * n + nx]) {
				continue;
			}
			int d = dx * dx + dy * dy;
			if (d < best_d) {
				best_d = d;
				best = ny * n + nx;
			}
		}
	}
	return best;
}

// Lines of the grid are handled in blocks of this many, and a grid with fewer cells than PARALLEL_CELLS is done on this thread
// (handing the work to the pool costs about as much as a small grid takes).
static const int LINE_BLOCK = 16;
static const int PARALLEL_CELLS = 30000;

void NutrientField::run_blocks(void (*fn)(void *, uint32_t), void *job, int blocks) {
	parallel_for(fn, job, blocks, threads, n * n >= PARALLEL_CELLS, "nutrient grid");
}

void NutrientField::snapshot_rows(int first_row, int last_row) {
	for (size_t i = (size_t)first_row * n; i < (size_t)last_row * n; i++) {
		int o = owner[i];
		eff[i] = o < 0 ? 0.0f : conc[o];
	}
}

void NutrientField::run_snapshot_block(void *job, uint32_t block) {
	NutrientField *field = (NutrientField *)job;
	int first = (int)block * LINE_BLOCK;
	field->snapshot_rows(first, std::min(first + LINE_BLOCK, field->n));
}

void NutrientField::snapshot(bool readers) {
	if (!readers) { // (nobody will read the field this step: the copy and the clouds' lists are made, by whoever reads next, when it is wanted)
		return;
	}
	eff.resize((size_t)n * n);
	run_blocks(&NutrientField::run_snapshot_block, this, (n + LINE_BLOCK - 1) / LINE_BLOCK);
	rebuild_hash();
	hmass.resize(puffs.size());
	for (size_t k = 0; k < puffs.size(); k++) {
		hmass[k] = puffs[k].mass;
	}
}

// ---- the clouds --------------------------------------------------------------------------------

double NutrientField::puff_reach(const Puff &p) const {
	double peak = p.mass / (2.0 * 3.14159265358979323846 * p.var);
	double cut = std::max(G.cloud_cut * p.cut * G.detection_floor, 1e-30);
	return peak > cut ? std::sqrt(2.0 * p.var * std::log(peak / cut)) : 0.0;
}

// How far a cloud can reach while its variance grows by up to `spread`: its reach first grows with its width, then shrinks as its peak falls
// (the largest at a variance of mass / (2 pi cut e)). Taking up its nutrient only shrinks it.
double NutrientField::puff_reach_ahead(const Puff &p, double spread) const {
	Puff later = p;
	later.var += spread;
	double reach = std::max(puff_reach(p), puff_reach(later));
	double cut = std::max(G.cloud_cut * p.cut * G.detection_floor, 1e-30);
	double widest = p.mass / (2.0 * 3.14159265358979323846 * cut * 2.718281828459045);
	if (widest > p.var && widest < later.var) {
		later.var = widest;
		reach = std::max(reach, puff_reach(later));
	}
	return reach;
}

// What a read needs of cloud k besides where it is, as the cloud is now; its reach is returned.
double NutrientField::note_puff(size_t k) const {
	const Puff &p = puffs[k];
	double reach = puff_reach(p);
	ha[k] = 1.0 / (2.0 * 3.14159265358979323846 * p.var);
	hb[k] = 0.5 / p.var;
	hreach2[k] = reach * reach;
	hsigma[k] = std::sqrt(p.var);
	return reach;
}

// Between steps this short the lists are kept for up to this many seconds of spreading (unless a cloud comes or goes): each cloud is listed in
// the bins its reach could touch over that time (`hash_spread`), and what a read needs of each (its width, its reach) is brought up to date every
// step in between (see advance_puffs), so a read finds what lists made afresh that step would give. Longer steps make them afresh every step.
static const double HASH_REFRESH = 2.0;

// The clouds' lists are cut into bins this many grid cells across. A read looks at the one bin its point is in and keeps the clouds that reach the point, so
// the bins' size changes how much work a rebuild and a read each take but not what is found or the order it is summed in: bigger bins mean far fewer entries
// to make for a cloud that reaches several cells (a cloud is listed in every bin its reach touches) and a few more clouds to look at per read.
static const double BIN_CELLS = 2.0;

void NutrientField::rebuild_hash() const {
	if (!hash_dirty) {
		return;
	}
	hash_dirty = false;
	size_t count = puffs.size();
	bin_entries.clear();
	if (count == 0) {
		bin_start.assign(2, 0);
		bins_across = 1;
		return;
	}
	bin_size = BIN_CELLS * spacing;
	bins_across = std::max(1, (int)std::ceil(2.0 * radius / bin_size) + 1);
	size_t bins = (size_t)bins_across * bins_across;
	ha.resize(count);
	hb.resize(count);
	hreach2.resize(count);
	hsigma.resize(count);
	std::vector<int> &lo_x = scratch_lo_x, &hi_x = scratch_hi_x, &lo_y = scratch_lo_y, &hi_y = scratch_hi_y;
	lo_x.resize(count);
	hi_x.resize(count);
	lo_y.resize(count);
	hi_y.resize(count);
	bin_start.assign(bins + 1, 0);
	hash_spread = hash_keep ? 2.0 * get_diffusion() * HASH_REFRESH : 0.0;
	for (size_t i = 0; i < count; i++) { // (first how many bins each puff touches, to size the lists)
		const Puff &p = puffs[i];
		double reach = note_puff(i);
		if (hash_spread > 0.0) {
			reach = puff_reach_ahead(p, hash_spread);
		}
		lo_x[i] = std::clamp((int)((p.x - reach + origin) / bin_size), 0, bins_across - 1);
		hi_x[i] = std::clamp((int)((p.x + reach + origin) / bin_size), 0, bins_across - 1);
		lo_y[i] = std::clamp((int)((p.y - reach + origin) / bin_size), 0, bins_across - 1);
		hi_y[i] = std::clamp((int)((p.y + reach + origin) / bin_size), 0, bins_across - 1);
		for (int by = lo_y[i]; by <= hi_y[i]; by++) {
			for (int bx = lo_x[i]; bx <= hi_x[i]; bx++) {
				bin_start[(size_t)by * bins_across + bx + 1]++;
			}
		}
	}
	for (size_t b = 0; b < bins; b++) {
		bin_start[b + 1] += bin_start[b];
	}
	bin_entries.resize((size_t)bin_start[bins]);
	std::vector<int> &next = scratch_next;
	next.assign(bin_start.begin(), bin_start.end() - 1);
	for (size_t i = 0; i < count; i++) { // (then who is in each, in the order the puffs were added: the same on any run)
		for (int by = lo_y[i]; by <= hi_y[i]; by++) {
			for (int bx = lo_x[i]; bx <= hi_x[i]; bx++) {
				bin_entries[(size_t)next[(size_t)by * bins_across + bx]++] = (int)i;
			}
		}
	}
}

template <typename F>
void NutrientField::each_puff(double x, double y, F fn) const {
	int bx = std::clamp((int)((x + origin) / bin_size), 0, bins_across - 1);
	int by = std::clamp((int)((y + origin) / bin_size), 0, bins_across - 1);
	int b = by * bins_across + bx;
	for (int e = bin_start[b]; e < bin_start[b + 1]; e++) {
		int k = bin_entries[e];
		const Puff &p = puffs[k];
		double dx = x - p.x, dy = y - p.y, r2 = dx * dx + dy * dy;
		if (r2 <= hreach2[k]) {
			fn(k, dx, dy, r2);
		}
	}
}

void NutrientField::puff_sum(double x, double y, double &c, double &gx, double &gy) const {
	each_puff(x, y, [&](int k, double dx, double dy, double r2) {
		double ci = puffs[k].mass * ha[k] * fast_exp(-r2 * hb[k]);
		c += ci;
		gx -= ci * dx * 2.0 * hb[k]; // (the gradient of a Gaussian is -c r / var)
		gy -= ci * dy * 2.0 * hb[k];
	});
}

void NutrientField::puff_probe(double x, double y, double &c, double &gx, double &gy, double &sigma) const {
	each_puff(x, y, [&](int k, double dx, double dy, double r2) {
		double ci = puffs[k].mass * ha[k] * fast_exp(-r2 * hb[k]);
		c += ci;
		gx -= ci * dx * 2.0 * hb[k];
		gy -= ci * dy * 2.0 * hb[k];
		sigma = std::min(sigma, hsigma[k]);
	});
}

double NutrientField::min_cloud_sigma(double x, double y) const {
	rebuild_hash();
	double smallest = 1.0e18;
	if (!puffs.empty()) {
		each_puff(x, y, [&](int k, double, double, double) { smallest = std::min(smallest, hsigma[k]); });
	}
	return smallest;
}

// Gives a cloud to the grid: its nutrient over the cells it covers, weighted as the cloud is (so what the cells hold
// stands for the cloud as well as a grid can), all of it on the cells inside the dish.
void NutrientField::deposit_gaussian(double x, double y, double mass, double var) {
	double reach = 4.0 * std::sqrt(var); // (all of the cloud that matters)
	int x0, x1, y0, y1;
	disc_block(x, y, reach, x0, x1, y0, y1);
	std::vector<std::pair<int, double>> weights;
	double sum = 0.0;
	for (int cy = y0; cy <= y1; cy++) {
		for (int cx = x0; cx <= x1; cx++) {
			int i = cy * n + cx;
			if (!inside[i]) {
				continue;
			}
			double dx = (cx + 0.5) * spacing - origin - x, dy = (cy + 0.5) * spacing - origin - y;
			double w = std::exp(-(dx * dx + dy * dy) / (2.0 * var));
			weights.push_back({ i, w });
			sum += w;
		}
	}
	if (sum <= 1e-12) {
		deposit_xy(x, y, mass);
		return;
	}
	for (const auto &w : weights) {
		add_to_cell(w.first, (float)(mass * w.second / sum / (spacing * spacing)));
	}
}

static const double MIN_CLOUD_VARIANCE = 100.0; // µm^2: a cloud is never thinner than 10 µm across (a dose of one nutrient lands on a point)
static const size_t MAX_CLOUDS = 200000; // past this a new one goes onto the grid

void NutrientField::add_to_cell(int cell, float amount) {
	if (recording) {
		rec_cells.push_back(cell);
		rec_amounts.push_back(amount);
	} else {
		conc[cell] += amount;
	}
}

PackedFloat32Array NutrientField::take_recorded_puffs() {
	PackedFloat32Array out = to_packed<PackedFloat32Array>(rec_puffs);
	rec_puffs.clear();
	return out;
}

PackedInt32Array NutrientField::take_recorded_cells() {
	PackedInt32Array out = to_packed<PackedInt32Array>(rec_cells);
	rec_cells.clear();
	return out;
}

PackedFloat32Array NutrientField::take_recorded_amounts() {
	PackedFloat32Array out = to_packed<PackedFloat32Array>(rec_amounts);
	rec_amounts.clear();
	return out;
}

void NutrientField::add_puff(double x, double y, double mass, double var, double cut) {
	if (recording) {
		rec_puffs.push_back((float)x);
		rec_puffs.push_back((float)y);
		rec_puffs.push_back((float)mass);
		rec_puffs.push_back((float)var);
		rec_puffs.push_back((float)cut);
		return;
	}
	if (puffs.size() >= MAX_CLOUDS) {
		deposit_gaussian(x, y, mass, var);
		return;
	}
	puffs.push_back({ x, y, mass, var, cut });
	hash_dirty = true;
	hash_age = 0.0;
}

void NutrientField::add_cloud(const Vector2 &local, double disc_radius, double energy) {
	double var = std::max(0.25 * disc_radius * disc_radius, MIN_CLOUD_VARIANCE); // (a uniform disc has this variance on each axis)
	if (!accepts(local) || std::sqrt(var) >= G.cloud_handover * spacing) { // a grid fine enough to hold it as it is
		deposit_disc(local, disc_radius, energy);
		return;
	}
	add_puff(local.x, local.y, energy, var);
}

static const double EMIT_INTERVAL = 60.0; // seconds between the clouds a steady source lets go of

void NutrientField::release_emitter(Emitter &e) {
	if (e.mass > 0.0) {
		double var = std::max(get_diffusion() * e.age, MIN_CLOUD_VARIANCE); // (what was released over the time has spread, on average, for half of it)
		if (inside_count > 0 && accepts(Vector2((float)e.x, (float)e.y))) {
			add_puff(e.x, e.y, e.mass, var, 0.001); // (looked for out to a thousandth of the usual: see Puff::cut)
		} else {
			deposit_xy(e.x, e.y, e.mass);
		}
	}
	e.mass = 0.0;
	e.age = 0.0;
}

void NutrientField::emit_xy(double x, double y, double energy, double dt) {
	if (std::sqrt(get_diffusion() * EMIT_INTERVAL) >= G.cloud_handover * spacing) { // a grid fine enough to hold the plume: straight onto it
		deposit_xy(x, y, energy);
		return;
	}
	float fx = (float)x, fy = (float)y;
	uint32_t bx, by;
	memcpy(&bx, &fx, 4);
	memcpy(&by, &fy, 4);
	Emitter &e = emitters[((uint64_t)bx << 32) | by];
	e.x = x;
	e.y = y;
	e.mass += energy;
	e.age += dt;
	e.lived += dt;
	e.epoch = emit_epoch;
	if (e.age >= std::clamp(e.lived, 5.0, EMIT_INTERVAL)) { // (often at first, so that a new source shows soon)
		release_emitter(e);
	}
}

void NutrientField::end_emissions() {
	for (auto it = emitters.begin(); it != emitters.end();) {
		if (it->second.epoch != emit_epoch) { // its source is gone: what it kept is let go
			release_emitter(it->second);
			it = emitters.erase(it);
		} else {
			++it;
		}
	}
}

void NutrientField::flush_emitters() {
	for (auto &item : emitters) {
		release_emitter(item.second);
	}
}

void NutrientField::advance_puffs(double dt) {
	if (puffs.empty()) {
		return;
	}
	double spread = 2.0 * get_diffusion() * dt;
	double handover = G.cloud_handover * spacing;
	std::vector<Puff> kept;
	kept.reserve(puffs.size());
	for (Puff p : puffs) {
		p.var += spread;
		if (p.mass <= 1e-9) {
			continue; // eaten
		}
		if (std::sqrt(p.var) >= handover) {
			deposit_gaussian(p.x, p.y, p.mass, p.var);
		} else {
			kept.push_back(p);
		}
	}
	bool removed = kept.size() != puffs.size();
	puffs.swap(kept);
	hash_age += dt;
	hash_keep = dt < HASH_REFRESH;
	if (removed || hash_age >= HASH_REFRESH || 2.0 * get_diffusion() * hash_age > hash_spread) {
		hash_dirty = true;
		hash_age = 0.0;
	} else if (!hash_dirty && ha.size() == puffs.size()) { // (the lists stay; a young cloud's peak halves in its first seconds, so what a read uses of each does not)
		for (size_t k = 0; k < puffs.size(); k++) {
			note_puff(k);
		}
	}
}

Array NutrientField::puffs_export() const {
	Array out;
	for (const Puff &p : puffs) {
		Array one;
		one.push_back(p.x);
		one.push_back(p.y);
		one.push_back(p.mass);
		one.push_back(p.var);
		one.push_back(p.cut);
		out.push_back(one);
	}
	return out;
}

void NutrientField::puffs_import(const Array &saved) {
	puffs.clear();
	for (int i = 0; i < saved.size(); i++) {
		Variant v = saved[i];
		if (v.get_type() != Variant::ARRAY) {
			continue;
		}
		Array one = v;
		if (one.size() != 5) {
			continue;
		}
		Puff p = { (double)one[0], (double)one[1], (double)one[2], (double)one[3], (double)one[4] };
		if (p.var > 0.0 && p.mass > 0.0 && p.x * p.x + p.y * p.y <= radius * radius) {
			puffs.push_back(p);
		}
	}
	hash_dirty = true;
}

// The grid's concentrations with each cloud's added at the cell centres it reaches.
std::vector<float> NutrientField::view_values() const {
	std::vector<float> view = conc;
	for (const Puff &p : puffs) {
		double reach = puff_reach(p);
		int x0, x1, y0, y1;
		disc_block(p.x, p.y, reach, x0, x1, y0, y1);
		for (int cy = y0; cy <= y1; cy++) {
			for (int cx = x0; cx <= x1; cx++) {
				int i = cy * n + cx;
				if (!inside[i]) {
					continue;
				}
				double dx = (cx + 0.5) * spacing - origin - p.x, dy = (cy + 0.5) * spacing - origin - p.y;
				view[i] += (float)(p.mass / ((2.0 * 3.14159265358979323846) * p.var) * std::exp(-(dx * dx + dy * dy) / (2.0 * p.var)));
			}
		}
	}
	return view;
}

double NutrientField::view_cell(const std::vector<float> &view, int ix, int iy) const {
	int o = owner[(size_t)iy * n + ix];
	return o < 0 ? 0.0 : (double)view[o];
}

int NutrientField::index_at(double x, double y) const {
	int ix = std::clamp((int)((x + origin) / spacing), 0, n - 1);
	int iy = std::clamp((int)((y + origin) / spacing), 0, n - 1);
	return iy * n + ix;
}

bool NutrientField::accepts(const Vector2 &local) const {
	return std::sqrt((double)local.x * local.x + (double)local.y * local.y) <= radius && inside[index_at(local.x, local.y)] == 1;
}

// A point source is shared out between the four cell centres around it, in proportion to how close
// each is, so the nutrient's centre of mass is exactly where the point is, whatever the grid
// spacing. (Putting it all in the cell that contains it would pull it to that cell's centre.)
// Cells outside the dish take no share: it goes to the ones inside, so nothing is lost.
void NutrientField::deposit_xy(double x, double y, double energy) {
	double fx = (x + origin) / spacing - 0.5, fy = (y + origin) / spacing - 0.5;
	int x0 = (int)std::floor(fx), y0 = (int)std::floor(fy);
	double tx = fx - x0, ty = fy - y0;
	int cells[4];
	double weights[4];
	double kept = 0.0;
	int count = 0;
	for (int k = 0; k < 4; k++) {
		int cx = x0 + (k & 1), cy = y0 + (k >> 1);
		if (cx < 0 || cy < 0 || cx >= n || cy >= n || !inside[(size_t)cy * n + cx]) {
			continue;
		}
		double w = ((k & 1) ? tx : 1.0 - tx) * ((k >> 1) ? ty : 1.0 - ty);
		cells[count] = cy * n + cx;
		weights[count] = w;
		kept += w;
		count++;
	}
	if (count == 0) {
		return;
	}
	if (kept <= 1e-9) { // all the weight was on cells outside the dish: use the nearest one inside
		add_to_cell(cells[0], (float)(energy / (spacing * spacing)));
		return;
	}
	for (int k = 0; k < count; k++) {
		add_to_cell(cells[k], (float)(energy * weights[k] / kept / (spacing * spacing)));
	}
}

void NutrientField::deposit(const Vector2 &local, double energy) {
	deposit_xy(local.x, local.y, energy);
}

// The cells whose centres could lie within `radius` of (x, y): a square block of the grid (clamped to it), so a small disc
// on a big grid does not look at every cell.
void NutrientField::disc_block(double x, double y, double radius, int &x0, int &x1, int &y0, int &y1) const {
	x0 = std::max(0, (int)std::floor((x - radius + origin) / spacing - 0.5));
	x1 = std::min(n - 1, (int)std::ceil((x + radius + origin) / spacing - 0.5));
	y0 = std::max(0, (int)std::floor((y - radius + origin) / spacing - 0.5));
	y1 = std::min(n - 1, (int)std::ceil((y + radius + origin) / spacing - 0.5));
}

void NutrientField::deposit_disc(const Vector2 &local, double disc_radius, double energy) {
	std::vector<int> targets;
	int x0, x1, y0, y1;
	disc_block(local.x, local.y, disc_radius, x0, x1, y0, y1);
	for (int y = y0; y <= y1; y++) {
		for (int x = x0; x <= x1; x++) {
			int i = y * n + x;
			if (!inside[i]) {
				continue;
			}
			double cx = (x + 0.5) * spacing - origin, cy = (y + 0.5) * spacing - origin;
			double dx = cx - local.x, dy = cy - local.y;
			if (std::sqrt(dx * dx + dy * dy) <= disc_radius) {
				targets.push_back(i);
			}
		}
	}
	if (targets.empty()) {
		deposit_xy(local.x, local.y, energy);
		return;
	}
	float per_cell = (float)(energy / (targets.size() * spacing * spacing));
	for (int i : targets) {
		add_to_cell(i, per_cell);
	}
}

double NutrientField::erase_disc(const Vector2 &local, double disc_radius, double strength) {
	double removed = 0.0;
	int x0, x1, y0, y1;
	disc_block(local.x, local.y, disc_radius, x0, x1, y0, y1);
	for (int y = y0; y <= y1; y++) {
		for (int x = x0; x <= x1; x++) {
			int i = y * n + x;
			if (!inside[i]) {
				continue;
			}
			double cx = (x + 0.5) * spacing - origin, cy = (y + 0.5) * spacing - origin;
			double dx = cx - local.x, dy = cy - local.y;
			double d = std::sqrt(dx * dx + dy * dy);
			if (d >= disc_radius) {
				continue;
			}
			double taken = conc[i] * strength * (1.0 - d / disc_radius);
			conc[i] -= (float)taken;
			removed += taken * spacing * spacing;
		}
	}
	for (Puff &p : puffs) { // a cloud under the brush gives up the share its centre would
		double d = std::sqrt((p.x - local.x) * (p.x - local.x) + (p.y - local.y) * (p.y - local.y));
		if (d < disc_radius) {
			double taken = p.mass * strength * (1.0 - d / disc_radius);
			p.mass -= taken;
			removed += taken;
			hash_dirty = true;
		}
	}
	return removed;
}

void NutrientField::read_xy(double x, double y, double &c, double &gx, double &gy) const {
	bilinear(x, y, [this](int ix, int iy) { return cell_value(ix, iy); }, c, gx, gy);
	rebuild_hash();
	if (!puffs.empty()) {
		puff_sum(x, y, c, gx, gy);
	}
}

double NutrientField::sample(const Vector2 &local) const {
	double c, gx, gy;
	read_xy(local.x, local.y, c, gx, gy);
	return c;
}

Vector3 NutrientField::read(const Vector2 &local) const {
	double c, gx, gy;
	read_xy(local.x, local.y, c, gx, gy);
	return Vector3((float)c, (float)gx, (float)gy);
}

Vector2 NutrientField::gradient(const Vector2 &local) const {
	double h = spacing * 0.5;
	double xp = sample(Vector2(local.x + h, local.y)), xm = sample(Vector2(local.x - h, local.y));
	double yp = sample(Vector2(local.x, local.y + h)), ym = sample(Vector2(local.x, local.y - h));
	return Vector2((float)((xp - xm) / (2.0 * h)), (float)((yp - ym) / (2.0 * h)));
}

// A bup takes what it wants from the nutrient where it is, from the grid's cell and from each cloud that reaches it in
// proportion to how much of the concentration at that point each makes. Where no cloud reaches, it is the cell's alone.
void NutrientField::cloud_share_xy(double x, double y, CloudShare &share) const {
	share.count = 0;
	share.more = false;
	share.total = 0.0;
	if (puffs.empty()) {
		return;
	}
	each_puff(x, y, [&](int k, double, double, double r2) {
		double ci = puffs[k].mass * ha[k] * fast_exp(-r2 * hb[k]);
		share.total += ci;
		if (share.count < 6) {
			share.k[share.count] = k;
			share.c[share.count] = ci;
			share.count++;
		} else {
			share.more = true;
		}
	});
}

double NutrientField::take_from_clouds(double x, double y, double wanted, double from_clouds, const CloudShare &share) {
	double taken = 0.0;
	if (!share.more) {
		for (int s = 0; s < share.count; s++) {
			double part = std::min(puffs[share.k[s]].mass, wanted * share.c[s] / from_clouds);
			puffs[share.k[s]].mass -= part;
			taken += part;
		}
		return taken;
	}
	each_puff(x, y, [&](int k, double, double, double r2) { // (more than the few kept: look again, by the masses as they were when the shares were made: the bups before this one have taken from the clouds since, and shares of the clouds as they are now would not add up to the whole)
		double mass_then = (size_t)k < hmass.size() ? hmass[k] : puffs[k].mass;
		double part = std::min(puffs[k].mass, wanted * (mass_then * ha[k] * fast_exp(-r2 * hb[k])) / from_clouds);
		puffs[k].mass -= part;
		taken += part;
	});
	return taken;
}

double NutrientField::uptake_concentration_xy(double x, double y, int own) const {
	double c, gx, gy;
	bilinear(x, y, [&](int ix, int iy) {
		size_t i = (size_t)iy * n + ix;
		return owner[i] == own ? (double)conc[own] : (double)eff[i];
	}, c, gx, gy);
	return c;
}

double NutrientField::take_cell(int cell, double energy) {
	double area = spacing * spacing;
	double taken = std::min(energy, (double)conc[cell] * area);
	conc[cell] -= (float)(taken / area);
	return taken;
}

// A test hook: what the step's uptake does for one bup at a point, from the cell it is in and from the clouds that reach it
// in proportion to how much of the concentration each makes.
double NutrientField::take(const Vector2 &local, double energy) {
	const double x = local.x, y = local.y;
	snapshot();
	int cell = uptake_cell_xy(x, y);
	if (cell < 0) {
		return 0.0;
	}
	double from_grid = uptake_concentration_xy(x, y, cell);
	CloudShare share;
	cloud_share_xy(x, y, share);
	if (share.total <= 0.0) {
		return take_cell(cell, energy);
	}
	double all = from_grid + share.total;
	double taken = take_cell(cell, energy * from_grid / all);
	return taken + take_from_clouds(x, y, energy * share.total / all, share.total, share);
}

void NutrientField::set_patchiness(double amplitude, double largest_patch_um, int64_t seed) {
	patch_amplitude = std::max(amplitude, 0.0);
	patch_size = std::max(largest_patch_um, 1.0);
	patch_seed = (uint64_t)seed;
	fill_weights_valid = false;
}

// Value noise: a hashed value at each corner of a lattice of this spacing, smoothly blended between them (about -1 to 1).
static double lattice_noise(double x, double y, double lattice, uint64_t seed) {
	double gx = x / lattice, gy = y / lattice;
	double fx = std::floor(gx), fy = std::floor(gy);
	double tx = gx - fx, ty = gy - fy;
	tx = tx * tx * (3.0 - 2.0 * tx);
	ty = ty * ty * (3.0 - 2.0 * ty);
	auto corner = [&](int64_t ix, int64_t iy) {
		uint64_t h = seed + (uint64_t)ix * 0x9E3779B97F4A7C15ULL + (uint64_t)iy * 0xC2B2AE3D27D4EB4FULL;
		h = (h ^ (h >> 30)) * 0xBF58476D1CE4E5B9ULL;
		h = (h ^ (h >> 27)) * 0x94D049BB133111EBULL;
		h ^= h >> 31;
		return (double)(h >> 11) * (2.0 / 9007199254740992.0) - 1.0;
	};
	int64_t ix = (int64_t)fx, iy = (int64_t)fy;
	double top = corner(ix, iy) + (corner(ix + 1, iy) - corner(ix, iy)) * tx;
	double bottom = corner(ix, iy + 1) + (corner(ix + 1, iy + 1) - corner(ix, iy + 1)) * tx;
	return top + (bottom - top) * ty;
}

// Fractal noise: the sum of octaves of value noise, each with half the spacing and 0.8 of the strength of the one before,
// from the largest patch down to the size of a grid cell, so the landscape is patchy at every scale.
double NutrientField::patch_noise(double x, double y) const {
	double total = 0.0, strength = 1.0;
	double lattice = patch_size;
	for (int octave = 0; octave < 10 && (octave == 0 || lattice >= spacing); octave++) {
		total += strength * lattice_noise(x, y, lattice, patch_seed + (uint64_t)octave * 0xD1B54A32D192ED03ULL);
		strength *= 0.8;
		lattice *= 0.5;
	}
	return total;
}

// Each cell's share of a feed, patches included: made once and kept until the grid or the landscape changes (the weights depend on nothing else).
void NutrientField::ensure_fill_weights() {
	// The noise, scaled to zero mean and unit spread over the dish, then each cell gets (1 + amplitude * noise) of the
	// concentration, kept above a floor and rescaled so that the dish still gets exactly `concentration` on average. The
	// weights depend only on the grid and the landscape, so they are made once and kept until either changes.
	if (!fill_weights_valid) {
		std::vector<double> &noise = fill_weights;
		noise.assign(conc.size(), 0.0);
		double sum = 0.0, sum_sq = 0.0;
		for (int y = 0; y < n; y++) {
			for (int x = 0; x < n; x++) {
				size_t i = (size_t)y * n + x;
				if (inside[i]) {
					double v = patch_noise((x + 0.5) * spacing - origin, (y + 0.5) * spacing - origin);
					noise[i] = v;
					sum += v;
					sum_sq += v * v;
				}
			}
		}
		double mean = sum / inside_count;
		double spread = std::sqrt(std::max(sum_sq / inside_count - mean * mean, 1e-12));
		fill_weight_total = 0.0;
		for (size_t i = 0; i < conc.size(); i++) {
			if (inside[i]) {
				noise[i] = std::max(1.0 + patch_amplitude * (noise[i] - mean) / spread, 0.05);
				fill_weight_total += noise[i];
			}
		}
		fill_weights_valid = true;
	}
}

// What `fill(1.0)` adds to each cell (nothing outside the dish): for the GPU spike's tests.
PackedFloat32Array NutrientField::export_fill_weights() {
	PackedFloat32Array out;
	out.resize((int64_t)conc.size());
	float *w = out.ptrw();
	if (patch_amplitude > 0.0) {
		ensure_fill_weights();
	}
	for (size_t i = 0; i < conc.size(); i++) {
		w[i] = !inside[i] ? 0.0f : patch_amplitude > 0.0 ? (float)(fill_weights[i] * inside_count / fill_weight_total) : 1.0f;
	}
	return out;
}

void NutrientField::fill(double concentration) {
	if (concentration <= 0.0 || inside_count == 0) {
		return;
	}
	if (patch_amplitude <= 0.0) {
		for (size_t i = 0; i < conc.size(); i++) {
			if (inside[i]) {
				conc[i] += (float)concentration;
			}
		}
		return;
	}
	ensure_fill_weights();
	double scale = concentration * inside_count / fill_weight_total;
	for (size_t i = 0; i < conc.size(); i++) {
		if (inside[i]) {
			conc[i] += (float)(scale * fill_weights[i]);
		}
	}
}

void NutrientField::solve_run(int first, int step, int count, double k, double *cp, double *dp) {
	double b = 1.0 + k;
	cp[0] = -k / b;
	dp[0] = conc[first] / b;
	for (int j = 1; j < count; j++) {
		b = 1.0 + k * (j == count - 1 ? 1.0 : 2.0);
		double denom = b + k * cp[j - 1];
		cp[j] = -k / denom;
		dp[j] = (conc[first + j * step] + k * dp[j - 1]) / denom;
	}
	double x = dp[count - 1];
	conc[first + (count - 1) * step] = (float)x;
	for (int j = count - 2; j >= 0; j--) {
		x = dp[j] - cp[j] * x;
		conc[first + j * step] = (float)x;
	}
}

// Solves the lines first_line..last_line of one sweep. Each line is its own tridiagonal system, so lines are independent.
void NutrientField::sweep_lines(bool along_rows, double k, int first_line, int last_line) {
	int step = along_rows ? 1 : n;
	int line_step = along_rows ? n : 1;
	std::vector<double> cp(n), dp(n);
	for (int line = first_line; line < last_line; line++) {
		int base = line * line_step;
		int i = 0;
		while (i < n) {
			if (!inside[base + i * step]) {
				i++;
				continue;
			}
			int start = i;
			while (i < n && inside[base + i * step]) {
				i++;
			}
			if (i - start > 1) {
				solve_run(base + start * step, step, i - start, k, cp.data(), dp.data());
			}
		}
	}
}

void NutrientField::run_sweep_block(void *job, uint32_t block) {
	const SweepJob *j = (const SweepJob *)job;
	int first = (int)block * LINE_BLOCK;
	j->field->sweep_lines(j->along_rows, j->k, first, std::min(first + LINE_BLOCK, j->field->n));
}

void NutrientField::sweep(bool along_rows, double k) {
	SweepJob job = { this, along_rows, k };
	run_blocks(&NutrientField::run_sweep_block, &job, (n + LINE_BLOCK - 1) / LINE_BLOCK);
}

void NutrientField::diffuse(double dt) {
	bool any = false; // (a field with nothing in it stays empty: diffusing it would only write zeros, and the second food mostly is empty)
	for (float c : conc) {
		if (c != 0.0f) {
			any = true;
			break;
		}
	}
	if (!any) {
		return;
	}
	double k = get_diffusion() * dt / (spacing * spacing);
	sweep(true, k);
	sweep(false, k);
}

double NutrientField::grid_total() const {
	double sum = 0.0;
	for (float c : conc) {
		sum += c;
	}
	return sum * spacing * spacing;
}

double NutrientField::total() const {
	double sum = grid_total();
	for (const Puff &p : puffs) {
		sum += p.mass;
	}
	for (const auto &item : emitters) {
		sum += item.second.mass;
	}
	return sum;
}

PackedFloat32Array NutrientField::values() const {
	return to_packed<PackedFloat32Array>(conc);
}

Dictionary NutrientField::export_packed() const {
	PackedFloat32Array packed;
	packed.resize((int64_t)puffs.size() * 5);
	float *w = packed.ptrw();
	for (size_t k = 0; k < puffs.size(); k++) {
		const Puff &p = puffs[k];
		w[k * 5] = (float)p.x;
		w[k * 5 + 1] = (float)p.y;
		w[k * 5 + 2] = (float)p.mass;
		w[k * 5 + 3] = (float)p.var;
		w[k * 5 + 4] = (float)p.cut;
	}
	Dictionary out;
	out["conc"] = values();
	out["puffs"] = packed;
	return out;
}

void NutrientField::import_packed(const PackedFloat32Array &new_conc, const PackedFloat32Array &new_puffs) {
	ERR_FAIL_COND_MSG(new_conc.size() != (int64_t)conc.size(), "NutrientField.import_packed: the grid is not this field's size");
	ERR_FAIL_COND_MSG(new_puffs.size() % 5 != 0, "NutrientField.import_packed: clouds are 5 floats each");
	const float *c = new_conc.ptr();
	for (size_t i = 0; i < conc.size(); i++) {
		conc[i] = inside[i] ? c[i] : 0.0f;
	}
	const float *q = new_puffs.ptr();
	int64_t clouds = new_puffs.size() / 5;
	puffs.clear();
	puffs.reserve((size_t)clouds);
	for (int64_t k = 0; k < clouds; k++) {
		Puff p = { q[k * 5], q[k * 5 + 1], q[k * 5 + 2], q[k * 5 + 3], q[k * 5 + 4] };
		if (p.var > 0.0 && p.mass > 0.0) {
			puffs.push_back(p);
		}
	}
	hash_dirty = true;
}

PackedInt32Array NutrientField::export_owner() const {
	return to_packed<PackedInt32Array>(owner);
}

// An amber haze, fainter where there is less nutrient (nothing at all below `visible_above`).
PackedByteArray NutrientField::haze_bytes(double visible_above, double alpha_scale, double max_alpha) const {
	PackedByteArray out;
	out.resize((int64_t)conc.size() * 4);
	uint8_t *w = out.ptrw();
	std::vector<float> view = view_values();
	for (size_t i = 0; i < conc.size(); i++) {
		double c = view[i];
		uint8_t *p = w + i * 4;
		if (c > visible_above) {
			p[0] = 230;
			p[1] = 191;
			p[2] = 77;
			p[3] = (uint8_t)std::min(std::sqrt(c) * alpha_scale, max_alpha);
		} else {
			p[0] = p[1] = p[2] = p[3] = 0;
		}
	}
	return out;
}

// A cool tint where a swimmer of this speed and sense range could tell up the gradient from down it, stronger where it
// does so more reliably (the chance of ending up further up the slope: see steering_chance), and nothing
// where it is only guessing.
PackedByteArray NutrientField::steer_bytes(double speed, double sense_range, double max_alpha) const {
	PackedByteArray out;
	out.resize((int64_t)conc.size() * 4);
	uint8_t *w = out.ptrw();
	std::vector<float> view = view_values();
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) {
			size_t i = (size_t)y * n + x;
			uint8_t *p = w + i * 4;
			p[0] = p[1] = p[2] = p[3] = 0;
			if (!inside[i]) {
				continue;
			}
			int xm = std::max(x - 1, 0), xp = std::min(x + 1, n - 1), ym = std::max(y - 1, 0), yp = std::min(y + 1, n - 1);
			double gx = (view_cell(view, xp, y) - view_cell(view, xm, y)) / ((xp - xm) * spacing);
			double gy = (view_cell(view, x, yp) - view_cell(view, x, ym)) / ((yp - ym) * spacing);
			double reliable = 2.0 * steering_chance(speed, sense_range, view[i], std::sqrt(gx * gx + gy * gy)) - 1.0; // (twice the chance above a coin toss: 0 where it only guesses, 1 where it is sure)
			p[0] = 90;
			p[1] = 190;
			p[2] = 255;
			p[3] = (uint8_t)(reliable * max_alpha);
		}
	}
	return out;
}

Vector2 NutrientField::cell_centre(int i) const {
	return Vector2((float)((i % n + 0.5) * spacing - origin), (float)((i / n + 0.5) * spacing - origin));
}

void NutrientField::load_values(const Array &saved) {
	int count = std::min((int)saved.size(), n * n);
	for (int i = 0; i < count; i++) {
		conc[i] = inside[i] ? (float)(double)saved[i] : 0.0f;
	}
}
