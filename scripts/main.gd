extends Node2D

const BANNER_SECONDS := 4.0
const MAX_FRAME_SECONDS := 0.1  ## the longest frame the sim will catch up on, so a hitch can't snowball
const LIVE_TEXT_MSEC := 100  ## at high playback speed the readouts are rewritten this often at most: faster is a flicker, not information
const LIVE_TEXT_FROM_SPEED := 100.0  ## the playback speed from which that applies
const FRAME_BUDGET_USEC := 9000  ## the most time the simulation may spend per frame; past it the sim falls behind its speed instead of the game stuttering
const ZOOM_MIN := 0.002  ## low enough to fit the largest dish (90000 µm in radius) in a window
const ZOOM_MAX := 12.0  ## close enough that a bup (a few µm) fills a good part of the window
const ZOOM_BUTTON_STEP := 1.25
const ZOOM_WHEEL_STEP := 1.1
const ZOOM_PINCH_GAIN := 1.0  ## a trackpad pinch zooms by its own factor, to this power
const ZOOM_TRACKPAD_SCROLL := 0.05  ## a two-finger scroll zooms by ZOOM_WHEEL_STEP to the power of this for each unit it moves
const WATCH_ICON := preload("res://icons/watch.svg")
const UNWATCH_ICON := preload("res://icons/unwatch.svg")
const PAN_KEY_PIXELS := 600.0  ## screen pixels a second the view moves while a pan key (W, A, S or D) is held
const RATE_PANEL_GAP := 16.0  ## screen pixels between the readout and the feed and bloom box under it
const FIT_MARGIN := 40.0  ## screen pixels kept clear at the sides when framing the dish
const TOOLBAR_CLEARANCE := 120.0  ## screen pixels kept clear above the dish for the toolbars
const TUTORIAL_ZOOM := 6.0  ## how close the tutorial brings the camera to a bup it asks the player to click
const TUTORIAL_BUP_PIXELS := 18.0  ## the lit square round that bup is this far out on each side
const PICK_SLACK_PIXELS := 4.0  ## how far outside a bup (in screen pixels) still counts as pointing at it

@onready var dish: Dish = $Dish
@onready var camera: Camera2D = $Camera
@onready var hud: RichTextLabel = $HUD/Readout
@onready var goal_panel: RichTextLabel = $HUD/GoalPanel
@onready var banner: Label = $HUD/Banner
@onready var graph: Control = $HUD/Graph
@onready var toolbar: Toolbar = $HUD/Toolbars/Toolbar
@onready var tool_options: ToolOptions = $HUD/Toolbars/ToolOptions
@onready var rate_panel: PanelContainer = $HUD/RatePanel  ## under the readout: the two ways nutrient arrives by itself
@onready var feed_row: SettingRow = $HUD/RatePanel/Rows/FeedRow
@onready var bloom_row: SettingRow = $HUD/RatePanel/Rows/BloomRow  ## how often plankton appear
@onready var info_panel: PanelContainer = $HUD/InfoPanel
@onready var info_text: RichTextLabel = $HUD/InfoPanel/Box/InfoText
@onready var top_row: HBoxContainer = $HUD/InfoPanel/Box/TopRow
@onready var name_row: BupNameRow = $HUD/InfoPanel/Box/TopRow/NameRow
@onready var lineage_button: Button = $HUD/InfoPanel/Box/TopRow/LineageButton
@onready var lineage_panel: PanelContainer = $HUD/LineagePanel
@onready var lineage_title: Label = $HUD/LineagePanel/Box/TitleRow/Title
@onready var lineage_back_button: Button = $HUD/LineagePanel/Box/TitleRow/BackButton
@onready var lineage_entries: VBoxContainer = $HUD/LineagePanel/Box/Scroll/Entries
@onready var source_rate_row: SettingRow = $HUD/InfoPanel/Box/SourceRate
@onready var delete_source_button: Button = $HUD/InfoPanel/Box/DeleteSource
@onready var follow_button: Button = $HUD/InfoPanel/Box/Follow
@onready var watch_button: Button = $HUD/InfoPanel/Box/TopRow/WatchButton
@onready var watch_panel: WatchPanel = $HUD/WatchPanel
@onready var tutorial: Tutorial = $TutorialLayer/Tutorial  ## the guided tour, when it is wanted (see Session.tutorial_wanted)
@onready var layers_panel: LayersPanel = $HUD/LayersPanel  ## what the dish shows: each kind of thing can be hidden
@onready var hud_layer: CanvasLayer = $HUD
@onready var pause_menu: PauseMenu = $MenuLayer/PauseMenu
@onready var pause_ring: Panel = $HUD/PauseRing

## The two modes share everything (dish, evolution, HUD, controls). Free mode differs in
## exactly three ways: no goals, no saving, and restarts use the player's start conditions.
var free_mode := Session.mode == Session.Mode.FREE
var tracker := GoalTracker.new()
var tool := Toolbar.Tool.SELECT  ## kept in step with the toolbar's selection (see _on_tool_selected)
var sim_speed := 1.0  ## seconds of simulation per real second (the toolbar sets it)
var achieved_speed := 1.0  ## what the simulation actually managed lately: lower than sim_speed when the frame budget cut a step short
var paused := false
var menu_open: bool:  ## the Escape menu is up: the game is frozen behind it and takes no input
	get:
		return pause_menu.visible
