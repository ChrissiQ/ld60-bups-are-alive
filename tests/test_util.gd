class_name TestUtil
extends RefCounted
## What the test scripts share.


## A dish of the old 300 µm size: tests that place things by hand count on a small, fine grid.
static func small_start() -> StartConditions:
	var start := StartConditions.new()
	start.dish_radius = 300.0
	start.bup_limit = Dish.cap_for(300.0)
	return start


## Units of nutrient dissolved in the dish.
static func units(dish: Dish) -> float:
	return dish.field.total() / Dish.NUTRIENT_ENERGY


## A dish's save, as it comes back from a file.
static func saved(dish: Dish) -> Dictionary:
	return JSON.parse_string(JSON.stringify(dish.to_dict()))
