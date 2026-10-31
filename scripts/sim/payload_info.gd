class_name PayloadInfo
extends RefCounted
## Which shared texture holds the main-view dish's picture and how fresh it is.

var texture_index := -1
var count := 0
var sim_time := 0.0
var row := -1
var generation := 0  ## changes when the textures are re-made at another size
var seq := 0
