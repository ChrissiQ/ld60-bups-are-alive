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

// BupSim's family records: who each bup came from, kept while anything holds them, and their save and load.

// ---- family records ------------------------------------------------------------------------

void BupSim::make_record(const Bup &b, int64_t parent) {
	Record r;
	auto p = records.find(parent);
	if (p != records.end()) {
		r.parent = parent;
		p->second.holds++;
	}
	r.born = now_minutes();
	r.divisions = b.divisions;
	r.g = b.g;
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
	r.divisions = b.divisions;
	r.max_energy = (float)max_energy(b);
	// (the genes and their raised ceilings as they were when it died: a conjugation can have changed them since it was born; the rest of a genome is as it was born)
	r.g.genes = b.g.genes;
	r.g.reach = b.g.reach;
	r.g.donor = b.g.donor;
	r.mass = b.mass;
	r.energy = b.energy;
	r.birth_mass = b.birth_mass;
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
	out["divisions"] = r.divisions;
	put_genome(out, r.g, true);
	out["max_energy"] = r.max_energy;
	out["mass"] = r.mass;
	out["energy"] = r.energy;
	out["birth_mass"] = r.birth_mass;
	out["div_mass"] = r.birth_mass + (float)(G.add_mass_factor * (double)r.g.genes[3] * (double)r.g.genes[3]);  // (the mass it divides at: what it was born with and what it adds)
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
		out["divisions"] = bups[i].divisions;
		out["max_energy"] = max_energy(bups[i]);
		out["mass"] = bups[i].mass;
		out["energy"] = bups[i].energy;
		out["birth_mass"] = bups[i].birth_mass;
		out["div_mass"] = bups[i].birth_mass + bups[i].add_mass;
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
		put<int32_t>(at, r.divisions);
		put<int32_t>(at, r.g.mutations);
		for (int g = 0; g < GENE_COUNT; g++) {
			put<float>(at, r.g.genes[g]);
		}
		put<float>(at, r.g.hue);
		put<float>(at, r.g.sat);
		put<float>(at, r.g.val);
		put<float>(at, r.g.harm);
		put<float>(at, r.g.mutator);
		put<float>(at, r.max_energy);
		put<uint32_t>(at, (uint32_t)r.g.reach | (r.g.donor ? 1u << 31 : 0u));
		put<float>(at, r.mass);
		put<float>(at, r.energy);
		put<float>(at, r.birth_mass);
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
		r.divisions = take<int32_t>(at);
		r.g.mutations = take<int32_t>(at);
		for (int g = 0; g < GENE_COUNT; g++) {
			r.g.genes[g] = take<float>(at);
		}
		r.g.hue = take<float>(at);
		r.g.sat = take<float>(at);
		r.g.val = take<float>(at);
		r.g.harm = take<float>(at);
		r.g.mutator = take<float>(at);
		r.max_energy = take<float>(at);
		uint32_t traits = take<uint32_t>(at);
		r.g.reach = (int)(traits & 0x7FFFFFFFu);
		r.g.donor = (traits >> 31) != 0;
		r.mass = take<float>(at);
		r.energy = take<float>(at);
		r.birth_mass = take<float>(at);
		r.alive = living.count(id) > 0;
		if (r.alive) {
			r.died = -1;
		} else if (r.died < 0) {
			r.died = now_minutes(); // (alive where it was exported from, but not among these bups: it is not alive here)
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
