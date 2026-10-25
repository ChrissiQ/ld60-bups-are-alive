class_name HistoryGraph
extends Control
## Oscilloscope-style plot of a dish's history: population (left axis, amber) and one trait
## (right axis, green) against time (bottom axis), over a scrolling window. The window is the last 24 hours, 72 hours or
## week, or the whole run: four modes, which the G key goes through. Until G is pressed the graph moves up a mode by
## itself, as the run reaches AUTO_BUMP times the window of the mode it is in (24 hours, then 72, then a week, then all).
## Colours and text sizes come from the theme type "HistoryGraph" (see scenes/menu_theme.tres),
## like any other widget; nothing about its look is decided here.

const TRAITS := ["speed", "sense", "metabolism", "size", "harm", "mutator", "donor"]  ## harm is the average % of food yield lost to mutation; mutator the average mutation rate as a multiple of the usual
const MUTATOR_STEPS := [2.0, 5.0, 20.0, 150.0]  ## the mutator axis (from 1, the usual rate) tops out at the first of these that holds the data
const HARM_STEPS := [10.0, 20.0, 50.0, 100.0]  ## the harm axis tops out at the first of these that holds the data (mean harm can reach about 99%)
const THEME_TYPE := "HistoryGraph"
const AXIS_ALPHA := 0.7  ## axis lines and ticks are the series colour, a little softer

const MARGIN_LEFT := 40.0  ## room for the population tick labels
const MARGIN_RIGHT := 40.0  ## room for the trait tick labels
const MARGIN_TOP := 28.0  ## legend
const MARGIN_BOTTOM := 20.0  ## time tick labels
const WEEK := 7.0 * 86400.0
const MIN_ALL_WINDOW := 3600.0  ## the whole-run view is never narrower than this
enum Span { LAST_24, LAST_72, LAST_WEEK, ALL }  ## what the window shows (the G key goes through them in this order)
const AUTO_BUMP := 1.0  ## until G is pressed, the graph moves to the next mode once the run is this many times as long as the mode's window (1: when the graph is full)
const SPAN_SECONDS := {Span.LAST_24: 24.0 * 3600.0, Span.LAST_72: 72.0 * 3600.0, Span.LAST_WEEK: 168.0 * 3600.0}
const SPAN_LEGENDS := {Span.LAST_24: "graph.time_24", Span.LAST_72: "graph.time_72", Span.LAST_WEEK: "graph.time_week", Span.ALL: "graph.time_all"}
const TICK_HOURS := [1.0, 2.0, 4.0, 6.0, 12.0, 24.0, 48.0, 96.0, 168.0, 336.0, 720.0, 1440.0, 4320.0, 8760.0, 17520.0, 43800.0, 87600.0]  ## the gaps the time ticks can have, in hours
const POP_STEPS := [10.0, 20.0, 25.0, 50.0, 100.0, 150.0, 200.0, 300.0, 500.0]
const BIG_STEPS := [1.0, 1.2, 1.6, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]  ## the leading digits of the axis maximums past POP_STEPS

var dish: Dish
var trait_index := 1
var span := Span.LAST_24  ## the mode the player has chosen with G (it counts once `chosen`)
var chosen := false  ## whether G has been pressed: until then the graph moves up a mode by itself (see `shown_span`)
var _drawn_key := []  ## what the graph was last drawn from (see `refresh`)
var _drawn_msec := 0  ## when it was


## Redraws only when something it shows has changed: the history gains a sample every couple of minutes of
## simulation time, so at normal speed most frames have nothing new to draw. At top speed a sample arrives
## every frame, so a new sample alone waits for the next redraw tenth of a second.
func refresh() -> void:
	var key := [dish.history_version if dish != null else -1, trait_index, shown_span(), size]
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


## The mode being shown: the one chosen with G, or until it is pressed the one the run has grown into.
func shown_span() -> Span:
	return span if chosen else auto_span(dish.time if dish != null else 0.0)


## The mode a run of this length is in when G has not been pressed: each moves to the next once the run is AUTO_BUMP times
## as long as its window; the whole-run mode is last.
static func auto_span(sim_time: float) -> Span:
	for mode: Span in [Span.LAST_24, Span.LAST_72, Span.LAST_WEEK]:
		if sim_time < SPAN_SECONDS[mode] * AUTO_BUMP:
			return mode
	return Span.ALL


