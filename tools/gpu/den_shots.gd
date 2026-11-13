extends SceneTree
## The game screen (Main) with one paused dish of `bups` founders spread over its middle in 16 colours, saved at interface sizes 100%, 150% and
## 250% at fit zoom and at four closer zooms (the density picture's crossing is at a bup length of Cell.MIN_VISIBLE_LENGTH_PX screen pixels: a
## founder is 2 to 4 µm long, so a zoom of 0.5 px/µm has every bup under it, 0.75 some, 1.5 none), and each again right after with density off (the
## capsule drawing the same view gets without it: cap_*.png). Prints each view's density state.
## tools/run_windowed.sh <log> -- --path . --rendering-driver metal --resolution 1920x1080 --position 6000,6000 -s tools/gpu/den_shots.gd -- <out_dir> [bups] [off]

const ZOOMS := [0.5, 0.75, 1.5, 4.0]  ## px/µm; fit zoom besides
const WAIT_MSEC := 300000


func _initialize() -> void:
	_run()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _grab(m: Node, path: String) -> void:
	await _frames(20)
	var image := m.get_viewport().get_texture().get_image()
	image.save_png(path)
	var v: ViewRenderer = m.dish.drawing.view
	print("DEN %s: density_ready %s, picture %s, sprite %s, bups %d" % [path.get_file(), v.density_ready() if v != null else "no view", str(v.density_size()) if v != null else "-", m.dish.drawing.density_sprite.visible if "density_sprite" in m.dish.drawing else "none (base code)", m.dish.population()])


func _run() -> void:
	SimConstants.apply()
	while not root.is_node_ready():  # (the autoloads' _ready is still running: a window change pumps frames inside it)
		await process_frame
	for i in 10:
		await process_frame
	print("DEN window: mode %d size %s" % [DisplayServer.window_get_mode(), DisplayServer.window_get_size()])
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://den_shots"
	var count := int(args[1]) if args.size() > 1 else 1000
	var off_only := args.size() > 2 and args[2] == "off"  ## the base code's check: only the density-off shots
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var start := StartConditions.new()
	start.dish_radius = 90000.0
	start.bups = count
	start.bup_limit = mini(int(count * 1.05) + 10, StartConditions.MAX_BUP_LIMIT)
	start.nutrient_density = 4.0
	start.feed_density = 0.0
	start.bloom_density = 0.0
	var palette: Array = []
	for c in Genome.spread_colors(16):
		palette.append({"color": Genome.hex_of(c)})
	start.founders = []
	for i in count:
		start.founders.append(palette[i % palette.size()])
	var m: Node = TestUtil.game_screen(self, start)
	if m == null or not m.is_inside_tree() or not "toolbar" in m:
		print("DEN FAIL: no game screen")
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	for i in 6000:
		await process_frame
		if m.is_node_ready() and m.dish != null and m.dish.row >= 0 and i > 5:
			break
	m.toolbar.set_paused(true)
	while Time.get_ticks_msec() - t0 < WAIT_MSEC:
		await process_frame
		var v: ViewRenderer = m.dish.drawing.view
		if v != null and (off_only or v.density_ready()) and v.payload().count >= count and m.dish.population() >= count:
			break
	print("DEN %d bups in the view after %d ms" % [count, Time.get_ticks_msec() - t0])
	UserSettings.native_override = 1.0
	for pct in [100, 150, 250]:
		UserSettings.ui_scale = pct / 100.0
		UserSettings.apply()
		await _frames(60)
		m.stage_input.fit_camera()
		var views: Array = [["fit", null]]
		for z: float in ZOOMS:
			views.append(["z" + str(z).replace(".", "p"), z])
		for view_spec: Array in views:
			if view_spec[1] != null:
				m.stage_input.look_at_world(m.dish.global_position, view_spec[1])
			elif view_spec != views[0]:
				m.stage_input.fit_camera()
			for with_density in ([false] if off_only else [true, false]):
				m.dish.drawing.view.set_density(with_density)
				var prefix := "den" if with_density else "cap"
				await _grab(m, ProjectSettings.globalize_path(out.path_join("%s_%d_%d_%s.png" % [prefix, count, pct, view_spec[0]])))
	quit(0)
