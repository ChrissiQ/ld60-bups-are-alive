class_name DishSpec
extends RefCounted
## A new dish for `SimCore.add_dish`: its size, grid, limit, settings, seed and founders. Positions are dish-local (µm
## from the centre). The founders are whole records (GpuLayout.RECORD_BYTES each, from RecordCodec or a test's builder); the core writes
## them as the dish's first segment and gives them the world's next ids in founder order.

var number := 1  ## the dish's number (its name, and what a birth event carries); never reused in a game
var radius := 3000.0  ## µm
var resolution := StartConditions.MIN_NUTRIENT_RESOLUTION  ## the most cells across the nutrient grid (as StartConditions.nutrient_resolution)
var limit := StartConditions.DEFAULT_BUP_LIMIT
var seed := 0  ## the dish's random seed; 0: derived from the world's seed and the number
var step := 0  ## the dish's own step at the start (0 for a new dish)
var flags := 0  ## DP_FLAGS bits the dish asks for (GpuLayout.DPF_STATIONARY, DPF_DEATH_HUSKS, DPF_PLANKTON_HUSKS); the core adds its own
var nutrient_density := 32.0  ## units of nutrient in each mm² at the start (StartConditions.nutrient_density)
var feed_density := 0.0  ## units fed in to each mm² every hour (StartConditions.feed_density)
var bloom_density := 0.0  ## plankton in each mm² every sim-day: the dish's DishWorld's, which the core does not hold
var upkeep := 1.0  ## the upkeep factor
var medium_thickness := Biology.MEDIUM_THICKNESS  ## as StartConditions.medium_thickness: the medium's diffusion is the water's over this
var patch_seed := 0  ## the landscape of richer and poorer patches the nutrient follows; 0: derived from the seed
var patchiness := Dish.NUTRIENT_PATCHINESS
var noise_reference := -1.0  ## the dish's receptor-noise scale for chemotaxis (DP_NOISE_REFERENCE); under 0: the constants' (every game dish; the motion table's pseudo-dishes each set their own)
var cloud_quota := 262144  ## clouds the dish may hold (a lone dish's puff capacity)
var husk_quota := 200000  ## husks the dish may hold (MAX_HUSKS)
var founders := PackedByteArray()  ## the founders' records
var founder_names: Array[String] = []  ## the names the founders were given, in their order ("" for none): the simulation binds each to its founder's id when it adds the dish
var world := {}  ## what the dish's DishWorld starts with (plankton, sources), for the host that keeps it


## The medium's diffusion coefficient (µm²/s).
func diffusion() -> float:
	return Biology.WATER_DIFFUSION / medium_thickness


## The spec as plain data (a DishBlob keeps it).
func to_dict() -> Dictionary:
	return {
		"number": number, "radius": radius, "resolution": resolution, "limit": limit, "seed": seed, "step": step, "flags": flags,
		"nutrient_density": nutrient_density, "feed_density": feed_density, "bloom_density": bloom_density, "upkeep": upkeep,
		"medium_thickness": medium_thickness, "patch_seed": patch_seed, "patchiness": patchiness, "cloud_quota": cloud_quota,
		"husk_quota": husk_quota, "noise_reference": noise_reference,
	}


static func from_dict(d: Dictionary) -> DishSpec:
	var s := DishSpec.new()
	for k: String in d:
		s.set(k, d[k])
	return s


func copy() -> DishSpec:
	var s := DishSpec.from_dict(to_dict())
	s.founders = founders.duplicate()
	s.founder_names = founder_names.duplicate()
	s.world = world.duplicate(true)
	return s
