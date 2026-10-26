class_name DishStrip
extends PanelContainer
## Every dish that is running, a tab each in the top bar: a small live picture of it and its number (the bups it holds are in its tip). The picture is a small
## viewport that looks at the same world through its own camera; each is redrawn once a second, one dish at a time so the cost is spread over the second.
## The dish in the main view is lit, and a click on another reports it (`dish_chosen`) for the screen to bring into the main view. The strip is hidden
## while there is only one dish.

signal dish_chosen(dish: Dish)

const REFRESH_SECONDS := 1.0  ## how often the counts are read, and each picture is redrawn
const THUMB := 44  ## pixels across a picture (shown smaller, so it stays sharp on a dense display)
const MARGIN := 1.05  ## the dish fills this share of the picture (its rim is not cut off)

var max_width := 240.0:  ## the most width the tabs take; with more tabs than fit, they scroll
	set(value):
		max_width = value
		_fit()

@onready var scroll: ScrollContainer = $Scroll  ## the tabs scroll sideways inside a width the top bar can afford (see `max_width`)
@onready var row: HBoxContainer = $Scroll/Row

var _entries: Array[Dictionary] = []  ## {dish, number, button, viewport, camera}
var _since := REFRESH_SECONDS
var _since_picture := 0.0
var _next_picture := 0  ## the entry whose picture is redrawn next
var _group := ButtonGroup.new()


func add(dish: Dish, number: int, world: World2D) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(THUMB, THUMB)
	viewport.world_2d = world
	viewport.transparent_bg = true  # (only the dish itself is seen, a round picture)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var camera := Camera2D.new()
	viewport.add_child(camera)
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
	var camera: Camera2D = entry["camera"]
	camera.global_position = dish.global_position
	camera.zoom = Vector2.ONE * (THUMB / (2.0 * dish.radius * MARGIN))
	entry["viewport"].render_target_update_mode = SubViewport.UPDATE_ONCE


func _name(entry: Dictionary) -> void:
	var dish: Dish = entry["dish"]
	var bups := UiText.thousands(dish.population())
	var button: Button = entry["button"]
	button.text = Strings.t("dishes.caption", [entry["number"]])
	button.tooltip_text = Strings.t("dishes.tip", [entry["number"], bups])


## The tabs take the width they need, up to `max_width`.
func _fit() -> void:
	if not is_node_ready():
		return
	scroll.custom_minimum_size.x = minf(row.get_combined_minimum_size().x, max_width)


## The width all the tabs together would need.
func full_width() -> float:
	return row.get_combined_minimum_size().x
