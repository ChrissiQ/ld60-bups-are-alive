extends Node
## Keeps every tooltip a few short lines (autoload "TooltipFit"): the engine's tooltip is one line however long its text, so a long one would run across the
## window. Each control gets its tooltip wrapped to UiText.TOOLTIP_WIDTH characters when the pointer reaches it, just before the tooltip is asked for, whoever set the text
## and whenever. (Tooltips are for names and icons: an explanation belongs in the encyclopedia.)


func _ready() -> void:
	get_tree().node_added.connect(_watch)
	_watch_all(get_tree().root)


func _watch_all(node: Node) -> void:
	_watch(node)
	for child in node.get_children():
		_watch_all(child)


func _watch(node: Node) -> void:
	if node is Control and not node.mouse_entered.is_connected(_fit.bind(node)):
		node.mouse_entered.connect(_fit.bind(node))


func _fit(control: Control) -> void:
	var text := control.tooltip_text
	if text.is_empty() or control.get_meta("tooltip_fitted", "") == text:
		return
	var wrapped := UiText.tooltip_lines(text)
	control.set_meta("tooltip_fitted", wrapped)
	control.tooltip_text = wrapped

