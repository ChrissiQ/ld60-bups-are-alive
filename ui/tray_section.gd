class_name TraySection
extends PanelContainer
## A panel of the right-hand tray that opens and closes under its heading, as every section of the tray does (an accordion): the heading is a
## `SectionButton` with a chevron at its right, and what is inside the section goes under it. Put the section's content as children of the node
## in the scene; they are moved under the heading when it is ready. The heading's words are the string `title_key` names.
## The headings of the sections that are `draggable` can be dragged to put the sections in another order (the others of the tray stay where they are);
## the order is `UserSettings.tray_order` (the sections' node names), and `apply_order` puts a tray's sections in it.

signal toggled(open: bool)

const CHEVRON_DOWN := preload("res://icons/chevron_down.svg")
const CHEVRON_UP := preload("res://icons/chevron_up.svg")

@export var title_key := "":
	set(value):
		title_key = value
		if header != null:
			header.text = Strings.t(title_key)
@export var draggable := true  ## whether its heading can be dragged to reorder the tray
@export var tip_key := ""  ## the heading's hover tip (a string key; {details}-style keys are filled in by Strings)

var header: Button
var body: VBoxContainer
var _home := 0  ## its place in the tray as the scene has it
var _dragged := false  ## this section's heading is being dragged
var open := true:
	set(value):
		open = value
		_show_open()
		toggled.emit(open)


func _init() -> void:
	theme_type_variation = &"HudPanel"


func _ready() -> void:
	_home = get_index()
	var content := get_children()
	var box := VBoxContainer.new()
	box.theme_type_variation = &"TightStack"
	header = Button.new()
	header.theme_type_variation = &"SectionButton"
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.focus_mode = Control.FOCUS_NONE
	header.pressed.connect(func() -> void: open = not open)
	if draggable:
		header.set_drag_forwarding(_drag_data, _can_drop, _drop)
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


## The sections of `tray` that can be reordered (its direct children, in their places).
static func _movable(tray: Node) -> Array[TraySection]:
	var out: Array[TraySection] = []
	for child in tray.get_children():
		if child is TraySection and child.draggable:
			out.append(child)
	return out


## Puts the movable sections of `tray` in the order `UserSettings.tray_order` names (a section it does not name goes after the named ones, in the scene's order), each into a
## slot the movable sections held.
static func apply_order(tray: Node) -> void:
	var sections := _movable(tray)
	var slots: Array[int] = []
	for section in sections:
		slots.append(section.get_index())
	var order := UserSettings.tray_order
	var wanted := sections.duplicate()
	wanted.sort_custom(func(a: TraySection, b: TraySection) -> bool:
		var ia := order.find(String(a.name))
		var ib := order.find(String(b.name))
		return (ia if ia >= 0 else 1000 + a._home) < (ib if ib >= 0 else 1000 + b._home))
	for k in wanted.size():
		tray.move_child(wanted[k], slots[k])


## The names of the movable sections of `tray`, in the order they are in.
static func order_of(tray: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for section in _movable(tray):
		out.append(String(section.name))
	return out


func _drag_data(_at: Vector2) -> Variant:
	_dragged = true
	var preview := Label.new()
	preview.theme_type_variation = &"Note"
	preview.text = header.text
	set_drag_preview(preview)
	return self


## Dragging over another section's heading puts the dragged section in its place, so the tray shows the order it will have.
func _can_drop(_at: Vector2, data: Variant) -> bool:
	if data is TraySection and data != self and data.draggable and data.get_parent() == get_parent():
		get_parent().move_child(data, get_index())
		return true
	return false


func _drop(_at: Vector2, _data: Variant) -> void:
	pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _dragged:  # (every control is told when any drag ends)
		_dragged = false
		UserSettings.set_tray_order(order_of(get_parent()))
