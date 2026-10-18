class_name Dish
extends Node2D
## The petri dish. The simulation itself (bups, genomes, the dissolved nutrient, stepping) runs in
## the native BupSim (native/src); this node owns what surrounds it: drawing, selection and hover,
## nutrient sources, the history graph's samples, and saving and loading.
## Lengths are µm and times are seconds of simulation time, which runs at real biological rates
## (see Biology); the player's playback speed only multiplies how much of it passes per second.
## Bups are named by a stable id (an int), since the native arrays compact as bups die.

signal extinct
enum PickMode { ALL, BACKGROUND, BUPS, SOURCES, PLANKTON }  ## what the select tool looks at: everything (a source over a bup), only the medium, only bups, or only sources

signal selection_changed  ## the selected bup is now another (or none)

const DEFAULT_RADIUS := 10000.0  ## µm: 10 mm, the dish goal mode uses and free mode starts with
const NUTRIENT_SCATTER := 5.0  ## radius a dose spreads over, per sqrt(nutrient) in it
const MAX_CELLS := 300  ## the smallest carrying limit; see `cap_for`. Past the limit each birth displaces a random bup (a Moran process)
const MAX_SOURCES := 12
const PLANKTON_UNITS := 300.0  ## nutrient a plankton releases when it bursts [choice: a patch a few minutes of chemotaxis can use; see SUGGESTED_BLOOM_RATE]
const PLANKTON_PATCH_RADIUS := 250.0  ## µm the released nutrient starts out spread over (a lysed cell's cloud: Stocker et al. 2008 used ~300 µm)
const PLANKTON_MEAN_LIFE := 3600.0  ## s a plankton floats on average before bursting [choice: lysis timing is random; no measured scale]
const PLANKTON_LIFE_SPREAD := 0.5  ## each one bursts at a random time from this share below to this share above the mean life, so the food keeps coming
const BLOOM_JITTER := 0.25  ## the bloom's plankton appear at steady intervals, each this share early or late at random
const PLANKTON_DRAW_RADIUS := 40.0  ## µm: about a small diatom
const PLANKTON_MIN_PIXELS := 7.0  ## drawn at least this many screen pixels in radius
const MAX_PLANKTON := 200
const SUGGESTED_BLOOM_RATE := 24.0  ## plankton a sim-day that the goal text suggests (one an hour): 300 units an hour, about what the old feed gave
const GOAL_UPKEEP_FACTOR := 3.0  ## how much costlier staying alive is once goal mode reaches experiment 2 (set by the screen; 1 elsewhere) [x10 killed every colony tested at once; x3 did not]
const MAX_BLOOM_ARRIVALS_PER_STEP := 50  ## the most plankton one step lets the bloom add (a few at most; a rate raised a great deal starts over)
const BLOOM_RATE_STEP := 1.0  ## the bloom rate moves in these steps (plankton a sim-day)
const MIN_SOURCE_RATE := 0.5  ## nutrients per minute, like the global feed
const MAX_SOURCE_RATE := 60.0
const SOURCE_NEARBY := 60.0  ## how close counts as "near" a source in its details
const SOURCE_DRAW_RADIUS := 3.0  ## the size a source is drawn at, in µm: about a bup's, so the same selection ring fits both
const SOURCE_MIN_PIXELS := 3.0  ## a source is drawn at least this many screen pixels in radius
const SOURCE_PICK_PIXELS := 9.0  ## and can be picked from at least this many pixels away
const SOURCE_PICK_RADIUS := 18.0  ## how close (in µm) a click must be to pick a source: generous, since it is small and often under bups
const ERASE_STRENGTH := 0.9  ## the share of nutrient the eraser takes from the middle of its brush
const DIFFUSE_INTERVAL := 5.0  ## seconds between solves of the nutrient field's diffusion (implicit, so long steps are fine)
const MAX_STEP := 20.0  ## the longest single step, in seconds: growth, uptake and division are slow (doubling takes 40 minutes), so they run once per step
const RING_PIXELS := 12.0  ## the radius of a selection or hover ring, in screen pixels
const RING_GROW_ABOVE := 0.5  ## the ring only grows once its subject is more than this share of the ring's diameter ...
const RING_GROW_TO := 0.25  ## ... and then to the size where the subject is this share of it
const MAX_TRAIL_PIXELS := 80.0  ## the longest trail a fast bup is drawn with, in screen pixels
const TRAIL_FADE_PIXELS := 10.0  ## a trail is a third as bright this many screen pixels behind the bup, however fast it went
const HAZE_REFRESH_MSEC := 100  ## how often the picture of the dissolved nutrient is rebuilt
const STEER_ALPHA := 0.35 * 255.0  ## the most opaque the steering map gets (where a bup is certain to steer up the slope)
const MIN_STEER_ARC := deg_to_rad(15.0)  ## the narrowest arc on the selection ring: how reliably its drift tends one way
const ARC_SHOWN_ABOVE := 0.54  ## chance of drifting up the slope above which the arc shows (below it, a coin toss)
const MOTION_STEP := 3.0  ## the longest motion sub-step, in seconds: a swimmer must not jump farther than a gradient is wide (~50-100 µm; a bup diffuses ~40 µm in 3 s)
const FINE_STEP := 0.25  ## steps this short or shorter follow individual runs and tumbles
const NUTRIENT_ENERGY := 16.0  ## the energy in one unit of nutrient: the unit of every feed, dose and source
const FOUNDER_ENERGY := 100.0  ## enough reserve to find a first meal in a sparse dish
const DIVISION_SPREAD := 0.03  ## how unevenly a division splits the mother: the daughters' sizes vary a few percent
const FIELD_TARGET_SPACING := 25.0  ## µm: plumes at the real diffusion are 50-100 µm wide, so a 25 µm grid resolves them
const FIELD_MIN_ACROSS := 48  ## small dishes keep a fine grid (a 300 µm dish gets 12.5 µm cells)
const FIELD_MAX_ACROSS := 100  ## a cost limit: the solve takes time in proportion to the cells (about 0.1 ms for this grid, once per step), and top playback speed depends on it
const RENDER_MIN_CAPACITY := 256  ## the fewest bups the picture has room for
const HISTORY_INTERVAL := 120.0  ## seconds between samples of the history graph
const HISTORY_LEN := 2160  ## 72 hours of samples: the longest span the graph shows
const HISTORY_SERIES := ["pop", "speed", "sense", "metabolism", "size", "harm"]  ## population, each gene's mean, and mean harm (%)

