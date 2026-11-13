extends Node
## Applies the player's preferences as the game starts (see UserSettings) and lets the full screen key flip full screen on every screen (see UserSettings.fullscreen_key_label).


const HOLD_MSEC := 10000  ## how long after the start a window that is not the game's to manage is kept as it was started (UserSettings.hold_windowed)


func _ready() -> void:
	UserSettings.apply()
	set_process(not UserSettings._window_is_managed())


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > HOLD_MSEC:
		set_process(false)
		return
	UserSettings.hold_windowed()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and UserSettings.is_fullscreen_key(event):
		UserSettings.load_once()
		UserSettings.set_fullscreen(not UserSettings.fullscreen)
		get_viewport().set_input_as_handled()
