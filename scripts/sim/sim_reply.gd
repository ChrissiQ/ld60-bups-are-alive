class_name SimReply
extends RefCounted
## What a command that answers later hands back: a flag, a value and an error, behind a mutex so the thread that completes it and the
## one that polls it never see half of it. The main thread polls `is_done` each frame; only the quit save calls `wait`.

var _mutex := Mutex.new()
var _done := false
var _value: Variant = null
var _error := ""


func is_done() -> bool:
	_mutex.lock()
	var d := _done
	_mutex.unlock()
	return d


## The value, or null before it is done (or when it failed).
func value() -> Variant:
	_mutex.lock()
	var v: Variant = _value
	_mutex.unlock()
	return v


## The failure's words, or "" (not done, or done well).
func error() -> String:
	_mutex.lock()
	var e := _error
	_mutex.unlock()
	return e


## Completes it once; a second call changes nothing.
func complete(p_value: Variant = null, p_error := "") -> void:
	_mutex.lock()
	if not _done:
		_value = p_value
		_error = p_error
		_done = true
	_mutex.unlock()


## Blocks until it is done, then gives the value. Only the quit save may call it.
func wait() -> Variant:
	while not is_done():
		OS.delay_usec(200)
	return value()
