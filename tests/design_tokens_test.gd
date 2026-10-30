extends SceneTree
## Run: godot --headless --path . -s tests/design_tokens_test.gd
## design/tokens.json is the one place the interface's colours, type, radii and spacing are defined. This checks that what is built
## from it (scenes/menu_theme.tres, docs/design-system.html) is not stale, and that the generators hold no colour of their own.


func _run(command: String) -> int:
	var root := ProjectSettings.globalize_path("res://")
	return OS.execute("/bin/sh", ["-c", "cd '%s' && %s" % [root, command]])


func _init() -> void:
	TestUtil.check(_run("python3 tools/gen_theme.py --check") == 0, "scenes/menu_theme.tres is stale: run python3 tools/gen_theme.py")
	TestUtil.check(_run("python3 tools/gen_design.py --check") == 0, "docs/design-system.html is stale: run python3 tools/gen_design.py")
	# A colour written as numbers in a generator is a second place to change it.
	var literal := RegEx.create_from_string("\\(\\s*[01]?\\.?\\d+\\s*,\\s*[01]?\\.?\\d+\\s*,\\s*[01]?\\.?\\d+\\s*,\\s*[01]?\\.?\\d+\\s*\\)")
	for path in ["res://tools/gen_theme.py", "res://tools/gen_design.py"]:
		for line in FileAccess.get_file_as_string(path).split("\n"):
			var found := literal.search(line)
			# (four-number tuples are margins (a, b, c, d) in gen_theme.py; a colour has a fractional part)
			if found and "." in found.get_string() and not line.strip_edges().begins_with("#"):
				TestUtil.check(false, "%s holds a colour literal %s: put it in design/tokens.json" % [path, found.get_string()])
	TestUtil.finish(self, "design tokens test OK")
