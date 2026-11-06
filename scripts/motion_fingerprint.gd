class_name MotionFingerprint
extends RefCounted
## What the motion table (scripts/motion_table.gd) was measured from, as two hashes it carries with it, so that a table
## measured from a swimmer that no longer exists is found rather than trusted.
##   - The constants hash covers the constants of the real run-and-tumble swimming (SimConstants.MOTION_INPUTS).
##   - The code hash covers the text of the swimming kernel (GpuKernelsField.K_SWIM, which the pooled world's swim kernel is
##     made from), with comments and spacing left out, so only a change to what it does counts.
## tests/motion_table_test.gd compares both with the table's; tests/sim/motion_test.gd (windowed, on the pooled GPU world)
## compares the coarse motion with the fine one directly (which catches what a hash can't); SimConstants.apply() checks the
## constants in a debug game. The fix for a stale table is always the same: run tools/gen_motion_table.gd (the command is in
## its header), which measures the table again.


static func constants_hash() -> String:
	var built := SimConstants.build()
	var text := ""
	var names: Array = SimConstants.MOTION_INPUTS.duplicate()
	names.sort()
	for key: String in names:
		text += "%s=%s\n" % [key, var_to_str(built[key])]
	return text.sha256_text()


## The hash of the swimming kernel's text, or "" when `source` is empty (a kernel that is not there is never a current one).
static func code_hash(source: String = GpuKernelsField.K_SWIM) -> String:
	if source.is_empty():
		return ""
	return _squeezed(source).sha256_text()


static func constants_current() -> bool:
	return constants_hash() == MotionTable.CONSTANTS_HASH


static func code_current(source: String = GpuKernelsField.K_SWIM) -> bool:
	var now := code_hash(source)
	return not now.is_empty() and now == MotionTable.CODE_HASH


## `source` with the comments taken out and all spacing squeezed to nothing.
static func _squeezed(source: String) -> String:
	var lines := []
	for line in source.split("\n"):
		var comment := line.find("//")
		lines.append(line if comment < 0 else line.substr(0, comment))
	var text := "".join(lines)
	for blank in [" ", "\t", "\r"]:
		text = text.replace(blank, "")
	return text
