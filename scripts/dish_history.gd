class_name DishHistory
extends RefCounted
## What the graph shows of one dish: the means of its population and traits, sampled on the dish's own clock. `fine` keeps the last week
## of samples; `whole` keeps the whole run in no more than ALL_LEN samples, each the mean of `whole_factor` fine ones, and when it fills
## up its neighbours are merged in pairs and the factor doubles, so a run of any length is kept, thinner the longer it gets. Sample i of
## `whole` ends at (i + 1) * whole_factor * INTERVAL. The save keeps these under its own names (`write`, `read`, `pad`).

const INTERVAL := 120.0  ## seconds between samples
const LEN := 5040  ## 168 hours (a week) of samples: the longest span of the fine history the graph shows
const ALL_LEN := 1024  ## how many samples the whole-run history holds before its neighbours are merged in pairs
const TRAITS := ["speed", "sense", "metabolism", "size", "harm", "mutator", "donor", "key", "generation"]  ## each gene's mean, mean harm (%) and the mean mutator (a multiple of the usual rate), the share of donors and of lines with the acetate key (%), and the mean generation
const SERIES := ["pop"] + TRAITS  ## every series: the population, then the traits

var fine := {}  ## series name -> samples, the oldest dropped off the front
var whole := {}
var whole_factor := 1
var version := 0  ## bumped whenever the history gains or loses a sample, so views can redraw only on change
var origin := 0.0  ## the world time this history began at (a dish that joins a running world begins at its time): the graph shows a dish's own time from here
var accum := 0.0  ## the seconds into the sample interval the clock is
var _sums := {}  ## the running sums for the next whole-run sample
var _count := 0  ## how many fine samples are in them


func _init() -> void:
	reset()


func reset() -> void:
	fine = {}
	whole = {}
	_sums = {}
	for series in SERIES:
		fine[series] = []
		whole[series] = []
		_sums[series] = 0.0
	whole_factor = 1
	_count = 0
	accum = 0.0
	origin = 0.0
	version += 1


## Moves the sampling clock on `delta`; true when a sample is due.
func tick(delta: float) -> bool:
	accum += delta
	if accum >= INTERVAL:
		accum -= INTERVAL
		return true
	return false


## One sample from these figures (BupSim.population_stats' keys).
func record(stats: Dictionary) -> void:
	fine["pop"].append(stats["count"])
	if stats["count"] == 0 and not fine["harm"].is_empty():  # (nobody left to average: the traits stay as they last were)
		for series in SERIES:
			if series != "pop":
				fine[series].append(fine[series][-1])
	else:
		for gene in Genome.GENES:
			fine[gene].append(stats[gene])
		fine["harm"].append(stats["harm"] * 100.0)
		fine["mutator"].append(stats["mutator"])
		fine["donor"].append(stats["donor"] * 100.0)
		fine["key"].append(stats["key"] * 100.0)
		fine["generation"].append(stats["generation"])
	if fine["pop"].size() > LEN:
		for series in fine.values():
			series.pop_front()
	for series in SERIES:
		_sums[series] += fine[series][-1]
	_count += 1
	if _count >= whole_factor:
		for series in SERIES:
			whole[series].append(_sums[series] / _count)
			_sums[series] = 0.0
		_count = 0
		if whole["pop"].size() >= ALL_LEN:
			_thin()
	version += 1


## Merges the whole-run history's neighbours in pairs (each the mean of two), so it holds twice the time in half the samples.
func _thin() -> void:
	for series in SERIES:
		var samples: Array = whole[series]
		var merged := []
		for i in range(0, samples.size() - 1, 2):
			merged.append((samples[i] + samples[i + 1]) * 0.5)
		whole[series] = merged
	whole_factor *= 2


## Takes a history `read` has checked, for a dish whose clock is at `time`. Samples are taken on multiples of the interval, so the clock
## resumes part-way through one.
func load(read_back: Dictionary, time: float) -> void:
	fine = read_back["fine"]
	whole = read_back["whole"]
	whole_factor = read_back["factor"]
	while whole["pop"].size() >= ALL_LEN:
		_thin()
	origin = read_back["origin"]
	accum = fposmod(time - origin, INTERVAL)


## The history's part of a dish's save.
func write() -> Dictionary:
	return {"history": fine, "history_all": whole, "history_all_factor": whole_factor, "history_origin": origin}


## The history in a save, checked and made ready for `load`: an empty dictionary if anything is unusable.
static func read(d: Dictionary) -> Dictionary:
	var saved_fine = d.get("history", {})
	if not (saved_fine is Dictionary):
		return {}
	var read_fine := {}
	for key in SERIES:
		var series = saved_fine.get(key)
		if not (series is Array) or not Validate.all_numbers(series):
			return {}
		read_fine[key] = series.slice(maxi(0, series.size() - LEN))
	var saved_whole = d.get("history_all")
	if not (saved_whole is Dictionary) or not Validate.is_number(d.get("history_all_factor")) or float(d["history_all_factor"]) < 1.0:
		return {}
	var read_whole := {}
	for key in SERIES:
		var series = saved_whole.get(key)
		if not (series is Array) or not Validate.all_numbers(series):
			return {}
		read_whole[key] = series
	return {"fine": read_fine, "whole": read_whole, "factor": int(d["history_all_factor"]), "origin": float(d["history_origin"]) if Validate.is_number(d.get("history_origin")) else 0.0}


## A save that was made `gap` seconds ago: its history goes on level for the time that has passed (the last figures it had, which is what a
## frozen dish was), so the graph's time axis stays the world's.
static func pad(data: Dictionary, gap: float) -> void:
	var saved_fine: Variant = data.get("history")
	if saved_fine is Dictionary:
		_pad_series(saved_fine, mini(int(gap / INTERVAL), LEN))
	var saved_whole: Variant = data.get("history_all")
	if saved_whole is Dictionary and Validate.is_number(data.get("history_all_factor")):
		_pad_series(saved_whole, mini(int(gap / (float(data["history_all_factor"]) * INTERVAL)), ALL_LEN))


static func _pad_series(series_by_name: Dictionary, count: int) -> void:
	for key in series_by_name:
		var series: Variant = series_by_name[key]
		if series is Array and not series.is_empty():
			var last: Variant = series[-1]
			for i in count:
				series.append(last)
