class_name FreezerShelf
extends VBoxContainer
## What is inside the tray's "Freezer" section: the buttons that freeze or trash the dish in view, a note while nothing is frozen, and a button for each frozen dish (its picture and
## number; a click asks for it to be unfrozen). The section itself is a plain TraySection that holds this as its content. It keeps the frozen dishes (`entries`, in the order
## they went in): {number, data (Dish.to_dict), picture (a texture), bups}. The screen does the freezing and thawing; this only holds and shows.

signal freeze_requested
signal trash_requested
signal thaw_requested(entry: Dictionary)

@onready var actions: DishActions = %FreezerActions  ## freeze or trash the dish in the main view
@onready var empty_note: Label = %FreezerEmpty
@onready var flow: HFlowContainer = %FreezerFlow

var entries: Array[Dictionary] = []


func _ready() -> void:
	actions.freeze_requested.connect(freeze_requested.emit)
	actions.trash_requested.connect(trash_requested.emit)
	refresh()


func add(entry: Dictionary) -> void:
	entries.append(entry)
	refresh()


func remove(entry: Dictionary) -> void:
	entries.erase(entry)
	refresh()


func refresh() -> void:
	Nodes.clear_children(flow)
	for entry in entries:
		var button := Button.new()
		button.theme_type_variation = &"PictureButton"
		button.icon = entry["picture"]
		button.text = Strings.t("dishes.caption", [entry["number"]])
		button.tooltip_text = Strings.t("hud.unfreeze_tip", [entry["number"], UiText.thousands(entry["bups"])])
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(thaw_requested.emit.bind(entry))
		flow.add_child(button)
	empty_note.visible = entries.is_empty()
