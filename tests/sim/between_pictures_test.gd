extends SceneTree
## Drawing between pictures as the game draws it: a bare Dish on the screen over the real world, run at x300 with a bup selected (so the
## pictures carry its place and its place before), then paused, the view holding the last picture; the share of the way between pictures
## set (`DishDrawing.share_override`) and the view's instances read back from the bups' MultiMesh. 150 µm radius, 100 founders, the
## camera at 1 px a µm (the whole dish well inside the window); density mode off, so every bup is a capsule and the instances are the
## payload's texels in order. Windowed only, on either path. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tests/sim/between_pictures_test.gd
##   (and with `-- --cpu-handover` after the script: the byte handover)
## The run is paced as on a 60 Hz display (60 frames a second, the governor told a 60 Hz frame), where the commands the dish sends during
## the hold start passes of no steps that publish the picture again; such a picture carries the motion of the one before (SimCore,
## WorldClient's header), so M holds through them. The hold is no set_time once the run has gone on RUN_FRAMES frames; a publish that still comes during the checks (a command the dish
## sends may start a pass) changes the picture under them, so the run and the checks are made again, up to ATTEMPTS times.
##
## Expected values [derived from GpuKernelsView.place_at: a bup is drawn at was (1 - t) + here t, here exactly at t = 1]:
## M  The picture held has bups that moved from their places before (at x300 a picture follows the one before by seconds of simulated
##    time, in which a swimming bup goes tens of µm or more): at least half of them by more than 1 µm.
## D  At shares 0, 0.5 and 1 every bup's instance is at its place before, halfway, and its place, within 1e-3 µm (float rounding of
##    places under 200 µm is about 2e-5 µm); a bup whose place before is its place (a newborn) is drawn at its place at every share.
## R  At 0.5, the selected bup's ring and its place for the camera's follow (DishDrawing.view_ring, Dish.bup_world_pos) are where its
##    instance is drawn, within 1e-3 µm: a followed bup stays in the middle of the view while the bups move between pictures.
## P  At 0.5, a pick at the halfway point of the bup that moved furthest (one whose halfway point is clear of every other bup's by more
##    than twice REACH, which is more than the pick's reach) finds it, and a pick at its place in the picture, more than REACH away, does
##    not.

const BUPS := 100
const WINDOW := Vector2i(1280, 720)
const ZOOM := 1.0
const SPEED := 300.0
const RUN_FRAMES := 180
const TOLERANCE := 1e-3  ## µm
const ATTEMPTS := 3
const REACH := 4.0  ## µm: more than a pick's reach with no slack, half a bup's drawn length (a bup is under 8 µm long; the least footprint at 1 px a µm is 2 µm)


func _initialize() -> void:
	_run()


func _pump(d: Dish, frames: int, running := false) -> void:
	for i in frames:
		if running:
			d.world.set_time(SPEED, false, 1.0 / 60.0)
		await process_frame


## Where the view's picture has each bup: {here: PackedVector2Array, was: PackedVector2Array, ids: PackedInt64Array (empty on the byte
## handover)}, read from the textures or bytes the view holds.
func _held(v: ViewRenderer) -> Dictionary:
	var p := v.payload()
	var out := {"here": PackedVector2Array(), "was": PackedVector2Array(), "ids": PackedInt64Array()}
	if not p.bytes.is_empty():
		for k in p.count:
			out["here"].append(Vector2(p.bytes.decode_float(k * GpuLayout.PAYLOAD_BYTES), p.bytes.decode_float(k * GpuLayout.PAYLOAD_BYTES + 4)))
			out["was"].append(Vector2(p.prev_bytes.decode_float(k * GpuLayout.PV_BYTES), p.prev_bytes.decode_float(k * GpuLayout.PV_BYTES + 4)))
		return out
	var pay: RID = v._imports["payload"]["rids"][p.texture_index]
	var idt: RID = v._imports["ids"]["rids"][p.texture_index]
	var got := [PackedByteArray(), PackedByteArray()]
	RenderingServer.call_on_render_thread(func() -> void:
		var rd := RenderingServer.get_rendering_device()
		got[0] = rd.texture_get_data(pay, 0)
		got[1] = rd.texture_get_data(idt, 0))
	for k in p.count:
		var o := k * GpuLayout.IDS_BYTES
		out["here"].append(Vector2(got[0].decode_float(k * GpuLayout.PAYLOAD_BYTES), got[0].decode_float(k * GpuLayout.PAYLOAD_BYTES + 4)))
		out["was"].append(Vector2(got[1].decode_float(o + GpuLayout.IDS_PREV_X * 4), got[1].decode_float(o + GpuLayout.IDS_PREV_Y * 4)))
		out["ids"].append(got[1].decode_u32(o + GpuLayout.IDT_LO * 4) | (got[1].decode_u32(o + GpuLayout.IDT_HI * 4) << 32))
	return out


