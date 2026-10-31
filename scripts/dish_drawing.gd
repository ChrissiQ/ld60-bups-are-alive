class_name DishDrawing
extends RefCounted
## How a dish is drawn: the bups (one multimesh whose buffer the main view's ViewRenderer writes from the picture the simulation publishes,
## never through `multimesh.buffer`), the dish itself with the nutrient haze, the steering map, the sources and the plankton (`draw`, for
## Dish._draw), and the rings, the placement preview and the flash above the bups (`draw_overlay`, for the dish's DishOverlay). Nothing here
## changes the simulation. It is a part of its Dish and holds the nodes it draws with.
##
## The dish in the main view (picture_scale 0) tells the world what it shows (WorldClient.set_view: its camera, the scale, whether the
## haze is wanted, the selected bup's speed and sense range for the steering map), offers the view each publish the world's playout shows
## (WorldClient.shown_payload) with the shared textures' handles, and tells the world every texture the view used this frame and the
## publish it held (WorldClient.texture_bound), so the simulation never writes over one still in use. The rings follow the bups' places in
## the picture. Husks are not drawn: the pooled world publishes no picture of them yet.

var dish: Dish
var view: ViewRenderer = null  ## the main view's picture of this dish (made when the dish is first in the main view and the world publishes)
var bups_mesh: MultiMeshInstance2D = null  ## all the bups, drawn in one go
var husks_mesh: MultiMeshInstance2D = null  ## the husks' layer (empty: see the header)
var overlay: Node2D = null  ## the selection and hover rings, drawn above the bups
var _no_view := false  ## a view was tried and cannot draw here (no main device, or its kernels did not build)
var _view_sent: Array = []  ## what the world was last told of the view
var _offered_payload := -1  ## the publish last given to the view
var _offered_field := -1
var _draw_key := []  ## what the dish was last drawn from (see `refresh`)
var _plankton_picture: ImageTexture = null  ## what a small plankton is drawn from (made when first needed)
var _plankton_mesh: MultiMesh = null  ## where each small plankton is, for drawing them all at once
var _plankton_key: Array = []  ## what `_plankton_mesh` was last built for: how many plankton, the edit count and the radius drawn
var _plankton_built := 0  ## when it was (msec)


func _init(for_dish: Dish) -> void:
	dish = for_dish


## A layer was shown or hidden: the bups' and the husks' pictures follow it, and the rings and the dish are drawn again.
func layer_changed(layer: Dish.Layer, shown: bool) -> void:
	match layer:
		Dish.Layer.BUPS:
			bups_mesh.visible = shown
			if view != null:
				view.forget_build()  # (what was not drawn while hidden is drawn afresh)
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
	husks_mesh = MultiMeshInstance2D.new()
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


## Gives back the view's buffers and imported textures (the dish is leaving the screen).
func release() -> void:
	if view != null:
		view.release()
		view = null


## Redraws the dish only when something it shows may have changed: the picture of the medium is published a few times a
## second, and the sources, the size and the zoom show at once. Most frames change none of these.
func refresh() -> void:
	var key := [Time.get_ticks_msec() / Dish.HAZE_REFRESH_MSEC, dish.sources.size(), dish.edit_count, dish.radius, dish.pixel(), dish.selected.bup, dish._layers_hidden.size()]
	if key != _draw_key:
		_draw_key = key
		dish.queue_redraw()


## Once a frame (Dish._process): the dish in the main view tells the world what it shows, takes the publish to show, draws its bups and
## tells the world which textures it used.
func process() -> void:
	if bups_mesh == null or dish.picture_scale > 0.0 or dish.row < 0 or dish.world == null:
		return
	var w := dish.world
	_send_view(w)
	if not _ensure_view(w):
		return
	var handles: Dictionary = w.backend.texture_handles()
	var shown := w.shown_payload()
	if shown != null and shown.row == dish.row and shown.seq != _offered_payload:
		var p := _with_handles(shown, handles)
		if p != null:
			view.set_payload(p)
			_offered_payload = shown.seq
	var field := w.latest().field_view
	var haze: Dictionary = handles.get("haze", {})
	if field != null and field.seq != _offered_field and not haze.is_empty():
		view.offer("haze", field.texture_index, int(haze["generation"]), PackedInt64Array(haze["handles"]), Vector2i(int(haze["width"]), int(haze["height"])), field.seq)
		_offered_field = field.seq
	draw_bups_view()
	for b: Array in view.take_bound():
		w.texture_bound(b[0], b[1], b[2], b[3])
	overlay.queue_redraw()


