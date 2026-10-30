class_name UserSettings
extends RefCounted
## The player's own preferences, kept between runs in user://preferences.cfg and applied as the game starts: whether the
## window is full screen (F11 also flips it, on every screen), how big the interface is, and whether the game holds back
## its flicker, flashes and pulses. The Options panel (ui/options_panel.tscn) is where they are changed.

const DEFAULT_PATH := "user://preferences.cfg"
static var path := DEFAULT_PATH  ## where the preferences are kept (tests point it at a scratch file)
const SCALE_MIN := 0.6
const SCALE_MAX := 2.5
const HEADLESS_SIZE := Vector2i(1280, 720)
const LARGE_TEXT := 40  ## font sizes from this up (the titles) grow only half as fast as the rest
const ROOM_EXPONENT := 0.35  ## the room round the text grows with the interface size to this power; the text itself grows to the whole of it
const SCALE_STEP := 0.05
const SCROLL_SPEED_MIN := 0.25
const SCROLL_SPEED_MAX := 4.0
const SCROLL_SPEED_STEP := 0.25
const WINDOWS_BASE_DPI := 96.0  ## the dpi Windows reports at a display scaling of 100%
const PLEX_SIZE := 1.3  ## Plex Sans is drawn at this multiple of a theme size (and an icon of its box) at 100%
const MONO_SIZE := 1.0  ## Commit Mono looks bigger than Plex Sans at the same size, so it is drawn at the theme size itself

static var fullscreen := true
static var scroll_speed := 1.0  ## how fast the mouse wheel and a two-finger scroll move what they scroll (zoom the dish, scroll a list), as a multiple of the usual (a trackpad scrolls far more than a wheel)
static var ui_scale := 1.0
static var tray_order := PackedStringArray()  ## the names of the tray's sections, in the order the player put them (empty: the scene's own order); a section left out keeps its place after these
static var _tray_listeners: Array[Callable] = []  ## called when the tray's order changes by anything but a drag in the tray itself
static var reduce_motion_choice := "system"  ## "system" (follow the operating system's setting, the default), "on" or "off"
## Whether the game holds back its flicker, flashes and pulses: the player's choice, or the operating system's when they have not made one.
static var reduce_motion: bool:
	get:
		match reduce_motion_choice:
			"on":
				return true
			"off":
				return false
		return system_reduce_motion()
static var _loaded := false
static var _system_motion := false
static var _system_motion_at := -10000
const SYSTEM_MOTION_CACHE_MSEC := 30000  ## how long the answer of the macOS query is kept
static var _applied := false
static var native_override := -1.0  ## tests and screenshots pretend the display has this density
## The operating system's setting. Godot's own query can answer false where the system says on (seen on macOS), so macOS is also asked
## directly (a process is spawned and waited for), at most once in `SYSTEM_MOTION_CACHE_MSEC` (this is read every frame on the title screen).
static func system_reduce_motion() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	if DisplayServer.accessibility_should_reduce_animation():
		return true
	if OS.get_name() != "macOS":
		return false
	if Time.get_ticks_msec() - _system_motion_at >= SYSTEM_MOTION_CACHE_MSEC:
		_system_motion_at = Time.get_ticks_msec()
		var out := []
		_system_motion = OS.execute("/usr/bin/defaults", ["read", "com.apple.universalaccess", "reduceMotion"], out) == 0 and str(out[0]).strip_edges() == "1"
	return _system_motion
static var _designed_icons := {}  ## "Type" -> the icon width the theme was designed with
static var _designed_sizes := {}  ## "Type/name" -> the font size the theme was designed with


## Reads the file, once. Every reader asks through `load_once`, so nothing depends on which script runs first.
static func load_once() -> void:
	if _loaded:
		return
	_loaded = true
	var file := ConfigFile.new()
	if DisplayServer.get_name() != "headless" and file.load(path) == OK:  # (headless runs are tests: they are not to depend on the player's own preferences)
		fullscreen = bool(file.get_value("display", "fullscreen", fullscreen))
		ui_scale = clampf(float(file.get_value("display", "ui_scale", ui_scale)), SCALE_MIN, SCALE_MAX)
		scroll_speed = clampf(float(file.get_value("comfort", "scroll_speed", scroll_speed)), SCROLL_SPEED_MIN, SCROLL_SPEED_MAX)
		tray_order = PackedStringArray(file.get_value("interface", "tray_order", tray_order))
		reduce_motion_choice = str(file.get_value("comfort", "reduce_motion", reduce_motion_choice))
		if not reduce_motion_choice in ["system", "on", "off"]:
			reduce_motion_choice = "system"


