class_name TestUtil
extends RefCounted
## What the test scripts share.

static var failures: Array = []  ## what has gone wrong so far in this run (a test script's `check` adds to it)
static var checks := 0  ## how many checks have been made so far in this run


static func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures.append(what)


## `check`, and the line a windowed tool prints for it: "ok   " or "FAIL " and what it checked.
static func show(ok: bool, what: String) -> void:
	check(ok, what)
	print(("ok   " if ok else "FAIL ") + what)


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


## The game screen of `free_game(start)`, added to the tree (so its _ready runs on the next frame).
static func game_screen(tree: SceneTree, start: StartConditions) -> Node:
	var screen := free_game(start)
	tree.root.add_child(screen)
	return screen


## A dish struck with `start`, added to the tree first; `seed_value` seeds it when it is not negative.
static func dish_from(tree: SceneTree, start: StartConditions, seed_value := -1) -> Dish:
	var d := Dish.new()
	tree.root.add_child(d)
	if seed_value >= 0:
		d.set_seed(seed_value)
	d.strike(start)
	return d


## Units of nutrient dissolved in the dish.
static func units(dish: Dish) -> float:
	return dish.field.total() / Dish.NUTRIENT_ENERGY


## The nutrient in a dish as a density, in units per mm² (what the player chooses), from the total in the field.
static func density(dish: Dish) -> float:
	return units(dish) / (PI * pow(dish.radius / StartConditions.UM_PER_MM, 2))


## A dish's save, as it comes back from a file.
static func saved(dish: Dish) -> Dictionary:
	return JSON.parse_string(JSON.stringify(dish.to_dict()))


## A key press (or its release, repeat or shift) as an event to hand to a node's `_input` or to `Input.parse_input_event`.
static func key_event(code: Key, pressed := true, echo := false, shift := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.pressed = pressed
	e.echo = echo
	e.shift_pressed = shift
	return e


## The simulation constants with diffusion and uptake switched off, so a bup's motion is all that moves: tests that pin the motion count on it.
## `structure` sets `motion_structure` too when it is a number.
static func frozen_constants(structure := NAN) -> void:
	var consts := SimConstants.build()
	consts["diffusion"] = 0.0
	consts["uptake_per_size"] = 0.0
	if not is_nan(structure):
		consts["motion_structure"] = structure
	BupSim.configure(consts)
