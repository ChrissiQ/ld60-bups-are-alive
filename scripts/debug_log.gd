class_name DebugLog
extends RefCounted
## The F12 debug log: a snapshot of the run (settings, state, the nutrient profile, the selected bup, the constants) written
## to a timestamped file with a screenshot beside it, so a problem seen in play can be diagnosed afterwards. It holds nothing
## personal (no user name, no paths). Every write prunes the folder: only recent logs are kept.

const MAX_KEPT := 20  ## the newest this many logs (each with its screenshot) are kept
const MAX_AGE_DAYS := 14  ## and none older than this
const PREFIX := "bups-"
const RIM_FRACTIONS := [0.0, 0.3, 0.6, 0.9, 0.95, 0.97, 0.985, 0.995]  ## the distances from the centre (of the radius) the nutrient is read at
const RIM_DIRECTIONS := 24  ## how many directions around the dish each is averaged over

static var directory := "user://logs"  ## (the tests use another)


## Everything worth knowing about the screen, the run and its dish (when there is one), as text. `extra` is what only the screen knows (speed, tour, goals).
static func report(dish: Dish, scene: Node, extra: Dictionary) -> String:
	var data := {
		"written": Time.get_datetime_string_from_system(false, true),
		"godot": Engine.get_version_info()["string"],
		"platform": OS.get_name(),
		"fps": Engine.get_frames_per_second(),
		"window": _window_size(),
		"scene": scene.scene_file_path if scene != null else "",
		"session": {
			"mode": Session.Mode.keys()[Session.mode],
			"load_requested": Session.load_requested,
			"tutorial_wanted": Session.tutorial_wanted,
			"free_start": Session.free_start.to_dict(),
		},
		"screen": extra,
	}
	if dish != null:
		var cells := DishGrid.cells_across(dish.radius, dish.resolution)
		data["dish"] = {
			"radius_um": dish.radius,
			"time_s": dish.time,
			"population": dish.population(),
			"bup_limit": dish.bup_limit,
			"stats": dish.population_stats(),
			"feed_density": dish.feed_density,
			"bloom_density": dish.bloom_density,
			"medium_thickness": dish.medium_thickness,
			"upkeep_factor": dish.upkeep_factor,
			"death_husks": dish.death_husks,
			"plankton_husks": dish.plankton_husks,
			"stationary_phase": dish.stationary_phase,
			"husks": _husks(dish),
			"global_position": [dish.global_position.x, dish.global_position.y],
			"history": _history(dish),
			"patch_seed": dish.patch_seed,
			"nutrients_placed": dish.nutrients_placed,
			"sources": dish.sources.size(),
			"plankton": dish.plankton.size(),
			"watched": dish.watched,
			"layers_hidden": _layers_hidden(dish),
			"pick_mode": Dish.PickMode.keys()[dish.pick_mode],
		}
		data["backend"] = backend(dish)
		data["nutrient"] = {
			"cells_across": cells,
			"max_across": dish.resolution,
			"cell_um": 2.0 * dish.radius / cells,
			"diffusion": Biology.WATER_DIFFUSION / dish.medium_thickness,
			"by_distance_from_centre": nutrient_profile(dish),
		}
		data["selected"] = _selected(dish)
	data["constants"] = _constants()
	return JSON.stringify(data, "\t", false, true)  # (in the order written here: what is looked at first comes first)


## Where the bups are simulated: the setting (a hidden field the world ignores), where they run (the world's backend: the GPU's pooled
## world, or the processor's stub, which runs nothing), whether this machine can use the GPU at all and the GPU's name.
static func backend(dish: Dish) -> Dictionary:
	var sim := WorldClient.shared().backend
	return {
		"setting": StartConditions.BACKEND_AUTO,
		"running": "gpu" if sim.can_simulate() else "cpu",
		"gpu_available": sim.can_simulate(),
		"gpu_device": sim.device_name(),
		"gpu_overflows": {},
		"steps_cap": 0,
		"record_usec": 0,
		"record_steps": 0,
		"apply_usec": 0,
		"applied_events": 0,
		"time_process": Performance.get_monitor(Performance.TIME_PROCESS),
		"draw_slots": _draw_slots(dish),
		"pick_latency_frames": {"last": 0, "max": 0},
	}


## The bups' picture's instance slots: drawn (visible), capacity (allocated), and the bups alive.
static func _draw_slots(dish: Dish) -> Dictionary:
	var mesh := dish.drawing.bups_mesh
	if mesh == null or mesh.multimesh == null:
		return {"drawn": 0, "capacity": 0, "live": dish.population()}
	return {"drawn": mesh.multimesh.visible_instance_count, "capacity": mesh.multimesh.instance_count, "live": dish.population()}


