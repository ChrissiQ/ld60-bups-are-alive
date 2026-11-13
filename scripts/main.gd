extends Node2D

const BANNER_SECONDS := 7.0
const BANNER_BRIEF_SECONDS := 1.5  ## how long a short banner stays up
const PIPETTE_PULSE_SECONDS := 0.5  ## the pipette button's fade each way while the timer holds the game
const PIPETTE_PULSE_LOW := 0.35  ## the opacity it fades to
const PIPETTE_STILL_ALPHA := 0.5  ## its opacity under reduced motion (lit, not pulsing)
const TUTORIAL_ZOOM := 6.0  ## how close the tutorial brings the camera to a bup it asks the player to click
const TUTORIAL_BUP_PIXELS := 18.0  ## the lit square round that bup is this far out on each side
const MAX_DISHES := 999  ## the most dishes running at once, and the highest number a dish is shown by: an interface choice (three digits), not the world's limit (GpuLayout.D_MAX rows)
const RECORD_BUDGET_USEC := 1000  ## the most of a frame spent recording the parked dishes' history samples (about 10 us a dish)
const LONGEST_CLOCK_HOURS := 999999  ## the top bar keeps room for the clock up to this many hours: about 114 years of simulated time, 100 hours of play at x10,000

@onready var dish: Dish = $Dish
@onready var camera: Camera2D = $Camera
@onready var vitals: RichTextLabel = %Readout  ## the top bar: how many bups, the time and the playback speed
@onready var placed_row: StatRow = %PlacedRow  ## the dish card's details: how many nutrient doses you placed
@onready var dish_details: TraySection = %DishDetails  ## the dish in the main view: what was placed, and the colony's averages (the details key opens and closes it)
@onready var colony: TraitRows = %Colony  ## the details: the placed row, then the colony's average traits, one row each (made as they are first shown)
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
@onready var all_rows: TraitRows = %AllRows
@onready var freezer_section: TraySection = %FreezerSection  ## the frozen dishes (hidden while there are none)
@onready var freezer_shelf: FreezerShelf = %FreezerShelf  ## the freezer's content: the frozen dishes and the button that freezes the one in view
@onready var old_dish_dialog: AcceptDialog = $MenuLayer/OldDishDialog
@onready var trash_dialog: ConfirmationDialog = $MenuLayer/TrashDishDialog  ## asks before a dish is trashed from its card or the freezer
@onready var card_actions: DishActions = %CardActions  ## freeze or trash, on the dish card
@onready var graph_controls: GraphControls = %GraphControls  ## the graph's switches and trait drop-down
@onready var playback_panel: Control = %Playback  ## the pause and speed buttons in the top bar
@onready var views: Control = %Views  ## the graph and layer toggles in the top bar
@onready var top_bar_row: HBoxContainer = %TopBar.get_node("Rows/Bar")  ## the top bar's first row: readout, dish tabs, toggles, playback, menu
@onready var speed_readout: RichTextLabel = %SpeedReadout  ## the playback speed, in the second row (instead of the readout's end) while there is one
@onready var top_bar_more_row: HBoxContainer = %MoreRow  ## its second row, there while the toggles do not fit in the first (the playback and the dish tabs join them in it)
@onready var menu_button: Button = %MenuButton
@onready var side: ScrollContainer = %Side  ## the side column: the goal, what is picked or the dish, the watch list (it scrolls when the window is too short for all of it)
@onready var stage: Control = %Stage  ## the free middle of the screen, between the rail, the side column, the top bar and the bottom bar: the dish is framed in it
@onready var toolbar: Toolbar = %Toolbar
@onready var tool_options: ToolOptions = %ToolOptions
@onready var feed_row: SettingRow = %FeedRow
@onready var bloom_row: SettingRow = %BloomRow  ## how often plankton appear
@onready var watch_section: TraySection = %WatchSection  ## the tray's "Watching" section: a plain tray section like the rest, holding the list
@onready var watch_list: WatchList = %WatchList
@onready var tutorial: Tutorial = $TutorialLayer/Tutorial  ## the guided tour, when it is wanted (see Session.tutorial_wanted)
@onready var layers_panel: LayersPanel = %LayersPanel  ## what the dish shows: each kind of thing can be hidden
@onready var dish_strip: DishStrip = %DishStrip  ## a thumbnail of every dish when there are several
@onready var hud_layer: CanvasLayer = $HUD
@onready var pause_menu: PauseMenu = $MenuLayer/PauseMenu
@onready var end_dialog: ConfirmationDialog = $MenuLayer/EndDialog
@onready var memory_notice: AcceptDialog = $MenuLayer/MemoryNoticeDialog  ## says what the computer's memory means for this game (`MemoryMode.start_notices`)
@onready var pause_ring: Panel = %PauseRing

## The two modes share everything (dish, evolution, HUD, controls). Free mode differs in
## exactly two ways: no goals, and no saving.
var free_mode := Session.mode == Session.Mode.FREE
var save_path := SaveGame.PATH  ## where the game is saved and loaded from (a test sets a scratch file before the screen is in the tree)
var tracker := GoalTracker.new()
var dishes: Array[Dish] = []  ## every dish that runs; `dish` is the one in the main view and the only one shown (the others are parked, Dish.park: see the strip). Every dish sits at the screen's origin, so what is drawn is in the main dish's own coordinates
var _view_before_extinct: Dish = null  ## the dish that was in the main view when the first dish in `_extinct_queue` was brought into view: the view goes back to it afterwards
var _extinct_queue: Array[Dish] = []  ## dishes that have died out and are not yet deleted (the first is the one the screen has said so about)
var _dish_numbers := {}  ## Dish -> the number it is shown by, 1 to MAX_DISHES (`_take_label`); its ids and the family tree use its world number, Dish.number
var _next_dish_number := 1  ## the world number (Dish.number) the next dish takes: never reused in a game, so no two bups ever share an id (a pipette's new dish takes the one the simulation gives it, and this moves past it)
var _labels_given := 0  ## the shown numbers handed out so far this game: one by one up to MAX_DISHES, then the lowest free one is taken again
var _label_of := {}  ## world number -> the number it was shown by, for every dish of this game (a bup that moved to a dish since gone names it so)
var game_began := 0.0  ## the world time this game began at: the world's clock runs from the start of the program, so what the screen shows is the time since
var _world_last := -1.0  ## the world's time at the last frame (-1: none yet)
var holds: PlayHolds  ## what holds the game besides the player: the pipette's timer (&"pipette"), the question about the old dish (&"old_dish"), the tour (&"tour"), the end of the game (&"end"), and quietly the wait for the simulation's answer (&"sim_reply")
var _pipette_hours := 0.0  ## the pipette timer: the game pauses for the pipette every this many simulated hours (0: off)
var _pipette_clock := 0.0  ## simulated seconds since the last pause for the pipette
var _pipette_pulse: Tween
var stage_input := StageInput.new()  ## the camera and the pointer on the stage
var tool: Toolbar.Tool:  ## the selected tool (kept in step with the toolbar's selection: see _on_tool_selected)
	get:
		return stage_input.tool
var sim_speed := 1.0  ## seconds of simulation per real second (the toolbar sets it)
var achieved_speed := 1.0  ## what the simulation actually managed lately: lower than sim_speed when the frame budget cut a step short
var paused := false
var _entry_to_trash := {}  ## the frozen dish (a freezer entry) the trash question is about, or empty when it is about `_to_trash`
var _to_trash: Dish  ## the dish the trash question (from its card or the freezer) is about
var _old_dish: Dish  ## the dish a pipette took bups from, while the question about it is up (null: no question)
var _pipette_pending := {}  ## a pipette waiting for the simulation's answer: {reply, source}
var _thawing := {}  ## row -> {entry, dish}: an unfrozen dish the simulation has not shown yet (its entry stays in the freezer until it has; a refusal puts it back as it was)
var _asked_rows := {}  ## row -> the Dish added there, until a snapshot shows it (a refusal takes it out again)
var _by_row := {}  ## world row -> the running dish in it (`_dish_in_row`)
var _by_row_count := -1  ## how many dishes ran when `_by_row` was made
var _to_record: Array = []  ## parked dishes holding history samples not yet recorded, oldest first (`_record_parked_history`; untyped: one may be freed meanwhile)
var _save_pending: SimReply = null  ## a save waiting for the simulation's dishes (the goal's: the quit save waits for them instead)
var _left_empty: Dish = null  ## the last running dish, died out while dishes are frozen: the next unfrozen dish takes its place
var _vitals_full_width := 0.0  ## the width the top bar's readout keeps in one row: its longest possible text with the playback speed at its end (see _measure_readouts)
var _vitals_short_width := 0.0  ## and with the speed in the second row
var _speed_width := 0.0  ## the width the speed readout keeps in the second row: its longest possible text
var _readout_height := 0.0  ## a line of the readouts
var _readouts_measured_for := []  ## what those widths were measured for: [the readout's font size, free mode, the digits of the bup limit]
var _limit_digits_for := []  ## [running dishes, the main dish's bup limit] when `_limit_digits` was worked out
var _limit_digits := 0  ## the most digits any running dish's bup limit has
var menu_open: bool:  ## the Escape menu is up: the game is frozen behind it and takes no input
	get:
		return pause_menu.visible