const BUP_SHADER := """
shader_type canvas_item;
uniform float fade_pixels = 10.0;  // how far behind a bup its trail falls to about a third as bright, in screen pixels
varying vec4 body;  // length, width and the margin round them, and the trail behind, in µm
void vertex() { body = INSTANCE_CUSTOM; }
void fragment() {
	// A capsule (a rod with round ends, lengthened by the trail of a fast one) inside a quad a margin larger, with its
	// edge antialiased over one screen pixel. A body thinner than a pixel stays visible, only fainter.
	float total = body.x + body.w;
	vec2 p = (UV - vec2(0.5)) * vec2(total + 2.0 * body.z, body.y + 2.0 * body.z);
	float half_straight = max(total * 0.5 - body.y * 0.5, 0.0);
	vec2 q = vec2(max(abs(p.x) - half_straight, 0.0), p.y);
	float d = length(q) - body.y * 0.5;
	float pixel = max(fwidth(p.y), 1e-6);
	COLOR.a *= clamp(0.5 - d / pixel, 0.0, 1.0);
	// The trail fades with the distance behind the body, at the same rate on screen however far the bup travelled: a
	// longer trail (a faster bup) simply has a fainter tail, not a longer visible one.
	float behind = max(total * 0.5 - body.x - p.x, 0.0);
	COLOR.a *= body.w > 0.0 ? exp(-behind / (fade_pixels * pixel)) : 1.0;
}
"""
var sim := BupSim.new()  ## the native simulation core
var field: NutrientField = sim.get_field()  ## the dissolved nutrient (owned by the simulation)
var radius := DEFAULT_RADIUS:  ## physical size of the dish; it changes only with a new dish (`strike`, a load) or `grow_to`
	set(value):
		radius = value
		_sync_render_capacity()
var bup_limit := StartConditions.DEFAULT_BUP_LIMIT:  ## the most bups the dish holds (chosen in free mode)
	set(value):
		bup_limit = clampi(value, 1, StartConditions.MAX_BUP_LIMIT)
		sim.set_limit(bup_limit)
		_sync_render_capacity()
var nutrients_placed := 0  ## how many units of nutrient the player has dropped in by hand
var sources: Array[NutrientSource] = []
var food_rate := 3.0:  ## units of nutrient fed in per minute, spread evenly over the dish
	set(value):
		food_rate = clampf(value, 0.0, StartConditions.MAX_NUTRIENT_RATE)
var bloom_rate := 0.0:  ## plankton appearing a sim-day (24 hours), at steady intervals, at random places
	set(value):
		if value > 0.0 and bloom_rate <= 0.0:
			_bloom_due = time  # (turned on: the first appears at once)
		bloom_rate = clampf(value, 0.0, StartConditions.MAX_BLOOM_RATE)
var _bloom_due := 0.0  ## when the bloom's next plankton appears
var upkeep_factor := 1.0:  ## multiplies what staying alive costs every bup (its base and per-mass maintenance)
	set(value):
		upkeep_factor = maxf(value, 0.0)
		sim.set_upkeep_scale(upkeep_factor)
var plankton: Array[Plankton] = []
var time := 0.0:
	set(value):
		time = value
		sim.set_time(value)  # births and deaths are stamped from the simulation's own copy
var flash := 0.0  ## lightning flash intensity, decays to 0

## Presentation state set by the screen that shows this dish (nothing here affects the sim).
var pick_mode := PickMode.ALL:  ## the select tool ignores whatever this leaves out
	set(value):
		pick_mode = value
		if not looks_at_bups():
			selected_id = -1
		if not looks_at_sources():
			selected_source = null
		if not looks_at_plankton():
			selected_plankton = null
var hovered_id := -1  ## the bup under the pointer, or -1
var selected_id := -1:  ## the bup that was clicked, or -1
	set(value):
		if value != selected_id:
			selected_id = value
			selection_changed.emit()
var selected_source: NutrientSource = null
var hovered_source: NutrientSource = null
var selected_plankton: Plankton = null
var hovered_plankton: Plankton = null
var place_preview_pos := Vector2.ZERO
var place_preview_radius := -1.0  ## < 0 hides the placement preview
var place_preview_erases := false  ## the preview is the eraser's brush
var place_preview_marker := false  ## the preview marks a single point (a source about to be placed): drawn as a GUI ring, like a selection

## Sampled every HISTORY_INTERVAL sim-seconds; oldest samples drop off the front.
var history := {}

## Bumped whenever the history gains or loses a sample, so views can redraw only on change.
var history_version := 0

var edit_count := 0  ## bumped by every change made to the dish by hand (a bup or source added or removed, nutrient dropped or erased), so screens can tell when to look again
var _draw_key := []  ## what the dish was last drawn from (see `refresh_drawing`)
var _render_stamp := []  ## what the bups' picture was last built from
var _render_stale := true  ## the bups were changed by hand (added, removed, a new dish), so the picture must be rebuilt
var _haze: ImageTexture = null
var _haze_built := 0
var _steer: ImageTexture = null  ## where the selected bup could steer (see `_draw_steering`)
var _steer_key := []
var _extinct_signalled := false
var _history_accum := 0.0
var _bups_mesh: MultiMeshInstance2D = null  ## all the bups, drawn in one go
var _overlay: Node2D = null  ## the selection and hover rings, drawn above the bups


func _init() -> void:
	SimConstants.apply()
	sim.set_limit(bup_limit)
	sim.reset(DEFAULT_RADIUS, 1)


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR  # the haze is a small texture stretched over the dish
	set_seed(Time.get_ticks_usec())
	_reset_history()
	_build_children()


## The random numbers are the native simulation's; tests set a seed to make a run repeatable.
func set_seed(value: int) -> void:
	sim.set_seed(value)


func _build_children() -> void:
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = BUP_SHADER
	material.set_shader_parameter("fade_pixels", TRAIL_FADE_PIXELS)
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	_bups_mesh = MultiMeshInstance2D.new()
	_bups_mesh.multimesh = multimesh
	_bups_mesh.material = material
	add_child(_bups_mesh)
	_overlay = DishOverlay.new()
	_overlay.dish = self
	add_child(_overlay)
	_sync_render_capacity()


