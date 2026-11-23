class_name DishDrawing
extends RefCounted
## How a dish is drawn: the bups (one multimesh whose buffer the main view's ViewRenderer writes from the picture the simulation publishes,
## never through `multimesh.buffer`, for the bups at or over their least footprint on screen; the smaller ones, a zoomed-out crowd, are the
## view's density picture, the colour of one covering bup a pixel, which `density_sprite` shows under the capsules), the husks (a multimesh of their own, under the bups, every live husk one instance, from the list the
## simulation reads for the main view: SimCore.run's husk_list), the dish itself with the nutrient haze, the steering map, the sources and the
## plankton (`draw`, for Dish._draw), and the rings, the placement preview and the flash above the bups (`draw_overlay`, for the dish's
## DishOverlay). Nothing here changes the simulation. It is a part of its Dish and holds the nodes it draws with.
##
## The dish in the main view (the one shown: the others are parked, Dish.park) tells the world what it shows (WorldClient.set_view: its camera, the scale, whether the
## haze and the steering map are wanted, the selected bup's speed and sense range for the map, whether its husks are), offers the view each
## publish the world's playout shows (WorldClient.shown_payload) and the newest haze and steering map, with the shared textures' handles,
## and tells the world every texture the view used this frame and the publish it held (WorldClient.texture_bound), so the simulation never
## writes over one still in use. Between pictures every bup is drawn part of the way from its place in the picture before to its place in
## the one shown (`share`: WorldClient.shown_share), and the rings, the camera's follow and the picks take it where it is drawn.

const AGAR := Color(0.03, 0.06, 0.04)  ## the dish's dark agar
const RIM := Color(0.45, 0.8, 0.6, 0.6)  ## its green-tinted glass rim
const RIM_OUTER := Color(0.45, 0.8, 0.6, 0.2)  ## and the rim's faint outer line
const THUMB_RIM_SIDES := 48  ## sides of a thumbnail's rim
const UNKNOWN := -2  ## `pick`: the view has not yet answered a question asked there
const ID_ASKS_OUT := 3  ## the questions about picked bups' ids `pick` keeps out to the simulation at once, of each kind (`_with_id`)
const ASKED_KEPT := 16  ## the questions `pick` remembers of each kind, to know what an answer answers (an answer comes a few frames late)
const MIN_INSTANCES := 1024  ## the fewest instances the bups' multimesh is made with

var dish: Dish
var view: ViewRenderer = null  ## the main view's picture of this dish (made when the dish is first in the main view and the world publishes)
var bups_mesh: MultiMeshInstance2D = null  ## the bups at or over their least footprint, drawn in one go
var density_sprite: Sprite2D = null  ## the bups under it, as the view's density picture (one texel a screen pixel), under the capsules
var husks_mesh: MultiMeshInstance2D = null  ## every live husk, as one instance each
var overlay: Node2D = null  ## the selection and hover rings, drawn above the bups
var share_override := -1.0  ## checks only: at 0 to 1, the share of the way between pictures every frame draws at (`share`), in place of the playout's
var _no_view := false  ## a view was tried and cannot draw here (no main device, or its kernels did not build)
var _view_sent: Array = []  ## what the world was last told of the view
var _view_forgotten := false  ## the view let go of its pictures since the world was last told of it (`ViewRequest.fresh`)
var _id_asked := {true: [], false: []}  ## hover -> the questions to the simulation for a picked bup's id that are out, oldest first: {reply, answer} each
var _id_asked_seq := {true: -1, false: -1}  ## hover -> the number of the newest answer whose bup's id was asked for
var _id_known := {true: {}, false: {}}  ## hover -> the newest answer whose bup's id the simulation has given
var _offered_payload := -1  ## the publish last given to the view
var _asked := {true: [], false: []}  ## hover -> the questions `pick` asked lately, oldest first: [number, local, slack, pixel] each
var _offered_field := -1
var _offered_steer := -1
var _husk_version := -1  ## the husk list last put into the husks' multimesh (Snapshot.husk_view's version)
var _draw_key := []  ## what the dish was last drawn from (see `refresh`)
var _plankton_picture: ImageTexture = null  ## what a small plankton is drawn from (made when first needed)
var _plankton_mesh: MultiMesh = null  ## where each small plankton is, for drawing them all at once
var _plankton_key: Array = []  ## what `_plankton_mesh` was last built for: the dish's edit count and the radius drawn
var _plankton_built := 0  ## when it was (msec)


