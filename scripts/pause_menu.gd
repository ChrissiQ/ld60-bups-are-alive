class_name PauseMenu
extends Control
## The menu Escape opens over a running game, dressed like the title screen. It asks whether to
## carry on or quit. In free mode it also lets the player enlarge the dish and change the bup limit,
## the two starting conditions that still mean something once a dish is running (the feed has its
## own keys, and bups are meant to evolve rather than be placed). It only reports what was chosen:
## the game screen applies it. Escape closes it again; main.gd handles the key.

signal resume_requested
signal quit_requested
signal dish_radius_chosen(radius: float)
signal bup_limit_chosen(limit: int)

@onready var settings: PanelContainer = $Content/Settings
@onready var initial_panel: PanelContainer = $Initial  ## how the dish began, for the record (it doesn't follow later changes)
@onready var initial_bups: StatRow = $Initial/Box/BupsRow
@onready var initial_nutrients: StatRow = $Initial/Box/NutrientsRow
@onready var initial_rate: StatRow = $Initial/Box/RateRow
@onready var initial_bloom: StatRow = $Initial/Box/BloomRow
@onready var initial_dish: StatRow = $Initial/Box/DishRow
@onready var initial_limit: StatRow = $Initial/Box/LimitRow
@onready var dish_row: SettingRow = $Content/Settings/Box/DishRow
@onready var limit_row: SettingRow = $Content/Settings/Box/LimitRow
@onready var resume_button: Button = $Content/Buttons/ResumeButton
@onready var quit_button: Button = $Content/Buttons/QuitButton
@onready var confirm: ConfirmationDialog = $ConfirmDialog

var _free_mode := false
var _opening := false  ## true while the rows are being set up, so that doesn't count as a choice


func _ready() -> void:
	resume_button.pressed.connect(resume_requested.emit)
	quit_button.pressed.connect(_on_quit_pressed)
	confirm.confirmed.connect(quit_requested.emit)
	dish_row.value_changed.connect(func(v: float) -> void:
		if not _opening:
			dish_radius_chosen.emit(snappedf(v * StartConditions.UM_PER_MM, 1.0)))
	limit_row.value_changed.connect(func(v: float) -> void:
		if not _opening:
			bup_limit_chosen.emit(int(v)))
	# Wrap keyboard navigation between the two buttons.
	resume_button.focus_neighbor_top = resume_button.get_path_to(quit_button)
	quit_button.focus_neighbor_bottom = quit_button.get_path_to(resume_button)


## Shows the menu for this dish. In free mode the sliders start at the dish's size and limit, and
## cannot go below them: a dish only grows, and the limit can't drop under the bups there are.
func open(dish: Dish, free_mode: bool, started_as: StartConditions = null) -> void:
	_free_mode = free_mode
	settings.visible = free_mode
	initial_panel.visible = free_mode and started_as != null
	if initial_panel.visible:
		initial_bups.value_text = UiText.thousands(started_as.bups)
		initial_nutrients.value_text = UiText.thousands(started_as.nutrients)
		initial_rate.value_text = UiText.thousands(started_as.nutrient_rate) + Strings.t("pause.per_minute")
		initial_bloom.value_text = UiText.thousands(started_as.bloom_rate) + Strings.t("pause.per_day")
		initial_dish.value_text = UiText.mm(started_as.dish_radius)
		initial_limit.value_text = UiText.thousands(started_as.bup_limit)
	quit_button.text = Strings.t("pause.quit") if free_mode else Strings.t("pause.save_quit")
	if free_mode:
		_opening = true
		var floor_limit := maxi(StartConditions.MIN_BUP_LIMIT, dish.population())
		dish_row.disabled_reason = Strings.t("pause.at_max_size")
		limit_row.disabled_reason = Strings.t("pause.at_max")
		dish_row.configure(dish.radius / StartConditions.UM_PER_MM, maxf(StartConditions.MAX_DISH_RADIUS, dish.radius) / StartConditions.UM_PER_MM, 0.1, dish.radius / StartConditions.UM_PER_MM, Strings.t("ui.mm_unit"))
		limit_row.configure(floor_limit, StartConditions.MAX_BUP_LIMIT, 1, dish.bup_limit)
		dish_row.value = dish.radius / StartConditions.UM_PER_MM
		limit_row.value = maxi(dish.bup_limit, floor_limit)
		_opening = false
	visible = true
	resume_button.grab_focus()


func close() -> void:
	confirm.hide()
	visible = false


## Free mode is not saved, so leaving it asks first; a goal-mode experiment is saved on the way out.
func _on_quit_pressed() -> void:
	if _free_mode:
		confirm.popup_centered()
	else:
		quit_requested.emit()