## Redraws the dish only when something it shows may have changed: the picture of the medium is rebuilt a few times a
## second, and the sources, the size and the zoom show at once. Most frames change none of these.
func refresh_drawing() -> void:
	var key := [Time.get_ticks_msec() / HAZE_REFRESH_MSEC, sources.size(), edit_count, radius, pixel(), selected_id]
	if key != _draw_key:
		_draw_key = key
		queue_redraw()


## The picture holds room for the bups there are (with some to spare, never past the limit), not for the
## most there could be: a buffer for 100,000 bups is rewritten every frame, which costs when only a few live.
func _fit_render_capacity(needed: int) -> void:
	var multimesh := _bups_mesh.multimesh
	var wanted := mini(bup_limit, maxi(RENDER_MIN_CAPACITY, nearest_po2(needed + needed / 2)))
	if needed > multimesh.instance_count or wanted * 4 <= multimesh.instance_count or multimesh.instance_count > bup_limit:
		multimesh.instance_count = wanted
		_render_stale = true  # (a resized multimesh starts empty)


func _sync_render_capacity() -> void:
	if _bups_mesh == null:
		return
	var multimesh := _bups_mesh.multimesh
	_fit_render_capacity(sim.bup_count())
	# The bounds the renderer culls by: the whole dish. Left to itself it works the bounds out from
	# the instances once, so a buffer written every frame can leave them stale, and the bups are
	# culled whenever the view no longer matches that first guess.
	multimesh.custom_aabb = AABB(Vector3(-radius, -radius, -1.0), Vector3(2.0 * radius, 2.0 * radius, 2.0))


## The lightning flash fades in real time, so it still clears while the sim is paused. The bups'
## picture is refreshed here, once a frame, from the native simulation.
func _process(delta: float) -> void:
	flash = maxf(0.0, flash - delta * 1.5)
	if _bups_mesh != null:
		_fit_render_capacity(sim.bup_count())
		var multimesh := _bups_mesh.multimesh
		# The picture is rebuilt only when what it shows may have changed: time has passed, or the bups, the zoom or
		# the pixel size have. (While paused nothing has, however many bups there are.)
		var stamp := [time, sim.bup_count(), pixel()]
		if _render_stale or stamp != _render_stamp:
			_render_stamp = stamp
			_render_stale = false
			multimesh.visible_instance_count = mini(sim.bup_count(), multimesh.instance_count)
			multimesh.buffer = sim.render_buffer(pixel(), multimesh.instance_count)
		_overlay.queue_redraw()


## Everything that belongs to one run of a dish and must start fresh with a new or loaded dish.
func _reset_runtime_state() -> void:
	clear_selection()
	clear_hover()
	_extinct_signalled = false
	_reset_history()


func _reset_history() -> void:
	history = {}
	for series in HISTORY_SERIES:
		history[series] = []
	_history_accum = 0.0
	history_version += 1


## Abiogenesis: founders appear near the centre, part-way through their first growth (generation 0: nothing precedes them).
## Every mode starts a dish through here, so setup can't drift between modes.
func strike(start: StartConditions = null) -> void:
	if start == null:  # goal mode's dish: the usual conditions, and founders in evenly spaced colours (more interesting than all green)
		start = StartConditions.new()
		start.spread_founders()
	flash = 1.0
	_render_stale = true
	edit_count += 1
	time = 0.0
	nutrients_placed = 0
	sources.clear()
	plankton.clear()
	bloom_rate = start.bloom_rate
	upkeep_factor = 1.0
	_reset_runtime_state()
	radius = clampf(start.dish_radius, StartConditions.MIN_SIM_RADIUS, StartConditions.MAX_DISH_RADIUS)
	sim.reset(radius, -1)  # a new dish: no bups, no nutrient, the random stream carries on
	bup_limit = start.bup_limit
	food_rate = start.nutrient_rate
	var bups := clampi(start.bups, 1, bup_limit)
	var spread := minf(radius * 0.8, 40.0 + 10.0 * sqrt(maxf(bups - 4.0, 0.0)))
	for i in bups:
		var founder := Genome.founder()
		var chosen: Dictionary = start.founders[i] if i < start.founders.size() else {}  # the player's name and colour for this one
		if chosen.has("color"):
			founder = Genome.with_color(founder, Genome.color_from_hex(chosen["color"]))
		var born_with := Cell.mass_to_add(founder)
		var grown := born_with * (1.0 + sim.random_float())  # not all at the same point in the cycle
		var id := sim.add_bup(sim.random_point(spread), founder, FOUNDER_ENERGY, sqrt(grown), born_with, 0, Vector2.RIGHT)
		if chosen.get("name", "") != "":
			rename_bup(id, chosen["name"])
	field.fill(clampi(start.nutrients, 0, StartConditions.MAX_NUTRIENTS) * NUTRIENT_ENERGY)  # the medium the colony starts in


## Enlarges the dish with everything in it: the bups, the nutrient (spread over the new grid, none of it
## lost) and the sources stay where they are. A dish never shrinks, since that would cut bups off.
func grow_to(new_radius: float) -> void:
	new_radius = minf(new_radius, StartConditions.MAX_DISH_RADIUS)
	if new_radius <= radius:
		return
	sim.grow(new_radius)  # the bups and the nutrient stay
	radius = new_radius
	queue_redraw()


## Changes how many bups the dish holds, without ever going below how many there are now.
func change_limit(value: int) -> void:
	bup_limit = maxi(value, population())


## Moves the dish. Bups are held relative to the dish centre, so only the sources (global) shift.
func recenter(new_position: Vector2) -> void:
	var shift := new_position - position
	for source in sources:
		source.pos += shift
	position = new_position


## The default limit for a dish of this radius. It grows with the radius, so a bigger dish keeps a
## comparable crowd per length of rim; a limit is also a cap on how much work the simulation does.
static func cap_for(dish_radius: float) -> int:
	return maxi(MAX_CELLS, int(dish_radius))


