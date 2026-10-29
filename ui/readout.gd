class_name Readout
extends RefCounted
## Sets the text of the screen's readouts. The readouts are asked for every frame, so the styling (a regex pass) and
## the re-parse only run when the text has actually changed; and at high playback speed the figures of what stays
## shown change at most every LIVE_TEXT_MSEC, since they would only flicker.

const LIVE_TEXT_MSEC := 100  ## at high playback speed the readouts are rewritten this often at most: faster is a flicker, not information
const LIVE_TEXT_FROM_SPEED := 100.0  ## the playback speed from which that applies

var is_live := func() -> bool: return false  ## whether the readouts are throttled now (time is moving fast)


## Sets a readout's text. `about` says what the text is about (a bup, the medium at a point...): while the same thing
## stays shown and time is live, its figures change at most every LIVE_TEXT_MSEC. True when the text was changed.
func set_text(label: RichTextLabel, text: String, about: String, flash := false) -> bool:
	var shown := text + ("\u0001" if flash else "")  # (what is asked for: the text, and whether its first number is flashing)
	if label.get_meta("raw", "") == shown or not due(label, about):
		return false
	stamp(label, about)
	label.set_meta("raw", shown)
	label.text = UiText.numbers(text, "divisions" if flash else "")
	return true


## Whether a readout would take new text about `about` now (see set_text). Asked before working the text out, so that
## at high playback speed, where most frames change nothing, it is not worked out for nothing.
func due(label: Control, about: String) -> bool:
	return not (is_live.call() and label.get_meta("about", "") == about and Time.get_ticks_msec() - label.get_meta("set_at", 0) < LIVE_TEXT_MSEC)


## Notes that a readout was just updated by the caller (a label whose text is not set through set_text): `due` then holds it for LIVE_TEXT_MSEC.
func stamp(label: Control, about: String) -> void:
	label.set_meta("about", about)
	label.set_meta("set_at", Time.get_ticks_msec())


## Makes the next set_text on a readout take its text even when it is the same as the one shown (the text is for something else now).
func forget(label: Control) -> void:
	label.set_meta("raw", "")


## set_text with the text worked out (by `make_text`) only if it is due.
func set_text_when_due(label: RichTextLabel, about: String, make_text: Callable) -> void:
	if due(label, about):
		set_text(label, make_text.call(), about)
