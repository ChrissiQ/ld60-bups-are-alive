extends Node
## Run: godot --headless --path . res://tests/dialog_test.tscn
## (Run as a scene, not with -s: scripts run with -s don't start the project's autoloads.)
## Any dialog, created with no styling code at all, must come out in the game's dialog style.



## A designed font size as it comes out at the interface size there is (the theme multiplies every size by this).
func sized(designed: int) -> int:
	return roundi(designed * UserSettings.text_factor())


func _ready() -> void:
	var root := get_tree().root
	TestUtil.check(root.get_node_or_null("DialogStyle") != null, "the DialogStyle autoload is running")

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
		var header: Label = dialog.get_meta("header_label")
		TestUtil.check(dialog.borderless, "%s: no system title bar, so no part of the dialog can be dragged" % who)
		TestUtil.check(header.text == who and header.get_theme_font_size("font_size") == sized(20), "%s: the dialog draws its own title (designed 20)" % who)
		TestUtil.check(not dialog.has_meta("header_close") and header.position.x == 24.0 and header.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT, "%s: no cross (the buttons are the way out), and the title starts at the same left edge as the text" % who)
		var msg: Label = dialog.get_label()
		TestUtil.check(msg.theme_type_variation == &"DialogText" and msg.get_theme_font_size("font_size") == sized(16), "%s: message is designed 16" % who)
		TestUtil.check(msg.get_theme_font("font").resource_path.ends_with("-300.ttf"), "%s: message is Plex Light" % who)
		TestUtil.check(msg.position.y >= 56.0, "%s: body starts under the title (%.0fpx)" % [who, msg.position.y])
		var panel: StyleBoxFlat = dialog.get_theme_stylebox("panel")
		TestUtil.check(panel.bg_color.a >= 0.98 and panel.border_width_top == 1 and panel.content_margin_top >= 56.0, "%s: solid dark panel with a hairline border and room for the title" % who)
		var ok: Button = dialog.get_ok_button()
		TestUtil.check(ok.theme_type_variation == &"DialogPrimaryButton" and ok.get_theme_font_size("font_size") == sized(15), "%s: OK is the main button, designed 15" % who)
		TestUtil.check(ok.size.y >= 36.0 and ok.size.y <= 52.0, "%s: OK button height is about 40 to 48 (%.0f)" % [who, ok.size.y])
		TestUtil.check(ok.get_theme_font("font").resource_path.ends_with("-400.ttf"), "%s: buttons are Regular" % who)
	var cancel := confirm.get_cancel_button()
	TestUtil.check(cancel.theme_type_variation == &"DialogButton" and cancel.get_theme_font_size("font_size") == sized(15), "cancel button is styled")
	TestUtil.check(extra.theme_type_variation == &"DialogButton" and extra.get_theme_font_size("font_size") == sized(15), "a button added later with add_button() is styled too")

	# Short button texts are not left as stubs, and the text sits in the middle; a longer text is not cut or changed.
	var yes_no := ConfirmationDialog.new()
	yes_no.ok_button_text = "Yes"
	yes_no.cancel_button_text = "No"
	yes_no.dialog_text = "Short buttons."
	var long_text := ConfirmationDialog.new()
	long_text.ok_button_text = "A rather long button text indeed"
	long_text.cancel_button_text = "No"
	long_text.dialog_text = "A long one."
	add_child(yes_no)
	add_child(long_text)
	await get_tree().process_frame
	plain.hide()
	confirm.hide()
	yes_no.popup_centered()
	await get_tree().create_timer(0.4).timeout
	var minimum: float = yes_no.get_theme_constant("buttons_min_width")
	TestUtil.check(minimum >= 96.0 and yes_no.get_ok_button().size.x >= minimum - 0.5 and yes_no.get_cancel_button().size.x >= minimum - 0.5, "Yes and No are at least %.0f wide (%.0f, %.0f)" % [minimum, yes_no.get_ok_button().size.x, yes_no.get_cancel_button().size.x])
	TestUtil.check(yes_no.get_ok_button().alignment == HORIZONTAL_ALIGNMENT_CENTER, "the text sits in the middle of the button")
	yes_no.hide()
	long_text.popup_centered()
	await get_tree().create_timer(0.4).timeout
	TestUtil.check(long_text.get_ok_button().size.x > minimum, "a longer text makes its button wider than the minimum (%.0f)" % long_text.get_ok_button().size.x)

	# The space between the message and the buttons is the same whatever the message's length.
	var gaps: Array[float] = []
	for message in ["One line.", "Several lines: a much longer text that wraps around onto more lines of the dialog, and then it goes on a little longer still, so that it takes up at least three lines in all.", "A long text again. " .repeat(30)]:
		var spaced := ConfirmationDialog.new()
		spaced.dialog_text = message
		spaced.dialog_autowrap = true
		add_child(spaced)
		await get_tree().process_frame
		spaced.popup_centered(Vector2i(460, 130))
		await get_tree().create_timer(0.4).timeout
		var text_rect := spaced.get_label().get_global_rect()
		gaps.append(spaced.get_ok_button().get_global_rect().position.y - (text_rect.end.y - spaced.get_label().get_theme_stylebox("normal").get_minimum_size().y))  # (the label ends its padding below its text: that is the space)
		spaced.hide()
		spaced.queue_free()
		await get_tree().process_frame
	TestUtil.check(absf(gaps[0] - gaps[1]) < 1.5 and absf(gaps[0] - gaps[2]) < 1.5, "the space between the message and the buttons does not change with the message's length (%s)" % [gaps])

	# Dialogs already in the tree when the game starts (the first scene's: nothing announces them) are styled by a sweep.
	var early := ConfirmationDialog.new()
	add_child(early)
	await get_tree().process_frame
	early.get_label().theme_type_variation = &""  # (as if the autoload had never seen it)
	early.get_ok_button().theme_type_variation = &""
	DialogStyle.style_existing(get_tree().root)
	TestUtil.check(early.get_label().theme_type_variation == &"DialogText" and early.get_ok_button().theme_type_variation == &"DialogPrimaryButton", "a dialog that was already in the tree gets styled by the start-up sweep")
	early.queue_free()

	# Widgets inside a dialog's own content are not touched.
	var holder := AcceptDialog.new()
	var inner := Button.new()
	inner.text = "inside"
	holder.add_child(inner)
	add_child(holder)
	await get_tree().process_frame
	TestUtil.check(inner.theme_type_variation == &"", "a button in the dialog's content is left alone")

	TestUtil.finish(get_tree(), "DIALOG TESTS OK")
