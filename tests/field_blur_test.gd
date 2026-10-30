extends SceneTree

const Blur := preload("res://scripts/field_blur.gd")
## Run: godot --headless --path . -s tests/field_blur_test.gd
## A click away from a text field takes the keyboard from it, and a click on it does not (FieldBlur).


func _init() -> void:
	_run()


func _run() -> void:
	var field := LineEdit.new()
	field.position = Vector2(10, 10)
	field.size = Vector2(100, 30)
	root.add_child(field)
	await process_frame
	field.grab_focus()
	var failures: Array[String] = []
	Blur.release_if_outside(field, Vector2(20, 20))
	if not field.has_focus():
		failures.append("a click on the field kept the focus")
	Blur.release_if_outside(field, Vector2(300, 300))
	if field.has_focus():
		failures.append("a click away from the field released the focus")
	for f in failures:
		printerr("  - ", f)
	print("FIELD BLUR TESTS OK" if failures.is_empty() else "FIELD BLUR TESTS FAILED:")
	quit(0 if failures.is_empty() else 1)
