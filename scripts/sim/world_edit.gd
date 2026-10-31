class_name WorldEdit
extends RefCounted
## An edit of a dish's world, in the dish's own coordinates. Two kinds touch the field and are the core's
## (`SimCore.queue_edit` records them as kernels before the next batch): DROP (nutrient at a point, `amount` units of energy, shared
## out over the four cells about it) and ERASE (a disc of `radius` µm whose cells and clouds lose `amount` of what they hold at the
## centre, less towards the rim). The others are the dish's DishWorld's (`as_world_op`).

enum Kind { DROP, ERASE, PLACE_SOURCE, REMOVE_SOURCE, SET_SOURCE_RATE, PLACE_PLANKTON, REMOVE_PLANKTON }

var kind := Kind.DROP
var position := Vector2.ZERO  ## µm, dish-local
var amount := 0.0  ## DROP: energy; ERASE: the strength at the centre (0 to 1); a source's rate
var radius := 0.0  ## µm: ERASE's disc, REMOVE_PLANKTON's reach
var id := -1  ## a source's id


static func drop(at: Vector2, energy: float) -> WorldEdit:
	var e := WorldEdit.new()
	e.kind = Kind.DROP
	e.position = at
	e.amount = energy
	return e


static func erase(at: Vector2, disc_radius: float, strength: float) -> WorldEdit:
	var e := WorldEdit.new()
	e.kind = Kind.ERASE
	e.position = at
	e.radius = disc_radius
	e.amount = strength
	return e


func is_field_edit() -> bool:
	return kind == Kind.DROP or kind == Kind.ERASE


## The edit as DishWorld.apply takes it ({} for a field edit).
func as_world_op() -> Dictionary:
	match kind:
		Kind.PLACE_SOURCE:
			return {"op": "add_source", "pos": position, "rate": amount}
		Kind.REMOVE_SOURCE:
			return {"op": "remove_source", "id": id}
		Kind.SET_SOURCE_RATE:
			return {"op": "set_rate", "id": id, "rate": amount}
		Kind.PLACE_PLANKTON:
			return {"op": "add_plankton", "pos": position}
		Kind.REMOVE_PLANKTON:
			return {"op": "remove_plankton", "pos": position, "radius": radius}
	return {}
