extends Node2D

const BANNER_SECONDS := 4.0
const MAX_FRAME_SECONDS := 0.1  ## the longest frame the sim will catch up on, so a hitch can't snowball
const ZOOM_MIN := 0.25
const ZOOM_MAX := 4.0
const ZOOM_BUTTON_STEP := 1.25
const ZOOM_WHEEL_STEP := 1.1
const FIT_MARGIN := 40.0  ## screen pixels kept clear at the sides when framing the dish
const TOOLBAR_CLEARANCE := 120.0  ## screen pixels kept clear above the dish for the toolbars
const PICK_SLACK_PIXELS := 4.0  ## how far outside a bup (in screen pixels) still counts as pointing at it

@onready var dish: Dish = $Dish
@onready var camera: Camera2D = $Camera
@onready var hud: RichTextLabel = $HUD/Readout
@onready var goal_panel: RichTextLabel = $HUD/GoalPanel
@onready var stats_panel: PanelContainer = $HUD/StatsPanel
@onready var banner: Label = $HUD/Banner
@onready var graph: Control = $HUD/Graph
@onready var toolbar: Toolbar = $HUD/Toolbars/Toolbar
@onready var tool_options: ToolOptions = $HUD/Toolbars/ToolOptions
@onready var info_panel: PanelContainer = $HUD/InfoPanel
@onready var info_text: RichTextLabel = $HUD/InfoPanel/InfoText
@onready var pause_ring: Panel = $HUD/PauseRing
@onready var stat_bups: StatRow = $HUD/StatsPanel/Box/BupsRow
@onready var stat_nutrients: StatRow = $HUD/StatsPanel/Box/NutrientsRow
@onready var stat_rate: StatRow = $HUD/StatsPanel/Box/RateRow
@onready var stat_dish: StatRow = $HUD/StatsPanel/Box/DishRow

## The two modes share everything (dish, evolution, HUD, controls). Free mode differs in
## exactly three ways: no goals, no saving, and restarts use the player's start conditions.
var free_mode := Session.mode == Session.Mode.FREE
var tracker := GoalTracker.new()
var tool := Toolbar.Tool.INFO  ## kept in step with the toolbar's selection (see _on_tool_selected)
var sim_speed := 1.0
var paused := false
var _banner_left := 0.0

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
	toolbar.speed_selected.connect(func(multiplier: float) -> void: sim_speed = multiplier)
	toolbar.pause_toggled.connect(_set_paused)
	graph.dish = dish
	banner.text = ""
	_on_tool_selected(toolbar.current_tool())  # the toolbar decides the starting tool
	# Goals are goal mode's panel; free mode shows its starting conditions instead.
	goal_panel.visible = not free_mode
	stats_panel.visible = free_mode
	if free_mode:
		_fill_stats(Session.free_start)
	var data := SaveGame.read() if Session.load_requested and not free_mode else {}
	Session.load_requested = false
	if data.is_empty() or not dish.from_dict(data["dish"]):
		_restart()
	else:
		tracker.from_dict(data["goals"])
		_fit_camera()


func _exit_tree() -> void:
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


func _restart() -> void:
	dish.selected = null
	dish.strike(Session.free_start if free_mode else null)
	_fit_camera()
	if free_mode:
		toolbar.set_paused(true)  # the playground starts paused so you can set the scene


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
	if free_mode or dish.cells.is_empty():
		return
	SaveGame.write({"dish": dish.to_dict(), "goals": tracker.to_dict()})


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_game()


func _process(delta: float) -> void:
	if not paused:
		# Fixed substeps keep the sim stable at high speed multipliers.
		var remaining := minf(delta, MAX_FRAME_SECONDS) * sim_speed
		while remaining > 0.0:
			var dt := minf(remaining, Dish.STEP)
			dish.step(dt)
			if not free_mode:
				tracker.update(dish, dt)
			remaining -= dt
	_banner_left = maxf(0.0, _banner_left - delta)
	if _banner_left == 0.0:
		banner.text = ""
	_update_pointer()
	_update_info_panel()
	dish.queue_redraw()
	graph.queue_redraw()
	_update_hud()


## Hover highlight (info tool) and the placement preview (nutrient tool).
func _update_pointer() -> void:
	dish.clear_hover()
	dish.place_preview_radius = -1.0
	# Skip while the mouse is over the toolbar/panels, or mid-drag.
	if _dragging or get_viewport().gui_get_hovered_control() != null:
		return
	var world := get_global_mouse_position()
	match tool:
		Toolbar.Tool.INFO:
			dish.hover_at(world, _pick_slack())
		Toolbar.Tool.NUTRIENT:
			if world.distance_to(dish.global_position) <= dish.radius:
				dish.place_preview_pos = world
				dish.place_preview_radius = Dish.scatter_radius(tool_options.nutrient_count())


func _pick_slack() -> float:
	return PICK_SLACK_PIXELS / camera.zoom.x


func _update_info_panel() -> void:
	if dish.selected != null and not dish.cells.has(dish.selected):
		dish.selected = null  # it died or was otherwise removed
	if dish.has_selected_food() and not dish.food.has(dish.selected_food):
		dish.selected_food = Dish.NO_FOOD  # a bup ate it
	info_panel.visible = dish.selected != null or dish.has_selected_food()
	if dish.selected != null:
		_set_rich(info_text, _info_text(dish.selected))
	elif dish.has_selected_food():
		_set_rich(info_text, _nutrient_text(dish.nutrient_details(dish.selected_food)))


