extends Node
## Keeps a scroll inside the panel it began in (autoload "ScrollKeep"). A list that is scrolled to its end passes the rest of the wheel to the panel round it, which
## then scrolls instead, so a fast scroll through a long list ends by throwing the whole side column down. A scroll container that holds another one that can scroll now
## takes any wheel or two-finger scroll that the pointer makes over that one, and the engine does not pass on.


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