var readout := Readout.new()  ## how the readouts are rewritten (see Readout)
var inspector := Inspector.new()  ## the panels about what is picked, and the hover card
var lineage := LineageView.new()  ## the views opened on bups (info, lineage) and the lineage list
var _tutorial_bup := -1  ## the bup the tour asked the player to pick, once it has set the view up for that (-1: it has not)
var _tutorial_look_pending := false  ## the camera waits for the world to say where the tour's bup is
var _tutorial_watched_before: Array[int] = []  ## who was on the watch list when the tour began, so it takes off only whom it put there
var _banner_left := 0.0

# Left/middle-button press tracking, to tell a click from a drag.


func _ready() -> void:
	UserSettings.ensure_applied()
	holds = PlayHolds.new(toolbar)
	WorldClient.shared().refused.connect(_on_refused)
	WorldClient.shared().snapshot_changed.connect(_on_snapshot)
	stage_input.host = self
	stage_input.camera = camera
	stage_input.stage = stage
	stage_input.tool_options = tool_options
	stage_input.dish = dish
	stage_input.clicked.connect(_click)
	lineage.dishes = dishes
	lineage.numbers = _dish_numbers
	lineage.dish = dish
	readout.is_live = func() -> bool: return not paused and sim_speed >= Readout.LIVE_TEXT_FROM_SPEED
	inspector.dish = dish
	inspector.number_of = func(d: Dish) -> int: return _dish_numbers[d]
	inspector.bind(self, lineage, readout)
	inspector.follow_pressed.connect(stage_input.toggle_follow)
	inspector.close_pressed.connect(_clear_selection)
	inspector.info_genome.entry_requested.connect(_open_encyclopedia)
	lineage.info_opened.connect(stage_input.stop_following)
	inspector.label_of = _label_for
	dish.number = _next_dish_number
	_next_dish_number += 1
	_register_dish(dish)
	dish_strip.dish_chosen.connect(set_main_dish)
	_apply_tray_order()
	UserSettings.listen_tray(_apply_tray_order)
	tracker.goal_completed.connect(_on_goal_completed)
	toolbar.tool_selected.connect(_on_tool_selected)
	toolbar.zoom_in_requested.connect(stage_input.zoom_by.bind(StageInput.ZOOM_BUTTON_STEP))
	toolbar.zoom_out_requested.connect(stage_input.zoom_by.bind(1.0 / StageInput.ZOOM_BUTTON_STEP))
	tool_options.pick_mode_selected.connect(_on_pick_mode_selected)
	tool_options.pipette_timer_changed.connect(_set_pipette_timer)
	toolbar.speed_selected.connect(func(multiplier: float) -> void:
		sim_speed = multiplier
		achieved_speed = multiplier)
	toolbar.pause_toggled.connect(_set_paused)
	end_dialog.confirmed.connect(_start_again)
	end_dialog.get_cancel_button().pressed.connect(_quit_to_menu)  # (only the button leaves: the window's cross and Escape do not, so the choice is always a deliberate one)
	end_dialog.visibility_changed.connect(func() -> void:
		if holds.has(&"end") and not end_dialog.visible:
			end_dialog.popup_centered.call_deferred())
	pause_menu.resume_requested.connect(_close_menu)
	pause_menu.quit_requested.connect(_quit_to_menu)
	pause_menu.tour_requested.connect(_replay_tour)
	pause_menu.dish_radius_chosen.connect(_resize_dish)
	pause_menu.bup_limit_chosen.connect(func(limit: int) -> void: dish.change_limit(limit))
	graph.dish = dish
	graph.dishes = dishes
	banner.text = ""
	feed_row.configure(0.0, StartConditions.MAX_FEED_DENSITY, 0.1, 0.0, Strings.t("hud.rate_unit_feed"))
	feed_row.value_changed.connect(func(v: float) -> void: dish.feed_density = v)
	bloom_row.configure(0.0, StartConditions.MAX_BLOOM_DENSITY, Dish.BLOOM_DENSITY_STEP, 0.0, Strings.t("hud.rate_unit_bloom"))
	bloom_row.disabled_reason = Strings.t("hud.rate_bloom_locked")
	bloom_row.value_changed.connect(func(v: float) -> void: dish.bloom_density = v)
	watch_list.dishes = dishes
	watch_list.numbers = _dish_numbers
	layers_panel.layer_toggled.connect(func(layer: Dish.Layer, shown: bool) -> void:  # (what is shown is one choice for every dish)
		for d in dishes:
			d.show_layer(layer, shown))
	watch_list.bup_chosen.connect(_open_watched)
	stage.resized.connect(stage_input.on_stage_resized)
	get_viewport().size_changed.connect(_adapt_layout)
	_adapt_layout()
	graph_controls.setup(graph)
	all_rows.set_lead("dishes", Strings.t("hud.all_dishes"))
	all_rows.set_lead("bups", Strings.t("hud.all_bups"))
	_setup_old_dish_dialog()
	freezer_shelf.freeze_requested.connect(func() -> void: freeze_dish(dish))
	freezer_shelf.trash_requested.connect(_ask_to_trash)
	card_actions.freeze_requested.connect(func() -> void: freeze_dish(dish))
	card_actions.trash_requested.connect(_ask_to_trash)
	trash_dialog.confirmed.connect(func() -> void:
		if not _entry_to_trash.is_empty():
			_trash_frozen(_entry_to_trash)
		elif is_instance_valid(_to_trash):
			trash_dish(_to_trash)
		_entry_to_trash = {})
	trash_dialog.canceled.connect(func() -> void: _entry_to_trash = {})
	freezer_shelf.trash_entry_requested.connect(_ask_to_trash_frozen)
	freezer_shelf.thaw_requested.connect(thaw)
	freezer_section.visible = free_mode  # (the goals' dish is the only one: nothing to freeze)
	card_actions.visible = free_mode
	menu_button.pressed.connect(_open_menu)
	menu_button.tooltip_text = Strings.t("hud.menu_tip")
	_on_tool_selected(toolbar.current_tool())  # the toolbar decides the starting tool
	_on_pick_mode_selected(tool_options.pick_mode())  # and its tray the starting mode
	goal_card.visible = not free_mode  # (free mode has no goals; how its dish began is on the Escape menu)
	var data := SaveGame.read(save_path) if Session.load_requested and not free_mode else {}
	Session.load_requested = false
	var blob: DishBlob = DishCodec.read_blob(data["dish"]) if not data.is_empty() else null
	if blob != null:
		var now := world_time()
		_carry_to(blob, now)
		var saved := DishHistory.read(blob.host.get("history", {}))
		_begin_game(now if saved.is_empty() else float(saved["origin"]))  # (the goals' dish began with the game, its history says when)
	if blob == null or not dish.load_blob(blob):
		if not data.is_empty():
			SaveGame.delete(save_path)  # (a save that will not load is no save: the title screen stops offering it)
		_begin_dish()
	else:
		if dish.row >= 0:
			_asked_rows[dish.row] = dish
		_next_dish_number = maxi(_next_dish_number, dish.number + 1)  # (the saved dish keeps its world number, and so its bups' ids)
		_label_of[dish.number] = _dish_numbers[dish]
		tracker.from_dict(data["goals"])
		stage_input.fit_camera()
	_sync_tool_locks()
	layers_panel.sync_from(dish)
	tool_options.set_husks_available(dish.has_husks())
	stage_input.refit_when_laid_out.call_deferred()
	tutorial.closed.connect(_on_tutorial_closed)
	if Session.tutorial_wanted:
		Session.tutorial_wanted = false
		_start_tutorial.call_deferred()  # (once the screen has been laid out, so the tour can point at it)
	else:
		_show_memory_notices.call_deferred()


## Tells what low-memory mode is, once per notice text (a new game on the same computer does not repeat it). The notices are one dialog the
## player closes; they wait for the tutorial when it runs.
func _show_memory_notices() -> void:
	var notices := MemoryMode.start_notices()
	var text := "\n\n".join(notices)
	if text.is_empty() or text == MemoryMode.last_notice:
		return
	MemoryMode.last_notice = text
	memory_notice.dialog_text = text
	memory_notice.popup_centered()


## Puts the tray's sections in the order the player chose (Options' reset puts them back as the scene has them).
func _apply_tray_order() -> void:
	TraySection.apply_order(graph_section.get_parent())


## The freezer is not kept beyond the game (nor saved): the family tree lets go of what it kept for the frozen dishes.
func _exit_tree() -> void:
	var w := WorldClient.shared()
	if w != null:
		var store := w.lineage()
		if store != null:
			for entry: Dictionary in freezer_shelf.entries:
				store.discard_frozen(int(entry["number"]))
		if w.refused.is_connected(_on_refused):
			w.refused.disconnect(_on_refused)
		if w.snapshot_changed.is_connected(_on_snapshot):
			w.snapshot_changed.disconnect(_on_snapshot)
	UserSettings.unlisten_tray(_apply_tray_order)
	Encyclopedia.set_fact("husks", false)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


