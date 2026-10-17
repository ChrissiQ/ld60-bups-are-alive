class_name SaveGame
extends RefCounted
## One save slot, stored as JSON in user://.

const PATH := "user://save.json"
const VERSION := 1


static func has_save() -> bool:
	return not read().is_empty()


static func write(data: Dictionary) -> bool:
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file == null:
		push_warning("Could not write save: %s" % error_string(FileAccess.get_open_error()))
		return false
	file.store_string(JSON.stringify(data.merged({"version": VERSION})))  # without altering the caller's dictionary
	return true


## Returns {} when there is no usable save.
static func read() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not (parsed is Dictionary) or parsed.get("version") != VERSION:
		return {}
	if not (parsed.get("dish") is Dictionary) or not (parsed.get("goals") is Dictionary):
		return {}
	return parsed


static func delete() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
