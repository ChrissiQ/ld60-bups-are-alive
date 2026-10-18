class_name Strings
extends RefCounted
## Every word the player reads lives in one file, text/strings.cfg, so it can be written or reworded in one place.
## Ask for a text by its section and name:
##
##     Strings.t("hud.paused")                     # "PAUSED"
##     Strings.t("goals.living_status", [412, 1000])  # a text with numbers in it: the file holds the %d / %s / %.0f
##
## In a scene, give a node's text (or tooltip, dialog title...) as "@section.name"; the scene's script calls
## `Strings.apply(self)` first thing in `_ready`, which swaps in the text for every such node under it.
##
## A text that is asked for with no numbers is used as written. A text asked for with numbers must hold exactly that many
## of them, in order (%d a whole number, %s words, %.0f a number rounded to a whole one, %.1f to one decimal, and %% for a
## percent sign), or the game says so and shows the text as it is. tests/strings_test.gd checks all of this.

const FILE := "res://text/strings.cfg"

static var _config: ConfigFile = null
static var _places: Dictionary = {}  ## how many places for values each text asked for with numbers has (it is asked for every frame)
static var missing: Array[String] = []  ## texts asked for that the file does not have (a test fails on any)


static func _file() -> ConfigFile:
	if _config == null:
		_config = ConfigFile.new()
		var error := _config.load(FILE)
		if error != OK:
			push_error("Could not read %s (error %d)" % [FILE, error])
		if OS.is_debug_build():  # (tests/strings_test.gd checks it too; a finished game need not read the file twice)
			for problem in problems():
				push_error(problem)
	return _config


## The text for "section.name", with `args` put into its %d / %s / %.0f places when there are any.
static func t(key: String, args: Array = []) -> String:
	var text := raw(key)
	if args.is_empty():
		return text
	if not _places.has(text):
		_places[text] = count_places(text)
	var places: int = _places[text]
	if places != args.size():
		push_error("The text '%s' has %d places for numbers but was given %d" % [key, places, args.size()])
		return text
	return text % args


## The text as written in the file, places and all (the key itself if there is none).
static func raw(key: String) -> String:
	var dot := key.find(".")
	var section := key.substr(0, dot) if dot >= 0 else ""
	var name := key.substr(dot + 1) if dot >= 0 else key
	if not has_key(key):
		if not missing.has(key):
			missing.append(key)
			push_error("No text '%s' in %s" % [key, FILE])
		return key
	return str(_file().get_value(section, name))


const PROPERTIES := ["text", "tooltip_text", "placeholder_text", "title", "dialog_text", "ok_button_text", "cancel_button_text"]  ## what a scene can give as "@section.name"


## Swaps "@section.name" for its text in everything under `root` (and `root` itself) that a scene put on screen.
static func apply(root: Node) -> void:
	for property: String in PROPERTIES:
		if property in root:
			var value: Variant = root.get(property)
			if value is String and value.begins_with("@"):
				root.set(property, resolve(value))
	for child in root.get_children():
		apply(child)


## Lines of the file whose text did not load, each with what to look for. (A quote mark inside a text without a backslash
## before it ends the text there, and the file stops loading from that line on: everything after it is then missing.)
static func problems() -> Array[String]:
	var out: Array[String] = []
	var config := ConfigFile.new()
	config.load(FILE)
	var section := ""
	var line_number := 0
	var section_line := RegEx.create_from_string("^\\[([A-Za-z0-9_]+)\\]")
	var text_line := RegEx.create_from_string("^([A-Za-z0-9_]+)\\s*=\\s*\"")
	for line in FileAccess.get_file_as_string(FILE).split("\n"):
		line_number += 1
		var heading := section_line.search(line)
		if heading != null:
			section = heading.get_string(1)
			continue
		var entry := text_line.search(line)
		if entry != null and not config.has_section_key(section, entry.get_string(1)):
			out.append("%s line %d: '%s.%s' did not load. Look at that text, and above it, for a quote mark inside a text that needs a backslash before it (write \\\" for a quote mark), and nothing after that point loaded." % [FILE, line_number, section, entry.get_string(1)])
			break  # (the first one is the cause; the rest follow from it)
	return out


static func has_key(key: String) -> bool:
	var dot := key.find(".")
	return dot >= 0 and _file().has_section_key(key.substr(0, dot), key.substr(dot + 1))


## "@section.name" is a text to look up; anything else is returned as it is (so a scene can still hold plain text).
static func resolve(text: String) -> String:
	return t(text.substr(1)) if text.begins_with("@") else text


## Every text named `name_1`, `name_2`, ... in a section, in order (a list the game picks from).
static func list(section: String, name: String) -> Array[String]:
	var out: Array[String] = []
	var i := 1
	while _file().has_section_key(section, "%s_%d" % [name, i]):
		out.append(str(_file().get_value(section, "%s_%d" % [name, i])))
		i += 1
	return out


## How many places for values (%d, %s, %.0f...) a text has, not counting a %% (a percent sign).
static func count_places(text: String) -> int:
	var count := 0
	var i := 0
	while i < text.length():
		if text[i] == "%":
			if i + 1 < text.length() and text[i + 1] == "%":
				i += 1
			else:
				count += 1
		i += 1
	return count
