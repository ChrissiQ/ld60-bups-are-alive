#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <unordered_map>
#include <vector>

// The family tree of every running dish: who each bup came from, kept while a living bup or a pin holds it. One store for every dish
// (ids are unique across dishes), written from the births and deaths a batch of GPU steps made and read by the game. Times are whole
// minutes of simulation time.
//
// Every method holds the store's one mutex while it works, so one thread can apply events while another reads. The long ones (export_dish,
// release_dish, import_bytes, discard_frozen, and apply_events while it makes the records' map bigger) work in slices: each holds the
// mutex for at most about SLICE, then lets in any thread that waits on the store, and takes it again. A thread that asks the store
// anything therefore waits about a slice at most, however big the dish. The other methods are short and hold it once (apply_events is
// given a bounded batch: see LineageWorker.APPLY_PART).
//
// At every slice boundary (between two slices of a long operation, where another thread may run any method):
//  - every record's `holds` is the number of records that name it as their parent plus its pins, and an operation's own temporary holds
//    (an export's on the records the dish pins, an import's on each record its export lists, each dropped before the operation returns);
//  - every record's parent is 0 or a record of the store (a record an import inserted ahead of its parent has parent 0 until the import
//    links it);
//  - a dead record with no holds is freed, except the one a freeing cut short by the boundary resumes from (a record the operation itself
//    left unheld, which it frees or finds held, or gone, when it resumes);
//  - claim_counts[id] is the number of frozen dishes whose claims (dish_claims) list id, apart from the claims of the one dish a release,
//    import or discard is adding or taking away, which are counted for the ids it has done; every tombstone's id has a claim;
//  - an operation keeps ids and indices only: no iterator, pointer or reference into records, pins, claim_counts or tombstones lives across
//    a boundary, and each slice looks its records up again.
// The game calls apply_events, export_dish, release_dish, import_bytes, retarget_ids and discard_frozen on one thread (its lineage worker)
// only, in order, so those never interleave with each other; pin, unpin, set_custom_name and every query may come from another thread at
// any boundary. discard_frozen may come from another thread too, but two operations on the same dish number must never overlap.
class LineageStore : public godot::RefCounted {
	GDCLASS(LineageStore, godot::RefCounted)

public:
	static constexpr int GENES = 4; // speed, sense, metabolism, size
	static constexpr int RECORD_BYTES = 88; // one record of the export: see export_bytes

	// What a bup inherits and its record keeps: the genes (and the raised ceilings and F factor as they were when it died), its colour.
	struct Genome {
		std::array<float, GENES> genes = {};
		float hue = 0, sat = 0, val = 0, harm = 0;
		int mutations = 0;
		float mutator = 1;
		bool donor = false;
		int reach = 0;
	};
	struct Record {
		int64_t parent = 0; // 0: a founder
		int born = 0, died = -1;
		int holds = 0; // records that name this one as their parent, plus pins: while any, a dead record stays
		int divisions = 0;
		Genome g;
		float max_energy = 0; // the reserve it could hold, as it was when it died
		float mass = 0, energy = 0, birth_mass = 0; // what it was when it died
		godot::String name; // what the player called it, if anything
		bool alive = true;
		int home = 0; // the number of the dish it lives in (what the per-dish queries select by; never what an export selects by)
	};

private:
	using RecordMap = std::unordered_map<int64_t, Record>;

	// The records: one hash map, grown in slices (make_room). Growing a map in one go (a rehash) moves every entry and would hold the
	// mutex for as long; instead a bigger map is made outside the mutex and the records are moved into it a few at a time, the rest
	// still found in the old one meanwhile. Outside a growth, a look-up is one map's.
	struct RecordTable {
		RecordMap main;
		RecordMap old; // while it grows: the records not moved yet
		bool growing = false;