func _begin_dish() -> void:
	_begin_game(world_time())  # (the game begins with its dish, at the world's time)
	dish.strike(Session.free_start if free_mode else null)
	if dish.row >= 0:
		_asked_rows[dish.row] = dish
	tracker.apply_costs(dish)  # (strike resets it: experiment 2 and after costs what it did)
	stage_input.fit_camera()
	if free_mode:
		toolbar.set_paused(true)  # the playground starts paused so you can set the scene


## The game's clock begins at `world` (the world's time then): the readout, the graph with every dish together, the freezer and the family
## tree's births and deaths count from it. The world is told before the game's first dish is asked for (WorldClient.begin_game: the
## dishes' numbers start again too).
func _begin_game(world: float) -> void:
	game_began = world
	graph.game_began = world
	WorldClient.shared().begin_game(world)


## A save is read into a world whose clock is not the one it was saved on: the times its history keeps go with the world's (the
## simulation moves its plankton's and bloom's, DishWorld.load_blob), so it carries on as though no time had passed. `now`: the world's time.
static func _carry_to(blob: DishBlob, now: float) -> void:
	var gap := now - float(blob.world.get("time", now))
	var saved: Variant = blob.host.get("history")
	if saved is Dictionary and Validate.is_number(saved.get("history_origin")):
		saved["history_origin"] = float(saved["history_origin"]) + gap


## The world's time, as the newest snapshot has it.
func world_time() -> float:
	return WorldClient.shared().latest().sim_time


## Once a frame: the world is told the speed, whether it stands still (the player's pause, the menu, a wait for the simulation's answer)
## and the frame's real length (it owes speed x the frame, and caps it). Returns how far its clock moved since the last frame.
func _advance_world(real_dt: float) -> float:
	var w := WorldClient.shared()
	w.set_time(sim_speed, paused or menu_open or holds.stills_world(), real_dt)
	var now := w.latest().sim_time
	var moved := 0.0 if _world_last < 0.0 else maxf(now - _world_last, 0.0)
	_world_last = now
	return moved


## Nutrient tools are a free-mode toy and a reward in goal mode: they unlock with experiment 2,
## so experiment 1 is about what a random supply does and experiment 2 about what a placed one does.
func _tools_unlocked() -> bool:
	return free_mode or tracker.tools_unlocked()


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


## Extinct colonies aren't saved, so a wipe-out never overwrites a good save. The simulation gathers every running dish for it; the quit
## save (`now`) is the one place the game waits for its answer, any other save is written when the answer comes.
func save_game(now := true) -> void:
	if free_mode or dish.population() == 0 or dish.row < 0:
		return
	var reply := WorldClient.shared().save_all()
	if now:
		_write_save(reply.wait())
	else:
		_save_pending = reply
		_sync_reply_hold()


func _write_save(blobs: Variant) -> void:
	for blob: DishBlob in (blobs if blobs is Array else []):
		if blob.number() == dish.number:
			blob.host.merge(dish.host_part(), true)
			SaveGame.write({"dish": DishCodec.write_blob(blob), "goals": tracker.to_dict()}, save_path)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game()


func _process(delta: float) -> void:
	holds.enforce()  # (the game waits while the tour is up, even on a step that asks the player to act)
	if not menu_open and not tutorial.active:
		stage_input.pan_with_keys(delta)
	_finish_pipette()
	_finish_replies()
	_record_parked_history()
	# The playback speed is how many seconds of simulation pass per real second: the simulation is told the frame's real length.
	var done := _advance_world(delta)
	dish.take_picture()  # (before the camera follows a bup: it follows the place this frame draws)
	if not paused and not menu_open:
		var snap := WorldClient.shared().latest()
		if snap.seq > 0 and not holds.stills_world():
			achieved_speed = snap.achieved_speed
		if _pipette_hours > 0.0 and not holds.has(&"pipette"):
			_pipette_clock += done
			if _pipette_clock >= _pipette_hours * 3600.0:
				_begin_pipette_wait()
		if not free_mode:
			tracker.update(dish, done)
	_show_memory_warning()
	_banner_left = maxf(0.0, _banner_left - delta)
	if _banner_left == 0.0:
		banner.text = ""
	stage_input.update_pointer()
	_tutorial_look()
	_update_info_panel()
	inspector.place_hover_card()
	stage_input.follow_selected()
	dish.refresh_drawing()
	graph.refresh()
	_show_graph_choices()
	watch_list.refresh()
	dish.want_thumbnails = dish_strip.visible
	dish_strip.refresh(delta)
	_update_hud()
	_sync_bloom_panel()


## The panels about what is picked, brought up to date.
func _update_info_panel() -> void:
	inspector.update(stage_input.following_id >= 0, stage_input.hover_point if stage_input.hovering_point else null)


## An entry of the watch list was clicked: that bup (living or not), in whichever dish it is in, in the inspect panel.
func _open_watched(watched_in: Dish, id: int) -> void:
	set_main_dish(watched_in)  # (the bup may be in another dish: the view goes there)
	if not dish.has_record(id):
		return
	tool_options.show_all()  # (a mode that skips bups would let go of it again)
	dish.selected.bup = id
	stage_input.stop_following()


## The select tool now looks at something else: a selection of a kind it no longer looks at is let go.
func _on_pick_mode_selected(mode: Dish.PickMode) -> void:
	dish.pick_mode = mode  # (which also lets go of a selection the mode doesn't look at)


func _on_tool_selected(new_tool: Toolbar.Tool) -> void:
	stage_input.tool = new_tool
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
		"following": stage_input.following_id,
		"views_open": lineage.depth(),
		"camera_position": [camera.position.x, camera.position.y],
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
		"tray_open": {"dish": inspector.dish_card.open, "graph": graph_section.open, "dish_details": dish_details.open, "all_details": all_details.open},
		"dish_strip": {"visible": dish_strip.visible, "tabs_made": dish_strip.tabs_made()},
		"watched_total": dishes.reduce(func(n: int, d: Dish) -> int: return n + d.watched.size(), 0),
		"world_time": world_time(),
		"game_time": world_time() - game_began,
		"waiting_for_sim": holds.stills_world(),
		"dishes": dishes.map(func(d: Dish) -> Dictionary: return {"number": _dish_numbers[d], "world_number": d.number, "bups": d.population(), "time": d.time, "history_origin": d.history.origin, "row": d.row, "husks": d.husk_count()}),
		"freezer": freezer_shelf.entries.map(func(entry: Dictionary) -> Dictionary: return {"number": entry["label"], "world_number": entry["number"], "bups": entry["bups"], "frozen_at": entry["data"].get("time", 0.0)}),
	}


## Only input the GUI didn't consume arrives here, so clicks on the toolbar never reach the dish.
func _unhandled_input(event: InputEvent) -> void:
	if _old_dish != null:
		return  # (a question about the old dish is up: nothing else is done until it is answered)
	if holds.stills_world():
		return  # (the simulation has not answered yet: a frame or a few)
	if menu_open:  # only Escape reaches the game while the menu is up, and it closes the menu
		if UiInput.is_escape_press(event) and not pause_menu.close_panel():
			_close_menu()
		return
	if event is InputEventKey:
		if event.pressed and not event.echo:
			_on_key(event)
	else:
		stage_input.handle(event)


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
			inspector.delete_selected_source()
	elif KeyBindings.matches("details", event):
		_toggle_colony()
	elif KeyBindings.matches("graph_trait", event):
		graph.cycle_trait()
	elif KeyBindings.matches("graph_span", event):
		graph.cycle_span()
	elif KeyBindings.matches("graph_show", event):
		graph_section.open = not graph_section.open
	elif KeyBindings.matches("frame", event):
		stage_input.fit_camera()
	elif KeyBindings.matches("follow", event):
		if dish.selected.bup >= 0 and dish.has_bup(dish.selected.bup):
			stage_input.toggle_follow()
	elif KeyBindings.matches("watch", event):
		if dish.selected.bup >= 0 and dish.has_record(dish.selected.bup):
			inspector.toggle_watch()
	elif KeyBindings.matches("lineage", event):
		lineage.open_lineage()
	elif layers_panel.toggle_for_key(event):
		pass
	elif KeyBindings.matches("dish_prev", event):
		_step_dish(-1)
	elif KeyBindings.matches("dish_next", event):
		_step_dish(1)
	elif KeyBindings.matches("slower", event):
		toolbar.step_speed(-1)
	elif KeyBindings.matches("faster", event):
		toolbar.step_speed(1)


## Escape lets go of a selection first, and only with nothing selected opens the menu.
func _escape() -> void:
	if lineage.depth() > 1:  # a lineage (or a bup reached through one) is open: back one step
		lineage.step_back()
	elif dish.has_selection():
		_clear_selection()
	else:
		_open_menu()


## Lets go of everything selected: the bup (with whatever views were opened on it) and any source.
func _clear_selection() -> void:
	lineage.clear()
	dish.clear_selection()
	stage_input.stop_following()


func _open_menu() -> void:
	hud_layer.process_mode = Node.PROCESS_MODE_DISABLED  # no toolbar shortcuts or clicks behind the menu
	dish.clear_hover()
	Encyclopedia.set_fact("husks", dishes.any(func(d: Dish) -> bool: return d.has_husks()))  # (the game's husk options: any running dish having one)
	pause_menu.open(dish, free_mode, Session.free_start)


