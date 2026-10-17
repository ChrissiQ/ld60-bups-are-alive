class_name Genome
extends RefCounted
## Heritable traits of one cell. Inherited clonally with mutation.

const GENES := {
	# name: [min, max, mutation step (stddev)]
	"speed": [10.0, 120.0, 6.0],
	"sense": [10.0, 150.0, 8.0],
	"metabolism": [0.4, 2.0, 0.08],
	"size": [2.0, 8.0, 0.35],
}

const MUTATION_RATE := 0.5  ## chance per gene per division

var values := {}
var hue := 0.33  ## lineage colour, drifts slowly with mutations
var mutations := 0  ## total mutations along this lineage


## How each gene is shown: its short label and decimals, so every readout agrees.
const LABELS := {"speed": "speed", "sense": "sense", "metabolism": "metab", "size": "size"}
const DECIMALS := {"speed": 0, "sense": 0, "metabolism": 2, "size": 1}


static func format(gene: String, value: float) -> String:
	return String.num(value, DECIMALS[gene])


static func founder() -> Genome:
	var g := Genome.new()
	g.values = {"speed": 40.0, "sense": 50.0, "metabolism": 1.0, "size": 4.0}
	return g


func get_gene(name: String) -> float:
	return values[name]


func to_dict() -> Dictionary:
	return {"values": values.duplicate(), "hue": hue, "mutations": mutations}


static func from_dict(d: Dictionary) -> Genome:
	var g := founder()
	var raw: Variant = d.get("values", {})
	var saved: Dictionary = raw if raw is Dictionary else {}
	for name in GENES:
		var v: Variant = saved.get(name)
		if Validate.is_number(v):
			var spec: Array = GENES[name]
			g.values[name] = clampf(float(v), spec[0], spec[1])
	var hue_saved: Variant = d.get("hue")
	if Validate.is_number(hue_saved):
		g.hue = fposmod(float(hue_saved), 1.0)
	var mutations_saved: Variant = d.get("mutations")
	if Validate.is_number(mutations_saved):
		g.mutations = maxi(0, int(mutations_saved))
	return g


func clone_mutated(rng: RandomNumberGenerator) -> Genome:
	var g := Genome.new()
	g.hue = hue
	g.mutations = mutations
	for name in GENES:
		var spec: Array = GENES[name]
		var v: float = values[name]
		if rng.randf() < MUTATION_RATE:
			v = clampf(v + rng.randfn(0.0, spec[2]), spec[0], spec[1])
			g.mutations += 1  # counted to visualise Muller's ratchet
			g.hue = fposmod(g.hue + rng.randfn(0.0, 0.01), 1.0)
		g.values[name] = v
	return g
