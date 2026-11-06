class_name ViewRequest
extends RefCounted
## What the main view wants published: the dish in it, its camera (dish-local), the scale, and whether the field's
## pictures, its husks and the thumbnails are wanted this time. `steer` is the selected swimmer's speed and sense range for the steering picture.

var row := -1
var camera := Rect2()
var pixel_um := 1.0
var want_field_view := false
var want_thumbnails := false
var want_husks := false
var steer := Vector2(20.0, 50.0)  ## speed (µm/s), sense range (µm)
var haze := Vector3(0.0, 1.0, 255.0)  ## visible_above, alpha_scale, max_alpha
var steer_alpha := 255.0
var track := PackedInt64Array()  ## bups whose places the payload's publish looks up as well (the sim thread sets them: the dish's tracked ones)
