extends Control
## Story screen shown once when a new experiment begins.

const START_DELAY := 0.9  ## seconds of lightning before the text starts typing
const CHARS_PER_SECOND := 70.0

@onready var body: Label = $Box/Body
@onready var prompt: Label = $Box/Prompt
@onready var flash: ColorRect = $Flash

var _typed := 0.0
var _delay := START_DELAY
var _done := false
var _leaving := false


func _ready() -> void:
	body.visible_characters = 0
	prompt.modulate.a = 0.0
	# Lightning: a hard flash, then a smaller flicker as it fades.
	flash.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_property(flash, "modulate:a", 0.0, 0.2)
	tween.tween_property(flash, "modulate:a", 0.7, 0.05)
	tween.tween_property(flash, "modulate:a", 0.0, 0.9)


func _process(delta: float) -> void:
	if _done:
		# Pulse the prompt so it reads as waiting for a key.
		prompt.modulate.a = 0.6 + 0.4 * sin(Time.get_ticks_msec() / 350.0)
		return
	if _delay > 0.0:
		_delay -= delta
		return
	_typed += CHARS_PER_SECOND * delta
	body.visible_characters = int(_typed)
	if body.visible_characters >= body.get_total_character_count():
		_finish_typing()


func _unhandled_input(event: InputEvent) -> void:
	var pressed_key: bool = event is InputEventKey and event.pressed and not event.echo
	var clicked: bool = event is InputEventMouseButton and event.pressed
	if not (pressed_key or clicked):
		return
	if pressed_key and event.keycode == KEY_ESCAPE:
		_begin()
	elif _done:
		_begin()
	else:
		_finish_typing()


func _finish_typing() -> void:
	_done = true
	body.visible_characters = -1


func _begin() -> void:
	if _leaving:
		return
	_leaving = true
	get_tree().change_scene_to_file(Scenes.GAME)
