extends Node
## Run: godot --headless --path . res://tests/dialog_test.tscn
## (Run as a scene, not with -s: scripts run with -s don't start the project's autoloads.)
## Any dialog, created with no styling code at all, must come out in the game's dialog style.

var failures: Array = []


func check(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)


func _ready() -> void:
	var root := get_tree().root
	check(root.get_node_or_null("DialogStyle") != null, "the DialogStyle autoload is running")

	# Brand-new dialogs, created the plain way, never touched by any styling code.
	var plain := AcceptDialog.new()
	plain.title = "Plain"
	plain.dialog_text = "A plain accept dialog."
	var confirm := ConfirmationDialog.new()
	confirm.title = "Confirm"
	confirm.dialog_text = "A confirmation dialog with an extra button."
	var extra := confirm.add_button("Maybe", false, "maybe")  # added after creation
	add_child(plain)
	add_child(confirm)
	await get_tree().process_frame
	plain.popup_centered()
	confirm.popup_centered()
	await get_tree().create_timer(0.4).timeout

	for dialog in [plain, confirm]:
		var who: String = dialog.title
		check(dialog.get_theme_font_size("title_font_size") == 24, "%s: title is 24px" % who)
		check(dialog.get_theme_constant("title_height") == 44, "%s: title bar is 44px" % who)
		var msg: Label = dialog.get_label()
		check(msg.theme_type_variation == &"DialogText" and msg.get_theme_font_size("font_size") == 16, "%s: message is 16px" % who)
		check(msg.get_theme_font("font").resource_path.ends_with("-500.otf"), "%s: message is Commit Mono Medium" % who)
		check(msg.position.y >= 20.0, "%s: body has padding under the title (%.0fpx)" % [who, msg.position.y])
		var border: StyleBoxFlat = dialog.get_theme_stylebox("embedded_border")
		check(border.bg_color == Color(0.25, 0.25, 0.25), "%s: grey border" % who)
		var panel: StyleBoxFlat = dialog.get_theme_stylebox("panel")
		check(panel.bg_color == Color(0.25, 0.25, 0.25) and panel.content_margin_top >= 20.0, "%s: grey panel with title padding" % who)
		var ok: Button = dialog.get_ok_button()
		check(ok.theme_type_variation == &"DialogButton" and ok.get_theme_font_size("font_size") == 16, "%s: OK button is 16px" % who)
		check(absf(ok.size.y - 41.0) <= 3.0, "%s: OK button height ~41 (%.0f)" % [who, ok.size.y])
		check(ok.get_theme_font("font").resource_path.ends_with("-600.otf"), "%s: buttons are SemiBold" % who)
	var cancel := confirm.get_cancel_button()
	check(cancel.theme_type_variation == &"DialogButton" and cancel.get_theme_font_size("font_size") == 16, "cancel button is styled")
	check(extra.theme_type_variation == &"DialogButton" and extra.get_theme_font_size("font_size") == 16, "a button added later with add_button() is styled too")

	# Widgets inside a dialog's own content are not touched.
	var holder := AcceptDialog.new()
	var inner := Button.new()
	inner.text = "inside"
	holder.add_child(inner)
	add_child(holder)
	await get_tree().process_frame
	check(inner.theme_type_variation == &"", "a button in the dialog's content is left alone")

	if failures.is_empty():
		print("DIALOG TESTS OK")
	else:
		print("FAILED:")
		for f in failures:
			print("  - ", f)
	get_tree().quit(0 if failures.is_empty() else 1)
