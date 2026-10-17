class_name Dish
extends Node2D
## The petri dish: owns the simulation (cells + food) and draws it.

signal extinct

const DEFAULT_RADIUS := 300.0
const NUTRIENT_SCATTER := 5.0  ## scatter radius per sqrt(nutrient) when placing several at once
const MAX_CELLS := 300
const MAX_FOOD := 150
const STEP := 1.0 / 30.0  ## the fixed simulation substep, in seconds
const FOOD_ENERGY := 12.0
const FOOD_PICK_RADIUS := 3.0  ## how close (in world units) a click must be to pick a nutrient
const NO_FOOD := Vector2(INF, INF)  ## 'no nutrient selected'; nutrients never move, so a position identifies one
const EAT_RANGE_BONUS := 2.0
const HISTORY_INTERVAL := 3.0
const HISTORY_LEN := 300

var rng := RandomNumberGenerator.new()
var radius := DEFAULT_RADIUS  ## physical size of the dish
var nutrients_placed := 0  ## how many nutrients the player has dropped in by hand
var cells: Array[Cell] = []
var food: Array[Vector2] = []
var food_rate := 6.0  ## food items per second
var time := 0.0
var flash := 0.0  ## lightning flash intensity, decays to 0

## Presentation state set by the screen that shows this dish (nothing here affects the sim).
var hovered: Cell = null
var selected: Cell = null
var hovered_food := NO_FOOD
var selected_food := NO_FOOD
var place_preview_pos := Vector2.ZERO
var place_preview_radius := -1.0  ## < 0 hides the placement preview

## Sampled every HISTORY_INTERVAL sim-seconds; oldest samples drop off the front.
var history := {}

## Bumped whenever the history gains or loses a sample, so views can redraw only on change.
var history_version := 0

var _food_accum := 0.0
var _extinct_signalled := false
var _history_accum := 0.0


func _ready() -> void:
	rng.randomize()
	_reset_history()


## The lightning flash fades in real time, so it still clears while the sim is paused.
func _process(delta: float) -> void:
	flash = maxf(0.0, flash - delta * 1.5)


## Everything that belongs to one run of a dish and must start fresh with a new or loaded dish.
func _reset_runtime_state() -> void:
	selected = null
	selected_food = NO_FOOD
	clear_hover()
	_extinct_signalled = false
	_reset_history()


func _reset_history() -> void:
	history = {"pop": []}
	for gene in Genome.GENES:
		history[gene] = []
	_history_accum = 0.0
	history_version += 1


## Abiogenesis: founders appear near the centre, already divided a bit.
## Every mode starts a dish through here, so setup can't drift between modes.
func strike(start: StartConditions = null) -> void:
	if start == null:
		start = StartConditions.new()
	flash = 1.0
	time = 0.0
	nutrients_placed = 0
	cells.clear()
	food.clear()
	_reset_runtime_state()
	radius = clampf(start.dish_radius, StartConditions.MIN_DISH_RADIUS, StartConditions.MAX_DISH_RADIUS)
	food_rate = clampf(start.nutrient_rate, 0.0, StartConditions.MAX_NUTRIENT_RATE)
	var bups := clampi(start.bups, 1, MAX_CELLS)
	var spread := minf(radius * 0.8, 40.0 + 10.0 * sqrt(maxf(bups - 4.0, 0.0)))
	for i in bups:
		var c := Cell.new(_random_in_dish(spread), Genome.founder(), 30.0)
		c.generation = 2
		cells.append(c)
	for i in clampi(start.nutrients, 0, MAX_FOOD):
		food.append(_random_in_dish(radius - 5.0))


## Moves the dish and everything in it (cells and food hold global positions).
func recenter(new_position: Vector2) -> void:
	var shift := new_position - position
	for c in cells:
		c.pos += shift
	for i in food.size():
		food[i] += shift
	position = new_position


