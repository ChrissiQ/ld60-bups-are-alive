class_name Tutorial
extends Control
## A guided tour of the screen: one part at a time is lit and explained on a card, and the rest is dimmed. A step is either
## read (the game is held, nothing behind the card can be clicked, and Next goes on) or acted on (the player is asked to
## do something, such as select a bup: Next stays shut until it is done, and the tour goes on the moment it is. Coming back
## to such a step does not go on again: it is shown, with Next open while what it asked for still holds). Skip is always there,
## and so is Escape. The screen that shows the tour gives it its steps (see `start`) and undoes whatever the tour set up when it
## closes: this only draws the steps and moves through them.
##
## A step is a Dictionary: "text" (what the card says), "target" (a Callable giving the lit part of the screen as a Rect2,
## or none: the card is then in the middle), "wait" (a Callable that returns true once the player has done what was asked:
## without it the step is read), "enter" (a Callable done when the step begins), "title" (a few words saying which part
## this is) and "escape_passes" (Escape goes to the game, not to Skip: the step asks for something Escape does there).
## While a step waits, the dimming still takes every click, so only what is lit can be pressed.

signal closed(completed: bool)  ## the tour ended: finished (true) or skipped (false)

const SPOT_PAD := 6.0  ## screen pixels the lit part is outlined outside what is lit
const CARD_GAP := 18.0  ## between the lit part and its card
const SCREEN_MARGIN := 16.0  ## the card keeps this far from the edges
const PULSE_SECONDS := 0.8  ## the outline fades in and out so the eye finds it

@onready var scrims: Array[Panel] = [$ScrimTop, $ScrimBottom, $ScrimLeft, $ScrimRight]
@onready var spot: Panel = $Spot
@onready var card: PanelContainer = $Card
@onready var title_label: Label = $Card/Box/TitleRow/Title
@onready var step_label: Label = $Card/Box/TitleRow/Step
@onready var text_label: Label = $Card/Box/Text
@onready var waiting_label: Label = $Card/Box/Waiting
@onready var skip_button: Button = $Card/Box/Actions/SkipButton
@onready var back_button: Button = $Card/Box/Actions/Pair/BackButton
@onready var next_button: Button = $Card/Box/Actions/Pair/NextButton

var active := false
var blocking := false  ## the step is being read: the game is held and nothing behind the card can be clicked
var index := -1
var _steps: Array[Dictionary] = []
var _pulse: Tween = null
var _was_satisfied := false  ## whether the step's condition held a moment ago: the tour goes on when it starts to, not when it already does


func _ready() -> void:
	visible = false
	skip_button.pressed.connect(skip)
	next_button.pressed.connect(next)
	back_button.pressed.connect(back)
	skip_button.text = Strings.t("tutorial.skip")
	back_button.text = Strings.t("tutorial.back")
	waiting_label.text = Strings.t("tutorial.waiting")
	skip_button.focus_mode = Control.FOCUS_NONE
	next_button.focus_mode = Control.FOCUS_NONE
	back_button.focus_mode = Control.FOCUS_NONE


func start(steps: Array[Dictionary]) -> void:
	if steps.is_empty():
		return
	_steps = steps
	active = true
	visible = true
	_pulse = create_tween().set_loops()
	_pulse.tween_property(spot, "modulate:a", 0.45, PULSE_SECONDS)
	_pulse.tween_property(spot, "modulate:a", 1.0, PULSE_SECONDS)
	_show_step(0)


## Whether the step's own condition is met (a step that asks for nothing is always met): Next is only open when it is.
func satisfied() -> bool:
	var wait: Callable = _steps[index].get("wait", Callable())
	return not wait.is_valid() or wait.call()


func next() -> void:
	if not active or not satisfied():
		return
	if index + 1 >= _steps.size():
		_close(true)
	else:
		_show_step(index + 1)


func back() -> void:
	if not active or index == 0:
		return
	_show_step(index - 1)


func skip() -> void:
	if active:
		_close(false)


func _close(completed: bool) -> void:
	active = false
	blocking = false
	visible = false
	if _pulse != null:
		_pulse.kill()
	closed.emit(completed)


