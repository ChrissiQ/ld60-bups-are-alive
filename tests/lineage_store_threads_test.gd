extends SceneTree
## Run: godot --headless --path . -s tests/lineage_store_threads_test.gd
## LineageStore's long operations (export_dish, release_dish, import_bytes, discard_frozen) on a tree big enough that each takes many
## slices of the store's mutex, with and without a second thread using the store all the while:
##  - a freeze, a trash of the dish holding a shared ancestor, a thaw, and a freeze and discard end in the state worked out below, the
##    export's bytes equal to the blob the tree was built from;
##  - while each operation runs, a thread pins, unpins and reads (has_record, info, chain): the end state is the same, every chain it
##    reads begins at the tree's root (a record's parent is always in the store), and it got in many times during the operations (they
##    are sliced);
##  - an export while another thread drops the dish's pin on a dead record lists exactly the records it writes, and the record goes.
## Expected values are derived in each function's comment from the rules of the store (LineageStore's header).

const RECORD_BYTES := 88
const DEPTH := 18  ## the tree: ids BASE + 1 .. BASE + 2^18 - 1, the parent of BASE + i is BASE + i / 2; the leaves (the lower half) alive
const N := (1 << DEPTH) - 1
const BASE := 1 << 33
const DIED := 7  ## the death time of every dead record of the tree
const A := 1  ## dish numbers
const C := 3
const F_DISH := 9
const C_BUPS := 1000
const ROOT := BASE + 1
const X := BASE + 2  ## a bup of the tree pipetted into dish C, alive there with children of its own
const F := 1 << 40  ## a founder of a dish nothing here releases: what the second thread pins and unpins

var store: LineageStore
var running := false
var hammer_calls := 0
var hammer_bad_chains := 0
var hammer_bad_parents := 0
var _result: Variant  ## what the last operation run by `_during` returned
var _drop_pin_of := -1  ## (_export_while_unpinned) the id the second thread unpins (holder A) once it sees it here


func _init() -> void:
	var blob := _tree_blob()
	_sequence(blob, false)
	_sequence(blob, true)
	_export_while_unpinned(blob)
	TestUtil.finish(self, "LINEAGE STORE THREADS TEST OK")


# ---- the tree ---------------------------------------------------------------------------------------------------------

## The tree as an export (see LineageStore.export_bytes): ascending ids; a record's other fields are 0; died -1 for the leaves and X.
static func _tree_blob() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4 + N * RECORD_BYTES + 4)
	b.encode_u32(0, N)
	for i in range(1, N + 1):
		var at := 4 + (i - 1) * RECORD_BYTES
		b.encode_s64(at, BASE + i)
		b.encode_s64(at + 8, BASE + i / 2 if i > 1 else 0)
		b.encode_s32(at + 20, -1 if i >= (1 << (DEPTH - 1)) or BASE + i == X else DIED)
	return b


static func _leaves() -> PackedInt64Array:
	var out := PackedInt64Array()
	for i in range(1 << (DEPTH - 1), N + 1):
		out.append(BASE + i)
	return out


static func _all_ids() -> PackedInt64Array:
	var out := PackedInt64Array()
	for i in range(1, N + 1):
		out.append(BASE + i)
	return out


## C's bups: children of X, alive in C (an export of them, as the tree's).
static func _c_blob() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4 + C_BUPS * RECORD_BYTES + 4)
	b.encode_u32(0, C_BUPS)
	for k in C_BUPS:
		var at := 4 + k * RECORD_BYTES
		b.encode_s64(at, _c_id(k))
		b.encode_s64(at + 8, X)
		b.encode_s32(at + 20, -1)
	return b


static func _c_id(k: int) -> int:
	return (1 << 34) + k


static func _c_live() -> PackedInt64Array:
	var out := PackedInt64Array([X])
	for k in C_BUPS:
		out.append(_c_id(k))
	return out


## The store as the game would have it: dish A holds the tree (its leaves alive, a leaf pinned by A); X was pipetted into C (alive, home
## C) and has C's bups as children; F is alive in a dish of its own.
func _new_store(blob: PackedByteArray) -> LineageStore:
	var s := LineageStore.new()
	var live := _leaves()
	live.append(X)
	s.import_bytes(blob, PackedInt64Array(), live, A)
	s.retarget_ids(PackedInt64Array([X]), C)
	s.import_bytes(_c_blob(), PackedInt64Array(), _c_live().slice(1), C)
	var f := PackedByteArray()
	f.resize(4 + RECORD_BYTES + 4)
	f.encode_u32(0, 1)
	f.encode_s64(4, F)
	f.encode_s32(4 + 20, -1)
	s.import_bytes(f, PackedInt64Array(), PackedInt64Array([F]), F_DISH)
	s.pin(_leaves()[0], A)
	return s


