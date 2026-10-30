class_name Encyclopedia
extends RefCounted
## The game's encyclopedia: what its terms and concepts mean, as games usually keep an encyclopedia (the Civilopedia gives each thing a part about what it is and a
## part about how it works in the game). How to do things is not here: that is the tutorial's, and the tooltips'. An entry has up to two parts: `about` (what it is in
## real life: biology checked against sources) and `game` (how it works in the game: values, ranges, costs, and where the game departs from real life).
## This holds only the order; every word is in text/strings.cfg, [encyclopedia] (`<id>_title`, `<id>_about`, `<id>_game`, `cat_<id>` for a heading). A text links
## to another entry with [url=<id>]words[/url]. The panel is ui/encyclopedia_panel.gd, in the title screen and the pause menu; a click on a band of the genome
## map opens the entry of its gene (`entry_for_locus`).

const CATEGORIES := [
	["genome", ["chromosome", "allele", "speed", "sense", "metabolism", "size", "mutator", "donor", "key", "ceilings"]],
	["evolution", ["mutation", "harm", "selection", "conjugation", "generation", "founders"]],
	["bups", ["mass", "energy", "steering", "starvation"]],
	["dish", ["nutrient", "acetate", "sources", "plankton", "husks", "population_cap", "freezer"]],
]


## Every entry, in the order the index lists them.
static func all_entries() -> Array[String]:
	var out: Array[String] = []
	for category: Array in CATEGORIES:
		for id: String in category[1]:
			out.append(id)
	return out


## Entries the index leaves out until the game has the fact named (set with `set_fact`). An unlisted entry is still an entry: links to it and
## `show_entry` open it.
const UNLISTED_UNTIL := {"husks": "husks"}

static var _facts := {}  ## fact name -> whether the game has it; a fact nothing has set is off


static func set_fact(fact: String, on: bool) -> void:
	_facts[fact] = on


## Whether the index lists an entry now.
static func is_listed(id: String) -> bool:
	return not UNLISTED_UNTIL.has(id) or _facts.get(UNLISTED_UNTIL[id], false)


## The entries the index lists now, in order.
static func listed_entries() -> Array[String]:
	var out: Array[String] = []
	for id in all_entries():
		if is_listed(id):
			out.append(id)
	return out


## The entry a locus of the genome map opens.
static func entry_for_locus(locus: String) -> String:
	return locus


static func title(id: String) -> String:
	return Strings.t("encyclopedia.%s_title" % id)


## What the thing is in real life ("" if the entry has no such part: a thing that is only in the game).
static func about(id: String) -> String:
	return _part("%s_about" % id)


## How the thing works in the game ("" if the entry has no such part).
static func game(id: String) -> String:
	return _part("%s_game" % id)


static func _part(name: String) -> String:
	return Strings.t("encyclopedia." + name) if Strings.has_key("encyclopedia." + name) else ""


static func category_title(id: String) -> String:
	return Strings.t("encyclopedia.cat_%s" % id)


## The ids of the listed entries whose title or text holds `query` (any case); every listed entry for an empty query.
static func search(query: String) -> Array[String]:
	var out: Array[String] = []
	var wanted := query.strip_edges().to_lower()
	for id in listed_entries():
		if wanted.is_empty() or title(id).to_lower().contains(wanted) or about(id).to_lower().contains(wanted) or game(id).to_lower().contains(wanted):
			out.append(id)
	return out

