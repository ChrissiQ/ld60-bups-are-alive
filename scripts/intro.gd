extends Control
## Story screen shown once when a new experiment begins.

const START_DELAY := 0.9  ## seconds of lightning before the text starts typing
const CHARS_PER_SECOND := 110.0
const START_DEPTH := 0.35  ## how far down the panel, as a share of its height, the text starts
const END_SPACE := 0.25  ## the same, for the prompt once the typing has finished: the text rises a few more lines to put it there
const LINE_DELAY := 0.2  ## the least time, in seconds, an empty line takes, as though a typewriter were returning its carriage over it
const EDGE_SPACE := 0.05  ## the distance, as a share of the panel height, kept between the typing and the panel's bottom edge

@onready var scroll: ScrollContainer = $Scroll
@onready var page: VBoxContainer = $Scroll/Page
@onready var box: VBoxContainer = $Scroll/Page/Box
@onready var top_space: Control = $Scroll/Page/TopSpace
@onready var more_space: Control = $Scroll/Page/MoreSpace
@onready var body: Label = $Scroll/Page/Box/Body
@onready var prompt: Label = $Scroll/Page/Box/Prompt
@onready var flash: ColorRect = $Flash

var _typed := 0.0
var _delay := START_DELAY
var _done := false
var _leaving := false
var _ready_to_type := false
var _blank_lines: Array[int] = []  ## the position in the text of each empty line's newline
var _next_blank := 0
var _pause := 0.0  ## time left in the pause an empty line has just taken
var _rise_target := 0.0  ## where the text is to rise to once the typing has finished
var _rise_timer := 0.0
var _line_count := 1  ## the lines the whole text takes
var _user_scrolled := false


func _ready() -> void:
	Strings.apply(self)  # (the texts the scene gives as @section.name)
	_reserve_layout()
	scroll.gui_input.connect(_on_scroll_input)
	prompt.modulate.a = 0.0
	# Lightning: a hard flash, then a smaller flicker as it fades.
	flash.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_property(flash, "modulate:a", 0.0, 0.2)
	tween.tween_property(flash, "modulate:a", 0.7, 0.05)
	tween.tween_property(flash, "modulate:a", 0.0, 0.9)


func _process(delta: float) -> void:
	if _done:
		_rise(delta)
		# Pulse the prompt so it reads as waiting for a key.
		prompt.modulate.a = 0.6 + 0.4 * sin(Time.get_ticks_msec() / 350.0)
		return
	if not _ready_to_type:
		return
	if _delay > 0.0:
		_delay -= delta
		return
	if _pause > 0.0:
		_pause -= delta
		return
	_typed += CHARS_PER_SECOND * delta
	if _next_blank < _blank_lines.size() and _typed > _blank_lines[_next_blank]:
		_typed = _blank_lines[_next_blank] + 1.0  # (it stops at the empty line, which takes its time)
		_pause = LINE_DELAY
		_next_blank += 1
	body.visible_characters = int(_typed)
	_follow_typing()
	if body.visible_characters >= body.get_total_character_count():
		_finish_typing()


## The text is shown in a panel inset from the top and bottom of the screen (the Scroll node), and scrolls out of that panel,
## never off the screen. It starts typing partway down the panel, and starts rising while it is still well clear of the
## panel's bottom edge, so the prompt at its end comes to rest well clear of it too.
## The text's full height is fixed before it starts typing, so that nothing moves while it types.
func _reserve_layout() -> void:
	body.visible_characters = -1
	for frame in 3:
		await get_tree().process_frame
	body.custom_minimum_size.y = body.get_combined_minimum_size().y
	_line_count = body.get_line_count()
	var at := body.text.find("\n\n")
	while at >= 0:
		_blank_lines.append(at + 1)
		at = body.text.find("\n\n", at + 1)
	body.visible_characters = 0
	var panel_height := scroll.size.y
	top_space.custom_minimum_size.y = panel_height * START_DEPTH
	more_space.custom_minimum_size.y = panel_height * (END_SPACE + 0.1)  # (room for the scroll to carry the prompt up to its place)
	page.custom_minimum_size.y = panel_height
	_ready_to_type = true


## Once the typing comes within a generous distance of the panel's bottom, the text rises one line each time a new line
## appears (never back up, and never once the player has scrolled by hand).
func _follow_typing() -> void:
	if _user_scrolled or body.get_total_character_count() == 0:
		return
	var line_pitch := body.size.y / _line_count
	var lines_appeared := body.get_line_count()  # (the label counts only the lines that have appeared so far, blank ones included)
	var typing_y := box.position.y + body.position.y + line_pitch * lines_appeared  # (the bottom of the last line that has appeared)
	_scroll_to_show(typing_y, EDGE_SPACE)


## Raises the text, if it needs it, so that `y` (a position on the page) is no nearer the panel's bottom than `space` (a share of the panel's height).
func _scroll_to_show(y: float, space: float) -> void:
	var panel_height := scroll.size.y
	scroll.scroll_vertical = maxi(scroll.scroll_vertical, int(y - panel_height * (1.0 - space)))


## After the last line, the text rises to its resting place a line at a time, each taking a moment.
func _rise(delta: float) -> void:
	if _user_scrolled or scroll.scroll_vertical >= _rise_target:
		return
	_rise_timer -= delta
	if _rise_timer <= 0.0:
		_rise_timer = LINE_DELAY
		scroll.scroll_vertical = mini(scroll.scroll_vertical + int(body.size.y / _line_count), ceili(_rise_target))


func _on_scroll_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] or event is InputEventPanGesture:
		_user_scrolled = true


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_ESCAPE:
		_begin()
	elif event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER] and _ready_to_type:  # (not before the text is laid out)
		if _done:
			_begin()
		else:
			_finish_typing(true)


func _finish_typing(skipped := false) -> void:
	_done = true
	body.visible_characters = -1
	_rise_target = box.position.y + prompt.position.y + prompt.size.y - scroll.size.y * (1.0 - END_SPACE)  # (the prompt comes to rest well clear of the panel's bottom)
	if skipped:
		scroll.scroll_vertical = maxi(scroll.scroll_vertical, ceili(_rise_target))  # (skipping goes straight there, not a line at a time)


func _begin() -> void:
	if _leaving:
		return
	_leaving = true
	get_tree().change_scene_to_file(Scenes.GAME)
