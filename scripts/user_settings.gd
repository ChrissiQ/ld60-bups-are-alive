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
const ZOOM_SPEED_MIN := 0.25
const ZOOM_SPEED_MAX := 4.0
const ZOOM_SPEED_STEP := 0.25
const WINDOWS_BASE_DPI := 96.0  ## the dpi Windows reports at a display scaling of 100%
const BASE_SCALE := 1.3  ## the interface at 100% is the size the first version's 130% was: Plex Sans at its old 100% read a little too small

static var fullscreen := true
static var zoom_speed := 1.0  ## how fast the mouse wheel and a two-finger scroll zoom the dish, as a multiple of the usual (a trackpad scrolls far more than a wheel)
static var ui_scale := 1.0
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
static var _applied := false
static var native_override := -1.0  ## tests and screenshots pretend the display has this density
## The operating system's setting. Godot's own query can answer false where the system says on (seen on macOS), so macOS is also asked
## directly, at most once a second (this is read every frame on the title screen).
static func system_reduce_motion() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	if DisplayServer.accessibility_should_reduce_animation():
		return true
	if OS.get_name() != "macOS":
		return false
	if Time.get_ticks_msec() - _system_motion_at >= 1000:
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
		zoom_speed = clampf(float(file.get_value("comfort", "zoom_speed", zoom_speed)), ZOOM_SPEED_MIN, ZOOM_SPEED_MAX)
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


static func set_zoom_speed(speed: float) -> void:
	load_once()
	zoom_speed = clampf(snappedf(speed, ZOOM_SPEED_STEP), ZOOM_SPEED_MIN, ZOOM_SPEED_MAX)
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
	return native_scale() * pow(ui_scale * BASE_SCALE, ROOM_EXPONENT)


## What the sizes of the interface's text are multiplied by (Plex Sans).
static func text_factor() -> float:
	return pow(ui_scale * BASE_SCALE, 1.0 - ROOM_EXPONENT)


## ... and Commit Mono's: it looks bigger than Plex Sans at the same size, so the numbers keep the size they had before the base scale went up (the window's
## content scale already makes everything bigger by the room factor, so the sizes here take that back out).
static func mono_text_factor() -> float:
	return ui_scale / pow(ui_scale * BASE_SCALE, ROOM_EXPONENT)


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
		var factor := mono_text_factor() if key != "default" and _is_mono_size(theme, parts[0], parts[1]) else text_factor()
		var size := roundi(designed * (pow(factor, 0.5) if designed >= LARGE_TEXT else factor))  # (big display type grows by half as much: it is already big)
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
	return "Ctrl+Cmd+F" if OS.get_name() == "macOS" else "F11"


static func is_fullscreen_key(event: InputEventKey) -> bool:
	if OS.get_name() == "macOS":
		return event.keycode == KEY_F and event.ctrl_pressed and event.meta_pressed
	return event.keycode == KEY_F11


## Every preference back to what it was before the player touched it (the operating system's reduce-motion setting is followed again).
static func reset() -> void:
	load_once()
	fullscreen = true
	ui_scale = 1.0
	zoom_speed = 1.0
	reduce_motion_choice = "system"
	_commit()


static func _commit() -> void:
	apply()
	var file := ConfigFile.new()
	file.set_value("display", "fullscreen", fullscreen)
	file.set_value("display", "ui_scale", ui_scale)
	file.set_value("comfort", "zoom_speed", zoom_speed)
	file.set_value("comfort", "reduce_motion", reduce_motion_choice)
	file.save(path)
