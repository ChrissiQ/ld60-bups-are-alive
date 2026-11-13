extends SceneTree
## Where the pooled world's graphics memory runs out on the machine it runs on (the memory budget's rule; macOS: it reads `vm_stat`, `footprint` and `sysctl`). Windowed, through the run lock, one mode a run:
##   RUN_TIMEOUT=900 tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/mem_check.gd -- <mode> [stage] [stages]
## modes: info (what the machine reports), slots (bups added `stage` thousand a time in one pool), dishes (empty 400x400 dishes added `stage` at a time),
## bigbuf (single buffers and a growth by copy, to see what a big buffer costs while it is made and after it is freed).
## The game's own needs, on the real game screen at x10,000 (the arena's bytes, both devices' memory and the process footprint at each sample):
## title (the menu), default (a dish of the default size and limit, run to its limit), ten (ten of them), big (the largest dish the interface allows,
## run towards its limit: `stage` = the most real seconds to run, default 900). Stop rules S1 and S2 are checked about once a second while they run.
##
## Stop rules, written before any run (a stage is refused before it is made, a stage that breaks one ends the run):
##  S1 the system's available memory (free + inactive + speculative + purgeable) after the stage's expected growth must stay at least RESERVE (a share of the physical memory);
##  S2 swap in use may not rise by more than 256 MB over the start, and pageouts by no more than 2,000 pages;
##  S3 a step's time per million bups (slots mode) or per dish (dishes mode) more than 3x the median of the stages before it ends the run;
##  S4 the footprint added may not pass 1.3x what the arena's bytes, the renderer's baseline and one growth's copy account for;
##  S5 the arena may not pass HARD_CEILING bytes (a share of the physical memory). Each stage steps its dishes 20 steps twice.
## Expected bytes of each stage: `SimArena.estimate_bytes` at the capacities `slot_cap_for` will make, printed before the stage runs.

const RESERVE_SHARE := 0.2  ## of the physical memory the system reports: what must stay available
const CEILING_SHARE := 0.55  ## of the physical memory: the most the arena may hold
const SWAP_RISE := 256.0 * 1048576.0
const PAGEOUTS_RISE := 2000
const SLOW_FACTOR := 3.0
const FOOTPRINT_FACTOR := 1.3
const GIB := 1073741824.0

var _reserve := 0.0
var _ceiling := 0.0
var _page := 16384
var _base_swap := 0.0
var _base_pageouts := 0
var _base_footprint := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var mode := String(args[0]) if args.size() > 0 else "info"
	var stage := int(args[1]) if args.size() > 1 else 250
	var stages := int(args[2]) if args.size() > 2 else 40
	var physical := float(OS.get_memory_info().get("physical", 0))
	_reserve = RESERVE_SHARE * physical
	_ceiling = CEILING_SHARE * physical
	SimConstants.apply()
	var is_game := mode in ["title", "default", "ten", "big"]
	if not is_game:
		_info()
	_base_swap = _swap_used()
	_base_pageouts = int(_vm().get("pageouts", 0))
	_base_footprint = _footprint()
	print("BASE footprint %.0f MB, available %.2f GiB, swap used %.0f MB, pageouts %d" % [_base_footprint / 1048576.0, float(_vm()["available"]) / GIB, _base_swap / 1048576.0, _base_pageouts])
	if is_game:
		_game(mode, stage if args.size() > 1 else 900)
		return
	match mode:
		"slots": _slots(stage * 1000, stages)
		"dishes": _dishes(stage, stages)
		"bigbuf": _bigbuf()
		"fill": _fill(stage)
	print("DONE %s" % mode)
	quit(0)


func _exec(cmd: String, args: Array) -> String:
	var out := []
	OS.execute(cmd, args, out)
	return String(out[0]) if out.size() > 0 else ""