func step(delta: float) -> void:
	time += delta
	_spawn_food(delta)

	var newborn: Array[Cell] = []
	var survivors: Array[Cell] = []
	var origin := global_position  # constant for the whole step
	for c in cells:
		_update_cell(c, delta, origin)
		if c.energy <= 0.0:
			continue
		survivors.append(c)
		if c.energy >= c.split_threshold() and cells.size() + newborn.size() < MAX_CELLS:
			newborn.append(_divide(c))
	cells = survivors
	cells.append_array(newborn)
	if cells.is_empty() and time > 0.0:
		if not _extinct_signalled:  # once, on the way down, not on every step after
			_extinct_signalled = true
			extinct.emit()
		return
	_history_accum += delta
	if _history_accum >= HISTORY_INTERVAL:
		_history_accum -= HISTORY_INTERVAL
		_record_history()


func _record_history() -> void:
	history["pop"].append(cells.size())
	for gene in Genome.GENES:
		history[gene].append(mean_gene(gene))
	if history["pop"].size() > HISTORY_LEN:
		for series in history.values():
			series.pop_front()
	history_version += 1


func _spawn_food(delta: float) -> void:
	_food_accum += food_rate * delta
	while _food_accum >= 1.0:
		_food_accum -= 1.0
		if food.size() < MAX_FOOD:
			food.append(_random_in_dish(radius - 5.0))


func _update_cell(c: Cell, delta: float, origin: Vector2) -> void:
	# Steer toward nearest food within sensing range, otherwise wander.
	var here := c.pos
	var best := -1
	var best_d2 := c.sense * c.sense
	for i in food.size():
		var d2 := here.distance_squared_to(food[i])
		if d2 < best_d2:
			best_d2 = d2
			best = i
	if best >= 0:
		c.dir = here.direction_to(food[best])
	else:
		c.dir = c.dir.rotated(rng.randfn(0.0, 2.0) * delta).normalized()

	c.pos += c.dir * c.speed * delta
	# Stay inside the dish.
	var off := c.pos - origin
	var limit := radius - c.radius()
	if off.length() > limit:
		c.pos = origin + off.normalized() * limit
		c.dir = -off.normalized()

	c.energy -= c.upkeep() * delta

	# Eat anything within reach.
	here = c.pos
	var reach2 := (c.radius() + EAT_RANGE_BONUS) * (c.radius() + EAT_RANGE_BONUS)
	var i := food.size() - 1
	while i >= 0:
		if here.distance_squared_to(food[i]) <= reach2:
			c.energy += FOOD_ENERGY
			food.remove_at(i)
		i -= 1


func _divide(parent: Cell) -> Cell:
	parent.energy *= 0.5
	var child := Cell.new(
		parent.pos + Vector2.from_angle(rng.randf() * TAU) * parent.radius(),
		parent.genome.clone_mutated(rng),
		parent.energy,
	)
	child.generation = parent.generation + 1
	parent.generation += 1
	return child


func _random_in_dish(reach: float) -> Vector2:
	var a := rng.randf() * TAU
	var r := reach * sqrt(rng.randf())
	return global_position + Vector2.from_angle(a) * r


func mean_gene(gene: String) -> float:
	if cells.is_empty():
		return 0.0
	var total := 0.0
	for c in cells:
		total += c.genome.get_gene(gene)
	return total / cells.size()


## The bup under a world position, or null. `slack` widens the target (e.g. for small bups).
func cell_at(world_pos: Vector2, slack: float = 0.0) -> Cell:
	var best: Cell = null
	var best_d2 := INF
	for c in cells:
		var reach := c.radius() + slack
		var d2 := c.pos.distance_squared_to(world_pos)
		if d2 <= reach * reach and d2 < best_d2:
			best = c
			best_d2 = d2
	return best


## Index of the nutrient nearest a world position within reach, or -1. `slack` widens the target.
func food_at(world_pos: Vector2, slack: float = 0.0) -> int:
	var best := -1
	var best_d2 := INF
	var reach := FOOD_PICK_RADIUS + slack
	for i in food.size():
		var d2 := food[i].distance_squared_to(world_pos)
		if d2 <= reach * reach and d2 < best_d2:
			best = i
			best_d2 = d2
	return best


func has_selected_food() -> bool:
	return selected_food.is_finite()


## The nutrient's position if one is in reach of a world position, else NO_FOOD.
func _food_pos_at(world_pos: Vector2, slack: float) -> Vector2:
	var i := food_at(world_pos, slack)
	return food[i] if i >= 0 else NO_FOOD