## The views the player has opened on bups, oldest first: each is {"view": "info" or "lineage", "id": a bup}.
## Escape takes the newest away; anything outside the stack (another selection, a tool) closes it all. Every bup on
## it is pinned in the simulation, so its record isn't dropped (even if it dies) while it is on the stack.
var _stack: Array[Dictionary] = []
var _lineage_shown := {}  ## what the lineage list was last built from, so it is only rebuilt when that changes
var _pointer_stamp := []  ## what the hover and placement preview were last worked out from
var _point_stamp := []  ## the same for the nutrient readout under the pointer
var _tutorial_was_paused := false  ## whether the game was held before the tour began, which it goes back to
var _tutorial_bup := -1  ## the bup the tour asked the player to pick, once it has set the view up for that (-1: it has not)
var _tutorial_watched_before: Array[int] = []  ## who was on the watch list when the tour began, so it takes off only whom it put there
var following_id := -1  ## the bup the camera is keeping in the middle of the view, or -1
var _banner_left := 0.0
var _hover_point := Vector2.ZERO  ## the spot in the dish the pointer is over, for the select tool's readout
var _hovering_point := false

# Left/middle-button press tracking, to tell a click from a drag.
var _press_button := MOUSE_BUTTON_NONE
var _press_position := Vector2.ZERO
var _dragging := false
var _drag_threshold: float = ProjectSettings.get_setting("gui/common/drag_threshold", 10)


func _ready() -> void:
	dish.extinct.connect(_on_extinct)
	tracker.goal_completed.connect(_on_goal_completed)
	toolbar.tool_selected.connect(_on_tool_selected)
	toolbar.zoom_in_requested.connect(_zoom_by.bind(ZOOM_BUTTON_STEP))
	toolbar.zoom_out_requested.connect(_zoom_by.bind(1.0 / ZOOM_BUTTON_STEP))
	dish.selection_changed.connect(_on_selection_changed)
	tool_options.pick_mode_selected.connect(_on_pick_mode_selected)
	toolbar.speed_selected.connect(func(multiplier: float) -> void:
		sim_speed = multiplier
		achieved_speed = multiplier)
	toolbar.pause_toggled.connect(_set_paused)
	pause_menu.resume_requested.connect(_close_menu)
	pause_menu.quit_requested.connect(_quit_to_menu)
	pause_menu.dish_radius_chosen.connect(_resize_dish)
	pause_menu.bup_limit_chosen.connect(dish.change_limit)
	graph.dish = dish
	banner.text = ""
	source_rate_row.configure(Dish.MIN_SOURCE_RATE, Dish.MAX_SOURCE_RATE, 0.1, 10.0, Strings.t("hud.source_rate_unit"))
	source_rate_row.value_changed.connect(_on_source_rate_changed)
	feed_row.configure(0.0, StartConditions.MAX_FEED_DENSITY, 0.1, 0.0, Strings.t("hud.rate_unit_feed"))
	feed_row.value_changed.connect(func(v: float) -> void: dish.feed_density = v)
	bloom_row.configure(0.0, StartConditions.MAX_BLOOM_DENSITY, Dish.BLOOM_DENSITY_STEP, 0.0, Strings.t("hud.rate_unit_bloom"))
	bloom_row.disabled_reason = Strings.t("hud.rate_bloom_locked")
	bloom_row.value_changed.connect(func(v: float) -> void: dish.bloom_density = v)
	delete_source_button.pressed.connect(_delete_selected_source)
	delete_source_button.focus_mode = Control.FOCUS_NONE
	follow_button.pressed.connect(_toggle_follow)
	watch_button.pressed.connect(_toggle_watch)
	lineage_back_button.pressed.connect(_step_back)
	watch_button.focus_mode = Control.FOCUS_NONE
	watch_panel.dish = dish
	layers_panel.layer_toggled.connect(dish.show_layer)
	watch_panel.bup_chosen.connect(_open_watched)
	lineage_button.pressed.connect(_open_lineage)
	follow_button.focus_mode = Control.FOCUS_NONE
	hud.resized.connect(_place_rate_panel)  # (the window changed shape)
	_on_tool_selected(toolbar.current_tool())  # the toolbar decides the starting tool
	_on_pick_mode_selected(tool_options.pick_mode())  # and its tray the starting mode
	goal_panel.visible = not free_mode  # (free mode has no goals; how its dish began is on the Escape menu)
	var data := SaveGame.read() if Session.load_requested and not free_mode else {}
	Session.load_requested = false
	if data.is_empty() or not dish.from_dict(data["dish"]):
		_restart()
	else:
		tracker.from_dict(data["goals"])
		_fit_camera()
	_sync_tool_locks()
	tutorial.closed.connect(_on_tutorial_closed)
	if Session.tutorial_wanted:
		Session.tutorial_wanted = false
		_start_tutorial.call_deferred()  # (once the screen has been laid out, so the tour can point at it)


func _exit_tree() -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


func _restart() -> void:
	_stack.clear()
	_lineage_shown = {}
	dish.selected_id = -1
	dish.strike(Session.free_start if free_mode else null)
	_fit_camera()
	if free_mode:
		toolbar.set_paused(true)  # the playground starts paused so you can set the scene


## Nutrient tools are a free-mode toy and a reward in goal mode: they unlock with experiment 2,
## so experiment 1 is about what a random supply does and experiment 2 about what a placed one does.
func _tools_unlocked() -> bool:
	return free_mode or tracker.index >= 1


func _sync_tool_locks() -> void:
	var locked := not _tools_unlocked()
	for locked_tool in [Toolbar.Tool.NUTRIENT, Toolbar.Tool.SOURCE, Toolbar.Tool.ERASE, Toolbar.Tool.PLANKTON]:
		toolbar.set_tool_locked(locked_tool, locked, Strings.t("toolbar.locked_reason"))


## A red ring around the window while paused, so it's never unclear why nothing is moving.
func _set_paused(is_paused: bool) -> void:
	paused = is_paused
	pause_ring.visible = is_paused


## Frame the whole dish below the toolbar, but never zoom in past 1:1.
func _fit_camera() -> void:
	var view := get_viewport_rect().size
	var room := minf(view.x * 0.5 - FIT_MARGIN, view.y * 0.5 - TOOLBAR_CLEARANCE)
	camera.zoom = Vector2.ONE * clampf(room / dish.radius, ZOOM_MIN, 1.0)
	camera.position = dish.global_position