## The instances' places in the bups' MultiMesh (the first `n`).
func _instances(d: Dish, n: int) -> PackedVector2Array:
	var buf := RenderingServer.multimesh_get_buffer_rd_rid(d.drawing.bups_mesh.multimesh.get_rid())
	var got := [PackedByteArray()]
	RenderingServer.call_on_render_thread(func() -> void: got[0] = RenderingServer.get_rendering_device().buffer_get_data(buf, 0, n * 64))
	var out := PackedVector2Array()
	for j in n:
		out.append(Vector2(got[0].decode_float(j * 64 + 12), got[0].decode_float(j * 64 + 28)))
	return out


## The worst distance of the instances from where share `t` should draw each bup of `held`.
static func _worst(held: Dictionary, inst: PackedVector2Array, t: float) -> float:
	var worst := 0.0
	for k in (held["here"] as PackedVector2Array).size():
		var want: Vector2 = held["here"][k] if t >= 1.0 else held["was"][k] * (1.0 - t) + held["here"][k] * t
		worst = maxf(worst, want.distance_to(inst[k]) if k < inst.size() else INF)
	return worst


func _draw_at(d: Dish, t: float) -> PackedVector2Array:
	d.drawing.share_override = t
	await _pump(d, 4)
	return _instances(d, d.drawing.view.payload().count)


## The answer to a pick at `local` (dish-local µm) with no slack, once the view has given it.
func _pick(d: Dish, local: Vector2) -> Dictionary:
	var v := d.drawing.view
	var seq := v.pick(local, 0.0, 1.0 / ZOOM, false, 0.0)
	for i in 30:
		await _pump(d, 1)
		var a := v.answer(false)
		if not a.is_empty() and int(a["seq"]) == seq:
			return a
	return {}


## The checks M, D, R and P on the picture the view holds: [passed, text] each.
func _measure(d: Dish, v: ViewRenderer, chosen: int) -> Array:
	var out: Array = []
	var held := _held(v)
	var n: int = (held["here"] as PackedVector2Array).size()
	var moved := 0
	var still := 0
	for k in n:
		var gone: float = (held["here"][k] as Vector2).distance_to(held["was"][k])
		moved += 1 if gone > 1.0 else 0
		still += 1 if gone == 0.0 else 0
	out.append(_result(n > 0 and moved * 2 >= n, "M %d of %d bups moved more than 1 µm from their places before (%d did not move: newborns)" % [moved, n, still]))
	var worst := {}
	var at_half := PackedVector2Array()
	for t: float in [0.0, 0.5, 1.0]:
		var inst: PackedVector2Array = await _draw_at(d, t)
		worst[t] = _worst(held, inst, t)
		if t == 0.5:
			at_half = inst
	var visible := int(v._visible.get("count", -1))
	out.append(_result(visible == n and worst[0.0] <= TOLERANCE and worst[0.5] <= TOLERANCE and worst[1.0] <= TOLERANCE, "D %d of %d bups drawn; worst off where they should be at shares 0, 0.5, 1: %.6f, %.6f, %.6f µm (want under %.4f)" % [visible, n, worst[0.0], worst[0.5], worst[1.0], TOLERANCE]))
	d.drawing.share_override = 0.5
	await _pump(d, 4)
	var ring: Variant = d.drawing.view_ring(chosen)
	var follow: Vector2 = d.bup_world_pos(chosen) - d.global_position
	var k_chosen := -1
	var p := v.payload()
	if (held["ids"] as PackedInt64Array).is_empty():
		var here: Variant = p.places.get(chosen)
		for k in n:
			if here != null and held["here"][k] == Vector2(here.x, here.y):
				k_chosen = k
	else:
		k_chosen = (held["ids"] as PackedInt64Array).find(chosen)
	var ring_off: float = INF if ring == null or k_chosen < 0 else Vector2(ring.x, ring.y).distance_to(at_half[k_chosen])
	var follow_off: float = INF if k_chosen < 0 else follow.distance_to(at_half[k_chosen])
	out.append(_result(ring_off <= TOLERANCE and follow_off <= TOLERANCE, "R the selected bup %d (texel %d): its ring %.6f µm and its follow place %.6f µm from where it is drawn" % [chosen, k_chosen, ring_off, follow_off]))
	var best := -1
	var best_gone := 0.0
	for k in n:
		var half: Vector2 = at_half[k]
		var clear := true
		for j in n:
			if j != k and half.distance_to(at_half[j]) <= 2.0 * REACH:
				clear = false
				break
		var gone: float = (held["here"][k] as Vector2).distance_to(half)
		if clear and gone > REACH and gone > best_gone:
			best = k
			best_gone = gone
	if best < 0:
		out.append(_result(false, "P a bup whose halfway point is clear of the others and of its own place"))
	else:
		var a := await _pick(d, at_half[best])
		var miss := await _pick(d, held["here"][best])
		var id_ok: bool = (held["ids"] as PackedInt64Array).is_empty() or (not a.is_empty() and int(a["id"]) == held["ids"][best])
		out.append(_result(not a.is_empty() and int(a["index"]) == best and id_ok and not miss.is_empty() and int(miss["index"]) != best, "P a pick at texel %d's halfway point (%.1f µm from its place) finds it (index %s), one at its place does not (index %s)" % [best, best_gone, a.get("index", "none"), miss.get("index", "none")]))
	return out


