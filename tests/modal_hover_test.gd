extends SceneTree
## Run: godot --headless --path . -s tests/modal_hover_test.gd
## While a modal is up (a dialog, the pause menu, a hold that stills the world) nothing under it is hovered: the pointer over the dish clears
## the hover and the hover card, and the dish asks nothing about what is under the pointer. With the modal gone the same pointer hovers again.
## Over FakeWorld, with a bup at the middle of the dish and the pointer on it.


## Whether the dish holds a hover: something under the pointer, or the question of what is there still open.
func _looking(d: Dish) -> bool:
	return not d.hovered.is_empty() or d._hover_waiting or d._hover_known


func _frames() -> void:
	for i in 3:
		await process_frame


func _initialize() -> void:
	var fake := TestUtil.use_fake_world(self)
	var start := StartConditions.new()
	start.dish_radius = 300.0
	start.nutrient_density = 0
	start.feed_density = 0.0
	var m: Node = TestUtil.game_screen(self, start)
	await _frames()
	var at: Vector2 = m.dish.global_position
	var id: int = fake.add_bups(m.dish.row, [Vector2.ZERO], -1)[0]
	await _frames()
	# (A headless window has its pointer at the corner: the camera is put so that the corner is the middle of the dish.)
	m.camera.position = at + m.get_viewport_rect().size * 0.5 / m.camera.zoom.x
	await _frames()
	TestUtil.check(m.dish.contains(m.get_global_mouse_position()), "the pointer is over the dish")
	var input: StageInput = m.stage_input
	input.update_pointer()
	TestUtil.check(_looking(m.dish), "with no modal the pointer on the dish hovers it")

	# A dialog.
	m.old_dish_dialog.popup_centered()
	await _frames()
	TestUtil.check(root.get_node("DialogStyle").is_open(), "the open dialog is known to DialogStyle")
	input.update_pointer()
	TestUtil.check(not _looking(m.dish), "an open dialog clears the hover")
	var sent: int = fake.calls.size()
	for i in 3:
		input.update_pointer()
		await process_frame
	var asked := false
	for c in fake.calls.slice(sent):
		if c["kind"] == SimCommand.KIND_ASK and not c["args"].get("questions", {}).get("tracked", []).is_empty():
			asked = true
	TestUtil.check(not asked and not _looking(m.dish), "...and the dish asks about nothing under it")
	m.old_dish_dialog.hide()
	await _frames()
	TestUtil.check(not root.get_node("DialogStyle").is_open(), "a closed dialog is not open")
	input.update_pointer()
	TestUtil.check(_looking(m.dish), "...and the pointer hovers again once it is closed")

	# The pause menu.
	m.pause_menu.visible = true
	input.update_pointer()
	TestUtil.check(not _looking(m.dish), "the pause menu clears the hover")
	m.pause_menu.visible = false
	input.update_pointer()
	TestUtil.check(_looking(m.dish), "...and the pointer hovers again once it is closed")
	TestUtil.check(id >= 0, "(the bup exists)")
	m.queue_free()
	await process_frame
	TestUtil.finish(self, "MODAL HOVER TESTS OK")
