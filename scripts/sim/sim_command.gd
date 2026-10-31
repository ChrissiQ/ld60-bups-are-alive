class_name SimCommand
extends RefCounted
## One request to the simulation, as the queue carries it: what it is (`kind`, one of the KIND_* names), its arguments, and the reply to
## complete when it is done (null for a command nobody waits on). Commands carry no time: an edit lands at the sim clock when it is drained.

const KIND_ADD_DISH := &"add_dish"
const KIND_REMOVE_DISH := &"remove_dish"
const KIND_FREEZE := &"freeze"
const KIND_THAW := &"thaw"
const KIND_PIPETTE := &"pipette"
const KIND_RESIZE := &"resize"
const KIND_SET_PARAMS := &"set_params"
const KIND_EDIT_WORLD := &"edit_world"
const KIND_SET_TIME := &"set_time"
const KIND_SET_VIEW := &"set_view"
const KIND_ASK := &"ask"
const KIND_SAVE_ALL := &"save_all"

var kind: StringName
var args: Dictionary
var reply: SimReply


func _init(p_kind: StringName = &"", p_args: Dictionary = {}, p_reply: SimReply = null) -> void:
	kind = p_kind
	args = p_args
	reply = p_reply
