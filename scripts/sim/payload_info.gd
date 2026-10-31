class_name PayloadInfo
extends RefCounted
## Which shared texture holds the main-view dish's picture and how fresh it is.

var texture_index := -1
var count := 0
var sim_time := 0.0
var row := -1
var generation := 0  ## changes when the textures are re-made at another size
var seq := 0  ## the number of the publish that wrote it (SimCore.publish_seq), which the main side gives back with each use
var handles := PackedInt64Array()  ## the payload textures' native handles on the simulation's device (ViewRenderer.driver_handles), all SimCore.TEXTURES
var id_handles := PackedInt64Array()  ## the id textures' likewise
var size := Vector2i()  ## the textures' size in texels (GpuLayout.PAYLOAD_TEX_WIDTH wide)
var places := {}  ## id -> Vector3(x, y, drawn length in µm), dish-local, of the bups the dish asks after (its selected and hovered) in this payload
