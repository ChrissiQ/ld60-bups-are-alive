extends SceneTree
## Run: godot --headless --path . -s tests/fonts_test.gd
## The whole game is set in two bundled typefaces: IBM Plex Sans for text and Commit Mono for numbers, in different weights.
## Nothing may use a system font, define its own font, or override the theme's fonts.

const THEME := "res://scenes/menu_theme.tres"
const FAMILIES := ["res://fonts/CommitMono-", "res://fonts/IBMPlexSans-"]
var used := {}  ## font resource path -> how many text controls use it


func _note(who: String, font: Font) -> void:
	var path := font.resource_path if font != null else "(none)"
	TestUtil.check(font is FontFile and (path.begins_with(FAMILIES[0]) or path.begins_with(FAMILIES[1])), "%s uses %s instead of the bundled font" % [who, path])
	used[path] = used.get(path, 0) + 1


func _walk(node: Node, who: String) -> void:
	var here := "%s/%s" % [who, node.name]
	if node is RichTextLabel:
		for item in ["normal_font", "bold_font", "mono_font"]:
			_note("%s (%s)" % [here, item], node.get_theme_font(item))
	elif node is Label or node is Button or node is LineEdit:
		_note(here, node.get_theme_font("font"))
	for c in node.get_children():
		_walk(c, who)


