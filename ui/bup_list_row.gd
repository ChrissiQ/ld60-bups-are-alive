class_name BupListRow
extends RefCounted
## One row of a list of bups: the bup itself in its colour (so a clade can be followed by eye), then a button
## that holds its name. The lineage panel and the watch list share it, each giving its own button and sizes.


## The row for the bup described by `info` (see Dish.lineage_info). `entry` is the button the caller has made
## (its text, look and handler are the caller's); the row sets what every list entry has in common and returns
## the row, to which the caller may add more.
static func make(info: Dictionary, swatch_size: float, entry: Button, row_variation := &"") -> HBoxContainer:
	var row := HBoxContainer.new()
	if row_variation != &"":
		row.theme_type_variation = row_variation
	var swatch := BupPicture.new()
	swatch.show_info(info)
	swatch.custom_minimum_size = Vector2(swatch_size, swatch_size)
	swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(swatch)
	entry.alignment = HORIZONTAL_ALIGNMENT_LEFT
	entry.focus_mode = Control.FOCUS_NONE
	entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(entry)
	return row
