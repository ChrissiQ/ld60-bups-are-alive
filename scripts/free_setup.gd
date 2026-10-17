extends Control
## Free-mode setup: choose the starting conditions, preview them, then GO.

const PREVIEW_RADIUS := 300.0  ## on-screen size the preview dish is shrunk to fit
const PREVIEW_SEED := 1964  ## fixed so the preview doesn't reshuffle on every nudge

@onready var dish: Dish = $Dish
@onready var bups_row: SettingRow = $Panel/Box/BupsRow
@onready var nutrients_row: SettingRow = $Panel/Box/NutrientsRow
@onready var rate_row: SettingRow = $Panel/Box/RateRow
@onready var dish_row: SettingRow = $Panel/Box/DishRow
@onready var back_button: Button = $Panel/Box/Actions/BackButton
@onready var go_button: Button = $Panel/Box/Actions/GoButton
@onready var reset_button: Button = $ResetButton

var _start: StartConditions  ## working copy; only committed on GO


func _ready() -> void:
	_start = Session.free_start.copy()
	var defaults := StartConditions.new()

	bups_row.configure(StartConditions.MIN_BUPS, StartConditions.MAX_BUPS, 1, defaults.bups)
	nutrients_row.configure(0, StartConditions.MAX_NUTRIENTS, 1, defaults.nutrients)
	rate_row.configure(0, StartConditions.MAX_NUTRIENT_RATE, 1, defaults.nutrient_rate, "/s")
	dish_row.configure(StartConditions.MIN_DISH_RADIUS, StartConditions.MAX_DISH_RADIUS, 10, defaults.dish_radius)
	bups_row.value = _start.bups
	nutrients_row.value = _start.nutrients
	rate_row.value = _start.nutrient_rate
	dish_row.value = _start.dish_radius
	# A saved value off the slider's step grid shows rounded, so take what the sliders hold,
	# so that what's shown, previewed and played are always the same number.
	_start.bups = int(bups_row.value)
	_start.nutrients = int(nutrients_row.value)
	_start.nutrient_rate = rate_row.value
	_start.dish_radius = dish_row.value
	bups_row.value_changed.connect(func(v: float) -> void: _start.bups = int(v); _refresh())
	nutrients_row.value_changed.connect(func(v: float) -> void: _start.nutrients = int(v); _refresh())
	rate_row.value_changed.connect(func(v: float) -> void: _start.nutrient_rate = v; _refresh())
	dish_row.value_changed.connect(func(v: float) -> void: _start.dish_radius = v; _refresh())

	back_button.pressed.connect(_back)
	reset_button.pressed.connect(_reset_to_defaults)
	reset_button.tooltip_text = "Use defaults"
	go_button.pressed.connect(_go)
	dish.position = _dish_center()
	_refresh()
	bups_row.slider.grab_focus()


func _dish_center() -> Vector2:
	var size_now := get_viewport_rect().size
	return Vector2(size_now.x - PREVIEW_RADIUS - 40.0, size_now.y * 0.5)


func _process(_delta: float) -> void:
	if not dish.position.is_equal_approx(_dish_center()):
		dish.recenter(_dish_center())
		dish.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_back()


func _refresh() -> void:
	dish.scale = Vector2.ONE * minf(1.0, PREVIEW_RADIUS / _start.dish_radius)
	# Preview the real thing: the same strike() the game will call.
	dish.rng.seed = PREVIEW_SEED
	dish.strike(_start)
	dish.flash = 0.0
	dish.queue_redraw()


## Loads the defaults into the sliders. Deliberately touches nothing else: the remembered
## choices only change when GO saves them, and backing out saves nothing.
func _reset_to_defaults() -> void:
	for row: SettingRow in [bups_row, nutrients_row, rate_row, dish_row]:
		row.value = row.default_value


func _go() -> void:
	var chosen := _start.copy()
	Session.free_start = chosen
	chosen.save()  # so the next launch starts from these
	Session.mode = Session.Mode.FREE
	Session.load_requested = false
	get_tree().change_scene_to_file(Scenes.GAME)


func _back() -> void:
	get_tree().change_scene_to_file(Scenes.MENU)
