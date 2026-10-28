extends Node2D

const BANNER_SECONDS := 7.0
const MAX_FRAME_SECONDS := 0.1  ## the longest frame the sim will catch up on, so a hitch can't snowball
const FLASH_MSEC := 1500  ## how long the divisions number stays in the flash colour after the bup divides
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
const PAINT_MIN_PIXELS := 24.0  ## the least screen distance between two places of a drag with a brush tool (so that a small brush does not stamp every pixel)
const PAINT_MAX_STEPS := 60  ## the most places one pointer movement makes (a fast sweep across the dish is not worth more than this)
const PAN_KEY_PIXELS := 600.0  ## screen pixels a second the view moves while a pan key (W, A, S or D) is held
const FIT_MARGIN := 24.0  ## screen pixels kept clear round the dish when framing it in the stage
const VIEWS_MIN_WIDTH := 900.0  ## a window narrower than this leaves the layer toggles out of the top bar
const MIN_TABS_WIDTH := 140.0  ## the least the dish tabs are given before the layer toggles make way for them
const VITALS_MAX_SHARE := 0.55  ## the most of the window's width the top bar's readout may take
const TRAY_RESERVE := 48.0  ## at the top of the stage, room for the tool options that open there (kept whether they are open or not, so choosing a tool never moves the dish)
const TUTORIAL_ZOOM := 6.0  ## how close the tutorial brings the camera to a bup it asks the player to click
const TUTORIAL_BUP_PIXELS := 18.0  ## the lit square round that bup is this far out on each side
const MAX_DISHES := 20  ## the most dishes at once (the strip holds that many)
const LINEAGE_ELSEWHERE_MSEC := 30000  ## how often the lineage panel looks again for a line's bups alive in other dishes
const LOCKSTEP_MIN_GAP := 1.0  ## a dish at least this many simulated seconds behind the world's target is advanced (a shorter step would be a fine one, which only the processor runs); nearer, it waits
const CATCHUP_SECONDS := 5.0  ## when the dishes are further apart than a frame holds (after a fast speed, one dish can be a minute ahead), the ones behind are asked for this many simulated seconds a frame (what the frame's budget allows) until they have caught up
const COST_SMOOTHING := 0.4  ## how much of a dish's newest timing goes into its running average
const LOCKSTEP_MIN_SHARE := 0.25  ## at speeds where a frame holds less than four of those seconds, a quarter of the frame's step
const DISH_SPACING := 4.0e5  ## µm between the centres of the dishes in the shared world (clear of the largest dish, 90000 µm in radius, either side). They sit in a grid DISH_COLUMNS wide so no coordinate grows large: the renderer's single-precision positions would shake what is drawn far from the origin when zoomed in
const DISH_COLUMNS := 5
const VIEW_BITS := 19  ## render layers there are for dishes (the 2D world has twenty and the screen keeps the first): dishes this many places apart share one
const PICK_SLACK_PIXELS := 4.0  ## how far outside a bup (in screen pixels) still counts as pointing at it

@onready var dish: Dish = $Dish
@onready var camera: Camera2D = $Camera
@onready var vitals: RichTextLabel = %Readout  ## the top bar: how many bups, the time and the playback speed
@onready var placed_row: StatRow = %PlacedRow  ## the dish card's details: how many nutrient doses you placed
@onready var dish_details: TraySection = %DishDetails  ## the dish in the main view: what was placed, and the colony's averages (the details key opens and closes it)
@onready var colony: VBoxContainer = %Colony  ## the details: the placed row, then the colony's average traits, one row each (made as they are first shown)
@onready var goal_card: PanelContainer = %GoalCard  ## top of the side column: what the current experiment asks, and how far along it is
@onready var goal_kicker: Label = %GoalKicker
@onready var goal_title: Label = %GoalTitle
@onready var goal_text: RichTextLabel = %GoalText
@onready var goal_bar: ProgressBar = %GoalBar
@onready var goal_status: Label = %GoalStatus
@onready var banner: Label = %Banner
@onready var graph: Control = %Graph
@onready var graph_section: TraySection = %GraphSection  ## the graph's section of the tray (Y opens and closes it)
@onready var all_details: TraySection = %AllDetails  ## the figures of every dish together
@onready var all_rows: VBoxContainer = %AllRows
@onready var freezer_section: TraySection = %FreezerSection  ## the frozen dishes (hidden while there are none)
@onready var freezer_flow: HFlowContainer = %FreezerFlow
@onready var freeze_button: Button = %FreezeButton  ## freezes the dish in the main view
@onready var freezer_empty: Label = %FreezerEmpty
@onready var old_dish_dialog: AcceptDialog = $MenuLayer/OldDishDialog
@onready var span_switch: Control = %SpanSwitch  ## the graph's time span: one button for each (see HistoryGraph.SPAN_LEGENDS)
@onready var trait_select: OptionButton = %TraitSelect  ## ... and the trait on its right axis
@onready var scope_switch: Control = %ScopeSwitch  ## one dish or all together (only with more than one dish)
var _scope_buttons: Array[Button] = []
var _span_buttons := {}  ## HistoryGraph.Span -> its button
@onready var playback_panel: Control = %Playback  ## the pause and speed buttons in the top bar
@onready var views: Control = %Views  ## the graph and layer toggles in the top bar
@onready var menu_button: Button = %MenuButton
@onready var side: ScrollContainer = %Side  ## the side column: the goal, what is picked or the dish, the watch list (it scrolls when the window is too short for all of it)
@onready var stage: Control = %Stage  ## the free middle of the screen, between the rail, the side column, the top bar and the bottom bar: the dish is framed in it
@onready var toolbar: Toolbar = %Toolbar
@onready var tool_options: ToolOptions = %ToolOptions
@onready var dish_card: PanelContainer = %DishCard  ## the side column: the two ways nutrient arrives by itself, and the readout
@onready var feed_row: SettingRow = %FeedRow
@onready var bloom_row: SettingRow = %BloomRow  ## how often plankton appear
@onready var info_panel: PanelContainer = %InfoPanel  ## what is picked (a bup, a source, a plankton)
@onready var hover_card: PanelContainer = %HoverCard  ## what the pointer rests on, next to the pointer (it never moves the side column)
@onready var hover_text: RichTextLabel = %HoverText
@onready var info_genome: GenomeRibbon = %InfoGenome  ## the picked bup's genome as a chromosome map, and the lines that come after it
@onready var info_tail: RichTextLabel = %InfoTail
@onready var info_gauges: BupGauges = %InfoGauges  ## the bup's mass and reserve bars, under its name (on the hover card, under its text)
@onready var hover_gauges: BupGauges = %HoverGauges
@onready var hover_genome: GenomeRibbon = %HoverGenome  ## the same on the card that follows the pointer
@onready var hover_tail: RichTextLabel = %HoverTail
@onready var info_text: RichTextLabel = %InfoText
@onready var top_row: HBoxContainer = %InfoTopRow
@onready var name_row: BupNameRow = %NameRow
@onready var lineage_button: Button = %LineageButton
@onready var lineage_panel: PanelContainer = %LineagePanel
@onready var lineage_title: Label = %LineageTitle
@onready var lineage_back_button: Button = %LineageBackButton
@onready var lineage_entries: VBoxContainer = %LineageEntries
@onready var source_rate_row: SettingRow = %InfoSourceRate
@onready var delete_source_button: Button = %DeleteSource
@onready var follow_button: Button = %FollowButton
@onready var watch_button: Button = %WatchButton
@onready var watch_section: TraySection = %WatchSection  ## the tray's "Watching" section: a plain tray section like the rest, holding the list
@onready var watch_list: WatchList = %WatchList
@onready var tutorial: Tutorial = $TutorialLayer/Tutorial  ## the guided tour, when it is wanted (see Session.tutorial_wanted)
@onready var layers_panel: LayersPanel = %LayersPanel  ## what the dish shows: each kind of thing can be hidden
@onready var dish_strip: DishStrip = %DishStrip  ## a thumbnail of every dish when there are several
@onready var hud_layer: CanvasLayer = $HUD
@onready var pause_menu: PauseMenu = $MenuLayer/PauseMenu
@onready var end_dialog: ConfirmationDialog = $MenuLayer/EndDialog
@onready var pause_ring: Panel = %PauseRing

## The two modes share everything (dish, evolution, HUD, controls). Free mode differs in
## exactly two ways: no goals, and no saving.
var free_mode := Session.mode == Session.Mode.FREE
var tracker := GoalTracker.new()
var dishes: Array[Dish] = []  ## every dish that runs; `dish` is the one in the main view (the others run beside it, see the strip)
var _view_before_extinct: Dish = null  ## the dish that was in the main view when the first dish in `_extinct_queue` was brought into view: the view goes back to it afterwards
var _divisions_of := -1  ## the bup whose divisions count the panel last saw ...
var _divisions_seen := 0  ## ... and what it was
var _flash_until := 0  ## when the divisions number stops flashing (Time.get_ticks_msec)
var _extinct_queue: Array[Dish] = []  ## dishes that have died out and are not yet deleted (the first is the one the screen has said so about)
var _game_over := false  ## the last dish died out: only starting again or quitting goes on
var _dish_numbers := {}  ## Dish -> its number (a number is never reused: a bup's "line from dish 2" stays true)
var _next_dish_number := 1
var _pipette_hours := 0.0  ## the pipette timer: the game pauses for the pipette every this many simulated hours (0: off)
var _pipette_clock := 0.0  ## simulated seconds since the last pause for the pipette
var _pipette_waiting := false  ## paused for the pipette: only a pipette use resumes play
var _elsewhere := {}  ## see _alive_elsewhere, and when it was worked out
var _elsewhere_stamp := []
var _switch_turn := 0  ## whose turn it is to change backend when no dish is waiting
var _pipette_pulse: Tween
var tool := Toolbar.Tool.SELECT  ## kept in step with the toolbar's selection (see _on_tool_selected)
var sim_speed := 1.0  ## seconds of simulation per real second (the toolbar sets it)
var achieved_speed := 1.0  ## what the simulation actually managed lately: lower than sim_speed when the frame budget cut a step short
var paused := false
var _freezer: Array[Dictionary] = []  ## the frozen dishes, in the order they went in: {number, data (Dish.to_dict), picture (a texture), bups, button}
var _all_rows := {}  ## trait (or "mutations", "harm", "dishes", "bups") -> its StatRow in the all-dishes section
var _old_dish: Dish  ## the dish a pipette took bups from, while the question about it is up (null: no question)
var _vitals_width := 0.0  ## the widest the top bar's readout has been (see _update_hud)
var _colony_rows := {}  ## trait (or "mutations", "harm") -> its StatRow in the dish card
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
var _view_moved := false  ## the view was panned or zoomed by hand: a change of the window does not frame the dish again
var following_id := -1  ## the bup the camera is keeping in the middle of the view, or -1
var _banner_left := 0.0
var _hover_point := Vector2.ZERO  ## the spot in the dish the pointer is over, for the select tool's readout
var _hovering_point := false

