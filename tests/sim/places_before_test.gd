extends SceneTree
## Where each bup was in the picture before (`pool_payload`'s PREVXY, found by id in the slot of the picture before; the ids texture's IDS_PREV_*, the bytes
## handed over, a tracked bup's R_PX and R_PY), against the ids the pictures carry. Windowed only. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/places_before_test.gd
##
## Expected values [derived: a bup's place before is its place in the last picture made of the same dish when its id is in it, else its
## own place; a dish's bups lie in the rising order of their ids, which compaction, a pipette into a new dish and a thaw keep]:
## On each path (shared textures, and the byte handover, SimCore.cpu_handover), a 900 µm dish of 2,000 founders with every flag and a
## limit of 2,100 (so births displace bups and some die every step once it is full) runs 20 steps, then three iterations of 6 steps asking
## 3 pictures each with a founder tracked (2 within the steps, after steps 2 and 4, and the last), 5 steps with no picture between the
## second and the third. For each picture:
## O  its ids rise strictly from texel to texel;
## P  each texel's place before equals, bit for bit, the place of the same id in the picture made before it (the one before the 5 steps,
##    for the first after them) when that picture holds the id, else its own place; over the pictures some bups are newborns (in no
##    picture before) and some of the picture before's bups are gone (dead), so both cases are met;
## T  the tracked founder's answer carries its place before (R_PX, R_PY) as its texel has it.
## Then the dish is pipetted (a 300 µm disc about its middle into a new dish): S  the source's next picture holds the rest, its places
## before found as in P; F  the new dish's first picture, after it, has every place before equal to the place (a picture of another dish
## row came before), and its ids rise. Then it is frozen and thawed: F  the thawed dish's first picture has every place before equal to the place (a new
## dish to the core), and after 3 more steps P holds again (the thaw kept the order: O).

const FOUNDERS := 2000
const LIMIT := 2100
const STEPS := 6
const PICTURES := 3


func _init() -> void:
	if not SimHarness.begin(self, "places_before_test", "the pooled core (SimCore)"):
		return
	for handed: bool in [false, true]:
		_check(handed)
	TestUtil.finish(self, "OK places_before_test")


func _view(row: int, track: Array = []) -> ViewRequest:
	var v := ViewRequest.new()
	v.row = row
	v.track = PackedInt64Array(track)
	return v


## One iteration of `k` steps as SimHarness.step runs one, with `view` and `pictures`.
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


## The pictures an iteration (its result `res`) or a publish (`pub`) made, oldest first: {ids, x, y, px, py (PackedInt64Array / bits),
## tracked}.
func _pictures(h: SimHarness, handed: bool, pub: Dictionary) -> Array:
	var out: Array = []
	for shot: Dictionary in pub.get("shots", []):
		out.append(_picture(h, handed, int(shot["payload"]), int(shot["count"]), int(shot["seq"]), shot.get("bytes", PackedByteArray()), shot.get("prev", PackedByteArray()), shot.get("tracked", {})))
	if pub.has("payload"):
		out.append(_picture(h, handed, int(pub["payload"]), h.core.count(int(pub.get("row", -1))) if pub.has("row") else -1, h.core.publish_seq,
			h.core.handed.get("payload", PackedByteArray()), h.core.handed.get("prev", PackedByteArray()), pub.get("tracked", {})))
	return out


func _picture(h: SimHarness, handed: bool, index: int, n: int, seq: int, bytes: PackedByteArray, prev: PackedByteArray, tracked: Dictionary) -> Dictionary:
	var p := {"ids": PackedInt64Array(), "x": PackedInt64Array(), "y": PackedInt64Array(), "px": PackedInt64Array(), "py": PackedInt64Array(), "tracked": tracked}
	var pay: PackedByteArray
	var ids: PackedByteArray
	if handed:
		n = bytes.size() / GpuLayout.PAYLOAD_BYTES
		pay = bytes
		var idx := PackedInt32Array()
		for k in n:
			idx.append(k)
		var got: PackedInt64Array = h.core.ids_at(seq, idx)
		ids = PackedByteArray()
		ids.resize(n * GpuLayout.IDS_BYTES)
		for k in n:
			ids.encode_s64(k * GpuLayout.IDS_BYTES, got[k])
			ids.encode_u64(k * GpuLayout.IDS_BYTES + GpuLayout.IDS_PREV_X * 4, prev.decode_u64(k * GpuLayout.PV_BYTES))
	else:
		pay = h.core.rd.texture_get_data(h.core.textures("payload")[index], 0)
		ids = h.core.rd.texture_get_data(h.core.textures("ids")[index], 0)
	for k in n:
		var o := k * GpuLayout.IDS_BYTES
		p["ids"].append(ids.decode_u32(o + GpuLayout.IDT_LO * 4) | (ids.decode_u32(o + GpuLayout.IDT_HI * 4) << 32))
		p["px"].append(ids.decode_u32(o + GpuLayout.IDS_PREV_X * 4))
		p["py"].append(ids.decode_u32(o + GpuLayout.IDS_PREV_Y * 4))
		p["x"].append(pay.decode_u32(k * GpuLayout.PAYLOAD_BYTES + GpuLayout.PL_X * 4))
		p["y"].append(pay.decode_u32(k * GpuLayout.PAYLOAD_BYTES + GpuLayout.PL_Y * 4))
	return p


