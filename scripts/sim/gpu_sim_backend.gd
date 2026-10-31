class_name GpuSimBackend
extends SimBackend
## The simulation on the GPU: the pooled world on a local RenderingDevice of its own, run by a SimThread, with the family tree in one
## LineageStore the main thread may query while the worker writes it (the store has its own mutex).

static var _warm: Array[Resource] = []  ## the pooled kernels' shader files, loaded on the main thread and held, so the sim thread's load finds them cached

var thread: SimThread = null
var store: LineageStore = null


## Whether this machine can run it: a local device can be made (not under --headless) and the pooled kernels' imported shaders load.
static func available() -> bool:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		return false
	rd.free()
	var defs := {}
	var all := GpuKernels.all()
	for kname: String in all:
		if kname.begins_with("pool_") or kname == "ev_deposits":
			defs[kname] = all[kname]
	_warm.clear()
	for kname: String in defs:
		var path := ShaderSet.SHADER_DIR.path_join(kname + ".glsl")
		if ResourceLoader.exists(path):
			_warm.append(load(path))
	return ShaderSet.imported(defs).errors.is_empty()


func can_simulate() -> bool:
	if thread == null:
		return false
	return not thread.status()["failed"]


func device_name() -> String:
	return String(thread.status()["device"]) if thread != null else ""


## Starts the sim thread and its worker. `limits` is a PoolLimits (null: PoolLimits.from_settings()).
func start(limits: RefCounted) -> void:
	if thread != null:
		return
	store = LineageStore.new()
	store.set_constants(Cell.RESERVE_PER_MASS, Cell.ADD_MASS_FACTOR)
	thread = SimThread.new(limits if limits != null else PoolLimits.from_settings(), store)
	thread.start()


func submit(cmd: SimCommand) -> void:
	if thread == null:
		if cmd.reply != null:
			cmd.reply.complete(null, "not started")
		return
	thread.submit(cmd)


func latest() -> Snapshot:
	return thread.worker.latest() if thread != null else Snapshot.new()


## The main device imports the shared textures itself (ViewRenderer.bind, from `texture_handles`), so there is no main-side source here.
func view_source() -> ViewSource:
	return null


func shutdown() -> void:
	if thread != null:
		thread.stop()
	_warm.clear()


# ---- beyond the seam (WorldClient uses them when the backend has them) ---------------------------------------------------------------

## The main thread took snapshot `seq` (what it carried once is not carried again).
func ack(seq: int) -> void:
	if thread != null:
		thread.worker.ack(seq)


func texture_bound(kind: String, index: int, frame: int) -> void:
	if thread != null:
		thread.texture_bound(kind, index, frame)


func texture_handles() -> Dictionary:
	return thread.texture_handles() if thread != null else {}


func lineage() -> LineageStore:
	return store


func status() -> Dictionary:
	return thread.status() if thread != null else {}
