class_name UiInput
extends RefCounted
## Small helpers for reading input events the same way everywhere.


## Whether the event is the Escape key going down (a held key's repeats don't count).
static func is_escape_press(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE


## Whether the event is Enter going down (a held key's repeats don't count). A box being typed in takes its own Enter first.
static func is_accept_press(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_KP_ENTER]


## For a box that holds a number: focus that comes from the keyboard (Tab) selects the whole number, so typing replaces it;
## focus that comes from a click (the mouse button is down as the focus arrives) does not, so the click puts the caret
## where it landed and the mouse can select part of the number to replace only that part. (Godot's own
## `select_all_on_focus` selects all for a click too, and so makes the first click into a box unable to select part of
## it.) Use this on every box that holds a number.
static func select_all_unless_clicked(edit: LineEdit) -> void:
	edit.focus_entered.connect(func() -> void:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			edit.select_all.call_deferred())  # (after anything else that changes the text as the focus arrives)


## Whether the event is a turn of a wheel or a scroll of a trackpad.
static func is_scroll(event: InputEvent) -> bool:
	if event is InputEventPanGesture:
		return true
	return event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]


## Whether a scroll container inside `outer`, under the point, has more than it shows (one that fits everything has nothing to scroll, so the wheel may go on to `outer`).
static func holds_scrollable_at(outer: ScrollContainer, point: Vector2) -> bool:
	for inner: Node in outer.find_children("*", "ScrollContainer", true, false):
		var scroll := inner as ScrollContainer
		if scroll.is_visible_in_tree() and scroll.get_global_rect().has_point(point) and (scroll.get_v_scroll_bar().max_value > scroll.get_v_scroll_bar().page or scroll.get_h_scroll_bar().max_value > scroll.get_h_scroll_bar().page):
			return true
	return false
