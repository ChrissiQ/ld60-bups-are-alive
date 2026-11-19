extends Node
## The simulation's one world for the whole run of the game, an autoload: the backend is chosen once, when the
## world is first asked for (`world()`): the GPU where a local device can be made and the pooled kernels load, else the stub backend (CpuSimBackend),
## which runs nothing. It lives until the game quits, when the sim thread is stopped and joined. Each frame it polls the world, so
## `WorldClient.snapshot_changed` is emitted on the main thread.
##
## A test swaps in its own backend (a FakeSimBackend) with `use_backend` before any scene asks for the world.
##
## The GPU backend's script is loaded by path when the world is first asked for, not named here: naming its class makes this autoload load
## the simulation's and the game's scripts when it is compiled, and some of them are then left in use at exit (Godot reports 78 objects and
## 41 resources leaked in a headless test that never asks for the world).

const GPU_BACKEND := "res://scripts/sim/gpu_sim_backend.gd"

var _backend: SimBackend = null
var _world: WorldClient = null


## The world (made on the first call).
func world() -> WorldClient:
	if _world == null:
		if _backend == null:
			var gpu: GDScript = load(GPU_BACKEND)
			_backend = gpu.new() if gpu.available() else CpuSimBackend.new()
			var limits := PoolLimits.from_settings()
			if MemoryMode.machine == null:
				MemoryMode.machine = limits.machine  # (the screens judge the machine by what the simulation started from)
			_backend.start(limits)
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
