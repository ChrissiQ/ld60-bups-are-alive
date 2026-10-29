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

// Conjugation. A donor (a bup with the F factor integrated in its chromosome) that touches a bup that is not one (centres no farther apart than
// the two bodies' radii and Genome.CONTACT_UM) passes on a run of its genes, in the order speed, sense, metabolism, size, from a fixed origin, the
// way an Hfr cell does: the first gene always, each next one with the chance CONJ_CONTINUE (the mating breaks off at random). A touching pair
// transfers at the rate `conj_rate` a second. A bup takes from one donor in a step (the lowest-numbered of those that transfer).
void BupSim::conjugate(double delta) {
	std::vector<int> donors;
	for (size_t i = 0; i < bups.size(); i++) {
		if (bups[i].donor) {
			donors.push_back((int)i);
		}
	}
	if (donors.empty()) {
		return;
	}
	const double chance = 1.0 - std::exp(-G.conj_rate * delta);
	std::vector<char> taken(bups.size(), 0);

	// A donor can only touch what is within one body radius of it, a contact distance and another body radius: so the bups are looked up
	// by the cell of a grid at least that wide, and only the cells round a donor are kept. (Checking every donor against every bup
	// was 15 ms of a 29 ms step at 100,000 bups, 87 of them donors.) The draws of the random numbers are as they were: each donor, in
	// order, then the bups it could touch, in order.
	double widest = 0.0;
	for (const Bup &b : bups) {
		widest = std::max(widest, body_radius(b));
	}
	const double cell = 2.0 * widest + G.contact_um + 1.0e-6;
	auto cell_key = [](double cx, double cy) -> uint64_t {
		return ((uint64_t)(uint32_t)(int32_t)cx << 32) | (uint64_t)(uint32_t)(int32_t)cy;
	};
	std::unordered_map<uint64_t, std::vector<int>> near;
	// A small table of bits says at a glance whether a cell can be one of those (a few thousand at most): most bups are nowhere near a donor, and one bit test
	// per bup is far cheaper than a lookup in the map (which is what the pass over 100,000 bups cost).
	const double per_cell = 1.0 / cell; // (every cell is worked out with this, donors and the rest alike, so that a bup on an edge is never in two different cells by rounding)
	static constexpr int HASH_BITS = 16; // (static, so that MSVC lets the lambda below use it without capturing it)
	std::vector<uint64_t> maybe((size_t)1 << (HASH_BITS - 6), 0);
	auto bit_of = [](uint64_t key) -> uint32_t {
		return (uint32_t)((key * 0x9E3779B97F4A7C15ull) >> (64 - HASH_BITS));
	};
	for (int d : donors) {
		const double cx = std::floor((double)bups[d].x * per_cell), cy = std::floor((double)bups[d].y * per_cell);
		for (int ox = -1; ox <= 1; ox++) {
			for (int oy = -1; oy <= 1; oy++) {
				const uint64_t key = cell_key(cx + ox, cy + oy);
				near[key];
				const uint32_t bit = bit_of(key);
				maybe[bit >> 6] |= (uint64_t)1 << (bit & 63);
			}
		}
	}
	for (size_t r = 0; r < bups.size(); r++) {
		const Bup &b = bups[r];
		if (b.donor) {
			continue;
		}
		const uint64_t key = cell_key(std::floor(b.x * per_cell), std::floor(b.y * per_cell));
		const uint32_t bit = bit_of(key);
		if (!((maybe[bit >> 6] >> (bit & 63)) & 1)) {
			continue;
		}
		auto at = near.find(key);
		if (at != near.end()) {
			at->second.push_back((int)r); // (in order of r)
		}
	}
	std::vector<int> candidates;
	for (int d : donors) {
		const Bup &from = bups[d];
		const double reach = body_radius(from) + G.contact_um;
		candidates.clear();
		const double cx = std::floor((double)from.x * per_cell), cy = std::floor((double)from.y * per_cell);
		for (int ox = -1; ox <= 1; ox++) {
			for (int oy = -1; oy <= 1; oy++) {
				auto at = near.find(cell_key(cx + ox, cy + oy));
				if (at != near.end()) {
					candidates.insert(candidates.end(), at->second.begin(), at->second.end());
				}
			}
		}
		std::sort(candidates.begin(), candidates.end());
		for (int r : candidates) {
			Bup &to = bups[r];
			if (to.donor || taken[r]) {
				continue;
			}
			double dx = (double)to.x - from.x, dy = (double)to.y - from.y, range = reach + body_radius(to);
			if (dx * dx + dy * dy > range * range || uniform() >= chance) {
				continue;
			}
			int run = 1;
			while (run < 4 && uniform() < G.conj_continue) {
				run++;
			}
			for (int g = 0; g < run; g++) {
				to.genes[g] = from.genes[g];
			}
			int mask = (1 << (2 * run)) - 1; // (the raised ceilings of the genes that moved go with them)
			to.reach = (to.reach & ~mask) | (from.reach & mask);
			derive(to);
			taken[r] = 1;
			transfers++;
		}
	}
}
