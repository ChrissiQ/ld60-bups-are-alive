class_name UiInput
extends RefCounted
## Small helpers for reading input events the same way everywhere.


## Whether the event is the Escape key going down (a held key's repeats don't count).
static func is_escape_press(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE


## For a box that holds a number: focus that comes from the keyboard (Tab) selects the whole number, so typing replaces it;
## focus that comes from a click (the mouse button is down as the focus arrives) does not, so the click puts the caret
## where it landed and the mouse can select part of the number to replace only that part. (Godot's own
## `select_all_on_focus` selects all for a click too, and so makes the first click into a box unable to select part of
## it.) Use this on every box that holds a number.
static func select_all_unless_clicked(edit: LineEdit) -> void:
	edit.focus_entered.connect(func() -> void:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			edit.select_all.call_deferred())  # (after anything else that changes the text as the focus arrives)
