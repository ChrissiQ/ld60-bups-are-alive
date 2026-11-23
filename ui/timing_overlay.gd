class_name TimingOverlay
extends MarginContainer
## F3 on the game screen shows how smoothly the dish in view is drawn, smoothed over the last WINDOW_MSEC and rewritten REFRESH_MSEC
## apart (see DebugHotkey, which owns the key). Its figures come from where the F12 log gets them:
## `WorldClient.picture_rate()` (pictures, holds, simulated time between them), the engine's frame rate, the frame record's
## main-thread time (`FrameRecord`), and the memory figures of the newest snapshot's timing (`memory_fraction`, `memory_need_fraction`,
## `memory_budget_bytes` and the machine's `MachineMemory` figures the memory watch reads every few seconds). A memory row whose
## figures are not known is hidden. Nothing here takes the mouse.

const WINDOW_MSEC := 1000  ## how far back the late frames are counted (as far as `WorldClient.PICTURE_WINDOW_MSEC`)
const REFRESH_MSEC := 250  ## how often the text is rewritten
const LATE_FRAMES := 1.5  ## a frame is late when it took longer than this many display frames (the refresh rate's frame, `WorldClient.display_ms`): the next refresh was missed

## The rows, top to bottom: the label's key and the key of the value's text in [debug] of strings.cfg.
const ROWS := ["pictures", "per_picture", "hold", "frames", "late", "main_thread", "pool", "need", "card", "system"]

## The memory rows, which hide when their figure is not known.
const MEMORY_ROWS := ["pool", "need", "card", "system"]
const GIB := 1073741824.0

@onready var _rows: GridContainer = $Panel/Rows

var _captions := {}  ## row name -> its caption Label
var _values := {}  ## row name -> its value's Label
var _frames: Array = []  ## [msec, length in msec] of each frame in the last WINDOW_MSEC
var _last_frame := 0  ## Time.get_ticks_msec() at the previous frame (0: none yet)
var _next_refresh := 0


func _ready() -> void:
	for row: String in ROWS:
		var caption := Label.new()
		caption.theme_type_variation = &"ReadoutLabel"
		caption.text = Strings.t("debug.overlay_%s" % row)
		_rows.add_child(caption)
		var value := Label.new()
		value.theme_type_variation = &"StatValue"
		value.size_flags_horizontal = Control.SIZE_SHRINK_END
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_rows.add_child(value)
		_values[row] = value
		_captions[row] = caption


func _process(_delta: float) -> void:
	if not visible:
		_last_frame = 0
		return
	var now := Time.get_ticks_msec()
	if _last_frame > 0:
		_frames.append([now, now - _last_frame])
	_last_frame = now
	while not _frames.is_empty() and now - int(_frames[0][0]) > WINDOW_MSEC:
		_frames.pop_front()
	if now >= _next_refresh:
		_next_refresh = now + REFRESH_MSEC
		refresh()


## Rewrites the figures from what is known now.
func refresh() -> void:
	var world := WorldClient.shared()
	var pictures: Dictionary = world.picture_rate() if world != null else {}
	var seconds_per_picture := float(pictures.get("sim_s_per_picture", 0.0))
	_write("pictures", Strings.t("debug.overlay_pictures_value", ["%.1f" % (float(pictures.get("shown", 0)) * 1000.0 / WorldClient.PICTURE_WINDOW_MSEC)]))
	# (A duration between two pictures, often well under a second at low speed, so it is in seconds, not SimClock.format's minutes.)
	_write("per_picture", Strings.t("debug.overlay_per_picture_value", ["%.3f" % seconds_per_picture if seconds_per_picture < 10.0 else "%.1f" % seconds_per_picture]))
	_write("hold", Strings.t("debug.overlay_hold_value", [int(pictures.get("longest_hold_frames", 0))]))
	_write("frames", Strings.t("debug.overlay_frames_value", ["%.0f" % Engine.get_frames_per_second()]))
	_write("late", Strings.t("debug.overlay_late_value", [int(round(late_share(world.display_ms if world != null else 0.0) * 100.0))]))
	_write("main_thread", Strings.t("debug.overlay_main_thread_value", ["%.1f" % FrameRecord.process_p95(FrameRecord.WINDOW_MSEC)]))
	var timing: Dictionary = world.latest().timing if world != null else {}
	show_memory(memory_figures(timing))


## Writes the memory rows from `figures` (`memory_figures`) and hides those it has no entry for.
func show_memory(figures: Dictionary) -> void:
	for row: String in MEMORY_ROWS:
		var known: bool = figures.has(row)
		(_values[row] as Label).visible = known
		(_captions[row] as Label).visible = known
		if known:
			var pair: Array = figures[row]
			_write(row, Strings.t("debug.overlay_memory_value", ["%.2f" % (float(pair[0]) / GIB), "%.2f" % (float(pair[1]) / GIB), int(round(float(pair[0]) / float(pair[1]) * 100.0))]))


## The memory rows a snapshot's `timing` can fill: row name -> [bytes used, bytes of the whole]. `pool` and `need` are against the pool's
## working budget; `card` is the card's own usage against the budget the system gives the process (a card with memory of its own that
## reports both); `system` is the memory in use against the installed memory where the graphics memory is the system's. No entry: not known.
static func memory_figures(timing: Dictionary) -> Dictionary:
	var out := {}
	var budget := float(timing.get("memory_budget_bytes", 0))
	if budget > 0.0:
		out["pool"] = [float(timing.get("memory_fraction", 0.0)) * budget, budget]
		out["need"] = [float(timing.get("memory_need_fraction", 0.0)) * budget, budget]
	var machine: Dictionary = (timing.get("machine", {}) as Dictionary).get("machine", {})
	var shared := int(machine.get("shared", MachineMemory.UNKNOWN))
	var card_budget := int(machine.get("card_budget", MachineMemory.UNKNOWN))
	var card_usage := int(machine.get("card_usage", MachineMemory.UNKNOWN))
	var physical := int(machine.get("physical", MachineMemory.UNKNOWN))
	var available := int(machine.get("available", MachineMemory.UNKNOWN))
	if shared == 0 and card_budget > 0 and card_usage >= 0:
		out["card"] = [card_usage, card_budget]
	elif shared == 1 and physical > 0 and available >= 0:
		out["system"] = [maxi(physical - available, 0), physical]
	return out


## The share (0 to 1) of the frames in the window that took longer than LATE_FRAMES display frames (`display_ms`; 0: not known, 60 Hz).
func late_share(display_ms: float) -> float:
	if _frames.is_empty():
		return 0.0
	var limit := LATE_FRAMES * (display_ms if display_ms > 0.0 else 1000.0 / 60.0)
	var late := 0
	for frame: Array in _frames:
		if int(frame[1]) > limit:
			late += 1
	return float(late) / _frames.size()


func _write(row: String, text: String) -> void:
	(_values[row] as Label).text = text
