class_name Inspector
extends RefCounted
## What the game screen says about the thing picked in the dish: the info panel in the side column for what was
## clicked (a bup, a source, a plankton, a husk), the lineage panel over it, and, until something is clicked, the small
## card beside the pointer for what the pointer rests on (or else the nutrient at that spot). The nodes are the screen's
## scene's: `bind` finds them under its root.

## The follow button was pressed (the camera is the screen's).
signal follow_pressed

## The close button of the info panel was pressed (the screen lets go of the selection, as Escape does).
signal close_pressed

const WATCH_ICON := preload("res://icons/watch.svg")
const UNWATCH_ICON := preload("res://icons/unwatch.svg")
const FLASH_MSEC := 1500  ## how long the divisions number stays in the flash colour after the bup divides

var dish: Dish  ## the dish in the main view
var number_of: Callable  ## a dish's number (Callable: Dish -> int)
var lineage: LineageView
var readout: Readout

var dish_card: TraySection  ## the dish's section of the side column (it stays when something is picked)
var info_panel: PanelContainer  ## what is picked (a bup, a source, a plankton)
var hover_card: PanelContainer  ## what the pointer rests on, next to the pointer (it never moves the side column)
var hover_text: RichTextLabel
var info_genome: GenomeRibbon  ## the picked bup's genome as a chromosome map, and the lines that come after it
var info_tail: RichTextLabel
var info_gauges: BupGauges  ## the bup's mass and reserve bars, under its name (on the hover card, under its text)
var hover_gauges: BupGauges
var hover_genome: GenomeRibbon  ## the same on the card that follows the pointer
var hover_tail: RichTextLabel
var info_text: RichTextLabel
var top_row: HBoxContainer
var info_title: Label  ## the title of a source, plankton or husk, at the left of the close button (a bup has its name row)
var close_button: Button
var name_row: BupNameRow
var lineage_button: Button
var lineage_panel: PanelContainer
var lineage_back_button: Button
var source_rate_row: SettingRow
var delete_source_button: Button
var follow_button: Button
var watch_button: Button

var _point_stamp := []  ## what the nutrient readout under the pointer was last worked out from
var _divisions_of := -1  ## the bup whose divisions count the panel last saw ...
var _divisions_seen := 0  ## ... and what it was
var _flash_until := 0  ## when the divisions number stops flashing (Time.get_ticks_msec)


## Finds the panels' nodes under the screen's `root`, and wires their buttons.
func bind(root: Node, lineage_view: LineageView, readouts: Readout) -> void:
	lineage = lineage_view
	readout = readouts
	dish_card = root.get_node("%DishCard")
	info_panel = root.get_node("%InfoPanel")
	hover_card = root.get_node("%HoverCard")
	hover_text = root.get_node("%HoverText")
	info_genome = root.get_node("%InfoGenome")
	info_tail = root.get_node("%InfoTail")
	info_gauges = root.get_node("%InfoGauges")
	hover_gauges = root.get_node("%HoverGauges")
	hover_genome = root.get_node("%HoverGenome")
	hover_tail = root.get_node("%HoverTail")
	info_text = root.get_node("%InfoText")
	top_row = root.get_node("%InfoTopRow")
	name_row = root.get_node("%NameRow")
	info_title = root.get_node("%InfoTitle")
	close_button = root.get_node("%CloseButton")
	lineage_button = root.get_node("%LineageButton")
	lineage_panel = root.get_node("%LineagePanel")
	lineage_back_button = root.get_node("%LineageBackButton")
	source_rate_row = root.get_node("%InfoSourceRate")
	delete_source_button = root.get_node("%DeleteSource")
	follow_button = root.get_node("%FollowButton")
	watch_button = root.get_node("%WatchButton")
	lineage.title = root.get_node("%LineageTitle")
	lineage.entries = root.get_node("%LineageEntries")
	source_rate_row.configure(Dish.MIN_SOURCE_RATE, Dish.MAX_SOURCE_RATE, 0.1, 10.0, Strings.t("hud.source_rate_unit"))
	source_rate_row.value_changed.connect(_on_source_rate_changed)
	delete_source_button.pressed.connect(delete_selected_source)
	delete_source_button.focus_mode = Control.FOCUS_NONE
	follow_button.pressed.connect(follow_pressed.emit)
	follow_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close_pressed.emit)
	close_button.focus_mode = Control.FOCUS_NONE
	watch_button.pressed.connect(toggle_watch)
	watch_button.focus_mode = Control.FOCUS_NONE
	lineage_button.pressed.connect(lineage.open_lineage)
	lineage_back_button.pressed.connect(lineage.step_back)


