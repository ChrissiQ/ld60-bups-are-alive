class_name ToggleRow
extends VBoxContainer
## The game's one control for a yes/no setting: its name, a segmented On/Off switch (exactly one side is lit), and below, always in view, what it does.
## `button_pressed` is the setting (true is On), as a toggle button has it; changing it reports `toggled` like one.
## With `auto_text` set it also has a checkbox ("System", "Automatic"): ticked, the machine decides, the switch is dimmed and cannot be used,
## and `automatic` is true; the switch still shows what is in force (set it with `set_pressed_no_signal`).

signal toggled(on: bool)
signal automatic_toggled(on: bool)

const AUTOMATIC_ALPHA := 0.4  ## how faint the switch is while the machine decides

@export var label_text := "":
	set(text):
		label_text = text
		if is_node_ready():
			name_label.text = text
@export var auto_text := "":
	set(text):
		auto_text = text
		if is_node_ready():
			auto_check.text = text
			auto_check.visible = text != ""
@export var hint_text := "":
	set(text):
		hint_text = text
		if is_node_ready():
			hint_label.text = text
			hint_label.visible = text != ""

@onready var name_label: Label = $Row/Name
@onready var on_button: Button = $Row/Segments/Choices/OnButton
@onready var off_button: Button = $Row/Segments/Choices/OffButton
@onready var auto_check: CheckBox = $Row/AutoCheck
@onready var segments: Control = $Row/Segments
@onready var hint_label: Label = $Hint

var button_pressed := false:
	set(value):
		if value != button_pressed:
			_state = value
			_light()
			toggled.emit(value)
	get:
		return _state

var automatic: bool:
	set(value):
		if value != automatic:
			_automatic = value
			_light()
			automatic_toggled.emit(value)
	get:
		return _automatic

var _state := false
var _automatic := false


func _ready() -> void:
	name_label.text = label_text
	hint_label.text = hint_text
	hint_label.visible = hint_text != ""  # (a setting that needs no explanation has none)
	auto_check.text = auto_text
	auto_check.visible = auto_text != ""
	auto_check.toggled.connect(func(on: bool) -> void: automatic = on)
	for control: Control in [segments, auto_check]:  # (the name takes the accent colour while the row has the keyboard, as in every setting row)
		control.focus_entered.connect(_show_focus.bind(true))
		control.focus_exited.connect(_show_focus.bind(false))
	# The two halves are one control: one stop for Tab, one ring round the pair, Space or Enter flips it, Left chooses On and Right Off.
	segments.focus_mode = Control.FOCUS_ALL
	segments.gui_input.connect(_on_segments_input)
	segments.focus_entered.connect(func() -> void: segments.theme_type_variation = &"SwitchSegmentsFocused")
	segments.focus_exited.connect(func() -> void: segments.theme_type_variation = &"SwitchSegments")
	var group := ButtonGroup.new()
	for button: Button in [on_button, off_button]:
		button.button_group = group
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
	on_button.pressed.connect(func() -> void: button_pressed = true)
	off_button.pressed.connect(func() -> void: button_pressed = false)
	_light()


## Ticks or unticks the checkbox without reporting it.
func set_automatic_no_signal(value: bool) -> void:
	_automatic = value
	if is_node_ready():
		_light()


## Sets the setting without reporting it.
func set_pressed_no_signal(value: bool) -> void:
	_state = value
	if is_node_ready():
		_light()


func _light() -> void:
	if is_node_ready():
		on_button.set_pressed_no_signal(_state)
		off_button.set_pressed_no_signal(not _state)
		auto_check.set_pressed_no_signal(_automatic)
		segments.modulate.a = AUTOMATIC_ALPHA if _automatic else 1.0  # (dimmed: the machine decides)
		for button: Button in [on_button, off_button]:
			button.mouse_filter = Control.MOUSE_FILTER_IGNORE if _automatic else Control.MOUSE_FILTER_STOP
		segments.focus_mode = Control.FOCUS_NONE if _automatic else Control.FOCUS_ALL  # (Tab skips a switch the machine is deciding)


func _show_focus(on: bool) -> void:
	name_label.theme_type_variation = &"FocusLabel" if on else &""


func _on_segments_input(event: InputEvent) -> void:
	if _automatic:
		return
	if event.is_action_pressed("ui_accept"):
		button_pressed = not button_pressed
	elif event.is_action_pressed("ui_left"):
		button_pressed = true
	elif event.is_action_pressed("ui_right"):
		button_pressed = false
	else:
		return
	segments.accept_event()