# Left/middle-button press tracking, to tell a click from a drag.
var _press_button := MOUSE_BUTTON_NONE
var _press_position := Vector2.ZERO
var _dragging := false
var _painting := false  ## the left button is down with a brush tool: the pointer's path is painted, and does not pan
var _paint_last := Vector2.ZERO  ## where the brush last placed something (world position)
var _drag_threshold: float = ProjectSettings.get_setting("gui/common/drag_threshold", 10)


func _ready() -> void:
	UserSettings.ensure_applied()
	_register_dish(dish)
	dish_strip.dish_chosen.connect(set_main_dish)
	tracker.goal_completed.connect(_on_goal_completed)
	toolbar.tool_selected.connect(_on_tool_selected)
	toolbar.zoom_in_requested.connect(_zoom_by.bind(ZOOM_BUTTON_STEP))
	toolbar.zoom_out_requested.connect(_zoom_by.bind(1.0 / ZOOM_BUTTON_STEP))
	tool_options.pick_mode_selected.connect(_on_pick_mode_selected)
	tool_options.pipette_timer_changed.connect(_set_pipette_timer)
	toolbar.speed_selected.connect(func(multiplier: float) -> void:
		sim_speed = multiplier
		achieved_speed = multiplier)
	toolbar.pause_toggled.connect(_set_paused)
	end_dialog.confirmed.connect(_start_again)
	end_dialog.get_cancel_button().pressed.connect(_quit_to_menu)  # (only the button leaves: the window's cross and Escape do not, so the choice is always a deliberate one)
	end_dialog.visibility_changed.connect(func() -> void:
		if _game_over and not end_dialog.visible:
			end_dialog.popup_centered.call_deferred())
	pause_menu.resume_requested.connect(_close_menu)
	pause_menu.quit_requested.connect(_quit_to_menu)
	pause_menu.tour_requested.connect(_replay_tour)
	info_genome.entry_requested.connect(_open_encyclopedia)
	pause_menu.dish_radius_chosen.connect(_resize_dish)
	pause_menu.bup_limit_chosen.connect(func(limit: int) -> void: dish.change_limit(limit))
	graph.dish = dish
	graph.dishes = dishes
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
	watch_list.dishes = dishes
	watch_list.numbers = _dish_numbers
	layers_panel.layer_toggled.connect(func(layer: Dish.Layer, shown: bool) -> void:  # (what is shown is one choice for every dish)
		for d in dishes:
			d.show_layer(layer, shown))
	watch_list.bup_chosen.connect(_open_watched)
	lineage_button.pressed.connect(_open_lineage)
	follow_button.focus_mode = Control.FOCUS_NONE
	stage.resized.connect(_on_stage_resized)
	get_viewport().size_changed.connect(_adapt_layout)
	_adapt_layout()
	_setup_graph_controls()
	_setup_old_dish_dialog()
	freeze_button.pressed.connect(func() -> void: freeze_dish(dish))
	_refresh_freezer()
	menu_button.pressed.connect(_open_menu)
	menu_button.tooltip_text = Strings.t("hud.menu_tip")
	_on_tool_selected(toolbar.current_tool())  # the toolbar decides the starting tool
	_on_pick_mode_selected(tool_options.pick_mode())  # and its tray the starting mode
	goal_card.visible = not free_mode  # (free mode has no goals; how its dish began is on the Escape menu)
	var data := SaveGame.read() if Session.load_requested and not free_mode else {}
	Session.load_requested = false
	if data.is_empty() or not dish.from_dict(data["dish"]):
		if not data.is_empty():
			SaveGame.delete()  # (a save that will not load is no save: the title screen stops offering it)
		_begin_dish()
	else:
		tracker.from_dict(data["goals"])
		_fit_camera()
	_sync_tool_locks()
	layers_panel.sync_from(dish)
	tool_options.set_husks_available(dish.has_husks())
	_refit_when_laid_out.call_deferred()
	tutorial.closed.connect(_on_tutorial_closed)
	if Session.tutorial_wanted:
		Session.tutorial_wanted = false
		_start_tutorial.call_deferred()  # (once the screen has been laid out, so the tour can point at it)


func _exit_tree() -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


func _begin_dish() -> void:
	dish.strike(Session.free_start if free_mode else null)
	if not free_mode and tracker.index >= 1:
		dish.upkeep_factor = Dish.GOAL_UPKEEP_FACTOR  # (strike resets it: experiment 2 and after costs what it did)
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
	toolbar.set_tool_locked(Toolbar.Tool.PIPETTE, not free_mode, Strings.t("toolbar.locked_reason"))  # (goal mode keeps its one dish)


## A red ring around the window while paused, so it's never unclear why nothing is moving.
func _set_paused(is_paused: bool) -> void:
	paused = is_paused
	pause_ring.visible = is_paused
	if not is_paused and not _extinct_queue.is_empty():
		_retire_extinct.call_deferred()  # (play was resumed: the dish that died out goes)


## Frame the whole dish in the stage (the free middle of the screen: the layout leaves it clear), but never zoom in past 1:1.
func _fit_camera() -> void:
	_view_moved = false
	var view := get_viewport_rect().size
	var area := Rect2(Vector2.ZERO, view)
	if is_node_ready() and stage.size.x > 0.0:
		area = stage.get_global_rect()
		area = Rect2(area.position + Vector2(0.0, TRAY_RESERVE), area.size - Vector2(0.0, TRAY_RESERVE))
	var room := minf((area.size.x - 2.0 * FIT_MARGIN) * 0.5, (area.size.y - 2.0 * FIT_MARGIN) * 0.5)
	room = maxf(room, 40.0)
	camera.zoom = Vector2.ONE * clampf(room / dish.radius, ZOOM_MIN, 1.0)
	var shift := area.get_center() - view * 0.5  # (screen pixels the dish's centre sits from the window's centre)
	camera.position = dish.global_position - shift / camera.zoom.x


## The panels know their sizes a frame or two after the screen is made: frame the dish again then (unless the player has moved the view).
func _refit_when_laid_out() -> void:
	var before := camera.position
	await get_tree().process_frame
	await get_tree().process_frame
	if is_inside_tree() and camera.position.is_equal_approx(before) and following_id < 0:
		_fit_camera()


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
		var done := _advance_world(frame * sim_speed)
		if frame > 0.0:
			achieved_speed = lerpf(achieved_speed, done / frame, 0.1)
		if _pipette_hours > 0.0 and not _pipette_waiting:
			_pipette_clock += done
			if _pipette_clock >= _pipette_hours * 3600.0:
				_begin_pipette_wait()
		if not free_mode:
			tracker.update(dish, done)
	_banner_left = maxf(0.0, _banner_left - delta)
	if _banner_left == 0.0:
		banner.text = ""
	_update_pointer()
	_update_info_panel()
	_place_hover_card()
	_follow_selected()
	dish.refresh_drawing()
	graph.refresh()
	_show_graph_choices()
	watch_list.refresh()
	dish_strip.main_dish = dish
	dish_strip.main_zoomed_in = 2.0 * dish.radius * camera.zoom.x > minf(stage.size.x, stage.size.y) * 1.02
	dish_strip.refresh(delta)
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
	var stamp := [get_viewport().get_mouse_position(), camera.position, camera.zoom, dish.get_instance_id(), dish.time, dish.edit_count, dish.radius, tool, _dragging, get_viewport().gui_get_hovered_control() != null, tool_options.nutrient_count(), tool_options.brush_radius(), dish.pick_mode]
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
		Toolbar.Tool.PIPETTE:
			dish.place_preview_pos = world
			dish.place_preview_radius = tool_options.pipette_radius()


func _pick_slack() -> float:
	return PICK_SLACK_PIXELS / camera.zoom.x


