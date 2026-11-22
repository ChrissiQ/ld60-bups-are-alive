extends SceneTree
## Run: godot --headless --path . -s tests/sim_layout_test.gd
## The pooled world's word layouts (gpu/gpu_layout.gd), headless. Expected values:
##  - the record: 28 words, each of R_* named once (0-27), no word or constant naming a dish (a bup's dish is its segment);
##  - ids: one world-wide positive 63-bit number (ID_MAX 2^63 - 1), no dish in it; R_ID_HI is its high word; WORLD holds the next id (WD_NEXT_ID_LO/HI);
##  - an event's step word (ED_STEP, and a birth's EB_STEP): 13 low bits step, 19 high bits dish number, 13 + 19 = 32; MAX_STEPS_PER_BATCH (1024) fits in 13 bits;
##  - DISHP: 32 words = 128 B; DP_* name 23 distinct words 0-22 (9 spare, 23-31 unused); six DPF_* flags in 0-6 (bit 4 spare);
##    it names seed, step, k_total, iterations, cloud_spread, noise_reference and radius;
##  - DSTATE: 32 words; DS_* name 25 distinct words 0-24 (24-31 the energy ledger's four sums), including moved_in and moved_out;
##  - WORLD: 16 words, 13 named (the totals the kernels bound their loops by are uints there, not floats in P); payload: 4 words = 16 B, id texture 2 words = 8 B, colour bytes inside the fourth word above its spare low byte;
##  - STATS per dish: 16 words x (1 + 16) = 272 words;
##  - D_MAX 1,024 rows: DISHP + DSTATE = 1,024 x 256 B = 256 KB;
##  - no kernel reads a dish table by a number, and no layout name is also a kernel's buffer name.

const L := preload("res://gpu/gpu_layout.gd")


func _init() -> void:
	var constants: Dictionary = (load("res://gpu/gpu_layout.gd") as Script).get_script_constant_map()
	_record_has_no_dish(constants)
	_ids()
	_event_step()
	_table(constants, "DP_", 23, L.DP_WORDS, "DISHP")
	_table(constants, "DS_", 25, L.DS_WORDS, "DSTATE")
	_table(constants, "WD_", 18, L.WD_WORDS, "WORLD")
	_dishp(constants)
	_dstate()
	_payload()
	_sizes()
	_kernels(constants)
	TestUtil.finish(self, "SIM LAYOUT TEST OK")


## The words of the table `prefix`..., distinct, from 0, `named` of them, inside `size`.
func _table(constants: Dictionary, prefix: String, named: int, size: int, what: String) -> void:
	var seen := {}
	for name: String in constants:
		if name.begins_with(prefix) and not name.ends_with("_WORDS") and constants[name] is int:
			var w: int = constants[name]
			TestUtil.check(w >= 0 and w < size, "%s: %s is %d, outside its %d words" % [what, name, w, size])
			TestUtil.check(not seen.has(w), "%s: %s and %s are both word %d" % [what, name, seen.get(w, ""), w])
			seen[w] = name
	TestUtil.check(seen.size() == named, "%s: %d words named, expected %d" % [what, seen.size(), named])
	for w in named:
		TestUtil.check(seen.has(w), "%s: word %d has no name (the named words are 0-%d, the rest spare)" % [what, w, named - 1])


func _record_has_no_dish(constants: Dictionary) -> void:
	TestUtil.check(L.RECORD_WORDS == 28 and L.RECORD_VEC4 == 7 and L.RECORD_BYTES == 112, "the record stays 28 words, 112 bytes")
	var words := {}
	for name: String in constants:
		if name.begins_with("R_") and constants[name] is int:
			TestUtil.check(not words.has(constants[name]), "the record: %s and %s are one word" % [name, words.get(constants[name], "")])
			words[constants[name]] = name
			TestUtil.check(not name.contains("DISH"), "the record has a word for a dish (%s): a bup's dish is its segment" % name)
	TestUtil.check(words.size() == L.RECORD_WORDS, "the record: %d words named, not %d" % [words.size(), L.RECORD_WORDS])
	TestUtil.check(L.R_ID_LO == 0 and L.R_ID_HI == 21 and L.R_TUMBLING == 27, "the record's words are where they were")


func _ids() -> void:
	TestUtil.check(L.ID_MAX == (1 << 63) - 1 and L.ID_MAX > 0, "an id is a positive 63-bit number")
	TestUtil.check(L.WD_NEXT_ID_HI == L.WD_NEXT_ID_LO + 1, "WORLD holds the next id as two words")
	for id: int in [1, 2, 12345, 1 << 32, (1 << 32) + 7, (1 << 44) + 3, L.ID_MAX]:
		var records := PackedByteArray()
		records.resize(L.RECORD_BYTES)
		L.set_id(records, 0, id)
		TestUtil.check(L.id_of(records, 0) == id and records.decode_u32(L.R_ID_HI * 4) == (id >> 32) and records.decode_u32(L.R_ID_LO * 4) == (id & 0xFFFFFFFF), "the record's two id words are not the id %d" % id)