# ---- the second thread ------------------------------------------------------------------------------------------------

## Pins and unpins F (a pin and its unpin, so that it leaves nothing behind), and reads the tree: a chain it reads is empty or begins at
## the root, and a record's parent is the one the tree gives it.
func _hammer() -> void:
	var leaves := _leaves()
	var k := 0
	while running:
		if _drop_pin_of >= 0:
			store.unpin(_drop_pin_of, A)
			_drop_pin_of = -1
		var leaf: int = leaves[(k * 7919) % leaves.size()]
		match k % 5:
			0:
				store.pin(F, F_DISH)
				store.unpin(F, F_DISH)
			1:
				store.has_record(leaf)
			2:
				var info := store.info(leaf)
				if not info.is_empty() and info["parent"] != BASE + (leaf - BASE) / 2:
					hammer_bad_parents += 1
			3:
				var chain := store.chain(leaf)
				if not chain.is_empty() and (chain[0] != ROOT or chain[-1] != leaf or chain.size() != DEPTH):
					hammer_bad_chains += 1
			4:
				store.info(F)
		hammer_calls += 1
		k += 1


## Runs `op`; with the second thread running, how many calls it made meanwhile.
func _during(op: Callable) -> int:
	var before := hammer_calls
	op.call()
	return hammer_calls - before


# ---- the sequence -----------------------------------------------------------------------------------------------------

## Expected [derived]:
##  (1) The freeze of A: the export lists every id of the tree (each is an ancestor of a leaf, X too) and nothing of C's; the tree has
##      not changed since it was imported, so the bytes are the blob's, byte for byte. The release frees every leaf (dead at 500, nothing
##      holds one: A's pin goes with A) and every dead record under them; X (alive in C) and the root (held by X) stay, with C's bups:
##      1,002 records. X is held by its 1,000 children, the root by X. A claims all N ids; nothing is tombstoned (A's claims come after).
##  (2) The trash of C at 800 frees C's bups (no claim), X (dead at 800) and the root (dead at 7); A claims both, so they leave
##      tombstones at 800 and 7. No record is left.
##  (3) The thaw of A at minute 900 inserts all N records; the leaves are alive in A; X, alive in the blob and not here, takes its
##      tombstone (800, not the thaw's 900); the root keeps 7. So the store's export is the blob with X's death 800. Each dead record
##      is held by its two children, the pinned leaf by A's pin again; no claim or tombstone is left.
##  (4) A frozen again exports those same bytes; its release frees all (X is dead, held by nothing above the leaves), leaving N claims
##      and no tombstone; the discard leaves no claim, no tombstone and no record but F.
## With the second thread, every one of these is the same: its pins on F are undone at once, and it changes nothing else.
func _sequence(blob: PackedByteArray, hammer: bool) -> void:
	var how := "with a second thread" if hammer else "alone"
	store = _new_store(blob)
	var leaves := _leaves()
	var thread := Thread.new()
	var got_in := 0
	if hammer:
		hammer_calls = 0
		hammer_bad_chains = 0
		hammer_bad_parents = 0
		running = true
		thread.start(_hammer)
		while hammer_calls == 0:
			OS.delay_usec(100)
	got_in += _during(func() -> void: _result = store.export_dish(A, leaves))
	var ex: Dictionary = _result
	TestUtil.check(ex["ids"] == _all_ids(), "(%s, 1) the export lists every id of the tree (%d)" % [how, (ex["ids"] as PackedInt64Array).size()])
	TestUtil.check(ex["bytes"] == blob, "(%s, 1) the export's bytes are the blob the tree came from" % how)
	got_in += _during(func() -> void: store.release_dish(A, leaves, 500, ex["ids"]))
	TestUtil.check(store.record_count() == 2 + C_BUPS + 1 and store.has_record(X) and store.has_record(ROOT) and not store.has_record(leaves[0]), "(%s, 1) the release leaves X, the root, C's bups and F (%d records)" % [how, store.record_count()])
	TestUtil.check(store.holds(X) == C_BUPS and store.holds(ROOT) == 1 and store.claim_count() == N + 0 and store.tombstone_count() == 0, "(%s, 1) X is held by C's bups, the root by X; N claims, no tombstone (%d, %d, %d, %d)" % [how, store.holds(X), store.holds(ROOT), store.claim_count(), store.tombstone_count()])
	got_in += _during(func() -> void: store.release_dish(C, _c_live(), 800))
	TestUtil.check(store.record_count() == 1 and store.tombstone(X) == 800 and store.tombstone(ROOT) == DIED and store.tombstone_count() == 2, "(%s, 2) the trash of C frees all of C's and leaves tombstones on X (800) and the root (7) (%d records, %d, %d)" % [how, store.record_count(), store.tombstone(X), store.tombstone(ROOT)])
	store.set_time(900 * 60.0)
	got_in += _during(func() -> void: store.import_bytes(ex["bytes"], PackedInt64Array([leaves[0]]), leaves, A))
	var want := blob.duplicate()
	want.encode_s32(4 + (X - BASE - 1) * RECORD_BYTES + 20, 800)
	var all_bytes := store.export_bytes()
	var tree_bytes := all_bytes.slice(0, 4 + N * RECORD_BYTES)
	tree_bytes.encode_u32(0, N)
	TestUtil.check(store.record_count() == N + 1 and tree_bytes == want.slice(0, 4 + N * RECORD_BYTES), "(%s, 3) the thaw brings the tree back with X dead at 800 (%d records)" % [how, store.record_count()])
	TestUtil.check(store.alive_ids().size() == leaves.size() + 1 and store.info(leaves[5])["alive"] and store.info(leaves[5])["home"] == A and not store.info(X)["alive"], "(%s, 3) the leaves are alive in A, X is not" % how)
	TestUtil.check(store.holds(ROOT) == 2 and store.holds(X) == 2 and store.holds(leaves[0]) == 1 and store.holds(leaves[1]) == 0 and store.claim_count() == 0 and store.tombstone_count() == 0, "(%s, 3) every dead record is held by its children, the leaf by its pin; no claim or tombstone" % how)
	got_in += _during(func() -> void: _result = store.export_dish(A, leaves))
	var ex2: Dictionary = _result
	TestUtil.check(ex2["bytes"] == want and ex2["ids"] == _all_ids(), "(%s, 4) the second export is the thawed tree's bytes" % how)
	got_in += _during(func() -> void: store.release_dish(A, leaves, 1000, ex2["ids"]))
	TestUtil.check(store.record_count() == 1 and store.claim_count() == N and store.tombstone_count() == 0, "(%s, 4) the second release frees the whole tree and claims it (%d records, %d claims)" % [how, store.record_count(), store.claim_count()])
	got_in += _during(func() -> void: store.discard_frozen(A))
	TestUtil.check(store.claim_count() == 0 and store.tombstone_count() == 0 and store.record_count() == 1, "(%s, 4) the discard leaves no claim, no tombstone and no record but F" % how)
	if hammer:
		running = false
		thread.wait_to_finish()
		TestUtil.check(hammer_bad_chains == 0 and hammer_bad_parents == 0, "(%s) every chain the second thread read began at the root and every parent was the tree's (%d, %d bad)" % [how, hammer_bad_chains, hammer_bad_parents])
		TestUtil.check(store.holds(F) == 0, "(%s) F is unpinned once the second thread stops" % how)
		# (held whole, the operations would let it in a call or two each; sliced, it gets in at every boundary)
		TestUtil.check(got_in >= 1000, "(%s) the second thread got in during the long operations (%d calls)" % [how, got_in])