func _vm() -> Dictionary:
	var d := {}
	var text := _exec("/usr/bin/vm_stat", [])
	var first := text.get_slice("\n", 0)
	var m := RegEx.create_from_string("page size of (\\d+)").search(first)
	if m != null:
		_page = int(m.get_string(1))
	var rx := RegEx.create_from_string("^(.+?):\\s+(\\d+)\\.")
	for line in text.split("\n"):
		var r := rx.search(line)
		if r != null:
			d[r.get_string(1)] = int(r.get_string(2))
	var avail := (int(d.get("Pages free", 0)) + int(d.get("Pages inactive", 0)) + int(d.get("Pages speculative", 0)) + int(d.get("Pages purgeable", 0))) * _page
	return {"available": avail, "free": int(d.get("Pages free", 0)) * _page, "compressor": int(d.get("Pages occupied by compressor", 0)) * _page, "pageouts": int(d.get("Pageouts", 0))}


func _swap_used() -> float:
	var m := RegEx.create_from_string("used = ([\\d.]+)M").search(_exec("/usr/sbin/sysctl", ["-n", "vm.swapusage"]))
	return float(m.get_string(1)) * 1048576.0 if m != null else 0.0


func _footprint() -> float:
	var m := RegEx.create_from_string("Footprint:\\s+([\\d.]+)\\s*(KB|MB|GB)").search(_exec("/usr/bin/footprint", ["-p", str(OS.get_process_id())]))
	if m == null:
		return -1.0
	var unit := {"KB": 1024.0, "MB": 1048576.0, "GB": GIB}[m.get_string(2)] as float
	return float(m.get_string(1)) * unit


func _pressure() -> String:
	var m := RegEx.create_from_string("free percentage: (\\d+)%").search(_exec("/usr/bin/memory_pressure", []))
	return m.get_string(1) + "% free" if m != null else "?"


## What the machine reports that the game can read.
func _info() -> void:
	var mi := OS.get_memory_info()
	print("INFO OS.get_memory_info: %s" % str(mi))
	print("INFO adapter: %s %s, type %d (0 other, 1 integrated, 2 discrete, 3 virtual, 4 cpu)" % [RenderingServer.get_video_adapter_vendor(), RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_type()])
	print("INFO api %s %s; driver %s" % [RenderingServer.get_video_adapter_api_version(), DisplayServer.get_name(), RenderingServer.get_current_rendering_driver_name()])
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("INFO no local device")
		return
	print("INFO rd device %s | vendor %s" % [rd.get_device_name(), rd.get_device_vendor_name()])
	var methods := []
	for m in ClassDB.class_get_method_list("RenderingDevice"):
		var n := String(m["name"])
		if n.contains("memory") or n.contains("limit") or n.contains("budget") or n.contains("capab"):
			methods.append(n)
	print("INFO RenderingDevice methods: %s" % str(methods))
	var consts := []
	for c in ClassDB.class_get_integer_constant_list("RenderingDevice"):
		if String(c).begins_with("LIMIT_MAX_STORAGE") or String(c).begins_with("LIMIT_MAX_BUFFER") or String(c).begins_with("MEMORY_"):
			consts.append(c)
	print("INFO limit/memory constants: %s" % str(consts))
	for c in ["LIMIT_MAX_STORAGE_BUFFER_RANGE", "LIMIT_MAX_UNIFORM_BUFFER_SIZE", "LIMIT_MAX_TEXTURE_SIZE_2D", "LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X"]:
		if ClassDB.class_has_integer_constant("RenderingDevice", c):
			print("INFO %s = %d" % [c, rd.limit_get(ClassDB.class_get_integer_constant("RenderingDevice", c))])
	print("INFO rd memory: total %d, buffers %d, textures %d" % [rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL), rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS), rd.get_memory_usage(RenderingDevice.MEMORY_TEXTURES)])
	print("INFO RS info: video mem used %d, buffer mem used %d" % [RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)])
	print("INFO sysctl: %s" % _exec("/usr/sbin/sysctl", ["-n", "hw.memsize"]).strip_edges())


func _core() -> SimCore:
	var limits := PoolLimits.new()
	limits.memory_budget_bytes = 1 << 42
	return SimCore.new(limits)


