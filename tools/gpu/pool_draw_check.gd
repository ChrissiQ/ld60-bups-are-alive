extends SceneTree
## The pooled picture kernels (record codec's neighbours) against the CPU's answers recorded in tools/gpu/golden/parity: the haze and
## steer map bytes, the probe's steering and concentration, the payload words, the thumbnail atlas; then what each costs at 2M bups.
## Run (nothing else on the GPU): tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/pool_draw_check.gd
##
## Expected, written before the first run:
## D1 every pool_* kernel of kernels_draw.gd and pool_probe_full builds on the device (rig.errors empty). [derived: ShaderSet reports
##    pipeline build failures]
## D2 haze: alpha within 1 of NutrientField::haze_bytes in every cell, RGB equal wherever either alpha is above 0. [derived: the float
##    view against the double one differs in the last bits, so a truncation boundary can move alpha by one; the view takes a cloud over the
##    CPU's block of cells, not the bups' circle: with the circle, 24 of 530 cells of a steer map were off by up to 17, all of them flat
##    cells at a cloud's cut where the gradient is float rounding]
## D3 steer map of ids 4, 10001 and 20000: alpha within 1 of bup_steer_bytes (STEER_ALPHA), RGB equal where alpha > 0. [derived: as D2,
##    plus the erfc fit's 1.2e-7 and the float central difference]
## D4 pool_probe_full at the 40 queries_info bups and the 50 medium_points: the unit direction and the chance within 1e-5 of the
##    fixture's steering (0.5 and (0,0) where it has none), the concentration within 1e-5 relative of field.read. [derived: float32 against
##    the double the CPU sums in; the erfc fit's error 1.2e-7 on a chance of at most 1]
## D5 payload: x and y within 2e-5 relative of the records; length (mass x mass_um) and angle (atan2) within one half-float ulp; colour
##    within 1 byte of Color.from_hsv; a dead bup (R_PY -2) and the texels past the count all zero; the ids in IDTEX equal the records'.
## D6 thumbnails: the counts sum to the bups alive, the most in the tile equals THUMBMAX, the atlas has alpha 255 where the count is the
##    most. [derived: the rule of the kernel]
## Cost at 2M bups (90 mm dish, 100 cells across) [to be measured]: pool_payload, pool_thumb_splat and pool_probe_full(64)
## per-bup passes; pool_view, pool_haze, pool_steer_map per cell; none of them runs in a step, they run when a picture is asked for
## (payload every frame at most).

const Rig := preload("res://tools/gpu/pool_rig.gd")
const Cost := preload("res://tools/gpu/pool_cost_check.gd")
const DIR := "res://tools/gpu/golden/parity/"
const RADIUS := 3000.0
const REPS := 20
const BUPS := 2000000
const CLOUDS := 20000

var fails := 0
var steer_ids := [4, 10001, 20000]


