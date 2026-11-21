extends SceneTree
## Run: godot --headless --path . -s tests/command_queue_test.gd
## The command queue, replies and the main thread's door to the simulation, with the processor's stub
## backend and the test double; no device.
##
## Expected values [derived from the classes' contracts]:
##  - CommandQueue: three pushes drain as a, b, c, and the queue is empty after; two writer threads of 1,000 commands each arrive all
##    2,000, each writer's in its own order; a reader waiting in `wait` wakes on a push. After 10,000 pushes drained with no wait (a
##    running sim thread drains between iterations without waiting), one `wait` returns at once and the next sleeps until a push 60 ms
##    later (40 ms or more) [derived: a push posts only when no post is waiting, so 9,999 earlier pushes leave one post and one wait returns at once].
##  - SimReply: not done and null at first; `complete(v)` makes it done with v; a second complete changes nothing; an error comes back.
##  - CpuSimBackend: cannot simulate; no device name (""); a command's reply is done at once with null and no error; the snapshot is empty
##    (seq 0, no dishes); no view source.
##  - WorldClient on the stub: rows 0, 1 for two dishes; after removing 0 the next dish gets 0 again; a freeze's reply is done at once
##    (null); a pipette takes the next free row; set_time, ask and set_view send nothing back; `poll` emits nothing for the stub's empty
##    snapshot.
##  - WorldClient on FakeSimBackend: the commands reach the backend in call order with their kinds and arguments (add_dish's row and a
##    copy of its spec; set_time's speed, pause and frame; ask's questions; set_view's row); a reply scripted at 2 frames is done after
##    2 ticks; a served snapshot with seq 1 is emitted once by `poll`, and a refused row in it is freed and emitted. A refusal carried
##    again by a later snapshot (timing["refused_seq"] the same: the worker carries one until a snapshot with it is acknowledged) is not
##    emitted again, and the row given to a new dish meanwhile stays that dish's; a later refusal of that row (a newer refused_seq) is.
##  - SimService (the autoload): headless, its world runs on the stub (cannot simulate); `use_backend` swaps in the fake.


func _initialize() -> void:
	_queue_order()
	_queue_threads()
	_queue_wait()
	_queue_posts()
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


func _queue_posts() -> void:
	var q := CommandQueue.new()
	for i in 10000:
		q.push(SimCommand.new(&"n"))
	q.drain()
	q.wait()  # (the one post the pushes left)
	var late := Thread.new()
	late.start(func() -> void:
		OS.delay_msec(60)
		q.push(SimCommand.new(&"late")))
	var t0 := Time.get_ticks_usec()
	q.wait()
	var waited_ms := (Time.get_ticks_usec() - t0) / 1000.0
	late.wait_to_finish()
	var got := q.drain()
	TestUtil.check(waited_ms >= 40.0 and got.size() == 1 and got[0].kind == &"late", "after 10,000 pushes drained without a wait, the second wait sleeps until the next push (%.1f ms)" % waited_ms)


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
	TestUtil.check(s.seq == 0 and s.dishes.is_empty(), "the stub's snapshot is empty")
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
	var refused_row := w.add_dish(DishSpec.new())
	snap = Snapshot.new()
	snap.seq = 2
	snap.timing = {"refused": {refused_row: "no room"}, "refused_seq": {refused_row: 2}}
	fake.serve(snap)
	w.poll()
	var taken := w.add_dish(DishSpec.new())  # (the row is free again: a new dish takes it)
	snap = Snapshot.new()
	snap.seq = 3
	snap.timing = {"refused": {refused_row: "no room"}, "refused_seq": {refused_row: 2}}  # (not yet acknowledged: carried again)
	fake.serve(snap)
	w.poll()
	TestUtil.check(taken == refused_row and gone.size() == 2 and w.rows().has(taken), "a refusal carried again by the next snapshot is not taken twice: the new dish keeps row %d (refusals %s)" % [taken, gone])
	snap = Snapshot.new()
	snap.seq = 4
	snap.timing = {"refused": {taken: "no room"}, "refused_seq": {taken: 4}}
	fake.serve(snap)
	w.poll()
	TestUtil.check(gone.size() == 3 and not w.rows().has(taken), "a later refusal of the same row is taken")
	snap = Snapshot.new()
	snap.seq = 5
	for s in [1, 2]:
		var p := PayloadInfo.new()
		p.seq = s
		snap.payloads.append(p)
	fake.serve(snap)
	for i in 4:
		w.poll()
	var rate := w.picture_rate()
	TestUtil.check(rate["shown"] == 2 and rate["published"] == 2 and rate["longest_hold_frames"] == 2, "two publishes in one snapshot: shown on two frames, the second still up two frames later (got %s)" % [rate])


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
