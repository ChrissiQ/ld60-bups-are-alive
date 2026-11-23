class_name Dish
extends Node2D
## The petri dish on the screen. Its bups, nutrient, clouds, husks, plankton and sources run in the simulation's pooled world (SimService's
## WorldClient: a dish of it under `row`); this node is the dish's face: it asks for the dish (`strike`, `load_blob`), sends the player's
## edits as commands, and shows what the snapshots say of it (its count and figures, its plankton and sources, the answers about the bups it
## asks after, its history's samples) and the picture the simulation publishes for the main view (DishDrawing). It also keeps what is the
## screen's own: selection and hover, layers, the watch list (pins in the shared LineageStore, held by the dish's number), names.
## Lengths are µm and times are seconds of simulation time, which runs at real biological rates (see Biology); the player's playback
## speed only multiplies how much of it passes per second. Bups are named by a stable id (an int).

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
const GOAL_UPKEEP_FACTOR := 3.0  ## how much costlier staying alive is once goal mode reaches experiment 2 (set by GoalTracker.apply_costs; 1 elsewhere) [choice: x10 kills colonies outright, x3 does not]
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
const DIFFUSE_ACCURACY := 0.004  ## the most D dt / cell^2 one solve of the diffusion is allowed (how far the nutrient spreads in it, in cells): a longer stretch is solved in pieces, down to DIFFUSE_INTERVAL.
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
const ARC_SHOWN_ABOVE := 0.54  ## the chance that it ends up further up the slope after a minute (0.5 a coin toss, 1 sure) above which the arc shows
const MOTION_STEP := 3.0  ## the longest motion sub-step on a fine nutrient grid, in seconds: a swimmer must not jump farther than a gradient is wide (~50-100 µm; a bup diffuses ~40 µm in 3 s). On a coarser grid it grows, see MOTION_STRUCTURE
const MOTION_STRUCTURE := 500.0  ## µm: the size of the smallest structure in the nutrient worth looking for (a plankton cloud: a patch of 250 µm radius, spread by hours of diffusion). Where grid cells are bigger than this the motion sub-step grows with the square of the cell since a bup sees no more by looking again after moving a short way across one
const CLOUD_HANDOVER := 0.5  ## a plankton's nutrient is kept as a Gaussian cloud until its sigma is this share of a grid cell, then given to the grid
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

const PROBE_SPEED := 20.0  ## the speed and sense range a point's probe is asked with (the founder's): only its concentration is shown
const PROBE_SENSE := 50.0
const PROBE_MOVE := 1.0  ## µm a probed point must move before it is asked again
const HUSK_HERE := 0.01  ## µm: how near a picked husk's place the husk asked after must lie (it is the husk there: a husk does not move)
const SOURCE_HERE := 0.01  ## µm: how near the place a source was put a new source in the world's copy must lie to be that one

var drawing := DishDrawing.new(self)  ## how the dish is drawn: the simulation's picture of its bups, the dish, the rings above the bups
var world: WorldClient = null  ## the simulation's world (SimService's, taken when the dish first needs it)
var row := -1  ## the dish's row in the world (-1: not in it: not struck yet, frozen, refused or gone)
var number := 0  ## the dish's world number, as its bups' ids and its pins carry it (never reused in a game; the screen shows the dish by a number of its own); the screen sets it before `strike` (0 is taken as 1)
var radius := DEFAULT_RADIUS  ## physical size of the dish; it changes only with a new dish (`strike`, a load) or `resize_to`
var resolution := StartConditions.MIN_NUTRIENT_RESOLUTION  ## the most cells across its nutrient grid (StartConditions.nutrient_resolution)
var bup_limit := StartConditions.DEFAULT_BUP_LIMIT:  ## the most bups the dish holds (chosen in free mode)
	set(value):
		bup_limit = clampi(value, 1, StartConditions.MAX_BUP_LIMIT)
		_send_params({"limit": bup_limit})
var nutrients_placed := 0  ## how many units of nutrient the player has dropped in by hand
var sources: Array[NutrientSource]:  ## the sources, as the newest copy of the dish's world has them (their positions global)
	get:
		_take_sources()
		return _sources_list
var feed_density := 3.0:  ## units of nutrient fed in to each mm² of the dish every hour, spread evenly (a density, so the dish's size does not change it)
	set(value):
		feed_density = clampf(value, 0.0, StartConditions.MAX_FEED_DENSITY)
		_send_params({"feed_density": feed_density})
var medium_thickness := StartConditions.DEFAULT_MEDIUM_THICKNESS  ## how many times thicker than water the medium is (see StartConditions.medium_thickness)
var bloom_density := 0.0:  ## plankton appearing in each mm² of the dish every sim-day (24 hours), at steady intervals, at random places (see `bloom_per_day`)
	set(value):
		bloom_density = clampf(value, 0.0, StartConditions.MAX_BLOOM_DENSITY)
		_send_params({"bloom_density": bloom_density})
var death_husks := false:  ## a dead bup leaves a husk that leaks its nutrient back over Biology.HUSK_SECONDS instead of giving it back at once (see StartConditions.death_husks)
	set(value):
		death_husks = value
		_send_params({"flags": _flags()})
var plankton_husks := false:  ## a plankton that dies leaves a husk instead of bursting into a cloud (see StartConditions.plankton_husks)
	set(value):
		plankton_husks = value
		_send_params({"flags": _flags()})
var stationary_phase := false:  ## starving bups stop growing, shrink and die at a constant rate (Biology.STARVE_*) instead of dying when the reserve is gone (see StartConditions.stationary_phase)
	set(value):
		stationary_phase = value
		_send_params({"flags": _flags()})
var upkeep_factor := 1.0:  ## multiplies what staying alive costs every bup (its base and per-mass maintenance)
	set(value):
		upkeep_factor = maxf(value, 0.0)
		_send_params({"upkeep": upkeep_factor})
var plankton: Array[Plankton]:  ## the plankton, as the newest copy of the dish's world has them (positions in the dish)
	get:
		_take_plankton()
		return _plankton_list
var time := 0.0:  ## the world's clock as the newest snapshot has it (one clock for every dish, read alike whether the dish is in view or parked)
	get:
		return world.latest().sim_time if world != null and row >= 0 and world.latest().seq > 0 else time
var flash := 0.0  ## lightning flash intensity, decays to 0
var want_thumbnails := false  ## the screen shows every dish's small picture (the strip): the world is asked for the thumbnails' atlas with the main view
var _layers_hidden := {}  ## Layer -> true for each one hidden

## Presentation state set by the screen that shows this dish (nothing here affects the sim).
var pick_mode := PickMode.ALL  ## the select tool ignores whatever this leaves out; what is selected stays selected when it changes
var _hover_pos := Vector2.ZERO  ## where the pointer was when `hovered` was picked
var _hover_slack := 0.0  ## and the slack it was picked with
var _hover_waiting := false  ## the picture has not yet answered whether a bup is at `_hover_pos`: `hovered` is empty until it does
var _hover_known := false  ## `hovered` is what is at `_hover_pos` (it may be nothing): a click there takes it
var _click_at := Vector2.INF  ## a click made before the hover there was answered: it selects what the hover finds once it does
var selected := DishPick.new()  ## what was clicked (`selection_changed` fires when its bup changes)
var hovered := DishPick.new()  ## what is under the pointer
var pointed_bup := -1  ## a bup the screen points out (the tour's), asked after as the selected and the hovered are, so its place is known
const NO_HUSK := DishPick.NO_HUSK
enum Preview { BRUSH, ERASE, MARKER }  ## what the placement preview shows: a circle the size of what a click scatters, the eraser's brush, or a single point (a source about to be placed: drawn as a GUI ring, like a selection)
var place_preview_pos := Vector2.ZERO
var place_preview_radius := -1.0  ## < 0 hides the placement preview
var place_preview_kind := Preview.BRUSH

