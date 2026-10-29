class_name Dish
extends Node2D
## The petri dish. The simulation itself (bups, genomes, the dissolved nutrient, stepping) runs in
## the native BupSim (native/src), or on the GPU (GpuWorld); this node owns what surrounds it: selection and hover,
## layers, nutrient sources, plankton, the history graph's samples, the choice of backend, and loading a save. Its drawing
## is DishDrawing's (`drawing`) and its save format DishCodec's.
## Lengths are µm and times are seconds of simulation time, which runs at real biological rates
## (see Biology); the player's playback speed only multiplies how much of it passes per second.
## Bups are named by a stable id (an int), since the native arrays compact as bups die.

signal extinct
enum PickMode { ALL, BACKGROUND, BUPS, SOURCES, PLANKTON, HUSKS }  ## what the select tool looks at: everything (a source over a bup), only the medium, only bups, only sources, only plankton or only husks

signal selection_changed  ## the selected bup is now another (or none)

## The kinds of thing the dish draws, each of which can be hidden (a view choice only: nothing here touches the simulation).
## A hidden layer cannot be hovered or picked, but what is already selected stays selected (hiding the bups to see the steering map of the selected one, say).
enum Layer { MEDIUM, SOURCES, PLANKTON, BUPS, STEERING, HUSKS }  ## the nutrient haze, the feeders, the plankton, the bups, the steering map and arc of the selected bup, and the husks

const DEFAULT_RADIUS := 10000.0  ## µm: 10 mm, the dish before any start (the tests' dish too); goal mode and free mode start from StartConditions.DEFAULT_RADIUS
const NUTRIENT_SCATTER := 5.0  ## radius a dose spreads over, per sqrt(nutrient) in it
const MAX_CELLS := 300  ## the smallest carrying limit; see `cap_for`. Past the limit each birth displaces a random bup (a Moran process)
const MAX_SOURCES := 1000
const PLANKTON_UNITS := 300.0  ## nutrient a plankton releases when it bursts [choice: a patch a few minutes of chemotaxis can use; see SUGGESTED_BLOOM_DENSITY]
const PLANKTON_PATCH_RADIUS := 250.0  ## µm the released nutrient starts out spread over (a lysed cell's cloud: Stocker et al. 2008 used ~300 µm)
const PLANKTON_MEAN_LIFE := 3600.0  ## s a plankton floats on average before bursting [choice: lysis timing is random; no measured scale]
const PLANKTON_LIFE_SPREAD := 0.5  ## each one bursts at a random time from this share below to this share above the mean life, so the food keeps coming
const PLANKTON_DRAW_RADIUS := 40.0  ## µm: about a small diatom
const PLANKTON_MIN_PIXELS := 3.0  ## drawn at least this many screen pixels in radius
const PLANKTON_DETAIL_PIXELS := 8.0  ## plankton smaller than this on screen (radius, in pixels) are drawn from a small picture of one, all in a single draw: drawing thousands of outlines one by one is too slow
const PLANKTON_PICTURE_SIZE := 64  ## pixels across that picture
const PLANKTON_PICTURE_REACH := 1.3  ## how far from its centre, in plankton radii, the picture extends (the outline wobbles out to 1.26)
const PLANKTON_PICTURE_REFRESH_MSEC := 100  ## the placing of the pictures is rebuilt at most this often (plankton appear and burst all the time, and are not missed for a moment)
const MAX_PLANKTON := 20000  ## floating at once: the most the biggest dish at the most bloom holds (a plankton floats about an hour, so 10 per mm² a day on 25,000 mm² is about 10,600)
const MAX_WATCHED := 1000  ## the most bups on the watch list
const SUGGESTED_BLOOM_DENSITY := 0.08  ## plankton in each mm² every sim-day that the goal text suggests: about one an hour on a 10 mm dish, 300 units an hour
const GOAL_UPKEEP_FACTOR := 3.0  ## how much costlier staying alive is once goal mode reaches experiment 2 (set by the screen; 1 elsewhere) [x10 killed every colony tested at once; x3 did not]
const MAX_BLOOM_ARRIVALS_PER_STEP := 200  ## the most plankton one step lets the bloom add (the most there is, at the most bloom on the biggest dish, is about 60 in a 20 s step; a rate raised a great deal starts over)
const BURST_CHECK_SECONDS := 60.0  ## how often the plankton are looked over for ones that have burst (sim seconds): with thousands floating that is most of what they cost, and a minute is nothing against the hour they float
const BLOOM_DENSITY_STEP := 0.01  ## the bloom density moves in these steps (plankton in each mm² a sim-day)
const MIN_SOURCE_RATE := 0.5  ## nutrients per minute, like the global feed
const MAX_SOURCE_RATE := 60.0
const SOURCE_NEARBY := 60.0  ## how close counts as "near" a source in its details
const SOURCE_DRAW_RADIUS := 3.0  ## the size a source is drawn at, in µm: about a bup's, so the same selection ring fits both
const SOURCE_MIN_PIXELS := 3.0  ## a source is drawn at least this many screen pixels in radius
const HOVER_CLICK_PIXELS := 3.0  ## a click this close to where the hover was picked selects what the hover outlines
const DISC_SIDES := 720  ## sides of the dish's disc
const SOURCE_PICK_PIXELS := 9.0  ## and can be picked from at least this many pixels away
const SOURCE_PICK_RADIUS := 18.0  ## how close (in µm) a click must be to pick a source: generous, since it is small and often under bups
const ERASE_STRENGTH := 0.9  ## the share of nutrient the eraser takes from the middle of its brush
const DIFFUSE_INTERVAL := 5.0  ## seconds between solves of the nutrient field's diffusion (implicit, so long steps are fine)
const DIFFUSE_ACCURACY := 0.004  ## the most D dt / cell^2 one solve of the diffusion is allowed (how far the nutrient spreads in it, in cells): a longer stretch is solved in pieces, down to DIFFUSE_INTERVAL. See BupSim.diffuse_pieces
const MAX_STEP := 20.0  ## the longest single step, in seconds: growth, uptake and division are slow (doubling takes 40 minutes), so they run once per step
const HUSK_PIXELS := 3.0  ## a husk's dot on screen
const HUSK_REFRESH_MSEC := 100  ## how often the husks' picture is rebuilt while time moves
const HUSK_MIN_CAPACITY := 1024  ## the husk picture holds room for at least this many (it grows by doubling)
const HUSK_COLOR := Color(0.4, 0.29, 0.19, 0.75)
const RING_PIXELS := 12.0  ## the radius of a selection or hover ring, in screen pixels
const RING_GROW_ABOVE := 0.5  ## the ring only grows once its subject is more than this share of the ring's diameter ...
const RING_GROW_TO := 0.25  ## ... and then to the size where the subject is this share of it
const MAX_TRAIL_PIXELS := 80.0  ## the longest trail a fast bup is drawn with, in screen pixels
const TRAIL_FADE_PIXELS := 10.0  ## a trail is a third as bright this many screen pixels behind the bup, however fast it went
const HAZE_REFRESH_MSEC := 100  ## how often the picture of the dissolved nutrient is rebuilt
const STEER_ALPHA := 0.35 * 255.0  ## the most opaque the steering map gets (where a bup is sure to end up further up the slope)
const MIN_STEER_ARC := deg_to_rad(15.0)  ## the narrowest arc on the selection ring: how reliably its drift tends one way
const ARC_SHOWN_ABOVE := 0.54  ## the chance that it ends up further up the slope after a minute (0.5 a coin toss, 1 sure: see BupSim.bup_steering) above which the arc shows
const MOTION_STEP := 3.0  ## the longest motion sub-step on a fine nutrient grid, in seconds: a swimmer must not jump farther than a gradient is wide (~50-100 µm; a bup diffuses ~40 µm in 3 s). On a coarser grid it grows, see MOTION_STRUCTURE
const MOTION_STRUCTURE := 500.0  ## µm: the size of the smallest structure in the nutrient worth looking for (a plankton cloud: a patch of 250 µm radius, spread by hours of diffusion). Where grid cells are bigger than this the motion sub-step grows with the square of the cell (BupSim.moves_for), since a bup sees no more by looking again after moving a short way across one
const CLOUD_HANDOVER := 0.5  ## a plankton's nutrient is kept as a Gaussian cloud (BupSim's NutrientField) until its sigma is this share of a grid cell, then given to the grid
const STEERING_WINDOW := 3600.0  ## seconds of swimming over which the steering readout asks whether a bup ends up further up the slope: an hour, about a generation and a half. Shorter and nearly every bup reads blind (a minute of drift is lost in its random walk wherever the slope is gentle); at an hour the words spread from blind where it is flat to sure on a cloud's flank (measured on 10 mm and 90 mm dishes at 100 h: about 40% blind, 30% faint, 15% clear, 15% sure)
const CLOUD_CUT := 0.1  ## a cloud is looked for out to where it falls to this share of the detection floor (about 3-4 sigma): beyond, it is nothing a bup can tell from the medium or use
const FINE_STEP := 0.25  ## steps this short or shorter follow individual runs and tumbles
const NUTRIENT_ENERGY := 16.0  ## the energy in one unit of nutrient: the unit of every feed, dose and source
const NUTRIENT_PATCHINESS := 0.2  ## how uneven the nutrient put into the dish is: the spread of its density as a share of the mean, richer and poorer patches within patches at every scale [choice: no measured scale; gentle: patches you can see without starving a founder's neighbourhood]
const CONCENTRATION_PER_DENSITY := NUTRIENT_ENERGY / 1.0e6  ## the concentration (energy per µm²) that one unit of nutrient per mm² makes: the field holds concentrations, so a density chosen in units/mm² goes in as it is
const FOUNDER_ENERGY := 100.0  ## enough reserve to find a first meal in a sparse dish
const DIVISION_SPREAD := 0.03  ## how unevenly a division splits the mother: the daughters' sizes vary a few percent
const FIELD_TARGET_SPACING := 25.0  ## µm: plumes at the real diffusion are 50-100 µm wide, so a 25 µm grid resolves them
const FIELD_MIN_ACROSS := 48  ## small dishes keep a fine grid (a 300 µm dish gets 12.5 µm cells)
const FIELD_MAX_ACROSS := 100  ## a cost limit: the solve takes time in proportion to the cells (about 0.1 ms for this grid, once per step), and top playback speed depends on it
const RENDER_MIN_CAPACITY := 256  ## the fewest bups the picture has room for
const HISTORY_INTERVAL := 120.0  ## seconds between samples of the history graph
const HISTORY_LEN := 5040  ## 168 hours (a week) of samples: the longest span of the fine history the graph shows
const HISTORY_ALL_LEN := 1024  ## how many samples the whole-run history holds before its neighbours are merged in pairs (see `history_all`)
const HISTORY_SERIES := ["pop", "speed", "sense", "metabolism", "size", "harm", "mutator", "donor", "key", "generation"]  ## population, each gene's mean, mean harm (%) and the mean mutation rate (a multiple of the usual)

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
var acetate: NutrientField = sim.get_acetate()  ## the second food, what fast growers let go of (same grid as `field`, no clouds)
var drawing := DishDrawing.new(self)  ## how the dish is drawn: the bups' and husks' pictures, the dish, the rings above the bups
var radius := DEFAULT_RADIUS:  ## physical size of the dish; it changes only with a new dish (`strike`, a load) or `resize_to`
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
var feed_density := 3.0:  ## units of nutrient fed in to each mm² of the dish every hour, spread evenly (a density, so the dish's size does not change it)
	set(value):
		feed_density = clampf(value, 0.0, StartConditions.MAX_FEED_DENSITY)
