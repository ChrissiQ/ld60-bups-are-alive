class_name CanonicalDump
extends RefCounted
## What one dish is, as bytes, in a form two runs can be compared word by word: a Dictionary of section name to PackedByteArray.
## Sections (SECTIONS): records (the bups' records in slot order, R_PX and R_PY zeroed: they are the last picture's, not the dish's),
## field, clouds, husks, dstate (the dish's DS_* words), births, deaths, stats. `diff` names the first word that differs by its
## GpuLayout constant (R_*, DS_*, EB_*, ED_*, ST_*), so a failing isolation test says which word of which record.
##
## Expected values (derived): two dumps of the same bytes differ nowhere (diff == ""); one flipped word in a record is named
## "records: record <i> ... word <w> (R_<NAME>)". No placeholder.

const SECTIONS := ["records", "field", "clouds", "husks", "dstate", "births", "deaths", "stats"]
const CLOUD_WORDS := 8  ## per cloud and per husk in a dump (the dump is a flat list of words; the layout is the core's)

static var _names: Dictionary = {}


## A dump from `bytes_by_section` (a missing section is empty); the records have R_PX and R_PY zeroed.
static func make(bytes_by_section: Dictionary) -> Dictionary:
	var out := {}
	for s in SECTIONS:
		out[s] = PackedByteArray(bytes_by_section.get(s, PackedByteArray()))
	out["records"] = mask_pictures(out["records"])
	return out


## What `SimCore.canonical_dump(row)` returned (a Dictionary of the sections, or an object with the same members) as a dump.
static func coerce(value: Variant) -> Dictionary:
	var sections := {}
	if value is Dictionary:
		sections = value
	elif value is Object:
		for s in SECTIONS:
			var v: Variant = value.get(s)
			if v != null:
				sections[s] = v
	return make(sections)


static func mask_pictures(records: PackedByteArray) -> PackedByteArray:
	var out := records.duplicate()
	var n := out.size() / GpuLayout.RECORD_BYTES
	for i in n:
		out.encode_u32(i * GpuLayout.RECORD_BYTES + GpuLayout.R_PX * 4, 0)
		out.encode_u32(i * GpuLayout.RECORD_BYTES + GpuLayout.R_PY * 4, 0)
	return out


## The words of a section as GpuLayout names them: "R_ENERGY", "DS_MOVED_IN"... ("" when no constant has that value).
static func word_name(section: String, word: int) -> String:
	if _names.is_empty():
		var prefixes := {"records": "R_", "dstate": "DS_", "births": "EB_", "deaths": "ED_", "stats": "ST_"}
		var constants: Dictionary = (GpuLayout as GDScript).get_script_constant_map()
		for sec in prefixes:
			var by_word := {}
			for k: String in constants:
				if k.begins_with(prefixes[sec]) and not k.ends_with("_WORDS") and not k.ends_with("_BYTES") and constants[k] is int:
					if not by_word.has(constants[k]):
						by_word[constants[k]] = k
			_names[sec] = by_word
	return _names.get(section, {}).get(word, "")


