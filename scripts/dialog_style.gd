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
const TITLE_VARIATION := &"DialogTitle"
const DANGER_VARIATION := &"DialogDangerButton"
const PRIMARY_VARIATION := &"DialogPrimaryButton"
const TITLE_TOP := 20.0  ## the title's line starts here: its letters then sit PAD from the top (a line is taller than its capitals)
const TITLE_GAP := 8.0  ## between the title's line and the message (the panel's top margin is the title's line and this: see UserSettings, which makes it as tall as the title's text needs)
const PAD := 24.0  ## the space at the sides: the title and the text under it start here
const SCRIM_VARIATION := &"Scrim"  ## the shade over everything else while a dialog is open
const SCRIM_LAYER := 100
const PREPARE_FRAMES := 2  ## frames a dialog is given to settle before it is prepared


static var _scrim: Panel  ## shown while any dialog is open: the screen behind it is dimmed, so the dialog is what is looked at
static var _shown: Array[AcceptDialog] = []  ## the dialogs open now


func _ready() -> void:
	var layer := CanvasLayer.new()
	layer.layer = SCRIM_LAYER  # (dialogs are windows on top of every layer: the shade goes under them and over the rest)
	add_child(layer)
	_scrim = Panel.new()
	_scrim.theme_type_variation = SCRIM_VARIATION
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.visible = false
	layer.add_child(_scrim)
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
	dialog.min_size = Vector2i(dialog.size.x, dialog.min_size.y)  # (a scene gives a dialog its width: keep it, so the message wraps at that width from the first layout and the height follows the lines)
	var refit := _fit_height.bind(dialog)
	var shade := _shade_for.bind(dialog)
	if not dialog.visibility_changed.is_connected(shade):
		dialog.visibility_changed.connect(shade)
		dialog.tree_exiting.connect(func() -> void: _shown.erase(dialog); _sync_scrim())
	if not dialog.visibility_changed.is_connected(refit):  # (a dialog can be styled again: by the sweep and by its coming into the tree)
		dialog.visibility_changed.connect(refit)
	dialog.borderless = true  # (no system title bar: it is the one part of a dialog that can be dragged)
	dialog.transparent_bg = true  # (the panel is rounded: without this the window's own black shows in its corners)
	dialog.transparent = true
	_add_header(dialog)
	dialog.get_label().theme_type_variation = TEXT_VARIATION
	_style_buttons(dialog)
	if not dialog.about_to_popup.is_connected(_style_buttons.bind(dialog)):
		dialog.about_to_popup.connect(_style_buttons.bind(dialog))
	_prepare(dialog)


## A dialog that is not showing is laid out with its message across the window's full width, so it counts fewer lines than
## it has once it is open, and would open that much too short and then grow. Having it count again once it has settled
## (and been put back to the scene's width and centred) makes it open at its full size.
static func _prepare(dialog: AcceptDialog) -> void:
	if await _wait_frames(dialog, PREPARE_FRAMES) and not dialog.visible:
		dialog.size = Vector2i(dialog.min_size.x, dialog.size.y)  # (the window widens while it is first laid out, and never narrows again on its own: bring it back to the width the scene gave it)
		dialog.move_to_center()
		dialog.get_label().update_minimum_size()


## The dialog's own title, drawn over the strip the panel leaves free along the top, at the left like the text under it. A dialog has no cross: its
## buttons are the way out (Escape is the one of them that is not asked for). The label is top-level so the dialog does not lay it out as its content.
static func _add_header(dialog: AcceptDialog) -> void:
	if dialog.has_meta("header_label"):
		return
	var title := Label.new()
	title.top_level = true
	title.theme_type_variation = TITLE_VARIATION
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dialog.add_child(title)
	dialog.set_meta("header_label", title)
	var layout := _layout_header.bind(dialog)
	dialog.size_changed.connect(layout)
	dialog.visibility_changed.connect(layout)


static func _layout_header(dialog: AcceptDialog) -> void:
	var title: Label = dialog.get_meta("header_label")
	title.text = dialog.title
	title.position = Vector2(PAD, TITLE_TOP)
	title.size = Vector2(dialog.size.x - 2.0 * PAD, title.get_combined_minimum_size().y)  # (the line is as tall as the title's text is)


## The buttons sit together at the right, as wide as their words need (the engine centres them and spreads them out with spacers), and a choice that
## cannot be undone (the dialog's `destructive` meta, set in its scene) has its OK button in the danger colour.
static func _style_buttons(dialog: AcceptDialog) -> void:
	var row := dialog.get_ok_button().get_parent() as BoxContainer
	if row == null:
		return
	var seen_spacer := false
	for child in row.get_children():
		if child is Button:
			(child as Button).size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		elif child is Control:
			(child as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL if not seen_spacer else Control.SIZE_SHRINK_BEGIN
			seen_spacer = true
	# The safe way on is the one that stands out: OK is the main button (it is the danger colour when it cannot be undone, and then the cancel button is the main one).
	var destructive: bool = dialog.get_meta("destructive", false)
	dialog.get_ok_button().theme_type_variation = DANGER_VARIATION if destructive else PRIMARY_VARIATION
	if dialog is ConfirmationDialog:
		dialog.get_cancel_button().theme_type_variation = PRIMARY_VARIATION if destructive else BUTTON_VARIATION


## Keeps the shade over the screen exactly while some dialog is open.
static func _shade_for(dialog: AcceptDialog) -> void:
	if dialog.visible and not _shown.has(dialog):
		_shown.append(dialog)
	elif not dialog.visible:
		_shown.erase(dialog)
	_sync_scrim()


static func _sync_scrim() -> void:
	if _scrim != null and is_instance_valid(_scrim):
		_scrim.visible = not _shown.is_empty()


## Waits `frames` frames; false if the dialog has gone from the tree in the meantime.
static func _wait_frames(dialog: AcceptDialog, frames: int) -> bool:
	for frame in frames:
		if not is_instance_valid(dialog) or not dialog.is_inside_tree():
			return false
		await dialog.get_tree().process_frame
	return is_instance_valid(dialog)


## A message that wraps is laid out only once the dialog is open, so the height it first got is for fewer lines than it
## needs: shrink the window to its content again once it has wrapped, so the space under the message is always the same.
static func _fit_height(dialog: AcceptDialog) -> void:
	if not dialog.visible:
		return
	if await _wait_frames(dialog, 2) and dialog.visible:
		dialog.size = Vector2i(dialog.min_size.x, 0)
		dialog.move_to_center()  # (it was centred when it opened, at whatever size it had then)


static func _owning_dialog(node: Node) -> AcceptDialog:
	var n := node.get_parent()
	while n != null and not (n is Window):
		n = n.get_parent()
	return n as AcceptDialog
