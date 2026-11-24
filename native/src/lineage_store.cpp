#include "lineage_store.h"

#include <godot_cpp/core/error_macros.hpp>

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstring>
#include <thread>

using namespace godot;

// ---- the words of the GPU's events, and the export's fields --------------------------------------------------------

namespace {
constexpr int BIRTH_WORDS = 16, DEATH_WORDS = 14;
constexpr uint32_t STEP_MASK = 0x1FFF; // a birth's or a death's step word: the step's place in the batch in the low 13 bits, the dish number above
constexpr int DISH_SHIFT = 13, DISH_MASK = 0x7FFFF;
// An imported record that was alive where it was exported from has this `died` while an import runs, until the import knows whether it
// lives here (never seen outside: a living record reads died -1).
constexpr int ALIVE_IN_BLOB = INT_MIN;
// The longest a slice boundary waits for the threads that were blocked on the store to take it.
constexpr std::chrono::microseconds HANDOFF_WAIT{ 2000 };

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
int step_of(uint32_t word) { // a step word (a birth's or a death's): the step's place in the batch
	return (int)(word & STEP_MASK);
}
int dish_of(uint32_t word) { // and the number of the dish the event happened in
	return (int)((word >> DISH_SHIFT) & DISH_MASK);
}

// One record of an export (see export_bytes).
void put_record(uint8_t *&at, int64_t id, const LineageStore::Record &r) {
	put<int64_t>(at, id);
	put<int64_t>(at, r.parent);
	put<int32_t>(at, r.born);
	put<int32_t>(at, r.alive ? -1 : r.died);
	put<int32_t>(at, r.divisions);
	put<int32_t>(at, r.g.mutations);
	for (int g = 0; g < LineageStore::GENES; g++) {
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

// And one read back: its id and its record, with `died` as the export wrote it.
int64_t take_record(const uint8_t *&at, LineageStore::Record &r) {
	int64_t id = take<int64_t>(at);
	r.parent = take<int64_t>(at);
	r.born = take<int32_t>(at);
	r.died = take<int32_t>(at);
	r.divisions = take<int32_t>(at);
	r.g.mutations = take<int32_t>(at);
	for (int g = 0; g < LineageStore::GENES; g++) {
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
	return id;
}

// A set of ids (each above 0) in one array, open addressing: an export's set of the records it climbed to, which may hold millions. One
// allocation, so that letting it go does not make the allocator free millions of entries one by one.
class IdSet {
	std::vector<int64_t> slots; // 0: empty
	size_t count = 0;
	size_t mask = 0;

	size_t place(int64_t id) const { return (size_t)(((uint64_t)id * 0x9E3779B97F4A7C15ull) >> 20) & mask; }

public:
	explicit IdSet(size_t expected) {
		size_t capacity = 16;
		while (capacity < expected * 2) {
			capacity <<= 1;
		}
		slots.assign(capacity, 0);
		mask = capacity - 1;
	}
	bool full() const { return (count + 1) * 2 > slots.size(); } // (kept at most half full)
	// False if it was there already.
	bool insert(int64_t id) {
		for (size_t at = place(id);; at = (at + 1) & mask) {
			if (slots[at] == id) {
				return false;
			}
			if (slots[at] == 0) {
				slots[at] = id;
				count++;
				return true;
			}
		}
	}
	void drop() { std::vector<int64_t>().swap(slots); }
	void grow() {
		std::vector<int64_t> old;
		old.swap(slots);
		slots.assign(old.size() * 2, 0);
		mask = slots.size() - 1;
		count = 0;
		for (int64_t id : old) {
			if (id != 0) {
				insert(id);
			}
		}
	}
};

std::vector<int64_t> sorted_unique(const PackedInt64Array &ids) {
	std::vector<int64_t> out(ids.ptr(), ids.ptr() + ids.size());
	if (!std::is_sorted(out.begin(), out.end())) {
		std::sort(out.begin(), out.end());
	}
	out.erase(std::unique(out.begin(), out.end()), out.end());
	return out;
}
} // namespace

// ---- the store's mutex ------------------------------------------------------------------------------------------------

// The store's mutex, held from construction to destruction. A long operation calls `boundary` between two units of its work: once the
// slice has held the mutex for SLICE, it is given up until the threads that were waiting for it have taken it (or HANDOFF_WAIT has
// passed), then taken again for the next slice. A thread counts itself in `waiting` while it blocks, so the boundary knows to wait.
// The entries a long operation takes out of the maps are kept in `freed_records` and `freed_ids` and given back to the allocator while the mutex is not held
// (a free can take milliseconds when the allocator returns memory to the system).
class LineageStore::Lock {
	const LineageStore &store;
	std::chrono::steady_clock::time_point since;
	int units = 0;

	void take() {
		store.waiting.fetch_add(1);
		store.mutex.lock();
		store.waiting.fetch_sub(1);
		since = std::chrono::steady_clock::now();
	}
	void give() {
		store.mutex.unlock();
		freed_records.clear();
		freed_ids.clear();
	}

public:
	std::vector<std::unordered_map<int64_t, Record>::node_type> freed_records;
	std::vector<std::unordered_map<int64_t, int>::node_type> freed_ids; // (claims and tombstones)

	explicit Lock(const LineageStore &s) :
			store(s) { take(); }
	~Lock() { give(); }
	Lock(const Lock &) = delete;
	Lock &operator=(const Lock &) = delete;

	// True if it gave the mutex up (and so another thread may have run).
	bool boundary(int weight = 1) { // (`weight`: the units the work since the last call counts for)
		if ((units += weight) < UNITS_PER_LOOK) {
			return false;
		}
		units = 0;
		const auto now = std::chrono::steady_clock::now();
		if (now - since < SLICE) {
			return false;
		}
		give();
		const auto until = now + HANDOFF_WAIT;
		while (store.waiting.load() > 0 && std::chrono::steady_clock::now() < until) {
			std::this_thread::yield();
		}
		take();
		return true;
	}
	// Gives the mutex up for work on the operation's own data, and takes it again.
	template <typename Work>
	void outside(Work work) {
		give();
		work();
		take();
	}
};

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
	Lock lock(*this);
	reserve_per_mass = reserve_per_mass_value;
	add_mass_factor = add_mass_factor_value;
}

void LineageStore::set_time(double seconds) {
	Lock lock(*this);
	now_seconds = seconds;
}

// ---- the records ------------------------------------------------------------------------------------------------

void LineageStore::make_record(int64_t id, int64_t parent, const Record &fields, int dish) {
	Record r = fields;
	if (Record *p = records.find(parent)) {
		r.parent = parent;
		p->holds++;
	}
	r.born = now_minutes();
	r.home = dish;
	records[id] = r;
}

// The bup has died (in dish `dish`): its record stays only if something living (or being looked at) still needs it.
void LineageStore::record_death(int64_t id, const Record &f, int dish) {
	RecordMap &m = records.map_of(id);
	auto it = m.find(id);
	if (it == m.end()) {
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
	free_found(m, it, nullptr);
}

// Frees a dead record nothing holds (`it` in its shard `m`, or the shard's end), and then the parents that leaves with nothing holding
// them. A record a frozen dish claims leaves its death time in the tombstones. With `slices`, a long operation's lock, a slice boundary
// may come after each record freed (the parent is looked up again after one), and the freed records go to the lock's `freed_records`.
void LineageStore::free_found(RecordMap &m, RecordMap::iterator it, Lock *slices) {
	RecordMap *map = &m;
	while (it != map->end() && !it->second.alive && it->second.holds <= 0) {
		const int64_t id = it->first;
		if (claim_counts.contains(id)) {
			tombstones[id] = it->second.died;
		}
		const int64_t parent = it->second.parent;
		if (slices != nullptr) {
			slices->freed_records.push_back(map->extract(it));
		} else {
			map->erase(it);
		}
		if (parent <= 0) {
			return;
		}
		map = &records.map_of(parent);
		it = map->find(parent);
		if (it == map->end()) {
			return;
		}
		it->second.holds--;
		if (slices != nullptr && slices->boundary()) {
			it = map->find(parent);
		}
	}
}

void LineageStore::free_if_unused(int64_t id) {
	RecordMap &m = records.map_of(id);
	free_found(m, m.find(id), nullptr);
}

// Room for `count` records: if the map has not, a map of `buckets` buckets is made outside the mutex and the records are moved into it,
// in slices.
void LineageStore::make_room(size_t count, size_t buckets, Lock &lock) {
	if (records.fits(count)) {
		return;
	}
	RecordMap bigger;
	lock.outside([&] { bigger.rehash(buckets); });
	records.begin_growth(bigger);
	while (records.move_one()) {
		lock.boundary();
	}
	RecordMap emptied;
	records.end_growth(emptied);
	lock.outside([&] { RecordMap().swap(emptied); });
}

void LineageStore::apply_events(const PackedByteArray &births, const PackedByteArray &deaths, double first_step_end_seconds, double step_seconds) {
	ERR_FAIL_COND_MSG(births.size() % (BIRTH_WORDS * 4) != 0, "LineageStore.apply_events: births are 64 bytes each");
	ERR_FAIL_COND_MSG(deaths.size() % (DEATH_WORDS * 4) != 0, "LineageStore.apply_events: deaths are 56 bytes each");
	Lock lock(*this);
	const int64_t born_count = births.size() / (BIRTH_WORDS * 4), died_count = deaths.size() / (DEATH_WORDS * 4);
	if (born_count > 0) { // (the births' room first, in slices, and twice the buckets, as the map would grow itself)
		const size_t need = (size_t)records.size() + (size_t)born_count;
		make_room(need, std::max(2 * records.main.bucket_count() + 1, (size_t)std::ceil((float)need / records.main.max_load_factor())), lock);
	}
	const uint8_t *bp = births.ptr(), *dp = deaths.ptr();
	int64_t bi = 0, di = 0;
	while (bi < born_count || di < died_count) {
		uint32_t step = UINT32_MAX;
		if (bi < born_count) {
			step = (uint32_t)step_of(get_u32(bp + bi * BIRTH_WORDS * 4, 4));
		}
		if (di < died_count) {
			step = std::min(step, get_u32(dp + di * DEATH_WORDS * 4, 2) & STEP_MASK);
		}
		now_seconds = first_step_end_seconds + step * step_seconds;
		for (; bi < born_count && (uint32_t)step_of(get_u32(bp + bi * BIRTH_WORDS * 4, 4)) == step; bi++) {
			const uint8_t *e = bp + bi * BIRTH_WORDS * 4;
			int64_t id = get_id(e, 0, 1);
			if (records.contains(id)) {
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
			make_record(id, get_id(e, 2, 3), f, dish_of(get_u32(e, 4)));
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
	Lock lock(*this);
	const Record *r = records.find(id);
	return r == nullptr ? Dictionary() : record_info(id, *r);
}

PackedInt64Array LineageStore::chain(int64_t id) const {
	Lock lock(*this);
	std::vector<int64_t> up;
	while (id > 0) {
		const Record *r = records.find(id);
		if (r == nullptr) {
			break;
		}
		up.push_back(id);
		id = r->parent;
	}
	PackedInt64Array out;
	out.resize((int64_t)up.size());
	for (size_t k = 0; k < up.size(); k++) {
		out.set((int64_t)k, up[up.size() - 1 - k]);
	}
	return out;
}

bool LineageStore::has_record(int64_t id) const {
	Lock lock(*this);
	return records.contains(id);
}

bool LineageStore::pin(int64_t id, int holder) {
	Lock lock(*this);
	Record *r = records.find(id);
	if (r == nullptr) {
		return false;
	}
	r->holds++;
	pins[id][holder]++;
	return true;
}

void LineageStore::unpin(int64_t id, int holder) {
	Lock lock(*this);
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
	Record *r = records.find(id);
	if (r != nullptr && r->holds > 0) {
		r->holds--;
		free_if_unused(id);
	}
}

void LineageStore::set_custom_name(int64_t id, const String &name) {
	Lock lock(*this);
	if (Record *r = records.find(id)) {
		r->name = name;
	}
}

String LineageStore::custom_name(int64_t id) const {
	Lock lock(*this);
	const Record *r = records.find(id);
	return r == nullptr ? String() : r->name;
}

// One pass over the living records, each walked up its family line.
PackedInt32Array LineageStore::living_descendants_of(const PackedInt64Array &ids, int number) const {
	Lock lock(*this);
	std::unordered_map<int64_t, int> place;
	for (int64_t i = 0; i < ids.size(); i++) {
		place[ids[i]] = (int)i;
	}
	PackedInt32Array counts;
	counts.resize(ids.size());
	for (int64_t i = 0; i < ids.size(); i++) {
		counts.set(i, 0);
	}
	for (const RecordMap *part : records.parts()) {
		for (const auto &entry : *part) {
			if (!entry.second.alive || (number >= 0 && entry.second.home != number)) {
				continue;
			}
			int64_t id = entry.first;
			while (id > 0) {
				auto at = place.find(id);
				if (at != place.end()) {
					counts.set(at->second, counts[at->second] + 1);
				}
				const Record *r = records.find(id);
				if (r == nullptr) {
					break;
				}
				id = r->parent;
			}
		}
	}
	return counts;
}

void LineageStore::retarget_ids(const PackedInt64Array &ids, int number) {
	Lock lock(*this);
	for (int64_t i = 0; i < ids.size(); i++) {
		if (Record *r = records.find(ids[i])) {
			r->home = number;
		}
	}
}

int64_t LineageStore::record_count() const {
	Lock lock(*this);
	return records.size();
}

PackedInt64Array LineageStore::alive_ids() const {
	Lock lock(*this);
	std::vector<int64_t> ids;
	for (const RecordMap *part : records.parts()) {
		for (const auto &entry : *part) {
			if (entry.second.alive) {
				ids.push_back(entry.first);
			}
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
	Lock lock(*this);
	const Record *r = records.find(id);
	return r == nullptr ? -1 : r->holds;
}

int LineageStore::tombstone(int64_t id) const {
	Lock lock(*this);
	const int *t = tombstones.find(id);
	return t == nullptr ? -1 : *t;
}

int64_t LineageStore::tombstone_count() const {
	Lock lock(*this);
	return tombstones.size();
}

int64_t LineageStore::claim_count() const {
	Lock lock(*this);
	return claim_counts.size();
}

// ---- export and import ----------------------------------------------------------------------------------------------

// Little-endian, and not a stable format: a 32-bit count, the records (RECORD_BYTES each: id, parent, born, died, divisions, mutations,
// the four genes, hue, sat, val, harm, mutator, the reserve it could hold, the reach word with the F factor in bit 31, mass, energy,
// birth mass), a 32-bit count of names and each (id, byte length, UTF-8). A living record has died -1. Records are in ascending id order.
PackedByteArray LineageStore::write_records(const std::vector<int64_t> &ids) const {
	int64_t names = 0, name_bytes = 0;
	for (int64_t id : ids) {
		const Record &r = *records.find(id);
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
		put_record(at, id, *records.find(id));
	}
	put<uint32_t>(at, (uint32_t)names);
	for (int64_t id : ids) {
		const Record &r = *records.find(id);
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
	Lock lock(*this);
	std::vector<int64_t> ids;
	ids.reserve((size_t)records.size());
	for (const RecordMap *part : records.parts()) {
		for (const auto &entry : *part) {
			ids.push_back(entry.first);
		}
	}
	std::sort(ids.begin(), ids.end());
	return write_records(ids);
}

// In slices. The dish's living bups cannot be freed while it runs (only the thread that runs it makes a bup dead), nor their ancestors,
// and the records its pins hold get a hold of the export's own for its length; so every record it climbs to is still there when it
// writes it, whatever another thread pins or unpins meanwhile, and `ids` lists exactly the records written.
Dictionary LineageStore::export_dish(int number, const PackedInt64Array &live) {
	std::vector<int64_t> pinned;
	IdSet wanted((size_t)live.size() * 2);
	std::vector<int64_t> ids;
	ids.reserve((size_t)live.size() * 2 + 1024);
	std::vector<std::pair<int64_t, CharString>> names;
	PackedByteArray bytes;
	int64_t kept = 0;
	{
		Lock lock(*this);
		for (const auto &entry : pins) { // (the pins are a few per dish: one slice)
			if (entry.second.count(number) > 0) {
				if (Record *r = records.find(entry.first)) {
					r->holds++;
					pinned.push_back(entry.first);
				}
			}
		}
		auto climb = [&](int64_t id) { // (the record and every ancestor of it the store has)
			while (id > 0) {
				if (wanted.full() || ids.size() == ids.capacity()) { // (growing is work on its own data: outside the mutex)
					lock.outside([&] {
						if (wanted.full()) {
							wanted.grow();
						}
						ids.reserve(ids.size() * 2 + 1024);
					});
				}
				const Record *r = records.find(id);
				if (r == nullptr || !wanted.insert(id)) {
					return;
				}
				ids.push_back(id);
				id = r->parent;
				lock.boundary();
			}
		};
		for (int64_t i = 0; i < live.size(); i++) {
			climb(live[i]);
			lock.boundary();
		}
		for (int64_t id : pinned) {
			climb(id);
		}
		lock.outside([&] {
			wanted.drop();
			std::sort(ids.begin(), ids.end());
			bytes.resize(4 + (int64_t)ids.size() * RECORD_BYTES + 4);
		});
		uint8_t *at = bytes.ptrw() + 4;
		for (int64_t id : ids) {
			const Record *r = records.find(id);
			if (r != nullptr) { // (always: see above)
				put_record(at, id, *r);
				if (!r->name.is_empty()) {
					names.emplace_back(id, r->name.utf8());
				}
				ids[kept++] = id;
			}
			lock.boundary();
		}
		for (int64_t id : pinned) { // the export's own holds go: what an unpin meanwhile left unheld is freed now
			RecordMap &m = records.map_of(id);
			auto it = m.find(id);
			if (it != m.end()) {
				it->second.holds--;
				free_found(m, it, &lock);
			}
		}
	}
	ids.resize((size_t)kept);
	int64_t name_bytes = 0;
	for (const auto &name : names) {
		name_bytes += 12 + name.second.length();
	}
	bytes.resize(4 + kept * RECORD_BYTES + 4 + name_bytes);
	uint8_t *at = bytes.ptrw();
	put<uint32_t>(at, (uint32_t)kept);
	at += kept * RECORD_BYTES;
	put<uint32_t>(at, (uint32_t)names.size());
	for (const auto &name : names) {
		put<int64_t>(at, name.first);
		put<uint32_t>(at, (uint32_t)name.second.length());
		memcpy(at, name.second.get_data(), name.second.length());
		at += name.second.length();
	}
	PackedInt64Array listed;
	listed.resize(kept);
	if (kept > 0) {
		memcpy(listed.ptrw(), ids.data(), (size_t)kept * sizeof(int64_t));
	}
	Dictionary out;
	out["bytes"] = bytes;
	out["ids"] = listed;
	return out;
}

// The pins the dish holds go (their records' `holds` with them); `touched` is the ids they were on.
void LineageStore::drop_pins_of(int holder, std::vector<int64_t> &touched) {
	for (auto p = pins.begin(); p != pins.end();) {
		auto h = p->second.find(holder);
		if (h != p->second.end()) {
			if (Record *r = records.find(p->first)) {
				r->holds = std::max(r->holds - h->second, 0);
			}
			touched.push_back(p->first);
			p->second.erase(h);
		}
		p = p->second.empty() ? pins.erase(p) : std::next(p);
	}
}

// `ids` (sorted, each once) become claims of the frozen dish `number`, counted in slices; the dish's list is in place once all are counted.
void LineageStore::add_claims(int number, std::vector<int64_t> ids, Lock &lock) {
	std::vector<int64_t> had;
	auto d = dish_claims.find(number);
	if (d != dish_claims.end()) {
		had = std::move(d->second);
		dish_claims.erase(d);
	}
	std::vector<int64_t> added;
	if (!had.empty()) { // (a dish that claims already: only the ids it did not claim are counted again)
		lock.outside([&] {
			std::set_difference(ids.begin(), ids.end(), had.begin(), had.end(), std::back_inserter(added));
			std::vector<int64_t> merged;
			std::set_union(ids.begin(), ids.end(), had.begin(), had.end(), std::back_inserter(merged));
			ids.swap(merged);
		});
	}
	for (int64_t id : had.empty() ? ids : added) {
		claim_counts[id]++;
		lock.boundary();
	}
	if (!ids.empty()) {
		dish_claims[number] = std::move(ids);
	}
}

// In slices: each unit marks one living bup not alive and frees what that leaves unheld.
void LineageStore::release_dish(int number, const PackedInt64Array &live, int minutes, const PackedInt64Array &claimed_ids) {
	std::vector<int64_t> claims = sorted_unique(claimed_ids);
	Lock lock(*this);
	std::vector<int64_t> touched;
	drop_pins_of(number, touched);
	for (int64_t i = 0; i < live.size(); i++) {
		const int64_t id = live[i];
		RecordMap &m = records.map_of(id);
		auto it = m.find(id);
		if (it != m.end() && it->second.alive) {
			it->second.alive = false;
			it->second.died = minutes;
		}
		free_found(m, it, &lock);
		lock.boundary();
	}
	for (int64_t id : touched) {
		RecordMap &m = records.map_of(id);
		free_found(m, m.find(id), &lock);
	}
	// (after the freeing: a record another frozen dish claims is tombstoned, this one's not)
	add_claims(number, std::move(claims), lock);
}

// In slices: one walk of the dish's own claims. A tombstone always has a claim (one is written only for a claimed id, and goes with the
// id's last claim), so no tombstone is left without one.
void LineageStore::release_claims_of(int number, Lock &lock) {
	std::vector<int64_t> ids;
	auto d = dish_claims.find(number);
	if (d == dish_claims.end()) {
		return;
	}
	ids = std::move(d->second);
	dish_claims.erase(d);
	for (int64_t id : ids) {
		auto &m = claim_counts.map_of(id);
		auto c = m.find(id);
		if (c != m.end() && --c->second <= 0) {
			lock.freed_ids.push_back(m.extract(c));
			auto &t = tombstones.map_of(id);
			auto stone = t.find(id);
			if (stone != t.end()) {
				lock.freed_ids.push_back(t.extract(stone));
			}
		}
		lock.boundary();
	}
}

void LineageStore::discard_frozen(int number) {
	Lock lock(*this);
	release_claims_of(number, lock);
}

// In slices. Each record of the export carries a hold of the import's own until its last steps, the ones it inserts and the ones the
// store had, so no unpin meanwhile can free one before the records that name it as their parent are linked to it. A record alive in the
// export is alive from its insertion, as nearly all of them stay.
void LineageStore::import_bytes(const PackedByteArray &data, const PackedInt64Array &watched, const PackedInt64Array &live, int number) {
	ERR_FAIL_COND_MSG(data.size() < 8, "LineageStore.import_bytes: too short");
	const uint8_t *begin = data.ptr();
	const uint8_t *end = begin + data.size();
	const uint8_t *at = begin;
	const uint32_t count = take<uint32_t>(at);
	ERR_FAIL_COND_MSG((int64_t)count * RECORD_BYTES + 8 > data.size(), "LineageStore.import_bytes: fewer records than it says");
	const uint8_t *names_at = begin + 4 + (int64_t)count * RECORD_BYTES;
	uint32_t names = 0;
	{ // (the names are checked before anything changes)
		const uint8_t *n = names_at;
		names = n + 4 <= end ? take<uint32_t>(n) : 0;
		for (uint32_t i = 0; i < names; i++) {
			ERR_FAIL_COND_MSG(end - n < 12, "LineageStore.import_bytes: names cut short");
			n += 8;
			const uint32_t length = take<uint32_t>(n);
			ERR_FAIL_COND_MSG((int64_t)(end - n) < (int64_t)length, "LineageStore.import_bytes: a name is cut short");
			n += length;
		}
	}
	std::vector<int64_t> inserted; // only the ids the store does not have, in the export's order
	std::vector<int64_t> kept; // the ids of the export the store has: each also has a hold of the import's own until its last step
	std::vector<std::pair<int64_t, int64_t>> unlinked; // an inserted id whose parent was not in the store when it was inserted, and that parent
	inserted.reserve(count);
	Lock lock(*this);
	const int now = now_minutes();
	const size_t need = (size_t)records.size() + count;
	make_room(need, (size_t)std::ceil((float)need / records.main.max_load_factor()), lock); // (as a map's reserve(need) sizes it)
	for (uint32_t i = 0; i < count; i++) { // (1) the records it lacks, each holding its parent if the store has it
		Record r;
		const int64_t id = take_record(at, r);
		if (id <= 0) {
			lock.boundary();
			continue;
		}
		if (Record *had = records.find(id)) {
			had->holds++;
			kept.push_back(id);
		} else {
			r.alive = r.died < 0;
			r.died = r.alive ? ALIVE_IN_BLOB : r.died;
			r.home = number;
			r.holds = 1;
			if (Record *p = records.find(r.parent)) {
				p->holds++;
			} else {
				if (r.parent > 0) {
					unlinked.emplace_back(id, r.parent);
				}
				r.parent = 0;
			}
			records[id] = std::move(r);
			inserted.push_back(id);
		}
		lock.boundary();
	}
	for (const auto &link : unlinked) { // (2) a record inserted ahead of its parent holds it now
		Record *p = records.find(link.second);
		Record *r = records.find(link.first);
		if (p != nullptr && r != nullptr) {
			r->parent = link.second;
			p->holds++;
		}
		lock.boundary();
	}
	if (names > 0) { // (a record the store had keeps its own name)
		std::vector<int64_t> sorted;
		lock.outside([&] {
			sorted = inserted;
			if (!std::is_sorted(sorted.begin(), sorted.end())) {
				std::sort(sorted.begin(), sorted.end());
			}
		});
		const uint8_t *n = names_at + 4;
		for (uint32_t i = 0; i < names; i++) {
			const int64_t id = take<int64_t>(n);
			const uint32_t length = take<uint32_t>(n);
			if (std::binary_search(sorted.begin(), sorted.end(), id)) {
				if (Record *r = records.find(id)) {
					r->name = String::utf8((const char *)n, (int)length);
				}
			}
			n += length;
			lock.boundary();
		}
	}
	for (int64_t i = 0; i < live.size(); i++) { // (3) the thawed segment's bups live again
		if (Record *r = records.find(live[i])) {
			r->alive = true;
			r->died = -1;
			r->home = number;
		}
		lock.boundary();
	}
	for (int64_t i = 0; i < watched.size(); i++) { // (4) before the pruning below, so a dead bup that is being watched survives it
		Record *r = records.find(watched[i]);
		if (r == nullptr) {
			continue;
		}
		auto &held = pins[watched[i]];
		if (held.count(number) == 0) {
			held[number] = 1;
			r->holds++;
		}
	}
	for (int64_t id : inserted) { // (5) the death time of one that is not alive here (its tombstone, else the export's, else now); then
		// the import's hold goes and what nothing holds is freed
		RecordMap &m = records.map_of(id);
		auto it = m.find(id);
		if (it == m.end()) {
			continue;
		}
		Record &r = it->second;
		if (r.died == ALIVE_IN_BLOB || !r.alive) {
			const int *t = tombstones.find(id);
			r.died = t != nullptr ? *t : (r.died == ALIVE_IN_BLOB ? now : r.died);
			r.alive = false;
		}
		r.holds--;
		free_found(m, it, &lock);
		lock.boundary();
	}
	for (int64_t id : kept) { // (6) and the import's holds on the records the store had go (what an unpin meanwhile left unheld is freed)
		RecordMap &m = records.map_of(id);
		auto it = m.find(id);
		if (it != m.end()) {
			it->second.holds--;
			free_found(m, it, &lock);
		}
		lock.boundary();
	}
	release_claims_of(number, lock); // (7)
}
