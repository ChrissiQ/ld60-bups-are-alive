extends SceneTree
## The per-dish stats equal a recount of the dish's records.
##
## Expected values, written before the first run:
## - ST_COUNT equals the number of records exactly [derived]; the sums of the four genes, mutator, donors and key equal the sums of
##   the dump's records within 1e-5 relative [placeholder: the fold order of the stats pass is not pinned; if it is pinned the
##   comparison becomes exact].
## - the stats of a dish are the same alone and in a pool (checked on the stats words only) [derived].
## - `fraction_with_gene_at_least` (the goals' question, SimCore's kernel): for each gene and each of four thresholds (the
##   median record's own value, so that equal genes count; a value between two floats, 0.3 of the way from the median to the largest;
##   0, which every bup passes; past the largest, which none does) it equals the share of the dump's records whose float gene is at least
##   the threshold, exactly [derived: an integer count over the same floats, divided on the host in double].
## Needs a GPU. Windowed only.

const TOLERANCE := 1e-5  ## placeholder


func _init() -> void:
	if not SimHarness.begin(self, "stats_test", "SimCore"):
		return
	var s := Scenario.small(60, 600.0).seed(5).with_flags({"conjugation": true, "key": true})
	var h := SimHarness.make([s.copy(), Scenario.small(40, 400.0).seed(6)]).step(200)
	var d := h.dump(0)
	var recs: PackedByteArray = d["records"]
	var stats: PackedByteArray = d["stats"]
	var n := recs.size() / GpuLayout.RECORD_BYTES
	TestUtil.show(int(stats.decode_float(GpuLayout.ST_COUNT * 4)) == n, "ST_COUNT %d equals %d records" % [int(stats.decode_float(GpuLayout.ST_COUNT * 4)), n])
	for g in GpuLayout.GENE_NAMES.size():
		var sum := 0.0
		for i in n:
			sum += recs.decode_float(i * GpuLayout.RECORD_BYTES + (GpuLayout.R_SPEED + g) * 4)
		var got := stats.decode_float((GpuLayout.ST_SPEED + g) * 4)
		TestUtil.show(absf(got - sum) <= TOLERANCE * maxf(absf(sum), 1.0), "sum of %s: stats %.4f, recount %.4f" % [GpuLayout.GENE_NAMES[g], got, sum])
	var donors := 0
	for i in n:
		donors += int(recs.decode_float(i * GpuLayout.RECORD_BYTES + GpuLayout.R_DONOR * 4) > 0.5)
	TestUtil.show(stats.decode_u32(GpuLayout.ST_DONORS * 4) == donors, "ST_DONORS %d equals %d" % [stats.decode_u32(GpuLayout.ST_DONORS * 4), donors])
	var lone := SimHarness.make([s.copy()]).step(200).dump(0)
	TestUtil.show(lone["stats"] == stats, "stats are the same alone and in a pool")
	_fractions(h, recs, n)
	TestUtil.finish(self, "OK stats_test")


func _fractions(h: SimHarness, recs: PackedByteArray, n: int) -> void:
	for g in GpuLayout.GENE_NAMES.size():
		var values := PackedFloat64Array()
		for i in n:
			values.append(recs.decode_float(i * GpuLayout.RECORD_BYTES + (GpuLayout.R_SPEED + g) * 4))
		var sorted := values.duplicate()
		sorted.sort()
		var median := sorted[n / 2]
		for thr: float in [median, median + 0.3 * (sorted[n - 1] - median) + 1e-9, 0.0, sorted[n - 1] * 1.5 + 1.0]:
			var at_least := 0
			for v: float in values:
				at_least += 1 if v >= thr else 0
			var want := float(at_least) / n
			var got: float = h.core.fraction_with_gene_at_least(0, GpuLayout.GENE_NAMES[g], thr)
			TestUtil.show(got == want, "fraction of %s at least %.9f: %.9f, recount %.9f (%d of %d)" % [GpuLayout.GENE_NAMES[g], thr, got, want, at_least, n])
