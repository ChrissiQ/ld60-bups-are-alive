class_name Genome
extends RefCounted
## Heritable traits of one bup, as a plain dictionary (speed, sense, metabolism, size, hue, harm,
## mutations). Inherited clonally (no recombination) with mutation. The mutation itself runs in the
## native simulation (native/src/bup_sim.cpp); this file holds the numbers it uses and the helpers
## that make, show, save and load genomes.
##
## Mutation follows the shape of real distributions of fitness effects (Eyre-Walker & Keightley
## 2007): most mutations that matter are harmful, with many of small effect and a few lethal;
## helpful ones are rare. Harmful ones add to `harm`, which only a rare compensatory mutation
## can reduce. With no recombination to rebuild the least-harmed class, harm accumulates in
## small populations once that class is lost by chance (Muller's ratchet).
##
## RATES ARE RAISED. A real E. coli makes about 1-3 x 10^-3 mutations per genome per division
## (Drake 1991; Lee et al. 2012; from memory, unchecked here), so the rates below are about a
## hundred and thirty times higher (they were four hundred times higher before MUTATION_SUPPLY, below, cut them to a third). The reason: a real culture has ~10^8 cells and a dish here has at most
## 300, so the supply of new mutations per generation (population x rate) would be nearly nil.
## Raising the rate keeps that supply near what a real culture sees, and selection and clonal
## interference work in a comparable regime; drift is much stronger than in life (a mutation's
## chance of fixing by luck is 1/N). The shape of the spectrum is realistic. Mutations happen at
## division, so how many arrive per second of simulation time depends on how often bups divide;
## playing at x3 or x8 multiplies the divisions, and so the mutations, per second you wait.

const GENES := {
	# name: [min, max, mutation step (stddev)]
	"speed": [5.0, 40.0, 1.8],  # µm/s; E. coli swims about 20 in liquid
	"sense": [10.0, 150.0, 8.0],
	"metabolism": [0.4, 2.0, 0.08],
	"size": [2.0, 8.0, 0.35],
}

const MAX_HARM := 5.0
# A bup's colour is a neutral marker, not a trait selection acts on. Every mutation nudges it a little (hue
# round the colour wheel, saturation and brightness within what shows against the dark dish), so lineages
# drift apart in colour, slowly: a line has about 15 mutations by 72 hours, 120-190 by 400 hours and 500-800 by 3,000
# (measured in long runs), and each step is small, so a clade keeps its founder's colour recognisably for hundreds of
# hours: at 0.01 the hue has spread about +-14 degrees by 72 hours, +-50 by 400 and +-90 by 3,000, and the colour stays
# saturated and bright (at the earlier 0.05 and 0.02 steps every hue was everywhere, and washed to off-white, within a
# few hundred hours).
const HUE_STEP := 0.01  ## per mutation, as a fraction of the colour wheel (3.6 degrees)
const SAT_STEP := 0.005
const VAL_STEP := 0.005
const VAL_MIN := 0.25  ## brightness never drifts below this
const RANDOM_VAL_MIN := 0.3  ## nor is a random colour picked darker than this
const RANDOM_SAT_POWER := 0.7  ## 1 is an even spread; lower leans towards vivid (about 59% saturated on average, and greys at a third of an even spread's rate)
const RANDOM_VAL_POWER := 0.85  ## the same for brightness, less strongly

# Expected mutations per division (Poisson), each of its own kind, for a bup with the usual mutation rate (a mutator makes daughters with
# its rate times these, see below).
const MUTATION_SUPPLY := 1.0 / 3.0  ## the share of the earlier base rates that is kept (1, 0.2 and 0.004), so that the strong mutator alleles below stay survivable at the real folds: a 150-fold mutator makes about 10 harmful mutations a division at this supply, and 30 at the old one, where most daughters die (the user chose to lower the base rate rather than scale the mutators; ordinary evolution is slower by the same factor)
const TRAIT_MUTATIONS := 1.0 * MUTATION_SUPPLY  ## change one trait by a random amount; helpful or harmful depending on the dish
const HARMFUL_MUTATIONS := 0.2 * MUTATION_SUPPLY  ## damage elsewhere in the genome, adding to `harm`
const COMPENSATORY_MUTATIONS := 0.004 * MUTATION_SUPPLY  ## the rare helpful ones: they repair some harm
const LETHAL_FRACTION := 0.05  ## share of harmful mutations that kill the daughter outright
const HARM_SHAPE := 0.3  ## gamma shape below 1: mostly tiny effects, a long tail of big ones
const MEAN_HARM := 0.03  ## average cost of a harmful mutation, as a fraction of food yield
const MEAN_REPAIR := 0.02

