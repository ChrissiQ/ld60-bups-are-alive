extends SceneTree
## Run: godot --headless --path . -s tests/strings_test.gd
## All the words the player reads are in text/strings.cfg. This checks that every text the code or a scene asks for is
## there, that a texts' numbers (%d, %s...) can be told apart from percent signs, and that no scene shows a raw "@key".

const SCENES := ["menu", "intro", "founders", "free_setup", "pause_menu", "main"]


## Every "@section.name" in the scene files, and every Strings.t / raw / has_key("section.name") in the scripts.
func _asked_for() -> Dictionary:
	var asked := {}  # key -> where
	var scene_key := RegEx.create_from_string('"@([a-z0-9_]+\\.[a-z0-9_]+)"')
	for dir in ["res://scenes", "res://ui"]:
		for path: String in TestUtil.files([dir], ["tscn"]):
			for m in scene_key.search_all(FileAccess.get_file_as_string(path)):
				asked[m.get_string(1)] = path
	var code_key := RegEx.create_from_string('Strings\\.(?:t|raw|has_key)\\("([a-z0-9_]+\\.[a-z0-9_]+)"')
	var dynamic := RegEx.create_from_string('Strings\\.t\\("([a-z0-9_]+\\.[a-z0-9_]+_)" \\+')
	for dir in ["res://scripts", "res://ui"]:
		for path: String in TestUtil.files([dir], ["gd"]):
			if path.ends_with("/strings.gd"):
				continue  # (its notes use example keys)
			var source := FileAccess.get_file_as_string(path)
			for m in code_key.search_all(source):
				if not m.get_string(1).ends_with("_"):  # (a key ending in _ is the start of one built from a word: below)
					asked[m.get_string(1)] = path
			for m in dynamic.search_all(source):  # a key built from a prefix and a word: the prefix must start some texts
				asked[m.get_string(1) + "*"] = path
	return asked


func _walk(node: Node, found: Array) -> void:
	for property: String in Strings.PROPERTIES:
		if property in node:
			var value: Variant = node.get(property)
			if value is String and value.begins_with("@"):
				found.append("%s.%s = %s" % [node.get_path(), property, value])
	for child in node.get_children():
		_walk(child, found)


func _init() -> void:
	TestUtil.check(Strings.has_key("hud.dish_title") and Strings.t("hud.dish_title") == "Dish", "the file loads and gives a text")
	TestUtil.check(Strings.problems().is_empty(), "every text in the file loads: %s" % [Strings.problems()])
	var asked := _asked_for()
	TestUtil.check(asked.size() > 100, "the code and scenes ask for the texts (found %d)" % asked.size())
	for key: String in asked:
		if key.ends_with("*"):
			var prefix := key.trim_suffix("*")
			var section := prefix.get_slice(".", 0)
			var any := false
			var config := ConfigFile.new()
			config.load(Strings.FILE)
			for name in config.get_section_keys(section):
				any = any or name.begins_with(prefix.get_slice(".", 1))
			TestUtil.check(any, "%s asks for texts starting '%s' and there are none" % [asked[key], prefix])
		else:
			TestUtil.check(Strings.has_key(key), "%s asks for '%s', which text/strings.cfg does not have" % [asked[key], key])

	# Every text is a string with something in it, and a %% is not taken for a place for a number.
	var config := ConfigFile.new()
	config.load(Strings.FILE)
	for section in config.get_sections():
		for name in config.get_section_keys(section):
			var value: Variant = config.get_value(section, name)
			TestUtil.check(value is String, "%s.%s is a text" % [section, name])
	TestUtil.check(Strings.count_places("a %d and %s and %.1f and 5%%") == 3, "places for numbers are counted, not percent signs")
	TestUtil.check(Strings.t("hud.readout_bups", [7]) == "7 bups", "a text with a place is filled in")
	TestUtil.check(Strings.list("menu", "quip").size() >= 3, "the title screen has some lines to pick from")

	# Nothing the scenes show is left as a raw "@key" (the TextSweep autoload does it); and TextSweep comes before
	# DialogStyle, so that a dialog is sized with its text.
	var project := FileAccess.get_file_as_string("res://project.godot")
	TestUtil.check(project.contains("TextSweep=") and project.find("TextSweep=") < project.find("DialogStyle="), "project.godot starts TextSweep before DialogStyle")
	Session.free_start = StartConditions.new()
	for scene in SCENES:
		var node: Node = load("res://scenes/%s.tscn" % scene).instantiate()
		root.add_child(node)
		await process_frame
		var raw: Array = []
		_walk(node, raw)
		TestUtil.check(raw.is_empty(), "%s shows a raw key: %s" % [scene, raw.slice(0, 3)])
		node.queue_free()
		await process_frame
	TestUtil.check(Strings.missing.is_empty(), "no text was asked for that the file lacks: %s" % [Strings.missing])

	# Raw files the game reads (not resources Godot imports) are left out of an exported game unless a preset's include filter names
	# them, and then every text shows as its key: so each one a script names must be in every preset's filter.
	var raw_file := RegEx.create_from_string('"res://([^"]+\\.(?:cfg|txt|json|csv))"')
	var needed := {}
	for dir in ["res://scripts", "res://ui"]:
		for path: String in TestUtil.files([dir], ["gd"]):
			for m in raw_file.search_all(FileAccess.get_file_as_string(path)):
				needed[m.get_string(1)] = path
	var presets := ConfigFile.new()
	TestUtil.check(presets.load("res://export_presets.cfg") == OK and needed.has("text/strings.cfg"), "the export presets load, and the scripts read raw files (text/strings.cfg at least)")
	for section in presets.get_sections():
		if not section.begins_with("preset.") or section.ends_with(".options"):
			continue
		var filters := String(presets.get_value(section, "include_filter", "")).split(",")
		for file: String in needed:
			var included := false
			for pattern in filters:
				included = included or file.match(pattern.strip_edges())
			TestUtil.check(included, "export preset '%s' includes %s (read by %s)" % [presets.get_value(section, "name", section), file, needed[file]])
	TestUtil.finish(self, "STRINGS TESTS OK  (%d texts asked for)" % asked.size())
