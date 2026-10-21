class_name StartConditions
extends RefCounted
## How a dish begins. Goal mode uses the defaults; free mode lets the player choose.

const MIN_BUPS := 1
const UM_PER_MM := 1000.0  ## the dish is chosen and shown in mm; the game works in µm
const MAX_BUPS := 250  ## the most founders a dish starts with (each can be named and coloured before the start)
const MIN_BUP_LIMIT := 10
const DEFAULT_BUP_LIMIT := 20000  ## what goal mode uses, and free mode starts with
const MAX_BUP_LIMIT := 100000  ## how far the limit slider goes: how many the machine can run is for the player to find out
const MAX_NUTRIENTS := 1000000  ## units of nutrient already dissolved in the dish at the start
const MAX_NUTRIENT_RATE := 30.0
const MAX_BLOOM_RATE := 500.0  ## plankton blooming a sim-day (about one every three minutes)
const MIN_DISH_RADIUS := 1000.0  ## µm: 1 mm, the smallest dish a player can choose (smaller ones are not much use)
const MIN_SIM_RADIUS := 150.0  ## µm: the smallest dish the simulation itself will run (the tests and old saves use small ones)
const MAX_DISH_RADIUS := 90000.0  ## µm: 90 mm in radius, 180 mm across; the nutrient grid has the same number of cells at any size, so a big dish has coarse ones (1.8 mm each here)

var bups := 4
var nutrients := 10000  ## units of nutrient dissolved in the dish at the start, spread evenly: enough that a few founders grow past the first goal (1,000 bups) with room to spare (measured with this default: all of 110 runs reached 1,000, at about 25-27 sim-hours; twice the nutrient gets there in about 12)
var nutrient_rate := 0.0  ## units of nutrient fed in per minute, spread evenly (none by default: the starting nutrient is the medium they begin in)
var bloom_rate := 0.0  ## plankton appearing a sim-day, at random places, each bursting into nutrient some time later
var dish_radius := Dish.DEFAULT_RADIUS  ## physical size of the dish
## What the player chose for the founders, in order: {"name": "", "color": "#rrggbb"}. Founders beyond the list, and
## any with nothing chosen, start unnamed and in the default colour.
var founders: Array = []
var bup_limit := DEFAULT_BUP_LIMIT  ## the most bups the dish holds: past it each birth displaces a random bup


## Where free mode remembers the player's last choices (separate from the experiment save).
static var settings_path := "user://free_settings.json"


## Gives the founders evenly spaced colours (as far apart in hue as they can be), at random. This is how goal mode and
## the title screen's dish start.
func spread_founders() -> void:
	founders = []
	for color in Genome.spread_colors(bups):
		founders.append({"color": Genome.hex_of(color)})


## An independent copy. Goes through to_dict/from_dict, so a new field only has to be added there.
func copy() -> StartConditions:
	return StartConditions.from_dict(to_dict())


func to_dict() -> Dictionary:
	return {"bups": bups, "nutrients": nutrients, "nutrient_rate": nutrient_rate, "bloom_rate": bloom_rate, "dish_radius": dish_radius, "bup_limit": bup_limit, "founders": founders.slice(0, bups).duplicate(true)}  # (only the founders there are: nothing hidden is carried over)


## Anything missing, malformed or out of range falls back to the default / the nearest valid value.
static func from_dict(d: Dictionary) -> StartConditions:
	var c := StartConditions.new()
	c.bups = clampi(int(_number(d, "bups", c.bups)), MIN_BUPS, MAX_BUPS)
	c.nutrients = clampi(int(_number(d, "nutrients", c.nutrients)), 0, MAX_NUTRIENTS)
	c.nutrient_rate = clampf(_number(d, "nutrient_rate", c.nutrient_rate), 0.0, MAX_NUTRIENT_RATE)
	c.bloom_rate = clampf(_number(d, "bloom_rate", c.bloom_rate), 0.0, MAX_BLOOM_RATE)
	c.dish_radius = clampf(_number(d, "dish_radius", c.dish_radius), MIN_DISH_RADIUS, MAX_DISH_RADIUS)
	c.bup_limit = clampi(int(_number(d, "bup_limit", c.bup_limit)), MIN_BUP_LIMIT, MAX_BUP_LIMIT)
	c.bup_limit = maxi(c.bup_limit, c.bups)  # the dish holds at least its founders
	var saved_founders: Variant = d.get("founders")
	if saved_founders is Array:
		for entry in saved_founders.slice(0, MAX_BUPS):
			var founder := {}
			if entry is Dictionary:
				if entry.get("name") is String:
					founder["name"] = Dish.cleaned_name(entry["name"])
				if Genome.is_hex_color(entry.get("color")):
					founder["color"] = entry["color"].to_lower()
			c.founders.append(founder)
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
