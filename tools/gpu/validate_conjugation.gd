extends SceneTree
## godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/validate_conjugation.gd -- N [gap_um size]
## The GPU's conjugation against the CPU's `conjugate`: N pairs, a donor and a bup `gap_um` from it (default 1; not swimming, so that the GPU's step keeps them touching), the pairs far apart, the rate so high that every
## touching pair transfers in the one step. What the recipients end up with (the share that took the first gene, and the run lengths) from each,
## and that a bup that is not touching a donor, and a donor, are left as they were. With `size`, both bups of a pair have that size gene and are near
## dividing, so that big bodies (a pair touching across more than the GPU's 20 µm cells: size 12 with a gap of 28) can be checked.
const DONOR := {"speed": 0.001, "sense": 100.0, "metabolism": 1.5, "size": 6.0}
const PLAIN := {"speed": 0.0, "sense": 40.0, "metabolism": 0.5, "size": 3.0}


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var n := int(args[0])
	var gap := float(args[1]) if args.size() > 1 else 1.0
	var size := float(args[2]) if args.size() > 2 else 0.0
	SimConstants.apply()
	var consts := SimConstants.build()
	consts["conj_rate"] = 1000.0
	BupSim.configure(consts)  # (after apply: the dish's creation would not undo it)
	var dish := Dish.new()
	root.add_child(dish)
	dish.set_seed(1)
	var sc := StartConditions.new()
	sc.bups = 4; sc.bup_limit = 4 * n + 1000; sc.dish_radius = 10000.0
	sc.spread_founders()
	dish.strike(sc)
	dish.stationary_phase = false
	dish.clear_bups()
	var side := int(ceil(sqrt(float(n))))
	var template: PackedFloat32Array = PackedFloat32Array()
	# --- the CPU
	var donor_genome := Genome.founder()
	donor_genome.merge(DONOR, true)
	donor_genome["donor"] = true
	var plain_genome := Genome.founder()
	plain_genome.merge(PLAIN, true)
	var mass := 5.0
	var birth := 5.0
	if size > 0.0:
		donor_genome["size"] = size
		plain_genome["size"] = size
		mass = 1.2 * size * size  # (a little short of the division mass, birth + 0.5 x size²)
		birth = 0.8 * size * size
	var spacing := maxf(60.0, 3.0 * (gap + mass * Cell.MASS_UM))  # (far enough that a recipient touches no other pair's donor)
	var ids := []
	for k in n:
		var at := Vector2(-4500.0 + spacing * (k % side), -4500.0 + spacing * (k / side))
		dish.sim.add_bup(at, donor_genome, 50.0, sqrt(mass), birth, 0, Vector2.RIGHT)
		ids.append(dish.sim.add_bup(at + Vector2(gap, 0.0), plain_genome, 50.0, sqrt(mass), birth, 0, Vector2.RIGHT))
	var alone := dish.sim.add_bup(Vector2(4900.0, 4900.0), plain_genome, 50.0, sqrt(5.0), 5.0, 0, Vector2.RIGHT)
	var state: PackedFloat32Array = dish.sim.export_state_bytes().to_float32_array()  # (the records the GPU starts from: the same bups)
	dish.sim.conjugate(0.1)
	var cpu := _tally(dish.sim.export_state_bytes().to_float32_array(), state, n)
	# --- the GPU, from the same records
	var gpu := GpuSim.new()
	var field := dish.field
	var zero := PackedFloat32Array(); zero.resize(field.get_size() * field.get_size())
	var c2 := consts.duplicate()
	c2["uptake_per_size"] = 0.0; c2["death_rate"] = 0.0; c2["growth_rate"] = 0.0; c2["donor_gain"] = 0.0; c2["donor_loss"] = 0.0
	var records := state.to_byte_array()
	var count := state.size() / GpuLayout.RECORD_WORDS
	for i in count:
		GpuLayout.set_id(records, i, i + 1)
	var loaded := GpuSim.State.of_grid(field, dish.radius, records, c2)
	loaded.conc = zero
	loaded.limit = count * 2
	loaded.next_id = count + 1
	gpu.load_state(loaded)
	gpu.run_steps(1)
	var out := gpu.read_bups().to_float32_array()
	var gtally := _tally_by_id(gpu.read_bups(), out, state, n)
	print("pairs %d: transferred   GPU %.4f  CPU %.4f" % [n, gtally[0], cpu[0]])
	for g in 4:
		print("  gene %d taken:        GPU %.4f  CPU %.4f   (expected %.4f)" % [g, gtally[1 + g], cpu[1 + g], pow(0.5, g)])
	print("  untouched changed:    GPU %d  CPU %d    donors changed: GPU %d  CPU %d" % [gtally[5], cpu[5], gtally[6], cpu[6]])
	var z: float = (float(gtally[2]) - float(cpu[2])) / sqrt(0.25 / n * 2.0)
	print("Z second gene: %+.2f s.e." % z)
	quit(0)


## Per recipient (the second bup of each pair, in the CPU's order: donor, recipient, donor, recipient, ..., the lone one last).
func _tally(now: PackedFloat32Array, start: PackedFloat32Array, n: int) -> Array:
	var s := GpuLayout.RECORD_WORDS
	var taken := [0, 0, 0, 0]
	var changed_lone := 0
	var changed_donors := 0
	for k in n:
		var d := (2 * k) * s
		var r := (2 * k + 1) * s
		for g in 4:
			taken[g] += 1 if now[r + 8 + g] == start[d + 8 + g] else 0
		if now[d + 8] != start[d + 8]:
			changed_donors += 1
	var lone := 2 * n * s
	for g in 4:
		changed_lone += 1 if now[lone + 8 + g] != start[lone + 8 + g] else 0
	return [float(taken[0]) / n, float(taken[0]) / n, float(taken[1]) / n, float(taken[2]) / n, float(taken[3]) / n, changed_lone, changed_donors]


## The GPU's bups are not in the CPU's order after a step (the ids are): find each by its id (1-based, the order of the records).
func _tally_by_id(raw: PackedByteArray, out: PackedFloat32Array, start: PackedFloat32Array, n: int) -> Array:
	var s := GpuLayout.RECORD_WORDS
	var by_id := {}
	for i in out.size() / s:
		by_id[GpuLayout.id_of(raw, i)] = i
	var now := PackedFloat32Array()
	now.resize(start.size())
	for k in start.size() / s:
		var i: int = by_id.get(k + 1, -1)
		if i < 0:
			continue
		for w in s:
			now[k * s + w] = out[i * s + w]
	return _tally(now, start, n)
