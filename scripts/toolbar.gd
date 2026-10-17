class_name Toolbar
extends PanelContainer
## Top-of-screen toolbar: click tools, zoom, and simulation speed.
## Plain Buttons with Shortcuts and tooltips; the screen that owns it reacts to the signals.

enum Tool { INFO, PAN, NUTRIENT }

signal tool_selected(tool: Tool)
signal zoom_in_requested
signal zoom_out_requested
signal speed_selected(multiplier: float)
signal pause_toggled(paused: bool)

@onready var info_button: Button = $Row/InfoButton
@onready var pan_button: Button = $Row/PanButton
@onready var nutrient_button: Button = $Row/NutrientButton
@onready var zoom_out_button: Button = $Row/ZoomOutButton
@onready var zoom_in_button: Button = $Row/ZoomInButton
@onready var pause_button: Button = $Row/PauseButton
@onready var speed_1_button: Button = $Row/Speed1Button
@onready var speed_3_button: Button = $Row/Speed3Button
@onready var speed_8_button: Button = $Row/Speed8Button

var _tool_buttons: Dictionary = {}
var _last_play: Button  ## the speed button to resume with


func _ready() -> void:
	var tools := ButtonGroup.new()
	_setup_tool(info_button, Tool.INFO, tools, "Info", "I", [KEY_I])
	_setup_tool(pan_button, Tool.PAN, tools, "Pan", "H", [KEY_H])
	_setup_tool(nutrient_button, Tool.NUTRIENT, tools, "Place nutrients", "N", [KEY_N])

	_setup(zoom_out_button, "Zoom out", "-", [KEY_MINUS, KEY_KP_SUBTRACT])
	zoom_out_button.pressed.connect(zoom_out_requested.emit)
	_setup(zoom_in_button, "Zoom in", "+", [KEY_EQUAL, KEY_KP_ADD], [KEY_EQUAL])
	zoom_in_button.pressed.connect(zoom_in_requested.emit)

	# Pause and the three play speeds are one exclusive group: exactly one is selected, so
	# you are either paused or playing. Space swaps between pause and the last speed (below).
	var playback := ButtonGroup.new()
	_setup(pause_button, "Pause", "Space", [])
	pause_button.toggle_mode = true
	pause_button.button_group = playback
	pause_button.toggled.connect(func(on: bool) -> void:
		if on:
			pause_toggled.emit(true))
	_setup_speed(speed_1_button, playback, 1.0, "Play", "1", KEY_1)
	_setup_speed(speed_3_button, playback, 3.0, "Speed x3", "2", KEY_2)
	_setup_speed(speed_8_button, playback, 8.0, "Speed x8", "3", KEY_3)
	speed_1_button.button_pressed = true


## Pauses, or resumes at the last speed, exactly as clicking the buttons would.
func set_paused(paused: bool) -> void:
	if paused:
		pause_button.button_pressed = true
	else:
		_last_play.button_pressed = true


func _shortcut_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		set_paused(not pause_button.button_pressed)
		get_viewport().set_input_as_handled()


## The button for a tool, so other widgets (like the options tray) can line up with it.
func button_for(tool: Tool) -> Button:
	return _tool_buttons.get(tool)


## The tool that is selected right now: the toolbar is the one source of truth for it.
func current_tool() -> Tool:
	for tool: Tool in _tool_buttons:
		if _tool_buttons[tool].button_pressed:
			return tool
	return Tool.INFO


func select_tool(tool: Tool) -> void:
	_tool_buttons[tool].button_pressed = true


func _setup_tool(button: Button, tool: Tool, group: ButtonGroup, description: String, key_label: String, keys: Array) -> void:
	_setup(button, description, key_label, keys)
	button.toggle_mode = true
	button.button_group = group
	button.toggled.connect(func(on: bool) -> void:
		if on:
			tool_selected.emit(tool))
	_tool_buttons[tool] = button


func _setup_speed(button: Button, group: ButtonGroup, multiplier: float, description: String, key_label: String, key: Key) -> void:
	_setup(button, description, key_label, [key])
	button.toggle_mode = true
	button.button_group = group
	button.toggled.connect(func(on: bool) -> void:
		if on:
			_last_play = button
			pause_toggled.emit(false)
			speed_selected.emit(multiplier))


## Tooltip reads "<what it does> (<key>)". Focus is off so Space and arrow keys keep
## reaching the shortcuts instead of re-pressing whichever button was clicked last.
func _setup(button: Button, description: String, key_label: String, keys: Array, shifted_keys: Array = []) -> void:
	button.tooltip_text = "%s  (%s)" % [description, key_label]
	button.focus_mode = Control.FOCUS_NONE
	button.shortcut_in_tooltip = false
	var shortcut := Shortcut.new()
	for code in keys:
		shortcut.events.append(_key_event(code, false))
	for code in shifted_keys:
		shortcut.events.append(_key_event(code, true))
	button.shortcut = shortcut


func _key_event(code: Key, shift: bool) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.shift_pressed = shift
	return e
