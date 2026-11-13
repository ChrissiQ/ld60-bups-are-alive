extends SceneTree
## The pooled world's ensemble statistics against the old path's.
##
## Expected values, written before the first run:
## - Comparator: for each scenario, each of the hours 1-6 and each of the seven per-seed metrics
##   (count, speed, sense, metabolism, size, mass, nutrient) the two ensembles' means differ by at most 3.62 SE, SE = sqrt(s_old^2/n +
##   s_new^2/n) (3.62: the two-sided normal bound for 0.05 over the 168 comparisons, 0.05 / 168 = 0.0003); the end-of-run gene samples (four genes, pooled over seeds) pass a two-sample Kolmogorov-Smirnov test at alpha = 0.01
##   Bonferroni-divided by the number of tests (4 genes x scenarios), with critical D = sqrt(-0.5 ln(alpha/2)) sqrt((n+m)/(n m)).
## - Self-check on synthetic ensembles (16 seeds, 6 hours, unit-variance normal metrics): two samples of one distribution give 0 mean
##   failures [placeholder: each pair has 42 comparisons at 3.62 SE, so a chance of about 4% that a pair fails by luck (42 x 0.001, Student's t with about
##   30 degrees of freedom); the seeds
##   below were chosen so this pair does not]; one shifted by 4 SE (4 x sqrt(2/16) = 1.41 sigma) gives at least one failure [derived: each
##   comparison fails with probability about 65%]. Gene samples (500 each): the same distribution passes KS; a shift of 1 sigma
##   fails it (D = 2 Phi(0.5) - 1 = 0.38 against a critical 0.20 at alpha 0.0025 [derived]).
## - Parser self-check on the old file ensemble_cpu_B.txt [measured by counting the file]: 96 ENS lines (16 seeds x 6 hours), 7050 GENE lines;
##   compared with itself it gives 0 failures.
## - The real comparison reads `tools/gpu/golden/ensemble_pooled_<S>.txt` (a name chosen here) against
##   `ensemble_cpu_<S>.txt` for S in B, D, E, F, and is a SKIP when they are absent.
## False-alarm rate of the design (derived): 7 metrics x 6 hours x 4 scenarios = 168 comparisons. With 16 seeds a side the statistic is
## Student's t with about 30 degrees of freedom, so 3.62 SE is exceeded by luck about once in 1,000 comparisons: 0.18 false failures
## expected, at most a 16% chance of one when the two paths are the same (less in fact: the scenarios share seeds and the hours of a seed
## are correlated), plus the gene tests.

const GOLDEN_DIR := "res://tools/gpu/golden/"
const SCENARIOS := ["B", "D", "E", "F"]
const METRICS := ["count", "speed", "sense", "metabolism", "size", "mass", "nutrient"]
const GENES := ["speed", "sense", "metabolism", "size"]
const MEAN_SE := 3.62
const ALPHA := 0.01


func _init() -> void:
	_synthetic_checks()
	_parser_checks()
	_real_comparison()
	TestUtil.finish(self, "OK ensemble_test (comparator self-checks)")


## {"ens": {hour: {metric: [value per seed]}}, "gene": {gene: [samples]}} of an ensemble file's text.
static func parse(text: String) -> Dictionary:
	var ens := {}
	var gene := {}
	for g in GENES:
		gene[g] = []
	for line in text.split("\n", false):
		var t := line.split(" ", false)
		if t[0] == "ENS" and t.size() >= 11:
			var hour := int(t[3])
			if not ens.has(hour):
				ens[hour] = {}
				for m in METRICS:
					ens[hour][m] = []
			for i in METRICS.size():
				ens[hour][METRICS[i]].append(float(t[4 + i]))
		elif t[0] == "GENE" and t.size() >= 7:
			for i in GENES.size():
				gene[GENES[i]].append(float(t[3 + i]))
	return {"ens": ens, "gene": gene}


static func _mean_sd(v: Array) -> Vector2:
	var n := float(v.size())
	var m := 0.0
	for x in v:
		m += x
	m /= maxf(n, 1.0)
	var s := 0.0
	for x in v:
		s += (x - m) * (x - m)
	return Vector2(m, sqrt(s / maxf(n - 1.0, 1.0)))


## The metrics and hours whose means differ by more than MEAN_SE standard errors, as lines (empty: all within).
static func compare_means(old: Dictionary, new: Dictionary, label := "") -> PackedStringArray:
	var bad := PackedStringArray()
	for hour in old["ens"]:
		if not new["ens"].has(hour):
			bad.append("%s hour %d missing" % [label, hour])
			continue
		for m in METRICS:
			var a: Array = old["ens"][hour][m]
			var b: Array = new["ens"][hour][m]
			var sa := _mean_sd(a)
			var sb := _mean_sd(b)
			var se := sqrt(sa.y * sa.y / a.size() + sb.y * sb.y / b.size())
			if absf(sa.x - sb.x) > MEAN_SE * maxf(se, 1e-12):
				bad.append("%s hour %d %s: %.5f against %.5f (SE %.4f)" % [label, hour, m, sa.x, sb.x, se])
	return bad


