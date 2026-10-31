class_name ThumbAtlas
extends RefCounted
## The main side of the thumbnails' atlas: once a second the simulation writes every running dish's tile into a shared
## texture (Snapshot.thumbs); this imports it (a ViewRenderer of its own, so it does not depend on which dish is in the main view), gives
## the canvas a texture that always shows the newest atlas, says where a dish's tile lies in it, and tells the world, every frame, which
## atlas it used (WorldClient.texture_bound), so the simulation writes over a texture only once a newer one is in use. Nothing is imported
## where there is no main device (a headless run) or the backend shares no textures: the dishes are then drawn without their bups.

var _view: ViewRenderer = null
var _tried := false
var _info: ThumbsInfo = null  ## the atlas offered last


## Once a frame: the newest atlas is offered, and the textures used are reported.
func tick(w: WorldClient) -> void:
	if w == null or not _ensure(w):
		return
	var info := w.latest().thumbs
	if info != null and info.texture_index >= 0 and (_info == null or info.seq != _info.seq):
		var handles: Dictionary = (w.backend.texture_handles() as Dictionary).get("thumbs", {})
		if not handles.is_empty():
			_view.offer("thumbs", info.texture_index, int(handles["generation"]), PackedInt64Array(handles["handles"]), Vector2i(int(handles["width"]), int(handles["height"])), info.seq)
			_info = info
	_view.tick()
	for b: Array in _view.take_bound():
		w.texture_bound(b[0], b[1], b[2], b[3])


## The atlas as the canvas draws it (null before the first).
func texture() -> Texture2D:
	return _view.texture("thumbs") if _view != null and _info != null else null


## Counts the atlases taken: a change means the tiles may lie elsewhere.
func version() -> int:
	return _info.version if _info != null else 0


## Where dish `row`'s tile lies in the atlas shown (texels); an empty rect when the atlas has none for it.
func region(row: int) -> Rect2:
	if _info == null or not _info.tiles.has(row):
		return Rect2()
	return ViewRenderer.thumbnail_region(int(_info.tiles[row]))


## Dish `row`'s tile as an image (a copy of just that tile, read back once: a freeze keeps it), or null when there is none.
func picture(row: int) -> Image:
	var at := region(row)
	if at.size == Vector2.ZERO or _view == null:
		return null
	var source := _view.imported_texture("thumbs", _info.texture_index)
	var rd := _view.rd
	if not source.is_valid() or rd == null:
		return null
	var fmt := RDTextureFormat.new()
	fmt.width = int(at.size.x)
	fmt.height = int(at.size.y)
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var got := [PackedByteArray()]
	RenderingServer.call_on_render_thread(func() -> void:  # (the main device's calls go through the render thread, which is the main thread here: it runs at once)
		var tile := rd.texture_create(fmt, RDTextureView.new())
		if not tile.is_valid():
			return
		rd.texture_copy(source, tile, Vector3(at.position.x, at.position.y, 0.0), Vector3.ZERO, Vector3(at.size.x, at.size.y, 1.0), 0, 0, 0, 0)
		got[0] = rd.texture_get_data(tile, 0)
		rd.free_rid(tile))
	var bytes: PackedByteArray = got[0]
	if bytes.size() != fmt.width * fmt.height * 4:
		return null
	return Image.create_from_data(fmt.width, fmt.height, false, Image.FORMAT_RGBA8, bytes)


## Gives back the imports (the strip is leaving the screen).
func release() -> void:
	if _view != null:
		_view.release()
		_view = null
	_info = null
	_tried = false


func _ensure(w: WorldClient) -> bool:
	if _view != null:
		return true
	if _tried:
		return false
	_tried = true
	if not w.backend.has_method("texture_handles") or RenderingServer.get_rendering_device() == null:
		return false
	_view = ViewRenderer.new(PoolLimits.from_settings().frame_queue_size)
	if _view.rd == null:
		_view = null
		return false
	return true