## Runs `seconds` of simulation time in steps no longer than MAX_STEP. With a time budget (in µs)
## it stops once the budget is spent and drops the rest, so a costly playback speed runs slower
## than its label instead of making the game stutter. Returns the seconds actually simulated.
func advance(seconds: float, budget_usec := 0) -> float:
	if seconds <= 0.0:
		return 0.0
	var steps := maxi(1, ceili(seconds / MAX_STEP))
	var delta := seconds / steps
	var started := Time.get_ticks_usec()
	var done := 0.0
	for i in steps:
		step(delta)
		done += delta
		if budget_usec > 0 and Time.get_ticks_usec() - started > budget_usec:
			break
	return done


func step(delta: float) -> void:
	time += delta
	_step_plankton()
	var positions := PackedVector2Array()
	var rates := PackedFloat32Array()
	for source in sources:
		positions.append(source.pos - global_position)
		rates.append(source.rate)
		source.emitted += source.rate / 60.0 * delta
	sim.step(delta, positions, rates, food_rate, time)  # (time, so births and deaths are stamped with it)
	if sim.bup_count() == 0 and time > 0.0:
		if not _extinct_signalled:  # once, on the way down, not on every step after
			_extinct_signalled = true
			extinct.emit()
		return
	_history_accum += delta
	if _history_accum >= HISTORY_INTERVAL:
		_history_accum -= HISTORY_INTERVAL
		_record_history()


func _record_history() -> void:
	var stats := sim.population_stats()
	history["pop"].append(stats["count"])
	for gene in Genome.GENES:
		history[gene].append(stats[gene])
	history["harm"].append(stats["harm"] * 100.0)
	if history["pop"].size() > HISTORY_LEN:
		for series in history.values():
			series.pop_front()
	history_version += 1


# --- The bups --------------------------------------------------------------------------------

func population() -> int:
	return sim.bup_count()


func has_bup(id: int) -> bool:
	return id >= 0 and sim.has_bup(id)


func bup_ids() -> PackedInt64Array:
	return sim.bup_ids()


## Everything about one bup (see BupSim.bup_info): its position is relative to the dish centre.
func bup_info(id: int) -> Dictionary:
	return sim.bup_info(id)


## The bup's position in the world, like the sources'.
func bup_world_pos(id: int) -> Vector2:
	return global_position + sim.bup_pos(id)


## Adds a bup at a world position and returns its id. `size` is its body now (the square root of
## its mass); negative means a newborn of this genome.
func add_bup(world_pos: Vector2, genome: Dictionary, energy: float, size := -1.0, birth_mass := -1.0, generation := 0, dir := Vector2.RIGHT, id := -1) -> int:
	_render_stale = true
	edit_count += 1
	return sim.add_bup(world_pos - global_position, genome, energy, size, birth_mass, generation, dir, id)


## What the bup is called: the name the player gave it, or else its size word and its number ("lil bup #578",
## the 578th born in this dish). Empty if there is no such bup. This is the only way to get a bup's name.
func bup_name(id: int) -> String:
	var custom := bup_custom_name(id)
	return custom if custom != "" else bup_default_name(id)


## What founder number `id` is called until it is named: the setup screens show it as the hint for a founder's name.
static func default_founder_name(id: int) -> String:
	return BupNames.default_name(Genome.founder()["size"], id)


## A typed name as it will be kept (tidied, and a sensible length).
static func cleaned_name(text: String) -> String:
	return BupNames.clean(text)


## What a panel shows for a bup, from one look-up: {"name", "color", "alive"} (empty if there is no record).
func bup_display(id: int) -> Dictionary:
	var info := sim.lineage_info(id)
	if info.is_empty():
		return {}
	var custom := sim.custom_name(id)
	return {
		"name": custom if custom != "" else BupNames.default_name(info["size_gene"], id),
		"color": Genome.color_of(info),
		"alive": info["alive"],
	}


## The name a bup has without one from the player (for showing as a hint while renaming).
func bup_default_name(id: int) -> String:
	var info := sim.lineage_info(id)
	return "" if info.is_empty() else BupNames.default_name(info["size_gene"], id)


## The name the player gave the bup, or "" if it has none (it still has its number).
func bup_custom_name(id: int) -> String:
	return sim.custom_name(id)


## Names a bup. An empty name takes the name away. The name goes when the bup dies.
func rename_bup(id: int, text: String) -> void:
	sim.set_custom_name(id, BupNames.clean(text))  # (an empty name takes the name away)


## Everything known about a bup, alive or dead, as BupSim.lineage_info (empty once its record is dropped).
## Dead bups keep a record while a living bup descends from them or something is pinning them.
func lineage_info(id: int) -> Dictionary:
	return sim.lineage_info(id)


## The family line that led to a bup: its oldest known ancestor first, the bup itself last.
func lineage_chain(id: int) -> PackedInt64Array:
	return sim.lineage_chain(id)


func has_record(id: int) -> bool:
	return id >= 0 and sim.has_record(id)


## Asks for a bup's record (and its ancestors') to be kept after it dies, until it is unpinned.
func pin_bup(id: int) -> void:
	sim.pin(id)


func unpin_bup(id: int) -> void:
	sim.unpin(id)


func remove_bup(id: int) -> void:
	_render_stale = true
	edit_count += 1
	sim.remove_bup(id)


func clear_bups() -> void:
	_render_stale = true
	edit_count += 1
	sim.clear_bups()


## The count and averages the readouts show (each gene, "harm" as a share of yield lost, "mutations"), in one pass.
func population_stats() -> Dictionary:
	return sim.population_stats()


func fraction_with_gene_at_least(gene: String, threshold: float) -> float:
	return sim.fraction_with_gene_at_least(gene, threshold)


## The id of the bup under a world position, or -1. `slack` widens the target (e.g. for small bups).
func cell_at(world_pos: Vector2, slack: float = 0.0) -> int:
	return sim.pick_bup(world_pos - global_position, slack, pixel())


## How big a source is drawn, in µm: its own size, or at least a few pixels, so it shows from far out.
func source_draw_radius() -> float:
	return maxf(SOURCE_DRAW_RADIUS, SOURCE_MIN_PIXELS * pixel())


## The one of `things` (anything with a `pos`) nearest `point` within `reach`, or null.
static func _nearest_within(things: Array, point: Vector2, reach: float) -> Variant:
	var best: Variant = null
	var best_d2 := INF
	for thing in things:
		var d2: float = thing.pos.distance_squared_to(point)
		if d2 <= reach * reach and d2 < best_d2:
			best = thing
			best_d2 = d2
	return best