func _nutrient_text(d: Dictionary) -> String:
	var offset: Vector2 = d["offset"]
	var nearest: float = d["nearest_bup"]
	return "NUTRIENT\nenergy  %.0f\nposition  %.0f, %.0f\nfrom centre  %.0f\nnearest bup  %s\nsensed by  %d %s" % [
		d["energy"], offset.x, offset.y, d["distance"],
		"%.0f away" % nearest if nearest >= 0.0 else "none",
		d["sensed_by"], "bup" if d["sensed_by"] == 1 else "bups",
	]


func _info_text(c: Cell) -> String:
	var text := "%s\ngeneration %d   energy %.0f / %.0f\n" % [c.title(), c.generation, c.energy, c.split_threshold()]
	for gene: String in Genome.LABELS:
		text += "\n%s  %s   (avg %s)" % [Genome.LABELS[gene].rpad(5), Genome.format(gene, c.genome.get_gene(gene)), Genome.format(gene, dish.mean_gene(gene))]
	return text + "\n\nmutations in lineage  %d" % c.genome.mutations


func _on_tool_selected(new_tool: Toolbar.Tool) -> void:
	tool = new_tool
	tool_options.show_for(tool)
	_sync_toolbar_shape()
	match tool:
		Toolbar.Tool.PAN:
			Input.set_default_cursor_shape(Input.CURSOR_DRAG)
		Toolbar.Tool.NUTRIENT:
			Input.set_default_cursor_shape(Input.CURSOR_CROSS)
		_:
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)


## Only input the GUI didn't consume arrives here, so clicks on the toolbar never reach the dish.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event)


func _on_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_UP:
			dish.food_rate = minf(dish.food_rate + 1.0, StartConditions.MAX_NUTRIENT_RATE)
		KEY_DOWN:
			dish.food_rate = maxf(dish.food_rate - 1.0, 0.0)
		KEY_T:
			graph.cycle_trait()
		KEY_R:
			_show_banner("", 0.0)
			_restart()
		KEY_ESCAPE:
			save_game()
			get_tree().change_scene_to_file(Scenes.MENU)


# Click vs. drag: remember where the button went down. If the pointer travels past the
# engine's drag threshold the gesture is a pan; if the button comes back up first it is a
# click. The middle button, and the left button with the pan tool, always pan.
func _on_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_zoom_by(ZOOM_WHEEL_STEP)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
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
		camera.position -= event.relative / camera.zoom.x
		camera.position = camera.position.limit_length(dish.radius)  # don't lose the dish


func _click(world: Vector2) -> void:
	match tool:
		Toolbar.Tool.INFO:
			dish.select_at(world, _pick_slack())
		Toolbar.Tool.NUTRIENT:
			var inside := world.distance_to(dish.global_position) <= dish.radius
			if dish.place_nutrients(world, tool_options.nutrient_count()) == 0 and inside:
				_show_banner("The dish can't hold any more nutrients.", 1.5)


func _zoom_by(factor: float) -> void:
	camera.zoom = Vector2.ONE * clampf(camera.zoom.x * factor, ZOOM_MIN, ZOOM_MAX)


func _show_banner(text: String, seconds: float) -> void:
	banner.text = text
	_banner_left = seconds


func _on_goal_completed(goal: Goal) -> void:
	_show_banner("EXPERIMENT COMPLETE\n%s" % goal.title, BANNER_SECONDS)
	save_game()


func _on_extinct() -> void:
	_show_banner("The bups are gone.  R - strike again", 1e9)


func _update_hud() -> void:
	if not free_mode:
		_set_rich(goal_panel, _goal_text())
	if dish.cells.is_empty():
		return
	_set_rich(hud, "BUPS  %d\nTIME  %.0fs\nPLAYBACK  %s\nNUTRIENT  %.0f/s\nPLACED  %d\n\nspeed  %.0f\nsense  %.0f\nmetab  %.2f\nsize   %.1f\nmutations/lineage  %.1f\n\nUP/DOWN  nutrient rate\nT  graph trait\nR  restart\nESC  %s" % [
		dish.cells.size(), dish.time, "paused" if paused else "x%d" % int(sim_speed),
		dish.food_rate, dish.nutrients_placed,
		dish.mean_gene("speed"), dish.mean_gene("sense"),
		dish.mean_gene("metabolism"), dish.mean_gene("size"),
		dish.mean_mutations(),
		"menu" if free_mode else "save + menu",
	])


func _goal_text() -> String:
	var goal := tracker.current()
	if goal == null:
		return "ALL EXPERIMENTS COMPLETE\n\nMore to come."
	var s := "EXPERIMENT %d / %d\n%s\n\n%s\n\n%s" % [
		tracker.index + 1, tracker.goals.size(), goal.title, goal.text, goal.status.call(dish)]
	if goal.hold_time > 0.0 and tracker.held > 0.0:
		s += "\nholding %.0f / %.0fs" % [tracker.held, goal.hold_time]
	return s


## Shows text with its numbers styled. The readouts refresh every frame, so the styling (a
## regex pass) and the re-parse only run when the text has actually changed.
func _set_rich(label: RichTextLabel, text: String) -> void:
	if label.get_meta("raw", "") == text:
		return
	label.set_meta("raw", text)
	label.text = UiText.numbers(text)


func _fill_stats(start: StartConditions) -> void:
	stat_bups.value_text = str(start.bups)
	stat_nutrients.value_text = str(start.nutrients)
	stat_rate.value_text = "%.0f/s" % start.nutrient_rate
	stat_dish.value_text = "%.0f" % start.dish_radius


## The toolbar and its tray read as one piece: square the bar's bottom corners while open.
func _sync_toolbar_shape() -> void:
	toolbar.theme_type_variation = &"ToolbarPanelOpen" if tool_options.visible else &"ToolbarPanel"
