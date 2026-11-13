extends SceneTree
## Run: godot --headless --path . -s tests/dish_history_test.gd
## A dish's history from the simulation's samples (host side): the samples are the ones Governor.sample_steps marks
## (after the step that crosses each multiple of DishHistory.INTERVAL of the world's clock), with their exact times, as snapshots carry them.
##
## Expected values, written before the first run [derived from the rule and the constants: INTERVAL 120 s, LEN 5,040, ALL_LEN 1,024]:
##  - Steps of 7 s from 0, in iterations of 1 to 5 steps (cycling) up to 172 steps (1,204 s): one sample for each multiple of
##    120 s, ten in all, at 126, 245, 364, 483, 602, 721, 840, 966, 1,085 and 1,204 s (the first step end at or past each multiple: 840 is
##    one exactly); each iteration's samples handed over twice (a snapshot not yet acknowledged carries them again) add nothing.
##  - A load at 130 s (a history read back, the clock at 130): a sample for 120 s (taken at 126) is refused; from 130 in steps of
##    7 s the next sample is at 242 s (the first step end past 240), and the one after at 361 s.
##  - A thaw 600 s after the freeze (frozen at 126 s, the history padded to 726 s and read back there): 5 level samples are added
##    (the multiples of 120 s crossed: 240 to 720), each the last figures; a sample for 720 s (taken at 721) is refused; from 726 in steps of
##    7 s the next is at 845 s (past 840). The padding is the multiples crossed, not the gap over 120 s: 119 -> 241 s adds 2 (120, 240),
##    121 -> 239 s none, 239 -> 241 s one (240); with a whole-run factor of 2 (multiples of 240 s), 119 -> 241 s adds one whole-run sample
##    and 241 -> 479 s none.
##  - One sample of counts and means comes out as the series: pop the count, each gene's mean, harm, donor and key as percents
##    (x100), the mutator and the generation as they are.
##  - 6,000 samples keep the fine history at LEN (5,040) and the whole run at 750 samples of 8 each (1,024 at 1, thinned to 512 at
##    2; 512 more at 2 (2,048 in all), 512 at 4; 512 more at 4 (4,096), 512 at 8; 1,904 more at 8 are 238: 750, 750 x 8 = 6,000), whose
##    mean is the mean of all 6,000 (each is a mean of 8 equal parts) within 0.01; written and read back, the whole run keeps 750 and 8.
##  - An extinct dish: after samples with bups, samples of count 0 add a pop of 0 and keep each trait at its last value, one a
##    multiple of 120 s as before (the history's time goes on).


func _initialize() -> void:
	_sample_times()
	_after_load()
	_after_thaw()
	_series()
	_whole_run()
	_extinct()
	_gaps()
	TestUtil.finish(self, "DISH HISTORY TEST OK")


## Figures as DishState.stats has them.
static func stats(count: int, gene := 20.0) -> Dictionary:
	return {"count": count, "speed": gene, "sense": gene + 1.0, "metabolism": 1.5, "size": 2.0, "harm": 0.05, "mutations": 3.0,
		"mutator": 1.0, "donor": 0.25, "key": 0.1, "generation": 7.5}


static var repeats_taken := 0  ## samples taken from the second handing-over (none should be)


## The samples a run of `steps` steps of `delta` from `start` hands over, iteration by iteration (sizes cycling 1 to 5), each iteration's
## twice: {time, stats} as Snapshot.history carries them. Returns the times of the samples taken.
static func run(history: DishHistory, start: float, steps: int, delta: float) -> PackedFloat64Array:
	var times := PackedFloat64Array()
	var clock := start
	var done := 0
	var size := 1
	while done < steps:
		var k := mini(size, steps - done)
		var marked := Governor.sample_steps(clock, k, delta, DishHistory.INTERVAL, GpuLayout.STATS_ITER_SAMPLES)
		var samples: Array = []
		for j in marked:
			samples.append({"time": clock + (j + 1) * delta, "stats": stats(100)})
		for s: Dictionary in samples:
			if history.record(s["time"], s["stats"]):
				times.append(s["time"])
		repeats_taken += history.take(samples)
		clock += k * delta
		done += k
		size = size % 5 + 1
	return times


