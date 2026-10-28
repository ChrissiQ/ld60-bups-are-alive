class_name Dish
extends Node2D
## The petri dish. The simulation itself (bups, genomes, the dissolved nutrient, stepping) runs in
## the native BupSim (native/src); this node owns what surrounds it: drawing, selection and hover,
## nutrient sources, the history graph's samples, and saving and loading.
## Lengths are µm and times are seconds of simulation time, which runs at real biological rates
## (see Biology); the player's playback speed only multiplies how much of it passes per second.
## Bups are named by a stable id (an int), since the native arrays compact as bups die.

signal extinct
enum PickMode { ALL, BACKGROUND, BUPS, SOURCES, PLANKTON, HUSKS }  ## what the select tool looks at: everything (a source over a bup), only the medium, only bups, only sources, only plankton or only husks

signal selection_changed  ## the selected bup is now another (or none)
signal layers_changed  ## a layer was shown or hidden

## The kinds of thing the dish draws, each of which can be hidden (a view choice only: nothing here touches the simulation).
## A hidden layer cannot be hovered or picked, but what is already selected stays selected (hiding the bups to see the steering map of the selected one, say).
enum Layer { MEDIUM, SOURCES, PLANKTON, BUPS, STEERING, HUSKS }  ## the nutrient haze, the feeders, the plankton, the bups, the steering map and arc of the selected bup, and the husks

const DEFAULT_RADIUS := 10000.0  ## µm: 10 mm, the dish before any start (the tests' dish too); goal mode and free mode start from StartConditions.DEFAULT_RADIUS
const NUTRIENT_SCATTER := 5.0  ## radius a dose spreads over, per sqrt(nutrient) in it
const MAX_CELLS := 300  ## the smallest carrying limit; see `cap_for`. Past the limit each birth displaces a random bup (a Moran process)
const MAX_SOURCES := 1000
const MAX_SAVED_BYTES := 600000000  ## the most a save's block of bups or of family records may be once decompressed (2,000,000 bups are 192 MB)
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
const SUGGESTED_BLOOM_DENSITY := 0.08  ## plankton in each mm² every sim-day that the goal text suggests: about one an hour on a 10 mm dish, 300 units an hour, about what the old feed gave
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
var _plankton_picture: ImageTexture = null  ## what a small plankton is drawn from (made when first needed)
var _plankton_mesh: MultiMesh = null  ## where each small plankton is, for drawing them all at once
var _plankton_key: Array = []  ## what `_plankton_mesh` was last built for: how many plankton, the edit count and the radius drawn
var _plankton_built := 0  ## when it was (msec)
var _burst_clock := 0.0  ## sim seconds since the plankton were last looked over for bursts
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
var _draw_key := []  ## what the dish was last drawn from (see `refresh_drawing`)
var _render_stamp := []  ## what the bups' picture was last built from
var _render_stale := true  ## the bups were changed by hand (added, removed, a new dish), so the picture must be rebuilt
var _trails_may_show := false  ## the last picture was made as time moved, so bups in it may be drawn with trails
var _haze: ImageTexture = null
var _haze_built := 0
var _steer: ImageTexture = null  ## where the selected bup could steer (see `_draw_steering`)
var _steer_key := []
var _extinct_signalled := false
var _history_accum := 0.0
var _bups_mesh: MultiMeshInstance2D = null  ## all the bups, drawn in one go
var _husks_mesh: MultiMeshInstance2D = null  ## every husk, as one instance each
var _husk_stamp := []  ## what the husk picture was last built for (the time, how many there were, the size of a husk)
var _husk_built_msec := 0
var _overlay: Node2D = null  ## the selection and hover rings, drawn above the bups
## The GPU path (gpu/gpu_world.gd): while `gpu_active`, the GPU runs the bups and answers for them; everything the dish asks the
## simulation about the bups goes to `gpu_world` (the branches below), and the CPU's BupSim keeps the records, names and pins.
## `_choose_backend` makes `gpu_world` and switches (see the GPU path's functions at the end of this file).
var gpu_world: GpuWorld = null
var cpu_cost_estimate := 0.0  ## µs the processor is estimated to need for one frame of this dish (the cost model's, at the last `advance`)
var _cpu_ratio := 1.0  ## what this machine's processor really takes per frame, as a multiple of the cost model's estimate (the model was fitted on one machine): Auto's rule uses the estimate times this
var _frame_estimate_usec := 0.0  ## the model's estimate for the frame `measured_usec` last timed
var measured_usec := 0.0  ## µs the processor really took the last frames this dish was advanced on it (a running average, set by the screen; 0 until it has been timed)
var switch_allowed := true  ## whether Auto's rule may move this dish between the processor and the GPU this frame (the screen lets one dish at a time, so each choice sees the load the last left)
var switch_wanted := false  ## Auto's rule wants this dish moved, and ...
var switch_wanted_gpu := false  ## ... to the GPU (else to the processor)
var other_cpu_load := 0.0  ## µs per frame the other dishes on the processor are estimated to take (the screen sets it, so that Auto weighs the processor's whole load)
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
	var husk_mesh := QuadMesh.new()
	husk_mesh.size = Vector2.ONE
	var husks := MultiMesh.new()
	husks.transform_format = MultiMesh.TRANSFORM_2D
	husks.mesh = husk_mesh
	_husks_mesh = MultiMeshInstance2D.new()  # (under the bups: one instance for every husk there is, drawn by the graphics card, so there is no limit on how many are shown)
	_husks_mesh.multimesh = husks
	_husks_mesh.self_modulate = HUSK_COLOR
	add_child(_husks_mesh)
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
	var key := [Time.get_ticks_msec() / HAZE_REFRESH_MSEC, sources.size(), edit_count, radius, pixel(), selected_id, _layers_hidden.size()]
	if key != _draw_key:
		_draw_key = key
		queue_redraw()


## The picture holds room for the bups there are (with some to spare, never past the limit), not for the
## most there could be: a buffer for 100,000 bups is rewritten every frame, which costs when only a few live.
func _fit_render_capacity(needed: int) -> void:
	if gpu_world != null and gpu_active:
		return  # (on the GPU path the picture is made once at the GPU's capacity: see _draw_bups_gpu)
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
	_refresh_husks()
	if _bups_mesh != null and gpu_world != null and gpu_active:
		for id in [selected_id, hovered_id]:  # (the bups the overlay shows: their records come back every frame)
			if id >= 0:
				gpu_world.track(id)
		_draw_bups_gpu()
		_overlay.queue_redraw()
	elif _bups_mesh != null:
		_fit_render_capacity(sim.bup_count())
		var multimesh := _bups_mesh.multimesh
		# The picture is rebuilt only when what it shows may have changed: time has passed, or the bups, the zoom or
		# the pixel size have. (While paused nothing has, however many bups there are.)
		var stamp := [time, sim.bup_count(), pixel()]
		var changed: bool = stamp != _render_stamp
		if _render_stale or changed or _trails_may_show:
			_render_stamp = stamp
			_render_stale = false
			_trails_may_show = changed  # (a picture made as time moved may carry trails; the next one, when nothing has moved since, clears them: so a paused dish shows none)
			multimesh.visible_instance_count = mini(sim.bup_count(), multimesh.instance_count)
			multimesh.buffer = sim.render_buffer(pixel(), multimesh.instance_count)
		_overlay.queue_redraw()


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
	if gpu_world != null and gpu_active:
		_discard_gpu_state()  # (a new dish: what the GPU holds, and every result still on its way, is for the old one)
	set_backend_setting(start.sim_backend)
	_fresh = true
	flash = 1.0
	_render_stale = true
	edit_count += 1
	time = 0.0
	nutrients_placed = 0
	sources.clear()
	plankton.clear()
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
	if gpu_world != null and gpu_active:
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
	if gpu_world != null and gpu_active:
		_to_cpu_for_edit()
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
	queue_redraw()
	if gpu_world != null and gpu_active:
		_mark_gpu_dirty()


