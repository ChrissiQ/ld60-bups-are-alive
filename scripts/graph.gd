class_name HistoryGraph
extends Control
## Oscilloscope-style plot of a dish's history: population (left axis, amber) and one trait
## (right axis, green) against time (bottom axis), over a scrolling window.
## Colours and text sizes come from the theme type "HistoryGraph" (see scenes/menu_theme.tres),
## like any other widget; nothing about its look is decided here.

const TRAITS := ["speed", "sense", "metabolism", "size", "harm"]  ## harm is the average % of food yield lost to mutation
const HARM_STEPS := [10.0, 20.0, 50.0, 100.0]  ## the harm axis tops out at the first of these that holds the data (mean harm can reach about 99%)
const THEME_TYPE := "HistoryGraph"
const AXIS_ALPHA := 0.7  ## axis lines and ticks are the series colour, a little softer

const MARGIN_LEFT := 40.0  ## room for the population tick labels
const MARGIN_RIGHT := 40.0  ## room for the trait tick labels
const MARGIN_TOP := 28.0  ## legend
const MARGIN_BOTTOM := 20.0  ## time tick labels
const SHORT_WINDOW := 24.0 * 3600.0  ## the span shown at first ...
const LONG_WINDOW := Dish.HISTORY_LEN * Dish.HISTORY_INTERVAL  ## ... and, once the run is past it, the span after (72 hours)
const POP_STEPS := [10.0, 20.0, 25.0, 50.0, 100.0, 150.0, 200.0, 300.0, 500.0]

var dish: Dish
var trait_index := 1
var _drawn_key := []  ## what the graph was last drawn from (see `refresh`)
var _drawn_msec := 0  ## when it was


## Redraws only when something it shows has changed: the history gains a sample every couple of minutes of
## simulation time, so at normal speed most frames have nothing new to draw. At top speed a sample arrives
## every frame, so a new sample alone waits for the next redraw tenth of a second.
func refresh() -> void:
	var key := [dish.history_version if dish != null else -1, trait_index, size]
	if key == _drawn_key:
		return
	var now := Time.get_ticks_msec()
	if key.slice(1) == _drawn_key.slice(1) and now - _drawn_msec < Dish.HAZE_REFRESH_MSEC:
		return  # (only the history grew)
	_drawn_key = key
	_drawn_msec = now
	queue_redraw()


func cycle_trait() -> void:
	trait_index = (trait_index + 1) % TRAITS.size()


## The top of the harm axis: the smallest of HARM_STEPS that holds every sample, so low harm is not squashed
## flat and high harm is not cut off.
static func harm_axis_max(samples: Array) -> float:
	var peak := 0.0
	for v in samples:
		peak = maxf(peak, v)
	for step in HARM_STEPS:
		if peak <= step:
			return step
	return HARM_STEPS[-1]


## The smallest "round" axis maximum at or above `value`, so the scale doesn't jitter.
static func nice_ceil(value: float) -> float:
	for step in POP_STEPS:
		if value <= step:
			return step
	return ceilf(value / 100.0) * 100.0


static func format_time(seconds: float) -> String:
	return UiText.thousands(int(seconds / 3600.0)) + "h"


## Times (seconds) of the ticks that fall inside [x_min, x_max], on multiples of `step`.
static func time_ticks(x_min: float, x_max: float, step: float) -> Array:
	var out := []
	var t := ceilf(x_min / step) * step
	while t <= x_max + 0.001:
		out.append(t)
		t += step
	return out


## How many seconds the graph spans: 24 hours until the run reaches 24 hours, then 72.
static func window_seconds(sim_time: float) -> float:
	return SHORT_WINDOW if sim_time < SHORT_WINDOW else LONG_WINDOW


## The gap between time ticks: wide enough that the labels fit.
static func tick_step(window: float) -> float:
	return 4.0 * 3600.0 if window <= SHORT_WINDOW else 12.0 * 3600.0


## Seconds shown at the left edge: the window starts at zero and follows the newest sample once
## the run is longer than it.
static func window_start(sim_time: float) -> float:
	var last_sample := floorf(sim_time / Dish.HISTORY_INTERVAL) * Dish.HISTORY_INTERVAL
	return maxf(0.0, last_sample - window_seconds(sim_time))


## Fewer decimals for wide-ranging genes (speed 10..120), one for small ones (metabolism 0.4..2).
static func tick_text(value: float, hi: float) -> String:
	return UiText.thousands(value, 1) if hi <= 2.5 else UiText.thousands(value)


