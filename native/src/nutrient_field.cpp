#include "nutrient_field.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

void NutrientField::_bind_methods() {
	ClassDB::bind_static_method("NutrientField", D_METHOD("size_for", "dish_radius"), &NutrientField::size_for);
	ClassDB::bind_method(D_METHOD("reset", "dish_radius"), &NutrientField::reset);
	ClassDB::bind_method(D_METHOD("resize", "dish_radius"), &NutrientField::resize);
	ClassDB::bind_method(D_METHOD("get_size"), &NutrientField::get_size);
	ClassDB::bind_method(D_METHOD("get_spacing"), &NutrientField::get_spacing);
	ClassDB::bind_method(D_METHOD("accepts", "local"), &NutrientField::accepts);
	ClassDB::bind_method(D_METHOD("deposit", "local", "energy"), &NutrientField::deposit);
	ClassDB::bind_method(D_METHOD("deposit_disc", "local", "radius", "energy"), &NutrientField::deposit_disc);
	ClassDB::bind_method(D_METHOD("erase_disc", "local", "radius", "strength"), &NutrientField::erase_disc);
	ClassDB::bind_method(D_METHOD("sample", "local"), &NutrientField::sample);
	ClassDB::bind_method(D_METHOD("read", "local"), &NutrientField::read);
	ClassDB::bind_method(D_METHOD("gradient", "local"), &NutrientField::gradient);
	ClassDB::bind_method(D_METHOD("take", "local", "energy"), &NutrientField::take);
	ClassDB::bind_method(D_METHOD("fill", "energy"), &NutrientField::fill);
	ClassDB::bind_method(D_METHOD("diffuse", "dt"), &NutrientField::diffuse);
	ClassDB::bind_method(D_METHOD("total"), &NutrientField::total);
	ClassDB::bind_method(D_METHOD("is_empty"), &NutrientField::is_empty);
	ClassDB::bind_method(D_METHOD("values"), &NutrientField::values);
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

void NutrientField::reset(double dish_radius) {
	build(dish_radius, size_for(dish_radius));
}

void NutrientField::build(double dish_radius, int cells_across) {
	radius = dish_radius;
	origin = dish_radius;
	n = cells_across;
	spacing = 2.0 * dish_radius / n;
	conc.assign((size_t)n * n, 0.0f);
	inside.assign((size_t)n * n, 0);
	cp.assign(n, 0.0);
	dp.assign(n, 0.0);
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
}

// The dish changes size: the nutrient stays where it is, on the new grid. Each new cell takes the old field's
// (smoothed) value at its centre. A larger dish is then scaled to hold exactly the nutrient there was; a smaller one
// keeps the concentration where it was, and the nutrient past the new edge is gone.
void NutrientField::resize(double dish_radius) {
	bool shrinking = dish_radius < radius;
	std::vector<float> old_conc = conc;
	int old_n = n;
	double old_spacing = spacing, old_origin = origin, old_total = total();
	reset(dish_radius);
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
	double new_total = total();
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

double NutrientField::cell_value(int ix, int iy) const {
	int i = iy * n + ix;
	if (!inside[i]) {
		i = nearest_inside(ix, iy);
	}
	return i < 0 ? 0.0 : (double)conc[i];
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
		conc[cells[0]] += (float)(energy / (spacing * spacing));
		return;
	}
	for (int k = 0; k < count; k++) {
		conc[cells[k]] += (float)(energy * weights[k] / kept / (spacing * spacing));
	}
}

void NutrientField::deposit(const Vector2 &local, double energy) {
	deposit_xy(local.x, local.y, energy);
}

void NutrientField::deposit_disc(const Vector2 &local, double disc_radius, double energy) {
	std::vector<int> targets;
	for (int i = 0; i < n * n; i++) {
		if (!inside[i]) {
			continue;
		}
		double cx = (i % n + 0.5) * spacing - origin, cy = (i / n + 0.5) * spacing - origin;
		double dx = cx - local.x, dy = cy - local.y;
		if (std::sqrt(dx * dx + dy * dy) <= disc_radius) {
			targets.push_back(i);
		}
	}
	if (targets.empty()) {
		deposit_xy(local.x, local.y, energy);
		return;
	}
	float per_cell = (float)(energy / (targets.size() * spacing * spacing));
	for (int i : targets) {
		conc[i] += per_cell;
	}
}

double NutrientField::erase_disc(const Vector2 &local, double disc_radius, double strength) {
	double removed = 0.0;
	for (int i = 0; i < n * n; i++) {
		if (!inside[i]) {
			continue;
		}
		double cx = (i % n + 0.5) * spacing - origin, cy = (i / n + 0.5) * spacing - origin;
		double dx = cx - local.x, dy = cy - local.y;
		double d = std::sqrt(dx * dx + dy * dy);
		if (d >= disc_radius) {
			continue;
		}
		double taken = conc[i] * strength * (1.0 - d / disc_radius);
		conc[i] -= (float)taken;
		removed += taken * spacing * spacing;
	}
	return removed;
}

void NutrientField::read_xy(double x, double y, double &c, double &gx, double &gy) const {
	double fx = std::clamp((x + origin) / spacing - 0.5, 0.0, n - 1.001);
	double fy = std::clamp((y + origin) / spacing - 0.5, 0.0, n - 1.001);
	int x0 = (int)fx, y0 = (int)fy;
	double tx = fx - x0, ty = fy - y0;
	double c00 = cell_value(x0, y0), c10 = cell_value(x0 + 1, y0), c01 = cell_value(x0, y0 + 1), c11 = cell_value(x0 + 1, y0 + 1);
	double top = c00 + (c10 - c00) * tx;
	double bottom = c01 + (c11 - c01) * tx;
	c = top + (bottom - top) * ty;
	gx = ((c10 - c00) + ((c11 - c01) - (c10 - c00)) * ty) / spacing;
	gy = (bottom - top) / spacing;
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

double NutrientField::take_xy(double x, double y, double energy) {
	int i = index_at(x, y);
	if (!inside[i]) {
		i = nearest_inside(i % n, i / n);
		if (i < 0) {
			return 0.0;
		}
	}
	double area = spacing * spacing;
	double taken = std::min(energy, (double)conc[i] * area);
	conc[i] -= (float)(taken / area);
	return taken;
}

double NutrientField::take(const Vector2 &local, double energy) {
	return take_xy(local.x, local.y, energy);
}

void NutrientField::fill(double energy) {
	if (inside_count == 0 || energy <= 0.0) {
		return;
	}
	float per_cell = (float)(energy / (inside_count * spacing * spacing));
	for (size_t i = 0; i < conc.size(); i++) {
		if (inside[i]) {
			conc[i] += per_cell;
		}
	}
}

void NutrientField::solve_run(int first, int step, int count, double k) {
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

void NutrientField::sweep(bool along_rows, double k) {
	int step = along_rows ? 1 : n;
	int line_step = along_rows ? n : 1;
	for (int line = 0; line < n; line++) {
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
				solve_run(base + start * step, step, i - start, k);
			}
		}
	}
}

void NutrientField::diffuse(double dt) {
	double k = G.diffusion * dt / (spacing * spacing);
	sweep(true, k);
	sweep(false, k);
}

double NutrientField::total() const {
	double sum = 0.0;
	for (float c : conc) {
		sum += c;
	}
	return sum * spacing * spacing;
}

PackedFloat32Array NutrientField::values() const {
	PackedFloat32Array out;
	out.resize((int64_t)conc.size());
	if (!conc.empty()) {
		memcpy(out.ptrw(), conc.data(), conc.size() * sizeof(float));
	}
	return out;
}

// An amber haze, fainter where there is less nutrient (nothing at all below `visible_above`).
PackedByteArray NutrientField::haze_bytes(double visible_above, double alpha_scale, double max_alpha) const {
	PackedByteArray out;
	out.resize((int64_t)conc.size() * 4);
	uint8_t *w = out.ptrw();
	for (size_t i = 0; i < conc.size(); i++) {
		double c = conc[i];
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
// does so more reliably (the chance of drifting up, above a coin toss), and nothing where it is only guessing.
PackedByteArray NutrientField::steer_bytes(double speed, double sense_range, double max_alpha) const {
	PackedByteArray out;
	out.resize((int64_t)conc.size() * 4);
	uint8_t *w = out.ptrw();
	for (int y = 0; y < n; y++) {
		for (int x = 0; x < n; x++) {
			size_t i = (size_t)y * n + x;
			uint8_t *p = w + i * 4;
			p[0] = p[1] = p[2] = p[3] = 0;
			if (!inside[i]) {
				continue;
			}
			int xm = std::max(x - 1, 0), xp = std::min(x + 1, n - 1), ym = std::max(y - 1, 0), yp = std::min(y + 1, n - 1);
			double gx = (cell_value(xp, y) - cell_value(xm, y)) / ((xp - xm) * spacing);
			double gy = (cell_value(x, yp) - cell_value(x, ym)) / ((yp - ym) * spacing);
			double snr = steering_snr(speed, sense_range, conc[i], std::sqrt(gx * gx + gy * gy));
			double reliable = std::erf(snr / std::sqrt(2.0)); // 2 * (chance of drifting up) - 1
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