func _update_info_panel() -> void:
	if dish.selected_id >= 0 and not dish.has_record(dish.selected_id):
		dish.selected_id = -1  # its record is gone
	if dish.hovered_id >= 0 and not dish.has_record(dish.hovered_id):
		dish.hovered_id = -1  # (a hover left over in a dish that has come into view: it has no record of that bup, and `_deceased_text` needs one)
	# A clicked bup, source or plankton is pinned to the info panel in the side column. Until one is, what the pointer
	# is over (or else the nutrient at that spot) shows on a small card beside the pointer, which never moves the column.
	var pinned := dish.has_selection()
	var bup_id: int = dish.selected_id if pinned else dish.hovered_id
	var source: NutrientSource = dish.selected_source if pinned else dish.hovered_source
	var floating: Plankton = dish.selected_plankton if pinned else dish.hovered_plankton
	var husk_place: Vector2 = dish.selected_husk if pinned else dish.hovered_husk
	var husk := dish.husk_details(husk_place) if husk_place != Dish.NO_HUSK else {}
	if husk_place != Dish.NO_HUSK and husk.is_empty():  # (it has leaked away)
		if pinned:
			dish.selected_husk = Dish.NO_HUSK
		else:
			dish.hovered_husk = Dish.NO_HUSK
		husk_place = Dish.NO_HUSK
	var editing := dish.selected_source != null and dish.selected_id < 0
	var alive_info: Dictionary = dish.bup_info(bup_id) if bup_id >= 0 else {}  # (fetched once: the panels below are built from it)
	var dead := bup_id >= 0 and alive_info.is_empty()  # a selected bup that has died stays up, as a record
	var lineage_open: bool = bup_id >= 0 and bup_id == dish.selected_id and _stack.size() > 0 and _stack.back()["view"] == "lineage"
	var something := bup_id >= 0 or source != null or floating != null or not husk.is_empty()
	var target: RichTextLabel = info_text if pinned else hover_text
	info_panel.visible = pinned and something and not lineage_open
	hover_card.visible = not pinned and (something or _hovering_point)
	dish_card.visible = not (info_panel.visible or lineage_panel.visible)  # (one slot in the side column: the dish, or what is picked)
	hover_card.theme_type_variation = &"DeceasedPanel" if dead else &"HudPanel"
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
	follow_button.tooltip_text = Strings.t("hud.stop_following_tip" if following_id >= 0 else "hud.follow_tip")
	top_row.visible = pinned and bup_id >= 0
	lineage_button.visible = bup_id >= 0 and bup_id == dish.selected_id
	watch_button.visible = lineage_button.visible  # (alive or dead: a record can be watched too)
	var shows_bup := bup_id >= 0
	info_genome.visible = shows_bup and pinned
	info_tail.visible = info_genome.visible
	info_gauges.visible = shows_bup and pinned
	hover_gauges.visible = shows_bup and not pinned
	hover_genome.visible = shows_bup and not pinned
	hover_tail.visible = hover_genome.visible
	if bup_id < 0:
		name_row.cancel_editing()
	if lineage_open:
		_show_lineage(bup_id)
	if bup_id >= 0:
		_point_stamp = []
		var record := dish.lineage_info(bup_id) if dead else alive_info
		var body := _deceased_text(record) if dead else _info_text(alive_info)
		var genome_map: GenomeRibbon = info_genome if pinned else hover_genome
		var tail: RichTextLabel = info_tail if pinned else hover_tail
		genome_map.show_bup(record, pinned)
		_set_rich(tail, _tail_text(record), "tail %d" % bup_id)
		var divided := _note_divisions(bup_id, record) and not dead and pinned  # (the hover card does not flash)
		var gauges: BupGauges = info_gauges if pinned else hover_gauges
		gauges.show_bup(record, dish.stationary_phase, not dead)
		if pinned:
			name_row.show_bup(dish, bup_id, true)  # a bup can be renamed once it is clicked, not just hovered
		else:
			body = "%s\n%s" % [dish.bup_display(bup_id).get("name", ""), body]  # (the hover card has no name row)
		_set_rich(target, body, "bup %d" % bup_id, divided)
	elif source != null:
		_point_stamp = []
		if editing:
			_show_source_rate(source)
		_set_rich_when_due(target, "source %d" % source.get_instance_id(), func() -> String: return _source_text(dish.source_details(source)))
	elif floating != null:
		_point_stamp = []
		_set_rich_when_due(target, "plankton %d" % floating.get_instance_id(), func() -> String: return _plankton_text(dish.plankton_details(floating)))
	elif not husk.is_empty():
		_point_stamp = []
		_set_rich_when_due(target, "husk %s" % husk_place, func() -> String: return _husk_text(husk))
	elif _hovering_point:
		var point_stamp := [_hover_point, dish.time, dish.edit_count]
		if point_stamp != _point_stamp:  # (the readout is worked out again only when the spot or the dish has changed)
			_point_stamp = point_stamp
			_set_rich(target, _point_text(dish.nutrient_at(_hover_point)), "point")


## The hover card follows the pointer, kept inside the window.
func _place_hover_card() -> void:
	if not hover_card.visible:
		return
	hover_card.size = Vector2.ZERO  # (a card does not shrink by itself when its words get fewer: the bup's is taller than the nutrient's)
	var view := get_viewport_rect().size
	var at := get_viewport().get_mouse_position() + Vector2(20.0, 20.0)
	if at.x + hover_card.size.x > view.x - 8.0:
		at.x = get_viewport().get_mouse_position().x - 20.0 - hover_card.size.x
	if at.y + hover_card.size.y > view.y - 8.0:
		at.y = get_viewport().get_mouse_position().y - 20.0 - hover_card.size.y
	hover_card.position = at.clamp(Vector2(8.0, 8.0), (view - hover_card.size - Vector2(8.0, 8.0)).max(Vector2(8.0, 8.0)))


## The Watch button: the selected bup goes on the watch list, or comes off it.
func _toggle_watch() -> void:
	var id := dish.selected_id
	if dish.is_watched(id):
		dish.unwatch_bup(id)
	else:
		dish.watch_bup(id)


## An entry of the watch list was clicked: that bup (living or not), in whichever dish it is in, in the inspect panel.
func _open_watched(watched_in: Dish, id: int) -> void:
	set_main_dish(watched_in)  # (the bup may be in another dish: the view goes there)
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
	if not source_rate_row.is_dragging() and not is_equal_approx(source_rate_row.value, snappedf(source.rate, 0.1)):
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


func _husk_text(d: Dictionary) -> String:
	var offset: Vector2 = d["offset"]
	var nearest: float = d["nearest_bup"]
	return Strings.t("panel.husk", [
		SimClock.format_minutes(int(d["age"] / 60.0)), d["units"], d["left"] * 100.0, offset.x, offset.y, d["distance"], _concentration_text(d["concentration"]),
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


## Whether the bup's divisions count went up just now: the number after "divisions" in the panel then shows in the flash colour for FLASH_MSEC, so that the drop in its mass and reserve
## that comes with a division is seen to have a reason.
func _note_divisions(id: int, info: Dictionary) -> bool:
	var divisions := int(info["divisions"])
	var now := Time.get_ticks_msec()
	if id != _divisions_of or divisions < _divisions_seen:
		_divisions_of = id  # (another bup is shown: nothing has just happened to it)
		_flash_until = 0
	elif divisions > _divisions_seen:
		_flash_until = now + FLASH_MSEC
	_divisions_seen = divisions
	return now < _flash_until


func _info_text(b: Dictionary) -> String:
	var text := Strings.t("panel.bup", [SimClock.format_minutes(b["born"]), b["divisions"]])
	text += Strings.t("panel.steering", [_steering_word(b["steering"])])
	text += Strings.t("panel.dish_line", [_dish_numbers[dish]])  # (the dish it is in now)
	return text.rstrip("\n")


## The lines under a bup's genome map (alive or dead): the mutations in its lineage, and its harm.
func _tail_text(b: Dictionary) -> String:
	return Strings.t("panel.bup_tail", [b["mutations"], Genome.harm_share(b["harm"]) * 100.0])


func _deceased_text(b: Dictionary) -> String:
	var text := Strings.t("panel.deceased", [SimClock.format_minutes(b["born"]), SimClock.format_minutes(b["died"]), b["divisions"]])
	if b.has("moved_to"):
		text += Strings.t("panel.moved_line", [b["moved_to"]]).substr(1) + "\n"
	else:
		text += Strings.t("panel.dish_line", [_dish_numbers[dish]]).substr(1) + "\n"  # (the dish it died in)
	return text.rstrip("\n")


## The select tool now looks at something else: a selection of a kind it no longer looks at is let go.
func _on_pick_mode_selected(mode: Dish.PickMode) -> void:
	dish.pick_mode = mode  # (which also lets go of a selection the mode doesn't look at)


func _on_tool_selected(new_tool: Toolbar.Tool) -> void:
	if new_tool != Toolbar.Tool.SELECT and (not _stack.is_empty() or dish.has_selected_thing()):
		_clear_selection()  # using another tool closes whatever was open on a bup or source
	tool = new_tool
	tool_options.show_for(tool)
	match tool:
		Toolbar.Tool.PAN:
			Input.set_default_cursor_shape(Input.CURSOR_DRAG)
		Toolbar.Tool.NUTRIENT, Toolbar.Tool.SOURCE, Toolbar.Tool.ERASE, Toolbar.Tool.PLANKTON, Toolbar.Tool.PIPETTE:
			Input.set_default_cursor_shape(Input.CURSOR_CROSS)
		_:
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)


## What only this screen knows, for the log.
func debug_state() -> Dictionary:
	return {
		"mode": "free" if free_mode else "goals",
		"goal_index": tracker.index,
		"sim_speed": sim_speed,
		"achieved_speed": achieved_speed,
		"paused": paused,
		"menu_open": menu_open,
		"tutorial_step": tutorial.index if tutorial.active else -1,
		"tool": Toolbar.Tool.keys()[tool],
		"zoom": camera.zoom.x,
		"following": following_id,
		"views_open": _stack.size(),
		"camera_position": [camera.position.x, camera.position.y],
		"camera_follow_precision_um": absf(camera.position.x) * 6.0e-8,  # (the single-precision step of the renderer's coordinates at the camera: a zoomed-in view shakes by it times the zoom)
		"stage_size": [stage.size.x, stage.size.y],
		"ui_scale": UserSettings.ui_scale,
		"graph": {
			"scope_all": graph.all_dishes,
			"combined": graph.combined(),
			"span": HistoryGraph.Span.keys()[graph.shown_span()],
			"span_chosen": graph.chosen,
			"trait": HistoryGraph.TRAITS[graph.trait_index],
			"shown_time_s": graph._now(),
		},
		"tray_open": {"graph": graph_section.open, "dish_details": dish_details.open, "all_details": all_details.open},
		"dish_strip": {"visible": dish_strip.visible, "main_zoomed_in": dish_strip.main_zoomed_in},
		"watched_total": dishes.reduce(func(n: int, d: Dish) -> int: return n + d.watched.size(), 0),
		"world_time": world_time(),
		"dishes": dishes.map(func(d: Dish) -> Dictionary: return {"number": _dish_numbers[d], "bups": d.population(), "time": d.time, "history_origin": d.history_origin, "position": [d.global_position.x, d.global_position.y], "backend": d.backend_running(), "husks": d.sim.husk_count(), "behind_s": maxf(dishes.reduce(func(m: float, o: Dish) -> float: return maxf(m, o.time), 0.0) - d.time, 0.0), "rule": DebugLog.rule(d)}),
		"switch_turn": _switch_turn,
		"frame_budget_usec": FRAME_BUDGET_USEC,
		"freezer": _freezer.map(func(entry: Dictionary) -> Dictionary: return {"number": entry["number"], "bups": entry["bups"], "frozen_at": entry["data"].get("time", 0.0)}),
	}


## Only input the GUI didn't consume arrives here, so clicks on the toolbar never reach the dish.
func _unhandled_input(event: InputEvent) -> void:
	if _old_dish != null:
		return  # (a question about the old dish is up: nothing else is done until it is answered)
	if menu_open:  # only Escape reaches the game while the menu is up, and it closes the menu
		if UiInput.is_escape_press(event) and not pause_menu.close_panel():
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
			_zoom_by(pow(ZOOM_WHEEL_STEP, -event.delta.y * ZOOM_TRACKPAD_SCROLL * UserSettings.zoom_speed))
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event)