## The mean nutrient at each of RIM_FRACTIONS of the radius, averaged around the dish: where a ring or a step shows up.
static func nutrient_profile(dish: Dish) -> Dictionary:
	var out := {}
	for fraction: float in RIM_FRACTIONS:
		var total := 0.0
		for k in RIM_DIRECTIONS:
			total += dish.nutrient_reading(Vector2.from_angle(TAU * k / RIM_DIRECTIONS) * dish.radius * fraction).x
		out["%.3f" % fraction] = total / RIM_DIRECTIONS
	return out


## Writes the log (and the screenshot, when there is one) and prunes the folder. Returns the log's path, or "" if it could
## not be written.
static func write(text: String, screenshot: Image = null) -> String:
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return ""
	var stem := _free_stem()
	var path := "%s/%s.log" % [directory, stem]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(text)
	file.close()
	if screenshot != null and not screenshot.is_empty():
		screenshot.save_png("%s/%s.png" % [directory, stem])
	prune()
	return path


## Removes the logs beyond the newest MAX_KEPT and those older than MAX_AGE_DAYS (their screenshots with them). Only files
## this made are looked at.
static func prune(now := Time.get_unix_time_from_system()) -> void:
	var stems := {}
	for name in DirAccess.get_files_at(directory):
		if name.begins_with(PREFIX) and (name.ends_with(".log") or name.ends_with(".png")):
			stems[name.get_basename()] = true
	var newest_first: Array = stems.keys()
	newest_first.sort()  # (the stamp in the name sorts by time)
	newest_first.reverse()
	var oldest_allowed := now - MAX_AGE_DAYS * 86400.0
	for i in newest_first.size():
		var stem: String = newest_first[i]
		var log_path := "%s/%s.log" % [directory, stem]
		var stamped := FileAccess.get_modified_time(log_path) if FileAccess.file_exists(log_path) else 0
		if i >= MAX_KEPT or stamped < oldest_allowed:
			for extension in [".log", ".png"]:
				DirAccess.remove_absolute("%s/%s%s" % [directory, stem, extension])


static func _window_size() -> Array:
	var size := DisplayServer.window_get_size()
	return [size.x, size.y]


static func _free_stem() -> String:
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var msec := int(fmod(Time.get_unix_time_from_system(), 1.0) * 1000.0)  # (so that a log written the same second as another is named after it, never before it)
	return "%s%s-%03d" % [PREFIX, stamp, msec]


## The simulation's constants, with the long measured tables (the motion table) left as their length.
static func _constants() -> Dictionary:
	var out := {}
	var all := SimConstants.build()
	for key: String in all:
		var value: Variant = all[key]
		out[key] = "(%d numbers)" % value.size() if value is Array and value.size() > 12 else value
	return out


## The husks: how many the newest snapshot counts, and how many the layer draws (none: the pooled world publishes no picture of them).
static func _husks(dish: Dish) -> Dictionary:
	return {"count": dish.husk_count(), "drawn": 0}


## The dish's graph history: where it began, how many samples each part holds, and the newest figures.
static func _history(dish: Dish) -> Dictionary:
	var newest := {}
	for series: String in dish.history.fine:
		if not (dish.history.fine[series] as Array).is_empty():
			newest[series] = dish.history.fine[series][-1]
	return {
		"origin_s": dish.history.origin,
		"samples": dish.history.fine["pop"].size(),
		"whole_run_samples": dish.history.whole["pop"].size(),
		"whole_run_factor": dish.history.whole_factor,
		"version": dish.history.version,
		"newest": newest,
	}


static func _layers_hidden(dish: Dish) -> Array:
	var hidden := []
	for layer: String in Dish.Layer.keys():
		if not dish.layer_shown(Dish.Layer[layer]):
			hidden.append(layer)
	return hidden


static func _selected(dish: Dish) -> Dictionary:
	var info := dish.bup_info(dish.selected.bup) if dish.has_bup(dish.selected.bup) else {}
	if not info.is_empty():  # (on the GPU path a bup's info comes a few frames after it is chosen, and goes as it dies)
		info["steering_reading"] = dish.bup_steering(dish.selected.bup)
		info["nutrient_here"] = dish.nutrient_reading(info["pos"])
		return {"bup": info}
	if dish.selected.source != null:
		return {"source": dish.source_details(dish.selected.source)}
	if dish.selected.plankton != null:
		return {"plankton": dish.plankton_details(dish.selected.plankton)}
	if dish.selected.husk != Dish.NO_HUSK:
		return {"husk": dish.husk_details(dish.selected.husk)}
	return {}