		RecordMap &map_of(int64_t id) { return growing && main.count(id) == 0 && old.count(id) > 0 ? old : main; }
		const Record *find(int64_t id) const {
			auto it = main.find(id);
			if (it != main.end()) {
				return &it->second;
			}
			if (growing) {
				it = old.find(id);
				if (it != old.end()) {
					return &it->second;
				}
			}
			return nullptr;
		}
		Record *find(int64_t id) { return const_cast<Record *>(static_cast<const RecordTable *>(this)->find(id)); }
		bool contains(int64_t id) const { return find(id) != nullptr; }
		Record &operator[](int64_t id) { return main[id]; } // (for an id it does not have)
		int64_t size() const { return (int64_t)(main.size() + old.size()); }
		std::array<const RecordMap *, 2> parts() const { return { &main, &old }; }
		// Whether `count` records fit without a rehash.
		bool fits(size_t count) const { return (float)count <= (float)main.bucket_count() * main.max_load_factor(); }
		// `bigger` (empty, with room) becomes the map, the records still to move are in `old`.
		void begin_growth(RecordMap &bigger) {
			old.swap(main);
			main.swap(bigger);
			growing = true;
		}
		// One record moved; false once none is left to move.
		bool move_one() {
			if (old.empty()) {
				return false;
			}
			main.insert(old.extract(old.begin()));
			return true;
		}
		// Growing ends; `emptied` takes the old map's (empty) table, to be let go outside the mutex.
		void end_growth(RecordMap &emptied) {
			emptied.swap(old);
			growing = false;
		}
	};

	// A hash map from id split into SHARDS maps, so that growing one (a rehash, which moves every entry of the map) moves a SHARDS-th of
	// the entries and fits in a slice: the claims and the tombstones. A run of RUN consecutive ids shares a shard (the runs are spread
	// by a mix), so that a frozen dish's claims, sorted and mostly runs of consecutive ids, are added and taken away a table at a time.
	template <typename V>
	struct ShardedMap {
		static constexpr int SHARDS = 256;
		std::array<std::unordered_map<int64_t, V>, SHARDS> shards;

		static constexpr int RUN_BITS = 10; // RUN = 1024
		static int shard_of(int64_t id) { return (int)((((uint64_t)id >> RUN_BITS) * 0x9E3779B97F4A7C15ull) >> 56); }
		std::unordered_map<int64_t, V> &map_of(int64_t id) { return shards[shard_of(id)]; }
		V *find(int64_t id) {
			auto &m = map_of(id);
			auto it = m.find(id);
			return it == m.end() ? nullptr : &it->second;
		}
		const V *find(int64_t id) const {
			const auto &m = shards[shard_of(id)];
			auto it = m.find(id);
			return it == m.end() ? nullptr : &it->second;
		}
		bool contains(int64_t id) const { return find(id) != nullptr; }
		V &operator[](int64_t id) { return map_of(id)[id]; }
		int64_t size() const {
			int64_t n = 0;
			for (const auto &m : shards) {
				n += (int64_t)m.size();
			}
			return n;
		}
	};

	// How long one slice of a long operation holds the mutex, and how many units of work (a record looked at, written, inserted or
	// freed; a claim added or taken away) it does between two looks at the clock.
	static constexpr std::chrono::microseconds SLICE{ 1000 };
	static constexpr int UNITS_PER_LOOK = 64;
	class Lock;

	mutable std::mutex mutex;
	mutable std::atomic<int> waiting{ 0 }; // threads blocked on the mutex: a slice boundary lets them in before it takes the mutex again
	RecordTable records;
	// The pins: for each pinned id, how many pins each holder (a dish number) has on it. Each raises the record's `holds`.
	std::unordered_map<int64_t, std::unordered_map<int, int>> pins;
	// For frozen dishes, ids and times only: the ids each frozen dish's blob lists (sorted), how many frozen dishes list each id, and the
	// death time of an id that was freed while a frozen dish listed it.
	std::unordered_map<int, std::vector<int64_t>> dish_claims;
	ShardedMap<int> claim_counts;
	ShardedMap<int> tombstones;
	double now_seconds = 0.0;
	double reserve_per_mass = 8.0; // what a body can store per unit of mass (the record keeps the reserve it could hold when it died)
	double add_mass_factor = 0.5; // what a bup adds to its birth mass, times its size gene squared, before it divides

