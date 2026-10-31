extends SceneTree
## A screenshot pack of the pooled world, windowed, on the real game stack, saved at interface sizes
## 100%, 150% and 250% for a look: the title backdrop, the free-setup preview, the game screen with feeders (sources layer), a bup at close zoom,
## and the busy state (several dishes, frozen dishes, a picked bup, a full watch list, the pipette open). It prints the counts.
## tools/run_windowed.sh <log> -- --path . --rendering-driver metal --resolution 1920x1080 --position 6000,6000 -s tools/parity_pack.gd -- <out_dir> [dishes] [frozen] [sections: title,setup,game,busy]

const WATCHED := 12  ## bups put on the watch list in the busy state
const WAIT_MSEC := 300000  ## the longest the busy world is waited for
const SCALES := [100, 150, 250]


func _initialize() -> void:
	_run()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(out: String, name: String, after_scale := Callable()) -> void:
	for pct: int in SCALES:
		UserSettings.native_override = 1.0
		UserSettings.ui_scale = pct / 100.0
		UserSettings.apply()
		await _frames(60)
		if after_scale.is_valid():
			after_scale.call()
			await _frames(20)
		var path := ProjectSettings.globalize_path(out.path_join("%s_%d.png" % [name, pct]))
		get_root().get_viewport().get_texture().get_image().save_png(path)
		print("PACK %s %d%%: %s" % [name, pct, path])


func _leave(screen: Node) -> void:
	screen.queue_free()
	await _frames(10)


func _run() -> void:
	SimConstants.apply()
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://parity_pack"
	var count := int(args[1]) if args.size() > 1 else 12
	var frozen := int(args[2]) if args.size() > 2 else 3
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var only: PackedStringArray = args[3].split(",") if args.size() > 3 else PackedStringArray(["title", "setup", "game", "busy"])
	if "title" in only:
		await _title(out)
	if "setup" in only:
		await _free_setup(out)
	if "game" in only:
		await _game_views(out)
	if "busy" in only:
		await _busy(out, count, frozen)
	quit(0)


## The title's dish, run at x1 for 3 s of real time, with its bup count.
func _title(out: String) -> void:
	var menu: Node = load(Scenes.MENU).instantiate()
	root.add_child(menu)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	var d: Dish = menu.dish
	print("PACK title backdrop: %d bups in the snapshot after %d ms, still picture %s" % [d.population(), Time.get_ticks_msec() - t0, str(menu._still != null and menu._still.visible)])
	await _shot(out, "title")
	await _leave(menu)


## The preview dish with a bloom, once the sliders have been still: its plankton count against the steady state.
func _free_setup(out: String) -> void:
	var start := StartConditions.new()
	start.bloom_density = 2.0
	start.spread_founders()
	Session.free_start = start
	Session.mode = Session.Mode.FREE
	var setup: Node = load(Scenes.FREE_SETUP).instantiate()
	root.add_child(setup)
	await _frames(240)
	var d: Dish = setup.dish
	var expected := int(round(d.bloom_per_day() * Dish.PLANKTON_MEAN_LIFE / 86400.0))
	print("PACK free setup preview: %d plankton in the snapshot, steady state asked for %d (derived: bloom_per_day * mean life / 86400), %d bups" % [d.plankton.size(), expected, d.population()])
	await _shot(out, "free_setup")
	await _leave(setup)


