extends SceneTree
## The per-dish stats equal a recount of the dish's records.
##
## Expected values, written before the first run:
## - ST_COUNT equals the number of records exactly [derived]; the sums of the four genes, mutator, donors and key equal the sums of
##   the dump's records within 1e-5 relative [placeholder: the fold order of the stats pass is not pinned; if it is pinned the
##   comparison becomes exact].
## - the stats of a dish are the same alone and in a pool (checked on the stats words only) [derived].
## - `fraction_with_gene_at_least`, the goals' question, is a stub: it needs the question kernels. Enabled by a later change.
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
	print("SKIP stats_test: fraction_with_gene_at_least, enabled by a later change")
	TestUtil.finish(self, "OK stats_test (fraction_with_gene_at_least skipped)")
