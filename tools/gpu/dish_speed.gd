extends SceneTree
## The game's dish on the GPU path at playback speed, as the game screen drives it (scripts/main.gd: each frame advance(frame seconds x
## speed, FRAME_BUDGET_USEC), achieved_speed its running mean): frame times, the CPU time of advance(), steps per frame, the speed
## achieved. The dish does not draw, so the frames hold the simulation and the window only.
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/dish_speed.gd -- [scenario] [founders] [frames] [speed] [limit]

const Tools := preload("res://tools/gpu/world_tools.gd")
const FRAME_BUDGET_USEC := DishScheduler.FRAME_BUDGET_USEC
const MAX_FRAME_SECONDS := 0.1

var dish: Dish
var speed := 10000.0
var frames := 600
var frame := 0
var achieved := 1.0
var frame_ms := PackedFloat64Array()
var advance_ms := PackedFloat64Array()
var steps_total := 0
var last_usec := 0
var done_seconds := 0.0
var finishing := 0
var most_births := 0
var record_ms := PackedFloat64Array()
var idle_frames := 0  ## frames whose batch could not be queued (its event set still waiting to be read)
var most_pending := 0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var scenario: String = a[0] if a.size() > 0 else "D"
	var founders := int(a[1]) if a.size() > 1 else 250
	frames = int(a[2]) if a.size() > 2 else 600
	speed = float(a[3]) if a.size() > 3 else 10000.0
	var limit := int(a[4]) if a.size() > 4 else 0
	SimConstants.apply()
	dish = Dish.new()
	root.add_child(dish)
	dish.process_mode = Node.PROCESS_MODE_DISABLED
	dish.set_seed(3)
	var sc := Tools.start_conditions(scenario, limit)
	sc.bups = founders
	sc.spread_founders()
	dish.strike(sc)
	Tools.load_onto_gpu(dish, 3)
	print("dish %s: %d founders, limit %d, radius %.0f µm, %d cells across, speed x%.0f, frames %d, the GPU's %s" % [scenario, dish.population(), dish.bup_limit, dish.radius, dish.field.get_size(), speed, frames, dish.gpu_world.device_name()])


static func _pct(values: PackedFloat64Array, share: float) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[mini(sorted.size() - 1, int(share * sorted.size()))]


static func _mean(values: PackedFloat64Array) -> float:
	var total := 0.0
	for v in values:
		total += v
	return total / maxf(values.size(), 1)


func _process(delta: float) -> bool:
	if finishing > 0:
		finishing += 1
		if finishing == 3:
			Tools.release(dish)
		return finishing > 6
	var now := Time.get_ticks_usec()
	if last_usec > 0:
		frame_ms.append((now - last_usec) / 1000.0)
	last_usec = now
	var real := minf(delta, MAX_FRAME_SECONDS)
	var t0 := Time.get_ticks_usec()
	var done := dish.advance(real * speed, FRAME_BUDGET_USEC)
	advance_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
	record_ms.append(dish.gpu_world.record_usec / 1000.0)
	if done <= 0.0:
		idle_frames += 1
	most_pending = maxi(most_pending, dish.gpu_world.pending_batches())
	steps_total += roundi(done / maxf(real * speed / maxi(1, ceili(real * speed / Dish.MAX_STEP)), 1e-9)) if done > 0.0 else 0
	done_seconds += done
	if real > 0.0:
		achieved = lerpf(achieved, done / real, 0.1)
	frame += 1
	most_births = maxi(most_births, dish.gpu_world._last_births)
	if frame <= 10 or frame % 100 == 0:
		print("  frame %d: births in the last batch read %d (room %d), steps %d" % [frame, dish.gpu_world._last_births, dish.gpu_world.gpu.event_capacity, roundi(done / maxf(real * speed / maxi(1, ceili(real * speed / Dish.MAX_STEP)), 1e-9)) if done > 0.0 else 0])
	if frame % 100 == 0:
		var recent := frame_ms.slice(maxi(0, frame_ms.size() - 100))
		print("frame %d: achieved x%.0f, frames %.2f ms mean / %.2f p95, advance %.2f ms mean, bups %d, sim %.2f h" % [frame, achieved, _mean(recent), _pct(recent, 0.95), _mean(advance_ms.slice(maxi(0, advance_ms.size() - 100))), dish.population(), dish.time / 3600.0])
	if frame >= frames:
		var steady := frame_ms.slice(mini(30, frame_ms.size() - 1))
		print("RESULT achieved x%.0f (asked x%.0f), sim %.2f h in %d frames, frame ms mean %.2f p50 %.2f p95 %.2f max %.2f, advance ms mean %.3f max %.2f (of it recording the batch %.3f, applying family events %.3f), steps/frame %.2f, most births in a batch %d, frames with no batch %d, most batches pending %d, bups %d, overflows %s" % [achieved, speed, dish.time / 3600.0, frame, _mean(steady), _pct(steady, 0.5), _pct(steady, 0.95), _pct(steady, 1.0), _mean(advance_ms), _pct(advance_ms, 1.0), _mean(record_ms), dish.gpu_world.apply_usec / 1000.0 / frame, float(steps_total) / frame, most_births, idle_frames, most_pending, dish.population(), str(dish.gpu_world.overflows())])
		finishing = 1
	return false
