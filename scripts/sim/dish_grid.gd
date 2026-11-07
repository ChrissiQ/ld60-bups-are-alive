class_name DishGrid
extends RefCounted
## A dish's nutrient grid as the host builds it for the pooled world: the host's part of the field's setup (build, the patchy landscape,
## fill, export_fill_weights) and of what turns the dish's world events into cells and clouds (accepts, deposit_xy, deposit_disc,
## add_cloud's choice). Arithmetic in doubles and stored as float32.

const MIN_CLOUD_VARIANCE := 100.0  ## µm²: no cloud is thinner than 10 µm across
const K_IX := -7046029254386353131  ## 0x9E3779B97F4A7C15 as a signed 64-bit int (GDScript ints wrap as a uint64 does)
const K_IY := -4417276706812531889  ## 0xC2B2AE3D27D4EB4F
const K_M1 := -4658895280553007687  ## 0xBF58476D1CE4E5B9
const K_M2 := -7723592293110705685  ## 0x94D049BB133111EB
const K_OCTAVE := -3335678366873096957  ## 0xD1B54A32D192ED03

var n := 0
var radius := 0.0
var spacing := 0.0
var inside := PackedInt32Array()  ## 1 for a cell whose centre is inside the dish
var owner := PackedInt32Array()  ## a cell's own index inside, the nearest inside cell's for a rim cell, -1 for none
var inside_count := 0
var weights := PackedFloat32Array()  ## what fill(1.0) adds to each cell (the feed's weights)
var _fill := PackedFloat64Array()  ## the landscape's weights before scaling (doubles)
var _fill_total := 0.0
var _amplitude := 0.0
var _patch_size := 1.0
var _patch_seed := 0


## The cells across a dish of `dish_radius` with `resolution` the most.
static func cells_across(dish_radius: float, resolution: int) -> int:
	var wanted := ceili(2.0 * dish_radius / Dish.FIELD_TARGET_SPACING)
	return clampi(wanted, Dish.FIELD_MIN_ACROSS, maxi(resolution, Dish.FIELD_MIN_ACROSS))


static func make(dish_radius: float, resolution: int, patchiness: float, patch_seed: int) -> DishGrid:
	var g := DishGrid.new()
	g._build(dish_radius, cells_across(dish_radius, resolution))
	g._amplitude = maxf(patchiness, 0.0)
	g._patch_size = maxf(dish_radius, 1.0)
	g._patch_seed = patch_seed
	g._make_weights()
	return g


func _build(dish_radius: float, across: int) -> void:
	radius = dish_radius
	n = across
	spacing = 2.0 * dish_radius / n
	inside.resize(n * n)
	inside_count = 0
	for y in n:
		for x in n:
			var cx := (x + 0.5) * spacing - radius
			var cy := (y + 0.5) * spacing - radius
			var on := sqrt(cx * cx + cy * cy) <= radius
			inside[y * n + x] = 1 if on else 0
			if on:
				inside_count += 1
	owner.resize(n * n)
	for y in n:
		for x in n:
			var i := y * n + x
			owner[i] = i if inside[i] == 1 else _nearest_inside(x, y)


func _nearest_inside(ix: int, iy: int) -> int:
	var best := -1
	var best_d := 1 << 30
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var nx := ix + dx
			var ny := iy + dy
			if nx < 0 or ny < 0 or nx >= n or ny >= n or inside[ny * n + nx] == 0:
				continue
			var d := dx * dx + dy * dy
			if d < best_d:
				best_d = d
				best = ny * n + nx
	return best


## The landscape's weights and the feed's.
func _make_weights() -> void:
	weights.resize(n * n)
	if _amplitude <= 0.0:
		for i in n * n:
			weights[i] = 1.0 if inside[i] == 1 else 0.0
		return
	_fill.resize(n * n)
	var sum := 0.0
	var sum_sq := 0.0
	for y in n:
		for x in n:
			var i := y * n + x
			if inside[i] == 1:
				var v := _patch_noise((x + 0.5) * spacing - radius, (y + 0.5) * spacing - radius)
				_fill[i] = v
				sum += v
				sum_sq += v * v
	var mean := sum / inside_count
	var spread := sqrt(maxf(sum_sq / inside_count - mean * mean, 1e-12))
	_fill_total = 0.0
	for i in n * n:
		if inside[i] == 1:
			_fill[i] = maxf(1.0 + _amplitude * (_fill[i] - mean) / spread, 0.05)
			_fill_total += _fill[i]
	for i in n * n:
		weights[i] = _fill[i] * inside_count / _fill_total if inside[i] == 1 else 0.0


