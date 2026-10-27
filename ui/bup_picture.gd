class_name BupPicture
extends Control
## A small picture of a bup, in the bup's colour: the capsule it is drawn as in the dish, lying on the diagonal, with the proportions the bup has (its length against
## the usual width, Biology.WIDTH), scaled to fit inside the control's square. The length is the bup's own, worked out from the reserve it could hold (a living bup's info and
## a family record both have it: for a bup that has died it is its size when it died), with its colour (`hue`, `sat`, `val`), so a bup that can no longer be seen in the
## dish has the picture it had in life. Used by the name row, the lineage and the watch list.

const ARC_STEPS := 8
const MIN_WIDTH_PIXELS := 3.0  ## the capsule is never thinner than this on screen, so the longest, thinnest bup is still seen

var length_um: float = Biology.BIRTH_LENGTH
var color: Color = Genome.color_of(Genome.founder())


func show_info(info: Dictionary) -> void:
	var new_length := body_length(info)
	var new_color := Genome.color_of(info)
	if is_equal_approx(new_length, length_um) and new_color == color:
		return
	length_um = new_length
	color = new_color
	queue_redraw()


## How long the bup is, in µm: its reserve at the most it could hold, over what a µm of body holds (the dish draws it by its mass the same way). A record that holds no reserve (a
## living bup that is on the GPU, not looked at) has the length its size gene divides at.
static func body_length(info: Dictionary) -> float:
	var reserve := float(info.get("max_energy", 0.0))
	if reserve <= 0.0:
		return maxf(float(info.get("size_gene", Biology.BIRTH_LENGTH)), Biology.WIDTH)
	return maxf(reserve / Cell.RESERVE_PER_MASS * Cell.MASS_UM, Biology.WIDTH)


## The capsule's length and width on screen, in pixels, for the control's present size: it lies on the diagonal, as long as will fit in the square, and keeps the
## bup's proportions (a width of at least MIN_WIDTH_PIXELS). A capsule at 45 degrees takes up (length - width) / sqrt(2) + width of each side.
func shape_pixels() -> Vector2:
	var side := maxf(minf(size.x, size.y), 1.0)
	var slim := Biology.WIDTH / length_um  ## width over length
	var length := side * sqrt(2.0) / (1.0 + slim * (sqrt(2.0) - 1.0))
	var width := length * slim
	if width < MIN_WIDTH_PIXELS:
		width = minf(MIN_WIDTH_PIXELS, side)
		length = (side - width) * sqrt(2.0) + width
	return Vector2(length, width)


func _draw() -> void:
	var shape := shape_pixels()
	var half := shape.y * 0.5
	var reach := shape.x * 0.5
	draw_set_transform(size * 0.5, -PI * 0.25)  # (rising to the right)
	if reach - half < 0.5:
		draw_circle(Vector2.ZERO, half, color)  # (as wide as it is long: a rod with no straight part is a circle, and a polygon of it would have its points on top of each other)
		return
	var points := PackedVector2Array()
	for step in ARC_STEPS + 1:  # (the round end on the right, from the top down, then the left)
		points.append(Vector2(reach - half, 0.0) + Vector2.from_angle(-PI * 0.5 + PI * step / ARC_STEPS) * half)
	for step in ARC_STEPS + 1:
		points.append(Vector2(half - reach, 0.0) + Vector2.from_angle(PI * 0.5 + PI * step / ARC_STEPS) * half)
	draw_colored_polygon(points, color)
