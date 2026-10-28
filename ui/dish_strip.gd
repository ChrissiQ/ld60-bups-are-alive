class_name DishStrip
extends PanelContainer
## Every dish that is running, a tab each in the top bar: a small live picture of it and its number (the bups it holds are in its tip). The picture is a small
## viewport that looks at the same world through its own camera; each is redrawn once a second, one dish at a time so the cost is spread over the second.
## The dish in the main view is lit, and a click on another reports it (`dish_chosen`) for the screen to bring into the main view. The strip is hidden
## while there is only one dish.

signal dish_chosen(dish: Dish)

const REFRESH_SECONDS := 1.0  ## how often the counts are read, and each picture is redrawn
const THUMB := 44  ## pixels across a picture (shown smaller, so it stays sharp on a dense display)
const REPEAT_DELAY := 0.4  ## seconds an arrow is held before it goes on by itself
const REPEAT_EVERY := 0.12  ## and then one tab every so many seconds
const MARGIN := 1.05  ## the dish fills this share of the picture (its rim is not cut off)

var max_width := 240.0:  ## the most width the tabs take; with more tabs than fit, they scroll
	set(value):
		max_width = value
		_fit()

@onready var scroll: ScrollContainer = $Bar/Scroll  ## the tabs scroll sideways inside a width the top bar can afford (see `max_width`)
@onready var row: HBoxContainer = $Bar/Scroll/Row
@onready var previous_button: Button = $Bar/Previous  ## an arrow at each end, there while the tabs do not all fit: a click moves by one tab, and holding goes on
@onready var next_button: Button = $Bar/Next

var _entries: Array[Dictionary] = []  ## {dish, number, button, viewport, camera}
var _since := REFRESH_SECONDS
var _since_picture := 0.0
var _next_picture := 0  ## the entry whose picture is redrawn next
var _group := ButtonGroup.new()
var main_zoomed_in := false  ## the main view shows only part of its dish: that dish's picture keeps its last one (it is drawn for the camera's zoom, not for the whole dish)
var main_dish: Dish
var _held := 0  ## the arrow held down: -1 the left one, 1 the right one, 0 none
var _held_for := 0.0  ## how long it has been held, from minus the delay before it starts repeating


func _ready() -> void:
	previous_button.button_down.connect(_press.bind(-1))
	next_button.button_down.connect(_press.bind(1))
	for button: Button in [previous_button, next_button]:
		button.button_up.connect(func() -> void: _held = 0)


func _process(delta: float) -> void:
	if not visible:
		return
	var most := scroll.get_h_scroll_bar().max_value - scroll.get_h_scroll_bar().page
	previous_button.disabled = scroll.scroll_horizontal <= 0
	next_button.disabled = scroll.scroll_horizontal >= most - 0.5
	if _held != 0:
		_held_for += delta
		while _held_for >= REPEAT_EVERY:
			_held_for -= REPEAT_EVERY
			_step(_held)


## An arrow went down: it moves by one tab now, and goes on moving while it is held (after a moment).
func _press(direction: int) -> void:
	_step(direction)
	_held = direction
	_held_for = -REPEAT_DELAY


## Scrolls to the next tab's edge in that direction (-1 left, 1 right), or to the end.
func _step(direction: int) -> void:
	var here := float(scroll.scroll_horizontal)
	var edges := row.get_children().map(func(tab: Node) -> float: return (tab as Control).position.x)
	var end := scroll.get_h_scroll_bar().max_value - scroll.get_h_scroll_bar().page
	var target := end if direction > 0 else 0.0
	if direction > 0:
		for edge: float in edges:
			if edge > here + 1.0:
				target = minf(edge, end)
				break
	else:
		for i in range(edges.size() - 1, -1, -1):
			if edges[i] < here - 1.0:
				target = edges[i]
				break
	scroll.scroll_horizontal = int(target)