## Brings the panels up to date (every frame). `following`: the camera is keeping the selected bup in the middle of the
## view. `hover_point`: the spot of the medium the select tool is over, or null when it is over none.
func update(following: bool, hover_point: Variant) -> void:
	if dish.selected.bup >= 0 and not dish.has_record(dish.selected.bup):
		dish.selected.bup = -1  # its record is gone
	if dish.hovered.bup >= 0 and not dish.has_record(dish.hovered.bup):
		dish.hovered.bup = -1  # (a hover left over in a dish that has come into view: it has no record of that bup, and `PanelText.deceased` needs one)
	# A clicked bup, source, plankton or husk is pinned to the info panel in the side column and stays there. What the
	# select tool's pointer rests on (or else the nutrient at that spot) shows on a small card beside the pointer, which
	# never moves the column, whether or not something is pinned.
	_show_info(following)
	_show_hover(hover_point)


## The info panel: what is selected.
func _show_info(following: bool) -> void:
	var picked := dish.selected
	var bup_id := picked.bup
	var source := picked.source
	var floating := picked.plankton
	var husk_place := picked.husk
	var husk := dish.husk_details(husk_place) if husk_place != Dish.NO_HUSK else {}
	if husk_place != Dish.NO_HUSK and husk.is_empty():  # (it has leaked away)
		picked.husk = Dish.NO_HUSK
		husk_place = Dish.NO_HUSK
	var pinned := dish.has_selection()
	var editing := source != null and bup_id < 0
	var alive_info: Dictionary = dish.bup_info(bup_id) if bup_id >= 0 else {}  # (fetched once: the panels below are built from it)
	if bup_id >= 0 and alive_info.is_empty() and dish.has_bup(bup_id):
		alive_info = dish.lineage_info(bup_id)  # (alive, but on the GPU its record has not come back yet: its family record stands in, rather than showing it as deceased)
	var dead := bup_id >= 0 and alive_info.is_empty()  # a selected bup that has died stays up, as a record
	var lineage_open := lineage.is_open_on(bup_id)
	var something := bup_id >= 0 or source != null or floating != null or not husk.is_empty()
	var panel_look := &"DeceasedPanel" if dead else &"HudPanel"
	info_panel.visible = pinned and something and not lineage_open
	info_panel.theme_type_variation = panel_look
	lineage_panel.visible = lineage_open
	lineage_panel.theme_type_variation = panel_look
	source_rate_row.visible = editing
	delete_source_button.visible = editing
	follow_button.visible = bup_id >= 0 and not dead  # a bup can be followed once it is selected
	var watched_now := dish.is_watched(bup_id)
	watch_button.icon = UNWATCH_ICON if watched_now else WATCH_ICON  # (an eye; crossed out while the bup is on the list, as that is what pressing it does)
	watch_button.tooltip_text = Strings.t("hud.unwatch") if watched_now else Strings.t("hud.watch")
	follow_button.text = Strings.t("hud.stop_following") if following else Strings.t("hud.follow")
	follow_button.tooltip_text = Strings.t("hud.stop_following_tip" if following else "hud.follow_tip")
	top_row.visible = pinned
	name_row.visible = bup_id >= 0
	info_title.visible = bup_id < 0
	lineage_button.visible = bup_id >= 0
	watch_button.visible = lineage_button.visible  # (alive or dead: a record can be watched too)
	var shows_bup := bup_id >= 0
	info_genome.visible = shows_bup
	info_tail.visible = shows_bup
	info_gauges.visible = shows_bup
	if bup_id < 0:
		name_row.cancel_editing()
	if lineage_open:
		lineage.show(bup_id)
	if bup_id >= 0:
		var record := dish.lineage_info(bup_id) if dead else alive_info
		var body := PanelText.deceased(record, number_of.call(dish)) if dead else PanelText.bup(alive_info, number_of.call(dish))
		info_genome.show_bup(record, true)
		readout.set_text(info_tail, PanelText.tail(record), "tail %d" % bup_id)
		var divided := note_divisions(bup_id, record) and not dead
		info_gauges.show_bup(record, dish.stationary_phase, not dead)
		name_row.show_bup(dish, bup_id, true)  # a bup can be renamed once it is clicked, not just hovered
		readout.set_text(info_text, body, "bup %d" % bup_id, divided)
	elif source != null:
		if editing:
			_show_source_rate(source)
		info_title.text = Strings.t("panel.source_title")
		readout.set_text_when_due(info_text, "source %d" % source.get_instance_id(), func() -> String: return PanelText.source(dish.source_details(source)))
	elif floating != null:
		info_title.text = Strings.t("panel.plankton_title")
		readout.set_text_when_due(info_text, "plankton %d" % floating.get_instance_id(), func() -> String: return PanelText.plankton(dish.plankton_details(floating)))
	elif not husk.is_empty():
		info_title.text = Strings.t("panel.husk_title")
		readout.set_text_when_due(info_text, "husk %s" % husk_place, func() -> String: return PanelText.husk(husk))


