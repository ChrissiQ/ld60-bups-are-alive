#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <array>
#include <cstdint>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// The family tree of every running dish: who each bup came from, kept while a living bup or a pin holds it. One store for every dish
// (ids are unique across dishes), written from the births and deaths a batch of GPU steps made and read by the game. Every method takes
// the store's mutex, so one thread can apply events while another reads. Times are whole minutes of simulation time.
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
	mutable std::mutex mutex;
	std::unordered_map<int64_t, Record> records;
	// The pins: for each pinned id, how many pins each holder (a dish number) has on it. Each raises the record's `holds`.
	std::unordered_map<int64_t, std::unordered_map<int, int>> pins;
	// For frozen dishes, ids and times only: the frozen dishes whose blob lists an id, and the death time of an id that was pruned
	// while a frozen dish listed it.
	std::unordered_map<int64_t, std::unordered_set<int>> frozen_claims;
	std::unordered_map<int64_t, int> tombstones;
	double now_seconds = 0.0;
	double reserve_per_mass = 8.0; // what a body can store per unit of mass (the record keeps the reserve it could hold when it died)
	double add_mass_factor = 0.5; // what a bup adds to its birth mass, times its size gene squared, before it divides

	int now_minutes() const { return (int)(now_seconds / 60.0); }
	void make_record(int64_t id, int64_t parent, const Record &fields);
	void record_death(int64_t id, const Record &fields, int dish);
	void free_if_unused(int64_t id, bool tombstone);
	void drop_pins_of(int holder, std::vector<int64_t> &touched);
	void release_claims_of(int number);
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
	// references them), in the format of export_bytes, and the ids written.
	godot::Dictionary export_dish(int number, const godot::PackedInt64Array &live) const;
	// The dish leaves (frozen or trashed): its pins go, its living bups are not alive from `minutes`, and what nothing holds is freed
	// (not tombstoned). A freeze passes the ids its blob lists, which become the dish's claims.
	void release_dish(int number, const godot::PackedInt64Array &live, int minutes, const godot::PackedInt64Array &claimed_ids = godot::PackedInt64Array());
	void discard_frozen(int number); // a frozen dish is trashed: its claims go, and the tombstones nothing claims
	// An idempotent merge of an export: only ids the store lacks are inserted; `live` become alive in dish `number`; `watched` are pinned
	// for the dish where it does not pin them already.
	void import_bytes(const godot::PackedByteArray &data, const godot::PackedInt64Array &watched, const godot::PackedInt64Array &live, int number);

	godot::PackedByteArray export_bytes() const; // every record: a 32-bit count, the records (RECORD_BYTES each), then the names
	int64_t record_count() const;
	godot::PackedInt64Array alive_ids() const; // sorted
	int holds(int64_t id) const; // -1 if there is no record
	int tombstone(int64_t id) const; // the death time kept for an id, -1 if none
	int64_t tombstone_count() const;
	int64_t claim_count() const; // ids with a claim
};
