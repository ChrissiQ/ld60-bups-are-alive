class_name Session
extends RefCounted
## State handed between scenes (menu, intro, free-mode setup, game).

enum Mode { GOALS, FREE }

static var mode := Mode.GOALS
static var load_requested := false
## The game screen shows the tutorial when it opens (set by whatever starts the game; the screen takes it, so it runs once).
static var tutorial_wanted := false
## Starting conditions for free mode: the last ones the player started with (loaded from
## disk), or the defaults if free mode has never been started.
static var free_start := StartConditions.load_saved()
