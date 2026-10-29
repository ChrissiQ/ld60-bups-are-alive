class_name LineageView
extends RefCounted
## The views the player has opened on bups, and the lineage panel's list. Each view on the stack is
## {"view": "info" or "lineage", "id": a bup}, oldest first. Escape takes the newest away; anything outside
## the stack (another selection, a tool) closes it all. Every bup on it is pinned in the simulation, so its
## record isn't dropped (even if it dies) while it is on the stack.

## A name in the lineage was clicked and its bup's info opened (the bup is selected, if it is alive).
signal info_opened

const ELSEWHERE_MSEC := 30000  ## how often the list looks again for a line's bups alive in other dishes

var dish: Dish  ## the dish in the main view
var dishes: Array[Dish] = []  ## every running dish (shared with the screen)
var numbers := {}  ## Dish -> its number (shared with the screen)
var title: Label
var entries: VBoxContainer  ## the rows of the list
var stack: Array[Dictionary] = []
var _shown := {}  ## what the list was last built from, so it is only rebuilt when that changes
var _elsewhere := {}  ## see alive_elsewhere, and when it was worked out
var _elsewhere_stamp := []


func is_empty() -> bool:
	return stack.is_empty()


func depth() -> int:
	return stack.size()


## Whether a lineage is the newest view.
func is_open() -> bool:
	return not stack.is_empty() and stack.back()["view"] == "lineage"


## Whether the lineage of the selected bup `id` is the newest view.
func is_open_on(id: int) -> bool:
	return id >= 0 and id == dish.selected.bup and is_open()


## Starts afresh with nothing pinned (the dish's simulation has been reset, so its pins are gone).
func reset() -> void:
	stack.clear()
	_shown = {}


## Forgets who was found alive in other dishes (a dish has come or gone).
func forget_elsewhere() -> void:
	_elsewhere_stamp = []


## Every step holds a pin on its bup (pins are counted, so a bup on two steps holds two). The new steps are pinned
## before the old are let go, so a bup staying on the stack is never unpinned in between.
func set_stack(new_stack: Array) -> void:
	for step in new_stack:
		dish.pin_bup(step["id"])
	for step in stack:
		dish.unpin_bup(step["id"])  # (that may drop its record, if nothing needs it now)
	stack.assign(new_stack)


func clear() -> void:
	set_stack([])


## The selection changed: one made anywhere else (a click in the dish, say) starts the stack afresh, and none closes it.
## (A change the stack itself made leaves its top as the selection, so nothing happens.)
func on_selection_changed() -> void:
	var top_id: int = stack.back()["id"] if not stack.is_empty() else -1
	if dish.selected.bup == top_id:
		return
	if dish.selected.bup >= 0:
		set_stack([{"view": "info", "id": dish.selected.bup}])
	else:
		set_stack([])


## The lineage icon: the family line of the bup on show, over its info.
func open_lineage() -> void:
	if stack.is_empty() or dish.selected.bup < 0:
		return
	set_stack(stack + [{"view": "lineage", "id": dish.selected.bup}])


## A name in a lineage was clicked: that bup's info, a step further on (and the bup is selected, if it is alive).
func open_info_of(id: int) -> void:
	if not dish.has_record(id):
		return
	set_stack(stack + [{"view": "info", "id": id}])
	dish.selected.bup = id
	info_opened.emit()


## One step back through the views opened on a bup (a lineage, or a bup reached through one).
func step_back() -> void:
	if stack.size() > 1:
		set_stack(stack.slice(0, stack.size() - 1))
		dish.selected.bup = stack.back()["id"]


## Who of a lineage is alive in the other dishes: ancestor id -> [[how many, the dish's number], ...]. Worked out when the lineage is first shown and then at most every
## ELSEWHERE_MSEC (a pass over a dish's records), and only for dishes that hold a record of someone in the line (the ones a pipette took bups into).
func alive_elsewhere(chain: PackedInt64Array) -> Dictionary:
	if dishes.size() < 2 or chain.is_empty():
		return {}
	var stamp := [chain[-1], Time.get_ticks_msec() / ELSEWHERE_MSEC]
	if _elsewhere_stamp == stamp:
		return _elsewhere
	_elsewhere_stamp = stamp
	_elsewhere = {}
	for other in dishes:
		if other == dish or not other.has_record(chain[0]):
			continue
		var counts := other.sim.living_descendants_of(chain)
		for k in chain.size():
			if counts[k] > 0:
				if not _elsewhere.has(chain[k]):
					_elsewhere[chain[k]] = []
				_elsewhere[chain[k]].append([counts[k], numbers[other]])
	return _elsewhere


## Lists the family line that led to a bup (oldest first). It is rebuilt only when the line, or who in it is
## still alive, changes.
func show(id: int) -> void:
	var chain := dish.lineage_chain(id)
	var elsewhere := alive_elsewhere(chain)
	var key := [elsewhere]
	for ancestor in chain:
		key.append([ancestor, dish.has_bup(ancestor), dish.bup_custom_name(ancestor)])  # (a name changes only by being given or taken away: the default one comes from the record, which never changes)
	if _shown.get("id") == id and _shown.get("key") == key:
		return
	_shown = {"id": id, "key": key}
	title.text = Strings.t("panel.lineage_title", [dish.bup_name(id)])
	Nodes.clear_children(entries)
	for k in chain.size():
		var ancestor: int = chain[k]
		var info := dish.lineage_info(ancestor)
		var line := Strings.t("panel.lineage_entry", [dish.bup_name(ancestor), SimClock.format_minutes(info["born"])])  # (the times on a second row, so nothing is cut off)
		if not info["alive"]:
			line += Strings.t("panel.lineage_died", [SimClock.format_minutes(info["died"])])
		for place: Array in elsewhere.get(ancestor, []):
			line += Strings.t("panel.lineage_elsewhere", [place[0], place[1]])
		var entry := Button.new()
		entry.text = line
		entry.theme_type_variation = &"ListButton"
		entry.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		entry.disabled = ancestor == id  # the bup itself: you are looking at its line
		entry.pressed.connect(open_info_of.bind(ancestor))
		entries.add_child(BupListRow.make(info, 14.0, entry))
