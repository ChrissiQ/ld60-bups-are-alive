class_name DishCodec
extends RefCounted
## A dish's save format: what `Dish.to_dict` writes (`write`), and the reading back of it for `Dish.from_dict` (`read_blocks`, `read`),
## which checks everything and builds it on the side, so that a save that is refused can leave the dish exactly as it was.
## Positions are saved relative to the dish centre so a resized window doesn't matter.

const MAX_SAVED_BYTES := 600000000  ## the most a save's block of bups or of family records may be once decompressed (2,000,000 bups are 224 MB)


## The save of `dish` as it is now (the caller has brought its state to the CPU and let go of what the sources kept back). `bloom_due` is
## when the dish's bloom next adds a plankton.
static func write(dish: Dish, bloom_due: float) -> Dictionary:
	var saved_moved_out := []
	for id: int in dish.moved_out:
		saved_moved_out.append([id, dish.moved_out[id]])  # (pairs, not a dictionary: a JSON save would turn its number keys into text)
	var saved_sources := []
	for source in dish.sources:
		saved_sources.append({"pos": _vec_to_array(source.pos - dish.global_position), "rate": source.rate, "emitted": source.emitted})
	var saved_plankton := []
	for cell in dish.plankton:
		saved_plankton.append({"pos": _vec_to_array(cell.pos), "born_at": cell.born_at, "burst_at": cell.burst_at, "units": cell.units, "shape": cell.shape})
	return {
		"next_id": dish.sim.get_next_id(),
		"lineage": pack_bytes(dish.sim.lineage_export_bytes()),
		"radius": dish.radius,
		"nutrient_resolution": dish.field.get_max_across(),
		"medium_thickness": dish.medium_thickness,
		"bup_limit": dish.bup_limit,
		"nutrients_placed": dish.nutrients_placed,
		"time": dish.time,
		"feed_density": dish.feed_density,
		"patch_seed": dish.patch_seed,
		"cells": pack_bytes(dish.sim.export_state_bytes()),  # (every bup as the GPU's record: a dictionary for each of a hundred thousand would take seconds to make and to write)
		"field": Array(dish.field.values()),
		"acetate": Array(dish.acetate.values()),
		"clouds": dish.field.puffs_export(),
		"death_husks": dish.death_husks,
		"plankton_husks": dish.plankton_husks,
		"stationary_phase": dish.stationary_phase,
		"husks": Array(dish.sim.husks_export()),
		"sources": saved_sources,
		"bloom_density": dish.bloom_density,
		"bloom_due": bloom_due,
		"upkeep_factor": dish.upkeep_factor,
		"plankton": saved_plankton,
		"history": dish.history,
		"history_all": dish.history_all,
		"watched": dish.watched,
		"history_all_factor": dish.history_all_factor,
		"history_origin": dish.history_origin,
		"backend": dish.backend.setting,
		"moved_out": saved_moved_out,
	}


## The save's two blocks of bytes, [the bups' records, the family records], or [] if either is missing or unreadable or the bups' block
## is not a whole number of records.
static func read_blocks(d: Dictionary) -> Array:
	var saved_bups: Variant = unpack_bytes(d.get("cells"))
	var saved_family: Variant = unpack_bytes(d.get("lineage"))
	if saved_bups == null or saved_family == null or saved_bups.size() % GpuSim.RECORD_BYTES != 0:
		return []
	return [saved_bups, saved_family]


