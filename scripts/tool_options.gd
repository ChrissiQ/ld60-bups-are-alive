class_name ToolOptions
extends PanelContainer
## Options for the current click tool: a tray that opens out of the bottom of the main
## toolbar, the same width as it. A tool without options keeps the tray closed.
## To give another tool options: add a group under this panel and register it in `_groups`.
## Its content lines up under that tool's toolbar button automatically.

@export var toolbar: Toolbar  ## set in the scene; the toolbar this tray belongs to

@onready var select_options: Control = $SelectOptions
@onready var nutrient_options: Control = $NutrientOptions
@onready var nutrient_count_box: SpinBox = $NutrientOptions/NutrientCount
@onready var source_options: Control = $SourceOptions
@onready var source_rate_box: SpinBox = $SourceOptions/SourceRate
@onready var erase_options: Control = $EraseOptions
@onready var brush_size_box: SpinBox = $EraseOptions/BrushSize
@onready var pipette_options: Control = $PipetteOptions
@onready var pipette_radius_box: SpinBox = $PipetteOptions/PipetteRadius

signal pick_mode_selected(mode: Dish.PickMode)  ## the select tool's choice of what to look at changed

var pick_buttons: Dictionary = {}  ## Dish.PickMode -> the select tray's button for it
var _groups: Dictionary = {}  ## tool -> the group of option controls shown for it


func _ready() -> void:
	_groups = {Toolbar.Tool.SELECT: select_options, Toolbar.Tool.NUTRIENT: nutrient_options, Toolbar.Tool.SOURCE: source_options, Toolbar.Tool.ERASE: erase_options, Toolbar.Tool.PIPETTE: pipette_options}
	var picks := ButtonGroup.new()
	_setup_pick(picks, $SelectOptions/Modes/PickAllButton, Dish.PickMode.ALL, Strings.t("tray.pick_all"))
	_setup_pick(picks, $SelectOptions/Modes/PickBackgroundButton, Dish.PickMode.BACKGROUND, Strings.t("tray.pick_background"))
	_setup_pick(picks, $SelectOptions/Modes/PickBupsButton, Dish.PickMode.BUPS, Strings.t("tray.pick_bups"))
	_setup_pick(picks, $SelectOptions/Modes/PickSourcesButton, Dish.PickMode.SOURCES, Strings.t("tray.pick_sources"))
	_setup_pick(picks, $SelectOptions/Modes/PickPlanktonButton, Dish.PickMode.PLANKTON, Strings.t("tray.pick_plankton"))
	_compact(nutrient_count_box, Strings.t("tray.nutrients_per_click"))
	_compact(source_rate_box, Strings.t("tray.nutrients_per_minute"))
	_compact(brush_size_box, Strings.t("tray.brush_radius"))
	_compact(pipette_radius_box, Strings.t("tray.pipette_radius"))
	resized.connect(_align)
	toolbar.resized.connect(_align)
	visibility_changed.connect(_align)


func _setup_pick(group: ButtonGroup, button: Button, mode: Dish.PickMode, tip: String) -> void:
	pick_buttons[mode] = button
	button.button_group = group
	button.tooltip_text = tip
	button.focus_mode = Control.FOCUS_NONE
	button.toggled.connect(func(on: bool) -> void:
		if on:
			pick_mode_selected.emit(mode))


## The mode the tray starts in: whichever of its buttons the scene has pressed.
func pick_mode() -> Dish.PickMode:
	for mode: Dish.PickMode in pick_buttons:
		if pick_buttons[mode].button_pressed:
			return mode
	return Dish.PickMode.ALL


func nutrient_count() -> int:
	return int(nutrient_count_box.value)


func source_rate() -> float:
	return source_rate_box.value


func brush_radius() -> float:
	return brush_size_box.value


func pipette_radius() -> float:
	return pipette_radius_box.value


## A number box in the tray: small, with its hover text on the field as well, since the field takes the hover itself.
func _compact(box: SpinBox, tooltip: String) -> void:
	box.tooltip_text = tooltip
	var field := box.get_line_edit()
	field.theme_type_variation = &"CompactField"  # the SpinBox's own role is set in the scene
	field.tooltip_text = tooltip
	UiInput.select_all_unless_clicked(field)
	field.max_length = str(int(box.max_value)).length() + (2 if box.step < 1.0 else 0)  # as many characters as the maximum has, and a decimal point and place if it takes them
	# The box measured itself with the default field style first, and a Control's rect doesn't
	# shrink back on its own once its minimum size drops, so settle it at its real size.
	box.reset_size.call_deferred()


func show_for(tool: Toolbar.Tool) -> void:
	for group: Control in _groups.values():
		group.visible = false
	var active: Control = _groups.get(tool)
	if active != null:
		active.visible = true
		_align.call_deferred()
	visible = active != null


## Centres each group's content under the toolbar button of its tool.
func _align() -> void:
	for tool in _groups:
		var group: Control = _groups[tool]
		var anchor := toolbar.button_for(tool)
		if anchor == null:
			continue
		var box := group.get_child(0) as Control
		var centre_x := anchor.global_position.x + anchor.size.x * 0.5
		box.position.x = clampf(centre_x - group.global_position.x - box.size.x * 0.5, 0.0, maxf(group.size.x - box.size.x, 0.0))  # (kept inside the tray)