## [rising, places before as the rule has them, newborns, gone] of picture `p` against the picture made before it (`before`: {} for none).
static func _compare(before: Dictionary, p: Dictionary) -> Array:
	var at := {}
	if not before.is_empty():
		for k in (before["ids"] as PackedInt64Array).size():
			at[before["ids"][k]] = k
	var rising := true
	var right := true
	var born := 0
	var kept := 0
	for k in (p["ids"] as PackedInt64Array).size():
		var id: int = p["ids"][k]
		if k > 0 and id <= int(p["ids"][k - 1]):
			rising = false
		if at.has(id):
			kept += 1
			right = right and p["px"][k] == before["x"][at[id]] and p["py"][k] == before["y"][at[id]]
		else:
			born += 1
			right = right and p["px"][k] == p["x"][k] and p["py"][k] == p["y"][k]
	return [rising, right, born, at.size() - kept]


## The tracked bups' answers carry their texels' places before.
static func _tracked_right(p: Dictionary) -> bool:
	var tracked: Dictionary = p["tracked"]
	for id: int in tracked:
		var k := (p["ids"] as PackedInt64Array).find(id)
		var r: PackedByteArray = tracked[id]
		if k < 0 or r.decode_u32(GpuLayout.R_PX * 4) != p["px"][k] or r.decode_u32(GpuLayout.R_PY * 4) != p["py"][k]:
			return false
	return true


func _check(handed: bool) -> void:
	var path := "bytes" if handed else "textures"
	var s := Scenario.small(FOUNDERS, 900.0).seed(11).with_all_flags()
	s.limit = LIMIT
	var h := SimHarness.make([s])
	h.core.cpu_handover = handed
	h.step(20)
	var track := int(h.core.live_ids(0)[0])
	var pictures: Array = []
	for i in 3:
		if i == 2:
			h.step(5)
		var res := _run(h, STEPS, _view(0, [track]), PICTURES)
		var pub: Dictionary = (res.get("published", {}) as Dictionary).duplicate()
		pub["row"] = 0
		pictures.append_array(_pictures(h, handed, pub))
	TestUtil.check(pictures.size() == 3 * PICTURES, "%s: %d pictures (want %d)" % [path, pictures.size(), 3 * PICTURES])
	var born := 0
	var gone := 0
	var all_rising := true
	var all_right := true
	var tracked_right := true
	var tracked_seen := 0
	for i in pictures.size():
		var r := _compare(pictures[i - 1] if i > 0 else {}, pictures[i])
		all_rising = all_rising and r[0]
		if i > 0:
			all_right = all_right and r[1]
			born += r[2]
			gone += r[3]
		tracked_right = tracked_right and _tracked_right(pictures[i])
		tracked_seen += (pictures[i]["tracked"] as Dictionary).size()
	TestUtil.check(all_rising, "%s: O every picture's ids rise" % path)
	TestUtil.check(all_right and born > 0 and gone > 0, "%s: P every place before is the same bup's in the picture before, or its own place (newborns %d, gone %d: want both above 0)" % [path, born, gone])
	TestUtil.check(tracked_right and tracked_seen > 0, "%s: T the tracked founder's answers carry its places before (%d answers)" % [path, tracked_seen])
	var last: Dictionary = pictures[-1]
	var moved := h.pipette(0, Vector2.ZERO, 300.0)
	var dest := h.last_pipette_row
	var got: Dictionary = h.core.publish(_view(0))
	got["row"] = 0
	var source: Array = _pictures(h, handed, got)
	var r_src := _compare(last, source[0]) if not source.is_empty() else [false, false, 0, 0]
	TestUtil.check(r_src[0] and r_src[1], "%s: S the source after the pipette: rising %s, its places before the picture before's %s (gone %d, moved %d)" % [path, r_src[0], r_src[1], r_src[3], moved])
	got = h.core.publish(_view(dest))
	got["row"] = dest
	var fresh: Array = _pictures(h, handed, got)
	var r_new := _compare({}, fresh[0]) if not fresh.is_empty() else [false, false, 0, 0]
	TestUtil.check(moved > 0 and r_new[0] and r_new[1], "%s: F the pipette's new dish (%d bups moved): its first picture rises and has no places before (rising %s, as the rule %s)" % [path, moved, r_new[0], r_new[1]])
	var row := h.thaw(h.freeze(0))
	got = h.core.publish(_view(row))
	got["row"] = row
	var thawed: Array = _pictures(h, handed, got)
	var r_thaw := _compare({}, thawed[0]) if not thawed.is_empty() else [false, false, 0, 0]
	TestUtil.check(r_thaw[0] and r_thaw[1], "%s: F the thawed dish's first picture rises (%s) and has no places before (%s)" % [path, r_thaw[0], r_thaw[1]])
	var res := _run(h, 3, _view(row), 1)
	got = (res.get("published", {}) as Dictionary).duplicate()
	got["row"] = row
	var after: Array = _pictures(h, handed, got)
	var r_after := _compare(thawed[0] if not thawed.is_empty() else {}, after[0]) if not after.is_empty() else [false, false, 0, 0]
	TestUtil.check(r_after[0] and r_after[1], "%s: P after the thaw and 3 steps: rising %s, places before the thawed picture's %s (newborns %d)" % [path, r_after[0], r_after[1], r_after[2]])
	print("     %s: %d pictures, newborns %d, gone %d; pipette moved %d, the source then lost %d" % [path, pictures.size(), born, gone, moved, r_src[3]])
