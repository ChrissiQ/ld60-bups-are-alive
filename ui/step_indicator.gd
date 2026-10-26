class_name StepIndicator
extends HBoxContainer
## Where a person is in a short run of pages: a numbered badge and a name for each step, joined by lines. The current step is lit, the ones before it
## are ticked off in a quiet version of the same colour, the ones after it are plain. Set `step_names` and `current` (from 0) in the scene.

@export var step_names: PackedStringArray = []
@export var current := 0


func _ready() -> void:
	for i in step_names.size():
		if i > 0:
			var line := HSeparator.new()
			line.custom_minimum_size.x = 32.0
			line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			add_child(line)
		var state := "Current" if i == current else ("Done" if i < current else "")
		var badge := PanelContainer.new()
		badge.theme_type_variation = "Badge" + state
		var number := Label.new()
		number.text = str(i + 1)
		number.theme_type_variation = "BadgeNumber" + state
		number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.add_child(number)
		badge.custom_minimum_size = Vector2(26.0, 26.0)
		badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var step := HBoxContainer.new()
		step.theme_type_variation = &"TightGroup"
		step.add_child(badge)
		var label := Label.new()
		label.text = Strings.resolve(step_names[i])
		label.theme_type_variation = "StepName" + state
		step.add_child(label)
		add_child(step)
