class_name RecordCodec
extends RefCounted
## A bup's record (28 words, `GpuLayout.R_*`) as the dictionary `bup_info` gives, worked out in script: a port of
## the native record reader's rule. The pooled world has no native simulation to ask, so a
## pick's panel reads its answer from the record this way.
##
## What a record cannot say comes in as arguments: `born` (the family record's, 0 for a founder), `steering` (the chance of
## steering up the gradient at the bup's place: the probe's answer, `pool_probe_full`) and `upkeep_scale` (the dish's).
## `constants` is `SimConstants.build()`.

const SIZE_GENE_KEY := "size_gene"
const GENE_KEYS := ["speed", "sense", "metabolism", SIZE_GENE_KEY]


## A float as the 32-bit float the native code keeps it in.
static func f32(x: float) -> float:
	var a := PackedFloat32Array([x])
	return a[0]


static func id_of(records: PackedByteArray, index: int) -> int:
	var o := index * GpuLayout.RECORD_BYTES
	return records.decode_u32(o + GpuLayout.R_ID_LO * 4) | (records.decode_u32(o + GpuLayout.R_ID_HI * 4) << 32)


## What `bup_info` would say of the bup in record `index` of `records`; empty when there is no such record.
static func info_from_record(records: PackedByteArray, index: int, constants: Dictionary, born := 0, steering := 0.5, upkeep_scale := 1.0) -> Dictionary:
	if index < 0 or (index + 1) * GpuLayout.RECORD_BYTES > records.size():
		return {}
	var o := index * GpuLayout.RECORD_BYTES
	var w := func(word: int) -> float: return records.decode_float(o + word * 4)
	var mass: float = w.call(GpuLayout.R_MASS)
	var birth_mass: float = w.call(GpuLayout.R_BIRTH_MASS)
	var speed: float = w.call(GpuLayout.R_SPEED)
	var sense: float = w.call(GpuLayout.R_SENSE)
	var metabolism: float = w.call(GpuLayout.R_METABOLISM)
	var size_gene: float = w.call(GpuLayout.R_SIZE)
	var harm: float = w.call(GpuLayout.R_HARM)
	var add_mass := f32(constants["add_mass_factor"] * size_gene * size_gene)
	var drag_upkeep := f32(constants["drag_upkeep"] * speed * speed)
	var size := sqrt(mass)
	var sense_range: float = sense * sqrt(size / constants["reference_size"])
	var info := {}
	info["id"] = id_of(records, index)
	info["pos"] = Vector2(w.call(GpuLayout.R_X), w.call(GpuLayout.R_Y))
	info["dir"] = Vector2(w.call(GpuLayout.R_DX), w.call(GpuLayout.R_DY))
	info["energy"] = w.call(GpuLayout.R_ENERGY)
	info["max_energy"] = constants["reserve_per_mass"] * mass
	info["born"] = born
	info["mass"] = mass
	info["birth_mass"] = birth_mass
	info["div_mass"] = f32(birth_mass + add_mass)
	info["size"] = size
	info["length"] = mass * constants["mass_um"]
	info["divisions"] = int(w.call(GpuLayout.R_DIVISIONS))
	info["speed"] = speed
	info["sense"] = sense
	info["metabolism"] = metabolism
	info[SIZE_GENE_KEY] = size_gene
	info["hue"] = w.call(GpuLayout.R_HUE)
	info["sat"] = w.call(GpuLayout.R_SAT)
	info["val"] = w.call(GpuLayout.R_VAL)
	info["harm"] = harm
	info["mutator"] = w.call(GpuLayout.R_MUTATOR)
	info["donor"] = f32(w.call(GpuLayout.R_DONOR)) > 0.5
	info["reach"] = int(f32(w.call(GpuLayout.R_REACH) + 0.5))
	info["mutations"] = int(w.call(GpuLayout.R_MUTATIONS))
	info["upkeep"] = upkeep_scale * (constants["base_upkeep"] + constants["maintenance_per_mass"] * mass) + drag_upkeep * size + constants["sense_upkeep"] * sense
	info["sense_range"] = sense_range
	info["steering"] = steering
	return info
