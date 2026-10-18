class_name ColorPicking
extends RefCounted
## The game's one way to choose a colour: Godot's own colour picker button, set up small and plain. Make every
## colour button with `make_button()`, so they all look and behave alike.
##
## The picker is cut down to the colour square, the hue bar and the #rrggbb code: no opacity, no HDR intensity,
## no sliders, no presets. It also hides the screen eyedropper (a game has no use for picking colours from other
## windows), and with it the "Screen Recording permission missing!" link macOS gives the picker whenever the app
## hasn't been allowed to record the screen.


static func make_button() -> ColorPickerButton:
	var button := ColorPickerButton.new()
	button.edit_alpha = false  # a colour is #rrggbb, with no opacity
	button.custom_minimum_size = Vector2(84.0, 30.0)
	var chooser := button.get_picker()
	chooser.edit_intensity = false
	chooser.sliders_visible = false
	chooser.color_modes_visible = false
	chooser.presets_visible = false
	chooser.can_add_swatches = false
	_hide_screen_picking(chooser, button.get_popup())
	button.ready.connect(_scan.bind(chooser, button.get_popup()))  # (the picker builds its parts as it joins the tree)
	return button


## The eyedropper and the permission message are made by the picker itself, and it may add or show them again
## whenever it is opened, so the picker is searched each time it opens, and what is found is kept hidden for good.
static func _hide_screen_picking(chooser: ColorPicker, popup: Window) -> void:
	_scan(chooser, popup)
	popup.about_to_popup.connect(_scan.bind(chooser, popup))
	popup.visibility_changed.connect(func() -> void: _scan.call_deferred(chooser, popup))


static func _scan(chooser: ColorPicker, popup: Window) -> void:
	for node in chooser.find_children("*", "", true, false):
		var is_eyedropper: bool = node is Button and not (node is MenuButton) and (node.tooltip_text.begins_with("Pick a color") or node.tooltip_text.contains("Screen Recording"))
		if (is_eyedropper or node is LinkButton) and not node.has_meta("kept_hidden"):
			node.set_meta("kept_hidden", true)
			_keep_hidden(node, popup)
		elif node.has_meta("kept_hidden"):
			node.hide()


static func _keep_hidden(node: Control, popup: Window) -> void:
	node.hide()
	node.visibility_changed.connect(func() -> void:
		if node.visible:
			node.hide()  # (at once: the picker has only just shown it)
			popup.size = Vector2i.ZERO)  # and the window shrinks back to what is left
