extends SceneTree
## Run: godot --headless --path . -s tests/dish_answers_test.gd
## What a dish makes of the simulation's answers and what it asks: husks found, picked, shown and gone; the
## point readout's slope; a source's release so far; a dose's scatter; the husks' picture; the start of a game. Over a backend of this
## file's own that keeps what is sent and serves the snapshots the test writes (SimService.use_backend).
##
## Expected values, written before the first run [derived from the code's rules; the backend's clock is whatever the test says]:
##  - Husks (a dish with death husks, the snapshot counting 5): the select tool's hover at (100, 50) asks for the husks within half a
##    husk's drawn size (3 px at a scale of 1: 1.5 µm) of it, and finds none until answered; answered with a husk at (100.5, 50) holding
##    160 energy, 30 s old, 2 pieces let go, the hover finds it there; its details: age 30, left exp(-0.5) = 0.6065, units 160 x 0.6065 /
##    16 = 6.065; the panel says "leaked so far  39%" (1 - 0.6065). A hover at (200, 50) with the same answer finds none (it is 99.5 µm
##    off). A click where the hover rests picks it, and the next questions ask after (100.5, 50) within 0.01 µm. While that place has no
##    answer of its own the details stay what the hover's answer said; an answer there with none found makes them empty (it leaked away).
##    With the Husks layer hidden nothing is looked for.
##  - The husks' picture: a list of 3 transforms makes 3 instances drawn in a room of 1,024 (Dish.HUSK_MIN_CAPACITY) (the headless
##    renderer keeps no transforms, so where they are is the windowed check's); a list of 2,000 makes a room of 2,048; the quad is the husk's drawn size (3 µm); the layer hidden, none is drawn; a list for
##    another row is not taken.
##  - The probe: an answer of way (0.6, 0.8), chance 0.7, concentration 1e-3, gradient's size 1e-5 reads as (1e-3, 6e-6, 8e-6); the point's
##    text says it rises to the south-east (y down: 53 degrees rounds to the eighth "se") by 1.0 x 100 = 100% per 100 µm, not "flat"; a
##    size of 0 reads as flat.
##  - A source in a copy of the world made at 1,000 s with 100 units released at 6 a minute reads 100 + 6 / 60 x 120 = 112 when the
##    snapshot's clock is 1,120 s, and 100 at 1,000 s.
##  - A dose of 9 units is one DROP of 9 x 16 = 144 energy over a disc of 5 x sqrt(9) = 15 µm (scatter_radius, the preview's circle); one
##    unit's disc is 0.
##  - WorldClient.begin_game(123) sends one begin_game command with game_began 123.
##  - The game screen (over FakeWorld) sends begin_game, with its game_began, before its first add_dish. Starting again after the last dish
##    (dish 3) died out: a remove_dish of its row, then begin_game, then an add_dish of number 1; Main's next number is 2.


class Backend:
	extends SimBackend
	var sent: Array = []  ## [kind, args]
	var snap := Snapshot.new()

	func can_simulate() -> bool:
		return true

	func submit(cmd: SimCommand) -> void:
		sent.append([cmd.kind, cmd.args])

	func latest() -> Snapshot:
		return snap

	func last(kind: StringName) -> Dictionary:
		for i in range(sent.size() - 1, -1, -1):
			if sent[i][0] == kind:
				return sent[i][1]
		return {}


var _b := Backend.new()
var _seq := 0


func _initialize() -> void:
	_run()


func _serve(d: Dish, time: float, answers: Dictionary, worlds := {}, husk_view := {}) -> void:
	var s := Snapshot.new()
	_seq += 1
	s.seq = _seq
	s.sim_time = time
	var ds := DishState.new()
	ds.number = d.number
	ds.count = 10
	ds.husk_count = 5
	s.dishes[d.row] = ds
	s.answers[d.row] = answers
	s.worlds = worlds
	s.husk_view = husk_view
	_b.snap = s
	d.world.poll()


func _run() -> void:
	SimConstants.apply()
	root.get_node("SimService").use_backend(_b)
	var start := TestUtil.small_start()
	start.death_husks = true
	start.bups = 4
	var d := Dish.new()
	root.add_child(d)
	d.strike(start)
	await process_frame
	TestUtil.check(d.row == 0 and d.has_husks(), "the dish is in the world, with husks on")
	_serve(d, 1000.0, {})
	_husks(d)
	_picture(d)
	_probe(d)
	_sources(d)
	_drop(d)
	d.world.begin_game(123.0)
	var began := _b.last(SimThread.KIND_BEGIN_GAME)
	TestUtil.check(began.get("game_began") == 123.0, "begin_game tells the world when the game began (%s)" % [began])
	d.queue_free()
	await process_frame
	await _game_starts()
	TestUtil.finish(self, "DISH ANSWERS TEST OK")