## Changes how many bups the dish holds, without ever going below how many there are now.
func change_limit(value: int) -> void:
	if gpu_world != null and gpu_active:
		_to_cpu_for_edit()
	bup_limit = maxi(value, population())
	if gpu_world != null and gpu_active:
		_mark_gpu_dirty()


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
	if gpu_world != null and gpu_active:
		return _advance_gpu(seconds, budget_usec)
	var started := Time.get_ticks_usec()
	var done := 0.0
	for i in steps:
		step(delta)
		done += delta
		if budget_usec > 0 and Time.get_ticks_usec() - started > budget_usec:
			break
	return done


func step(delta: float) -> void:
	if gpu_world != null and gpu_active:
		_advance_gpu(delta, 0)
		return
	time += delta
	_step_plankton(delta)
	var positions := PackedVector2Array()
	var rates := PackedFloat32Array()
	for source in sources:
		positions.append(source.pos - global_position)
		rates.append(source.rate)
		source.emitted += source.rate / 60.0 * delta
	sim.step(delta, positions, rates, feed_density * CONCENTRATION_PER_DENSITY / 3600.0, time)  # (time, so births and deaths are stamped with it)
	_history_accum += delta
	if _history_accum >= HISTORY_INTERVAL:
		_history_accum -= HISTORY_INTERVAL
		_record_history()  # (also once the colony has died out, so the graph's time stays true)
	if sim.bup_count() == 0 and time > 0.0 and not _extinct_signalled:  # once, on the way down, not on every step after
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

func population() -> int:
	if gpu_world != null and gpu_active:
		return gpu_world.bup_count()
	return sim.bup_count()


func has_bup(id: int) -> bool:
	return id >= 0 and sim.has_bup(id)


func bup_ids() -> PackedInt64Array:
	if gpu_world != null and gpu_active:
		return sim.alive_ids()  # (the bups are on the GPU; their records are here)
	return sim.bup_ids()


## Everything about one bup (see BupSim.bup_info): its position is relative to the dish centre.
func bup_info(id: int) -> Dictionary:
	if gpu_world != null and gpu_active:
		return gpu_world.bup_info(id)
	return sim.bup_info(id)


## The bup's position in the world, like the sources'.
func bup_world_pos(id: int) -> Vector2:
	return global_position + _bup_pos(id)


## Whether the bup is alive and its place is known, so it can be drawn round. On the GPU path a bup chosen by its id (the watch list, the
## lineage) has no place for the few frames until its record comes back.
func _bup_shown(id: int) -> bool:
	return sim.has_bup(id) and (gpu_world == null or not gpu_active or gpu_world.knows(id))


## The bup's position in the dish (relative to its centre).
func _bup_pos(id: int) -> Vector2:
	if gpu_world != null and gpu_active:
		return gpu_world.bup_pos(id)
	return sim.bup_pos(id)


## Half the length the bup is drawn at (BupSim.bup_radius).
func _bup_radius(id: int, pixel_um: float) -> float:
	if gpu_world != null and gpu_active:
		return gpu_world.bup_radius(id, pixel_um)
	return sim.bup_radius(id, pixel_um)


## Which way the bup's drift tends where it is and how surely (BupSim.bup_steering).
func bup_steering(id: int) -> Vector3:
	if gpu_world != null and gpu_active:
		return gpu_world.bup_steering(id)
	return sim.bup_steering(id)


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
	if gpu_world != null and gpu_active:
		_to_cpu_for_edit()
	_render_stale = true
	edit_count += 1
	var added := sim.add_bup(world_pos - global_position, genome, energy, size, birth_mass, divisions, dir, id)
	if gpu_world != null and gpu_active:
		_mark_gpu_dirty()
	return added


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
	var info := sim.lineage_info(id)
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
	if not info.is_empty() and info["alive"] and gpu_world != null and gpu_active:
		info.merge(gpu_world.bup_info(id), true)  # (a bup on the GPU: the simulation here has only its record, which does not hold its size and reserve now)
	if moved_out.has(id):
		info["moved_to"] = moved_out[id]
	return info


## The pipette's taking half: every bup whose centre is within `disc_radius` of the world point leaves this dish and comes back as records (relative to the
## point, to be dropped into another dish with `add_transferred`). The dish is brought to the CPU for it.
func take_in_disc(world_pos: Vector2, disc_radius: float) -> PackedByteArray:
	_to_cpu_for_edit()
	edit_count += 1
	_render_stale = true
	var local := world_pos - global_position
	taken_lineage = sim.lineage_export_bytes()  # (the family records as they are before the bups leave, for the dish they go to)
	return sim.take_disc(local, disc_radius)


## The pipette's giving half: the records `take_in_disc` made come in as the same bups (same ids, so the same names, genes and colours) at the middle of the dish (a
## droplet), with their whole family tree (`lineage`, from the dish they left: dead ancestors included, and the ones that stayed behind as dead here). Returns their ids.
func add_transferred(records: PackedByteArray, lineage: PackedByteArray) -> PackedInt64Array:
	_to_cpu_for_edit()
	var ids := sim.add_state_bytes(records, Vector2.ZERO, true)
	sim.lineage_import_bytes(lineage, PackedInt64Array())
	edit_count += 1
	_render_stale = true
	return ids


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
	if gpu_world != null and gpu_active:
		_to_cpu_for_edit()
	_render_stale = true
	edit_count += 1
	sim.remove_bup(id)
	if gpu_world != null and gpu_active:
		_mark_gpu_dirty()


func clear_bups() -> void:
	if gpu_world != null and gpu_active:
		_to_cpu_for_edit()
	_render_stale = true
	edit_count += 1
	sim.clear_bups()
	if gpu_world != null and gpu_active:
		_mark_gpu_dirty()


## The count and averages the readouts show (each gene, "harm" as a share of yield lost, "mutations"), and "generation", the population's: the mean of its bups' divisions (a pipette keeps the bups' counts, so the dish it founds carries on the count of the dish it came from).
func population_stats() -> Dictionary:
	if gpu_world != null and gpu_active:
		return gpu_world.population_stats()
	return sim.population_stats()


func fraction_with_gene_at_least(gene: String, threshold: float) -> float:
	if not _fractions_asked.has([gene, threshold]):
		if _fractions_asked.size() >= GpuKernels.FRACTIONS:
			_fractions_asked.clear()  # (asked for something else now: the old pairs go)
		_fractions_asked[[gene, threshold]] = true
	if gpu_world != null and gpu_active:
		return gpu_world.fraction_with_gene_at_least(gene, threshold)
	return sim.fraction_with_gene_at_least(gene, threshold)


## The id of the bup under a world position, or -1. `slack` widens the target (e.g. for small bups).
func cell_at(world_pos: Vector2, slack: float = 0.0, hover := false) -> int:
	if gpu_world != null and gpu_active:
		return gpu_world.pick_bup(world_pos - global_position, slack, pixel(), hover)
	return sim.pick_bup(world_pos - global_position, slack, pixel())


## The distance to the nearest bup (-1 if there is none) and how many lie within `near` of a point of the dish.
func _nearest_and_count(local: Vector2, near: float) -> Vector2:
	if gpu_world != null and gpu_active:
		return gpu_world.nearest_and_count(local, near)
	return sim.nearest_and_count(local, near)


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
	layers_changed.emit()
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
	for i in range(plankton.size() - 1, -1, -1):
		var cell := plankton[i]
		if cell.burst_at <= time:
			if plankton_husks:
				sim.add_plankton_husk(cell.pos, cell.units * NUTRIENT_ENERGY)
			else:
				field.add_cloud(cell.pos, PLANKTON_PATCH_RADIUS, cell.units * NUTRIENT_ENERGY)
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
	if gpu_world != null and gpu_active and not _gpu_on_cpu:  # (the GPU holds the true field: its erase also changes the CPU's copy, which is what is shown until the next refresh. Not while a save has brought the state over: the CPU's field is the true one then, and a refresh from the GPU's would undo what was dropped in since)
		return gpu_world.erase_disc(world_pos - global_position, brush_radius, ERASE_STRENGTH) / NUTRIENT_ENERGY
	return field.erase_disc(world_pos - global_position, brush_radius, ERASE_STRENGTH) / NUTRIENT_ENERGY


