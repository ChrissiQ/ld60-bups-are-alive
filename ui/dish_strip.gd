class_name DishStrip
extends PanelContainer
## Every dish that is running, a thumbnail each along the bottom edge. The thumbnails are live: a small viewport looks at the same world through its own
## camera and is redrawn once a second. Each shows its number and how many bups it holds; the dish in the main view is lit, and a click on another reports
## it (`dish_chosen`) for the screen to bring into the main view. The strip is hidden while there is only one dish.

signal dish_chosen(dish: Dish)

const THUMB := 56  ## pixels across a thumbnail
const REFRESH_SECONDS := 1.0  ## how often the thumbnails are redrawn and the counts read
const MARGIN := 1.05  ## the dish fills this share of the thumbnail (its rim is not cut off)

@onready var row: HBoxContainer = $Row

var _entries: Array[Dictionary] = []  ## {dish, number, button, viewport, camera}
var _since := REFRESH_SECONDS


func add(dish: Dish, number: int, world: World2D) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(THUMB, THUMB)
	viewport.world_2d = world
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var camera := Camera2D.new()
	viewport.add_child(camera)
	add_child(viewport)
	var button := Button.new()
	button.theme_type_variation = &"DishButton"
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.icon = viewport.get_texture()
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	button.custom_minimum_size = Vector2(THUMB + 8, THUMB + 22)
	button.pressed.connect(func() -> void: dish_chosen.emit(dish))
	row.add_child(button)
	_entries.append({"dish": dish, "number": number, "button": button, "viewport": viewport, "camera": camera})
	_since = REFRESH_SECONDS
	visible = _entries.size() > 1


func remove(dish: Dish) -> void:
	for i in _entries.size():
		if _entries[i]["dish"] == dish:
			_entries[i]["button"].queue_free()
			_entries[i]["viewport"].queue_free()
			_entries.remove_at(i)
			break
	visible = _entries.size() > 1


func clear() -> void:
	for entry in _entries:
		entry["button"].queue_free()
		entry["viewport"].queue_free()
	_entries.clear()
	visible = false


func count() -> int:
	return _entries.size()


## Lights the thumbnail of the dish in the main view.
func light(main_dish: Dish) -> void:
	for entry in _entries:
		entry["button"].set_pressed_no_signal(entry["dish"] == main_dish)


## Called every frame: now and then the counts are read and the thumbnails redrawn.
func refresh(delta: float) -> void:
	_since += delta
	if _since < REFRESH_SECONDS:
		return
	_since = 0.0
	for entry in _entries:
		var dish: Dish = entry["dish"]
		var camera: Camera2D = entry["camera"]
		camera.global_position = dish.global_position
		camera.zoom = Vector2.ONE * (THUMB / (2.0 * dish.radius * MARGIN))
		entry["viewport"].render_target_update_mode = SubViewport.UPDATE_ONCE
		var bups := UiText.thousands(dish.population())
		var button: Button = entry["button"]
		button.text = Strings.t("dishes.caption", [entry["number"]])
		button.tooltip_text = Strings.t("dishes.tip", [entry["number"], bups])