func _event_step() -> void:
	TestUtil.check(L.EV_STEP_BITS + L.EV_DISH_BITS == 32 and L.EV_DISH_SHIFT == L.EV_STEP_BITS, "ED_STEP: 13 bits of step, 19 of dish number")
	TestUtil.check(L.EV_STEP_MASK == (1 << L.EV_STEP_BITS) - 1 and L.EV_DISH_MASK == (1 << L.EV_DISH_BITS) - 1, "ED_STEP's masks")
	TestUtil.check(L.MAX_STEPS_PER_BATCH <= L.EV_STEP_MASK + 1, "a batch's steps fit ED_STEP's low bits")
	for pair: Array in [[0, 0], [1023, 524287], [5, 1], [L.EV_STEP_MASK, 123456]]:
		var word := L.event_step_word(pair[0], pair[1])
		TestUtil.check(word >= 0 and word <= 0xFFFFFFFF and L.event_step(word) == pair[0] and L.event_dish_number(word) == pair[1], "ED_STEP (%d, %d) does not read back" % pair)


func _dishp(constants: Dictionary) -> void:
	TestUtil.check(L.DP_WORDS * 4 == 128, "a DISHP row is 128 bytes")
	for name in ["DP_SEED", "DP_STEP", "DP_K_TOTAL", "DP_ITERATIONS", "DP_NOISE_REFERENCE", "DP_CLOUD_SPREAD", "DP_RADIUS", "DP_NUMBER", "DP_LIMIT", "DP_CAP", "DP_FLAGS"]:
		TestUtil.check(constants.has(name), "DISHP has no %s" % name)
	var bits := {}
	for name: String in constants:
		if name.begins_with("DPF_") and name != "DPF_COUNT":
			TestUtil.check(constants[name] >= 0 and constants[name] < 32 and not bits.has(constants[name]), "flag %s is a bit in use or outside the word" % name)
			bits[constants[name]] = name
	TestUtil.check(bits.size() == L.DPF_COUNT and L.DPF_COUNT == 6, "DISHP has six flags")


func _dstate() -> void:
	TestUtil.check(L.DS_WORDS * 4 == 128, "a DSTATE row is 128 bytes")
	TestUtil.check(L.D_MAX * (L.DP_WORDS + L.DS_WORDS) * 4 == 256 * 1024, "DISHP and DSTATE together are 256 KB")
	TestUtil.check(L.DS_MOVED_IN != L.DS_MOVED_OUT, "DSTATE has moved_in and moved_out apart")


func _payload() -> void:
	TestUtil.check(L.PL_WORDS == 4 and L.PAYLOAD_BYTES == 16 and L.IDT_WORDS == 2 and L.IDT_BYTES == 8, "the payload is 16 bytes a bup, its ids buffer 8")
	TestUtil.check(L.IDS_WORDS == 4 and L.IDS_BYTES == 16 and L.IDS_PREV_X == 2 and L.IDS_PREV_Y == 3, "the ids texture is the id then the place before, 16 bytes a bup")
	TestUtil.check(L.PV_WORDS == 2 and L.PV_BYTES == 8 and L.SH_WORDS == 4 and L.SH_ROW == 0 and L.SH_COUNT == 1, "the places before and a slot's header")
	TestUtil.check(L.PL_X == 0 and L.PL_Y == 1 and L.PL_SHAPE == 2 and L.PL_COLOR == 3 and L.IDT_LO == 0 and L.IDT_HI == 1, "payload words in order")
	TestUtil.check(L.PL_RED_SHIFT == 24 and L.PL_GREEN_SHIFT == 16 and L.PL_BLUE_SHIFT == 8, "the colour's three bytes sit above the spare low byte")
	TestUtil.check(L.PAYLOAD_TEX_WIDTH == 2048, "payload textures are 2048 wide")


func _sizes() -> void:
	TestUtil.check(L.ST_MASS == 12 and L.STATS_SUMS == 12, "a sample's sums are 12 words, the last the bups' mass (the births bound reads it)")
	TestUtil.check(L.STATS_DISH_WORDS == 272 and L.STATS_ITER_SAMPLES == 16, "a dish's STATS row is 17 samples of 16 words")
	TestUtil.check(L.D_MAX == 1024 and L.BLK_SLOTS == 1 << L.BLK_SHIFT and L.BLK_SLOTS == 256 and L.NO_DISH == 0xFFFFFFFF, "D_MAX, the block size and the no-dish value")
	TestUtil.check(L.PIPDST_WORDS == 1, "PIPDST is one uint a slot")


## No kernel reads a dish table with a number in its index, and no layout name is a kernel's buffer name (it would be declared twice).
func _kernels(constants: Dictionary) -> void:
	var numbered := RegEx.create_from_string("\\b(DISHP|DSTATE|WORLD|BLKDISH|PIPDST)(_[AB])?\\[[^\\]]*\\b\\d+u?\\b")
	var all := GpuKernels.all()
	var buffers := {}
	for kernel_name: String in all:
		var source: String = all[kernel_name]["source"]
		var raw := numbered.search(source)
		TestUtil.check(raw == null, "kernel %s: %s reads a dish table by a number (use gpu/gpu_layout.gd's names)" % [kernel_name, raw.get_string() if raw != null else ""])
		for b: String in all[kernel_name]["buffers"]:
			buffers[b] = true
	for name: String in constants:
		if constants[name] is int:
			TestUtil.check(not buffers.has(name), "layout name %s is also a kernel buffer" % name)
