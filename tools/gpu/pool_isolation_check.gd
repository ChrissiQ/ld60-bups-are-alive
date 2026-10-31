extends SceneTree
## The pooled field, cloud and husk kernels: a dish among others equals the dish alone, whatever the others, their order, their rows,
## and dishes joining and leaving (a test at the level of these kernels: life is tools/gpu/pool_rig.gd's fake one, so the
## bups swim, eat and give back their deaths every step but do not divide); the whole-bin cut of the cloud lists against a reference
## worked out on the host; puffs_at_d against a double-precision sum; the husks' spawn, leak and cull against the CPU's rules
## (native/src/bup_husks.cpp).
## Run: tools/run_windowed.sh <out> -- --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/pool_isolation_check.gd
##
## Expected, written before the first run:
## I1 Four dishes (A: 3 mm, stationary, acetate, a third of the bups with the acetate key; B: 10 mm, death and plankton husks, the husk
##    quota 400, no acetate flag; C: 45 mm at 200 cells across, a cloud quota of 300; D: 1 mm, the most diffusion passes, death husks)
##    each alone and in three pools (rows 0-3 in order; reversed
##    with a fifth dish E between them at rows 7, 1000, 3, 512, 0; shuffled at rows 2, 5, 9, 1, 4 with E leaving at step 100 and a dish F
##    joining at step 150), 300 steps of 120 s with 8% of the bups dying a step (a quarter of them trimmed): every dish's records, cells,
##    clouds and husks in order, cloud lists and counters equal its run alone, bit for bit, at steps 16, 48, 120 and 300 (F: after its
##    own 150 steps). No overflow flag. [derived: every pooled kernel reads a dish's own words, cells, bins and clouds, its random
##    streams are keyed by its own step and places, appends keep each dish's order, and its virtual counters move only with its own
##    appends; P's slots of a dish hold POISON in a pool, so a kernel that still read one would differ]
##    The paths are exercised: C's DS_CLOUDS_TO_GRID > 0, B's DS_HUSKS reaches its quota of 400, D has more diffusion passes than the rest.
## I2 Whole-bin cut: with C's quota set to cut its lists halfway, the first bin whose end (from the dish's first entry) passes 12 x quota
##    and every bin after it have no entries, every bin before it keeps all its entries in ascending cloud order, DS_ENTRIES_CUT grows by
##    the entries dropped, alone and in a pool alike [derived: the kernel's rule]. With the pool's entries made to end inside the last
##    dish's last listed bin (and its quota not binding), that bin and those after it are cut and the overflow flag is raised (the host
##    then grows the entries); the dishes before it are not cut.
## I3 puffs_at_d (pool_probe) at 400 points of each dish (inside, on bin edges, beyond the rim) equals the dish alone bit for bit, and a
##    sum over the dish's live clouds in double precision within 2e-5 of the sum of the terms' sizes, plus the terms of clouds whose
##    reach the point is within 1e-5 of (which float rounding may take or leave) [derived: float32 sums of exp() terms of relative error
##    about 1e-6 each].
## I4 Husks (one dish of 10 mm, death husks, deaths at steps 0 and 60 only, 120 s steps): a husk for each death that gives back, holding
##    P_DEATH_GIVE x its mass bit for bit, at its place, in rank order; a trimmed death leaves an empty slot; piece k leaks once the
##    age reaches (k + 0.5) x 2700 s (age exact: multiples of 120 in float32), its mass the husk's energy x the share of piece k within
##    1e-6, as a cloud of variance 100 and cut 1 at the husk; the twelve shares sum to 1; a cull at step 280 keeps the second cohort
##    alone, in its order, and DS_HUSKS (virtual) is not changed by the cull but counts the live husks at the dish's next cadence. With the husk quota full, a death gives back a cloud, and a plankton husk event gives
##    a cloud where the dish accepts one and nothing in the slots where it does not.

const Rig := preload("res://tools/gpu/pool_rig.gd")

var fails := 0
var specs := {}


func ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		fails += 1


func _iterations(st: GpuSim.State) -> int:
	return maxi(2, 2 * ceili(st.diffusion * 120.0 / (st.spacing * st.spacing) / 0.4))


## A dish's events of its own step `s`: `per_step` clouds (a share of them with cut 0.001), with plankton husks a plankton husk event
## every third step, and two deposits.
func events_for(d: Dictionary, s: int) -> Dictionary:
	var st: GpuSim.State = d["state"]
	var rng := RandomNumberGenerator.new()
	rng.seed = d["seed"] * 1000003 + s
	var puffs := PackedFloat32Array()
	for k in int(d.get("per_step", 2)):
		var c := Rig.random_cloud(rng, st.radius, st.spacing, 1.0 if rng.randf() < 0.6 else 0.001, st.constants)
		puffs.append_array(c)
		puffs.append(0.0)
	if d["flags"] & (1 << GpuLayout.DPF_PLANKTON_HUSKS) and s % 3 == 0:
		var c := Rig.random_cloud(rng, st.radius, st.spacing, 1.0, st.constants)
		c[4] = -1.0
		puffs.append_array(c)
		puffs.append(0.0)
	var n := st.cells_across
	var cells := PackedInt32Array()
	var amounts := PackedFloat32Array()
	for k in 2:
		var c := rng.randi_range(0, n * n - 1)
		if st.owner[c] == c:
			cells.append(c)
			amounts.append(rng.randf() * 0.001)
	return {"puffs": puffs, "cells": cells, "amounts": amounts}


