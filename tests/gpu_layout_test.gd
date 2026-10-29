extends SceneTree
## Run: godot --headless --path . -s tests/gpu_layout_test.gd
## The GPU path's word layouts (gpu/gpu_layout.gd), headless:
## - the table itself: each layout's words distinct and within its size, the record and the events with every word named, the parts of
##   QIN and OUT apart from one another, the slots of P unique (an array counts every slot it covers) and inside P, each "const" or
##   "array" slot a constant SimConstants.build() has, each "dish" and "batch" slot set by gpu/gpu_sim.gd and no other name set there;
## - the kernels (GpuKernels.all()): no slot of P, record stride, CNT or PCNT word left as a number, and every layout-like name they use
##   declared by the table;
## - the C++ side, word by word: a record built from the table's names is what BupSim.import_state_bytes reads (bup_info) and what
##   export_state_bytes writes back, its last picture and its chemotaxis memory included. (apply_events' layout is checked word by word
##   in tests/gpu_native_test.gd, whose events are built from the table's names.)

const L := preload("res://gpu/gpu_layout.gd")
const PREFIXES := ["P_", "R_", "EB_", "ED_", "EV_", "CNT_", "PCNT_", "Q_", "QO_", "ST_", "OUT_"]


func _init() -> void:
	SimConstants.apply()
	var constants: Dictionary = (load("res://gpu/gpu_layout.gd") as Script).get_script_constant_map()
	_words_cover(constants, "R_", GpuLayout.RECORD_WORDS, "the bup record")
	_words_cover(constants, "EB_", GpuLayout.BIRTH_WORDS, "a birth event")
	_words_cover(constants, "ED_", GpuLayout.DEATH_WORDS, "a death event")
	_words_within(constants, "CNT_", GpuLayout.CNT_WORDS, "CNT")
	_words_within(constants, "PCNT_", GpuLayout.PCNT_WORDS, "PCNT")
	_words_within(constants, "ST_", GpuLayout.STATS_WORDS, "a stats sample")
	_parts_apart()
	_slots(constants)
	_kernels()
	_record_word_by_word()
	TestUtil.finish(self, "GPU LAYOUT TEST OK")


## The constants named `prefix`... (not the ..._WORDS sizes).
static func _named(constants: Dictionary, prefix: String) -> Dictionary:
	var out := {}
	for name: String in constants:
		if name.begins_with(prefix) and not name.ends_with("_WORDS") and constants[name] is int:
			out[name] = constants[name]
	return out


## Every word of the layout has exactly one name.
func _words_cover(constants: Dictionary, prefix: String, size: int, what: String) -> void:
	var named := _named(constants, prefix)
	var values: Array = named.values()
	values.sort()
	var expected := range(size)
	TestUtil.check(values == expected, "%s: the %s* names give the words %s, not each of 0-%d once" % [what, prefix, str(values), size - 1])


## The named words of the layout are distinct and inside it.
func _words_within(constants: Dictionary, prefix: String, size: int, what: String) -> void:
	var named := _named(constants, prefix)
	var seen := {}
	for name: String in named:
		var w: int = named[name]
		TestUtil.check(w >= 0 and w < size, "%s: %s is %d, outside its %d words" % [what, name, w, size])
		TestUtil.check(not seen.has(w), "%s: %s and %s are both word %d" % [what, name, seen.get(w, ""), w])
		seen[w] = name