## Info-tool picking. A bup wins over a nutrient where they overlap; selecting one clears the other.
func select_at(world_pos: Vector2, slack: float = 0.0) -> void:
	selected = cell_at(world_pos, slack)
	selected_food = NO_FOOD if selected != null else _food_pos_at(world_pos, slack)


func hover_at(world_pos: Vector2, slack: float = 0.0) -> void:
	hovered = cell_at(world_pos, slack)
	hovered_food = NO_FOOD if hovered != null else _food_pos_at(world_pos, slack)


func clear_hover() -> void:
	hovered = null
	hovered_food = NO_FOOD


## What there is to know about the nutrient at `pos`: its energy, where it lies, how far the
## nearest bup is, and how many bups are close enough to sense it right now.
func nutrient_details(pos: Vector2) -> Dictionary:
	var nearest := -1.0
	var sensed_by := 0
	for c in cells:
		var d := c.pos.distance_to(pos)
		if nearest < 0.0 or d < nearest:
			nearest = d
		if d <= c.sense:
			sensed_by += 1
	return {
		"energy": FOOD_ENERGY,
		"offset": pos - global_position,
		"distance": pos.distance_to(global_position),
		"nearest_bup": nearest,
		"sensed_by": sensed_by,
	}


## Radius of the circle `count` nutrients are scattered over. One nutrient lands exactly on the point.
static func scatter_radius(count: int) -> float:
	return 0.0 if count <= 1 else NUTRIENT_SCATTER * sqrt(count)


## Drops nutrients at a world position (scattered when count > 1). Returns how many were
## placed: 0 when the point is outside the dish or the dish is already full.
func place_nutrients(world_pos: Vector2, count: int) -> int:
	if world_pos.distance_to(global_position) > radius:
		return 0
	var spread := scatter_radius(count)
	var placed := 0
	for i in mini(count, MAX_FOOD - food.size()):
		var p := world_pos
		if spread > 0.0:
			p += Vector2.from_angle(rng.randf() * TAU) * spread * sqrt(rng.randf())
		food.append(global_position + (p - global_position).limit_length(radius - 2.0))
		placed += 1
	nutrients_placed += placed
	return placed


## Positions are saved relative to the dish centre so a resized window doesn't matter.
func to_dict() -> Dictionary:
	var saved_cells := []
	for c in cells:
		saved_cells.append({
			"pos": _vec_to_array(c.pos - global_position),
			"dir": _vec_to_array(c.dir),
			"energy": c.energy,
			"generation": c.generation,
			"genome": c.genome.to_dict(),
		})
	var saved_food := []
	for f in food:
		saved_food.append(_vec_to_array(f - global_position))
	return {
		"radius": radius,
		"nutrients_placed": nutrients_placed,
		"time": time,
		"food_rate": food_rate,
		"cells": saved_cells,
		"food": saved_food,
		"history": history,
	}


## Returns false, leaving the dish exactly as it was, if the data is unusable. Everything is
## validated and built on the side first, so a bad save can never leave a half-loaded dish.
func from_dict(d: Dictionary) -> bool:
	if not (d.get("cells") is Array) or not (d.get("food") is Array):
		return false
	for key in ["radius", "nutrients_placed", "time", "food_rate"]:
		if d.has(key) and not Validate.is_number(d[key]):
			return false
	var loaded_cells: Array[Cell] = []
	for saved in d["cells"]:
		var c := _cell_from_saved(saved)
		if c == null:
			return false
		loaded_cells.append(c)
	var loaded_food: Array[Vector2] = []
	for f in d["food"]:
		if not Validate.is_vec2(f):
			return false
		loaded_food.append(global_position + _array_to_vec(f))
	var saved_history = d.get("history", {})
	if not (saved_history is Dictionary):
		return false
	var loaded_history := {}
	for key in ["pop"] + Genome.GENES.keys():
		var series = saved_history.get(key)
		if series == null:
			continue
		if not (series is Array):
			return false
		for v in series:
			if not Validate.is_number(v):
				return false
		loaded_history[key] = series.slice(maxi(0, series.size() - HISTORY_LEN))

	# Everything checked out; now it is safe to replace the dish's state.
	loaded_cells.resize(mini(loaded_cells.size(), MAX_CELLS))
	loaded_food.resize(mini(loaded_food.size(), MAX_FOOD))
	cells = loaded_cells
	food = loaded_food
	radius = clampf(float(d.get("radius", DEFAULT_RADIUS)), StartConditions.MIN_DISH_RADIUS, StartConditions.MAX_DISH_RADIUS)
	nutrients_placed = int(d.get("nutrients_placed", 0))
	time = float(d.get("time", 0.0))
	food_rate = clampf(float(d.get("food_rate", food_rate)), 0.0, StartConditions.MAX_NUTRIENT_RATE)
	_reset_runtime_state()
	for key in loaded_history:
		history[key] = loaded_history[key]
	# Samples are taken on multiples of the interval, so resume the timer part-way through one.
	_history_accum = fposmod(time, HISTORY_INTERVAL)
	return true


