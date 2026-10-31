class_name DishCodec
extends RefCounted
## A dish's save format: a `DishBlob` as a dictionary (`write_blob`) and the reading back of it (`read_blob`), which checks
## everything and builds it on the side, so that a save that is refused leaves the dish exactly as it was.

const MAX_SAVED_BYTES := 600000000  ## the most a save's block of bups or of family records may be once decompressed (2,000,000 bups are 224 MB)

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