## False (and why) when this stage's expected growth would break S1; the expected arena bytes after the growth otherwise.
func _may_grow(expected_extra: float, held: float) -> bool:
	var v := _vm()
	var left := float(v["available"]) - expected_extra * 2.0  # (a growth holds the old buffers and the new together while it copies)
	if left < _reserve:
		print("STOP S1: available %.2f GiB, the stage adds about %.2f GiB (x2 while it grows), the reserve is %.1f GiB" % [float(v["available"]) / GIB, expected_extra / GIB, _reserve / GIB])
		return false
	if held + expected_extra > _ceiling:
		print("STOP S5: the arena would pass the hard ceiling (%.2f GiB)" % (_ceiling / GIB))
		return false
	return true


func _broke(prev_times: Array, per_unit: float, arena_bytes: float, footprint: float, extra_allowed: float) -> bool:
	var swap := _swap_used()
	var v := _vm()
	if swap - _base_swap > SWAP_RISE or int(v["pageouts"]) - _base_pageouts > PAGEOUTS_RISE:
		print("STOP S2: swap %.0f MB (start %.0f), pageouts +%d" % [swap / 1048576.0, _base_swap / 1048576.0, int(v["pageouts"]) - _base_pageouts])
		return true
	if prev_times.size() >= 2:
		var s: Array = prev_times.duplicate()
		s.sort()
		var med: float = s[s.size() / 2]
		if per_unit > SLOW_FACTOR * med:
			print("STOP S3: %.3f per unit against a median of %.3f before" % [per_unit, med])
			return true
	if footprint > 0.0 and footprint - _base_footprint > FOOTPRINT_FACTOR * (arena_bytes + extra_allowed):
		print("STOP S4: footprint added %.0f MB against %.0f MB accounted" % [(footprint - _base_footprint) / 1048576.0, (arena_bytes + extra_allowed) / 1048576.0])
		return true
	return false


func _line(tag: String, n: int, core: SimCore, expected: float, t1: float, t2: float, unit_n: float) -> Dictionary:
	var fp := _footprint()
	var v := _vm()
	var rd_buf := core.rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)
	print("%s %d: slot_cap %d cell_cap %d | arena %.0f MB (expected %.0f) device buffers %.0f MB | footprint +%.0f MB | available %.2f GiB compressor %.2f GiB pressure %s swap %.0f MB | run1 %.0f ms run2 %.0f ms = %.3f ms/step, %.3f per unit | errors %d overflow %d growths %s" % [
		tag, n, core.arena.slot_cap, core.arena.cell_cap, core.arena.bytes_now() / 1048576.0, expected / 1048576.0, rd_buf / 1048576.0, (fp - _base_footprint) / 1048576.0,
		float(v["available"]) / GIB, float(v["compressor"]) / GIB, _pressure(), _swap_used() / 1048576.0, t1, t2, t2 / 20.0, t2 / 20.0 / maxf(unit_n, 1.0), core.errors.size(), int(core.overflow()), str(core.arena.growths)])
	return {"footprint": fp, "per_unit": t2 / 20.0 / maxf(unit_n, 1.0)}