var medium_thickness := Biology.MEDIUM_THICKNESS  ## how many times thicker than water the medium is (see StartConditions.medium_thickness)
var bloom_density := 0.0:  ## plankton appearing in each mm² of the dish every sim-day (24 hours), at steady intervals, at random places (a density: the dish's size sets how many a day that is, see `bloom_per_day`)
	set(value):
		if value > 0.0 and bloom_density <= 0.0:
			_bloom_due = time  # (turned on: the first appears at once)
		bloom_density = clampf(value, 0.0, StartConditions.MAX_BLOOM_DENSITY)
var _bloom_due := 0.0  ## when the bloom's next plankton appears
var _burst_clock := 0.0  ## sim seconds since the plankton were last looked over for bursts
var _first_burst := -INF  ## no plankton bursts before this sim time, so the look-over can be skipped until then (-INF: not known, look). Never later than the first one due: a plankton added lowers it, a look-over sets it exactly, and plankton taken out leave it as it was (early is safe)
var death_husks := false:  ## a dead bup leaves a husk that leaks its nutrient back over Biology.HUSK_SECONDS instead of giving it back at once (see StartConditions.death_husks)
	set(value):
		death_husks = value
		sim.set_death_husks(value)
var plankton_husks := false  ## a plankton that dies leaves a husk that leaks its nutrient back over Biology.HUSK_SECONDS instead of bursting into a cloud (see StartConditions.plankton_husks)
var stationary_phase := false:  ## starving bups stop growing, shrink and die at a constant rate (Biology.STARVE_*) instead of dying when the reserve is gone: free mode's option, never on in goal mode (see StartConditions.stationary_phase)
	set(value):
		stationary_phase = value
		sim.set_stationary_phase(value)
var upkeep_factor := 1.0:  ## multiplies what staying alive costs every bup (its base and per-mass maintenance)
	set(value):
		upkeep_factor = maxf(value, 0.0)
		sim.set_upkeep_scale(upkeep_factor)
var plankton: Array[Plankton] = []
var time := 0.0:
	set(value):
		time = value
		sim.set_time(value)  # births and deaths are stamped from the simulation's own copy
var picture_scale := 0.0  ## above 0 (a dish that is not in the main view): the pixels one µm covers in its small picture in the strip, so its bups are drawn as big as that picture needs
var flash := 0.0  ## lightning flash intensity, decays to 0
var _layers_hidden := {}  ## Layer -> true for each one hidden

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
		if not looks_at_husks():
			selected_husk = NO_HUSK
var _hover_pos := Vector2.ZERO  ## where the pointer was when `hovered_id` and the other hovers were picked
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
const NO_HUSK := Vector2(INF, INF)
var selected_husk := NO_HUSK  ## where the clicked husk lies (a husk has no identity: it is found by its place), or NO_HUSK
var hovered_husk := NO_HUSK
var place_preview_pos := Vector2.ZERO
var place_preview_radius := -1.0  ## < 0 hides the placement preview
var place_preview_erases := false  ## the preview is the eraser's brush
var place_preview_marker := false  ## the preview marks a single point (a source about to be placed): drawn as a GUI ring, like a selection

