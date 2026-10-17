extends SceneTree
## Run: godot --headless --path . -s tests/fonts_test.gd
## The whole game is set in one bundled typeface (Commit Mono), in different weights.
## Nothing may use a system font, define its own font, or override the theme's fonts.

const THEME := "res://scenes/menu_theme.tres"
const FAMILY := "res://fonts/CommitMono-"
var failures: Array = []
var used := {}  ## font resource path -> how many text controls use it


func check(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)


func _files(dir: String, exts: Array) -> Array:
	var out := []
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() in exts:
			out.append(dir.path_join(f))
	return out


func _note(who: String, font: Font) -> void:
	var path := font.resource_path if font != null else "(none)"
	check(font is FontFile and path.begins_with(FAMILY), "%s uses %s instead of the bundled font" % [who, path])
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
	check(str(ProjectSettings.get_setting("autoload/DialogStyle")) == "*res://scripts/dialog_style.gd", "DialogStyle is registered as an autoload")

	# 1. The font files and their license ship with the game.
	for w in [400, 500, 600, 700]:
		check(FileAccess.file_exists("%s%d.otf" % [FAMILY, w]), "weight %d is bundled" % w)
	var ofl := FileAccess.get_file_as_string("res://fonts/OFL.txt")
	check(ofl.contains("SIL OPEN FONT LICENSE Version 1.1") and ofl.contains("Eigil Nikolajsen"), "the OFL license text ships with the fonts (required by the license)")
	check(FileAccess.file_exists("res://fonts/README.txt"), "fonts/README.txt records the source")
	check(_files("res://fonts", ["otf", "ttf", "woff", "woff2"]).size() == 4, "exactly the four Commit Mono weights are bundled")

	# 2. Nothing defines or overrides a font anywhere else.
	var scanned := 0
	for dir in ["res://scenes", "res://scripts"]:
		for path in _files(dir, ["tscn", "tres", "gd"]):
			var text := FileAccess.get_file_as_string(path)
			scanned += 1
			for needle in ["SystemFont", "FontVariation", "theme_override_fonts", "load_dynamic_font", ".ttf", ".woff"]:
				check(not text.contains(needle), "%s contains '%s'" % [path, needle])
			if path != THEME and path != "res://scripts/ui_text.gd":
				check(not text.contains(".otf"), "%s references a font file directly; fonts belong in the theme" % path)
	check(scanned > 10, "scanned the project (%d files)" % scanned)

	# 3. The theme is the project-wide theme, and its fonts come from the bundle.
	check(ProjectSettings.get_setting("gui/theme/custom") == THEME, "the project theme is the global theme")
	check(str(ProjectSettings.get_setting("gui/theme/custom_font")) == "res://fonts/CommitMono-500.otf", "the global fallback font is Commit Mono Medium")
	var fb := ThemeDB.fallback_font
	check(fb != null and fb.resource_path == "res://fonts/CommitMono-500.otf", "ThemeDB.fallback_font (used by custom drawing, e.g. the graph) is the bundled font, got '%s'" % (fb.resource_path if fb else ""))
	var theme: Theme = load(THEME)
	check(theme.default_font != null and theme.default_font.resource_path == "res://fonts/CommitMono-500.otf", "theme default font is Medium")
	check(theme.get_font("font", "Button").resource_path.ends_with("-600.otf"), "buttons are SemiBold")
	check(theme.get_font("font", "Heading").resource_path.ends_with("-700.otf"), "headings are Bold")

	# 4. Every text control on every screen resolves to the bundled font.
	Session.free_start = StartConditions.new()
	var screens := {}
	Session.mode = Session.Mode.FREE
	screens["game(free)"] = load("res://scenes/main.tscn").instantiate()
	screens["setup"] = load("res://scenes/free_setup.tscn").instantiate()
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
	check(menu.get_node("Title").get_theme_font("font").resource_path.ends_with("-700.otf"), "the title is Bold")
	check(menu.new_button.get_theme_font("font").resource_path.ends_with("-600.otf"), "menu buttons are SemiBold")
	check(menu.tagline.get_theme_font("font").resource_path.ends_with("-500.otf"), "body text is Medium")
	check(screens["game(free)"].pause_ring.get_node("PausedLabel").get_theme_font("font").resource_path.ends_with("-700.otf"), "PAUSED is Bold")

	# 6. Dialog: larger title, smaller button text in roomier buttons of about the same height.
	dialog.popup_centered()
	await create_timer(0.3).timeout
	var ok_button := dialog.get_ok_button()
	check(dialog.get_theme_font_size("title_font_size") >= 22, "dialog title is larger (%d)" % dialog.get_theme_font_size("title_font_size"))
	var message_size: int = dialog.get_label().get_theme_font_size("font_size")
	check(message_size == 16 and message_size < dialog.get_theme_font_size("title_font_size") - 6, "dialog message is clearly smaller than the title (%d vs %d)" % [message_size, dialog.get_theme_font_size("title_font_size")])
	check(ok_button.get_theme_font_size("font_size") <= 17 and ok_button.get_theme_font_size("font_size") >= 14, "dialog button text is smaller (%d)" % ok_button.get_theme_font_size("font_size"))
	check(absf(ok_button.size.y - 41.0) <= 3.0, "dialog buttons keep about the same height (%.0f, was 41)" % ok_button.size.y)
	check(dialog.get_cancel_button().get_theme_font("font").resource_path.ends_with("-600.otf"), "dialog buttons are still SemiBold")
	var border: StyleBoxFlat = dialog.get_theme_stylebox("embedded_border")
	check(border.bg_color == Color(0.25, 0.25, 0.25) and is_equal_approx(border.expand_margin_top, dialog.get_theme_constant("title_height") - 4.0), "dialog keeps its grey, with the bar grown to fit the larger title (expand %.0f, title bar %d)" % [border.expand_margin_top, dialog.get_theme_constant("title_height")])
	dialog.hide()

	if failures.is_empty():
		var parts := []
		for k in used:
			parts.append("%s x%d" % [k.get_file(), used[k]])
		print("FONTS TESTS OK  (%s)" % ", ".join(parts))
	else:
		print("FAILED:")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)