func _init(for_dish: Dish) -> void:
	dish = for_dish


## A layer was shown or hidden: the bups' and the husks' pictures follow it, and the rings and the dish are drawn again.
func layer_changed(layer: Dish.Layer, shown: bool) -> void:
	if bups_mesh == null:
		return  # (not drawn yet: its children are made, as the layers say, when it is first shown)
	match layer:
		Dish.Layer.BUPS:
			bups_mesh.visible = shown
			density_sprite.visible = shown and density_sprite.texture != null
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
	husks_mesh = MultiMeshInstance2D.new()  # (under the bups: one instance for every husk there is, drawn by the graphics card, so there is no limit on how many are shown)
	husks_mesh.multimesh = husks
	husks_mesh.self_modulate = Dish.HUSK_COLOR
	husks_mesh.visible = dish.layer_shown(Dish.Layer.HUSKS) and dish.has_husks()
	dish.add_child(husks_mesh)
	density_sprite = Sprite2D.new()  # (under the capsules; its place and size follow the camera each frame, `draw_bups_view`)
	density_sprite.centered = false
	density_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	density_sprite.visible = false
	dish.add_child(density_sprite)
	bups_mesh = MultiMeshInstance2D.new()
	bups_mesh.multimesh = multimesh
	bups_mesh.material = material
	bups_mesh.visible = dish.layer_shown(Dish.Layer.BUPS)
	dish.add_child(bups_mesh)
	overlay = DishOverlay.new()
	overlay.dish = dish
	dish.add_child(overlay)


## Gives back the view's buffers and imported textures (the dish is leaving the screen).
func release() -> void:
	if density_sprite != null:
		density_sprite.texture = null  # (the picture's texture is freed with the view)
		density_sprite.visible = false
	if view != null:
		view.release()
		view = null
	_id_asked = {true: [], false: []}
	_id_asked_seq = {true: -1, false: -1}
	_id_known = {true: {}, false: {}}


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
	if bups_mesh == null or dish.row < 0 or dish.world == null:
		return
	var w := dish.world
	_send_view(w)
	refresh_husks(w.latest().husk_view)
	if not _ensure_view(w):
		return
	var handles: Dictionary = w.backend.texture_handles()
	_take(w, handles)
	var field := w.latest().field_view
	var haze: Dictionary = handles.get("haze", {})
	var offered_before := [_offered_field, _offered_steer]
	if field != null and field.texture_index >= 0 and field.seq != _offered_field and not field.haze_bytes.is_empty():
		view.hand_over_picture("haze", field.haze_bytes, Vector2i(field.n, field.n), field.seq)
		_offered_field = field.seq
	elif field != null and field.texture_index >= 0 and field.seq != _offered_field and not haze.is_empty():
		view.offer("haze", field.texture_index, int(haze["generation"]), PackedInt64Array(haze["handles"]), Vector2i(int(haze["width"]), int(haze["height"])), field.seq)
		_offered_field = field.seq
	var steer: Dictionary = handles.get("steer", {})
	if field != null and field.steer_index >= 0 and field.steer_seq != _offered_steer and not field.steer_bytes.is_empty():
		view.hand_over_picture("steer", field.steer_bytes, Vector2i(field.n, field.n), field.steer_seq)
		_offered_steer = field.steer_seq
	elif field != null and field.steer_index >= 0 and field.steer_seq != _offered_steer and not steer.is_empty():
		view.offer("steer", field.steer_index, int(steer["generation"]), PackedInt64Array(steer["handles"]), Vector2i(int(steer["width"]), int(steer["height"])), field.steer_seq)
		_offered_steer = field.steer_seq
	if offered_before != [_offered_field, _offered_steer]:
		dish.queue_redraw()  # (a new picture of the medium is drawn now, so its use is told and the set it replaced can go: a paused world publishes no more)
	draw_bups_view()
	for b: Array in view.take_bound():
		w.texture_bound(b[0], b[1], b[2], b[3])
	overlay.queue_redraw()


