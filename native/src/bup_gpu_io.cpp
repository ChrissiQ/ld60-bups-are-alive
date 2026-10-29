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

// BupSim's side of the GPU path: the bups as the GPU's records, and the family events a batch of GPU steps made.

// ---- the GPU simulation's records and events ------------------------------------------------

// Every bup as the GPU simulation's record (gpu/kernels.gd): 28 32-bit words, 0 the id's low word, 1-20 x, y, dx, dy, energy, mass,
// birth_mass, speed, sense, metabolism, size, reach, mutator, donor, harm, hue, sat, val, mutations, divisions (floats),
// 21 the id's high word, 22-23 where it was in the last picture (NO_PICTURE if nowhere yet), 24-27 its chemotaxis memory (the fast and the
// slow signal, the receptor noise, the seconds of tumble left; a fast signal below 0 means it has not read one yet).
PackedByteArray BupSim::export_state_bytes() const {
	PackedByteArray out;
	out.resize((int64_t)bups.size() * STATE_WORDS * 4);
	uint8_t *w = out.ptrw();
	for (size_t i = 0; i < bups.size(); i++) {
		const Bup &b = bups[i];
		uint8_t *r = w + i * STATE_WORDS * 4;
		const float body[7] = { b.x, b.y, b.dx, b.dy, b.energy, b.mass, b.birth_mass };
		put_u32(r, 0, (uint32_t)((uint64_t)b.id & 0xFFFFFFFFULL));
		for (int k = 0; k < 7; k++) {
			put_f32(r, 1 + k, body[k]);
		}
		put_record_genome(r, genome_of(b));
		put_f32(r, 20, (float)b.divisions);
		put_u32(r, 21, (uint32_t)((uint64_t)b.id >> 32));
		put_f32(r, 22, std::isnan(b.px) ? NO_PICTURE : b.px);
		put_f32(r, 23, std::isnan(b.py) ? NO_PICTURE : b.py);
		put_f32(r, 24, b.primed ? b.fast : -1.0f);
		put_f32(r, 25, b.slow);
		put_f32(r, 26, b.noise);
		put_f32(r, 27, b.tumbling);
	}
	return out;
}

BupSim::Genome BupSim::record_genome(const uint8_t *record) {
	Genome g;
	for (int k = 0; k < 4; k++) {
		g.genes[k] = get_f32(record, 8 + k);
	}
	g.reach = (int)(get_f32(record, 12) + 0.5f);
	g.mutator = get_f32(record, 13);
	g.donor = get_f32(record, 14) > 0.5f;
	g.harm = get_f32(record, 15);
	g.hue = get_f32(record, 16);
	g.sat = get_f32(record, 17);
	g.val = get_f32(record, 18);
	g.mutations = (int)get_f32(record, 19);
	return g;
}

void BupSim::put_record_genome(uint8_t *record, const Genome &g) {
	for (int k = 0; k < 4; k++) {
		put_f32(record, 8 + k, g.genes[k]);
	}
	put_f32(record, 12, (float)g.reach);
	put_f32(record, 13, g.mutator);
	put_f32(record, 14, g.donor ? 1.0f : 0.0f);
	put_f32(record, 15, g.harm);
	put_f32(record, 16, g.hue);
	put_f32(record, 17, g.sat);
	put_f32(record, 18, g.val);
	put_f32(record, 19, (float)g.mutations);
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
	set_genome(b, record_genome(record));
	b.divisions = (int)get_f32(record, 20);
	float px = get_f32(record, 22), py = get_f32(record, 23);
	b.px = px >= 1e30f ? std::numeric_limits<float>::quiet_NaN() : px;
	b.py = py >= 1e30f ? std::numeric_limits<float>::quiet_NaN() : py;
	b.fast = get_f32(record, 24);
	b.primed = b.fast >= 0.0f;
	b.slow = get_f32(record, 25);
	b.noise = get_f32(record, 26);
	b.tumbling = get_f32(record, 27);
	derive(b); // (yield, add_mass and drag_upkeep, as the CPU works them out: the record keeps the mutator in word 13 where the GPU's building size was)
	return b;
}

