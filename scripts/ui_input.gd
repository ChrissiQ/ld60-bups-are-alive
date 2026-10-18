class_name UiInput
extends RefCounted
## Small helpers for reading input events the same way everywhere.


## Whether the event is the Escape key going down (a held key's repeats don't count).
static func is_escape_press(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE
