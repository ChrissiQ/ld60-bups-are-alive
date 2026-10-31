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
	var out := {
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
		"watched": dish.watched,
		"backend": dish.backend.setting,
		"moved_out": saved_moved_out,
	}
	out.merge(dish.history.write())
	return out


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
	var loaded_history := DishHistory.read(d)
	if loaded_history.is_empty():
		return {}
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
		"watched": loaded_watched,
		"moved_out": loaded_moved_out,
	}
	if Validate.is_number(d.get("feed_density")):
		loaded["feed_density"] = float(d["feed_density"])  # (none saved: the dish keeps the feed it has)
	if Validate.is_number(d.get("next_id")):
		loaded["next_id"] = int(d["next_id"])
	return loaded


## ---- The pooled world's save: a `DishBlob` as a dictionary and back ----

const FORMAT := 3  ## the blob format; a save of another one (every earlier one included) is refused, never read
const SPEC_NUMBERS := ["number", "seed", "radius", "resolution", "limit", "step", "flags", "nutrient_density", "feed_density", "bloom_density", "upkeep",
		"medium_thickness", "patch_seed", "patchiness", "cloud_quota", "husk_quota"]
const WORLD_NUMBERS := ["time", "radius", "bloom_density", "diffusion", "handover_len", "nutrient_energy", "next_source", "bloom_due", "burst_clock", "rng_seed", "rng_state"]
const PLANKTON_NUMBERS := ["born_at", "burst_at", "units", "shape"]
const SOURCE_NUMBERS := ["rate", "emitted", "em_mass", "em_age", "em_lived"]
const SLOT_BYTES := 32  ## a cloud's or a husk's slot: eight words
const LINEAGE_RECORD_BYTES := 88  ## LineageStore::RECORD_BYTES


## The save of a dish taken out of the world (`SimCore.gather`, with `blob.world` from `DishWorld.save()` and `blob.host` holding what the
## host keeps with the dish: `history` (what `DishHistory.write` returns, and what `DishHistory.read` takes), `watched` (the ids, in the host's order), `lineage` (the bytes
## of `LineageStore.export_dish`) and `nutrients_placed`). Every number the run continues from is written bit for bit: the device blocks
## as bytes, the spec, the world and the history as binary variants (JSON text would round a double). There is no `moved_out`: a pipette's
## bups carry their ids and the family tree is one store.
static func write_blob(blob: DishBlob) -> Dictionary:
	var host := blob.host
	var host_out := {}
	host_out["history"] = host.get("history", {})
	host_out["watched"] = Array(host.get("watched", []))
	host_out["nutrients_placed"] = int(host.get("nutrients_placed", 0))
	var meta := {"spec": blob.spec, "world": blob.world, "host": host_out}
	return {
		"format": FORMAT,
		"meta": pack_bytes(var_to_bytes(meta)),
		"dstate": pack_bytes(blob.dstate),
		"records": pack_bytes(blob.records),
		"conc": pack_bytes(blob.conc.to_byte_array()),
		"conc2": pack_bytes(blob.conc2.to_byte_array()),
		"dplo": pack_bytes(blob.dplo),
		"dphi": pack_bytes(blob.dphi),
		"clouds": pack_bytes(blob.clouds.to_byte_array()),
		"husks": pack_bytes(blob.husks.to_byte_array()),
		"lineage": pack_bytes(host.get("lineage", PackedByteArray())),
	}


