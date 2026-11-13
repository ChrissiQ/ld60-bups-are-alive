extends SceneTree
## The windowed part of the info panel's follow (it keeps the selected bup in the middle of the stage), on the real pool at x10,000:
## the game screen itself (Main, free mode, on SimService's world), a bup selected and followed, and each frame the bup's place in the
## picture drawn that frame (the payload the dish's view drew, read back from its shared texture) against the stage's middle, in screen
## pixels. Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/parity_follow_test.gd
##
## Expected values, written before the first run [derived unless marked]:
## F  The bound: over 100 frames at x10,000, zoomed in to 2 px a µm, the followed bup is drawn within 2 px of the stage's middle
##    in every frame. StageInput.follow_selected puts the camera on Dish.bup_world_pos, which is the bup's place in the payload the frame
##    draws (PayloadInfo.places: the sim thread looks up the bups the dish asks after as it publishes, and Main gives the view the frame's
##    payload before it moves the camera), so the two differ by float rounding only: well under 0.01 px [derived]. A frame drawn from a
##    payload published before the dish asked after the bup has no place for it; the 60 frames before the window leave none of those.

var g: ParityGame
var main: Node


func _initialize() -> void:
	g = ParityGame.start(self, "parity_follow_test")
	if g == null:
		return
	var start := StartConditions.new()
	start.dish_radius = 3000.0
	start.bups = 200
	start.bup_limit = 2000
	start.nutrient_density = 32.0
	main = TestUtil.game_screen(self, start)
	_run()


func _run() -> void:
	if not await g.world_ready(false):
		TestUtil.show(false, "the world's device was made")
		TestUtil.finish(self, "OK parity_follow_test")
		return
	await g.wait_until(func() -> bool: return main.dish != null)
	var dish: Dish = main.dish
	await g.wait_shown(dish)
	await g.wait_picture(dish)
	await g.settle()
	var ids := dish.bup_ids()
	var id: int = ids[ids.size() / 2] if not ids.is_empty() else -1
	if id < 0:
		TestUtil.show(false, "F a bup to follow (the dish has none in the family tree)")
		TestUtil.finish(self, "OK parity_follow_test")
		return
	dish.selected.bup = id
	main.camera.zoom = Vector2.ONE * 2.0
	main.stage_input.toggle_follow()
	main.toolbar.set_paused(false)  # (presses the last play speed's button, x1: the speed is set after it)
	main._set_paused(false)
	main.sim_speed = 10000.0
	for f in 60:
		await process_frame
	var errors: Array = []
	var missing := 0
	for f in 100:
		await process_frame
		var at: Variant = _drawn_at(dish, id)
		if at == null:
			missing += 1
			continue
		var zoom: float = main.camera.zoom.x
		var shift: Vector2 = main.stage_input._centre_shift(main.stage.get_global_rect(), main.get_viewport_rect().size)
		var centre: Vector2 = main.camera.position + shift / zoom
		errors.append(((dish.global_position + (at as Vector2)) - centre).length() * zoom)
	errors.sort()
	var worst: float = errors[-1] if not errors.is_empty() else INF
	print("     x10,000 (achieved x%.0f): following %d, the drawn bup off the stage's middle by median %.1f px, p95 %.1f px, worst %.1f px; %d frames it was not in the picture" % [g.world.latest().achieved_speed, id, errors[errors.size() / 2] if not errors.is_empty() else -1.0, errors[int(errors.size() * 0.95)] if not errors.is_empty() else -1.0, worst, missing])
	TestUtil.show(g.world.latest().achieved_speed >= 5000.0, "the game runs at x10,000 (achieved x%.0f)" % g.world.latest().achieved_speed)
	TestUtil.show(id >= 0 and main.stage_input.following_id == id and errors.size() >= 95 and worst <= 2.0, "F the followed bup stays within 2 px of the stage's middle over 100 frames at x10,000 (worst %.1f px)" % worst)
	TestUtil.finish(self, "OK parity_follow_test")


## Where bup `id` is in the payload the dish's view drew this frame (dish-local), read from the shared textures; null when it is not there.
func _drawn_at(dish: Dish, id: int) -> Variant:
	var view := dish.drawing.view
	if view == null:
		return null
	var p := view.payload()
	var imports: Dictionary = view._imports
	if p == null or p.texture_index < 0 or not imports.has("payload") or not imports.has("ids"):
		return null
	var pay: RID = imports["payload"]["rids"][p.texture_index]
	var idt: RID = imports["ids"]["rids"][p.texture_index]
	var got := [PackedByteArray(), PackedByteArray()]
	RenderingServer.call_on_render_thread(func() -> void:
		var rd := RenderingServer.get_rendering_device()
		got[0] = rd.texture_get_data(pay, 0)
		got[1] = rd.texture_get_data(idt, 0))
	var lo := id & 0xFFFFFFFF
	var hi := (id >> 32) & 0xFFFFFFFF
	for k in mini(p.count, (got[1] as PackedByteArray).size() / GpuLayout.IDT_BYTES):
		if got[1].decode_u32(k * GpuLayout.IDT_BYTES) == lo and got[1].decode_u32(k * GpuLayout.IDT_BYTES + 4) == hi:
			return Vector2(got[0].decode_float(k * GpuLayout.PAYLOAD_BYTES), got[0].decode_float(k * GpuLayout.PAYLOAD_BYTES + 4))
	return null