func _close_menu() -> void:
	pause_menu.close()
	_sync_hud_input()


## The top bar, the tools and the tray take input unless the menu is up or the game waits for the simulation's answer.
func _sync_hud_input() -> void:
	hud_layer.process_mode = Node.PROCESS_MODE_DISABLED if menu_open or holds.stills_world() else Node.PROCESS_MODE_INHERIT


## The quiet hold (PlayHolds.hold_quietly) is on while an answer is awaited: a pipette's, a freeze's, an unfrozen dish not shown yet, a save.
func _sync_reply_hold() -> void:
	var waiting := not _pipette_pending.is_empty() or not _thawing.is_empty() or _save_pending != null or freezer_shelf.entries.any(_waits)
	if waiting:
		holds.hold_quietly(&"sim_reply")
	else:
		holds.release(&"sim_reply")
	_sync_hud_input()


## Whether a freezer entry's dish is still on its way out of the world (its freeze has not answered).
static func _waits(entry: Dictionary) -> bool:
	var reply: SimReply = entry.get("reply")
	return reply != null and not reply.is_done()


## Once a frame: the answers that have come. A frozen dish whose blob has come is unfrozen or trashed if that was asked meanwhile; one the
## simulation could not freeze (it answered with nothing) leaves the freezer; a save is written.
func _finish_replies() -> void:
	for entry: Dictionary in freezer_shelf.entries.duplicate():
		if _waits(entry):
			continue
		if entry.get("reply") != null and (entry["reply"] as SimReply).value() == null:
			freezer_shelf.remove(entry)
			continue
		var then: String = entry.get("then", "")
		entry.erase("then")
		match then:
			"thaw":
				thaw(entry)
			"trash":
				_trash_frozen(entry)
	if _save_pending != null and _save_pending.is_done():
		_write_save(_save_pending.value())
		_save_pending = null
	_sync_reply_hold()


## The newest snapshot: an added or unfrozen dish it shows is in the world for good (an unfrozen one leaves the freezer then, and takes the
## place of the last running dish if that one had died out).
func _on_snapshot(snap: Snapshot) -> void:
	var due := {}  # (the parked dishes hear only what they must not miss: new history samples, a new copy of their world, dying out)
	for row: int in snap.history:
		if not (snap.history[row] as Array).is_empty():
			due[row] = true
	for row: int in snap.worlds:
		due[row] = true
	for row: int in snap.totals.get("extinct", []):
		due[row] = true
	for row: int in due:
		var d := _dish_in_row(row)
		if d != null and d.is_parked():
			var had := d.has_unrecorded()
			if d.take_parked(snap) and not had:
				_to_record.append(d)
	for row: int in _asked_rows.keys():
		var ds: DishState = snap.dishes.get(row)
		if ds != null and ds.number == (_asked_rows[row] as Dish).number:
			_asked_rows.erase(row)
	for row: int in _thawing.keys():
		var ds: DishState = snap.dishes.get(row)
		if ds != null and ds.number == (_thawing[row]["dish"] as Dish).number:
			_thawed(row)


## Records the history samples the parked dishes were handed, oldest first, for at most RECORD_BUDGET_USEC a frame: a snapshot can bring a
## sample for every dish at once, and recording a thousand at once would hold up a frame. (A history that is read records its own first.)
func _record_parked_history() -> void:
	var until := Time.get_ticks_usec() + RECORD_BUDGET_USEC
	var k := 0
	while k < _to_record.size() and Time.get_ticks_usec() < until:
		var d: Variant = _to_record[k]
		if is_instance_valid(d):
			(d as Dish).record_history(until)
			if (d as Dish).has_unrecorded():  # (the time ran out part way through it: it goes on next frame)
				break
		k += 1
	if k > 0:
		_to_record = _to_record.slice(k)


## The running dish in world row `row` (null: none). The table is made again after a dish came, went or lost its row (`_by_row_count` -1),
## and when a dish it has is in another row now.
func _dish_in_row(row: int) -> Dish:
	var found: Variant = _by_row.get(row)  # (untyped: a dish freed since the table was made is no Dish)
	if _by_row_count != dishes.size() or (found != null and (not is_instance_valid(found) or (found as Dish).row != row)):
		_by_row.clear()
		_by_row_count = dishes.size()
		for each in dishes:
			if each.row >= 0:
				_by_row[each.row] = each
		found = _by_row.get(row)
	return found


func _thawed(row: int) -> void:
	var t: Dictionary = _thawing[row]
	_thawing.erase(row)
	freezer_shelf.remove(t["entry"])
	var d: Dish = t["dish"]
	if _left_empty != null and dishes.has(_left_empty) and dishes.has(d):
		set_main_dish(d)
		_remove_dish(_left_empty)
		_show_banner("", 0.0)
	_left_empty = null
	_sync_reply_hold()


## The simulation refused a dish this screen added or unfroze: there was no room for it in the graphics memory (with MAX_DISHES rows far
## below the world's, that is the only refusal it can have). An unfrozen dish's entry stays in the freezer, as it was; the dish's node goes.
## A pipette's refusal comes with its reply (`_finish_pipette`).
func _on_refused(row: int, _why: String) -> void:
	var d: Dish = null
	if _thawing.has(row):
		d = _thawing[row]["dish"]
		(_thawing[row]["entry"] as Dictionary).erase("thawing")
		_thawing.erase(row)
	elif _asked_rows.has(row):
		d = _asked_rows[row]
		_asked_rows.erase(row)
	else:
		return
	d.row = -1  # (its row is free again: the node must not hand it back)
	_by_row_count = -1  # (the rows' table is made again)
	if dishes.has(d) and dishes.size() > 1:
		_remove_dish(d)
	_show_banner(Strings.t("banner.memory_budget"), BANNER_SECONDS, true)
	_sync_reply_hold()


## The pipette timer was switched or set (hours; 0 is off). Switching it off ends a wait for the pipette (play stays paused).
func _set_pipette_timer(hours: float) -> void:
	_pipette_hours = hours
	_pipette_clock = 0.0
	if hours <= 0.0:
		_end_pipette_wait(false)


## The timer has run out: the game pauses, and only using the pipette resumes it. Tools can still be changed; the pipette's button pulses.
func _begin_pipette_wait() -> void:
	_pipette_clock = 0.0
	holds.hold(&"pipette")
	var button := toolbar.button_for(Toolbar.Tool.PIPETTE)
	if UserSettings.reduce_motion:
		button.modulate.a = PIPETTE_STILL_ALPHA
		return
	_pipette_pulse = create_tween().set_loops()
	_pipette_pulse.tween_property(button, "modulate:a", PIPETTE_PULSE_LOW, PIPETTE_PULSE_SECONDS).set_trans(Tween.TRANS_SINE)
	_pipette_pulse.tween_property(button, "modulate:a", 1.0, PIPETTE_PULSE_SECONDS).set_trans(Tween.TRANS_SINE)


func _end_pipette_wait(resume: bool) -> void:
	if not holds.has(&"pipette"):
		return
	holds.release(&"pipette", PlayHolds.Then.RESUME if resume else PlayHolds.Then.STAY)
	if _pipette_pulse != null:
		_pipette_pulse.kill()
	toolbar.button_for(Toolbar.Tool.PIPETTE).modulate.a = 1.0


## The pipette: every bup in the circle moves to a new dish (a droplet in the middle of a fresh dish like this one, as the player started it), and the old dish
## goes on without them. The simulation moves them (a retarget: the same bups, alive, with their ids) and answers a frame or a few later (`_finish_pipette`):
## then the new dish takes its place in the strip and the main view moves to it; a circle with nothing in it, or no room, makes none. The world stands
## still meanwhile, so the circle takes the bups that were in it.
func pipette(world: Vector2, circle_radius: float) -> void:
	if _at_dish_limit():
		return
	if not _pipette_pending.is_empty():
		return
	var reply := dish.pipette(world, circle_radius)
	if reply != null:
		_pipette_pending = {"reply": reply, "source": dish}
		_next_dish_number += 1  # (the simulation gives the new dish a number past every dish's so far: one added before it answers must not take that one)
		_sync_reply_hold()


## The pipette's answer has come: the new dish takes its place in the strip and the main view moves to it, and the player is asked about
## the old one; a circle with no bups makes no dish. A refusal while the dish is still there means the graphics memory had no room
## for the new dish (the pipette is then undone in the simulation).
func _finish_pipette() -> void:
	if _pipette_pending.is_empty() or not (_pipette_pending["reply"] as SimReply).is_done():
		return
	var source: Dish = _pipette_pending["source"]
	var reply: SimReply = _pipette_pending["reply"]
	var got: Variant = reply.value()
	_pipette_pending = {}
	_sync_reply_hold()
	if got == null:
		if dishes.has(source) and reply.error() != "":  # (the processor's stub answers with nothing and no error: nothing ran)
			_show_banner(Strings.t("banner.memory_budget"), BANNER_SECONDS, true)
		return
	if int(got["moved"]) == 0 or not dishes.has(source):
		WorldClient.shared().remove_dish(int(got["new_row"]))
		_show_banner(Strings.t("hud.banner_pipette_empty"), BANNER_BRIEF_SECONDS)
		return
	var number := int(got["number"])
	_next_dish_number = maxi(_next_dish_number, number + 1)
	var receiver := Dish.new()
	receiver.visible = false  # (it comes into view below; what it draws is made then)
	add_child(receiver)
	receiver.adopt(int(got["new_row"]), number, source)
	for layer: int in Dish.Layer.values():
		receiver.show_layer(layer, dish.layer_shown(layer))
	_register_dish(receiver)
	for id: int in got["ids"]:  # (the same bup in its new dish: a watched one stays on the watch list, now as one of that dish's)
		if source.is_watched(id):
			source.unwatch_bup(id)
			receiver.watch_bup(id)
	set_main_dish(receiver)  # (the view follows the bups to their new dish)
	toolbar.select_tool(Toolbar.Tool.SELECT)  # (the pipette is done: the next click inspects)
	_ask_about_old_dish(source, int(got["moved"]), receiver)  # (play, which the pipette's timer was holding, goes on once that is answered)


