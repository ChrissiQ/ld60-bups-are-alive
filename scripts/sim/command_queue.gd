class_name CommandQueue
extends RefCounted
## The commands from the main thread to the sim thread: many writers, one reader, in the order they were pushed. A
## mutex guards the list and a semaphore wakes the reader: every `push` (and `wake`) posts it, so a reader waiting in `wait` sleeps
## until there is something to do and never spins. The reader drains only between iterations.

var _mutex := Mutex.new()
var _items: Array[SimCommand] = []
var _semaphore := Semaphore.new()


func push(cmd: SimCommand) -> void:
	_mutex.lock()
	_items.append(cmd)
	_mutex.unlock()
	_semaphore.post()


## Everything pushed so far, oldest first; the queue is empty afterwards.
func drain() -> Array[SimCommand]:
	_mutex.lock()
	var out := _items
	_items = []
	_mutex.unlock()
	return out


func size() -> int:
	_mutex.lock()
	var n := _items.size()
	_mutex.unlock()
	return n


## Blocks until a push or a `wake` since the last wait returned (a post not yet waited for returns at once).
func wait() -> void:
	_semaphore.wait()


## Wakes a waiting reader without a command (shutdown).
func wake() -> void:
	_semaphore.post()
