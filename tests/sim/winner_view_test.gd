extends SceneTree
## The winner view as the game draws it (DishDrawing turns ViewRenderer's density mode on; the picture is a sprite under the capsules).
## A bare Dish on the screen over the real world, paused, 3 mm across (1,500 um radius: 150 texels at 0.1 px/um, inside the picture's half height), 100 founders in four colours, the camera at 0.1 px/um: every bup is
## far under its least footprint (Cell.MIN_VISIBLE_LENGTH_PX = 2 px; a founder is 2 to 4 um = 0.2 to 0.4 px), so every bup is in the picture
## and none is a capsule. Windowed only:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 --windowed --resolution 1280x720 -s tests/sim/winner_view_test.gd
##
## Expected values, written before the first run [derived from the splat's rules, GpuKernelsView.K_DENSITY_SPLAT and its header]:
## W  The view is made with density on and ready; the sprite shows a picture the size of the camera's rectangle (`density_size`, one texel a pixel,
##    at least 300 high so that the dish lies inside it; run with --windowed --resolution 1280x720; checked here); the last count of bups
##    the capsule path must draw is 0 (`_large`: every bup is under its footprint).
## L  Lit texels (alpha > 0). A bup covers 1.8 px^2 (2 x 1 pixels less the capsule's rounded ends, as the density header says) spread by
##    bilinear taps over up to four texels. The dish is 300 texels across with 100 bups, so two bups meet in a texel rarely and every bup lights
##    at least one texel: lit texels >= 0.9 x the bups and <= 4 x the bups.
## A  A footprint adds L = -ln(1 - its share of the texel) to the texel's sum and the texel's coverage is 1 - exp(-sum L), so for one footprint
##    the alpha is its share itself, and the four bilinear shares of one bup sum to its area: the rod of the least size, (2 - 1) x 1 + pi/4
##    = 1.785 px^2 (the kernel's `area`). The picture's alpha summed over all texels is at most 1.785 x N (texels shared by two footprints add their L, and 1 - exp(-sum L) is below the sum of the shares, so overlap
##    only lowers it) and at least 0.85 x that for 100 bups in a 300-texel dish (measured 0.92: the overlap of the founders' neighbours).
## C  Winner, not mean: the lit texels' colours are the founders' own, at most four colours (after dropping the three low bits of each
##    channel), however the bups' footprints overlap.
## H  The Bups layer hidden: the sprite is hidden. Shown again, it is back.
## F  The fallback: with the density kernels gone (`_den_made` emptied, as when they do not build) `density_ready` is false, the sprite is
##    hidden, and the view's visible bups (`_visible`: what the capsule path draws) are all N.

const BUPS := 100
const COLORS := ["e03030", "30c050", "3060e0", "e0c030"]


func _initialize() -> void:
	_run()


func _pump(d: Dish, frames: int) -> void:
	for i in frames:
		d.world.set_time(1.0, true, 1.0 / 60.0)
		await process_frame


func _picture(d: Dish) -> Image:
	var v: ViewRenderer = d.drawing.view
	var size := v.density_size()
	var out: Array = [PackedByteArray()]
	var tex := v.density_texture()
	RenderingServer.call_on_render_thread(func() -> void: out[0] = RenderingServer.get_rendering_device().texture_get_data(tex.texture_rd_rid, 0))
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, out[0])


func _run() -> void:
	if not SimHarness.begin(self, "winner_view_test", "the winner view in the game's drawing"):
		return
	SimConstants.apply()
	while not root.is_node_ready():  # (the autoloads' _ready is still running: a window change pumps frames inside it)
		await process_frame
	for i in 10:
		await process_frame
	print("window: mode %d size %s viewport %s" % [DisplayServer.window_get_mode(), DisplayServer.window_get_size(), root.size])
	var start := TestUtil.small_start()
	start.dish_radius = 1500.0
	start.bup_limit = 3000
	start.bups = BUPS
	start.founders = []
	for i in BUPS:
		start.founders.append({"color": COLORS[i % COLORS.size()]})
	var d := Dish.new()
	root.add_child(d)
	var camera := Camera2D.new()
	camera.zoom = Vector2.ONE * 0.1
	root.add_child(camera)
	await process_frame
	if not camera.is_inside_tree() or not d.is_inside_tree():
		print("FAIL: the dish or camera is not in the tree")
		quit(1)
		return
	camera.make_current()
	d.strike(start)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000 and (d.drawing.view == null or not d.drawing.density_sprite.visible):
		await _pump(d, 1)
	await _pump(d, 30)
	var v: ViewRenderer = d.drawing.view
	var n := d.population()
	var size := v.density_size() if v != null else Vector2i.ZERO
	TestUtil.show(v != null and v.density_ready() and d.drawing.density_sprite.visible and n == BUPS and size.y >= 300 and root.size == Vector2i(1280, 720) and int(v._large.get("count", -1)) == 0, "W density ready %s, sprite shown %s, %d bups, picture %s (want a height of at least the dish's 300 texels) in a %s window, capsule-path bups %s (want 0)" % [v != null and v.density_ready(), d.drawing.density_sprite.visible, n, size, root.size, v._large.get("count", "none") if v != null else "-"])
	if v == null or not v.density_ready():
		d.queue_free()
		TestUtil.finish(self, "OK winner_view_test")
		return
	var img := _picture(d)
	var lit := 0
	var alpha_sum := 0.0
	var seen := {}
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.0:
				lit += 1
				alpha_sum += c.a
				seen[Vector3i(int(c.r8) >> 3, int(c.g8) >> 3, int(c.b8) >> 3)] = true
	TestUtil.show(lit >= int(0.9 * n) and lit <= 4 * n, "L lit texels %d for %d bups (want %d to %d)" % [lit, n, int(0.9 * n), 4 * n])
	var lo := 0.85 * 1.785 * n
	var hi := 1.05 * 1.785 * n
	TestUtil.show(alpha_sum >= lo and alpha_sum <= hi, "A summed alpha %.1f for %d bups (want %.1f to %.1f)" % [alpha_sum, n, lo, hi])
	TestUtil.show(seen.size() <= COLORS.size(), "C %d colours among the lit texels (want at most %d)" % [seen.size(), COLORS.size()])
	d.show_layer(Dish.Layer.BUPS, false)
	await _pump(d, 5)
	var hidden: bool = not d.drawing.density_sprite.visible
	d.show_layer(Dish.Layer.BUPS, true)
	await _pump(d, 30)
	TestUtil.show(hidden and d.drawing.density_sprite.visible, "H the Bups layer hidden hides the picture (%s) and shown brings it back (%s)" % [hidden, d.drawing.density_sprite.visible])
	var made: Dictionary = v._den_made
	v._den_made = {}  # (the density kernels did not build)
	v.forget_build()
	await _pump(d, 30)
	var instances := int(v._visible.get("count", -1))
	TestUtil.show(not v.density_ready() and not d.drawing.density_sprite.visible and instances == n, "F without the density kernels: ready %s, sprite shown %s, visible bups %d (want %d)" % [v.density_ready(), d.drawing.density_sprite.visible, instances, n])
	v._den_made = made  # (put back, so the view frees them)
	d.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	TestUtil.finish(self, "OK winner_view_test")