## A band of the genome map was clicked: the game holds and the encyclopedia opens on the entry of its gene.
func _open_encyclopedia(entry: String) -> void:
	_open_menu()
	pause_menu.show_encyclopedia(entry)


func _on_key(event: InputEventKey) -> void:
	if event.keycode == KEY_ESCAPE:
		_escape()
	elif event.keycode == KEY_F1:
		_open_menu()
		pause_menu.show_controls()
	elif event.keycode in [KEY_DELETE, KEY_BACKSPACE]:
		if _tools_unlocked():
			_delete_selected_source()
	elif KeyBindings.matches("details", event):
		_toggle_colony()
	elif KeyBindings.matches("graph_trait", event):
		graph.cycle_trait()
	elif KeyBindings.matches("graph_span", event):
		graph.cycle_span()
	elif KeyBindings.matches("graph_show", event):
		graph_section.open = not graph_section.open
	elif KeyBindings.matches("frame", event):
		_fit_camera()
	elif KeyBindings.matches("follow", event):
		if dish.selected_id >= 0 and dish.has_bup(dish.selected_id):
			_toggle_follow()
	elif KeyBindings.matches("watch", event):
		if dish.selected_id >= 0 and dish.has_record(dish.selected_id):
			_toggle_watch()
	elif KeyBindings.matches("lineage", event):
		_open_lineage()
	elif KeyBindings.matches("slower", event):
		toolbar.step_speed(-1)
	elif KeyBindings.matches("faster", event):
		toolbar.step_speed(1)


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
## Who of a lineage is alive in the other dishes: ancestor id -> [[how many, the dish's number], ...]. Worked out when the lineage is first shown and then at most every
## LINEAGE_ELSEWHERE_MSEC (a pass over a dish's records), and only for dishes that hold a record of someone in the line (the ones a pipette took bups into).
func _alive_elsewhere(chain: PackedInt64Array) -> Dictionary:
	if dishes.size() < 2 or chain.is_empty():
		return {}
	var stamp := [chain[-1], Time.get_ticks_msec() / LINEAGE_ELSEWHERE_MSEC]
	if _elsewhere_stamp == stamp:
		return _elsewhere
	_elsewhere_stamp = stamp
	_elsewhere = {}
	for other in dishes:
		if other == dish or not other.has_record(chain[0]):
			continue
		var counts := other.living_descendants(chain)
		for k in chain.size():
			if counts[k] > 0:
				if not _elsewhere.has(chain[k]):
					_elsewhere[chain[k]] = []
				_elsewhere[chain[k]].append([counts[k], _dish_numbers[other]])
	return _elsewhere


func _show_lineage(id: int) -> void:
	var chain := dish.lineage_chain(id)
	var elsewhere := _alive_elsewhere(chain)
	var key := [elsewhere]
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
		for place: Array in elsewhere.get(ancestor, []):
			line += Strings.t("panel.lineage_elsewhere", [place[0], place[1]])
		var row := HBoxContainer.new()
		var swatch := BupPicture.new()  # the bup itself, in its colour, so a clade can be followed by eye
		swatch.show_info(info)
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
## The pipette timer was switched or set (hours; 0 is off). Switching it off ends a wait for the pipette (play stays paused).
func _set_pipette_timer(hours: float) -> void:
	_pipette_hours = hours
	_pipette_clock = 0.0
	if hours <= 0.0:
		_end_pipette_wait(false)


## The timer has run out: the game pauses, and only using the pipette resumes it. Tools can still be changed; the pipette's button pulses.
func _begin_pipette_wait() -> void:
	_pipette_waiting = true
	_pipette_clock = 0.0
	toolbar.set_paused(true)
	toolbar.resume_locked = true
	var button := toolbar.button_for(Toolbar.Tool.PIPETTE)
	if UserSettings.reduce_motion:
		button.modulate.a = 0.5  # (lit, but not pulsing)
		return
	_pipette_pulse = create_tween().set_loops()
	_pipette_pulse.tween_property(button, "modulate:a", 0.35, 0.5).set_trans(Tween.TRANS_SINE)
	_pipette_pulse.tween_property(button, "modulate:a", 1.0, 0.5).set_trans(Tween.TRANS_SINE)


func _end_pipette_wait(resume: bool) -> void:
	if not _pipette_waiting:
		return
	_pipette_waiting = false
	toolbar.resume_locked = false
	if _pipette_pulse != null:
		_pipette_pulse.kill()
	toolbar.button_for(Toolbar.Tool.PIPETTE).modulate.a = 1.0
	if resume:
		toolbar.set_paused(false)


## The pipette: every bup in the circle moves to a new dish (a droplet in the middle of a fresh dish like this one, as the player started it), and the old dish
## goes on without them. The new dish takes its place in the strip and the main view moves to it. Returns the new dish, or null if there was nothing to move or no room.
func pipette(world: Vector2, circle_radius: float) -> Dish:
	if dishes.size() >= MAX_DISHES:
		_show_banner(Strings.t("hud.banner_pipette_limit"), 1.5)
		return null
	var source := dish
	var taken := source.take_in_disc(world, circle_radius)
	var count := taken.size() / GpuSim.RECORD_BYTES
	if count == 0:
		_show_banner(Strings.t("hud.banner_pipette_empty"), 1.5)
		return null
	var start: StartConditions = Session.free_start.copy() if Session.free_start != null else StartConditions.new()
	start.dish_radius = source.radius
	start.bup_limit = source.bup_limit
	var receiver := add_dish(start)
	receiver.clear_bups()
	for i in count:
		source.moved_out[GpuSim.id_of(taken, i)] = _dish_numbers[receiver]
	var ids := receiver.add_transferred(taken, source.taken_lineage)
	source.taken_lineage = PackedByteArray()
	for id in ids:  # (the same bup in its new dish: a watched one stays on the watch list, now as one of that dish's)
		if source.is_watched(id):
			source.unwatch_bup(id)
			receiver.watch_bup(id)
	set_main_dish(receiver)  # (the view follows the bups to their new dish)
	toolbar.select_tool(Toolbar.Tool.SELECT)  # (the pipette is done: the next click inspects)
	_ask_about_old_dish(source, count, receiver)  # (play, which the pipette's timer was holding, goes on once that is answered)
	return receiver


## One world clock: every dish is advanced to the same time, so no dish runs faster than another over time. The target is a frame's simulated seconds past the
## slowest dish; a dish that has reached it waits, and a dish that is short of it by less than a second (or a quarter of a frame's step, if that is less) waits for the next frame
## (a tiny step would take it off the GPU). A dish that is ahead of a slow world moves every frame by what the slow one gained, so it stays smooth. The dishes that move share the frame's budget. If the machine cannot keep up, the whole world slows together. Returns how far the world's clock moved.
func _advance_world(asked: float) -> float:
	var cpu_total := 0.0  # (the processor's load: what each dish still running on it is estimated to need for a frame)
	for d in dishes:
		if not d.gpu_active:
			cpu_total += d.cpu_cost_estimate
	for d in dishes:
		d.other_cpu_load = cpu_total - (0.0 if d.gpu_active else d.cpu_cost_estimate)
	_let_one_dish_switch()
	var before := world_time()
	var latest := before
	for d in dishes:
		latest = maxf(latest, d.time)
	if latest - before > maxf(LOCKSTEP_MIN_GAP, 2.0 * asked):
		# The dishes are further apart than the world moves in a frame (slowing down from a fast speed leaves them so): waiting for the slowest at the speed asked would
		# freeze the others for as long as the gap is, so the ones behind catch up first, as fast as the frame's budget lets them, and the ones ahead wait.
		var behind: Array[Dish] = dishes.filter(func(d: Dish) -> bool: return latest - d.time > 0.0)
		behind = _within_budget(behind, latest)
		var catch_share := FRAME_BUDGET_USEC / maxi(behind.size(), 1)
		for d in behind:
			_advance_timed(d, minf(latest - d.time, maxf(asked, CATCHUP_SECONDS)), catch_share)
		return minf(maxf(world_time() - before, 0.0), asked)  # (what the speed readout and the timers see is the pace asked for, not the catching up)
	var target := before + asked
	var due: Array[Dish] = []
	for d in dishes:
		if target - d.time >= minf(LOCKSTEP_MIN_GAP, asked * LOCKSTEP_MIN_SHARE):
			due.append(d)
	due = _within_budget(due, target)
	var share := FRAME_BUDGET_USEC / maxi(due.size(), 1)
	for d in due:
		_advance_timed(d, target - d.time, share)
	return maxf(world_time() - before, 0.0)


