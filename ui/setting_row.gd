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
@export var label_min_width := 196.0
@export var slider_min_width := 64.0  ## (with the value's 112, a row is as wide as it was with 180 and 88: the setup screen's panel keeps clear of its preview)
@export var slider_min_height := 28.0
@export var value_min_width := 104.0  ## (room for "1,000,000", the most bups a dish holds)
@export var unit_min_width := 96.0
## A small row for a sidebar: the readout's text size, and no reset button.
@export var compact := false
## Whether the row has its own reset icon. Off by default: a panel has one reset for everything in it, at the top right.
@export var show_reset := false
## What hovering the name says (blank: nothing).
@export var label_tip := ""
const DISABLED_ALPHA := 0.45  ## how faint a row is when it can't be changed

var disabled_reason := Strings.t("ui.fixed")  ## what hovering a row that can't change says

@onready var reset_button: Button = $Reset
@onready var label: Label = $Label
@onready var slider: HSlider = $Slider
@onready var value_field: LineEdit = $Value  ## the number: click it to type an exact value
@onready var unit_label: Label = $Unit  ## what the number counts, outside the box (e.g. "mm"); blank for plain counts

var _dragging := false  ## the slider's handle is held
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
	reset_button.visible = show_reset and not compact
	if compact:
		theme_type_variation = &"TightRow"  # (less space between the parts, notably between the number and its unit)
		reset_button.visible = false
		label.theme_type_variation = &"ReadoutLabel"
	value_field.theme_type_variation = &"ReadoutField"  # (the numbers are smaller than the names, so the sliders get the room)
	label.custom_minimum_size.x = label_min_width
	slider.custom_minimum_size = Vector2(slider_min_width, slider_min_height)
	value_field.custom_minimum_size.x = value_min_width
	unit_label.custom_minimum_size.x = unit_min_width
	label.text = label_text
	_set_changeable(true)  # (sets the label's tooltip, which a label shows only if it is told to take the mouse)
	slider.value_changed.connect(_on_slider_changed)
	slider.drag_started.connect(func() -> void: _dragging = true)
	slider.drag_ended.connect(_on_drag_ended)
	reset_button.pressed.connect(func() -> void: slider.value = default_value)
	value_field.text_submitted.connect(func(_text: String) -> void: value_field.release_focus())  # which commits (below)
	slider.focus_entered.connect(_show_focus.bind(true))  # (a slider draws no focus ring: the name takes the accent colour while the row has the keyboard)
	slider.focus_exited.connect(_show_focus.bind(false))
	value_field.focus_entered.connect(_show_focus.bind(true))
	value_field.focus_exited.connect(_show_focus.bind(false))
	value_field.focus_entered.connect(_begin_typing)
	UiInput.select_all_unless_clicked(value_field)
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


## While the handle is held the number follows it but nothing is reported: a setting that rebuilds or moves things (the
## preview, the interface itself) would otherwise shift under the pointer mid-drag. A change without a drag (a click on the
## track, the arrow keys, the number box, the reset icon) is reported at once.
func _on_slider_changed(_v: float) -> void:
	_update_text()
	if _dragging:
		return
	value_changed.emit(slider.value)


func _on_drag_ended(_changed: bool) -> void:
	_dragging = false
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


## The number's box is wide enough for the longest number the setting can show, in the text size there is now.
func _fit_value_box() -> void:
	var font := value_field.get_theme_font("font")
	var size := value_field.get_theme_font_size("font_size")
	var widest := font.get_string_size(_format(slider.max_value), HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var pad := value_field.get_theme_stylebox("normal").get_minimum_size().x
	value_field.custom_minimum_size.x = maxf(value_min_width, widest + pad + 8.0)


func _update_text() -> void:
	_fit_value_box()
	if value_field.has_focus():
		return  # the player is typing: leave their text alone until they commit it
	value_field.text = _format(slider.value)
	unit_label.text = suffix
	reset_button.tooltip_text = Strings.t("ui.use_default", [_format_with_unit(default_value)])


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


## Locks or unlocks the row from outside (a range of one value does it from within): a locked row stays, faint, and says
## `disabled_reason` when hovered.
func set_enabled(enabled: bool) -> void:
	_set_changeable(enabled)


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
	label.tooltip_text = hint if not changeable or label_tip == "" else label_tip
	label.mouse_filter = Control.MOUSE_FILTER_PASS if (not changeable or label_tip != "") else Control.MOUSE_FILTER_IGNORE


func _show_focus(on: bool) -> void:
	if not compact:
		label.theme_type_variation = &"FocusLabel" if on else &""