## Takes a dish into the set under the number it is shown by (`label`; -1: a new one, `_take_label`; a dish out of the freezer comes back under the
## one it had): the screen hears when it dies out or its selection changes (when it is the one in the main view), and the strip gets its tab. A dish
## that is not the one in the main view is parked (hidden, and doing nothing a frame). Its world number (Dish.number) is set already.
func _register_dish(d: Dish, label := -1) -> void:
	if label < 0:
		label = _take_label()
	dishes.append(d)
	_by_row_count = -1  # (the rows' table is made again)
	_dish_numbers[d] = label
	_label_of[d.number] = label
	if d != dish:
		d.park()
	d.extinct.connect(_on_dish_extinct.bind(d))
	d.selection_changed.connect(func() -> void:
		if d == dish:
			lineage.on_selection_changed())
	dish_strip.add(d, label)
	dish_strip.light(dish)


## The number a new dish is shown by: 1, 2, 3... until MAX_DISHES have been handed out in this game, then the lowest that no running or frozen dish
## holds (a frozen dish keeps its number for when it is unfrozen). `_at_dish_limit` makes sure there is one; 0 when there is not.
func _take_label() -> int:
	if _labels_given < MAX_DISHES:
		_labels_given += 1
		return _labels_given
	var held := {}
	for d: Dish in _dish_numbers:
		held[_dish_numbers[d]] = true
	for entry: Dictionary in freezer_shelf.entries:
		held[entry["label"]] = true
	for label in range(1, MAX_DISHES + 1):
		if not held.has(label):
			return label
	return 0


## The number a dish of this game was shown by, from its world number (as a bup's family record has it); the world number itself for one never shown;
## 0 for one that is gone (trashed, or retired when it died out), as its number may since be another dish's.
func _label_for(world_number: int) -> int:
	if not _label_of.has(world_number):
		return world_number
	for d: Dish in dishes:
		if d.number == world_number:
			return int(_label_of[world_number])
	for entry: Dictionary in freezer_shelf.entries:
		if int(entry["number"]) == world_number:
			return int(_label_of[world_number])
	return 0


## How many shown numbers are held: by the running dishes, the frozen ones (one on its way back out of the freezer is among the running already)
## and a pipette's dish not made yet. Never more than MAX_DISHES: a freeze or a thaw only moves a number between the two, so at most MAX_DISHES run.
func _labels_held() -> int:
	return dishes.size() + freezer_shelf.entries.size() - _thawing.size() + (0 if _pipette_pending.is_empty() else 1)


## Whether every number is held, by the running dishes and the frozen ones together: then nothing that would add a dish (a pipette, a new dish)
## is done, and the banner says why (the tray's dish actions show a warning meanwhile, `_show_graph_choices`). An unfrozen dish has its own number.
func _at_dish_limit() -> bool:
	if _next_dish_number > GpuLayout.EV_DISH_MASK:  # (an event's dish number has no more bits: see EV_DISH_BITS)
		_show_banner(Strings.t("banner.dish_numbers"), BANNER_BRIEF_SECONDS)
		return true
	if _labels_held() < MAX_DISHES:
		return _too_many_running()
	_show_banner(Strings.t("banner.dish_limit"), BANNER_BRIEF_SECONDS)
	return true


## How many dishes run now or are about to (a pipette's dish not made yet counts; an unfrozen dish is among `dishes` already).
func _running_held() -> int:
	return dishes.size() + (0 if _pipette_pending.is_empty() else 1)


## Whether low-memory mode allows no more running dishes (goal mode keeps one dish and has no such limit); the banner says why.
func _running_full() -> bool:
	return free_mode and _running_held() >= MemoryMode.max_dishes()


func _too_many_running() -> bool:
	if not _running_full():
		return false
	_show_banner(Strings.t("banner.low_dish_limit", [MemoryMode.max_dishes()]), BANNER_SECONDS, true)
	return true


## Another dish, run beside the main one in the same world (parked: it shows in the strip). It is started as `start` says (null: the usual dish) at the
## world's time; the main view stays where it is. Returns it, or null when no dish can be added (`_at_dish_limit`: nothing changes then); a dish the
## graphics memory has no room for goes again (`_on_refused`).
func add_dish(start: StartConditions) -> Dish:
	if _at_dish_limit():
		return null
	var d := Dish.new()
	d.number = _next_dish_number
	_next_dish_number += 1
	d.visible = false  # (parked from the start: what it draws is made when it is first shown)
	add_child(d)
	d.strike(start)
	for layer: int in Dish.Layer.values():
		d.show_layer(layer, dish.layer_shown(layer))  # (what is shown is one choice for every dish)
	_register_dish(d)
	if d.row >= 0:
		_asked_rows[d.row] = d
	return d


## The dish the view goes to when `d` leaves it: the one before it in the tabs, or the next when it is the first.
func _neighbour(d: Dish) -> Dish:
	var at := dishes.find(d)
	return dishes[at - 1] if at > 0 else dishes[1]


## Takes a dish out of the running set for good: the view goes to its neighbour if it was the one in the main view, the strip and the lists forget it, and it is freed
## (leaving the world, unless a freeze took it out already).
func _remove_dish(d: Dish) -> void:
	if d == dish:
		set_main_dish(_neighbour(d))
	dishes.erase(d)
	_by_row_count = -1  # (the rows' table is made again)
	_dish_numbers.erase(d)
	_extinct_queue.erase(d)
	for row: int in _asked_rows.keys():
		if _asked_rows[row] == d:
			_asked_rows.erase(row)
	for row: int in _thawing.keys():
		if _thawing[row]["dish"] == d:
			(_thawing[row]["entry"] as Dictionary).erase("thawing")
			_thawing.erase(row)
	dish_strip.remove(d)
	dish_strip.light(dish)
	d.queue_free()
	lineage.forget_elsewhere()


## Whether a pipette's answer is awaited from `d`: until it comes the dish stays as it is (it is neither frozen nor trashed meanwhile).
func _pipetting_from(d: Dish) -> bool:
	return not _pipette_pending.is_empty() and _pipette_pending["source"] == d


## Puts a dish in the freezer: the simulation takes it out of the world whole (its DishBlob, with its part of the family tree, a frame or a few later), and it leaves
## the running dishes. It does not advance until `thaw` brings it back under its own number. The last running dish cannot be frozen. The main view leaves it
## first, so its lineage stack lets go of the bups it held before the dish's family is written out.
func freeze_dish(d: Dish) -> void:
	if not dishes.has(d) or dishes.size() < 2 or _pipetting_from(d):
		return
	if d == dish:
		set_main_dish(_neighbour(d))
	var label: int = _dish_numbers[d]
	var picture := dish_strip.picture_of(d)
	var entry := {
		"number": d.number,  # (its world number: the family tree keeps what it holds for the dish under it)
		"label": label,  # (the number it is shown by, held while it is frozen)
		"data": {"time": world_time() - game_began},  # (when it was frozen, on the game's clock)
		"host": d.host_part(),
		"bups": d.population(),
		"picture": ImageTexture.create_from_image(picture) if picture != null else null,
	}
	entry["reply"] = d.freeze()
	freezer_shelf.add(entry)
	_remove_dish(d)
	_sync_reply_hold()
	_show_banner(Strings.t("hud.banner_frozen", [label]), BANNER_BRIEF_SECONDS)


## Asks before a frozen dish is trashed.
func _ask_to_trash_frozen(entry: Dictionary) -> void:
	_entry_to_trash = entry
	trash_dialog.title = Strings.t("hud.trash_title", [entry["label"]])
	trash_dialog.dialog_text = Strings.t("hud.trash_text_frozen", [UiText.thousands(entry["bups"])])
	trash_dialog.popup_centered()


## Takes a frozen dish out of the freezer for good: the family tree lets go of the records it was keeping the death times of for it (LineageStore.discard_frozen).
## A dish still on its way out of the world is trashed once its freeze has answered (its claims on those records are made then).
func _trash_frozen(entry: Dictionary) -> void:
	if not freezer_shelf.entries.has(entry):
		return
	if _waits(entry):
		entry["then"] = "trash"
		return
	freezer_shelf.remove(entry)
	var store := WorldClient.shared().lineage()
	if store != null:
		store.discard_frozen(int(entry["number"]))
	_show_banner(Strings.t("hud.banner_trashed", [entry["label"]]), BANNER_BRIEF_SECONDS)