## Extinct colonies aren't saved, so a wipe-out never overwrites a good save.
func save_game() -> void:
	if free_mode or dish.population() == 0:
		return
	SaveGame.write({"dish": dish.to_dict(), "goals": tracker.to_dict()})


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game()


func _process(delta: float) -> void:
	if tutorial.active and not paused:
		toolbar.set_paused(true)  # (the game waits while the tour is up, even on a step that asks the player to act)
	if not menu_open and not tutorial.active:
		_pan_with_keys(delta)
	if not paused and not menu_open:
		# The playback speed is how many seconds of simulation pass per real second.
		var frame := minf(delta, MAX_FRAME_SECONDS)
		var done := dish.advance(frame * sim_speed, FRAME_BUDGET_USEC)
		if frame > 0.0:
			achieved_speed = lerpf(achieved_speed, done / frame, 0.1)
		if not free_mode:
			tracker.update(dish, done)
	_banner_left = maxf(0.0, _banner_left - delta)
	if _banner_left == 0.0:
		banner.text = ""
	_update_pointer()
	_update_info_panel()
	_follow_selected()
	dish.refresh_drawing()
	graph.refresh()
	watch_panel.refresh()
	_update_hud()
	_sync_bloom_panel()


## What the select tool is over at a world point, under the pick mode: a bup, a source, or else the medium itself.
func _hover_dish(world: Vector2) -> void:
	dish.hover_at(world, _pick_slack())
	_hover_point = world
	_hovering_point = dish.looks_at_medium()


## Hover highlight (select tool) and the placement preview (nutrient tool).
func _update_pointer() -> void:
	# Nothing to look at again when neither the pointer, the view, the dish nor the tool has changed.
	var stamp := [get_viewport().get_mouse_position(), camera.position, camera.zoom, dish.time, dish.edit_count, dish.radius, tool, _dragging, get_viewport().gui_get_hovered_control() != null, tool_options.nutrient_count(), tool_options.brush_radius(), dish.pick_mode]
	if stamp == _pointer_stamp:
		return
	_pointer_stamp = stamp
	dish.clear_hover()
	dish.place_preview_radius = -1.0
	_hovering_point = false
	# Skip while the mouse is over the toolbar/panels, or mid-drag.
	if _dragging or get_viewport().gui_get_hovered_control() != null:
		return
	var world := get_global_mouse_position()
	if world.distance_to(dish.global_position) > dish.radius:
		return
	match tool:
		Toolbar.Tool.SELECT:
			_hover_dish(world)
		Toolbar.Tool.NUTRIENT:
			if dish.can_place_at(world):  # no ring where a click would do nothing
				dish.place_preview_pos = world
				dish.place_preview_radius = Dish.scatter_radius(tool_options.nutrient_count())
		Toolbar.Tool.SOURCE:
			if dish.can_place_at(world):
				dish.place_preview_pos = world
				dish.place_preview_radius = dish.source_draw_radius()
				dish.place_preview_marker = true  # a ring like a selection's: same size at any zoom
		Toolbar.Tool.PLANKTON:
			if dish.can_place_at(world):
				dish.place_preview_pos = world
				dish.place_preview_radius = dish.plankton_draw_radius()
				dish.place_preview_marker = true
		Toolbar.Tool.ERASE:
			dish.place_preview_pos = world
			dish.place_preview_radius = tool_options.brush_radius()
			dish.place_preview_erases = true


func _pick_slack() -> float:
	return PICK_SLACK_PIXELS / camera.zoom.x


func _update_info_panel() -> void:
	if dish.selected_id >= 0 and not dish.has_record(dish.selected_id):
		dish.selected_id = -1  # its record is gone (a restart, say)
	# A clicked bup, source or plankton is pinned to the panel. Until one is, the panel follows the pointer:
	# whatever it is over, or else the nutrient at that spot.
	var pinned := dish.has_selection()
	var bup_id: int = dish.selected_id if pinned else dish.hovered_id
	var source: NutrientSource = dish.selected_source if pinned else dish.hovered_source
	var floating: Plankton = dish.selected_plankton if pinned else dish.hovered_plankton
	var editing := dish.selected_source != null and dish.selected_id < 0
	var alive_info: Dictionary = dish.bup_info(bup_id) if bup_id >= 0 else {}  # (fetched once: the panels below are built from it)
	var dead := bup_id >= 0 and alive_info.is_empty()  # a selected bup that has died stays up, as a record
	var lineage_open: bool = bup_id >= 0 and bup_id == dish.selected_id and _stack.size() > 0 and _stack.back()["view"] == "lineage"
	info_panel.visible = (bup_id >= 0 or source != null or floating != null or (not pinned and _hovering_point)) and not lineage_open
	info_panel.theme_type_variation = &"DeceasedPanel" if dead else &"HudPanel"
	lineage_panel.visible = lineage_open
	lineage_panel.theme_type_variation = &"DeceasedPanel" if dead else &"HudPanel"
	source_rate_row.visible = editing
	delete_source_button.visible = editing
	follow_button.visible = dish.selected_id >= 0 and not dead  # a bup can be followed once it is selected, not just hovered
	var watched_now := dish.is_watched(dish.selected_id)
	watch_button.icon = UNWATCH_ICON if watched_now else WATCH_ICON  # (an eye; crossed out while the bup is on the list, as that is what pressing it does)
	watch_button.tooltip_text = Strings.t("hud.unwatch") if watched_now else Strings.t("hud.watch")
	follow_button.text = Strings.t("hud.stop_following") if following_id >= 0 else Strings.t("hud.follow")
	top_row.visible = bup_id >= 0
	lineage_button.visible = bup_id >= 0 and bup_id == dish.selected_id
	watch_button.visible = lineage_button.visible  # (alive or dead: a record can be watched too)
	if bup_id < 0:
		name_row.cancel_editing()
	if lineage_open:
		_show_lineage(bup_id)
	if bup_id >= 0:
		_point_stamp = []
		name_row.show_bup(dish, bup_id, dish.selected_id == bup_id)  # a bup can be renamed once it is clicked, not just hovered
		_set_rich(info_text, _deceased_text(dish.lineage_info(bup_id)) if dead else _info_text(alive_info), "bup %d" % bup_id)
	elif source != null:
		_point_stamp = []
		if editing:
			_show_source_rate(source)
		_set_rich_when_due(info_text, "source %d" % source.get_instance_id(), func() -> String: return _source_text(dish.source_details(source)))
	elif floating != null:
		_point_stamp = []
		_set_rich_when_due(info_text, "plankton %d" % floating.get_instance_id(), func() -> String: return _plankton_text(dish.plankton_details(floating)))
	elif _hovering_point:
		var point_stamp := [_hover_point, dish.time, dish.edit_count]
		if point_stamp != _point_stamp:  # (the readout is worked out again only when the spot or the dish has changed)
			_point_stamp = point_stamp
			_set_rich(info_text, _point_text(dish.nutrient_at(_hover_point)), "point")