## The cells' concentration after fill(`concentration`) of an empty grid.
func filled(concentration: float) -> PackedFloat32Array:
	var conc := PackedFloat32Array()
	conc.resize(n * n)
	if concentration <= 0.0 or inside_count == 0:
		return conc
	if _amplitude <= 0.0:
		for i in n * n:
			if inside[i] == 1:
				conc[i] = concentration
		return conc
	var scale := concentration * inside_count / _fill_total
	for i in n * n:
		if inside[i] == 1:
			conc[i] = scale * _fill[i]
	return conc


static func _logical_shift(h: int, s: int) -> int:
	return (h >> s) & ((1 << (64 - s)) - 1)


static func _corner(ix: int, iy: int, seed_v: int) -> float:
	var h := seed_v + ix * K_IX + iy * K_IY
	h = (h ^ _logical_shift(h, 30)) * K_M1
	h = (h ^ _logical_shift(h, 27)) * K_M2
	h ^= _logical_shift(h, 31)
	return float(_logical_shift(h, 11)) * (2.0 / 9007199254740992.0) - 1.0


static func _lattice_noise(x: float, y: float, lattice: float, seed_v: int) -> float:
	var gx := x / lattice
	var gy := y / lattice
	var fx := floorf(gx)
	var fy := floorf(gy)
	var tx := gx - fx
	var ty := gy - fy
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var ix := int(fx)
	var iy := int(fy)
	var c00 := _corner(ix, iy, seed_v)
	var c10 := _corner(ix + 1, iy, seed_v)
	var c01 := _corner(ix, iy + 1, seed_v)
	var c11 := _corner(ix + 1, iy + 1, seed_v)
	var top := c00 + (c10 - c00) * tx
	var bottom := c01 + (c11 - c01) * tx
	return top + (bottom - top) * ty


func _patch_noise(x: float, y: float) -> float:
	var total := 0.0
	var strength := 1.0
	var lattice := _patch_size
	var octave := 0
	while octave < 10 and (octave == 0 or lattice >= spacing):
		total += strength * _lattice_noise(x, y, lattice, _patch_seed + octave * K_OCTAVE)
		strength *= 0.8
		lattice *= 0.5
		octave += 1
	return total


func index_at(x: float, y: float) -> int:
	var ix := clampi(int((x + radius) / spacing), 0, n - 1)
	var iy := clampi(int((y + radius) / spacing), 0, n - 1)
	return iy * n + ix


## Whether a point may hold a cloud.
func accepts(x: float, y: float) -> bool:
	return sqrt(x * x + y * y) <= radius and inside[index_at(x, y)] == 1


## A point's energy shared out over the four cell centres about it: appends cells (dish-local, plus `base`)
## and amounts (concentrations) to the lists.
func deposit_xy(x: float, y: float, energy: float, base: int, cells: PackedInt32Array, amounts: PackedFloat32Array) -> void:
	var fx := (x + radius) / spacing - 0.5
	var fy := (y + radius) / spacing - 0.5
	var x0 := floori(fx)
	var y0 := floori(fy)
	var tx := fx - x0
	var ty := fy - y0
	var got: Array[int] = []
	var ws: Array[float] = []
	var kept := 0.0
	for k in 4:
		var cx := x0 + (k & 1)
		var cy := y0 + (k >> 1)
		if cx < 0 or cy < 0 or cx >= n or cy >= n or inside[cy * n + cx] == 0:
			continue
		var w := (tx if (k & 1) != 0 else 1.0 - tx) * (ty if (k >> 1) != 0 else 1.0 - ty)
		got.append(cy * n + cx)
		ws.append(w)
		kept += w
	if got.is_empty():
		return
	if kept <= 1e-9:
		cells.append(base + got[0])
		amounts.append(energy / (spacing * spacing))
		return
	for k in got.size():
		cells.append(base + got[k])
		amounts.append(energy * ws[k] / kept / (spacing * spacing))


## A disc's energy over the cells inside it.
func deposit_disc(x: float, y: float, disc_radius: float, energy: float, base: int, cells: PackedInt32Array, amounts: PackedFloat32Array) -> void:
	var x0 := maxi(0, floori((x - disc_radius + radius) / spacing - 0.5))
	var x1 := mini(n - 1, ceili((x + disc_radius + radius) / spacing - 0.5))
	var y0 := maxi(0, floori((y - disc_radius + radius) / spacing - 0.5))
	var y1 := mini(n - 1, ceili((y + disc_radius + radius) / spacing - 0.5))
	var targets: Array[int] = []
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var i := cy * n + cx
			if inside[i] == 0:
				continue
			var dx := (cx + 0.5) * spacing - radius - x
			var dy := (cy + 0.5) * spacing - radius - y
			if sqrt(dx * dx + dy * dy) <= disc_radius:
				targets.append(i)
	if targets.is_empty():
		deposit_xy(x, y, energy, base, cells, amounts)
		return
	var per_cell := energy / (targets.size() * spacing * spacing)
	for i in targets:
		cells.append(base + i)
		amounts.append(per_cell)