func _init() -> void:
	# (Bare scripts don't start autoloads; add the dialog style hook the way the project does.)
	var hook := Node.new()
	hook.set_script(load("res://scripts/dialog_style.gd"))
	root.add_child(hook)
	await process_frame  # nodes added in _init only enter the tree on the first frame
	TestUtil.check(str(ProjectSettings.get_setting("autoload/DialogStyle")) == "*res://scripts/dialog_style.gd", "DialogStyle is registered as an autoload")

	# 1. The font files and their license ship with the game.
	for w in [500, 700]:
		TestUtil.check(FileAccess.file_exists("%s%d.otf" % [FAMILIES[0], w]), "Commit Mono %d is bundled" % w)
	for w in [300, 400, 500, 700]:
		TestUtil.check(FileAccess.file_exists("%s%d.ttf" % [FAMILIES[1], w]), "IBM Plex Sans %d is bundled" % w)
	var ofl := FileAccess.get_file_as_string("res://fonts/OFL.txt")
	var ofl_inter := FileAccess.get_file_as_string("res://fonts/OFL-IBMPlex.txt")
	TestUtil.check(ofl.contains("SIL OPEN FONT LICENSE Version 1.1") and ofl.contains("Eigil Nikolajsen") and ofl_inter.contains("SIL OPEN FONT LICENSE Version 1.1") and ofl_inter.contains("IBM Corp"), "the OFL license texts ship with the fonts (required by the license)")
	TestUtil.check(FileAccess.file_exists("res://fonts/README.txt"), "fonts/README.txt records the source")
	TestUtil.check(TestUtil.files(["res://fonts"], ["otf", "ttf", "woff", "woff2"]).size() == 6, "exactly the weights the theme uses are bundled")

	# 2. Nothing defines or overrides a font anywhere else.
	var scanned := 0
	for dir in ["res://scenes", "res://scripts"]:
		for path in TestUtil.files([dir], ["tscn", "tres", "gd"]):
			var text := FileAccess.get_file_as_string(path)
			scanned += 1
			for needle in ["SystemFont", "FontVariation", "theme_override_fonts", "load_dynamic_font", ".woff"]:
				TestUtil.check(not text.contains(needle), "%s contains '%s'" % [path, needle])
			if path != THEME and path != "res://scripts/ui_text.gd":
				TestUtil.check(not text.contains(".otf") and not text.contains(".ttf"), "%s references a font file directly; fonts belong in the theme" % path)
	TestUtil.check(scanned > 10, "scanned the project (%d files)" % scanned)

	# 3. The theme is the project-wide theme, and its fonts come from the bundle.
	TestUtil.check(ProjectSettings.get_setting("gui/theme/custom") == THEME, "the project theme is the global theme")
	TestUtil.check(str(ProjectSettings.get_setting("gui/theme/custom_font")) == "res://fonts/IBMPlexSans-400.ttf", "the global fallback font is IBM Plex Sans Regular")
	var fb := ThemeDB.fallback_font
	TestUtil.check(fb != null and fb.resource_path == "res://fonts/IBMPlexSans-400.ttf", "ThemeDB.fallback_font (used by custom drawing, e.g. the graph) is the bundled font, got '%s'" % (fb.resource_path if fb else ""))
	var theme: Theme = load(THEME)
	TestUtil.check(theme.default_font != null and theme.default_font.resource_path == "res://fonts/IBMPlexSans-400.ttf", "theme default font is Regular")
	TestUtil.check(theme.get_font("font", "Button").resource_path.ends_with("-400.ttf"), "buttons are Regular")
	TestUtil.check(theme.get_font("font", "Heading").resource_path.ends_with("-300.ttf") and theme.get_font("font", "Note").resource_path.ends_with("-300.ttf"), "headings and descriptions are Light")
	TestUtil.check(theme.get_font("font", "StatValue").resource_path.contains("CommitMono") and theme.get_font("font", "HistoryGraph").resource_path.contains("CommitMono"), "numbers (stat values, the graph) are in Commit Mono")
	TestUtil.check(theme.get_font("font", "Warning").resource_path.ends_with("-500.ttf"), "Medium is only for the warning")

	# 4. Every text control on every screen resolves to the bundled font.
	Session.free_start = StartConditions.new()
	var screens := {}
	Session.mode = Session.Mode.FREE
	screens["game(free)"] = load(Scenes.GAME).instantiate()
	screens["setup"] = load(Scenes.FREE_SETUP).instantiate()
	screens["menu"] = load("res://scenes/menu.tscn").instantiate()
	screens["intro"] = load("res://scenes/intro.tscn").instantiate()
	for k in screens:
		root.add_child(screens[k])
	await process_frame
	await process_frame
	for k in screens:
		_walk(screens[k], k)
	# Dialog windows and tooltips are separate windows; check them too.
	var dialog: ConfirmationDialog = screens["menu"].confirm
	_note("confirm dialog message", dialog.get_label().get_theme_font("font"))
	_note("confirm OK button", dialog.get_ok_button().get_theme_font("font"))
	_note("confirm cancel button", dialog.get_cancel_button().get_theme_font("font"))
	_note("dialog title", dialog.get_theme_font("title_font"))
	_note("tooltip", ThemeDB.get_project_theme().get_font("font", "TooltipLabel"))
	_note("number box field", screens["game(free)"].tool_options.nutrient_count_box.get_line_edit().get_theme_font("font"))

	# 5. The weights are used for their roles.
	var menu: Control = screens["menu"]
	TestUtil.check(menu.title.get_theme_font("font").resource_path.ends_with("-700.ttf"), "the game's name on the title screen is Bold")
	TestUtil.check(menu.new_button.get_theme_font("font").resource_path.ends_with("-400.ttf"), "menu buttons are Regular")
	TestUtil.check(menu.tagline.get_theme_font("font").resource_path.ends_with("-300.ttf"), "descriptive text is Light")
	
	# 6. Dialog: larger title, smaller button text in roomier buttons of about the same height.
	dialog.popup_centered()
	await create_timer(0.3).timeout
	var ok_button := dialog.get_ok_button()
	var title_size: int = (dialog.get_meta("header_label") as Label).get_theme_font_size("font_size")
	TestUtil.check(title_size >= 18, "dialog title is larger (%d)" % title_size)
	var sized := func(designed: int) -> int: return roundi(designed * UserSettings.text_factor())
	var message_size: int = dialog.get_label().get_theme_font_size("font_size")
	TestUtil.check(message_size == sized.call(16) and message_size <= title_size - 3, "dialog message is clearly smaller than the title (%d vs %d)" % [message_size, title_size])
	TestUtil.check(ok_button.get_theme_font_size("font_size") == sized.call(15) and ok_button.get_theme_font_size("font_size") < title_size, "dialog button text is smaller than the title (%d)" % ok_button.get_theme_font_size("font_size"))
	TestUtil.check(absf(ok_button.size.y - 47.0) <= 3.0, "dialog buttons keep about the same height (%.0f, was 47)" % ok_button.size.y)
	TestUtil.check(dialog.get_cancel_button().get_theme_font("font").resource_path.ends_with("-400.ttf"), "dialog buttons are Regular")
	dialog.hide()

	var parts := []
	for k in used:
		parts.append("%s x%d" % [k.get_file(), used[k]])
	TestUtil.finish(self, "FONTS TESTS OK  (%s)" % ", ".join(parts))