func _color(name: String) -> Color:
	return get_theme_color(name, THEME_TYPE)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _color("background"))
	draw_rect(Rect2(Vector2.ZERO, size), _color("border"), false, 1.0)
	if dish == null:
		return
	var font := get_theme_default_font()
	var tick_size := get_theme_font_size("tick", THEME_TYPE)
	var legend_size := get_theme_font_size("legend", THEME_TYPE)
	var population_color := _color("population")
	var trait_color := _color("trait")
	var muted := _color("muted")
	var trait_name: String = TRAITS[trait_index]
	var vals: Array = dish.history[trait_name]
	var spec: Array = Genome.GENES.get(trait_name, [0.0, harm_axis_max(vals)])
	var lo: float = spec[0]
	var hi: float = spec[1]
	var plot := Rect2(MARGIN_LEFT, MARGIN_TOP, size.x - MARGIN_LEFT - MARGIN_RIGHT, size.y - MARGIN_TOP - MARGIN_BOTTOM)

	var pops: Array = dish.history["pop"]
	var peak := 10.0
	for p in pops:
		peak = maxf(peak, p)
	var pop_max := nice_ceil(peak)
	var window := window_seconds(dish.time)
	var x_min := window_start(dish.time)
	var x_max := x_min + window
	var tick := tick_step(window)

	# Gridlines first, so the data lines sit on top.
	for k in 3:
		var y := plot.end.y - plot.size.y * k / 2.0
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), _color("grid"), 1.0)
	for t: float in time_ticks(x_min, x_max, tick):
		var x := plot.position.x + plot.size.x * (t - x_min) / window
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), _color("grid_faint"), 1.0)

	# Axes: population on the left, the trait on the right, time along the bottom.
	var population_axis := Color(population_color, AXIS_ALPHA)
	var trait_axis := Color(trait_color, AXIS_ALPHA)
	draw_line(plot.position, Vector2(plot.position.x, plot.end.y), population_axis, 1.0)
	draw_line(Vector2(plot.end.x, plot.position.y), plot.end, trait_axis, 1.0)
	draw_line(Vector2(plot.position.x, plot.end.y), plot.end, muted, 1.0)

	# Tick marks and labels.
	for k in 3:
		var frac := k / 2.0
		var y := plot.end.y - plot.size.y * frac
		var base := y + tick_size * 0.35
		draw_line(Vector2(plot.position.x - 3.0, y), Vector2(plot.position.x, y), population_axis, 1.0)
		draw_string(font, Vector2(2.0, base), UiText.thousands(pop_max * frac), HORIZONTAL_ALIGNMENT_RIGHT, plot.position.x - 7.0, tick_size, population_color)
		draw_line(Vector2(plot.end.x, y), Vector2(plot.end.x + 3.0, y), trait_axis, 1.0)
		draw_string(font, Vector2(plot.end.x + 6.0, base), tick_text(lerpf(lo, hi, frac), hi), HORIZONTAL_ALIGNMENT_LEFT, -1, tick_size, trait_color)
	for t: float in time_ticks(x_min, x_max, tick):
		var x := plot.position.x + plot.size.x * (t - x_min) / window
		draw_line(Vector2(x, plot.end.y), Vector2(x, plot.end.y + 3.0), muted, 1.0)
		draw_string(font, Vector2(x - 20.0, plot.end.y + 15.0), format_time(t), HORIZONTAL_ALIGNMENT_CENTER, 40.0, tick_size, muted)

	# Legend doubles as the axis titles, coloured to match the axis each belongs to.
	draw_string(font, Vector2(6.0, 16.0), Strings.t("graph.bups"), HORIZONTAL_ALIGNMENT_LEFT, -1, legend_size, population_color)
	draw_string(font, Vector2(plot.position.x, 16.0), Strings.t("graph.time"), HORIZONTAL_ALIGNMENT_CENTER, plot.size.x, legend_size, muted)
	draw_string(font, Vector2(0.0, 16.0), Strings.t("graph.trait", [Strings.t("genes.graph_" + trait_name)]), HORIZONTAL_ALIGNMENT_RIGHT, size.x - 6.0, legend_size, trait_color)

	_plot_line(pops, plot, 0.0, pop_max, x_min, window, population_color)
	_plot_line(vals, plot, lo, hi, x_min, window, trait_color)


## Sample i was recorded at (newest sample time) - (samples after it) * interval.
func _plot_line(series: Array, plot: Rect2, lo: float, hi: float, x_min: float, window: float, color: Color) -> void:
	if series.size() < 2:
		return
	var last_sample := floorf(dish.time / Dish.HISTORY_INTERVAL) * Dish.HISTORY_INTERVAL
	var pts := PackedVector2Array()
	for i in series.size():
		var t := last_sample - (series.size() - 1 - i) * Dish.HISTORY_INTERVAL
		var x := plot.position.x + plot.size.x * (t - x_min) / window
		var v := clampf((series[i] - lo) / (hi - lo), 0.0, 1.0)
		pts.append(Vector2(x, plot.end.y - plot.size.y * v))
	draw_polyline(pts, color, 1.5)