# Mutators. A bup carries `mutator`: how many times the usual rate it makes its daughters at (1 for the usual). It changes in jumps, as the
# loss of a repair gene does in life (the folds are measured: mutY about 11x, mutS and mutL about 100-290x, mutT about 156x; Foster et al.
# 2015, Lee et al. 2012, Wielgoss et al. 2013), and an antimutator mutation halves it again (Wielgoss et al. 2013: mutY antimutators cut a
# mutT mutator's rate by 40-60%). The cost comes with the rate: more harmful mutations, more load, no extra penalty; and no direct benefit,
# the mutator spreads only by hitchhiking on the helpful mutations it makes in the same asexual genome (Sniegowski et al. 1997).
const MUTATOR_FOLD_WEAK := 10.0  ## a mutY-like allele (a fifth of the new alleles)
const MUTATOR_FOLD_STRONG := 100.0  ## a mutS- or mutL-like allele, the commonest (three fifths)
const MUTATOR_FOLD_TOP := 150.0  ## a mutT-like allele (a fifth)
## A new mutator allele per division: in life 5e-6 per cell per generation (Boe et al. 2000), when a genome mutates 0.003 times a
## generation (Drake 1991; Lee et al. 2012): the same ratio to this dish's rate.
const MUTATOR_RATE := 5.0e-6 * (TRAIT_MUTATIONS + HARMFUL_MUTATIONS) / 0.003
const MUTATOR_DOWN_SHARE := 0.3  ## antimutator mutations in a mutator, as a share of the mutator rate [choice: no measured ratio; Wielgoss et al. saw two in the time one mutator arose]

# Conjugation: a donor is a bup with the F factor integrated in its chromosome (an Hfr cell). It passes a run of its genes to a bup that is not a
# donor and that it touches (see BupSim.conjugate). Only the facts below are sourced; the rest are choices, marked as such.
const DONOR_COST := 0.09  ## the share of its growth a donor gives up: carrying a conjugative plasmid costs about 9% (Vogwill & MacLean 2015)
const CONTACT_UM := 1.0  ## how close the bodies must be, in µm: conjugation happens between cells in tight contact, and the F pilus is about 1 µm long (Goldlust et al. 2023)
const CONJ_CONTINUE := 0.5  ## the chance that a transfer goes on to the next gene of the run (speed, sense, metabolism, size, from a fixed origin) [choice: the genes' places on the chromosome are not real, and so is this; in life transfer is sequential and breaks off at random, so the first genes move most]
const DONOR_GAIN := 1.0e-4  ## the chance, per division, that a daughter's chromosome takes up the F factor [choice: no measured rate for the integration]
const DONOR_LOSS := 1.0e-3  ## the chance that a donor's daughter loses it [choice]
## How fast a touching donor and recipient transfer, per second. Real conjugation completes in minutes (a plasmid-sized piece in about 3 minutes at 620
## nucleotides a second; Couturier et al. 2023); 0.1 a second is about eighteen times faster, so that a touch of a few seconds, which is all that swimming
## bups have, can transfer [choice: scaled for playability]. It is not what limits the number of transfers: how often a donor touches a bup is (measured
## in scenario D, tools/gpu/game_dynamics.gd: with about 0.1% of the bups donors, one transfer per 480 divisions at 0.1, only 1.4 times as many at 0.6).
## In life chromosomal genes move at about 1e-4 per cell per generation (Cooper 2007), 3% of the mutation rate; here it is about 0.5% of it.
const CONJ_RATE := 0.1

