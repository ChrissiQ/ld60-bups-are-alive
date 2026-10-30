extends SceneTree
## Run: godot --headless --path . -s tests/encyclopedia_test.gd
## The encyclopedia: every entry has a title and an article, every link in an article goes to an entry, every gene of the genome map has its entry, the search finds
## entries, the panel opens on an entry, and a tooltip is wrapped to a few short lines.


func _init() -> void:
	_run()


func _run() -> void:
	var ids := Encyclopedia.all_entries()
	var seen := {}
	var link_rx := RegEx.create_from_string("\\[url=([a-z_]+)\\]")
	var bad_links := []
	var empty := []
	for id in ids:
		seen[id] = true
		if Encyclopedia.title(id).strip_edges().is_empty() or (Encyclopedia.about(id) + Encyclopedia.game(id)).strip_edges().is_empty() or Encyclopedia.game(id).is_empty():
			empty.append(id)
	TestUtil.check(seen.size() == ids.size() and not ids.is_empty(), "no entry is listed twice (%d entries)" % ids.size())
	TestUtil.check(empty.is_empty(), "every entry has a title and says how it works in the game (%s)" % [empty])
	for id in ids:
		for m in link_rx.search_all(Encyclopedia.about(id) + Encyclopedia.game(id)):
			if not seen.has(m.get_string(1)):
				bad_links.append("%s -> %s" % [id, m.get_string(1)])
	TestUtil.check(bad_links.is_empty(), "every link in an article goes to an entry (%s)" % [bad_links])
	for locus: String in Genome.LOCI:
		TestUtil.check(seen.has(Encyclopedia.entry_for_locus(locus)), "the band of %s has an entry" % locus)
	for category: Array in Encyclopedia.CATEGORIES:
		TestUtil.check(not Encyclopedia.category_title(category[0]).is_empty(), "heading %s has a title" % category[0])
	TestUtil.check(Encyclopedia.search("").size() == Encyclopedia.listed_entries().size(), "an empty search finds every listed entry")
	TestUtil.check(Encyclopedia.search("MUTATOR").has("mutator") and Encyclopedia.search("fertility").has("donor"), "the search looks in titles and articles, in any case")
	TestUtil.check(Encyclopedia.search("zzzz-nothing").is_empty(), "a search with no match finds none")

	var panel: EncyclopediaPanel = load("res://ui/encyclopedia_panel.tscn").instantiate()
	root.add_child(panel)
	await process_frame
	TestUtil.check(panel.current == ids[0] and panel.title_label.text == Encyclopedia.title(ids[0]), "the panel opens on the first entry")
	panel.show_entry("donor")
	TestUtil.check(panel.current == "donor" and panel.game_body.text != "" and panel.about_body.text != "" and panel.title_label.text == Encyclopedia.title("donor"), "it opens on a given entry")
	panel.search_field.text = "plankton"
	panel._filter("plankton")
	TestUtil.check(panel._buttons["plankton"].visible and not panel._buttons["speed"].visible, "a search hides the entries that do not match")
	panel.show_entry("speed")
	TestUtil.check(panel.search_field.text == "" and panel._buttons["speed"].visible, "opening an entry the search hides clears the search")
	panel.show_entry("steering")
	TestUtil.check(not panel.about_body.visible and panel.game_body.visible and not panel.game_heading.visible, "an entry that is only in the game shows just that part, unlabelled")
	var how_to := RegEx.create_from_string("(?i)\\b(click|press|drag|scroll|hover|point at)\\b")
	var mixed := []
	for id in ids:
		if how_to.search(Encyclopedia.about(id) + " " + Encyclopedia.game(id)) != null:
			mixed.append(id)
	TestUtil.check(mixed.is_empty(), "no entry tells the player what to click: that is the tutorial's (%s)" % [mixed])
	TestUtil.check(not Encyclopedia.is_listed("husks") and not Encyclopedia.search("").has("husks") and not panel._buttons["husks"].visible, "the Husks entry is unlisted while the game has no husk option")
	panel.show_entry("husks")
	TestUtil.check(panel.current == "husks" and panel.game_body.text == Encyclopedia.game("husks"), "...and still opens, as a link or a click on the genome map would")
	Encyclopedia.set_fact("husks", true)
	panel.visible = false
	panel.visible = true
	TestUtil.check(Encyclopedia.is_listed("husks") and panel._buttons["husks"].visible and Encyclopedia.search("husk").has("husks"), "it is listed once the game has one")
	Encyclopedia.set_fact("husks", false)
	panel.queue_free()

	var tip := "A very long tooltip that would run across the whole window if it were left on one line, which is what the engine does"
	var wrapped := UiText.tooltip_lines(tip)
	var longest := 0
	for line in wrapped.split("\n"):
		longest = maxi(longest, line.length())
	TestUtil.check(longest <= UiText.TOOLTIP_WIDTH and wrapped.replace("\n", " ") == tip, "a long tooltip is broken into lines of at most %d characters, nothing lost (%d)" % [UiText.TOOLTIP_WIDTH, longest])
	TestUtil.check(UiText.tooltip_lines("Pause") == "Pause" and UiText.tooltip_lines("") == "", "a short tooltip is left alone")
	TestUtil.finish(self, "ENCYCLOPEDIA TESTS OK", "ENCYCLOPEDIA TESTS FAILED:")
