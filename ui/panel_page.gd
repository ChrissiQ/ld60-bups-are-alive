class_name PanelPage
extends PanelContainer
## A page of the title screen and the pause menu (the controls, the encyclopedia, the options): shown in place of what is behind it, with a
## Back button at `Box/Actions/BackButton` that raises `back_requested`.

signal back_requested

@onready var back_button: Button = $Box/Actions/BackButton


## Wired here and not in `_ready`: a subclass's own `_ready` replaces the base's, but every class in the chain gets the notification.
func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		back_button.pressed.connect(back_requested.emit)


## So the keyboard can go straight back.
func focus_back() -> void:
	back_button.grab_focus()
