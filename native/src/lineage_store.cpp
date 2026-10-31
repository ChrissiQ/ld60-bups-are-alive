#include "lineage_store.h"

#include <godot_cpp/core/error_macros.hpp>

#include <algorithm>
#include <cstring>

using namespace godot;

// ---- the words of the GPU's events, and the export's fields --------------------------------------------------------

namespace {
constexpr int BIRTH_WORDS = 16, DEATH_WORDS = 14;
constexpr uint32_t STEP_MASK = 0x1FFF; // a death's step word: the step's place in the batch in the low 13 bits, the dish number above
constexpr int DISH_SHIFT = 13, DISH_MASK = 0x7FFFF;
constexpr int ID_DISH_SHIFT = 44; // an id: the dish it was born in above its counter's 44 bits

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
int birth_dish(int64_t id) {
	return (int)((id >> ID_DISH_SHIFT) & DISH_MASK);
}
} // namespace

void LineageStore::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_constants", "reserve_per_mass", "add_mass_factor"), &LineageStore::set_constants);
	ClassDB::bind_method(D_METHOD("set_time", "seconds"), &LineageStore::set_time);
	ClassDB::bind_method(D_METHOD("apply_events", "births", "deaths", "first_step_end", "step_seconds"), &LineageStore::apply_events);
	ClassDB::bind_method(D_METHOD("info", "id"), &LineageStore::info);
	ClassDB::bind_method(D_METHOD("chain", "id"), &LineageStore::chain);
	ClassDB::bind_method(D_METHOD("has_record", "id"), &LineageStore::has_record);
	ClassDB::bind_method(D_METHOD("pin", "id", "holder"), &LineageStore::pin);
	ClassDB::bind_method(D_METHOD("unpin", "id", "holder"), &LineageStore::unpin);
	ClassDB::bind_method(D_METHOD("set_custom_name", "id", "name"), &LineageStore::set_custom_name);
	ClassDB::bind_method(D_METHOD("custom_name", "id"), &LineageStore::custom_name);
	ClassDB::bind_method(D_METHOD("living_descendants_of", "ids", "number"), &LineageStore::living_descendants_of, DEFVAL(-1));
	ClassDB::bind_method(D_METHOD("retarget_ids", "ids", "number"), &LineageStore::retarget_ids);
	ClassDB::bind_method(D_METHOD("export_dish", "number", "live"), &LineageStore::export_dish);
	ClassDB::bind_method(D_METHOD("release_dish", "number", "live", "minutes", "claimed_ids"), &LineageStore::release_dish, DEFVAL(PackedInt64Array()));
	ClassDB::bind_method(D_METHOD("discard_frozen", "number"), &LineageStore::discard_frozen);
	ClassDB::bind_method(D_METHOD("import_bytes", "data", "watched", "live", "number"), &LineageStore::import_bytes);
	ClassDB::bind_method(D_METHOD("export_bytes"), &LineageStore::export_bytes);
	ClassDB::bind_method(D_METHOD("record_count"), &LineageStore::record_count);
	ClassDB::bind_method(D_METHOD("alive_ids"), &LineageStore::alive_ids);
	ClassDB::bind_method(D_METHOD("holds", "id"), &LineageStore::holds);
	ClassDB::bind_method(D_METHOD("tombstone", "id"), &LineageStore::tombstone);
	ClassDB::bind_method(D_METHOD("tombstone_count"), &LineageStore::tombstone_count);
	ClassDB::bind_method(D_METHOD("claim_count"), &LineageStore::claim_count);
}

void LineageStore::set_constants(double reserve_per_mass_value, double add_mass_factor_value) {
	std::lock_guard<std::mutex> lock(mutex);
	reserve_per_mass = reserve_per_mass_value;
	add_mass_factor = add_mass_factor_value;
}

void LineageStore::set_time(double seconds) {
	std::lock_guard<std::mutex> lock(mutex);
	now_seconds = seconds;
}

