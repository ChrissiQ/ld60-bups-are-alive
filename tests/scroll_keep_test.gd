extends SceneTree
## Run: godot --headless --path . -s tests/scroll_keep_test.gd
## A scroll that begins in a list stays in it: at the end of the list the wheel does not go on to the panel round it (ScrollKeep).


func _init() -> void:
	_run()


func _list(rows: int, height: float) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(200.0, height)
	var box := VBoxContainer.new()
	for i in rows:
		var row := Label.new()
		row.text = "row %d" % i
		box.add_child(row)
	scroll.add_child(box)
	return scroll


func _wheel(at: Vector2, button: MouseButton) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.global_position = at
		event.button_index = button
		event.pressed = pressed
		root.push_input(event, true)


func _run() -> void:
	var outer := ScrollContainer.new()
	outer.position = Vector2(10.0, 10.0)
	outer.custom_minimum_size = Vector2(240.0, 240.0)
	outer.size = Vector2(240.0, 240.0)
	var column := VBoxContainer.new()
	var long_list := _list(60, 100.0)
	var short_list := _list(2, 100.0)
	column.add_child(long_list)
	column.add_child(short_list)
	for i in 30:
		var filler := Label.new()
		filler.text = "below %d" % i
		column.add_child(filler)
	outer.add_child(column)
	root.add_child(outer)
	for i in 3:
		await process_frame
	var on_long := long_list.get_global_rect().get_center()
	var on_short := short_list.get_global_rect().get_center()
	TestUtil.check(UiInput.holds_scrollable_at(outer, on_long), "a list with more than it shows, under the pointer, keeps the wheel")
	TestUtil.check(not UiInput.holds_scrollable_at(outer, on_short), "a list that shows everything does not: the panel round it may scroll")
	TestUtil.check(not UiInput.holds_scrollable_at(outer, Vector2(15.0, 235.0)), "a pointer that is not over a list does not")
	TestUtil.check(UiInput.is_scroll(InputEventPanGesture.new()) and not UiInput.is_scroll(InputEventMouseMotion.new()), "wheel turns and trackpad scrolls count, other events do not")

	long_list.scroll_vertical = int(long_list.get_v_scroll_bar().max_value)  # (the end of the list)
	var before := outer.scroll_vertical
	for i in 5:
		_wheel(on_long, MOUSE_BUTTON_WHEEL_DOWN)
		await process_frame
	TestUtil.check(outer.scroll_vertical == before, "a wheel turned at the end of the list does not scroll the panel round it (%d, was %d)" % [outer.scroll_vertical, before])
	for i in 5:
		_wheel(on_short, MOUSE_BUTTON_WHEEL_DOWN)
		await process_frame
	TestUtil.check(outer.scroll_vertical > before, "over a list that has nothing to scroll the panel does scroll (%d)" % outer.scroll_vertical)

	# The scroll speed setting scales a list's scroll too.
	var speed_was := UserSettings.scroll_speed
	outer.scroll_vertical = 0
	await process_frame
	on_long = long_list.get_global_rect().get_center()
	var moved := []
	for speed in [1.0, 2.0, 0.5]:
		UserSettings.scroll_speed = speed
		long_list.scroll_vertical = 0
		_wheel(on_long, MOUSE_BUTTON_WHEEL_DOWN)
		await process_frame
		moved.append(long_list.get_v_scroll_bar().value)
	UserSettings.scroll_speed = speed_was
	var page: float = long_list.get_v_scroll_bar().page
	TestUtil.check(is_equal_approx(moved[0], page / 8.0) and is_equal_approx(moved[1], 2.0 * moved[0]) and is_equal_approx(moved[2], 0.5 * moved[0]), "a click of the wheel moves a list an eighth of a page at the usual speed, and the setting scales it (%s)" % [moved])
	TestUtil.finish(self, "SCROLL KEEP TESTS OK", "SCROLL KEEP TESTS FAILED:")