func _sample_times() -> void:
	var h := DishHistory.new()
	h.begin(0.0)
	var times := run(h, 0.0, 172, 7.0)
	var want := PackedFloat64Array([126.0, 245.0, 364.0, 483.0, 602.0, 721.0, 840.0, 966.0, 1085.0, 1204.0])
	var close := times.size() == want.size()
	for i in mini(times.size(), want.size()):
		close = close and absf(times[i] - want[i]) < 1e-6
	TestUtil.check(close, "steps of 7 s: one sample a multiple of 120 s, at the first step end past it (%s)" % [times])
	TestUtil.check(h.fine["pop"].size() == 10 and repeats_taken == 0, "each sample is taken once, though handed over twice (%d samples, %d again)" % [h.fine["pop"].size(), repeats_taken])


func _after_load() -> void:
	var saved := DishHistory.new()
	saved.begin(0.0)
	run(saved, 0.0, 18, 7.0)  # (to 126 s: the sample for 120 s)
	var back := DishHistory.read(saved.write())
	TestUtil.check(not back.is_empty(), "a history written reads back")
	var h := DishHistory.new()
	h.load(back, 130.0)
	TestUtil.check(not h.record(126.0, stats(100)) and h.fine["pop"].size() == 1, "after a load at 130 s a sample for 120 s is not taken again")
	var times := run(h, 130.0, 34, 7.0)  # (to 368 s)
	TestUtil.check(times.size() == 2 and absf(times[0] - 242.0) < 1e-6 and absf(times[1] - 361.0) < 1e-6, "a load at 130 s goes on at 242 s and 361 s, past 240 and 360 (%s)" % [times])


func _after_thaw() -> void:
	var frozen := DishHistory.new()
	frozen.begin(0.0)
	run(frozen, 0.0, 18, 7.0)  # (to 126 s: one sample)
	var data := frozen.write()
	DishHistory.pad(data, 126.0, 726.0)
	var h := DishHistory.new()
	h.load(DishHistory.read(data), 726.0)
	var pops: Array = h.fine["pop"]
	TestUtil.check(pops.size() == 6 and pops.all(func(v: Variant) -> bool: return v == pops[0]), "a thaw 600 s on pads the history with 5 level samples (%s)" % [pops])
	TestUtil.check(not h.record(721.0, stats(100)), "after the thaw a sample for 720 s is not taken")
	var times := run(h, 726.0, 17, 7.0)
	TestUtil.check(times.size() == 1 and absf(times[0] - 845.0) < 1e-6, "after the thaw the next sample is at 845 s, past 840 (%s)" % [times])
	for case: Array in [[119.0, 241.0, 2, 1], [121.0, 239.0, 0, 0], [239.0, 241.0, 1, 1], [241.0, 479.0, 1, 0]]:
		var saved := {"history": {"pop": [1.0]}, "history_all": {"pop": [1.0]}, "history_all_factor": 2}
		DishHistory.pad(saved, case[0], case[1])
		var added: int = saved["history"]["pop"].size() - 1
		var added_whole: int = saved["history_all"]["pop"].size() - 1
		TestUtil.check(added == case[2] and added_whole == case[3], "frozen at %s s, thawed at %s s: %d level samples and %d whole-run ones (want %d and %d: the multiples crossed)" % [case[0], case[1], added, added_whole, case[2], case[3]])


func _series() -> void:
	var h := DishHistory.new()
	h.record(120.0, stats(42))
	var got := {}
	for series: String in DishHistory.SERIES:
		got[series] = h.fine[series][-1]
	var want := {"pop": 42, "speed": 20.0, "sense": 21.0, "metabolism": 1.5, "size": 2.0, "harm": 5.0, "mutator": 1.0, "donor": 25.0, "key": 10.0, "generation": 7.5}
	var same := true
	for series: String in want:
		same = same and is_equal_approx(float(got[series]), float(want[series]))
	TestUtil.check(same and got.size() == want.size(), "a sample's series: pop, the genes, harm, donor and key in percent, the mutator and generation (%s)" % [got])