## The `DishBlob` of a `write_blob` (its `host` has `history`, `watched`, `lineage`, `nutrients_placed`), checked whole and built on the
## side; null if anything is missing, unreadable, of another format or of a size the dish cannot have. Values that are only out of
## range (the limit, the feeds, the upkeep, the medium) are made safe; a size or grid that does not fit the saved blocks is refused.
static func read_blob(d: Dictionary) -> DishBlob:
	if not Validate.is_number(d.get("format")) or int(d["format"]) != FORMAT:
		return null
	var parts := {}
	for key: String in ["meta", "dstate", "records", "conc", "conc2", "dplo", "dphi", "clouds", "husks", "lineage"]:
		var bytes: Variant = unpack_bytes(d.get(key))
		if bytes == null:
			return null
		parts[key] = bytes
	var meta: Variant = bytes_to_var(parts["meta"]) if parts["meta"].size() > 0 else null
	if not (meta is Dictionary) or not (meta.get("spec") is Dictionary) or not (meta.get("world") is Dictionary) or not (meta.get("host") is Dictionary):
		return null
	var spec: Variant = _read_spec(meta["spec"])
	var world: Variant = _read_world(meta["world"])
	if spec == null or world == null:
		return null
	var count_bytes: int = parts["records"].size()
	if count_bytes % GpuLayout.RECORD_BYTES != 0 or count_bytes / GpuLayout.RECORD_BYTES > StartConditions.MAX_BUP_LIMIT:
		return null
	spec["limit"] = clampi(maxi(int(spec["limit"]), count_bytes / GpuLayout.RECORD_BYTES), 1, StartConditions.MAX_BUP_LIMIT)
	var cells := DishGrid.cells_across(float(spec["radius"]), int(spec["resolution"]))
	var grid_bytes := cells * cells * 4
	if parts["dstate"].size() != GpuLayout.DS_WORDS * 4 or parts["conc"].size() != grid_bytes or parts["conc2"].size() != grid_bytes \
			or parts["dplo"].size() != grid_bytes or parts["dphi"].size() != grid_bytes:
		return null
	if int(parts["dstate"].decode_u32(GpuLayout.DS_COUNT * 4)) != count_bytes / GpuLayout.RECORD_BYTES:
		return null
	if parts["clouds"].size() % SLOT_BYTES != 0 or parts["husks"].size() % SLOT_BYTES != 0:
		return null
	spec["cloud_quota"] = maxi(int(spec["cloud_quota"]), parts["clouds"].size() / SLOT_BYTES)
	spec["husk_quota"] = maxi(int(spec["husk_quota"]), parts["husks"].size() / SLOT_BYTES)
	var lineage: PackedByteArray = parts["lineage"]
	if not lineage.is_empty():
		if lineage.size() < 4 or 4 + lineage.decode_u32(0) * LINEAGE_RECORD_BYTES > lineage.size():
			return null
	var saved_host: Dictionary = meta["host"]
	var saved_history: Variant = saved_host.get("history")
	if not (saved_history is Dictionary) or DishHistory.read(saved_history).is_empty():
		return null
	var watched := PackedInt64Array()
	var saved_watched: Variant = saved_host.get("watched", [])
	if not (saved_watched is Array):
		return null
	for id: Variant in saved_watched:
		if not (id is int):
			return null
		watched.append(id)
	var blob := DishBlob.new()
	blob.spec = spec
	blob.dstate = parts["dstate"]
	blob.records = parts["records"]
	blob.conc = parts["conc"].to_float32_array()
	blob.conc2 = parts["conc2"].to_float32_array()
	blob.dplo = parts["dplo"]
	blob.dphi = parts["dphi"]
	blob.clouds = parts["clouds"].to_float32_array()
	blob.husks = parts["husks"].to_float32_array()
	blob.world = world
	var host := {}
	host["history"] = saved_history
	host["watched"] = watched
	host["lineage"] = lineage
	host["nutrients_placed"] = maxi(int(saved_host.get("nutrients_placed", 0)), 0) if Validate.is_number(saved_host.get("nutrients_placed")) else 0
	blob.host = host
	return blob


static func _read_spec(saved: Dictionary) -> Variant:
	for key: String in SPEC_NUMBERS:
		if not (saved.get(key) is int or saved.get(key) is float) or not is_finite(float(saved[key])):
			return null
	var spec := saved.duplicate()
	var radius := float(spec["radius"])
	var resolution := int(spec["resolution"])
	if radius < StartConditions.MIN_SIM_RADIUS or radius > StartConditions.MAX_DISH_RADIUS \
			or resolution < StartConditions.MIN_NUTRIENT_RESOLUTION or resolution > StartConditions.MAX_NUTRIENT_RESOLUTION:
		return null  # (the saved grid is built for these: a clamped size would not fit it)
	spec["number"] = maxi(int(spec["number"]), 0)
	spec["step"] = maxi(int(spec["step"]), 0)
	spec["limit"] = clampi(int(spec["limit"]), 1, StartConditions.MAX_BUP_LIMIT)
	spec["upkeep"] = clampf(float(spec["upkeep"]), 1.0, 100.0)
	spec["medium_thickness"] = clampf(float(spec["medium_thickness"]), StartConditions.MIN_MEDIUM_THICKNESS, StartConditions.MAX_MEDIUM_THICKNESS)
	for key: String in ["feed_density", "bloom_density", "nutrient_density", "patchiness"]:
		spec[key] = maxf(float(spec[key]), 0.0)
	spec["cloud_quota"] = maxi(int(spec["cloud_quota"]), 0)
	spec["husk_quota"] = maxi(int(spec["husk_quota"]), 0)
	return spec


static func _read_world(saved: Dictionary) -> Variant:
	for key: String in WORLD_NUMBERS:
		if not (saved.get(key) is int or saved.get(key) is float) or not is_finite(float(saved[key])):
			return null
	if not (saved.get("plankton_husks") is bool) or not (saved.get("plankton") is Array) or not (saved.get("sources") is Dictionary):
		return null
	if not (saved["rng_seed"] is int) or not (saved["rng_state"] is int):
		return null
	if saved["plankton"].size() > Dish.MAX_PLANKTON:
		return null
	for p: Variant in saved["plankton"]:
		if not (p is Dictionary) or not (p.get("pos") is Vector2) or not is_finite(p["pos"].x) or not is_finite(p["pos"].y):
			return null
		for key: String in PLANKTON_NUMBERS:
			if not Validate.is_number(p.get(key)):
				return null
	if saved["sources"].size() > Dish.MAX_SOURCES:
		return null
	for id: Variant in saved["sources"]:
		var s: Variant = saved["sources"][id]
		if not (id is int) or not (s is Dictionary) or not (s.get("pos") is Vector2) or not is_finite(s["pos"].x) or not is_finite(s["pos"].y):
			return null
		for key: String in SOURCE_NUMBERS:
			if not Validate.is_number(s.get(key)):
				return null
	return saved


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
