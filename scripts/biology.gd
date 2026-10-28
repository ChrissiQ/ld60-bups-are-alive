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

# --- The medium ------------------------------------------------------------------------------
const MEDIUM_THICKNESS := 25.0  ## how many times thicker than water the medium is (viscosity): nutrient diffuses that many times slower (Stokes-Einstein). Swimming is left as it is [choice]
const WATER_DIFFUSION := 600.0  ## µm^2/s, glucose in water [memory: the search could not confirm it]
const NUTRIENT_DIFFUSION := WATER_DIFFUSION / MEDIUM_THICKNESS  ## µm^2/s

# --- Body ------------------------------------------------------------------------------------
const BIRTH_LENGTH := 2.0  ## µm [search: length 2.6-4.0 µm in one compilation; 2 at birth is typical]
const WIDTH := 0.9  ## µm [search: diameter 0.68-1.04 µm]

# --- Growth and upkeep -----------------------------------------------------------------------
const DOUBLING_SECONDS := 2400.0  ## 40 min, glucose minimal medium at 37 C [search: BioNumbers]
const MAINTENANCE_SHARE := 0.05  ## maintenance as a share of the fast-growth energy budget; small in E. coli [search: Pirt-style maintenance is a small component], 5% is a choice
const MOTILITY_SHARE := 0.03  ## cost of swimming at the founders' speed, share of the same budget [search: flagella+chemotaxis ~2-10%]
const SENSING_SHARE := 0.005  ## cost of the founders' chemoreceptors, same basis [choice: chemotaxis signalling is "a lesser extent" than flagella, per the same source]
const DEATH_RELEASE := 0.25  ## share of a dead bup's body (its mass at COST_PER_MASS) that returns to the medium as nutrient the others can eat; a bup rebuilds that share, since eating has no loss of its own, so this is the net new biomass per dead one [search: new cells per dead cell, E. coli 0.12-0.23 (Biselli 2020), 0.28 (Middelboe 2003, lysate of a marine bacterium), 0.2-0.33 (Mason & Hamer 1987, per carbon released); 20-65% of lysate carbon is used within hours and 2-5% stays refractory for months (Kitayama 2007)]. The reserve is not returned. A bup displaced at the limit and one the player erases return nothing
const HUSK_SECONDS := 10800.0  ## with husks on (an advanced option), a dead bup leaks its nutrient back over this lifetime (an exponential leak: most of it in the first hours, the last of it after nine) instead of all at once [choice: Mason & Hamer 1987 saw about half of the soluble contents of lysed cells used by growing bacteria within 5 h, and the cell debris that holds the rest dissolves more slowly (their model's rate for particulates is 0.05 per hour, a lifetime of 20 h, an input rather than a measurement); 3 h is where the husk tests of 2026-10-18 matched the thick medium]
# --- Starvation (the stationary phase, an option of free mode: see Dish.stationary_phase) ---
# A starving E. coli stops growing (the stringent response), shrinks, and its viability decays exponentially: a constant death rate set by
# its maintenance and by how much of the dead cells' bodies the living recover (Schink et al. 2019; Biselli, Schink & Gerland 2020: death rates
# of 0.25-0.59 per day, maintenance of 0.16-0.81 fmol glycerol per cell per day, 12-23% of a dead cell recovered, about eight dead cells per new one).
const STARVE_MAINTENANCE := 0.08 / 86400.0  ## per second, as a share of the body's energy (its mass at COST_PER_MASS) [search: the maintenance of a starving cell is 3-14% of its body a day (derived from Biselli et al. 2020); 8% is about the middle]
const STARVE_DEATH_RATE := 0.22 / 86400.0  ## per second at a growth rate of nothing: the prefactor of the death rate of starving cells, 0.21-0.23 per day [search: Biselli et al. 2020]
const STARVE_DEATH_GROWTH_HOURS := 0.95  ## the death rate grows as exp(this x the growth rate before starvation, per hour): cells that grew faster die faster, 0.9-1.0 hours [search: Biselli et al. 2020]
const STARVE_MIN_MASS_SHARE := 0.25  ## a starving bup that has digested itself down to this share of its birth mass dies [choice: starved cells dwindle (Navarro Llorens et al. 2010, dwarfing) with no measured floor]
# --- Overflow: acetate as a second food ---
# A fast-growing E. coli lets go of acetate (threshold-linear in its growth rate: Basan et al. 2015; in MG1655 from about 0.27 per hour, 8.5% of the glucose
# carbon at 0.51 per hour: Valgepea et al. 2010) and takes it up again when glucose is short (growth on acetate alone is 0.27-0.45 per hour, 30-60% of glucose's:
# Pinhal et al. 2019; Basan et al. 2020). Acetate does not slow growth at the concentrations a dish reaches (unchanged to 8 mM, 6% lower at 10 mM, half at about
# 100 mM at neutral pH: Enjalbert et al. 2017; Millard et al. 2023; Pinhal et al. 2019), so no inhibition is modelled.
const ACETATE_THRESHOLD := 0.27  ## per hour: the growth rate (the one the bup's intake could sustain) above which a bup lets go of acetate [search: Valgepea et al. 2010, Nahku et al. 2010: onset 0.27-0.34 per hour in MG1655]
const ACETATE_SLOPE := 0.354  ## share of the food taken in that is let go as well (the bup keeps its whole gain: the yield per glucose does not fall, Valgepea et al. 2010) per (per hour) of growth rate above the threshold: 8.5% at 0.51 per hour [search: Valgepea et al. 2010, derived]
const ACETATE_UPTAKE := 0.45  ## the most a bup takes up of acetate, as a share of its glucose uptake rate [search: growth on acetate is 30-60% of that on glucose: Pinhal et al. 2019, Basan et al. 2020]
const DEATH_PER_SECOND := 1.0e-6  ## death from causes other than starvation while growing: negligible [search: Biselli 2020 ties death to starvation, not growth]

# --- Mutation (see Genome for the argument) -------------------------------------------------
const REAL_MUTATIONS_PER_DIVISION := 0.003  ## per genome [memory: Drake 1991, Lee et al. 2012]