## The card beside the pointer: what the select tool's pointer rests on, or else the nutrient at that spot. Not the
## thing the info panel already shows.
func _show_hover(hover_point: Variant) -> void:
	var picked := dish.hovered
	var bup_id := picked.bup
	var source := picked.source
	var floating := picked.plankton
	var husk_place := picked.husk
	var husk := dish.husk_details(husk_place) if husk_place != Dish.NO_HUSK else {}
	if husk_place != Dish.NO_HUSK and husk.is_empty():  # (it has leaked away)
		picked.husk = Dish.NO_HUSK
		husk_place = Dish.NO_HUSK
	var chosen := dish.selected
	if (bup_id >= 0 and bup_id == chosen.bup) or (source != null and source == chosen.source) or (floating != null and floating == chosen.plankton) or (husk_place != Dish.NO_HUSK and husk_place == chosen.husk):
		hover_card.visible = false  # (the pointer is over what the info panel shows)
		return
	var alive_info: Dictionary = dish.bup_info(bup_id) if bup_id >= 0 else {}
	if bup_id >= 0 and alive_info.is_empty() and dish.has_bup(bup_id):
		alive_info = dish.lineage_info(bup_id)
	var dead := bup_id >= 0 and alive_info.is_empty()
	var something := bup_id >= 0 or source != null or floating != null or not husk.is_empty()
	hover_card.visible = something or hover_point != null
	hover_card.theme_type_variation = &"DeceasedPanel" if dead else &"HudPanel"
	var shows_bup := bup_id >= 0
	hover_gauges.visible = shows_bup
	hover_genome.visible = shows_bup
	hover_tail.visible = shows_bup
	if bup_id >= 0:
		_point_stamp = []
		var record := dish.lineage_info(bup_id) if dead else alive_info
		var body := PanelText.deceased(record, number_of.call(dish)) if dead else PanelText.bup(alive_info, number_of.call(dish))
		hover_genome.show_bup(record, false)
		readout.set_text(hover_tail, PanelText.tail(record), "tail %d" % bup_id)
		hover_gauges.show_bup(record, dish.stationary_phase, not dead)
		body = "%s\n%s" % [dish.bup_display(bup_id).get("name", ""), body]  # (the hover card has no name row)
		readout.set_text(hover_text, body, "bup %d" % bup_id)
	elif source != null:
		_point_stamp = []
		readout.set_text_when_due(hover_text, "source %d" % source.get_instance_id(), func() -> String: return _titled("panel.source_title", PanelText.source(dish.source_details(source))))
	elif floating != null:
		_point_stamp = []
		readout.set_text_when_due(hover_text, "plankton %d" % floating.get_instance_id(), func() -> String: return _titled("panel.plankton_title", PanelText.plankton(dish.plankton_details(floating))))
	elif not husk.is_empty():
		_point_stamp = []
		readout.set_text_when_due(hover_text, "husk %s" % husk_place, func() -> String: return _titled("panel.husk_title", PanelText.husk(husk)))
	elif hover_point != null:
		var point_stamp := [hover_point, dish.time, dish.edit_count]
		if point_stamp != _point_stamp:  # (the readout is worked out again only when the spot or the dish has changed)
			_point_stamp = point_stamp
			readout.set_text(hover_text, PanelText.point(dish.nutrient_at(hover_point)), "point")