	int now_minutes() const { return (int)(now_seconds / 60.0); }
	void make_record(int64_t id, int64_t parent, const Record &fields, int dish);
	void record_death(int64_t id, const Record &fields, int dish);
	void free_found(RecordMap &m, RecordMap::iterator it, Lock *slices);
	void free_if_unused(int64_t id);
	void make_room(size_t count, size_t buckets, Lock &lock);
	void drop_pins_of(int holder, std::vector<int64_t> &touched);
	void add_claims(int number, std::vector<int64_t> ids, Lock &lock);
	void release_claims_of(int number, Lock &lock);
	godot::Dictionary record_info(int64_t id, const Record &r) const;
	godot::PackedByteArray write_records(const std::vector<int64_t> &ids) const;

protected:
	static void _bind_methods();

public:
	// The constants of the model the record's derived figures use (Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR).
	void set_constants(double reserve_per_mass_value, double add_mass_factor_value);
	// The store's clock, in seconds: what an import stamps a record that was alive where it was exported from and is not alive here
	// with, when nothing else says. apply_events moves it to the end of the last step it was given.
	void set_time(double seconds);

	// The births and deaths of a batch of GPU steps (see GpuLayout: a birth is 16 words, a death 14; a death's step word holds the
	// dish number the bup was in above the step's place in the batch). A birth whose id has a record is passed over.
	void apply_events(const godot::PackedByteArray &births, const godot::PackedByteArray &deaths, double first_step_end_seconds, double step_seconds);

	godot::Dictionary info(int64_t id) const; // empty if the record has been freed
	godot::PackedInt64Array chain(int64_t id) const; // the family line: the oldest known ancestor first, the bup itself last
	bool has_record(int64_t id) const;
	bool pin(int64_t id, int holder);
	void unpin(int64_t id, int holder);
	void set_custom_name(int64_t id, const godot::String &name);
	godot::String custom_name(int64_t id) const;
	// For each id, how many living bups have it in their line (itself included); with a dish number, only bups whose home is that dish.
	godot::PackedInt32Array living_descendants_of(const godot::PackedInt64Array &ids, int number = -1) const;
	void retarget_ids(const godot::PackedInt64Array &ids, int number); // sets `home`, nothing else

	// {bytes, ids}: the records of the dish's living bups and of what its pins hold, with every ancestor of each (whichever dish also
	// references them), in the format of export_bytes, and the ids written. The set is what the dish's pins held when the export began.
	godot::Dictionary export_dish(int number, const godot::PackedInt64Array &live);
	// The dish leaves (frozen or trashed): its pins go, its living bups are not alive from `minutes`, and what nothing holds is freed;
	// a freed record another frozen dish claims is tombstoned at its `died` (`minutes` for a bup alive here). A freeze passes the ids
	// its blob lists, which become the dish's claims (after the freeing, so its own records leave no tombstone).
	void release_dish(int number, const godot::PackedInt64Array &live, int minutes, const godot::PackedInt64Array &claimed_ids = godot::PackedInt64Array());
	void discard_frozen(int number); // a frozen dish is trashed: its claims go, and the tombstones nothing claims
	// An idempotent merge of an export: only ids the store lacks are inserted; `live` become alive in dish `number`; `watched` are pinned
	// for the dish where it does not pin them already. A malformed export changes nothing.
	void import_bytes(const godot::PackedByteArray &data, const godot::PackedInt64Array &watched, const godot::PackedInt64Array &live, int number);

	godot::PackedByteArray export_bytes() const; // every record: a 32-bit count, the records (RECORD_BYTES each), then the names
	int64_t record_count() const;
	godot::PackedInt64Array alive_ids() const; // sorted
	int holds(int64_t id) const; // -1 if there is no record
	int tombstone(int64_t id) const; // the death time kept for an id, -1 if none
	int64_t tombstone_count() const;
	int64_t claim_count() const; // ids with a claim
};