## The game screen over FakeWorld (which keeps no numbering or clock of its own for a game: only the order of what Main sends is read).
func _game_starts() -> void:
	var fake := FakeWorld.new()
	root.get_node("SimService").use_backend(fake)
	var m: Node = TestUtil.game_screen(self, TestUtil.small_start())
	await process_frame
	await process_frame
	var kinds: Array = fake.calls.map(func(c: Dictionary) -> StringName: return c["kind"])
	var begin := kinds.find(SimThread.KIND_BEGIN_GAME)
	var first_add := kinds.find(SimCommand.KIND_ADD_DISH)
	var began: Dictionary = fake.calls[begin]["args"] if begin >= 0 else {}
	TestUtil.check(begin >= 0 and begin < first_add and is_equal_approx(float(began.get("game_began", -1.0)), m.game_began), "the game screen tells the world when the game began (%s) before it asks for its dish (begin %d, add %d)" % [began, begin, first_add])
	var old_row: int = m.dish.row
	m._dish_numbers[m.dish] = 3  # (as though dishes 2 and 3 had come and gone, and dish 3 was the last)
	m.dish.number = 3
	m._next_dish_number = 4
	m._labels_given = 3
	var mark := fake.calls.size()
	m._start_again()
	kinds = fake.calls.slice(mark).map(func(c: Dictionary) -> StringName: return c["kind"])
	var removed := kinds.find(SimCommand.KIND_REMOVE_DISH)
	begin = kinds.find(SimThread.KIND_BEGIN_GAME)
	var added := kinds.find(SimCommand.KIND_ADD_DISH)
	var spec: DishSpec = fake.calls[mark + added]["args"]["spec"] if added >= 0 else null
	TestUtil.check(removed >= 0 and int(fake.calls[mark + removed]["args"]["row"]) == old_row and removed < begin and begin < added, "starting again: the old dish leaves the world, then the game begins, then the new dish is asked for (%s)" % [kinds])
	TestUtil.check(spec != null and spec.number == 1 and m._dish_numbers[m.dish] == 1 and m._next_dish_number == 2 and m._labels_given == 1, "starting again numbers the dish 1 (in the world and on screen) and the next 2 (%s, %d)" % [spec.number if spec != null else -1, m._next_dish_number])
	m.queue_free()
	await process_frame


func _husks(d: Dish) -> void:
	var at := d.global_position + Vector2(100.0, 50.0)
	d.hover_at(at)
	TestUtil.check(d.hovered.husk == Dish.NO_HUSK, "no husk is found before an answer")
	d._process(0.0)
	var asked: Array = _b.last(SimCommand.KIND_ASK).get("questions", {}).get("husks", [])
	TestUtil.check(asked.size() == 1 and is_equal_approx(asked[0][0], 100.0) and is_equal_approx(asked[0][1], 50.0) and is_equal_approx(asked[0][2], 1.5), "the hover asks for the husks within half a husk's size of it (%s)" % [asked])
	var husk := PackedFloat32Array([100.5, 50.0, 160.0, 30.0, 2.0])
	_serve(d, 1000.0, {"husks": [{"at": Vector2(100.0, 50.0), "reach": 1.5, "found": husk}]})
	d.hover_at(at)
	TestUtil.check(d.hovered.husk == Vector2(100.5, 50.0), "the answer's husk is found under the pointer (%s)" % d.hovered.husk)
	var details := d.husk_details(d.hovered.husk)
	var left := exp(-0.5)
	TestUtil.check(not details.is_empty() and is_equal_approx(details["age"], 30.0) and is_equal_approx(details["left"], left) and absf(details["units"] - 160.0 * left / 16.0) < 1e-4, "its details: age, what is left, units (%s)" % [details])
	var text := PanelText.husk(details)
	TestUtil.check(text.contains("leaked so far  39%"), "the panel says how much has leaked, not what is left (%s)" % text.replace("\n", " | "))
	d.hover_at(d.global_position + Vector2(200.0, 50.0))
	TestUtil.check(d.hovered.husk == Dish.NO_HUSK, "a husk out of reach of the pointer is not found")
	d.hover_at(at)
	d.select_at(at)
	TestUtil.check(d.selected.husk == Vector2(100.5, 50.0), "a click where the hover rests picks the husk")
	d.clear_hover()
	d._process(0.0)
	asked = _b.last(SimCommand.KIND_ASK).get("questions", {}).get("husks", [])
	TestUtil.check(asked.has([100.5, 50.0, Dish.HUSK_HERE]), "the picked husk's place is asked after (%s)" % [asked])
	_serve(d, 1010.0, {"husks": []})
	TestUtil.check(not d.husk_details(d.selected.husk).is_empty(), "until its place is answered, the picked husk keeps the details it was found with")
	_serve(d, 1020.0, {"husks": [{"at": Vector2(100.5, 50.0), "reach": Dish.HUSK_HERE, "found": PackedFloat32Array([100.5, 50.0, 160.0, 45.0, 3.0])}]})
	TestUtil.check(is_equal_approx(d.husk_details(d.selected.husk).get("age", -1.0), 45.0), "an answer about its place brings its details up to date")
	_serve(d, 1030.0, {"husks": [{"at": Vector2(100.5, 50.0), "reach": Dish.HUSK_HERE, "found": PackedFloat32Array()}]})
	TestUtil.check(d.husk_details(d.selected.husk).is_empty(), "an answer that finds nothing there means it has leaked away")
	d.show_layer(Dish.Layer.HUSKS, false)
	_serve(d, 1030.0, {"husks": [{"at": Vector2(100.0, 50.0), "reach": 1.5, "found": husk}]})
	d.hover_at(at)
	TestUtil.check(d.hovered.husk == Dish.NO_HUSK, "with the layer hidden no husk is looked for")
	d.show_layer(Dish.Layer.HUSKS, true)
	d.clear_selection()
	d.clear_hover()


