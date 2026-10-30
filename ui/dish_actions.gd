class_name DishActions
extends HFlowContainer
## The two things that take the dish in the main view out of play: freeze it (kept in the freezer) or trash it (gone for good). It is on the dish card and in the
## Freezer section; the screen does the freezing and trashing, and asks before trashing. Neither is possible for the last running dish.

signal freeze_requested
signal trash_requested

@onready var freeze_button: Button = $Freeze
@onready var trash_button: Button = $Trash


func _ready() -> void:
	for button in [freeze_button, trash_button]:
		button.focus_mode = Control.FOCUS_NONE  # (keys stay the game's shortcuts)
	freeze_button.pressed.connect(freeze_requested.emit)
	trash_button.pressed.connect(trash_requested.emit)


## The buttons work only while there is another dish to carry on.
func set_available(available: bool) -> void:
	freeze_button.disabled = not available
	trash_button.disabled = not available
	freeze_button.tooltip_text = Strings.t("hud.freeze_tip" if available else "hud.freeze_last_tip")
	trash_button.tooltip_text = Strings.t("hud.trash_tip" if available else "hud.trash_last_tip")