// ---- the records ------------------------------------------------------------------------------------------------

void LineageStore::make_record(int64_t id, int64_t parent, const Record &fields) {
	Record r = fields;
	auto p = records.find(parent);
	if (p != records.end()) {
		r.parent = parent;
		p->second.holds++;
	}
	r.born = now_minutes();
	r.home = birth_dish(id);
	records[id] = r;
}

// The bup has died (in dish `dish`): its record stays only if something living (or being looked at) still needs it.
void LineageStore::record_death(int64_t id, const Record &f, int dish) {
	auto it = records.find(id);
	if (it == records.end()) {
		return;
	}
	Record &r = it->second;
	r.alive = false;
	r.died = now_minutes();
	r.home = dish;
	r.divisions = f.divisions;
	r.max_energy = (float)(reserve_per_mass * (double)f.mass);
	// (the genes and their raised ceilings as they were when it died: a conjugation can have changed them since it was born)
	r.g.genes = f.g.genes;
	r.g.reach = f.g.reach;
	r.g.donor = f.g.donor;
	r.mass = f.mass;
	r.energy = f.energy;
	r.birth_mass = f.birth_mass;
	free_if_unused(id);
}

// Frees a dead record nothing holds, and then the parents that leaves with nothing holding them. A record a frozen dish claims leaves
// its death time in the tombstones.
void LineageStore::free_if_unused(int64_t id) {
	while (id > 0) {
		auto it = records.find(id);
		if (it == records.end() || it->second.alive || it->second.holds > 0) {
			return;
		}
		auto c = frozen_claims.find(id);
		if (c != frozen_claims.end() && !c->second.empty()) {
			tombstones[id] = it->second.died;
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

void LineageStore::apply_events(const PackedByteArray &births, const PackedByteArray &deaths, double first_step_end_seconds, double step_seconds) {
	ERR_FAIL_COND_MSG(births.size() % (BIRTH_WORDS * 4) != 0, "LineageStore.apply_events: births are 64 bytes each");
	ERR_FAIL_COND_MSG(deaths.size() % (DEATH_WORDS * 4) != 0, "LineageStore.apply_events: deaths are 56 bytes each");
	std::lock_guard<std::mutex> lock(mutex);
	const int64_t born_count = births.size() / (BIRTH_WORDS * 4), died_count = deaths.size() / (DEATH_WORDS * 4);
	const uint8_t *bp = births.ptr(), *dp = deaths.ptr();
	int64_t bi = 0, di = 0;
	while (bi < born_count || di < died_count) {
		uint32_t step = UINT32_MAX;
		if (bi < born_count) {
			step = get_u32(bp + bi * BIRTH_WORDS * 4, 4);
		}
		if (di < died_count) {
			step = std::min(step, get_u32(dp + di * DEATH_WORDS * 4, 2) & STEP_MASK);
		}
		now_seconds = first_step_end_seconds + step * step_seconds;
		for (; bi < born_count && get_u32(bp + bi * BIRTH_WORDS * 4, 4) == step; bi++) {
			const uint8_t *e = bp + bi * BIRTH_WORDS * 4;
			int64_t id = get_id(e, 0, 1);
			if (records.count(id) > 0) {
				continue;
			}
			Record f;
			f.divisions = (int)get_u32(e, 5);
			const uint32_t traits = get_u32(e, 6); // the mutations in the low 20 bits, the reach word above them (10 bits), the F factor at bit 30
			f.g.mutations = (int)(traits & 0xFFFFFu);
			f.g.reach = (int)((traits >> 20) & 0x3FFu);
			f.g.donor = ((traits >> 30) & 1u) != 0;
			for (int k = 0; k < GENES; k++) {
				f.g.genes[k] = get_f32(e, 7 + k);
			}
			f.g.hue = get_f32(e, 11);
			f.g.sat = get_f32(e, 12);
			f.g.val = get_f32(e, 13);
			f.g.harm = get_f32(e, 14);
			f.g.mutator = get_f32(e, 15);
			make_record(id, get_id(e, 2, 3), f);
		}
		for (; di < died_count && (get_u32(dp + di * DEATH_WORDS * 4, 2) & STEP_MASK) == step; di++) {
			const uint8_t *e = dp + di * DEATH_WORDS * 4;
			Record f;
			const uint32_t traits = get_u32(e, 3); // the divisions in the low 20 bits, the reach word above them, the F factor at bit 30
			f.divisions = (int)(traits & 0xFFFFFu);
			f.g.reach = (int)((traits >> 20) & 0x3FFu);
			f.g.donor = ((traits >> 30) & 1u) != 0;
			f.mass = get_f32(e, 4);
			f.energy = get_f32(e, 8);
			f.birth_mass = get_f32(e, 9);
			for (int g = 0; g < GENES; g++) {
				f.g.genes[g] = get_f32(e, 10 + g);
			}
			record_death(get_id(e, 0, 1), f, (int)((get_u32(e, 2) >> DISH_SHIFT) & DISH_MASK));
		}
	}
}

// ---- queries --------------------------------------------------------------------------------------------------------

Dictionary LineageStore::record_info(int64_t id, const Record &r) const {
	Dictionary out;
	out["id"] = id;
	out["parent"] = r.parent;
	out["alive"] = r.alive;
	out["born"] = r.born;
	out["died"] = r.alive ? -1 : r.died;
	out["divisions"] = r.divisions;
	static const char *const names[GENES] = { "speed", "sense", "metabolism", "size_gene" };
	for (int i = 0; i < GENES; i++) {
		out[names[i]] = r.g.genes[i];
	}
	out["hue"] = r.g.hue;
	out["sat"] = r.g.sat;
	out["val"] = r.g.val;
	out["harm"] = r.g.harm;
	out["mutator"] = r.g.mutator;
	out["donor"] = r.g.donor;
	out["reach"] = r.g.reach;
	out["mutations"] = r.g.mutations;
	out["max_energy"] = r.max_energy;
	out["mass"] = r.mass;
	out["energy"] = r.energy;
	out["birth_mass"] = r.birth_mass;
	out["div_mass"] = r.birth_mass + (float)(add_mass_factor * (double)r.g.genes[3] * (double)r.g.genes[3]);
	out["name"] = r.name;
	out["home"] = r.home;
	return out;
}

Dictionary LineageStore::info(int64_t id) const {
	std::lock_guard<std::mutex> lock(mutex);
	auto it = records.find(id);
	return it == records.end() ? Dictionary() : record_info(id, it->second);
}

PackedInt64Array LineageStore::chain(int64_t id) const {
	std::lock_guard<std::mutex> lock(mutex);
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

bool LineageStore::has_record(int64_t id) const {
	std::lock_guard<std::mutex> lock(mutex);
	return records.count(id) > 0;
}

bool LineageStore::pin(int64_t id, int holder) {
	std::lock_guard<std::mutex> lock(mutex);
	auto it = records.find(id);
	if (it == records.end()) {
		return false;
	}
	it->second.holds++;
	pins[id][holder]++;
	return true;
}

void LineageStore::unpin(int64_t id, int holder) {
	std::lock_guard<std::mutex> lock(mutex);
	auto p = pins.find(id);
	if (p == pins.end()) {
		return;
	}
	auto h = p->second.find(holder);
	if (h == p->second.end()) {
		return;
	}
	if (--h->second <= 0) {
		p->second.erase(h);
	}
	if (p->second.empty()) {
		pins.erase(p);
	}
	auto it = records.find(id);
	if (it != records.end() && it->second.holds > 0) {
		it->second.holds--;
		free_if_unused(id);
	}
}

void LineageStore::set_custom_name(int64_t id, const String &name) {
	std::lock_guard<std::mutex> lock(mutex);
	auto it = records.find(id);
	if (it != records.end()) {
		it->second.name = name;
	}
}

String LineageStore::custom_name(int64_t id) const {
	std::lock_guard<std::mutex> lock(mutex);
	auto it = records.find(id);
	return it == records.end() ? String() : it->second.name;
}

// One pass over the living records, each walked up its family line.
PackedInt32Array LineageStore::living_descendants_of(const PackedInt64Array &ids, int number) const {
	std::lock_guard<std::mutex> lock(mutex);
	std::unordered_map<int64_t, int> place;
	for (int64_t i = 0; i < ids.size(); i++) {
		place[ids[i]] = (int)i;
	}
	PackedInt32Array counts;
	counts.resize(ids.size());
	for (int64_t i = 0; i < ids.size(); i++) {
		counts.set(i, 0);
	}
	for (const auto &entry : records) {
		if (!entry.second.alive || (number >= 0 && entry.second.home != number)) {
			continue;
		}
		int64_t id = entry.first;
		while (id > 0) {
			auto at = place.find(id);
			if (at != place.end()) {
				counts.set(at->second, counts[at->second] + 1);
			}
			auto it = records.find(id);
			if (it == records.end()) {
				break;
			}
			id = it->second.parent;
		}
	}
	return counts;
}

void LineageStore::retarget_ids(const PackedInt64Array &ids, int number) {
	std::lock_guard<std::mutex> lock(mutex);
	for (int64_t i = 0; i < ids.size(); i++) {
		auto it = records.find(ids[i]);
		if (it != records.end()) {
			it->second.home = number;
		}
	}
}

int64_t LineageStore::record_count() const {
	std::lock_guard<std::mutex> lock(mutex);
	return (int64_t)records.size();
}

PackedInt64Array LineageStore::alive_ids() const {
	std::lock_guard<std::mutex> lock(mutex);
	std::vector<int64_t> ids;
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

int LineageStore::holds(int64_t id) const {
	std::lock_guard<std::mutex> lock(mutex);
	auto it = records.find(id);
	return it == records.end() ? -1 : it->second.holds;
}

int LineageStore::tombstone(int64_t id) const {
	std::lock_guard<std::mutex> lock(mutex);
	auto it = tombstones.find(id);
	return it == tombstones.end() ? -1 : it->second;
}

int64_t LineageStore::tombstone_count() const {
	std::lock_guard<std::mutex> lock(mutex);
	return (int64_t)tombstones.size();
}

int64_t LineageStore::claim_count() const {
	std::lock_guard<std::mutex> lock(mutex);
	return (int64_t)frozen_claims.size();
}

// ---- export and import ----------------------------------------------------------------------------------------------

// Little-endian, and not a stable format: a 32-bit count, the records (RECORD_BYTES each: id, parent, born, died, divisions, mutations,
// the four genes, hue, sat, val, harm, mutator, the reserve it could hold, the reach word with the F factor in bit 31, mass, energy,
// birth mass), a 32-bit count of names and each (id, byte length, UTF-8). A living record has died -1. Records are in ascending id order.
PackedByteArray LineageStore::write_records(const std::vector<int64_t> &ids) const {
	int64_t names = 0, name_bytes = 0;
	for (int64_t id : ids) {
		const Record &r = records.at(id);
		if (!r.name.is_empty()) {
			names++;
			name_bytes += r.name.utf8().length();
		}
	}
	PackedByteArray out;
	out.resize(4 + (int64_t)ids.size() * RECORD_BYTES + 4 + names * 12 + name_bytes);
	uint8_t *at = out.ptrw();
	put<uint32_t>(at, (uint32_t)ids.size());
	for (int64_t id : ids) {
		const Record &r = records.at(id);
		put<int64_t>(at, id);
		put<int64_t>(at, r.parent);
		put<int32_t>(at, r.born);
		put<int32_t>(at, r.alive ? -1 : r.died);
		put<int32_t>(at, r.divisions);
		put<int32_t>(at, r.g.mutations);
		for (int g = 0; g < GENES; g++) {
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
	for (int64_t id : ids) {
		const Record &r = records.at(id);
		if (r.name.is_empty()) {
			continue;
		}
		CharString utf8 = r.name.utf8();
		put<int64_t>(at, id);
		put<uint32_t>(at, (uint32_t)utf8.length());
		memcpy(at, utf8.get_data(), utf8.length());
		at += utf8.length();
	}
	return out;
}

PackedByteArray LineageStore::export_bytes() const {
	std::lock_guard<std::mutex> lock(mutex);
	std::vector<int64_t> ids;
	ids.reserve(records.size());
	for (const auto &entry : records) {
		ids.push_back(entry.first);
	}
	std::sort(ids.begin(), ids.end());
	return write_records(ids);
}

Dictionary LineageStore::export_dish(int number, const PackedInt64Array &live) const {
	std::lock_guard<std::mutex> lock(mutex);
	std::unordered_set<int64_t> wanted;
	auto climb = [&](int64_t id) { // (the record and every ancestor of it the store has)
		while (id > 0) {
			auto it = records.find(id);
			if (it == records.end() || !wanted.insert(id).second) {
				return;
			}
			id = it->second.parent;
		}
	};
	for (int64_t i = 0; i < live.size(); i++) {
		climb(live[i]);
	}
	for (const auto &entry : pins) {
		if (entry.second.count(number) > 0) {
			climb(entry.first);
		}
	}
	std::vector<int64_t> ids(wanted.begin(), wanted.end());
	std::sort(ids.begin(), ids.end());
	PackedInt64Array listed;
	listed.resize((int64_t)ids.size());
	if (!ids.empty()) {
		memcpy(listed.ptrw(), ids.data(), ids.size() * sizeof(int64_t));
	}
	Dictionary out;
	out["bytes"] = write_records(ids);
	out["ids"] = listed;
	return out;
}

// The pins the dish holds go (their records' `holds` with them); `touched` is the ids they were on.
void LineageStore::drop_pins_of(int holder, std::vector<int64_t> &touched) {
	for (auto p = pins.begin(); p != pins.end();) {
		auto h = p->second.find(holder);
		if (h != p->second.end()) {
			auto it = records.find(p->first);
			if (it != records.end()) {
				it->second.holds = std::max(it->second.holds - h->second, 0);
			}
			touched.push_back(p->first);
			p->second.erase(h);
		}
		p = p->second.empty() ? pins.erase(p) : std::next(p);
	}
}

void LineageStore::release_dish(int number, const PackedInt64Array &live, int minutes, const PackedInt64Array &claimed_ids) {
	std::lock_guard<std::mutex> lock(mutex);
	std::vector<int64_t> touched;
	drop_pins_of(number, touched);
	for (int64_t i = 0; i < live.size(); i++) {
		auto it = records.find(live[i]);
		if (it != records.end() && it->second.alive) {
			it->second.alive = false;
			it->second.died = minutes;
		}
		touched.push_back(live[i]);
	}
	for (int64_t id : touched) { // (before the dish's own claims are added: a record another frozen dish claims is tombstoned, this one's not)
		free_if_unused(id);
	}
	for (int64_t i = 0; i < claimed_ids.size(); i++) {
		frozen_claims[claimed_ids[i]].insert(number);
	}
}

void LineageStore::release_claims_of(int number) {
	for (auto c = frozen_claims.begin(); c != frozen_claims.end();) {
		c->second.erase(number);
		if (c->second.empty()) {
			tombstones.erase(c->first);
			c = frozen_claims.erase(c);
		} else {
			++c;
		}
	}
	for (auto t = tombstones.begin(); t != tombstones.end();) { // (a tombstone with no claim at all: its dish's claim was never registered or is gone)
		t = frozen_claims.count(t->first) == 0 ? tombstones.erase(t) : std::next(t);
	}
}

void LineageStore::discard_frozen(int number) {
	std::lock_guard<std::mutex> lock(mutex);
	release_claims_of(number);
}

void LineageStore::import_bytes(const PackedByteArray &data, const PackedInt64Array &watched, const PackedInt64Array &live, int number) {
	ERR_FAIL_COND_MSG(data.size() < 8, "LineageStore.import_bytes: too short");
	std::lock_guard<std::mutex> lock(mutex);
	const uint8_t *begin = data.ptr();
	const uint8_t *end = begin + data.size();
	const uint8_t *at = begin;
	uint32_t count = take<uint32_t>(at);
	ERR_FAIL_COND_MSG((int64_t)count * RECORD_BYTES + 8 > data.size(), "LineageStore.import_bytes: fewer records than it says");
	std::unordered_set<int64_t> living;
	for (int64_t i = 0; i < live.size(); i++) {
		living.insert(live[i]);
	}
	std::vector<int64_t> inserted; // (1) only the ids the store does not have
	std::unordered_map<int64_t, int> blob_died; // what the blob says of an inserted id's death, -1 if alive there
	records.reserve(records.size() + count);
	for (uint32_t i = 0; i < count; i++) {
		int64_t id = take<int64_t>(at);
		Record r;
		r.parent = take<int64_t>(at);
		r.born = take<int32_t>(at);
		int died = take<int32_t>(at);
		r.divisions = take<int32_t>(at);
		r.g.mutations = take<int32_t>(at);
		for (int g = 0; g < GENES; g++) {
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
		if (id <= 0 || records.count(id) > 0) {
			continue;
		}
		r.alive = false;
		r.died = died;
		r.home = birth_dish(id);
		records[id] = r;
		inserted.push_back(id);
		blob_died[id] = died;
	}
	uint32_t names = at + 4 <= end ? take<uint32_t>(at) : 0;
	for (uint32_t i = 0; i < names; i++) {
		ERR_FAIL_COND_MSG(end - at < 12, "LineageStore.import_bytes: names cut short");
		int64_t id = take<int64_t>(at);
		uint32_t length = take<uint32_t>(at);
		ERR_FAIL_COND_MSG((int64_t)(end - at) < (int64_t)length, "LineageStore.import_bytes: a name is cut short");
		if (blob_died.count(id) > 0) { // (a record the store had keeps its own name)
			records[id].name = String::utf8((const char *)at, (int)length);
		}
		at += length;
	}
	for (int64_t id : inserted) { // (2) an inserted record holds its parent
		Record &r = records[id];
		auto p = records.find(r.parent);
		if (p == records.end()) {
			r.parent = 0;
		} else {
			p->second.holds++;
		}
	}
	for (int64_t id : live) { // (3) the thawed segment's bups live again
		auto it = records.find(id);
		if (it != records.end()) {
			it->second.alive = true;
			it->second.died = -1;
			it->second.home = number;
		}
	}
	for (int64_t id : inserted) { // (4) the death time of one that is not alive here: its tombstone, else the blob's, else now
		Record &r = records[id];
		if (r.alive) {
			continue;
		}
		auto t = tombstones.find(id);
		if (t != tombstones.end()) {
			r.died = t->second;
		} else if (blob_died[id] < 0) {
			r.died = now_minutes();
		}
	}
	for (int64_t i = 0; i < watched.size(); i++) { // (5) before the pruning below, so a dead bup that is being watched survives it
		auto it = records.find(watched[i]);
		if (it == records.end()) {
			continue;
		}
		auto &held = pins[watched[i]];
		if (held.count(number) == 0) {
			held[number] = 1;
			it->second.holds++;
		}
	}
	for (int64_t id : inserted) { // (6) only what it inserted and nothing holds
		free_if_unused(id);
	}
	release_claims_of(number); // (7)
}
