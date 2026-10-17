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


func _on_node_added(node: Node) -> void:
	if node is AcceptDialog:
		apply(node)
	elif node is Button:
		# Buttons added later with add_button() / add_cancel_button() land in the dialog's
		# own button row; style those too, but not widgets a dialog's content might hold.
		var dialog := _owning_dialog(node)
		if dialog != null and node.get_parent() == dialog.get_ok_button().get_parent():
			node.theme_type_variation = BUTTON_VARIATION


static func apply(dialog: AcceptDialog) -> void:
	dialog.get_label().theme_type_variation = TEXT_VARIATION
	dialog.get_ok_button().theme_type_variation = BUTTON_VARIATION
	if dialog is ConfirmationDialog:
		dialog.get_cancel_button().theme_type_variation = BUTTON_VARIATION


static func _owning_dialog(node: Node) -> AcceptDialog:
	var n := node.get_parent()
	while n != null and not (n is Window):
		n = n.get_parent()
	return n as AcceptDialog
