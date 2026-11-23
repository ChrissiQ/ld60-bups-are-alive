extends SceneTree
## Leaving a game for the menu: the game's dishes leave the world, and the menu's backdrop dish shows only its own bups. Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/leave_game_test.gd
##
## Expected values [derived: a dish leaves the world when its node leaves the tree (Dish._exit_tree); the menu strikes one dish of
## StartConditions.new() with `spread_founders` (4 founders, a pool block of 256 slots) in the row the game's first dish held, with the same
## world number 1; snapshots and pictures made before the dish was added are those of the dish that held the row, so a dish must tell them from its own]:
## G  A free game of 4 dishes (250 founders, 90 mm, a limit of 2,000,000), run at x10,000 until the main dish has 150,000 bups: the world holds
##    4 dishes, in rows 0 to 3, and at least 150,000 slots are in use.
## B  From the frame the menu opens, on every frame (the pipeline still holds states and pictures of the game for some frames): the backdrop's
##    population is 0 (nothing of its own seen yet) or 4, never the game's, and a picture its view holds has 4 bups.
## L  Once the backdrop has shown its 4 bups: the world holds one dish, in row 0, and 256 slots are in use (the game's slots are closed up and
##    given back), and the backdrop's population is still 4.

const DISHES := 4
const FOUNDERS_BACKDROP := 4
const BIG := 150000

var _frames := 0


func _initialize() -> void:
	_run()


func _frame(speed := 1.0, paused := false) -> void:
	WorldClient.shared().set_time(speed, paused, 1.0 / 60.0)
	await process_frame
	_frames += 1


func _run() -> void:
	if not SimHarness.begin(self, "leave_game_test", "the pooled world"):
		return
	Session.mode = Session.Mode.FREE
	Session.tutorial_wanted = false
	var start := StartConditions.new()
	start.bups = 250
	start.dish_radius = 90000.0
	start.bup_limit = 2000000
	start.feed_density = 50.0
	Session.free_start = start
	# (a window mode set inside a screen's _ready runs frames in the middle of it: set it before the screen opens)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	for i in 10:
		await process_frame
	change_scene_to_file(Scenes.GAME)
	var w := WorldClient.shared()
	var main: Node = null
	for i in 3600:
		main = current_scene
		if main != null and main.get("holds") != null and not main.dishes.is_empty() and w.backend.status().get("ready", false):
			break
		await _frame()
	for i in 20:
		await _frame()
	for i in DISHES - 1:
		main.add_dish(start)
	main.toolbar.set_paused(false)
	main.sim_speed = 10000.0
	for i in 20000:
		await _frame()
		if main.dish.population() >= BIG:
			break
	var game: Dictionary = await _world_state()
	TestUtil.show(game["rows"] == [0, 1, 2, 3] and game["slots"] >= BIG, "G the game's world holds dishes in rows %s and %d slots" % [game["rows"], game["slots"]])

	change_scene_to_file(Scenes.MENU)
	var foreign := 0
	var bad_picture := 0
	var shown_own := false
	var seen_pictures := 0
	for i in 600:
		await _frame()
		var menu := current_scene
		if menu == null or menu.scene_file_path != Scenes.MENU:
			continue
		var d: Dish = menu.dish
		var pop := d.population()
		if pop != 0 and pop != FOUNDERS_BACKDROP:
			foreign += 1
		var view := d.drawing.view
		if view != null:
			var p := view.payload()
			if p != null and p.seq >= 0 and p.count > 0:
				seen_pictures += 1
				if p.count != FOUNDERS_BACKDROP:
					bad_picture += 1
		if pop == FOUNDERS_BACKDROP and seen_pictures > 0:
			shown_own = true
			if i > 60:
				break
	TestUtil.show(foreign == 0, "B the backdrop's population was never the game's (%d frames of another's)" % foreign)
	TestUtil.show(bad_picture == 0 and seen_pictures > 0, "B every picture its view held was its own, of %d bups (%d of %d were not)" % [FOUNDERS_BACKDROP, bad_picture, seen_pictures])
	TestUtil.show(shown_own, "L the backdrop shows its %d bups" % FOUNDERS_BACKDROP)
	var menu_world: Dictionary = await _world_state()
	TestUtil.show(menu_world["rows"] == [0] and menu_world["slots"] == 256, "L the world holds only the backdrop, in rows %s with %d slots in use" % [menu_world["rows"], menu_world["slots"]])
	TestUtil.finish(self, "OK leave_game_test")


## {rows: the core's dishes' client rows, slots}, read on the simulation's thread.
func _world_state() -> Dictionary:
	var r := WorldClient.shared().inspect(func(core: SimCore, rows: Dictionary) -> Dictionary:
		var rs := rows.keys()
		rs.sort()
		return {"rows": rs, "slots": core.in_use()["slots"]})
	for i in 3600:
		if r.is_done():
			break
		await _frame()
	return r.value()