## One dish with feeders, whole and then a bup at close zoom (paused, so the bup stays put).
func _game_views(out: String) -> void:
	var start := StartConditions.new()
	start.dish_radius = 600.0
	start.bups = 60
	start.bup_limit = 300
	start.nutrient_density = 32.0
	start.bloom_density = 2.0
	start.spread_founders()
	var m: Node = TestUtil.game_screen(self, start)
	for i in 600:
		await process_frame
		if m.is_node_ready() and m.dish != null and i > 5:
			break
	m.toolbar.set_paused(false)
	m.sim_speed = 100.0
	var placed := 0
	for a in 6:
		var at: Vector2 = m.dish.global_position + Vector2.from_angle(a * TAU / 6.0 + 0.3) * 330.0
		if m.dish.place_source(at, 2.0 + a):
			placed += 1
	m.dish.show_layer(Dish.Layer.SOURCES, true)
	await _frames(600)
	print("PACK sources: %d placed, %d in the snapshot, layer shown %s, %d bups, %d plankton" % [placed, m.dish.sources.size(), str(m.dish.layer_shown(Dish.Layer.SOURCES)), m.dish.population(), m.dish.plankton.size()])
	await _shot(out, "sources")
	var src: NutrientSource = m.dish.sources[0] if not m.dish.sources.is_empty() else null
	if src != null:
		await _shot(out, "sources_close", func() -> void: m.stage_input.look_at_world(src.pos, 3.0))
	m.toolbar.set_paused(true)
	await _frames(30)
	var ids: PackedInt64Array = m.dish.bup_ids()
	if not ids.is_empty():
		m.dish.selected.bup = ids[0]  # (the dish asks after the picked bup's place, so the view knows where it is)
		await _frames(60)
		var at: Vector2 = m.dish.bup_world_pos(ids[0])
		print("PACK close zoom on bup %d at %s, zoom %.0f, %d bups" % [ids[0], str(at), StageInput.ZOOM_MAX, ids.size()])
		await _shot(out, "bups_close", func() -> void: m.stage_input.look_at_world(at, StageInput.ZOOM_MAX))
	await _leave(m)


## Several dishes, frozen ones, a picked bup, the watch list full, the pipette open, the all-dishes details and the freezer open.
func _busy(out: String, count: int, frozen: int) -> void:
	var start := StartConditions.new()
	start.dish_radius = 600.0
	start.bups = 60
	start.bup_limit = 300
	start.nutrient_density = 32.0
	start.spread_founders()
	var m: Node = TestUtil.game_screen(self, start)
	for i in 600:
		await process_frame
		if m.is_node_ready() and m.dish != null and i > 5:
			break
	m.toolbar.set_paused(false)
	m.sim_speed = 100.0
	var t0 := Time.get_ticks_msec()
	while m.dishes.size() < count + frozen:
		if m.add_dish(start) == null:
			break
	while Time.get_ticks_msec() - t0 < WAIT_MSEC:
		await process_frame
		if WorldClient.shared().latest().dishes.size() >= m.dishes.size():
			break
	await _frames(300)
	for i in frozen:
		m.freeze_dish(m.dishes[m.dishes.size() - 1 - i * 3])
	while m.holds.stills_world() and Time.get_ticks_msec() - t0 < WAIT_MSEC:
		await process_frame
	await _frames(300)
	print("PACK busy: running %d, in the snapshot %d, frozen %d" % [m.dishes.size(), WorldClient.shared().latest().dishes.size(), m.freezer_shelf.entries.size()])
	var ids: PackedInt64Array = m.dish.bup_ids()
	for i in mini(WATCHED, ids.size()):
		m.dish.watch_bup(ids[i])
	m.all_details.open = true
	m.freezer_section.open = true
	m.toolbar.select_tool(Toolbar.Tool.PIPETTE)
	m.set_main_dish(m.dishes[m.dishes.size() / 2])
	m.set_main_dish(m.dishes[0])
	m.dish.selected.bup = ids[0] if not ids.is_empty() else -1
	await _frames(180)
	print("PACK busy: picked bup %d, achieved x%.0f" % [m.dish.selected.bup, m.achieved_speed])
	for pct: int in SCALES:
		UserSettings.native_override = 1.0
		UserSettings.ui_scale = pct / 100.0
		UserSettings.apply()
		await _frames(60)
		get_root().get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(out.path_join("busy_%d.png" % pct)))
		m.side.ensure_control_visible(m.freezer_section)
		await _frames(10)
		get_root().get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(out.path_join("busy_%d_tray.png" % pct)))
		m.side.scroll_vertical = 0
		print("PACK busy %d%% saved" % pct)
	await _leave(m)