static func set_fullscreen(on: bool) -> void:
	load_once()
	fullscreen = on
	_commit()


static func set_ui_scale(scale: float) -> void:
	load_once()
	ui_scale = clampf(snappedf(scale, SCALE_STEP), SCALE_MIN, SCALE_MAX)
	_commit()


static func set_scroll_speed(speed: float) -> void:
	load_once()
	scroll_speed = clampf(snappedf(speed, SCROLL_SPEED_STEP), SCROLL_SPEED_MIN, SCROLL_SPEED_MAX)
	_commit()


static func set_reduce_motion(choice: String) -> void:
	load_once()
	reduce_motion_choice = choice
	_commit()


## Windows that a person is not looking at keep the size they were started with: headless, started from a script (the tests and tools), or with
## `--windowed` (never full screen, whatever the saved preference says) or `--resolution`. A game started from the editor is managed even though the
## editor passes `--position` to place it.
static func _window_is_managed() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	var args := OS.get_cmdline_args()
	return not ("--resolution" in args or "--windowed" in args or "-s" in args or "--script" in args)


## The window mode when full screen is off: the one the project starts in (maximized), never the small default window.
static func _windowed_mode() -> DisplayServer.WindowMode:
	match int(ProjectSettings.get_setting("display/window/size/mode", 0)):
		0:
			return DisplayServer.WINDOW_MODE_WINDOWED
	return DisplayServer.WINDOW_MODE_MAXIMIZED


## The interface at 100% is the size an ordinary desktop program has on this screen: its text is the same number of points
## high whatever the window or the display, and a high-density display (a Retina one) shows it sharper rather than smaller.
static func native_scale() -> float:
	if native_override > 0.0:
		return native_override
	if DisplayServer.get_name() == "headless":
		return 1.0
	if OS.get_name() == "Windows":
		var screen := DisplayServer.window_get_current_screen()
		return maxf(DisplayServer.screen_get_dpi(screen) / WINDOWS_BASE_DPI, 1.0)  # (Windows reports its display scaling, 225%, as a dpi of 216)
	return maxf(DisplayServer.screen_get_scale(), 1.0)


## How the interface grows with its size setting: the text grows all the way (a size of 200% is text twice as big), but the
## room round it (paddings, gaps, the height of buttons and rows) grows only by ROOM_EXPONENT, so that bigger text does
## not make bigger buttons and panels all the way too. The window's content scale carries the room, and the theme's font
## sizes carry the rest of what the text needs.
static func layout_scale() -> float:
	return native_scale() * pow(ui_scale, ROOM_EXPONENT)


## What text grows by on top of the room: the rest of the setting.
static func _growth() -> float:
	return pow(ui_scale, 1.0 - ROOM_EXPONENT)


## What the sizes of the interface's text are multiplied by (Plex Sans), and what an icon's box is.
static func text_factor() -> float:
	return PLEX_SIZE * _growth()


## Whether a font size of the theme is for text set in Commit Mono (looked up from the font the same type uses).
static func _is_mono_size(theme: Theme, type: String, size_name: String) -> bool:
	var font_name := "font"
	match size_name:
		"normal_font_size": font_name = "normal_font"
		"bold_font_size": font_name = "bold_font"
		"mono_font_size": font_name = "mono_font"
		"font_size", "legend", "tick": font_name = "font"
		_: return false
	var font := theme.get_font(font_name, type)
	return font != null and font.resource_path.contains("CommitMono")


