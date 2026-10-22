class_name LayersPanel
extends PanelContainer
## What the dish shows, a row of small toggles in the top left corner above the readout, buttons like the toolbar's: the nutrient haze, the sources, the plankton, the
## bups, and the steering map and arc. Lit means shown. It only reports a choice (`layer_toggled`); the screen applies it to the dish.

signal layer_toggled(layer: Dish.Layer, shown: bool)

@onready var row: HBoxContainer = $Row
@onready var medium_button: Button = $Row/MediumButton
@onready var sources_button: Button = $Row/SourcesButton
@onready var plankton_button: Button = $Row/PlanktonButton
@onready var bups_button: Button = $Row/BupsButton
@onready var steering_button: Button = $Row/SteeringButton

var _buttons := {}  ## Dish.Layer -> its button


func _ready() -> void:
	_setup(medium_button, Dish.Layer.MEDIUM, "medium", "Z", KEY_Z)
	_setup(sources_button, Dish.Layer.SOURCES, "sources", "X", KEY_X)
	_setup(plankton_button, Dish.Layer.PLANKTON, "plankton", "C", KEY_C)
	_setup(bups_button, Dish.Layer.BUPS, "bups", "V", KEY_V)
	_setup(steering_button, Dish.Layer.STEERING, "steering", "B", KEY_B)


## Lights the buttons to match what the dish shows (without reporting it back).
func sync_from(dish: Dish) -> void:
	for layer: Dish.Layer in _buttons:
		_buttons[layer].set_pressed_no_signal(dish.layer_shown(layer))


func _setup(button: Button, layer: Dish.Layer, key_name: String, key_label: String, key: Key) -> void:
	button.toggle_mode = true
	button.button_pressed = true
	button.focus_mode = Control.FOCUS_NONE
	button.shortcut_in_tooltip = false
	button.tooltip_text = Strings.t("toolbar.tip", [Strings.t("layers." + key_name), key_label])
	var shortcut := Shortcut.new()
	var event := InputEventKey.new()
	event.keycode = key
	shortcut.events.append(event)
	button.shortcut = shortcut
	button.toggled.connect(func(on: bool) -> void: layer_toggled.emit(layer, on))
	_buttons[layer] = button
