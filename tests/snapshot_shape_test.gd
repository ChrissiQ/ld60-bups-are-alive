extends SceneTree
## Run: godot --headless --path . -s tests/snapshot_shape_test.gd
## The fake's canned snapshots have the real `Snapshot`'s shape, and the fake's own machinery works.
## Expected values, written before the first run [derived]:
##  - every member of `Snapshot` (read from the script) is present in a canned snapshot with the declared type: seq/sim_time/
##    achieved_speed/paused: int/float/float/bool, dishes/history/answers/worlds/timing/totals: Dictionary, payloads: Array, husk_view: Dictionary, payload/field_view/thumbs: objects of
##    PayloadInfo/FieldViewInfo/ThumbsInfo; `Snapshot` has exactly 15 members;
##  - a DishState's stats keys equal `BupSim.population_stats()`'s keys, in order (measured once: count, speed, sense, metabolism, size,
##    harm, mutations, mutator, donor, key, generation = 11);
##  - a tracked answer is GpuLayout.ANSWER_BYTES (96) bytes; a record GpuLayout.RECORD_BYTES (112); records(3) is 336 bytes with ids 1..3;
##  - serve: latest() is the served snapshot (same object); before serve it is an empty Snapshot;
##  - replies at latency 0 are done at submit; at latency 2 they are not done after 0 and 1 ticks and done after 2; a scripted value, then
##    the default, then (queue empty) the default again; a scripted error comes back as the error;
##  - the call log has one entry per submit, in order, with the kind, args and frame; calls_of filters; feed_lineage without a store logs
##    "lineage_pending" and with a store passes the arguments on;
##  - shutdown completes the pending replies with an error and sets shut_down; the base SimBackend is the CPU stub's face: cannot
##    simulate, empty snapshot, no view source, no error from any call.

const SNAPSHOT_MEMBERS := {
	"seq": TYPE_INT, "sim_time": TYPE_FLOAT, "achieved_speed": TYPE_FLOAT, "paused": TYPE_BOOL, "dishes": TYPE_DICTIONARY,
	"history": TYPE_DICTIONARY, "answers": TYPE_DICTIONARY, "payload": TYPE_OBJECT, "payloads": TYPE_ARRAY, "field_view": TYPE_OBJECT, "thumbs": TYPE_OBJECT, "totals": TYPE_DICTIONARY,
	"husk_view": TYPE_DICTIONARY, "worlds": TYPE_DICTIONARY, "timing": TYPE_DICTIONARY,
}


class StoreProbe:
	extends RefCounted
	var got: Array = []

	func apply_events(births: PackedByteArray, deaths: PackedByteArray, first_step_end: float, step_seconds: float) -> void:
		got = [births.size(), deaths.size(), first_step_end, step_seconds]


func _init() -> void:
	_shape()
	_stats_keys()
	_records()
	_serve()
	_replies()
	_log()
	_lineage_seam()
	_shutdown_and_stub()
	TestUtil.finish(self, "SNAPSHOT SHAPE TEST OK")


func _shape() -> void:
	var members := {}
	for p: Dictionary in (Snapshot as Script).get_script_property_list():
		if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			members[p["name"]] = p["type"]
	TestUtil.check(members.size() == SNAPSHOT_MEMBERS.size() and members == SNAPSHOT_MEMBERS, "Snapshot has exactly the declared members: %s" % [members])
	var snap := FakeScenes.snapshot(3, 10)
	for name: String in SNAPSHOT_MEMBERS:
		TestUtil.check(typeof(snap.get(name)) == SNAPSHOT_MEMBERS[name], "canned snapshot's %s has the declared type" % name)
	TestUtil.check(snap.payload is PayloadInfo and snap.field_view is FieldViewInfo and snap.thumbs is ThumbsInfo, "payload, field_view and thumbs are the real classes")
	TestUtil.check(snap.dishes.size() == 3 and snap.dishes[2] is DishState and (snap.dishes[2] as DishState).number == 3, "three dishes, numbered 1..3")


func _stats_keys() -> void:
	var real: Array = BupSim.new().population_stats().keys()
	TestUtil.check(real.size() == 11, "population_stats has 11 keys (got %d)" % real.size())
	TestUtil.check(DishState.STATS_KEYS == Array(real, TYPE_STRING, "", null), "DishState.STATS_KEYS equal BupSim.population_stats' keys in order")
	var s := FakeScenes.stats(7)
	TestUtil.check(Array(s.keys()) == real and s["count"] == 7, "FakeScenes.stats has the real keys")
	var snap := FakeScenes.snapshot(2, 5)
	TestUtil.check(Array((snap.dishes[0] as DishState).stats.keys()) == real, "a canned dish's stats have the real keys")
	TestUtil.check(Array((snap.history[0][0]["stats"] as Dictionary).keys()) == real, "a history sample's stats have the real keys")


