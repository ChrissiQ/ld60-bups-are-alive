class_name ControlsPanel
extends PanelContainer
## The list of controls, which is also where they are changed: every action has its key on a button, and clicking it waits
## for the new key (Escape cancels). The keys that cannot change are listed under them. Shown by the title screen and by
## the pause menu (each hides what is behind it while this is up, and shows it again on `back_requested`).
## The names are in text/strings.cfg, [keys]; the keys themselves are KeyBindings'.

signal back_requested

@onready var keys_grid: GridContainer = $Box/Scroll/Keys
@onready var message: Label = $Box/Message
@onready var reset_button: Button = $Box/Actions/ResetButton
@onready var back_button: Button = $Box/Actions/BackButton

var _buttons := {}  ## action id -> its key button
var _waiting := ""  ## the action whose new key is being waited for ("" for none)


func _ready() -> void:
	for id: String in KeyBindings.ids():
		var button := Button.new()
		button.custom_minimum_size = Vector2(96, 30)
		button.pressed.connect(_wait_for_key.bind(id))
		_buttons[id] = button
		keys_grid.add_child(button)
		var name_label := Label.new()
		name_label.text = Strings.t("keys." + id)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		keys_grid.add_child(name_label)
	while keys_grid.get_child_count() % keys_grid.columns != 0:  # (the next part starts on a row of its own)
		keys_grid.add_child(Control.new())
	var heading := Label.new()  # (a line of its own between the keys that change and the ones that do not)
	heading.text = Strings.t("keys.fixed_heading")
	heading.theme_type_variation = &"Accent"
	keys_grid.add_child(heading)
	for blank in 3:
		keys_grid.add_child(Control.new())
	for n in range(1, 8):  # (the same shape as the rows above, with the key dimmed: it cannot be pressed to change)
		var fixed := Button.new()
		fixed.custom_minimum_size = Vector2(96, 30)
		fixed.focus_mode = Control.FOCUS_NONE
		fixed.disabled = true
		fixed.text = UserSettings.fullscreen_key_label() if n == 4 else Strings.t("keys.fixed_key_%d" % n)  # (the fourth fixed row is full screen: its key depends on the system)
		keys_grid.add_child(fixed)
		var text := Label.new()
		text.text = Strings.t("keys.fixed_text_%d" % n)
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		keys_grid.add_child(text)
	back_button.pressed.connect(back_requested.emit)
	reset_button.pressed.connect(func() -> void:
		_waiting = ""
		message.text = ""
		KeyBindings.reset()
		_refresh())
	visibility_changed.connect(func() -> void:
		_waiting = ""
		message.text = ""
		_refresh()
		_fit_columns.call_deferred())
	get_viewport().size_changed.connect(_fit_columns)
	_refresh()


## Two columns of key and action when four (two pairs) would not fit across the window, as with a big interface size.
func _fit_columns() -> void:
	if not is_inside_tree() or not visible:
		return
	keys_grid.columns = 4
	await get_tree().process_frame
	if keys_grid.get_combined_minimum_size().x > get_viewport_rect().size.x - 120.0:  # (the panel keeps 40 clear at each side, and has its own margins)
		keys_grid.columns = 2


func _refresh() -> void:
	for id: String in _buttons:
		_buttons[id].text = Strings.t("keys.press") if id == _waiting else KeyBindings.label(id)
	reset_button.disabled = KeyBindings.is_default()


func _wait_for_key(id: String) -> void:
	_waiting = id
	message.text = ""
	_refresh()


## While a key is wanted it is taken here, before anything else (the menus' Escape included) can use it.
func _input(event: InputEvent) -> void:
	if _waiting == "" or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	get_viewport().set_input_as_handled()
	if event.keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
		return  # (a modifier alone is not a key; wait for the one it goes with)
	var id := _waiting
	_waiting = ""
	if event.keycode == KEY_ESCAPE:
		message.text = ""
	else:
		var swapped := KeyBindings.set_key(id, event.keycode)
		if swapped == "!":
			message.text = Strings.t("keys.reserved")
		elif swapped != "":
			message.text = Strings.t("keys.swapped", [Strings.t("keys." + swapped)])
		else:
			message.text = ""
	_refresh()


## Whether the panel is waiting for a key (so Escape means "cancel", not "go back").
func is_waiting() -> bool:
	return _waiting != ""


## So the keyboard can go straight back.
func focus_back() -> void:
	back_button.grab_focus()
