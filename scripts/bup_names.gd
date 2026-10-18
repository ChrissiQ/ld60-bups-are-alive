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

## "lil bup #578": its size word, going by the size its genome grows to, and its number.
static func default_name(size_gene: float, id: int) -> String:
	return "%s #%s" % [Cell.title_for(size_gene), UiText.group(str(id))]


## What a typed name becomes: no line breaks or control characters, spaces trimmed, a sensible length.
static func clean(text: String) -> String:
	var out := ""
	for i in text.length():
		var code := text.unicode_at(i)
		out += " " if code < 32 or code == 127 else text[i]
	return out.strip_edges().substr(0, MAX_LENGTH).strip_edges()
