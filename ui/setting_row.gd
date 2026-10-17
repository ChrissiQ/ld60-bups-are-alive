class_name SettingRow
extends HBoxContainer
## One labelled numeric setting: a reset-to-default icon, the name, a slider, and the current
## value. Use this for every numeric setting so they all look and behave the same:
##
##     row.label_text = "Bups"          # (or set it in the scene)
##     row.configure(1, 200, 1, 4)      # min, max, step, default (+ optional suffix like "/s")
##     row.value_changed.connect(...)
##
## The row has no styling of its own: fonts, colours and spacing all come from the theme.

signal value_changed(value: float)

@export var label_text := "":
	set(text):
		label_text = text
		if is_node_ready():
			label.text = text

@onready var reset_button: Button = $Reset
@onready var label: Label = $Label
@onready var slider: HSlider = $Slider
@onready var value_label: Label = $Value

var default_value := 0.0
var suffix := ""  ## shown after the number, e.g. "/s"

var value: float:
	get:
		assert(is_node_ready(), "SettingRow.value used before the row is in the scene tree")
		return slider.value
	set(v):
		assert(is_node_ready(), "SettingRow.value used before the row is in the scene tree")
		slider.value = v


func _ready() -> void:
	label.text = label_text
	slider.value_changed.connect(_on_slider_changed)
	reset_button.pressed.connect(func() -> void: slider.value = default_value)
	_update_text()


## Call once the row is in the scene tree (e.g. from the owning screen's _ready).
func configure(lo: float, hi: float, step: float, default: float, p_suffix: String = "") -> void:
	assert(is_node_ready(), "SettingRow.configure called before the row is in the scene tree")
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	default_value = default
	suffix = p_suffix
	_update_text()


func _on_slider_changed(_v: float) -> void:
	_update_text()
	value_changed.emit(slider.value)


## Enough decimals to show every step: 1 -> "5", 0.1 -> "0.5", 0.25 -> "0.25".
func _decimals() -> int:
	var places := 0
	var scaled := slider.step
	while absf(scaled - roundf(scaled)) > 0.0001 and places < 6:
		scaled *= 10.0
		places += 1
	return places


func _format(v: float) -> String:
	return String.num(v, _decimals()) + suffix


func _update_text() -> void:
	value_label.text = _format(slider.value)
	reset_button.tooltip_text = "Use default (%s)" % _format(default_value)
