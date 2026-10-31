class_name FreezerShelf
extends VBoxContainer
## What is inside the tray's "Freezer" section: the buttons that freeze or trash the dish in view, a note while nothing is frozen, and a row for each frozen dish (its picture,
## its number and bups, and icon buttons to unfreeze it, show what is known of it or trash it). The section itself is a plain TraySection that holds this as its content. It keeps
## the frozen dishes (`entries`, in the order they went in): {number, data ({time}: when it was frozen), picture (a texture of its tile, or null), bups}. The screen does the
## freezing, thawing and trashing; this only holds and shows.
##
## The rows scroll inside a height of their own (up to SCROLL_MAX_HEIGHT), and only those in view and OVERSCAN either side are made: they are reused for other entries as
## the list scrolls, and a spacer at each end stands for the rest, so a thousand frozen dishes cost what a screenful does. Every row is as tall as the first one made (and its
## details line, when open, as tall as the first one shown), so where a row lies is arithmetic.

const UNFREEZE_ICON := preload("res://icons/unfreeze.svg")
const INFO_ICON := preload("res://icons/info.svg")
const TRASH_ICON := preload("res://icons/trash.svg")
const PICTURE_SIZE := 40
const SCROLL_MAX_HEIGHT := 200.0  ## the most the rows take before they scroll
const OVERSCAN := 3  ## rows made past each end of what is in view

signal freeze_requested
signal trash_requested
signal thaw_requested(entry: Dictionary)
signal trash_entry_requested(entry: Dictionary)

@onready var actions: DishActions = %FreezerActions  ## freeze or trash the dish in the main view
@onready var empty_note: Label = %FreezerEmpty
@onready var scroll: ScrollContainer = %FreezerScroll  ## the rows in view
@onready var list: VBoxContainer = %FreezerList
@onready var lead: Control = %FreezerList/Lead  ## stands for the rows before the first one made
@onready var tail: Control = %FreezerList/Tail  ## and for those after the last

var entries: Array[Dictionary] = []
var _shown_info: Array[Dictionary] = []  ## the entries whose details are open
var _rows: Array[Control] = []  ## the rows made, in order: row k shows entry _first + k
var _first := 0
var _row_height := 0.0  ## a row's height without its details
var _details_height := 0.0  ## the details line's height and the gap above it
var _measured_at := 0  ## the font size the heights were measured at


func _ready() -> void:
	actions.freeze_requested.connect(freeze_requested.emit)
	actions.trash_requested.connect(trash_requested.emit)
	scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _lay_out())
	refresh()


func add(entry: Dictionary) -> void:
	entries.append(entry)
	refresh()


func remove(entry: Dictionary) -> void:
	entries.erase(entry)
	_shown_info.erase(entry)
	refresh()


## The entries changed: the rows in view are shown afresh.
func refresh() -> void:
	empty_note.visible = entries.is_empty()
	scroll.visible = not entries.is_empty()
	_lay_out()


## The row made for `entry` (null when it is out of view and not made).
func row_for(entry: Dictionary) -> Control:
	var k := entries.find(entry) - _first
	return _rows[k] if k >= 0 and k < _rows.size() else null


## The rows made now (at most those in view and OVERSCAN either side).
func rows_made() -> int:
	return _rows.size()


## Makes the rows in view and OVERSCAN either side (and no more), shows in each the entry its place stands for, and sizes the spacers for the rest.
func _lay_out() -> void:
	if not is_node_ready():
		return
	var n := entries.size()
	if n == 0:
		_keep_rows(0)
		lead.visible = false
		tail.visible = false
		return
	_measure()
	var sep := float(list.get_theme_constant("separation"))
	var tops := PackedFloat32Array()  # (where each row begins, and past the last the whole height and a gap)
	tops.resize(n + 1)
	var y := 0.0
	for i in n:
		tops[i] = y
		y += _row_height + (_details_height if _shown_info.has(entries[i]) else 0.0) + sep
	tops[n] = y
	var height := minf(y - sep, SCROLL_MAX_HEIGHT)
	scroll.custom_minimum_size.y = height
	var top := float(scroll.scroll_vertical)
	var first := 0
	while first < n - 1 and tops[first + 1] <= top:
		first += 1
	var last := first
	while last < n and tops[last] < top + height:
		last += 1
	first = maxi(first - OVERSCAN, 0)
	last = mini(last + OVERSCAN, n)
	_first = first
	_keep_rows(last - first)
	lead.visible = first > 0
	lead.custom_minimum_size.y = tops[first] - sep
	tail.visible = last < n
	tail.custom_minimum_size.y = tops[n] - tops[last] - sep
	for k in _rows.size():
		_bind(_rows[k], entries[first + k])


