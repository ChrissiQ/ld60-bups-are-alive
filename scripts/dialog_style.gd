extends Node
## Gives every dialog the game's dialog style automatically (autoload "DialogStyle").
##
## To make a dialog, just create an AcceptDialog or ConfirmationDialog. Do not set fonts,
## sizes or button styles on it. The look comes from two places that never need touching
## per dialog:
##   - scenes/menu_theme.tres: title size and bar, the grey border, the body padding.
##   - this script: the theme type variations for the message and the buttons, which the
##     engine creates internally and a theme cannot target on its own.
## To change how every dialog looks, change the theme or this script, never a single dialog.
## tests/dialog_test.tscn fails if a plain dialog comes out unstyled.

const TEXT_VARIATION := &"DialogText"
const BUTTON_VARIATION := &"DialogButton"


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	# The game's first scene is already in the tree by now (nothing told us as it came in), so style the dialogs it holds.
	style_existing(get_tree().root)


func _on_node_added(node: Node) -> void:
	if node is AcceptDialog:
		apply(node)
	elif node is Button:
		# Buttons added later with add_button() / add_cancel_button() land in the dialog's
		# own button row; style those too, but not widgets a dialog's content might hold.
		var dialog := _owning_dialog(node)
		if dialog != null and node.get_parent() == dialog.get_ok_button().get_parent():
			node.theme_type_variation = BUTTON_VARIATION


## Styles every dialog already under `node`.
static func style_existing(node: Node) -> void:
	if node is AcceptDialog:
		apply(node)
	for dialog in node.find_children("*", "AcceptDialog", true, false):
		apply(dialog)


static func apply(dialog: AcceptDialog) -> void:
	if not dialog.has_meta("wanted_width"):
		dialog.set_meta("wanted_width", dialog.size.x)  # (the width the scene gave it: a window only ever grows to fit its first, unfinished texts, so this is how it is brought back)
	dialog.min_size = Vector2i(dialog.size.x, dialog.min_size.y)  # (a scene gives a dialog its width: keep it, so the message wraps at that width from the first layout and the height follows the lines)
	var rewiden := _restore_width.bind(dialog)
	if not dialog.about_to_popup.is_connected(rewiden):
		dialog.about_to_popup.connect(rewiden)
	var refit := _fit_height.bind(dialog)
	if not dialog.visibility_changed.is_connected(refit):  # (a dialog can be styled again: by the sweep and by its coming into the tree)
		dialog.visibility_changed.connect(refit)
	dialog.get_label().theme_type_variation = TEXT_VARIATION
	dialog.get_ok_button().theme_type_variation = BUTTON_VARIATION
	if dialog is ConfirmationDialog:
		dialog.get_cancel_button().theme_type_variation = BUTTON_VARIATION
	_settle_width(dialog)


## The window widens to fit its first, unfinished texts (a scene's own keys, before they are swapped for the real words)
## and never narrows again on its own: bring it back to the width the scene gave it, before anyone opens it.
static func _settle_width(dialog: AcceptDialog) -> void:
	if await _wait_frames(dialog, 4) and not dialog.visible:
		_restore_width(dialog)
		dialog.move_to_center()
		dialog.get_label().update_minimum_size()  # (a hidden dialog keeps the height it was first laid out at, for fewer lines than its text takes; this has it counted again, so that it opens at its full height)


static func _wanted_width(dialog: AcceptDialog) -> int:
	return dialog.get_meta("wanted_width", dialog.size.x)


## Waits `frames` frames; false if the dialog has gone from the tree in the meantime.
static func _wait_frames(dialog: AcceptDialog, frames: int) -> bool:
	for frame in frames:
		if not is_instance_valid(dialog) or not dialog.is_inside_tree():
			return false
		await dialog.get_tree().process_frame
	return is_instance_valid(dialog)


static func _restore_width(dialog: AcceptDialog) -> void:
	dialog.size = Vector2i(_wanted_width(dialog), dialog.size.y)


## A message that wraps is laid out only once the dialog is open, so the height it first got is for fewer lines than it
## needs: shrink the window to its content again once it has wrapped, so the space under the message is always the same.
static func _fit_height(dialog: AcceptDialog) -> void:
	if not dialog.visible:
		return
	if await _wait_frames(dialog, 2) and dialog.visible:
		dialog.size = Vector2i(_wanted_width(dialog), 0)
		dialog.move_to_center()  # (it was centred when it opened, at whatever size it had then)


static func _owning_dialog(node: Node) -> AcceptDialog:
	var n := node.get_parent()
	while n != null and not (n is Window):
		n = n.get_parent()
	return n as AcceptDialog