## Which of the dishes that are due this frame the processor can afford. A dish on the processor costs what it was timed to take (or what the cost model says, until it has been
## timed); the GPU's dishes cost the processor next to nothing and always go. The dishes furthest behind go first, and one dish on the processor always goes, however much it costs, so
## the world never stops; the ones left out are further behind next frame, so they go first then: the dishes take turns, and when the processor cannot keep up with all of them the whole
## world slows down together (its clock is the slowest dish's) instead of every frame costing the sum of every dish's step and the interface waiting for it.
func _within_budget(due: Array[Dish], target: float) -> Array[Dish]:
	var ordered := due.duplicate()
	ordered.sort_custom(func(a: Dish, b: Dish) -> bool: return target - a.time > target - b.time)
	var left := float(FRAME_BUDGET_USEC)
	var chosen: Array[Dish] = []
	var on_processor := 0
	for d: Dish in ordered:
		if d.gpu_active:
			chosen.append(d)
			continue
		var cost := d.measured_usec if d.measured_usec > 0.0 else d.cpu_cost_estimate
		if on_processor == 0 or cost <= left:
			left -= cost
			on_processor += 1
			chosen.append(d)
	return chosen


## Advances a dish and, when it ran on the processor, notes how long that took (see Dish.measured_usec).
func _advance_timed(d: Dish, seconds: float, budget_usec: int) -> void:
	var started := Time.get_ticks_usec()
	d.advance(seconds, budget_usec)
	if d.gpu_active:
		d.measured_usec = 0.0  # (the timing was of the processor; on the GPU it is timed afresh if the dish comes back)
	else:
		var took := float(Time.get_ticks_usec() - started)
		d.measured_usec = took if d.measured_usec <= 0.0 else lerpf(d.measured_usec, took, COST_SMOOTHING)


## Auto moves one dish between the processor and the GPU at a time: dishes that all decide in the same frame would each see the others' load as it was, and all go (or all come
## back) together. Of the dishes waiting, the one that wants the GPU and costs the processor most goes first; with none waiting, the turn goes round the dishes.
func _let_one_dish_switch() -> void:
	var chosen: Dish = null
	for d in dishes:
		if not d.switch_wanted:
			continue
		if chosen == null or (d.switch_wanted_gpu and (not chosen.switch_wanted_gpu or d.cpu_cost_estimate > chosen.cpu_cost_estimate)) or (not d.switch_wanted_gpu and not chosen.switch_wanted_gpu and d.cpu_cost_estimate < chosen.cpu_cost_estimate):
			chosen = d
	if chosen == null:  # (nobody is waiting: the turn goes round, so no two dishes ever decide in the same frame)
		_switch_turn = (_switch_turn + 1) % dishes.size()
		chosen = dishes[_switch_turn]
	for d in dishes:
		d.switch_allowed = d == chosen
		d.switch_wanted = false  # (a dish that still wants a change says so again in this frame's advance; one that is not advanced has nothing to say)


## The world's time: that of the slowest dish.
func world_time() -> float:
	var slowest := dish.time
	for d in dishes:
		slowest = minf(slowest, d.time)
	return slowest


## Takes a dish into the set: the screen hears when it dies out or its selection changes (when it is the one in the main view), and the strip gets its thumbnail.
func _register_dish(d: Dish, number := -1) -> void:
	var is_new := number < 0  # (a dish out of the freezer comes back under the number it had)
	if is_new:
		number = _next_dish_number
	dishes.append(d)
	_dish_numbers[d] = number
	d.set_view_layer(_view_bit(d))
	_apply_view_mask()
	d.extinct.connect(_on_dish_extinct.bind(d))
	d.selection_changed.connect(func() -> void:
		if d == dish:
			_on_selection_changed())
	dish_strip.add(d, number, get_world_2d(), _view_bit(d))
	if is_new:
		_next_dish_number += 1
	_set_picture_scales()
	dish_strip.light(dish)


## The render layer a dish is on (bits 1 to VIEW_BITS: a place far enough from another to share its layer is never in view with it).
func _view_bit(d: Dish) -> int:
	var slot := roundi(d.global_position.x / DISH_SPACING) + roundi(d.global_position.y / DISH_SPACING) * DISH_COLUMNS
	return 1 + slot % VIEW_BITS


## The main view shows the screen's own layer and the layer of the dish in the main view, and no other dish, however far it is zoomed out.
func _apply_view_mask() -> void:
	get_viewport().canvas_cull_mask = 1 | (1 << _view_bit(dish))


## Where the dish in a place of the shared world has its centre.
static func _slot_position(slot: int) -> Vector2:
	return Vector2(DISH_SPACING * float(slot % DISH_COLUMNS), DISH_SPACING * float(slot / DISH_COLUMNS))


## Another dish, run beside the main one in the same world, far enough away that the view of one is clear of the next (when zoomed in). It is started as `start` says (null: the usual
## dish) and takes its place in the strip; the main view stays where it is. Returns it.
func add_dish(start: StartConditions, number := -1) -> Dish:
	var d := Dish.new()
	add_child(d)
	var slot := 0  # (the first place no dish holds: a dish that went extinct leaves its place free)
	while dishes.any(func(other: Dish) -> bool: return other.global_position.is_equal_approx(_slot_position(slot))):
		slot += 1
	d.global_position = _slot_position(slot)
	d.strike(start)
	d.begin_at(world_time())  # (a dish that joins is at the world's time: one clock for all)
	for layer: int in Dish.Layer.values():
		d.show_layer(layer, dish.layer_shown(layer))  # (what is shown is one choice for every dish)
	_register_dish(d, number)
	return d


## Takes a dish out of the running set for good: the view goes to its neighbour if it was the one in the main view, the strip and the lists forget it, and it is freed.
## A dish out of the main view is looked at only through its small picture in the strip, so its bups are sized for that (they would be too small to see at the
## main view's zoom); the dish in the main view is drawn for the camera.
func _set_picture_scales() -> void:
	for d in dishes:
		d.picture_scale = 0.0 if d == dish else DishStrip.THUMB / (2.0 * d.radius * DishStrip.MARGIN)


func _remove_dish(d: Dish) -> void:
	if d == dish:
		var at := dishes.find(d)
		set_main_dish(dishes[at - 1] if at > 0 else dishes[1])
	dishes.erase(d)
	_dish_numbers.erase(d)
	_extinct_queue.erase(d)
	dish_strip.remove(d)
	dish_strip.light(dish)
	d.queue_free()
	_elsewhere_stamp = []


## Puts a dish in the freezer: its whole state is kept as a save keeps it, and it leaves the running dishes. It does not advance (the world's clock, the machine's
## load and the graph's all-dishes view leave it out) until `thaw` brings it back under its own number. The last running dish cannot be frozen.
func freeze_dish(d: Dish) -> void:
	if not dishes.has(d) or dishes.size() < 2:
		return
	var picture := dish_strip.picture_of(d)
	_freezer.append({
		"number": _dish_numbers[d],
		"data": d.to_dict(),
		"bups": d.population(),
		"picture": ImageTexture.create_from_image(picture) if picture != null else null,
	})
	var number: int = _dish_numbers[d]
	_remove_dish(d)
	_refresh_freezer()
	_show_banner(Strings.t("hud.banner_frozen", [number]), 1.5)


## Takes a dish out of the game: its bups die with it and nothing of it is kept. The last running dish cannot be trashed.
func trash_dish(d: Dish) -> void:
	if not dishes.has(d) or dishes.size() < 2:
		return
	var number: int = _dish_numbers[d]
	_remove_dish(d)
	_show_banner(Strings.t("hud.banner_trashed", [number]), 1.5)


## A frozen dish runs again, as one of the running dishes, from the world's time on (the time it was frozen is not simulated), under the number it had.
func thaw(entry: Dictionary) -> void:
	if dishes.size() >= MAX_DISHES:
		_show_banner(Strings.t("hud.banner_unfreeze_limit"), 1.5)
		return
	var world := world_time()
	var data: Dictionary = (entry["data"] as Dictionary).duplicate(true)
	_move_saved_dish_to(data, world)
	var d := add_dish(null, entry["number"])
	if not d.from_dict(data):
		_remove_dish(d)
		return
	_freezer.erase(entry)
	_refresh_freezer()


## What a dish's save holds in the times of the run, moved on to `world` (the dish was frozen at an earlier time): the plankton's and the bloom's times go with
## it, so nothing is overdue the moment it runs, and the history goes on level for the time it was away (it is the last figures it had, which is what a frozen
## dish was) so the graph's time axis stays the world's.
static func _move_saved_dish_to(data: Dictionary, world: float) -> void:
	var gap := maxf(world - float(data.get("time", world)), 0.0)
	data["time"] = world
	if Validate.is_number(data.get("bloom_due")):
		data["bloom_due"] = float(data["bloom_due"]) + gap
	for saved in data.get("plankton", []):
		if saved is Dictionary:
			for key in ["born_at", "burst_at"]:
				if Validate.is_number(saved.get(key)):
					saved[key] = float(saved[key]) + gap
	var history: Variant = data.get("history")
	if history is Dictionary:
		_pad_series(history, mini(int(gap / Dish.HISTORY_INTERVAL), Dish.HISTORY_LEN))
	var whole: Variant = data.get("history_all")
	if whole is Dictionary and Validate.is_number(data.get("history_all_factor")):
		_pad_series(whole, mini(int(gap / (float(data["history_all_factor"]) * Dish.HISTORY_INTERVAL)), Dish.HISTORY_ALL_LEN))