var _history := DishHistory.new()
var history: DishHistory:  ## what the graph shows of this dish (a parked dish's samples are recorded when it is read: `take_parked`)
	get:
		if not _unrecorded.is_empty():
			var samples := _unrecorded
			_unrecorded = []
			_history.take(samples)
		return _history
var _unrecorded: Array = []  ## history samples a parked dish was handed and has not recorded yet, oldest first (at most BACKLOG_MAX: `_thin_backlog`)
const BACKLOG_MAX := 96  ## the most samples a parked dish keeps unrecorded; past it every second one is let go (the history draws a line across the gap)
var edit_count := 0  ## bumped by every change made to the dish by hand and by every new copy of its world, so screens can tell when to look again
var patch_seed := 0  ## which landscape of richer and poorer patches the nutrient follows (see NUTRIENT_PATCHINESS)
var watched: Array[int] = []  ## the bups the player is watching, newest first (see watch_bup); each holds a pin of this dish's number
var view_zoom := 0.0  ## where the screen was looking at this dish when it last looked away: the camera's zoom (0: never looked yet) ...
var view_position := Vector2.ZERO  ## ... and its position
static var watch_epoch := 0  ## bumped with every dish's watch_version: the watch list looks at every dish only when it has changed
var watch_version := 0  ## bumped whenever the list changes, so its panel can rebuild only then

var _state: DishState = null  ## what the newest snapshot says of the dish (null until one has it)
var _answers := {}  ## the newest answers to its questions: {tracked: {id: record bytes}, steer: {id: Vector3}, probes: PackedFloat32Array}
var _world_version := -1  ## the copy of the dish's world last taken
var _sources_by_id := {}  ## a source's id in the dish's world -> its NutrientSource (kept, so a selection survives a new copy)
var _plankton_by_id := {}  ## a plankton's id in the dish's world -> its Plankton, likewise
var _plankton_list: Array[Plankton] = []  ## what `plankton` hands out
var _sources_list: Array[NutrientSource] = []  ## what `sources` hands out
var _pending_world: DishWorldCopy = null  ## the newest copy of the dish's world, while its sources or plankton are not unpacked yet: each is unpacked when it is read (`sources`, `plankton`)
var _sources_pending := false  ## the sources of `_pending_world` are not unpacked yet
var _plankton_pending := false  ## the plankton of `_pending_world` are not unpacked yet
var _asked := {}  ## the questions last sent (WorldClient.ask)
var _fractions := {}  ## name -> [gene, threshold] for each share asked lately (fraction_with_gene_at_least)
var _probe := Vector2.INF  ## the point of the dish whose medium is asked after (nutrient_reading)
var _husk_point := Vector2.INF  ## the place the select tool last looked for a husk at (husk_at), and the reach it looked within
var _husk_reach := 0.0
var _husks_seen := {}  ## a picked husk's place -> what an answer last said of it ([x, y, energy, age, pieces let go]), until one says it is gone
var _world_time := 0.0  ## the world time of the newest copy of the dish's world (a source's `emitted` is as of then)
var _pending_names := {}  ## id -> a name given before the bup's family record came
var _extinct_signalled := false
var _parked := false  ## out of the main view (`park`): what the snapshots say of it is read when asked, not taken from each one
var _resizes: Array = []  ## [reply, radius asked] of each resize not yet answered, oldest first (`resize_to`)
var _resize_agreed := 0.0  ## µm: the size the world last agreed to, while resizes are waiting for their answers
var _source_to_select := Vector2.INF  ## where a source was just placed with `select`: it is selected when the copy of the world that has it comes
var _seed := 0  ## the dish's seed for the world (0: the world draws one from its own and the number)
var _rng := RandomNumberGenerator.new()  ## where the founders lie and the patches' landscape
static var _constants := {}  ## SimConstants.build(), for RecordCodec


func _init() -> void:
	selected.bup_changed.connect(selection_changed.emit)
	_rng.randomize()


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR  # the haze is a small texture stretched over the dish
	if visible and drawing.bups_mesh == null:  # (a shown dish is told it is visible as it enters the tree, before this, and has made them then)
		drawing.build_children()
	_world()


## A dish out of the main view is hidden and does nothing a frame (`park`); what it draws is made the first time it is shown.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible and is_inside_tree() and drawing.bups_mesh == null:
		drawing.build_children()


## The dish leaves the main view: it is hidden, does nothing a frame, and takes back the questions it asked about what was picked (the
## screen let go of them first). It no longer hears each snapshot: its count and figures are read from the newest when asked, and the screen
## hands it what it must not miss (`take_parked`), so a thousand parked dishes cost a snapshot nothing.
func park() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_DISABLED
	_ask()
	drawing.forget_view()  # (back in view, it tells the world afresh what it shows: the world has shown another dish meanwhile)
	_parked = true
	if world != null and world.snapshot_changed.is_connected(_on_snapshot):
		world.snapshot_changed.disconnect(_on_snapshot)


## The dish comes into the main view: shown and run every frame again, and it hears every snapshot (the newest at once).
func unpark() -> void:
	process_mode = Node.PROCESS_MODE_INHERIT
	visible = true
	if not _parked:
		return
	_parked = false
	_on_snapshot(_world().latest())


func is_parked() -> bool:
	return _parked


## What a snapshot brings a parked dish that it must not miss: its history's samples, a new copy of its world, and that it has died out. The
## screen calls it only for a dish the snapshot has one of these for; the rest (the count, the figures, the time) is read when asked. The
## samples are only kept here (recording a thousand dishes' samples at once would hold up a frame): they are recorded when the history is
## next read, which the screen does for a few parked dishes a frame (`record_history`). Returns whether samples were kept.
func take_parked(snap: Snapshot) -> bool:
	if row < 0:
		return false
	var ds: DishState = snap.dishes.get(row)
	if not is_mine(ds):
		return false
	_state = ds
	var samples: Array = snap.history.get(row, [])
	_unrecorded.append_array(samples)
	if _unrecorded.size() > BACKLOG_MAX:
		_thin_backlog()
	var copy: DishWorldCopy = snap.worlds.get(row)
	if copy != null and copy.version != _world_version:
		_hold_world(copy)
	if ds.extinct and not _extinct_signalled:
		_extinct_signalled = true
		extinct.emit()
	return not samples.is_empty()


## Lets go of every second unrecorded sample, the oldest and the newest kept, until at most BACKLOG_MAX are left: a dish parked for a long time at
## a high speed would otherwise hold a sample for every interval it missed. The history fills what is missing from a line between the samples
## that remain (the oldest stays so that a dish's history still begins where it began).
func _thin_backlog() -> void:
	while _unrecorded.size() > BACKLOG_MAX:
		var kept := _unrecorded.slice(0, _unrecorded.size(), 2)
		if _unrecorded.size() % 2 == 0:  # (the newest is not one of every second from the oldest)
			kept.append(_unrecorded[-1])
		_unrecorded = kept