func _records() -> void:
	var recs := FakeScenes.records(3)
	TestUtil.check(GpuLayout.RECORD_BYTES == 112 and GpuLayout.ANSWER_BYTES == 96, "record 112 bytes, answer 96")
	TestUtil.check(recs.size() == 336, "records(3) is 336 bytes (got %d)" % recs.size())
	TestUtil.check([GpuLayout.id_of(recs, 0), GpuLayout.id_of(recs, 1), GpuLayout.id_of(recs, 2)] == [1, 2, 3], "ids 1..3")
	TestUtil.check(recs.decode_float(GpuLayout.R_SPEED * 4) == 10.0, "a gene word is where GpuLayout says")
	var snap := FakeScenes.snapshot(1, 5, 2)
	var tracked: Dictionary = snap.answers[0]["tracked"]
	TestUtil.check(tracked.size() == 2 and (tracked[1] as PackedByteArray).size() == GpuLayout.ANSWER_BYTES, "tracked answers are ANSWER_BYTES")


func _serve() -> void:
	var fake := FakeSimBackend.new()
	TestUtil.check(fake.latest() != null and fake.latest().dishes.is_empty(), "before serve: an empty snapshot")
	var snap := FakeScenes.snapshot(2, 4)
	fake.serve(snap)
	TestUtil.check(fake.latest() == snap, "after serve: the served snapshot")
	TestUtil.check(fake.can_simulate() and fake.device_name() == "fake", "the fake can simulate by default")
	fake.start(null)
	TestUtil.check(fake.started, "start is recorded")


func _replies() -> void:
	var fake := FakeSimBackend.new()
	var r0 := SimReply.new()
	fake.script_reply(&"freeze", "blob", 0)
	fake.submit(SimCommand.new(&"freeze", {"row": 0}, r0))
	TestUtil.check(r0.is_done() and r0.value() == "blob", "latency 0: done at submit with the scripted value")
	var r2 := SimReply.new()
	fake.script_reply(&"pipette", {"new_row": 1}, 2)
	fake.submit(SimCommand.new(&"pipette", {"row": 0}, r2))
	TestUtil.check(not r2.is_done(), "latency 2: not done at submit")
	fake.tick()
	TestUtil.check(not r2.is_done(), "latency 2: not done after 1 tick")
	fake.tick()
	TestUtil.check(r2.is_done() and r2.value() == {"new_row": 1}, "latency 2: done after 2 ticks with the value")
	var r3 := SimReply.new()
	fake.default_reply = 42
	fake.submit(SimCommand.new(&"pipette", {}, r3))
	TestUtil.check(r3.is_done() and r3.value() == 42, "queue empty: the default reply")
	var r4 := SimReply.new()
	fake.script_reply(&"resize", null, 0, "no room")
	fake.submit(SimCommand.new(&"resize", {}, r4))
	TestUtil.check(r4.is_done() and r4.error() == "no room", "a scripted error comes back")
	fake.reply_latency_frames = 1
	var r5 := SimReply.new()
	fake.submit(SimCommand.new(&"save_all", {}, r5))
	TestUtil.check(not r5.is_done(), "the default latency knob applies")
	fake.tick()
	TestUtil.check(r5.is_done(), "... and ends")
	r5.complete("again")
	TestUtil.check(r5.value() == 42, "a reply completes once")


func _log() -> void:
	var fake := FakeSimBackend.new()
	fake.submit(SimCommand.new(&"set_time", {"speed": 1.0}))
	fake.tick()
	fake.submit(SimCommand.new(&"add_dish", {"number": 2}))
	fake.submit(SimCommand.new(&"set_time", {"speed": 10.0}))
	TestUtil.check(fake.calls.size() == 3, "one log entry per submit")
	TestUtil.check(fake.calls.map(func(c: Dictionary) -> StringName: return c["kind"]) == [&"set_time", &"add_dish", &"set_time"], "in order")
	TestUtil.check(fake.calls[1]["frame"] == 1 and fake.calls[0]["frame"] == 0, "each has its frame")
	TestUtil.check(fake.calls_of(&"set_time").size() == 2 and fake.calls_of(&"set_time")[1]["args"]["speed"] == 10.0, "calls_of filters and keeps args")


func _lineage_seam() -> void:
	var fake := FakeSimBackend.new()
	fake.feed_lineage(PackedByteArray([1, 2]), PackedByteArray(), 1.5, 0.25)
	TestUtil.check(fake.calls_of(&"lineage_pending").size() == 1, "no store: logged as pending")
	var probe := StoreProbe.new()
	fake.lineage_store = probe
	fake.feed_lineage(PackedByteArray([1, 2]), PackedByteArray([3]), 1.5, 0.25)
	TestUtil.check(probe.got == [2, 1, 1.5, 0.25], "a store gets the arguments")


func _shutdown_and_stub() -> void:
	var fake := FakeSimBackend.new()
	var r := SimReply.new()
	fake.script_reply(&"freeze", "x", 5)
	fake.submit(SimCommand.new(&"freeze", {}, r))
	fake.shutdown()
	TestUtil.check(fake.shut_down and r.is_done() and r.error() == "shutdown", "shutdown completes pending replies with an error")
	var stub := SimBackend.new()
	stub.start(null)
	stub.submit(SimCommand.new(&"add_dish"))
	stub.shutdown()
	TestUtil.check(not stub.can_simulate() and stub.latest().dishes.is_empty() and stub.view_source() == null, "the base class is the stub's face")
