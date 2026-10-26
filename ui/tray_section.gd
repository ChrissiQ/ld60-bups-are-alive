class_name TraySection
extends PanelContainer
## A panel of the right-hand tray that opens and closes under its heading, as every section of the tray does (an accordion): the heading is a
## `SectionButton` with a chevron at its right, and what is inside the section goes under it. Put the section's content as children of the node
## in the scene; they are moved under the heading when it is ready. The heading's words are the string `title_key` names.

signal toggled(open: bool)

const CHEVRON_DOWN := preload("res://icons/chevron_down.svg")
const CHEVRON_UP := preload("res://icons/chevron_up.svg")

@export var title_key := "":
	set(value):
		title_key = value
		if header != null:
			header.text = Strings.t(title_key)
@export var tip_key := ""  ## the heading's hover tip (a string key; {details}-style keys are filled in by Strings)

var header: Button
var body: VBoxContainer
var open := true:
	set(value):
		open = value
		_show_open()
		toggled.emit(open)


func _init() -> void:
	theme_type_variation = &"HudPanel"


func _ready() -> void:
	var content := get_children()
	var box := VBoxContainer.new()
	box.theme_type_variation = &"TightStack"
	header = Button.new()
	header.theme_type_variation = &"SectionButton"
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.focus_mode = Control.FOCUS_NONE
	header.pressed.connect(func() -> void: open = not open)
	if title_key != "":
		header.text = Strings.t(title_key)
	if tip_key != "":
		header.tooltip_text = Strings.t(tip_key)
	body = VBoxContainer.new()
	body.theme_type_variation = &"TightStack"
	add_child(box)
	box.add_child(header)
	box.add_child(body)
	var scene_owner := owner
	for child in content:
		var owned := [child] + child.find_children("*", "", true, true).filter(func(n: Node) -> bool: return n.owner == scene_owner)
		remove_child(child)
		body.add_child(child)
		for node: Node in owned:
			node.owner = scene_owner  # (taking a node out of the tree lets go of its owner: the scene's % names need it)
	_show_open()


func _show_open() -> void:
	if header == null:
		return
	body.visible = open
	header.icon = CHEVRON_UP if open else CHEVRON_DOWN