## Records the samples a parked dish was handed, for as long as the clock (Time.get_ticks_usec) is before `deadline` (0: all of them). Reading the
## history does all of them.
func record_history(deadline := 0) -> void:
	if deadline == 0 or _unrecorded.is_empty():
		var _read := history  # (reading it records them)
		return
	var went := _history.take_until(_unrecorded, deadline)
	_unrecorded = _unrecorded.slice(went)


## The history's version as far as it is recorded: reading it does not record the samples a parked dish is holding (the screen records those within
## a budget each frame, `Main._record_parked_history`), so a screen that only looks for a change can ask every dish every frame.
func history_version() -> int:
	return _history.version


func has_unrecorded() -> bool:
	return not _unrecorded.is_empty()


## A dish that leaves the screen leaves the world too (a trash); a frozen dish has left it already.
func _exit_tree() -> void:
	_leave_world()
	drawing.release()


## The simulation's world, joined on first use: its snapshots and refusals come to the dish from then on.
func _world() -> WorldClient:
	if world == null:
		world = WorldClient.shared()
	if not _parked and not world.snapshot_changed.is_connected(_on_snapshot):
		world.snapshot_changed.connect(_on_snapshot)
	if not world.refused.is_connected(_on_refused):
		world.refused.connect(_on_refused)
	return world


## The dish's family tree: the world's LineageStore (null when the backend keeps none).
func lineage_store() -> Object:
	return _world().lineage()


## Seeds the dish's founders' places and its patches' landscape, and the dish's own random numbers in the world, so a run repeats.
func set_seed(value: int) -> void:
	_rng.seed = value
	_seed = value & 0x7fffffff


## Redraws the dish only when something it shows may have changed (DishDrawing.refresh).
func refresh_drawing() -> void:
	drawing.refresh()


## The lightning flash fades in real time, so it still clears while the sim is paused. A hover the picture has not answered yet is asked
## again until it is (then a click made meanwhile takes what it found), the questions about the bups and the medium the screen shows are
## sent when they change, and the picture is brought up to date (DishDrawing.process), once a frame.
func _process(delta: float) -> void:
	flash = maxf(0.0, flash - delta * 1.5)
	if _hover_waiting:
		hover_at(_hover_pos, _hover_slack)
	if _click_at.is_finite() and not _hover_waiting:
		if _hover_is_at(_click_at):
			selected.set_to(hovered)
		_click_at = Vector2.INF
	_take_resizes()
	_ask()
	drawing.process()


## The picture this frame (DishDrawing.take_payload): the screen takes it before it moves the camera, so a followed bup's place is the
## one drawn.
func take_picture() -> void:
	drawing.take_payload()


## Everything that belongs to one run of a dish and must start fresh with a new or loaded dish.
func _reset_runtime_state() -> void:
	for id in watched:
		unpin_bup(id)
	watched.clear()
	watch_version += 1
	watch_epoch += 1
	clear_selection()
	clear_hover()
	_click_at = Vector2.INF
	_extinct_signalled = false
	_state = null
	_answers = {}
	_asked = {}
	_fractions = {}
	_pending_names = {}
	_world_version = -1
	_unrecorded = []
	_source_to_select = Vector2.INF
	_husk_point = Vector2.INF
	_husks_seen = {}
	_sources_by_id = {}
	_plankton_by_id = {}
	_pending_world = null
	_sources_pending = false
	_plankton_pending = false
	_resizes = []
	pointed_bup = -1
	_sources_list.clear()
	_plankton_list.clear()
	history.reset()


## The DP_FLAGS bits of the dish's switches.
func _flags() -> int:
	return (int(stationary_phase) << GpuLayout.DPF_STATIONARY) | (int(death_husks) << GpuLayout.DPF_DEATH_HUSKS) | (int(plankton_husks) << GpuLayout.DPF_PLANKTON_HUSKS)


## A running dish's settings change from its next step (nothing is sent before it is in the world).
func _send_params(params: Dictionary) -> void:
	if row >= 0:
		_world().set_params(row, params)


func _number() -> int:
	if number <= 0:
		number = 1
	return number


## Abiogenesis: founders appear near the centre, part-way through their first growth (no divisions in their line: nothing precedes them).
## Every mode starts a dish through here, so setup can't drift between modes. The dish is asked of the world and appears in a later
## snapshot; it begins at the world's time.
func strike(start: StartConditions = null) -> void:
	if start == null:  # goal mode's dish: the usual conditions
		start = StartConditions.new()
	_leave_world()
	flash = 1.0
	_edited()
	nutrients_placed = 0
	radius = clampf(start.dish_radius, StartConditions.MIN_SIM_RADIUS, StartConditions.MAX_DISH_RADIUS)
	resolution = clampi(start.nutrient_resolution, StartConditions.MIN_NUTRIENT_RESOLUTION, MemoryMode.max_resolution())  # (a dish is never made over low-memory mode's limits)
	medium_thickness = start.medium_thickness
	bup_limit = mini(start.bup_limit, MemoryMode.max_bup_limit())
	feed_density = start.feed_density
	bloom_density = start.bloom_density
	upkeep_factor = 1.0
	death_husks = start.death_husks
	plankton_husks = start.plankton_husks
	stationary_phase = start.stationary_phase
	_reset_runtime_state()
	patch_seed = maxi(1, _rng.randi() & 0x7fffffff)
	var spec := DishSpec.new()
	spec.number = _number()
	spec.radius = radius
	spec.resolution = resolution
	spec.limit = bup_limit
	spec.seed = _seed
	spec.flags = _flags()
	spec.nutrient_density = clampf(start.nutrient_density, 0.0, StartConditions.MAX_NUTRIENT_DENSITY)
	spec.feed_density = feed_density
	spec.bloom_density = bloom_density
	spec.upkeep = upkeep_factor
	spec.medium_thickness = medium_thickness
	spec.patch_seed = patch_seed
	var founders := clampi(start.bups, 1, bup_limit)
	spec.founders = _founder_records(start, founders)
	for i in founders:
		var chosen: Dictionary = start.founders[i] if i < start.founders.size() else {}
		spec.founder_names.append(chosen.get("name", ""))
	row = _world().add_dish(spec)
	begin_at(_world().latest().sim_time)


