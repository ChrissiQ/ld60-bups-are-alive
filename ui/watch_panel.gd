class_name WatchPanel
extends PanelContainer
## The bups the player is watching (see Dish.watch_bup), in a scrolling list, youngest bup first and oldest last: each with its colour and its name
## (grey once it has died). Clicking one asks for it to be opened in the inspect panel (`bup_chosen`); the cross at
## its end takes it off the list. Shown only while there is something on the list. The list is rebuilt when it changes, and
## otherwise only the names and who is alive are looked at again, twice a second.

const CLOSE_ICON := preload("res://icons/close.svg")

signal bup_chosen(dish: Dish, id: int)

const LOOK_AGAIN_MSEC := 500
const SCROLL_MAX_HEIGHT := 150.0  ## the most the list takes before it scrolls

@onready var title: Label = $Box/Title
@onready var scroll: ScrollContainer = $Box/Scroll
@onready var entries: VBoxContainer = $Box/Scroll/Entries

var numbers := {}  ## Dish -> its number (the screen's own record, shared)
var dishes: Array[Dish] = []  ## every dish: the list is one for all of them (a bup the pipette moved is followed to its new dish)
var _version := ""  ## what this was built from: each dish's watch_version
var _entries_list: Array = []  ## [dish, id] for each entry, youngest first
var _looked_msec := 0
var _buttons := {}  ## [dish, bup id] -> its button, for the second look


## Called every frame by the screen that shows the panel.
func refresh() -> void:
	var count := 0
	var version := str(dishes.size())
	for d in dishes:
		count += d.watched.size()
		version += ":%d" % d.watch_version
	visible = count > 0
	if not visible:
		_version = ""  # (so it is built afresh when it next has something)
		return
	var now := Time.get_ticks_msec()
	if version == _version and now - _looked_msec < LOOK_AGAIN_MSEC:
		return
	_looked_msec = now
	if version != _version:
		_version = version
		_rebuild(count)
	else:
		for key: Array in _buttons:
			_style_entry(_buttons[key], key[0], key[1])


func _rebuild(count: int) -> void:
	for child in entries.get_children():
		entries.remove_child(child)
		child.queue_free()
	_buttons.clear()
	title.text = Strings.t("watch.title", [count])
	_entries_list = []
	for d in dishes:
		for id in d.watched:
			_entries_list.append([d, id])
	_entries_list.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1] if a[0] == b[0] else dishes.find(a[0]) < dishes.find(b[0]))  # (a dish's bups youngest first: the biggest number is the youngest)
	for pair: Array in _entries_list:
		var d: Dish = pair[0]
		var id: int = pair[1]
		var row := HBoxContainer.new()
		row.theme_type_variation = &"TightRow"
		var swatch := ColorRect.new()  # the bup's colour, so a clade can be followed by eye
		swatch.color = Genome.color_of(d.lineage_info(id))
		swatch.custom_minimum_size = Vector2(10.0, 10.0)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		var entry := Button.new()
		_style_entry(entry, d, id)
		entry.alignment = HORIZONTAL_ALIGNMENT_LEFT
		entry.focus_mode = Control.FOCUS_NONE
		entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		entry.clip_text = true
		entry.pressed.connect(bup_chosen.emit.bind(d, id))
		row.add_child(entry)
		var stop := Button.new()
		stop.icon = CLOSE_ICON
		stop.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stop.tooltip_text = Strings.t("watch.stop_tip")
		stop.theme_type_variation = &"IconButton"
		stop.focus_mode = Control.FOCUS_NONE
		stop.pressed.connect(d.unwatch_bup.bind(id))
		row.add_child(stop)
		entries.add_child(row)
		_buttons[[d, id]] = entry
	scroll.custom_minimum_size.y = clampf(entries.get_combined_minimum_size().y + 4.0, 24.0, SCROLL_MAX_HEIGHT)  # (as tall as its entries, up to this)
	reset_size.call_deferred()


## A bup that has died keeps its place on the list, with its name in grey. With several dishes each entry says which dish its bup is in.
func _style_entry(entry: Button, d: Dish, id: int) -> void:
	var where := Strings.t("watch.in_dish", [numbers.get(d, 0)]) if dishes.size() > 1 else ""
	entry.text = d.bup_name(id) + where
	entry.theme_type_variation = &"CompactListButton" if d.has_bup(id) else &"DeceasedListButton"
