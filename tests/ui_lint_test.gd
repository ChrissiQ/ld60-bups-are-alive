extends SceneTree
## Run: godot --headless --path . -s tests/ui_lint_test.gd
##
## Keeps the interface cohesive by making hand-styling fail the build.
##
## The rules, and what to do instead:
##   - Never style a node directly (no `theme_override_*`, no `add_theme_*_override`, no
##     StyleBox in a scene or script). Pick a theme type variation with `theme_type_variation`.
##     If none fits, add a new variation to scenes/menu_theme.tres so everything can reuse it.
##   - Never assign a theme in a scene. The project theme applies to every Control already, so a
##     new scene gets the right look just by existing.
##   - Numeric settings are `ui/setting_row.tscn` (SettingRow), not hand-built sliders or spin
##     boxes; label/value pairs are `ui/stat_row.tscn` (StatRow).
##   - No palette in code: colours (and font sizes) used by UI come from the theme, e.g.
##     `get_theme_color("name", "ThemeType")`. Custom-drawn widgets add their own theme type.
##   - Dialogs are plain AcceptDialog / ConfirmationDialog; DialogStyle styles them.

const THEME := "res://scenes/menu_theme.tres"
const SCENE_DIRS := ["res://scenes", "res://ui"]
const SCRIPT_DIRS := ["res://scripts", "res://ui"]
const SETTING_ROW := "res://ui/setting_row.tscn"
## Widgets that stand in for SettingRow, and the few places allowed to use them.
const BANNED_WIDGETS := ["HSlider", "VSlider", "SpinBox", "HScrollBar", "VScrollBar"]
const WIDGET_ALLOWED := ["res://ui/setting_row.tscn", "res://scenes/main.tscn:NutrientCount", "res://scenes/main.tscn:SourceRate", "res://scenes/main.tscn:BrushSize", "res://scenes/main.tscn:PipetteRadius"]  ## (the tool tray's number boxes)
## World rendering (the dish, bups, nutrient) is art, not UI chrome, so it keeps its own colours.
const COLOR_ALLOWED := ["res://scripts/dish.gd", "res://scripts/genome.gd"]  ## (the bups' own colours are world data too)
## A bup's name has exactly one source (see BupNames): panels must not build one themselves.
const NAME_FILES := ["res://scripts/bup_names.gd", "res://scripts/cell.gd", "res://scripts/dish.gd"]  ## the only scripts that may touch how a bup is named
const NAME_INTERNALS := ["\\btitle_for\\(", "\\bdefault_name\\(", "BupNames\\.clean\\("]  ## (regular expressions: Dish's own bup_default_name( is fine)
const SCENE_PATHS_FILE := "res://scripts/scenes.gd"  ## the only script that may spell out a screen's path

func fail(where: String, line: int, what: String, fix: String) -> void:
	TestUtil.failures.append("%s%s: %s  ->  %s" % [where, ":%d" % line if line > 0 else "", what, fix])


## Variation name -> base type, read from the theme file.
func _theme_variations() -> Dictionary:
	var out := {}
	var rx := RegEx.create_from_string("^(\\w+)/base_type = &?\"(\\w+)\"")  # the editor saves it as a StringName: &"Label"
	for line in FileAccess.get_file_as_string(THEME).split("\n"):
		var m := rx.search(line)
		if m:
			out[m.get_string(1)] = m.get_string(2)
	return out


## A line of code with its trailing comment removed. Unlike get_slice("#", 0), a '#' inside a
## string (a hex colour, say) is left alone, so those strings are still scanned.
static func _code_only(line: String) -> String:
	var quote := ""
	var i := 0
	while i < line.length():
		var ch := line[i]
		if quote != "":
			if ch == "\\":
				i += 1
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, i)
		i += 1
	return line


## The type of a scene's root node, so a variation set on an instance can be checked too.
func _scene_root_type(path: String) -> String:
	var rx := RegEx.create_from_string("^\\[node name=\"[^\"]+\" type=\"(\\w+)\"")
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var m := rx.search(line)
		if m:
			return m.get_string(1)
	return ""


