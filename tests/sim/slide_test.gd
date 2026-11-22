extends SceneTree
## Bups move between pictures at the played settings: the game screen, its dish put in the world again filled to `bups=` bups at once
## (default 2,000,000; perf_gates_test.filled_spec, as interface_gate's gate A), the 90 mm dish (perf_gates_test.DISH_90MM), bloom 1,
## nutrient and feed at the setup maxima, asked x10,000 (20 s steps: Governor's MAX_STEP), 10 s of settling. Windowed only, on either
## path. On macOS:
##   tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 --windowed --resolution 1600x1000 -s tests/sim/slide_test.gd
##   (and with `-- --cpu-handover` after the script: the byte handover; `-- bups=N` for another count)
##
## Expected values [derived: between two pictures every frame draws each bup DishDrawing.share of the way from its place before to its
## place; at 20 s steps a swimming bup goes tens to hundreds of µm a picture, which is many µm a frame]:
## Z  Zoomed out (the game's fit of the dish: every bup is far under its least footprint, so the density picture draws them all): over
##    FRAMES frames, every pair of frames that show the same picture at different shares (the frames between two pictures) has a density
##    picture with other bytes; such pairs are some of the frames (pictures are held several frames at 2M).
## C  Zoomed in (1 px a µm about the dish's middle: a bup of 2 µm or more is a capsule there, and some hundreds are in view): the same of the capsules' instances (the first
##    INSTANCES of them, their places).
## M  The motion, zoomed out, over FRAMES frames before Z and with nothing read back (a read back stalls the card the simulation shares;
##    WorldClient's playout keeps its clock of simulated time a lead behind the newest picture, so a picture a little late does not stop the
##    bups): the simulated time drawn this frame is the picture before's time and the share of the way to the shown one's (the bups move
##    with simulated time, and pictures need not be evenly spaced in it); a stall is a frame whose drawn time did not move, a jump one
##    whose drawn time moved over 3 times the median speed (simulated s a real s, over the real time the playout's clock moved by that
##    frame, `Playout.last_dt`, which the frame's start does not mark). Stalls are at most 2% of the frames, no jump comes, the clock is
##    never brought up to the lead (`Playout.snaps`) and no picture is skipped. The lag (WorldClient.lag, in ms and pictures, averaged over the frames) is printed. (A build whose playout
##    has no clock counts the stalls by the share alone.)
## S  The share of bups whose place before (the ids texture's, or the bytes handed over) differs from their place: on the shared path,
##    over the bups that are in both of two pictures shown one after the other (matched by id), within 0.02 of the share whose place
##    changed from the first picture to the second; on the byte handover (no ids on this side) it is printed. Either is above 0.5 (most
##    bups swim).

const FRAMES := 240
const INSTANCES := 4096
const SETTLE_MSEC := 10000

var _perf := load("res://tests/sim/perf_gates_test.gd")


func _initialize() -> void:
	_run()