## A card's words under their title (the info panel has the title beside its close button instead).
func _titled(title_key: String, body: String) -> String:
	return "%s\n%s" % [Strings.t(title_key), body]


## The hover card follows the pointer, kept inside the window.
func place_hover_card() -> void:
	if not hover_card.visible:
		return
	hover_card.size = Vector2.ZERO  # (a card does not shrink by itself when its words get fewer: the bup's is taller than the nutrient's)
	var viewport := hover_card.get_viewport()
	var view := viewport.get_visible_rect().size
	var mouse := viewport.get_mouse_position()
	var at := mouse + Vector2(20.0, 20.0)
	if at.x + hover_card.size.x > view.x - 8.0:
		at.x = mouse.x - 20.0 - hover_card.size.x
	if at.y + hover_card.size.y > view.y - 8.0:
		at.y = mouse.y - 20.0 - hover_card.size.y
	hover_card.position = at.clamp(Vector2(8.0, 8.0), (view - hover_card.size - Vector2(8.0, 8.0)).max(Vector2(8.0, 8.0)))


## Whether the bup's divisions count went up just now: the number after "divisions" in the panel then shows in the flash colour for FLASH_MSEC, so that the drop in its mass and reserve
## that comes with a division is seen to have a reason.
func note_divisions(id: int, info: Dictionary) -> bool:
	var divisions := int(info["divisions"])
	var now := Time.get_ticks_msec()
	if id != _divisions_of or divisions < _divisions_seen:
		_divisions_of = id  # (another bup is shown: nothing has just happened to it)
		_flash_until = 0
	elif divisions > _divisions_seen:
		_flash_until = now + FLASH_MSEC
	_divisions_seen = divisions
	return now < _flash_until


## Puts the selected source's rate in the row, without that counting as the player changing it.
func _show_source_rate(source: NutrientSource) -> void:
	if not source_rate_row.is_dragging() and not is_equal_approx(source_rate_row.value, snappedf(source.rate, 0.1)):
		source_rate_row.set_value_silently(source.rate)


func _on_source_rate_changed(rate: float) -> void:
	if dish.selected.source != null:
		dish.selected.source.rate = rate


func delete_selected_source() -> void:
	if dish.selected.source != null:
		dish.remove_source(dish.selected.source)


## The Watch button: the selected bup goes on the watch list, or comes off it.
func toggle_watch() -> void:
	var id := dish.selected.bup
	if dish.is_watched(id):
		dish.unwatch_bup(id)
	else:
		dish.watch_bup(id)