## G: the next mode after the one shown, and from now on the player's choice.
func cycle_span() -> void:
	span = ((shown_span() + 1) % Span.size()) as Span
	chosen = true


## The top of the harm axis: the smallest of HARM_STEPS that holds every sample, so low harm is not squashed
## flat and high harm is not cut off.
static func mutator_axis_max(samples: Array) -> float:
	var peak := 0.0
	for v in samples:
		peak = maxf(peak, v)
	for step in MUTATOR_STEPS:
		if peak <= step:
			return step
	return MUTATOR_STEPS[-1]


static func harm_axis_max(samples: Array) -> float:
	var peak := 0.0
	for v in samples:
		peak = maxf(peak, v)
	for step in HARM_STEPS:
		if peak <= step:
			return step
	return HARM_STEPS[-1]


## The smallest "round" axis maximum at or above `value`, so the scale doesn't jitter. Beyond the table it is one of
## BIG_STEPS times a power of ten, each of which halves to a round number too (the axis has a tick at its middle).
static func nice_ceil(value: float) -> float:
	for step in POP_STEPS:
		if value <= step:
			return step
	var magnitude := pow(10.0, floorf(log(value) / log(10.0)))
	for step in BIG_STEPS:
		if value <= step * magnitude * 1.000001:
			return step * magnitude
	return 10.0 * magnitude


## The time on a tick: hours, or days (a day a tick or more apart, so whole days; see `ticks_in_days`).
static func format_time(seconds: float, days := false) -> String:
	if days:
		return UiText.thousands(int(roundf(seconds / 86400.0))) + "d"
	return UiText.thousands(int(seconds / 3600.0)) + "h"


## Whether the time axis counts days: when the window is wider than a week, and for the whole run once it is a couple of days.
static func ticks_in_days(mode: Span, window: float) -> bool:
	return window > WEEK or (mode == Span.ALL and window >= 2.0 * 86400.0)


## Times (seconds) of the ticks that fall inside [x_min, x_max], on multiples of `step`.
static func time_ticks(x_min: float, x_max: float, step: float) -> Array:
	var out := []
	var t := ceilf(x_min / step) * step
	while t <= x_max + 0.001:
		out.append(t)
		t += step
	return out


## How many seconds the graph spans in a mode: the hours it names, or the whole run so far (and at least MIN_ALL_WINDOW).
static func span_seconds(mode: Span, sim_time: float) -> float:
	if mode == Span.ALL:
		return maxf(MIN_ALL_WINDOW, last_sample_time(sim_time))
	return SPAN_SECONDS[mode]


## The gap between time ticks: the smallest of TICK_HOURS (from `min_hours` up) with room for its labels (at most six or
## so across).
static func tick_step(window: float, min_hours := 1.0) -> float:
	for hours: float in TICK_HOURS:
		if hours >= min_hours and window / (hours * 3600.0) <= 6.0:
			return hours * 3600.0
	return TICK_HOURS[-1] * 3600.0


## The time of the newest sample.
static func last_sample_time(sim_time: float) -> float:
	return floorf(sim_time / Dish.HISTORY_INTERVAL) * Dish.HISTORY_INTERVAL


## Seconds shown at the left edge: the window starts at zero and follows the newest sample once
## the run is longer than it (the whole-run mode always starts at zero).
static func window_start_for(mode: Span, sim_time: float) -> float:
	return maxf(0.0, last_sample_time(sim_time) - span_seconds(mode, sim_time)) if mode != Span.ALL else 0.0


## Fewer decimals for wide-ranging genes (speed 10..120), one for small ones (metabolism 0.4..2).
static func tick_text(value: float, hi: float) -> String:
	return UiText.thousands(value, 1) if hi <= 2.5 else UiText.thousands(value)


func _color(name: String) -> Color:
	return get_theme_color(name, THEME_TYPE)