static func _result(ok: bool, text: String) -> Array:
	return [ok, text]


func _run() -> void:
	if not SimHarness.begin(self, "between_pictures_test", "drawing between pictures"):
		return
	SimConstants.apply()
	while not root.is_node_ready():
		await process_frame
	DisplayServer.window_set_size(WINDOW)
	for i in 10:
		await process_frame
	var start := TestUtil.small_start()
	start.dish_radius = 150.0
	start.bup_limit = 2000
	start.bups = BUPS
	var d := Dish.new()
	root.add_child(d)
	var camera := Camera2D.new()
	camera.zoom = Vector2.ONE * ZOOM
	root.add_child(camera)
	await process_frame
	camera.make_current()
	Engine.max_fps = 60  # (a 60 Hz display: see the header)
	d.world.display_ms = 1000.0 / 60.0
	d.strike(start)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 5000 and d.drawing.view == null:
		d.world.set_time(SPEED, true, 1.0 / 60.0)
		await process_frame
	var v: ViewRenderer = d.drawing.view
	if v == null:
		TestUtil.show(false, "the dish's view was made")
		TestUtil.finish(self, "OK between_pictures_test")
		return
	v.set_density(false)
	var ids := d.bup_ids()
	while Time.get_ticks_msec() - t0 < 10000 and ids.is_empty():
		d.world.set_time(SPEED, true, 1.0 / 60.0)
		await process_frame
		ids = d.bup_ids()
	var chosen: int = ids[ids.size() / 2] if not ids.is_empty() else -1
	d.selected.bup = chosen
	var out: Array = []
	for attempt in ATTEMPTS:  # (a publish that comes after the hold began, from a command the dish sends, starts the attempt again)
		await _pump(d, RUN_FRAMES, true)
		var quiet := 0  # (no more set_time: once the owed steps are run and the waiting pictures shown, the view holds the run's last picture)
		var seen := -1
		while quiet < 30 and Time.get_ticks_msec() - t0 < 60000:
			await process_frame
			quiet = quiet + 1 if v.payload().seq == seen else 0
			seen = v.payload().seq
		out = await _measure(d, v, chosen)
		d.drawing.share_override = -1.0
		if v.payload().seq == seen:
			break
		print("     the held picture changed during attempt %d (publish %d, then %d): again" % [attempt + 1, seen, v.payload().seq])
		out = [[false, "the view held one picture through an attempt"]]
	for r: Array in out:
		TestUtil.show(r[0], r[1])
	d.queue_free()
	camera.queue_free()
	await process_frame
	await process_frame
	TestUtil.finish(self, "OK between_pictures_test")