func _whole_run() -> void:
	var h := DishHistory.new()
	var samples := 6000
	var sum := 0.0
	for i in samples:
		var pop := (i * 7) % 13
		h.record((i + 1) * DishHistory.INTERVAL, stats(pop))
		sum += pop
	var n: int = h.whole["pop"].size()
	TestUtil.check(n == 750 and h.whole_factor == 8, "6,000 samples: the whole run holds 750 of 8 each (%d of %d)" % [n, h.whole_factor])
	TestUtil.check(h.fine["pop"].size() == DishHistory.LEN, "the fine history keeps its week (%d)" % h.fine["pop"].size())
	var mean := 0.0
	for v: float in h.whole["pop"]:
		mean += v
	TestUtil.check(absf(mean / n - sum / samples) < 0.01, "the whole run's samples are means, so they keep the average (%.4f, %.4f)" % [mean / n, sum / samples])
	var copy := DishHistory.new()
	copy.load(DishHistory.read(h.write()), samples * DishHistory.INTERVAL)
	TestUtil.check(copy.whole["pop"].size() == 750 and copy.whole_factor == 8, "the whole run survives being written and read")


func _extinct() -> void:
	var h := DishHistory.new()
	for k in 3:
		h.record((k + 1) * DishHistory.INTERVAL + 3.0, stats(50, 30.0 + k))
	var sense_then: float = h.fine["sense"][-1]
	for k in range(3, 6):
		h.record((k + 1) * DishHistory.INTERVAL + 3.0, stats(0, 0.0))
	TestUtil.check(h.fine["pop"].size() == 6 and h.fine["pop"][-1] == 0 and h.fine["sense"][-1] == sense_then and h.fine["speed"][-1] == 32.0, "an extinct dish: pop 0, the traits held, a sample each 120 s as before")
	TestUtil.check(is_equal_approx(h.last_time, 6.0 * DishHistory.INTERVAL + 3.0), "the history's time goes on after the dish died out (%.1f)" % h.last_time)


## A sample for a later multiple of INTERVAL than the next one has the multiples between filled in on a line.
func _gaps() -> void:
	var h := DishHistory.new()
	for k in 3:
		h.record((k + 1) * DishHistory.INTERVAL + 3.0, stats(100, 20.0))
	var n := h.take([{"time": 10.0 * DishHistory.INTERVAL + 3.0, "stats": stats(100, 30.0)}])
	TestUtil.check(n == 1 and h.fine["pop"].size() == 10, "a gap of 6 multiples is filled: 10 samples, 1 new (%d, %d)" % [h.fine["pop"].size(), n])
	TestUtil.check(is_equal_approx(h.fine["speed"][5], 20.0 + 10.0 * 3.0 / 7.0) and is_equal_approx(h.fine["speed"][9], 30.0), "...on a straight line from the last figures to the new (%.3f)" % h.fine["speed"][5])
	TestUtil.check(is_equal_approx(h.last_time, 10.0 * DishHistory.INTERVAL + 3.0), "...and the history's time is the sample's")
	var late := DishHistory.new()
	late.record(1.0 * DishHistory.INTERVAL, stats(100, 20.0))
	late.record(2.0 * DishHistory.INTERVAL, stats(100, 20.0))
	late.take([{"time": 6.0 * DishHistory.INTERVAL, "stats": stats(0, 0.0)}])
	TestUtil.check(late.fine["pop"].size() == 6 and late.fine["pop"][2] == 100 and late.fine["pop"][5] == 0 and late.fine["speed"][4] == 20.0, "a gap that ends with nobody is held level, then the sample (pop %s)" % [late.fine["pop"]])
	var timed := DishHistory.new()
	timed.record(1.0 * DishHistory.INTERVAL, stats(100, 20.0))
	var far := [{"time": 40.0 * DishHistory.INTERVAL, "stats": stats(100, 60.0)}]
	TestUtil.check(timed.take_until(far, Time.get_ticks_usec() - 1) == 0 and timed.fine["pop"].size() == 1, "take_until with its time passed goes through nothing and changes nothing")
	TestUtil.check(timed.take_until(far, Time.get_ticks_usec() + 10000000) == 1 and timed.fine["pop"].size() == 40 and is_equal_approx(timed.fine["speed"][19], 20.0 + 40.0 * 19.0 / 39.0), "...with time it takes it and fills the line (%d)" % timed.fine["pop"].size())