## Asks before the dish in the main view is trashed (it cannot be got back).
func _ask_to_trash() -> void:
	if dishes.size() < 2:
		return
	_entry_to_trash = {}
	_to_trash = dish
	trash_dialog.title = Strings.t("hud.trash_title", [_dish_numbers[dish]])
	trash_dialog.dialog_text = Strings.t("hud.trash_text", [UiText.thousands(dish.population())])
	trash_dialog.popup_centered()


## Takes a dish out of the game: its bups die with it and nothing of it is kept. The last running dish cannot be trashed.
func trash_dish(d: Dish) -> void:
	if not dishes.has(d) or dishes.size() < 2 or _pipetting_from(d):
		return
	var number: int = _dish_numbers[d]
	_remove_dish(d)
	_show_banner(Strings.t("hud.banner_trashed", [number]), BANNER_BRIEF_SECONDS)


## A frozen dish runs again, as one of the running dishes, from the world's time on (the time it was frozen is not simulated: the simulation moves its
## plankton's and bloom's times on, and its history goes on level for the time it was away), under the number it had. Its entry leaves the freezer when a
## snapshot shows it (`_thawed`); one asked for while its freeze has not answered is unfrozen when it has.
func thaw(entry: Dictionary) -> void:
	if not freezer_shelf.entries.has(entry) or entry.get("thawing", false):
		return
	if _too_many_running():
		return
	if _waits(entry):
		entry["then"] = "thaw"
		return
	var reply: SimReply = entry.get("reply")
	var blob: DishBlob = reply.value() if reply != null else null
	if blob == null:
		return
	blob.host.merge(entry["host"], true)
	var now := world_time()
	var history: Dictionary = (entry["host"]["history"] as Dictionary).duplicate(true)
	DishHistory.pad(history, float(blob.world.get("time", now)), now)  # (the graph's time axis stays the world's)
	blob.host["history"] = history
	var d := Dish.new()  # (not struck: a new dish under its number would put founders' records under the frozen dish's own ids)
	d.visible = false  # (parked: what it draws is made when it is first shown)
	add_child(d)
	d.load_blob(blob)
	if d.row < 0:  # (no row at all: as the graphics memory refusing it)
		d.queue_free()
		_show_banner(Strings.t("banner.memory_budget"), BANNER_SECONDS, true)
		return
	for layer: int in Dish.Layer.values():
		d.show_layer(layer, dish.layer_shown(layer))
	_register_dish(d, entry["label"])
	entry["thawing"] = true
	_thawing[d.row] = {"entry": entry, "dish": d}
	if not WorldClient.shared().backend.can_simulate():
		_thawed(d.row)  # (the processor's stub shows no dish: there is nothing to wait for)
	_sync_reply_hold()


## After a pipette: the dish the bups came from is what the player decides about, and nothing else can be done until they have. The game holds meanwhile.
func _ask_about_old_dish(source: Dish, moved: int, receiver: Dish) -> void:
	_old_dish = source
	holds.hold(&"old_dish")
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
	holds.release(&"old_dish")  # (the question held the game; answering gives it back as it was, unless the pipette's timer still holds it ...)
	_end_pipette_wait(true)  # (... the pause the pipette's timer held is what using the pipette ends)


## The rect of something in the tray, scrolled into view first (the tray scrolls when its sections are taller than the window).
func _in_tray(item: Control) -> Rect2:
	side.ensure_control_visible(item)
	return item.get_global_rect()


## The tour's graph step: the graph's section is open and in view.
func _tutorial_show_graph() -> void:
	graph_section.open = true
	side.ensure_control_visible.call_deferred(graph_section)


## What the graph's controls show follows the graph (they are one choice whichever way it is made), and what depends on how many dishes run.
func _show_graph_choices() -> void:
	graph_controls.show_choices(graph, dishes.size(), _dish_numbers.get(dish, 0))
	all_details.visible = dishes.size() > 1  # (with one dish there is no "all")
	freezer_shelf.actions.set_available(dishes.size() > 1)  # (the last running dish stays)
	card_actions.set_available(dishes.size() > 1)
	var full := _labels_held() >= MAX_DISHES
	var low_text := Strings.t("banner.low_dish_limit", [MemoryMode.max_dishes()]) if _running_full() and not full else ""
	freezer_shelf.actions.set_at_limit(full or low_text != "", low_text)
	card_actions.set_at_limit(full or low_text != "", low_text)


## Brings the dish `by` places along the tabs (wrapping round) into the main view.
func _step_dish(by: int) -> void:
	if dishes.size() > 1:
		set_main_dish(dishes[posmod(dishes.find(dish) + by, dishes.size())])


## Brings another dish into the main view: the panels and the graph follow it, and the camera goes back to where (and how close) it last looked at that dish, or frames the dish if it has not looked yet; what was open on the old dish (a selection, a lineage) is closed.
func set_main_dish(d: Dish) -> void:
	if d == dish or not dishes.has(d):
		return
	_clear_selection()
	stage_input.remember_view()
	var old := dish
	dish = d
	old.clear_hover()
	old.park()
	d.unpark()
	stage_input.dish = d
	lineage.dish = d
	inspector.dish = d
	d.clear_hover()  # (what it was hovering when last in view is stale)
	d.pick_mode = tool_options.pick_mode()
	graph.dish = d
	layers_panel.sync_from(d)
	tool_options.set_husks_available(d.has_husks())
	dish_strip.light(d)
	stage_input.restore_view()


## The player chose another size for a dish (in the pause menu): the view stays inside it.
func _resize_dish(target: Dish, new_radius: float) -> void:
	if not dishes.has(target):  # (frozen or gone since the menu was opened)
		return
	target.resize_to(new_radius)
	if target == dish:
		stage_input.keep_on_dish()


## A goal-mode experiment is saved on the way out; free mode is not saved.
func _quit_to_menu() -> void:
	save_game()
	get_tree().change_scene_to_file(Scenes.MENU)


# Click vs. drag: remember where the button went down. If the pointer travels past the
# engine's drag threshold the gesture is a pan; if the button comes back up first it is a
# click. The middle button, and the left button with the pan tool, always pan.
func _click(world: Vector2) -> void:
	match tool:
		Toolbar.Tool.SELECT:
			dish.select_at(world, stage_input.pick_slack())
		Toolbar.Tool.NUTRIENT:
			dish.drop_nutrients(world, tool_options.nutrient_count())
		Toolbar.Tool.SOURCE:
			if dish.place_source(world, tool_options.source_rate(), true):
				# The new source is what you will want to look at or adjust next: it is selected when the world's copy has it (its panel opens); the tool stays.
				tool_options.show_all()  # (a mode that skips sources would hide the one just placed)
			elif dish.contains(world):
				if dish.sources.size() >= Dish.MAX_SOURCES:
					_show_banner(Strings.t("hud.banner_source_limit"), BANNER_BRIEF_SECONDS)
				else:
					_show_banner(Strings.t("hud.banner_edge"), BANNER_BRIEF_SECONDS)
		Toolbar.Tool.PLANKTON:
			if not dish.place_plankton(world) and dish.contains(world):
				_show_banner(Strings.t("hud.banner_plankton_limit" if dish.plankton.size() >= Dish.MAX_PLANKTON else "hud.banner_edge"), BANNER_BRIEF_SECONDS)
		Toolbar.Tool.ERASE:
			if dish.contains(world):
				dish.erase_nutrient(world, tool_options.brush_radius())
		Toolbar.Tool.PIPETTE:
			if dish.contains(world):
				pipette(world, tool_options.pipette_radius())


## The memory warning (PoolLimits.warning_state) as the banner while it holds, kept up a moment at a time; it never replaces a banner
## about something else (the player's action, a goal), which comes first and leaves it to return.
func _show_memory_warning() -> void:
	var state := PoolLimits.warning_state(WorldClient.shared().latest().timing)
	if state == "":
		return
	var text := Strings.t("banner.memory_stalled" if state == PoolLimits.WARN_STALLED else "banner.memory_near")
	var ours := banner.text == Strings.t("banner.memory_stalled") or banner.text == Strings.t("banner.memory_near")
	if _banner_left <= 0.0 or ours:
		_show_banner(text, BANNER_BRIEF_SECONDS, true)


## `note`: a sentence of advice, set in the smaller `BannerNote` (the usual banner is a few words).
func _show_banner(text: String, seconds: float, note := false) -> void:
	banner.theme_type_variation = &"BannerNote" if note else &"Banner"
	banner.text = text
	_banner_left = seconds


func _on_goal_completed(goal: Goal) -> void:
	tracker.apply_costs(dish)
	toolbar.set_paused(true)  # so the colony isn't left running while the player reads and sets up what comes next
	_sync_tool_locks()
	_show_banner(Strings.t("hud.banner_complete", [goal.title]) + ("\n" + Strings.t("hud.banner_unlocked") if tracker.index == 1 else ""), BANNER_SECONDS)
	save_game(false)


