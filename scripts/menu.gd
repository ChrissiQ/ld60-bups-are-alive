extends Control
## Title screen. A live dish of bups multiplies quietly behind the buttons.

@onready var dish: Dish = $Dish
@onready var title: Label = $Title
@onready var buttons: VBoxContainer = $Buttons
@onready var tagline: Label = $Tagline
@onready var new_button: Button = $Buttons/NewButton
@onready var load_button: Button = $Buttons/LoadButton
@onready var free_button: Button = $Buttons/FreeButton
@onready var controls_button: Button = $Buttons/ControlsButton
@onready var quit_button: Button = $Buttons/QuitButton
@onready var controls_panel: PanelContainer = $ControlsPanel
@onready var back_button: Button = $ControlsPanel/Box/BackButton
@onready var confirm: ConfirmationDialog = $ConfirmDialog

var _flicker_left := 0.0


func _ready() -> void:
	var quips := Strings.list("menu", "quip")
	tagline.text = quips[randi() % quips.size()] if not quips.is_empty() else ""
	dish.position = _dish_center()
	dish.strike(_ambient_start())
	dish.extinct.connect(func() -> void: dish.strike(_ambient_start()), CONNECT_DEFERRED)  # (each time in new colours)

	load_button.disabled = not SaveGame.has_save()
	# Without this, arrow-key navigation still lands on the disabled button.
	load_button.focus_mode = Control.FOCUS_NONE if load_button.disabled else Control.FOCUS_ALL
	new_button.pressed.connect(_on_new_pressed)
	load_button.pressed.connect(_on_load_pressed)
	free_button.pressed.connect(_on_free_pressed)
	controls_button.pressed.connect(_show_controls.bind(true))
	back_button.pressed.connect(_show_controls.bind(false))
	quit_button.pressed.connect(get_tree().quit)
	confirm.confirmed.connect(_start_new)
	# Wrap keyboard navigation: up from the first item lands on the last, and vice versa.
	new_button.focus_neighbor_top = new_button.get_path_to(quit_button)
	new_button.focus_previous = new_button.get_path_to(quit_button)
	quit_button.focus_neighbor_bottom = quit_button.get_path_to(new_button)
	quit_button.focus_next = quit_button.get_path_to(new_button)
	new_button.grab_focus()


## The dish behind the title: a fed colony of founders in evenly spaced colours.
func _ambient_start() -> StartConditions:
	var start := StartConditions.new()
	start.nutrient_rate = 10.0
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
	title.modulate.a = 0.4 if _flicker_left > 0.0 else 1.0


func _unhandled_input(event: InputEvent) -> void:
	if UiInput.is_escape_press(event) and controls_panel.visible:
		_show_controls(false)


func _show_controls(visible_now: bool) -> void:
	controls_panel.visible = visible_now
	buttons.visible = not visible_now
	title.visible = not visible_now
	tagline.visible = not visible_now
	if visible_now:
		back_button.grab_focus()
	else:
		controls_button.grab_focus()


func _on_new_pressed() -> void:
	if SaveGame.has_save():
		confirm.popup_centered()
	else:
		_start_new()


func _start_new() -> void:
	SaveGame.delete()
	Session.mode = Session.Mode.GOALS
	Session.load_requested = false
	get_tree().change_scene_to_file(Scenes.INTRO)


func _on_load_pressed() -> void:
	Session.mode = Session.Mode.GOALS
	Session.load_requested = true
	get_tree().change_scene_to_file(Scenes.GAME)


func _on_free_pressed() -> void:
	get_tree().change_scene_to_file(Scenes.FREE_SETUP)