func _cell_from_saved(saved: Variant) -> Cell:
	if not (saved is Dictionary) or not Validate.is_vec2(saved.get("pos")) or not Validate.is_vec2(saved.get("dir")):
		return null
	if not Validate.is_number(saved.get("energy")) or not Validate.is_number(saved.get("generation")) or not (saved.get("genome") is Dictionary):
		return null
	var c := Cell.new(global_position + _array_to_vec(saved["pos"]), Genome.from_dict(saved["genome"]), float(saved["energy"]))
	c.dir = _array_to_vec(saved["dir"])
	c.generation = int(saved["generation"])
	return c


static func _vec_to_array(v: Vector2) -> Array:
	return [v.x, v.y]


static func _array_to_vec(a: Array) -> Vector2:
	return Vector2(a[0], a[1])


func fraction_with_gene_at_least(gene: String, threshold: float) -> float:
	if cells.is_empty():
		return 0.0
	var n := 0
	for c in cells:
		if c.genome.get_gene(gene) >= threshold:
			n += 1
	return n / float(cells.size())


func mean_mutations() -> float:
	if cells.is_empty():
		return 0.0
	var total := 0.0
	for c in cells:
		total += c.genome.mutations
	return total / cells.size()


func _draw() -> void:
	# Dish: dark agar, green-tinted glass rim.
	draw_circle(Vector2.ZERO, radius, Color(0.03, 0.06, 0.04))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 96, Color(0.45, 0.8, 0.6, 0.6), 3.0)
	draw_arc(Vector2.ZERO, radius + 6.0, 0.0, TAU, 96, Color(0.45, 0.8, 0.6, 0.2), 2.0)

	for f in food:
		draw_circle(f - global_position, 1.8, Color(0.9, 0.8, 0.4, 0.8))

	for c in cells:
		var col := Color.from_hsv(c.genome.hue, 0.7, 1.0)
		var p := c.pos - global_position
		draw_circle(p, c.radius() + 2.0, Color(col, 0.18))  # glow
		draw_circle(p, c.radius(), col)

	if selected != null:
		var sp := selected.pos - global_position
		draw_arc(sp, selected.genome.get_gene("sense"), 0.0, TAU, 64, Color(1, 0.75, 0.3, 0.25), 1.0)
		draw_arc(sp, selected.radius() + 4.0, 0.0, TAU, 24, Color(1, 0.75, 0.3, 0.95), 2.0)
	if hovered != null and hovered != selected:
		draw_arc(hovered.pos - global_position, hovered.radius() + 4.0, 0.0, TAU, 24, Color(1, 1, 1, 0.9), 1.5)
	if selected_food.is_finite():
		draw_arc(selected_food - global_position, 5.0, 0.0, TAU, 20, Color(1, 0.75, 0.3, 0.95), 2.0)
	if hovered_food.is_finite() and hovered_food != selected_food:
		draw_arc(hovered_food - global_position, 5.0, 0.0, TAU, 20, Color(1, 1, 1, 0.9), 1.5)
	if place_preview_radius >= 0.0:
		draw_arc(place_preview_pos - global_position, maxf(place_preview_radius, 2.0), 0.0, TAU, 32, Color(1, 0.9, 0.5, 0.8), 1.5)

	if flash > 0.0:
		draw_circle(Vector2.ZERO, radius, Color(0.85, 0.95, 1.0, flash))