## Everything else in the save, checked and made ready to put in the dish: an empty dictionary if anything is unusable. `field` is the
## dish's nutrient field (asked the size of the grid the saved one must have; left as it was), `origin` the dish's place in the world
## (the sources are kept in world positions). Out-of-range values are made safe rather than refused.
static func read(d: Dictionary, field: NutrientField, origin: Vector2) -> Dictionary:
	for key in ["radius", "bup_limit", "nutrients_placed", "time", "feed_density", "bloom_density", "nutrient_resolution", "medium_thickness"]:
		if d.has(key) and not Validate.is_number(d[key]):
			return {}
	var loaded_sources: Array[NutrientSource] = []
	var saved_sources = d.get("sources", [])
	if not (saved_sources is Array):
		return {}
	for saved in saved_sources:
		if not (saved is Dictionary) or not Validate.is_vec2(saved.get("pos")) or not Validate.is_number(saved.get("rate")):
			return {}
		var source := NutrientSource.new(origin + _array_to_vec(saved["pos"]), clampf(float(saved["rate"]), Dish.MIN_SOURCE_RATE, Dish.MAX_SOURCE_RATE))
		if Validate.is_number(saved.get("emitted")):
			source.emitted = maxf(float(saved["emitted"]), 0.0)
		loaded_sources.append(source)
	loaded_sources.resize(mini(loaded_sources.size(), Dish.MAX_SOURCES))
	var loaded_plankton: Array[Plankton] = []
	var saved_plankton = d.get("plankton", [])
	if not (saved_plankton is Array):
		return {}
	for saved in saved_plankton:
		if not (saved is Dictionary) or not Validate.is_vec2(saved.get("pos")) or not Validate.is_number(saved.get("burst_at")) or not Validate.is_number(saved.get("units")):
			return {}
		var shape := float(saved["shape"]) if Validate.is_number(saved.get("shape")) else 0.0
		var born := float(saved["born_at"]) if Validate.is_number(saved.get("born_at")) else 0.0
		loaded_plankton.append(Plankton.new(_array_to_vec(saved["pos"]), born, float(saved["burst_at"]), maxf(float(saved["units"]), 0.0), shape))
	loaded_plankton.resize(mini(loaded_plankton.size(), Dish.MAX_PLANKTON))
	var loaded_radius := clampf(float(d.get("radius", Dish.DEFAULT_RADIUS)), StartConditions.MIN_SIM_RADIUS, StartConditions.MAX_DISH_RADIUS)
	var loaded_limit := clampi(int(d.get("bup_limit", StartConditions.DEFAULT_BUP_LIMIT)), 1, StartConditions.MAX_BUP_LIMIT)
	if not Validate.is_number(d.get("nutrient_resolution")) or not Validate.is_number(d.get("medium_thickness")):
		return {}
	var loaded_resolution := clampi(int(d["nutrient_resolution"]), StartConditions.MIN_NUTRIENT_RESOLUTION, StartConditions.MAX_NUTRIENT_RESOLUTION)
	var loaded_thickness := clampf(float(d["medium_thickness"]), StartConditions.MIN_MEDIUM_THICKNESS, StartConditions.MAX_MEDIUM_THICKNESS)
	var resolution_before := field.get_max_across()
	field.set_max_across(loaded_resolution)
	var field_size := field.size_for_radius(loaded_radius)
	field.set_max_across(resolution_before)  # (until everything checks out)
	var saved_field = d.get("field", [])
	if saved_field is Array and not is_equal_approx(loaded_radius, float(d.get("radius", Dish.DEFAULT_RADIUS))):
		saved_field = []  # the radius had to be clamped, so the saved grid no longer fits the dish: start with a clear medium
	if not (saved_field is Array) or (not saved_field.is_empty() and saved_field.size() != field_size * field_size):
		return {}
	if not Validate.all_numbers(saved_field):
		return {}
	var saved_acetate = d.get("acetate", [])
	if saved_field.is_empty():
		saved_acetate = []  # (a clear medium has no acetate either)
	if not (saved_acetate is Array) or (not saved_acetate.is_empty() and saved_acetate.size() != field_size * field_size):
		return {}
	if not Validate.all_numbers(saved_acetate):
		return {}
	var saved_clouds = d.get("clouds")  # the plankton's nutrient not yet given to the grid: five numbers a cloud (NutrientField.puffs_export)
	if not (saved_clouds is Array):
		return {}
	for cloud in saved_clouds:
		if not (cloud is Array) or cloud.size() != 5 or not Validate.all_numbers(cloud):
			return {}
	var saved_history = d.get("history", {})
	if not (saved_history is Dictionary):
		return {}
	var loaded_history := {}
	for key in Dish.HISTORY_SERIES:
		var series = saved_history.get(key)
		if not (series is Array) or not Validate.all_numbers(series):
			return {}
		loaded_history[key] = series.slice(maxi(0, series.size() - Dish.HISTORY_LEN))
	var saved_all = d.get("history_all")
	if not (saved_all is Dictionary) or not Validate.is_number(d.get("history_all_factor")) or float(d["history_all_factor"]) < 1.0:
		return {}
	var loaded_all := {}
	for key in Dish.HISTORY_SERIES:
		var series = saved_all.get(key)
		if not (series is Array) or not Validate.all_numbers(series):
			return {}
		loaded_all[key] = series

	var loaded_watched := PackedInt64Array()  # the watch list, oldest first
	var saved_watched = d.get("watched", [])
	if saved_watched is Array:
		for i in range(saved_watched.size() - 1, -1, -1):
			if Validate.is_number(saved_watched[i]):
				loaded_watched.append(int(saved_watched[i]))
	var loaded_moved_out := {}  # the bups the pipette took out -> the dish they went to
	var saved_moved_out = d.get("moved_out", [])
	if saved_moved_out is Array:
		for pair: Variant in saved_moved_out:
			if pair is Array and pair.size() == 2 and Validate.is_number(pair[0]) and Validate.is_number(pair[1]):
				loaded_moved_out[int(pair[0])] = int(pair[1])
	var saved_husks := PackedFloat64Array()
	if d.get("husks") is Array:
		for value: Variant in d["husks"]:
			if Validate.is_number(value):
				saved_husks.append(float(value))
	var loaded_time := float(d.get("time", 0.0))
	var loaded := {
		"radius": loaded_radius,
		"resolution": loaded_resolution,
		"thickness": loaded_thickness,
		"limit": loaded_limit,
		"field": saved_field,
		"acetate": saved_acetate,
		"clouds": saved_clouds,
		"death_husks": d.get("death_husks") is bool and d["death_husks"],
		"plankton_husks": d.get("plankton_husks") is bool and d["plankton_husks"],
		"stationary_phase": d.get("stationary_phase") is bool and d["stationary_phase"],
		"husks": saved_husks,
		"sources": loaded_sources,
		"plankton": loaded_plankton,
		"bloom_density": float(d["bloom_density"]) if Validate.is_number(d.get("bloom_density")) else 0.0,
		"upkeep_factor": clampf(float(d["upkeep_factor"]) if Validate.is_number(d.get("upkeep_factor")) else 1.0, 1.0, 100.0),
		"nutrients_placed": int(d.get("nutrients_placed", 0)),
		"time": loaded_time,
		"bloom_due": float(d["bloom_due"]) if Validate.is_number(d.get("bloom_due")) else loaded_time,
		"patch_seed": int(d["patch_seed"]) if Validate.is_number(d.get("patch_seed")) else 0,
		"backend": str(d.get("backend", "")),  # (anything but one of the three is Auto)
		"history": loaded_history,
		"history_all": loaded_all,
		"history_all_factor": int(d["history_all_factor"]),
		"history_origin": float(d["history_origin"]) if Validate.is_number(d.get("history_origin")) else 0.0,
		"watched": loaded_watched,
		"moved_out": loaded_moved_out,
	}
	if Validate.is_number(d.get("feed_density")):
		loaded["feed_density"] = float(d["feed_density"])  # (none saved: the dish keeps the feed it has)
	if Validate.is_number(d.get("next_id")):
		loaded["next_id"] = int(d["next_id"])
	return loaded