# Raised ceilings. Real adaptation has no hard ceiling: gains slow but go on for tens of thousands of generations (Wiser et al. 2013, Good et al. 2017),
# and a single regulatory mutation can move a trait well past where it was: one in clpX raised the run speed of E. coli from 18.7 to 28.7 µm/s (Fraebel et al.
# 2017); an insertion upstream of flhD made swarming seven times faster (Barker et al. 2004); cells grew to 1.5, 1.7 and 2.6 times their ancestors' volume in 2,000,
# 10,000 and 50,000 generations, the gains shrinking each time (Grant et al. 2021). So a rare mutation raises one gene's upper bound for its line, up to three times,
# by a smaller factor each time (larger gains have more negative epistasis: Khan et al. 2011). The sizes and the rate are derived, not measured: see below.
const REACH_FACTOR_1 := 1.25  ## the first raise: the gene's bound times this [choice: below the +50% that Fraebel's strains reached with several mutations]
const REACH_FACTOR_2 := 1.40  ## the second [choice]
const REACH_FACTOR_3 := 1.50  ## the third
const REACH_COST := 0.05  ## the share of its growth a bup gives up for each raise [Fraebel et al. 2017: about 10% less growth for about 50% more speed; motility costs several percent of protein and energy, in proportion to expression (Ni et al. 2020)], on top of what the larger trait already costs in upkeep
## A raise per division: beneficial mutations arise at about 1e-5 per genome per generation with an exponential spread of effects of mean 2% (Perfeito et al. 2007; Imhof
## & Schloetterer 2001), so one of 10% or more (the chance e^-5, about 0.7%) is about 7e-8 a generation; scaled as the mutator's rate is, by this dish's mutation rate over a real genome's.
const REACH_RATE := 1.0e-5 * exp(-5.0) * (TRAIT_MUTATIONS + HARMFUL_MUTATIONS) / 0.003

## How each gene is shown: its short label and decimals, so every readout agrees.
const LABELED := ["speed", "sense", "metabolism", "size", "mutator"]  ## the traits the readouts list, in order


## The raised ceilings of a bup as text: "speed +2, sense +1" ("" for none). `reach` is two bits a gene, speed the lowest.
static func reach_text(reach: int) -> String:
	var parts := []
	for i in LABELED.size() - 1:
		var level := (reach >> (2 * i)) & 3
		if level > 0:
			parts.append("%s +%d" % [label(LABELED[i]), level])
	return ", ".join(parts)


## A trait's name as the readouts show it (see text/strings.cfg).
static func label(gene: String) -> String:
	return Strings.t("genes." + gene)


const DECIMALS := {"speed": 0, "sense": 0, "metabolism": 2, "size": 1, "mutator": 1}
## Where each gene is in a bup's info (BupSim.bup_info): its body size is `size`, so the size gene is not.
const INFO_KEYS := {"speed": "speed", "sense": "sense", "metabolism": "metabolism", "size": "size_gene", "mutator": "mutator"}


static func format(gene: String, value: float) -> String:
	return String.num(value, DECIMALS[gene])


## The share of food yield a bup's accumulated harm costs it (0 to nearly 1): the same figure the simulation uses.
static func harm_share(harm: float) -> float:
	return 1.0 - exp(-harm)


## The genome of the first bups: green, no harm, no mutations yet.
static func founder() -> Dictionary:
	return {"speed": 20.0, "sense": 50.0, "metabolism": 1.0, "size": 4.0, "hue": 0.33, "sat": 0.7, "val": 1.0, "harm": 0.0, "mutations": 0, "mutator": 1.0, "donor": false, "reach": 0}


## The colour a genome shows (a colour is kept as hue, saturation and brightness).
static func color_of(genome: Dictionary) -> Color:
	return Color.from_hsv(genome["hue"], genome["sat"], genome["val"])