func _gz(name: String) -> PackedByteArray:
	var f := FileAccess.open_compressed(DIR + name, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	var b := f.get_buffer(f.get_length())
	return b


func _check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL ", what)


func _zeros(n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(maxi(n, 16))
	return b


## The probe's buffers (rows of PAYLOAD_TEX_WIDTH texels cover the dish's bups, the picture buffers a dish's cells).
func _add_buffers(rig: Rig, count: int, cells: int) -> void:
	var texels := ((count + GpuLayout.PAYLOAD_TEX_WIDTH - 1) / GpuLayout.PAYLOAD_TEX_WIDTH) * GpuLayout.PAYLOAD_TEX_WIDTH
	rig._buf("PAYLOAD", _zeros(texels * GpuLayout.PAYLOAD_BYTES))
	rig._buf("IDTEX", _zeros(texels * GpuLayout.IDT_BYTES))
	rig._buf("VIEW", _zeros(rig.cells * 4))
	rig._buf("VQ", _zeros(16))
	rig._buf("HAZEPIX", _zeros(cells * 4))
	rig._buf("STEERPIX", _zeros(cells * 4))
	rig._buf("SPQ", _zeros(4096 * 16))
	rig._buf("SPR", _zeros(4096 * 16))
	rig._buf("THUMBN", _zeros(GpuLayout.D_MAX * GpuKernelsDraw.THUMB_TILE * GpuKernelsDraw.THUMB_TILE * 4))
	rig._buf("THUMBMAX", _zeros(GpuLayout.D_MAX * 4))
	rig._buf("THUMBS", _zeros(GpuKernelsDraw.THUMB_ATLAS * GpuKernelsDraw.THUMB_ATLAS * 4))


var _sets := {}


func _go(rig: Rig, cl: int, kname: String, groups: int, a := 0.0, b := 0.0, c := 0.0, d := 0.0) -> void:
	var k: Dictionary = rig.made[kname]
	if not _sets.has(kname):
		_sets[kname] = ShaderSet.uniform_set(rig.rd, k, rig.bufs)
	rig.rd.compute_list_bind_compute_pipeline(cl, k["pipeline"])
	rig.rd.compute_list_bind_uniform_set(cl, _sets[kname], 0)
	rig.rd.compute_list_set_push_constant(cl, PackedFloat32Array([a, b, c, d]).to_byte_array(), 16)
	rig.rd.compute_list_dispatch(cl, groups, 1, 1)
	rig.rd.compute_list_add_barrier(cl)


func _run(rig: Rig, kname: String, groups: int, a := 0.0, b := 0.0, c := 0.0, d := 0.0) -> void:
	var cl := rig.rd.compute_list_begin()
	_go(rig, cl, kname, groups, a, b, c, d)
	rig.rd.compute_list_end()
	rig.rd.submit()
	rig.rd.sync()


## The clouds' lists and the snapshot the reads use.
func _prepare(rig: Rig) -> void:
	var cl := rig.rd.compute_list_begin()
	rig.dispatch(cl, "pool_snapshot", ceili(rig.cells / 64.0))
	rig.record_index(cl)
	rig.rd.compute_list_end()
	rig.rd.submit()
	rig.rd.sync()


func _initialize() -> void:
	SimConstants.apply()
	var sim := BupSim.new()
	sim.reset(RADIUS, 5)
	var field := sim.get_field()
	field.import_packed(_gz("state_field_conc.bin.gz").to_float32_array(), _gz("state_field_puffs.bin.gz").to_float32_array())
	var records := _gz("state_records.bin.gz")
	var count := records.size() / GpuLayout.RECORD_BYTES
	var st := GpuSim.State.of_field(field, RADIUS, records, SimConstants.build())
	st.dish_seed = 1
	st.limit = count + 1000
	st.feed = 0.0
	var rig := Rig.new()
	rig.make_kernels()
	_check(rig.errors.is_empty(), "D1 kernels build: " + str(rig.errors))
	for kname: String in ["pool_payload", "pool_view", "pool_haze", "pool_steer_map", "pool_probe_full", "pool_thumb_clear", "pool_thumb_splat", "pool_thumb_resolve"]:
		_check(rig.made.has(kname), "D1 " + kname + " made")
	rig.build([{"state": st, "row": 0}], {"poison": false, "delta": 20.0})
	var n: int = rig.dishes[0]["n"]
	_add_buffers(rig, count, n * n)
	# a few dead bups for D5
	var dead := [5, 777, count - 1]
	var recs := rig.read("BUPS", 0, count * GpuLayout.RECORD_BYTES).to_float32_array()
	for i: int in dead:
		recs[i * GpuLayout.RECORD_WORDS + GpuLayout.R_PY] = -2.0
	var rb := recs.to_byte_array()
	rig.rd.buffer_update(rig.bufs["BUPS"], 0, rb.size(), rb)
	_prepare(rig)
	_haze_and_steer(rig, n, count, records)
	_probe(rig, n, records)
	_payload(rig, count, records, dead)
	_thumbs(rig, count - dead.size())
	rig.release()
	_timing()
	print("POOL DRAW CHECK ", "OK" if fails == 0 else "FAILED %d" % fails)
	quit(0 if fails == 0 else 1)


func _haze_and_steer(rig: Rig, n: int, count: int, records: PackedByteArray) -> void:
	var cg := ceili(n * n / 64.0)
	_run(rig, "pool_view", cg, 0.0)
	_run(rig, "pool_haze", cg, 0.0, Cell.DETECTION_FLOOR, 0.5 * 255.0 / sqrt(10.0 * Cell.HALF_SATURATION), 0.45 * 255.0)
	var want := _gz("haze_bytes.bin.gz")
	var got := rig.read("HAZEPIX", 0, n * n * 4)
	_compare_bytes("D2 haze", got, want, n * n)
	var info := _info_lines()
	for id: int in steer_ids:
		var rec: Dictionary = RecordCodec.info_from_record(records, id - 1, SimConstants.build())
		var q := PackedFloat32Array([rec["speed"], rec["sense_range"], Dish.STEER_ALPHA, Dish.STEERING_WINDOW]).to_byte_array()
		rig.rd.buffer_update(rig.bufs["VQ"], 0, q.size(), q)
		_run(rig, "pool_steer_map", cg, 0.0)
		_compare_bytes("D3 steer %d" % id, rig.read("STEERPIX", 0, n * n * 4), _gz("steer_%d.bin.gz" % id), n * n)


func _compare_bytes(what: String, got: PackedByteArray, want: PackedByteArray, cells: int) -> void:
	_check(want.size() == cells * 4, "%s fixture size %d" % [what, want.size()])
	var worst := 0
	var rgb_bad := 0
	var set := 0
	var off := 0
	var too_high := 0
	for c in cells:
		var ga := got[c * 4 + 3]
		var wa := want[c * 4 + 3]
		worst = maxi(worst, absi(ga - wa))
		if absi(ga - wa) > 1:
			off += 1
			if ga > wa:
				too_high += 1
		if wa > 0:
			set += 1
		if (ga > 0 or wa > 0) and (got[c * 4] != want[c * 4] or got[c * 4 + 1] != want[c * 4 + 1] or got[c * 4 + 2] != want[c * 4 + 2]):
			rgb_bad += 1
	print("%s: alpha off by at most %d, rgb differs in %d cells (%d cells set); %d cells off by more than 1 (%d of them too high)" % [what, worst, rgb_bad, set, off, too_high])
	_check(worst <= 1 and rgb_bad == 0 and set > 0, what)


## [{"idx", "pos", "speed", "sense_range", "steering": Vector3}] of queries_info.txt.
func _info_lines() -> Array:
	var out := []
	var text := FileAccess.get_file_as_string(DIR + "queries_info.txt")
	var re := RegEx.create_from_string("id (\\d+) index (\\d+)")
	var cur := {}
	for line in text.split("\n"):
		var m := re.search(line)
		if m != null:
			cur = {"idx": int(m.get_string(2))}
			out.append(cur)
		elif cur.has("idx"):
			var s := line.strip_edges()
			if s.begins_with("steering Vector3("):
				cur["steering"] = str_to_var(s.get_slice(" radius2", 0).trim_prefix("steering "))
				cur["pos"] = str_to_var(s.get_slice(" pos ", 1))
			elif s.begins_with("\"speed\""):
				cur["speed"] = float(s.get_slice(": ", 1).trim_suffix(","))
			elif s.begins_with("\"sense_range\""):
				cur["sense_range"] = float(s.get_slice(": ", 1).trim_suffix(","))
	return out


func _probe(rig: Rig, n: int, records: PackedByteArray) -> void:
	var queries := PackedFloat32Array()
	var expect := []
	for it: Dictionary in _info_lines():
		queries.append_array(PackedFloat32Array([it["pos"].x, it["pos"].y, it["speed"], it["sense_range"]]))
		expect.append([it["steering"].x, it["steering"].y, it["steering"].z, NAN])
	var info_n := expect.size()
	var med := FileAccess.get_file_as_string(DIR + "medium_points.txt")
	var re := RegEx.create_from_string("point (Vector2\\([^)]*\\)) read (Vector3\\([^)]*\\)) steering_at (Vector3\\([^)]*\\))")
	for line in med.split("\n"):
		var m := re.search(line)
		if m == null:
			continue
		var p: Vector2 = str_to_var(m.get_string(1))
		var rd: Vector3 = str_to_var(m.get_string(2))
		var s: Vector3 = str_to_var(m.get_string(3))
		queries.append_array(PackedFloat32Array([p.x, p.y, 30.0, 60.0]))
		expect.append([s.x, s.y, s.z, rd.x])
	var qb := queries.to_byte_array()
	rig.rd.buffer_update(rig.bufs["SPQ"], 0, qb.size(), qb)
	_run(rig, "pool_probe_full", 1, float(expect.size()), 0.0, Dish.STEERING_WINDOW)
	var r := rig.read("SPR", 0, expect.size() * 16).to_float32_array()
	var worst := 0.0
	var worst_c := 0.0
	for i in expect.size():
		var e: Array = expect[i]
		for k in 3:
			worst = maxf(worst, absf(r[i * 4 + k] - e[k]))
		if not is_nan(e[3]):
			worst_c = maxf(worst_c, absf(r[i * 4 + 3] - e[3]) / maxf(absf(e[3]), 1e-9))
	print("D4 probe: %d queries (%d bups), steering off by at most %s, concentration relative %s" % [expect.size(), info_n, worst, worst_c])
	_check(expect.size() == 90 and worst <= 1e-5 and worst_c <= 1e-5, "D4 probe")


static func _half_ulp(v: float) -> float:
	var a := absf(v)
	if a < 6.1e-5:
		return 5.96e-8
	return pow(2.0, floorf(log(a) / log(2.0)) - 10.0)


func _payload(rig: Rig, count: int, records: PackedByteArray, dead: Array) -> void:
	_run(rig, "pool_payload", ceili(count / 64.0), 0.0)
	var texels := ((count + GpuLayout.PAYLOAD_TEX_WIDTH - 1) / GpuLayout.PAYLOAD_TEX_WIDTH) * GpuLayout.PAYLOAD_TEX_WIDTH
	var pl := rig.read("PAYLOAD", 0, texels * GpuLayout.PAYLOAD_BYTES)
	var ids := rig.read("IDTEX", 0, texels * GpuLayout.IDT_BYTES)
	var rec := records.to_float32_array()
	var mass_um := float(SimConstants.build()["mass_um"])
	var w := GpuLayout.RECORD_WORDS
	var worst_xy := 0.0
	var worst_len := 0.0
	var worst_ang := 0.0
	var worst_col := 0
	var bad := 0
	for i in texels:
		var o := i * GpuLayout.PAYLOAD_BYTES
		if i >= count or i in dead:
			for k in 4:
				if pl.decode_u32(o + k * 4) != 0:
					bad += 1
			continue
		var x := pl.decode_float(o)
		var y := pl.decode_float(o + 4)
		worst_xy = maxf(worst_xy, absf(x - rec[i * w + GpuLayout.R_X]) / maxf(absf(rec[i * w + GpuLayout.R_X]), 1.0))
		worst_xy = maxf(worst_xy, absf(y - rec[i * w + GpuLayout.R_Y]) / maxf(absf(rec[i * w + GpuLayout.R_Y]), 1.0))
		var shape := pl.decode_u32(o + 8)
		var len_v := _half(shape & 0xFFFF)
		var ang_v := _half(shape >> 16)
		var len_w := rec[i * w + GpuLayout.R_MASS] * mass_um
		var ang_w := atan2(rec[i * w + GpuLayout.R_DY], rec[i * w + GpuLayout.R_DX])
		worst_len = maxf(worst_len, absf(len_v - len_w) / _half_ulp(len_w))
		worst_ang = maxf(worst_ang, absf(ang_v - ang_w) / _half_ulp(ang_w))
		var col := Color.from_hsv(rec[i * w + GpuLayout.R_HUE], rec[i * w + GpuLayout.R_SAT], rec[i * w + GpuLayout.R_VAL])
		var cw := pl.decode_u32(o + 12)
		worst_col = maxi(worst_col, absi(int(cw >> 24) - int(roundf(col.r * 255.0))))
		worst_col = maxi(worst_col, absi(int((cw >> 16) & 255) - int(roundf(col.g * 255.0))))
		worst_col = maxi(worst_col, absi(int((cw >> 8) & 255) - int(roundf(col.b * 255.0))))
		var id := records.decode_u32(i * GpuLayout.RECORD_BYTES) | (records.decode_u32(i * GpuLayout.RECORD_BYTES + GpuLayout.R_ID_HI * 4) << 32)
		if ids.decode_u32(i * 8) != (id & 0xFFFFFFFF) or ids.decode_u32(i * 8 + 4) != (id >> 32):
			bad += 1
	print("D5 payload: x,y relative %s; length %.2f ulp; angle %.2f ulp; colour %d/255; %d words wrong" % [worst_xy, worst_len, worst_ang, worst_col, bad])
	_check(worst_xy <= 2e-5 and worst_len <= 1.0 and worst_ang <= 1.0 and worst_col <= 1 and bad == 0, "D5 payload")


static func _half(h: int) -> float:
	var s := -1.0 if (h & 0x8000) != 0 else 1.0
	var e := (h >> 10) & 31
	var m := h & 1023
	if e == 0:
		return s * m * pow(2.0, -24.0)
	return s * (1.0 + m / 1024.0) * pow(2.0, e - 15)


func _thumbs(rig: Rig, alive: int) -> void:
	var tile := GpuKernelsDraw.THUMB_TILE
	var groups := Rig.groups_for(GpuLayout.D_MAX * tile * tile)
	_run(rig, "pool_thumb_clear", groups)
	_run(rig, "pool_thumb_splat", GpuKernels.bup_groups(rig.slots))
	_run(rig, "pool_thumb_resolve", groups)
	var cnt := rig.read("THUMBN", 0, tile * tile * 4).to_int32_array()
	var most := rig.read("THUMBMAX", 0, 4).decode_u32(0)
	var total := 0
	var biggest := 0
	for v in cnt:
		total += v
		biggest = maxi(biggest, v)
	var atlas := rig.read("THUMBS", 0, GpuKernelsDraw.THUMB_ATLAS * tile * 4)
	var at_most := 0
	var lit := 0
	for ty in tile:
		for tx in tile:
			var w := atlas.decode_u32((ty * GpuKernelsDraw.THUMB_ATLAS + tx) * 4)
			if w != 0:
				lit += 1
			if (w >> 24) == 255:
				at_most += 1
	print("D6 thumbs: %d counted of %d alive, most %d (words %d), %d texels lit, %d at full alpha" % [total, alive, biggest, most, lit, at_most])
	_check(total == alive and biggest == most and lit > 0 and at_most >= 1, "D6 thumbs")


func _timing() -> void:
	var sc := StartConditions.new()
	sc.bups = 8; sc.dish_radius = 90000.0; sc.nutrient_density = 32.0; sc.feed_density = 20.0; sc.bup_limit = BUPS
	var st := Rig.make_state(self, sc, 51, 8, 0.1, CLOUDS)
	st.bups = Cost.tile_bups(st.bups, BUPS, st.radius, 51, st.constants)
	st.limit = BUPS
	_sets.clear()
	var rig := Rig.new()
	rig.make_kernels()
	rig.build([{"state": st, "row": 0, "flags": 1 << GpuLayout.DPF_ACETATE}], {"poison": false, "delta": 20.0})
	var n: int = rig.dishes[0]["n"]
	_add_buffers(rig, BUPS, n * n)
	rig.cloud_hint = CLOUDS
	_prepare(rig)
	var cg := ceili(n * n / 64.0)
	var bg := GpuKernels.bup_groups(rig.slots)
	var tg := Rig.groups_for(GpuLayout.D_MAX * GpuKernelsDraw.THUMB_TILE * GpuKernelsDraw.THUMB_TILE)
	var q := PackedFloat32Array([30.0, 60.0, Dish.STEER_ALPHA, Dish.STEERING_WINDOW]).to_byte_array()
	rig.rd.buffer_update(rig.bufs["VQ"], 0, q.size(), q)
	var timed := {}
	var plan := [["pool_payload", bg, 0.0, 0.0, 0.0, 0.0], ["pool_view", cg, 0.0, 0.0, 0.0, 0.0], ["pool_haze", cg, 0.0, 0.01, 1.0, 100.0],
		["pool_steer_map", cg, 0.0, 0.0, 0.0, 0.0], ["pool_probe_full", 1, 64.0, 0.0, Dish.STEERING_WINDOW, 0.0], ["pool_thumb_clear", tg, 0.0, 0.0, 0.0, 0.0],
		["pool_thumb_splat", bg, 0.0, 0.0, 0.0, 0.0], ["pool_thumb_resolve", tg, 0.0, 0.0, 0.0, 0.0]]
	for item: Array in plan:
		var t0 := Time.get_ticks_usec()
		var cl := rig.rd.compute_list_begin()
		for r in REPS:
			_go(rig, cl, item[0], item[1], item[2], item[3], item[4], item[5])
		rig.rd.compute_list_end()
		rig.rd.submit()
		rig.rd.sync()
		timed[item[0]] = float(Time.get_ticks_usec() - t0) / REPS
		print("cost %s: %.1f us at %d bups (%d cells)" % [item[0], timed[item[0]], BUPS, n * n])
	rig.release()

