class_name DishActions
extends VBoxContainer
## The two things that take the dish in the main view out of play: freeze it (kept in the freezer) or trash it (gone for good). It is on the dish card and in the
## Freezer section; the screen does the freezing and trashing, and asks before trashing. Neither is possible for the last running dish. While the most dishes
## that can run are running, a warning under the buttons says so (a pipette or an unfrozen dish has no room until one goes).

signal freeze_requested
signal trash_requested

const WARNING_ICON_SHARE := 0.64  ## the warning icon's width as a share of a text line: about the height of a capital letter

@onready var freeze_button: Button = $Buttons/Freeze
@onready var trash_button: Button = $Buttons/Trash
@onready var limit_row: HBoxContainer = $Limit  ## the warning that the most dishes are running
@onready var limit_icon: Button = $Limit/WarningIcon
@onready var limit_note: Label = $Limit/Note


func _ready() -> void:
	for button in [freeze_button, trash_button]:
		button.focus_mode = Control.FOCUS_NONE  # (keys stay the game's shortcuts)
	freeze_button.pressed.connect(freeze_requested.emit)
	trash_button.pressed.connect(trash_requested.emit)
	limit_note.theme_changed.connect(_size_icon)
	_size_icon()


## The buttons work only while there is another dish to carry on.
func set_available(available: bool) -> void:
	freeze_button.disabled = not available
	trash_button.disabled = not available
	freeze_button.tooltip_text = Strings.t("hud.freeze_tip" if available else "hud.freeze_last_tip")
	trash_button.tooltip_text = Strings.t("hud.trash_tip" if available else "hud.trash_last_tip")


## The warning shows while the most dishes are running.
func set_at_limit(at_limit: bool) -> void:
	limit_row.visible = at_limit


## The icon is as tall as a line of the note beside it, so it grows with the text and sits on its first line.
func _size_icon() -> void:
	var line := limit_note.get_theme_font("font").get_height(limit_note.get_theme_font_size("font_size"))
	limit_icon.custom_minimum_size = Vector2(line * WARNING_ICON_SHARE, line)