func _slots(per_stage: int, stages: int) -> void:
	var core := _core()
	var h := SimHarness.new()
	h.core = core
	var total := 0
	var times := []
	for i in stages:
		var need := total + per_stage + 256
		var cap := core.arena.slot_cap_for(need)
		var expected := float(core.arena.estimate_bytes(cap, core.arena.cell_cap + 10240, core.arena.bin_cap, core.arena.cloud_cap, core.arena.husk_cap))
		var held := float(core.arena.bytes_now())
		print("PLAN stage %d: +%d bups -> %d, slots %d -> %d, expected arena %.0f MB (now %.0f MB)" % [i, per_stage, total + per_stage, core.arena.slot_cap, cap, expected / 1048576.0, held / 1048576.0])
		if not _may_grow(maxf(expected - held, 0.0), held):
			break
		var s := Scenario.small(per_stage, 60000.0).seed(i + 1)
		s.limit = int(per_stage * 1.1)
		h.add(s)
		total += per_stage
		var t0 := Time.get_ticks_usec()
		h.step(20)
		var t1 := (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		h.step(20)
		var t2 := (Time.get_ticks_usec() - t0) / 1000.0
		var r := _line("SLOTS", total, core, expected, t1, t2, total / 1e6)
		if _broke(times, r["per_unit"], float(core.arena.bytes_now()), r["footprint"], held * 0.5 + 400e6):
			break
		times.append(r["per_unit"])
		print("TIME bups(M) %.2f ms/step %.3f" % [total / 1e6, t2 / 20.0])


func _dishes(per_stage: int, stages: int) -> void:
	var core := _core()
	var h := SimHarness.new()
	h.core = core
	var total := 0
	var times := []
	for i in stages:
		var held := float(core.arena.bytes_now())
		var one := Scenario.small(0, 20000.0).with_flags({"resolution": 400})
		var cells_each := 160000 + 255
		var expected := float(core.arena.estimate_bytes(core.arena.slot_cap, core.arena.cell_cap + per_stage * cells_each, core.arena.bin_cap + per_stage * 4096, core.arena.cloud_cap, core.arena.husk_cap))
		print("PLAN stage %d: +%d dishes -> %d, expected arena at least %.0f MB (now %.0f MB)" % [i, per_stage, total + per_stage, expected / 1048576.0, held / 1048576.0])
		if not _may_grow(maxf(expected - held, 0.0), held):
			break
		for k in per_stage:
			h.add(one.copy().seed(total + k + 1))
		total += per_stage
		var t0 := Time.get_ticks_usec()
		h.step(20)
		var t1 := (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		h.step(20)
		var t2 := (Time.get_ticks_usec() - t0) / 1000.0
		var r := _line("DISHES", total, core, expected, t1, t2, float(total))
		if _broke(times, r["per_unit"], float(core.arena.bytes_now()), r["footprint"], held * 0.5 + 400e6):
			break
		times.append(r["per_unit"])
		print("TIME dishes %d ms/step %.3f" % [total, t2 / 20.0])


func _settle(rd: RenderingDevice, n := 6) -> void:
	for k in n:
		rd.submit()
		rd.sync()


## One buffer of each size (made, cleared, measured, freed, six submits, measured), then a growth by copy (the old one and the new together).
func _bigbuf() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	for gib in [0.25, 0.5, 1.0, 2.0, 3.0]:
		var n := int(gib * GIB)
		if float(_vm()["available"]) - 2.2 * n < _reserve:
			print("STOP S1 at a buffer of %.2f GiB" % gib)
			return
		var f0 := _footprint()
		var rid := rd.storage_buffer_create(n)
		var f1 := _footprint()
		rd.buffer_clear(rid, 0, n)
		rd.submit()
		rd.sync()
		var f2 := _footprint()
		var dev := rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)
		rd.free_rid(rid)
		var f3 := _footprint()
		_settle(rd)
		var f4 := _footprint()
		print("BIGBUF %.2f GiB: footprint after create %+.0f MB, after clear %+.0f MB (device buffers %.0f MB), after free %+.0f MB, six submits later %+.0f MB (all against %.0f MB before)" % [gib, (f1 - f0) / 1048576.0, (f2 - f0) / 1048576.0, dev / 1048576.0, (f3 - f0) / 1048576.0, (f4 - f0) / 1048576.0, f0 / 1048576.0])
		print("BIGBUF %.2f GiB: swap %.0f MB pageouts +%d available %.2f GiB" % [gib, _swap_used() / 1048576.0, int(_vm()["pageouts"]) - _base_pageouts, float(_vm()["available"]) / GIB])
	for gib in [0.5, 1.0, 1.5]:
		var a := int(gib * GIB)
		var b := int(gib * 1.5 * GIB)
		if float(_vm()["available"]) - 2.2 * (a + b) < _reserve:
			print("STOP S1 at a growth of %.2f GiB" % gib)
			return
		var f0 := _footprint()
		var ra := rd.storage_buffer_create(a)
		rd.buffer_clear(ra, 0, a)
		rd.submit()
		rd.sync()
		var fa := _footprint()
		var rb := rd.storage_buffer_create(b)
		rd.buffer_clear(rb, 0, b)
		rd.buffer_copy(ra, rb, 0, 0, a)
		rd.submit()
		rd.sync()
		var fb := _footprint()
		rd.free_rid(ra)
		var fc := _footprint()
		_settle(rd)
		var fd := _footprint()
		rd.free_rid(rb)
		_settle(rd)
		var fe := _footprint()
		print("GROWTH %.2f -> %.2f GiB: old %+.0f MB, with the new and the copy %+.0f MB, old freed %+.0f MB, six submits later %+.0f MB, new freed and settled %+.0f MB" % [gib, gib * 1.5, (fa - f0) / 1048576.0, (fb - f0) / 1048576.0, (fc - f0) / 1048576.0, (fd - f0) / 1048576.0, (fe - f0) / 1048576.0])


## 256 MB buffers made and cleared one after another, each followed by a reading, until a stop rule (S1 to S3, or the hard ceiling) ends it, then all
## freed and the memory read again: how the system's available memory, compressor, swap and the time of one allocation follow the held bytes.
func _fill(chunk_mb: int) -> void:
	var rd := RenderingServer.create_local_rendering_device()
	var n := chunk_mb * 1048576
	var held := []
	var times := []
	for i in 200:
		if not _may_grow(float(n), float(held.size() * n)):
			break
		var t0 := Time.get_ticks_usec()
		var rid := rd.storage_buffer_create(n)
		rd.buffer_clear(rid, 0, n)
		rd.submit()
		rd.sync()
		var t := (Time.get_ticks_usec() - t0) / 1000.0
		held.append(rid)
		var fp := _footprint()
		var v := _vm()
		print("FILL held %.2f GiB: footprint +%.0f MB | available %.2f GiB compressor %.2f GiB pressure %s swap %.0f MB pageouts +%d | allocation %.1f ms" % [held.size() * n / GIB, (fp - _base_footprint) / 1048576.0, float(v["available"]) / GIB, float(v["compressor"]) / GIB, _pressure(), _swap_used() / 1048576.0, int(v["pageouts"]) - _base_pageouts, t])
		if _broke(times, t, float(held.size() * n), fp, 400e6):
			break
		times.append(t)
	for rid in held:
		rd.free_rid(rid)
	_settle(rd, 10)
	print("FILL freed: footprint +%.0f MB, available %.2f GiB" % [(_footprint() - _base_footprint) / 1048576.0, float(_vm()["available"]) / GIB])


# ---- the game's own needs ---------------------------------------------------------------------------------------------------------

var _main: Node
var _stopped := false


func _inspect(call: Callable) -> Variant:
	var reply := WorldClient.shared().inspect(call)
	for i in 6000:
		if reply == null or reply.is_done():
			break
		await process_frame
	return reply.value() if reply != null else null


func _sample(label: String) -> void:
	var sim: Variant = await _inspect(func(core: SimCore, _r: Dictionary) -> Dictionary:
		var d := {"arena": core.arena.bytes_now(), "slots": core.arena.slot_cap, "cells": core.arena.cell_cap}
		if core.rd != null:
			d["buffers"] = core.rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS)
			d["textures"] = core.rd.get_memory_usage(RenderingDevice.MEMORY_TEXTURES)
			d["total"] = core.rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL)
		return d)
	var rd := RenderingServer.get_rendering_device()
	var v := _vm()
	var pop := 0
	var dishes := 0
	if _main != null and _main.get("dishes") != null:
		dishes = _main.dishes.size()
		for d: Dish in _main.dishes:
			pop += d.population()
	var s: Dictionary = sim if sim is Dictionary else {}
	var m_buf := rd.get_memory_usage(RenderingDevice.MEMORY_BUFFERS) / 1048576.0 if rd != null else -1.0
	var m_tex := rd.get_memory_usage(RenderingDevice.MEMORY_TEXTURES) / 1048576.0 if rd != null else -1.0
	var m_tot := rd.get_memory_usage(RenderingDevice.MEMORY_TOTAL) / 1048576.0 if rd != null else -1.0
	print("GAME %s: dishes %d bups %d | arena %.0f MB (slots %d, cells %d) | sim device buffers %.0f textures %.0f total %.0f MB | main device buffers %.0f textures %.0f total %.0f MB | footprint %.0f MB | available %.2f GiB swap %.0f MB static %.0f MB" % [
		label, dishes, pop, float(s.get("arena", 0)) / 1048576.0, int(s.get("slots", 0)), int(s.get("cells", 0)),
		float(s.get("buffers", 0)) / 1048576.0, float(s.get("textures", 0)) / 1048576.0, float(s.get("total", 0)) / 1048576.0,
		m_buf, m_tex, m_tot, _footprint() / 1048576.0, float(v["available"]) / GIB, _swap_used() / 1048576.0, OS.get_static_memory_usage() / 1048576.0])


