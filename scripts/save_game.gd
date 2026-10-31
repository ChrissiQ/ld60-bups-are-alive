class_name SaveGame
extends RefCounted
## One save slot, stored as JSON in user://. Its layout: `version`, `dish` (a dish blob as `DishCodec.write_blob` makes it, which carries the
## dish's family records, history and watch list) and `goals` (`GoalTracker.to_dict`). The functions take a path so that a test can use a
## scratch file.

const PATH := "user://save.json"
const VERSION := 3  ## a save of another version is taken for no save at all (it is never read, and the next one overwrites it)


static func has_save(path := PATH) -> bool:
	return not read(path).is_empty()


static func write(data: Dictionary, path := PATH) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Could not write save: %s" % error_string(FileAccess.get_open_error()))
		return false
	file.store_string(JSON.stringify(data.merged({"version": VERSION})))  # without altering the caller's dictionary
	return true


## Returns {} when there is no usable save.
static func read(path := PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or parsed.get("version") != VERSION:
		return {}
	if not (parsed.get("dish") is Dictionary) or not (parsed.get("goals") is Dictionary):
		return {}
	if not Validate.is_number(parsed["dish"].get("format")) or int(parsed["dish"]["format"]) != DishCodec.FORMAT:
		return {}  # (a dish of another format is never read: the title screen does not offer it)
	return parsed


static func delete(path := PATH) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
