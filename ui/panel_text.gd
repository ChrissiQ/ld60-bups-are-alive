class_name PanelText
extends RefCounted
## The words of the inspector's panels and the hover card, worked out from what a dish says about a thing
## (the detail dictionaries of Dish.source_details, plankton_details, husk_details, nutrient_at, bup_info).


static func plankton(d: Dictionary) -> String:
	var offset: Vector2 = d["offset"]
	var nearest: float = d["nearest_bup"]
	return Strings.t("panel.plankton", [
		SimClock.format_minutes(int(d["age"] / 60.0)), d["units"], offset.x, offset.y, d["distance"], concentration(d["concentration"]),
		away(nearest),
	])


static func husk(d: Dictionary) -> String:
	var offset: Vector2 = d["offset"]
	var nearest: float = d["nearest_bup"]
	return Strings.t("panel.husk", [
		SimClock.format_minutes(int(d["age"] / 60.0)), d["units"], d["left"] * 100.0, offset.x, offset.y, d["distance"], concentration(d["concentration"]),
		away(nearest),
	])


static func source(d: Dictionary) -> String:
	var offset: Vector2 = d["offset"]
	var nearest: float = d["nearest_bup"]
	return Strings.t("panel.source", [
		d["emitted"], offset.x, offset.y, d["distance"], concentration(d["concentration"]),
		away(nearest),
		Dish.SOURCE_NEARBY, d["nearby"],
	])


## A concentration in the unit the player works in: units of nutrient per square millimetre (the unit of a dose, a feed
## and a source), not the simulation's energy per square micrometre, which is far too small to read.
static func concentration(energy_per_um2: float) -> String:
	var units := energy_per_um2 * 1.0e6 / Dish.NUTRIENT_ENERGY
	return Strings.t("panel.concentration", [("%.1f" if units < 10.0 else "%.0f") % units])


## The medium at a spot: how much nutrient, which way it rises and how steeply (as a share of
## what is there, per 100 units), and what is near.
static func point(d: Dictionary) -> String:
	var offset: Vector2 = d["offset"]
	var amount: float = d["concentration"]
	var gradient: Vector2 = d["gradient"]
	var change := gradient.length() / maxf(amount, 1e-6) * 100.0  # the fraction it changes by over 100 units
	var slope := Strings.t("panel.gradient_flat")
	if amount > 0.0005 and change >= 0.02:
		var compass := ["e", "se", "s", "sw", "w", "nw", "n", "ne"]  # the screen's y axis points down
		slope = Strings.t("panel.gradient_rising", [Strings.t("panel.compass_" + compass[posmod(roundi(gradient.angle() / (TAU / 8.0)), 8)]), change * 100.0])
	var nearest_source: float = d["nearest_source"]
	var nearest_bup: float = d["nearest_bup"]
	return Strings.t("panel.nutrient", [
		concentration(amount), slope, offset.x, offset.y, d["distance"],
		away(nearest_source),
		away(nearest_bup),
	])


## How surely a bup goes up the slope where it is (the chance that it ends up further up after a minute of swimming), in a word.
static func steering_word(chance: float) -> String:
	if chance < 0.55:
		return Strings.t("panel.steering_blind")
	if chance < 0.7:
		return Strings.t("panel.steering_faint")
	return Strings.t("panel.steering_clear") if chance < 0.9 else Strings.t("panel.steering_sure")


## How far away something is, for the panels: "none" when there is nothing of that kind in the dish.
static func away(distance: float) -> String:
	return Strings.t("panel.away", [distance]) if distance >= 0.0 else Strings.t("panel.none")


## A living bup's lines; `dish_number` is the dish it is in now.
static func bup(b: Dictionary, dish_number: int) -> String:
	var text := Strings.t("panel.bup", [SimClock.format_minutes(b["born"]), b["divisions"]])
	text += Strings.t("panel.steering", [steering_word(b.get("steering", 0.5))])
	text += Strings.t("panel.dish_line", [dish_number])
	return text.rstrip("\n")


## The lines under a bup's genome map (alive or dead): the mutations in its lineage, and its harm.
static func tail(b: Dictionary) -> String:
	return Strings.t("panel.bup_tail", [b["mutations"], Genome.harm_share(b["harm"]) * 100.0])


## A dead bup's lines; `dish_number` is the dish it died in.
static func deceased(b: Dictionary, dish_number: int) -> String:
	var text := Strings.t("panel.deceased", [SimClock.format_minutes(b["born"]), SimClock.format_minutes(b["died"]), b["divisions"]])
	if b.has("moved_to"):
		text += Strings.t("panel.moved_line", [b["moved_to"]]).substr(1) + "\n"
	else:
		text += Strings.t("panel.dish_line", [dish_number]).substr(1) + "\n"
	return text.rstrip("\n")
