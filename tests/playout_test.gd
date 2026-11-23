extends SceneTree
## Run: godot --headless --path . -s tests/playout_test.gd
## WorldClient's playout of the main view's pictures on its clock of simulated time (`WorldClient.Playout`), stepped with synthetic
## arrivals at frames of 1/120 s, each publish 20 s of simulated time after the one before, and `poll` over FakeSimBackend for the dish
## switch.
##
## Expected values [derived from the rule: the clock runs at the pace the publishes arrive at, trimmed to keep LEAD_SPANS arrivals' worth
## behind the newest; the picture shown is the first at or past the clock; the share is where the clock is between the picture before
## and it]. A frame's advance is how far the drawing moved, in pictures: the share's rise, or across a change of picture the rest of the
## last one and the share of the new one; a stall is a frame that does not move while running. Counted after a warm-up of 120 frames:
## - One publish every 4 frames: no stall, every advance 0.25 within 0.02, nothing skipped, the lead on the cycle's last frame 1.5
##   publishes within 0.1 (the aim just after an arrival is LEAD_SPANS and half a publish, 2.5; the cycle's four frames each move 0.25).
## - Arrivals 3, 5, 4, 5, 3, 4 frames apart (a mean of 4, the latest a quarter late): no stall, every advance within 0.5 to 1.5 times
##   the mean advance (no stop, no jump), nothing skipped.
## - Arrivals 2 and 10 frames apart in turn (a mean of 6): no stall, nothing skipped. The pace is the smoothed span over the smoothed time
##   between arrivals, 20 s in 6 frames; the mean of each arrival's own ratio would be (10 + 2) / 2 s a frame, 80% fast, and the clock
##   would catch the newest before each long gap ended. Just after an arrival the lead is 2.5 arrivals' worth (15 frames), so a 10-frame
##   gap leaves it above 0.
## - Bursts of 6 every 8 frames (an iteration's pictures, SimThread._pictures_for): no stall, a new picture on 6 frames of every 8 on
##   average (all are shown), nothing skipped.
## - 12 publishes at once: at most WAITING_MOST wait past the one shown; the oldest are skipped.
## - One publish every 4 frames, and once a publish 4 publishes' worth past the one before (an iteration of several steps): the clock is
##   not brought up to the lead (no snap: that arrival's own span is allowed for), no stall.
## - A publish at the same simulated time as the newest (a pass of no steps) takes its place: the frame's advance is as the frames' before.
## - Paused: the newest is shown, at a share of 1.
## - Dish switch (poll on FakeSimBackend): three publishes of dish 0 arrive together (the newest shown); after set_view to dish 1 the
##   next frame shows nothing new; a snapshot then carrying a late publish of dish 0 and one of dish 1 shows dish 1's.

const DT := 1.0 / 120.0
const SPAN := 20.0
const WARM := 120


func _initialize() -> void:
	_steady()
	_jitter()
	_uneven()
	_bursts()
	_big_arrival()
	_overflow()
	_same_time()
	_paused()
	_dish_switch()
	TestUtil.finish(self, "PLAYOUT TEST OK")


## `pattern` (publishes arriving each frame) repeated `times`: {stalls, advances (after WARM), skipped, changes (new pictures after WARM),
## frames (after WARM), lead (pictures, the last frame)}.
static func _played(pattern: Array, times: int, same_at := -1) -> Dictionary:
	var pl := WorldClient.Playout.new()
	var seq := 0
	var out := {"stalls": 0, "advances": [], "changes": 0, "frames": 0}
	var last: PayloadInfo = null
	var last_share := 1.0
	var frame := 0
	for t in times:
		for n: int in pattern:
			var arrived: Array = []
			for k in n:
				seq += 1
				arrived.append(_publish(seq, SPAN * seq))
			if frame == same_at:
				arrived.append(_publish(seq + 1000, SPAN * seq))
			pl.step(arrived, DT, false)
			if frame == WARM - 1:
				out["skipped_warm"] = pl.skipped
			if frame >= WARM:
				out["frames"] += 1
				var advance := pl.share - last_share
				if pl.shown != last:
					advance = (1.0 - last_share) + pl.share + float(pl.shown.sim_time - last.sim_time) / SPAN - 1.0
					out["changes"] += 1
				if absf(advance) < 1e-6:
					out["stalls"] += 1
				out["advances"].append(advance)
			last = pl.shown
			last_share = pl.share
			frame += 1
	out["skipped"] = pl.skipped - int(out.get("skipped_warm", 0))
	out["lead"] = ((pl.queue[-1] as PayloadInfo).sim_time - pl.clock) / SPAN
	out["playout"] = pl
	return out


static func _mean(a: Array) -> float:
	var s := 0.0
	for v: float in a:
		s += v
	return s / maxf(a.size(), 1)


func _steady() -> void:
	var r := _played([1, 0, 0, 0], 100)
	var off := (r["advances"] as Array).filter(func(v: float) -> bool: return absf(v - 0.25) > 0.02).size()
	TestUtil.check(r["stalls"] == 0 and off == 0 and r["skipped"] == 0 and absf(r["lead"] - 1.5) < 0.1, "one every 4 frames: no stall (%d), every advance 0.25 (%d off), none skipped (%d), lead %.2f publishes" % [r["stalls"], off, r["skipped"], r["lead"]])