## The publish the world's playout shows this frame (WorldClient.shown_payload) is given to the view, which draws it; `process` does it if
## the screen did not first (Main takes it before it moves the camera, so a followed bup's place is the one the frame draws).
func take_payload() -> void:
	if view != null and dish.row >= 0 and dish.world != null:
		_take(dish.world, dish.world.backend.texture_handles())


func _take(w: WorldClient, handles: Dictionary) -> void:
	var shown := w.shown_payload()
	if shown != null and shown.row == dish.row and shown.epoch == w.epoch_of(dish.row) and shown.seq != _offered_payload:
		var p := _with_handles(shown, handles)
		if p != null:
			view.set_payload(p)
			_offered_payload = shown.seq


## The world is told what the main view shows when that changes: the dish's row, the camera (dish-local), the scale, whether the haze and
## the steering map are wanted (the haze's layer, or the map's with a bup selected: hiding the medium to see the map is the point of it)
## and whether the husks are, the selected bup's speed and sense range (for the map) and the haze's and the map's look.
func _send_view(w: WorldClient) -> void:
	var camera := dish.get_global_transform_with_canvas().affine_inverse() * dish.get_viewport_rect()
	var steer := Vector2(20.0, 50.0)
	var chosen := dish.bup_info(dish.selected.bup) if dish.selected.bup >= 0 else {}
	if not chosen.is_empty():
		steer = Vector2(chosen["speed"], chosen["sense_range"])
	var field := dish.layer_shown(Dish.Layer.MEDIUM) or (dish.layer_shown(Dish.Layer.STEERING) and dish.selected.bup >= 0)
	var husks := dish.layer_shown(Dish.Layer.HUSKS) and dish.has_husks()
	var key := [dish.row, camera, dish.pixel(), field, husks, steer, dish.want_thumbnails]
	if key == _view_sent:
		return
	_view_sent = key
	var v := ViewRequest.new()
	v.camera = camera
	v.pixel_um = dish.pixel()
	v.fresh = _view_forgotten
	_view_forgotten = false
	v.want_field_view = field
	v.want_husks = husks
	v.want_thumbnails = dish.want_thumbnails
	v.steer = steer
	v.haze = Vector3(Cell.DETECTION_FLOOR, 0.5 * 255.0 / sqrt(10.0 * Cell.HALF_SATURATION), 0.45 * 255.0)
	v.steer_alpha = Dish.STEER_ALPHA
	w.set_view(dish.row, v)


## The dish left the main view: what the world was told of the view is forgotten, so it is told again next time, and the view lets go of
## the pictures it holds (ViewRenderer.let_go: the textures it drew from will hold the other dishes' pictures), its last uses told first.
func forget_view() -> void:
	_view_sent = []
	_view_forgotten = true
	if density_sprite != null:
		density_sprite.visible = false  # (shown again by the first build, the picture holding another dish's bups until then)
	if view != null:
		if dish.world != null:
			for b: Array in view.take_bound():
				dish.world.texture_bound(b[0], b[1], b[2], b[3])
		view.let_go()
	_offered_payload = -1
	_offered_field = -1
	_offered_steer = -1
	_asked = {true: [], false: []}


## Makes the view once the world publishes (its backend hands out the shared textures' handles) and the main device can draw; false
## while there is none.
func _ensure_view(w: WorldClient) -> bool:
	if view != null:
		return true
	if _no_view or not w.backend.has_method("texture_handles"):
		return false
	view = ViewRenderer.new(PoolLimits.from_settings().frame_queue_size)
	_asked = {true: [], false: []}  # (a new view numbers its questions afresh)
	view.set_density(true)  # (if its kernels do not build, `density_ready` stays false and every bup is a capsule)
	if not view.can_draw():
		view.release()
		view = null
		_no_view = true
		return false
	return true


