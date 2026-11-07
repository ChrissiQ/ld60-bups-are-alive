extends SceneTree
## Run: godot --headless --path . -s tests/record_codec_test.gd
## RecordCodec.info_from_record against the native info_from_state, headless.
## Expected, written before the first run [derived: the codec is a port of BupSim::info_of]:
##  - for every one of 1,000 records (half with ids past 2^32, donors and raised ceilings among them, an upkeep scale of 3), the
##    codec's dictionary equals info_from_state's once `born` and `steering` are given what the family record and the field say:
##    exactly equal (same keys, same values: the float32 roundings are reproduced), 1000 of 1000, except `upkeep`, a sum of three
##    products that the native build may fuse: within 2 ulp (4e-16 relative) of it;
##  - an index past the end, or below 0, gives an empty dictionary;
##  - `born` and `steering` are the arguments given, 0 and 0.5 by default.


func _init() -> void:
	# Skipped: the reference is native BupSim.info_from_state, which the C++ simulation no longer has.
	# The codec's check against it needs a new reference (the pooled world's records), not yet written.
	print("RECORD CODEC TEST SKIP: no native BupSim reference")
	quit(0)
	return