static func _pad_series(series_by_name: Dictionary, count: int) -> void:
	for key in series_by_name:
		var series: Variant = series_by_name[key]
		if series is Array and not series.is_empty():
			var last: Variant = series[-1]
			for i in count:
				series.append(last)


## The freezer's section of the tray: a button for each frozen dish (its picture and number; a click unfreezes it). It is there only while something is in it.
func _refresh_freezer() -> void:
	for child in freezer_flow.get_children():
		child.queue_free()
	for entry in _freezer:
		var button := Button.new()
		button.theme_type_variation = &"PictureButton"
		button.icon = entry["picture"]
		button.text = Strings.t("dishes.caption", [entry["number"]])
		button.tooltip_text = Strings.t("hud.unfreeze_tip", [entry["number"], UiText.thousands(entry["bups"])])
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(thaw.bind(entry))
		freezer_flow.add_child(button)
	freezer_empty.visible = _freezer.is_empty()
	freezer_section.visible = free_mode  # (the goals' dish is the only one: nothing to freeze)


## After a pipette: the dish the bups came from is what the player decides about, and nothing else can be done until they have. The game holds meanwhile.
func _ask_about_old_dish(source: Dish, moved: int, receiver: Dish) -> void:
	_old_dish = source
	toolbar.set_paused(true)
	toolbar.resume_locked = true
	var number: int = _dish_numbers[source]
	old_dish_dialog.title = Strings.t("hud.old_title", [number])
	old_dish_dialog.dialog_text = Strings.t("hud.old_text", [UiText.thousands(moved), _dish_numbers[receiver], UiText.thousands(source.population())])
	old_dish_dialog.popup_centered()


func _setup_old_dish_dialog() -> void:
	old_dish_dialog.ok_button_text = Strings.t("hud.old_freeze")  # (the main answer: freezing is safe and spares the computer)
	old_dish_dialog.add_button(Strings.t("hud.old_keep"), false, "keep")
	var trash := old_dish_dialog.add_button(Strings.t("hud.old_trash"), false, "trash")
	trash.theme_type_variation = DialogStyle.DANGER_VARIATION  # (the choice that cannot be undone)
	old_dish_dialog.confirmed.connect(_answer_old_dish.bind("freeze"))
	old_dish_dialog.custom_action.connect(func(action: StringName) -> void: _answer_old_dish(String(action)))
	old_dish_dialog.visibility_changed.connect(func() -> void:  # (only a button answers: nothing else closes it, as with the end of the game)
		if _old_dish != null and not old_dish_dialog.visible:
			(func() -> void:  # (OK hides the dialog before `confirmed` answers it: look again once the answer has been given)
				if _old_dish != null and not old_dish_dialog.visible:
					old_dish_dialog.popup_centered()).call_deferred())


func _answer_old_dish(choice: String) -> void:
	var source := _old_dish
	_old_dish = null
	old_dish_dialog.hide()
	if is_instance_valid(source) and dishes.has(source):
		match choice:
			"freeze":
				freeze_dish(source)
			"trash":
				trash_dish(source)
	toolbar.resume_locked = false
	if _pipette_waiting:
		_end_pipette_wait(true)  # (the pause the pipette's timer held is what using the pipette ends)
	else:
		toolbar.set_paused(false)  # (the question paused the game; answering it goes on)


## The rect of something in the tray, scrolled into view first (the tray scrolls when its sections are taller than the window).
func _in_tray(item: Control) -> Rect2:
	side.ensure_control_visible(item)
	return item.get_global_rect()


## The tour's graph step: the graph's section is open and in view.
func _tutorial_show_graph() -> void:
	graph_section.open = true
	side.ensure_control_visible.call_deferred(graph_section)


## The graph's two choices as controls above it: a switch for the time span (all four in view) and a drop-down for the trait (eight).
## They are one choice for the graph whichever way it is made (the G and T keys too), so they follow it (`_show_graph_choices`).
func _setup_graph_controls() -> void:
	var group := ButtonGroup.new()
	for mode: HistoryGraph.Span in HistoryGraph.SPAN_LEGENDS:
		var button := Button.new()
		button.theme_type_variation = &"SwitchButton"
		button.toggle_mode = true
		button.button_group = group
		button.focus_mode = Control.FOCUS_NONE  # (the keyboard has G)
		button.text = Strings.t(HistoryGraph.SPAN_LEGENDS[mode])
		button.pressed.connect(graph.set_span.bind(mode))
		span_switch.get_node("Choices").add_child(button)
		_span_buttons[mode] = button
	var scope_group := ButtonGroup.new()
	for all in [false, true]:
		var button := Button.new()
		button.theme_type_variation = &"SwitchButton"
		button.toggle_mode = true
		button.button_group = scope_group
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(graph.set_all_dishes.bind(all))
		scope_switch.get_node("Choices").add_child(button)
		_scope_buttons.append(button)
	_scope_buttons[1].text = Strings.t("graph.scope_all")
	scope_switch.tooltip_text = Strings.t("graph.scope_tip")
	for trait_name: String in HistoryGraph.TRAITS:
		trait_select.add_item(Strings.t("genes.graph_" + trait_name))
	trait_select.item_selected.connect(graph.set_trait)
	trait_select.item_selected.connect(func(_index: int) -> void: trait_select.release_focus.call_deferred())  # (a choice completes the interaction: Space goes back to the game)
	span_switch.tooltip_text = Strings.t("graph.span_tip")
	trait_select.tooltip_text = Strings.t("graph.trait_tip")


func _show_graph_choices() -> void:
	var shown: HistoryGraph.Span = graph.shown_span()
	for mode: HistoryGraph.Span in _span_buttons:
		_span_buttons[mode].set_pressed_no_signal(mode == shown)
	scope_switch.visible = dishes.size() > 1
	all_details.visible = dishes.size() > 1  # (with one dish there is no "all")
	freeze_button.disabled = dishes.size() < 2  # (the last running dish stays)
	_scope_buttons[0].text = Strings.t("graph.scope_dish", [_dish_numbers.get(dish, 0)])
	_scope_buttons[0].set_pressed_no_signal(not graph.combined())
	_scope_buttons[1].set_pressed_no_signal(graph.combined())
	if trait_select.selected != graph.trait_index:
		trait_select.select(graph.trait_index)


## Brings another dish into the main view: the panels and the graph follow it, and the camera goes back to where (and how close) it last looked at that dish, or frames the dish if it has not looked yet; what was open on the old dish (a selection, a lineage) is closed.
func set_main_dish(d: Dish) -> void:
	if d == dish or not dishes.has(d):
		return
	_clear_selection()
	following_id = -1
	dish.view_zoom = camera.zoom.x  # (where it was being looked at, for when the view comes back)
	dish.view_position = camera.position
	dish = d
	_apply_view_mask()
	d.clear_hover()  # (what it was hovering when last in view is stale)
	_set_picture_scales()
	d.pick_mode = tool_options.pick_mode()
	graph.dish = d
	layers_panel.sync_from(d)
	tool_options.set_husks_available(d.has_husks())
	dish_strip.light(d)
	if d.view_zoom > 0.0:
		camera.zoom = Vector2.ONE * d.view_zoom
		camera.position = d.view_position
	else:
		_fit_camera()


func _resize_dish(new_radius: float) -> void:
	dish.resize_to(new_radius)
	camera.position = dish.global_position + (camera.position - dish.global_position).limit_length(dish.radius)


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
				_zoom_by(pow(ZOOM_WHEEL_STEP, UserSettings.zoom_speed))
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed and not _over_hud():
				_zoom_by(pow(ZOOM_WHEEL_STEP, -UserSettings.zoom_speed))
		MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				get_viewport().gui_release_focus()  # so keys go to shortcuts, not the nutrient box
				_press_button = event.button_index
				_press_position = event.position
				_dragging = event.button_index == MOUSE_BUTTON_MIDDLE or tool == Toolbar.Tool.PAN
				_painting = event.button_index == MOUSE_BUTTON_LEFT and _is_brush(tool)
				if _painting:  # (a brush tool acts where the button goes down, and goes on along the drag: it never pans)
					_paint_last = make_input_local(event).position
					_click(_paint_last)
			elif event.button_index == _press_button:
				if not _dragging and not _painting:
					_click(make_input_local(event).position)
				_press_button = MOUSE_BUTTON_NONE
				_dragging = false
				_painting = false


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
		_painting = false
		return
	if _painting:
		_paint_to(make_input_local(event).position)
		return
	if not _dragging and event.position.distance_to(_press_position) > _drag_threshold:
		_dragging = true
	if _dragging:
		_pan_camera(-event.relative / camera.zoom.x)


## The tools that place something along a drag (the nutrient dose, the plankton and the eraser), and so do not pan with the left button.
func _is_brush(which: Toolbar.Tool) -> bool:
	return which == Toolbar.Tool.NUTRIENT or which == Toolbar.Tool.PLANKTON or which == Toolbar.Tool.ERASE


## The world distance between two places of a drag: the brush's own width, and never less than PAINT_MIN_PIXELS on the screen.
func _paint_spacing() -> float:
	var width := 0.0
	match tool:
		Toolbar.Tool.ERASE:
			width = tool_options.brush_radius()
		Toolbar.Tool.NUTRIENT:
			width = Dish.scatter_radius(tool_options.nutrient_count())
		Toolbar.Tool.PLANKTON:
			width = Dish.PLANKTON_PATCH_RADIUS
	return maxf(width, PAINT_MIN_PIXELS / camera.zoom.x)


