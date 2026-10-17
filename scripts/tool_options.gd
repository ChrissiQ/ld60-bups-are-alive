class_name ToolOptions
extends PanelContainer
## Options for the current click tool: a tray that opens out of the bottom of the main
## toolbar, the same width as it. A tool without options keeps the tray closed.
## To give another tool options: add a group under this panel and register it in `_groups`.
## Its content lines up under that tool's toolbar button automatically.

@export var toolbar: Toolbar  ## set in the scene; the toolbar this tray belongs to

@onready var nutrient_options: Control = $NutrientOptions
@onready var nutrient_count_box: SpinBox = $NutrientOptions/NutrientCount

var _groups: Dictionary = {}  ## tool -> the group of option controls shown for it


func _ready() -> void:
	_groups = {Toolbar.Tool.NUTRIENT: nutrient_options}
	nutrient_count_box.tooltip_text = "Nutrients per click"
	var count_field := nutrient_count_box.get_line_edit()
	count_field.theme_type_variation = &"CompactField"  # the SpinBox's own role is set in the scene
	count_field.tooltip_text = nutrient_count_box.tooltip_text  # the field takes the hover itself, so it needs its own
	count_field.max_length = str(int(nutrient_count_box.max_value)).length()  # as many digits as the maximum has
	# The box measured itself with the default field style first, and a Control's rect doesn't
	# shrink back on its own once its minimum size drops, so settle it at its real size.
	nutrient_count_box.reset_size.call_deferred()
	resized.connect(_align)
	toolbar.resized.connect(_align)
	visibility_changed.connect(_align)


func nutrient_count() -> int:
	return int(nutrient_count_box.value)


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
		box.position.x = centre_x - group.global_position.x - box.size.x * 0.5
