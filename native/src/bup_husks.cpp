#include "bup_sim.h"

#include "bup_internal.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <unordered_map>
#include <unordered_set>

using namespace godot;

// The husks: what a dead bup leaves, and its slow leak of nutrient.

// The share of a husk's nutrient that leaks in piece k: what an exponential leak lets go in the k-th quarter of a lifetime, and in the last
// piece what is left after the HUSK_PIECES quarters.
static double husk_share(int k) {
	double share = std::exp(-0.25 * k) - std::exp(-0.25 * (k + 1));
	return k == HUSK_PIECES - 1 ? share + std::exp(-0.25 * HUSK_PIECES) : share;
}

void BupSim::add_husk(float x, float y, float energy, double age) {
	if (husks.size() >= MAX_HUSKS) {
		field->add_cloud(Vector2(x, y), 0.0, energy);
		return;
	}
	husks.push_back({ x, y, energy, age, 0 }); // (the pieces its age has passed are let go at the next advance_husks)
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

PackedFloat32Array BupSim::husk_buffer(double size, int capacity) const {
	PackedFloat32Array out;
	out.resize((int64_t)std::max((size_t)std::max(capacity, 0), husks.size()) * 8);
	out.fill(0.0f);
	float *w = out.ptrw();
	const float s = (float)size;
	size_t n = 0;
	for (const Husk &h : husks) {
		float *p = w + n * 8;
		p[0] = s;
		p[3] = h.x;
		p[5] = s;
		p[7] = h.y;
		n++;
	}
	return out;
}

PackedFloat64Array BupSim::husk_near(const Vector2 &at, double radius) const {
	PackedFloat64Array out;
	double best = radius * radius;
	const Husk *found = nullptr;
	for (const Husk &h : husks) {
		const double dx = (double)h.x - at.x, dy = (double)h.y - at.y;
		const double d2 = dx * dx + dy * dy;
		if (d2 <= best) {
			best = d2;
			found = &h;
		}
	}
	if (found != nullptr) {
		out.resize(5);
		double *w = out.ptrw();
		w[0] = found->x;
		w[1] = found->y;
		w[2] = found->energy;
		w[3] = found->age;
		w[4] = found->next;
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