## The world is told what the main view shows when that changes: the dish's row, the camera (dish-local), the scale, whether the haze is
## wanted, the selected bup's speed and sense range (for the steering map) and the haze's and the map's look.
func _send_view(w: WorldClient) -> void:
	var camera := dish.get_global_transform_with_canvas().affine_inverse() * dish.get_viewport_rect()
	var steer := Vector2(20.0, 50.0)
	var chosen := dish.bup_info(dish.selected.bup) if dish.selected.bup >= 0 else {}
	if not chosen.is_empty():
		steer = Vector2(chosen["speed"], chosen["sense_range"])
	var key := [dish.row, camera, dish.pixel(), dish.layer_shown(Dish.Layer.MEDIUM), steer]
	if key == _view_sent:
		return
	_view_sent = key
	var v := ViewRequest.new()
	v.camera = camera
	v.pixel_um = dish.pixel()
	v.want_field_view = dish.layer_shown(Dish.Layer.MEDIUM)
	v.steer = steer
	v.haze = Vector3(Cell.DETECTION_FLOOR, 0.5 * 255.0 / sqrt(10.0 * Cell.HALF_SATURATION), 0.45 * 255.0)
	v.steer_alpha = Dish.STEER_ALPHA
	w.set_view(dish.row, v)


## Makes the view once the world publishes (its backend hands out the shared textures' handles) and the main device can draw; false
## while there is none.
func _ensure_view(w: WorldClient) -> bool:
	if view != null:
		return true
	if _no_view or not w.backend.has_method("texture_handles"):
		return false
	view = ViewRenderer.new(PoolLimits.from_settings().frame_queue_size)
	if not view.can_draw():
		view.release()
		view = null
		_no_view = true
		return false
	return true


## The publish `p` with the payload's and the ids' native handles and size (the backend's `texture_handles`); null when the textures were
## made again since it was published.
static func _with_handles(p: PayloadInfo, handles: Dictionary) -> PayloadInfo:
	var pay: Dictionary = handles.get("payload", {})
	var ids: Dictionary = handles.get("ids", {})
	if pay.is_empty() or ids.is_empty() or int(pay["generation"]) != p.generation:
		return null
	var out := PayloadInfo.new()
	out.texture_index = p.texture_index
	out.count = p.count
	out.sim_time = p.sim_time
	out.row = p.row
	out.generation = p.generation
	out.seq = p.seq
	out.handles = PackedInt64Array(pay["handles"])
	out.id_handles = PackedInt64Array(ids["handles"])
	out.size = Vector2i(int(pay["width"]), int(pay["height"]))
	return out


## A dish out of the main view is shown only in the strip, whose pictures are the world's thumbnails: nothing to make here.
func prepare_picture(_scale: float) -> void:
	pass


## Draws the bups from the view this frame: the MultiMesh holds the dish's limit and a twentieth more (more if the payload has more), and
## the view's kernels write the instances of the bups the camera sees into its buffer.
func draw_bups_view() -> void:
	view.tick()
	var multimesh := bups_mesh.multimesh
	var capacity := maxi(ceili(dish.bup_limit * 1.05), view.payload().count)
	if multimesh.instance_count < capacity:
		multimesh.instance_count = capacity  # (a new RD buffer: the view binds it afresh)
	multimesh.custom_aabb = AABB(Vector3(-dish.radius, -dish.radius, -1.0), Vector3(2.0 * dish.radius, 2.0 * dish.radius, 2.0))  # (the renderer culls by these bounds: the whole dish)
	view.follow([dish.selected.bup, dish.hovered.bup].filter(func(id: int) -> bool: return id >= 0))
	if not bups_mesh.visible:
		return
	var camera := dish.get_global_transform_with_canvas().affine_inverse() * dish.get_viewport_rect()
	view.draw_frame(camera, dish.pixel(), multimesh.get_rid())


