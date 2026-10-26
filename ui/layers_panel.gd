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
	_setup(medium_button, Dish.Layer.MEDIUM, "medium")
	_setup(sources_button, Dish.Layer.SOURCES, "sources")
	_setup(plankton_button, Dish.Layer.PLANKTON, "plankton")
	_setup(bups_button, Dish.Layer.BUPS, "bups")
	_setup(steering_button, Dish.Layer.STEERING, "steering")
	_apply_keys()
	KeyBindings.listen(_apply_keys)


func _exit_tree() -> void:
	KeyBindings.unlisten(_apply_keys)


## Lights the buttons to match what the dish shows (without reporting it back).
func sync_from(dish: Dish) -> void:
	for layer: Dish.Layer in _buttons:
		_buttons[layer].set_pressed_no_signal(dish.layer_shown(layer))


func _setup(button: Button, layer: Dish.Layer, key_name: String) -> void:
	button.toggle_mode = true
	button.button_pressed = true
	button.focus_mode = Control.FOCUS_NONE
	button.shortcut_in_tooltip = false
	button.set_meta("action", "layer_" + key_name)
	button.set_meta("name", key_name)
	button.toggled.connect(func(on: bool) -> void: layer_toggled.emit(layer, on))
	_buttons[layer] = button


## Each button's tooltip and shortcut from the keys as they are now (also after the player changes one).
func _apply_keys() -> void:
	for button: Button in _buttons.values():
		var action: String = button.get_meta("action")
		button.tooltip_text = Strings.t("toolbar.tip", [Strings.t("layers." + (button.get_meta("name") as String)), KeyBindings.label(action)])
		var shortcut := Shortcut.new()
		var event := InputEventKey.new()
		event.keycode = KeyBindings.key(action)
		shortcut.events.append(event)
		button.shortcut = shortcut
