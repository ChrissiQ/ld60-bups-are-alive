class_name FreezerShelf
extends VBoxContainer
## What is inside the tray's "Freezer" section: the buttons that freeze or trash the dish in view, a note while nothing is frozen, and a row for each frozen dish (its picture,
## its number and bups, and icon buttons to unfreeze it, show what is known of it or trash it). The section itself is a plain TraySection that holds this as its content. It keeps
## the frozen dishes (`entries`, in the order they went in): {number, data (Dish.to_dict), picture (a texture), bups}. The screen does the freezing, thawing and trashing; this
## only holds and shows.

const UNFREEZE_ICON := preload("res://icons/unfreeze.svg")
const INFO_ICON := preload("res://icons/info.svg")
const TRASH_ICON := preload("res://icons/trash.svg")
const PICTURE_SIZE := 40.0

signal freeze_requested
signal trash_requested
signal thaw_requested(entry: Dictionary)
signal trash_entry_requested(entry: Dictionary)

@onready var actions: DishActions = %FreezerActions  ## freeze or trash the dish in the main view
@onready var empty_note: Label = %FreezerEmpty
@onready var list: VBoxContainer = %FreezerList

var entries: Array[Dictionary] = []
var _shown_info: Array[Dictionary] = []  ## the entries whose details are open


func _ready() -> void:
	actions.freeze_requested.connect(freeze_requested.emit)
	actions.trash_requested.connect(trash_requested.emit)
	refresh()


func add(entry: Dictionary) -> void:
	entries.append(entry)
	refresh()


func remove(entry: Dictionary) -> void:
	entries.erase(entry)
	_shown_info.erase(entry)
	refresh()


func refresh() -> void:
	Nodes.clear_children(list)
	for entry in entries:
		list.add_child(_row(entry))
	empty_note.visible = entries.is_empty()


func _row(entry: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.theme_type_variation = &"TightStack"
	var row := HBoxContainer.new()
	row.name = "Row"
	box.add_child(row)
	var picture := TextureRect.new()
	picture.texture = entry["picture"]
	picture.custom_minimum_size = Vector2(PICTURE_SIZE, PICTURE_SIZE)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(picture)
	var caption := Label.new()
	caption.text = Strings.t("hud.frozen_row", [entry["number"], UiText.thousands(entry["bups"])])
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(caption)
	row.add_child(_icon_button("Unfreeze", UNFREEZE_ICON, Strings.t("hud.unfreeze_tip"), thaw_requested.emit.bind(entry)))
	row.add_child(_icon_button("Info", INFO_ICON, Strings.t("hud.frozen_info_tip"), _toggle_info.bind(entry)))
	row.add_child(_icon_button("Trash", TRASH_ICON, Strings.t("hud.frozen_trash_tip"), trash_entry_requested.emit.bind(entry)))
	var details := Label.new()
	details.name = "Details"
	details.theme_type_variation = &"Note"
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.text = Strings.t("hud.frozen_info", [SimClock.format(float(entry["data"].get("time", 0.0))), UiText.thousands(entry["bups"])])
	details.visible = _shown_info.has(entry)
	box.add_child(details)
	return box


func _icon_button(button_name: String, icon: Texture2D, tip: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = button_name
	button.theme_type_variation = &"IconButton"
	button.icon = icon
	button.tooltip_text = tip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button


func _toggle_info(entry: Dictionary) -> void:
	if _shown_info.has(entry):
		_shown_info.erase(entry)
	else:
		_shown_info.append(entry)
	refresh()
