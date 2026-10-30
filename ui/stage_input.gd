class_name StageInput
extends RefCounted
## The camera and the pointer on the stage (the free middle of the screen where the dish is framed): framing, panning
## (drag, keys), zooming (wheel, pinch, trackpad, buttons), following a bup, what the select tool hovers and the
## placement preview, and the reading of a press as a click, a drag or a brush stroke. A click (or each place of a
## brush stroke) is passed on as `clicked`: what it does depends on the tool, and that is the screen's.

## A click at a world position, or one place of a brush stroke.
signal clicked(world: Vector2)

const ZOOM_MIN := 0.002  ## low enough to fit the largest dish (90000 µm in radius) in a window
const ZOOM_MAX := 12.0  ## close enough that a bup (a few µm) fills a good part of the window
const ZOOM_BUTTON_STEP := 1.25
const ZOOM_WHEEL_STEP := 1.1
const ZOOM_PINCH_GAIN := 1.0  ## a trackpad pinch zooms by its own factor, to this power
const ZOOM_TRACKPAD_SCROLL := 0.05  ## a two-finger scroll zooms by ZOOM_WHEEL_STEP to the power of this for each unit it moves
const PAINT_MIN_PIXELS := 24.0  ## the least screen distance between two places of a drag with a brush tool (so that a small brush does not stamp every pixel)
const PAINT_MAX_STEPS := 60  ## the most places one pointer movement makes (a fast sweep across the dish is not worth more than this)
const PAN_KEY_PIXELS := 600.0  ## screen pixels a second the view moves while a pan key (W, A, S or D) is held
const FIT_MARGIN := 24.0  ## screen pixels kept clear round the dish when framing it in the stage
const TRAY_RESERVE := 48.0  ## at the top of the stage, room for the tool options that open there (kept whether they are open or not, so choosing a tool never moves the dish)
const PICK_SLACK_PIXELS := 4.0  ## how far outside a bup (in screen pixels) still counts as pointing at it

var host: Node2D  ## the screen: the pointer is read in its coordinates
var camera: Camera2D
var stage: Control
var tool_options: ToolOptions
var dish: Dish  ## the dish in the main view
var tool := Toolbar.Tool.SELECT  ## the selected tool (the screen sets it)
var following_id := -1  ## the bup the camera is keeping in the middle of the view, or -1
var view_moved := false  ## the view was panned or zoomed by hand: a change of the window does not frame the dish again
var hover_point := Vector2.ZERO  ## the spot in the dish the pointer is over, for the select tool's readout
var hovering_point := false  ## whether that spot is what the select tool is over (the medium, with nothing else under the pointer)
var _pointer_stamp := []  ## what the hover and placement preview were last worked out from
var _press_button := MOUSE_BUTTON_NONE
var _press_position := Vector2.ZERO
var _dragging := false
var _painting := false  ## the left button is down with a brush tool: the pointer's path is painted, and does not pan
var _paint_last := Vector2.ZERO  ## where the brush last placed something (world position)
var _drag_threshold: float = ProjectSettings.get_setting("gui/common/drag_threshold", 10)


## Whether a drag is panning the view.
func is_dragging() -> bool:
	return _dragging


## Frames the whole dish in the stage (the layout leaves it clear), but never zooms in past 1:1.
func fit_camera() -> void:
	view_moved = false
	var view := host.get_viewport_rect().size
	var area := Rect2(Vector2.ZERO, view)
	if host.is_node_ready() and stage.size.x > 0.0:
		area = stage.get_global_rect()
		area = Rect2(area.position + Vector2(0.0, TRAY_RESERVE), area.size - Vector2(0.0, TRAY_RESERVE))
	var room := minf((area.size.x - 2.0 * FIT_MARGIN) * 0.5, (area.size.y - 2.0 * FIT_MARGIN) * 0.5)
	room = maxf(room, 40.0)
	camera.zoom = Vector2.ONE * clampf(room / dish.radius, ZOOM_MIN, 1.0)
	camera.position = dish.global_position - _centre_shift(area, view) / camera.zoom.x


## Screen pixels the middle of `area` (what the tray and rail leave clear) sits from the window's middle, which is where the camera looks.
func _centre_shift(area: Rect2, view: Vector2) -> Vector2:
	return area.get_center() - view * 0.5


## The panels know their sizes a frame or two after the screen is made: frames the dish again then (unless the player has moved the view).
func refit_when_laid_out() -> void:
	var before := camera.position
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	if host.is_inside_tree() and camera.position.is_equal_approx(before) and following_id < 0:
		fit_camera()


## The stage changed size (the window, or the interface size): the dish is framed again, unless the view has been moved.
func on_stage_resized() -> void:
	if following_id < 0 and not view_moved:
		fit_camera()


## Notes where the dish is being looked at (and stops following), for when its view comes back: called as another dish comes into view.
func remember_view() -> void:
	following_id = -1
	dish.view_zoom = camera.zoom.x
	dish.view_position = camera.position