func _picture(d: Dish) -> void:
	var t := PackedFloat32Array()
	for k in 3:
		t.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 10.0 * k, 0.0, 1.0, 0.0, -5.0 * k]))
	d.drawing.refresh_husks({"row": d.row, "version": 1, "transforms": t})
	var mm := d.drawing.husks_mesh.multimesh
	TestUtil.check(d.drawing.husks_drawn() == 3 and mm.instance_count == Dish.HUSK_MIN_CAPACITY, "3 husks are drawn (%d of %d)" % [d.drawing.husks_drawn(), mm.instance_count])
	TestUtil.check((mm.mesh as QuadMesh).size == Vector2.ONE * d.husk_draw_size(), "a husk is drawn at the husk's size (%s)" % (mm.mesh as QuadMesh).size)
	var many := PackedFloat32Array()
	many.resize(2000 * 8)
	d.drawing.refresh_husks({"row": d.row, "version": 2, "transforms": many})
	TestUtil.check(d.drawing.husks_drawn() == 2000 and mm.instance_count == 2048, "2,000 husks fit a room of 2,048 (%d)" % mm.instance_count)
	d.drawing.refresh_husks({"row": d.row + 1, "version": 3, "transforms": t})
	TestUtil.check(d.drawing.husks_drawn() == 2000, "another row's list is not taken")
	d.show_layer(Dish.Layer.HUSKS, false)
	d.drawing.refresh_husks({"row": d.row, "version": 4, "transforms": t})
	TestUtil.check(d.drawing.husks_drawn() == 0, "with the layer hidden no husk is drawn")
	d.show_layer(Dish.Layer.HUSKS, true)


func _probe(d: Dish) -> void:
	var local := Vector2(30.0, 40.0)
	d.nutrient_reading(local)
	_serve(d, 1000.0, {"probes": PackedFloat32Array([0.6, 0.8, 0.7, 1e-3, 1e-5])})
	var r := d.nutrient_reading(local)
	TestUtil.check(is_equal_approx(r.x, 1e-3) and absf(r.y - 6e-6) < 1e-12 and absf(r.z - 8e-6) < 1e-12, "the probe's way and size make the gradient (%s)" % r)
	var text := PanelText.point(d.nutrient_at(d.global_position + local))
	TestUtil.check(text.contains(Strings.t("panel.compass_se")) and not text.contains(Strings.t("panel.gradient_flat")), "the point readout says which way it rises (%s)" % text.replace("\n", " | "))
	_serve(d, 1000.0, {"probes": PackedFloat32Array([0.0, 0.0, 0.5, 1e-3, 0.0])})
	text = PanelText.point(d.nutrient_at(d.global_position + local))
	TestUtil.check(text.contains(Strings.t("panel.gradient_flat")), "no gradient reads flat")


func _sources(d: Dish) -> void:
	var copy := DishWorldCopy.new()
	copy.version = 7
	copy.time = 1000.0
	copy.sources = [{"id": 1, "pos": Vector2(20.0, 0.0), "rate": 6.0, "emitted": 100.0}]
	_serve(d, 1000.0, {}, {d.row: copy})
	TestUtil.check(d.sources.size() == 1 and is_equal_approx(d.source_details(d.sources[0])["emitted"], 100.0), "a source's release so far is the copy's")
	_serve(d, 1120.0, {})
	TestUtil.check(is_equal_approx(d.source_details(d.sources[0])["emitted"], 112.0), "two minutes later it has released its rate's worth more (%.2f)" % d.source_details(d.sources[0])["emitted"])


func _drop(d: Dish) -> void:
	d.drop_nutrients(d.global_position + Vector2(10.0, 0.0), 9)
	var e: WorldEdit = _b.last(SimCommand.KIND_EDIT_WORLD).get("edit")
	TestUtil.check(e != null and e.kind == WorldEdit.Kind.DROP and is_equal_approx(e.amount, 144.0) and is_equal_approx(e.radius, 15.0), "a dose of 9 is dropped over the circle the preview shows (%s, %s)" % [e.amount if e != null else -1.0, e.radius if e != null else -1.0])
	d.drop_nutrients(d.global_position + Vector2(10.0, 0.0), 1)
	e = _b.last(SimCommand.KIND_EDIT_WORLD).get("edit")
	TestUtil.check(e != null and e.radius == 0.0, "one unit lands on its point")
