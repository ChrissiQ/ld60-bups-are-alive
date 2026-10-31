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
	SimConstants.apply()
	var constants := SimConstants.build()
	var sim := BupSim.new()
	sim.reset(10000.0, 3)
	sim.set_limit(5000)
	sim.set_upkeep_scale(3.0)
	sim.get_field().deposit_disc(Vector2(2000.0, -1000.0), 4000.0, 2.0e6)
	for i in 1000:
		var g := {}
		g["speed"] = 10.0 + 40.0 * sim.random_float()
		g["sense"] = 20.0 + 100.0 * sim.random_float()
		g["metabolism"] = 0.6 + 0.8 * sim.random_float()
		g["size"] = 3.0 + 2.0 * sim.random_float()
		g["hue"] = sim.random_float()
		g["sat"] = 0.4 + 0.5 * sim.random_float()
		g["val"] = 0.6 + 0.4 * sim.random_float()
		g["harm"] = 0.3 * sim.random_float()
		g["mutations"] = int(10.0 * sim.random_float())
		g["donor"] = i % 5 == 0
		g["reach"] = (i % 4) | (((i / 4) % 3) << 8)
		var born := Cell.mass_to_add(g)
		var id := (1 << 32) + 5 + 3 * i if i % 2 == 0 else 1 + i
		sim.add_bup(sim.random_point(9000.0), g, 30.0 + 50.0 * sim.random_float(), sqrt(born * (1.0 + sim.random_float())), born, i % 7, Vector2.from_angle(sim.random_float() * TAU), id)
	sim.step(20.0, PackedVector2Array(), PackedFloat32Array(), 0.0, 20.0)
	var state := sim.export_state_bytes()
	var count := state.size() / GpuLayout.RECORD_BYTES
	var equal := 0
	var first_bad := ""
	for i in count:
		var native := sim.info_from_state(state, i)
		var mine := RecordCodec.info_from_record(state, i, constants, native["born"], native["steering"], 3.0)
		var upkeep: float = native["upkeep"]
		var close: bool = absf(mine["upkeep"] - upkeep) <= 4e-16 * absf(upkeep)  # (the native sum may be fused: one rounding fewer)
		mine["upkeep"] = native["upkeep"]
		if mine == native and close:
			equal += 1
		elif first_bad.is_empty():
			for k in native:
				if not mine.has(k) or mine[k] != native[k]:
					first_bad = "record %d key %s: codec %s native %s" % [i, k, mine.get(k), native[k]]
					break
	TestUtil.check(count > 900 and equal == count, "the codec's dictionary equals info_from_state's for every record (%d of %d) %s" % [equal, count, first_bad])
	TestUtil.check(RecordCodec.info_from_record(state, count, constants).is_empty() and RecordCodec.info_from_record(state, -1, constants).is_empty(), "no such record gives an empty dictionary")
	var d := RecordCodec.info_from_record(state, 0, constants)
	TestUtil.check(d["born"] == 0 and d["steering"] == 0.5, "born and steering default to 0 and 0.5")
	var e := RecordCodec.info_from_record(state, 0, constants, 77, 0.9)
	TestUtil.check(e["born"] == 77 and e["steering"] == 0.9, "born and steering are the arguments given")
	TestUtil.finish(self, "RECORD CODEC TEST OK")
