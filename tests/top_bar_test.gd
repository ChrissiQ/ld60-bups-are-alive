extends SceneTree
## The top bar always holds every control: the layer toggles sit in its row when they fit and in a second row when they do not, the dish tabs shrink to their
## arrows before anything is hidden, and the bar never needs more than the window has, at any interface size and with any number of dishes.


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	for scale in [1.0, 1.2, 2.0, 2.5]:
		for dishes in [1, 2, 8]:
			UserSettings.native_override = 0.7407  # (a 3456-wide screen at twice the system scale)
			UserSettings.ui_scale = scale
			UserSettings._applied = false
			UserSettings.apply()
			var chosen := TestUtil.small_start()
			var m: Node = TestUtil.game_screen(self, chosen)
			for i in 6:
				await process_frame
			for i in dishes - 1:
				m.add_dish(chosen)
			for i in 20:
				await process_frame
			var what := "at %d%% with %d dishes" % [int(scale * 100.0), dishes]
			var width: float = m.get_viewport_rect().size.x
			TestUtil.check(m.views.visible, "%s the layer toggles are shown" % what)
			TestUtil.check(m.top_bar_row.get_combined_minimum_size().x <= width, "%s the top bar's row fits the window (%.0f of %.0f)" % [what, m.top_bar_row.get_combined_minimum_size().x, width])
			TestUtil.check(m.views.get_global_rect().end.x <= width and m.menu_button.get_global_rect().end.x <= width, "%s the toggles and the menu are inside the window" % what)
			var wrapped: bool = m.views.get_parent() == m.top_bar_more_row
			TestUtil.check(wrapped == (m.dish_strip.get_parent() == m.top_bar_more_row), "%s the tabs and the toggles share a row" % what)
			TestUtil.check(wrapped or m.top_bar_more_row.get_child_count() == 3, "%s the second row holds only the speed and its spacers unless the toggles are in it" % what)
			if wrapped:
				TestUtil.check(m.top_bar_more_row.get_child(0) == m.speed_readout and m.top_bar_more_row.get_child(m.top_bar_more_row.get_child_count() - 1) == m.views, "%s the speed is at the second row's left and the toggles at its right" % what)
				TestUtil.check(m.speed_readout.get_global_rect().end.x <= m.dish_strip.get_global_rect().position.x and m.dish_strip.get_global_rect().end.x <= m.views.get_global_rect().position.x, "%s the tabs sit between the speed and the toggles" % what)
				TestUtil.check(m.speed_readout.size.x >= m.speed_readout.get_content_width() - 1.0 and m.speed_readout.get_content_width() > 0.0, "%s the speed shows all its text (%.0f of %.0f)" % [what, m.speed_readout.size.x, m.speed_readout.get_content_width()])
			TestUtil.check(m.vitals.size.y >= m.vitals.get_content_height(), "%s the readout is as tall as its text" % what)
			TestUtil.check(m.vitals.size.x >= minf(m.vitals.get_content_width(), m._vitals_room()) - 1.0, "%s the readout shows all its text (%.0f of %.0f)" % [what, m.vitals.size.x, m.vitals.get_content_width()])
			m.queue_free()
			for i in 5:
				await process_frame
	# Going from a big interface size to 100% in a game lets go of the room the big text needed: four dishes sit in the first row at 100%.
	var chosen := TestUtil.small_start()
	UserSettings.ui_scale = 2.5
	UserSettings._applied = false
	UserSettings.apply()
	var m: Node = TestUtil.game_screen(self, chosen)
	for i in 6:
		await process_frame
	for i in 3:
		m.add_dish(chosen)
	for i in 20:
		await process_frame
	UserSettings.ui_scale = 1.0
	UserSettings._applied = false
	UserSettings.apply()
	for i in 30:
		await process_frame
	TestUtil.check(not m.top_bar_more_row.visible, "after going from 250% to 100% the top bar is one row again")
	UserSettings.ui_scale = 2.5
	UserSettings._applied = false
	UserSettings.apply()
	m.sim_speed = 10000.0
	m.achieved_speed = 1.0
	m.paused = true
	for i in 40:
		await process_frame
	TestUtil.check(m.top_bar_more_row.visible and m.speed_readout.size.x >= m.speed_readout.get_content_width() - 1.0, "after going from 100%% to 250%% the speed is shown whole (%.0f of %.0f)" % [m.speed_readout.size.x, m.speed_readout.get_content_width()])
	m.queue_free()
	TestUtil.finish(self, "TOP BAR TESTS OK", "TOP BAR TESTS FAILED:")
