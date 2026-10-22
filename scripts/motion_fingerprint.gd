class_name MotionFingerprint
extends RefCounted
## What the motion table (scripts/motion_table.gd) was measured from, as two hashes it carries with it, so that a table
## measured from a swimmer that no longer exists is found rather than trusted.
##   - The constants hash covers the constants of the real run-and-tumble swimming (SimConstants.MOTION_INPUTS).
##   - The code hash covers the text of the native functions that make that swimming (FINE_MOTION), with comments and
##     spacing left out, so only a change to what they do counts.
## tests/motion_table_test.gd compares both with the table's, and compares the coarse motion with the fine one directly
## (which catches what a hash can't); SimConstants.apply() checks the constants in a debug game. The fix for a stale
## table is always the same: run tools/gen_motion_table.gd (the command is in its header), which measures the table again.

## The native code of the real swimming: [file, the text a function's definition begins with].
const FINE_MOTION := [
	["native/src/bup_sim.cpp", "double BupSim::tumble_rate("],
	["native/src/bup_sim.cpp", "void BupSim::swim_by_runs("],
	["native/src/bup_sim.cpp", "void BupSim::keep_inside("],
	["native/src/bup_sim.cpp", "double BupSim::estimate_error("],
	["native/src/bup_sim.cpp", "double BupSim::sense_range("],
	["native/src/bup_sim.cpp", "double BupSim::size_of("],
	["native/src/params.h", "inline double sense_error("],
]


static func constants_hash() -> String:
	var built := SimConstants.build()
	var text := ""
	var names: Array = SimConstants.MOTION_INPUTS.duplicate()
	names.sort()
	for key: String in names:
		text += "%s=%s\n" % [key, var_to_str(built[key])]
	return text.sha256_text()


## "" if the native sources are not there (an exported game has none).
static func code_hash() -> String:
	var text := ""
	for entry: Array in FINE_MOTION:
		var source := FileAccess.get_file_as_string("res://" + entry[0])
		if source.is_empty():
			return ""
		var function := _function_text(source, entry[1])
		if function.is_empty():
			push_error("MotionFingerprint: no function '%s' in %s (renamed? update FINE_MOTION)" % [entry[1], entry[0]])
			return ""
		text += function + "\n"
	return text.sha256_text()


static func constants_current() -> bool:
	return constants_hash() == MotionTable.CONSTANTS_HASH


static func code_current() -> bool:
	var now := code_hash()
	return now.is_empty() or now == MotionTable.CODE_HASH


## The function that starts with `head`, from its first character to its closing brace, with the comments taken out and
## all spacing squeezed to nothing.
static func _function_text(source: String, head: String) -> String:
	var start := source.find(head)
	if start < 0:
		return ""
	var open := source.find("{", start)
	var depth := 0
	var end := open
	while end < source.length():
		var c := source[end]
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				break
		end += 1
	var text := source.substr(start, end - start + 1)
	var lines := []
	for line in text.split("\n"):
		var comment := line.find("//")
		lines.append(line if comment < 0 else line.substr(0, comment))
	text = "".join(lines)
	for blank in [" ", "\t", "\r"]:
		text = text.replace(blank, "")
	return text