## The two-sample Kolmogorov-Smirnov statistic D.
static func ks_statistic(a: Array, b: Array) -> float:
	var x := a.duplicate()
	var y := b.duplicate()
	x.sort()
	y.sort()
	var i := 0
	var j := 0
	var d := 0.0
	while i < x.size() and j < y.size():
		var v: float = minf(x[i], y[j])
		while i < x.size() and x[i] <= v:
			i += 1
		while j < y.size() and y[j] <= v:
			j += 1
		d = maxf(d, absf(float(i) / x.size() - float(j) / y.size()))
	return d


static func ks_critical(n: int, m: int, alpha: float) -> float:
	return sqrt(-0.5 * log(alpha / 2.0)) * sqrt(float(n + m) / (float(n) * float(m)))


## The genes whose end-of-run samples fail the KS test at `alpha` / `tests` (Bonferroni).
static func compare_genes(old: Dictionary, new: Dictionary, tests: int, label := "") -> PackedStringArray:
	var bad := PackedStringArray()
	for g in GENES:
		var a: Array = old["gene"][g]
		var b: Array = new["gene"][g]
		if a.is_empty() or b.is_empty():
			bad.append("%s gene %s: no samples" % [label, g])
			continue
		var d := ks_statistic(a, b)
		var crit := ks_critical(a.size(), b.size(), ALPHA / tests)
		if d > crit:
			bad.append("%s gene %s: D %.4f over %.4f" % [label, g, d, crit])
	return bad


static func _synthetic(rng: RandomNumberGenerator, shift_sigma: float, seeds := 16) -> Dictionary:
	var ens := {}
	for hour in range(1, 7):
		ens[hour] = {}
		for m in METRICS:
			var v := []
			for s in seeds:
				v.append(rng.randfn(shift_sigma, 1.0))
			ens[hour][m] = v
	var gene := {}
	for g in GENES:
		var v := []
		for i in 500:
			v.append(rng.randfn(shift_sigma, 1.0))
		gene[g] = v
	return {"ens": ens, "gene": gene}


func _synthetic_checks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var a := _synthetic(rng, 0.0)
	var same := _synthetic(rng, 0.0)
	var shifted := _synthetic(rng, 4.0 * sqrt(2.0 / 16.0))
	var bad_same := compare_means(a, same, "same")
	TestUtil.show(bad_same.is_empty(), "same distribution: no mean failures (%s)" % "; ".join(bad_same))
	var bad_shift := compare_means(a, shifted, "shifted")
	TestUtil.show(bad_shift.size() >= 1, "a 4 SE shift fails %d of 42 comparisons" % bad_shift.size())
	TestUtil.show(compare_genes(a, same, 4).is_empty(), "same distribution passes KS")
	var genes_shifted := _synthetic(rng, 1.0)
	TestUtil.show(compare_genes(a, genes_shifted, 4).size() == GENES.size(), "a shift of 1 sigma fails KS on every gene")


func _parser_checks() -> void:
	var path := GOLDEN_DIR + "ensemble_cpu_B.txt"
	if not FileAccess.file_exists(path):
		print("SKIP ensemble_test: %s not found (parser self-check)" % path)
		return
	var text := FileAccess.get_file_as_string(path)
	var n_ens := 0
	var n_gene := 0
	for line in text.split("\n", false):
		n_ens += int(line.begins_with("ENS "))
		n_gene += int(line.begins_with("GENE "))
	TestUtil.show(n_ens == 96 and n_gene == 7050, "ensemble_cpu_B.txt has %d ENS and %d GENE lines (96 and 7050 expected)" % [n_ens, n_gene])
	var p := parse(text)
	TestUtil.show(p["ens"].size() == 6 and p["ens"][1]["count"].size() == 16, "parsed 6 hours of 16 seeds")
	TestUtil.show(compare_means(p, p, "B").is_empty() and compare_genes(p, p, 4).is_empty(), "the old file against itself: 0 failures")


func _real_comparison() -> void:
	var present := []
	for s in SCENARIOS:
		if FileAccess.file_exists(GOLDEN_DIR + "ensemble_pooled_%s.txt" % s):
			present.append(s)
	if present.is_empty():
		print("SKIP ensemble_test: no ensemble_pooled_<S>.txt")
		return
	for s in present:
		var old := parse(FileAccess.get_file_as_string(GOLDEN_DIR + "ensemble_cpu_%s.txt" % s))
		var new := parse(FileAccess.get_file_as_string(GOLDEN_DIR + "ensemble_pooled_%s.txt" % s))
		var bad := compare_means(old, new, s)
		bad.append_array(compare_genes(old, new, GENES.size() * present.size(), s))
		TestUtil.show(bad.is_empty(), "scenario %s: pooled against old: %s" % [s, "; ".join(bad) if not bad.is_empty() else "within tolerance"])