## Carries the brush from where it last placed something to `world`, placing at every spacing along the way.
func _paint_to(world: Vector2) -> void:
	var spacing := _paint_spacing()
	var steps := 0
	while _paint_last.distance_to(world) >= spacing and steps < PAINT_MAX_STEPS:
		_paint_last = _paint_last.move_toward(world, spacing)
		_click(_paint_last)
		steps += 1
	if steps == PAINT_MAX_STEPS:
		_paint_last = world  # (a sweep past the cap carries on from here, not from where it fell short)


## Moves the view by `world_delta`, but never off the dish. Panning by hand takes over from following.
func _pan_camera(world_delta: Vector2) -> void:
	_view_moved = true
	following_id = -1
	camera.position = dish.global_position + (camera.position + world_delta - dish.global_position).limit_length(dish.radius)


## W, A, S and D move the view while held. The keys are taken by their place on the keyboard, so they are the same four
## on any layout; nothing happens while a text box has the keyboard, or with Ctrl, Alt or Cmd held (those are shortcuts).
func _pan_with_keys(delta: float) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_META):
		return
	var direction := Vector2(
		float(Input.is_key_pressed(KeyBindings.key("pan_right"))) - float(Input.is_key_pressed(KeyBindings.key("pan_left"))),
		float(Input.is_key_pressed(KeyBindings.key("pan_down"))) - float(Input.is_key_pressed(KeyBindings.key("pan_up"))))
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
		Toolbar.Tool.PIPETTE:
			if world.distance_to(dish.global_position) <= dish.radius:
				pipette(world, tool_options.pipette_radius())


## Zooms about the selected bup or source, so it stays where it is on the screen. With nothing selected, or the
## selection out of view, it zooms about the middle of the view.
func _zoom_by(factor: float) -> void:
	_view_moved = true
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
	if dish.selected_husk != Dish.NO_HUSK:
		return dish.global_position + dish.selected_husk
	return null


func _show_banner(text: String, seconds: float) -> void:
	banner.text = text
	_banner_left = seconds


func _on_goal_completed(goal: Goal) -> void:
	if tracker.index >= 1:
		dish.upkeep_factor = Dish.GOAL_UPKEEP_FACTOR  # experiment 2 and after: staying alive costs more
	toolbar.set_paused(true)  # so the colony isn't left running while the player reads and sets up what comes next
	_sync_tool_locks()
	_show_banner(Strings.t("hud.banner_complete", [goal.title]) + ("\n" + Strings.t("hud.banner_unlocked") if tracker.index == 1 else ""), BANNER_SECONDS)
	save_game()


## A dish has no bups left. The game pauses on that dish and says so; resuming goes on without it (the dish before it, or the next when it was the first, comes
## into view and the extinct one is deleted). When it was the last dish the game is over: only starting again or quitting to the menu go on.
func _on_dish_extinct(d: Dish) -> void:
	if _game_over or not dishes.has(d) or _extinct_queue.has(d):
		return
	_extinct_queue.append(d)
	if _extinct_queue.size() == 1:
		_announce_extinct()


func _announce_extinct() -> void:
	var d := _extinct_queue[0]
	if d != dish:
		if _view_before_extinct == null:
			_view_before_extinct = dish
		set_main_dish(d)
	toolbar.set_paused(true)
	if dishes.size() == 1 and not _freezer.is_empty():
		_show_banner(Strings.t("hud.banner_extinct_frozen", [_dish_numbers[d]]), 1e9)
		return
	if dishes.size() == 1:
		_game_over = true
		_extinct_queue.clear()
		_view_before_extinct = null
		toolbar.resume_locked = true
		pause_ring.visible = false  # (the game is over, not paused: the dialog says what happened)
		end_dialog.dialog_text = Strings.t("hud.end_text") + "\n" + Strings.t("hud.end_survived", [SimClock.format(dish.time)])
		end_dialog.popup_centered()
		return
	_show_banner(Strings.t("hud.banner_dish_extinct", [_dish_numbers[d]]), 1e9)


## Play was resumed after a dish went extinct: it is deleted as though it had never been, and the view goes to its neighbour.
func _retire_extinct() -> void:
	if _extinct_queue.is_empty() or _game_over:
		return
	if dishes.size() < 2:  # (the last running dish died out while others are frozen: it stays, empty, until one is unfrozen)
		_extinct_queue.clear()
		_view_before_extinct = null
		_show_banner("", 0.0)
		return
	var d: Dish = _extinct_queue.pop_front()
	if d == dish and _view_before_extinct != null and dishes.has(_view_before_extinct) and _view_before_extinct != d and not _extinct_queue.has(_view_before_extinct):
		set_main_dish(_view_before_extinct)  # (back to what was being looked at: the dish before this one only if this was the one being looked at)
	if _extinct_queue.is_empty():
		_view_before_extinct = null
	_remove_dish(d)
	_show_banner("", 0.0)
	if not _extinct_queue.is_empty():
		_announce_extinct()


## The last dish died out and the player chose to begin again: the same beginning as the game screen's own.
func _start_again() -> void:
	_game_over = false
	toolbar.resume_locked = false
	_stack.clear()
	_lineage_shown = {}
	_end_pipette_wait(false)
	_pipette_clock = 0.0
	dish.selected_id = -1
	_begin_dish()
	toolbar.set_paused(free_mode)


## The rate box sits just under the readout. The feed is always there; the bloom comes with plankton. Both follow the dish.
func _sync_bloom_panel() -> void:
	var plankton_unlocked := _tools_unlocked()
	if plankton_unlocked != bloom_row.slider.editable:  # (the bloom stays in the box, faint, until plankton unlock)
		bloom_row.set_enabled(plankton_unlocked)
	if not feed_row.is_dragging() and not is_equal_approx(feed_row.value, snappedf(dish.feed_density, 0.1)):  # (a row being dragged reports nothing until it is let go: the dish's value would pull the handle back)
		feed_row.set_value_silently(dish.feed_density)
	if not bloom_row.is_dragging() and not is_equal_approx(bloom_row.value, snappedf(dish.bloom_density, Dish.BLOOM_DENSITY_STEP)):
		bloom_row.set_value_silently(dish.bloom_density)


func _update_hud() -> void:
	if not free_mode:
		_update_goal_card()
	if dish.population() == 0:
		return
	var about := "hud %s" % sim_speed
	if not _readout_due(vitals, about):
		return  # (nothing below is worth working out: the text would not be shown yet)
	_set_rich(vitals, Strings.t("hud.vitals", [_dish_lines(), SimClock.format(dish.time), _playback_text()]), about)
	# The readout takes the width its text needs (never less than it has needed, so it does not shrink and grow as the figures change), up to
	# a share of the bar; the hint beside it gets all the rest.
	_vitals_width = maxf(_vitals_width, vitals.get_content_width())
	vitals.custom_minimum_size.x = minf(_vitals_width, get_viewport_rect().size.x * VITALS_MAX_SHARE)
	_fit_top_bar()
	placed_row.value_text = UiText.thousands(dish.nutrients_placed)
	var stats := dish.population_stats()
	if _colony_rows.is_empty():
		for gene: String in Genome.LABELED:
			_add_colony_row(gene, Genome.label(gene))
		_add_colony_row("mutations", Strings.t("hud.colony_mutations"))
		_add_colony_row("harm", Strings.t("hud.colony_harm"))
		_add_colony_row("donor", Strings.t("hud.colony_donors"))
		_add_colony_row("key", Strings.t("hud.colony_key"))
		_add_colony_row("generation", Strings.t("hud.colony_generation"))
	for gene: String in Genome.LABELED:
		(_colony_rows[gene] as StatRow).value_text = Genome.format(gene, stats[gene])
	(_colony_rows["mutations"] as StatRow).value_text = "%.1f" % stats["mutations"]
	(_colony_rows["harm"] as StatRow).value_text = "%.1f%%" % (stats["harm"] * 100.0)
	(_colony_rows["donor"] as StatRow).value_text = "%.1f%%" % (stats["donor"] * 100.0)
	(_colony_rows["key"] as StatRow).value_text = "%.1f%%" % (stats["key"] * 100.0)
	(_colony_rows["generation"] as StatRow).value_text = UiText.thousands(stats["generation"], 1)
	_update_all_details()


## The all-dishes section: how many dishes run and how many bups they hold, and the traits averaged over every bup of every dish (each dish counts by its bups).
func _update_all_details() -> void:
	if not all_details.open:
		return
	if _all_rows.is_empty():
		for key: String in ["dishes", "bups"]:
			_add_all_row(key, Strings.t("hud.all_" + key))
		for gene: String in Genome.LABELED:
			_add_all_row(gene, Genome.label(gene))
		_add_all_row("mutations", Strings.t("hud.colony_mutations"))
		_add_all_row("harm", Strings.t("hud.colony_harm"))
		_add_all_row("donor", Strings.t("hud.colony_donors"))
		_add_all_row("key", Strings.t("hud.colony_key"))
		_add_all_row("generation", Strings.t("hud.colony_generation"))
	var total := 0.0
	var sums := {}
	for d in dishes:
		var stats := d.population_stats()
		var count := float(stats["count"])
		total += count
		for key: String in Genome.LABELED + ["mutations", "harm", "donor", "key", "generation"]:
			sums[key] = float(sums.get(key, 0.0)) + float(stats[key]) * count
	(_all_rows["dishes"] as StatRow).value_text = str(dishes.size())
	(_all_rows["bups"] as StatRow).value_text = UiText.thousands(total)
	var mean := func(key: String) -> float: return float(sums.get(key, 0.0)) / total if total > 0.0 else 0.0
	for gene: String in Genome.LABELED:
		(_all_rows[gene] as StatRow).value_text = Genome.format(gene, mean.call(gene))
	(_all_rows["mutations"] as StatRow).value_text = "%.1f" % mean.call("mutations")
	(_all_rows["harm"] as StatRow).value_text = "%.1f%%" % (mean.call("harm") * 100.0)
	(_all_rows["donor"] as StatRow).value_text = "%.1f%%" % (mean.call("donor") * 100.0)
	(_all_rows["key"] as StatRow).value_text = "%.1f%%" % (mean.call("key") * 100.0)
	(_all_rows["generation"] as StatRow).value_text = UiText.thousands(mean.call("generation"), 1)


