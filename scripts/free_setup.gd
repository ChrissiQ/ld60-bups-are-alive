extends Control
## Free-mode setup: choose the starting conditions, preview them, then GO.

const PREVIEW_RADIUS := 260.0  ## on-screen size the preview dish is shrunk to fit
const PREVIEW_SEED := 1964  ## fixed so the preview doesn't reshuffle on every nudge
const TITLE_CLEARANCE := 130.0  ## screen pixels from the top that the settings panel keeps clear (the title is above that): the panel starts there and grows down
const BOTTOM_CLEARANCE := 24.0  ## and from the bottom
const PLANKTON_SETTLE_SECONDS := 0.5  ## how long the settings are still before the preview fills with plankton (up to thousands, so not on every nudge of a slider)

@onready var dish: Dish = $Dish
@onready var panel: PanelContainer = $Panel
@onready var scroll: ScrollContainer = $Panel/Box/Scroll  ## the rows, which scroll when there are more than fit below the title
@onready var rows: VBoxContainer = $Panel/Box/Scroll/Rows
@onready var bups_row: SettingRow = $Panel/Box/Scroll/Rows/BupsRow
@onready var nutrients_row: SettingRow = $Panel/Box/Scroll/Rows/NutrientsRow
@onready var rate_row: SettingRow = $Panel/Box/Scroll/Rows/RateRow
@onready var bloom_row: SettingRow = $Panel/Box/Scroll/Rows/BloomRow
@onready var dish_row: SettingRow = $Panel/Box/Scroll/Rows/DishRow
@onready var tutorial_toggle: ToggleRow = $Panel/Box/Scroll/Rows/TutorialToggle  ## whether the guided tour runs when the dish starts
@onready var advanced_toggle: Button = $Panel/Box/Scroll/Rows/AdvancedToggle
@onready var advanced_reset: Button = $Panel/Box/Scroll/Rows/Advanced/NoteRow/AdvancedReset  ## inside the advanced options: puts them (only) back to their defaults
@onready var advanced: VBoxContainer = $Panel/Box/Scroll/Rows/Advanced  ## options for testing the simulation itself, hidden until asked for
@onready var detail_row: SettingRow = $Panel/Box/Scroll/Rows/Advanced/DetailRow
@onready var thickness_row: SettingRow = $Panel/Box/Scroll/Rows/Advanced/ThicknessRow
@onready var backend_buttons: Dictionary = {  ## the choices of the GPU setting: StartConditions.BACKEND_* -> its button
	StartConditions.BACKEND_AUTO: $Panel/Box/Scroll/Rows/Advanced/BackendBox/BackendRow/AutoButton,
	StartConditions.BACKEND_GPU: $Panel/Box/Scroll/Rows/Advanced/BackendBox/BackendRow/OnButton,
	StartConditions.BACKEND_CPU: $Panel/Box/Scroll/Rows/Advanced/BackendBox/BackendRow/OffButton,
}
@onready var stationary_toggle: ToggleRow = $Panel/Box/Scroll/Rows/Advanced/StationaryToggle  ## whether starving bups shrink and die slowly (on) or die as soon as the reserve is gone
@onready var plankton_husks_toggle: ToggleRow = $Panel/Box/Scroll/Rows/Advanced/PlanktonHusksToggle  ## whether a plankton that dies leaves a husk that leaks its nutrient slowly
@onready var husks_toggle: ToggleRow = $Panel/Box/Scroll/Rows/Advanced/HusksToggle  ## whether a dead bup leaves a husk that leaks its nutrient slowly
@onready var backend_notice: Label = $Panel/Box/Scroll/Rows/Advanced/BackendBox/BackendNotice  ## says so when On is chosen and this machine has no GPU to use
@onready var limit_row: SettingRow = $Panel/Box/Scroll/Rows/LimitRow
@onready var back_button: Button = $Panel/Box/Actions/BackButton
@onready var go_button: Button = $Panel/Box/Actions/GoButton
@onready var reset_button: Button = $Panel/Box/Header/ResetButton

var _start: StartConditions  ## working copy; only committed on GO
var _refreshes := 0  ## how many times the preview has been rebuilt: a pause after the latest one is what adds its plankton


