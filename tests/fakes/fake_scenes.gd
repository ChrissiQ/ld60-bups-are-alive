class_name FakeScenes
extends RefCounted
## Canned worlds for the fake: bup records built from `GpuLayout` words, dish states with the real stats keys, and whole snapshots.

## One bup's record (GpuLayout.RECORD_BYTES) with the named words set; `words` maps a GpuLayout R_* index to a float
## (the id and the high id word go through `id`).
static func record(id: int, words: Dictionary = {}) -> PackedByteArray:
	var rec := PackedByteArray()
	rec.resize(GpuLayout.RECORD_BYTES)
	GpuLayout.set_id(rec, 0, id)
	for w: int in words:
		rec.encode_float(w * 4, words[w])
	return rec


## `n` records with ids from `first_id`, spread on a line, with plausible genes.
static func records(n: int, first_id := 1) -> PackedByteArray:
	var out := PackedByteArray()
	for i in n:
		out.append_array(record(first_id + i, {
			GpuLayout.R_X: float(i), GpuLayout.R_Y: 0.0, GpuLayout.R_DX: 1.0,
			GpuLayout.R_SPEED: 10.0, GpuLayout.R_SENSE: 1.0, GpuLayout.R_METABOLISM: 1.0, GpuLayout.R_SIZE: 1.0,
			GpuLayout.R_ENERGY: 5.0, GpuLayout.R_MASS: 1.0, GpuLayout.R_BIRTH_MASS: 1.0, GpuLayout.R_MUTATOR: 1.0,
		}))
	return out


## A `DishState.STATS_KEYS` dictionary: every key, each mean `mean` except the count.
static func stats(count: int, mean := 1.0) -> Dictionary:
	var s := {}
	for k in DishState.STATS_KEYS:
		s[k] = mean
	s["count"] = count
	return s


static func dish_state(number: int, count: int, mean := 1.0) -> DishState:
	var d := DishState.new()
	d.number = number
	d.count = count
	d.stats = stats(count, mean)
	return d


## A snapshot of dishes in rows 0..n-1, numbered 1..n, each of `bups_per_dish` bups; the main-view row (0) has its first
## `tracked` bups' records as answers (ANSWER_BYTES each) and a payload.
static func snapshot(dish_count: int, bups_per_dish: int, tracked := 2) -> Snapshot:
	var snap := Snapshot.new()
	snap.seq = 1
	snap.sim_time = 60.0
	snap.achieved_speed = 1.0
	for row in dish_count:
		snap.dishes[row] = dish_state(row + 1, bups_per_dish)
		snap.history[row] = [{"time": 0.0, "stats": stats(bups_per_dish)}]
	var recs := records(tracked)
	var by_id := {}
	for i in tracked:
		by_id[i + 1] = recs.slice(i * GpuLayout.RECORD_BYTES, i * GpuLayout.RECORD_BYTES + GpuLayout.ANSWER_BYTES)
	if dish_count > 0:
		snap.answers[0] = {"tracked": by_id, "probes": [], "steer": {}}
	snap.payload = PayloadInfo.new()
	snap.payload.texture_index = 0
	snap.payload.count = bups_per_dish
	snap.payload.row = 0
	snap.field_view = FieldViewInfo.new()
	snap.field_view.texture_index = 0
	snap.field_view.n = 100
	snap.timing = {"iteration_ms": 25.0, "steps": 1, "step_ms_ema": 0.6, "duty": 0.5, "sync_ms": 0.1, "publish_ms": 0.1, "lineage_ms": 0.0}
	return snap
