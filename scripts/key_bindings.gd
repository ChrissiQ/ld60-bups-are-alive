class_name KeyBindings
extends RefCounted
## Every key the game answers to, and the player's changes to them (kept in user://keys.cfg). Code asks for an action by its
## id (`KeyBindings.key("pause")`, `KeyBindings.matches("pause", event)`); nothing else spells out a letter. Each action has
## one rebindable key; a few fixed extras (the keypad's + and -, Shift for +) ride along with the zoom keys in the toolbar.
## The names shown to the player are in text/strings.cfg, [keys]. Escape, F1, F11 (full screen; Ctrl+Cmd+F on a Mac) and F12 are not rebindable.

const PATH := "user://keys.cfg"
## id -> default key, in the order the controls list shows them.
const DEFAULTS := {
	"pause": KEY_SPACE,
	"speed_1": KEY_1, "speed_2": KEY_2, "speed_3": KEY_3, "speed_4": KEY_4,
	"slower": KEY_BRACKETLEFT, "faster": KEY_BRACKETRIGHT,
	"tool_select": KEY_I, "tool_pan": KEY_H, "tool_nutrient": KEY_N, "tool_source": KEY_F, "tool_erase": KEY_E, "tool_plankton": KEY_P, "tool_pipette": KEY_Q,
	"zoom_out": KEY_MINUS, "zoom_in": KEY_EQUAL, "frame": KEY_HOME,
	"pan_up": KEY_W, "pan_left": KEY_A, "pan_down": KEY_S, "pan_right": KEY_D,
	"layer_medium": KEY_Z, "layer_sources": KEY_X, "layer_plankton": KEY_C, "layer_bups": KEY_V, "layer_steering": KEY_B,
	"graph_trait": KEY_T, "graph_span": KEY_G, "graph_show": KEY_Y, "details": KEY_TAB,
	"follow": KEY_R, "watch": KEY_O, "lineage": KEY_L,
}
## Keys that mean something fixed, which no action may take.
const RESERVED := [KEY_ESCAPE, KEY_F1, KEY_F11, KEY_F12, KEY_ENTER, KEY_KP_ENTER, KEY_DELETE, KEY_BACKSPACE]

static var path := PATH  ## where the changes are kept (tests point it at a scratch file)
static var _custom := {}  ## id -> key, only for the actions the player changed
static var _loaded := false
static var _listeners: Array[Callable] = []  ## called after any change (the toolbar and layers re-read their keys)


static func load_once() -> void:
	if _loaded:
		return
	_loaded = true
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return
	for id: String in DEFAULTS:
		if file.has_section_key("keys", id):
			_custom[id] = int(file.get_value("keys", id)) as Key


static func ids() -> Array:
	return DEFAULTS.keys()


static func key(id: String) -> Key:
	load_once()
	return _custom.get(id, DEFAULTS[id])


## How the key reads on screen: "Space", "I", "[".
static func label(id: String) -> String:
	return label_of(key(id))


static func label_of(code: Key) -> String:
	match code:
		KEY_BRACKETLEFT: return "["
		KEY_BRACKETRIGHT: return "]"
		KEY_EQUAL: return "+"
		KEY_MINUS: return "-"
	return OS.get_keycode_string(code)


static func matches(id: String, event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo and event.keycode == key(id)


## Gives `id` the key `code`. An action that already had that key takes this one's old key (a swap), so no key does two things.
## Returns the id that was swapped, or "". Reserved keys are refused (returns "!").
static func set_key(id: String, code: Key) -> String:
	load_once()
	if code in RESERVED:
		return "!"
	var swapped := ""
	var old := key(id)
	for other: String in DEFAULTS:
		if other != id and key(other) == code:
			swapped = other
			_custom[other] = old
	_custom[id] = code
	for changed: String in _custom.keys():  # (a key put back to its default is no change at all)
		if _custom[changed] == DEFAULTS[changed]:
			_custom.erase(changed)
	_save()
	_notify()
	return swapped


static func reset() -> void:
	load_once()
	_custom.clear()
	_save()
	_notify()


static func is_default() -> bool:
	load_once()
	return _custom.is_empty()


## Calls `listener` after every change; the caller removes it with `unlisten`.
static func listen(listener: Callable) -> void:
	if not _listeners.has(listener):
		_listeners.append(listener)


static func unlisten(listener: Callable) -> void:
	_listeners.erase(listener)


## Text with {action} marks filled with that action's key: "press {follow}" becomes "press R".
static func fill(text: String) -> String:
	if not text.contains("{"):
		return text
	for id: String in DEFAULTS:
		text = text.replace("{%s}" % id, label(id))
	return text


static func _notify() -> void:
	for listener in _listeners.duplicate():
		if listener.is_valid():
			listener.call()
		else:
			_listeners.erase(listener)


static func _save() -> void:
	var file := ConfigFile.new()
	for id: String in _custom:
		file.set_value("keys", id, int(_custom[id]))
	if _custom.is_empty():
		DirAccess.remove_absolute(path)
	else:
		file.save(path)
