class_name StartConditions
extends RefCounted
## How a dish begins. Goal mode uses the defaults; free mode lets the player choose.

const MIN_BUPS := 1
const UM_PER_MM := 1000.0  ## the dish is chosen and shown in mm; the game works in µm
const MAX_BUPS := 250  ## the most founders a dish starts with (each can be named and coloured before the start)
const MIN_BUP_LIMIT := 10
const DEFAULT_BUP_LIMIT := 20000  ## what goal mode uses, and free mode starts with
const MAX_BUP_LIMIT := 100000  ## how far the limit slider goes: how many the machine can run is for the player to find out
const MAX_NUTRIENT_DENSITY := 1000.0  ## units of nutrient in each mm² of the dish at the start (the info panel reads the nutrient in the same units/mm²)
const MAX_FEED_DENSITY := 20.0  ## units of nutrient added to each mm² of the dish every hour
const MIN_NUTRIENT_RESOLUTION := 100  ## the fewest cells across the dish's nutrient grid (the default: what a dish up to 2.5 mm across gets anyway)
const MAX_NUTRIENT_RESOLUTION := 400  ## the most: 450 µm cells on the biggest dish, which keeps the plankton clouds there (see Dish.FIELD_MAX_ACROSS)
const NUTRIENT_RESOLUTION_STEP := 50
const MIN_MEDIUM_THICKNESS := 1.0  ## water
const MAX_MEDIUM_THICKNESS := 100.0
const MAX_BLOOM_DENSITY := 10.0  ## plankton blooming in each mm² of the dish every sim-day (about 250,000 a day, 10,000 floating at once, on the biggest dish)
const MIN_DISH_RADIUS := 1000.0  ## µm: 1 mm, the smallest dish a player can choose (smaller ones are not much use)
const MIN_SIM_RADIUS := 150.0  ## µm: the smallest dish the simulation itself will run (the tests and old saves use small ones)
const MAX_DISH_RADIUS := 90000.0  ## µm: 90 mm in radius, 180 mm across; the nutrient grid has the same number of cells at any size, so a big dish has coarse ones (1.8 mm each here)

var bups := 4
var nutrient_density := 32.0  ## units of nutrient in each mm² of the dish at the start, spread evenly: enough that a few founders grow past the first goal (1,000 bups) with room to spare (measured at 10 mm radius, 10,000 units in all, about this much: all of 110 runs reached 1,000, at about 25-27 sim-hours; twice the nutrient gets there in about 12). A density, not a total, so the dish can be made any size without choosing the nutrient again.
var feed_density := 0.0  ## units of nutrient fed in to each mm² of the dish every hour, spread evenly (none by default: the starting nutrient is the medium they begin in)
var bloom_density := 0.0  ## plankton appearing in each mm² of the dish every sim-day, at random places, each bursting into nutrient some time later (a density, like the nutrient and the feed, so the dish can be any size without choosing it again)
var dish_radius := Dish.DEFAULT_RADIUS  ## physical size of the dish
var medium_thickness := Biology.MEDIUM_THICKNESS  ## how many times thicker than water the medium is: the nutrient spreads that many times slower in it (swimming is not slowed). An advanced option: the default is what the game is tuned for
var nutrient_resolution := MIN_NUTRIENT_RESOLUTION  ## cells across the dish's nutrient grid: more shows small nutrient clouds true in a big dish (a cell is the dish's width over this) and slows the simulation
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
	return {"bups": bups, "nutrient_density": nutrient_density, "feed_density": feed_density, "bloom_density": bloom_density, "dish_radius": dish_radius, "medium_thickness": medium_thickness, "nutrient_resolution": nutrient_resolution, "bup_limit": bup_limit, "founders": founders.slice(0, bups).duplicate(true)}  # (only the founders there are: nothing hidden is carried over)


## Anything missing, malformed or out of range falls back to the default / the nearest valid value.
static func from_dict(d: Dictionary) -> StartConditions:
	var c := StartConditions.new()
	c.bups = clampi(int(_number(d, "bups", c.bups)), MIN_BUPS, MAX_BUPS)
	c.nutrient_density = clampf(_number(d, "nutrient_density", c.nutrient_density), 0.0, MAX_NUTRIENT_DENSITY)
	c.feed_density = clampf(_number(d, "feed_density", c.feed_density), 0.0, MAX_FEED_DENSITY)
	c.bloom_density = clampf(_number(d, "bloom_density", c.bloom_density), 0.0, MAX_BLOOM_DENSITY)
	c.dish_radius = clampf(_number(d, "dish_radius", c.dish_radius), MIN_DISH_RADIUS, MAX_DISH_RADIUS)
	c.medium_thickness = clampf(_number(d, "medium_thickness", c.medium_thickness), MIN_MEDIUM_THICKNESS, MAX_MEDIUM_THICKNESS)
	c.nutrient_resolution = clampi(int(_number(d, "nutrient_resolution", c.nutrient_resolution)), MIN_NUTRIENT_RESOLUTION, MAX_NUTRIENT_RESOLUTION)
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