## The genome with this colour (any #rrggbb).
static func with_color(genome: Dictionary, color: Color) -> Dictionary:
	var out := genome.duplicate()
	out["hue"] = color.h
	out["sat"] = color.s
	out["val"] = color.v
	return out


## A random colour: any hue, any saturation (greys and muddy ones included) and any brightness except the very dark
## ones, which would vanish against the dark dish. Saturation leans towards vivid, and brightness a little towards
## bright (a power below 1 pushes a uniform draw up): muddy colours are still possible, just not most of them.
static func random_color() -> Color:
	var saturation := pow(randf(), RANDOM_SAT_POWER)
	var value := RANDOM_VAL_MIN + (1.0 - RANDOM_VAL_MIN) * pow(randf(), RANDOM_VAL_POWER)
	return Color.from_hsv(randf(), saturation, value)


## `count` colours as far apart as they can be: the same saturation and brightness (full), and hues spaced evenly
## round the wheel (two founders get opposite colours, ten get every 36 degrees). Where the first one starts on the
## wheel is random; each next founder is the next step round it.
static func spread_colors(count: int) -> Array[Color]:
	var out: Array[Color] = []
	if count <= 0:
		return out
	var start := randf()
	for k in count:
		out.append(Color.from_hsv(fposmod(start + float(k) / count, 1.0), 1.0, 1.0))
	return out


## "#rrggbb" for a colour (no opacity).
static func hex_of(color: Color) -> String:
	return "#" + color.to_html(false)


static func is_hex_color(text: Variant) -> bool:
	return text is String and text.length() == 7 and text.begins_with("#") and Color.html_is_valid(text)


## The colour for a saved "#rrggbb" (the default green if it isn't one).
static func color_from_hex(text: Variant) -> Color:
	return Color.html(text) if is_hex_color(text) else color_of(founder())


## The genome as it is stored in a save file.
static func to_saved(genome: Dictionary) -> Dictionary:
	var values := {}
	for gene in GENES:
		values[gene] = genome[gene]
	return {"values": values, "hue": genome["hue"], "sat": genome["sat"], "val": genome["val"], "mutations": genome["mutations"], "harm": genome["harm"], "mutator": genome.get("mutator", 1.0), "donor": genome.get("donor", false), "reach": genome.get("reach", 0)}


## A genome from a save file. Odd values are made safe instead of rejected: anything missing or
## not a number falls back to the founder's, and every value is kept inside its range.
static func from_saved(d: Dictionary) -> Dictionary:
	var g := founder()
	var raw: Variant = d.get("values", {})
	var saved: Dictionary = raw if raw is Dictionary else {}
	for gene in GENES:
		var v: Variant = saved.get(gene)
		if Validate.is_number(v):
			var spec: Array = GENES[gene]
			g[gene] = clampf(float(v), spec[0], spec[1])
	var hue_saved: Variant = d.get("hue")
	if Validate.is_number(hue_saved):
		g["hue"] = fposmod(float(hue_saved), 1.0)
	var sat_saved: Variant = d.get("sat")
	if Validate.is_number(sat_saved):
		g["sat"] = clampf(float(sat_saved), 0.0, 1.0)
	var val_saved: Variant = d.get("val")
	if Validate.is_number(val_saved):
		g["val"] = clampf(float(val_saved), 0.0, 1.0)
	var harm_saved: Variant = d.get("harm")
	if Validate.is_number(harm_saved):
		g["harm"] = clampf(float(harm_saved), 0.0, MAX_HARM)
	var mutations_saved: Variant = d.get("mutations")
	if Validate.is_number(mutations_saved):
		g["mutations"] = maxi(0, int(mutations_saved))
	var mutator_saved: Variant = d.get("mutator")
	if Validate.is_number(mutator_saved):
		g["mutator"] = clampf(float(mutator_saved), 1.0, MUTATOR_FOLD_TOP)
	g["donor"] = d.get("donor") is bool and d["donor"]
	var reach_saved: Variant = d.get("reach")
	if Validate.is_number(reach_saved):
		g["reach"] = clampi(int(reach_saved), 0, 255)
	return g