## Puts the camera where the dish was last looked at, or frames it if it has not been looked at yet.
func restore_view() -> void:
	if dish.view_zoom > 0.0:
		camera.zoom = Vector2.ONE * dish.view_zoom
		camera.position = dish.view_position
	else:
		fit_camera()


## Keeps the camera over the dish after it has been made smaller.
func keep_on_dish() -> void:
	camera.position = dish.global_position + (camera.position - dish.global_position).limit_length(dish.radius)


## Brings the camera close over a world position (inside the dish).
func look_at_world(world: Vector2, zoom: float) -> void:
	camera.zoom = Vector2.ONE * zoom
	camera.position = dish.global_position + (world - dish.global_position).limit_length(dish.radius)


func stop_following() -> void:
	following_id = -1


## Follow: the camera keeps the selected bup in the middle of the view until the player stops it,
## pans, selects something else, or the bup dies.
func toggle_follow() -> void:
	following_id = -1 if following_id >= 0 else dish.selected.bup
	follow_selected()


func follow_selected() -> void:
	if following_id >= 0 and (following_id != dish.selected.bup or not dish.has_bup(following_id)):
		following_id = -1
	if following_id >= 0:
		var view := host.get_viewport_rect().size
		var shift := Vector2.ZERO  # (the bup is kept in the middle of what the tray leaves clear, not of the window)
		if host.is_node_ready() and stage.size.x > 0.0:
			shift = _centre_shift(stage.get_global_rect(), view)
		camera.position = dish.bup_world_pos(following_id) - shift / camera.zoom.x


func pick_slack() -> float:
	return PICK_SLACK_PIXELS / camera.zoom.x


## Whether the pointer is over one of the HUD's panels or lists: a wheel or a trackpad scroll there is the list's, and
## never the zoom's, even when the list has nowhere left to scroll.
func over_hud() -> bool:
	return host.get_viewport().gui_get_hovered_control() != null


## Reads a mouse or trackpad event (others are ignored).
func handle(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)
	elif event is InputEventMagnifyGesture:  # a trackpad pinch: apart zooms in
		if not over_hud():
			zoom_by(pow(event.factor, ZOOM_PINCH_GAIN))
	elif event is InputEventPanGesture:  # a trackpad's two-finger scroll, which stands in for the mouse wheel (up zooms in)
		if not over_hud():
			zoom_by(pow(ZOOM_WHEEL_STEP, -event.delta.y * ZOOM_TRACKPAD_SCROLL * UserSettings.scroll_speed))


func _on_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed and not over_hud():
				zoom_by(pow(ZOOM_WHEEL_STEP, UserSettings.scroll_speed))
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed and not over_hud():
				zoom_by(pow(ZOOM_WHEEL_STEP, -UserSettings.scroll_speed))
		MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				host.get_viewport().gui_release_focus()  # so keys go to shortcuts, not the nutrient box
				_press_button = event.button_index
				_press_position = event.position
				_dragging = event.button_index == MOUSE_BUTTON_MIDDLE or tool == Toolbar.Tool.PAN
				_painting = event.button_index == MOUSE_BUTTON_LEFT and _is_brush(tool)
				if _painting:  # (a brush tool acts where the button goes down, and goes on along the drag: it never pans)
					_paint_last = host.make_input_local(event).position
					clicked.emit(_paint_last)
			elif event.button_index == _press_button:
				if not _dragging and not _painting:
					clicked.emit(host.make_input_local(event).position)
				_press_button = MOUSE_BUTTON_NONE
				_dragging = false
				_painting = false


func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _press_button == MOUSE_BUTTON_NONE:
		return
	# The release may have been eaten by the GUI (or happened outside the window), so trust the
	# button state this event reports rather than waiting for a release we may never see.
	var held_mask := MOUSE_BUTTON_MASK_MIDDLE if _press_button == MOUSE_BUTTON_MIDDLE else MOUSE_BUTTON_MASK_LEFT
	if event.button_mask & held_mask == 0:
		_press_button = MOUSE_BUTTON_NONE
		_dragging = false
		_painting = false
		return
	if _painting:
		_paint_to(host.make_input_local(event).position)
		return
	if not _dragging and event.position.distance_to(_press_position) > _drag_threshold:
		_dragging = true
	if _dragging:
		_pan_camera(-event.relative / camera.zoom.x)


## The tools that place something along a drag (the nutrient dose, the plankton and the eraser), and so do not pan with the left button.
func _is_brush(which: Toolbar.Tool) -> bool:
	return which == Toolbar.Tool.NUTRIENT or which == Toolbar.Tool.PLANKTON or which == Toolbar.Tool.ERASE


## The world distance between two places of a drag: the brush's own width, and never less than PAINT_MIN_PIXELS on the screen.
func paint_spacing() -> float:
	var width := 0.0
	match tool:
		Toolbar.Tool.ERASE:
			width = tool_options.brush_radius()
		Toolbar.Tool.NUTRIENT:
			width = Dish.scatter_radius(tool_options.nutrient_count())
		Toolbar.Tool.PLANKTON:
			width = Dish.PLANKTON_PATCH_RADIUS
	return maxf(width, PAINT_MIN_PIXELS / camera.zoom.x)


