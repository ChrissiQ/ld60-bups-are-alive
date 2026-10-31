class_name BupNameRow
extends HBoxContainer
## A bup's name with a pencil to rename it. To show a bup's name in a panel, put this row in it and call
## `show_bup(dish, id, can_rename)` every frame the bup is shown. The row asks the dish for the name itself, so
## a panel can't show anything but what the rest of the game calls the bup (never build a name by hand: see
## BupNames). Renaming asks the dish too, so a new name appears in every row at once. Escape while typing
## cancels; Enter, or clicking away, keeps the name; an empty name goes back to the bup's number. The name itself is a text field
## made to look like a label: clicking it puts a caret in it, so a name too long for the row can be read with the arrow keys (or by
## dragging a selection), and nothing can be typed into it; leaving it puts the name back at its start.

@onready var swatch: BupPicture = $Swatch  ## a picture of the bup, in its colour and the shape its size gene gives it (a dead bup can no longer be seen in the dish, and has the picture it had)
@onready var name_label: LineEdit = $Name  ## the name, shown like a label but a field (see above): it has a caret, and `_on_name_input` lets no key change the text (a field that is not editable shows no caret)
@onready var edit: LineEdit = $Edit
@onready var rename_button: Button = $Rename

var editing: bool:
	get:
		return edit.visible

var _dish: Dish = null
var _id := -1
var _shown_name := ""  ## the name the field stands for (a number-bearing default name may be shown cut short with an ellipsis)
var _finishing := false  ## true while typing is being ended, so losing focus doesn't count as a second commit


func _ready() -> void:
	edit.max_length = BupNames.MAX_LENGTH
	rename_button.pressed.connect(_begin_editing)
	rename_button.focus_mode = Control.FOCUS_NONE
	edit.text_submitted.connect(_commit)
	edit.focus_exited.connect(_on_focus_lost)
	edit.gui_input.connect(_on_edit_input)
	name_label.gui_input.connect(_on_name_input)
	name_label.focus_exited.connect(_rewind_name)
	name_label.resized.connect(_fit_name)
	_show_label()


func show_bup(dish: Dish, id: int, can_rename: bool) -> void:
	if dish != _dish or id != _id:
		cancel_editing()
		_dish = dish
		_id = id
		_rewind_name()
	var shown := dish.bup_display(id)
	var shown_name: String = shown.get("name", "")
	if _shown_name != shown_name:  # (a field's text is only set when it changes: setting it, even to the same text, puts the caret and the scroll back at the start)
		_shown_name = shown_name
		name_label.tooltip_text = ""
		_fit_name()
	swatch.show_info(shown["info"])
	rename_button.visible = can_rename and not editing


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and is_node_ready():
		_fit_name.call_deferred()  # (the field's font changes with the interface size, after the field was last measured)


## The name in the field. A default name ("lil bup #1,234,567") that is wider than the field ends in an ellipsis, with the whole name on hover, so
## the number is never cut in the middle; a name the player gave is shown whole and read with the arrow keys.
func _fit_name() -> void:
	var text := _shown_name
	if _dish != null and _id >= 0 and _dish.bup_custom_name(_id) == "" and name_label.size.x > 0.0:
		var font := name_label.get_theme_font("font")
		var font_size := name_label.get_theme_font_size("font_size")
		var room := name_label.size.x - name_label.get_theme_stylebox("normal").get_minimum_size().x - 2.0
		var cut := text
		while cut.length() > 1 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > room:
			cut = cut.left(cut.length() - 1)
			text = cut.strip_edges() + "\u2026"
		name_label.tooltip_text = _shown_name if text != _shown_name else ""
	if name_label.text != text:
		name_label.text = text


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
		_shown_name = _dish.bup_name(_id)
		_fit_name()
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


## The name field takes the keys that move the caret, select and copy (and Escape, which leaves it); anything else is eaten, so that
## no key types, deletes or pastes (and so the game's own shortcuts are not set off while it has the keyboard).
func _on_name_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	var key: InputEventKey = event
	if key.keycode == KEY_ESCAPE:
		name_label.accept_event()
		name_label.release_focus()
		return
	if not lets_through(key):
		name_label.accept_event()


## Whether the name field takes this key: the ones that move the caret or the focus, and select all and copy.
static func lets_through(key: InputEventKey) -> bool:
	var moves := key.keycode in [KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_TAB]
	var copies := (key.ctrl_pressed or key.meta_pressed) and key.keycode in [KEY_A, KEY_C, KEY_INSERT]
	return moves or copies


## Back to the start of the name, nothing selected (the bup changed, or the field was left).
func _rewind_name() -> void:
	name_label.deselect()
	name_label.caret_column = 0