// The bups become those of the records (as export_state_bytes makes them); the family records are left as they are (on the GPU path
// they are kept up by apply_events, which must have been given every birth and death up to this state first). The next id never goes back past an id in the state.
void BupSim::import_state_bytes(const PackedByteArray &state) {
	ERR_FAIL_COND_MSG(state.size() % (STATE_WORDS * 4) != 0, "BupSim.import_state_bytes: not a whole number of 112-byte records");
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
	ERR_FAIL_COND_V_MSG(state.size() % (STATE_WORDS * 4) != 0, Dictionary(), "BupSim.info_from_state: not a whole number of 112-byte records");
	if (index < 0 || (int64_t)index >= state.size() / (STATE_WORDS * 4)) {
		return Dictionary();
	}
	return info_of(bup_from_record(state.ptr() + (size_t)index * STATE_WORDS * 4));
}

// The family records of a batch of GPU steps (little-endian 32-bit words):
//   a birth, 16 words: id lo, id hi, parent lo, parent hi, step, divisions, mutations (uints; the low 20 bits, with the bup's reach word in bits 20-29 and its F factor in bit 30), speed, sense, metabolism, size, hue, sat,
//     val, harm, mutator (floats);
//   a death, 14 words: id lo, id hi, step, divisions (uint: the low 20 bits, with the bup's reach word in bits 20-29 and its F factor in bit 30), mass, x, y, the nutrient energy it gives back (floats; 0 for one that does not:
//     a trimmed one), then its own energy, the mass it was born with and its four genes (floats). With husks on, words 5-7 make the husk.
// `step` is the step's place in the batch (from 0), and step k ended at first_step_end_seconds + k * step_seconds, which is when its
// records are stamped (and a husk made then has been leaking since: it is as old as the dish's clock is past that). Each list is in the order of its steps. Step by step, the births are recorded and then the deaths (a bup never
// divides and dies in the same step, except one displaced at the limit after dividing, which is held by its daughter either way).
// The bups themselves are not touched. A birth whose id already has a record (a batch given twice) is passed over. The next id is
// kept past every id born.
void BupSim::apply_events(const PackedByteArray &births, const PackedByteArray &deaths, double first_step_end_seconds, double step_seconds) {
	ERR_FAIL_COND_MSG(births.size() % (BIRTH_WORDS * 4) != 0, "BupSim.apply_events: births are 64 bytes each");
	ERR_FAIL_COND_MSG(deaths.size() % (DEATH_WORDS * 4) != 0, "BupSim.apply_events: deaths are 56 bytes each");
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
			b.divisions = (int)get_u32(e, 5);
			const uint32_t traits = get_u32(e, 6); // the mutations in the low 20 bits, the reach word above them (10 bits), the F factor at bit 30
			Genome g;
			g.mutations = (int)(traits & 0xFFFFFu);
			g.reach = (int)((traits >> 20) & 0x3FFu);
			g.donor = ((traits >> 30) & 1u) != 0;
			for (int k = 0; k < 4; k++) {
				g.genes[k] = get_f32(e, 7 + k);
			}
			g.hue = get_f32(e, 11);
			g.sat = get_f32(e, 12);
			g.val = get_f32(e, 13);
			g.harm = get_f32(e, 14);
			g.mutator = get_f32(e, 15);
			set_genome(b, g);
			make_record(b, get_id(e, 2, 3));
			next_id = std::max(next_id, b.id + 1); // (a bup added here later never takes a number the GPU has given)
		}
		for (; di < died_count && get_u32(dp + di * DEATH_WORDS * 4, 2) == step; di++) {
			const uint8_t *e = dp + di * DEATH_WORDS * 4;
			Bup b;
			b.id = get_id(e, 0, 1);
			const uint32_t traits = get_u32(e, 3); // the divisions in the low 20 bits, the reach word above them, the F factor at bit 30 (as the bup was when it died)
			b.divisions = (int)(traits & 0xFFFFFu);
			b.reach = (int)((traits >> 20) & 0x3FFu);
			b.donor = ((traits >> 30) & 1u) != 0;
			b.mass = get_f32(e, 4);
			b.energy = get_f32(e, 8);
			b.birth_mass = get_f32(e, 9);
			for (int g = 0; g < 4; g++) {
				b.genes[g] = get_f32(e, 10 + g);
			}
			record_death(b);
			if (death_husks && get_f32(e, 7) > 0.0f) {
				add_husk(get_f32(e, 5), get_f32(e, 6), get_f32(e, 7), std::max(now_before - now_seconds, 0.0));
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