## The founders' records (GpuLayout's bup record, as SimCore.add_dish takes them): the founder's genome in the colour the player chose for
## each, a newborn's mass grown by up to as much again (not all at the same point in the cycle), FOUNDER_ENERGY (no more than the body can hold), in a disc that grows with
## their number (4 in a spot 40 µm across, 100 across about 430 µm); the world gives them their ids when the dish is added.
func _founder_records(start: StartConditions, count: int) -> PackedByteArray:
	var w := GpuLayout.RECORD_WORDS
	var spread := minf(radius * 0.8, 40.0 + 40.0 * sqrt(maxf(count - 4.0, 0.0)))
	var all := PackedFloat32Array()
	all.resize(count * w)
	for i in count:
		var founder := Genome.founder()
		var chosen: Dictionary = start.founders[i] if i < start.founders.size() else {}
		if chosen.has("color"):
			founder = Genome.with_color(founder, Genome.color_from_hex(chosen["color"]))
		var born: float = Cell.mass_to_add(founder)
		var o := i * w
		for g in GpuLayout.GENE_NAMES.size():
			all[o + GpuLayout.R_SPEED + g] = founder[GpuLayout.GENE_NAMES[g]]
		all[o + GpuLayout.R_MUTATOR] = founder["mutator"]
		all[o + GpuLayout.R_HUE] = founder["hue"]
		all[o + GpuLayout.R_SAT] = founder["sat"]
		all[o + GpuLayout.R_VAL] = founder["val"]
		all[o + GpuLayout.R_BIRTH_MASS] = born
		var mass := born * (1.0 + _rng.randf())
		all[o + GpuLayout.R_MASS] = mass
		all[o + GpuLayout.R_ENERGY] = minf(FOUNDER_ENERGY, Cell.RESERVE_PER_MASS * mass)  # a body holds at most this
		var at := Vector2.from_angle(_rng.randf() * TAU) * (spread * sqrt(_rng.randf()))
		all[o + GpuLayout.R_X] = at.x
		all[o + GpuLayout.R_Y] = at.y
		all[o + GpuLayout.R_DX] = 1.0
		all[o + GpuLayout.R_DY] = 0.0
		all[o + GpuLayout.R_PX] = GpuLayout.NO_PICTURE
		all[o + GpuLayout.R_PY] = GpuLayout.NO_PICTURE
		all[o + GpuLayout.R_FAST] = -1.0
	return all.to_byte_array()


## A saved or frozen dish (DishBlob, from DishCodec.read_blob or a freeze's reply) comes back into the world at its time, in place of this
## dish's own. False, leaving the dish as it was, for no blob.
func load_blob(blob: DishBlob) -> bool:
	if blob == null:
		return false
	_leave_world()
	var spec := DishSpec.from_dict(blob.spec)
	number = spec.number if spec.number > 0 else _number()
	radius = spec.radius
	resolution = spec.resolution
	medium_thickness = spec.medium_thickness
	patch_seed = spec.patch_seed
	_reset_runtime_state()
	var flags := spec.flags
	bup_limit = spec.limit
	feed_density = spec.feed_density
	bloom_density = float(blob.world.get("bloom_density", spec.bloom_density))
	upkeep_factor = spec.upkeep
	stationary_phase = ((flags >> GpuLayout.DPF_STATIONARY) & 1) == 1
	death_husks = ((flags >> GpuLayout.DPF_DEATH_HUSKS) & 1) == 1
	plankton_husks = ((flags >> GpuLayout.DPF_PLANKTON_HUSKS) & 1) == 1
	nutrients_placed = int(blob.host.get("nutrients_placed", 0))
	row = _world().thaw(blob)
	time = _world().latest().sim_time
	var saved_history := DishHistory.read(blob.host.get("history", {}))
	if saved_history.is_empty():
		history.begin(time)
	else:
		history.load(saved_history, time)
	for id: int in blob.host.get("watched", PackedInt64Array()):  # (the store pins them for this dish as it merges the blob's lineage)
		if not watched.has(id):
			watched.append(id)
	watch_version += 1
	watch_epoch += 1
	_edited()
	return true


## What the host keeps with the dish in a DishBlob (DishCodec.write_blob): its history, its watch list (newest first) and the nutrient dropped in.
func host_part() -> Dictionary:
	return {"history": history.write(), "watched": PackedInt64Array(watched), "nutrients_placed": nutrients_placed}


## The dish leaves the world whole: the reply's value is its DishBlob, with its lineage, once the simulation has gathered it; the
## dish here is then out of the world (put `host_part` into the blob's `host`). Null when it is not in the world.
func freeze() -> SimReply:
	if row < 0:
		return null
	var reply := _world().freeze(row)
	row = -1
	return reply


## The pipette: the bups within `disc_radius` of the world point move, alive and with their ids, into a new dish like this one.
## The reply's value: {new_row, number, moved, ids, pass_ms: the retarget pass on the sim thread} (null when refused). The screen makes
## the new dish's node with `adopt`.
func pipette(world_pos: Vector2, disc_radius: float) -> SimReply:
	if row < 0:
		return null
	_edited()
	return _world().pipette(row, world_pos - global_position, disc_radius)


## Takes a dish the simulation already made (a pipette's new dish at `new_row`, numbered `new_number`) as this node's, with the settings of
## `like` (the dish it was made like).
func adopt(new_row: int, new_number: int, like: Dish) -> void:
	_leave_world()
	_reset_runtime_state()
	number = new_number
	radius = like.radius
	resolution = like.resolution
	medium_thickness = like.medium_thickness
	patch_seed = like.patch_seed
	row = new_row
	bup_limit = like.bup_limit
	feed_density = like.feed_density
	bloom_density = like.bloom_density
	upkeep_factor = like.upkeep_factor
	stationary_phase = like.stationary_phase
	death_husks = like.death_husks
	plankton_husks = like.plankton_husks
	begin_at(_world().latest().sim_time)
	_edited()


## The dish leaves the world (a trash: its pins go with it) and stays on the screen out of it until it is struck or loaded again.
func leave_world() -> void:
	_leave_world()


## The dish leaves the world for good (a trash): its pins go with it.
func _leave_world() -> void:
	if row >= 0 and world != null:
		world.remove_dish(row)
	row = -1


## A dish the simulation refused (no room in the memory budget, or no free row) is in no world.
func _on_refused(refused_row: int, _why: String) -> void:
	if refused_row == row:
		row = -1


## What a new snapshot says of the dish: its state, the world's time, the history's new samples, a new copy of its world, the answers to
## its questions; `extinct` once when it has died out.
func _on_snapshot(snap: Snapshot) -> void:
	if row < 0:
		return
	time = snap.sim_time
	var ds: DishState = snap.dishes.get(row)
	if not is_mine(ds):
		return
	_state = ds
	history.take(snap.history.get(row, []))
	var copy: DishWorldCopy = snap.worlds.get(row)
	if copy != null and copy.version != _world_version:
		_hold_world(copy)
	_answers = snap.answers.get(row, {})
	_flush_names()
	if ds.extinct and not _extinct_signalled:
		_extinct_signalled = true
		extinct.emit()


## The newest copy of the dish's world, kept to be unpacked when its sources or plankton are read: a dish that nothing reads (one out of view,
## or one whose layers are hidden) does not pay for thousands of plankton every snapshot. `edit_count` tells screens that it came.
func _hold_world(copy: DishWorldCopy) -> void:
	_world_version = copy.version
	_pending_world = copy
	_sources_pending = true
	_plankton_pending = true
	edit_count += 1