func _ready() -> void:
	_start = Session.free_start.copy()
	var defaults := StartConditions.new()

	bups_row.configure(StartConditions.MIN_BUPS, StartConditions.MAX_BUPS, 1, defaults.bups)
	nutrients_row.configure(0, StartConditions.MAX_NUTRIENT_DENSITY, 1, defaults.nutrient_density, Strings.t("free_setup.unit_nutrient"))
	rate_row.configure(0, StartConditions.MAX_FEED_DENSITY, 0.1, defaults.feed_density, Strings.t("free_setup.unit_feed"))
	bloom_row.configure(0, StartConditions.MAX_BLOOM_DENSITY, Dish.BLOOM_DENSITY_STEP, defaults.bloom_density, Strings.t("free_setup.unit_bloom"))
	dish_row.configure(StartConditions.MIN_DISH_RADIUS / StartConditions.UM_PER_MM, StartConditions.MAX_DISH_RADIUS / StartConditions.UM_PER_MM, 0.1, defaults.dish_radius / StartConditions.UM_PER_MM, Strings.t("ui.mm_unit"))  # the dish is chosen in mm; the simulation works in µm
	detail_row.configure(StartConditions.MIN_NUTRIENT_RESOLUTION, StartConditions.MAX_NUTRIENT_RESOLUTION, StartConditions.NUTRIENT_RESOLUTION_STEP, defaults.nutrient_resolution, Strings.t("free_setup.unit_detail"))
	thickness_row.configure(StartConditions.MIN_MEDIUM_THICKNESS, StartConditions.MAX_MEDIUM_THICKNESS, 1, defaults.medium_thickness, Strings.t("free_setup.unit_thickness"))
	limit_row.configure(StartConditions.MIN_BUP_LIMIT, StartConditions.MAX_BUP_LIMIT, 1, defaults.bup_limit)
	bups_row.value = _start.bups
	nutrients_row.value = _start.nutrient_density
	rate_row.value = _start.feed_density
	bloom_row.value = _start.bloom_density
	dish_row.value = _start.dish_radius / StartConditions.UM_PER_MM
	detail_row.value = _start.nutrient_resolution
	thickness_row.value = _start.medium_thickness
	limit_row.value = _start.bup_limit
	# A saved value off the slider's step grid shows rounded, so take what the sliders hold,
	# so that what's shown, previewed and played are always the same number.
	_start.bups = int(bups_row.value)
	_start.nutrient_density = nutrients_row.value
	_start.feed_density = rate_row.value
	_start.bloom_density = bloom_row.value
	_start.dish_radius = snappedf(dish_row.value * StartConditions.UM_PER_MM, 1.0)
	_start.nutrient_resolution = int(detail_row.value)
	_start.medium_thickness = thickness_row.value
	_start.bup_limit = int(limit_row.value)
	bups_row.value_changed.connect(func(v: float) -> void: _start.bups = int(v); _sync_limit_floor(); _refresh())
	nutrients_row.value_changed.connect(func(v: float) -> void: _start.nutrient_density = v; _refresh())
	rate_row.value_changed.connect(func(v: float) -> void: _start.feed_density = v; _refresh())
	bloom_row.value_changed.connect(func(v: float) -> void: _start.bloom_density = v; _refresh())
	dish_row.value_changed.connect(func(v: float) -> void: _start.dish_radius = snappedf(v * StartConditions.UM_PER_MM, 1.0); _refresh())
	detail_row.value_changed.connect(func(v: float) -> void: _start.nutrient_resolution = int(v); _refresh(); _update_advanced_label())
	thickness_row.value_changed.connect(func(v: float) -> void: _start.medium_thickness = v; _refresh(); _update_advanced_label())
	var backend_group := ButtonGroup.new()  # (like the speed buttons: exactly one choice is on)
	for choice: String in backend_buttons:
		var button: Button = backend_buttons[choice]
		button.button_group = backend_group
		button.set_pressed_no_signal(choice == _start.sim_backend)
		button.pressed.connect(func() -> void: _choose_backend(choice))
	_update_backend_notice()
	stationary_toggle.set_pressed_no_signal(_start.stationary_phase)
	stationary_toggle.toggled.connect(func(on: bool) -> void: _start.stationary_phase = on; _update_advanced_label())
	husks_toggle.set_pressed_no_signal(_start.death_husks)
	husks_toggle.toggled.connect(func(on: bool) -> void: _start.death_husks = on; _update_advanced_label())
	plankton_husks_toggle.set_pressed_no_signal(_start.plankton_husks)
	plankton_husks_toggle.toggled.connect(func(on: bool) -> void: _start.plankton_husks = on; _update_advanced_label())
	tutorial_toggle.set_pressed_no_signal(_start.tutorial)
	tutorial_toggle.toggled.connect(func(on: bool) -> void: _start.tutorial = on)
	advanced_toggle.pressed.connect(func() -> void:
		advanced.visible = not advanced.visible
		_update_advanced_label()
		_fit_scroll()
	)
	get_viewport().size_changed.connect(_fit_scroll)
	advanced_reset.tooltip_text = Strings.t("free_setup.advanced_reset_tip")
	advanced_reset.pressed.connect(func() -> void:
		for row: SettingRow in [detail_row, thickness_row]:
			row.value = row.default_value
		husks_toggle.button_pressed = StartConditions.new().death_husks
		plankton_husks_toggle.button_pressed = StartConditions.new().plankton_husks
		stationary_toggle.button_pressed = StartConditions.new().stationary_phase
		_choose_backend(StartConditions.new().sim_backend))
	limit_row.value_changed.connect(func(v: float) -> void: _start.bup_limit = int(v); _refresh())

	_sync_limit_floor()
	_update_advanced_label()
	_fit_scroll.call_deferred()
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


