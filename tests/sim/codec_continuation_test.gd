extends SceneTree
## Through the save format: a dish frozen, written with DishCodec as JSON text, read back and thawed carries on as if it had run
## straight through (continuation property).
##
## Expected values, written before the first run:
## - run N = 80 steps, freeze, DishCodec.write_blob, JSON text, DishCodec.read_blob, thaw, run M = 80 steps gives a dump with 0 differing
##   words against the dish run N + M = 160 steps straight (diff == "") [derived: the codec keeps every block of the blob byte for byte and
##   the world (DishWorld.save()) as a lossless binary variant, so the thawed dish is the one `continuation_test` thaws from memory].
## - the blob that comes back has the records, DSTATE, grids, clouds and husks it was written with (equal as packed arrays).
## Needs a GPU. Windowed only.

const N := 80
const M := 80


func _init() -> void:
	if not SimHarness.begin(self, "codec_continuation_test", "SimCore"):
		return
	for flags in [{}, {"stationary": true, "death_husks": true, "plankton_husks": true, "acetate": true, "key": true, "conjugation": true}]:
		var s := Scenario.small(40, 600.0).seed(31).with_flags(flags)
		s.bloom_density = 2.0
		var straight := SimHarness.make([s.copy()]).step(N + M)
		var h := SimHarness.make([s.copy()]).step(N)
		var blob: Variant = h.freeze(0)
		blob.host.merge({"history": DishHistory.new().write(), "watched": PackedInt64Array(), "lineage": PackedByteArray(), "nutrients_placed": 0})
		var text := JSON.stringify(DishCodec.write_blob(blob))
		var back := DishCodec.read_blob(JSON.parse_string(text))
		TestUtil.show(back != null, "flags %s: the written blob reads back (%d bytes of text)" % [flags.keys(), text.length()])
		if back == null:
			continue
		var same: bool = true
		for part: String in ["records", "dstate", "conc", "conc2", "dplo", "dphi", "clouds", "husks"]:
			same = same and back.get(part) == blob.get(part)
		TestUtil.show(same, "its device blocks equal the frozen dish's")
		back.host["scenario"] = blob.host["scenario"]
		back.host["steps_done"] = blob.host["steps_done"]
		var row := h.thaw(back)
		h.step(M)
		var line := SimHarness.diff(straight.dump(0), h.dump(row))
		TestUtil.show(line == "", "flags %s: freeze at %d, save, load and thaw equals the straight run: %s" % [flags.keys(), N, line if line != "" else "same"])
	TestUtil.finish(self, "OK codec_continuation_test")