## The source nearest a world position within reach, or null.
func source_at(world_pos: Vector2, slack: float = 0.0) -> NutrientSource:
	return _nearest_within(sources, world_pos, maxf(SOURCE_PICK_RADIUS, SOURCE_PICK_PIXELS * pixel()) + slack)


## Select-tool picking. Where they overlap a source wins over a bup (a source is small and
## usually crowded by bups, so if there is one under the pointer it is what is being aimed at);
## picking empty ground selects nothing, which is how a selection is let go.
func select_at(world_pos: Vector2, slack: float = 0.0) -> void:
	var picked := _pick(world_pos, slack)
	selected_source = picked["source"]
	selected_id = picked["bup"]
	selected_plankton = picked["plankton"]


func hover_at(world_pos: Vector2, slack: float = 0.0) -> void:
	var picked := _pick(world_pos, slack)
	hovered_source = picked["source"]
	hovered_id = picked["bup"]
	hovered_plankton = picked["plankton"]


## What is under a world position, of the kinds the pick mode looks at: only the first of a source, a bup and a plankton
## (in that order) that is there, the others being none.
func _pick(world_pos: Vector2, slack: float) -> Dictionary:
	var source: NutrientSource = source_at(world_pos, slack) if looks_at_sources() else null
	var bup := cell_at(world_pos, slack) if source == null and looks_at_bups() else -1
	var floating: Plankton = plankton_at(world_pos, slack) if source == null and bup < 0 and looks_at_plankton() else null
	return {"source": source, "bup": bup, "plankton": floating}


## Whether a bup, a source or a plankton is selected.
func has_selection() -> bool:
	return selected_id >= 0 or has_selected_thing()


## Whether a source or a plankton is selected (what is picked besides a bup).
func has_selected_thing() -> bool:
	return selected_source != null or selected_plankton != null


## Lets go of everything selected.
func clear_selection() -> void:
	selected_id = -1
	selected_source = null
	selected_plankton = null


func looks_at_sources() -> bool:
	return pick_mode == PickMode.ALL or pick_mode == PickMode.SOURCES


func looks_at_plankton() -> bool:
	return pick_mode == PickMode.ALL or pick_mode == PickMode.PLANKTON


func looks_at_bups() -> bool:
	return pick_mode == PickMode.ALL or pick_mode == PickMode.BUPS


## Whether the readout of the medium under the pointer is wanted: when looking at everything (where nothing else is
## under the pointer) or at the background alone.
func looks_at_medium() -> bool:
	return pick_mode == PickMode.ALL or pick_mode == PickMode.BACKGROUND


func clear_hover() -> void:
	hovered_id = -1
	hovered_source = null
	hovered_plankton = null
	place_preview_erases = false
	place_preview_marker = false


func remove_source(source: NutrientSource) -> void:
	sources.erase(source)
	edit_count += 1
	if selected_source == source:
		selected_source = null
	if hovered_source == source:
		hovered_source = null


## Whether nutrient (a dose or a source) can be put at a world point: inside the dish, and not in
## the thin band at the rim where the nutrient grid has no cell to hold it.
func can_place_at(world_pos: Vector2) -> bool:
	return field.accepts(world_pos - global_position)


## Adds a feeder inside the dish. Returns false when the dish can't take another, or the spot
## can't hold one (too close to the rim).
func place_source(world_pos: Vector2, rate: float) -> bool:
	if sources.size() >= MAX_SOURCES or not can_place_at(world_pos):
		return false
	sources.append(NutrientSource.new(world_pos, clampf(rate, MIN_SOURCE_RATE, MAX_SOURCE_RATE)))
	edit_count += 1
	return true


## The plankton under a world position (within its drawn size, plus `slack`), or null.
func plankton_at(world_pos: Vector2, slack: float = 0.0) -> Plankton:
	return _nearest_within(plankton, world_pos - global_position, plankton_draw_radius() + slack)


## What there is to know about a plankton: how long it has floated, what it holds, where it is, and what is near.
## (Not when it will burst: that is not known.)
func plankton_details(cell: Plankton) -> Dictionary:
	var details := _spot_details(cell.pos)
	details["age"] = time - cell.born_at
	details["units"] = cell.units
	return details


## What there is to know about a spot in the dish, given its place within it: where it is, the concentration there, and how
## many bups are close by and how far the nearest is.
func _spot_details(local: Vector2) -> Dictionary:
	var near := sim.nearest_and_count(local, SOURCE_NEARBY)
	return {
		"offset": local,
		"distance": local.length(),
		"concentration": field.sample(local),
		"nearest_bup": near.x,
		"nearby": int(near.y),
	}


## Puts a plankton in the dish. False when the dish holds as many as it can, or the spot can't take one.
func place_plankton(world_pos: Vector2) -> bool:
	if plankton.size() >= MAX_PLANKTON or not can_place_at(world_pos):
		return false
	_add_plankton(world_pos - global_position)
	return true


func _add_plankton(local: Vector2) -> void:
	var life := PLANKTON_MEAN_LIFE * (1.0 + PLANKTON_LIFE_SPREAD * (2.0 * sim.random_float() - 1.0))
	plankton.append(Plankton.new(local, time, time + life, PLANKTON_UNITS, sim.random_float() * TAU))
	edit_count += 1


## The plankton: the bloom adds one at a random place at each steady interval (so there are no long gaps with none
## coming), and any whose time has come burst, at random times, leaving their nutrient in the medium.
func _step_plankton() -> void:
	if bloom_rate > 0.0:
		var interval := 86400.0 / bloom_rate
		var arrivals := 0
		while time >= _bloom_due and arrivals < MAX_BLOOM_ARRIVALS_PER_STEP:
			if plankton.size() < MAX_PLANKTON:
				_add_plankton(sim.random_point(radius * 0.95))
			_bloom_due += interval * (1.0 + BLOOM_JITTER * (2.0 * sim.random_float() - 1.0))
			arrivals += 1
		if time >= _bloom_due:  # (far behind, say the rate was just raised a great deal: start over from now)
			_bloom_due = time + interval
	for i in range(plankton.size() - 1, -1, -1):
		var cell := plankton[i]
		if cell.burst_at <= time:
			field.deposit_disc(cell.pos, PLANKTON_PATCH_RADIUS, cell.units * NUTRIENT_ENERGY)
			plankton.remove_at(i)
			if selected_plankton == cell:
				selected_plankton = null
			if hovered_plankton == cell:
				hovered_plankton = null
			edit_count += 1


