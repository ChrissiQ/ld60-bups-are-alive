class_name WatchPanel
extends PanelContainer
## The bups the player is watching (see Dish.watch_bup), newest first, in a scrolling list: each with its colour and its name
## (grey once it has died). Clicking one asks for it to be opened in the inspect panel (`bup_chosen`); the cross at
## its end takes it off the list. Shown only while there is something on the list. The list is rebuilt when it changes, and
## otherwise only the names and who is alive are looked at again, twice a second.

signal bup_chosen(id: int)

const LOOK_AGAIN_MSEC := 500

@onready var title: Label = $Box/Title
@onready var entries: VBoxContainer = $Box/Scroll/Entries

var dish: Dish
var _version := -1  ## the dish's watch_version this was built from
var _looked_msec := 0
var _buttons := {}  ## bup id -> its button, for the second look


## Called every frame by the screen that shows the panel.
func refresh() -> void:
	visible = dish != null and not dish.watched.is_empty()
	if not visible:
		_version = -1  # (so it is built afresh when it next has something)
		return
	var now := Time.get_ticks_msec()
	if dish.watch_version == _version and now - _looked_msec < LOOK_AGAIN_MSEC:
		return
	_looked_msec = now
	if dish.watch_version != _version:
		_rebuild()
	else:
		for id: int in _buttons:
			_style_entry(_buttons[id], id)


func _rebuild() -> void:
	_version = dish.watch_version
	for child in entries.get_children():
		entries.remove_child(child)
		child.queue_free()
	_buttons.clear()
	title.text = Strings.t("watch.title", [dish.watched.size()])
	for id in dish.watched:
		var row := HBoxContainer.new()
		row.theme_type_variation = &"TightRow"
		var swatch := ColorRect.new()  # the bup's colour, so a clade can be followed by eye
		swatch.color = Genome.color_of(dish.lineage_info(id))
		swatch.custom_minimum_size = Vector2(10.0, 10.0)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		var entry := Button.new()
		_style_entry(entry, id)
		entry.alignment = HORIZONTAL_ALIGNMENT_LEFT
		entry.focus_mode = Control.FOCUS_NONE
		entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		entry.clip_text = true
		entry.pressed.connect(bup_chosen.emit.bind(id))
		row.add_child(entry)
		var stop := Button.new()
		stop.text = Strings.t("watch.stop")
		stop.tooltip_text = Strings.t("watch.stop_tip")
		stop.theme_type_variation = &"CompactListButton"
		stop.focus_mode = Control.FOCUS_NONE
		stop.pressed.connect(dish.unwatch_bup.bind(id))
		row.add_child(stop)
		entries.add_child(row)
		_buttons[id] = entry


## A bup that has died keeps its place on the list, with its name in grey.
func _style_entry(entry: Button, id: int) -> void:
	entry.text = dish.bup_name(id)
	entry.theme_type_variation = &"CompactListButton" if dish.has_bup(id) else &"DeceasedListButton"
