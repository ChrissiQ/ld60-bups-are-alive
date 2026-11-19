class_name OptionsPanel
extends PanelPage
## The player's preferences (see UserSettings), with a Back button. Shown by the title screen and by the pause menu, in
## place of what is behind it, until `back_requested`.

const WIDTH := 560.0  ## the least width of the rows at 100%: it grows with the text
const CLEARANCE := 48.0  ## the room kept round the panel when the window is smaller than the rows

@onready var scroll: ScrollContainer = $Box/Scroll
@onready var rows: Control = $Box/Scroll/Rows
@onready var fullscreen_toggle: ToggleRow = $Box/Scroll/Rows/FullscreenToggle
@onready var scale_row: SettingRow = $Box/Scroll/Rows/ScaleRow
@onready var scroll_row: SettingRow = $Box/Scroll/Rows/ScrollRow
@onready var motion_toggle: ToggleRow = $Box/Scroll/Rows/MotionToggle  ## ticked: the operating system decides, and the switch shows what it says
@onready var reset_button: Button = $Box/Actions/ResetButton  ## one reset for every setting on the panel

var _syncing := false


func _ready() -> void:
	UserSettings.load_once()
	fullscreen_toggle.hint_text = Strings.t("options.fullscreen_hint", [UserSettings.fullscreen_key_label()])
	scale_row.configure(UserSettings.SCALE_MIN * 100.0, UserSettings.SCALE_MAX * 100.0, UserSettings.SCALE_STEP * 100.0, 100.0, "%")
	scroll_row.configure(UserSettings.SCROLL_SPEED_MIN * 100.0, UserSettings.SCROLL_SPEED_MAX * 100.0, UserSettings.SCROLL_SPEED_STEP * 100.0, 100.0, "%")
	scroll_row.value_changed.connect(func(v: float) -> void:
		if not _syncing:
			UserSettings.set_scroll_speed(v / 100.0))
	fullscreen_toggle.toggled.connect(func(on: bool) -> void:
		if not _syncing:
			UserSettings.set_fullscreen(on))
	motion_toggle.automatic_toggled.connect(func(_on: bool) -> void: _motion_changed())
	motion_toggle.toggled.connect(func(_on: bool) -> void: _motion_changed())
	scale_row.value_changed.connect(func(v: float) -> void:
		if not _syncing:
			UserSettings.set_ui_scale(v / 100.0))
	reset_button.tooltip_text = Strings.t("options.reset_tip")
	reset_button.pressed.connect(func() -> void:
		UserSettings.reset()
		_sync())
	visibility_changed.connect(_sync)
	visibility_changed.connect(_fit)
	rows.minimum_size_changed.connect(_fit)
	get_viewport().size_changed.connect(_fit)
	_sync()
	_fit()


## The panel takes the size its rows need, and no more than the window leaves: past that only the rows scroll.
func _fit() -> void:
	await get_tree().process_frame  # (the sizes of what has just changed are known a frame later)
	if not is_inside_tree():
		return
	scroll.custom_minimum_size = Vector2.ZERO
	var view := get_viewport_rect().size
	var chrome := get_combined_minimum_size().y  # (the heading, the buttons and the panel's own room, with the rows' height at zero)
	scroll.custom_minimum_size = Vector2(
		clampf(maxf(WIDTH * UserSettings.text_factor() / UserSettings.PLEX_SIZE, rows.get_combined_minimum_size().x), 0.0, maxf(view.x - CLEARANCE, 0.0)),
		clampf(rows.get_combined_minimum_size().y, 0.0, maxf(view.y - chrome - CLEARANCE, 120.0)))


func _sync() -> void:
	UserSettings.load_once()
	_syncing = true
	fullscreen_toggle.set_pressed_no_signal(UserSettings.fullscreen)
	_show_motion()
	scale_row.set_value_silently(UserSettings.ui_scale * 100.0)
	scroll_row.set_value_silently(UserSettings.scroll_speed * 100.0)
	_syncing = false


func _show_motion() -> void:
	motion_toggle.set_automatic_no_signal(UserSettings.reduce_motion_choice == "system")
	motion_toggle.set_pressed_no_signal(UserSettings.reduce_motion)


## Coming back from the system's settings, the switch shows what the system now says.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and is_node_ready() and is_visible_in_tree():
		_syncing = true
		_show_motion()
		_syncing = false


func _motion_changed() -> void:
	if _syncing:
		return
	if motion_toggle.automatic:
		UserSettings.set_reduce_motion("system")
	else:
		UserSettings.set_reduce_motion("on" if motion_toggle.button_pressed else "off")
	_show_motion()

