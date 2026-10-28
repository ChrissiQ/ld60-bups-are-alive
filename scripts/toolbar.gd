class_name Toolbar
extends Node
## The game screen's tools, zoom and playback buttons (the tool rail and the speeds in the top bar; they are found by their unique names in the screen).
## Plain Buttons with Shortcuts and tooltips; the screen that owns it reacts to the signals.

enum Tool { SELECT, PAN, NUTRIENT, SOURCE, ERASE, PLANKTON, PIPETTE }

signal tool_selected(tool: Tool)
signal zoom_in_requested
signal zoom_out_requested
signal speed_selected(multiplier: float)
signal pause_toggled(paused: bool)

@onready var select_button: Button = %SelectButton
@onready var pan_button: Button = %PanButton
@onready var nutrient_button: Button = %NutrientButton
@onready var source_button: Button = %SourceButton
@onready var erase_button: Button = %EraseButton
@onready var plankton_button: Button = %PlanktonButton
@onready var pipette_button: Button = %PipetteButton
@onready var zoom_out_button: Button = %ZoomOutButton
@onready var zoom_in_button: Button = %ZoomInButton
@onready var pause_button: Button = %PauseButton
@onready var speed_1_button: Button = %Speed1Button
@onready var speed_100_button: Button = %Speed100Button
@onready var speed_1000_button: Button = %Speed1000Button
@onready var speed_ultra_button: Button = %SpeedUltraButton

var _tool_buttons: Dictionary = {}
var _keyed: Array[Button] = []  ## every button that has a key action (see _setup)
var _last_play: Button  ## the speed button to resume with
var resume_locked := false  ## nothing but the screen can resume play (the game waits for the pipette): Space and the speed buttons do nothing


func _ready() -> void:
	var tools := ButtonGroup.new()
	_setup_tool(select_button, Tool.SELECT, tools, Strings.t("toolbar.select"), "tool_select")
	_setup_tool(pan_button, Tool.PAN, tools, Strings.t("toolbar.pan"), "tool_pan")
	_setup_tool(nutrient_button, Tool.NUTRIENT, tools, Strings.t("toolbar.nutrient"), "tool_nutrient")
	_setup_tool(source_button, Tool.SOURCE, tools, Strings.t("toolbar.source"), "tool_source")
	_setup_tool(erase_button, Tool.ERASE, tools, Strings.t("toolbar.erase"), "tool_erase")
	_setup_tool(plankton_button, Tool.PLANKTON, tools, Strings.t("toolbar.plankton"), "tool_plankton")
	_setup_tool(pipette_button, Tool.PIPETTE, tools, Strings.t("toolbar.pipette"), "tool_pipette")

	_setup(zoom_out_button, Strings.t("toolbar.zoom_out"), "zoom_out", [[KEY_KP_SUBTRACT, false]])
	zoom_out_button.pressed.connect(zoom_out_requested.emit)
	_setup(zoom_in_button, Strings.t("toolbar.zoom_in"), "zoom_in", [[KEY_KP_ADD, false], [KEY_EQUAL, true]])
	zoom_in_button.pressed.connect(zoom_in_requested.emit)

	# Pause and the four play speeds are one exclusive group: exactly one is selected, so
	# you are either paused or playing. Space swaps between pause and the last speed (below).
	var playback := ButtonGroup.new()
	_setup_toggle(pause_button, playback, Strings.t("toolbar.pause"), "pause", pause_toggled.emit.bind(true))
	_setup_speed(speed_1_button, playback, 1.0, Strings.t("toolbar.speed_1"), "speed_1")
	_setup_speed(speed_100_button, playback, 100.0, Strings.t("toolbar.speed_100"), "speed_2")
	_setup_speed(speed_1000_button, playback, 1000.0, Strings.t("toolbar.speed_1000"), "speed_3")
	_setup_speed(speed_ultra_button, playback, 10000.0, Strings.t("toolbar.speed_10000"), "speed_4")
	speed_1_button.button_pressed = true
	playback.pressed.connect(func(_button: BaseButton) -> void: _mark_resume())
	_mark_resume()
	_apply_keys()
	KeyBindings.listen(_apply_keys)


func _exit_tree() -> void:
	KeyBindings.unlisten(_apply_keys)


