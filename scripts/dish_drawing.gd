class_name DishDrawing
extends RefCounted
## How a dish is drawn: the bups' picture (one multimesh, built from the CPU's simulation or written by the GPU), the husks' picture,
## the dish itself with the nutrient haze, the steering map, the sources and the plankton (`draw`, for Dish._draw), and the rings, the
## placement preview and the flash above the bups (`draw_overlay`, for the dish's DishOverlay). Nothing here changes the simulation.
## It is a part of its Dish, and holds the nodes it draws with and the bups' picture's flags between frames; the dish's edits set `stale`.

var dish: Dish
var bups_mesh: MultiMeshInstance2D = null  ## all the bups, drawn in one go
var husks_mesh: MultiMeshInstance2D = null  ## every husk, as one instance each
var overlay: Node2D = null  ## the selection and hover rings, drawn above the bups
var render_stamp := []  ## what the bups' picture was last built from
var stale := true  ## the bups were changed by hand (added, removed, a new dish), so the picture must be rebuilt
var trails_may_show := false  ## the last picture was made as time moved, so bups in it may be drawn with trails
var _draw_key := []  ## what the dish was last drawn from (see `refresh`)
var _haze: ImageTexture = null
var _haze_built := 0
var _steer: ImageTexture = null  ## where the selected bup could steer (see `_draw_steering`)
var _steer_key := []
var _plankton_picture: ImageTexture = null  ## what a small plankton is drawn from (made when first needed)
var _plankton_mesh: MultiMesh = null  ## where each small plankton is, for drawing them all at once
var _plankton_key: Array = []  ## what `_plankton_mesh` was last built for: how many plankton, the edit count and the radius drawn
var _plankton_built := 0  ## when it was (msec)
var _husk_stamp := []  ## what the husk picture was last built for (the time, how many there were, the size of a husk)
var _husk_built_msec := 0


func _init(for_dish: Dish) -> void:
	dish = for_dish


## A layer was shown or hidden: the bups' and the husks' pictures follow it, and the rings and the dish are drawn again.
func layer_changed(layer: Dish.Layer, shown: bool) -> void:
	match layer:
		Dish.Layer.BUPS:
			bups_mesh.visible = shown
			stale = true  # (what was not drawn while hidden is drawn afresh)
		Dish.Layer.HUSKS:
			husks_mesh.visible = shown
	dish.queue_redraw()
	overlay.queue_redraw()


## Makes the dish's children that draw: the husks' and the bups' multimeshes (the husks under the bups) and the overlay above them.
func build_children() -> void:
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = Dish.BUP_SHADER
	material.set_shader_parameter("fade_pixels", Dish.TRAIL_FADE_PIXELS)
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	var husk_mesh := QuadMesh.new()
	husk_mesh.size = Vector2.ONE
	var husks := MultiMesh.new()
	husks.transform_format = MultiMesh.TRANSFORM_2D
	husks.mesh = husk_mesh
	husks_mesh = MultiMeshInstance2D.new()  # (under the bups: one instance for every husk there is, drawn by the graphics card, so there is no limit on how many are shown)
	husks_mesh.multimesh = husks
	husks_mesh.self_modulate = Dish.HUSK_COLOR
	dish.add_child(husks_mesh)
	bups_mesh = MultiMeshInstance2D.new()
	bups_mesh.multimesh = multimesh
	bups_mesh.material = material
	dish.add_child(bups_mesh)
	overlay = DishOverlay.new()
	overlay.dish = dish
	dish.add_child(overlay)
	sync_render_capacity()


## Redraws the dish only when something it shows may have changed: the picture of the medium is rebuilt a few times a
## second, and the sources, the size and the zoom show at once. Most frames change none of these.
func refresh() -> void:
	var key := [Time.get_ticks_msec() / Dish.HAZE_REFRESH_MSEC, dish.sources.size(), dish.edit_count, dish.radius, dish.pixel(), dish.selected.bup, dish._layers_hidden.size()]
	if key != _draw_key:
		_draw_key = key
		dish.queue_redraw()


