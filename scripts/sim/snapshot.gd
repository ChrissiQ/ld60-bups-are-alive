class_name Snapshot
extends RefCounted
## What the simulation last finished, immutable once published. The main thread reads it and never waits for it.

var seq := 0
var sim_time := 0.0  ## s: the world clock
var achieved_speed := 0.0
var paused := false
var dishes: Dictionary = {}  ## row -> DishState
var history: Dictionary = {}  ## row -> Array of {time, stats}: the samples since the previous snapshot
var answers: Dictionary = {}  ## row -> {tracked: {id: PackedByteArray (GpuLayout.ANSWER_BYTES)}, steer: {id: Vector3 (the way up the gradient at the bup, x and y, and its chance of steering up it)}, probes: PackedFloat32Array (4 floats a point asked: that way, x and y, the chance, the concentration)}
var payload: PayloadInfo = null
var payloads: Array = []  ## every PayloadInfo published since the snapshot the main thread last took, oldest first (`payload` is the last)
var field_view: FieldViewInfo = null
var worlds: Dictionary = {}  ## row -> DishWorldCopy (only when it changed)
var timing: Dictionary = {}  ## iteration_ms, steps, step_ms_ema, duty, sync_ms, publish_ms, lineage_ms
