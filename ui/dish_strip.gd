class_name DishStrip
extends PanelContainer
## Every dish that is running, a tab each in the top bar in the order they came: a small picture of it (its tile of the simulation's
## thumbnails' atlas, redrawn once a second: ThumbAtlas, DishThumb) and its number (its bups are in its tip), and beside the tabs how many
## dishes there are. The dish in the main view is lit, and a click on another reports it (`dish_chosen`) for the screen to bring into the
## main view. The strip is hidden while there is only one dish.
##
## The tabs scroll sideways inside a width the top bar can afford (`max_width`), and only those in view and OVERSCAN either side are made:
## they are reused for other dishes as the strip scrolls, and a spacer at each end stands for the tabs that are not made, so a thousand
## dishes cost what a screenful does. Every tab is as wide as a three-digit number needs, so where a tab lies is arithmetic.

signal dish_chosen(dish: Dish)

const REFRESH_SECONDS := 1.0  ## how often the tabs' tips (their bups) are written again
const THUMB := 44  ## pixels across a picture (shown smaller, so it stays sharp on a dense display)
const OVERSCAN := 4  ## tabs made past each end of what is in view
const REPEAT_DELAY := 0.4  ## seconds an arrow is held before it goes on by itself
const REPEAT_EVERY := 0.12  ## and then one tab every so many seconds
const PAGE_AFTER := 1.5  ## seconds an arrow is held after which it moves a whole view at a time (a thousand tabs are crossed in seconds)
const MIN_DIGITS := 3  ## every tab has room for a number this long (dishes are shown by 1 to 999: Main.MAX_DISHES), so the tabs keep one width

var max_width := 240.0:  ## the most width the strip takes (its tabs, arrows and count); with more tabs than fit, they scroll
	set(value):
		if value == max_width:
			return  # (the top bar sets it every frame: the tabs are laid out again only when it changes)
		max_width = value
		_fit()

var tab_height := 0.0:  ## how tall every tab is (the top bar gives it the height of a layer toggle, so the two rows of the bar line up)
	set(value):
		if value == tab_height:
			return
		tab_height = value
		for tab in _tabs:
			tab.custom_minimum_size.y = value

@onready var scroll: ScrollContainer = $Bar/Scroll  ## the tabs in view (see `max_width`)
@onready var row: HBoxContainer = $Bar/Scroll/Row
@onready var lead: Control = $Bar/Scroll/Row/Lead  ## stands for the tabs before the first one made
@onready var tail: Control = $Bar/Scroll/Row/Tail  ## and for those after the last
@onready var previous_button: Button = $Bar/Previous  ## an arrow at each end, there while the tabs do not all fit: a click moves by one tab, and holding goes on
@onready var next_button: Button = $Bar/Next
@onready var count_label: Label = $Bar/Count  ## how many dishes run

var _entries: Array[Dictionary] = []  ## {dish, number} in the order of the tabs
var _index := {}  ## Dish -> its place in _entries
var _top := 0  ## the biggest number a tab has had (a number of more than MIN_DIGITS would widen every tab)
var _tabs: Array[Button] = []  ## the tabs made, in order: tab k shows entry _first + k
var _first := 0
var _lit: Dish = null  ## the dish in the main view
var _atlas := ThumbAtlas.new()
var _atlas_version := -1
var _tab_width := 0.0  ## every tab's width
var _measured_for := []  ## what `_tab_width` was measured for: [digits, font size]
var _since := REFRESH_SECONDS
var _held := 0  ## the arrow held down: -1 the left one, 1 the right one, 0 none
var _held_for := 0.0  ## how long it has been held, from minus the delay before it starts repeating
var _held_total := 0.0


func _ready() -> void:
	previous_button.button_down.connect(_press.bind(-1))
	next_button.button_down.connect(_press.bind(1))
	for button: Button in [previous_button, next_button]:
		button.button_up.connect(func() -> void: _held = 0)
	scroll.get_h_scroll_bar().value_changed.connect(func(_v: float) -> void: _lay_out())
	scroll.resized.connect(_lay_out)
	scroll.gui_input.connect(_wheel)


## The atlas's imports go with the strip (not when it leaves the tree: the top bar moves it between its rows).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_atlas.release()


func _process(delta: float) -> void:
	if not visible:
		return
	var bar := scroll.get_h_scroll_bar()
	previous_button.disabled = scroll.scroll_horizontal <= 0
	next_button.disabled = scroll.scroll_horizontal >= bar.max_value - bar.page - 0.5
	if _held != 0:
		_held_for += delta
		_held_total += delta
		while _held_for >= REPEAT_EVERY:
			_held_for -= REPEAT_EVERY
			_step(_held * (_in_view() if _held_total >= PAGE_AFTER else 1))