## The picture holds room for the bups there are (with some to spare, never past the limit), not for the
## most there could be: a buffer for 100,000 bups is rewritten every frame, which costs when only a few live.
func fit_render_capacity(needed: int) -> void:
	if dish.runs_on_gpu():
		return  # (on the GPU path the picture is made once at the GPU's capacity: see draw_bups_gpu)
	var multimesh := bups_mesh.multimesh
	var wanted := mini(dish.bup_limit, maxi(Dish.RENDER_MIN_CAPACITY, nearest_po2(needed + needed / 2)))
	if needed > multimesh.instance_count or wanted * 4 <= multimesh.instance_count or multimesh.instance_count > dish.bup_limit:
		multimesh.instance_count = wanted
		stale = true  # (a resized multimesh starts empty)


## Fits the bups' picture to the bups there are and to the dish's size (once the dish has built its children).
func sync_render_capacity() -> void:
	if bups_mesh == null:
		return
	var multimesh := bups_mesh.multimesh
	fit_render_capacity(dish.sim.bup_count())
	# The bounds the renderer culls by: the whole dish. Left to itself it works the bounds out from
	# the instances once, so a buffer written every frame can leave them stale, and the bups are
	# culled whenever the view no longer matches that first guess.
	multimesh.custom_aabb = AABB(Vector3(-dish.radius, -dish.radius, -1.0), Vector3(2.0 * dish.radius, 2.0 * dish.radius, 2.0))


## Once a frame (Dish._process): the husks' picture, and the bups' picture of the dish in the main view, from the native simulation
## or the GPU.
func process() -> void:
	refresh_husks()
	if bups_mesh != null and dish.runs_on_gpu():
		for id in [dish.selected.bup, dish.hovered.bup]:  # (the bups the overlay shows: their records come back every frame)
			if id >= 0:
				dish.gpu_world.track(id)
		draw_bups_gpu()
		overlay.queue_redraw()
	elif bups_mesh != null:
		if dish.picture_scale <= 0.0:  # (a dish out of the main view is drawn only for the strip's small picture, which asks for it: `prepare_picture`)
			build_cpu_picture(dish.pixel())
		overlay.queue_redraw()


## Makes the bups' picture for the strip's small one of this dish, `scale` pixels to the µm, just before the strip has it drawn (the GPU's dishes are drawn every frame).
func prepare_picture(scale: float) -> void:
	if bups_mesh != null and not dish.runs_on_gpu():
		build_cpu_picture(1.0 / scale)


## Rebuilds the bups' picture from the native simulation, `pixel_um` µm to a pixel.
func build_cpu_picture(pixel_um: float) -> void:
	var sim := dish.sim
	fit_render_capacity(sim.bup_count())
	var multimesh := bups_mesh.multimesh
	# The picture is rebuilt only when what it shows may have changed: time has passed, or the bups, the zoom or
	# the pixel size have. (While paused nothing has, however many bups there are.)
	var stamp := [dish.time, sim.bup_count(), pixel_um]
	var changed: bool = stamp != render_stamp
	if stale or changed or trails_may_show:
		render_stamp = stamp
		stale = false
		trails_may_show = changed  # (a picture made as time moved may carry trails; the next one, when nothing has moved since, clears them: so a paused dish shows none)
		multimesh.visible_instance_count = mini(sim.bup_count(), multimesh.instance_count)
		multimesh.buffer = sim.render_buffer(pixel_um, multimesh.instance_count)