## While paused, the speed that play would go back to is outlined (so Space has a visible answer); while playing, the lit one says it.
func _mark_resume() -> void:
	for button: Button in [speed_1_button, speed_100_button, speed_1000_button, speed_ultra_button]:
		button.theme_type_variation = &"ToolButtonArmed" if pause_button.button_pressed and button == _last_play else &"ToolButton"


## Pauses, or resumes at the last speed, exactly as clicking the buttons would.
func set_paused(paused: bool) -> void:
	if not paused and resume_locked:
		return
	if paused:
		pause_button.button_pressed = true
	else:
		_last_play.button_pressed = true


func _shortcut_input(event: InputEvent) -> void:
	if KeyBindings.matches("pause", event):
		set_paused(not pause_button.button_pressed)
		get_viewport().set_input_as_handled()


## The next slower (-1) or faster (+1) speed: from a pause it goes to the slowest or fastest, at the ends it stays.
func step_speed(direction: int) -> void:
	if resume_locked:
		return
	var speeds := [speed_1_button, speed_100_button, speed_1000_button, speed_ultra_button]
	var at := speeds.find(_last_play) if not pause_button.button_pressed else (-1 if direction > 0 else speeds.size())
	speeds[clampi(at + direction, 0, speeds.size() - 1)].button_pressed = true


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
	if locked:
		button.set_meta("lock_reason", reason)
	else:
		button.remove_meta("lock_reason")
	button.tooltip_text = Strings.t("toolbar.locked", [base, reason]) if locked and reason != "" else base
	if locked and button.button_pressed:
		select_tool(Tool.SELECT)


func _setup_tool(button: Button, tool: Tool, group: ButtonGroup, description: String, action: String) -> void:
	_setup_toggle(button, group, description, action, tool_selected.emit.bind(tool))
	_tool_buttons[tool] = button


func _setup_speed(button: Button, group: ButtonGroup, multiplier: float, description: String, action: String) -> void:
	_setup_toggle(button, group, description, action, func() -> void:
		_last_play = button
		if resume_locked:
			pause_button.button_pressed = true  # (the choice is kept for when play resumes)
			return
		pause_toggled.emit(false)
		speed_selected.emit(multiplier))


## A button of an exclusive group: choosing it (not letting go of it) does `on_chosen`.
func _setup_toggle(button: Button, group: ButtonGroup, description: String, action: String, on_chosen: Callable) -> void:
	_setup(button, description, action)
	button.toggle_mode = true
	button.button_group = group
	button.toggled.connect(func(on: bool) -> void:
		if on:
			on_chosen.call())


## What a button is told once, however its key is changed later: what it does, its key action, and any fixed extra keys
## ([code, shift] pairs, like the keypad's + and -). Focus is off so Space and arrow keys keep reaching the shortcuts
## instead of re-pressing whichever button was clicked last. `_apply_keys` gives it its tooltip, hint and shortcut.
func _setup(button: Button, description: String, action: String, extras: Array = []) -> void:
	button.set_meta("description", description)
	button.set_meta("action", action)
	button.set_meta("extras", extras)
	button.focus_mode = Control.FOCUS_NONE
	button.shortcut_in_tooltip = false
	_keyed.append(button)


## Gives every button its tooltip ("<what it does> (<key>)"), its line of hint and its shortcut from the keys as they are now.
## Called as the toolbar is made and whenever the player changes a key.
func _apply_keys() -> void:
	for button in _keyed:
		var action: String = button.get_meta("action")
		var label := KeyBindings.label(action)
		var tip := Strings.t("toolbar.tip", [button.get_meta("description"), label])
		button.set_meta("tooltip", tip)
		button.tooltip_text = Strings.t("toolbar.locked", [tip, button.get_meta("lock_reason")]) if button.disabled and button.has_meta("lock_reason") else tip
		if action == "pause":
			continue  # (Space is taken by _shortcut_input, so the button that was last clicked is not pressed again by it)
		var shortcut := Shortcut.new()
		shortcut.events.append(_key_event(KeyBindings.key(action), false))
		for extra: Array in button.get_meta("extras"):
			shortcut.events.append(_key_event(extra[0], extra[1]))
		button.shortcut = shortcut


func _key_event(code: Key, shift: bool) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.shift_pressed = shift
	return e