func add(dish: Dish, number: int, world: World2D, dish_bit: int) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(THUMB, THUMB)
	viewport.world_2d = world
	viewport.transparent_bg = true  # (only the dish itself is seen, a round picture)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var camera := Camera2D.new()
	viewport.add_child(camera)
	viewport.canvas_cull_mask = (1 << dish_bit) | 1  # (its own dish, and layer 0 for the screen node the dish is a child of: an item that is culled takes its children with it)
	add_child(viewport)
	var button := Button.new()
	button.icon = viewport.get_texture()
	button.theme_type_variation = &"ChoiceButton"
	button.toggle_mode = true
	button.button_group = _group
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func() -> void: dish_chosen.emit(dish))
	row.add_child(button)
	_entries.append({"dish": dish, "number": number, "button": button, "viewport": viewport, "camera": camera})
	_since = REFRESH_SECONDS
	_name(_entries.back())
	_redraw(_entries.back())
	visible = _entries.size() > 1
	_fit.call_deferred()


func remove(dish: Dish) -> void:
	for i in _entries.size():
		if _entries[i]["dish"] == dish:
			_entries[i]["button"].queue_free()
			_entries[i]["viewport"].queue_free()
			_entries.remove_at(i)
			break
	visible = _entries.size() > 1
	_fit.call_deferred()


func clear() -> void:
	for entry in _entries:
		entry["button"].queue_free()
		entry["viewport"].queue_free()
	_entries.clear()
	visible = false


func count() -> int:
	return _entries.size()


## Lights the tab of the dish in the main view.
func light(main_dish: Dish) -> void:
	for entry in _entries:
		var lit: bool = entry["dish"] == main_dish
		entry["button"].set_pressed_no_signal(lit)
		if lit:
			scroll.ensure_control_visible.call_deferred(entry["button"])


## Called every frame: now and then the counts are read, and a picture is redrawn (each dish's once in REFRESH_SECONDS, one after another).
func refresh(delta: float) -> void:
	if not visible or _entries.is_empty():
		return
	_since_picture += delta
	if _since_picture >= REFRESH_SECONDS / _entries.size():
		_since_picture = 0.0
		_next_picture = (_next_picture + 1) % _entries.size()
		_redraw(_entries[_next_picture])
	_since += delta
	if _since < REFRESH_SECONDS:
		return
	_since = 0.0
	for entry in _entries:
		_name(entry)


## The picture of a dish as it was last drawn (as an image), or null when none has been drawn yet (a headless run draws nothing).
func picture_of(dish: Dish) -> Image:
	if DisplayServer.get_name() == "headless":
		return null
	for entry in _entries:
		if entry["dish"] == dish:
			var image: Image = (entry["viewport"] as SubViewport).get_texture().get_image()
			return image if image != null and not image.is_empty() else null
	return null


## Points the entry's camera at its dish and has the viewport draw one frame.
func _redraw(entry: Dictionary) -> void:
	var dish: Dish = entry["dish"]
	if main_zoomed_in and dish == main_dish and entry.get("drawn", false):
		return  # (it keeps the picture it has once it has one)
	entry["drawn"] = true
	var camera: Camera2D = entry["camera"]
	camera.global_position = dish.global_position
	var scale := THUMB / (2.0 * dish.radius * MARGIN)
	camera.zoom = Vector2.ONE * scale
	dish.prepare_picture(scale)  # (a dish that is not in the main view builds its picture only here)
	entry["viewport"].render_target_update_mode = SubViewport.UPDATE_ONCE


func _name(entry: Dictionary) -> void:
	var dish: Dish = entry["dish"]
	var bups := UiText.thousands(dish.population())
	var button: Button = entry["button"]
	button.text = Strings.t("dishes.caption", [entry["number"]])
	button.tooltip_text = Strings.t("dishes.tip", [entry["number"], bups])


## The tabs take the width they need, up to `max_width`; when they do not all fit the arrows come, out of that width.
func _fit() -> void:
	if not is_node_ready():
		return
	var needed := row.get_combined_minimum_size().x
	var overflow := needed > max_width
	previous_button.visible = overflow
	next_button.visible = overflow
	var arrows := 0.0
	if overflow:
		arrows = previous_button.get_combined_minimum_size().x + next_button.get_combined_minimum_size().x + 2.0 * float($Bar.get_theme_constant("separation"))
	scroll.custom_minimum_size.x = maxf(minf(needed, max_width - arrows), 24.0)


## The width all the tabs together would need.
func full_width() -> float:
	return row.get_combined_minimum_size().x