## What there is to know about a source: its rate and output so far, where it lies, the
## concentration at it, and how many bups are close by.
func source_details(source: NutrientSource) -> Dictionary:
	var details := _spot_details(source.pos - global_position)
	details["rate"] = source.rate
	details["emitted"] = source.emitted
	return details


## What there is to know about the medium at a world point: how much nutrient is there, which
## way it rises, and how far the nearest source and bup are.
func nutrient_at(world_pos: Vector2) -> Dictionary:
	var local := world_pos - global_position
	var reading := field.read(local)  # the concentration and its slope together
	var nearest_source := -1.0
	for source in sources:
		var d := source.pos.distance_to(world_pos)
		if nearest_source < 0.0 or d < nearest_source:
			nearest_source = d
	return {
		"offset": local,
		"distance": local.length(),
		"concentration": reading.x,
		"gradient": Vector2(reading.y, reading.z),
		"nearest_bup": sim.nearest_and_count(local, 0.0).x,
		"nearest_source": nearest_source,
	}


## Radius of the circle a dose of `count` nutrients spreads over. One nutrient lands on the point.
static func scatter_radius(count: int) -> float:
	return 0.0 if count <= 1 else NUTRIENT_SCATTER * sqrt(count)


## Drops `count` units of nutrient into the medium at a world point (spread over a small disc
## when there are several). Returns false when the point is outside the dish.
func drop_nutrients(world_pos: Vector2, count: int) -> bool:
	if not can_place_at(world_pos) or count <= 0:
		return false
	field.deposit_disc(world_pos - global_position, scatter_radius(count), count * NUTRIENT_ENERGY)
	edit_count += 1
	nutrients_placed += count
	return true


## The eraser: takes most of the nutrient out of a disc of the medium, a little less towards
## its edge. Returns how many units were removed.
func erase_nutrient(world_pos: Vector2, brush_radius: float) -> float:
	edit_count += 1
	return field.erase_disc(world_pos - global_position, brush_radius, ERASE_STRENGTH) / NUTRIENT_ENERGY


# --- Saving and loading ------------------------------------------------------------------------

## Positions are saved relative to the dish centre so a resized window doesn't matter.
func to_dict() -> Dictionary:
	var saved_cells := []
	for id in sim.bup_ids():
		var b := sim.bup_info(id)
		saved_cells.append({
			"id": b["id"],
			"pos": _vec_to_array(b["pos"]),
			"dir": _vec_to_array(b["dir"]),
			"energy": b["energy"],
			"size": b["size"],
			"birth_mass": b["birth_mass"],
			"generation": b["generation"],
			"genome": Genome.to_saved({"speed": b["speed"], "sense": b["sense"], "metabolism": b["metabolism"], "size": b["size_gene"], "hue": b["hue"], "sat": b["sat"], "val": b["val"], "harm": b["harm"], "mutations": b["mutations"]}),
		})
	var saved_sources := []
	for source in sources:
		saved_sources.append({"pos": _vec_to_array(source.pos - global_position), "rate": source.rate, "emitted": source.emitted})
	var saved_plankton := []
	for cell in plankton:
		saved_plankton.append({"pos": _vec_to_array(cell.pos), "born_at": cell.born_at, "burst_at": cell.burst_at, "units": cell.units, "shape": cell.shape})
	return {
		"next_id": sim.get_next_id(),
		"lineage": sim.lineage_export(),
		"radius": radius,
		"bup_limit": bup_limit,
		"nutrients_placed": nutrients_placed,
		"time": time,
		"food_rate": food_rate,
		"cells": saved_cells,
		"field": Array(field.values()),
		"sources": saved_sources,
		"bloom_rate": bloom_rate,
		"bloom_due": _bloom_due,
		"upkeep_factor": upkeep_factor,
		"plankton": saved_plankton,
		"history": history,
	}


