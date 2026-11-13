class_name CpuSimBackend
extends SimBackend
## The stub backend: the seam's CPU side, switched off, it runs nothing. The seam lets another backend be plugged in,
## but the GPU is always used where it can be (SimService picks this only where no local GPU device can be made, as under --headless).
## Every command is accepted and dropped; one that wants a reply has it completed at once with no value; the snapshot is always empty.

var _snapshot := Snapshot.new()


func can_simulate() -> bool:
	return false


func device_name() -> String:
	return ""


func submit(cmd: SimCommand) -> void:
	if cmd.reply != null:
		cmd.reply.complete(null)


func latest() -> Snapshot:
	return _snapshot