## The Watch button: the selected bup goes on the watch list, or comes off it.
func _toggle_watch() -> void:
	var id := dish.selected_id
	if dish.is_watched(id):
		dish.unwatch_bup(id)
	else:
		dish.watch_bup(id)


## An entry of the watch list was clicked: that bup (living or not) in the inspect panel.
func _open_watched(id: int) -> void:
	if not dish.has_record(id):
		return
	toolbar.select_tool(Toolbar.Tool.SELECT)
	tool_options.pick_buttons[Dish.PickMode.ALL].button_pressed = true  # (a mode that skips bups would let go of it again)
	dish.selected_id = id
	following_id = -1


## Follow: the camera keeps the selected bup in the middle of the view until the player stops it,
## pans, selects something else, or the bup dies.
func _toggle_follow() -> void:
	following_id = -1 if following_id >= 0 else dish.selected_id
	_follow_selected()


func _follow_selected() -> void:
	if following_id >= 0 and (following_id != dish.selected_id or not dish.has_bup(following_id)):
		following_id = -1
	if following_id >= 0:
		camera.position = dish.bup_world_pos(following_id)


## Puts the selected source's rate in the row, without that counting as the player changing it.
func _show_source_rate(source: NutrientSource) -> void:
	if not is_equal_approx(source_rate_row.value, snappedf(source.rate, 0.1)):
		source_rate_row.set_value_silently(source.rate)


func _delete_selected_source() -> void:
	if dish.selected_source != null:
		dish.remove_source(dish.selected_source)


func _on_source_rate_changed(rate: float) -> void:
	if dish.selected_source != null:
		dish.selected_source.rate = rate


func _plankton_text(d: Dictionary) -> String:
	var offset: Vector2 = d["offset"]
	var nearest: float = d["nearest_bup"]
	return Strings.t("panel.plankton", [
		SimClock.format_minutes(int(d["age"] / 60.0)), d["units"], offset.x, offset.y, d["distance"], _concentration_text(d["concentration"]),
		_away_text(nearest),
	])


func _source_text(d: Dictionary) -> String:
	var offset: Vector2 = d["offset"]
	var nearest: float = d["nearest_bup"]
	return Strings.t("panel.source", [
		d["emitted"], offset.x, offset.y, d["distance"], _concentration_text(d["concentration"]),
		_away_text(nearest),
		Dish.SOURCE_NEARBY, d["nearby"],
	])


## A concentration in the unit the player works in: units of nutrient per square millimetre (the unit of a dose, a feed
## and a source), not the simulation's energy per square micrometre, which is far too small to read.
func _concentration_text(energy_per_um2: float) -> String:
	var units := energy_per_um2 * 1.0e6 / Dish.NUTRIENT_ENERGY
	return Strings.t("panel.concentration", [("%.1f" if units < 10.0 else "%.0f") % units])


## The medium at a spot: how much nutrient, which way it rises and how steeply (as a share of
## what is there, per 100 units), and what is near.
func _point_text(d: Dictionary) -> String:
	var offset: Vector2 = d["offset"]
	var concentration: float = d["concentration"]
	var gradient: Vector2 = d["gradient"]
	var change := gradient.length() / maxf(concentration, 1e-6) * 100.0  # the fraction it changes by over 100 units
	var slope := Strings.t("panel.gradient_flat")
	if concentration > 0.0005 and change >= 0.02:
		var compass := ["e", "se", "s", "sw", "w", "nw", "n", "ne"]  # the screen's y axis points down
		slope = Strings.t("panel.gradient_rising", [Strings.t("panel.compass_" + compass[posmod(roundi(gradient.angle() / (TAU / 8.0)), 8)]), change * 100.0])
	var source: float = d["nearest_source"]
	var bup: float = d["nearest_bup"]
	return Strings.t("panel.nutrient", [
		_concentration_text(concentration), slope, offset.x, offset.y, d["distance"],
		_away_text(source),
		_away_text(bup),
	])


## How surely a bup goes up the slope where it is (the chance that it ends up further up after a minute of swimming), in a word.
func _steering_word(chance: float) -> String:
	if chance < 0.55:
		return Strings.t("panel.steering_blind")
	if chance < 0.7:
		return Strings.t("panel.steering_faint")
	return Strings.t("panel.steering_clear") if chance < 0.9 else Strings.t("panel.steering_sure")


## How far away something is, for the panels: "none" when there is nothing of that kind in the dish.
func _away_text(distance: float) -> String:
	return Strings.t("panel.away", [distance]) if distance >= 0.0 else Strings.t("panel.none")