## Returns false, leaving the dish exactly as it was, if the data is unusable. Everything is
## validated and built on the side first, so a bad save can never leave a half-loaded dish.
func from_dict(d: Dictionary) -> bool:
	if not (d.get("cells") is Array):
		return false
	for key in ["radius", "bup_limit", "nutrients_placed", "time", "food_rate", "bloom_rate"]:
		if d.has(key) and not Validate.is_number(d[key]):
			return false
	var loaded_cells := []
	for saved in d["cells"]:
		var spec := _cell_from_saved(saved)
		if spec.is_empty():
			return false
		loaded_cells.append(spec)
	var loaded_sources: Array[NutrientSource] = []
	var saved_sources = d.get("sources", [])
	if not (saved_sources is Array):
		return false
	for saved in saved_sources:
		if not (saved is Dictionary) or not Validate.is_vec2(saved.get("pos")) or not Validate.is_number(saved.get("rate")):
			return false
		var source := NutrientSource.new(global_position + _array_to_vec(saved["pos"]), clampf(float(saved["rate"]), MIN_SOURCE_RATE, MAX_SOURCE_RATE))
		if Validate.is_number(saved.get("emitted")):
			source.emitted = maxf(float(saved["emitted"]), 0.0)
		loaded_sources.append(source)
	loaded_sources.resize(mini(loaded_sources.size(), MAX_SOURCES))
	var loaded_plankton: Array[Plankton] = []
	var saved_plankton = d.get("plankton", [])
	if not (saved_plankton is Array):
		return false
	for saved in saved_plankton:
		if not (saved is Dictionary) or not Validate.is_vec2(saved.get("pos")) or not Validate.is_number(saved.get("burst_at")) or not Validate.is_number(saved.get("units")):
			return false
		var shape := float(saved["shape"]) if Validate.is_number(saved.get("shape")) else 0.0
		var born := float(saved["born_at"]) if Validate.is_number(saved.get("born_at")) else 0.0
		loaded_plankton.append(Plankton.new(_array_to_vec(saved["pos"]), born, float(saved["burst_at"]), maxf(float(saved["units"]), 0.0), shape))
	loaded_plankton.resize(mini(loaded_plankton.size(), MAX_PLANKTON))
	var loaded_radius := clampf(float(d.get("radius", DEFAULT_RADIUS)), StartConditions.MIN_SIM_RADIUS, StartConditions.MAX_DISH_RADIUS)
	var loaded_limit := clampi(int(d.get("bup_limit", cap_for(loaded_radius))), 1, StartConditions.MAX_BUP_LIMIT)
	var field_size := NutrientField.size_for(loaded_radius)
	var saved_field = d.get("field", [])
	if saved_field is Array and not is_equal_approx(loaded_radius, float(d.get("radius", DEFAULT_RADIUS))):
		saved_field = []  # the radius had to be clamped, so the saved grid no longer fits the dish: start with a clear medium
	if not (saved_field is Array) or (not saved_field.is_empty() and saved_field.size() != field_size * field_size):
		return false
	for v in saved_field:
		if not Validate.is_number(v):
			return false
	var saved_history = d.get("history", {})
	if not (saved_history is Dictionary):
		return false
	var loaded_history := {}
	for key in HISTORY_SERIES:
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
	radius = loaded_radius
	sim.reset(radius, -1)
	bup_limit = loaded_limit
	loaded_cells.resize(mini(loaded_cells.size(), loaded_limit))
	_render_stale = true
	edit_count += 1
	for spec in loaded_cells:
		sim.add_bup(spec["pos"], spec["genome"], spec["energy"], spec["size"], spec["birth_mass"], spec["generation"], spec["dir"], spec["id"])
	var saved_next = d.get("next_id")
	if Validate.is_number(saved_next):
		sim.set_next_id(int(saved_next))  # so the next bup born doesn't take a number already used
	var saved_lineage = d.get("lineage")
	if saved_lineage is Array:
		sim.lineage_import(saved_lineage.filter(_is_saved_record))
	field.load_values(saved_field)
	sources = loaded_sources
	plankton = loaded_plankton
	bloom_rate = float(d["bloom_rate"]) if Validate.is_number(d.get("bloom_rate")) else 0.0
	upkeep_factor = clampf(float(d["upkeep_factor"]) if Validate.is_number(d.get("upkeep_factor")) else 1.0, 1.0, 100.0)
	nutrients_placed = int(d.get("nutrients_placed", 0))
	time = float(d.get("time", 0.0))
	_bloom_due = float(d["bloom_due"]) if Validate.is_number(d.get("bloom_due")) else time
	food_rate = float(d["food_rate"]) if Validate.is_number(d.get("food_rate")) else food_rate
	_reset_runtime_state()
	for key in loaded_history:
		history[key] = loaded_history[key]
	# Samples are taken on multiples of the interval, so resume the timer part-way through one.
	_history_accum = fposmod(time, HISTORY_INTERVAL)
	return true


## One saved bup as the arguments for BupSim.add_bup, or an empty dictionary if it is unusable.
func _cell_from_saved(saved: Variant) -> Dictionary:
	if not (saved is Dictionary) or not Validate.is_vec2(saved.get("pos")) or not Validate.is_vec2(saved.get("dir")):
		return {}
	if not Validate.is_number(saved.get("energy")) or not Validate.is_number(saved.get("generation")) or not (saved.get("genome") is Dictionary):
		return {}
	if not Validate.is_number(saved.get("size")) or not Validate.is_number(saved.get("birth_mass")) or not Validate.is_number(saved.get("id")):
		return {}
	var body := clampf(float(saved["size"]), 0.5, 12.0)
	var born_with := clampf(float(saved["birth_mass"]), 0.25, body * body)
	return {
		"pos": _array_to_vec(saved["pos"]),
		"dir": _array_to_vec(saved["dir"]),
		"energy": float(saved["energy"]),
		"size": body,
		"birth_mass": born_with,
		"generation": int(saved["generation"]),
		"genome": Genome.from_saved(saved["genome"]),
		"id": int(saved["id"]),
	}


## A saved family record with every figure in it a number (anything else is dropped rather than trusted).
static func _is_saved_record(r: Variant) -> bool:
	if not (r is Dictionary) or not Validate.is_number(r.get("id")):
		return false
	for key in ["parent", "born", "died", "generation", "mutations", "speed", "sense", "metabolism", "size_gene", "hue", "sat", "val", "harm", "max_energy"]:
		if r.has(key) and not Validate.is_number(r[key]):
			return false
	if r.has("name") and not (r["name"] is String):
		return false
	return true


static func _vec_to_array(v: Vector2) -> Array:
	return [v.x, v.y]


static func _array_to_vec(a: Array) -> Vector2:
	return Vector2(a[0], a[1])


# --- Drawing ---------------------------------------------------------------------------------

## A solid glowing dot with no outline, so it can't be mistaken for a selection ring.
func _draw_source(source: NutrientSource) -> void:
	var p := source.pos - global_position
	var r := source_draw_radius()
	draw_circle(p, r * 2.0, Color(0.95, 0.8, 0.35, 0.18))
	draw_circle(p, r, Color(1.0, 0.85, 0.4, 1.0))
	draw_circle(p, r * 0.45, Color(1.0, 0.97, 0.8, 1.0))


func plankton_draw_radius() -> float:
	return maxf(PLANKTON_DRAW_RADIUS, PLANKTON_MIN_PIXELS * pixel())


## An amorphous green outline: no two are quite alike, and it is faint inside, so the nutrient haze shows through.
func _draw_plankton(cell: Plankton) -> void:
	var r := plankton_draw_radius()
	var outline := PackedVector2Array()
	for k in 17:
		var a := TAU * k / 16.0
		var wobble := 1.0 + 0.16 * sin(2.0 * a + cell.shape) + 0.1 * sin(3.0 * a + 2.0 * cell.shape)
		outline.append(cell.pos + Vector2.from_angle(a) * r * wobble)  # (the last point repeats the first, closing the outline)
	draw_colored_polygon(outline.slice(0, 16), Color(0.5, 0.9, 0.45, 0.1))
	draw_polyline(outline, Color(0.55, 0.95, 0.5, 0.85), 1.5 * pixel())
	draw_circle(cell.pos + Vector2.from_angle(cell.shape) * r * 0.25, r * 0.18, Color(0.55, 0.95, 0.5, 0.55))


