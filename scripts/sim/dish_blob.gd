class_name DishBlob
extends RefCounted
## A dish taken out of the pooled world: its spec and the device state that continues its run bit for bit when it is
## loaded again (`SimCore.load_dish`): every DSTATE word, the records (whole: the picture words do not feed the model), the glucose and
## acetate grids and the deposits waiting for the grid as the device holds them (not folded in), and the dish's clouds and husks as whole
## 8-word slots in pool order (the live ones: a dead slot of a dish changes nothing the dish does). The host adds the dish's world
## (`DishWorld.save()`), and what else it keeps with the dish (`host`: its history, watch list, lineage bytes).

const VERSION := 1

var version := VERSION
var spec := {}  ## DishSpec.to_dict()
var dstate := PackedByteArray()  ## DS_WORDS words
var records := PackedByteArray()
var conc := PackedFloat32Array()
var conc2 := PackedFloat32Array()
var dplo := PackedByteArray()
var dphi := PackedByteArray()
var clouds := PackedFloat32Array()  ## 8 floats a cloud; word 5 is 1.0 here (the row word is the pool's)
var husks := PackedFloat32Array()  ## 8 floats a husk, likewise
var world := {}  ## DishWorld.save()
var host := {}  ## the host's own (history, watched, lineage)


func number() -> int:
	return int(spec.get("number", 0))


func count() -> int:
	return records.size() / GpuLayout.RECORD_BYTES
