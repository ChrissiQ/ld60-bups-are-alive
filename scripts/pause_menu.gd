class_name PauseMenu
extends Control
## The menu Escape opens over a running game, dressed like the title screen. It asks whether to
## carry on or quit. In free mode it also lets the player enlarge the dish and change the bup limit,
## the two starting conditions that still mean something once a dish is running (the feed has its
## own keys, and bups are meant to evolve rather than be placed). It only reports what was chosen:
## the game screen applies it. Escape closes it again; main.gd handles the key.

signal resume_requested
signal quit_requested
signal tour_requested  ## the guided tour was asked for again
signal dish_radius_chosen(dish: Dish, radius: float)  ## the dish the menu was opened for, which is not always the one in view when this arrives
signal bup_limit_chosen(limit: int)

@onready var card: PanelContainer = %Card
@onready var settings: Control = %Settings  ## the dish's size and limit (free mode)
@onready var right: Control = %Right  ## the column of the dish: its settings and how it began (free mode)
@onready var divider: Control = %Divider
@onready var controls_panel: ControlsPanel = $ControlsPanel
@onready var options_panel: OptionsPanel = $OptionsPanel
@onready var encyclopedia_panel: EncyclopediaPanel = $EncyclopediaPanel
@onready var encyclopedia_button: Button = %EncyclopediaButton
@onready var options_button: Button = %OptionsButton
@onready var tour_button: Button = %TourButton
@onready var initial_panel: Control = %Initial  ## how the dish began, for the record (it doesn't follow later changes)
@onready var initial_bups: StatRow = %BupsRow
@onready var initial_nutrients: StatRow = %NutrientsRow
@onready var initial_rate: StatRow = %RateRow
@onready var initial_bloom: StatRow = %BloomRow
@onready var initial_dish: StatRow = %DishRow
@onready var initial_detail: StatRow = %DetailRow
@onready var initial_thickness: StatRow = %ThicknessRow
@onready var initial_backend: StatRow = %BackendRow
@onready var initial_stationary: StatRow = %StationaryRow  ## shown when the dish was started with starvation switched on
@onready var initial_plankton_husks: StatRow = %PlanktonHusksRow  ## shown when the dish was started with plankton husks
@onready var initial_husks: StatRow = %HusksRow  ## shown when the dish was started with husks
@onready var initial_running: StatRow = %RunningRow  ## where the bups are simulated right now (unlike the rest of the record, this follows the game)
@onready var initial_limit: StatRow = %LimitRow
@onready var dish_row: SettingRow = %DishSettingRow
@onready var limit_row: SettingRow = %LimitSettingRow
@onready var resume_button: Button = %ResumeButton
@onready var controls_button: Button = %ControlsButton
@onready var quit_button: Button = %QuitButton
@onready var confirm: ConfirmationDialog = $ConfirmDialog

const DISH_SETTLE_SECONDS := 0.6  ## how long the dish-size slider is still before its size is taken

var _free_mode := false
var _from_game := false  ## the encyclopedia was opened straight from the game (a click on a band of the genome map), not from this menu: leaving it goes back to the game
var _dish: Dish  ## the dish the menu was opened for
var _dish_change := 0  ## counts changes to the dish-size slider, so only the last of a quick run counts
var _record_shown := false  ## the starting-conditions record is wanted (it is hidden while the controls are up)
var _opening := false  ## true while the rows are being set up, so that doesn't count as a choice


func _ready() -> void:
	resume_button.pressed.connect(resume_requested.emit)
	controls_button.pressed.connect(_show_controls.bind(true))
	controls_panel.back_requested.connect(_show_controls.bind(false))
	encyclopedia_button.pressed.connect(_show_encyclopedia.bind(true))
	encyclopedia_panel.back_requested.connect(_show_encyclopedia.bind(false))
	options_button.pressed.connect(_show_options.bind(true))
	options_panel.back_requested.connect(_show_options.bind(false))
	tour_button.pressed.connect(tour_requested.emit)
	quit_button.pressed.connect(_on_quit_pressed)
	confirm.confirmed.connect(quit_requested.emit)
	confirm.about_to_popup.connect(func() -> void: confirm.get_cancel_button().grab_focus.call_deferred())  # (Stay is the default: Enter must not throw a dish away)
	dish_row.value_changed.connect(_on_dish_row_changed)
	limit_row.value_changed.connect(func(v: float) -> void:
		if not _opening:
			bup_limit_chosen.emit(int(v)))
	# Wrap keyboard navigation: up from the first button lands on the last, and down from the last on the first.
	resume_button.focus_neighbor_top = resume_button.get_path_to(quit_button)
	quit_button.focus_neighbor_bottom = quit_button.get_path_to(resume_button)