func _info_text(b: Dictionary) -> String:
	var text := Strings.t("panel.bup", [b["generation"], SimClock.format_minutes(b["born"]), maxi(1, roundi(b["energy"])), b["max_energy"]])  # (a living bup never reads 0)
	text += Strings.t("panel.steering", [_steering_word(b["steering"])])
	return text + _traits_text(b)


## The genes, mutations and harm of a bup (alive or dead), the same lines in either panel.
func _traits_text(b: Dictionary) -> String:
	var text := ""
	for gene: String in Genome.LABELED:
		text += Strings.t("panel.gene_line", [Genome.label(gene).rpad(5), Genome.format(gene, b[Genome.INFO_KEYS[gene]])])
	return text + Strings.t("panel.bup_tail", [b["mutations"], Genome.harm_share(b["harm"]) * 100.0])


func _deceased_text(b: Dictionary) -> String:
	var text := Strings.t("panel.deceased", [SimClock.format_minutes(b["born"]), SimClock.format_minutes(b["died"]), b["generation"], b["max_energy"]])
	return text + _traits_text(b)


## The select tool now looks at something else: a selection of a kind it no longer looks at is let go.
func _on_pick_mode_selected(mode: Dish.PickMode) -> void:
	dish.pick_mode = mode  # (which also lets go of a selection the mode doesn't look at)


func _on_tool_selected(new_tool: Toolbar.Tool) -> void:
	if new_tool != Toolbar.Tool.SELECT and (not _stack.is_empty() or dish.has_selected_thing()):
		_clear_selection()  # using another tool closes whatever was open on a bup or source
	tool = new_tool
	tool_options.show_for(tool)
	_sync_toolbar_shape()
	match tool:
		Toolbar.Tool.PAN:
			Input.set_default_cursor_shape(Input.CURSOR_DRAG)
		Toolbar.Tool.NUTRIENT, Toolbar.Tool.SOURCE, Toolbar.Tool.ERASE, Toolbar.Tool.PLANKTON:
			Input.set_default_cursor_shape(Input.CURSOR_CROSS)
		_:
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)


## Only input the GUI didn't consume arrives here, so clicks on the toolbar never reach the dish.
func _unhandled_input(event: InputEvent) -> void:
	if menu_open:  # only Escape reaches the game while the menu is up, and it closes the menu
		if UiInput.is_escape_press(event) and not pause_menu.close_controls():
			_close_menu()
		return
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)
	elif event is InputEventMagnifyGesture:  # a trackpad pinch: apart zooms in
		if not _over_hud():
			_zoom_by(pow(event.factor, ZOOM_PINCH_GAIN))
	elif event is InputEventPanGesture:  # a trackpad's two-finger scroll, which stands in for the mouse wheel (up zooms in)
		if not _over_hud():
			_zoom_by(pow(ZOOM_WHEEL_STEP, -event.delta.y * ZOOM_TRACKPAD_SCROLL))
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event)


func _on_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_T:
			graph.cycle_trait()
		KEY_G:
			graph.cycle_span()
		KEY_DELETE, KEY_BACKSPACE:
			if _tools_unlocked():
				_delete_selected_source()
		KEY_R:
			_show_banner("", 0.0)
			_restart()
		KEY_ESCAPE:
			_escape()


## Escape lets go of a selection first, and only with nothing selected opens the menu.
func _escape() -> void:
	if _stack.size() > 1:  # a lineage (or a bup reached through one) is open: back one step
		_step_back()
	elif dish.has_selection():
		_clear_selection()
	else:
		_open_menu()


## One step back through the views opened on a bup (a lineage, or a bup reached through one): what Escape does, and the
## back icon of the lineage panel.
func _step_back() -> void:
	if _stack.size() > 1:
		_set_stack(_stack.slice(0, _stack.size() - 1))
		dish.selected_id = _stack.back()["id"]


## Lets go of everything selected: the bup (with whatever views were opened on it) and any source.
func _clear_selection() -> void:
	_set_stack([])
	dish.clear_selection()
	following_id = -1


## The selection changed: one made anywhere else (a click in the dish, say) starts the stack afresh, and none closes it.
## (A change the stack itself made leaves its top as the selection, so nothing happens.)
func _on_selection_changed() -> void:
	var top_id: int = _stack.back()["id"] if not _stack.is_empty() else -1
	if dish.selected_id == top_id:
		return
	if dish.selected_id >= 0:
		_set_stack([{"view": "info", "id": dish.selected_id}])
	else:
		_set_stack([])


## Every step holds a pin on its bup (pins are counted, so a bup on two steps holds two). The new steps are pinned
## before the old are let go, so a bup staying on the stack is never unpinned in between.
func _set_stack(new_stack: Array) -> void:
	for step in new_stack:
		dish.pin_bup(step["id"])
	for step in _stack:
		dish.unpin_bup(step["id"])  # (that may drop its record, if nothing needs it now)
	_stack.assign(new_stack)


## The lineage icon: the family line of the bup on show, over its info.
func _open_lineage() -> void:
	if _stack.is_empty() or dish.selected_id < 0:
		return
	_set_stack(_stack + [{"view": "lineage", "id": dish.selected_id}])


## A name in a lineage was clicked: that bup's info, a step further on (and the bup is selected, if it is alive).
func _open_info_of(id: int) -> void:
	if not dish.has_record(id):
		return
	_set_stack(_stack + [{"view": "info", "id": id}])
	dish.selected_id = id
	following_id = -1


