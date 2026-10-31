extends SceneTree
## The top bar always holds every control: the layer toggles sit in its row when they fit and in a second row when they do not, the dish tabs shrink to their
## arrows before anything is hidden, and the bar never needs more than the window has, at any interface size and with any number of dishes.


func _initialize() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	TestUtil.use_fake_world(self)
	for scale in [1.0, 1.2, 2.0, 2.5]:
		for dishes in [1, 2, 8]:
			UserSettings.native_override = 0.7407  # (a wide display at twice the system scale)
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
				if m.dish_strip.visible:
					TestUtil.check(m.speed_readout.get_global_rect().end.x <= m.dish_strip.get_global_rect().position.x and m.dish_strip.get_global_rect().end.x <= m.views.get_global_rect().position.x, "%s the tabs sit between the speed and the toggles" % what)
				else:
					TestUtil.check(m.speed_readout.get_global_rect().end.x <= m.views.get_global_rect().position.x, "%s the speed sits left of the toggles" % what)
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
	for i in 5:
		await process_frame
	await _speed_sweep()
	TestUtil.finish(self, "TOP BAR TESTS OK", "TOP BAR TESTS FAILED:")


## The top bar's rows do not change as the playback changes: in the 1280 x 720 window, three dishes of the default 100,000 limit in free mode, the speed
## goes x1, x100, x1,000, x10,000, x10,000 running x8,499, the same paused, waiting for the pipette, and back to x1, and the bar keeps one row or two
## throughout, with every readout as wide as its longest possible text and showing all of what it has.
## Expected [derived from the widths measured on this build (printed as "TOP BAR figures"): the longest readout with the speed 719 / 944 / 1,305 px at
## 100 / 150 / 250%, without it 380 / 502 / 692, the speed alone 315 / 410 / 568; a row's room 1,680 / 1,451 / 1,206 at a display scale of 0.7407 (the
## wide display at twice the system scale) and 1,232 / 1,063 at 1.0; playback and menu 239 / 270, toggles 204 / 234 and about 40 kept for the
## husks' button, two tabs with arrows and count 302 to 383, six gaps of 12]:
##  - 0.7407 at 100%: 1,680 - 719 - 239 - 244 - 72 = 406 >= 302 for the tabs: one row.
##  - 0.7407 at 150%: 1,451 - 944 - 270 - 234 - 72 < 0: two rows (the readout 502 of 1,133).
##  - 0.7407 at 250%: two rows (the readout 692 of 888; the second row 1,206 - 568 - 274 - 48 leaves about 300 for the tabs, past their narrowest).
##  - 1.0 at 100%: 1,232 - 719 - 239 - 244 - 72 < 0: two rows (the readout 380 of 945).
##  - 1.0 at 150%: two rows (the readout 502 of 745).
##  (1.0 at 250% is not in the list: 881 of room holds neither the readout's 692 beside the playback (563 left) nor the second row's 568 + 274 + the
##  tabs' narrowest.)
func _speed_sweep() -> void:
	for setting: Array in [[0.7407, 1.0, false], [0.7407, 1.5, true], [0.7407, 2.5, true], [1.0, 1.0, true], [1.0, 1.5, true]]:
		UserSettings.native_override = setting[0]
		UserSettings.ui_scale = setting[1]
		UserSettings._applied = false
		UserSettings.apply()
		var chosen := TestUtil.small_start()
		chosen.bup_limit = StartConditions.DEFAULT_BUP_LIMIT
		var m: Node = TestUtil.game_screen(self, chosen)
		for i in 6:
			await process_frame
		for i in 2:
			m.add_dish(chosen)
		for i in 20:
			await process_frame
		var what := "display scale %.4f at %d%%" % [setting[0], int(setting[1] * 100.0)]
		var two_rows: bool = m.top_bar_more_row.visible
		print("TOP BAR figures %s: room %.0f, readout %.0f / %.0f without the speed, speed %.0f, playback and menu %.0f, toggles %.0f (husks %s), tabs least %.0f, gap %.0f" % [what, m._bar_room(), m._vitals_full_width, m._vitals_short_width, m._speed_width, m.playback_panel.get_combined_minimum_size().x + m.menu_button.get_combined_minimum_size().x, m.views.get_combined_minimum_size().x, m.layers_panel.husks_button.visible, m.dish_strip.shortest_width(), m._bar_gap()])
		TestUtil.check(two_rows == setting[2], "%s the bar has %s, as derived" % [what, "two rows" if two_rows else "one row"])
		var changed := 0
		var cut := []
		for step: Array in [[1.0, 1.0, false, false], [100.0, 100.0, false, false], [1000.0, 1000.0, false, false], [10000.0, 10000.0, false, false],
				[10000.0, 8499.0, false, false], [10000.0, 8499.0, true, false], [10000.0, 8499.0, true, true], [1.0, 1.0, false, false]]:
			m.sim_speed = step[0]
			m.achieved_speed = step[1]
			m.paused = step[2]
			if step[3]:
				m.holds.hold(&"pipette")
			elif m.holds.has(&"pipette"):
				m.holds.release(&"pipette", PlayHolds.Then.STAY)
			m.readout.forget(m.vitals)
			m.readout.forget(m.speed_readout)
			for i in 4:
				await process_frame
			if m.top_bar_more_row.visible != two_rows:
				changed += 1
			var shown: Array = [[m.vitals, m._vitals_short_width if two_rows else m._vitals_full_width]]
			if two_rows:
				shown.append([m.speed_readout, m._speed_width])
			for pair: Array in shown:
				var label: RichTextLabel = pair[0]
				if label.get_content_width() > label.size.x + 1.0 or float(pair[1]) > label.size.x + 1.0:
					cut.append("%s at %s: content %.0f, longest %.0f, room %.0f" % [label.name, m._playback_text(), label.get_content_width(), pair[1], label.size.x])
			var width: float = m.get_viewport_rect().size.x
			if m.top_bar_row.get_combined_minimum_size().x > width or m.top_bar_more_row.get_combined_minimum_size().x > width:
				cut.append("a row is wider than the window at %s" % m._playback_text())
		TestUtil.check(changed == 0, "%s the rows never change as the speed changes (%d changes)" % [what, changed])
		TestUtil.check(cut.is_empty(), "%s no readout is cut and both rows fit the window %s" % [what, cut])
		m.queue_free()
		for i in 5:
			await process_frame