# --- Saving and loading ------------------------------------------------------------------------

## Positions are saved relative to the dish centre so a resized window doesn't matter.
func to_dict() -> Dictionary:
	if gpu_world != null and gpu_active:
		_to_cpu_for_edit()  # (the save is made from the CPU's state)
	field.flush_emitters()  # (what the sources have kept to release as a cloud is let go, so that the save has it)
	var saved_sources := []
	for source in sources:
		saved_sources.append({"pos": _vec_to_array(source.pos - global_position), "rate": source.rate, "emitted": source.emitted})
	var saved_plankton := []
	for cell in plankton:
		saved_plankton.append({"pos": _vec_to_array(cell.pos), "born_at": cell.born_at, "burst_at": cell.burst_at, "units": cell.units, "shape": cell.shape})
	return {
		"next_id": sim.get_next_id(),
		"lineage": _pack_bytes(sim.lineage_export_bytes()),
		"radius": radius,
		"nutrient_resolution": field.get_max_across(),
		"medium_thickness": medium_thickness,
		"bup_limit": bup_limit,
		"nutrients_placed": nutrients_placed,
		"time": time,
		"feed_density": feed_density,
		"patch_seed": patch_seed,
		"cells": _pack_bytes(sim.export_state_bytes()),  # (every bup as the GPU's record: a dictionary for each of a hundred thousand would take seconds to make and to write)
		"field": Array(field.values()),
		"acetate": Array(acetate.values()),
		"clouds": field.puffs_export(),
		"death_husks": death_husks,
		"plankton_husks": plankton_husks,
		"stationary_phase": stationary_phase,
		"husks": Array(sim.husks_export()),
		"sources": saved_sources,
		"bloom_density": bloom_density,
		"bloom_due": _bloom_due,
		"upkeep_factor": upkeep_factor,
		"plankton": saved_plankton,
		"history": history,
		"history_all": history_all,
		"watched": watched,
		"history_all_factor": history_all_factor,
		"history_origin": history_origin,
	}


## Returns false, leaving the dish exactly as it was, if the data is unusable. Everything is
## validated and built on the side first, so a bad save can never leave a half-loaded dish.
func from_dict(d: Dictionary) -> bool:
	var saved_bups: Variant = _unpack_bytes(d.get("cells"))
	var saved_family: Variant = _unpack_bytes(d.get("lineage"))
	if saved_bups == null or saved_family == null or saved_bups.size() % GpuSim.RECORD_BYTES != 0:
		return false
	var loaded_bups: PackedByteArray = saved_bups
	var loaded_family: PackedByteArray = saved_family
	_fresh = true
	if gpu_world != null and gpu_active:
		_to_cpu_for_edit()  # (a load that is refused leaves the dish as it was: so the bups must be the CPU's, and the GPU reloads them at its next batch)
	for key in ["radius", "bup_limit", "nutrients_placed", "time", "feed_density", "bloom_density", "nutrient_resolution", "medium_thickness"]:
		if d.has(key) and not Validate.is_number(d[key]):
			return false
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
	var loaded_limit := clampi(int(d.get("bup_limit", StartConditions.DEFAULT_BUP_LIMIT)), 1, StartConditions.MAX_BUP_LIMIT)
	var loaded_resolution := StartConditions.MIN_NUTRIENT_RESOLUTION  # (a save from before the setting has the default)
	if Validate.is_number(d.get("nutrient_resolution")):
		loaded_resolution = clampi(int(d["nutrient_resolution"]), StartConditions.MIN_NUTRIENT_RESOLUTION, StartConditions.MAX_NUTRIENT_RESOLUTION)
	var loaded_thickness := Biology.MEDIUM_THICKNESS  # (a save from before the setting has the usual medium)
	if Validate.is_number(d.get("medium_thickness")):
		loaded_thickness = clampf(float(d["medium_thickness"]), StartConditions.MIN_MEDIUM_THICKNESS, StartConditions.MAX_MEDIUM_THICKNESS)
	var resolution_before := field.get_max_across()
	field.set_max_across(loaded_resolution)
	var field_size := field.size_for_radius(loaded_radius)
	field.set_max_across(resolution_before)  # (until everything checks out)
	var saved_field = d.get("field", [])
	if saved_field is Array and not is_equal_approx(loaded_radius, float(d.get("radius", DEFAULT_RADIUS))):
		saved_field = []  # the radius had to be clamped, so the saved grid no longer fits the dish: start with a clear medium
	if not (saved_field is Array) or (not saved_field.is_empty() and saved_field.size() != field_size * field_size):
		return false
	for v in saved_field:
		if not Validate.is_number(v):
			return false
	var saved_acetate = d.get("acetate", [])
	if saved_field.is_empty():
		saved_acetate = []  # (a clear medium has no acetate either)
	if not (saved_acetate is Array) or (not saved_acetate.is_empty() and saved_acetate.size() != field_size * field_size):
		return false
	for v in saved_acetate:
		if not Validate.is_number(v):
			return false
	var saved_clouds = d.get("clouds", [])  # the plankton's nutrient not yet given to the grid (a save from before them has none)
	if not (saved_clouds is Array):
		return false
	for cloud in saved_clouds:
		if not (cloud is Array) or (cloud.size() != 4 and cloud.size() != 5):
			return false
		for v in cloud:
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
	var loaded_all := {}
	var loaded_factor := 1
	var saved_all = d.get("history_all")
	if saved_all is Dictionary and Validate.is_number(d.get("history_all_factor")) and float(d["history_all_factor"]) >= 1.0:
		loaded_factor = int(d["history_all_factor"])
		for key in HISTORY_SERIES:
			var series = saved_all.get(key)
			if not (series is Array):
				loaded_all = {}
				break
			for v in series:
				if not Validate.is_number(v):
					return false
			loaded_all[key] = series

	var loaded_watched := PackedInt64Array()  # the watch list, oldest first
	var saved_watched = d.get("watched", [])
	if saved_watched is Array:
		for i in range(saved_watched.size() - 1, -1, -1):
			if Validate.is_number(saved_watched[i]):
				loaded_watched.append(int(saved_watched[i]))

	# Everything checked out; now it is safe to replace the dish's state.
	radius = loaded_radius
	field.set_max_across(loaded_resolution)
	_set_medium_thickness(loaded_thickness)
	sim.reset(radius, -1)
	bup_limit = loaded_limit
	loaded_bups = loaded_bups.slice(0, mini(loaded_bups.size(), StartConditions.MAX_BUP_LIMIT * GpuSim.RECORD_BYTES))  # (not the dish's limit: a save made on the GPU at the limit can hold a step's births more, which the next step takes back, as in play)
	_render_stale = true
	edit_count += 1
	sim.import_state_bytes(loaded_bups)
	var saved_next = d.get("next_id")
	if Validate.is_number(saved_next):
		sim.set_next_id(int(saved_next))  # so the next bup born doesn't take a number already used
	sim.lineage_import_bytes(loaded_family, loaded_watched)
	field.load_values(saved_field)
	acetate.load_values(saved_acetate)
	field.puffs_import(saved_clouds)
	death_husks = d.get("death_husks") is bool and d["death_husks"]
	plankton_husks = d.get("plankton_husks") is bool and d["plankton_husks"]
	stationary_phase = d.get("stationary_phase") is bool and d["stationary_phase"]
	var saved_husks := PackedFloat64Array()
	if d.get("husks") is Array:
		for value: Variant in d["husks"]:
			if Validate.is_number(value):
				saved_husks.append(float(value))
	sim.husks_import(saved_husks)
	sources = loaded_sources
	plankton = loaded_plankton
	bloom_density = float(d["bloom_density"]) if Validate.is_number(d.get("bloom_density")) else 0.0
	upkeep_factor = clampf(float(d["upkeep_factor"]) if Validate.is_number(d.get("upkeep_factor")) else 1.0, 1.0, 100.0)
	nutrients_placed = int(d.get("nutrients_placed", 0))
	time = float(d.get("time", 0.0))
	_bloom_due = float(d["bloom_due"]) if Validate.is_number(d.get("bloom_due")) else time
	feed_density = float(d["feed_density"]) if Validate.is_number(d.get("feed_density")) else feed_density
	patch_seed = int(d["patch_seed"]) if Validate.is_number(d.get("patch_seed")) else 0
	field.set_patchiness(NUTRIENT_PATCHINESS, radius, patch_seed)  # (so the feed goes on following the same landscape)
	_reset_runtime_state()
	for key in loaded_history:
		history[key] = loaded_history[key]
	if loaded_all.is_empty():  # (a save without the whole run: what the fine history holds is all there is)
		loaded_factor = 1
		for key in HISTORY_SERIES:
			loaded_all[key] = history[key].duplicate()
	history_all = loaded_all
	history_all_factor = loaded_factor
	while history_all["pop"].size() >= HISTORY_ALL_LEN:
		_thin_history_all()
	for id in loaded_watched:  # (the import pinned them, oldest first, so the newest ends up on top again)
		if has_record(id) and not watched.has(id):
			watched.push_front(id)
	watch_version += 1
	# Samples are taken on multiples of the interval, so resume the timer part-way through one.
	history_origin = float(d["history_origin"]) if Validate.is_number(d.get("history_origin")) else 0.0
	_history_accum = fposmod(time - history_origin, HISTORY_INTERVAL)
	if gpu_world != null and gpu_active:
		_mark_gpu_dirty()  # (a loaded dish: what the GPU held is gone)
	return true