## Draws the bups from the GPU this frame (gpu/gpu_draw.gd): the MultiMesh is allocated at the GPU's capacity (not by
## fit_render_capacity; again only when the capacity changes), its visible_instance_count is the slots the bups need, and
## gpu_world.draw_bups(its RD buffer, those slots, pixel()) records the render kernel when the picture must change (the same rule as
## `build_cpu_picture`: time moved, the zoom or the slots changed, the GPU's state was loaded, or trails may show).
func draw_bups_gpu() -> void:
	var world := dish.gpu_world
	if not world.can_draw():
		return  # (only the main device can write the picture's buffer: a world on a local device, as tools make, is not drawn)
	var multimesh := bups_mesh.multimesh
	if multimesh.instance_count != world.draw_capacity():
		multimesh.instance_count = world.draw_capacity()  # (a new RD buffer, all zero: the render kernel is set up again for it)
		stale = true
	# The slots drawn: room for the bups there are, as on the CPU path (from the last count read back, which lags a few frames, or the
	# count loaded while none has come back), not for all the GPU holds: every slot drawn costs, an empty one too (about 2 ms a frame
	# for a million on an M1 Pro). The render kernel writes the slots past the live count as nothing; those past `slots` are not drawn.
	var known := dish.population()
	if known <= 0:
		known = world.draw_count()
	var slots := mini(world.draw_capacity(), maxi(Dish.RENDER_MIN_CAPACITY, nearest_po2(known + known / 2)))
	if multimesh.visible_instance_count != slots:
		multimesh.visible_instance_count = slots
	var target := RenderingServer.multimesh_get_buffer_rd_rid(multimesh.get_rid())
	# Never multimesh.buffer or the per-instance setters here: a CPU copy of the instances would be uploaded over the GPU's.
	var stamp := [dish.time, dish.pixel(), target, slots, world.draw_generation()]  # (a load of the GPU's state is a new picture too)
	var changed: bool = stamp != render_stamp
	if stale or changed or trails_may_show:
		render_stamp = stamp
		stale = false
		trails_may_show = changed  # (as on the CPU: a picture made as time moved may carry trails, the next still one clears them)
		world.draw_bups(target, slots, dish.pixel())


## Builds the husks' picture again when time has moved, the husks are different or the zoom has changed (and not oftener than HUSK_REFRESH_MSEC while only time moves).
func refresh_husks() -> void:
	var shown := dish.layer_shown(Dish.Layer.HUSKS)
	husks_mesh.visible = shown
	if not shown:
		_husk_stamp = []  # (built afresh when it is shown again)
		return
	var count := dish.sim.husk_count()
	var size: float = snappedf(dish.husk_draw_size(), 0.001)
	var stamp := [dish.time, count, size, dish.radius]
	if stamp == _husk_stamp:
		return
	var now := Time.get_ticks_msec()
	var changed_hard: bool = _husk_stamp.is_empty() or _husk_stamp[2] != size or _husk_stamp[3] != dish.radius or (count == 0) != (_husk_stamp[1] == 0)
	if not changed_hard and now - _husk_built_msec < Dish.HUSK_REFRESH_MSEC:
		return
	_husk_stamp = stamp
	_husk_built_msec = now
	var husks := husks_mesh.multimesh
	var capacity := maxi(Dish.HUSK_MIN_CAPACITY, nearest_po2(count))
	if husks.instance_count != capacity:
		husks.instance_count = capacity
	husks.custom_aabb = AABB(Vector3(-dish.radius, -dish.radius, -1.0), Vector3(2.0 * dish.radius, 2.0 * dish.radius, 2.0))  # (the whole dish, as the renderer culls by it: made again when a resize changes the radius)
	husks.visible_instance_count = count
	if count > 0:
		husks.buffer = dish.sim.husk_buffer(size, capacity)


## The dish, drawn on its own canvas (Dish._draw): under the bups, which are a child node drawn on top of this; the rings and the
## lightning flash are on top of them (`draw_overlay`).
func draw() -> void:
	# Dish: dark agar, green-tinted glass rim.
	dish.draw_colored_polygon(disc_outline(dish.radius), Color(0.03, 0.06, 0.04))  # (not draw_circle: it draws a big disc with few sides, and the flats show when the dish is bigger than the window)
	dish.draw_arc(Vector2.ZERO, dish.radius, 0.0, TAU, 96, Color(0.45, 0.8, 0.6, 0.6), 3.0)
	dish.draw_arc(Vector2.ZERO, dish.radius + 6.0, 0.0, TAU, 96, Color(0.45, 0.8, 0.6, 0.2), 2.0)

	if dish.layer_shown(Dish.Layer.MEDIUM):
		_draw_medium()
	if dish.layer_shown(Dish.Layer.STEERING):
		_draw_steering()
	if dish.layer_shown(Dish.Layer.SOURCES):
		for source in dish.sources:
			_draw_source(source)
	if dish.layer_shown(Dish.Layer.PLANKTON):
		_draw_all_plankton()