## Sampled every HISTORY_INTERVAL sim-seconds; oldest samples drop off the front.
var history := {}
## The whole run, in no more than HISTORY_ALL_LEN samples: each is the mean of `history_all_factor` samples of `history`,
## and when it fills up the neighbours are merged in pairs and the factor doubles. So a run of any length is kept, thinner
## the longer it gets. Sample i ends at (i + 1) * history_all_factor * HISTORY_INTERVAL.
var history_all := {}
var history_all_factor := 1
var _all_sums := {}  ## the running sums for the next whole-run sample
var _all_count := 0  ## how many samples of `history` are in them

## Bumped whenever the history gains or loses a sample, so views can redraw only on change.
var history_version := 0
## The world time this dish's history began at (a dish that joins a running world begins at its time): the graph shows a dish's own time from here.
var history_origin := 0.0

var edit_count := 0  ## bumped by every change made to the dish by hand (a bup or source added or removed, nutrient dropped or erased), so screens can tell when to look again
var _render_stamp := []  ## what the bups' picture was last built from
var _render_stale := true  ## the bups were changed by hand (added, removed, a new dish), so the picture must be rebuilt
var _trails_may_show := false  ## the last picture was made as time moved, so bups in it may be drawn with trails
var _extinct_signalled := false
var _history_accum := 0.0
var _bups_mesh: MultiMeshInstance2D = null  ## all the bups, drawn in one go
var _husks_mesh: MultiMeshInstance2D = null  ## every husk, as one instance each
var _overlay: Node2D = null  ## the selection and hover rings, drawn above the bups
## The GPU path (gpu/gpu_world.gd): while `gpu_active`, the GPU runs the bups and answers for them; everything the dish asks the
## simulation about the bups goes to `gpu_world` (through `_bups`, or a branch on `runs_on_gpu` where the two answer differently),
## and the CPU's BupSim keeps the records, names and pins.
## `_choose_backend` makes `gpu_world` and switches (see the GPU path's functions at the end of this file).
var gpu_world: GpuWorld = null
var backend := DishBackend.new()  ## where the bups run, and what Auto's rule keeps to decide it
var gpu_active := false


func _init() -> void:
	SimConstants.apply()
	sim.set_husk_seconds(Biology.HUSK_SECONDS)
	sim.set_limit(bup_limit)
	sim.reset(DEFAULT_RADIUS, 1)


## A dish that is freed gives back the buffers, shaders and pipelines its GPU simulation made on the main device.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and gpu_world != null and gpu_world.gpu != null and gpu_world.gpu.is_main:
		RenderingServer.call_on_render_thread(gpu_world.gpu.release)


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR  # the haze is a small texture stretched over the dish
	set_seed(Time.get_ticks_usec())
	_reset_history()
	drawing.build_children()


## The random numbers are the native simulation's; tests set a seed to make a run repeatable.
func set_seed(value: int) -> void:
	sim.set_seed(value)


## Redraws the dish only when something it shows may have changed (DishDrawing.refresh).
func refresh_drawing() -> void:
	drawing.refresh()


## Fits the bups' picture to the bups there are and to the dish's size (the radius and the limit change it).
func _sync_render_capacity() -> void:
	drawing.sync_render_capacity()


## The lightning flash fades in real time, so it still clears while the sim is paused. The bups' and the husks'
## pictures are refreshed here, once a frame (DishDrawing.process).
func _process(delta: float) -> void:
	flash = maxf(0.0, flash - delta * 1.5)
	drawing.process()


## Makes the bups' picture for the strip's small one of this dish, `scale` pixels to the µm, just before the strip has it drawn (the GPU's dishes are drawn every frame).
func prepare_picture(scale: float) -> void:
	drawing.prepare_picture(scale)


## Everything that belongs to one run of a dish and must start fresh with a new or loaded dish.
func _reset_runtime_state() -> void:
	moved_out.clear()
	watched.clear()  # (the simulation was reset, so its records, and the pins on them, are gone)
	watch_version += 1
	clear_selection()
	clear_hover()
	_extinct_signalled = false
	_reset_history()


func _reset_history() -> void:
	history = {}
	history_all = {}
	_all_sums = {}
	for series in HISTORY_SERIES:
		history[series] = []
		history_all[series] = []
		_all_sums[series] = 0.0
	history_all_factor = 1
	_all_count = 0
	_history_accum = 0.0
	history_origin = 0.0
	history_version += 1


## Abiogenesis: founders appear near the centre, part-way through their first growth (no divisions in their line: nothing precedes them).
## Every mode starts a dish through here, so setup can't drift between modes.
## The medium: the nutrient spreads at the speed of water over this many. The usual thickness leaves the field to the
## simulation's own constant (SimConstants), so that anything that sets that one (the tests holding the nutrient still) still does.
func _set_medium_thickness(thickness: float) -> void:
	medium_thickness = thickness
	field.set_diffusion(0.0 if is_equal_approx(thickness, Biology.MEDIUM_THICKNESS) else Biology.WATER_DIFFUSION / thickness)


func strike(start: StartConditions = null) -> void:
	if start == null:  # goal mode's dish: the usual conditions, and founders in evenly spaced colours (more interesting than all green)
		start = StartConditions.new()
	if runs_on_gpu():
		_discard_gpu_state()  # (a new dish: what the GPU holds, and every result still on its way, is for the old one)
	set_backend_setting(start.sim_backend)
	backend.fresh = true
	flash = 1.0
	_render_stale = true
	edit_count += 1
	time = 0.0
	nutrients_placed = 0
	sources.clear()
	plankton.clear()
	_first_burst = -INF
	bloom_density = start.bloom_density
	_bloom_due = time  # (a new dish's bloom starts now: the setter does this only when the bloom is switched on, and the last dish may have had the same)
	_burst_clock = 0.0
	upkeep_factor = 1.0
	death_husks = start.death_husks
	plankton_husks = start.plankton_husks
	stationary_phase = start.stationary_phase
	_reset_runtime_state()
	radius = clampf(start.dish_radius, StartConditions.MIN_SIM_RADIUS, StartConditions.MAX_DISH_RADIUS)
	field.set_max_across(clampi(start.nutrient_resolution, StartConditions.MIN_NUTRIENT_RESOLUTION, StartConditions.MAX_NUTRIENT_RESOLUTION))
	_set_medium_thickness(start.medium_thickness)
	sim.reset(radius, -1)  # a new dish: no bups, no nutrient, the random stream carries on
	bup_limit = start.bup_limit
	feed_density = start.feed_density
	var bups := clampi(start.bups, 1, bup_limit)
	var spread := minf(radius * 0.8, 40.0 + 40.0 * sqrt(maxf(bups - 4.0, 0.0)))  # (the founders start in a disc that grows with their number, 4 in a spot 40 µm across, 100 across about 430 µm)
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
	patch_seed = int(sim.random_float() * 2147483647.0)
	field.set_patchiness(NUTRIENT_PATCHINESS, radius, patch_seed)  # (the largest patches about the size of the dish; the feed follows the same landscape)
	field.fill(clampf(start.nutrient_density, 0.0, StartConditions.MAX_NUTRIENT_DENSITY) * CONCENTRATION_PER_DENSITY)  # the medium the colony starts in
	_mark_gpu_dirty()  # (a new dish: what the GPU held is gone)


