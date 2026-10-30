extends Node
## Keeps a scroll inside the panel it began in (autoload "ScrollKeep"). A list that is scrolled to its end passes the rest of the wheel to the panel round it, which
## then scrolls instead, so a fast scroll through a long list ends by throwing the whole side column down. A scroll container that holds another one that can scroll now
## takes any wheel or two-finger scroll that the pointer makes over that one, and the engine does not pass on. A list that can scroll takes the scroll itself,
## by `UserSettings.scroll_speed` times the engine's step (an eighth of the page for a click of the wheel).

const WHEEL_STEP_OF_PAGE := 0.125


func _ready() -> void:
	get_tree().node_added.connect(_watch)
	_watch_all(get_tree().root)


func _watch_all(node: Node) -> void:
	_watch(node)
	for child in node.get_children():
		_watch_all(child)


func _watch(node: Node) -> void:
	if node is ScrollContainer and not node.gui_input.is_connected(_on_input.bind(node)):
		node.gui_input.connect(_on_input.bind(node))


func _on_input(event: InputEvent, outer: ScrollContainer) -> void:
	if not UiInput.is_scroll(event):
		return
	var local := Vector2.ZERO  # (the event's place is in the container's own coordinates)
	if event is InputEventMouse:
		local = (event as InputEventMouse).position
	elif event is InputEventGesture:
		local = (event as InputEventGesture).position
	var point := outer.get_global_transform() * local
	if UiInput.holds_scrollable_at(outer, point):
		outer.accept_event()
		return
	_scroll(event, outer)


## Scrolls the container by the event, at the user's scroll speed, when it has something to scroll that way.
func _scroll(event: InputEvent, outer: ScrollContainer) -> void:
	var step := Vector2.ZERO  # (in pages of the bar: x along, y down)
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if not button.pressed:
			return
		match button.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				step.y = -button.factor * WHEEL_STEP_OF_PAGE
			MOUSE_BUTTON_WHEEL_DOWN:
				step.y = button.factor * WHEEL_STEP_OF_PAGE
			MOUSE_BUTTON_WHEEL_LEFT:
				step.x = -button.factor * WHEEL_STEP_OF_PAGE
			MOUSE_BUTTON_WHEEL_RIGHT:
				step.x = button.factor * WHEEL_STEP_OF_PAGE
	elif event is InputEventPanGesture:
		step = (event as InputEventPanGesture).delta * WHEEL_STEP_OF_PAGE
	var moved := false
	for axis in 2:
		var bar: ScrollBar = outer.get_v_scroll_bar() if axis == 1 else outer.get_h_scroll_bar()
		if step[axis] != 0.0 and bar.max_value > bar.page:
			bar.value += step[axis] * bar.page * UserSettings.scroll_speed
			moved = true
	if moved:
		outer.accept_event()