## The population axis's top: the round maximum that holds the peak, but never above the dish's bup limit (the population cannot
## go higher, so the scale must not show it going there). At the limit the population line sits on the top of the plot.
static func pop_axis_max(peak: float, bup_limit: int) -> float:
	var top := nice_ceil(peak)
	return minf(top, float(bup_limit)) if bup_limit > 0 else top


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
	var mode := shown_span()
	var window := span_seconds(mode, dish.time)
	var x_min := window_start_for(mode, dish.time)
	var x_max := x_min + window
	var pops := _points("pop", x_min, mode)
	var vals := _points(trait_name, x_min, mode)
	var spec: Array = Genome.GENES.get(trait_name, [1.0, mutator_axis_max(_values(vals))] if trait_name == "mutator" else [0.0, harm_axis_max(_values(vals))])
	var lo: float = spec[0]
	var hi: float = spec[1]
	for v: float in _values(vals):  # (a gene whose ceiling was raised can pass its usual top)
		hi = maxf(hi, ceilf(v))
	var peak := 10.0
	for p in pops:
		peak = maxf(peak, p.y)
	var pop_max := pop_axis_max(peak, dish.bup_limit)
	var margin_left := maxf(MARGIN_LEFT, font.get_string_size(UiText.thousands(pop_max), HORIZONTAL_ALIGNMENT_LEFT, -1, tick_size).x + 10.0)  # (room for the widest population label)
	var plot := Rect2(margin_left, MARGIN_TOP, size.x - margin_left - MARGIN_RIGHT, size.y - MARGIN_TOP - MARGIN_BOTTOM)
	var in_days := ticks_in_days(mode, window)
	var tick := tick_step(window, 24.0 if in_days else 1.0)  # (days are whole days apart)

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
		draw_string(font, Vector2(x - 20.0, plot.end.y + 15.0), format_time(t, in_days), HORIZONTAL_ALIGNMENT_CENTER, 40.0, tick_size, muted)

	# Legend doubles as the axis titles, coloured to match the axis each belongs to.
	draw_string(font, Vector2(6.0, 16.0), Strings.t("graph.bups"), HORIZONTAL_ALIGNMENT_LEFT, -1, legend_size, population_color)
	draw_string(font, Vector2(plot.position.x, 16.0), Strings.t(SPAN_LEGENDS[mode]), HORIZONTAL_ALIGNMENT_CENTER, plot.size.x, legend_size, muted)
	draw_string(font, Vector2(0.0, 16.0), Strings.t("graph.trait", [Strings.t("genes.graph_" + trait_name)]), HORIZONTAL_ALIGNMENT_RIGHT, size.x - 6.0, legend_size, trait_color)

	_plot_line(vals, plot, lo, hi, x_min, window, trait_color)
	_plot_line(pops, plot, 0.0, pop_max, x_min, window, population_color)  # (last: at the cap the population sits on the top edge and must not be hidden by the trait)


## The samples of a series as (time, value), the ones from `x_min` on. In the whole-run view they are the whole run's (thinned: see
## Dish.history_all), each at the end of the stretch it is the mean of, with the newest sample of the fine history after them.
## Otherwise sample i was recorded at (newest sample time) - (samples after it) * interval.
func _points(name: String, x_min: float, mode: Span) -> PackedVector2Array:
	var out := PackedVector2Array()
	var last_sample := last_sample_time(dish.time)
	var fine: Array = dish.history[name]
	if mode == Span.ALL:
		var whole: Array = dish.history_all[name]
		var step := dish.history_all_factor * Dish.HISTORY_INTERVAL
		for i in whole.size():
			out.append(Vector2((i + 1) * step, whole[i]))
		if not fine.is_empty() and (out.is_empty() or last_sample > out[-1].x):
			out.append(Vector2(last_sample, fine[-1]))
		return out
	for i in fine.size():
		var t := last_sample - (fine.size() - 1 - i) * Dish.HISTORY_INTERVAL
		if t >= x_min:
			out.append(Vector2(t, fine[i]))
	return out


static func _values(points: PackedVector2Array) -> Array:
	var out := []
	for p in points:
		out.append(p.y)
	return out


func _plot_line(points: PackedVector2Array, plot: Rect2, lo: float, hi: float, x_min: float, window: float, color: Color) -> void:
	if points.size() < 2:
		return
	var pts := PackedVector2Array()
	for p in points:
		var x := plot.position.x + plot.size.x * (p.x - x_min) / window
		var v := clampf((p.y - lo) / (hi - lo), 0.0, 1.0)
		pts.append(Vector2(x, plot.end.y - plot.size.y * v))
	draw_polyline(pts, color, 1.5)