func _parts_apart() -> void:
	TestUtil.check(L.RECORD_VEC4 * 4 == L.RECORD_WORDS, "RECORD_VEC4 is the record in 16-byte pieces")
	TestUtil.check(L.ANSWER_WORDS == L.R_FAST and L.R_FAST < L.R_SLOW and L.R_SLOW < L.R_NOISE and L.R_NOISE < L.R_TUMBLING and L.R_TUMBLING == L.RECORD_WORDS - 1,
		"an answer's record is every word before the chemotaxis memory, which ends the record (GpuLayout.whole_record fills the rest)")
	TestUtil.check(L.R_ID_LO < L.ANSWER_WORDS and L.R_ID_HI < L.ANSWER_WORDS, "an answer's record holds the id (a tracked bup not found is told by it)")
	TestUtil.check(L.R_SPEED + 1 == L.R_SENSE and L.R_SENSE + 1 == L.R_METABOLISM and L.R_METABOLISM + 1 == L.R_SIZE, "the genes are four words in a row (R_SPEED + g)")
	TestUtil.check(L.EB_SPEED + 3 == L.EB_SIZE and L.ST_SPEED + 3 == L.ST_SIZE, "the genes are in a row in a birth and in a stats sample too")
	TestUtil.check(Genome.GENES.keys() == ["speed", "sense", "metabolism", "size"] and GpuWorld.GENE_NAMES == Genome.GENES.keys(), "the genes' order is Genome.GENES' and GpuWorld.GENE_NAMES'")
	TestUtil.check(L.ST_COUNT == 0 and L.ST_SPEED == 1 and L.ST_MUTATIONS == 6, "stats2 copies its sums 1-6 to ST_SPEED..ST_MUTATIONS")
	TestUtil.check(L.EV_LOW_MASK == (1 << L.EV_REACH_SHIFT) - 1 and L.EV_REACH_SHIFT + 10 == L.EV_DONOR_SHIFT and L.EV_REACH_MASK == 0x3FF, "a traits word: 20 low bits, the reach word's 10, then the F factor")
	# QIN: the counts, then their parts, in order and inside it
	TestUtil.check(L.Q_PICK_X == L.Q_PICK + 1 and L.Q_PICK_Y == L.Q_PICK + 2 and L.Q_SLACK == L.Q_PICK + 3 and L.Q_PIXEL == L.Q_PICK + 4 and L.Q_PIXEL < L.Q_NEAR, "QIN: the pick's words")
	TestUtil.check(L.Q_NEAR_FIRST == L.Q_NEAR + 1 and L.Q_NEAR_FIRST + 3 * L.NEAR_SLOTS <= L.Q_FRAC, "QIN: the nearest points fit before the fractions")
	TestUtil.check(L.Q_FRAC_FIRST == L.Q_FRAC + 1 and L.Q_FRAC_FIRST + 2 * L.FRACTIONS <= L.Q_TRACK, "QIN: the fractions fit before the tracked ids")
	TestUtil.check(L.Q_TRACK_FIRST == L.Q_TRACK + 1 and L.Q_TRACK_FIRST + 2 * L.TRACKED <= L.QIN_WORDS, "QIN: the tracked ids fit")
	# OUT
	TestUtil.check(L.OUT_CNT + L.CNT_WORDS <= L.OUT_PCNT and L.OUT_PCNT + L.PCNT_WORDS <= L.OUT_Q, "OUT: CNT and PCNT fit before the answers")
	TestUtil.check(L.CNT_WORDS + L.PCNT_WORDS <= L.QOUT_WORDS, "q_clear's threads (QOUT_WORDS) cover CNT and PCNT")
	TestUtil.check(L.QO_D2 == L.QO_INDEX + 1 and L.QO_RECORD == L.QO_D2 + 1 and L.QO_RECORD + L.ANSWER_WORDS <= L.QO_NEAR, "QOUT: the pick and its record")
	TestUtil.check(L.QO_NEAR + 2 <= L.QO_FRAC and L.QO_FRAC + L.FRACTIONS <= L.QO_TRACKED, "QOUT: the first nearest point and the fractions")
	TestUtil.check(L.QO_TRACKED + L.TRACKED * L.ANSWER_WORDS <= L.QO_NEAR_MORE and L.QO_NEAR_MORE + 2 * (L.NEAR_SLOTS - 1) <= L.QOUT_WORDS, "QOUT: the tracked records and the other nearest points")
	TestUtil.check(L.OUT_Q + L.QOUT_WORDS <= L.OUT_STATS and L.OUT_WORDS == L.OUT_STATS + L.STATS_WORDS * (1 + L.MAX_SAMPLES), "OUT: the stats samples after the answers")
	TestUtil.check(L.RECORD_BYTES == L.RECORD_WORDS * 4 and L.ANSWER_BYTES == L.ANSWER_WORDS * 4, "the record's and an answer's sizes in bytes")
	TestUtil.check(GpuSim.RECORD_BYTES == L.RECORD_BYTES and GpuKernels.FRACTIONS == L.FRACTIONS, "the names scripts/ reads outside the table are the table's")


