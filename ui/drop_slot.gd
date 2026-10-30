class_name DropSlot
extends PanelContainer
## The empty place a dragged thing will land: a dotted outline with the words "Move here" (what `TraySection` leaves in the tray while one of its sections is dragged).
## Its line and dash come from the theme type `DropSlot`.


func _init() -> void:
	theme_type_variation = &"DropSlot"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.theme_type_variation = &"Note"
	label.text = Strings.t("hud.move_here")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


func _draw() -> void:
	var line := get_theme_color("line", &"DropSlot")
	var width := float(get_theme_constant("width", &"DropSlot"))
	var dash := float(get_theme_constant("dash", &"DropSlot"))
	var radius := float(get_theme_constant("radius", &"DropSlot"))
	var r := Rect2(Vector2.ZERO, size).grow(-width / 2.0)
	radius = minf(radius, minf(r.size.x, r.size.y) / 2.0)
	var path := PackedVector2Array()
	var centres := [Vector2(r.end.x - radius, r.position.y + radius), Vector2(r.end.x - radius, r.end.y - radius), Vector2(r.position.x + radius, r.end.y - radius), Vector2(r.position.x + radius, r.position.y + radius)]
	for k in 4:  # (a quarter circle round each corner, clockwise from the top right)
		for step in 9:
			path.append(centres[k] + Vector2.from_angle((k - 1) * PI / 2.0 + step * PI / 16.0) * radius)
	path.append(path[0])
	var on := true  # (dashes along the path: a dash, then a gap of the same length)
	var left := dash
	for k in path.size() - 1:
		var from := path[k]
		var to := path[k + 1]
		var length := from.distance_to(to)
		var at := 0.0
		while at < length:
			var run := minf(left, length - at)
			if on:
				draw_line(from.lerp(to, at / length), from.lerp(to, (at + run) / length), line, width)
			at += run
			left -= run
			if left <= 0.0:
				on = not on
				left = dash