## Asks which bup is at `local` (dish-local µm) within `slack`, and how many lie within Dish.SOURCE_NEARBY of it (ViewRenderer.pick);
## returns the id of the last answer to a question of the same kind (`hover` or a click's), -1 for none.
func pick(local: Vector2, slack: float, hover: bool) -> int:
	if view == null:
		return -1
	view.pick(local, slack, dish.pixel(), hover, Dish.SOURCE_NEARBY)
	var a: Dictionary = view.answer(hover)
	return int(a["id"]) if not a.is_empty() else -1


## The nearest bup's distance from the last hover pick's point and how many lie within Dish.SOURCE_NEARBY of it ((-1, 0): none known).
func near_count() -> Vector2:
	return view.near_count() if view != null else Vector2(-1.0, 0.0)


## Where a bup is drawn round: Vector3(x, y, half its drawn length), or null when the picture does not show it.
func ring_of(id: int) -> Variant:
	return view_ring(id) if view != null and id >= 0 else null


## Where a bup is drawn round (its place and half its drawn length) on the view's picture: from the last place looked up, or, until that
## comes, from the pick that found it (so the hover ring shows as soon as the pick is answered); null when the view does not know it.
func view_ring(id: int) -> Variant:
	var at: Variant = view.place_of(id)
	if at == null:
		for hover in [true, false]:
			var a: Dictionary = view.answer(hover)
			if not a.is_empty() and a["id"] == id:
				at = Vector3(a["pos"].x, a["pos"].y, a["length"])
				break
	if at == null:
		return null
	return Vector3(at.x, at.y, 0.5 * maxf(at.z, Cell.MIN_VISIBLE_LENGTH_PX * dish.pixel()))


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


## The dissolved nutrient as a faint amber haze, so gradients (and the depleted zones around a growing colony) can be seen: the picture
## the simulation publishes a few times a second, one texture over the whole dish.
func _draw_medium() -> void:
	var haze := view.texture("haze") if view != null else null
	if haze != null:
		dish.draw_texture_rect(haze, Rect2(-dish.radius, -dish.radius, 2.0 * dish.radius, 2.0 * dish.radius), false)


## While a bup is selected, a cool tint over the places where it could steer: where the slope stands out from the
## noise in its own estimate of it (a keener or faster bup lights more of the dish; in a dilute medium nothing lights).
func _draw_steering() -> void:
	var steer := view.texture("steer") if view != null else null
	if dish.selected.bup >= 0 and steer != null and ring_of(dish.selected.bup) != null:
		dish.draw_texture_rect(steer, Rect2(-dish.radius, -dish.radius, 2.0 * dish.radius, 2.0 * dish.radius), false)


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
func _draw_steering_arc(canvas: CanvasItem, id: int, at: Vector3) -> void:
	var steering := dish.bup_steering(id)
	if steering.z < Dish.ARC_SHOWN_ABOVE:
		return
	var px := dish.pixel()
	var span := maxf(2.0 * (1.0 - steering.z) * TAU, Dish.MIN_STEER_ARC)
	var heading := Vector2(steering.x, steering.y).angle()
	canvas.draw_arc(Vector2(at.x, at.y), Dish.ring_radius_pixels(at.z / px) * px, heading - span / 2.0, heading + span / 2.0, 24, Color(1, 0.95, 0.7, 1.0), 3.0 * px, true)


## What goes above the bups (on the overlay child's canvas): the selection and hover rings, the
## placement preview, the flash. Rings are GUI, not part of the dish: the same size and a thin
## line at any zoom.
func draw_overlay(canvas: CanvasItem) -> void:
	var px := dish.pixel()
	_draw_bup_rings(canvas, dish.selected.bup, dish.hovered.bup)
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


## The selection's ring (with its steering arc) and the hover's ring, where the picture has the bups.
func _draw_bup_rings(canvas: CanvasItem, selected_id: int, hovered_id: int) -> void:
	var at: Variant = ring_of(selected_id)
	if at != null:
		draw_ring(canvas, Vector2(at.x, at.y), at.z, Color(1, 0.75, 0.3, 0.95))
		if dish.layer_shown(Dish.Layer.STEERING):
			_draw_steering_arc(canvas, selected_id, at)
	at = ring_of(hovered_id) if hovered_id != selected_id else null
	if at != null:
		draw_ring(canvas, Vector2(at.x, at.y), at.z, Color(1, 1, 1, 0.9))

