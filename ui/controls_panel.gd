class_name ControlsPanel
extends PanelContainer
## The list of keyboard controls, with a Back button. Shown by the title screen and by the pause menu (each hides what
## is behind it while this is up, and shows it again on `back_requested`). The texts are in text/strings.cfg, [menu].

signal back_requested

@onready var back_button: Button = $Box/BackButton


func _ready() -> void:
	back_button.pressed.connect(back_requested.emit)


## So the keyboard can go straight back.
func focus_back() -> void:
	back_button.grab_focus()