## The rows take the height they need, up to what fits between the title and the bottom of the screen with the heading and the
## buttons (which stay where they are): past that they scroll, rather than the panel growing over the title. The scrollbar's
## strip is always in the layout (the scroll area shows its bar always) and the bar is only made invisible when there is nothing
## to scroll, so that opening the advanced options changes the panel's height and nothing else.
func _fit_scroll() -> void:
	await get_tree().process_frame  # (the sizes of what has just changed are known a frame later)
	if not is_inside_tree():
		return  # (the screen has been left in the meantime)
	var was_open := advanced.visible
	advanced.visible = true  # (the panel is as wide as its widest row, the advanced ones too, shut or not)
	rows.custom_minimum_size.x = 0.0
	rows.custom_minimum_size.x = rows.get_combined_minimum_size().x
	advanced.visible = was_open
	scroll.custom_minimum_size.y = 0.0
	var chrome := panel.get_combined_minimum_size().y  # (everything but the rows, now that they have no height of their own)
	var room := get_viewport_rect().size.y - TITLE_CLEARANCE - BOTTOM_CLEARANCE - chrome
	var wanted := rows.get_combined_minimum_size().y
	scroll.custom_minimum_size.y = clampf(wanted, 0.0, maxf(room, 120.0))
	scroll.get_v_scroll_bar().modulate.a = 1.0 if wanted > scroll.custom_minimum_size.y + 0.5 else 0.0  # (nothing to scroll: the strip stays, the bar does not show)


## Sets where the bups are simulated (a StartConditions.BACKEND_*) and shows it on the buttons.
func _choose_backend(choice: String) -> void:
	_start.sim_backend = choice
	for key: String in backend_buttons:
		backend_buttons[key].set_pressed_no_signal(key == choice)
	_update_backend_notice()
	_update_advanced_label()


## One line says so when On is chosen and this machine has no GPU the simulation can run on.
func _update_backend_notice() -> void:
	backend_notice.visible = _start.sim_backend == StartConditions.BACKEND_GPU and not GpuWorld.available()


## The advanced options' heading says whether they are open, and, so that a changed one is not forgotten while it is shut,
## whether any is not at its usual value.
func _update_advanced_label() -> void:
	var changed := not is_equal_approx(detail_row.value, detail_row.default_value) or not is_equal_approx(thickness_row.value, thickness_row.default_value) or _start.sim_backend != StartConditions.new().sim_backend or _start.death_husks or _start.plankton_husks or _start.stationary_phase != StartConditions.new().stationary_phase
	advanced_toggle.text = Strings.t("free_setup.advanced_open" if advanced.visible else "free_setup.advanced_closed") + (Strings.t("free_setup.advanced_changed") if changed else "")


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
	# A bloom's plankton are put in once the settings have been still for a moment (a dish that has run a while has them floating).
	_refreshes += 1
	var refresh := _refreshes
	await get_tree().create_timer(PLANKTON_SETTLE_SECONDS).timeout
	if refresh == _refreshes:
		dish.add_steady_state_plankton()
		dish.queue_redraw()


## Loads the defaults into the sliders. Deliberately touches nothing else: the remembered
## choices only change when GO saves them, and backing out saves nothing.
func _reset_to_defaults() -> void:
	for row: SettingRow in [bups_row, nutrients_row, rate_row, bloom_row, dish_row, detail_row, thickness_row, limit_row]:
		row.value = row.default_value
	tutorial_toggle.button_pressed = StartConditions.new().tutorial
	husks_toggle.button_pressed = StartConditions.new().death_husks
	plankton_husks_toggle.button_pressed = StartConditions.new().plankton_husks
	stationary_toggle.button_pressed = StartConditions.new().stationary_phase
	_choose_backend(StartConditions.new().sim_backend)


func _go() -> void:
	var chosen := _start.copy()
	Session.tutorial_wanted = chosen.tutorial
	Session.free_start = chosen
	chosen.save()  # so the next launch starts from these
	Session.mode = Session.Mode.FREE
	Session.load_requested = false
	get_tree().change_scene_to_file(Scenes.FOUNDERS)  # the founders are named and coloured next, then the dish starts


func _back() -> void:
	get_tree().change_scene_to_file(Scenes.MENU)
