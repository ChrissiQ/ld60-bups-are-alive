extends SceneTree
## Run: godot --headless --path . -s tests/strings_test.gd
## All the words the player reads are in text/strings.cfg. This checks that every text the code or a scene asks for is
## there, that a texts' numbers (%d, %s...) can be told apart from percent signs, and that no scene shows a raw "@key".

const SCENES := ["menu", "intro", "founders", "free_setup", "pause_menu", "main"]


func check(ok: bool, what: String) -> void:
	TestUtil.check(ok, what)


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
	check(Strings.has_key("hud.paused") and Strings.t("hud.paused") == "PAUSED", "the file loads and gives a text")
	check(Strings.problems().is_empty(), "every text in the file loads: %s" % [Strings.problems()])
	var asked := _asked_for()
	check(asked.size() > 100, "the code and scenes ask for the texts (found %d)" % asked.size())
	for key: String in asked:
		if key.ends_with("*"):
			var prefix := key.trim_suffix("*")
			var section := prefix.get_slice(".", 0)
			var any := false
			var config := ConfigFile.new()
			config.load(Strings.FILE)
			for name in config.get_section_keys(section):
				any = any or name.begins_with(prefix.get_slice(".", 1))
			check(any, "%s asks for texts starting '%s' and there are none" % [asked[key], prefix])
		else:
			check(Strings.has_key(key), "%s asks for '%s', which text/strings.cfg does not have" % [asked[key], key])

	# Every text is a string with something in it, and a %% is not taken for a place for a number.
	var config := ConfigFile.new()
	config.load(Strings.FILE)
	for section in config.get_sections():
		for name in config.get_section_keys(section):
			var value: Variant = config.get_value(section, name)
			check(value is String, "%s.%s is a text" % [section, name])
	check(Strings.count_places("a %d and %s and %.1f and 5%%") == 3, "places for numbers are counted, not percent signs")
	check(Strings.t("hud.readout_bups", [7]) == "bups  7", "a text with a place is filled in")
	check(Strings.list("menu", "quip").size() >= 3, "the title screen has some lines to pick from")

	# Nothing the scenes show is left as a raw "@key" (the TextSweep autoload does it); and TextSweep comes before
	# DialogStyle, so that a dialog is sized with its text.
	var project := FileAccess.get_file_as_string("res://project.godot")
	check(project.contains("TextSweep=") and project.find("TextSweep=") < project.find("DialogStyle="), "project.godot starts TextSweep before DialogStyle")
	Session.free_start = StartConditions.new()
	for scene in SCENES:
		var node: Node = load("res://scenes/%s.tscn" % scene).instantiate()
		root.add_child(node)
		await process_frame
		var raw: Array = []
		_walk(node, raw)
		check(raw.is_empty(), "%s shows a raw key: %s" % [scene, raw.slice(0, 3)])
		node.queue_free()
		await process_frame
	check(Strings.missing.is_empty(), "no text was asked for that the file lacks: %s" % [Strings.missing])

	TestUtil.finish(self, "STRINGS TESTS OK  (%d texts asked for)" % asked.size())