## An export while the second thread drops the dish's pin on a dead record D (a child of the root that nothing else holds). Expected
## [derived]: whether the unpin comes before the export reads the dish's pins (D is not listed) or after (D is listed: the export holds
## it until it has written it), the ids are exactly the records in the bytes, every id of the tree is among them, and D is gone once
## both are done; the root is held by its two children only.
func _export_while_unpinned(blob: PackedByteArray) -> void:
	store = _new_store(blob)
	var d := BASE + N + 1
	var one := PackedByteArray()
	one.resize(4 + RECORD_BYTES + 4)
	one.encode_u32(0, 1)
	one.encode_s64(4, d)
	one.encode_s64(4 + 8, ROOT)
	one.encode_s32(4 + 20, DIED)
	store.import_bytes(one, PackedInt64Array([d]), PackedInt64Array(), A)
	TestUtil.check(store.has_record(d) and store.holds(d) == 1 and store.holds(ROOT) == 3, "(unpin) D is held by A's pin alone")
	running = true
	hammer_calls = 0
	var thread := Thread.new()
	thread.start(_hammer)
	while hammer_calls == 0:
		OS.delay_usec(100)
	_drop_pin_of = d
	var ex := store.export_dish(A, _leaves())
	while _drop_pin_of >= 0:
		OS.delay_usec(100)
	running = false
	thread.wait_to_finish()
	var ids: PackedInt64Array = ex["ids"]
	var bytes: PackedByteArray = ex["bytes"]
	var written := PackedInt64Array()
	for i in bytes.decode_u32(0):
		written.append(bytes.decode_s64(4 + i * RECORD_BYTES))
	TestUtil.check(ids == written and (ids.size() == N or ids.size() == N + 1) and ids.slice(0, N) == _all_ids(), "(unpin) the ids are the records written: the tree, with D or not (%d)" % ids.size())
	TestUtil.check(not store.has_record(d) and store.holds(ROOT) == 2, "(unpin) D is gone and the root is held by its children")
