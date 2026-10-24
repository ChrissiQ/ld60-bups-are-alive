class_name GpuDraw
extends RefCounted
## Draws the bups straight from the GPU's records the render kernel (`render_bups` in
## gpu/kernels_draw.gd, a port of BupSim::render_buffer) writes each bup's instance into a MultiMesh's RD buffer, with no copy
## through the CPU. GpuWorld.draw_bups calls it; tools use it on a local device with a plain buffer.
##
## What was checked on Metal, and the rules that follow from it:
## - On the main RenderingDevice a compute list recorded during the frame (from the main thread, through
##   RenderingServer.call_on_render_thread) runs before the same frame's canvas draw, which shows what it wrote.
## - The MultiMesh's RD buffer (RenderingServer.multimesh_get_buffer_rd_rid) holds exactly multimesh_set_buffer's 16 floats per instance.
##   `multimesh.buffer = ...` leaves no CPU copy behind, but a per-instance setter (set_instance_color, ...) makes one, and from then on
##   its changed instances are uploaded over the GPU's: never call those on a GPU-drawn MultiMesh.
## - A new instance_count makes a new RD buffer (a new RID) and frees the uniform sets bound to the old one: the kernel's set is made
##   again whenever the buffer drawn into is not the one it was made for, or GpuSim.buffers_rebuilt was emitted.
## One GpuDraw per GpuSim (`of`), kept on it as metadata; it holds no reference to the GpuSim, so the two do not keep each other alive.

const KERNEL := "render_bups"
const META := &"gpu_draw"

var generation := 0  ## how many times the GpuSim's buffers were made afresh (a load) since this was made: a reason to draw again
var _target := RID()  ## the buffer the kernel's uniform set binds now (none until the first draw)
var _rebuilt := true  ## the GpuSim's buffers were made afresh since the set was made


## The GpuDraw of `gpu` (made on first use).
static func of(gpu: GpuSim) -> GpuDraw:
	if not gpu.has_meta(META):
		var made := GpuDraw.new()
		gpu.buffers_rebuilt.connect(made._on_buffers_rebuilt)
		gpu.set_meta(META, made)
	return gpu.get_meta(META)


func _on_buffers_rebuilt() -> void:
	_rebuilt = true
	generation += 1


## Writes the picture of `gpu`'s bups into `target` (a MultiMesh's RD buffer, or any storage buffer of the same device at least
## 64 * instance_count bytes): `instance_count` instances, at `pixel_um` µm to the screen pixel. On the main device it is recorded on
## the render thread and runs with the frame; on a local device it is submitted and waited for. Nothing happens before a state is loaded.
func draw(gpu: GpuSim, target: RID, instance_count: int, pixel_um: float) -> void:
	if gpu.capacity <= 0 or instance_count <= 0 or not target.is_valid():
		return
	if gpu.is_main:
		RenderingServer.call_on_render_thread(_draw_now.bind(gpu, target, instance_count, pixel_um))
	else:
		_draw_now(gpu, target, instance_count, pixel_um)


func _draw_now(gpu: GpuSim, target: RID, instance_count: int, pixel_um: float) -> void:
	var cl := gpu.rd.compute_list_begin()
	record(cl, gpu, target, instance_count, pixel_um)
	gpu.rd.compute_list_end()
	if not gpu.is_main:
		gpu.rd.submit()
		gpu.rd.sync()


## Records the render kernel into the compute list `cl` (begun by the caller, on the render thread for the main device): one thread
## per slot, and one per bup past the slots (those lose their last place, so they get no trail when they are drawn again).
func record(cl: int, gpu: GpuSim, target: RID, instance_count: int, pixel_um: float) -> void:
	if _rebuilt or target != _target:
		gpu.make_external_kernel(KERNEL, ["P", "CNT", "BUPS", target])
		_target = target
		_rebuilt = false
	gpu.dispatch(cl, KERNEL, maxi(instance_count, gpu.capacity), pixel_um, float(instance_count))
