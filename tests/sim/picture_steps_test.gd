extends SceneTree
## The bup pictures an iteration makes within its steps (IterationPlan.pictures, SimCore._record_shot) are the pictures of the dish as it
## was after their steps, and making them changes nothing of the run. Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/picture_steps_test.gd
##
## Expected values [derived: a picture only reads the records, after the step it follows, into a slot or texture of its own]:
## On each path (shared textures, and the byte handover, SimCore.cpu_handover), two worlds made alike (a 900 µm dish of 2,000 founders,
## every flag; it grows, so the counts differ from step to step) run 20 steps alike. World A then runs one iteration of 12 steps asking
## 6 pictures with a founder tracked: 5 come within the steps, after steps 2, 4, 6, 8 and 10 [derived: (j + 1) x 12 / 6], each with its
## own publish number, ascending, below the last publish's. World B runs to each of those steps (and to 12) and publishes there. For each
## picture: its count is B's count then, its payload's texels (bytes handed over, or the shared texture's first count texels) and its ids
## (`ids_at`, or the id texture) are B's word for word, and its tracked founder's record is B's (found at least in the first). After the
## 12 steps A's dish is word for word (canonical dump) that of a third world C, made alike, whose iteration of 12 steps asks one picture.

const FOUNDERS := 2000
const STEPS := 12
const PICTURES := 6


func _init() -> void:
	if not SimHarness.begin(self, "picture_steps_test", "the pooled core (SimCore)"):
		return
	for handed: bool in [false, true]:
		_check(handed)
	TestUtil.finish(self, "OK picture_steps_test")


func _world(handed: bool) -> SimHarness:
	var h := SimHarness.make([Scenario.small(FOUNDERS, 900.0).seed(11).with_all_flags()])
	h.core.cpu_handover = handed
	h.step(20)
	return h


func _view(track: int) -> ViewRequest:
	var v := ViewRequest.new()
	v.row = 0
	v.track = PackedInt64Array([track])
	return v


## One iteration of `k` steps of `h` as SimHarness.step runs one, with `plan`'s view and pictures.
static func _run(h: SimHarness, k: int, view: ViewRequest, pictures: int) -> Dictionary:
	var d := 20.0
	var plan := IterationPlan.new()
	plan.delta = d
	plan.view = view
	plan.pictures = pictures
	for row in h.scenarios:
		plan.events[row] = h._worlds[row].events(h._steps_done[row] * d, k, d)
		h._steps_done[row] += k
	return h.core.run(k, d, plan)


func _check(handed: bool) -> void:
	var path := "bytes" if handed else "textures"
	var a := _world(handed)
	var b := _world(handed)
	var track := int(a.core.live_ids(0)[0])
	var res := _run(a, STEPS, _view(track), PICTURES)
	var pub: Dictionary = res.get("published", {})
	var shots: Array = pub.get("shots", [])
	var steps := shots.map(func(s: Dictionary) -> int: return int(s["step"]))
	TestUtil.check(steps == [2, 4, 6, 8, 10], "%s: 5 pictures within the steps, after steps 2, 4, 6, 8, 10 (got %s)" % [path, steps])
	var seqs := shots.map(func(s: Dictionary) -> int: return int(s["seq"]))
	seqs.append(a.core.publish_seq)
	var ascending := true
	for i in range(1, seqs.size()):
		ascending = ascending and seqs[i] == seqs[i - 1] + 1
	TestUtil.check(ascending, "%s: each picture its own publish number, ascending, the last publish's last (got %s)" % [path, seqs])
	var pictures: Array = shots.duplicate()
	pictures.append({"step": STEPS, "payload": pub.get("payload", -1), "count": a.core.count(0), "seq": a.core.publish_seq,
		"bytes": a.core.handed.get("payload", PackedByteArray()), "tracked": pub.get("tracked", {})})
	var done := 0
	for p: Dictionary in pictures:
		_run(b, int(p["step"]) - done, null, 1)
		done = int(p["step"])
		var got: Dictionary = b.core.publish(_view(track))
		var n: int = b.core.count(0)
		TestUtil.check(int(p["count"]) == n, "%s, step %d: the picture's count is the dish's then (%d, %d)" % [path, done, p["count"], n])
		var mine := _texels(a.core, handed, p, n)
		var theirs := _texels(b.core, handed, {"payload": got.get("payload", -1), "bytes": b.core.handed.get("payload", PackedByteArray()), "seq": b.core.publish_seq}, n)
		TestUtil.check(not mine[0].is_empty() and mine[0] == theirs[0], "%s, step %d: the payload's %d texels are the dish's then" % [path, done, n])
		TestUtil.check(not mine[1].is_empty() and mine[1] == theirs[1], "%s, step %d: its ids are the dish's then" % [path, done])
		var tracked: Dictionary = p.get("tracked", {})
		var want: Dictionary = got.get("tracked", {})
		TestUtil.check(tracked == want and (done > 2 or tracked.has(track)), "%s, step %d: its tracked founder's record is the dish's then (found: %s)" % [path, done, tracked.has(track)])
	var c := _world(handed)
	_run(c, STEPS, _view(track), 1)
	var same := a.dump(0) == c.dump(0)
	if not same:
		for key: String in a.dump(0):
			if a.dump(0)[key] != c.dump(0)[key]:
				print("differs: %s" % key)
	TestUtil.check(same, "%s: after the %d steps the dish is the one an iteration publishing only its last picture leaves" % [path, STEPS])


## [payload bytes, id bytes] of the first `n` texels of picture `p` (its "payload" texture index, or its handed "bytes" and its "seq" for
## the ids) of `core`.
static func _texels(core: SimCore, handed: bool, p: Dictionary, n: int) -> Array:
	if handed:
		var idx := PackedInt32Array()
		for i in n:
			idx.append(i)
		return [p["bytes"], core.ids_at(int(p["seq"]), idx).to_byte_array()]
	var i: int = p["payload"]
	if i < 0:
		return [PackedByteArray(), PackedByteArray()]
	var pay := core.rd.texture_get_data(core.textures("payload")[i], 0)
	var ids := core.rd.texture_get_data(core.textures("ids")[i], 0)
	return [pay.slice(0, n * GpuLayout.PAYLOAD_BYTES), ids.slice(0, n * GpuLayout.IDT_BYTES)]
