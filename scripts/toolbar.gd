class_name Toolbar
extends PanelContainer
## Top-of-screen toolbar: click tools, zoom, and simulation speed.
## Plain Buttons with Shortcuts and tooltips; the screen that owns it reacts to the signals.

enum Tool { SELECT, PAN, NUTRIENT, SOURCE, ERASE, PLANKTON }

signal tool_selected(tool: Tool)
signal zoom_in_requested
signal zoom_out_requested
signal speed_selected(multiplier: float)
signal pause_toggled(paused: bool)

@onready var select_button: Button = $Row/SelectButton
@onready var pan_button: Button = $Row/PanButton
@onready var nutrient_button: Button = $Row/NutrientButton
@onready var source_button: Button = $Row/SourceButton
@onready var erase_button: Button = $Row/EraseButton
@onready var plankton_button: Button = $Row/PlanktonButton
@onready var zoom_out_button: Button = $Row/ZoomOutButton
@onready var zoom_in_button: Button = $Row/ZoomInButton
@onready var pause_button: Button = $Row/PauseButton
@onready var speed_1_button: Button = $Row/Speed1Button
@onready var speed_100_button: Button = $Row/Speed100Button
@onready var speed_1000_button: Button = $Row/Speed1000Button
@onready var speed_ultra_button: Button = $Row/SpeedUltraButton

var _tool_buttons: Dictionary = {}
var _last_play: Button  ## the speed button to resume with


func _ready() -> void:
	var tools := ButtonGroup.new()
	_setup_tool(select_button, Tool.SELECT, tools, Strings.t("toolbar.select"), "I", [KEY_I])
	_setup_tool(pan_button, Tool.PAN, tools, Strings.t("toolbar.pan"), "H", [KEY_H])
	_setup_tool(nutrient_button, Tool.NUTRIENT, tools, Strings.t("toolbar.nutrient"), "N", [KEY_N])
	_setup_tool(source_button, Tool.SOURCE, tools, Strings.t("toolbar.source"), "F", [KEY_F])
	_setup_tool(erase_button, Tool.ERASE, tools, Strings.t("toolbar.erase"), "E", [KEY_E])
	_setup_tool(plankton_button, Tool.PLANKTON, tools, Strings.t("toolbar.plankton"), "P", [KEY_P])

	_setup(zoom_out_button, Strings.t("toolbar.zoom_out"), "-", [KEY_MINUS, KEY_KP_SUBTRACT])
	zoom_out_button.pressed.connect(zoom_out_requested.emit)
	_setup(zoom_in_button, Strings.t("toolbar.zoom_in"), "+", [KEY_EQUAL, KEY_KP_ADD], [KEY_EQUAL])
	zoom_in_button.pressed.connect(zoom_in_requested.emit)

	# Pause and the four play speeds are one exclusive group: exactly one is selected, so
	# you are either paused or playing. Space swaps between pause and the last speed (below).
	var playback := ButtonGroup.new()
	_setup_toggle(pause_button, playback, Strings.t("toolbar.pause"), "Space", [], pause_toggled.emit.bind(true))
	_setup_speed(speed_1_button, playback, 1.0, Strings.t("toolbar.speed_1"), "1", KEY_1)
	_setup_speed(speed_100_button, playback, 100.0, Strings.t("toolbar.speed_100"), "2", KEY_2)
	_setup_speed(speed_1000_button, playback, 1000.0, Strings.t("toolbar.speed_1000"), "3", KEY_3)
	_setup_speed(speed_ultra_button, playback, 10000.0, Strings.t("toolbar.speed_10000"), "4", KEY_4)
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
	return Tool.SELECT


func select_tool(tool: Tool) -> void:
	_tool_buttons[tool].button_pressed = true


## Locks or unlocks a tool. A locked one is greyed out and says why; if it was the selected
## tool the toolbar falls back to Select, so the screen is never left holding a tool it can't use.
func set_tool_locked(tool: Tool, locked: bool, reason := "") -> void:
	var button: Button = _tool_buttons[tool]
	button.disabled = locked
	var base := button.get_meta("tooltip", button.tooltip_text) as String
	button.set_meta("tooltip", base)
	button.tooltip_text = Strings.t("toolbar.locked", [base, reason]) if locked and reason != "" else base
	if locked and button.button_pressed:
		select_tool(Tool.SELECT)


func _setup_tool(button: Button, tool: Tool, group: ButtonGroup, description: String, key_label: String, keys: Array) -> void:
	_setup_toggle(button, group, description, key_label, keys, tool_selected.emit.bind(tool))
	_tool_buttons[tool] = button


func _setup_speed(button: Button, group: ButtonGroup, multiplier: float, description: String, key_label: String, key: Key) -> void:
	_setup_toggle(button, group, description, key_label, [key], func() -> void:
		_last_play = button
		pause_toggled.emit(false)
		speed_selected.emit(multiplier))


## A button of an exclusive group: choosing it (not letting go of it) does `on_chosen`.
func _setup_toggle(button: Button, group: ButtonGroup, description: String, key_label: String, keys: Array, on_chosen: Callable) -> void:
	_setup(button, description, key_label, keys)
	button.toggle_mode = true
	button.button_group = group
	button.toggled.connect(func(on: bool) -> void:
		if on:
			on_chosen.call())


## Tooltip reads "<what it does> (<key>)". Focus is off so Space and arrow keys keep
## reaching the shortcuts instead of re-pressing whichever button was clicked last.
func _setup(button: Button, description: String, key_label: String, keys: Array, shifted_keys: Array = []) -> void:
	button.tooltip_text = Strings.t("toolbar.tip", [description, key_label])
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