func _slots(constants: Dictionary) -> void:
	var sim_constants := SimConstants.build()
	var taken := {}
	for slot_name: String in GpuLayout.P_SLOTS:
		var entry: Array = GpuLayout.P_SLOTS[slot_name]
		var kind: String = entry[1]
		TestUtil.check(kind in ["const", "array", "dish", "batch"], "P slot %s: unknown kind %s" % [slot_name, kind])
		var length: int = entry[2] if kind == "array" else 1
		TestUtil.check(entry[0] >= 0 and entry[0] + length <= GpuLayout.P_WORDS, "P slot %s (%d, %d long) is outside P's %d" % [slot_name, entry[0], length, GpuLayout.P_WORDS])
		for k in length:
			var slot: int = entry[0] + k
			TestUtil.check(not taken.has(slot), "P slot %d is both %s and %s" % [slot, taken.get(slot, ""), slot_name])
			taken[slot] = slot_name
		if kind == "const":
			TestUtil.check(sim_constants.has(slot_name) and (sim_constants[slot_name] is float or sim_constants[slot_name] is int), "P slot %s: SimConstants.build() has no number of that name" % slot_name)
		elif kind == "array":
			TestUtil.check(sim_constants.has(slot_name) and sim_constants[slot_name] is Array and (sim_constants[slot_name] as Array).size() == length, "P slot %s: SimConstants.build() has no list of %d of that name" % [slot_name, length])
		TestUtil.check(not constants.has("P_" + slot_name.to_upper()), "P slot %s and the constant P_%s would be one GLSL name" % [slot_name, slot_name.to_upper()])
	# what gpu/gpu_sim.gd sets by name
	var text := FileAccess.get_file_as_string("res://gpu/gpu_sim.gd")
	var set_names := {}
	for m in RegEx.create_from_string("_set_p\\(\"(\\w+)\"").search_all(text):
		set_names[m.get_string(1)] = true
	for slot_name: String in set_names:
		TestUtil.check(GpuLayout.P_SLOTS.has(slot_name), "gpu_sim.gd sets P slot %s, which GpuLayout.P_SLOTS does not have" % slot_name)
		if GpuLayout.P_SLOTS.has(slot_name):
			TestUtil.check(GpuLayout.P_SLOTS[slot_name][1] in ["dish", "batch"], "gpu_sim.gd sets P slot %s by hand, but its kind is %s (set from SimConstants)" % [slot_name, GpuLayout.P_SLOTS[slot_name][1]])
	for slot_name: String in GpuLayout.P_SLOTS:
		if GpuLayout.P_SLOTS[slot_name][1] in ["dish", "batch"]:
			TestUtil.check(set_names.has(slot_name), "P slot %s (kind %s) is never set in gpu_sim.gd" % [slot_name, GpuLayout.P_SLOTS[slot_name][1]])
	TestUtil.check(not RegEx.create_from_string("\\b_?p\\[\\d").search(text), "gpu_sim.gd sets a slot of P by number")


func _kernels() -> void:
	var names := GpuKernels.layout_names()
	var numbered := RegEx.create_from_string("\\b(P|CNT|PCNT)\\[\\d|\\* 28u\\b|\\* 7u\\b")
	var token := RegEx.create_from_string("\\b(" + "|".join(PREFIXES) + ")[A-Z0-9_]+\\b")
	var all := GpuKernels.all()
	var used := {}
	for kernel_name: String in all:
		var source: String = all[kernel_name]["source"]
		var raw := numbered.search(source)
		TestUtil.check(raw == null, "kernel %s: %s by number (use gpu/gpu_layout.gd's names)" % [kernel_name, raw.get_string() if raw != null else ""])
		for m in token.search_all(source):
			var name := m.get_string()
			used[name] = true
			TestUtil.check(names.has(name), "kernel %s: %s is not in gpu/gpu_layout.gd" % [kernel_name, name])
	for name: String in ["P_DELTA", "R_MASS", "CNT_BUPS", "EB_MUTATOR", "ED_BIRTH_MASS", "Q_TRACK_FIRST", "QO_NEAR_MORE", "ST_DIVISIONS"]:
		TestUtil.check(used.has(name), "no kernel uses %s: the declarations are not reaching the kernels" % name)


