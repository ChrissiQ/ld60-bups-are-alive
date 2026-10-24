extends Node
## F12 on any screen writes the debug log and a screenshot (see DebugLog), then says so for a few seconds (autoload
## "DebugHotkey"). The screen can add what only it knows by having a `debug_state()` method, and its dish (if it has one) is
## the one in the log: a `dish` property.

const NOTICE_SECONDS := 3.0  ## how long the notice stays up
const FREEZE_FRAMES := 3  ## frames the game stands still before the screenshot is taken, so the picture has caught up with the state the log reads

@onready var notice: Label = $Layer/Notice

var _notice_left := 0.0
var _logging := false  ## the log is being written (it waits a frame for the screenshot)


func _ready() -> void:
	get_tree().node_added.connect(_watch_window)  # (a dialog is a window of its own: its keys never reach the main one)


## Listens to a window's own keys too, for the dialogs (a "start over?" question) that have the keyboard while they are up.
func _watch_window(node: Node) -> void:
	if node is Window and node != get_tree().root and not node.window_input.is_connected(_on_window_input):
		node.window_input.connect(_on_window_input)


func _on_window_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F12:
		write()


func _process(delta: float) -> void:
	_notice_left = maxf(0.0, _notice_left - delta)
	notice.visible = _notice_left > 0.0


## Before anything else sees the key, so that no screen (a menu, the tour) can take it.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F12:
		write()
		get_viewport().set_input_as_handled()


## Writes the log and a screenshot (taken once the frame has been drawn, without the notice in it), then says so. The game is held
## for those frames (and put back as it was after), so the screenshot and the log show the same instant.
func write() -> void:
	if _logging:
		return
	_logging = true
	notice.visible = false
	_notice_left = 0.0
	var was_paused := get_tree().paused
	get_tree().paused = true
	for i in FREEZE_FRAMES:
		await get_tree().process_frame  # (in a window these are drawn, and the picture catches up with the frozen state)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw  # (nothing is drawn headless, so no frame ever finishes drawing)
	var screenshot: Image = null
	if DisplayServer.get_name() != "headless":
		screenshot = get_viewport().get_texture().get_image()
	var scene := get_tree().current_scene
	var dish: Dish = scene.get("dish") if scene != null else null
	var state: Dictionary = scene.debug_state() if scene != null and scene.has_method("debug_state") else {}
	var path := DebugLog.write(DebugLog.report(dish, scene, state), screenshot)
	get_tree().paused = was_paused
	notice.text = Strings.t("debug.logged" if path != "" else "debug.failed")
	_notice_left = NOTICE_SECONDS
	notice.visible = true
	_logging = false
