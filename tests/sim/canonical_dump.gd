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


## "" when `a` and `b` are the same, else a line naming the first difference: the section, the record or event it is in and the word.
static func diff(a: Dictionary, b: Dictionary) -> String:
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
