class_name SimBackend
extends RefCounted
## The seam between the game and whatever runs the simulation. Pure data and no-ops here: the GPU backend, the CPU stub and the test
## double (`FakeSimBackend`) override it. Nothing here blocks except `shutdown` and `SimReply.wait`.

func can_simulate() -> bool:
	return false


func device_name() -> String:
	return ""


## `limits` is the pool's limits (a `PoolLimits` once that type exists).
func start(_limits: RefCounted) -> void:
	pass


func submit(_cmd: SimCommand) -> void:
	pass


## The newest complete snapshot; an empty one before the first.
func latest() -> Snapshot:
	return Snapshot.new()


func shutdown() -> void:
	pass