## Unpacks the sources of the newest copy of the dish's world, each kept as the same object while it lasts (so what is picked stays picked).
func _take_sources() -> void:
	if not _sources_pending:
		return
	_sources_pending = false
	var copy := _pending_world
	if not _plankton_pending:
		_pending_world = null
	_world_time = copy.time
	var by_id := {}
	var list: Array[NutrientSource] = []
	for s: Dictionary in copy.sources:
		var at: Vector2 = global_position + (s["pos"] as Vector2)
		var source: NutrientSource = _sources_by_id.get(s["id"])
		if source == null:
			source = NutrientSource.new(at, s["rate"])
			if _source_to_select.is_finite() and (s["pos"] as Vector2).distance_to(_source_to_select) <= SOURCE_HERE:
				_source_to_select = Vector2.INF
				selected.bup = -1
				selected.source = source
		source.pos = at
		source.rate = s["rate"]
		source.emitted = s.get("emitted", 0.0)
		by_id[s["id"]] = source
		list.append(source)
	for id: int in _sources_by_id:
		if not by_id.has(id):
			selected.forget(_sources_by_id[id])
			hovered.forget(_sources_by_id[id])
	_sources_by_id = by_id
	_sources_list = list


## Unpacks the plankton of the newest copy of the dish's world, each kept as the same object while it floats (so what is picked stays picked).
func _take_plankton() -> void:
	if not _plankton_pending:
		return
	_plankton_pending = false
	var copy := _pending_world
	if not _sources_pending:
		_pending_world = null
	var by_id := {}
	var floating: Array[Plankton] = []
	for p: Dictionary in copy.plankton:
		var id: int = p["id"]
		var cell: Plankton = _plankton_by_id.get(id)
		if cell == null:
			cell = Plankton.new(p["pos"], p["born_at"], p["burst_at"], p["units"], p["shape"])
			cell.id = id
		by_id[id] = cell
		floating.append(cell)
	for picked: Plankton in [selected.plankton, hovered.plankton]:  # (only a picked one needs letting go: nothing else holds on to one)
		if picked != null and by_id.get(picked.id) != picked:
			selected.forget(picked)
			hovered.forget(picked)
	_plankton_by_id = by_id
	_plankton_list = floating


## The questions the screen needs answered, sent when they change: the shares a goal watches, the selected and hovered bups' records
## (and the steering at each), the medium at the probed point, and the husks where the select tool looks and where the picked ones lie.
func _ask() -> void:
	if row < 0:
		return
	var tracked: Array = []
	for id in [selected.bup, hovered.bup, pointed_bup]:
		if id >= 0 and not tracked.has(id):
			tracked.append(id)
	var husks: Array = []
	if has_husks():
		if _husk_point.is_finite():
			husks.append([_husk_point.x, _husk_point.y, _husk_reach])
		for place: Vector2 in [selected.husk, hovered.husk]:
			if place != NO_HUSK and not husks.has([place.x, place.y, HUSK_HERE]):
				husks.append([place.x, place.y, HUSK_HERE])
	for place: Vector2 in _husks_seen.keys():
		if place != selected.husk and place != hovered.husk:
			_husks_seen.erase(place)
	var pinned: Array = []  ## the ones the screen holds (not the one the pointer passes over): their places in the bups' picture are looked up whenever one is made, and a picture is made that has them
	for id in [selected.bup, pointed_bup]:
		if id >= 0 and not pinned.has(id):
			pinned.append(id)
	var q := {"fractions": _fractions.duplicate(), "tracked": tracked, "pinned": pinned, "probes": [[_probe.x, _probe.y, PROBE_SPEED, PROBE_SENSE]] if _probe.is_finite() else [], "husks": husks}
	if q != _asked:
		_asked = q
		_world().ask(row, q)


func _flush_names() -> void:
	var store := lineage_store()
	if store == null:
		return
	if _pending_names.is_empty():
		return
	for id: int in _pending_names.keys():
		if store.has_record(id):
			store.set_custom_name(id, _pending_names[id])
			_pending_names.erase(id)


## A dish that joins a world already under way begins at the world's time, and its history begins then too.
func begin_at(world_time: float) -> void:
	time = world_time
	history.begin(world_time)


## Changes the dish's size about its centre, with everything in it (SimCore.resize: larger, the bups, the nutrient and the sources stay;
## smaller, what is past the new edge goes, the bups there dying like any other death). The feed and the bloom are densities.
func resize_to(new_radius: float) -> void:
	new_radius = clampf(new_radius, StartConditions.MIN_DISH_RADIUS, StartConditions.MAX_DISH_RADIUS)
	if is_equal_approx(new_radius, radius) or row < 0:
		return
	if _resizes.is_empty():
		_resize_agreed = radius
	_resizes.append([_world().resize(row, new_radius), new_radius])
	radius = new_radius
	_edited()
	queue_redraw()


## The answers to the resizes asked (`resize_to`), in the order asked: the size the world agreed to last is the dish's once all have
## answered (a resize the memory budget refused leaves the world's dish as it was, so this one goes back too).
func _take_resizes() -> void:
	var answered := false
	while not _resizes.is_empty() and (_resizes[0][0] as SimReply).is_done():
		var asked: Array = _resizes.pop_front()
		if (asked[0] as SimReply).error() == "":
			_resize_agreed = asked[1]
		answered = true
	if answered and _resizes.is_empty() and not is_equal_approx(radius, _resize_agreed):
		radius = _resize_agreed
		_edited()
		queue_redraw()


## Changes how many bups the dish holds, without ever going below how many there are now, and not above low-memory mode's most (a dish that
## already holds more keeps what it has).
func change_limit(value: int) -> void:
	bup_limit = maxi(mini(value, MemoryMode.max_bup_limit(bup_limit)), population())


## Moves the dish. Bups and plankton are held relative to the dish centre, so only the sources (global) shift.
func recenter(new_position: Vector2) -> void:
	var shift := new_position - position
	for source in sources:
		source.pos += shift
	position = new_position


## The default limit for a dish of this radius. It grows with the radius, so a bigger dish keeps a
## comparable crowd per length of rim; a limit is also a cap on how much work the simulation does.
static func cap_for(dish_radius: float) -> int:
	return maxi(MAX_CELLS, int(dish_radius))


## The nutrient the feed adds every second, as a concentration, for a feed of `density` units to each mm² every hour.
static func feed_per_second(density: float) -> float:
	return density * CONCENTRATION_PER_DENSITY / 3600.0


# --- The bups --------------------------------------------------------------------------------

## What the newest snapshot says of the dish (null until one has it): taken from each snapshot while in view, looked up while parked.
func _now() -> DishState:
	if _parked and world != null and row >= 0:
		var ds: DishState = world.latest().dishes.get(row)
		if is_mine(ds):
			_state = ds
	return _state


## Whether `ds`, the world's state of this dish's row, is of this dish: its number and the epoch of the dish the row was last given to
## (WorldClient.epoch_of) are the dish's. A state made before the dish was added is of the dish that held the row before, whatever its number.
func is_mine(ds: DishState) -> bool:
	return ds != null and ds.number == _number() and world != null and ds.epoch == world.epoch_of(row)


## How many bups the newest snapshot counts in the dish.
func population() -> int:
	var ds := _now()
	return ds.count if ds != null else 0


## Whether `id` is alive in this dish (its family record is alive and its home is this dish).
func has_bup(id: int) -> bool:
	if id < 0:
		return false
	var store := lineage_store()
	if store == null:
		return false
	var info: Dictionary = store.info(id)
	return not info.is_empty() and info["alive"] and int(info.get("home", _number())) == _number()


