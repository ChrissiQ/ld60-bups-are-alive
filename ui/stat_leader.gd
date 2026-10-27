class_name StatLeader
extends Control
## The pale dotted line between a stat's name and its value (see StatRow), so the eye can follow a row across the panel. Its colour is the theme type "StatLeader".

const THEME_TYPE := "StatLeader"
const GAP := 6.0  ## room left clear at each end, beside the words
const DOT := 2.0
const HEIGHT_SHARE := 0.72  ## how far down the row the line sits (near the baseline of the words)


func _draw() -> void:
	var y := size.y * HEIGHT_SHARE
	if size.x > 2.0 * GAP + DOT:
		draw_dashed_line(Vector2(GAP, y), Vector2(size.x - GAP, y), get_theme_color("line", THEME_TYPE), 1.0, DOT * 2.0)