## A block of bytes as a save holds it: its size, and the bytes compressed (zstd) and as text. A bup's record is 112 bytes and a family
## record 88, so a hundred thousand of each is about 20 MB raw and a few MB compressed.
static func pack_bytes(bytes: PackedByteArray) -> Dictionary:
	return {"raw": bytes.size(), "z": "" if bytes.is_empty() else Marshalls.raw_to_base64(bytes.compress(FileAccess.COMPRESSION_ZSTD))}  # (nothing to compress: base64 of an empty array is an error)


## What `pack_bytes` made of these, read back from a save; null if it is not one (or does not decompress to the size it says).
static func unpack_bytes(saved: Variant) -> Variant:
	if not (saved is Dictionary) or not Validate.is_number(saved.get("raw")) or not (saved.get("z") is String):
		return null
	var size := int(saved["raw"])
	if size < 0 or size > MAX_SAVED_BYTES:
		return null
	var bytes := Marshalls.base64_to_raw(saved["z"]).decompress(size, FileAccess.COMPRESSION_ZSTD) if size > 0 else PackedByteArray()
	return bytes if bytes.size() == size else null


static func _vec_to_array(v: Vector2) -> Array:
	return [v.x, v.y]


static func _array_to_vec(a: Array) -> Vector2:
	return Vector2(a[0], a[1])