## A solid glowing dot with no outline, so it can't be mistaken for a selection ring.
func _draw_source(source: NutrientSource) -> void:
	var p := source.pos - dish.global_position
	var r := dish.source_draw_radius()
	dish.draw_circle(p, r * 2.0, Color(0.95, 0.8, 0.35, 0.18))
	dish.draw_circle(p, r, Color(1.0, 0.85, 0.4, 1.0))
	dish.draw_circle(p, r * 0.45, Color(1.0, 0.97, 0.8, 1.0))


## The plankton: outlines when they are big enough to see, and only those on screen; otherwise dots, all in a single draw.
func _draw_all_plankton() -> void:
	if dish.plankton.is_empty():
		return
	var r := dish.plankton_draw_radius()
	if r < Dish.PLANKTON_DETAIL_PIXELS * dish.pixel():
		_draw_plankton_pictures(r)
		return
	var seen := (dish.get_global_transform_with_canvas().affine_inverse() * dish.get_viewport_rect()).grow(r)
	for cell in dish.plankton:
		if seen.has_point(cell.pos):
			_draw_plankton(cell)


## Every plankton at once, each a turned copy of one picture, through a multimesh. Where they are is rebuilt when they
## or their size on screen change, and not more than a few times a second.
func _draw_plankton_pictures(r: float) -> void:
	if _plankton_picture == null:
		_plankton_picture = _make_plankton_picture()
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * 2.0 * Dish.PLANKTON_PICTURE_REACH
		_plankton_mesh = MultiMesh.new()
		_plankton_mesh.transform_format = MultiMesh.TRANSFORM_2D
		_plankton_mesh.mesh = quad
	var plankton := dish.plankton
	var now := Time.get_ticks_msec()
	var key := [plankton.size(), dish.edit_count, snappedf(r, 0.001)]
	if key != _plankton_key and now - _plankton_built >= Dish.PLANKTON_PICTURE_REFRESH_MSEC:
		_plankton_key = key
		_plankton_built = now
		var buffer := PackedFloat32Array()  # (a 2D transform is 8 floats: x.x, y.x, 0, origin.x, x.y, y.y, 0, origin.y)
		buffer.resize(8 * plankton.size())
		var k := 0
		for cell in plankton:
			var turn := Vector2.from_angle(cell.shape) * r
			buffer[k] = turn.x
			buffer[k + 1] = -turn.y
			buffer[k + 3] = cell.pos.x
			buffer[k + 4] = turn.y
			buffer[k + 5] = turn.x
			buffer[k + 7] = cell.pos.y
			k += 8
		_plankton_mesh.instance_count = plankton.size()
		_plankton_mesh.buffer = buffer
	elif key != _plankton_key:
		dish.queue_redraw()  # (too soon to rebuild: look again next frame, so a paused dish does not keep a stale picture)
	if _plankton_mesh.instance_count > 0:
		dish.draw_multimesh(_plankton_mesh, _plankton_picture)


## One plankton as a small picture: the same faint fill, outline and spot as the outlines drawn when they are big, for a
## radius of 1 at the middle.
static func _make_plankton_picture() -> ImageTexture:
	var size := Dish.PLANKTON_PICTURE_SIZE
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var per_unit := size / 2.0 / Dish.PLANKTON_PICTURE_REACH  # pixels to a plankton radius
	var fill := Color(0.5, 0.9, 0.45, 0.1)
	var line := Color(0.55, 0.95, 0.5, 0.9)
	var spot := Color(0.55, 0.95, 0.5, 0.6)
	var line_half := 1.6 / per_unit * 2.0  # (a line a good few texels wide, so it still shows when the picture is shrunk to a few pixels)
	for y in size:
		for x in size:
			var d := Vector2((x + 0.5) / per_unit - Dish.PLANKTON_PICTURE_REACH, (y + 0.5) / per_unit - Dish.PLANKTON_PICTURE_REACH)
			var a := d.angle()
			var edge := 1.0 + 0.16 * sin(2.0 * a) + 0.1 * sin(3.0 * a)
			var colour := Color(0, 0, 0, 0)
			if d.length() < edge:
				colour = fill
			var on_line := 1.0 - smoothstep(0.5 * line_half, line_half, absf(d.length() - edge))
			colour = _over(Color(line.r, line.g, line.b, line.a * on_line), colour)
			var in_spot := 1.0 - smoothstep(0.15, 0.2, d.distance_to(Vector2(0.25, 0.0)))
			colour = _over(Color(spot.r, spot.g, spot.b, spot.a * in_spot), colour)
			image.set_pixel(x, y, colour)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## `top` laid over `below`, in straight (not premultiplied) colour.