## The ids of the bups alive in this dish, from the family tree.
func bup_ids() -> PackedInt64Array:
	var out := PackedInt64Array()
	var store := lineage_store()
	if store == null:
		return out
	for id: int in store.alive_ids():
		if int((store.info(id) as Dictionary).get("home", _number())) == _number():
			out.append(id)
	return out


## Everything about a living bup the dish asks after (the selected and the hovered: see `_ask`), from its record in the newest answer
## (RecordCodec.info_from_record): its position is relative to the dish centre. Empty for a bup not asked after, or until it is answered.
func bup_info(id: int) -> Dictionary:
	var tracked: Dictionary = _answers.get("tracked", {})
	if id < 0 or not tracked.has(id):
		return {}
	var record: PackedByteArray = (tracked[id] as PackedByteArray).duplicate()
	record.resize(GpuLayout.RECORD_BYTES)  # (the answer leaves out the chemotaxis memory, which the panel does not read)
	if _constants.is_empty():
		_constants = SimConstants.build()
	var store := lineage_store()
	var family: Dictionary = store.info(id) if store != null else {}
	var steer: Vector3 = (_answers.get("steer", {}) as Dictionary).get(id, Vector3(0.0, 0.0, 0.5))
	return RecordCodec.info_from_record(record, 0, _constants, int(family.get("born", 0)), steer.z, upkeep_factor)


## The bup's position in the world, like the sources'.
func bup_world_pos(id: int) -> Vector2:
	return global_position + _bup_pos(id)


## Whether the bup's place is known, so it can be drawn round.
func _bup_shown(id: int) -> bool:
	return drawing.ring_of(id) != null


## Whether the bup's place is known (the picture's, or an answer's: a bup asked after), so `bup_world_pos` is where it is.
func bup_place_known(id: int) -> bool:
	return _bup_shown(id) or not bup_info(id).is_empty()


## The bup's position in the dish (relative to its centre): where the picture has it, else its newest answer's place.
func _bup_pos(id: int) -> Vector2:
	var at: Variant = drawing.ring_of(id)
	if at != null:
		return Vector2(at.x, at.y)
	return bup_info(id).get("pos", Vector2.ZERO)


## Half the length the bup is drawn at.
func _bup_radius(id: int, _pixel_um: float) -> float:
	var at: Variant = drawing.ring_of(id)
	return at.z if at != null else 0.0


## Which way the bup's drift tends where it is and how surely (the newest answer's steering: x, y the way, z the chance).
func bup_steering(id: int) -> Vector3:
	return (_answers.get("steer", {}) as Dictionary).get(id, Vector3(0.0, 0.0, 0.5))


## The nutrient at a point of the dish: the concentration, and the gradient's x and y. The point is asked after from now on; the
## answer is the newest for the point asked before (a frame or two behind).
func nutrient_reading(local: Vector2) -> Vector3:
	if not _probe.is_finite() or _probe.distance_to(local) > PROBE_MOVE:
		_probe = local
	var p: Variant = _answers.get("probes")
	if not (p is PackedFloat32Array and p.size() >= GpuLayout.PROBE_FLOATS):
		return Vector3.ZERO
	return Vector3(p[3], p[0] * p[4], p[1] * p[4])  # (the probe gives the way up as a unit vector, and the gradient's size)


## What a bup is called: the name the player gave it, or else its size word and its number ("lil bup #578",
## 578 being its id). Empty if there is no such bup. This is the only way to get a bup's name.
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
	var info := lineage_info(id)
	if info.is_empty():
		return {}
	var custom := bup_custom_name(id)
	return {
		"name": custom if custom != "" else BupNames.default_name(info["size_gene"], id),
		"info": info,
	}


## The name a bup has without one from the player (for showing as a hint while renaming).
func bup_default_name(id: int) -> String:
	var store := lineage_store()
	var info: Dictionary = store.info(id) if store != null and id >= 0 else {}
	return "" if info.is_empty() else BupNames.default_name(info["size_gene"], id)


## The name the player gave the bup, or "" if it has none (it still has its number).
func bup_custom_name(id: int) -> String:
	if _pending_names.has(id):
		return _pending_names[id]
	var store := lineage_store()
	return store.custom_name(id) if store != null and id >= 0 else ""


## Names a bup. An empty name takes the name away. The name goes when its record does.
func rename_bup(id: int, text: String) -> void:
	var store := lineage_store()
	if store != null and store.has_record(id):
		store.set_custom_name(id, BupNames.clean(text))
	else:
		_pending_names[id] = BupNames.clean(text)  # (a founder's record comes with the dish's first snapshot)


## Everything known about a bup, alive or dead (LineageStore.info; empty once its record is dropped), with a living bup's present figures
## when the dish asks after it. A bup whose home is another dish now (a pipette took it there) says so in "moved_to".
func lineage_info(id: int) -> Dictionary:
	var store := lineage_store()
	if store == null or id < 0:
		return {}
	var info: Dictionary = store.info(id)
	if info.is_empty():
		return {}
	if info["alive"]:
		info.merge(bup_info(id), true)
	var home := int(info.get("home", _number()))
	if home != _number():
		info["moved_to"] = home
	return info


## The family line that led to a bup: its oldest known ancestor first, the bup itself last.
func lineage_chain(id: int) -> PackedInt64Array:
	var store := lineage_store()
	return store.chain(id) if store != null and id >= 0 else PackedInt64Array()


func has_record(id: int) -> bool:
	var since := Time.get_ticks_usec()
	var store := lineage_store()
	var has: bool = id >= 0 and store != null and store.has_record(id)
	FrameRecord.note_look(since)
	return has


## For each id of `chain`, how many living bups of this dish have it in their line.
func living_descendants_of(chain: PackedInt64Array) -> PackedInt32Array:
	var store := lineage_store()
	if store == null:
		var none := PackedInt32Array()
		none.resize(chain.size())
		return none
	return store.living_descendants_of(chain, _number())


## Asks for a bup's record (and its ancestors') to be kept after it dies, until it is unpinned: a pin held by this dish's number.
## False when there was no record to pin (the store may have dropped it since `has_record` answered: the worker prunes a dead bup's record
## whenever nothing holds it).
func pin_bup(id: int) -> bool:
	var store := lineage_store()
	return store != null and id >= 0 and store.pin(id, _number())


func unpin_bup(id: int) -> void:
	var store := lineage_store()
	if store != null and id >= 0:
		store.unpin(id, _number())


func is_watched(id: int) -> bool:
	return watched.has(id)


## Adds a bup, alive or dead, to the watch list, and keeps its record and its ancestors' until it is taken off. False if
## it has no record, is already there, or the list is full.
func watch_bup(id: int) -> bool:
	if not has_record(id) or watched.has(id) or watched.size() >= MAX_WATCHED:
		return false
	if not pin_bup(id):
		return false
	watched.push_front(id)
	watch_version += 1
	watch_epoch += 1
	return true


func unwatch_bup(id: int) -> void:
	if watched.has(id):
		watched.erase(id)
		unpin_bup(id)  # (that may drop its record, if nothing else needs it now)
		watch_version += 1
		watch_epoch += 1


