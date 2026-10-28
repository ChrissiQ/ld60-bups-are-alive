class_name GraphControls
extends VBoxContainer
## The graph's choices as controls above it, what is inside the tray's "Graph" section besides the plot: a switch for one dish or all together (only with more than one
## dish), a switch for the time span (all four in view) and a drop-down for the trait (eight). They are one choice for the graph whichever way it is made (the G and T keys
## too), so `show_choices` makes them follow it. The section itself is a plain TraySection that holds this as its content.

@onready var scope_switch: Control = %ScopeSwitch  ## one dish or all together
@onready var span_switch: Control = %SpanSwitch  ## the graph's time span: one button for each (see HistoryGraph.SPAN_LEGENDS)
@onready var trait_select: OptionButton = %TraitSelect  ## ... and the trait on its right axis

var _scope_buttons: Array[Button] = []
var _span_buttons := {}  ## HistoryGraph.Span -> its button


func setup(graph: HistoryGraph) -> void:
	var group := ButtonGroup.new()
	for mode: HistoryGraph.Span in HistoryGraph.SPAN_LEGENDS:
		var button := Button.new()
		button.theme_type_variation = &"SwitchButton"
		button.toggle_mode = true
		button.button_group = group
		button.focus_mode = Control.FOCUS_NONE  # (the keyboard has G)
		button.text = Strings.t(HistoryGraph.SPAN_LEGENDS[mode])
		button.pressed.connect(graph.set_span.bind(mode))
		span_switch.get_node("Choices").add_child(button)
		_span_buttons[mode] = button
	var scope_group := ButtonGroup.new()
	for all in [false, true]:
		var button := Button.new()
		button.theme_type_variation = &"SwitchButton"
		button.toggle_mode = true
		button.button_group = scope_group
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(graph.set_all_dishes.bind(all))
		scope_switch.get_node("Choices").add_child(button)
		_scope_buttons.append(button)
	_scope_buttons[1].text = Strings.t("graph.scope_all")
	scope_switch.tooltip_text = Strings.t("graph.scope_tip")
	for trait_name: String in HistoryGraph.TRAITS:
		trait_select.add_item(Strings.t("genes.graph_" + trait_name))
	trait_select.item_selected.connect(graph.set_trait)
	trait_select.item_selected.connect(func(_index: int) -> void: trait_select.release_focus.call_deferred())  # (a choice completes the interaction: Space goes back to the game)
	span_switch.tooltip_text = Strings.t("graph.span_tip")
	trait_select.tooltip_text = Strings.t("graph.trait_tip")


## Makes the controls show what the graph shows; `dish_count` running dishes, the one in view being number `dish_number`.
func show_choices(graph: HistoryGraph, dish_count: int, dish_number: int) -> void:
	var shown: HistoryGraph.Span = graph.shown_span()
	for mode: HistoryGraph.Span in _span_buttons:
		_span_buttons[mode].set_pressed_no_signal(mode == shown)
	scope_switch.visible = dish_count > 1
	_scope_buttons[0].text = Strings.t("graph.scope_dish", [dish_number])
	_scope_buttons[0].set_pressed_no_signal(not graph.combined())
	_scope_buttons[1].set_pressed_no_signal(graph.combined())
	if trait_select.selected != graph.trait_index:
		trait_select.select(graph.trait_index)
