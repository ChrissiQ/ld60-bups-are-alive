extends Node
## The simulation's one world for the whole run of the game, an autoload: the backend is chosen once, when the
## world is first asked for (`world()`): the GPU where a local device can be made and the pooled kernels load, else the processor's stub,
## which runs nothing. It lives until the game quits, when the sim thread is stopped and joined. Each frame it polls the world, so
## `WorldClient.snapshot_changed` is emitted on the main thread.
##
## A test swaps in its own backend (a FakeSimBackend) with `use_backend` before any scene asks for the world.

var _backend: SimBackend = null
var _world: WorldClient = null


## The world (made on the first call).
func world() -> WorldClient:
	if _world == null:
		if _backend == null:
			_backend = GpuSimBackend.new() if GpuSimBackend.available() else CpuSimBackend.new()
			_backend.start(PoolLimits.from_settings())
		_world = WorldClient.new(_backend)
	return _world


func backend() -> SimBackend:
	world()
	return _backend


## Replaces the backend (tests: before any scene asks for the world). The old one, if any, is shut down.
func use_backend(b: SimBackend) -> void:
	if _backend != null and _backend != b:
		_backend.shutdown()
	_backend = b
	_world = WorldClient.new(b)


## Whether the world has been made (nothing runs before the first `world()`).
func started() -> bool:
	return _world != null


func _process(_delta: float) -> void:
	if _world != null:
		_world.poll()


func _exit_tree() -> void:
	shutdown()


func shutdown() -> void:
	if _backend != null:
		_backend.shutdown()
		_backend = null
	_world = null
