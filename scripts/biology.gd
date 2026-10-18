class_name Biology
extends RefCounted
## Every real-world number the simulation is built on, in micrometres and seconds, and where it
## comes from. The simulation clock runs in these seconds (see SimClock); the player's playback
## speed multiplies it. Nothing here is sped up for the game: when a number is a game decision it
## says "choice". Provenance tags:
##   [search]  seen in a source while building this
##   [memory]  recalled, NOT checked against a source: treat as unverified
##   choice    a game decision, not biology

# --- Swimming: E. coli in liquid ------------------------------------------------------------
const SWIM_SPEED := 20.0  ## µm/s [search: ~20 µm/s, Berg & Brown 1972 via lecture notes]
const RUN_SECONDS := 1.0  ## mean run before a tumble in a uniform medium [search]
const TUMBLE_SECONDS := 0.1  ## a tumble [search]
const TUMBLE_TURN_MEAN := 1.19  ## radians, about 68 degrees [memory]
const TUMBLE_TURN_SPREAD := 0.68  ## [memory]
const ROTATIONAL_DIFFUSION := 0.55  ## rad per sqrt(s), i.e. a rotational diffusion of 0.15 rad^2/s [memory]
const TUMBLE_UP_FACTOR := 0.15  ## tumble rate falls to this fraction while climbing, so runs are ~7x longer; strong ramps suppress tumbling by far more than 3x [memory; the stronger-model consult, citing Block 1983 tethered-cell data]
# The response to a change in concentration is biphasic: a fast positive lobe, then a negative
# one, back to baseline within ~5 s [search: Segall 1985 thesis; cells respond most to changes over
# about a run length, Block 1983 thesis]. It is modelled as a fast average (the motor's response,
# a few tenths of a second) minus a slower one (adaptation). Setting both to the lobes' full
# extents (1 s and 3 s) would make the response peak too late to steer a ~1 s run: the signal
# then reflects the previous run, and drift falls to a few percent (derivation: de Gennes 2004,
# "internal delays", and Clark & Grant 2005 on this trade-off [memory, unverified]).
const MEMORY_SHORT := 0.3  ## s
const MEMORY_LONG := 2.0  ## s
const MAX_DRIFT_FRACTION := 0.22  ## the ceiling of the coarse drift up a gradient, as a share of swim speed, fitted with Cell.DRIFT_HALF and DRIFT_NOISE so that it reproduces the run-and-tumble model (which reaches about 3 of 20 µm/s in steep gradients: noise keeps it under the ceiling). Real cells are reported to reach ~0.35 [search: ~7 of 20 µm/s, Berg & Turner 1990, secondary source], so this model's chemotaxis is still conservative; TUMBLE_UP_FACTOR is the knob.

# --- The medium ------------------------------------------------------------------------------
const NUTRIENT_DIFFUSION := 600.0  ## µm^2/s, glucose in water [memory: the search could not confirm it]

# --- Body ------------------------------------------------------------------------------------
const BIRTH_LENGTH := 2.0  ## µm [search: length 2.6-4.0 µm in one compilation; 2 at birth is typical]
const DIVISION_LENGTH := 4.0  ## µm [search]
const WIDTH := 0.9  ## µm [search: diameter 0.68-1.04 µm]

# --- Growth and upkeep -----------------------------------------------------------------------
const DOUBLING_SECONDS := 2400.0  ## 40 min, glucose minimal medium at 37 C [search: BioNumbers]
const MAINTENANCE_SHARE := 0.05  ## maintenance as a share of the fast-growth energy budget; small in E. coli [search: Pirt-style maintenance is a small component], 5% is a choice
const MOTILITY_SHARE := 0.03  ## cost of swimming at the founders' speed, share of the same budget [search: flagella+chemotaxis ~2-10%]
const SENSING_SHARE := 0.005  ## cost of the founders' chemoreceptors, same basis [choice: chemotaxis signalling is "a lesser extent" than flagella, per the same source]
const DEATH_PER_SECOND := 1.0e-6  ## death from causes other than starvation while growing: negligible [search: Biselli 2020 ties death to starvation, not growth]

# --- Mutation (see Genome for the argument) -------------------------------------------------
const REAL_MUTATIONS_PER_DIVISION := 0.003  ## per genome [memory: Drake 1991, Lee et al. 2012]