## A dish has no bups left. The game pauses on that dish and says so; resuming goes on without it (the dish before it, or the next when it was the first, comes
## into view and the extinct one is deleted). When it was the last dish the game is over: only starting again or quitting to the menu go on.
func _on_dish_extinct(d: Dish) -> void:
	if holds.has(&"end") or not dishes.has(d) or _extinct_queue.has(d):
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
	if dishes.size() == 1 and not freezer_shelf.entries.is_empty():
		_left_empty = d
		_show_banner(Strings.t("hud.banner_extinct_frozen", [_dish_numbers[d]]), 1e9)
		return
	if dishes.size() == 1:
		_extinct_queue.clear()
		_view_before_extinct = null
		holds.hold(&"end")
		pause_ring.visible = false  # (the game is over, not paused: the dialog says what happened)
		end_dialog.dialog_text = Strings.t("hud.end_text") + "\n" + Strings.t("hud.end_survived", [SimClock.format(dish.time - game_began)])
		end_dialog.popup_centered()
		return
	_show_banner(Strings.t("hud.banner_dish_extinct", [_dish_numbers[d]]), 1e9)


## Play was resumed after a dish went extinct: it is deleted as though it had never been, and the view goes to its neighbour.
func _retire_extinct() -> void:
	if _extinct_queue.is_empty() or holds.has(&"end"):
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


## The last dish died out and the player chose to begin again: the same beginning as the game screen's own, a new game, so the dish (the
## only one left) leaves the world first and the numbers (the world's and those shown) start again from 1 with it.
func _start_again() -> void:
	holds.release(&"end", PlayHolds.Then.STAY)
	lineage.reset()
	_end_pipette_wait(false)
	_pipette_clock = 0.0
	dish.selected.bup = -1
	dish.leave_world()
	_next_dish_number = 2
	_dish_numbers[dish] = 1
	dish.number = 1
	_labels_given = 1
	_label_of = {1: 1}
	dish_strip.remove(dish)
	dish_strip.add(dish, 1)
	dish_strip.light(dish)
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
	_fit_top_bar()
	if dish.population() == 0:
		return
	var about := "hud %s" % sim_speed
	if not readout.due(vitals, about) and not (top_bar_more_row.visible and readout.due(speed_readout, about)):
		return  # (nothing below is worth working out: the text would not be shown yet; the speed in the second row keeps its own time)
	if top_bar_more_row.visible:
		readout.set_text(vitals, Strings.t("hud.vitals_short", [_dish_lines(), SimClock.format(dish.time - game_began)]), about)
		readout.set_text(speed_readout, _playback_text(), about)
	else:
		readout.set_text(vitals, Strings.t("hud.vitals", [_dish_lines(), SimClock.format(dish.time - game_began), _playback_text()]), about)
	placed_row.value_text = UiText.thousands(dish.nutrients_placed)
	colony.show_stats(dish.population_stats())
	_update_all_details()


## The all-dishes section: how many dishes run and how many bups they hold, and the traits averaged over every bup of every dish (each dish counts by its
## bups), as the newest snapshot has them together (Snapshot.totals, worked out where the snapshot is made: nothing here looks at each dish).
func _update_all_details() -> void:
	if not all_details.open:
		return
	var totals := WorldClient.shared().latest().totals
	if totals.is_empty():
		return
	all_rows.show_stats(totals["stats"])
	all_rows.set_lead_text("dishes", UiText.thousands(dishes.size()))
	all_rows.set_lead_text("bups", UiText.thousands(totals["count"]))


## The details key: the dish's details section opens or closes.
func _toggle_colony() -> void:
	dish_details.open = not dish_details.open


## The pause menu's "Replay tutorial": back to the game, and the tutorial begins.
func _replay_tour() -> void:
	_close_menu()
	_start_tutorial.call_deferred()


## The tour of the screen: what each part does, in the order a first-time player needs it, asking for a click now and then so
## that what only shows while it is in use (the info panel, the watch list, the lineage) is there to be explained.
func _start_tutorial() -> void:
	_tutorial_watched_before = dish.watched.duplicate()
	holds.hold(&"tour", false)
	var steps: Array[Dictionary] = []
	steps.append(_tour("welcome"))
	if not free_mode:
		steps.append(_tour("goal", func() -> Rect2: return goal_card.get_global_rect()))
	steps.append(_tour("dish", func() -> Rect2: return dish.get_global_transform_with_canvas() * Rect2(-dish.radius, -dish.radius, 2.0 * dish.radius, 2.0 * dish.radius)))
	steps.append(_tour("readout", func() -> Rect2: return vitals.get_global_rect().grow(8.0)))
	steps.append(_tour("rates", func() -> Rect2: return _in_tray(inspector.dish_card)))
	steps.append(_tour("graph", func() -> Rect2: return _in_tray(graph_section), Callable(), _tutorial_show_graph))
	steps.append(_tour("tools", func() -> Rect2: return toolbar.select_button.get_global_rect().merge(toolbar.plankton_button.get_global_rect()), Callable(), Callable(), "" if free_mode else Strings.t("tutorial.tools_locked")))
	steps.append(_tour("tray", func() -> Rect2: return tool_options.get_global_rect()))
	steps.append(_tour("sections", func() -> Rect2: return _in_tray(graph_section)))
	steps.append(_tour("time", func() -> Rect2: return toolbar.pause_button.get_global_rect().merge(toolbar.speed_ultra_button.get_global_rect()).grow(4.0)))
	if dish_strip.visible:  # (the tabs are there only while several dishes run)
		steps.append(_tour("dishes", func() -> Rect2: return dish_strip.get_global_rect().grow(4.0)))
	steps.append(_tour("layers", func() -> Rect2: return layers_panel.get_global_rect().grow(4.0)))
	steps.append(_tour("pick_bup", _tutorial_bup_rect, func() -> bool: return dish.selected.bup >= 0, _tutorial_show_bup))
	steps.append(_tour("info", func() -> Rect2: return _in_tray(inspector.info_panel)))
	steps.append(_tour("genome", func() -> Rect2: return _in_tray(inspector.info_genome)))
	steps.append(_tour("watch", func() -> Rect2: return _in_tray(inspector.watch_button), func() -> bool: return dish.is_watched(dish.selected.bup)))
	steps.append(_tour("watched", func() -> Rect2: return _in_tray(watch_section)))
	steps.append(_tour("lineage_open", func() -> Rect2: return _in_tray(inspector.lineage_button), lineage.is_open, _tutorial_close_lineage))
	steps.append(_tour("lineage", func() -> Rect2: return inspector.lineage_panel.get_global_rect(), func() -> bool: return not lineage.is_open(), _tutorial_open_lineage))
	steps.back()["escape_passes"] = true  # (Escape closes a lineage, which is what that step asks for)
	steps.append(_tour("finish"))
	tutorial.start(steps)


## One step of the tour (see Tutorial): its text by key (with `extra` added), what it lights, what it waits for, what it does first.
func _tour(key: String, target := Callable(), wait := Callable(), enter := Callable(), extra := "") -> Dictionary:
	return {"title": Strings.t("tutorial.title_" + key), "text": Strings.t("tutorial." + key) + extra, "target": target, "wait": wait, "enter": enter}


## Brings the camera close to a bup and makes sure a click on it would select it: the step that asks for that click.
func _tutorial_show_bup() -> void:
	toolbar.select_tool(Toolbar.Tool.SELECT)
	tool_options.show_all()
	var ids := dish.bup_ids()
	if ids.is_empty():
		return
	_tutorial_bup = dish.selected.bup if dish.has_bup(dish.selected.bup) else ids[0]  # (coming back to the step keeps the bup already chosen)
	dish.pointed_bup = _tutorial_bup  # (asked after, so the world says where it is)
	stage_input.look_at_world(dish.bup_world_pos(_tutorial_bup), TUTORIAL_ZOOM)
	_tutorial_look_pending = not dish.bup_place_known(_tutorial_bup)


## The tour's bup's place once the world has answered where it is: the camera goes there (it went to the dish's middle meanwhile).
func _tutorial_look() -> void:
	if _tutorial_look_pending and dish.bup_place_known(_tutorial_bup):
		_tutorial_look_pending = false
		stage_input.look_at_world(dish.bup_world_pos(_tutorial_bup), TUTORIAL_ZOOM)


## The lineage step comes with the lineage open, and the step that asks for it with it shut, whichever way they are reached.
func _tutorial_open_lineage() -> void:
	if not lineage.is_open():
		lineage.open_lineage()


func _tutorial_close_lineage() -> void:
	if lineage.is_open():
		lineage.step_back()


func _tutorial_bup_rect() -> Rect2:
	if not dish.has_bup(_tutorial_bup) or not dish.bup_place_known(_tutorial_bup):
		return Rect2()
	var at := get_viewport().get_canvas_transform() * dish.bup_world_pos(_tutorial_bup)
	return Rect2(at - Vector2.ONE * TUTORIAL_BUP_PIXELS, Vector2.ONE * 2.0 * TUTORIAL_BUP_PIXELS)