## Changes the dish's size about its centre, with everything in it.
## Larger: the bups, the nutrient (spread over the new grid, none of it lost) and the sources stay where they are.
## Smaller: everything past the new edge goes. Bups there die like any other death (a family record with no living
## descendants, and not open in a panel, is freed with them), and so do the sources and plankton and the nutrient there.
## The feed and the bloom are densities, so they stay as they were and the dish gets as many more or fewer as its area changes.
func resize_to(new_radius: float) -> void:
	new_radius = clampf(new_radius, StartConditions.MIN_DISH_RADIUS, StartConditions.MAX_DISH_RADIUS)
	if is_equal_approx(new_radius, radius):
		return
	_edit_on_cpu(func() -> void:
		if new_radius > radius:
			sim.grow(new_radius)  # the bups and the nutrient stay
		else:
			sim.shrink(new_radius)
			for source in sources.duplicate():
				if source.pos.distance_to(global_position) > new_radius:
					remove_source(source)
			for i in range(plankton.size() - 1, -1, -1):
				if plankton[i].pos.length() > new_radius:
					if selected_plankton == plankton[i]:
						selected_plankton = null
					if hovered_plankton == plankton[i]:
						hovered_plankton = null
					plankton.remove_at(i)
		radius = new_radius
		edit_count += 1
		_render_stale = true
		queue_redraw())


## Changes how many bups the dish holds, without ever going below how many there are now.
func change_limit(value: int) -> void:
	_edit_on_cpu(func() -> void: bup_limit = maxi(value, population()))


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
	_choose_backend(delta, steps)
	if runs_on_gpu():
		return _advance_gpu(seconds)
	var started := Time.get_ticks_usec()
	var done := 0.0
	for i in steps:
		step(delta)
		done += delta
		if budget_usec > 0 and Time.get_ticks_usec() - started > budget_usec:
			break
	return done


## One step of exactly `delta` simulated seconds: no splitting into MAX_STEP pieces, no time budget and no choice of backend (a dish already on the GPU
## steps there). `advance` is the playback entry point; this is for the title screen's backdrop and for tests and tools that pin the step length.
func step(delta: float) -> void:
	if runs_on_gpu():
		_advance_gpu(delta)
		return
	var world := _step_world(delta)
	sim.step(delta, world["positions"], world["rates"], feed_per_second(feed_density), time)  # (time, so births and deaths are stamped with it)
	if world["sample"]:
		_record_history()  # (also once the colony has died out, so the graph's time stays true)
	_signal_if_extinct(sim.bup_count())


## The nutrient the feed adds every second, as a concentration, for a feed of `density` units to each mm² every hour.
static func feed_per_second(density: float) -> float:
	return density * CONCENTRATION_PER_DENSITY / 3600.0


## The part of a step that is the same on both backends, before the bups' own: the clock moves on `delta`, the plankton arrive and burst,
## the sources count what they release, and the history's clock moves. Returns the sources' places in the dish ("positions") and rates
## ("rates"), for the simulation's step, and whether a history sample is due after it ("sample").
func _step_world(delta: float) -> Dictionary:
	time += delta
	_step_plankton(delta)
	var positions := PackedVector2Array()
	var rates := PackedFloat32Array()
	for source in sources:
		positions.append(source.pos - global_position)
		rates.append(source.rate)
		source.emitted += source.rate / 60.0 * delta
	var sample := false
	_history_accum += delta
	if _history_accum >= HISTORY_INTERVAL:
		_history_accum -= HISTORY_INTERVAL
		sample = true
	return {"positions": positions, "rates": rates, "sample": sample}


## Emits `extinct` once, on the way down (not on every step after), when `count` bups are left and that is none.
func _signal_if_extinct(count: int) -> void:
	if count == 0 and time > 0.0 and not _extinct_signalled:
		_extinct_signalled = true
		extinct.emit()


func _record_history() -> void:
	_record_history_from(sim.population_stats())


## One sample of the history graph from these figures (BupSim.population_stats' keys). The GPU path records its samples, taken on
## the GPU at the steps they belong to, through this too.
func _record_history_from(stats: Dictionary) -> void:
	history["pop"].append(stats["count"])
	if stats["count"] == 0 and not history["harm"].is_empty():  # (nobody left to average: the traits stay as they last were)
		for series in HISTORY_SERIES:
			if series != "pop":
				history[series].append(history[series][-1])
	else:
		for gene in Genome.GENES:
			history[gene].append(stats[gene])
		history["harm"].append(stats["harm"] * 100.0)
		history["mutator"].append(stats["mutator"])
		history["donor"].append(stats["donor"] * 100.0)
		history["key"].append(stats["key"] * 100.0)
		history["generation"].append(stats["generation"])
	if history["pop"].size() > HISTORY_LEN:
		for series in history.values():
			series.pop_front()
	for series in HISTORY_SERIES:
		_all_sums[series] += history[series][-1]
	_all_count += 1
	if _all_count >= history_all_factor:
		for series in HISTORY_SERIES:
			history_all[series].append(_all_sums[series] / _all_count)
			_all_sums[series] = 0.0
		_all_count = 0
		if history_all["pop"].size() >= HISTORY_ALL_LEN:
			_thin_history_all()
	history_version += 1


## Merges the whole-run history's neighbours in pairs (each the mean of two), so it holds twice the time in half the samples.
func _thin_history_all() -> void:
	for series in HISTORY_SERIES:
		var samples: Array = history_all[series]
		var merged := []
		for i in range(0, samples.size() - 1, 2):
			merged.append((samples[i] + samples[i + 1]) * 0.5)
		history_all[series] = merged
	history_all_factor *= 2


# --- The bups --------------------------------------------------------------------------------

## Whether the GPU runs the bups now (it then answers every question about them: see `_bups`).
func runs_on_gpu() -> bool:
	return gpu_world != null and gpu_active


## What answers the questions about the bups that both backends answer alike (BupSim and GpuWorld have the same calls for them):
## `gpu_world` while it runs the bups, else `sim`. Asked again at every call, since a switch (or a tool) changes `gpu_active`.
func _bups() -> Object:
	if runs_on_gpu():
		return gpu_world
	return sim


func population() -> int:
	return _bups().bup_count()


func has_bup(id: int) -> bool:
	return id >= 0 and sim.has_bup(id)


func bup_ids() -> PackedInt64Array:
	if runs_on_gpu():
		return sim.alive_ids()  # (the bups are on the GPU; their records are here)
	return sim.bup_ids()


## Everything about one bup (see BupSim.bup_info): its position is relative to the dish centre.
func bup_info(id: int) -> Dictionary:
	return _bups().bup_info(id)


## The bup's position in the world, like the sources'.
func bup_world_pos(id: int) -> Vector2:
	return global_position + _bup_pos(id)


## Whether the bup is alive and its place is known, so it can be drawn round. On the GPU path a bup chosen by its id (the watch list, the
## lineage) has no place for the few frames until its record comes back.
func _bup_shown(id: int) -> bool:
	return sim.has_bup(id) and (not runs_on_gpu() or gpu_world.knows(id))


## The bup's position in the dish (relative to its centre).
func _bup_pos(id: int) -> Vector2:
	return _bups().bup_pos(id)


## Half the length the bup is drawn at (BupSim.bup_radius).
func _bup_radius(id: int, pixel_um: float) -> float:
	return _bups().bup_radius(id, pixel_um)


## Which way the bup's drift tends where it is and how surely (BupSim.bup_steering).
func bup_steering(id: int) -> Vector3:
	return _bups().bup_steering(id)


## The nutrient at a point of the dish: concentration, and the gradient's x and y (NutrientField.read). On the GPU path `field` is
## the copy of the GPU's field, so this is the same call there.
func nutrient_reading(local: Vector2) -> Vector3:
	return field.read(local)


