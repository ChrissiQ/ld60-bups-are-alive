class_name FieldViewInfo
extends RefCounted
## Which shared texture holds the main dish's nutrient picture (`n` cells across), and its version.

var texture_index := -1
var n := 0
var version := 0
var seq := 0  ## the number of the publish that wrote it (SimCore.publish_seq), which the main side gives back with each use
