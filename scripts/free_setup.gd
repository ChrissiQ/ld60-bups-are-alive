extends Control
## Free-mode setup: choose the starting conditions, preview them, then GO.

const PREVIEW_RADIUS := 260.0  ## on-screen size the preview dish is shrunk to fit
const PREVIEW_SEED := 1964  ## fixed so the preview doesn't reshuffle on every nudge

@onready var dish: Dish = $Dish
@onready var bups_row: SettingRow = $Panel/Box/BupsRow
@onready var nutrients_row: SettingRow = $Panel/Box/NutrientsRow
@onready var rate_row: SettingRow = $Panel/Box/RateRow
@onready var bloom_row: SettingRow = $Panel/Box/BloomRow
@onready var dish_row: SettingRow = $Panel/Box/DishRow
@onready var limit_row: SettingRow = $Panel/Box/LimitRow
@onready var back_button: Button = $Panel/Box/Actions/BackButton
@onready var go_button: Button = $Panel/Box/Actions/GoButton
@onready var reset_button: Button = $Panel/Box/Header/ResetButton

var _start: StartConditions  ## working copy; only committed on GO


func _ready() -> void:
	_start = Session.free_start.copy()
	var defaults := StartConditions.new()

	bups_row.configure(StartConditions.MIN_BUPS, StartConditions.MAX_BUPS, 1, defaults.bups)
	nutrients_row.configure(0, StartConditions.MAX_NUTRIENT_DENSITY, 1, defaults.nutrient_density, Strings.t("free_setup.unit_nutrient"))
	rate_row.configure(0, StartConditions.MAX_FEED_DENSITY, 0.1, defaults.feed_density, Strings.t("free_setup.unit_feed"))
	bloom_row.configure(0, StartConditions.MAX_BLOOM_RATE, Dish.BLOOM_RATE_STEP, defaults.bloom_rate, Strings.t("free_setup.unit_bloom"))
	dish_row.configure(StartConditions.MIN_DISH_RADIUS / StartConditions.UM_PER_MM, StartConditions.MAX_DISH_RADIUS / StartConditions.UM_PER_MM, 0.1, defaults.dish_radius / StartConditions.UM_PER_MM, Strings.t("ui.mm_unit"))  # the dish is chosen in mm; the simulation works in µm
	limit_row.configure(StartConditions.MIN_BUP_LIMIT, StartConditions.MAX_BUP_LIMIT, 1, defaults.bup_limit)
	bups_row.value = _start.bups
	nutrients_row.value = _start.nutrient_density
	rate_row.value = _start.feed_density
	bloom_row.value = _start.bloom_rate
	dish_row.value = _start.dish_radius / StartConditions.UM_PER_MM
	limit_row.value = _start.bup_limit
	# A saved value off the slider's step grid shows rounded, so take what the sliders hold,
	# so that what's shown, previewed and played are always the same number.
	_start.bups = int(bups_row.value)
	_start.nutrient_density = nutrients_row.value
	_start.feed_density = rate_row.value
	_start.bloom_rate = bloom_row.value
	_start.dish_radius = snappedf(dish_row.value * StartConditions.UM_PER_MM, 1.0)
	_start.bup_limit = int(limit_row.value)
	bups_row.value_changed.connect(func(v: float) -> void: _start.bups = int(v); _sync_limit_floor(); _refresh())
	nutrients_row.value_changed.connect(func(v: float) -> void: _start.nutrient_density = v; _refresh())
	rate_row.value_changed.connect(func(v: float) -> void: _start.feed_density = v; _refresh())
	bloom_row.value_changed.connect(func(v: float) -> void: _start.bloom_rate = v; _refresh())
	dish_row.value_changed.connect(func(v: float) -> void: _start.dish_radius = snappedf(v * StartConditions.UM_PER_MM, 1.0); _refresh())
	limit_row.value_changed.connect(func(v: float) -> void: _start.bup_limit = int(v); _refresh())

	_sync_limit_floor()
	back_button.pressed.connect(_back)
	reset_button.pressed.connect(_reset_to_defaults)
	reset_button.tooltip_text = Strings.t("free_setup.defaults_tip")
	go_button.pressed.connect(_go)
	dish.position = _dish_center()
	_refresh()
	bups_row.slider.grab_focus()


## The limit can't be lower than the number of founders, or some of them (with their names and colours) would never
## start: its slider's minimum follows the founders, and it rises with them if need be.
func _sync_limit_floor() -> void:
	var floor_limit := maxi(StartConditions.MIN_BUP_LIMIT, _start.bups)
	var wanted := maxi(int(limit_row.value), floor_limit)
	limit_row.configure(floor_limit, StartConditions.MAX_BUP_LIMIT, 1, maxi(StartConditions.new().bup_limit, floor_limit))
	limit_row.value = wanted
	_start.bup_limit = int(limit_row.value)


func _dish_center() -> Vector2:
	var size_now := get_viewport_rect().size
	return Vector2(size_now.x - PREVIEW_RADIUS - 40.0, size_now.y * 0.5)


func _process(_delta: float) -> void:
	if not dish.position.is_equal_approx(_dish_center()):
		dish.recenter(_dish_center())
		dish.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if UiInput.is_escape_press(event):
		_back()


func _refresh() -> void:
	dish.scale = Vector2.ONE * minf(1.0, PREVIEW_RADIUS / _start.dish_radius)
	# Preview the real thing: the same strike() the game will call.
	dish.set_seed(PREVIEW_SEED)
	dish.strike(_start)
	dish.flash = 0.0
	dish.queue_redraw()


## Loads the defaults into the sliders. Deliberately touches nothing else: the remembered
## choices only change when GO saves them, and backing out saves nothing.
func _reset_to_defaults() -> void:
	for row: SettingRow in [bups_row, nutrients_row, rate_row, bloom_row, dish_row, limit_row]:
		row.value = row.default_value


func _go() -> void:
	var chosen := _start.copy()
	Session.free_start = chosen
	chosen.save()  # so the next launch starts from these
	Session.mode = Session.Mode.FREE
	Session.load_requested = false
	get_tree().change_scene_to_file(Scenes.FOUNDERS)  # the founders are named and coloured next, then the dish starts


func _back() -> void:
	get_tree().change_scene_to_file(Scenes.MENU)
