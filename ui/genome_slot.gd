class_name GenomeSlot
extends Control
## One band of the chromosome in the map (see GenomeRibbon): the way a graphical genotype colours a chromosome, a band is the locus's own colour and its
## shade is the allele, from the dim end of the gene's range to the bright end, with the gene's symbol in it. A band that is not there (no F factor, no acetate key) is an
## empty track with its symbol faint. A click on it asks for its gene's entry in the encyclopedia.
## The first and last bands round off the chromosome's ends. Colours are the locus colour (Genome) and the theme type "GenomeSlot".

signal chosen(locus: String)  ## the band was clicked: its entry in the encyclopedia

const THEME_TYPE := "GenomeSlot"
const DIM := 0.55  ## how much of the locus colour's brightness the dim end of a gene's range keeps
const CORNER := 9.0  ## the radius of the chromosome's rounded ends
const CORNER_STEPS := 6

var locus := ""
var symbol := ""
var shade := 0.0  ## where the allele sits in the gene's range, 0 (dim) to 1 (bright)
var present := true  ## false: the band is not there (a bup without the F factor): only a faint outline of where it would be
var top := false  ## the first band: its upper corners are round
var bottom := false  ## the last: its lower corners are round


func _init() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		chosen.emit(locus)
		accept_event()


func show_allele(new_shade: float, is_present: bool) -> void:
	if is_equal_approx(shade, new_shade) and present == is_present:
		return
	shade = new_shade
	present = is_present
	queue_redraw()


func _draw() -> void:
	var color := Genome.locus_color(locus)
	var fill := get_theme_color("track", THEME_TYPE)
	if present:
		fill = Color(color.r * lerpf(DIM, 1.0, shade), color.g * lerpf(DIM, 1.0, shade), color.b * lerpf(DIM, 1.0, shade))
	draw_colored_polygon(_outline(), fill)
	var font := get_theme_font("font", THEME_TYPE)
	var font_size := get_theme_font_size("font_size", THEME_TYPE)
	var ink := get_theme_color("symbol" if present else "symbol_dim", THEME_TYPE)
	draw_string(font, Vector2(0.0, (size.y + font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5), symbol, HORIZONTAL_ALIGNMENT_CENTER, size.x, font_size, ink)  # (a band that is not there, or not kept, shows its symbol faintly: where it would be)


## The band's shape: a rectangle, its upper and/or lower corners rounded when it ends the chromosome.
func _outline() -> PackedVector2Array:
	var points := PackedVector2Array()
	var r := minf(CORNER, minf(size.x, size.y) * 0.5)
	for corner in 4:  # (clockwise from the top left)
		var center := Vector2(r if corner in [0, 3] else size.x - r, r if corner in [0, 1] else size.y - r)
		var rounded := (top and corner in [0, 1]) or (bottom and corner in [2, 3])
		if not rounded:
			points.append(Vector2(0.0 if corner in [0, 3] else size.x, 0.0 if corner in [0, 1] else size.y))
			continue
		var start := PI + corner * PI * 0.5
		for step in CORNER_STEPS + 1:
			var angle := start + PI * 0.5 * step / CORNER_STEPS
			points.append(center + Vector2.from_angle(angle) * r)
	return points
