class_name SimClock
extends RefCounted
## How the simulation clock is shown. It counts the seconds the simulation has run,
## which is what the bups' swimming and tumbling happen in. Playback speed (x1, x3, x8) only
## changes how fast it runs against the wall clock.


## A time of birth or death, kept only to the minute: "3h 20m", or "20m" in the first hour. (Not the clock's
## h:mm:ss, which would claim seconds that aren't recorded.)
static func format_minutes(minutes: int) -> String:
	var hours := minutes / 60
	if hours > 0:
		return "%sh %dm" % [UiText.group(str(hours)), minutes % 60]
	return "%dm" % minutes


static func format(sim_seconds: float) -> String:
	var total := int(sim_seconds)
	var hours := total / 3600
	var minutes := total / 60 % 60
	var seconds := total % 60
	if hours > 0:
		return "%d:%02d:%02d" % [hours, minutes, seconds]
	return "%d:%02d" % [minutes, seconds]
