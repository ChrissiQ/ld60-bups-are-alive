class_name PlayHolds
extends RefCounted
## The reasons the game is held that Space does not lift: the pipette's timer, the question about the old dish, the tour, the end of the
## game. Each is a named hold: it pauses the game, may lock the toolbar so that only the screen resumes play (`locked`), and remembers
## whether the game was already paused when it began, which is what `release` can give back. The toolbar's `resume_locked` is written here
## and nowhere else.

## What `release` leaves the game as.
enum Then {
	STAY,  ## paused, as it is
	RESTORE,  ## as it was when the hold began (unless another hold still holds it)
	RESUME,  ## playing
}

var _toolbar: Toolbar
var _held := {}  ## name -> {"locked": bool, "was_paused": bool}


func _init(toolbar: Toolbar) -> void:
	_toolbar = toolbar


func has(name: StringName) -> bool:
	return _held.has(name)


## Pauses the game for `name` (nothing changes if it already holds).
func hold(name: StringName, locked := true) -> void:
	if _held.has(name):
		return
	_held[name] = {"locked": locked, "was_paused": _toolbar.is_paused()}
	_sync_lock()
	_toolbar.set_paused(true)


## Lifts `name`'s hold (nothing changes if it does not hold).
func release(name: StringName, then := Then.RESTORE) -> void:
	if not _held.has(name):
		return
	var was_paused: bool = _held[name]["was_paused"]
	_held.erase(name)
	_sync_lock()
	match then:
		Then.RESTORE:
			if _held.is_empty():
				_toolbar.set_paused(was_paused)
		Then.RESUME:
			_toolbar.set_paused(false)


## Pauses the game again if something holds it and the player has resumed (a hold that does not lock, as the tour's).
func enforce() -> void:
	if not _held.is_empty() and not _toolbar.is_paused():
		_toolbar.set_paused(true)


func _sync_lock() -> void:
	var locked := false
	for entry: Dictionary in _held.values():
		locked = locked or entry["locked"]
	_toolbar.resume_locked = locked
