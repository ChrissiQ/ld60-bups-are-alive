extends SceneTree
## A world row another dish took over does not carry the old dish's history samples or world copy into the snapshots.
##
## Expected, written before the run: a row's sample, held until acknowledged, is in the next snapshot while the same dish (number 7) holds the row;
## once the row shows dish 8 the snapshot has only dish 8's own sample (one, with the time it was given), and the old world copy is gone.

func _item(number: int, sample_time: float, worlds: Dictionary) -> Dictionary:
	return {
		"kind": "iteration", "steps": 0, "sim_time": 0.0, "achieved": 1.0, "paused": false, "stats": PackedByteArray(),
		"rows": [{"row": 3, "number": number, "count": 1, "core_row": 0, "fractions": {}, "extinct": false, "lost": 0, "clouds": 0, "husks": 0}],
		"samples": [[0, sample_time]], "worlds": worlds, "refused": {}, "payload": null, "field_view": null, "timing": {},
	}


func _init() -> void:
	var w := ResultWorker.new()
	w._iteration(_item(7, 10.0, {3: DishWorldCopy.new()}))
	var a := w.latest()
	TestUtil.check(a.history[3].size() == 1 and a.worlds.has(3), "the dish holding the row has its sample and world copy")
	w._iteration(_item(7, 20.0, {}))
	var b := w.latest()
	TestUtil.check(b.history[3].size() == 2 and b.worlds.has(3), "unacknowledged, they stay while the same dish holds the row")
	w._iteration(_item(8, 30.0, {}))
	var c := w.latest()
	TestUtil.check(c.history[3].size() == 1 and c.history[3][0]["time"] == 30.0 and not c.worlds.has(3), "a dish that took the row over starts clean (%s)" % [c.history[3]])
	TestUtil.finish(self, "OK result_worker_rows_test")
