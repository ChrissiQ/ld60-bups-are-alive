class_name FieldViewInfo
extends RefCounted
## Which shared textures hold the main dish's nutrient picture and its steering picture (`n` cells across each), and their versions. The
## two are published together, but a publish that finds no free texture of one kind leaves that kind's last picture in place: each kind
## keeps its own index and publish number.

var texture_index := -1  ## the haze's texture (-1: none yet)
var n := 0
var version := 0
var seq := 0  ## the number of the publish that wrote the haze's texture (SimCore.publish_seq), which the main side gives back with each use
var steer_index := -1  ## the steering picture's texture (-1: none yet)
var steer_seq := 0
var haze_bytes := PackedByteArray()  ## with ViewRenderer.cpu_handover: the haze's `n` x `n` RGBA8 texels (SimCore.handed), in place of a shared texture
var steer_bytes := PackedByteArray()  ## the steering picture's likewise  ## the number of the publish that wrote it