## The publish `p` with the payload's and the ids' native handles and size (the backend's `texture_handles`); null when the textures were
## made again since it was published.
static func _with_handles(p: PayloadInfo, handles: Dictionary) -> PayloadInfo:
	if not p.bytes.is_empty() or ViewRenderer.cpu_handover():
		return p  # (handed over as bytes: nothing to import)
	var pay: Dictionary = handles.get("payload", {})
	var ids: Dictionary = handles.get("ids", {})
	if pay.is_empty() or ids.is_empty() or int(pay["generation"]) != p.generation:
		return null
	var out := PayloadInfo.new()
	out.texture_index = p.texture_index
	out.count = p.count
	out.sim_time = p.sim_time
	out.row = p.row
	out.epoch = p.epoch
	out.generation = p.generation
	out.seq = p.seq
	out.places = p.places
	out.places_before = p.places_before
	out.handles = PackedInt64Array(pay["handles"])
	out.id_handles = PackedInt64Array(ids["handles"])
	out.size = Vector2i(int(pay["width"]), int(pay["height"]))
	return out


## Puts the newest list of the dish's husks (Snapshot.husk_view) into the husks' multimesh: its room grows by doubling (at least
## Dish.HUSK_MIN_CAPACITY) and only the husks in the list are drawn; each is a quad of the husk's drawn size (the list's transforms have a
## unit basis, so a change of zoom needs no new list). Hidden with its layer, or in a dish that cannot have husks.
func refresh_husks(husk_view: Dictionary) -> void:
	var shown := dish.layer_shown(Dish.Layer.HUSKS) and dish.has_husks()
	husks_mesh.visible = shown
	if not shown:
		return
	var husks := husks_mesh.multimesh
	var size := Vector2.ONE * dish.husk_draw_size()
	if (husks.mesh as QuadMesh).size != size:
		(husks.mesh as QuadMesh).size = size
	if husk_view.is_empty() or int(husk_view["row"]) != dish.row or int(husk_view["version"]) == _husk_version:
		return
	_husk_version = int(husk_view["version"])
	var transforms: PackedFloat32Array = husk_view["transforms"]
	var count := transforms.size() / 8
	var capacity := maxi(Dish.HUSK_MIN_CAPACITY, nearest_po2(count))
	if husks.instance_count != capacity:
		husks.instance_count = capacity
	husks.custom_aabb = AABB(Vector3(-dish.radius, -dish.radius, -1.0), Vector3(2.0 * dish.radius, 2.0 * dish.radius, 2.0))  # (the whole dish, as the renderer culls by it)
	husks.visible_instance_count = count
	if count > 0:
		var buffer := transforms
		buffer.resize(capacity * 8)  # (a buffer holds the whole room; what is past the count is not drawn)
		husks.buffer = buffer


## The husks drawn now (the newest list's).
func husks_drawn() -> int:
	return husks_mesh.multimesh.visible_instance_count if husks_mesh != null and husks_mesh.visible else 0


## Draws the bups from the view this frame: the view's kernels write the instances of the bups the camera sees into the MultiMesh's
## buffer. It holds the payload's bups: made for twice their count (at least MIN_INSTANCES, at most the dish's limit and a twentieth
## more, never fewer than the payload has), it grows the same way when they outgrow it, and never shrinks.
func draw_bups_view() -> void:
	view.tick()
	var multimesh := bups_mesh.multimesh
	var count := view.payload().count
	if multimesh.instance_count < count or multimesh.instance_count == 0:
		multimesh.instance_count = maxi(count, mini(maxi(MIN_INSTANCES, nearest_po2(2 * count)), ceili(dish.bup_limit * 1.05)))  # (a new RD buffer: the view binds it afresh)
	multimesh.custom_aabb = AABB(Vector3(-dish.radius, -dish.radius, -1.0), Vector3(2.0 * dish.radius, 2.0 * dish.radius, 2.0))  # (the renderer culls by these bounds: the whole dish)
	view.follow([dish.selected.bup, dish.hovered.bup].filter(func(id: int) -> bool: return id >= 0))
	if not bups_mesh.visible:
		density_sprite.visible = false
		return
	var camera := dish.get_global_transform_with_canvas().affine_inverse() * dish.get_viewport_rect()
	view.draw_frame(camera, dish.pixel(), multimesh.get_rid(), share())
	var picture := view.density_texture() if view.density_ready() else null
	density_sprite.visible = picture != null
	if picture != null:
		if density_sprite.texture != picture:
			density_sprite.texture = picture
		density_sprite.position = camera.position
		density_sprite.scale = Vector2.ONE * dish.pixel()