func spec(name: String, row: int, running := true) -> Dictionary:
	var s: Dictionary = specs[name].duplicate()
	s["row"] = row
	s["running"] = running
	return s


func new_rig(list: Array, poison: bool) -> Rig:
	var rig := Rig.new()
	rig.make_kernels()
	ok(rig.errors.is_empty(), "kernels load: %s" % [rig.errors])
	rig.build(list, {"poison": poison, "delta": 120.0})
	return rig


func run(rig: Rig, steps: int) -> void:
	var left := steps
	while left > 0:
		var k := mini(left, 8)
		rig.run_fake_steps(k, events_for, 0.08, 0.25, 32)
		left -= k


## Dish i of the rig joins now: its blocks, cells and row run, its clouds go on top of the pool's.
func join(rig: Rig, i: int) -> void:
	var d: Dictionary = rig.dishes[i]
	d["flags"] |= 1 << GpuLayout.DPF_RUNNING
	rig.upload_dishp()
	var blk := rig.read("BLKDISH").to_int32_array()
	for b in d["seg"] / GpuLayout.BLK_SLOTS:
		blk[d["start"] / GpuLayout.BLK_SLOTS + b] = d["row"]
	var bb := blk.to_byte_array()
	rig.rd.buffer_update(rig.bufs["BLKDISH"], 0, bb.size(), bb)
	var cd := PackedInt32Array()
	cd.resize(d["n"] * d["n"])
	cd.fill(d["row"])
	var cb := cd.to_byte_array()
	rig.rd.buffer_update(rig.bufs["CELLDISH"], d["base"] * 4, cb.size(), cb)
	var clouds := Rig._clouds_of(d["state"])
	var top := rig.word("WORLD", GpuLayout.WD_CLOUD_SLOTS)
	var pf := PackedFloat32Array()
	for k in clouds.size() / 5:
		pf.append_array(clouds.slice(k * 5, k * 5 + 5))
		pf.append_array(PackedFloat32Array([Rig.row_word(d["row"]), 0.0, 0.0]))
	if pf.size() > 0:
		var pb := pf.to_byte_array()
		rig.rd.buffer_update(rig.bufs["PUFF"], top * 32, pb.size(), pb)
	var w := PackedByteArray()
	w.resize(4)
	w.encode_u32(0, top + clouds.size() / 5)
	rig.rd.buffer_update(rig.bufs["WORLD"], GpuLayout.WD_CLOUD_SLOTS * 4, 4, w)
	w.encode_u32(0, clouds.size() / 5)
	rig.rd.buffer_update(rig.bufs["DSTATE"], (d["row"] * GpuLayout.DS_WORDS + GpuLayout.DS_CLOUD_SLOTS) * 4, 4, w)