func _run() -> void:
	if not SimHarness.begin(self, "slide_test", "the game screen on the real pool"):
		return
	SimConstants.apply()
	var bups := 2000000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("bups="):
			bups = int(a.substr(5))
	var start := StartConditions.new()
	start.bups = 4
	start.bup_limit = bups
	start.dish_radius = _perf.DISH_90MM
	start.nutrient_density = StartConditions.MAX_NUTRIENT_DENSITY
	start.feed_density = StartConditions.MAX_FEED_DENSITY
	start.bloom_density = 1.0
	start.tutorial = false
	start.spread_founders()
	var m: Node = TestUtil.game_screen(self, start)
	for i in 3600:
		await process_frame
		if m.is_node_ready() and m.dish != null and m.dish.row >= 0:
			break
	for i in 3600:
		if WorldClient.shared().backend.status().get("ready", false):
			break
		await process_frame
	m.toolbar.set_paused(false)
	m._set_paused(false)
	m.sim_speed = 10000.0
	_fill(m.dish, m, bups)
	for i in 3600:
		await process_frame
		if m.dish._state != null and m.dish.row >= 0:
			break
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < SETTLE_MSEC:
		await process_frame
		if m.paused:  # (the screen may pause on its own as the dish is put in again: a goal reached, the emptied row's notice)
			m.toolbar.set_paused(false)
			m._set_paused(false)
			m.sim_speed = 10000.0
	var d: Dish = m.dish
	var v: ViewRenderer = d.drawing.view
	if v == null:
		TestUtil.show(false, "the dish's view was made")
		TestUtil.finish(self, "OK slide_test")
		return
	print("     %d bups in the dish, speed reached x%.0f, density ready %s" % [d.population(), WorldClient.shared().latest().achieved_speed, v.density_ready()])
	var skipped_at: int = WorldClient.shared().picture_rate().get("skipped", 0)
	var pl0: Variant = WorldClient.shared().get("_playout")
	var snaps_at: int = pl0.snaps if pl0 != null else 0
	var mo := await _frames(d, func() -> int: return 0)
	var skipped: int = int(WorldClient.shared().picture_rate().get("skipped", 0)) - skipped_at
	var snaps: int = (pl0.snaps - snaps_at) if pl0 != null else 0
	var motion: Dictionary = mo[3]
	TestUtil.show(motion["stalls"] <= FRAMES / 50 and motion["jumps"] == 0 and skipped == 0 and snaps == 0, "M zoomed out: %d stalled frames of %d (share held at 1: %d), %d jumps (speed over 3 x the median %.2f; the fastest %.2f), %d snaps, %d pictures skipped; lag %.0f ms, %.2f pictures on average; %d new pictures" % [motion["stalls"], FRAMES, motion["at_one"], motion["jumps"], motion["median"], motion["largest"], snaps, skipped, motion["lag_ms"], motion["lag_pictures"], mo[2]])
	var z := await _frames(d, func() -> int: return _density_hash(v))
	TestUtil.show(z[0] > 0 and z[1] == z[0], "Z zoomed out: %d pairs of frames between pictures (of %d frames), the density picture changed in %d; %d new pictures" % [z[0], FRAMES, z[1], z[2]])
	var zoom: Vector2 = m.camera.zoom
	var at: Vector2 = m.camera.position
	m.camera.zoom = Vector2.ONE
	m.camera.position = d.global_position
	for i in 30:
		await process_frame
	var c := await _frames(d, func() -> int: return _instances_hash(d))
	TestUtil.show(c[0] > 0 and c[1] == c[0], "C zoomed in: %d pairs of frames between pictures (of %d frames), the instances changed in %d (%d drawn); %d new pictures" % [c[0], FRAMES, c[1], int(v._visible.get("count", -1)), c[2]])
	m.camera.zoom = zoom
	m.camera.position = at
	var s := await _shares(d)
	if s.size() == 3:
		TestUtil.show(absf(s[0] - s[1]) <= 0.02 and s[0] > 0.5, "S over %d bups in two pictures shown one after the other: place before apart from the place %.4f, really moved %.4f" % [s[2], s[0], s[1]])
	elif s.size() == 1:
		TestUtil.show(s[0] > 0.5, "S (byte handover, no ids on this side) place before apart from the place for %.4f of the bups" % s[0])
	else:
		TestUtil.show(false, "S two pictures shown one after the other were read")
	TestUtil.finish(self, "OK slide_test")


## Over FRAMES frames: [pairs of consecutive frames with the same picture and another share, of those the pairs whose `look` differs,
## new pictures, {stalls, at_one (stalls at a share of 1), jumps, median, largest (speeds: simulated s drawn a real s, or pictures a
## second without a clock), lag_ms, lag_pictures}].
func _frames(d: Dish, look: Callable) -> Array:
	var v := d.drawing.view
	var pairs := 0
	var changed := 0
	var pictures := 0
	var last_seq := -1
	var last_share := -1.0
	var last_look := 0
	var advances: Array = []
	var stalls := 0
	var at_one := 0
	var lag_ms := 0.0
	var lag_pictures := 0.0
	var speeds: Array = []
	var last_drawn := -1.0
	var usec := Time.get_ticks_usec()
	for i in FRAMES:
		await process_frame
		var dt := (Time.get_ticks_usec() - usec) / 1e6
		usec = Time.get_ticks_usec()
		var seq := v.payload().seq
		var share := d.drawing.share()
		var now: int = look.call()
		if seq == last_seq and share != last_share:
			pairs += 1
			changed += 1 if now != last_look else 0
		if seq != last_seq:
			pictures += 1
		var pl: Variant = WorldClient.shared().get("_playout")
		var drawn: float = (pl.before + share * (v.payload().sim_time - pl.before)) if pl != null and pl.before >= 0.0 else -1.0
		if i > 0:
			var advance := share - last_share if seq == last_seq else (1.0 - last_share) + share
			if drawn >= 0.0 and last_drawn >= 0.0:
				advance = drawn - last_drawn
			advances.append(advance)
			speeds.append(advance / maxf(pl.last_dt if pl != null else dt, 1e-4))
			if absf(advance) < 1e-6:
				stalls += 1
				at_one += 1 if share >= 1.0 else 0
		var lag: Dictionary = WorldClient.shared().lag() if WorldClient.shared().has_method("lag") else {"ms": 0.0, "pictures": 0.0}
		lag_ms += float(lag["ms"]) / FRAMES
		lag_pictures += float(lag["pictures"]) / FRAMES
		last_seq = seq
		last_share = share
		last_look = now
		last_drawn = drawn
	var sorted := speeds.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0
	var jumps := speeds.filter(func(a: float) -> bool: return a > 3.0 * median).size() if median > 0.0 else 0
	return [pairs, changed, pictures, {"stalls": stalls, "at_one": at_one, "jumps": jumps, "median": median,
		"largest": sorted[-1] if not sorted.is_empty() else 0.0, "lag_ms": lag_ms, "lag_pictures": lag_pictures}]