## A block of bytes as a save holds it: its size, and the bytes compressed (zstd) and as text. A bup's record is 112 bytes and a family
## record 68, so a hundred thousand of each is about 18 MB raw and a few MB compressed.
static func _pack_bytes(bytes: PackedByteArray) -> Dictionary:
	return {"raw": bytes.size(), "z": "" if bytes.is_empty() else Marshalls.raw_to_base64(bytes.compress(FileAccess.COMPRESSION_ZSTD))}  # (nothing to compress: base64 of an empty array is an error)


## What `_pack_bytes` made of these, read back from a save; null if it is not one (or does not decompress to the size it says).
static func _unpack_bytes(saved: Variant) -> Variant:
	if not (saved is Dictionary) or not Validate.is_number(saved.get("raw")) or not (saved.get("z") is String):
		return null
	var size := int(saved["raw"])
	if size < 0 or size > MAX_SAVED_BYTES:
		return null
	var bytes := Marshalls.base64_to_raw(saved["z"]).decompress(size, FileAccess.COMPRESSION_ZSTD) if size > 0 else PackedByteArray()
	return bytes if bytes.size() == size else null


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


## The plankton: outlines when they are big enough to see, and only those on screen; otherwise dots, all in a single draw.
func _draw_all_plankton() -> void:
	if plankton.is_empty():
		return
	var r := plankton_draw_radius()
	if r < PLANKTON_DETAIL_PIXELS * pixel():
		_draw_plankton_pictures(r)
		return
	var seen := (get_global_transform_with_canvas().affine_inverse() * get_viewport_rect()).grow(r)
	for cell in plankton:
		if seen.has_point(cell.pos):
			_draw_plankton(cell)


## Every plankton at once, each a turned copy of one picture, through a multimesh. Where they are is rebuilt when they
## or their size on screen change, and not more than a few times a second.
func _draw_plankton_pictures(r: float) -> void:
	if _plankton_picture == null:
		_plankton_picture = _make_plankton_picture()
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * 2.0 * PLANKTON_PICTURE_REACH
		_plankton_mesh = MultiMesh.new()
		_plankton_mesh.transform_format = MultiMesh.TRANSFORM_2D
		_plankton_mesh.mesh = quad
	var now := Time.get_ticks_msec()
	var key := [plankton.size(), edit_count, snappedf(r, 0.001)]
	if key != _plankton_key and now - _plankton_built >= PLANKTON_PICTURE_REFRESH_MSEC:
		_plankton_key = key
		_plankton_built = now
		var buffer := PackedFloat32Array()  # (a 2D transform is 8 floats: x.x, y.x, 0, origin.x, x.y, y.y, 0, origin.y)
		buffer.resize(8 * plankton.size())
		var k := 0
		for cell in plankton:
			var turn := Vector2.from_angle(cell.shape) * r
			buffer[k] = turn.x
			buffer[k + 1] = -turn.y
			buffer[k + 3] = cell.pos.x
			buffer[k + 4] = turn.y
			buffer[k + 5] = turn.x
			buffer[k + 7] = cell.pos.y
			k += 8
		_plankton_mesh.instance_count = plankton.size()
		_plankton_mesh.buffer = buffer
	elif key != _plankton_key:
		queue_redraw()  # (too soon to rebuild: look again next frame, so a paused dish does not keep a stale picture)
	if _plankton_mesh.instance_count > 0:
		draw_multimesh(_plankton_mesh, _plankton_picture)


## One plankton as a small picture: the same faint fill, outline and spot as the outlines drawn when they are big, for a
## radius of 1 at the middle.
func _make_plankton_picture() -> ImageTexture:
	var size := PLANKTON_PICTURE_SIZE
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var per_unit := size / 2.0 / PLANKTON_PICTURE_REACH  # pixels to a plankton radius
	var fill := Color(0.5, 0.9, 0.45, 0.1)
	var line := Color(0.55, 0.95, 0.5, 0.9)
	var spot := Color(0.55, 0.95, 0.5, 0.6)
	var line_half := 1.6 / per_unit * 2.0  # (a line a good few texels wide, so it still shows when the picture is shrunk to a few pixels)
	for y in size:
		for x in size:
			var d := Vector2((x + 0.5) / per_unit - PLANKTON_PICTURE_REACH, (y + 0.5) / per_unit - PLANKTON_PICTURE_REACH)
			var a := d.angle()
			var edge := 1.0 + 0.16 * sin(2.0 * a) + 0.1 * sin(3.0 * a)
			var colour := Color(0, 0, 0, 0)
			if d.length() < edge:
				colour = fill
			var on_line := 1.0 - smoothstep(0.5 * line_half, line_half, absf(d.length() - edge))
			colour = _over(Color(line.r, line.g, line.b, line.a * on_line), colour)
			var in_spot := 1.0 - smoothstep(0.15, 0.2, d.distance_to(Vector2(0.25, 0.0)))
			colour = _over(Color(spot.r, spot.g, spot.b, spot.a * in_spot), colour)
			image.set_pixel(x, y, colour)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## `top` laid over `below`, in straight (not premultiplied) colour.
func _over(top: Color, below: Color) -> Color:
	var alpha := top.a + below.a * (1.0 - top.a)
	if alpha <= 0.0:
		return Color(0, 0, 0, 0)
	return Color((top.r * top.a + below.r * below.a * (1.0 - top.a)) / alpha, (top.g * top.a + below.g * below.a * (1.0 - top.a)) / alpha, (top.b * top.a + below.b * below.a * (1.0 - top.a)) / alpha, alpha)


## An amorphous green outline: no two are quite alike, and it is faint inside, so the nutrient haze shows through.
func _draw_plankton(cell: Plankton) -> void:
	var r := plankton_draw_radius()
	draw_set_transform(cell.pos, 0.0, Vector2(r, r))  # (the outline is kept for a radius of 1)
	draw_colored_polygon(cell.outline.slice(0, 16), Color(0.5, 0.9, 0.45, 0.1))  # (the last point repeats the first)
	draw_polyline(cell.outline, Color(0.55, 0.95, 0.5, 0.85), 1.5 * pixel() / r)
	draw_circle(Vector2.from_angle(cell.shape) * 0.25, 0.18, Color(0.55, 0.95, 0.5, 0.55))
	draw_set_transform(Vector2.ZERO)


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
	if selected_id < 0 or not _bup_shown(selected_id):
		return
	var key := [selected_id, field.size, Time.get_ticks_msec() / HAZE_REFRESH_MSEC]
	if key != _steer_key:
		_steer_key = key
		var n := field.size
		var pixels: PackedByteArray = gpu_world.bup_steer_bytes(selected_id, STEER_ALPHA) if gpu_world != null and gpu_active else sim.bup_steer_bytes(selected_id, STEER_ALPHA)
		var image := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, pixels)
		if _steer == null or _steer.get_width() != n:
			_steer = ImageTexture.create_from_image(image)
		else:
			_steer.update(image)
	draw_texture_rect(_steer, Rect2(-radius, -radius, 2.0 * radius, 2.0 * radius), false)


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


