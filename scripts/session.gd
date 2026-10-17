class_name Session
extends RefCounted
## State handed between scenes (menu, intro, free-mode setup, game).

enum Mode { GOALS, FREE }

static var mode := Mode.GOALS
static var load_requested := false
## Starting conditions for free mode: the last ones the player started with (loaded from
## disk), or the defaults if free mode has never been started.
static var free_start := StartConditions.load_saved()
