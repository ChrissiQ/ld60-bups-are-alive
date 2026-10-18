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

## Column widths. The defaults suit the setup and menu screens; a narrow panel sets smaller ones in its scene,
## so a row never makes its panel wider than the other things in it.
@export var label_min_width := 148.0
@export var slider_min_width := 180.0
@export var value_min_width := 88.0
@export var unit_min_width := 100.0
const DISABLED_ALPHA := 0.45  ## how faint a row is when it can't be changed

var disabled_reason := "Fixed"  ## what hovering a row that can't change says

@onready var reset_button: Button = $Reset
@onready var label: Label = $Label
@onready var slider: HSlider = $Slider
@onready var value_field: LineEdit = $Value  ## the number: click it to type an exact value
@onready var unit_label: Label = $Unit  ## what the number counts, outside the box (e.g. "mm"); blank for plain counts

var default_value := 0.0
var suffix := ""  ## the unit, shown beside the number (not in it), e.g. "mm" or "/min"

var value: float:
	get:
		assert(is_node_ready(), "SettingRow.value used before the row is in the scene tree")
		return slider.value
	set(v):
		assert(is_node_ready(), "SettingRow.value used before the row is in the scene tree")
		slider.value = v


func _ready() -> void:
	label.custom_minimum_size.x = label_min_width
	slider.custom_minimum_size.x = slider_min_width
	value_field.custom_minimum_size.x = value_min_width
	unit_label.custom_minimum_size.x = unit_min_width
	label.text = label_text
	slider.value_changed.connect(_on_slider_changed)
	reset_button.pressed.connect(func() -> void: slider.value = default_value)
	value_field.text_submitted.connect(func(_text: String) -> void: value_field.release_focus())  # which commits (below)
	value_field.focus_entered.connect(_begin_typing)
	value_field.focus_exited.connect(_commit_typing)
	value_field.gui_input.connect(_on_field_key)
	_update_text()


## Call once the row is in the scene tree (e.g. from the owning screen's _ready).
func configure(lo: float, hi: float, step: float, default: float, p_suffix: String = "") -> void:
	assert(is_node_ready(), "SettingRow.configure called before the row is in the scene tree")
	slider.min_value = lo
	slider.max_value = hi
	_set_changeable(hi > lo)  # a range of one value has nothing to choose between
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
	return UiText.thousands(v, _decimals())


## The number with its unit, for tooltips: "0.5 mm", "10 /min".
func _format_with_unit(v: float) -> String:
	return _format(v) if suffix == "" else "%s %s" % [_format(v), suffix]


func _update_text() -> void:
	if value_field.has_focus():
		return  # the player is typing: leave their text alone until they commit it
	value_field.text = _format(slider.value)
	unit_label.text = suffix
	reset_button.tooltip_text = "Use default (%s)" % _format_with_unit(default_value)


## Typing starts from the bare number: no thousands commas or unit to delete first.
func _begin_typing() -> void:
	value_field.text = String.num(slider.value, _decimals())


## Takes what was typed (commas, spaces and the unit are ignored). The slider clamps it to its range and
## snaps it to its step; anything that isn't a number puts the old value back.
func _commit_typing() -> void:
	slider.value = _typed_value()
	_update_text()


## What is in the box as a number (commas, spaces and the unit are ignored), or the slider's value if it isn't one.
func _typed_value() -> float:
	var typed := value_field.text.replace(",", "").replace(" ", "").trim_suffix(suffix)
	return typed.to_float() if typed.is_valid_float() else slider.value


## Sets the row without announcing a change: for a screen showing a value that came from elsewhere.
func set_value_silently(v: float) -> void:
	slider.set_value_no_signal(v)
	_update_text()


## While typing, Up and Down raise and lower the number by one unit (Shift: ten units). A unit is 1,
## or the slider's step where that is larger. What has been typed so far counts first.
func _on_field_key(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and (event.keycode == KEY_UP or event.keycode == KEY_DOWN)):
		return
	value_field.accept_event()  # so the arrow doesn't also move focus or change the game's nutrient rate
	var unit := maxf(slider.step, 1.0) * (10.0 if event.shift_pressed else 1.0)
	slider.value = _typed_value() + (unit if event.keycode == KEY_UP else -unit)
	value_field.text = String.num(slider.value, _decimals())
	value_field.select_all()


## Whether the row can be changed at all. When it can't, it is faint and says why on hover, so a slider that
## looks movable never does nothing.
func _set_changeable(changeable: bool) -> void:
	slider.editable = changeable
	value_field.editable = changeable
	reset_button.disabled = not changeable
	modulate.a = 1.0 if changeable else DISABLED_ALPHA
	var hint := "" if changeable else disabled_reason
	slider.tooltip_text = hint
	value_field.tooltip_text = hint
	label.tooltip_text = hint
	label.mouse_filter = Control.MOUSE_FILTER_PASS if not changeable else Control.MOUSE_FILTER_IGNORE