## The count and averages the readouts show (DishState.STATS_KEYS: each gene, "harm", "mutations", and "generation", the population's: the
## mean of its bups' divisions), as the newest snapshot has them.
func population_stats() -> Dictionary:
	var ds := _now()
	if ds != null and not ds.stats.is_empty():
		return ds.stats
	var none := {}
	for k: String in DishState.STATS_KEYS:
		none[k] = 0 if k == "count" else 0.0
	return none


## The share of the dish's bups whose `gene` is at least `threshold`, as the newest answer has it (asked from now on).
func fraction_with_gene_at_least(gene: String, threshold: float) -> float:
	var name := "%s>=%s" % [gene, threshold]
	if not _fractions.has(name):
		if _fractions.size() >= GpuKernels.FRACTIONS:
			_fractions.clear()  # (asked for something else now: the old pairs go)
		_fractions[name] = [gene, threshold]
	var ds := _now()
	return float(ds.fractions.get(name, 0.0)) if ds != null else 0.0


## The id of the bup under a world position, or -1 (the picture's pick, DishDrawing.pick: the answer to the same question asked a few
## frames before; -1 too until that answer comes). `slack` widens the target (e.g. for small bups).
func cell_at(world_pos: Vector2, slack: float = 0.0, hover := false) -> int:
	return maxi(drawing.pick(world_pos - global_position, slack, hover), -1)


## The distance to the nearest bup (-1 if there is none) and how many lie within SOURCE_NEARBY of the hovered point (the picture's).
func _nearest_and_count(_local: Vector2, _near: float) -> Vector2:
	return drawing.near_count()


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
## picking empty ground selects nothing, which is how a selection is let go. A click takes what the hover found where it rests (in a crowd
## that moves, a fresh pick would often be another bup); where the hover has no answer yet, the point is hovered, and the click takes what
## that finds once the picture answers (`_process`), unless the pointer has moved on.
func select_at(world_pos: Vector2, slack: float = 0.0) -> void:
	_click_at = Vector2.INF
	if not _hover_is_at(world_pos):
		hover_at(world_pos, slack)
	if _hover_waiting:
		_click_at = world_pos
		return
	selected.set_to(hovered)


## Whether a click waits for the picture to answer what is under it (`select_at`): until it does, the hover stays on the click's point.
func click_pending() -> bool:
	return _click_at.is_finite()


## Whether the hover was answered at (nearly) this point (what it found may be nothing).
func _hover_is_at(world_pos: Vector2) -> bool:
	return _hover_known and _hover_pos.distance_to(world_pos) <= HOVER_CLICK_PIXELS * pixel()


## What is under the pointer at `world_pos`. Until the picture answers whether a bup is there, nothing is outlined, and the dish asks again
## each frame (`_process`).
func hover_at(world_pos: Vector2, slack: float = 0.0) -> void:
	_hover_pos = world_pos
	_hover_slack = slack
	var picked := _pick(world_pos, slack, true)
	_hover_waiting = picked == null
	_hover_known = picked != null
	hovered.set_to(picked if picked != null else DishPick.new())


## What is under a world position, of the kinds the pick mode looks at: only the first of a source, a bup, a plankton and a husk
## (in that order) that is there, the others being none. Null while the picture has not answered whether a bup is there.
func _pick(world_pos: Vector2, slack: float, hover := false) -> DishPick:
	var source: NutrientSource = source_at(world_pos, slack) if looks_at_sources() else null
	var bup := drawing.pick(world_pos - global_position, slack, hover) if source == null and looks_at_bups() else -1
	if bup == DishDrawing.UNKNOWN:
		return null
	var floating: Plankton = plankton_at(world_pos, slack) if source == null and bup < 0 and looks_at_plankton() else null
	var husk := husk_at(world_pos, slack) if source == null and bup < 0 and floating == null and looks_at_husks() else NO_HUSK
	var picked := DishPick.new()
	picked.source = source
	picked.bup = bup
	picked.plankton = floating
	picked.husk = husk
	return picked


## Whether a bup, a source, a plankton or a husk is selected.
func has_selection() -> bool:
	return not selected.is_empty()


## Lets go of everything selected.
func clear_selection() -> void:
	selected.clear()


func looks_at_sources() -> bool:
	return layer_shown(Layer.SOURCES) and (pick_mode == PickMode.ALL or pick_mode == PickMode.SOURCES)


func looks_at_plankton() -> bool:
	return layer_shown(Layer.PLANKTON) and (pick_mode == PickMode.ALL or pick_mode == PickMode.PLANKTON)


## Whether the dish can have husks at all: a dead bup or a dying plankton leaves one only with its switch on.
func has_husks() -> bool:
	return death_husks or plankton_husks


## How many husks lie in the dish, as the newest snapshot counts them.
func husk_count() -> int:
	var ds := _now()
	return ds.husk_count if ds != null else 0


func looks_at_husks() -> bool:
	return layer_shown(Layer.HUSKS) and (pick_mode == PickMode.ALL or pick_mode == PickMode.HUSKS) and husk_count() > 0


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
			if not shown:
				hovered.bup = -1
		Layer.SOURCES:
			if not shown:
				hovered.source = null
		Layer.PLANKTON:
			if not shown:
				hovered.plankton = null
		Layer.HUSKS:
			if not shown:
				hovered.husk = NO_HUSK
	drawing.layer_changed(layer, shown)


## Whether the readout of the medium under the pointer is wanted: when looking at everything (where nothing else is
## under the pointer) or at the background alone.
func looks_at_medium() -> bool:
	return pick_mode == PickMode.ALL or pick_mode == PickMode.BACKGROUND


## Shows the placement preview at a world position.
func set_place_preview(pos: Vector2, preview_radius: float, kind := Preview.BRUSH) -> void:
	place_preview_pos = pos
	place_preview_radius = preview_radius
	place_preview_kind = kind


func clear_place_preview() -> void:
	place_preview_radius = -1.0
	place_preview_kind = Preview.BRUSH


## Whether a world position is inside the dish.
func contains(world: Vector2) -> bool:
	return world.distance_to(global_position) <= radius


func clear_hover() -> void:
	hovered.clear()
	_hover_waiting = false
	_hover_known = false
	_husk_point = Vector2.INF
	place_preview_kind = Preview.BRUSH


## The id a source has in the dish's world (-1: none known).
func _source_id(source: NutrientSource) -> int:
	_take_sources()
	for id: int in _sources_by_id:
		if _sources_by_id[id] == source:
			return id
	return -1


## Takes a source away (from the next copy of the dish's world on; it goes from the picture at once).
func remove_source(source: NutrientSource) -> void:
	var id := _source_id(source)
	if id >= 0 and row >= 0:
		var e := WorldEdit.new()
		e.kind = WorldEdit.Kind.REMOVE_SOURCE
		e.id = id
		_world().edit_world(row, e)
		_sources_by_id.erase(id)
	sources.erase(source)
	edit_count += 1
	selected.forget(source)
	hovered.forget(source)


## Sets a source's rate (nutrients a minute, within MIN_SOURCE_RATE and MAX_SOURCE_RATE).
func set_source_rate(source: NutrientSource, rate: float) -> void:
	source.rate = clampf(rate, MIN_SOURCE_RATE, MAX_SOURCE_RATE)
	var id := _source_id(source)
	if id >= 0 and row >= 0:
		var e := WorldEdit.new()
		e.kind = WorldEdit.Kind.SET_SOURCE_RATE
		e.id = id
		e.amount = source.rate
		_world().edit_world(row, e)


