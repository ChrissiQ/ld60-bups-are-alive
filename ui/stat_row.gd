class_name StatRow
extends HBoxContainer
## One read-only "name ... value" line for stat panels. Use it for every labelled readout so
## they all look the same:
##
##     row.label_text = "Bups"      # (or set it in the scene)
##     row.value_text = "31"
##
## The row has no styling of its own: fonts, colours and spacing all come from the theme.

@export var label_text := "":
	set(text):
		label_text = text
		if is_node_ready():
			name_label.text = text

@onready var name_label: Label = $Name
@onready var value_label: Label = $Value

var value_text := "":
	set(text):
		value_text = text
		if is_node_ready():
			value_label.text = text


func _ready() -> void:
	name_label.text = label_text
	value_label.text = value_text