## Puts the dish, and everything it draws, on one render layer of the 2D world (bit 0 is the default layer, which the rest of the screen is on). A camera that does not
## look at that layer does not see the dish, so a dish never shows beside another however far the view is zoomed out.
func set_view_layer(bit: int) -> void:
	for node: Node in [self] + find_children("*", "CanvasItem", true, false):
		(node as CanvasItem).visibility_layer = 1 << bit


## A dish that joins a world already under way begins at the world's time, and its bloom begins then too (not catching up on the time before).
func begin_at(world_time: float) -> void:
	time = world_time
	history_origin = world_time
	_bloom_due = time


## Adds a bup at a world position and returns its id. `size` is its body now (the square root of
## its mass); negative means a newborn of this genome.
func add_bup(world_pos: Vector2, genome: Dictionary, energy: float, size := -1.0, birth_mass := -1.0, divisions := 0, dir := Vector2.RIGHT, id := -1) -> int:
	return _edit_on_cpu(func() -> int:
		_render_stale = true
		edit_count += 1
		return sim.add_bup(world_pos - global_position, genome, energy, size, birth_mass, divisions, dir, id))


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


## What a panel shows for a bup, from one look-up: {"name", "info"} (its info or family record; empty if there is no record).
func bup_display(id: int) -> Dictionary:
	var info := lineage_info(id)  # (a living GPU bup's present size, for the swatch's length)
	if info.is_empty():
		return {}
	var custom := sim.custom_name(id)
	return {
		"name": custom if custom != "" else BupNames.default_name(info["size_gene"], id),
		"info": info,
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


## Everything known about a bup, alive or dead, as BupSim.lineage_info (empty once its record is dropped), with a living bup's present figures from the GPU when it runs there.
## Dead bups keep a record while a living bup descends from them or something is pinning them.
func lineage_info(id: int) -> Dictionary:
	var info := sim.lineage_info(id)
	if not info.is_empty() and info["alive"] and runs_on_gpu():
		info.merge(gpu_world.bup_info(id), true)  # (a bup on the GPU: the simulation here has only its record, which does not hold its size and reserve now)
	if moved_out.has(id):
		info["moved_to"] = moved_out[id]
	return info


## The pipette's taking half: every bup whose centre is within `disc_radius` of the world point leaves this dish and comes back as records (relative to the
## point, to be dropped into another dish with `add_transferred`). A hand edit (`_edit_on_cpu`).
func take_in_disc(world_pos: Vector2, disc_radius: float) -> PackedByteArray:
	return _edit_on_cpu(func() -> PackedByteArray:
		edit_count += 1
		_render_stale = true
		taken_lineage = sim.lineage_export_bytes()  # (the family records as they are before the bups leave, for the dish they go to)
		return sim.take_disc(world_pos - global_position, disc_radius))


## The pipette's giving half: the records `take_in_disc` made come in as the same bups (same ids, so the same names, genes and colours) at the middle of the dish (a
## droplet), with their whole family tree (`lineage`, from the dish they left: dead ancestors included, and the ones that stayed behind as dead here). Returns their ids.
func add_transferred(records: PackedByteArray, lineage: PackedByteArray) -> PackedInt64Array:
	return _edit_on_cpu(func() -> PackedInt64Array:
		var ids := sim.add_state_bytes(records, Vector2.ZERO, true)
		sim.lineage_import_bytes(lineage, PackedInt64Array())
		edit_count += 1
		_render_stale = true
		return ids)


## For each of these ids, how many bups alive in this dish have it in their family line (itself included).
func living_descendants(ids: PackedInt64Array) -> PackedInt32Array:
	return sim.living_descendants_of(ids)


## The family line that led to a bup: its oldest known ancestor first, the bup itself last.
func lineage_chain(id: int) -> PackedInt64Array:
	return sim.lineage_chain(id)


func has_record(id: int) -> bool:
	return id >= 0 and sim.has_record(id)


## Asks for a bup's record (and its ancestors') to be kept after it dies, until it is unpinned.
func pin_bup(id: int) -> void:
	sim.pin(id)


## The bups the player is watching, newest first (see watch_bup). Their records, and their ancestors', are kept.
var patch_seed := 0  ## which landscape of richer and poorer patches the nutrient follows (see NUTRIENT_PATCHINESS)
var watched: Array[int] = []
var taken_lineage := PackedByteArray()  ## the family records as they were when the last pipette took bups out (see take_in_disc)
var view_zoom := 0.0  ## where the screen was looking at this dish when it last looked away: the camera's zoom (0: never looked yet) ...
var view_position := Vector2.ZERO  ## ... and its position
var moved_out := {}  ## the ids of bups the pipette took out of this dish -> the number of the dish they went to (kept for the records that outlast them)
var watch_version := 0  ## bumped whenever the list changes, so its panel can rebuild only then


func is_watched(id: int) -> bool:
	return watched.has(id)


## Adds a bup, alive or dead, to the watch list, and keeps its record and its ancestors' until it is taken off. False if
## it has no record, is already there, or the list is full.
func watch_bup(id: int) -> bool:
	if not has_record(id) or watched.has(id) or watched.size() >= MAX_WATCHED:
		return false
	pin_bup(id)
	watched.push_front(id)
	watch_version += 1
	return true


func unwatch_bup(id: int) -> void:
	if watched.has(id):
		watched.erase(id)
		unpin_bup(id)  # (that may drop its record, if nothing else needs it now)
		watch_version += 1


func unpin_bup(id: int) -> void:
	sim.unpin(id)


func remove_bup(id: int) -> void:
	_edit_on_cpu(func() -> void:
		_render_stale = true
		edit_count += 1
		sim.remove_bup(id))


func clear_bups() -> void:
	_edit_on_cpu(func() -> void:
		_render_stale = true
		edit_count += 1
		sim.clear_bups())


## The count and averages the readouts show (each gene, "harm" as a share of yield lost, "mutations"), and "generation", the population's: the mean of its bups' divisions (a pipette keeps the bups' counts, so the dish it founds carries on the count of the dish it came from).
func population_stats() -> Dictionary:
	return _bups().population_stats()


func fraction_with_gene_at_least(gene: String, threshold: float) -> float:
	if not _fractions_asked.has([gene, threshold]):
		if _fractions_asked.size() >= GpuKernels.FRACTIONS:
			_fractions_asked.clear()  # (asked for something else now: the old pairs go)
		_fractions_asked[[gene, threshold]] = true
	return _bups().fraction_with_gene_at_least(gene, threshold)


## The id of the bup under a world position, or -1. `slack` widens the target (e.g. for small bups). (Not through `_bups`: the GPU's
## pick takes whether it is a hover, BupSim's does not.)
func cell_at(world_pos: Vector2, slack: float = 0.0, hover := false) -> int:
	if runs_on_gpu():
		return gpu_world.pick_bup(world_pos - global_position, slack, pixel(), hover)
	return sim.pick_bup(world_pos - global_position, slack, pixel())


## The distance to the nearest bup (-1 if there is none) and how many lie within `near` of a point of the dish.
func _nearest_and_count(local: Vector2, near: float) -> Vector2:
	return _bups().nearest_and_count(local, near)


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
	if _hover_is_at(world_pos):  # (a click where the pointer rests takes what is outlined: in a crowd that moves, a fresh pick would often be another bup)
		selected_source = hovered_source
		selected_id = hovered_id
		selected_plankton = hovered_plankton
		selected_husk = hovered_husk
		return
	var picked := _pick(world_pos, slack)
	selected_source = picked["source"]
	selected_id = picked["bup"]
	selected_plankton = picked["plankton"]
	selected_husk = picked["husk"]


## Whether something is outlined by a hover made at (nearly) this point.
func _hover_is_at(world_pos: Vector2) -> bool:
	var something := hovered_id >= 0 or hovered_source != null or hovered_plankton != null or hovered_husk != NO_HUSK
	return something and _hover_pos.distance_to(world_pos) <= HOVER_CLICK_PIXELS * pixel()


func hover_at(world_pos: Vector2, slack: float = 0.0) -> void:
	_hover_pos = world_pos
	var picked := _pick(world_pos, slack, true)
	hovered_source = picked["source"]
	hovered_id = picked["bup"]
	hovered_plankton = picked["plankton"]
	hovered_husk = picked["husk"]


## What is under a world position, of the kinds the pick mode looks at: only the first of a source, a bup, a plankton and a husk
## (in that order) that is there, the others being none.
func _pick(world_pos: Vector2, slack: float, hover := false) -> Dictionary:
	var source: NutrientSource = source_at(world_pos, slack) if looks_at_sources() else null
	var bup := cell_at(world_pos, slack, hover) if source == null and looks_at_bups() else -1
	var floating: Plankton = plankton_at(world_pos, slack) if source == null and bup < 0 and looks_at_plankton() else null
	var husk := husk_at(world_pos, slack) if source == null and bup < 0 and floating == null and looks_at_husks() else NO_HUSK
	return {"source": source, "bup": bup, "plankton": floating, "husk": husk}


## Whether a bup, a source, a plankton or a husk is selected.
func has_selection() -> bool:
	return selected_id >= 0 or has_selected_thing()


## Whether a source or a plankton is selected (what is picked besides a bup).
func has_selected_thing() -> bool:
	return selected_source != null or selected_plankton != null or selected_husk != NO_HUSK


## Lets go of everything selected.
func clear_selection() -> void:
	selected_id = -1
	selected_source = null
	selected_plankton = null
	selected_husk = NO_HUSK


func looks_at_sources() -> bool:
	return layer_shown(Layer.SOURCES) and (pick_mode == PickMode.ALL or pick_mode == PickMode.SOURCES)


func looks_at_plankton() -> bool:
	return layer_shown(Layer.PLANKTON) and (pick_mode == PickMode.ALL or pick_mode == PickMode.PLANKTON)


## Whether the dish can have husks at all: a dead bup or a dying plankton leaves one only with its switch on.
func has_husks() -> bool:
	return death_husks or plankton_husks


func looks_at_husks() -> bool:
	return layer_shown(Layer.HUSKS) and (pick_mode == PickMode.ALL or pick_mode == PickMode.HUSKS) and sim.husk_count() > 0


func looks_at_bups() -> bool:
	return layer_shown(Layer.BUPS) and (pick_mode == PickMode.ALL or pick_mode == PickMode.BUPS)


func layer_shown(layer: Layer) -> bool:
	return not _layers_hidden.has(layer)


## Shows or hides a layer. What it hides can no longer be pointed at (a hover on it is let go), but a selection stays.
func show_layer(layer: Layer, shown: bool) -> void:
	if shown == layer_shown(layer):
		return
	if shown:
		_layers_hidden.erase(layer)
	else:
		_layers_hidden[layer] = true
	match layer:
		Layer.BUPS:
			_bups_mesh.visible = shown
			_render_stale = true  # (what was not drawn while hidden is drawn afresh)
			if not shown:
				hovered_id = -1
		Layer.SOURCES:
			if not shown:
				hovered_source = null
		Layer.PLANKTON:
			if not shown:
				hovered_plankton = null
		Layer.HUSKS:
			_husks_mesh.visible = shown
			if not shown:
				hovered_husk = NO_HUSK
	queue_redraw()
	_overlay.queue_redraw()


## Whether the readout of the medium under the pointer is wanted: when looking at everything (where nothing else is
## under the pointer) or at the background alone.
func looks_at_medium() -> bool:
	return pick_mode == PickMode.ALL or pick_mode == PickMode.BACKGROUND


func clear_hover() -> void:
	hovered_id = -1
	hovered_source = null
	hovered_plankton = null
	hovered_husk = NO_HUSK
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


## The husk under a world position (within its drawn size, plus `slack`): its place in the dish, or NO_HUSK.
func husk_at(world_pos: Vector2, slack: float = 0.0) -> Vector2:
	var found := sim.husk_near(world_pos - global_position, husk_draw_size() * 0.5 + slack)
	return Vector2(found[0], found[1]) if found.size() == 5 else NO_HUSK


## What there is to know about the husk at a place in the dish (empty once it has leaked away): how long it has lain, the nutrient it still holds, where it is,
## and what is near.
func husk_details(local: Vector2) -> Dictionary:
	var found := sim.husk_near(local, 0.01)
	if found.size() != 5:
		return {}
	var details := _spot_details(local)
	var left := exp(-0.25 * found[4])  # (what is left after the pieces already let go: see husk_share in bup_sim.cpp)
	details["age"] = found[3]
	details["units"] = found[2] * left / NUTRIENT_ENERGY
	details["left"] = left
	return details


## What there is to know about a spot in the dish, given its place within it: where it is, the concentration there, and how
## many bups are close by and how far the nearest is.
func _spot_details(local: Vector2) -> Dictionary:
	var near := _nearest_and_count(local, SOURCE_NEARBY)
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


## Anywhere in the dish a plankton's body fits (so the bloom feeds the rim as well as the middle).
func _random_plankton_spot() -> Vector2:
	return sim.random_point(radius - PLANKTON_DRAW_RADIUS)


func _add_plankton(local: Vector2) -> void:
	var life := PLANKTON_MEAN_LIFE * (1.0 + PLANKTON_LIFE_SPREAD * (2.0 * sim.random_float() - 1.0))
	plankton.append(Plankton.new(local, time, time + life, PLANKTON_UNITS, sim.random_float() * TAU))
	_first_burst = minf(_first_burst, time + life)
	edit_count += 1


## Puts in the plankton a bloom of this density keeps floating (what arrives in the time one floats, on average), at
## random places: the dish as it looks once the bloom has been going a while. For a preview, which does not run.
func add_steady_state_plankton() -> void:
	var wanted := mini(int(round(bloom_per_day() * PLANKTON_MEAN_LIFE / 86400.0)), MAX_PLANKTON - plankton.size())
	for i in wanted:
		_add_plankton(_random_plankton_spot())


## How many plankton the bloom adds in a sim-day: its density over the dish's area.
func bloom_per_day() -> float:
	return bloom_density * PI * pow(radius / StartConditions.UM_PER_MM, 2)


## The plankton: the bloom adds one at a random place at each steady interval (so there are no long gaps with none
## coming), and any whose time has come burst, at random times, leaving their nutrient in the medium (looked for once
## every BURST_CHECK_SECONDS, so one may burst a little after its time).
func _step_plankton(delta: float) -> void:
	if bloom_density > 0.0:
		var interval := 86400.0 / bloom_per_day()
		var arrivals := 0
		while time >= _bloom_due and arrivals < MAX_BLOOM_ARRIVALS_PER_STEP:
			if plankton.size() < MAX_PLANKTON:
				_add_plankton(_random_plankton_spot())
			_bloom_due += interval  # (exactly on schedule: only where it lands, and how long it floats, are random)
			arrivals += 1
		if time >= _bloom_due:  # (far behind, say the rate was just raised a great deal: start over from now)
			_bloom_due = time + interval
	_burst_clock += delta
	if _burst_clock < BURST_CHECK_SECONDS:
		return
	_burst_clock = 0.0
	if time < _first_burst:
		return
	var kept := 0  # (one pass that closes the gaps, in order, instead of a removal that shifts the rest for every plankton that bursts)
	var next_burst := INF
	for cell in plankton:
		if cell.burst_at <= time:
			if plankton_husks:
				sim.add_plankton_husk(cell.pos, cell.units * NUTRIENT_ENERGY)
			else:
				field.add_cloud(cell.pos, PLANKTON_PATCH_RADIUS, cell.units * NUTRIENT_ENERGY)
			if selected_plankton == cell:
				selected_plankton = null
			if hovered_plankton == cell:
				hovered_plankton = null
			edit_count += 1
		else:
			plankton[kept] = cell
			kept += 1
			next_burst = minf(next_burst, cell.burst_at)
	plankton.resize(kept)
	_first_burst = next_burst


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
		"nearest_bup": _nearest_and_count(local, 0.0).x,
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
	field.add_cloud(world_pos - global_position, scatter_radius(count), count * NUTRIENT_ENERGY)
	edit_count += 1
	nutrients_placed += count
	return true


## The eraser: takes most of the nutrient out of a disc of the medium, a little less towards
## its edge. Returns how many units were removed.
func erase_nutrient(world_pos: Vector2, brush_radius: float) -> float:
	edit_count += 1
	if runs_on_gpu() and not _gpu_on_cpu:  # (the GPU holds the true field: its erase also changes the CPU's copy, which is what is shown until the next refresh. Not while a save has brought the state over: the CPU's field is the true one then, and a refresh from the GPU's would undo what was dropped in since)
		return gpu_world.erase_disc(world_pos - global_position, brush_radius, ERASE_STRENGTH) / NUTRIENT_ENERGY
	return field.erase_disc(world_pos - global_position, brush_radius, ERASE_STRENGTH) / NUTRIENT_ENERGY


# --- Saving and loading ------------------------------------------------------------------------
# The format, its checks and its parsing are DishCodec's; what a load does to the dish is here.

## The dish as a save (DishCodec.write).
func to_dict() -> Dictionary:
	_to_cpu_for_edit()  # (the save is made from the CPU's state)
	field.flush_emitters()  # (what the sources have kept to release as a cloud is let go, so that the save has it)
	return DishCodec.write(self, _bloom_due)


## Returns false, leaving the dish exactly as it was, if the data is unusable. Everything is
## validated and built on the side first (DishCodec.read), so a bad save can never leave a half-loaded dish.
func from_dict(d: Dictionary) -> bool:
	var blocks := DishCodec.read_blocks(d)
	if blocks.is_empty():
		return false
	var loaded_bups: PackedByteArray = blocks[0]
	var loaded_family: PackedByteArray = blocks[1]
	backend.fresh = true
	_to_cpu_for_edit()  # (a load that is refused leaves the dish as it was: so the bups must be the CPU's, and the GPU reloads them at its next batch)
	var loaded := DishCodec.read(d, field, global_position)
	if loaded.is_empty():
		return false

	# Everything checked out; now it is safe to replace the dish's state.
	radius = loaded["radius"]
	field.set_max_across(loaded["resolution"])
	_set_medium_thickness(loaded["thickness"])
	sim.reset(radius, -1)
	bup_limit = loaded["limit"]
	loaded_bups = loaded_bups.slice(0, mini(loaded_bups.size(), StartConditions.MAX_BUP_LIMIT * GpuSim.RECORD_BYTES))  # (not the dish's limit: a save made on the GPU at the limit can hold a step's births more, which the next step takes back, as in play)
	_render_stale = true
	edit_count += 1
	sim.import_state_bytes(loaded_bups)
	if loaded.has("next_id"):
		sim.set_next_id(loaded["next_id"])  # so the next bup born doesn't take a number already used
	var loaded_watched: PackedInt64Array = loaded["watched"]
	sim.lineage_import_bytes(loaded_family, loaded_watched)
	field.load_values(loaded["field"])
	acetate.load_values(loaded["acetate"])
	field.puffs_import(loaded["clouds"])
	death_husks = loaded["death_husks"]
	plankton_husks = loaded["plankton_husks"]
	stationary_phase = loaded["stationary_phase"]
	sim.husks_import(loaded["husks"])
	sources = loaded["sources"]
	plankton = loaded["plankton"]
	_first_burst = -INF
	bloom_density = loaded["bloom_density"]
	upkeep_factor = loaded["upkeep_factor"]
	nutrients_placed = loaded["nutrients_placed"]
	time = loaded["time"]
	_bloom_due = loaded["bloom_due"]
	if loaded.has("feed_density"):
		feed_density = loaded["feed_density"]
	patch_seed = loaded["patch_seed"]
	field.set_patchiness(NUTRIENT_PATCHINESS, radius, patch_seed)  # (so the feed goes on following the same landscape)
	_reset_runtime_state()
	moved_out = loaded["moved_out"]
	set_backend_setting(loaded["backend"])
	var loaded_history: Dictionary = loaded["history"]
	for key in loaded_history:
		history[key] = loaded_history[key]
	history_all = loaded["history_all"]
	history_all_factor = loaded["history_all_factor"]
	while history_all["pop"].size() >= HISTORY_ALL_LEN:
		_thin_history_all()
	for id in loaded_watched:  # (the import pinned them, oldest first, so the newest ends up on top again)
		if has_record(id) and not watched.has(id):
			watched.push_front(id)
	watch_version += 1
	# Samples are taken on multiples of the interval, so resume the timer part-way through one.
	history_origin = loaded["history_origin"]
	_history_accum = fposmod(time - history_origin, HISTORY_INTERVAL)
	_mark_gpu_dirty()  # (a loaded dish: what the GPU held is gone)
	return true


# --- Drawing ---------------------------------------------------------------------------------
# DishDrawing draws; the sizes here are the ones picking shares with it.

func plankton_draw_radius() -> float:
	return maxf(PLANKTON_DRAW_RADIUS, PLANKTON_MIN_PIXELS * pixel())


## How many screen pixels one µm of this dish covers: the camera's zoom and the dish's own scale (a setup
## preview is a shrunken dish) together.
func screen_scale() -> float:
	if picture_scale > 0.0:
		return picture_scale
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


## How wide a husk is drawn, in µm: a few pixels, never smaller than a bup's body.
func husk_draw_size() -> float:
	return maxf(HUSK_PIXELS * pixel(), 2.0)


## A thin ring marking a bup or source: GUI, so the same size and line at every zoom (see
## ring_radius_pixels for the one case where it grows).
func draw_ring(canvas: CanvasItem, center: Vector2, object_radius: float, color: Color) -> void:
	drawing.draw_ring(canvas, center, object_radius, color)


func _draw() -> void:
	drawing.draw()


## What goes above the bups (called by the overlay child): the selection and hover rings, the
## placement preview, the flash (DishDrawing.draw_overlay).
func draw_overlay(canvas: CanvasItem) -> void:
	drawing.draw_overlay(canvas)


# --- The GPU path ------------------------------------------------------------------------------
# The hooks of the GPU path: none is reached while `gpu_active` is false, except _choose_backend, which every `advance` asks.

## Runs `seconds` of simulation on the GPU, as `advance` does on the CPU (steps of seconds / ceil(seconds / MAX_STEP)), and returns
## the seconds simulated: as many steps as gpu_world.steps_for allows (the GPU's own budget, which `advance`'s time budget does not
## enter). First gpu_world.poll() (finished results: records, counts, stats, answers), and each of gpu_world.take_history_samples()
## through _record_history_from. Then for each step: `_step_world` (the clock, the plankton, the sources, the history's clock),
## sim.step_world(delta, the sources' places and rates, time) for their emissions, the field's recorded clouds and deposits
## (take_recorded_*) gathered into the batch's events, and the steps a history sample is due after; then one
## gpu_world.queue_batch(plan) (see its keys). Emits `extinct` once when a polled count is 0, as `step` does.
func _advance_gpu(seconds: float) -> float:
	gpu_world.poll()
	for sample: Dictionary in gpu_world.take_history_samples():
		_record_history_from(sample["stats"])
	if gpu_world.count_known():
		_signal_if_extinct(gpu_world.bup_count())
	if seconds <= 0.0:
		return 0.0
	var wanted := maxi(1, ceili(seconds / MAX_STEP))
	var delta := seconds / wanted
	var steps := gpu_world.steps_for(wanted)  # (the GPU's budget: fewer when the frames run long; 0 when its results are behind)
	if steps == 0:
		return 0.0
	var start := time
	var events := GpuSim.WorldEvents.new()
	var history_steps := PackedInt32Array()
	for k in steps:
		var world := _step_world(delta)
		sim.step_world(delta, world["positions"], world["rates"], time)  # (the sources' emissions only: the field records them, as it does the plankton's)
		events.add_step(field)
		if world["sample"]:
			history_steps.append(k)  # (taken on the GPU after this step, recorded here when it comes back)
	gpu_world.queue_batch({
		"steps": steps, "delta": delta, "start_time": start, "history_steps": history_steps,
		"events": events.as_dict(),
		"feed_per_second": feed_per_second(feed_density), "upkeep_scale": upkeep_factor, "limit": bup_limit,
		"death_puff": 0.0 if death_husks else Biology.DEATH_RELEASE * Cell.COST_PER_MASS, "stationary": stationary_phase,
	})
	return steps * delta


var _gpu_on_cpu := false  ## gpu_active, but the CPU's bups are the true ones just now (an edit or a save brought them over): the GPU reloads them before its next batch
var _fractions_asked := {}  ## [gene, threshold] -> true for each share asked lately (fraction_with_gene_at_least): a load answers them from the CPU's bups



## Where the bups run now, "gpu" or "cpu" (the debug log and the pause menu's record of the settings say it).
func backend_running() -> String:
	return "gpu" if runs_on_gpu() else "cpu"


## Sets the setting (StartConditions.BACKEND_*; anything else is Auto) and has the next `advance` ask again.
func set_backend_setting(value: String) -> void:
	backend.set_setting(value)


## Chooses where the bups run for this frame (the rule is `DishBackend.choose`; this carries the answer out): makes `gpu_world` when first
## needed (if GpuWorld.available()), moves the state (gpu_world.load_from_cpu / export_to_cpu) and sets `gpu_active`. Called at the top of
## every `advance`, before any step (never while paused). `step_delta` and `steps` are as `choose` takes them. A dish that stays on the GPU
## with `_gpu_on_cpu` set reloads it before it runs: the GPU's copy is from before the save or edit.
func _choose_backend(step_delta: float, steps := 0) -> void:
	var real := minf(get_process_delta_time(), 0.1)  # (the frame the caller advances for: main.gd's, capped as it caps it, MAX_FRAME_SECONDS)
	var on_gpu := runs_on_gpu()
	if backend.idle_release(on_gpu, gpu_world != null and gpu_world.gpu != null and gpu_world.gpu.is_main, real if real > 0.0 else BackendRule.RULE_FRAME_SECONDS):
		_release_idle_gpu()
	var facts := DishBackend.Facts.new()
	facts.on_gpu = on_gpu
	facts.available = BackendRule.usable(GpuWorld.available(), bup_limit, GpuWorld.most_bups())
	facts.state_on_cpu = _gpu_on_cpu
	facts.cells = field.get_size()
	facts.moves = sim.moves_for(step_delta)
	facts.population = population()
	facts.clouds = field.puff_count()
	match backend.choose(step_delta, steps, real, facts):
		DishBackend.Action.TO_GPU:
			if gpu_world == null:
				gpu_world = GpuWorld.new(sim)
			_load_gpu()
			gpu_active = true
			_render_stale = true
		DishBackend.Action.TO_CPU:
			_to_cpu_for_edit()  # (its state, brought over unless an edit has just done so)
			gpu_active = false
			_gpu_on_cpu = false
			_render_stale = true
		DishBackend.Action.RELOAD:
			_load_gpu()


## Gives back the GPU's buffers, shaders and pipelines (on the render thread, as a freed dish does); `_load_gpu` makes them afresh when the
## GPU is wanted later.
func _release_idle_gpu() -> void:
	var idle := gpu_world.gpu
	gpu_world.gpu = null
	RenderingServer.call_on_render_thread(idle.release)


## What load_from_cpu needs of the dish, and what it shows of the bups (the selected and hovered ones, the shares of a gene a goal
## watches), so that the GPU's answers to these start from the CPU's instead of from nothing.
func _gpu_params() -> Dictionary:
	return {"radius": radius, "limit": bup_limit, "seed": patch_seed, "upkeep_scale": upkeep_factor, "feed_per_second": feed_per_second(feed_density), "step_seconds": MAX_STEP,
		"tracked": [selected_id, hovered_id], "fractions": _fractions_asked.keys()}


## Hands the CPU's bups and field to the GPU (the CPU's are the true ones until it has).
func _load_gpu() -> void:
	gpu_world.load_from_cpu(field, _gpu_params())
	_gpu_on_cpu = false


## Forgets what the GPU holds, for a dish that is being replaced (a new one): no export, the CPU's field stops recording, and what
## the GPU still has on its way is dropped. The CPU's own state is the new dish's, which the caller makes; `_mark_gpu_dirty` loads it.
func _discard_gpu_state() -> void:
	field.set_recording(false)
	gpu_world.reset_pipeline(0)
	gpu_world.take_history_samples()  # (the old dish's samples that came back and were not yet recorded: not the new dish's)
	_gpu_on_cpu = true


## Before an edit made by hand (adding or removing bups, a resize, the limit, a save): brings the GPU's state to the CPU
## (gpu_world.export_to_cpu, which stalls), so the edit is made on the CPU's bups. Nothing to do when it already has them.
func _to_cpu_for_edit() -> void:
	if not runs_on_gpu() or _gpu_on_cpu:
		return
	gpu_world.export_to_cpu(field)
	for sample: Dictionary in gpu_world.take_history_samples():  # (the history samples of the batches the stall finished: recorded, in order, before any CPU step)
		_record_history_from(sample["stats"])
	_gpu_on_cpu = true


## After an edit made by hand, a new dish or a load: the CPU's state is the true one, so the GPU loads it (now, so that the picture and
## the counts are the edited dish's, whether or not time is moving), and results of batches from before it are dropped.
func _mark_gpu_dirty() -> void:
	if not runs_on_gpu():
		return
	_gpu_on_cpu = true
	if bup_limit <= GpuWorld.most_bups():  # (a limit the device cannot hold stays on the CPU: the next `advance` says so)
		_load_gpu()


## A hand edit of the bups (adding or removing them, a resize, the limit, the pipette): `work` runs on the CPU's bups, which
## `_to_cpu_for_edit` brings over from the GPU first, and the GPU then loads the result (`_mark_gpu_dirty`). Returns what `work` returns.
func _edit_on_cpu(work: Callable) -> Variant:
	_to_cpu_for_edit()
	var result: Variant = work.call()
	_mark_gpu_dirty()
	return result