## The rings on a selected and a hovered source or plankton (`offset` takes a thing's `pos` to the dish's own coordinates).
func _draw_pick_rings(canvas: CanvasItem, selected: Variant, hovered: Variant, offset: Vector2, radius: float) -> void:
	if selected != null:
		draw_ring(canvas, selected.pos - offset, radius, Color(1, 0.75, 0.3, 0.95))
	if hovered != null and hovered != selected:
		draw_ring(canvas, hovered.pos - offset, radius, Color(1, 1, 1, 0.9))


## How wide a husk is drawn, in µm: a few pixels, never smaller than a bup's body.
func husk_draw_size() -> float:
	return maxf(HUSK_PIXELS * pixel(), 2.0)


## Builds the husks' picture again when time has moved, the husks are different or the zoom has changed (and not oftener than HUSK_REFRESH_MSEC while only time moves).
func _refresh_husks() -> void:
	var shown := layer_shown(Layer.HUSKS)
	_husks_mesh.visible = shown
	if not shown:
		_husk_stamp = []  # (built afresh when it is shown again)
		return
	var count := sim.husk_count()
	var size: float = snappedf(husk_draw_size(), 0.001)
	var stamp := [time, count, size]
	if stamp == _husk_stamp:
		return
	var now := Time.get_ticks_msec()
	var changed_hard: bool = _husk_stamp.is_empty() or _husk_stamp[2] != size or (count == 0) != (_husk_stamp[1] == 0)
	if not changed_hard and now - _husk_built_msec < HUSK_REFRESH_MSEC:
		return
	_husk_stamp = stamp
	_husk_built_msec = now
	var husks := _husks_mesh.multimesh
	var capacity := maxi(HUSK_MIN_CAPACITY, nearest_po2(count))
	if husks.instance_count != capacity:
		husks.instance_count = capacity
		husks.custom_aabb = AABB(Vector3(-radius, -radius, -1.0), Vector3(2.0 * radius, 2.0 * radius, 2.0))
	husks.visible_instance_count = count
	if count > 0:
		husks.buffer = sim.husk_buffer(size, capacity)


## A thin ring marking a bup or source: GUI, so the same size and line at every zoom (see
## ring_radius_pixels for the one case where it grows).
func draw_ring(canvas: CanvasItem, center: Vector2, object_radius: float, color: Color) -> void:
	var px := pixel()
	canvas.draw_arc(center, ring_radius_pixels(object_radius / px) * px, 0.0, TAU, 64, color, px, true)


