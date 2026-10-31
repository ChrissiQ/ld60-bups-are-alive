class_name CommandQueue
extends RefCounted
## The commands from the main thread to the sim thread: many writers, one reader, in the order they were pushed. A
## mutex guards the list and a semaphore wakes the reader: a `push` (or `wake`) posts it only when no post is waiting yet, and `wait`
## takes the one post, so a reader waiting in `wait` sleeps until there is something to do and never spins, however many commands came
## while it was busy and drained them without waiting (at most one `wait` then returns with nothing new).
## The reader drains only between iterations.

var _mutex := Mutex.new()
var _items: Array[SimCommand] = []
var _semaphore := Semaphore.new()
var _posted := false  ## a post is waiting for the reader's `wait`


func push(cmd: SimCommand) -> void:
	_mutex.lock()
	_items.append(cmd)
	var post := not _posted
	_posted = true
	_mutex.unlock()
	if post:
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


## Blocks until a push or a `wake` since the last wait returned (one not yet waited for returns at once). The reader drains after it, so
## a push between the two is drained with the rest.
func wait() -> void:
	_semaphore.wait()
	_mutex.lock()
	_posted = false
	_mutex.unlock()


## Wakes a waiting reader without a command (shutdown, a pipette's grid made).
func wake() -> void:
	_mutex.lock()
	var post := not _posted
	_posted = true
	_mutex.unlock()
	if post:
		_semaphore.post()
