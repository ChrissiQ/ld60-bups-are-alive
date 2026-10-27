class_name GaugeBar
extends Control
## One bar of the bup's panel, in the two forms the panel uses (see BupGauges): the MASS bar, whose fill is the body's length (mass drawn as a length, left to right), with a tick for the
## mass it was born with and, when starvation is on, one for the mass it dies at, its track ending where it divides; and the RESERVE bar, whose track is the most the body can hold, its
## fill what it holds, a tick for the floor below which growth stops, and a muted band up to it. Colours are the theme type "GaugeBar"; `tone` picks the fill's.

enum Tone { NORMAL, LIMITED, STARVING, DEAD }
enum Kind { MASS, RESERVE }

const THEME_TYPE := "GaugeBar"
const CAPSULE_HEIGHT := 14.0
const BAR_HEIGHT := 8.0
const TICK_WIDTH := 2.0
const TICK_OVERHANG := 3.0

var kind := Kind.MASS
var tone := Tone.NORMAL
var fraction := 0.0  ## how far the fill goes, 0 to 1 of the track
var ticks: Array[float] = []  ## where the white ticks stand, as shares of the track (the mass bar's birth, the reserve bar's floor)
var mark := -1.0  ## where the red tick stands (the mass bar's death), as a share; negative: none
var band := 0.0  ## the muted band behind the reserve bar's fill, up to this share


func show_gauge(new_kind: Kind, new_tone: Tone, new_fraction: float, new_ticks: Array[float], new_mark: float, new_band: float) -> void:
	kind = new_kind
	tone = new_tone
	fraction = clampf(new_fraction, 0.0, 1.0)
	ticks = new_ticks
	mark = new_mark
	band = new_band
	queue_redraw()


func _fill_color() -> Color:
	match tone:
		Tone.LIMITED:
			return get_theme_color("limited", THEME_TYPE)
		Tone.STARVING:
			return get_theme_color("starving", THEME_TYPE)
		Tone.DEAD:
			return get_theme_color("dead", THEME_TYPE)
	return get_theme_color("fill", THEME_TYPE)


func _draw() -> void:
	var track := get_theme_color("track", THEME_TYPE)
	var tick := get_theme_color("tick", THEME_TYPE)
	if kind == Kind.MASS:
		var y := (size.y - CAPSULE_HEIGHT) * 0.5
		_capsule(Rect2(0.0, y, size.x, CAPSULE_HEIGHT), track)
		_capsule(Rect2(0.0, y, maxf(size.x * fraction, CAPSULE_HEIGHT), CAPSULE_HEIGHT), _fill_color())
		if tone != Tone.DEAD:
			for share in ticks:
				draw_rect(Rect2(size.x * share - TICK_WIDTH * 0.5, y - TICK_OVERHANG, TICK_WIDTH, CAPSULE_HEIGHT + 2.0 * TICK_OVERHANG), tick)
			if mark >= 0.0:
				draw_rect(Rect2(size.x * mark - TICK_WIDTH * 0.5, y - TICK_OVERHANG, TICK_WIDTH, CAPSULE_HEIGHT + 2.0 * TICK_OVERHANG), get_theme_color("starving", THEME_TYPE))
	else:
		var y := (size.y - BAR_HEIGHT) * 0.5
		draw_rect(Rect2(0.0, y, size.x, BAR_HEIGHT), track)
		draw_rect(Rect2(0.0, y, size.x * band, BAR_HEIGHT), get_theme_color("band", THEME_TYPE))
		draw_rect(Rect2(0.0, y, size.x * fraction, BAR_HEIGHT), _fill_color())
		for share in ticks:
			draw_rect(Rect2(size.x * share - TICK_WIDTH * 0.5, y - TICK_OVERHANG, TICK_WIDTH, BAR_HEIGHT + 2.0 * TICK_OVERHANG), tick)


## A rod with round ends.
func _capsule(rect: Rect2, color: Color) -> void:
	var radius := rect.size.y * 0.5
	draw_circle(Vector2(rect.position.x + radius, rect.position.y + radius), radius, color)
	draw_circle(Vector2(rect.end.x - radius, rect.position.y + radius), radius, color)
	draw_rect(Rect2(rect.position.x + radius, rect.position.y, maxf(rect.size.x - 2.0 * radius, 0.0), rect.size.y), color)