## Makes or drops rows until there are `count`.
func _keep_rows(count: int) -> void:
	while _rows.size() < count:
		var box := _make_row()
		list.add_child(box)
		list.move_child(box, tail.get_index())
		_rows.append(box)
	while _rows.size() > count:
		var gone: Control = _rows.pop_back()
		list.remove_child(gone)  # (out of the list now; freed once whatever it is doing this frame is done)
		gone.queue_free()


## A row's and its details line's heights, measured on a row made for that (again when the text size changes).
func _measure() -> void:
	var size_now := get_theme_font_size("font_size", &"Label")
	if _row_height > 0.0 and size_now == _measured_at:
		return
	_measured_at = size_now
	var probe := _make_row()
	list.add_child(probe)  # (in the tree, so it has the theme's sizes)
	_bind(probe, {"number": 1000, "data": {"time": 0.0}, "bups": 1000000, "picture": null})
	_row_height = (probe.get_node("Row") as Control).get_combined_minimum_size().y
	var details: Label = probe.get_node("Details")
	_details_height = details.get_theme_font("font").get_height(details.get_theme_font_size("font_size")) + float(probe.get_theme_constant("separation"))  # (one line: an entry's details are short)
	list.remove_child(probe)
	probe.free()


func _make_row() -> Control:
	var box := VBoxContainer.new()
	box.theme_type_variation = &"TightStack"
	var row := HBoxContainer.new()
	row.name = "Row"
	box.add_child(row)
	var picture := TextureRect.new()
	picture.name = "Picture"
	var thumb := DishThumb.new()
	thumb.size = PICTURE_SIZE
	picture.texture = thumb
	picture.custom_minimum_size = Vector2(PICTURE_SIZE, PICTURE_SIZE)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(picture)
	var caption := Label.new()
	caption.name = "Caption"
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(caption)
	row.add_child(_icon_button("Unfreeze", UNFREEZE_ICON, Strings.t("hud.unfreeze_tip"), func() -> void: thaw_requested.emit(box.get_meta(&"entry"))))
	row.add_child(_icon_button("Info", INFO_ICON, Strings.t("hud.frozen_info_tip"), func() -> void: _toggle_info(box.get_meta(&"entry"))))
	row.add_child(_icon_button("Trash", TRASH_ICON, Strings.t("hud.frozen_trash_tip"), func() -> void: trash_entry_requested.emit(box.get_meta(&"entry"))))
	var details := Label.new()
	details.name = "Details"
	details.theme_type_variation = &"Note"
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(details)
	return box


## Shows `entry` in a row made before: its picture, number and bups, and its details when they are open.
func _bind(box: Control, entry: Dictionary) -> void:
	box.set_meta(&"entry", entry)
	var thumb := (box.get_node("Row/Picture") as TextureRect).texture as DishThumb
	var picture: Texture2D = entry.get("picture")
	thumb.atlas = picture
	thumb.region = Rect2(Vector2.ZERO, picture.get_size()) if picture != null else Rect2()
	(box.get_node("Row/Picture") as TextureRect).queue_redraw()
	(box.get_node("Row/Caption") as Label).text = Strings.t("hud.frozen_row", [entry["number"], UiText.thousands(entry["bups"])])
	var details: Label = box.get_node("Details")
	details.text = Strings.t("hud.frozen_info", [SimClock.format(float(entry["data"].get("time", 0.0))), UiText.thousands(entry["bups"])])
	details.visible = _shown_info.has(entry)


func _icon_button(button_name: String, icon: Texture2D, tip: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = button_name
	button.theme_type_variation = &"IconButton"
	button.icon = icon
	button.tooltip_text = tip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button


func _toggle_info(entry: Dictionary) -> void:
	if _shown_info.has(entry):
		_shown_info.erase(entry)
	else:
		_shown_info.append(entry)
	refresh()
