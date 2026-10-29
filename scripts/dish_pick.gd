class_name DishPick
extends RefCounted
## What is picked in a dish: a bup, a source, a plankton or a husk, each or none. A dish keeps two,
## the selection (what was clicked) and the hover (what is under the pointer).

## Emitted when `bup` changes.
signal bup_changed

const NO_HUSK := Vector2(INF, INF)

var bup := -1:  ## the bup's id, or -1
	set(value):
		if value != bup:
			bup = value
			bup_changed.emit()
var source: NutrientSource = null
var plankton: Plankton = null
var husk := NO_HUSK  ## where the husk lies (a husk has no identity: it is found by its place), or NO_HUSK


func is_empty() -> bool:
	return bup < 0 and not has_thing()


## Whether a source, a plankton or a husk is picked (what is picked besides a bup).
func has_thing() -> bool:
	return source != null or plankton != null or husk != NO_HUSK


func clear() -> void:
	bup = -1
	source = null
	plankton = null
	husk = NO_HUSK


func set_to(other: DishPick) -> void:
	source = other.source
	bup = other.bup
	plankton = other.plankton
	husk = other.husk


## Lets go of a source or plankton that is gone from the dish.
func forget(thing: Object) -> void:
	if source == thing:
		source = null
	if plankton == thing:
		plankton = null