## Asks which bup is at `local` (dish-local µm) within `slack`, and how many lie within Dish.SOURCE_NEARBY of it (ViewRenderer.pick).
## Returns the newest answer of the same kind (`hover` or a click's) when it answers a question asked here: its question (found by its
## number among the last ASKED_KEPT asked) was at the same slack and scale and at most Dish.HOVER_CLICK_PIXELS away. Its id, -1 for none,
## or UNKNOWN when no answer to such a question has come yet (an answer comes a few frames after its question).
func pick(local: Vector2, slack: float, hover: bool) -> int:
	if view == null:
		return -1
	var pixel := dish.pixel()
	var asked: Array = _asked[hover]
	asked.append([view.pick(local, slack, pixel, hover, Dish.SOURCE_NEARBY), local, slack, pixel])
	if asked.size() > ASKED_KEPT:
		asked.pop_front()
	var a: Dictionary = view.answer(hover)
	if not a.is_empty() and int(a["id"]) == ViewRenderer.UNRESOLVED:
		a = _with_id(a, hover)  # (the payload came with no ids: the simulation gives the picked bup's)
	if a.is_empty():
		return UNKNOWN
	for q: Array in asked:
		if q[0] == int(a["seq"]):
			var here: bool = is_equal_approx(q[2], slack) and is_equal_approx(q[3], pixel) and (q[1] as Vector2).distance_to(local) <= Dish.HOVER_CLICK_PIXELS * pixel
			return int(a["id"]) if here else UNKNOWN
	return UNKNOWN


## The newest answer of this kind whose bup's id is known, for a payload with no ids (the answer `a` carries the picked texel and the
## publish, `ViewRenderer.answer`): asks the simulation for the bup of each new answer (at most ID_ASKS_OUT questions out of each kind) and
## keeps the newest answer it has resolved. Empty until one is.
func _with_id(a: Dictionary, hover: bool) -> Dictionary:
	var out: Array = _id_asked[hover]
	var waiting: Array = []
	for w: Dictionary in out:
		var reply := w["reply"] as SimReply
		if not reply.is_done():
			waiting.append(w)
			continue
		var ids: Variant = reply.value()
		var answered := w["answer"] as Dictionary
		if ids is PackedInt64Array and (ids as PackedInt64Array).size() == 1 and ids[0] >= 0 and int(answered["seq"]) > int((_id_known[hover] as Dictionary).get("seq", -1)):
			var known := answered.duplicate()
			known["id"] = ids[0]
			_id_known[hover] = known
	if dish.world != null and waiting.size() < ID_ASKS_OUT and int(a["seq"]) > int(_id_asked_seq[hover]):
		_id_asked_seq[hover] = int(a["seq"])
		waiting.append({"reply": dish.world.ids_at(int(a["pub"]), PackedInt32Array([int(a["index"])])), "answer": a})
	_id_asked[hover] = waiting
	return _id_known[hover]


## The nearest bup's distance from the last hover pick's point and how many lie within Dish.SOURCE_NEARBY of it ((-1, 0): none known).
func near_count() -> Vector2:
	return view.near_count() if view != null else Vector2(-1.0, 0.0)


## Where a bup is drawn round: Vector3(x, y, half its drawn length), or null when the picture does not show it.
func ring_of(id: int) -> Variant:
	return view_ring(id) if view != null and id >= 0 else null