## Sets every font size of the project theme to its designed size times `text_factor`.
static func _scale_theme_text() -> void:
	var theme := ThemeDB.get_project_theme()
	if theme == null:
		return
	if _designed_sizes.is_empty():
		_designed_sizes["default"] = theme.default_font_size
		for type in theme.get_font_size_type_list():
			for name in theme.get_font_size_list(type):
				_designed_sizes["%s/%s" % [type, name]] = theme.get_font_size(name, type)
	for key: String in _designed_sizes:
		var designed := float(_designed_sizes[key])
		var parts := key.split("/")
		var ratio := MONO_SIZE if key != "default" and _is_mono_size(theme, parts[0], parts[1]) else PLEX_SIZE
		var size := roundi(designed * ratio * (sqrt(_growth()) if designed >= LARGE_TEXT else _growth()))  # (big display type grows by half as much: it is already big)
		if key == "default":
			theme.default_font_size = size
		else:
			theme.set_font_size(parts[1], parts[0], size)
	# Icons are something to recognise, so they grow with the text, as the text does (the room round them grows by the window's scale only).
	if _designed_icons.is_empty():
		for type in theme.get_constant_type_list():
			if theme.has_constant("icon_max_width", type):
				_designed_icons[type] = theme.get_constant("icon_max_width", type)
	for type: String in _designed_icons:
		theme.set_constant("icon_max_width", type, roundi(float(_designed_icons[type]) * text_factor()))
	# A dialog's panel leaves a strip along its top for the title, which is drawn over it: as tall as the title's text needs now that the text has been scaled.
	var title_font := theme.get_font("font", "DialogTitle")
	var strip := DialogStyle.TITLE_TOP + title_font.get_height(theme.get_font_size("font_size", "DialogTitle")) + DialogStyle.TITLE_GAP
	for type in ["AcceptDialog", "ConfirmationDialog"]:
		theme.get_stylebox("panel", type).content_margin_top = maxf(56.0, strip)


## Applies the preferences if nothing has yet (each screen asks, so that one started on its own, as the tests start them, is laid out the same).
static func ensure_applied() -> void:
	if not _applied:
		apply()


static func apply() -> void:
	_applied = true
	load_once()
	var window := (Engine.get_main_loop() as SceneTree).root
	if DisplayServer.get_name() == "headless" and window.size.x < 640:
		window.size = HEADLESS_SIZE  # (a headless window starts tiny: the tests and tools are laid out for an ordinary one)
	window.content_scale_factor = layout_scale()
	_scale_theme_text()
	if _window_is_managed():
		var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else _windowed_mode()
		if DisplayServer.window_get_mode() != mode:
			DisplayServer.window_set_mode(mode)
	elif DisplayServer.get_name() != "headless" and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)  # (a run from a script is a small window where it was put, whatever mode the project starts in)


## The key that flips full screen, as the player reads it. F11 is the system's own "Show Desktop" on a Mac (it slides the windows away and never reaches
## the game), so there it is Ctrl+Cmd+F, which is also what other Mac programs use.
static func fullscreen_key_label() -> String:
	return Strings.t("options.fullscreen_key_mac" if OS.get_name() == "macOS" else "options.fullscreen_key")


static func is_fullscreen_key(event: InputEventKey) -> bool:
	if OS.get_name() == "macOS":
		return event.keycode == KEY_F and event.ctrl_pressed and event.meta_pressed
	return event.keycode == KEY_F11


## Every preference back to what it was before the player touched it (the operating system's reduce-motion setting is followed again).
## Keeps the order the tray's sections are in (the tray is already showing it).
static func set_tray_order(order: PackedStringArray) -> void:
	load_once()
	tray_order = order
	_save()


## `listener` is called when a reset puts the tray's sections back in the scene's order.
static func listen_tray(listener: Callable) -> void:
	if not _tray_listeners.has(listener):
		_tray_listeners.append(listener)


static func unlisten_tray(listener: Callable) -> void:
	_tray_listeners.erase(listener)


static func reset() -> void:
	load_once()
	tray_order = PackedStringArray()
	for listener in _tray_listeners:
		listener.call()
	fullscreen = true
	ui_scale = 1.0
	scroll_speed = 1.0
	reduce_motion_choice = "system"
	_commit()


static func _commit() -> void:
	apply()
	_save()


## Writes the preferences without applying them (a setting the screens have already acted on, as the tray's order is when a section is dropped: applying re-lays-out the whole window).
static func _save() -> void:
	var file := ConfigFile.new()
	file.set_value("display", "fullscreen", fullscreen)
	file.set_value("display", "ui_scale", ui_scale)
	file.set_value("interface", "tray_order", tray_order)
	file.set_value("comfort", "scroll_speed", scroll_speed)
	file.set_value("comfort", "reduce_motion", reduce_motion_choice)
	file.save(path)