## Carries the brush from where it last placed something to `world`, placing at every spacing along the way.
func _paint_to(world: Vector2) -> void:
	var spacing := paint_spacing()
	var steps := 0
	while _paint_last.distance_to(world) >= spacing and steps < PAINT_MAX_STEPS:
		_paint_last = _paint_last.move_toward(world, spacing)
		clicked.emit(_paint_last)
		steps += 1
	if steps == PAINT_MAX_STEPS:
		_paint_last = world  # (a sweep past the cap carries on from here, not from where it fell short)


## Moves the view by `world_delta`, but never off the dish. Panning by hand takes over from following.
func _pan_camera(world_delta: Vector2) -> void:
	view_moved = true
	following_id = -1
	camera.position = dish.global_position + (camera.position + world_delta - dish.global_position).limit_length(dish.radius)


## W, A, S and D move the view while held. The keys are taken by their place on the keyboard, so they are the same four
## on any layout; nothing happens while a text box has the keyboard, or with Ctrl, Alt or Cmd held (those are shortcuts).
func pan_with_keys(delta: float) -> void:
	var focus := host.get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_META):
		return
	var direction := Vector2(
		float(Input.is_key_pressed(KeyBindings.key("pan_right"))) - float(Input.is_key_pressed(KeyBindings.key("pan_left"))),
		float(Input.is_key_pressed(KeyBindings.key("pan_down"))) - float(Input.is_key_pressed(KeyBindings.key("pan_up"))))
	if direction != Vector2.ZERO:
		_pan_camera(direction.normalized() * PAN_KEY_PIXELS * delta / camera.zoom.x)


## Zooms about the selected bup or source, so it stays where it is on the screen. With nothing selected, or the
## selection out of view, it zooms about the middle of the view.
func zoom_by(factor: float) -> void:
	view_moved = true
	var old_zoom := camera.zoom.x
	camera.zoom = Vector2.ONE * clampf(old_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	var anchor: Variant = _selected_world_pos()
	if anchor != null and _on_screen(anchor, old_zoom):  # (a selection scrolled out of view is no anchor)
		camera.position = anchor - (anchor - camera.position) * old_zoom / camera.zoom.x


## Whether a world position is inside the window at this zoom.
func _on_screen(world_pos: Vector2, zoom: float) -> bool:
	var view := host.get_viewport_rect().size
	return Rect2(Vector2.ZERO, view).has_point((world_pos - camera.position) * zoom + view * 0.5)


## Where the selected bup or source is in the world, or null when nothing is selected.
func _selected_world_pos() -> Variant:
	if dish.has_bup(dish.selected.bup):
		return dish.bup_world_pos(dish.selected.bup)
	if dish.selected.source != null:
		return dish.selected.source.pos
	if dish.selected.plankton != null:
		return dish.global_position + dish.selected.plankton.pos
	if dish.selected.husk != Dish.NO_HUSK:
		return dish.global_position + dish.selected.husk
	return null


## Hover highlight (select tool) and the placement preview (the placing tools).
func update_pointer() -> void:
	# Nothing to look at again when neither the pointer, the view, the dish nor the tool has changed.
	var viewport := host.get_viewport()
	var stamp := [viewport.get_mouse_position(), camera.position, camera.zoom, dish.get_instance_id(), dish.time, dish.edit_count, dish.radius, tool, _dragging, viewport.gui_get_hovered_control() != null, tool_options.nutrient_count(), tool_options.brush_radius(), dish.pick_mode]
	if stamp == _pointer_stamp:
		return
	_pointer_stamp = stamp
	dish.clear_hover()
	dish.clear_place_preview()
	hovering_point = false
	# Skip while the mouse is over the toolbar/panels, or mid-drag.
	if _dragging or viewport.gui_get_hovered_control() != null:
		return
	var world := host.get_global_mouse_position()
	if not dish.contains(world):
		return
	match tool:
		Toolbar.Tool.SELECT:
			hover_at(world)
		Toolbar.Tool.NUTRIENT:
			if dish.can_place_at(world):  # no ring where a click would do nothing
				dish.set_place_preview(world, Dish.scatter_radius(tool_options.nutrient_count()))
		Toolbar.Tool.SOURCE:
			if dish.can_place_at(world):
				dish.set_place_preview(world, dish.source_draw_radius(), Dish.Preview.MARKER)  # a ring like a selection's: same size at any zoom
		Toolbar.Tool.PLANKTON:
			if dish.can_place_at(world):
				dish.set_place_preview(world, dish.plankton_draw_radius(), Dish.Preview.MARKER)
		Toolbar.Tool.ERASE:
			dish.set_place_preview(world, tool_options.brush_radius(), Dish.Preview.ERASE)
		Toolbar.Tool.PIPETTE:
			dish.set_place_preview(world, tool_options.pipette_radius())


## What the select tool is over at a world point, under the pick mode: a bup, a source, or else the medium itself.
func hover_at(world: Vector2) -> void:
	dish.hover_at(world, pick_slack())
	hover_point = world
	hovering_point = dish.looks_at_medium()