## Lists the family line that led to a bup (oldest first). It is rebuilt only when the line, or who in it is
## still alive, changes.
func _show_lineage(id: int) -> void:
	var chain := dish.lineage_chain(id)
	var key := []
	for ancestor in chain:
		key.append([ancestor, dish.has_bup(ancestor), dish.bup_name(ancestor)])
	if _lineage_shown.get("id") == id and _lineage_shown.get("key") == key:
		return
	_lineage_shown = {"id": id, "key": key}
	lineage_title.text = Strings.t("panel.lineage_title", [dish.bup_name(id)])
	for child in lineage_entries.get_children():
		lineage_entries.remove_child(child)
		child.queue_free()
	for k in chain.size():
		var ancestor: int = chain[k]
		var info := dish.lineage_info(ancestor)
		var line := Strings.t("panel.lineage_entry", [dish.bup_name(ancestor), SimClock.format_minutes(info["born"])])  # (the times on a second row, so nothing is cut off)
		if not info["alive"]:
			line += Strings.t("panel.lineage_died", [SimClock.format_minutes(info["died"])])
		var row := HBoxContainer.new()
		var swatch := ColorRect.new()  # the bup's colour, so a clade can be followed by eye
		swatch.color = Genome.color_of(info)
		swatch.custom_minimum_size = Vector2(14.0, 14.0)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		var entry := Button.new()
		entry.text = line
		entry.theme_type_variation = &"ListButton"
		entry.alignment = HORIZONTAL_ALIGNMENT_LEFT
		entry.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		entry.focus_mode = Control.FOCUS_NONE
		entry.disabled = ancestor == id  # the bup itself: you are looking at its line
		entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		entry.pressed.connect(_open_info_of.bind(ancestor))
		row.add_child(entry)
		lineage_entries.add_child(row)


func _open_menu() -> void:
	hud_layer.process_mode = Node.PROCESS_MODE_DISABLED  # no toolbar shortcuts or clicks behind the menu
	dish.clear_hover()
	pause_menu.open(dish, free_mode, Session.free_start)


func _close_menu() -> void:
	hud_layer.process_mode = Node.PROCESS_MODE_INHERIT
	pause_menu.close()


## The player chose another size for the dish (in the pause menu): the view stays inside it.
func _resize_dish(new_radius: float) -> void:
	dish.resize_to(new_radius)
	camera.position = camera.position.limit_length(dish.radius)


## A goal-mode experiment is saved on the way out; free mode is not saved.
func _quit_to_menu() -> void:
	save_game()
	get_tree().change_scene_to_file(Scenes.MENU)


# Click vs. drag: remember where the button went down. If the pointer travels past the
# engine's drag threshold the gesture is a pan; if the button comes back up first it is a
# click. The middle button, and the left button with the pan tool, always pan.
func _on_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed and not _over_hud():
				_zoom_by(ZOOM_WHEEL_STEP)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed and not _over_hud():
				_zoom_by(1.0 / ZOOM_WHEEL_STEP)
		MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				get_viewport().gui_release_focus()  # so keys go to shortcuts, not the nutrient box
				_press_button = event.button_index
				_press_position = event.position
				_dragging = event.button_index == MOUSE_BUTTON_MIDDLE or tool == Toolbar.Tool.PAN
			elif event.button_index == _press_button:
				if not _dragging:
					_click(make_input_local(event).position)
				_press_button = MOUSE_BUTTON_NONE
				_dragging = false


## Whether the pointer is over one of the HUD's panels or lists: a wheel or a trackpad scroll there is the list's, and
## never the zoom's, even when the list has nowhere left to scroll.
func _over_hud() -> bool:
	return get_viewport().gui_get_hovered_control() != null


func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if _press_button == MOUSE_BUTTON_NONE:
		return
	# The release may have been eaten by the GUI (or happened outside the window), so trust the
	# button state this event reports rather than waiting for a release we may never see.
	var held_mask := MOUSE_BUTTON_MASK_MIDDLE if _press_button == MOUSE_BUTTON_MIDDLE else MOUSE_BUTTON_MASK_LEFT
	if event.button_mask & held_mask == 0:
		_press_button = MOUSE_BUTTON_NONE
		_dragging = false
		return
	if not _dragging and event.position.distance_to(_press_position) > _drag_threshold:
		_dragging = true
	if _dragging:
		_pan_camera(-event.relative / camera.zoom.x)


## Moves the view by `world_delta`, but never off the dish. Panning by hand takes over from following.
func _pan_camera(world_delta: Vector2) -> void:
	following_id = -1
	camera.position = (camera.position + world_delta).limit_length(dish.radius)


## W, A, S and D move the view while held. The keys are taken by their place on the keyboard, so they are the same four
## on any layout; nothing happens while a text box has the keyboard, or with Ctrl, Alt or Cmd held (those are shortcuts).
func _pan_with_keys(delta: float) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_META):
		return
	var direction := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	if direction != Vector2.ZERO:
		_pan_camera(direction.normalized() * PAN_KEY_PIXELS * delta / camera.zoom.x)


func _click(world: Vector2) -> void:
	match tool:
		Toolbar.Tool.SELECT:
			dish.select_at(world, _pick_slack())
		Toolbar.Tool.NUTRIENT:
			dish.drop_nutrients(world, tool_options.nutrient_count())
		Toolbar.Tool.SOURCE:
			if dish.place_source(world, tool_options.source_rate()):
				# The new source is what the player will want to look at or adjust next.
				toolbar.select_tool(Toolbar.Tool.SELECT)
				tool_options.pick_buttons[Dish.PickMode.ALL].button_pressed = true  # (a mode that skips sources would hide the one just placed)
				dish.selected_id = -1
				dish.selected_source = dish.sources[-1]
			elif world.distance_to(dish.global_position) <= dish.radius:
				if dish.sources.size() >= Dish.MAX_SOURCES:
					_show_banner(Strings.t("hud.banner_source_limit"), 1.5)
				else:
					_show_banner(Strings.t("hud.banner_edge"), 1.5)
		Toolbar.Tool.PLANKTON:
			if not dish.place_plankton(world) and world.distance_to(dish.global_position) <= dish.radius:
				_show_banner(Strings.t("hud.banner_plankton_limit" if dish.plankton.size() >= Dish.MAX_PLANKTON else "hud.banner_edge"), 1.5)
		Toolbar.Tool.ERASE:
			if world.distance_to(dish.global_position) <= dish.radius:
				dish.erase_nutrient(world, tool_options.brush_radius())


