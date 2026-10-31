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
##  - one sample of counts and means comes out as the series: pop the count, each gene's mean, harm, donor and key as percents
##    (x100), the mutator and the generation as they are.
##  - 6,000 samples keep the fine history at LEN (5,040) and the whole run at 750 samples of 8 each (1,024 at 1, thinned to 512 at
##    2; 512 more at 2 (2,048 in all), 512 at 4; 512 more at 4 (4,096), 512 at 8; 1,904 more at 8 are 238: 750, 750 x 8 = 6,000), whose
##    mean is the mean of all 6,000 (each is a mean of 8 equal parts) within 0.01; written and read back, the whole run keeps 750 and 8.
##  - An extinct dish: after samples with bups, samples of count 0 add a pop of 0 and keep each trait at its last value, one a
##    multiple of 120 s as before (the history's time goes on).


func _initialize() -> void:
	_sample_times()
	_after_load()
	_series()
	_whole_run()
	_extinct()
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