func _density_hash(v: ViewRenderer) -> int:
	var tex := v.density_texture()
	if tex == null:
		return 0
	var got := [PackedByteArray()]
	RenderingServer.call_on_render_thread(func() -> void: got[0] = RenderingServer.get_rendering_device().texture_get_data(tex.texture_rd_rid, 0))
	return hash(got[0])


func _instances_hash(d: Dish) -> int:
	var buf := RenderingServer.multimesh_get_buffer_rd_rid(d.drawing.bups_mesh.multimesh.get_rid())
	var n := mini(INSTANCES, maxi(int(d.drawing.view._visible.get("count", 0)), 0))
	if n == 0:
		return 0
	var got := [PackedByteArray()]
	RenderingServer.call_on_render_thread(func() -> void: got[0] = RenderingServer.get_rendering_device().buffer_get_data(buf, 0, n * 64))
	return hash(got[0])


## The share of bups with a place before apart from their place, and (on the shared path) the share that really moved, over the bups in
## both of two pictures shown one after the other: [before, moved, bups] ([before] on the byte handover; [] if none was read).
func _shares(d: Dish) -> Array:
	var v := d.drawing.view
	var first := {}
	var seq := v.payload().seq
	for i in 600:
		await process_frame
		if v.payload().seq != seq:
			seq = v.payload().seq
			if first.is_empty():
				first = _read(v)
			else:
				var second := _read(v)
				if second.is_empty() or first.is_empty():
					return []
				if not second.has("ids"):
					return [second["before"]]
				var at := {}
				var ids_a: PackedInt64Array = first["ids"]
				for k in ids_a.size():
					at[ids_a[k]] = k
				var both := 0
				var apart := 0
				var moved := 0
				var ids_b: PackedInt64Array = second["ids"]
				for k in ids_b.size():
					if not at.has(ids_b[k]):
						continue
					both += 1
					var here: Vector2 = second["here"][k]
					apart += 1 if here != (second["was"][k] as Vector2) else 0
					moved += 1 if here != (first["here"][at[ids_b[k]]] as Vector2) else 0
				return [float(apart) / maxf(both, 1), float(moved) / maxf(both, 1), both]
	return []


## The picture the view holds: {here, was (PackedVector2Array), ids (shared path only), before (the share apart, byte path)}.
func _read(v: ViewRenderer) -> Dictionary:
	var p := v.payload()
	if not p.bytes.is_empty():
		var apart := 0
		for k in p.count:
			if p.bytes.decode_u64(k * GpuLayout.PAYLOAD_BYTES) != p.prev_bytes.decode_u64(k * GpuLayout.PV_BYTES):
				apart += 1
		return {"before": float(apart) / maxf(p.count, 1)}
	if not v._imports.has("ids"):
		return {}
	var pay: RID = v._imports["payload"]["rids"][p.texture_index]
	var idt: RID = v._imports["ids"]["rids"][p.texture_index]
	var got := [PackedByteArray(), PackedByteArray()]
	RenderingServer.call_on_render_thread(func() -> void:
		var rd := RenderingServer.get_rendering_device()
		got[0] = rd.texture_get_data(pay, 0)
		got[1] = rd.texture_get_data(idt, 0))
	var out := {"here": PackedVector2Array(), "was": PackedVector2Array(), "ids": PackedInt64Array()}
	for k in p.count:
		var o := k * GpuLayout.IDS_BYTES
		out["here"].append(Vector2(got[0].decode_float(k * GpuLayout.PAYLOAD_BYTES), got[0].decode_float(k * GpuLayout.PAYLOAD_BYTES + 4)))
		out["was"].append(Vector2(got[1].decode_float(o + GpuLayout.IDS_PREV_X * 4), got[1].decode_float(o + GpuLayout.IDS_PREV_Y * 4)))
		out["ids"].append(got[1].decode_u32(o + GpuLayout.IDT_LO * 4) | (got[1].decode_u32(o + GpuLayout.IDT_HI * 4) << 32))
	return out


## The screen's dish put in the world again as perf_gates_test.filled_spec (`n` bups at once), as interface_gate does for gate A, with
## the dish's bloom.
func _fill(d: Dish, m: Node, n: int) -> void:
	var spec: DishSpec = _perf.filled_spec(n, _perf.DISH_90MM, d.number)
	spec.bloom_density = 1.0
	d._leave_world()
	d.radius = spec.radius
	d.resolution = spec.resolution
	d.bup_limit = spec.limit
	d.feed_density = spec.feed_density
	d.bloom_density = spec.bloom_density
	d.upkeep_factor = spec.upkeep
	d.medium_thickness = spec.medium_thickness
	d.patch_seed = spec.patch_seed
	d._reset_runtime_state()
	spec.flags = d._flags()
	d.row = WorldClient.shared().add_dish(spec)
	d.begin_at(WorldClient.shared().latest().sim_time)
	m._asked_rows[d.row] = d