## Dish i of the rig leaves now (a freeze or a trash): its row stops, its blocks and cells are no dish's, its clouds and husks are gone.
func leave(rig: Rig, i: int) -> void:
	var d: Dictionary = rig.dishes[i]
	d["flags"] &= ~(1 << GpuLayout.DPF_RUNNING)
	rig.upload_dishp()
	var blk := rig.read("BLKDISH").to_int32_array()
	for b in d["seg"] / GpuLayout.BLK_SLOTS:
		blk[d["start"] / GpuLayout.BLK_SLOTS + b] = -1
	var bb := blk.to_byte_array()
	rig.rd.buffer_update(rig.bufs["BLKDISH"], 0, bb.size(), bb)
	var cd := PackedInt32Array()
	cd.resize(d["n"] * d["n"])
	cd.fill(-1)
	var cb := cd.to_byte_array()
	rig.rd.buffer_update(rig.bufs["CELLDISH"], d["base"] * 4, cb.size(), cb)
	var want := Rig.row_word(d["row"])
	for pair in [["PUFF", GpuLayout.WD_CLOUD_SLOTS], ["HUSK", GpuLayout.WD_HUSK_SLOTS]]:
		var top := rig.word("WORLD", pair[1])
		if top == 0:
			continue
		var raw := rig.read(pair[0], 0, top * 32).to_float32_array()
		for k in top:
			if raw[k * 8 + 5] == want:
				raw[k * 8 + 5] = 0.0
				raw[k * 8 + 6] = 0.0 if pair[0] == "HUSK" else raw[k * 8 + 6]
		var rb := raw.to_byte_array()
		rig.rd.buffer_update(rig.bufs[pair[0]], 0, rb.size(), rb)


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()
	var sc_a := StartConditions.new()
	sc_a.bups = 8; sc_a.dish_radius = 3000.0; sc_a.nutrient_density = 32.0; sc_a.feed_density = 5.0; sc_a.stationary_phase = true
	var sc_b := StartConditions.new()
	sc_b.bups = 8; sc_b.dish_radius = 10000.0; sc_b.nutrient_density = 8.0; sc_b.bloom_density = 0.5
	var sc_c := StartConditions.new()
	sc_c.bups = 8; sc_c.dish_radius = 45000.0; sc_c.nutrient_density = 4.0; sc_c.nutrient_resolution = 200
	var sc_d := StartConditions.new()
	sc_d.bups = 8; sc_d.dish_radius = 1000.0; sc_d.nutrient_density = 32.0; sc_d.feed_density = 20.0
	var sc_e := StartConditions.new()
	sc_e.bups = 8; sc_e.dish_radius = 20000.0; sc_e.nutrient_density = 16.0; sc_e.nutrient_resolution = 150; sc_e.feed_density = 2.0
	var dpf := func(names: Array) -> int:
		var v := 0
		for nm: int in names:
			v |= 1 << nm
		return v
	specs["A"] = {"state": Rig.make_state(self, sc_a, 11, 3000, 0.33, 200), "flags": dpf.call([GpuLayout.DPF_STATIONARY, GpuLayout.DPF_ACETATE]), "per_step": 2}
	specs["B"] = {"state": Rig.make_state(self, sc_b, 12, 2000, 0.0, 300), "flags": dpf.call([GpuLayout.DPF_DEATH_HUSKS, GpuLayout.DPF_PLANKTON_HUSKS]), "husk_quota": 400, "per_step": 3}
	specs["C"] = {"state": Rig.make_state(self, sc_c, 13, 4000, 0.1, 400), "flags": dpf.call([GpuLayout.DPF_ACETATE]), "cloud_quota": 300, "per_step": 6}
	specs["D"] = {"state": Rig.make_state(self, sc_d, 14, 500, 0.5, 20), "flags": dpf.call([GpuLayout.DPF_ACETATE, GpuLayout.DPF_DEATH_HUSKS]), "per_step": 1}
	specs["E"] = {"state": Rig.make_state(self, sc_e, 15, 3000, 0.2, 500), "flags": dpf.call([GpuLayout.DPF_ACETATE, GpuLayout.DPF_DEATH_HUSKS, GpuLayout.DPF_PLANKTON_HUSKS, GpuLayout.DPF_STATIONARY]), "per_step": 8}
	specs["F"] = {"state": Rig.make_state(self, sc_a, 16, 1500, 0.0, 50), "flags": dpf.call([GpuLayout.DPF_ACETATE, GpuLayout.DPF_DEATH_HUSKS]), "per_step": 2}
	for nm: String in specs:
		var st: GpuSim.State = specs[nm]["state"]
		print("dish %s: %d cells across, spacing %.2f µm, %d bups, %d clouds" % [nm, st.cells_across, st.spacing, st.bups.size() / GpuLayout.RECORD_BYTES, st.clouds.size() / 5])
	var checkpoints := [16, 48, 120, 300]
	# the dishes alone
	var alone := {}
	for nm: String in ["A", "B", "C", "D"]:
		var rig := new_rig([spec(nm, 0)], false)
		alone[nm] = {}
		var at := 0
		for cp: int in checkpoints:
			run(rig, cp - at)
			at = cp
			alone[nm][cp] = rig.dump(0)
		alone[nm]["probe"] = probe_dish(rig, 0)
		alone[nm]["cut"] = cut_check(rig, nm, "alone")
		var cs: PackedInt32Array = alone[nm][300]["counters"]
		print("dish %s alone: clouds to grid %d, entries cut %d, husks %d, cloud slots %d, overflow %d" % [nm, cs[4], cs[5], cs[6], cs[3], cs[7]])
		if nm == "C":
			ok(cs[4] > 0, "I1 C's cloud quota binds (clouds to grid %d)" % cs[4])
		if nm == "B":
			ok(cs[6] == 400, "I1 B's husk quota of 400 is reached (husks now %d)" % cs[6])
		if nm == "D":
			var most := 0
			for other: String in ["A", "B", "C"]:
				most = maxi(most, _iterations(specs[other]["state"]))
			ok(_iterations(specs["D"]["state"]) > most, "I1 D needs the most diffusion passes (%d against %d)" % [_iterations(specs["D"]["state"]), most])
		rig.release()
	var f_alone := new_rig([spec("F", 0)], false)
	run(f_alone, 150)
	var f_dump := f_alone.dump(0)
	f_alone.release()
	# pool 1: in order
	var pools := [
		{"name": "in order", "list": [spec("A", 0), spec("B", 1), spec("C", 2), spec("D", 3)]},
		{"name": "reversed with E", "list": [spec("D", 7), spec("E", 1000), spec("C", 3), spec("B", 512), spec("A", 0)]},
		{"name": "shuffled, E leaves at 100, F joins at 150", "list": [spec("B", 2), spec("A", 5), spec("E", 9), spec("D", 1), spec("C", 4), spec("F", 6, false)]},
	]
	for pool: Dictionary in pools:
		var list: Array = pool["list"]
		var rig := new_rig(list, true)
		var names := []
		for s: Dictionary in list:
			for nm: String in specs:
				if specs[nm]["state"] == s["state"]:
					names.append(nm)
		var at := 0
		var moves: bool = names.has("F")
		var stops := checkpoints.duplicate() + ([100, 150] if moves else [])
		stops.sort()
		for stop: int in stops:
			if moves and at == 100:
				leave(rig, names.find("E"))
			if moves and at == 150:
				join(rig, names.find("F"))
			run(rig, stop - at)
			at = stop
			if not checkpoints.has(stop):
				continue
			var cp := stop
			for i in names.size():
				if not alone.has(names[i]):
					continue
				var line := Rig.diff(alone[names[i]][cp], rig.dump(i))
				ok(line == "", "I1 %s equals alone at step %d, pool %s%s" % [names[i], cp, pool["name"], ": " + line if line != "" else ""])
		ok(rig.word("WORLD", GpuLayout.WD_OVERFLOW) == 0, "I1 no overflow, pool %s" % pool["name"])
		if names.has("F"):
			var line := Rig.diff(f_dump, rig.dump(names.find("F")))
			ok(line == "", "I1 F joined at step 150 equals F alone after 150 steps%s" % (": " + line if line != "" else ""))
		for i in names.size():
			if not alone.has(names[i]):
				continue
			var pr := probe_dish(rig, i)
			ok(pr["values"] == alone[names[i]]["probe"]["values"], "I3 puffs_at_d of %s equals alone, pool %s" % [names[i], pool["name"]])
			var cut := cut_check(rig, names[i], pool["name"])
			ok(cut == alone[names[i]]["cut"], "I2 the cut lists of %s equal alone, pool %s" % [names[i], pool["name"]])
		if pool["name"] == "in order":
			room_cut_check(rig)
		rig.release()
	husk_check()
	print("POOL ISOLATION CHECK %s (%.1f s)" % ["OK" if fails == 0 else "FAILED (%d)" % fails, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(0 if fails == 0 else 1)


## pool_probe at 400 points of dish i; checked against a double-precision sum over its clouds (I3); returns the floats for the
## comparison with the dish alone.
func probe_dish(rig: Rig, i: int) -> Dictionary:
	var d: Dictionary = rig.dishes[i]
	var st: GpuSim.State = d["state"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 77 + i * 0
	var pts := PackedFloat32Array()
	var bs: float = 0.5 * st.spacing
	for k in 400:
		var x: float
		var y: float
		if k % 4 == 3:  # a bin edge
			x = float(rng.randi_range(0, d["bins_across"] - 1)) * bs - st.radius
			y = rng.randf_range(-0.8, 0.8) * st.radius
		elif k % 10 == 9:  # beyond the rim
			var a := rng.randf() * TAU
			x = cos(a) * st.radius * 1.03
			y = sin(a) * st.radius * 1.03
		else:
			var a := rng.randf() * TAU
			var r := st.radius * 0.9 * sqrt(rng.randf())
			x = r * cos(a)
			y = r * sin(a)
		pts.append(x)
		pts.append(y)
	var qb := pts.to_byte_array()
	var zeros := PackedByteArray()
	zeros.resize(400 * 16)
	rig._buf("PQ", qb)
	rig._buf("PR", zeros)
	rig._sets.erase("pool_probe")
	var cl := rig.rd.compute_list_begin()
	rig.record_index(cl)  # (the lists of the clouds as they are now)
	rig.dispatch(cl, "pool_probe", 7, 400.0, float(d["row"]))
	rig.rd.compute_list_end()
	rig.rd.submit()
	rig.rd.sync()
	var got := rig.read("PR").to_float32_array()
	var clouds: PackedFloat32Array = rig.dump(i)["clouds"]
	var worst := 0.0
	var bad := 0
	for k in 400:
		var x := float(pts[k * 2])
		var y := float(pts[k * 2 + 1])
		var c := 0.0
		var size := 0.0
		var edge := 0.0
		for j in clouds.size() / 8:
			var o := j * 8
			var dx := x - clouds[o]
			var dy := y - clouds[o + 1]
			var r2 := dx * dx + dy * dy
			var reach2 := float(clouds[o + 6])
			var v := float(clouds[o + 3])
			var term := float(clouds[o + 2]) / (TAU * v) * exp(-r2 * 0.5 / v)
			if absf(r2 - reach2) <= 1e-5 * maxf(reach2, 1e-30):
				edge += term
			elif r2 <= reach2:
				c += term
				size += term
		var err := absf(float(got[k * 4]) - c)
		var tol := 2e-5 * size + edge + 1e-30
		if err > tol:
			bad += 1
		worst = maxf(worst, err / maxf(tol, 1e-30))
	ok(bad == 0, "I3 puffs_at_d of %s within the double sum's tolerance at 400 points (%d out; worst error / tolerance %.3f)" % [d["row"], bad, worst])
	return {"values": got}


## I2: C's lists cut halfway by its quota (DISHP set for the index only), checked against the host's rule. Returns the lists of the
## dish named `name` after the cut (for the comparison with the dish alone); the quotas are put back.
func cut_check(rig: Rig, name: String, pool_name: String) -> PackedInt32Array:
	var i := -1
	for k in rig.dishes.size():
		if rig.dishes[k]["state"] == specs[name]["state"]:
			i = k
	var d: Dictionary = rig.dishes[i]
	var nb: int = d["bins_across"] * d["bins_across"]
	var cl := rig.rd.compute_list_begin()
	rig.record_index(cl, false)
	rig.rd.compute_list_end()
	rig.rd.submit()
	rig.rd.sync()
	var binc := rig.read("BINC", d["bin_base"] * 4, nb * 4).to_int32_array()
	var bstart := rig.read("BINS", d["bin_base"] * 4, nb * 4).to_int32_array()
	var total := bstart[nb - 1] + binc[nb - 1] - bstart[0]
	if total < 2 * GpuKernelsClouds.ENTRIES_PER_SLOT:
		print("I2 %s (%s): %d entries, too few to cut" % [name, pool_name, total])
		return PackedInt32Array(binc)
	var saved_quota: int = d["cloud_quota"]
	var quota := maxi(1, total / 2 / GpuKernelsClouds.ENTRIES_PER_SLOT)
	var limit := quota * GpuKernelsClouds.ENTRIES_PER_SLOT
	var first_cut := nb
	for b in nb:
		if bstart[b] + binc[b] - bstart[0] > limit:
			first_cut = b
			break
	var dropped := 0
	for b in range(first_cut, nb):
		dropped += binc[b]
	var cut_before := rig.ds(d["row"], GpuLayout.DS_ENTRIES_CUT)
	d["cloud_quota"] = quota
	rig.upload_dishp()
	cl = rig.rd.compute_list_begin()
	rig.record_index_rest(cl)
	rig.rd.compute_list_end()
	rig.rd.submit()
	rig.rd.sync()
	d["cloud_quota"] = saved_quota
	rig.upload_dishp()
	var after := rig.read("BINC", d["bin_base"] * 4, nb * 4).to_int32_array()
	var ent := rig.read("ENT").to_int32_array() if total > 0 else PackedInt32Array()
	var kept_ok := true
	var sorted_ok := true
	for b in nb:
		var want := binc[b] if b < first_cut else 0
		if after[b] != want:
			kept_ok = false
		for e in range(bstart[b] + 1, bstart[b] + after[b]):
			if ent[e - 1] >= ent[e]:
				sorted_ok = false
	var grew := rig.ds(d["row"], GpuLayout.DS_ENTRIES_CUT) - cut_before
	ok(total > 0 and first_cut < nb, "I2 %s (%s): its lists (%d entries) are cut by a quota of %d at bin %d of %d" % [name, pool_name, total, quota, first_cut, nb])
	ok(kept_ok, "I2 %s (%s): the bins before the first that does not fit keep every entry, the rest none" % [name, pool_name])
	ok(sorted_ok, "I2 %s (%s): every kept list is in ascending cloud order" % [name, pool_name])
	ok(grew == dropped, "I2 %s (%s): DS_ENTRIES_CUT grew by the %d entries dropped (%d)" % [name, pool_name, dropped, grew])
	ok(rig.word("WORLD", GpuLayout.WD_OVERFLOW) == 0, "I2 %s (%s): a cut by the quota raises no overflow" % [name, pool_name])
	# the lists as they now stand: the counts, then each list's entries as places among the dish's own clouds
	var top := rig.word("WORLD", GpuLayout.WD_CLOUD_SLOTS)
	var raw := rig.read("PUFF", 0, maxi(top, 1) * 32).to_float32_array()
	var rank := {}
	var want_row := Rig.row_word(d["row"])
	for k in top:
		if raw[k * 8 + 5] == want_row:
			rank[k] = rank.size()
	var out := PackedInt32Array(after)
	for b in nb:
		for e in range(bstart[b], bstart[b] + after[b]):
			out.append(rank.get(ent[e], -1))
	return out


## I2's physical case: the pool's entries end inside the last dish's last listed bin.
func room_cut_check(rig: Rig) -> void:
	var cl := rig.rd.compute_list_begin()
	rig.record_index(cl, false)
	rig.rd.compute_list_end()
	rig.rd.submit()
	rig.rd.sync()
	var b := -1
	var li := rig.dishes.size()
	var last: Dictionary
	var nb := 0
	var binc := PackedInt32Array()
	var bstart := PackedInt32Array()
	while b < 0 and li > 0:  # the last dish with a listed bin that straddles a multiple of 12
		li -= 1
		last = rig.dishes[li]
		nb = last["bins_across"] * last["bins_across"]
		binc = rig.read("BINC", last["bin_base"] * 4, nb * 4).to_int32_array()
		bstart = rig.read("BINS", last["bin_base"] * 4, nb * 4).to_int32_array()
		for k in range(nb - 1, -1, -1):
			var lo := bstart[k]
			var hi := bstart[k] + binc[k]
			if binc[k] > 0 and (hi - 1) / GpuKernelsClouds.ENTRIES_PER_SLOT * GpuKernelsClouds.ENTRIES_PER_SLOT > lo:
				b = k
				break
	if b < 0:
		ok(false, "I2 room: no listed bin straddles a multiple of 12 (cannot set the case up)")
		return
	var cap := (bstart[b] + binc[b] - 1) / GpuKernelsClouds.ENTRIES_PER_SLOT
	var earlier := []
	for d: Dictionary in rig.dishes.slice(0, li):
		var m: int = d["bins_across"] * d["bins_across"]
		earlier.append(rig.read("BINC", d["bin_base"] * 4, m * 4))
	var w := PackedByteArray()
	w.resize(4)
	w.encode_u32(0, cap)
	rig.rd.buffer_update(rig.bufs["WORLD"], GpuLayout.WD_PUFF_CAPACITY * 4, 4, w)
	cl = rig.rd.compute_list_begin()
	rig.record_index_rest(cl)
	rig.rd.compute_list_end()
	rig.rd.submit()
	rig.rd.sync()
	var after := rig.read("BINC", last["bin_base"] * 4, nb * 4).to_int32_array()
	var good := true
	for k in nb:
		if after[k] != (binc[k] if k < b else 0):
			good = false
	ok(good, "I2 room: dish %d's bins from %d on are cut where the pool's %d entries end" % [li, b, cap * GpuKernelsClouds.ENTRIES_PER_SLOT])
	ok(rig.word("WORLD", GpuLayout.WD_OVERFLOW) == 1 and rig.ds(last["row"], GpuLayout.DS_OVERFLOW) == 1, "I2 room: the overflow flag is raised")
	var same := true
	for k in earlier.size():
		var d: Dictionary = rig.dishes[k]
		var m: int = d["bins_across"] * d["bins_across"]
		if rig.read("BINC", d["bin_base"] * 4, m * 4) != earlier[k]:
			same = false
	ok(same, "I2 room: the dishes before it are not cut")
	w.encode_u32(0, rig.puff_capacity)
	rig.rd.buffer_update(rig.bufs["WORLD"], GpuLayout.WD_PUFF_CAPACITY * 4, 4, w)
	w.encode_u32(0, 0)
	rig.rd.buffer_update(rig.bufs["WORLD"], GpuLayout.WD_OVERFLOW * 4, 4, w)


static func husk_share(k: int) -> float:
	var share := exp(-0.25 * k) - exp(-0.25 * (k + 1))
	return share + exp(-0.25 * 12) if k == 11 else share


static func pieces_at(age: float) -> int:
	var quarter := Biology.HUSK_SECONDS / 4.0
	var n := 0
	while n < 12 and age >= (n + 0.5) * quarter:
		n += 1
	return n


## I4.
func husk_check() -> void:
	var total := 0.0
	for k in 12:
		total += husk_share(k)
	ok(absf(total - 1.0) < 1e-12, "I4 the twelve shares sum to 1 (%.15f)" % total)
	var sc := StartConditions.new()
	sc.bups = 8; sc.dish_radius = 10000.0; sc.nutrient_density = 8.0
	var hs := {"state": Rig.make_state(self, sc, 21, 1500, 0.0, 0), "flags": (1 << GpuLayout.DPF_DEATH_HUSKS) | (1 << GpuLayout.DPF_ACETATE), "row": 3, "per_step": 0}
	var rig := new_rig([hs], true)
	var none := func(_d: Dictionary, _s: int) -> Dictionary: return {}
	var row := 3
	var give := float(rig.p[GpuLayout.p_slot("death_give")])
	var rb := GpuLayout.RECORD_BYTES
	var count: int = rig.dishes[0]["count"]
	# step 0: a fifth die
	rig.run_fake_steps(1, none, 0.2, 0.25, 0)
	var surv := rig.read("SURV", 0, count * 4).to_int32_array()
	var recs := rig.read("BUPS", 0, count * rb)
	var husks := rig.read("HUSK", 0, rig.word("WORLD", GpuLayout.WD_HUSK_SLOTS) * 32).to_float32_array()
	var rank := 0
	var spawn_ok := true
	var real := 0
	for i in count:
		if surv[i] != 0:
			continue
		var o := rank * 8
		var gives := recs.decode_float(i * rb + GpuLayout.R_PY * 4) == -2.0
		var mass := recs.decode_float(i * rb + GpuLayout.R_MASS * 4)
		var e := Rig.f32(Rig.f32(give) * mass)
		if husks[o] != recs.decode_float(i * rb + GpuLayout.R_X * 4) or husks[o + 1] != recs.decode_float(i * rb + GpuLayout.R_Y * 4) or husks[o + 2] != e:
			spawn_ok = false
		if (husks[o + 6] > 0.5) != gives or husks[o + 5] != Rig.row_word(row):
			spawn_ok = false
		real += 1 if gives else 0
		rank += 1
	ok(rank > 100 and husks.size() / 8 == rank, "I4 a husk slot for each of the %d deaths (%d slots)" % [rank, husks.size() / 8])
	ok(spawn_ok, "I4 each husk holds P_DEATH_GIVE x its mass at its place, alive only for a death that gives back (%d of %d)" % [real, rank])
	var first_cohort := husks.size() / 8
	# steps 1-59: no deaths; check the pieces each step against the CPU's rule, and the masses of the pieces
	var pieces_ok := true
	var mass_ok := true
	var worst := 0.0
	var deposited := 0
	for s in range(1, 60):
		var top_before := rig.word("WORLD", GpuLayout.WD_CLOUD_SLOTS)
		var before := rig.read("HUSK", 0, first_cohort * 32).to_float32_array()
		rig.run_fake_steps(1, none, 0.0, 0.0, 0)
		var after := rig.read("HUSK", 0, first_cohort * 32).to_float32_array()
		var top_after := rig.word("WORLD", GpuLayout.WD_CLOUD_SLOTS)
		var expected_due := 0
		var expected := PackedFloat32Array()
		for k in first_cohort:
			if before[k * 8 + 6] < 0.5:
				continue
			var age := float(after[k * 8 + 3])
			if age != float(s + 1) * 120.0:
				pieces_ok = false
			var want := pieces_at(age)
			if int(after[k * 8 + 4]) != want:
				pieces_ok = false
			for j in range(int(before[k * 8 + 4]), want):
				expected_due += 1
				expected.append_array(PackedFloat32Array([before[k * 8], before[k * 8 + 1], float(before[k * 8 + 2]) * husk_share(j)]))
		if (rig.world_step - 1) % 16 == 15:
			continue  # (the clouds were compacted this step: the pieces' slots moved)
		if expected_due > 0:
			var got := rig.read("PUFF", (top_after - expected_due) * 32, expected_due * 32).to_float32_array()
			for q in expected_due:
				var o := q * 8
				if got[o + 5] == 0.0:
					deposited += 1  # (a husk in a rim cell: its piece went onto the grid)
					continue
				var rel := absf(got[o + 2] - expected[q * 3 + 2]) / maxf(absf(expected[q * 3 + 2]), 1e-30)
				worst = maxf(worst, rel)
				if got[o] != expected[q * 3] or got[o + 1] != expected[q * 3 + 1] or rel > 1e-6 or got[o + 3] != 100.0 or got[o + 4] != 1.0 or got[o + 5] != Rig.row_word(row):
					mass_ok = false
			if top_after - top_before < expected_due:
				pieces_ok = false
	ok(pieces_ok, "I4 piece k leaks at the first step whose age reaches (k + 0.5) x %d s, ages exact" % int(Biology.HUSK_SECONDS / 4.0))
	ok(mass_ok, "I4 each piece is a cloud of variance 100, cut 1, at the husk, its mass the energy x its share (worst relative error %s; %d pieces of rim husks went onto the grid)" % [String.num_scientific(worst), deposited])
	# step 60: a second cohort; then on to step 280 and a cull: the first cohort (done at 259 steps) leaves, the second stays in order
	rig.run_fake_steps(1, none, 0.2, 0.25, 0)
	var htop := rig.word("WORLD", GpuLayout.WD_HUSK_SLOTS)
	var second := rig.read("HUSK", first_cohort * 32, (htop - first_cohort) * 32).to_float32_array()
	for s in range(61, 280, 20):
		rig.run_fake_steps(mini(20, 280 - s), none, 0.0, 0.0, 0)
	var pre := rig.read("HUSK", 0, htop * 32).to_float32_array()
	var first_done := true
	for k in first_cohort:
		if int(pre[k * 8 + 4]) != 12 and pre[k * 8 + 6] > 0.5:
			first_done = false
	var counted_before := rig.ds(row, GpuLayout.DS_HUSKS)
	var cl := rig.rd.compute_list_begin()
	rig.record_cull(cl)
	rig.rd.compute_list_end()
	rig.rd.submit()
	rig.rd.sync()
	var kept_expected := PackedFloat32Array()
	for k in range(first_cohort, htop):
		if pre[k * 8 + 6] > 0.5 and int(pre[k * 8 + 4]) < 12:
			kept_expected.append_array(pre.slice(k * 8, k * 8 + 8))
	var ntop := rig.word("WORLD", GpuLayout.WD_HUSK_SLOTS)
	var kept := rig.read("HUSK", 0, maxi(ntop, 1) * 32).to_float32_array().slice(0, ntop * 8)
	ok(first_done, "I4 by step 280 the first cohort has let all twelve pieces go")
	ok(ntop > 0 and kept == kept_expected, "I4 the cull keeps the %d live husks of the second cohort, in order, and only them (%d kept)" % [kept_expected.size() / 8, ntop])
	ok(rig.ds(row, GpuLayout.DS_HUSKS) == counted_before, "I4 DS_HUSKS is not changed by the cull (%d, %d)" % [counted_before, rig.ds(row, GpuLayout.DS_HUSKS)])
	rig.run_fake_steps(288 - rig.world_step, none, 0.0, 0.0, 0)  # (to the dish's next cadence, after its step 287)
	ok(rig.ds(row, GpuLayout.DS_HUSKS) == ntop, "I4 DS_HUSKS counts the live husks at the dish's cadence (%d of %d)" % [rig.ds(row, GpuLayout.DS_HUSKS), ntop])
	ok(second.size() > 0, "I4 the second cohort spawned (%d slots)" % (second.size() / 8))
	# the husk quota full: deaths give clouds; plankton husk events give a cloud where accepted, else none
	rig.dishes[0]["husk_quota"] = ntop
	rig.upload_dishp()
	var clouds_before: int = rig.dump(0)["clouds"].size() / 8
	var hst: GpuSim.State = rig.dishes[0]["state"]
	var r := hst.radius
	var rim := Vector2.ZERO
	for k in 3600:  # a point inside the radius in a cell whose centre is outside (the CPU's `accepts` refuses it)
		var a := k * TAU / 3600.0
		var pt := Vector2(cos(a), sin(a)) * r * 0.9999
		var cx := clampi(int((pt.x + r) / hst.spacing), 0, hst.cells_across - 1)
		var cy := clampi(int((pt.y + r) / hst.spacing), 0, hst.cells_across - 1)
		if hst.owner[cy * hst.cells_across + cx] != cy * hst.cells_across + cx:
			rim = Vector2(Rig.f32(pt.x), Rig.f32(pt.y))
			break
	ok(rim != Vector2.ZERO, "I4 found a rim point (%s)" % rim)
	var ev := func(_d: Dictionary, _s: int) -> Dictionary:
		return {"puffs": PackedFloat32Array([10.0, -20.0, 0.5, 100.0, -1.0, 0.0, rim.x, rim.y, 0.5, 100.0, -1.0, 0.0])}
	var husks_before := rig.word("WORLD", GpuLayout.WD_HUSK_SLOTS)
	rig.run_fake_steps(1, ev, 0.0, 0.0, 0)
	var clouds_now: PackedFloat32Array = rig.dump(0)["clouds"]
	var found_centre := false
	var found_rim := false
	for k in clouds_now.size() / 8:
		if clouds_now[k * 8] == 10.0 and clouds_now[k * 8 + 1] == -20.0 and clouds_now[k * 8 + 2] <= 0.5 and clouds_now[k * 8 + 4] == 1.0:
			found_centre = true
		if clouds_now[k * 8] == rim.x and clouds_now[k * 8 + 1] == rim.y:
			found_rim = true
	ok(rig.word("WORLD", GpuLayout.WD_HUSK_SLOTS) == husks_before, "I4 with the quota full a plankton husk makes no husk")
	ok(found_centre and not found_rim, "I4 ... it gives a cloud where the dish accepts one, none at the rim (%s, %s)" % [found_centre, found_rim])
	var before_deaths: int = rig.dump(0)["clouds"].size() / 8
	rig.run_fake_steps(1, none, 0.2, 0.0, 0)
	ok(rig.word("WORLD", GpuLayout.WD_HUSK_SLOTS) == husks_before and rig.dump(0)["clouds"].size() / 8 > before_deaths, "I4 with the quota full the deaths give clouds back (%d -> %d)" % [before_deaths, rig.dump(0)["clouds"].size() / 8])
	print("husk check: %d clouds before the quota test" % clouds_before)
	rig.release()
