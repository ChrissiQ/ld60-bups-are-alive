class_name ToggleRow
extends VBoxContainer
## A yes/no setting that reads as one: its name, On and Off buttons side by side (like the speed buttons, exactly one is lit), and below them, always in view, what it does.
## `button_pressed` is the setting (true is On), as a toggle button has it; changing it reports `toggled` like one.

signal toggled(on: bool)

@export var label_text := "":
	set(text):
		label_text = text
		if is_node_ready():
			name_label.text = text
@export var hint_text := "":
	set(text):
		hint_text = text
		if is_node_ready():
			hint_label.text = text

@onready var name_label: Label = $Row/Name
@onready var on_button: Button = $Row/OnButton
@onready var off_button: Button = $Row/OffButton
@onready var hint_label: Label = $Hint

var button_pressed := false:
	set(value):
		if value != button_pressed:
			_state = value
			_light()
			toggled.emit(value)
	get:
		return _state

var _state := false


func _ready() -> void:
	name_label.text = label_text
	hint_label.text = hint_text
	var group := ButtonGroup.new()
	for button: Button in [on_button, off_button]:
		button.button_group = group
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
	on_button.pressed.connect(func() -> void: button_pressed = true)
	off_button.pressed.connect(func() -> void: button_pressed = false)
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
