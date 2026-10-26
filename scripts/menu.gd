extends Control
## Title screen. A live dish of bups multiplies quietly behind the buttons.

@onready var dish: Dish = $Dish
@onready var title: Label = $Column/Title
@onready var buttons: VBoxContainer = $Column/Buttons
@onready var tagline: Label = $Column/Tagline
@onready var new_button: Button = $Column/Buttons/NewButton
@onready var load_button: Button = $Column/Buttons/LoadButton
@onready var free_button: Button = $Column/Buttons/FreeButton
@onready var controls_button: Button = $Column/Buttons/ControlsButton
@onready var quit_button: Button = $Column/Buttons/QuitButton
@onready var options_button: Button = $Column/Buttons/OptionsButton
@onready var controls_panel: ControlsPanel = $ControlsPanel
@onready var options_panel: OptionsPanel = $OptionsPanel
@onready var confirm: ConfirmationDialog = $ConfirmDialog

var _flicker_left := 0.0


func _ready() -> void:
	UserSettings.ensure_applied()
	UserSettings.load_once()
	var quips := Strings.list("menu", "quip")
	tagline.text = quips[randi() % quips.size()] if not quips.is_empty() else ""
	dish.position = _dish_center()
	dish.strike(_ambient_start())
	dish.extinct.connect(func() -> void: dish.strike(_ambient_start()), CONNECT_DEFERRED)  # (each time in new colours)

	load_button.visible = SaveGame.has_save()  # (Continue is the first thing offered when there is something to continue)
	new_button.theme_type_variation = &"" if load_button.visible else &"PrimaryButton"
	new_button.pressed.connect(_on_new_pressed)
	load_button.pressed.connect(_on_load_pressed)
	free_button.pressed.connect(_on_free_pressed)
	controls_button.pressed.connect(_show_controls.bind(true))
	controls_panel.back_requested.connect(_show_controls.bind(false))
	options_button.pressed.connect(_show_options.bind(true))
	options_panel.back_requested.connect(_show_options.bind(false))
	quit_button.pressed.connect(get_tree().quit)
	confirm.confirmed.connect(_start_new)
	confirm.about_to_popup.connect(func() -> void: confirm.get_cancel_button().grab_focus.call_deferred())  # (the safe choice is the default: Enter must not throw a save away)
	# Wrap keyboard navigation: up from the first item lands on the last, and vice versa.
	var first := load_button if load_button.visible else new_button
	first.focus_neighbor_top = first.get_path_to(quit_button)
	first.focus_previous = first.get_path_to(quit_button)
	quit_button.focus_neighbor_bottom = quit_button.get_path_to(first)
	quit_button.focus_next = quit_button.get_path_to(first)
	first.grab_focus()


## The dish behind the title: a fed colony of founders in evenly spaced colours.
func _ambient_start() -> StartConditions:
	var start := StartConditions.new()
	start.feed_density = 2.0
	start.spread_founders()
	return start


func _dish_center() -> Vector2:
	return get_viewport_rect().size * 0.5


func _process(delta: float) -> void:
	# Follow the window if it is resized (or stretched by the editor's game view).
	if not dish.position.is_equal_approx(_dish_center()):
		dish.recenter(_dish_center())
	dish.step(minf(delta, 1.0 / 30.0))
	dish.queue_redraw()
	# Neon-sign flicker on the title.
	_flicker_left = maxf(0.0, _flicker_left - delta)
	if _flicker_left == 0.0 and randf() < 0.4 * delta:
		_flicker_left = randf_range(0.05, 0.2)
	title.modulate.a = 0.4 if _flicker_left > 0.0 and not UserSettings.reduce_motion else 1.0


func _unhandled_input(event: InputEvent) -> void:
	if UiInput.is_escape_press(event) and controls_panel.visible:
		_show_controls(false)
	elif UiInput.is_escape_press(event) and options_panel.visible:
		_show_options(false)


func _show_controls(visible_now: bool) -> void:
	controls_panel.visible = visible_now
	_show_panel(visible_now)
	if visible_now:
		controls_panel.focus_back()
	else:
		controls_button.grab_focus()


func _show_options(visible_now: bool) -> void:
	options_panel.visible = visible_now
	_show_panel(visible_now)
	if visible_now:
		options_panel.focus_back()
	else:
		options_button.grab_focus()


## A panel is up in place of the title and its buttons (or gone again).
func _show_panel(up: bool) -> void:
	buttons.visible = not up
	title.visible = not up
	tagline.visible = not up


func _on_new_pressed() -> void:
	if SaveGame.has_save():
		confirm.popup_centered()
	else:
		_start_new()


func _start_new() -> void:
	SaveGame.delete()
	Session.mode = Session.Mode.GOALS
	Session.load_requested = false
	Session.tutorial_wanted = true  # (goal mode always opens with the tour, which the player can skip; nothing about it is kept)
	get_tree().change_scene_to_file(Scenes.INTRO)


func _on_load_pressed() -> void:
	Session.mode = Session.Mode.GOALS
	Session.load_requested = true
	Session.tutorial_wanted = false  # (the tour is for a first game; it can be replayed from the pause menu)
	get_tree().change_scene_to_file(Scenes.GAME)


func _on_free_pressed() -> void:
	get_tree().change_scene_to_file(Scenes.FREE_SETUP)