## Two bups as records built from the table's names: the first with a picture and a chemotaxis memory, the second with neither.
func _record_word_by_word() -> void:
	var id := (7 << 32) + 12345
	var words := {
		L.R_X: 101.5, L.R_Y: -202.25, L.R_DX: 0.6, L.R_DY: 0.8, L.R_ENERGY: 33.0, L.R_MASS: 2.5, L.R_BIRTH_MASS: 1.75,
		L.R_SPEED: 21.0, L.R_SENSE: 55.0, L.R_METABOLISM: 1.25, L.R_SIZE: 4.5, L.R_REACH: 313.0, L.R_MUTATOR: 3.0, L.R_DONOR: 1.0,
		L.R_HARM: 0.125, L.R_HUE: 0.4, L.R_SAT: 0.6, L.R_VAL: 0.9, L.R_MUTATIONS: 17.0, L.R_DIVISIONS: 9.0,
		L.R_PX: 50.0, L.R_PY: 60.0, L.R_FAST: 0.3, L.R_SLOW: 0.2, L.R_NOISE: -0.5, L.R_TUMBLING: 0.05,
	}
	var state := PackedByteArray()
	state.resize(2 * GpuLayout.RECORD_BYTES)
	for w: int in words:
		state.encode_float(w * 4, words[w])
	GpuLayout.set_id(state, 0, id)
	var second := GpuLayout.RECORD_BYTES
	for w: int in words:
		state.encode_float(second + w * 4, words[w])
	state.encode_float(second + L.R_X * 4, -30.0)
	state.encode_float(second + L.R_PX * 4, 1e31)  # (no picture)
	state.encode_float(second + L.R_PY * 4, 1e31)
	state.encode_float(second + L.R_FAST * 4, -5.0)  # (no signal read yet)
	GpuLayout.set_id(state, 1, id + 1)
	var sim := BupSim.new()
	sim.reset(1000.0, 3)
	sim.import_state_bytes(state)
	var info := sim.bup_info(id)
	var f := func(w: int) -> float: return state.decode_float(w * 4)  # (each as the 32-bit float the record holds)
	var expected := {
		"id": id, "pos": Vector2(f.call(L.R_X), f.call(L.R_Y)), "dir": Vector2(f.call(L.R_DX), f.call(L.R_DY)), "energy": f.call(L.R_ENERGY),
		"mass": f.call(L.R_MASS), "birth_mass": f.call(L.R_BIRTH_MASS), "speed": f.call(L.R_SPEED), "sense": f.call(L.R_SENSE),
		"metabolism": f.call(L.R_METABOLISM), "size_gene": f.call(L.R_SIZE), "reach": 313, "mutator": f.call(L.R_MUTATOR), "donor": true,
		"harm": f.call(L.R_HARM), "hue": f.call(L.R_HUE), "sat": f.call(L.R_SAT), "val": f.call(L.R_VAL), "mutations": 17, "divisions": 9,
	}
	for key: String in expected:
		TestUtil.check(info.get(key) == expected[key], "import_state_bytes: bup_info's %s is %s, the record's word says %s" % [key, str(info.get(key)), str(expected[key])])
	var back := sim.export_state_bytes()
	TestUtil.check(back.size() == state.size(), "export_state_bytes gives the two records back")
	if back.size() != state.size():
		return
	var constants: Dictionary = (load("res://gpu/gpu_layout.gd") as Script).get_script_constant_map()
	var record_names := _named(constants, "R_")
	for name: String in record_names:
		var w: int = record_names[name]
		TestUtil.check(back.decode_u32(w * 4) == state.decode_u32(w * 4), "export_state_bytes: %s (word %d) of the first bup is %s, not the %s it was given" % [name, w, back.decode_float(w * 4), state.decode_float(w * 4)])
	TestUtil.check(GpuLayout.id_of(back, 1) == id + 1, "the second bup's id comes back in R_ID_LO and R_ID_HI")
	var none: float = PackedFloat32Array([GpuLayout.NO_PICTURE])[0]  # (as a 32-bit float)
	TestUtil.check(back.decode_float(second + L.R_PX * 4) == none and back.decode_float(second + L.R_PY * 4) == none, "a bup with no picture comes back with NO_PICTURE in R_PX and R_PY (got %s)" % back.decode_float(second + L.R_PX * 4))
	TestUtil.check(back.decode_float(second + L.R_FAST * 4) == -1.0, "a bup that has read no signal comes back with -1 in R_FAST (got %s)" % back.decode_float(second + L.R_FAST * 4))
	TestUtil.check(back.decode_float(second + L.R_X * 4) == -30.0, "the second bup keeps its own R_X")
	sim.render_buffer(1.0, 8)  # (both are drawn: each notes where it was)
	var drawn := sim.export_state_bytes()
	TestUtil.check(drawn.decode_float(L.R_PX * 4) == f.call(L.R_X) and drawn.decode_float(L.R_PY * 4) == f.call(L.R_Y), "a picture puts the bup's R_X and R_Y in its R_PX and R_PY")
	TestUtil.check(drawn.decode_float(second + L.R_PX * 4) == -30.0, "the second bup, drawn, has its place in R_PX")
