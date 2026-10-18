class_name Cell
extends RefCounted
## What a bup is, as numbers and formulas. The living bups themselves are in the native simulation
## (native/src/bup_sim.cpp), which reads every constant here through scripts/sim_constants.gd.
##
## A bup takes nutrient into an energy reserve, grows exponentially as fast as its metabolism and
## reserve allow, and divides once it has added a fixed amount of mass since birth (the "adder":
## Campos 2014, Taheri-Araghi 2015). It finds food by chemotaxis on the concentration it senses
## (Berg & Brown 1972). Motion has two forms of one model: at slow playback it really runs and
## tumbles, once a second or so; at fast playback a step spans many runs, so it moves as what a
## run-and-tumble walker averages to: a random walk with the same effective diffusion, plus a drift
## up the gradient (the drift-diffusion limit, the standard coarse-graining of run and tumble).
## Everything runs in real time and real micrometres (see Biology for each number's source).

const MASS_UM := 0.25  ## µm of body length per unit of mass: newborn (mass 8) 2 µm, dividing (16) 4 µm
const REFERENCE_MASS := 12.0  ## a typical mass, which the energy budget below is expressed at
const REFERENCE_SIZE := 4.0  ## the founders' size (sqrt of mass) at division, where the sense gene is exact
const REFERENCE_SENSE := 50.0
const ADD_MASS_FACTOR := 0.5  ## a bup adds this times its size gene squared before dividing
# A bup is drawn at its true size, unless that would be too small to see: each bup on its own is then drawn at
# the least that shows. (The simulation does it as it builds the picture; see BupSim.drawn_length.)
const MIN_VISIBLE_LENGTH_PX := 2.0  ## no bup is drawn shorter than this many screen pixels ...
const MIN_VISIBLE_WIDTH_PX := 1.0  ## ... or thinner than this

# Energy is in arbitrary units, fixed by this: building one unit of mass costs COST_PER_MASS.
const COST_PER_MASS := 4.0
const GROWTH_RATE := 0.6931471805599453 / Biology.DOUBLING_SECONDS  ## per second at metabolism 1
const FAST_BUDGET := COST_PER_MASS * GROWTH_RATE * REFERENCE_MASS  ## energy per second of a bup growing flat out
const RESERVE_PER_MASS := 8.0  ## how much energy a body can store; surplus intake is lost
const MAINTENANCE_FLOOR := 5.0  ## growth never spends the reserve below this
const BASE_UPKEEP := 0.5 * Biology.MAINTENANCE_SHARE * FAST_BUDGET
const MAINTENANCE_PER_MASS := 0.5 * Biology.MAINTENANCE_SHARE * FAST_BUDGET / REFERENCE_MASS
const DRAG_UPKEEP := Biology.MOTILITY_SHARE * FAST_BUDGET / (Biology.SWIM_SPEED * Biology.SWIM_SPEED * 3.464)  ## swimming costs speed squared, and drag grows with size (3.464 = sqrt(REFERENCE_MASS))
const SENSE_UPKEEP := Biology.SENSING_SHARE * FAST_BUDGET / REFERENCE_SENSE
const UPTAKE_PER_SIZE := 1.5 * FAST_BUDGET / 3.464  ## at saturating concentration, metabolism 1
const HALF_SATURATION := 0.002  ## concentration (energy per µm^2) at which uptake is half its maximum (Monod); real Ks is far below the concentrations a culture grows in [memory: micromolar vs millimolar]

const DETECTION_FLOOR := HALF_SATURATION / 20.0  ## concentrations below this make no impression: receptors sense from far below the half-saturation of uptake
# Receptors count molecules, so there is a limit to how well a bup can tell that the concentration
# is changing (Berg & Purcell 1977; Mora & Wingreen 2010): the error in its estimate of the
# change falls with the square root of the concentration and with the receptor array, which
# grows with the sense gene. A bup with poor senses cannot resolve a shallow gradient.
const GRADIENT_NOISE := 0.1  ## error of the estimated change at the reference concentration and range
const NOISE_REFERENCE_CONC := HALF_SATURATION  ## where receptors are about half occupied, so the estimate is at its best

# Chemotaxis, after Berg & Brown (1972) and Segall, Block & Berg (1986): it tumbles about once a
# second; swimming up a gradient makes runs longer, and swimming down one does not shorten them.
const TUMBLE_BASE := 1.0 / Biology.RUN_SECONDS
const CHEMOTAXIS_GAIN := 8.0  ## how strongly an improving signal suppresses tumbling (receptor gain is very high in life [memory])
# The coarse drift is fitted to the real run-and-tumble model, not derived: drift speed measured
# for keen (sense 50) and dull (sense 10) bups at gradients of 0.25%, 0.5%, 1% and 2% per µm, in a dish wide enough
# that no wall is in reach (a wall cuts the drift short, so a fit made in a small dish comes out too low), then
# a ceiling, half-saturation and noise scale found that reproduce all eight to within about 0.3 µm/s.
const DRIFT_HALF := 0.035  ## the signal change at which the coarse drift is half its maximum
const DRIFT_NOISE := 0.39  ## how much of the estimate error survives averaging over a step's many runs
const MEAN_COS_TURN := 0.29  ## average cosine of a tumble's turn: exp(-spread^2 / 2) * cos(mean)
const SIGNAL_COS := 0.64  ## average of the heading's cosine against the gradient, over a run
## How much of the steady-state response a swimmer actually gets, given that its heading
## decorrelates (rate PERSISTENCE_RATE) while the response kernel is still building. The
## response is K(t) = exp(-t/long) - exp(-t/short) and the heading correlation exp(-rate*t), so the
## efficiency is the integral of K times the correlation, over the integral of K (de Gennes 2004).
const PERSISTENCE_RATE := TUMBLE_BASE * (1.0 - MEAN_COS_TURN) + Biology.ROTATIONAL_DIFFUSION * Biology.ROTATIONAL_DIFFUSION / 2.0
const MEMORY_EFFICIENCY := (1.0 / (1.0 / Biology.MEMORY_LONG + PERSISTENCE_RATE) - 1.0 / (1.0 / Biology.MEMORY_SHORT + PERSISTENCE_RATE)) / (Biology.MEMORY_LONG - Biology.MEMORY_SHORT)


## The mass a bup of this genome adds before dividing.
static func mass_to_add(genome: Dictionary) -> float:
	var r: float = genome["size"]
	return ADD_MASS_FACTOR * r * r


## The size word in a bup's default name, going by the size its genome grows to. Only BupNames uses this:
## to show a bup's name, ask the dish (`Dish.bup_name`).
static func title_for(size_gene: float) -> String:
	return Strings.t("bups.small") if size_gene < 3.5 else (Strings.t("bups.large") if size_gene > 5.5 else Strings.t("bups.medium"))