## How far this frame draws the bups from their places in the picture before (0) to their places in the payload the view holds (1): the
## world's playout share while the view holds the publish the playout shows, else 1 (`share_override` in its place when set).
func share() -> float:
	if share_override >= 0.0:
		return share_override
	var w := dish.world
	if view == null or w == null:
		return 1.0
	var shown := w.shown_payload()
	return w.shown_share() if shown != null and shown.seq == view.payload().seq else 1.0


## Where a bup is drawn round (its place and half its drawn length) on the view's picture: from the payload the view draws, which carries
## the places of the bups the dish asks after and where they were in the picture before (PayloadInfo.places, places_before: the place
## drawn is `share` of the way between, as the view's kernels draw it); else from the last place the view looked up, or, until that comes,
## from the pick that found it (so the hover ring shows as soon as the pick is answered); null when the view does not know it.
func view_ring(id: int) -> Variant:
	var p := view.payload()
	var at: Variant = p.places.get(id) if p != null else null
	if at != null and p.places_before.has(id):
		var t := share()
		if t < 1.0:
			var was: Vector2 = p.places_before[id]
			at = Vector3(was.x * (1.0 - t) + at.x * t, was.y * (1.0 - t) + at.y * t, at.z)
	if at == null:
		at = view.place_of(id)
	if at == null:
		for hover in [true, false]:
			var a: Dictionary = view.answer(hover)
			if a.is_empty() or int(a["id"]) == ViewRenderer.UNRESOLVED:
				a = _id_known[hover]
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
	dish.draw_colored_polygon(disc_outline(dish.radius), AGAR)  # (not draw_circle: it draws a big disc with few sides, and the flats show when the dish is bigger than the window)
	# The rim follows the disc's own outline and is never thinner than a screen pixel: a thinner line shows only where it happens to
	# cross the pixels' centres, which on a wide dish is one upright stretch of it at the left and right edges.
	var px := dish.pixel()
	dish.draw_arc(Vector2.ZERO, dish.radius, 0.0, TAU, Dish.DISC_SIDES + 1, RIM, maxf(3.0, px))
	dish.draw_arc(Vector2.ZERO, dish.radius + maxf(6.0, 1.5 * px), 0.0, TAU, Dish.DISC_SIDES + 1, RIM_OUTER, maxf(2.0, px))

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
	var r := dish.plankton_draw_radius()
	if r < Dish.PLANKTON_DETAIL_PIXELS * dish.pixel():
		_draw_plankton_pictures(r)
		return
	if dish.plankton.is_empty():
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
	var now := Time.get_ticks_msec()
	var key := [dish.edit_count, snappedf(r, 0.001)]
	if key != _plankton_key and now - _plankton_built >= Dish.PLANKTON_PICTURE_REFRESH_MSEC:
		var plankton := dish.plankton  # (the dish unpacks its newest copy of the plankton here, at most once for every rebuild)
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


## A dish's small picture in `rect` of the canvas item `ci`: the agar and the rim, and over them its tile of the thumbnails' atlas (where the
## bups are, white, the denser the brighter: SimCore's thumbnails), when there is one (`atlas` null: the dish alone).
static func draw_thumbnail(ci: RID, rect: Rect2, atlas: Texture2D, region: Rect2, modulate: Color) -> void:
	var centre := rect.get_center()
	var r := 0.5 * minf(rect.size.x, rect.size.y)
	RenderingServer.canvas_item_add_circle(ci, centre, r, AGAR * modulate)
	if atlas != null:
		RenderingServer.canvas_item_add_texture_rect_region(ci, rect, atlas.get_rid(), region, modulate)
	var rim := PackedVector2Array()
	for i in THUMB_RIM_SIDES + 1:
		rim.append(centre + Vector2.from_angle(TAU * i / THUMB_RIM_SIDES) * (r - 0.5))
	RenderingServer.canvas_item_add_polyline(ci, rim, PackedColorArray([RIM * modulate]), 1.0, true)


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

