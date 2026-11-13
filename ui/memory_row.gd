class_name MemoryRow
extends VBoxContainer
## The setting for the memory the simulation may use (`UserSettings.memory_mode`): its name, three segments (Auto, Low, Number) of which exactly one
## is lit, a number of GB that shows only under Number, and below, always in view, what the choices do. It is a row of its own and not a ToggleRow
## because it has three states and a number. It reports `changed` with the mode and the GB when the player chooses.

signal changed(mode: String, gb: float)

const MODES: Array[String] = [PoolLimits.MEMORY_AUTO, PoolLimits.MEMORY_LOW, PoolLimits.MEMORY_CUSTOM]

@onready var name_label: Label = $Row/Name
@onready var segments: Control = $Row/Segments
@onready var auto_button: Button = $Row/Segments/Choices/AutoButton
@onready var low_button: Button = $Row/Segments/Choices/LowButton
@onready var custom_button: Button = $Row/Segments/Choices/CustomButton
@onready var amount_row: SettingRow = $AmountRow
@onready var hint_label: Label = $Hint

var mode := PoolLimits.MEMORY_AUTO
var gb := 0.0
var _syncing := false


func _ready() -> void:
	var group := ButtonGroup.new()
	var buttons: Array[Button] = [auto_button, low_button, custom_button]
	for i in buttons.size():
		var button := buttons[i]
		button.button_group = group
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_choose.bind(MODES[i]))
	segments.focus_mode = Control.FOCUS_ALL
	segments.gui_input.connect(_on_segments_input)
	segments.focus_entered.connect(func() -> void:
		segments.theme_type_variation = &"SwitchSegmentsFocused"
		name_label.theme_type_variation = &"FocusLabel")
	segments.focus_exited.connect(func() -> void:
		segments.theme_type_variation = &"SwitchSegments"
		name_label.theme_type_variation = &"")
	amount_row.configure(UserSettings.MEMORY_GB_MIN, UserSettings.MEMORY_GB_MAX, UserSettings.MEMORY_GB_STEP, _auto_gb(), Strings.t("options.memory_unit"))
	amount_row.value_changed.connect(func(v: float) -> void:
		if not _syncing:
			gb = v
			changed.emit(mode, gb))
	hint_label.text = Strings.t("options.memory_hint", [
		str(PoolLimits.BUDGET_SHARE),
		MemoryMode.gb_text(PoolLimits.BUDGET_FLOOR),
		MemoryMode.gb_text(PoolLimits.BUDGET_CAP),
		MemoryMode.gb_text(PoolLimits.DISCRETE_BUDGET),
		UiText.thousands(PoolLimits.LOW_BUPS),
		str(PoolLimits.LOW_DISHES),
		"%d x %d" % [PoolLimits.LOW_GRID, PoolLimits.LOW_GRID]])
	_light()


## Shows a setting without reporting it.
func show_setting(p_mode: String, p_gb: float) -> void:
	mode = p_mode
	gb = p_gb
	_light()


## What Auto gives on this machine, in GB: where the number starts when the player first chooses Number.
func _auto_gb() -> float:
	return snappedf(float(PoolLimits.budget_for(MemoryMode.report())) / float(PoolLimits.GIB), UserSettings.MEMORY_GB_STEP)


func _choose(p_mode: String) -> void:
	if _syncing or p_mode == mode:
		return
	mode = p_mode
	if mode == PoolLimits.MEMORY_CUSTOM and gb <= 0.0:
		gb = _auto_gb()
	_light()
	changed.emit(mode, gb)


func _light() -> void:
	if not is_node_ready():
		return
	_syncing = true
	auto_button.set_pressed_no_signal(mode == PoolLimits.MEMORY_AUTO)
	low_button.set_pressed_no_signal(mode == PoolLimits.MEMORY_LOW)
	custom_button.set_pressed_no_signal(mode == PoolLimits.MEMORY_CUSTOM)
	amount_row.visible = mode == PoolLimits.MEMORY_CUSTOM
	if gb > 0.0:
		amount_row.set_value_silently(gb)
	else:
		amount_row.set_value_silently(_auto_gb())
	_syncing = false


func _on_segments_input(event: InputEvent) -> void:
	var at := MODES.find(mode)
	if event.is_action_pressed("ui_left"):
		at = maxi(at - 1, 0)
	elif event.is_action_pressed("ui_right"):
		at = mini(at + 1, MODES.size() - 1)
	else:
		return
	segments.accept_event()
	_choose(MODES[at])