## A dump with its ids replaced by their rank among the ids the dump holds (the world's ids depend on the other dishes, their order within a
## dish does not), and the dstate words only a blob keeps (DS_WORLD_ID_*) zeroed: what two runs of one dish are compared by.
static func normalised(dump: Dictionary) -> Dictionary:
	var out := dump.duplicate()
	var recs: PackedByteArray = dump.get("records", PackedByteArray()).duplicate()
	var births: PackedByteArray = dump.get("births", PackedByteArray()).duplicate()
	var deaths: PackedByteArray = dump.get("deaths", PackedByteArray()).duplicate()
	var dstate: PackedByteArray = dump.get("dstate", PackedByteArray()).duplicate()
	var bw := GpuLayout.BIRTH_WORDS
	var dw := GpuLayout.DEATH_WORDS
	var rw := GpuLayout.RECORD_WORDS
	var seen := {}
	for k in recs.size() / GpuLayout.RECORD_BYTES:
		seen[GpuLayout.id_of(recs, k)] = true
	for k in births.size() / (bw * 4):
		seen[_id64(births, k * bw + GpuLayout.EB_ID_LO)] = true
		seen[_id64(births, k * bw + GpuLayout.EB_PARENT_LO)] = true
	for k in deaths.size() / (dw * 4):
		seen[_id64(deaths, k * dw + GpuLayout.ED_ID_LO)] = true
	seen.erase(0)
	seen.erase(-1)
	var ids := seen.keys()
	ids.sort()
	var rank := {0: 0, -1: -1}
	for k in ids.size():
		rank[ids[k]] = k + 1
	for k in recs.size() / GpuLayout.RECORD_BYTES:
		GpuLayout.set_id(recs, k, rank[GpuLayout.id_of(recs, k)])
	for k in births.size() / (bw * 4):
		for w in [GpuLayout.EB_ID_LO, GpuLayout.EB_PARENT_LO]:
			_put_id64(births, k * bw + w, rank[_id64(births, k * bw + w)])
	for k in deaths.size() / (dw * 4):
		_put_id64(deaths, k * dw + GpuLayout.ED_ID_LO, rank[_id64(deaths, k * dw + GpuLayout.ED_ID_LO)])
	for k in dstate.size() / (GpuLayout.DS_WORDS * 4):
		dstate.encode_u32((k * GpuLayout.DS_WORDS + GpuLayout.DS_WORLD_ID_LO) * 4, 0)
		dstate.encode_u32((k * GpuLayout.DS_WORDS + GpuLayout.DS_WORLD_ID_HI) * 4, 0)
	if rw > 0:
		out["records"] = recs
	out["births"] = births
	out["deaths"] = deaths
	out["dstate"] = dstate
	return out


static func _id64(bytes: PackedByteArray, word: int) -> int:
	return bytes.decode_u32(word * 4) | (bytes.decode_u32((word + 1) * 4) << 32)


static func _put_id64(bytes: PackedByteArray, word: int, id: int) -> void:
	bytes.encode_u32(word * 4, id & 0xFFFFFFFF)
	bytes.encode_u32((word + 1) * 4, (id >> 32) & 0xFFFFFFFF)


## "" when `a` and `b` are the same, else a line naming the first difference: the section, the record or event it is in and the word.
static func diff(p_a: Dictionary, p_b: Dictionary) -> String:
	var a := normalised(p_a)
	var b := normalised(p_b)
	for s in SECTIONS:
		var x: PackedByteArray = a.get(s, PackedByteArray())
		var y: PackedByteArray = b.get(s, PackedByteArray())
		if x == y:
			continue
		var common := mini(x.size(), y.size())
		var at := _first_difference(x, y, common)
		if at < 0:
			return "%s: length %d bytes against %d bytes" % [s, x.size(), y.size()]
		var word := at / 4
		return "%s: %s word %d (%s): a=0x%08x b=0x%08x" % [s, _where(s, word), word % _stride(s) if _stride(s) > 0 else word,
			word_name(s, word % _stride(s) if _stride(s) > 0 else word), x.decode_u32(word * 4), y.decode_u32(word * 4)]
	return ""


static func _stride(section: String) -> int:
	match section:
		"records": return GpuLayout.RECORD_WORDS
		"clouds", "husks": return CLOUD_WORDS
		"dstate": return GpuLayout.DS_WORDS
		"births": return GpuLayout.BIRTH_WORDS
		"deaths": return GpuLayout.DEATH_WORDS
		"stats": return GpuLayout.STATS_WORDS
	return 0


static func _where(section: String, word: int) -> String:
	var stride := _stride(section)
	if stride == 0:
		return "cell" if section == "field" else "at"
	var index := word / stride
	if section == "records":
		return "record %d" % index
	return "entry %d" % index


## The byte of the first 32-bit word that differs in the first `common` bytes (-1 when none): halves the range while it differs.
static func _first_difference(x: PackedByteArray, y: PackedByteArray, common: int) -> int:
	var hi := common - common % 4
	if hi == 0 or x.slice(0, hi) == y.slice(0, hi):
		return -1
	var lo := 0  ## words [lo, hi) hold the first difference, and the words before lo are equal
	hi /= 4
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if x.slice(lo * 4, mid * 4) != y.slice(lo * 4, mid * 4):
			hi = mid
		else:
			lo = mid
	return lo * 4
