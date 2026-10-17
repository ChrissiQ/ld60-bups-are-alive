class_name StartConditions
extends RefCounted
## How a dish begins. Goal mode uses the defaults; free mode lets the player choose.

const MIN_BUPS := 1
const MAX_BUPS := 200  ## a deliberate cap for the setup sliders, below the sim's Dish.MAX_CELLS
const MAX_NUTRIENTS := Dish.MAX_FOOD  ## can't start with more food than the dish can hold
const MAX_NUTRIENT_RATE := 30.0
const MIN_DISH_RADIUS := 150.0
const MAX_DISH_RADIUS := 600.0

var bups := 4
var nutrients := 60  ## food items in the dish at the start
var nutrient_rate := 6.0  ## food items appearing per second
var dish_radius := Dish.DEFAULT_RADIUS  ## physical size of the dish


## Where free mode remembers the player's last choices (separate from the experiment save).
static var settings_path := "user://free_settings.json"


## An independent copy. Goes through to_dict/from_dict, so a new field only has to be added there.
func copy() -> StartConditions:
	return StartConditions.from_dict(to_dict())


func to_dict() -> Dictionary:
	return {"bups": bups, "nutrients": nutrients, "nutrient_rate": nutrient_rate, "dish_radius": dish_radius}


## Anything missing, malformed or out of range falls back to the default / the nearest valid value.
static func from_dict(d: Dictionary) -> StartConditions:
	var c := StartConditions.new()
	c.bups = clampi(int(_number(d, "bups", c.bups)), MIN_BUPS, MAX_BUPS)
	c.nutrients = clampi(int(_number(d, "nutrients", c.nutrients)), 0, MAX_NUTRIENTS)
	c.nutrient_rate = clampf(_number(d, "nutrient_rate", c.nutrient_rate), 0.0, MAX_NUTRIENT_RATE)
	c.dish_radius = clampf(_number(d, "dish_radius", c.dish_radius), MIN_DISH_RADIUS, MAX_DISH_RADIUS)
	return c


func save() -> bool:
	var file := FileAccess.open(settings_path, FileAccess.WRITE)
	if file == null:
		push_warning("Could not save free-mode settings: %s" % error_string(FileAccess.get_open_error()))
		return false
	file.store_string(JSON.stringify(to_dict()))
	return true


## The last saved choices, or the defaults if free mode has never been started.
static func load_saved() -> StartConditions:
	if not FileAccess.file_exists(settings_path):
		return StartConditions.new()
	var json := JSON.new()  # unlike JSON.parse_string, a bad file fails quietly
	if json.parse(FileAccess.get_file_as_string(settings_path)) != OK:
		return StartConditions.new()
	return from_dict(json.data) if json.data is Dictionary else StartConditions.new()


static func _number(d: Dictionary, key: String, fallback: float) -> float:
	var v: Variant = d.get(key)
	return float(v) if Validate.is_number(v) else fallback
