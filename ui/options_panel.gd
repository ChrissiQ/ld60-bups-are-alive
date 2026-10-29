class_name OptionsPanel
extends PanelPage
## The player's preferences (see UserSettings), with a Back button. Shown by the title screen and by the pause menu, in
## place of what is behind it, until `back_requested`.

@onready var fullscreen_toggle: ToggleRow = $Box/Scroll/Rows/FullscreenToggle
@onready var scale_row: SettingRow = $Box/Scroll/Rows/ScaleRow
@onready var zoom_row: SettingRow = $Box/Scroll/Rows/ZoomRow
@onready var motion_toggle: ToggleRow = $Box/Scroll/Rows/MotionToggle  ## ticked: the operating system decides, and the switch shows what it says
@onready var reset_button: Button = $Box/Actions/ResetButton  ## one reset for every setting on the panel

var _syncing := false


func _ready() -> void:
	UserSettings.load_once()
	fullscreen_toggle.hint_text = Strings.t("options.fullscreen_hint", [UserSettings.fullscreen_key_label()])
	scale_row.configure(UserSettings.SCALE_MIN * 100.0, UserSettings.SCALE_MAX * 100.0, UserSettings.SCALE_STEP * 100.0, 100.0, "%")
	zoom_row.configure(UserSettings.ZOOM_SPEED_MIN * 100.0, UserSettings.ZOOM_SPEED_MAX * 100.0, UserSettings.ZOOM_SPEED_STEP * 100.0, 100.0, "%")
	zoom_row.value_changed.connect(func(v: float) -> void:
		if not _syncing:
			UserSettings.set_zoom_speed(v / 100.0))
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
	_sync()


func _sync() -> void:
	UserSettings.load_once()
	_syncing = true
	fullscreen_toggle.set_pressed_no_signal(UserSettings.fullscreen)
	_show_motion()
	scale_row.set_value_silently(UserSettings.ui_scale * 100.0)
	zoom_row.set_value_silently(UserSettings.zoom_speed * 100.0)
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

