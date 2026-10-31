class_name DishWorldCopy
extends RefCounted
## The main thread's read-only copy of a dish's world: its plankton and sources, stamped with a version that changes when they do.

var version := 0
var time := 0.0  ## s: the world time the copy was made at (a source's `emitted` goes on growing at its rate after it)
var plankton: Array = []  ## {pos: Vector2, born_at, burst_at, units, shape}
var sources: Array = []  ## {id, pos: Vector2, rate, emitted (the units it has released so far, as of `time`)}
