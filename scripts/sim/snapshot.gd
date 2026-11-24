class_name Snapshot
extends RefCounted
## What the simulation last finished, immutable once published. The main thread reads it and never waits for it.

var seq := 0
var sim_time := 0.0  ## s: the world clock
var achieved_speed := 0.0
var paused := false
var dishes: Dictionary = {}  ## row -> DishState
var history: Dictionary = {}  ## row -> Array of {time, stats}: the samples since the previous snapshot
var answers: Dictionary = {}  ## row -> {tracked: {id: PackedByteArray (GpuLayout.ANSWER_BYTES)}, steer: {id: Vector3 (the way up the gradient at the bup, x and y, and its chance of steering up it)}, probes: PackedFloat32Array (GpuLayout.PROBE_FLOATS a point asked: that way, x and y, the chance, the concentration, the gradient's size), husks: Array of {at: Vector2, reach, found: PackedFloat32Array (the nearest live husk within reach: x, y, energy, age, pieces let go; empty for none)}}
var payload: PayloadInfo = null
var payloads: Array = []  ## every PayloadInfo published since the snapshot the main thread last took, oldest first (`payload` is the last)
var field_view: FieldViewInfo = null
var thumbs: ThumbsInfo = null  ## the newest thumbnails' atlas (null before the first)
var totals: Dictionary = {}  ## every running dish together, worked out where the snapshot is made (DishState.aggregate): {dishes, count, stats}
var husk_view: Dictionary = {}  ## the main dish's live husks as last read: {row, version, transforms: PackedFloat32Array (SimCore.run's husk_list)}; empty before
var worlds: Dictionary = {}  ## row -> DishWorldCopy (only when it changed)
var timing: Dictionary = {}  ## iteration_ms, steps, step_ms_ema, duty, sync_ms, publish_ms; worker_queue; the family tree's lineage_ms, lineage_queue, lineage_queue_bytes, lineage_behind_s
var lineage_ticket := 0  ## every family-tree step asked for before this snapshot's iteration (its events, a thaw's import, a pipette's retarget) is in the store once the family tree has done this many (WorldClient.lineage_done); 0: nothing to wait for