## Whether nutrient (a dose or a source) can be put at a world point: inside the dish, and in a cell of its grid whose centre is inside
## the rim (DishGrid.accepts: the thin band at the rim has no cell to hold it).
func can_place_at(world_pos: Vector2) -> bool:
	var local := world_pos - global_position
	if local.length() > radius:
		return false
	var n := DishGrid.cells_across(radius, resolution)
	var spacing := 2.0 * radius / n
	var cell := Vector2(clampi(int((local.x + radius) / spacing), 0, n - 1), clampi(int((local.y + radius) / spacing), 0, n - 1))
	return ((cell + Vector2(0.5, 0.5)) * spacing - Vector2(radius, radius)).length() <= radius


## Adds a feeder inside the dish (it shows from the next copy of the dish's world on). Returns false when the dish can't take another, or
## the spot can't hold one (too close to the rim).
func place_source(world_pos: Vector2, rate: float, select := false) -> bool:
	if sources.size() >= MAX_SOURCES or not can_place_at(world_pos) or row < 0:
		return false
	var e := WorldEdit.new()
	e.kind = WorldEdit.Kind.PLACE_SOURCE
	e.position = world_pos - global_position
	e.amount = clampf(rate, MIN_SOURCE_RATE, MAX_SOURCE_RATE)
	_world().edit_world(row, e)
	edit_count += 1
	if select:
		_source_to_select = e.position
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


## The husk under a world position (within its drawn size, plus `slack`): its place in the dish, or NO_HUSK. The place is asked after
## from now on (the nearest live husk within reach); the answer is the newest the simulation gave of any husk
## asked after (a frame or two behind), the nearest of them within reach of the point.
func husk_at(world_pos: Vector2, slack: float = 0.0) -> Vector2:
	var local := world_pos - global_position
	var reach := husk_draw_size() * 0.5 + slack
	if not _husk_point.is_finite() or _husk_point.distance_to(local) > PROBE_MOVE or not is_equal_approx(reach, _husk_reach):
		_husk_point = local
		_husk_reach = reach
	var best := NO_HUSK
	var best_d2 := reach * reach
	for a: Dictionary in _answers.get("husks", []):
		var found: PackedFloat32Array = a["found"]
		if found.size() < 5:
			continue
		var at := Vector2(found[0], found[1])
		var d2 := at.distance_squared_to(local)
		if d2 <= best_d2:
			best = at
			best_d2 = d2
			_husks_seen[at] = found
	return best


## What there is to know about the husk at a place in the dish (empty once it has leaked away): how long it has lain, the nutrient it
## still holds, where it is, and what is near. From the newest answer about it; until the place is answered, from what the answer that
## found it said.
func husk_details(local: Vector2) -> Dictionary:
	var found := PackedFloat32Array()
	var gone := false
	for a: Dictionary in _answers.get("husks", []):
		var f: PackedFloat32Array = a["found"]
		if f.size() >= 5 and Vector2(f[0], f[1]).distance_to(local) <= HUSK_HERE:
			found = f
			break
		if f.is_empty() and (a["at"] as Vector2).distance_to(local) <= HUSK_HERE:
			gone = true  # (asked after exactly there, and none was found: it has leaked away)
	if found.is_empty() and not gone:
		found = _husks_seen.get(local, PackedFloat32Array())
	if found.is_empty():
		_husks_seen.erase(local)
		return {}
	_husks_seen[local] = found
	var details := _spot_details(local)
	var left := exp(-0.25 * found[4])  # (what is left after the pieces already let go: see husk_share in gpu/kernels_husks.gd)
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
		"concentration": nutrient_reading(local).x,
		"nearest_bup": near.x,
		"nearby": int(near.y),
	}


## Puts a plankton in the dish (it shows from the next copy of the dish's world on). False when the dish holds as many as it can, or the
## spot can't take one.
func place_plankton(world_pos: Vector2) -> bool:
	if plankton.size() >= MAX_PLANKTON or not can_place_at(world_pos) or row < 0:
		return false
	var e := WorldEdit.new()
	e.kind = WorldEdit.Kind.PLACE_PLANKTON
	e.position = world_pos - global_position
	_world().edit_world(row, e)
	edit_count += 1
	return true


## Puts in the plankton a bloom of this density keeps floating (what arrives in the time one floats, on average), at
## random places: the dish as it looks once the bloom has been going a while. For a preview, which does not run.
func add_steady_state_plankton() -> void:
	var wanted := mini(int(round(bloom_per_day() * PLANKTON_MEAN_LIFE / 86400.0)), MAX_PLANKTON - plankton.size())
	for i in wanted:
		var at := Vector2.from_angle(_rng.randf() * TAU) * ((radius - PLANKTON_DRAW_RADIUS) * sqrt(_rng.randf()))
		place_plankton(global_position + at)


## How many plankton the bloom adds in a sim-day: its density over the dish's area.
func bloom_per_day() -> float:
	return bloom_density * PI * pow(radius / StartConditions.UM_PER_MM, 2)


## What there is to know about a source: its rate and what it has released so far, where it lies, the concentration at it, and how many
## bups are close by. What it has released is the newest copy of the dish's world's, and its rate's worth for each second since.
func source_details(source: NutrientSource) -> Dictionary:
	var details := _spot_details(source.pos - global_position)
	details["rate"] = source.rate
	details["emitted"] = source.emitted + source.rate / 60.0 * maxf(time - _world_time, 0.0)
	return details


## What there is to know about the medium at a world point: how much nutrient is there, which
## way it rises, and how far the nearest source and bup are.
func nutrient_at(world_pos: Vector2) -> Dictionary:
	var local := world_pos - global_position
	var reading := nutrient_reading(local)  # the concentration and its slope together
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


## Drops `count` units of nutrient into the medium at a world point, spread over a small disc when there are several (`scatter_radius`:
## the circle the tool's preview shows; WorldEdit.DROP). Returns false when the point is outside the dish.
func drop_nutrients(world_pos: Vector2, count: int) -> bool:
	if not can_place_at(world_pos) or count <= 0 or row < 0:
		return false
	_world().edit_world(row, WorldEdit.drop(world_pos - global_position, count * NUTRIENT_ENERGY, scatter_radius(count)))
	edit_count += 1
	nutrients_placed += count
	return true


## The eraser: takes most of the nutrient out of a disc of the medium, a little less towards its edge. Returns how many units were
## removed: not known here (the simulation erases on its own thread), so 0.
func erase_nutrient(world_pos: Vector2, brush_radius: float) -> float:
	edit_count += 1
	if row >= 0:
		_world().edit_world(row, WorldEdit.erase(world_pos - global_position, brush_radius, ERASE_STRENGTH))
	return 0.0


# --- Drawing ---------------------------------------------------------------------------------
# DishDrawing draws; the sizes here are the ones picking shares with it.

func plankton_draw_radius() -> float:
	return maxf(PLANKTON_DRAW_RADIUS, PLANKTON_MIN_PIXELS * pixel())


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


## A hand edit was made (what `edit_count` counts), and the picture is out of date.
func _edited() -> void:
	edit_count += 1