func _add_all_row(key: String, label: String) -> void:
	var row: StatRow = preload("res://ui/stat_row.tscn").instantiate()
	row.label_text = label
	all_rows.add_child(row)
	_all_rows[key] = row


## The details key: the dish's details section opens or closes.
func _toggle_colony() -> void:
	dish_details.open = not dish_details.open


func _add_colony_row(key: String, label: String) -> void:
	var row: StatRow = preload("res://ui/stat_row.tscn").instantiate()
	row.label_text = label
	colony.add_child(row)
	_colony_rows[key] = row


## The pause menu's "Replay tutorial": back to the game, and the tutorial begins.
func _replay_tour() -> void:
	_close_menu()
	_start_tutorial.call_deferred()


## The tour of the screen: what each part does, in the order a first-time player needs it, asking for a click now and then so
## that what only shows while it is in use (the info panel, the watch list, the lineage) is there to be explained.
func _start_tutorial() -> void:
	_tutorial_was_paused = paused
	_tutorial_watched_before = dish.watched.duplicate()
	toolbar.set_paused(true)
	var steps: Array[Dictionary] = []
	steps.append(_tour("welcome"))
	if not free_mode:
		steps.append(_tour("goal", func() -> Rect2: return goal_card.get_global_rect()))
	steps.append(_tour("dish", func() -> Rect2: return dish.get_global_transform_with_canvas() * Rect2(-dish.radius, -dish.radius, 2.0 * dish.radius, 2.0 * dish.radius)))
	steps.append(_tour("readout", func() -> Rect2: return vitals.get_global_rect().grow(8.0)))
	steps.append(_tour("rates", func() -> Rect2: return _in_tray(dish_card)))
	steps.append(_tour("graph", func() -> Rect2: return _in_tray(graph_section), Callable(), _tutorial_show_graph))
	steps.append(_tour("tools", func() -> Rect2: return toolbar.select_button.get_global_rect().merge(toolbar.plankton_button.get_global_rect()), Callable(), Callable(), "" if free_mode else Strings.t("tutorial.tools_locked")))
	steps.append(_tour("tray", func() -> Rect2: return tool_options.get_global_rect()))
	steps.append(_tour("time", func() -> Rect2: return toolbar.pause_button.get_global_rect().merge(toolbar.speed_ultra_button.get_global_rect()).grow(4.0)))
	steps.append(_tour("layers", func() -> Rect2: return layers_panel.get_global_rect().grow(4.0)))
	steps.append(_tour("pick_bup", _tutorial_bup_rect, func() -> bool: return dish.selected_id >= 0, _tutorial_show_bup))
	steps.append(_tour("info", func() -> Rect2: return _in_tray(info_panel)))
	steps.append(_tour("genome", func() -> Rect2: return _in_tray(info_genome)))
	steps.append(_tour("watch", func() -> Rect2: return _in_tray(watch_button), func() -> bool: return dish.is_watched(dish.selected_id)))
	steps.append(_tour("watched", func() -> Rect2: return _in_tray(watch_section)))
	steps.append(_tour("lineage_open", func() -> Rect2: return _in_tray(lineage_button), _lineage_is_open, _tutorial_close_lineage))
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


## A narrow window gives the side column less width; the graph, in the column, is as tall as the window allows.
func _adapt_layout() -> void:
	var view := get_viewport_rect().size
	side.custom_minimum_size.x = clampf(view.x * 0.34, 316.0, 336.0 * UserSettings.text_factor())  # (its cards need more room as the text grows)
	graph.custom_minimum_size.y = clampf(view.y * 0.22, 170.0, 260.0)  # (it grows with the window: it is one of the things worth reading)
	_fit_top_bar()  # (a narrow top bar keeps its room for the vitals and the playback)


## The top bar never needs more than the window has. The readout and the controls come first; the dish tabs take everything that is left (they scroll
## when there are more than fit), and when even a short strip does not fit, the layer toggles go (their keys still work).
func _fit_top_bar() -> void:
	var room := get_viewport_rect().size.x - 64.0  # (the screen's margin, the bar's padding and the frames of the tabs and toggles)
	var fixed := playback_panel.get_combined_minimum_size().x + menu_button.get_combined_minimum_size().x
	var vitals_w := minf(_vitals_width, get_viewport_rect().size.x * VITALS_MAX_SHARE)
	var tabs_full := dish_strip.full_width() if dish_strip.visible else 0.0
	var views_w := views.get_combined_minimum_size().x
	var gaps := 12.0 * (4.0 if tabs_full == 0.0 else 5.0)  # (between the readout, the tabs, the spacer, the toggles, the playback and the menu)
	var left_with_views := room - vitals_w - fixed - views_w - gaps
	var show_views := tabs_full == 0.0 or left_with_views >= minf(tabs_full, MIN_TABS_WIDTH)
	if tabs_full > 0.0:
		dish_strip.max_width = maxf(left_with_views if show_views else left_with_views + views_w + 12.0, 60.0)
	views.visible = show_views


## The stage changed size (the window, or the interface size): the dish is framed again, unless the view has been moved.
func _on_stage_resized() -> void:
	if following_id < 0 and not _view_moved:
		_fit_camera()


## The top bar's bups: how many there are, and (in free mode, where you can change it) the dish's bup limit.
func _dish_lines() -> String:
	if not free_mode:
		return Strings.t("hud.readout_bups", [dish.population()])
	return Strings.t("hud.readout_bups_limit", [dish.population(), dish.bup_limit])


## The playback speed, and the speed actually achieved when the simulation can't keep up with it.
func _playback_text() -> String:
	if _pipette_waiting:
		return Strings.t("hud.pipette_paused")
	var slow := sim_speed > 1.0 and achieved_speed < 0.85 * sim_speed  # (while paused the speed it reached stays what it was: nothing updates it)
	if paused:
		if slow:
			return Strings.t("hud.playback_slow_paused", [int(sim_speed), int(achieved_speed)])
		return Strings.t("hud.playback_speed_paused", [int(sim_speed)])
	if slow:
		return Strings.t("hud.playback_slow", [int(sim_speed), int(achieved_speed)])
	return Strings.t("hud.playback_speed", [int(sim_speed)])


## The goal card: which experiment, its title and text, a bar of how near it is to being met, and the progress line.
## Its text only changes with the goal, and the figures only at the rate the readouts use.
func _update_goal_card() -> void:
	var goal := tracker.current()
	if goal == null:
		goal_kicker.text = ""
		goal_title.text = Strings.t("hud.goal_all_done_title")
		_set_rich(goal_text, Strings.t("hud.goal_all_done_text"), "goal")
		goal_bar.value = 1.0
		goal_status.text = ""
		return
	if goal_title.text != goal.title:
		goal_kicker.text = Strings.t("hud.goal_kicker", [tracker.index + 1, tracker.goals.size()])
		goal_title.text = goal.title
		goal_text.set_meta("raw", "")  # (the text is for another goal)
		_set_rich(goal_text, goal.text, "goal text")
	if not _readout_due(goal_status, "goal"):
		return
	goal_status.set_meta("about", "goal")
	goal_status.set_meta("set_at", Time.get_ticks_msec())
	goal_bar.value = goal.progress.call(dish)
	var line: String = goal.status.call(dish)
	if goal.hold_time > 0.0 and tracker.held > 0.0:
		line += Strings.t("hud.goal_holding", [SimClock.format(tracker.held), SimClock.format(goal.hold_time)])
	goal_status.text = line


## Shows text with its numbers styled. The readouts refresh every frame, so the styling (a
## regex pass) and the re-parse only run when the text has actually changed.
## Sets a readout's text. `about` says what the text is about (a bup, the medium at a point...): while the same thing
## stays shown at high playback speed, its figures change at most every LIVE_TEXT_MSEC, since they would only flicker.
## True when the text was changed.
func _set_rich(label: RichTextLabel, text: String, about: String, flash := false) -> bool:
	var shown := text + ("\u0001" if flash else "")  # (what is asked for: the text, and whether its first number is flashing)
	if label.get_meta("raw", "") == shown or not _readout_due(label, about):
		return false
	label.set_meta("about", about)
	label.set_meta("set_at", Time.get_ticks_msec())
	label.set_meta("raw", shown)
	label.text = UiText.numbers(text, "divisions" if flash else "")
	return true


## Whether a readout would take new text about `about` now (see _set_rich). Asked before working the text out, so that
## at high playback speed, where most frames change nothing, it is not worked out for nothing.
func _readout_due(label: Control, about: String) -> bool:
	var live := not paused and sim_speed >= LIVE_TEXT_FROM_SPEED
	return not (live and label.get_meta("about", "") == about and Time.get_ticks_msec() - label.get_meta("set_at", 0) < LIVE_TEXT_MSEC)


## _set_rich with the text worked out (by `make_text`) only if it is due.
func _set_rich_when_due(label: RichTextLabel, about: String, make_text: Callable) -> void:
	if _readout_due(label, about):
		_set_rich(label, make_text.call(), about)
