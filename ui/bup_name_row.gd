class_name BupNameRow
extends HBoxContainer
## A bup's name with a pencil to rename it. To show a bup's name in a panel, put this row in it and call
## `show_bup(dish, id, can_rename)` every frame the bup is shown. The row asks the dish for the name itself, so
## a panel can't show anything but what the rest of the game calls the bup (never build a name by hand: see
## BupNames). Renaming asks the dish too, so a new name appears in every row at once. Escape while typing
## cancels; Enter, or clicking away, keeps the name; an empty name goes back to the bup's number.

@onready var swatch: ColorRect = $Swatch  ## the bup's colour: shown for a dead bup, which can no longer be seen in the dish
@onready var name_label: Label = $Name
@onready var edit: LineEdit = $Edit
@onready var rename_button: Button = $Rename

var editing: bool:
	get:
		return edit.visible

var _dish: Dish = null
var _id := -1
var _finishing := false  ## true while typing is being ended, so losing focus doesn't count as a second commit


func _ready() -> void:
	edit.max_length = BupNames.MAX_LENGTH
	rename_button.pressed.connect(_begin_editing)
	rename_button.focus_mode = Control.FOCUS_NONE
	edit.text_submitted.connect(_commit)
	edit.focus_exited.connect(_on_focus_lost)
	edit.gui_input.connect(_on_edit_input)
	_show_label()


func show_bup(dish: Dish, id: int, can_rename: bool) -> void:
	if dish != _dish or id != _id:
		cancel_editing()
		_dish = dish
		_id = id
	var shown := dish.bup_display(id)
	name_label.text = shown.get("name", "")
	swatch.visible = not shown.get("alive", true)  # (a dead bup can't be seen in the dish, so its colour is shown here)
	if swatch.visible:
		swatch.color = shown["color"]
	rename_button.visible = can_rename and not editing


func cancel_editing() -> void:
	if editing:
		_finish()


func _begin_editing() -> void:
	if _dish == null or not _dish.has_record(_id):
		return
	edit.text = _dish.bup_custom_name(_id)
	edit.placeholder_text = _dish.bup_default_name(_id)
	name_label.visible = false
	rename_button.visible = false
	edit.visible = true
	edit.grab_focus()
	edit.select_all()


func _commit(text: String) -> void:
	if not editing or _finishing:
		return
	if _dish != null:
		_dish.rename_bup(_id, text)
		name_label.text = _dish.bup_name(_id)
	_finish()


func _finish() -> void:
	_finishing = true
	edit.visible = false
	edit.release_focus()
	_finishing = false
	_show_label()


func _show_label() -> void:
	name_label.visible = true
	rename_button.visible = _dish != null and _dish.has_record(_id)


func _on_focus_lost() -> void:
	if editing and not _finishing:
		_commit(edit.text)


func _on_edit_input(event: InputEvent) -> void:
	if UiInput.is_escape_press(event):
		edit.accept_event()  # so Escape doesn't also let go of the selection or open the menu
		cancel_editing()