func _gui_input(event: InputEvent) -> void:
	_wheel(event)


## The wheel over the strip (its tabs too) moves it a tab a notch.
func _wheel(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT:
			_step(-1)
			accept_event()
		MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_RIGHT:
			_step(1)
			accept_event()


## An arrow went down: it moves by one tab now, and goes on moving while it is held (after a moment; a view at a time after longer).
func _press(direction: int) -> void:
	_step(direction)
	_held = direction
	_held_for = -REPEAT_DELAY
	_held_total = 0.0


## Scrolls `tabs` tabs along (negative: left), to a tab's edge, within the ends.
func _step(tabs: int) -> void:
	var pitch := _pitch()
	if pitch <= 0.0:
		return
	var at := roundi(scroll.scroll_horizontal / pitch) + tabs
	scroll.scroll_horizontal = int(clampf(at * pitch, 0.0, _content_width() - scroll.size.x))


func add(dish: Dish, number: int) -> void:
	_index[dish] = _entries.size()
	_entries.append({"dish": dish, "number": number})
	_top = maxi(_top, number)
	_since = REFRESH_SECONDS
	_changed()


func remove(dish: Dish) -> void:
	if not _index.has(dish):
		return
	_entries.remove_at(_index[dish])
	_index.clear()
	for i in _entries.size():
		_index[_entries[i]["dish"]] = i
	if _lit == dish:
		_lit = null
	_changed()


func clear() -> void:
	_entries.clear()
	_index.clear()
	_top = 0
	_lit = null
	_changed()


func count() -> int:
	return _entries.size()


## The tabs made now (at most those in view and OVERSCAN either side).
func tabs_made() -> int:
	return _tabs.size()


## Lights the tab of the dish in the main view, and scrolls it into view.
func light(main_dish: Dish) -> void:
	_lit = main_dish
	_lay_out()
	_scroll_to_lit.call_deferred()  # (once the row has its new width: a tab just added is past the old end)


## Brings the lit tab into view (in the middle of it) when it is not.
func _scroll_to_lit() -> void:
	if not _index.has(_lit) or not is_node_ready():
		return
	var pitch := _pitch()
	var left: float = _index[_lit] * pitch
	if left < scroll.scroll_horizontal or left + pitch > scroll.scroll_horizontal + _view_width():
		scroll.scroll_horizontal = int(clampf(left - 0.5 * (_view_width() - pitch), 0.0, maxf(_content_width() - _view_width(), 0.0)))


## Called every frame: the newest atlas is taken (and the textures used told), and now and then the tabs' tips are written again.
func refresh(delta: float) -> void:
	if not visible or _entries.is_empty():
		return
	_atlas.tick(WorldClient.shared())
	_since += delta
	if _since < REFRESH_SECONDS and _atlas.version() == _atlas_version:
		return
	_since = 0.0
	_atlas_version = _atlas.version()
	for k in _tabs.size():
		_bind(_tabs[k], _first + k)


## The picture of a dish as the atlas last had it (an image of its tile), or null when there is none (a headless run draws nothing).
func picture_of(dish: Dish) -> Image:
	return _atlas.picture(dish.row) if dish != null else null


## The dishes came or went: the count, whether the strip shows, the tabs' width and which are made.
func _changed() -> void:
	visible = _entries.size() > 1
	if not is_node_ready():
		return
	count_label.text = Strings.t("dish_strip.count", [UiText.thousands(_entries.size())])
	_fit.call_deferred()
	_lay_out()


## Makes the tabs in view and OVERSCAN either side (and no more), shows in each the dish its place stands for, and sizes the spacers for
## the rest.
func _lay_out() -> void:
	if not is_node_ready():
		return
	var n := _entries.size()
	_measure()
	var pitch := _pitch()
	var sep := float(row.get_theme_constant("separation"))
	var span := ceili(_view_width() / pitch) + 1 + 2 * OVERSCAN
	var first := clampi(floori(scroll.scroll_horizontal / pitch) - OVERSCAN, 0, maxi(n - 1, 0))
	var last := mini(n, first + span)
	var want := maxi(last - first, 0)
	while _tabs.size() < want:
		_tabs.append(_new_tab())
	while _tabs.size() > want:
		var gone: Button = _tabs.pop_back()
		row.remove_child(gone)  # (out of the row now; freed once whatever it is doing this frame is done)
		gone.queue_free()
	_first = first
	lead.visible = first > 0
	lead.custom_minimum_size.x = first * pitch - sep
	tail.visible = last < n
	tail.custom_minimum_size.x = (n - last) * pitch - sep
	for k in want:
		_bind(_tabs[k], first + k)


func _new_tab() -> Button:
	var tab := Button.new()
	tab.theme_type_variation = &"DishTab"
	tab.toggle_mode = true
	tab.focus_mode = Control.FOCUS_NONE
	var thumb := DishThumb.new()
	thumb.size = THUMB
	tab.icon = thumb
	tab.custom_minimum_size = Vector2(_tab_width, tab_height)
	tab.pressed.connect(_on_tab.bind(tab))
	tab.gui_input.connect(_wheel)
	row.add_child(tab)
	row.move_child(tab, tail.get_index())
	return tab


## Shows entry `i` in `tab`: its number, its tip, its picture and whether it is the one in view.
func _bind(tab: Button, i: int) -> void:
	var entry := _entries[i]
	var dish: Dish = entry["dish"]
	tab.set_meta(&"entry", i)
	tab.text = Strings.t("dishes.caption", [entry["number"]])
	tab.tooltip_text = Strings.t("dishes.tip", [entry["number"], UiText.thousands(dish.population())])
	tab.custom_minimum_size.x = _tab_width
	var thumb := tab.icon as DishThumb
	thumb.atlas = _atlas.texture()
	thumb.region = _atlas.region(dish.row)
	tab.set_pressed_no_signal(dish == _lit)
	tab.queue_redraw()


func _on_tab(tab: Button) -> void:
	var i := int(tab.get_meta(&"entry", -1))
	tab.set_pressed_no_signal(i >= 0 and i < _entries.size() and _entries[i]["dish"] == _lit)  # (lit only when the screen brings it into view: `light`)
	if i >= 0 and i < _entries.size():
		dish_chosen.emit(_entries[i]["dish"])


## Every tab is as wide as a tab with a number of MIN_DIGITS (or the most digits a number has had, were there more) in the widest digit needs:
## measured again when the text size changes.
func _measure() -> void:
	var digits := maxi(MIN_DIGITS, str(_top).length())
	var probe := _tabs[0] if not _tabs.is_empty() else _new_tab()
	var key := [digits, probe.get_theme_font_size("font_size")]
	if key == _measured_for and _tab_width > 0.0:
		return
	_measured_for = key
	var text := probe.text
	probe.custom_minimum_size.x = 0.0
	_tab_width = 0.0
	for digit in 10:
		probe.text = Strings.t("dishes.caption", [1]).replace("1", str(digit).repeat(digits))
		_tab_width = maxf(_tab_width, probe.get_combined_minimum_size().x)
	probe.text = text
	probe.custom_minimum_size.x = _tab_width
	if _tabs.is_empty():
		probe.free()
	_fit.call_deferred()


## A tab's width and the gap after it.
func _pitch() -> float:
	return maxf(_tab_width, 1.0) + float(row.get_theme_constant("separation"))


## How many tabs the view holds whole.
func _in_view() -> int:
	return maxi(1, floori(_view_width() / _pitch()))


func _view_width() -> float:
	return scroll.size.x if scroll.size.x > 0.0 else scroll.custom_minimum_size.x


## The width all the tabs together take.
func _content_width() -> float:
	return maxf(_entries.size() * _pitch() - float(row.get_theme_constant("separation")), 0.0)


## The tabs take the width they need, up to `max_width`; when they do not all fit the arrows come, out of that width.
func _fit() -> void:
	if not is_node_ready():
		return
	var needed := _content_width()
	var overflow := needed > max_width  # (the count and the arrows come only when the tabs do not all fit)
	var room := max_width - (_count_width() if overflow else 0.0)
	count_label.visible = overflow
	previous_button.visible = overflow
	next_button.visible = overflow
	scroll.custom_minimum_size.x = maxf(minf(needed, room - (_arrows_width() if overflow else 0.0)), 24.0)
	_lay_out()


## The width the whole strip would take with every tab in view (no count then).
func full_width() -> float:
	return _content_width()


## What the two arrows take with their gaps.
func _arrows_width() -> float:
	return previous_button.get_combined_minimum_size().x + next_button.get_combined_minimum_size().x + 2.0 * float($Bar.get_theme_constant("separation"))


## What the count beside the tabs takes with its gap.
func _count_width() -> float:
	return count_label.get_combined_minimum_size().x + float($Bar.get_theme_constant("separation"))


## The least the strip is given by choice: its arrows, two tabs and the count (the arrows reach the rest).
func shortest_width() -> float:
	return minf(_arrows_width() + 2.0 * _pitch() + _count_width(), full_width())


## The least it can be at all, when the window leaves no more: its arrows, a sliver of a tab and the count.
func narrowest_width() -> float:
	return minf(_arrows_width() + 24.0 + _count_width(), full_width())