func _init() -> void:
	var variations := _theme_variations()
	if variations.size() < 20:
		fail(THEME, 0, "found only %d theme variations" % variations.size(), "the theme should define the shared roles")
	for v in variations:
		if not ClassDB.class_exists(variations[v]):
			fail(THEME, 0, "variation %s has unknown base type %s" % [v, variations[v]], "fix its base_type")

	var variation_rx := RegEx.create_from_string("theme_type_variation = &\"(\\w+)\"")
	var node_rx := RegEx.create_from_string("^\\[node name=\"([^\"]+)\" type=\"(\\w+)\"")
	var instance_rx := RegEx.create_from_string("^\\[node name=\"([^\"]+)\" parent=\"[^\"]*\" instance=ExtResource\\(\"([^\"]+)\"\\)")
	var resource_rx := RegEx.create_from_string("^\\[ext_resource type=\"PackedScene\"(?: uid=\"[^\"]*\")? path=\"([^\"]+)\" id=\"([^\"]+)\"")
	var scenes_checked := 0

	for path in TestUtil.files(SCENE_DIRS, ["tscn"]):
		scenes_checked += 1
		var lines := FileAccess.get_file_as_string(path).split("\n")
		var node_name := ""
		var node_type := ""
		var scene_by_id := {}
		for line in lines:
			var r := resource_rx.search(line)
			if r:
				scene_by_id[r.get_string(2)] = r.get_string(1)
		for i in lines.size():
			var line: String = lines[i]
			var n := node_rx.search(line)
			var inst := instance_rx.search(line)
			if n:
				node_name = n.get_string(1)
				node_type = n.get_string(2)
			elif inst:
				node_name = inst.get_string(1)
				node_type = _scene_root_type(scene_by_id.get(inst.get_string(2), ""))  # an instance's type is its scene's root
			elif line.begins_with("[node "):
				node_name = ""
				node_type = ""
			if line.begins_with("theme_override_"):
				fail(path, i + 1, "'%s' on node %s" % [line, node_name], "use a theme_type_variation (add one to the theme if needed); never override styling on a node")
			if line.begins_with("[sub_resource type=\"StyleBox") or line.begins_with("[sub_resource type=\"SystemFont") or line.begins_with("[sub_resource type=\"Theme"):
				fail(path, i + 1, "'%s' defined in a scene" % line, "styles and fonts belong in scenes/menu_theme.tres")
			if line.begins_with("theme = ") or line.contains("type=\"Theme\""):
				fail(path, i + 1, "'%s' assigns a theme in a scene" % line, "remove it; the project theme already applies to every Control")
			for widget in BANNED_WIDGETS:
				if line.contains("type=\"%s\"" % widget) and not (path in WIDGET_ALLOWED or "%s:%s" % [path, node_name] in WIDGET_ALLOWED):
					fail(path, i + 1, "hand-built %s (%s)" % [widget, node_name], "use a SettingRow (res://ui/setting_row.tscn) for numeric settings")
			var v := variation_rx.search(line)
			if v:
				var name := v.get_string(1)
				if not variations.has(name):
					fail(path, i + 1, "node %s uses theme_type_variation '%s', which the theme doesn't define" % [node_name, name], "check the spelling or add it to the theme")
				elif node_type != "" and not ClassDB.is_parent_class(node_type, variations[name]):
					fail(path, i + 1, "node %s (%s) uses '%s', a %s variation" % [node_name, node_type, name, variations[name]], "pick a variation made for a %s" % node_type)

	# Scripts must not build styles either, and any variation they name must exist.
	var banned := ["add_theme_", "remove_theme_", "theme_override", "StyleBoxFlat", "StyleBoxEmpty", "StyleBoxTexture", "StyleBoxLine", "Theme.new", "SystemFont", "FontFile.new", "FontVariation"]
	var named_rx := RegEx.create_from_string("&\"([A-Z]\\w+)\"")
	var color_rx := RegEx.create_from_string("\\bColor8?\\(\\s*[-\\d.]|\\bColor\\.[A-Za-z_]+\\b|#[0-9a-fA-F]{6}\\b")
	var scripts_checked := 0
	for path in TestUtil.files(SCRIPT_DIRS, ["gd"]):
		scripts_checked += 1
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			var line: String = lines[i]
			var code := _code_only(line)
			if path != SCENE_PATHS_FILE and code.contains("res://scenes/"):
				fail(path, i + 1, "spells out a scene path in '%s'" % code.strip_edges(), "add it to scripts/scenes.gd and use Scenes.NAME")
			if path not in NAME_FILES:
				for internal in NAME_INTERNALS:
					if RegEx.create_from_string(internal).search(code) != null:
						fail(path, i + 1, "builds a bup's name itself ('%s')" % code.strip_edges(), "use Dish.bup_name(id), or put a BupNameRow (ui/bup_name_row.tscn) in the panel and call show_bup()")
			if path not in COLOR_ALLOWED:
				if color_rx.search(code) != null:
					fail(path, i + 1, "hard-coded colour in '%s'" % code.strip_edges(), "add a colour to the theme (a theme type for custom drawing) and read it with get_theme_color()")
			for word in banned:
				if code.contains(word):
					fail(path, i + 1, "uses '%s'" % word, "style through the theme and theme_type_variation, never in code")
			if code.contains("theme_type_variation") or code.contains("_VARIATION"):
				for m in named_rx.search_all(code):
					if not variations.has(m.get_string(1)):
						fail(path, i + 1, "names theme variation '%s', which the theme doesn't define" % m.get_string(1), "check the spelling or add it to the theme")

	if scenes_checked < 5 or scripts_checked < 10:
		fail("lint", 0, "scanned only %d scenes and %d scripts" % [scenes_checked, scripts_checked], "the scan paths are wrong")

	TestUtil.finish(self, "UI LINT OK  (%d scenes, %d scripts, %d theme variations)" % [scenes_checked, scripts_checked, variations.size()], "UI LINT FAILED - %d problem(s):" % TestUtil.failures.size())
