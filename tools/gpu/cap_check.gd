extends SceneTree
## The GPU's population at the bup limit: a scenario (B by default) with a low limit, through the game's path (Dish.advance on the GPU, x10,000 at 60
## frames a second: nine steps a frame). Once the colony first comes within 2% of the limit, the count is read after every frame (stalling) and
## compared with the limit: the CPU holds exactly at it (a birth takes a random bup's place), the GPU trims a random share each step by
## the births it expects plus a margin (CNT[12]), so it stops just short of the limit and is over it in very few frames.
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/cap_check.gd -- [limit] [hours] [max_share_over] [scenario] > out.txt
## Prints the frames measured, the count minus the limit (mean, most over, most under), the share of frames over the limit, and whether
## that share is within max_share_over (default 0.01: under the limit in 99% of the frames).

const Tools := preload("res://tools/gpu/world_tools.gd")

var dish: Dish
var limit := 600
var hours := 8.0
var max_share_over := 0.01
var per_frame := 1000.0 / 6.0  # (x10,000 at 60 frames a second)
var reached_frame := -1
var frames := 0
var over: Array[int] = []
var finishing := 0
var scenario := "B"


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		limit = int(a[0])
	if a.size() > 1:
		hours = float(a[1])
	max_share_over = float(a[2]) if a.size() > 2 else 0.01
	if a.size() > 3:
		scenario = a[3]
	SimConstants.apply()
	dish = Tools.make_dish(self, scenario, 1, limit)
	Tools.load_onto_gpu(dish, 1)


func _count() -> int:
	var out := []
	var gpu := dish.gpu_world.gpu
	RenderingServer.call_on_render_thread(func() -> void: out.append(gpu.counts()[0]))
	return out[0]


func _process(_delta: float) -> bool:
	if finishing > 0:
		finishing += 1
		if finishing == 3:
			Tools.release(dish)
		if finishing > 6:
			dish.queue_free()
			return true
		return false
	frames += 1
	dish.advance(per_frame)
	var count := _count()
	if reached_frame < 0 and count >= 0.98 * limit:  # (the count stops a margin short of the limit, so "reached" is within 2%)
		reached_frame = frames
	if reached_frame >= 0:
		over.append(count - limit)
	if dish.time >= hours * 3600.0:
		var most := -1000000000
		var least := 1000000000
		var sum := 0
		var frames_over := 0
		for v in over:
			most = maxi(most, v)
			least = mini(least, v)
			sum += v
			frames_over += 1 if v > 0 else 0
		var share := float(frames_over) / maxf(over.size(), 1)
		var ok := over.size() > 0 and share <= max_share_over
		print("%s limit %d: reached at frame %d, %d frames measured; count - limit: mean %.1f, most over %d, most under %d; over the limit in %.2f%% of the frames (at most %.2f%%)" % [scenario, limit, reached_frame, over.size(), float(sum) / maxf(over.size(), 1), most, least, 100.0 * share, 100.0 * max_share_over])
		print("CAP CHECK " + ("OK" if ok else "FAILED"))
		finishing = 1
	return false