## The dissolved nutrient as a faint amber haze, so gradients (and the depleted zones around a
## growing colony) can be seen. The grid is drawn as one smoothed texture, so a big dish costs one
## draw, not thousands; the texture is rebuilt a few times a second, not every frame.
func _draw_medium() -> void:
	var now := Time.get_ticks_msec()
	if _haze == null or _haze.get_width() != field.size or now - _haze_built > HAZE_REFRESH_MSEC:
		_haze_built = now
		var n := field.size
		var pixels := field.haze_bytes(Cell.DETECTION_FLOOR, 0.5 * 255.0 / sqrt(10.0 * Cell.HALF_SATURATION), 0.45 * 255.0)
		var image := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, pixels)
		if _haze == null or _haze.get_width() != n:
			_haze = ImageTexture.create_from_image(image)
		else:
			_haze.update(image)
	draw_texture_rect(_haze, Rect2(-radius, -radius, 2.0 * radius, 2.0 * radius), false)


## While a bup is selected, a cool tint over the places where it could steer: where the slope stands out from the
## noise in its own estimate of it (a keener or faster bup lights more of the dish; in a dilute medium nothing lights).
## Rebuilt a few times a second, like the haze it is drawn over.
func _draw_steering() -> void:
	if selected_id < 0 or not sim.has_bup(selected_id):
		return
	var key := [selected_id, field.size, Time.get_ticks_msec() / HAZE_REFRESH_MSEC]
	if key != _steer_key:
		_steer_key = key
		var n := field.size
		var image := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, sim.bup_steer_bytes(selected_id, STEER_ALPHA))
		if _steer == null or _steer.get_width() != n:
			_steer = ImageTexture.create_from_image(image)
		else:
			_steer.update(image)
	draw_texture_rect(_steer, Rect2(-radius, -radius, 2.0 * radius, 2.0 * radius), false)


## How many screen pixels one µm of this dish covers: the camera's zoom and the dish's own scale (a setup
## preview is a shrunken dish) together.
func screen_scale() -> float:
	return maxf(get_global_transform_with_canvas().get_scale().x, 0.0001)


## The size of one screen pixel in dish units (µm).
func pixel() -> float:
	return 1.0 / screen_scale()


## The radius, in screen pixels, of the ring around something `subject_px` across (radius): always
## RING_PIXELS, except that once the subject is more than half the ring's diameter the ring grows
## until the subject is a quarter of it.
static func ring_radius_pixels(subject_px: float) -> float:
	if subject_px > RING_GROW_ABOVE * RING_PIXELS:
		return subject_px / RING_GROW_TO
	return RING_PIXELS


## The rings on a selected and a hovered source or plankton (`offset` takes a thing's `pos` to the dish's own coordinates).
func _draw_pick_rings(canvas: CanvasItem, selected: Variant, hovered: Variant, offset: Vector2, radius: float) -> void:
	if selected != null:
		draw_ring(canvas, selected.pos - offset, radius, Color(1, 0.75, 0.3, 0.95))
	if hovered != null and hovered != selected:
		draw_ring(canvas, hovered.pos - offset, radius, Color(1, 1, 1, 0.9))


## A thin ring marking a bup or source: GUI, so the same size and line at every zoom (see
## ring_radius_pixels for the one case where it grows).
func draw_ring(canvas: CanvasItem, center: Vector2, object_radius: float, color: Color) -> void:
	var px := pixel()
	canvas.draw_arc(center, ring_radius_pixels(object_radius / px) * px, 0.0, TAU, 48, color, px)


func _draw() -> void:
	# Dish: dark agar, green-tinted glass rim.
	draw_circle(Vector2.ZERO, radius, Color(0.03, 0.06, 0.04))
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 96, Color(0.45, 0.8, 0.6, 0.6), 3.0)
	draw_arc(Vector2.ZERO, radius + 6.0, 0.0, TAU, 96, Color(0.45, 0.8, 0.6, 0.2), 2.0)

	_draw_medium()
	_draw_steering()
	for source in sources:
		_draw_source(source)
	for cell in plankton:
		_draw_plankton(cell)
	# The bups are a child node drawn on top of this; the rings and the lightning flash on top of them.


## A brighter stretch of the selection ring, centred on the way the bup's drift tends (up the slope), and shorter the
## more reliably it does: it narrows from the whole ring as the bup goes from guessing to certain.
func _draw_steering_arc(canvas: CanvasItem, id: int) -> void:
	var steering: Vector3 = sim.bup_steering(id)
	if steering.z < ARC_SHOWN_ABOVE:
		return
	var px := pixel()
	var span := maxf(2.0 * (1.0 - steering.z) * TAU, MIN_STEER_ARC)
	var heading := Vector2(steering.x, steering.y).angle()
	canvas.draw_arc(sim.bup_pos(id), ring_radius_pixels(sim.bup_radius(id, px) / px) * px, heading - span / 2.0, heading + span / 2.0, 24, Color(1, 0.95, 0.7, 1.0), 3.0 * px)


## What goes above the bups (called by the overlay child): the selection and hover rings, the
## placement preview, the flash. Rings are GUI, not part of the dish: the same size and a thin
## line at any zoom.
func draw_overlay(canvas: CanvasItem) -> void:
	var px := pixel()
	if selected_id >= 0 and sim.has_bup(selected_id):
		draw_ring(canvas, sim.bup_pos(selected_id), sim.bup_radius(selected_id, px), Color(1, 0.75, 0.3, 0.95))
		_draw_steering_arc(canvas, selected_id)
	if hovered_id >= 0 and hovered_id != selected_id and sim.has_bup(hovered_id):
		draw_ring(canvas, sim.bup_pos(hovered_id), sim.bup_radius(hovered_id, px), Color(1, 1, 1, 0.9))
	_draw_pick_rings(canvas, selected_source, hovered_source, global_position, source_draw_radius())
	_draw_pick_rings(canvas, selected_plankton, hovered_plankton, Vector2.ZERO, plankton_draw_radius())
	if place_preview_radius >= 0.0:
		var brush := Color(1, 0.3, 0.25, 0.9) if place_preview_erases else Color(1, 0.9, 0.5, 0.8)
		if place_preview_marker:
			draw_ring(canvas, place_preview_pos - global_position, place_preview_radius, brush)
		else:
			canvas.draw_arc(place_preview_pos - global_position, maxf(place_preview_radius, 3.0 * px), 0.0, TAU, 32, brush, px)
	if flash > 0.0:
		canvas.draw_circle(Vector2.ZERO, radius, Color(0.85, 0.95, 1.0, flash))
