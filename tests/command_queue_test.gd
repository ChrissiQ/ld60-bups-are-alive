extends SceneTree
## Run: godot --headless --path . -s tests/command_queue_test.gd
## The command queue, replies and the main thread's door to the simulation, with the processor's stub
## backend and the test double; no device.
##
## Expected values, written before the first run [derived from the classes' contracts]:
##  - CommandQueue: three pushes drain as a, b, c, and the queue is empty after; two writer threads of 1,000 commands each arrive all
##    2,000, each writer's in its own order; a reader waiting in `wait` wakes on a push.
##  - SimReply: not done and null at first; `complete(v)` makes it done with v; a second complete changes nothing; an error comes back.
##  - CpuSimBackend: cannot simulate; no device name (""); a command's reply is done at once with null and no error; the snapshot is empty
##    (seq 0, no dishes); no view source.
##  - WorldClient on the stub: rows 0, 1 for two dishes; after removing 0 the next dish gets 0 again; a freeze's reply is done at once
##    (null); a pipette takes the next free row; set_time, ask and set_view send nothing back; `poll` emits nothing for the stub's empty
##    snapshot.
##  - WorldClient on FakeSimBackend: the commands reach the backend in call order with their kinds and arguments (add_dish's row and a
##    copy of its spec; set_time's speed, pause and frame; ask's questions; set_view's row); a reply scripted at 2 frames is done after
##    2 ticks; a served snapshot with seq 1 is emitted once by `poll`, and a refused row in it is freed and emitted.
##  - SimService (the autoload): headless, its world runs on the stub (cannot simulate); `use_backend` swaps in the fake.


func _initialize() -> void:
	_queue_order()
	_queue_threads()
	_queue_wait()
	_reply()
	_stub()
	_client_on_stub()
	_client_on_fake()
	_service()
	TestUtil.finish(self, "COMMAND QUEUE TEST OK")


func _queue_order() -> void:
	var q := CommandQueue.new()
	for k in [&"a", &"b", &"c"]:
		q.push(SimCommand.new(k))
	TestUtil.check(q.size() == 3, "three queued")
	var kinds := q.drain().map(func(c: SimCommand) -> StringName: return c.kind)
	TestUtil.check(kinds == [&"a", &"b", &"c"], "drained in push order (got %s)" % [kinds])
	TestUtil.check(q.drain().is_empty() and q.size() == 0, "empty after a drain")


func _queue_threads() -> void:
	var q := CommandQueue.new()
	var writers: Array[Thread] = []
	for w in 2:
		var t := Thread.new()
		t.start(func() -> void:
			for i in 1000:
				q.push(SimCommand.new(&"n", {"writer": w, "i": i})))
		writers.append(t)
	var got: Array[SimCommand] = []
	while got.size() < 2000:
		got.append_array(q.drain())
		OS.delay_usec(50)
	for t in writers:
		t.wait_to_finish()
	got.append_array(q.drain())
	var next := [0, 0]
	var in_order := true
	for c in got:
		var w: int = c.args["writer"]
		if c.args["i"] != next[w]:
			in_order = false
		next[w] = int(c.args["i"]) + 1
	TestUtil.check(got.size() == 2000 and in_order, "two writers: all 2,000 arrive, each writer's in order (got %d, in order %s)" % [got.size(), in_order])


func _queue_wait() -> void:
	var q := CommandQueue.new()
	var woke := [false]
	var t := Thread.new()
	t.start(func() -> void:
		q.wait()
		woke[0] = true)
	OS.delay_msec(20)
	var before: bool = woke[0]
	q.push(SimCommand.new(&"x"))
	t.wait_to_finish()
	TestUtil.check(not before and woke[0], "a waiting reader sleeps until a push wakes it")


func _reply() -> void:
	var r := SimReply.new()
	TestUtil.check(not r.is_done() and r.value() == null, "a new reply is not done")
	r.complete(7)
	TestUtil.check(r.is_done() and r.value() == 7 and r.error() == "", "complete(7): done with 7")
	r.complete(8, "late")
	TestUtil.check(r.value() == 7 and r.error() == "", "a second complete changes nothing")
	var e := SimReply.new()
	e.complete(null, "refused")
	TestUtil.check(e.is_done() and e.error() == "refused", "an error comes back")


func _stub() -> void:
	var b := CpuSimBackend.new()
	TestUtil.check(not b.can_simulate() and b.device_name() == "", "the stub cannot simulate and names no device")
	var r := SimReply.new()
	b.submit(SimCommand.new(SimCommand.KIND_FREEZE, {"row": 0}, r))
	TestUtil.check(r.is_done() and r.value() == null and r.error() == "", "the stub completes a reply at once with nothing")
	var s := b.latest()
	TestUtil.check(s.seq == 0 and s.dishes.is_empty() and b.view_source() == null, "the stub's snapshot is empty")
	b.shutdown()