static func _over(top: Color, below: Color) -> Color:
	var alpha := top.a + below.a * (1.0 - top.a)
	if alpha <= 0.0:
		return Color(0, 0, 0, 0)
	return Color((top.r * top.a + below.r * below.a * (1.0 - top.a)) / alpha, (top.g * top.a + below.g * below.a * (1.0 - top.a)) / alpha, (top.b * top.a + below.b * below.a * (1.0 - top.a)) / alpha, alpha)


## An amorphous green outline: no two are quite alike, and it is faint inside, so the nutrient haze shows through.
func _draw_plankton(cell: Plankton) -> void:
	var r := dish.plankton_draw_radius()
	dish.draw_set_transform(cell.pos, 0.0, Vector2(r, r))  # (the outline is kept for a radius of 1)
	dish.draw_colored_polygon(cell.outline.slice(0, 16), Color(0.5, 0.9, 0.45, 0.1))  # (the last point repeats the first)
	dish.draw_polyline(cell.outline, Color(0.55, 0.95, 0.5, 0.85), 1.5 * dish.pixel() / r)
	dish.draw_circle(Vector2.from_angle(cell.shape) * 0.25, 0.18, Color(0.55, 0.95, 0.5, 0.55))
	dish.draw_set_transform(Vector2.ZERO)


## The dissolved nutrient as a faint amber haze, so gradients (and the depleted zones around a
## growing colony) can be seen. The grid is drawn as one smoothed texture, so a big dish costs one
## draw, not thousands; the texture is rebuilt a few times a second, not every frame.
func _draw_medium() -> void:
	var field := dish.field
	var now := Time.get_ticks_msec()
	if _haze == null or _haze.get_width() != field.size or now - _haze_built > Dish.HAZE_REFRESH_MSEC:
		_haze_built = now
		var n := field.size
		var pixels := field.haze_bytes(Cell.DETECTION_FLOOR, 0.5 * 255.0 / sqrt(10.0 * Cell.HALF_SATURATION), 0.45 * 255.0)
		var image := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, pixels)
		if _haze == null or _haze.get_width() != n:
			_haze = ImageTexture.create_from_image(image)
		else:
			_haze.update(image)
	dish.draw_texture_rect(_haze, Rect2(-dish.radius, -dish.radius, 2.0 * dish.radius, 2.0 * dish.radius), false)


## While a bup is selected, a cool tint over the places where it could steer: where the slope stands out from the
## noise in its own estimate of it (a keener or faster bup lights more of the dish; in a dilute medium nothing lights).
## Rebuilt a few times a second, like the haze it is drawn over.
func _draw_steering() -> void:
	var selected := dish.selected.bup
	if selected < 0 or not dish._bup_shown(selected):
		return
	var key := [selected, dish.field.size, Time.get_ticks_msec() / Dish.HAZE_REFRESH_MSEC]
	if key != _steer_key:
		_steer_key = key
		var n := dish.field.size
		var pixels: PackedByteArray = dish._bups().bup_steer_bytes(selected, Dish.STEER_ALPHA)
		var image := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, pixels)
		if _steer == null or _steer.get_width() != n:
			_steer = ImageTexture.create_from_image(image)
		else:
			_steer.update(image)
	dish.draw_texture_rect(_steer, Rect2(-dish.radius, -dish.radius, 2.0 * dish.radius, 2.0 * dish.radius), false)


## The rings on a selected and a hovered source or plankton (`offset` takes a thing's `pos` to the dish's own coordinates).
func _draw_pick_rings(canvas: CanvasItem, selected: Variant, hovered: Variant, offset: Vector2, radius: float) -> void:
	if selected != null:
		draw_ring(canvas, selected.pos - offset, radius, Color(1, 0.75, 0.3, 0.95))
	if hovered != null and hovered != selected:
		draw_ring(canvas, hovered.pos - offset, radius, Color(1, 1, 1, 0.9))