## A circle as a polygon with enough sides that its flats are under a pixel at the biggest the dish is drawn.
static func _disc_outline(disc_radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	points.resize(DISC_SIDES)
	for i in DISC_SIDES:
		points[i] = Vector2.from_angle(TAU * i / DISC_SIDES) * disc_radius
	return points


func _draw() -> void:
	# Dish: dark agar, green-tinted glass rim.
	draw_colored_polygon(_disc_outline(radius), Color(0.03, 0.06, 0.04))  # (not draw_circle: it draws a big disc with few sides, and the flats show when the dish is bigger than the window)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 96, Color(0.45, 0.8, 0.6, 0.6), 3.0)
	draw_arc(Vector2.ZERO, radius + 6.0, 0.0, TAU, 96, Color(0.45, 0.8, 0.6, 0.2), 2.0)

	if layer_shown(Layer.MEDIUM):
		_draw_medium()
	if layer_shown(Layer.STEERING):
		_draw_steering()
	if layer_shown(Layer.SOURCES):
		for source in sources:
			_draw_source(source)
	if layer_shown(Layer.PLANKTON):
		_draw_all_plankton()
	# The bups are a child node drawn on top of this; the rings and the lightning flash on top of them.


## A brighter stretch of the selection ring, centred on the way the bup's drift tends (up the slope), and shorter the
## more reliably it does: it narrows from the whole ring as the bup goes from guessing to certain.
func _draw_steering_arc(canvas: CanvasItem, id: int) -> void:
	var steering := bup_steering(id)
	if steering.z < ARC_SHOWN_ABOVE:
		return
	var px := pixel()
	var span := maxf(2.0 * (1.0 - steering.z) * TAU, MIN_STEER_ARC)
	var heading := Vector2(steering.x, steering.y).angle()
	canvas.draw_arc(_bup_pos(id), ring_radius_pixels(_bup_radius(id, px) / px) * px, heading - span / 2.0, heading + span / 2.0, 24, Color(1, 0.95, 0.7, 1.0), 3.0 * px, true)


## What goes above the bups (called by the overlay child): the selection and hover rings, the
## placement preview, the flash. Rings are GUI, not part of the dish: the same size and a thin
## line at any zoom.
func draw_overlay(canvas: CanvasItem) -> void:
	var px := pixel()
	if selected_id >= 0 and _bup_shown(selected_id):
		draw_ring(canvas, _bup_pos(selected_id), _bup_radius(selected_id, px), Color(1, 0.75, 0.3, 0.95))
		if layer_shown(Layer.STEERING):
			_draw_steering_arc(canvas, selected_id)
	if hovered_id >= 0 and hovered_id != selected_id and _bup_shown(hovered_id):
		draw_ring(canvas, _bup_pos(hovered_id), _bup_radius(hovered_id, px), Color(1, 1, 1, 0.9))
	_draw_pick_rings(canvas, selected_source, hovered_source, global_position, source_draw_radius())
	_draw_pick_rings(canvas, selected_plankton, hovered_plankton, Vector2.ZERO, plankton_draw_radius())
	if selected_husk != NO_HUSK:
		draw_ring(canvas, selected_husk, husk_draw_size(), Color(1, 0.75, 0.3, 0.95))
	if hovered_husk != NO_HUSK and hovered_husk != selected_husk:
		draw_ring(canvas, hovered_husk, husk_draw_size(), Color(1, 1, 1, 0.9))
	if place_preview_radius >= 0.0:
		var brush := Color(1, 0.3, 0.25, 0.9) if place_preview_erases else Color(1, 0.9, 0.5, 0.8)
		if place_preview_marker:
			draw_ring(canvas, place_preview_pos - global_position, place_preview_radius, brush)
		else:
			canvas.draw_arc(place_preview_pos - global_position, maxf(place_preview_radius, 3.0 * px), 0.0, TAU, 32, brush, px)
	if flash > 0.0:
		canvas.draw_colored_polygon(_disc_outline(radius), Color(0.85, 0.95, 1.0, flash))


# --- The GPU path ------------------------------------------------------------------------------
# The hooks of the GPU path: none is reached while `gpu_active` is false, except _choose_backend, which every `advance` asks.

## (3B) Runs `seconds` of simulation on the GPU, as `advance` does on the CPU (steps of seconds / ceil(seconds / MAX_STEP), the same
## budget rule), and returns the seconds simulated. First gpu_world.poll() (finished results: records, counts, stats, answers), and
## each of gpu_world.take_history_samples() through _record_history_from. Then for each step: time += delta, _step_plankton(delta),
## sim.step_world(delta, the sources' places and rates, time) for their emissions, source.emitted, the field's recorded clouds and
## deposits (take_recorded_*) gathered into the batch's events, and the history steps from _history_accum; then one
## gpu_world.queue_batch(plan) (see its keys). Emits `extinct` once when a polled count is 0, as `step` does.
func _advance_gpu(seconds: float, _budget_usec: int) -> float:
	gpu_world.poll()
	for sample: Dictionary in gpu_world.take_history_samples():
		_record_history_from(sample["stats"])
	if gpu_world.count_known() and gpu_world.bup_count() == 0 and time > 0.0 and not _extinct_signalled:  # (once, as `step` does)
		_extinct_signalled = true
		extinct.emit()
	if seconds <= 0.0:
		return 0.0
	var wanted := maxi(1, ceili(seconds / MAX_STEP))
	var delta := seconds / wanted
	var steps := gpu_world.steps_for(wanted)  # (the GPU's budget: fewer when the frames run long; 0 when its results are behind)
	if steps == 0:
		return 0.0
	var start := time
	var ranges := PackedInt32Array()
	var puffs := PackedFloat32Array()
	var cells := PackedInt32Array()
	var amounts := PackedFloat32Array()
	var history_steps := PackedInt32Array()
	for k in steps:
		time += delta
		_step_plankton(delta)
		var positions := PackedVector2Array()
		var rates := PackedFloat32Array()
		for source in sources:
			positions.append(source.pos - global_position)
			rates.append(source.rate)
			source.emitted += source.rate / 60.0 * delta
		sim.step_world(delta, positions, rates, time)  # (the sources' emissions only: the field records them, as it does the plankton's)
		var pf := field.take_recorded_puffs()
		var cc := field.take_recorded_cells()
		ranges.append_array(PackedInt32Array([puffs.size() / 6, pf.size() / 5, cells.size(), cc.size()]))
		for j in pf.size() / 5:
			puffs.append_array(PackedFloat32Array([pf[j * 5], pf[j * 5 + 1], pf[j * 5 + 2], pf[j * 5 + 3], pf[j * 5 + 4], 0.0]))
		cells.append_array(cc)
		amounts.append_array(field.take_recorded_amounts())
		_history_accum += delta
		if _history_accum >= HISTORY_INTERVAL:
			_history_accum -= HISTORY_INTERVAL
			history_steps.append(k)  # (taken on the GPU after this step, recorded here when it comes back)
	gpu_world.queue_batch({
		"steps": steps, "delta": delta, "start_time": start, "history_steps": history_steps,
		"events": {"ranges": ranges, "puffs": puffs, "cells": cells, "amounts": amounts},
		"feed_per_second": feed_density * CONCENTRATION_PER_DENSITY / 3600.0, "upkeep_scale": upkeep_factor, "limit": bup_limit,
		"death_puff": 0.0 if death_husks else Biology.DEATH_RELEASE * Cell.COST_PER_MASS, "stationary": stationary_phase,
	})
	return steps * delta


## (3A) Draws the bups from the GPU this frame (gpu/gpu_draw.gd): the MultiMesh is allocated at the GPU's capacity (not by
## _fit_render_capacity; again only when the capacity changes), its visible_instance_count is the slots the bups need, and
## gpu_world.draw_bups(its RD buffer, those slots, pixel()) records the render kernel when the picture must change (the same rule as
## `_process`: time moved, the zoom or the slots changed, the GPU's state was loaded, or trails may show).
func _draw_bups_gpu() -> void:
	var gpu := gpu_world.gpu
	if gpu == null or gpu.capacity <= 0 or not gpu.is_main:
		return  # (only the main device can write the picture's buffer: a world on a local device, as tools make, is not drawn)
	var multimesh := _bups_mesh.multimesh
	if multimesh.instance_count != gpu.capacity:
		multimesh.instance_count = gpu.capacity  # (a new RD buffer, all zero: the render kernel is set up again for it)
		_render_stale = true
	# The slots drawn: room for the bups there are, as on the CPU path (from the last count read back, which lags a few frames, or the
	# count loaded while none has come back), not for all the GPU holds: every slot drawn costs, an empty one too (about 2 ms a frame
	# for a million on an M1 Pro). The render kernel writes the slots past the live count as nothing; those past `slots` are not drawn.
	var known := population()
	if known <= 0:
		known = gpu.count
	var slots := mini(gpu.capacity, maxi(RENDER_MIN_CAPACITY, nearest_po2(known + known / 2)))
	if multimesh.visible_instance_count != slots:
		multimesh.visible_instance_count = slots
	var target := RenderingServer.multimesh_get_buffer_rd_rid(multimesh.get_rid())
	# Never multimesh.buffer or the per-instance setters here: a CPU copy of the instances would be uploaded over the GPU's.
	var stamp := [time, pixel(), target, slots, GpuDraw.of(gpu).generation]  # (a load of the GPU's state is a new picture too)
	var changed: bool = stamp != _render_stamp
	if _render_stale or changed or _trails_may_show:
		_render_stamp = stamp
		_render_stale = false
		_trails_may_show = changed  # (as on the CPU: a picture made as time moved may carry trails, the next still one clears them)
		gpu_world.draw_bups(target, slots, pixel())


## The setting's value as StartConditions.BACKEND_*: where the bups are simulated. Changing it (the setup screen sets it with the dish's
## start, `set_backend_setting` is for anything that changes it while the dish runs) takes effect at the next `advance`.
var backend_setting := StartConditions.BACKEND_AUTO

## The rule that picks the backend (the measurements are in tools/gpu/switch_check.gd's bench mode):
const AUTO_CPU_UP_USEC := 6000.0  ## Auto: the processor is left for the GPU once its steps for one frame are estimated to take more than this (two thirds of Main.FRAME_BUDGET_USEC: the picture and the rest of the frame need the remainder) ...
const AUTO_CPU_DOWN_USEC := 3000.0  ## ... and taken back when they come below this (the gap is the hysteresis: a colony hovering about one threshold does not flip every few seconds)
const CPU_RATIO_MIN := 0.5  ## how far the cost model's estimate may be corrected by what the processor really took (below and above 1)
const CPU_RATIO_MAX := 8.0
const CPU_RATIO_SMOOTHING := 0.1  ## how much of each frame's measured-to-estimated ratio is taken in
const AUTO_MIN_POPULATION := 1  ## below this many bups (none) Auto stays on the processor: there is nothing to move. A nearly empty dish can still cost the processor most of a frame (the grid, the clouds, the nine steps), and the rule's cost test is what decides, so a small colony at x10,000 goes to the GPU as soon as the processor could not hold the speed
const GPU_WAIT_SECONDS := 0.5  ## real seconds in a row that the rule wants the GPU before it takes over: a speed button pressed in passing, or a hitch, does not move the whole state. Counted in time, not frames: a frame costs most where the dish is heaviest, so a count of frames would be longest exactly there (a frame counts at most the 0.1 s the frames are capped at)
const AUTO_DOWN_FRAMES := 10  ## frames in a row that Auto's rule must want the processor before the GPU lets go (the GPU's count of bups arrives a few frames after a load; the setting does not wait)
const STEPS_AT_TOP_SPEED := 9  ## steps a frame takes at x10,000 at 60 frames a second (one frame is 167 s; the step is 18.5 s): what a step this long stands for when the caller does not say how many a frame holds
const TOP_SPEED_STEP := 17.5  ## a step this long or longer is taken for a frame of several steps (x10,000 at 60 Hz: 18.5 s), shorter ones for a frame of one (x1,000: 16.7 s). A guess: `advance` knows, and passes `steps`
const RULE_FRAME_SECONDS := 1.0 / 60.0  ## the frame Auto's costs are for: a frame's steps are scaled to one this long (the frame just past may be any length: a 120 Hz display's, or one a switch held up, whose many steps would otherwise make the processor look slower than it is and switch straight back)
## Measured on the M1 Pro (tools/gpu/switch_check.gd bench, 2,000-1,000,000 bups, 3 dishes, 2 step lengths, 5 repeats, least of them,
## the processor alone with BENCH_CPU_ONLY=1; fits to every point within 16%, mean error 4.6%, no clouds; the earlier fit, to 50,000 bups
## only, read up to 29% low at a million and at long steps): microseconds for one step by the processor, from the number of cells across,
## the motion sub-steps `m` (BupSim.moves_for), the bups `n`, the step's length `d` in seconds and the clouds `k`: 81.3 + 0.00156 cells²
## + 50.9 m + n (0.00993 + 0.00579 m + 0.000264 d) + 5.88 d + 0.06 k; by the GPU (unchanged; the batch's
## own cost, leaving the fixed ~220 µs of a submit and wait that only a local device pays): 146 + 0.00049 cells² + n (0.0044 + 0.0005 m) + 0.04 k.
## The GPU's share of the frame that these do not have (drawing, the readbacks and queries of the frame) is GPU_FRAME_USEC and
## GPU_FRAME_USEC_PER_BUP (measured with the game's pipeline, below).
## With 10,000 plankton clouds in the dish each step took (measured the same way, 8 repeats) 330-1,200 µs more on the processor and
## 150-1,000 µs more on the GPU (the clouds spread, and are read by every bup near them): 0.06 and 0.04 µs a cloud, good to about a
## factor of two. Measured to 50,000 bups and 10,000 clouds only: past that (up to the 1,000,000 bups a dish may hold) the rule
## extrapolates the lines, which have held so far (the processor's cost is linear in the bups by construction; the GPU's rose a little slower).
const CPU_STEP_MODEL := [81.3, 0.00156, 50.9, 0.00993, 0.00579, 0.06, 0.000264, 5.88]
const GPU_STEP_MODEL := [146.0, 0.00049, 0.0044, 0.0005, 0.04]
const GPU_FRAME_USEC := 250.0  ## what a frame on the GPU costs besides its steps, beyond the engine's own frame: the fixed part ...
const GPU_FRAME_USEC_PER_BUP := 0.005  ## ... and the part for each bup (every one is drawn, and the frame's questions look at every slot). Measured on the M1 Pro (tools/gpu/game_check.gd frame: vsync off, the frame with the GPU's bups paused against the engine's frame with none, same sitting, a busy machine): about 0 ms at 20,000 bups, 0.3-0.65 ms at 100,000, 5.8 ms at 1,000,000 (the old assumption, 1,000 µs at any size, was 2-3x too high at 100,000 and 6x too low at a million). It moves none of the rule's switches to the GPU (game_check thresholds: at each the GPU's frame is far below the processor's), and one hand-back (90 mm, x10,000, 2,000 clouds: below 2,250 bups instead of 4,000)

const TYPICAL_FRAMES := 5  ## the recent frames whose median length is the usual frame (rule_step)

var _recent_frames := PackedFloat32Array()  ## the lengths of the last TYPICAL_FRAMES frames `advance` was asked for (real seconds, capped)
var _gpu_wanted_seconds := 0.0  ## real seconds in a row that the rule wanted the GPU
var _fresh := true  ## a dish just made or loaded (a new one, a save, one thawed): its first choice does not wait GPU_WAIT_SECONDS: the wait guards against a speed pressed in passing, which a loaded dish has not had
var _cpu_votes := 0  ## frames in a row that Auto's rule wanted the processor while the GPU ran
var _gpu_on_cpu := false  ## gpu_active, but the CPU's bups are the true ones just now (an edit or a save brought them over): the GPU reloads them before its next batch
var _fractions_asked := {}  ## [gene, threshold] -> true for each share asked lately (fraction_with_gene_at_least): a load answers them from the CPU's bups


## The frames of `frame_seconds` that make GPU_WAIT_SECONDS (for tools and tests that call `_choose_backend` once a frame).
static func wait_frames(frame_seconds: float) -> int:
	return ceili(GPU_WAIT_SECONDS / frame_seconds - 1.0e-6)


## Estimated microseconds the steps of one frame take on the processor and on the GPU, as (cpu, gpu): `moves` the motion sub-steps of
## a step (BupSim.moves_for(step_delta)), `step_delta` its length, `steps` how many steps the frame holds (0, when not known: the
## length says, STEPS_AT_TOP_SPEED at TOP_SPEED_STEP or longer, else one).
static func backend_frame_costs(step_delta: float, cells_across: int, moves: int, population: int, frame_steps := 0, clouds := 0) -> Vector2:
	var steps := float(frame_steps if frame_steps > 0 else (STEPS_AT_TOP_SPEED if step_delta >= TOP_SPEED_STEP else 1))
	var cells_squared := float(cells_across) * cells_across
	var cpu: float = CPU_STEP_MODEL[0] + CPU_STEP_MODEL[1] * cells_squared + CPU_STEP_MODEL[2] * moves + population * (CPU_STEP_MODEL[3] + CPU_STEP_MODEL[4] * moves) + CPU_STEP_MODEL[5] * clouds + population * CPU_STEP_MODEL[6] * step_delta + CPU_STEP_MODEL[7] * step_delta
	var gpu: float = GPU_STEP_MODEL[0] + GPU_STEP_MODEL[1] * cells_squared + population * (GPU_STEP_MODEL[2] + GPU_STEP_MODEL[3] * moves) + GPU_STEP_MODEL[4] * clouds
	return Vector2(steps * cpu, GPU_FRAME_USEC + GPU_FRAME_USEC_PER_BUP * population + steps * gpu)


## The median of the recent frames' lengths (0 for none).
static func typical_frame(frames: PackedFloat32Array) -> float:
	if frames.is_empty():
		return 0.0
	var sorted := frames.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


## The step the backend rule is judged on. A step is the playback speed times the frame's length, and only the speed is the player's:
## one short frame (a stray 1.8 ms one at x100 makes a 0.18 s step) must not make the rule judge another speed and restart the takeover
## count. So a one-step frame is judged as the same speed over the usual frame (`typical`, from `typical_frame`); pressing x1 is judged
## at once, and a hitch (a long frame) does not make x1 faster. Frames of several steps are taken as they are, and without the frame's
## length or its steps the step is taken as given.
static func rule_step(step_delta: float, steps: int, real: float, typical: float) -> float:
	if steps != 1 or real <= 0.0 or typical <= 0.0:
		return step_delta
	return step_delta * typical / real


## The backend rule, as a function of what it depends on alone (so that it can be tested and re-asked after anything changes): whether the
## GPU should run these steps. `setting` is a StartConditions.BACKEND_*; `step_delta` this frame's step; `moves` BupSim.moves_for of it;
## `frame_steps` how many steps the frame holds (0: guess), `clouds` the plankton clouds in the dish (NutrientField.puff_count());
## `running_gpu` where the bups are now (Auto keeps the GPU until the processor would manage with room to spare, which is
## the hysteresis); `gpu_ok` whether the machine has a usable GPU and one that holds `limit` bups. It does not wait for GPU_WAIT_SECONDS:
## `_choose_backend` does.
## - off: never; on: whenever it can; auto: when the processor's estimated time for the frame is above AUTO_CPU_UP_USEC (AUTO_CPU_DOWN_USEC
##   once the GPU is running) and the GPU's is less, with at least AUTO_MIN_POPULATION bups. The processor's time for the frame is this dish's plus
##   `other_cpu_usec`, what the other dishes still on the processor are estimated to take (several dishes share one frame: it is their total that must fit).
static func backend_wants_gpu(setting: String, step_delta: float, moves: int, cells_across: int, population: int, running_gpu: bool, gpu_ok: bool, frame_steps := 0, clouds := 0, other_cpu_usec := 0.0, cpu_ratio := 1.0) -> bool:
	if not gpu_ok or setting == StartConditions.BACKEND_CPU:
		return false
	if setting == StartConditions.BACKEND_GPU:
		return true
	if population < AUTO_MIN_POPULATION:
		return false
	var costs := backend_frame_costs(step_delta, cells_across, moves, population, frame_steps, clouds)
	return costs.x * cpu_ratio + other_cpu_usec > (AUTO_CPU_DOWN_USEC if running_gpu else AUTO_CPU_UP_USEC) and costs.y < costs.x


## Whether the GPU can run a dish at all: the machine has a usable one (GpuWorld.available()) and it holds `limit` bups (`most` is
## GpuWorld.most_bups()).
static func backend_usable(gpu_available: bool, limit: int, most: int) -> bool:
	return gpu_available and limit <= most


## Where the bups run now, "gpu" or "cpu" (the debug log and the pause menu's record of the settings say it).
func backend_running() -> String:
	return "gpu" if gpu_world != null and gpu_active else "cpu"


## Sets the setting (StartConditions.BACKEND_*; anything else is Auto) and has the next `advance` ask again.
func set_backend_setting(value: String) -> void:
	backend_setting = value if value in StartConditions.BACKENDS else StartConditions.BACKEND_AUTO
	_gpu_wanted_seconds = 0.0


## (3C) Chooses where the bups run for this frame (the switch rule), from the setting (on, off, automatic),
## `step_delta` (judged by rule_step, so one stray short frame does not count as a short step, though a whole frame's steps run as asked), `steps` (how many of them the frame holds, if
## the caller knows: `advance` does; 0 guesses from the length; Auto's costs take them scaled to a frame of RULE_FRAME_SECONDS by the length
## of the frame just past), the population, the dish and the limit:
## makes `gpu_world` when first needed (if GpuWorld.available()), moves the state (gpu_world.load_from_cpu / export_to_cpu) and sets
## `gpu_active`. Called at the top of every `advance`, before any step (never while paused). The processor takes over at once when the
## setting or the machine says so; when only Auto's rule says so, after AUTO_DOWN_FRAMES frames of it saying so
## (the GPU's count of bups reaches the dish a few frames after a load). The GPU takes over only after GPU_WAIT_SECONDS of real time in a row of the rule
## wanting it, except for a dish just made or loaded (`_fresh`), which goes at once when the rule wants it. Asked again on every frame, so a resize, a new limit, a new speed or a new setting (all of which `advance`
## meets here) is re-evaluated at once.
func _choose_backend(step_delta: float, steps := 0) -> void:
	var real := minf(get_process_delta_time(), 0.1)  # (the frame the caller advances for: main.gd's, capped as it caps it, MAX_FRAME_SECONDS)
	var typical := 0.0
	if steps > 0 and real > 0.0:
		_recent_frames.append(real)
		if _recent_frames.size() > TYPICAL_FRAMES:
			_recent_frames = _recent_frames.slice(_recent_frames.size() - TYPICAL_FRAMES)
		typical = typical_frame(_recent_frames)
	var rule_delta := rule_step(step_delta, steps, real, typical)  # (the rule is judged on this; the steps that run keep step_delta)
	var allowed := backend_setting != StartConditions.BACKEND_CPU
	var available := backend_usable(GpuWorld.available(), bup_limit, GpuWorld.most_bups())
	var rule_steps := steps
	if steps > 0 and real > 0.0:
		rule_steps = maxi(1, roundi(steps * RULE_FRAME_SECONDS / real))  # (the same work per real second, whichever backend ran the last frame and however long it took)
	var on_gpu := gpu_world != null and gpu_active
	var frame_estimate := backend_frame_costs(rule_delta, field.get_size(), sim.moves_for(step_delta), population(), steps, field.puff_count()).x  # (for the frame as it really was: what `measured_usec` measures)
	if not on_gpu and measured_usec > 0.0 and _frame_estimate_usec > 0.0:
		_cpu_ratio = lerpf(_cpu_ratio, clampf(measured_usec / _frame_estimate_usec, CPU_RATIO_MIN, CPU_RATIO_MAX), CPU_RATIO_SMOOTHING)
	_frame_estimate_usec = frame_estimate
	cpu_cost_estimate = backend_frame_costs(rule_delta, field.get_size(), sim.moves_for(step_delta), population(), rule_steps, field.puff_count()).x * _cpu_ratio
	var wants := backend_wants_gpu(backend_setting, rule_delta, sim.moves_for(step_delta), field.get_size(), population(), on_gpu, available, rule_steps, field.puff_count(), other_cpu_load, _cpu_ratio)
	_gpu_wanted_seconds = _gpu_wanted_seconds + (real if real > 0.0 else RULE_FRAME_SECONDS) if wants else 0.0  # (no frame length, as when a tool calls this directly: a frame of the rule's)
	if not wants:
		_fresh = false  # (a small dish: it waits like any other when it grows)
	switch_wanted = false
	if gpu_world != null and gpu_active:
		_cpu_votes = 0 if wants else _cpu_votes + 1
		var rule_only := allowed and available  # (what is left to say 'no' is Auto's rule: it must say so for a while)
		if not wants and (not rule_only or _cpu_votes >= AUTO_DOWN_FRAMES):
			if rule_only and backend_setting == StartConditions.BACKEND_AUTO and not switch_allowed:
				switch_wanted = true  # (Auto's rule wants the processor: it waits its turn)
				switch_wanted_gpu = false
				return
			_to_cpu_for_edit()  # (its state, brought over unless an edit has just done so)
			gpu_active = false
			_gpu_on_cpu = false
			_cpu_votes = 0
			_render_stale = true
			if rule_only:
				_gpu_wanted_seconds = 0.0  # (Auto's rule let go: it must want the GPU for as long again before the GPU takes over)
		elif wants and _gpu_on_cpu:
			_load_gpu()  # (a save or an edit has brought the bups over; the GPU takes them back before it runs)
	elif wants and (_gpu_wanted_seconds >= GPU_WAIT_SECONDS - 1.0e-6 or _fresh):
		if backend_setting == StartConditions.BACKEND_AUTO and not switch_allowed:
			switch_wanted = true  # (Auto's rule wants the GPU: it waits its turn)
			switch_wanted_gpu = true
			return
		if gpu_world == null:
			gpu_world = GpuWorld.new(sim)
		_load_gpu()
		gpu_active = true
		_fresh = false
		_cpu_votes = 0
		_render_stale = true


## What load_from_cpu needs of the dish, and what it shows of the bups (the selected and hovered ones, the shares of a gene a goal
## watches), so that the GPU's answers to these start from the CPU's instead of from nothing.
func _gpu_params() -> Dictionary:
	return {"radius": radius, "limit": bup_limit, "seed": patch_seed, "upkeep_scale": upkeep_factor, "feed_per_second": feed_density * CONCENTRATION_PER_DENSITY / 3600.0, "step_seconds": MAX_STEP,
		"tracked": [selected_id, hovered_id], "fractions": _fractions_asked.keys()}


## Hands the CPU's bups and field to the GPU (the CPU's are the true ones until it has).
func _load_gpu() -> void:
	gpu_world.load_from_cpu(field, _gpu_params())
	_gpu_on_cpu = false


## Forgets what the GPU holds, for a dish that is being replaced (a new one): no export, the CPU's field stops recording, and what
## the GPU still has on its way is dropped. The CPU's own state is the new dish's, which the caller makes; `_mark_gpu_dirty` loads it.
func _discard_gpu_state() -> void:
	field.set_recording(false)
	if gpu_world.has_method("_pipeline_reset"):
		gpu_world.call("_pipeline_reset", 0)
	gpu_world.take_history_samples()  # (the old dish's samples that came back and were not yet recorded: not the new dish's)
	_gpu_on_cpu = true


## (3C) Before an edit made by hand (adding or removing bups, a resize, the limit, a save): brings the GPU's state to the CPU
## (gpu_world.export_to_cpu, which stalls), so the edit is made on the CPU's bups. Nothing to do when it already has them.
func _to_cpu_for_edit() -> void:
	if gpu_world == null or not gpu_active or _gpu_on_cpu:
		return
	gpu_world.export_to_cpu(field)
	for sample: Dictionary in gpu_world.take_history_samples():  # (the history samples of the batches the stall finished: recorded, in order, before any CPU step)
		_record_history_from(sample["stats"])
	_gpu_on_cpu = true


## (3C) After an edit made by hand, a new dish or a load: the CPU's state is the true one, so the GPU loads it (now, so that the picture and
## the counts are the edited dish's, whether or not time is moving), and results of batches from before it are dropped.
func _mark_gpu_dirty() -> void:
	if gpu_world == null or not gpu_active:
		return
	_gpu_on_cpu = true
	if bup_limit <= GpuWorld.most_bups():  # (a limit the device cannot hold stays on the CPU: the next `advance` says so)
		_load_gpu()
