extends Node
## Applies the player's preferences as the game starts (see UserSettings) and lets the full screen key flip full screen on every screen (see UserSettings.fullscreen_key_label).


func _ready() -> void:
	UserSettings.apply()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and UserSettings.is_fullscreen_key(event):
		UserSettings.load_once()
		UserSettings.set_fullscreen(not UserSettings.fullscreen)
		get_viewport().set_input_as_handled()