## Shows the menu for this dish. In free mode the sliders start at the dish's size and limit, and
## cannot go below them: the limit can't drop under the bups there are. The dish can grow or shrink.
func open(dish: Dish, free_mode: bool, started_as: StartConditions = null) -> void:
	_free_mode = free_mode
	_dish = dish
	_from_game = false
	settings.visible = free_mode
	right.visible = free_mode
	divider.visible = free_mode
	_record_shown = free_mode and started_as != null
	initial_panel.visible = _record_shown
	if _record_shown:
		initial_bups.value_text = UiText.thousands(started_as.bups)
		initial_nutrients.value_text = UiText.thousands(started_as.nutrient_density) + Strings.t("pause.per_mm2")
		initial_rate.value_text = UiText.thousands(started_as.feed_density, 1) + Strings.t("pause.per_mm2_hour")
		initial_bloom.value_text = UiText.thousands(started_as.bloom_density, 2) + Strings.t("pause.per_mm2_day")
		initial_dish.value_text = UiText.mm(started_as.dish_radius)
		var defaults := StartConditions.new()  # (the advanced options are on the record only when they were not left as they were)
		initial_detail.visible = started_as.nutrient_resolution != defaults.nutrient_resolution
		initial_thickness.visible = not is_equal_approx(started_as.medium_thickness, defaults.medium_thickness)
		initial_detail.value_text = UiText.thousands(started_as.nutrient_resolution) + Strings.t("pause.cells_across")
		initial_thickness.value_text = UiText.thousands(started_as.medium_thickness) + Strings.t("pause.times_water")
		initial_backend.visible = started_as.sim_backend != defaults.sim_backend
		initial_backend.value_text = Strings.t("free_setup.backend_on" if started_as.sim_backend == StartConditions.BACKEND_GPU else "free_setup.backend_off")
		initial_stationary.visible = started_as.stationary_phase
		initial_stationary.value_text = Strings.t("pause.stationary_value")
		initial_husks.visible = started_as.death_husks
		initial_husks.value_text = Strings.t("pause.husks_value")
		initial_plankton_husks.visible = started_as.plankton_husks
		initial_plankton_husks.value_text = Strings.t("pause.husks_value")
		initial_limit.value_text = UiText.thousands(started_as.bup_limit)
	if _record_shown:
		initial_running.value_text = Strings.t("pause.running_gpu" if dish.backend_running() == "gpu" else "pause.running_cpu") + (Strings.t("pause.running_auto") if dish.backend_setting == StartConditions.BACKEND_AUTO else "")
	quit_button.text = Strings.t("pause.quit") if free_mode else Strings.t("pause.save_quit")
	if free_mode:
		_opening = true
		var floor_limit := maxi(StartConditions.MIN_BUP_LIMIT, dish.population())
		limit_row.disabled_reason = Strings.t("pause.at_max")
		dish_row.configure(StartConditions.MIN_DISH_RADIUS / StartConditions.UM_PER_MM, StartConditions.MAX_DISH_RADIUS / StartConditions.UM_PER_MM, 0.1, dish.radius / StartConditions.UM_PER_MM, Strings.t("ui.mm_unit"))
		limit_row.configure(floor_limit, StartConditions.MAX_BUP_LIMIT, 1, dish.bup_limit)
		dish_row.value = dish.radius / StartConditions.UM_PER_MM
		limit_row.value = maxi(dish.bup_limit, floor_limit)
		_opening = false
	_show_controls(false)
	visible = true
	resume_button.grab_focus()


## A new size is only reported once the slider has been still for a moment: a smaller dish cuts bups off for good, so
## dragging past a size on the way to another must not.
func _on_dish_row_changed(v: float) -> void:
	if _opening:
		return
	_dish_change += 1
	var change := _dish_change
	var target := _dish
	await get_tree().create_timer(DISH_SETTLE_SECONDS).timeout
	if change == _dish_change and is_instance_valid(target):
		dish_radius_chosen.emit(target, snappedf(v * StartConditions.UM_PER_MM, 1.0))


func close() -> void:
	confirm.hide()
	_from_game = false
	visible = false


## Shows the list of controls in place of the menu, or the menu again.
func _show_controls(visible_now: bool) -> void:
	controls_panel.visible = visible_now
	options_panel.visible = false
	encyclopedia_panel.visible = false
	_show_panel(visible_now)
	if visible_now:
		controls_panel.focus_back()
	elif visible:
		controls_button.grab_focus()


## Shows the encyclopedia in place of the menu, or the menu again.
func _show_encyclopedia(visible_now: bool) -> void:
	if not visible_now and _from_game and encyclopedia_panel.visible:
		_from_game = false
		resume_requested.emit()  # (the player never came through this menu: Back goes to where they were)
		return
	_from_game = false
	encyclopedia_panel.visible = visible_now
	controls_panel.visible = false
	options_panel.visible = false
	_show_panel(visible_now)
	if visible_now:
		encyclopedia_panel.focus_back()
	elif visible:
		encyclopedia_button.grab_focus()


## The encyclopedia open on an entry (a click on a band of the genome map).
func show_encyclopedia(entry: String) -> void:
	encyclopedia_panel.show_entry(entry)
	_show_encyclopedia(true)
	_from_game = true


## The controls list, straight away (the F1 key).
func show_controls() -> void:
	_show_controls(true)


## Shows the options in place of the menu, or the menu again.
func _show_options(visible_now: bool) -> void:
	options_panel.visible = visible_now
	controls_panel.visible = false
	encyclopedia_panel.visible = false
	_show_panel(visible_now)
	if visible_now:
		options_panel.focus_back()
	elif visible:
		options_button.grab_focus()


## A panel is up in place of the menu (or gone again).
func _show_panel(up: bool) -> void:
	card.visible = not up


## Escape while the controls or the options are up goes back to the menu: true if it did that (so the menu itself stays open).
func close_panel() -> bool:
	if controls_panel.visible:
		_show_controls(false)
		return true
	if options_panel.visible:
		_show_options(false)
		return true
	if encyclopedia_panel.visible:
		_show_encyclopedia(false)
		return true
	return false


## Free mode is not saved, so leaving it asks first; a goal-mode experiment is saved on the way out.
func _on_quit_pressed() -> void:
	if _free_mode:
		confirm.popup_centered()
	else:
		quit_requested.emit()