func _jitter() -> void:
	var r := _played([1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0], 40)
	var m := _mean(r["advances"])
	var off := (r["advances"] as Array).filter(func(v: float) -> bool: return v < 0.5 * m or v > 1.5 * m).size()
	TestUtil.check(r["stalls"] == 0 and off == 0 and r["skipped"] == 0, "arrivals 3-5 frames apart: no stall (%d), every advance within half to one and a half times the mean %.3f (%d off), none skipped (%d)" % [r["stalls"], m, off, r["skipped"]])


func _uneven() -> void:
	var r := _played([1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0], 40)
	TestUtil.check(r["stalls"] == 0 and r["skipped"] == 0, "arrivals 2 and 10 frames apart: no stall (%d), none skipped (%d)" % [r["stalls"], r["skipped"]])


func _bursts() -> void:
	var r := _played([6, 0, 0, 0, 0, 0, 0, 0], 60)
	TestUtil.check(r["stalls"] == 0 and r["skipped"] == 0 and absf(float(r["changes"]) / r["frames"] - 0.75) < 0.03, "bursts of 6 every 8 frames: no stall (%d), none skipped (%d), new pictures on %.3f of the frames (want 0.75)" % [r["stalls"], r["skipped"], float(r["changes"]) / r["frames"]])


func _big_arrival() -> void:
	var pl := WorldClient.Playout.new()
	var t := 0.0
	var stalls := 0
	var last := -1.0
	for f in 400:
		var arrived: Array = []
		if f % 4 == 0:
			t += SPAN * (4.0 if f == 300 else 1.0)
			arrived.append(_publish(f + 1, t))
		pl.step(arrived, DT, false)
		if f >= WARM and pl.clock == last:
			stalls += 1
		last = pl.clock
	TestUtil.check(pl.snaps == 0 and stalls == 0, "an arrival of 4 publishes' worth: no snap (%d), no stall (%d)" % [pl.snaps, stalls])


func _overflow() -> void:
	var pl := WorldClient.Playout.new()
	pl.step([_publish(1, SPAN)], DT, false)
	pl.step([_publish(2, 2 * SPAN)], DT * 4, false)
	var many: Array = []
	for s in 12:
		many.append(_publish(3 + s, (3 + s) * SPAN))
	pl.step(many, DT, false)
	TestUtil.check(pl.queue.size() <= WorldClient.WAITING_MOST + 1 and pl.skipped > 0, "12 at once: %d kept (at most %d), %d skipped" % [pl.queue.size(), WorldClient.WAITING_MOST + 1, pl.skipped])


func _same_time() -> void:
	var r := _played([1, 0, 0, 0], 100, 302)
	var off := (r["advances"] as Array).filter(func(v: float) -> bool: return absf(v - 0.25) > 0.02).size()
	var pl: WorldClient.Playout = r["playout"]
	TestUtil.check(off == 0 and r["stalls"] == 0 and pl.skipped == 0, "a publish at the newest's simulated time takes its place: every advance 0.25 (%d off), no stall (%d)" % [off, r["stalls"]])


func _paused() -> void:
	var pl := WorldClient.Playout.new()
	pl.step([_publish(1, SPAN)], DT, false)
	pl.step([_publish(2, 2 * SPAN), _publish(3, 3 * SPAN)], DT, true)
	TestUtil.check(pl.shown.seq == 3 and pl.share == 1.0, "paused: the newest shown (%d) at a share of 1 (%.2f)" % [pl.shown.seq, pl.share])


func _dish_switch() -> void:
	var fake := FakeSimBackend.new()
	var w := WorldClient.new(fake)
	w.set_view(0, ViewRequest.new())
	var snap := Snapshot.new()
	snap.seq = 1
	for s in [1, 2, 3]:
		snap.payloads.append(_publish(s, s * SPAN, 0))
	fake.serve(snap)
	w.poll()
	TestUtil.check(w.shown_payload() != null and w.shown_payload().seq == 3, "dish 0's burst: the newest shown (%s)" % (w.shown_payload().seq if w.shown_payload() != null else "none"))
	w.set_view(1, ViewRequest.new())
	w.poll()
	TestUtil.check(w.shown_payload().seq == 3, "after the switch to dish 1 nothing new is shown (shown %d)" % w.shown_payload().seq)
	snap = Snapshot.new()
	snap.seq = 2
	snap.payloads.append(_publish(4, 4 * SPAN, 0))
	snap.payloads.append(_publish(5, 5 * SPAN, 1))
	fake.serve(snap)
	w.poll()
	TestUtil.check(w.shown_payload().seq == 5, "a late publish of dish 0 is dropped, dish 1's shown (shown %d)" % w.shown_payload().seq)


static func _publish(seq: int, t: float, row := -1) -> PayloadInfo:
	var p := PayloadInfo.new()
	p.seq = seq
	p.row = row
	p.sim_time = t
	return p
