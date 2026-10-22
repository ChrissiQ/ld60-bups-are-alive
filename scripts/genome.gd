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
## (Drake 1991; Lee et al. 2012; from memory, unchecked here), so the rates below are several
## hundred times higher. The reason: a real culture has ~10^8 cells and a dish here has at most
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

# Expected mutations per division (Poisson), each of its own kind.
const TRAIT_MUTATIONS := 1.0  ## change one trait by a random amount; helpful or harmful depending on the dish
const HARMFUL_MUTATIONS := 0.2  ## damage elsewhere in the genome, adding to `harm`
const COMPENSATORY_MUTATIONS := 0.004  ## the rare helpful ones: they repair some harm
const LETHAL_FRACTION := 0.05  ## share of harmful mutations that kill the daughter outright
const HARM_SHAPE := 0.3  ## gamma shape below 1: mostly tiny effects, a long tail of big ones
const MEAN_HARM := 0.03  ## average cost of a harmful mutation, as a fraction of food yield
const MEAN_REPAIR := 0.02

## How each gene is shown: its short label and decimals, so every readout agrees.
const LABELED := ["speed", "sense", "metabolism", "size"]  ## the traits the readouts list, in order


## A trait's name as the readouts show it (see text/strings.cfg).
static func label(gene: String) -> String:
	return Strings.t("genes." + gene)


const DECIMALS := {"speed": 0, "sense": 0, "metabolism": 2, "size": 1}
## Where each gene is in a bup's info (BupSim.bup_info): its body size is `size`, so the size gene is not.
const INFO_KEYS := {"speed": "speed", "sense": "sense", "metabolism": "metabolism", "size": "size_gene"}


static func format(gene: String, value: float) -> String:
	return String.num(value, DECIMALS[gene])


## The share of food yield a bup's accumulated harm costs it (0 to nearly 1): the same figure the simulation uses.
static func harm_share(harm: float) -> float:
	return 1.0 - exp(-harm)


## The genome of the first bups: green, no harm, no mutations yet.
static func founder() -> Dictionary:
	return {"speed": 20.0, "sense": 50.0, "metabolism": 1.0, "size": 4.0, "hue": 0.33, "sat": 0.7, "val": 1.0, "harm": 0.0, "mutations": 0}


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
## round the wheel (two founders get opposite colours, ten get every 36 degrees). Which colour starts where on
## the wheel, and which founder gets which, is random.
static func spread_colors(count: int) -> Array[Color]:
	var out: Array[Color] = []
	if count <= 0:
		return out
	var start := randf()
	var slots := range(count)
	slots.shuffle()
	for k in count:
		out.append(Color.from_hsv(fposmod(start + float(slots[k]) / count, 1.0), 1.0, 1.0))
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
	return {"values": values, "hue": genome["hue"], "sat": genome["sat"], "val": genome["val"], "mutations": genome["mutations"], "harm": genome["harm"]}


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
	return g
