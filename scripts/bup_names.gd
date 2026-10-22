class_name BupNames
extends RefCounted
## What bups are called. Every bup has a number, given in birth order within its dish (the 578th bup born
## is #578) and kept for its whole life; the dish starting over starts the numbering again at 1. Unless
## the player renames one, a bup's name is its size word and that number ("lil bup #578"). A name the
## player gave is kept on the bup's family record in the simulation (see BupSim) and goes when the record does.
##
## Nothing outside Dish and this file builds or looks up a name. To show a bup's name, ask the dish
## (`Dish.bup_name(id)`) or put a BupNameRow (ui/bup_name_row.tscn) in the panel; tests/ui_lint_test.gd fails
## on anything else, so a panel can't end up calling a bup something the rest of the game doesn't.

const MAX_LENGTH := 24
const RANDOM_NAMES_FILE := "res://text/names.txt"  ## the names the founders screen picks from: one on each line (an export has to include it, like text/strings.cfg)

static var _random_names: Array[String] = []


## The silly names a founder can be given at random, in the file's order (empty if it can't be read).
static func random_pool() -> Array[String]:
	if _random_names.is_empty():
		for line in FileAccess.get_file_as_string(RANDOM_NAMES_FILE).split("\n"):
			var name := line.strip_edges()
			if name != "":
				_random_names.append(name)
		if _random_names.is_empty():
			push_error("No names in %s" % RANDOM_NAMES_FILE)
	return _random_names

## "lil bup #578": its size word, going by the size its genome grows to, and its number.
static func default_name(size_gene: float, id: int) -> String:
	return Strings.t("bups.name", [Cell.title_for(size_gene), UiText.group(str(id))])


## What a typed name becomes: no line breaks or control characters, spaces trimmed, a sensible length.
static func clean(text: String) -> String:
	var out := ""
	for i in text.length():
		var code := text.unicode_at(i)
		out += " " if code < 32 or code == 127 else text[i]
	return out.strip_edges().substr(0, MAX_LENGTH).strip_edges()
