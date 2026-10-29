class_name GpuQuestions
extends RefCounted
## What the dish asks about the GPU's bups every frame, and the last answers: the bup under a point (a pick), the nearest bup to a point
## and how many lie near it, the share of bups whose gene is at least a threshold, and the records of the bups it shows (tracked). Each
## ask is sent again for a few frames after it was last made; `questions()` gives the set to send with a request (a Dictionary of plain
## values, so that a later ask cannot change one already sent), `qin()` its QIN words, and `take_out()` reads the answers from the OUT
## that comes back (GpuLayout's QO_* words). GpuWorld holds one and answers the dish's getters from it; no device is used here.

const SAME_POINT_PIXELS := 2.0  ## an answer about a point serves a question about another this many pixels away
const HOVER_POINT_PIXELS := 6.0  ## a hover takes the answer for a point this many pixels away: the pointer moves on while the answer comes back a few frames later
const QUESTION_FRAMES := 2  ## a pick or nearest question is sent again for this many frames after it was last asked
const TRACK_FRAMES := 10  ## a tracked bup not asked for in this many frames is dropped
const FRACTION_FRAMES := 60  ## a fraction not asked for in this many frames is no longer asked


## A pick asked: the point, the slack, µm per pixel, the frame it was asked in.
class PickAsk:
	var at: Vector2
	var slack: float
	var pixel_um: float
	var frame: int

	func _init(point: Vector2, slack_um: float, um_per_pixel: float, asked_frame: int) -> void:
		at = point
		slack = slack_um
		pixel_um = um_per_pixel
		frame = asked_frame


## The answer to a pick: the point and slack it was asked with, and the bup found (-1: none).
class PickAnswer:
	var at: Vector2
	var slack: float
	var id: int

	func _init(point: Vector2, slack_um: float, found: int) -> void:
		at = point
		slack = slack_um
		id = found


## A nearest point asked (`frame`: when it was last asked), or answered (`value`: the distance to the nearest bup, -1 if none, and how
## many lie within `near`).
class Near:
	var at: Vector2
	var near: float
	var frame: int
	var value: Vector2

	func _init(point: Vector2, near_um: float, asked_frame := 0, answer := Vector2.ZERO) -> void:
		at = point
		near = near_um
		frame = asked_frame
		value = answer


var _pick: PickAsk = null
var _pick_answer: PickAnswer = null
var _pixel_um := 1.0
var _near: Array[Near] = []  ## the points asked lately (up to NEAR_SLOTS)
var _near_answers: Array[Near] = []
var _fractions := {}  ## [gene index, threshold] -> frame asked
var _fraction_answers := {}
var _tracked := {}  ## id -> frame asked
var _records := {}  ## id -> its last record (RECORD_BYTES)
var _gone := {}  ## id -> the last record of a tracked bup the GPU no longer has (it died): its place, until its death reaches the records
var _sent := {}  ## the questions sent with the last request


## The bup under a point of the dish (BupSim.pick_bup's rule): asks for it and returns the last answer for a point within 2 pixels of
## this one (with the same slack), else -1. A `hover` (the pointer is moving, the answer is a few frames old) is answered from a point
## `HOVER_POINT_PIXELS` away and whatever slack it was asked with (the slack changes with every step of a zoom); a click is exact.
func ask_pick(local: Vector2, slack: float, pixel_um: float, hover: bool, frame: int) -> int:
	_pick = PickAsk.new(local, slack, pixel_um, frame)
	_pixel_um = pixel_um
	if _pick_answer == null or (not hover and _pick_answer.slack != slack):
		return -1
	if _pick_answer.at.distance_to(local) > (HOVER_POINT_PIXELS if hover else SAME_POINT_PIXELS) * pixel_um:
		return -1
	return _pick_answer.id


## BupSim.nearest_and_count: asks for it (up to NEAR_SLOTS points) and returns the last answer for a point within 2 pixels of this one
## with the same `near`, else the last answer with the same `near`, else (-1, 0).
func ask_nearest(local: Vector2, near: float, frame: int) -> Vector2:
	var found := false
	for asked: Near in _near:
		if asked.near == near and asked.at.distance_to(local) <= SAME_POINT_PIXELS * _pixel_um:
			asked.at = local
			asked.frame = frame
			found = true
			break
	if not found:
		_near.append(Near.new(local, near, frame))
		if _near.size() > GpuLayout.NEAR_SLOTS:
			_near.pop_front()
	var fallback := Vector2(-1.0, 0.0)
	for answer: Near in _near_answers:
		if answer.near != near:
			continue
		if answer.at.distance_to(local) <= SAME_POINT_PIXELS * _pixel_um:
			return answer.value
		fallback = answer.value
	return fallback


## The share of bups whose `gene` is at least `threshold`: asks for it (up to FRACTIONS pairs, the least recently asked dropped) and
## returns the last answer, 0.0 until there is one.
func ask_fraction(gene: String, threshold: float, frame: int) -> float:
	var g := GpuLayout.GENE_NAMES.find(gene)
	if g < 0:
		return 0.0
	var key := [g, threshold]
	_fractions[key] = frame
	_keep_newest(_fractions, GpuLayout.FRACTIONS)
	return _fraction_answers.get(key, 0.0)


