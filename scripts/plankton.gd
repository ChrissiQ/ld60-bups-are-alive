class_name Plankton
extends RefCounted
## A plankton cell: it does nothing but float, and at some point it bursts and its contents become nutrient in
## the medium (the way phytoplankton lyse, leaving a short-lived cloud of food that bacteria can swim to).

var pos: Vector2  ## relative to the dish centre, like the bups
var born_at: float  ## simulation time (s) at which it appeared
var burst_at: float  ## simulation time (s) at which it bursts (the player is not told)
var units: float  ## nutrient released when it does
var shape: float  ## makes each one's outline a little different
var outline: PackedVector2Array  ## that outline for a radius of 1, closed (the last point repeats the first): one of OUTLINES, the nearest to its shape

const VARIANTS := 32  ## how many different outlines there are (the shape is rounded to one of them: they are too alike to tell apart, and thousands of plankton share them rather than each building its own)
static var OUTLINES: Array[PackedVector2Array] = _make_outlines()


func _init(p_pos: Vector2, p_born_at: float, p_burst_at: float, p_units: float, p_shape: float) -> void:
	pos = p_pos
	born_at = p_born_at
	burst_at = p_burst_at
	units = p_units
	shape = p_shape
	outline = OUTLINES[int(fposmod(shape, TAU) / TAU * VARIANTS) % VARIANTS]


static func _make_outlines() -> Array[PackedVector2Array]:
	var made: Array[PackedVector2Array] = []
	for variant in VARIANTS:
		var phase := TAU * (variant + 0.5) / VARIANTS
		var line := PackedVector2Array()
		for k in 17:
			var a := TAU * k / 16.0
			var wobble := 1.0 + 0.16 * sin(2.0 * a + phase) + 0.1 * sin(3.0 * a + 2.0 * phase)
			line.append(Vector2.from_angle(a) * wobble)
		made.append(line)
	return made