## The tour ended, finished or skipped: whatever it set up goes back, so the screen looks as it did before it.
func _on_tutorial_closed(_completed: bool) -> void:
	_show_memory_notices.call_deferred()
	if _tutorial_bup >= 0:
		for id in dish.watched.duplicate():
			if not id in _tutorial_watched_before:
				dish.unwatch_bup(id)
		_tutorial_bup = -1
		_tutorial_look_pending = false
		dish.pointed_bup = -1
		_clear_selection()
		stage_input.fit_camera()
	holds.release(&"tour")


## A narrow window gives the side column less width; the graph, in the column, is as tall as the window allows.
func _adapt_layout() -> void:
	var view := get_viewport_rect().size
	side.custom_minimum_size.x = clampf(view.x * 0.34, 316.0, 336.0 * UserSettings.text_factor())  # (its cards need more room as the text grows)
	graph.custom_minimum_size.y = clampf(view.y * 0.22, 170.0, 260.0)  # (it grows with the window: it is one of the things worth reading)
	_fit_top_bar()  # (a narrow top bar keeps its room for the vitals and the playback)


## The most width the readout may take: what the playback and the menu leave in the bar's row (it is never cut short for any other reason).
func _vitals_room() -> float:
	return _bar_room() - playback_panel.get_combined_minimum_size().x - menu_button.get_combined_minimum_size().x - 4.0 * _bar_gap()  # (four gaps: the readout, the two spacers, the playback and the menu)


## The width a row of the top bar has: the window less the screen's margins and the bar's padding.
func _bar_room() -> float:
	var frame: Control = $HUD/Frame
	var panel := (%TopBar as Control).get_theme_stylebox("panel")
	return get_viewport_rect().size.x - frame.get_theme_constant("margin_left") - frame.get_theme_constant("margin_right") - panel.get_minimum_size().x


## The gap between the parts of a row of the top bar.
func _bar_gap() -> float:
	return float(top_bar_row.get_theme_constant("separation"))


## The top bar never needs more than the window has, and never changes as the game runs. The readout keeps the width of its longest possible text
## (`_measure_readouts`), and the controls come first; the dish tabs take everything that is left (they scroll when there are more than fit), and when
## not even two tabs and the strip's arrows fit beside the layer toggles, the playback speed (the readout's end), the tabs and the toggles move to a
## second row (never away): the speed at its left, the tabs centred in what is between, the toggles at its right. So which it is depends on the window,
## the interface size, the bup limit's digits and whether the tabs are there (and how many digits their count has), never on the speed, a pause or
## how many bups there are.
func _fit_top_bar() -> void:
	_measure_readouts()
	var room := _bar_room()
	var gap := _bar_gap()
	var fixed := playback_panel.get_combined_minimum_size().x + menu_button.get_combined_minimum_size().x
	var tabs_shown := dish_strip.visible
	dish_strip.tab_height = layers_panel.husks_button.get_combined_minimum_size().y
	var strip_frame := dish_strip.get_theme_stylebox("panel").get_minimum_size().x  # (max_width is what is inside it)
	var views_w := views.get_combined_minimum_size().x
	var husks := layers_panel.husks_button
	if not husks.visible:  # (room is kept for the husks' button, which comes with a dish that has husks)
		views_w += husks.get_combined_minimum_size().x + float(husks.get_parent().get_theme_constant("separation"))
	var gaps := gap * (6.0 if tabs_shown else 5.0)  # (between the readout, the spacer, the tabs, the spacer, the toggles, the playback and the menu)
	var left_with_views := room - _vitals_full_width - fixed - views_w - gaps - (strip_frame if tabs_shown else 0.0)
	var tabs_least := dish_strip.shortest_width() if tabs_shown else 0.0
	var beside := left_with_views >= tabs_least
	if tabs_shown:
		var second_row_room := room - _speed_width - views.get_combined_minimum_size().x - strip_frame - gap * 4.0  # (the speed, the spacer, the tabs, the spacer, the toggles: no room kept for the husks' button, the tabs take what the toggles leave)
		dish_strip.max_width = maxf(left_with_views if beside else second_row_room, dish_strip.narrowest_width())
	var centred := not beside and dish_strip.full_width() <= dish_strip.max_width  # (when the tabs fill the row they are against the toggles whatever)
	top_bar_more_row.get_node("MoreSpacer").size_flags_horizontal = Control.SIZE_EXPAND_FILL if centred else Control.SIZE_FILL
	if beside:
		_move_to(views, top_bar_row, top_bar_row.get_node("Spacer").get_index() + 1)
		_move_to(dish_strip, top_bar_row, top_bar_row.get_node("LeadSpacer").get_index() + 1)
	else:
		_move_to(dish_strip, top_bar_more_row, top_bar_more_row.get_node("MoreLead").get_index() + 1)
		_move_to(views, top_bar_more_row, -1)
	if top_bar_more_row.visible == beside:  # (the readout's text changes with where the speed is: it is written afresh)
		top_bar_more_row.visible = not beside
		readout.forget(vitals)
		readout.forget(speed_readout)
	speed_readout.visible = not beside
	vitals.custom_minimum_size = Vector2(minf(_vitals_full_width if beside else _vitals_short_width, _vitals_room()), _readout_height)
	speed_readout.custom_minimum_size = Vector2(_speed_width, _readout_height)


## The readouts keep the width of their longest possible text, so nothing in the top bar moves as the figures change: the speed at its highest,
## running slower; as many bups as the bup limit has digits (the most digits of any running dish's limit, and the
## limit beside them in free mode); the clock at LONGEST_CLOCK_HOURS. Measured again when the readout's font size changes (the label's own size, not the
## setting: the setting changes a moment before the theme does), or the limit's digits.
func _measure_readouts() -> void:
	var key := [speed_readout.get_theme_font_size("normal_font_size"), free_mode, _bup_limit_digits()]
	if key == _readouts_measured_for:
		return
	_readouts_measured_for = key
	var bups := int("9".repeat(_limit_digits))
	var lines := Strings.t("hud.readout_bups_limit", [bups, bups]) if free_mode else Strings.t("hud.readout_bups", [bups])
	var clock := SimClock.format(LONGEST_CLOCK_HOURS * 3600.0 + 3599.0)
	_speed_width = 0.0
	var speeds := [Strings.t("hud.playback_slow", [10000, 8499])]  # (the achieved part shows only below 85% of the speed asked)
	for text: String in speeds:
		_speed_width = maxf(_speed_width, _readout_width(text))
	_vitals_short_width = _readout_width(Strings.t("hud.vitals_short", [lines, clock]))
	_vitals_full_width = 0.0
	for text: String in speeds:
		_vitals_full_width = maxf(_vitals_full_width, _readout_width(Strings.t("hud.vitals", [lines, clock, text])))
	_readout_height = speed_readout.get_content_height()
	readout.forget(vitals)
	readout.forget(speed_readout)


## How wide `text` is in the readouts (measured on the speed readout: both are the one theme type).
func _readout_width(text: String) -> float:
	speed_readout.text = UiText.numbers(text, "")
	return speed_readout.get_content_width()


## The most digits a running dish's bup limit has (worked out again when a dish comes or goes, or the main dish's limit changes).
func _bup_limit_digits() -> int:
	var now := [dishes.size(), dish.bup_limit]
	if now != _limit_digits_for:
		_limit_digits_for = now
		var most := 1
		for d in dishes:
			most = maxi(most, d.bup_limit)
		_limit_digits = str(most).length()
	return _limit_digits


## A top bar part sits in the bar's row or in the second row under it.
func _move_to(node: Control, row: Control, index: int) -> void:
	if node.get_parent() == row:
		return
	var scene_owner := node.owner
	var owned := [node] + node.find_children("*", "", true, true).filter(func(n: Node) -> bool: return n.owner == scene_owner)
	node.get_parent().remove_child(node)
	row.add_child(node)
	row.move_child(node, index)
	for n: Node in owned:
		n.owner = scene_owner  # (taking a node out of the tree lets go of its owner: the scene's % names need it)


## The top bar's bups: how many there are, and (in free mode, where you can change it) the dish's bup limit.
func _dish_lines() -> String:
	if not free_mode:
		return Strings.t("hud.readout_bups", [dish.population()])
	return Strings.t("hud.readout_bups_limit", [dish.population(), dish.bup_limit])


## The playback speed, and the speed actually achieved when the simulation can't keep up with it.
func _playback_text() -> String:
	var slow := sim_speed > 1.0 and achieved_speed < 0.85 * sim_speed  # (while paused the speed it reached stays what it was: nothing updates it)
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
		readout.set_text(goal_text, Strings.t("hud.goal_all_done_text"), "goal")
		goal_bar.value = 1.0
		goal_status.text = ""
		return
	if goal_title.text != goal.title:
		goal_kicker.text = Strings.t("hud.goal_kicker", [tracker.index + 1, tracker.goals.size()])
		goal_title.text = goal.title
		readout.forget(goal_text)  # (the text is for another goal)
		readout.set_text(goal_text, goal.text, "goal text")
	if not readout.due(goal_status, "goal"):
		return
	readout.stamp(goal_status, "goal")
	goal_bar.value = goal.progress.call(dish)
	var line: String = goal.status.call(dish)
	if goal.hold_time > 0.0 and tracker.held > 0.0:
		line += Strings.t("hud.goal_holding", [SimClock.format(tracker.held), SimClock.format(goal.hold_time)])
	goal_status.text = line
