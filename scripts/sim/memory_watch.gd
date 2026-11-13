class_name MemoryWatch
extends RefCounted
## Keeps the pool's working memory budget (`PoolLimits.memory_budget_bytes`, which the arena reads) in step with the memory the machine has
## free. The budget worked out at start (`PoolLimits.budget_for`) is the ceiling; while the game runs the machine is read again on a timer
## (`tick`, every INTERVAL_MSEC) and before a growth (`before_growth`, at most every MIN_GAP_MSEC), and the working budget follows:
##  - it falls at once when what is free no longer covers what the pool may still take (`PoolLimits.working_budget_for`);
##  - it rises again only when the figure has come back by at least RAISE_STEP of the ceiling (so a reading that flickers does not make
##    the pool grow, hit the budget and shrink again);
##  - it is never above the ceiling and never below `PoolLimits.BUDGET_FLOOR`.
## `short` says that free memory is under `PoolLimits.SHORT_FREE_SHARE` of the physical memory: the arena then gives back classes it uses
## little (`SimArena.shrink_after_msec` short) until the memory recovers. Nothing here runs per step: the sim thread calls `tick` once a loop.
## `reader` returns a `MachineMemory`; the tests give one that returns made-up machines.

const INTERVAL_MSEC := 5000
const MIN_GAP_MSEC := 1000
const RAISE_STEP := 0.1  ## of the ceiling

var _limits: WeakRef  ## the limits whose budget it sets (weak: the limits own the watch, and two counted references to each other are never freed)
var ceiling := 0  ## the budget worked out at start: the working budget's upper bound
var reader: Callable
var first: MachineMemory  ## what the machine reported when the game started
var last: MachineMemory  ## the newest reading
var short := false
var reads := 0
var lowered := 0  ## times the working budget was lowered
var raised := 0
var _next_msec := 0
var _last_read_msec := -MIN_GAP_MSEC


func _init(p_limits: PoolLimits, p_reader: Callable) -> void:
	_limits = weakref(p_limits)
	ceiling = p_limits.memory_budget_bytes
	reader = p_reader
	first = p_limits.machine if p_limits.machine != null else MachineMemory.new()
	last = first


## The timer: reads the machine when INTERVAL_MSEC has passed since the last read; `held` is the bytes the buffers hold.
func tick(now_msec: int, held: int) -> void:
	if now_msec >= _next_msec:
		_read(now_msec, held)


## A new ceiling (the memory setting changed): the working budget is worked out again at once, so a lower ceiling takes hold now and a higher one
## as far as the free memory allows.
func set_ceiling(new_ceiling: int, now_msec: int, held: int) -> void:
	ceiling = new_ceiling
	var limits: PoolLimits = _limits.get_ref()
	if limits != null and limits.memory_budget_bytes > ceiling:
		limits.memory_budget_bytes = ceiling
		lowered += 1
	_read(now_msec, held)


## Before a growth: reads again unless a read is under MIN_GAP_MSEC old.
func before_growth(now_msec: int, held: int) -> void:
	if now_msec - _last_read_msec >= MIN_GAP_MSEC:
		_read(now_msec, held)


func _read(now_msec: int, held: int) -> void:
	_last_read_msec = now_msec
	_next_msec = now_msec + INTERVAL_MSEC
	var limits: PoolLimits = _limits.get_ref()
	var m: Variant = reader.call()
	if limits == null or not (m is MachineMemory):
		return
	last = m
	reads += 1
	short = PoolLimits.is_short(last)
	var target := PoolLimits.working_budget_for(last, held, ceiling)
	var now := limits.memory_budget_bytes
	if target < now:
		limits.memory_budget_bytes = target
		lowered += 1
	elif target >= now + int(RAISE_STEP * ceiling) or (target == ceiling and now < ceiling):
		limits.memory_budget_bytes = target
		raised += 1


## For the debug log.
func report() -> Dictionary:
	var limits: PoolLimits = _limits.get_ref()
	return {"class": PoolLimits.classify(first), "at_start": first.to_dict(), "machine": last.to_dict(), "ceiling": ceiling, "working": limits.memory_budget_bytes if limits != null else 0, "short": short, "reads": reads, "lowered": lowered, "raised": raised}