## S1 and S2 while the game runs: false when either is broken.
func _safe() -> bool:
	var v := _vm()
	if float(v["available"]) < _reserve:
		print("STOP S1: available %.2f GiB, the reserve is %.2f GiB" % [float(v["available"]) / GIB, _reserve / GIB])
		return false
	if _swap_used() - _base_swap > SWAP_RISE or int(v["pageouts"]) - _base_pageouts > PAGEOUTS_RISE:
		print("STOP S2: swap or pageouts rose")
		return false
	return true


func _game_start(radius: float, resolution: int, limit: int, bups: int, feed: float, bloom: float) -> StartConditions:
	var s := StartConditions.new()
	s.dish_radius = radius
	s.nutrient_resolution = resolution
	s.bup_limit = limit
	s.bups = bups
	s.feed_density = feed
	s.bloom_density = bloom
	s.spread_founders()
	return s


func _game_wait_ready() -> void:
	for i in 3600:
		if _main == null or not _main.has_method("add_dish") or (_main.is_node_ready() and _main.dish != null and _main.dish.row >= 0):
			break
		await process_frame
	var w := WorldClient.shared()
	for i in 3600:
		if bool(w.backend.status().get("ready", false)):
			break
		await process_frame


func _game(mode: String, seconds: int) -> void:
	for i in 600:
		if root.is_node_ready():
			break
		await process_frame
	if mode == "title":
		_main = load(Scenes.MENU).instantiate()
		root.add_child(_main)
		await _game_wait_ready()
		for i in 240:
			await process_frame
		await _sample("title")
		quit(0)
		return
	var start := _game_start(45000.0, 100, 100000, 250, 3.0, 0.0)
	var target := 97000
	var copies := 1
	if mode == "ten":
		copies = 10
	if mode == "big":
		start = _game_start(StartConditions.MAX_DISH_RADIUS, StartConditions.MAX_NUTRIENT_RESOLUTION, StartConditions.MAX_BUP_LIMIT, 250, StartConditions.MAX_FEED_DENSITY, 0.0)
		target = 1940000
	_main = TestUtil.game_screen(self, start)
	await _game_wait_ready()
	for i in 120:
		await process_frame
	await _sample("start (one dish)")
	for i in copies - 1:
		_main.add_dish(_game_start(45000.0, 100, 100000, 250, 3.0, 0.0))
		for j in 30:
			await process_frame
	if copies > 1:
		await _sample("added %d dishes" % copies)
	_main.toolbar.set_paused(false)
	_main._set_paused(false)
	_main.sim_speed = 10000.0
	_main.achieved_speed = 10000.0
	var t0 := Time.get_ticks_msec()
	var n := 0
	while Time.get_ticks_msec() - t0 < seconds * 1000:
		await process_frame
		n += 1
		if n % 60 == 0 and not _safe():
			_stopped = true
			break
		if n % 600 == 0:
			await _sample("running %.0f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
		var low := 1 << 30
		for d: Dish in _main.dishes:
			low = mini(low, d.population())
		if low >= target and n > 300:
			break
	_main.toolbar.set_paused(true)
	_main._set_paused(true)
	for i in 120:
		await process_frame
	await _sample("end")
	print("DONE %s after %.0f s%s" % [mode, (Time.get_ticks_msec() - t0) / 1000.0, ", stopped by a stop rule" if _stopped else ""])
	quit(0)
