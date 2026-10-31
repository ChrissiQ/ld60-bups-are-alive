class_name DishWorldCopy
extends RefCounted
## The main thread's read-only copy of a dish's world: its plankton and sources, stamped with a version that changes when they do.

var version := 0
var plankton: Array = []  ## {pos: Vector2, born_at, burst_at, units, shape}
var sources: Array = []  ## {id, pos: Vector2, rate}