## Keeps this bup's record coming back (up to TRACKED, the least recently asked dropped).
func ask_track(id: int, frame: int) -> void:
	if id < 0:
		return
	_tracked[id] = frame
	_keep_newest(_tracked, GpuLayout.TRACKED)


## The last record of a tracked (or picked) bup that is alive; empty if none is known.
func record_of(id: int) -> PackedByteArray:
	return _records.get(id, PackedByteArray())


## The last record known of a bup, alive or died since; empty if none is known.
func last_record(id: int) -> PackedByteArray:
	return _records.get(id, _gone.get(id, PackedByteArray()))


## Whether a record is known for this bup (it is tracked or was picked and its record has come back, or it died since).
func knows(id: int) -> bool:
	return _records.has(id) or _gone.has(id)


## The questions to send now: the pick asked lately, the nearest points, the fractions, the tracked ids (each still asked within its
## few frames; a tracked id past them is dropped, with its record unless it is the picked bup's).
func questions(frame: int) -> Dictionary:
	var q := {"pick": [], "near": [], "fractions": [], "tracked": []}
	if _pick != null and frame - _pick.frame <= QUESTION_FRAMES:
		q["pick"] = [_pick.at, _pick.slack, _pick.pixel_um]
	for asked: Near in _near:
		if frame - asked.frame <= QUESTION_FRAMES:
			q["near"].append([asked.at, asked.near])
	for key: Array in _fractions:
		if frame - int(_fractions[key]) <= FRACTION_FRAMES:
			q["fractions"].append(key)
	for id: int in _tracked.keys():
		if frame - int(_tracked[id]) <= TRACK_FRAMES:
			q["tracked"].append(id)
		else:
			_tracked.erase(id)
			_gone.erase(id)
			if _pick_answer == null or _pick_answer.id != id:
				_records.erase(id)
	return q


## Whether `q` differs from the questions last sent.
func differ_from_sent(q: Dictionary) -> bool:
	return q != _sent


## Notes `q` as sent.
func mark_sent(q: Dictionary) -> void:
	_sent = q


## Drops every answer (a new state was loaded: they were about the old one); what is asked stays asked.
func reset() -> void:
	_records.clear()
	_gone.clear()
	_pick_answer = null
	_near_answers.clear()
	_fraction_answers.clear()
	_sent = {}


