class_name TraySection
extends PanelContainer
## A panel of the right-hand tray that opens and closes under its heading, as every section of the tray does (an accordion): the heading is a
## `SectionButton` with a chevron at its right, and what is inside the section goes under it. Put the section's content as children of the node
## in the scene; they are moved under the heading when it is ready. The heading's words are the string `title_key` names.
## The headings can be dragged to put the sections in another order;
## the order is `UserSettings.tray_order` (the sections' node names), and `apply_order` puts a tray's sections in it.

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
var _home := 0  ## its place in the tray as the scene has it
var _dragged := false  ## this section's heading is being dragged
var _open_before := true  ## whether it was open when the drag began (letting go over the heading must not toggle it)
var _slot: DropSlot  ## where it will land, while it is dragged
var _accepting: Array = []  ## the controls of the tray that take a drop while it is dragged
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


## The sections of `tray` (its direct children, in their places).
static func _movable(tray: Node) -> Array[TraySection]:
	var out: Array[TraySection] = []
	for child in tray.get_children():
		if child is TraySection:
			out.append(child)
	return out


## Puts the sections of `tray` in the order `UserSettings.tray_order` names (a section it does not name goes after the named ones, in the scene's order), each into a
## slot the sections held.
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


## The names of the sections of `tray`, in the order they are in.
static func order_of(tray: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for section in _movable(tray):
		out.append(String(section.name))
	return out


## Dragging lifts the section out of the tray: a copy of its heading follows the pointer, a `DropSlot` ("Move here") stands where it will land, and the slot moves to
## wherever the pointer is among the other sections. Letting go in the tray puts the section in the slot; Esc, or letting go outside the tray, puts it back.
func _drag_data(at: Vector2) -> Variant:
	var tray := get_parent()
	_dragged = true
	_open_before = open
	_slot = DropSlot.new()
	_slot.custom_minimum_size.y = header.size.y + get_theme_stylebox("panel").get_minimum_size().y  # (as tall as the section is when closed, however long its content)
	tray.add_child(_slot)
	tray.move_child(_slot, get_index())
	var lifted := PanelContainer.new()
	lifted.theme_type_variation = &"HudPanel"
	lifted.custom_minimum_size.x = size.x
	lifted.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var copy := Button.new()
	copy.theme_type_variation = &"SectionButton"
	copy.alignment = HORIZONTAL_ALIGNMENT_LEFT
	copy.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	copy.text = header.text
	copy.icon = header.icon
	copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lifted.add_child(copy)
	var holder := Control.new()  # (the preview hangs from its top left corner: this keeps the grabbed point under the pointer)
	holder.add_child(lifted)
	lifted.position = -at
	if get_viewport().gui_is_dragging():
		set_drag_preview(holder)
	else:
		holder.free()
	visible = false
	var headings: Array = _movable(tray).map(func(s: TraySection) -> Button: return s.header)  # (they have their own drag handlers: leave them be)
	_accepting = [tray] + tray.find_children("*", "Control", true, false).filter(func(c: Node) -> bool: return not headings.has(c))
	for c: Control in _accepting:  # (a control that cannot take the drop shows the "not allowed" pointer, so every control of the tray takes it)
		c.set_drag_forwarding(Callable(), _can_drop_here, _drop)
	set_process(true)
	return self


func _process(_delta: float) -> void:
	if _dragged and _slot != null:
		_move_slot()


## Puts the slot after the other sections whose middle the pointer has passed (judged without the slot's own height, so the slot does not flicker at a boundary).
func _move_slot() -> void:
	var tray := get_parent()
	var mouse_y := get_global_mouse_position().y
	var shift: float = _slot.size.y + (tray.get_theme_constant("separation") if tray is BoxContainer else 0)
	var others: Array[TraySection] = []
	for s in _movable(tray):
		if s != self and s.visible:
			others.append(s)
	var passed := 0
	for s in others:
		var middle := s.get_global_rect().get_center().y
		if s.get_index() > _slot.get_index():
			middle -= shift
		if mouse_y > middle:
			passed += 1
	var at: int
	if passed == others.size():
		at = others[passed - 1].get_index() + 1 if not others.is_empty() else _slot.get_index()
		if not others.is_empty() and _slot.get_index() < others[passed - 1].get_index():
			at -= 1
	else:
		at = others[passed].get_index()
		if _slot.get_index() < at:
			at -= 1
	if at != _slot.get_index():
		tray.move_child(_slot, at)


## Whether `data` is a section of this tray that may be dropped (any control of the tray answers, so the pointer never shows "not allowed" over it).
func _can_drop_here(_at: Vector2, data: Variant) -> bool:
	return data is TraySection and data.get_parent() == get_parent()


func _can_drop(at: Vector2, data: Variant) -> bool:
	return data != self and _can_drop_here(at, data)


func _drop(_at: Vector2, _data: Variant) -> void:
	pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _dragged:  # (every control is told when any drag ends)
		_end_drag()


func _end_drag() -> void:
	var tray := get_parent() as Control
	_finish_drag(tray.get_global_rect().has_point(get_global_mouse_position()) and not Input.is_key_pressed(KEY_ESCAPE))


## Ends the drag: the section goes into the slot when `kept`, else stays where it was.
func _finish_drag(kept: bool) -> void:
	_dragged = false
	set_process(false)
	var tray := get_parent()
	if kept and _slot != null:
		tray.move_child(self, _slot.get_index())
	if _slot != null:
		_slot.queue_free()
		_slot = null
	for c: Control in _accepting:
		if is_instance_valid(c):
			c.set_drag_forwarding(Callable(), Callable(), Callable())
	_accepting = []
	visible = true
	open = _open_before
	(func() -> void: open = _open_before).call_deferred()  # (a press the release raises after the drag's end)
	if kept:
		UserSettings.set_tray_order(order_of(tray))
	# The pointer shape is chosen at a mouse move: send one, or the "not allowed" shape stays until the mouse moves.
	var motion := InputEventMouseMotion.new()
	motion.position = get_viewport().get_mouse_position()
	motion.global_position = motion.position
	Input.parse_input_event.call_deferred(motion)