## Zooms about the selected bup or source, so it stays where it is on the screen. With nothing selected, or the
## selection out of view, it zooms about the middle of the view.
func _zoom_by(factor: float) -> void:
	var old_zoom := camera.zoom.x
	camera.zoom = Vector2.ONE * clampf(old_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	var anchor: Variant = _selected_world_pos()
	if anchor != null and _on_screen(anchor, old_zoom):  # (a selection scrolled out of view is no anchor)
		camera.position = anchor - (anchor - camera.position) * old_zoom / camera.zoom.x


## Whether a world position is inside the window at this zoom.
func _on_screen(world_pos: Vector2, zoom: float) -> bool:
	var view := get_viewport_rect().size
	return Rect2(Vector2.ZERO, view).has_point((world_pos - camera.position) * zoom + view * 0.5)


## Where the selected bup or source is in the world, or null when nothing is selected.
func _selected_world_pos() -> Variant:
	if dish.has_bup(dish.selected_id):
		return dish.bup_world_pos(dish.selected_id)
	if dish.selected_source != null:
		return dish.selected_source.pos
	if dish.selected_plankton != null:
		return dish.global_position + dish.selected_plankton.pos
	return null


func _show_banner(text: String, seconds: float) -> void:
	banner.text = text
	_banner_left = seconds


func _on_goal_completed(goal: Goal) -> void:
	if tracker.index >= 1:
		dish.upkeep_factor = Dish.GOAL_UPKEEP_FACTOR  # experiment 2 and after: staying alive costs more
	toolbar.set_paused(true)  # so the colony isn't left running while the player reads and sets up what comes next
	_sync_tool_locks()
	_show_banner(Strings.t("hud.banner_complete", [goal.title]), BANNER_SECONDS)
	save_game()


func _on_extinct() -> void:
	_show_banner(Strings.t("hud.banner_extinct"), 1e9)


## The rate box sits just under the readout. The feed is always there; the bloom comes with plankton. Both follow the dish.
func _sync_bloom_panel() -> void:
	var plankton_unlocked := _tools_unlocked()
	if plankton_unlocked != bloom_row.slider.editable:  # (the bloom stays in the box, faint, until plankton unlock)
		bloom_row.set_enabled(plankton_unlocked)
	if not is_equal_approx(feed_row.value, snappedf(dish.feed_density, 0.1)):
		feed_row.set_value_silently(dish.feed_density)
	if not is_equal_approx(bloom_row.value, snappedf(dish.bloom_density, Dish.BLOOM_DENSITY_STEP)):
		bloom_row.set_value_silently(dish.bloom_density)


func _update_hud() -> void:
	if not free_mode:
		_set_rich_when_due(goal_panel, "goal", _goal_text)
	if dish.population() == 0:
		return
	var about := "hud %s" % sim_speed
	if not _readout_due(hud, about):
		return  # (nothing below is worth working out: the text would not be shown yet)
	var stats := dish.population_stats()
	var genes := ""
	for gene: String in Genome.LABELED:
		genes += "%s  %s\n" % [Genome.label(gene).rpad(5), Genome.format(gene, stats[gene])]
	if _set_rich(hud, Strings.t("hud.readout", [
		_dish_lines(), SimClock.format(dish.time), _playback_text(),
		dish.nutrients_placed, genes,
		stats["mutations"], stats["harm"] * 100.0,
	]), about):
		_place_rate_panel()  # (the readout's height changes with its text)


## The tour of the screen: what each part does, in the order a first-time player needs it, asking for a click now and then so
## that what only shows while it is in use (the info panel, the watch list, the lineage) is there to be explained.
func _start_tutorial() -> void:
	_tutorial_was_paused = paused
	_tutorial_watched_before = dish.watched.duplicate()
	toolbar.set_paused(true)
	var steps: Array[Dictionary] = []
	steps.append(_tour("welcome"))
	steps.append(_tour("dish", func() -> Rect2: return dish.get_global_transform_with_canvas() * Rect2(-dish.radius, -dish.radius, 2.0 * dish.radius, 2.0 * dish.radius)))
	steps.append(_tour("readout", func() -> Rect2: return Rect2(hud.global_position, Vector2(210.0, hud.get_content_height()))))
	if not free_mode:
		steps.append(_tour("goal", func() -> Rect2: return goal_panel.get_global_rect()))
	steps.append(_tour("rates", func() -> Rect2: return rate_panel.get_global_rect()))
	steps.append(_tour("graph", func() -> Rect2: return graph.get_global_rect()))
	steps.append(_tour("tools", func() -> Rect2: return toolbar.select_button.get_global_rect().merge(toolbar.plankton_button.get_global_rect()), Callable(), Callable(), "" if free_mode else Strings.t("tutorial.tools_locked")))
	steps.append(_tour("tray", func() -> Rect2: return tool_options.get_global_rect()))
	steps.append(_tour("time", func() -> Rect2: return toolbar.pause_button.get_global_rect().merge(toolbar.speed_ultra_button.get_global_rect())))
	steps.append(_tour("layers", func() -> Rect2: return layers_panel.get_global_rect()))
	steps.append(_tour("pick_bup", _tutorial_bup_rect, func() -> bool: return dish.selected_id >= 0, _tutorial_show_bup))
	steps.append(_tour("info", func() -> Rect2: return info_panel.get_global_rect()))
	steps.append(_tour("watch", func() -> Rect2: return watch_button.get_global_rect(), func() -> bool: return dish.is_watched(dish.selected_id)))
	steps.append(_tour("watched", func() -> Rect2: return watch_panel.get_global_rect()))
	steps.append(_tour("lineage_open", func() -> Rect2: return lineage_button.get_global_rect(), _lineage_is_open, _tutorial_close_lineage))
	steps.append(_tour("lineage", func() -> Rect2: return lineage_panel.get_global_rect(), func() -> bool: return not _lineage_is_open(), _tutorial_open_lineage))
	steps.back()["escape_passes"] = true  # (Escape closes a lineage, which is what that step asks for)
	steps.append(_tour("finish"))
	tutorial.start(steps)


## One step of the tour (see Tutorial): its text by key (with `extra` added), what it lights, what it waits for, what it does first.
func _tour(key: String, target := Callable(), wait := Callable(), enter := Callable(), extra := "") -> Dictionary:
	return {"title": Strings.t("tutorial.title_" + key), "text": Strings.t("tutorial." + key) + extra, "target": target, "wait": wait, "enter": enter}


## Brings the camera close to a bup and makes sure a click on it would select it: the step that asks for that click.
func _tutorial_show_bup() -> void:
	toolbar.select_tool(Toolbar.Tool.SELECT)
	tool_options.pick_buttons[Dish.PickMode.ALL].button_pressed = true
	var ids := dish.bup_ids()
	if ids.is_empty():
		return
	_tutorial_bup = dish.selected_id if dish.has_bup(dish.selected_id) else ids[0]  # (coming back to the step keeps the bup already chosen)
	camera.zoom = Vector2.ONE * TUTORIAL_ZOOM
	camera.position = dish.global_position + (dish.bup_world_pos(_tutorial_bup) - dish.global_position).limit_length(dish.radius)


## The lineage step comes with the lineage open, and the step that asks for it with it shut, whichever way they are reached.
func _tutorial_open_lineage() -> void:
	if not _lineage_is_open():
		_open_lineage()


func _tutorial_close_lineage() -> void:
	if _lineage_is_open():
		_step_back()


func _lineage_is_open() -> bool:
	return not _stack.is_empty() and _stack.back()["view"] == "lineage"


func _tutorial_bup_rect() -> Rect2:
	if not dish.has_bup(_tutorial_bup):
		return Rect2()
	var at := get_viewport().get_canvas_transform() * dish.bup_world_pos(_tutorial_bup)
	return Rect2(at - Vector2.ONE * TUTORIAL_BUP_PIXELS, Vector2.ONE * 2.0 * TUTORIAL_BUP_PIXELS)


## The tour ended, finished or skipped: whatever it set up goes back, so the screen looks as it did before it.
func _on_tutorial_closed(_completed: bool) -> void:
	if _tutorial_bup >= 0:
		for id in dish.watched.duplicate():
			if not id in _tutorial_watched_before:
				dish.unwatch_bup(id)
		_tutorial_bup = -1
		_clear_selection()
		_fit_camera()
	toolbar.set_paused(_tutorial_was_paused)


## The rate box sits just under the readout.
func _place_rate_panel() -> void:
	rate_panel.position.y = hud.position.y + hud.get_content_height() + RATE_PANEL_GAP


## The top of the readout: how many bups there are, and (in free mode, where the player changes them) the dish's
## current size and bup limit.
func _dish_lines() -> String:
	if not free_mode:
		return Strings.t("hud.readout_bups", [dish.population()])
	return Strings.t("hud.readout_bups_limit", [dish.population(), dish.bup_limit, UiText.mm(dish.radius)])


## The playback speed, and the speed actually achieved when the simulation can't keep up with it.
func _playback_text() -> String:
	if paused:
		return Strings.t("hud.playback_paused")
	if sim_speed > 1.0 and achieved_speed < 0.85 * sim_speed:
		return Strings.t("hud.playback_slow", [int(sim_speed), int(achieved_speed)])
	return Strings.t("hud.playback_speed", [int(sim_speed)])


func _goal_text() -> String:
	var goal := tracker.current()
	if goal == null:
		return Strings.t("hud.goal_all_done")
	var s := Strings.t("hud.goal_panel", [
		tracker.index + 1, tracker.goals.size(), goal.title, goal.text, goal.status.call(dish)])
	if goal.hold_time > 0.0 and tracker.held > 0.0:
		s += Strings.t("hud.goal_holding", [SimClock.format(tracker.held), SimClock.format(goal.hold_time)])
	return s


## Shows text with its numbers styled. The readouts refresh every frame, so the styling (a
## regex pass) and the re-parse only run when the text has actually changed.
## Sets a readout's text. `about` says what the text is about (a bup, the medium at a point...): while the same thing
## stays shown at high playback speed, its figures change at most every LIVE_TEXT_MSEC, since they would only flicker.
## True when the text was changed.
func _set_rich(label: RichTextLabel, text: String, about: String) -> bool:
	if label.get_meta("raw", "") == text or not _readout_due(label, about):
		return false
	label.set_meta("about", about)
	label.set_meta("set_at", Time.get_ticks_msec())
	label.set_meta("raw", text)
	label.text = UiText.numbers(text)
	return true


## Whether a readout would take new text about `about` now (see _set_rich). Asked before working the text out, so that
## at high playback speed, where most frames change nothing, it is not worked out for nothing.
func _readout_due(label: RichTextLabel, about: String) -> bool:
	var live := not paused and sim_speed >= LIVE_TEXT_FROM_SPEED
	return not (live and label.get_meta("about", "") == about and Time.get_ticks_msec() - label.get_meta("set_at", 0) < LIVE_TEXT_MSEC)


## _set_rich with the text worked out (by `make_text`) only if it is due.
func _set_rich_when_due(label: RichTextLabel, about: String, make_text: Callable) -> void:
	if _readout_due(label, about):
		_set_rich(label, make_text.call(), about)


## The toolbar and its tray read as one piece: square the bar's bottom corners while open.
func _sync_toolbar_shape() -> void:
	toolbar.theme_type_variation = &"ToolbarPanelOpen" if tool_options.visible else &"ToolbarPanel"