## QIN's words for the questions `q` (GpuLayout's Q_* words).
static func qin(q: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(GpuLayout.QIN_WORDS * 4)
	if not q["pick"].is_empty():
		var at: Vector2 = q["pick"][0]
		b.encode_u32(GpuLayout.Q_PICK * 4, 1)
		b.encode_float(GpuLayout.Q_PICK_X * 4, at.x)
		b.encode_float(GpuLayout.Q_PICK_Y * 4, at.y)
		b.encode_float(GpuLayout.Q_SLACK * 4, q["pick"][1])
		b.encode_float(GpuLayout.Q_PIXEL * 4, q["pick"][2])
	var near: Array = q["near"]
	b.encode_u32(GpuLayout.Q_NEAR * 4, near.size())
	for s in near.size():
		var w := (GpuLayout.Q_NEAR_FIRST + 3 * s) * 4
		b.encode_float(w, near[s][0].x)
		b.encode_float(w + 4, near[s][0].y)
		b.encode_float(w + 8, near[s][1])
	var fractions: Array = q["fractions"]
	b.encode_u32(GpuLayout.Q_FRAC * 4, fractions.size())
	for f in fractions.size():
		var w := (GpuLayout.Q_FRAC_FIRST + 2 * f) * 4
		b.encode_u32(w, fractions[f][0])
		b.encode_u32(w + 4, _float_at_least(fractions[f][1]))
	var tracked: Array = q["tracked"]
	b.encode_u32(GpuLayout.Q_TRACK * 4, tracked.size())
	for t in tracked.size():
		var w := (GpuLayout.Q_TRACK_FIRST + 2 * t) * 4
		b.encode_u32(w, tracked[t] & 0xFFFFFFFF)
		b.encode_u32(w + 4, (tracked[t] >> 32) & 0xFFFFFFFF)
	return b


## The answers in an OUT to the questions `q` sent with it, `count` the bups it counted.
func take_out(data: PackedByteArray, q: Dictionary, count: int) -> void:
	var o := GpuLayout.OUT_Q * 4
	if not q["pick"].is_empty():
		var index := data.decode_u32(o + GpuLayout.QO_INDEX * 4)
		var id := -1
		if index != 0xFFFFFFFF:
			var at := o + GpuLayout.QO_RECORD * 4
			var record := GpuLayout.whole_record(data.slice(at, at + GpuLayout.ANSWER_BYTES))
			id = GpuLayout.id_of(record, 0)
			_records[id] = record
		_pick_answer = PickAnswer.new(q["pick"][0], q["pick"][1], id)
	var near: Array = q["near"]
	for s in near.size():
		var w := o + (GpuLayout.QO_NEAR if s == 0 else GpuLayout.QO_NEAR_MORE + 2 * (s - 1)) * 4
		var bits := data.decode_u32(w)
		var value := Vector2(-1.0 if bits == 0xFFFFFFFF else sqrt(data.decode_float(w)), float(data.decode_u32(w + 4)))
		var key_local: Vector2 = near[s][0]
		var key_near: float = near[s][1]
		for k in range(_near_answers.size() - 1, -1, -1):
			if _near_answers[k].near == key_near and _near_answers[k].at.distance_to(key_local) <= SAME_POINT_PIXELS * _pixel_um:
				_near_answers.remove_at(k)
		_near_answers.append(Near.new(key_local, key_near, 0, value))
		if _near_answers.size() > 2 * GpuLayout.NEAR_SLOTS:
			_near_answers.pop_front()
	var fractions: Array = q["fractions"]
	for f in fractions.size():
		_fraction_answers[fractions[f]] = float(data.decode_u32(o + (GpuLayout.QO_FRAC + f) * 4)) / count if count > 0 else 0.0
	var tracked: Array = q["tracked"]
	for t in tracked.size():
		var w := o + (GpuLayout.QO_TRACKED + GpuLayout.ANSWER_WORDS * t) * 4
		var id: int = tracked[t]
		if data.decode_u32(w + GpuLayout.R_ID_LO * 4) == 0xFFFFFFFF and data.decode_u32(w + GpuLayout.R_ID_HI * 4) == 0xFFFFFFFF:
			if _records.has(id):
				_gone[id] = _records[id]  # (not found: no longer alive. Its place is kept: its record says it lives until its death is applied, a few frames on)
			_records.erase(id)
		else:
			_records[id] = GpuLayout.whole_record(data.slice(w, w + GpuLayout.ANSWER_BYTES))


## The answers to what is asked (the fractions, the tracked bups' records, the last pick and nearest points), worked out on the CPU from
## its bups (`sim`, `records`: sim.export_state_bytes()), for a load or an export, which drop every answer still on its way. `dish_params`
## may name more to answer: "tracked" (ids) and "fractions" ([gene name, threshold] pairs) the dish shows; they are asked from now on.
func answers_from_cpu(sim: BupSim, records: PackedByteArray, dish_params: Dictionary, frame: int) -> Dictionary:
	for id: int in dish_params.get("tracked", []):
		if id >= 0:
			_tracked[id] = frame
	for pair: Array in dish_params.get("fractions", []):
		var g := GpuLayout.GENE_NAMES.find(pair[0])
		if g >= 0:
			_fractions[[g, pair[1]]] = frame
	_keep_newest(_tracked, GpuLayout.TRACKED)
	_keep_newest(_fractions, GpuLayout.FRACTIONS)
	var out := {"fractions": {}, "records": {}, "near": []}
	for key: Array in _fractions:
		out["fractions"][key] = sim.fraction_with_gene_at_least(GpuLayout.GENE_NAMES[key[0]], key[1])
	var wanted: Array = _tracked.keys()
	if _pick != null:
		var picked := sim.pick_bup(_pick.at, _pick.slack, _pick.pixel_um)
		out["pick"] = PickAnswer.new(_pick.at, _pick.slack, picked)
		wanted.append(picked)
	for asked: Near in _near:
		out["near"].append(Near.new(asked.at, asked.near, 0, sim.nearest_and_count(asked.at, asked.near)))
	if not wanted.is_empty():
		var ids := sim.bup_ids()  # (in the records' order)
		for id: int in wanted:
			var i := ids.find(id) if id >= 0 else -1
			if i >= 0 and GpuLayout.id_of(records, i) == id:
				out["records"][id] = records.slice(i * GpuLayout.RECORD_BYTES, (i + 1) * GpuLayout.RECORD_BYTES)
	return out


## Takes the answers of answers_from_cpu as the last ones known.
func take_answers(answers: Dictionary) -> void:
	_fraction_answers.merge(answers["fractions"], true)
	_records.merge(answers["records"], true)
	if answers.has("pick"):
		_pick_answer = answers["pick"]
	_near_answers.assign(answers["near"])


## Drops the least recently asked of `asked` (key -> the frame it was asked) until `most` are left.
static func _keep_newest(asked: Dictionary, most: int) -> void:
	while asked.size() > most:
		var oldest: Variant = null
		for key: Variant in asked:
			if oldest == null or asked[key] < asked[oldest]:
				oldest = key
		asked.erase(oldest)


## The bits of the least 32-bit float at or above `value`: a float gene g is >= value (a double, as the CPU compares) exactly when it
## is >= that float.
static func _float_at_least(value: float) -> int:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, value)
	var bits := b.decode_u32(0)
	if b.decode_float(0) < value:
		bits = bits + 1 if b.decode_float(0) >= 0.0 else bits - 1
	return bits
