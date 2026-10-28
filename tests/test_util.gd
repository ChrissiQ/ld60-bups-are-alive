class_name TestUtil
extends RefCounted
## What the test scripts share.

static var failures: Array = []  ## what has gone wrong so far in this run (a test script's `check` adds to it)


static func check(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)


## Ends a test script: prints `ok_text` if nothing failed, or each failure if something did, and quits with the result.
static func finish(tree: SceneTree, ok_text: String, failed_title := "FAILED:") -> void:
	if failures.is_empty():
		print(ok_text)
	else:
		print(failed_title)
		for f in failures:
			print("  - ", f)
	tree.quit(0 if failures.is_empty() else 1)


## The files in `dirs` (a list of folders) with one of the extensions `exts`, as paths.
static func files(dirs: Array, exts: Array) -> Array:
	var out := []
	for dir in dirs:
		for f in DirAccess.get_files_at(dir):
			if f.get_extension() in exts:
				out.append(dir.path_join(f))
	return out


## A dish of the old 300 µm size: tests that place things by hand count on a small, fine grid.
static func small_start() -> StartConditions:
	var start := StartConditions.new()
	start.dish_radius = 300.0
	start.bup_limit = Dish.cap_for(300.0)
	start.stationary_phase = false  # (the tests that use this dish pin the model's other rules, among them that a bup with no energy dies at once)
	return start


## The game screen in free mode with `start`, as Main starts from the setup screen: not yet in the tree, so its _ready has not run.
static func free_game(start: StartConditions) -> Node:
	Session.free_start = start
	Session.mode = Session.Mode.FREE
	Session.load_requested = false
	return load(Scenes.GAME).instantiate()


## Units of nutrient dissolved in the dish.
static func units(dish: Dish) -> float:
	return dish.field.total() / Dish.NUTRIENT_ENERGY


## The nutrient in a dish as a density, in units per mm² (what the player chooses), from the total in the field.
static func density(dish: Dish) -> float:
	return units(dish) / (PI * pow(dish.radius / StartConditions.UM_PER_MM, 2))


## A dish's save, as it comes back from a file.
static func saved(dish: Dish) -> Dictionary:
	return JSON.parse_string(JSON.stringify(dish.to_dict()))