## A thin ring marking a bup or source: GUI, so the same size and line at every zoom (see
## Dish.ring_radius_pixels for the one case where it grows).
func draw_ring(canvas: CanvasItem, center: Vector2, object_radius: float, color: Color) -> void:
	var px := dish.pixel()
	canvas.draw_arc(center, Dish.ring_radius_pixels(object_radius / px) * px, 0.0, TAU, 64, color, px, true)


## A circle as a polygon with enough sides that its flats are under a pixel at the biggest the dish is drawn.
static func disc_outline(disc_radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	points.resize(Dish.DISC_SIDES)
	for i in Dish.DISC_SIDES:
		points[i] = Vector2.from_angle(TAU * i / Dish.DISC_SIDES) * disc_radius
	return points


## A brighter stretch of the selection ring, centred on the way the bup's drift tends (up the slope), and shorter the
## more reliably it does: it narrows from the whole ring as the bup goes from guessing to certain.
func _draw_steering_arc(canvas: CanvasItem, id: int) -> void:
	var steering := dish.bup_steering(id)
	if steering.z < Dish.ARC_SHOWN_ABOVE:
		return
	var px := dish.pixel()
	var span := maxf(2.0 * (1.0 - steering.z) * TAU, Dish.MIN_STEER_ARC)
	var heading := Vector2(steering.x, steering.y).angle()
	canvas.draw_arc(dish._bup_pos(id), Dish.ring_radius_pixels(dish._bup_radius(id, px) / px) * px, heading - span / 2.0, heading + span / 2.0, 24, Color(1, 0.95, 0.7, 1.0), 3.0 * px, true)


## What goes above the bups (on the overlay child's canvas): the selection and hover rings, the
## placement preview, the flash. Rings are GUI, not part of the dish: the same size and a thin
## line at any zoom.
func draw_overlay(canvas: CanvasItem) -> void:
	var px := dish.pixel()
	var selected_id := dish.selected.bup
	var hovered_id := dish.hovered.bup
	if selected_id >= 0 and dish._bup_shown(selected_id):
		draw_ring(canvas, dish._bup_pos(selected_id), dish._bup_radius(selected_id, px), Color(1, 0.75, 0.3, 0.95))
		if dish.layer_shown(Dish.Layer.STEERING):
			_draw_steering_arc(canvas, selected_id)
	if hovered_id >= 0 and hovered_id != selected_id and dish._bup_shown(hovered_id):
		draw_ring(canvas, dish._bup_pos(hovered_id), dish._bup_radius(hovered_id, px), Color(1, 1, 1, 0.9))
	_draw_pick_rings(canvas, dish.selected.source, dish.hovered.source, dish.global_position, dish.source_draw_radius())
	_draw_pick_rings(canvas, dish.selected.plankton, dish.hovered.plankton, Vector2.ZERO, dish.plankton_draw_radius())
	if dish.selected.husk != Dish.NO_HUSK:
		draw_ring(canvas, dish.selected.husk, dish.husk_draw_size(), Color(1, 0.75, 0.3, 0.95))
	if dish.hovered.husk != Dish.NO_HUSK and dish.hovered.husk != dish.selected.husk:
		draw_ring(canvas, dish.hovered.husk, dish.husk_draw_size(), Color(1, 1, 1, 0.9))
	if dish.place_preview_radius >= 0.0:
		var brush := Color(1, 0.3, 0.25, 0.9) if dish.place_preview_kind == Dish.Preview.ERASE else Color(1, 0.9, 0.5, 0.8)
		var at := dish.place_preview_pos - dish.global_position
		if dish.place_preview_kind == Dish.Preview.MARKER:
			draw_ring(canvas, at, dish.place_preview_radius, brush)
		else:
			canvas.draw_arc(at, maxf(dish.place_preview_radius, 3.0 * px), 0.0, TAU, 32, brush, px)
	if dish.flash > 0.0:
		canvas.draw_colored_polygon(disc_outline(dish.radius), Color(0.85, 0.95, 1.0, dish.flash))
