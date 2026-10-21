extends Control
## Free mode's last step before the dish starts: every founder, in order (#1, #2 ...), to name and colour.
## Only founders can be given a colour here; their descendants drift from it as they mutate (see Genome).
## What is chosen is kept with the starting conditions, so the next launch (and a restart) starts the same way.

@onready var list: VBoxContainer = $Panel/Box/Scroll/List
@onready var random_button: Button = $Panel/Box/Header/RandomButton
@onready var spread_button: Button = $Panel/Box/Header/SpreadButton
@onready var back_button: Button = $Panel/Box/Actions/BackButton
@onready var start_button: Button = $Panel/Box/Actions/StartButton

var _start: StartConditions  ## working copy; only committed on START
var _names: Array[LineEdit] = []
var _colors: Array[ColorPickerButton] = []


func _ready() -> void:
	_start = Session.free_start.copy()
	for i in _start.bups:
		_add_row(i)
	random_button.pressed.connect(_randomise_colors)
	spread_button.pressed.connect(_spread_colors)
	back_button.pressed.connect(_back)
	start_button.pressed.connect(_start_game)
	if not _names.is_empty():
		_names[0].grab_focus()


func _add_row(index: int) -> void:
	var chosen: Dictionary = _start.founders[index] if index < _start.founders.size() else {}
	var row := HBoxContainer.new()
	var number := Label.new()
	number.text = Strings.t("founders.number", [index + 1])
	number.custom_minimum_size.x = 64.0
	number.theme_type_variation = &"Bright"
	row.add_child(number)
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = Dish.default_founder_name(index + 1)
	name_edit.text = chosen.get("name", "")
	name_edit.max_length = BupNames.MAX_LENGTH
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.custom_minimum_size.x = 260.0
	row.add_child(name_edit)
	var picker := ColorPicking.make_button()
	picker.color = Genome.color_from_hex(chosen.get("color"))
	picker.tooltip_text = Strings.t("founders.colour_tip")
	row.add_child(picker)
	list.add_child(row)
	_names.append(name_edit)
	_colors.append(picker)


## Every founder a new random colour, so they can be looked over (and any changed by hand) before the start.
func _randomise_colors() -> void:
	for picker in _colors:
		picker.color = Genome.random_color()


## Every founder a colour as far from the others as it can be: evenly spaced hues, full saturation and brightness.
func _spread_colors() -> void:
	var spread := Genome.spread_colors(_colors.size())
	for i in _colors.size():
		_colors[i].color = spread[i]


## What the rows hold, as the starting conditions keep it: only what was chosen (a name typed, a colour other than
## the default), and nothing for the founders left as they are at the end. So a short list means "these first
## ones, then the defaults", and nothing invisible from an earlier, longer list is carried along.
func _collect() -> Array:
	var default_hex := Genome.hex_of(Genome.color_of(Genome.founder()))
	var out := []
	for i in _names.size():
		var entry := {}
		var typed := Dish.cleaned_name(_names[i].text)
		if typed != "":
			entry["name"] = typed
		var hex := Genome.hex_of(_colors[i].color)
		if hex != default_hex:
			entry["color"] = hex
		out.append(entry)
	while not out.is_empty() and out.back().is_empty():
		out.pop_back()
	return out


func _unhandled_input(event: InputEvent) -> void:
	if UiInput.is_escape_press(event):
		_back()


## Keeps what the rows hold with the starting conditions (so it is there when the player comes back, and at the next launch).
func _commit() -> void:
	_start.founders = _collect()
	Session.free_start = _start
	_start.save()


func _back() -> void:
	_commit()
	get_tree().change_scene_to_file(Scenes.FREE_SETUP)


func _start_game() -> void:
	_commit()
	Session.mode = Session.Mode.FREE
	Session.load_requested = false
	get_tree().change_scene_to_file(Scenes.GAME)