func _client_on_stub() -> void:
	var w := WorldClient.new(CpuSimBackend.new())
	var emitted := [0]
	w.snapshot_changed.connect(func(_s: Snapshot) -> void: emitted[0] += 1)
	var a := w.add_dish(DishSpec.new())
	var b := w.add_dish(DishSpec.new())
	TestUtil.check(a == 0 and b == 1, "rows 0 and 1 (got %d, %d)" % [a, b])
	w.remove_dish(0)
	TestUtil.check(w.add_dish(DishSpec.new()) == 0, "a removed row is given again")
	var fr := w.freeze(1)
	TestUtil.check(fr.is_done() and fr.value() == null, "a freeze on the stub is done at once")
	var pr := w.pipette(0, Vector2.ZERO, 100.0)
	TestUtil.check(pr.is_done() and w.rows() == [0, 1], "a pipette takes the next free row (rows %s)" % [w.rows()])
	w.set_time(1.0, false, 1.0 / 60.0)
	w.ask(0, {"fractions": {"fast": ["speed", 30.0]}})
	w.set_view(0, ViewRequest.new())
	w.poll()
	TestUtil.check(emitted[0] == 0, "poll emits nothing for the stub's empty snapshot")


func _client_on_fake() -> void:
	var fake := FakeSimBackend.new()
	var w := WorldClient.new(fake)
	var spec := DishSpec.new()
	spec.number = 4
	var row := w.add_dish(spec)
	spec.number = 5
	w.set_time(2.0, false, 0.016)
	w.ask(row, {"fractions": {"fast": ["speed", 30.0]}})
	var view := ViewRequest.new()
	view.pixel_um = 3.0
	w.set_view(row, view)
	var kinds := fake.calls.map(func(c: Dictionary) -> StringName: return c["kind"])
	TestUtil.check(kinds == [SimCommand.KIND_ADD_DISH, SimCommand.KIND_SET_TIME, SimCommand.KIND_ASK, SimCommand.KIND_SET_VIEW], "commands in call order (got %s)" % [kinds])
	var add: Dictionary = fake.calls[0]["args"]
	TestUtil.check(add["row"] == row and (add["spec"] as DishSpec).number == 4, "add_dish sends its row and a copy of its spec")
	var st: Dictionary = fake.calls[1]["args"]
	TestUtil.check(st["speed"] == 2.0 and st["paused"] == false and st["real_dt"] == 0.016, "set_time's speed, pause and frame")
	TestUtil.check(fake.calls[2]["args"]["questions"]["fractions"]["fast"] == ["speed", 30.0], "ask's questions")
	var sv: Dictionary = fake.calls[3]["args"]
	TestUtil.check(sv["row"] == row and (sv["view"] as ViewRequest).row == row and (sv["view"] as ViewRequest).pixel_um == 3.0, "set_view's row and view")
	fake.script_reply(SimCommand.KIND_FREEZE, "blob", 2)
	var r := w.freeze(row)
	fake.tick()
	var after_one := r.is_done()
	fake.tick()
	TestUtil.check(not after_one and r.is_done() and r.value() == "blob", "a reply scripted at 2 frames is done after 2 ticks")
	var emitted: Array = []
	var gone: Array = []
	w.snapshot_changed.connect(func(s: Snapshot) -> void: emitted.append(s.seq))
	w.refused.connect(func(rw: int, why: String) -> void: gone.append([rw, why]))
	var again := w.add_dish(DishSpec.new())
	var snap := Snapshot.new()
	snap.seq = 1
	snap.timing = {"refused": {again: "no room"}}
	fake.serve(snap)
	w.poll()
	w.poll()
	TestUtil.check(emitted == [1], "a new snapshot is emitted once (got %s)" % [emitted])
	TestUtil.check(gone == [[again, "no room"]] and not w.rows().has(again), "a refused dish's row is freed and emitted")


func _service() -> void:
	var service := root.get_node_or_null("SimService")
	TestUtil.check(service != null, "the SimService autoload is there")
	if service == null:
		return
	TestUtil.check(not service.started(), "nothing is made before the world is asked for")
	var w: WorldClient = service.world()
	TestUtil.check(service.backend() is CpuSimBackend and not w.backend.can_simulate(), "headless: the world runs on the stub")
	var fake := FakeSimBackend.new()
	service.use_backend(fake)
	TestUtil.check(service.world().backend == fake, "use_backend swaps in the test double")
	service.shutdown()