func _show_step(i: int) -> void:
	index = i
	var step := _steps[i]
	var enter: Callable = step.get("enter", Callable())
	if enter.is_valid():
		enter.call()
	var wait: Callable = step.get("wait", Callable())
	blocking = not wait.is_valid()
	# A step being read takes every click. One that asks for something takes all but those on what is lit (the dimming round it
	# does the taking), so the player cannot wander off and spoil what the step needs.
	mouse_filter = Control.MOUSE_FILTER_STOP if blocking else Control.MOUSE_FILTER_IGNORE
	for scrim in scrims:
		scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE if blocking else Control.MOUSE_FILTER_STOP
	title_label.text = step["title"]
	step_label.text = Strings.t("tutorial.step", [i + 1, _steps.size()])
	text_label.text = step["text"]
	waiting_label.visible = not blocking
	back_button.visible = i > 0
	_was_satisfied = satisfied()
	next_button.disabled = not _was_satisfied
	next_button.text = Strings.t("tutorial.done" if i == _steps.size() - 1 else "tutorial.next")
	_layout()


func _process(_delta: float) -> void:
	if not active:
		return
	var now := satisfied()
	next_button.disabled = not now
	if now and not _was_satisfied:
		next()  # (what the step asked for has just been done)
		return
	_was_satisfied = now
	_layout()  # (what is lit can move: the window changes shape, a panel appears)


func _input(event: InputEvent) -> void:
	if not active or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_F12:
		return  # (the debug log is taken from the tour too)
	if event.keycode == KEY_ESCAPE and _steps[index].get("escape_passes", false):
		return  # (the step asks for something Escape does in the game)
	if event.keycode == KEY_ESCAPE:
		skip()
	elif event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_RIGHT]:
		next()  # (which does nothing while the step still asks for something)
	elif event.keycode == KEY_LEFT:
		back()
	get_viewport().set_input_as_handled()  # (none of the game's shortcuts act behind the tour: a tool key would spoil the step)


## The lit part of the screen for this step, or an empty Rect2 when the step lights nothing.
func target_rect() -> Rect2:
	var target: Callable = _steps[index].get("target", Callable())
	return target.call() if target.is_valid() else Rect2()


func _layout() -> void:
	var view := get_viewport_rect().size
	var hole := target_rect()
	var lit := hole.has_area()
	if lit:
		hole = hole.grow(SPOT_PAD).intersection(Rect2(Vector2.ZERO, view))
	spot.visible = lit
	if lit:
		spot.position = hole.position
		spot.size = hole.size
	_place_scrims(hole if lit else Rect2(), view)
	card.size = card.get_combined_minimum_size()
	card.position = _card_position(card.size, hole if lit else Rect2(), view)


## The dimming is four panels round the lit part (or one over everything when nothing is lit), so what is lit stays bright.
func _place_scrims(hole: Rect2, view: Vector2) -> void:
	var rects: Array[Rect2] = [Rect2(Vector2.ZERO, view), Rect2(), Rect2(), Rect2()]
	if hole.has_area():
		rects = [
			Rect2(0, 0, view.x, hole.position.y),
			Rect2(0, hole.end.y, view.x, view.y - hole.end.y),
			Rect2(0, hole.position.y, hole.position.x, hole.size.y),
			Rect2(hole.end.x, hole.position.y, view.x - hole.end.x, hole.size.y),
		]
	for k in 4:
		scrims[k].position = rects[k].position
		scrims[k].size = rects[k].size


## Beside the lit part where there is room (below for what is along the top, else right, left, below, then above), kept on
## the screen, and in the middle when nothing is lit.
func _card_position(size: Vector2, hole: Rect2, view: Vector2) -> Vector2:
	if not hole.has_area():
		return ((view - size) * 0.5).floor()
	var bounds := Rect2(Vector2.ONE * SCREEN_MARGIN, view - Vector2.ONE * 2.0 * SCREEN_MARGIN - size)
	var centre := hole.get_center()
	var right := Vector2(hole.end.x + CARD_GAP, centre.y - size.y * 0.5)
	var left := Vector2(hole.position.x - CARD_GAP - size.x, centre.y - size.y * 0.5)
	var below := Vector2(centre.x - size.x * 0.5, hole.end.y + CARD_GAP)
	var above := Vector2(centre.x - size.x * 0.5, hole.position.y - CARD_GAP - size.y)
	var options := [below, right, left, above] if centre.y < view.y * 0.2 else [right, left, below, above]  # (under a lit part along the top, which would otherwise have the card across the rest of its bar)
	var fallback := Vector2.ZERO
	for k in options.size():
		var p: Vector2 = options[k]
		p = Vector2(clampf(p.x, bounds.position.x, bounds.end.x), clampf(p.y, bounds.position.y, bounds.end.y))
		if k == 0:
			fallback = p
		if not Rect2(p, size).intersects(hole):
			return p.floor()
	return fallback.floor()
