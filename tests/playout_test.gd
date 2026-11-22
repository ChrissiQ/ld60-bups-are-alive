extends SceneTree
## Run: godot --headless --path . -s tests/playout_test.gd
## WorldClient's playout of the main view's pictures (`playout`, `next_gap`, and `poll` over FakeSimBackend), on synthetic arrivals
## (publishes per frame, the gap between arrivals smoothed as `poll` does).
##
## Expected values [derived from the rule: a frame with arrivals shows the oldest waiting at once and sets the rate for the rest to the
## waiting over gap - 1 frames, at least one a frame while that is under two; a frame without shows the oldest once a picture's worth has
## built up; at most WAITING_MOST wait, the oldest of more are skipped]:
## - One publish a frame with jitter (gaps of 1-3 frames, so the rate is at least one a frame): [1, 1, 0, 2] x 25 (an iteration ending
##   just after a poll every fourth frame): showing the newest changes the picture in 75 of 100 frames; the playout misses only the first
##   empty frame (nothing was waiting yet): 99. [1, 0, 1, 1, 2] x 20: the newest 80, the playout 99. [1, 1, 0, 1] x 25 (a publish truly
##   missing every fourth frame): 75 either way. [2, 2, 0, 0] x 25: the newest 50; the two waiting cover both empty frames: 100.
## - Bursts of 6 every 8 frames x 30 (an iteration's pictures, SimThread._pictures_for): every one of the 180 is shown, none skipped,
##   never an older one; once the gap is learnt (the last 10 bursts) 6 of every 8 frames show a new picture (the rate 5 / 7: shown on
##   frames 0, 2, 3, 5, 6, 7 of each burst) and no picture stays up more than 2 frames. The newest-only picture would change on 1 frame in 8.
## - Bursts of 6 every 9 frames x 30: all 180 shown, none held more than 2 frames in the last 10 bursts (rate 5 / 8).
## - Bursts of 4 every 3 frames (more than the frames can show): the playout never shows more than one a frame and never waits more than
##   WAITING_MOST; the oldest are skipped.
## - [3] at once: the oldest is shown, two wait; WAITING_MOST + 2 at once: the second is shown, the oldest skipped, WAITING_MOST wait.
## - Dish switch (poll on FakeSimBackend): three publishes of dish 0 arrive together (the first shown, two waiting); after set_view to dish
##   1 the next frame shows nothing new (the waiting are dropped); a snapshot then carrying a late publish of dish 0 and one of dish 1
##   shows dish 1's, and the next frames nothing new.
## - The share between pictures (`expected_up`, `shown_share`): a picture's expected frames up are the frames until the playout shows the
##   next (the pace's owed reaching one: ceil((1 - owed) / rate)) or, with none waiting, until the next arrival is due (the gap less the
##   frames since the last). Where arrivals are regular that is exact once the gap is learnt: in the last 10 repeats every picture of
##   bursts of 6 every 8 frames and of one every 4 frames stays up the frames expected (within 0.05: the smoothed gap is then within 0.001
##   of the true one), so the share runs 0, 1/n, ... (n - 1)/n and
##   the next picture starts at 0 where the last would have reached 1. Through `poll` on FakeSimBackend with one publish every 4 frames,
##   the shares of the last 4 frames are 0, 0.25, 0.5, 0.75 once the gap has settled (it reaches 4 within 0.01 after 20 arrivals, as it
##   moves a quarter of the way a gap); paused (set_time), the share is 1.


func _initialize() -> void:
	_jitter()
	_bursts()
	_at_once()
	_dish_switch()
	_share()
	TestUtil.finish(self, "PLAYOUT TEST OK")


func _jitter() -> void:
	var late := _played_out([1, 1, 0, 2], 25)
	TestUtil.check(late["newest"] == 75 and late["changes"] == 99, "late iterations [1,1,0,2]: newest 75, playout 99 of 100 (got %d, %d)" % [late["newest"], late["changes"]])
	var apart := _played_out([1, 0, 1, 1, 2], 20)
	TestUtil.check(apart["newest"] == 80 and apart["changes"] == 99, "[1,0,1,1,2]: newest 80, playout 99 of 100 (got %d, %d)" % [apart["newest"], apart["changes"]])
	var gaps := _played_out([1, 1, 0, 1], 25)
	TestUtil.check(gaps["newest"] == 75 and gaps["changes"] == 75, "missing publishes [1,1,0,1]: 75 of 100 either way (got %d, %d)" % [gaps["newest"], gaps["changes"]])
	var pairs := _played_out([2, 2, 0, 0], 25)
	TestUtil.check(pairs["newest"] == 50 and pairs["changes"] == 100, "two doubles then two empty frames [2,2,0,0]: newest 50, playout 100 of 100 (got %d, %d)" % [pairs["newest"], pairs["changes"]])
	for r: Dictionary in [late, apart, gaps, pairs]:
		TestUtil.check(r["back"] == 0 and r["skipped"] == 0, "one a frame: never an older publish, none skipped (got %s)" % [r])


func _bursts() -> void:
	var eight := _played_out([6, 0, 0, 0, 0, 0, 0, 0], 30, 10)
	TestUtil.check(eight["shown"] == 180 and eight["skipped"] == 0 and eight["back"] == 0, "bursts of 6 every 8 frames: all 180 shown, none skipped, never older (got %s)" % [eight])
	TestUtil.check(eight["tail_changes"] == 60 and eight["tail_hold"] == 2, "bursts of 6 every 8 frames, the last 10: 60 of 80 frames new, held at most 2 (got %d, %d)" % [eight["tail_changes"], eight["tail_hold"]])
	var nine := _played_out([6, 0, 0, 0, 0, 0, 0, 0, 0], 30, 10)
	TestUtil.check(nine["shown"] == 180 and nine["skipped"] == 0 and nine["tail_hold"] <= 2, "bursts of 6 every 9 frames: all 180 shown, held at most 2 (got %s)" % [nine])
	var over := _played_out([4, 0, 0], 30)
	TestUtil.check(over["most_waiting"] <= WorldClient.WAITING_MOST and over["changes"] == 90 and over["skipped"] > 0 and over["back"] == 0, "bursts of 4 every 3 frames: one a frame, at most %d waiting, the oldest skipped (got %s)" % [WorldClient.WAITING_MOST, over])


func _at_once() -> void:
	var three := WorldClient.playout([], [_publish(1), _publish(2), _publish(3)])
	TestUtil.check(three[0] != null and (three[0] as PayloadInfo).seq == 1 and three[1].size() == 2 and (three[1][0] as PayloadInfo).seq == 2, "three at once: the oldest shown, two wait")
	var many: Array = []
	for s in WorldClient.WAITING_MOST + 2:
		many.append(_publish(s + 1))
	var over := WorldClient.playout([], many)
	TestUtil.check(over[0] != null and (over[0] as PayloadInfo).seq == 2 and over[1].size() == WorldClient.WAITING_MOST and (over[1][0] as PayloadInfo).seq == 3, "%d at once: the second shown, the oldest skipped, %d wait" % [many.size(), WorldClient.WAITING_MOST])


func _dish_switch() -> void:
	var fake := FakeSimBackend.new()
	var w := WorldClient.new(fake)
	w.set_view(0, ViewRequest.new())
	var snap := Snapshot.new()
	snap.seq = 1
	for s in [1, 2, 3]:
		snap.payloads.append(_publish(s, 0))
	fake.serve(snap)
	w.poll()
	TestUtil.check(w.shown_payload() != null and w.shown_payload().seq == 1, "dish 0's burst: the first shown")
	w.set_view(1, ViewRequest.new())
	w.poll()
	TestUtil.check(w.shown_payload().seq == 1, "after the switch to dish 1 the waiting pictures of dish 0 are dropped (shown %d)" % w.shown_payload().seq)
	snap = Snapshot.new()
	snap.seq = 2
	snap.payloads.append(_publish(4, 0))
	snap.payloads.append(_publish(5, 1))
	fake.serve(snap)
	w.poll()
	TestUtil.check(w.shown_payload().seq == 5, "a late publish of dish 0 is dropped, dish 1's shown (shown %d)" % w.shown_payload().seq)
	w.poll()
	w.poll()
	TestUtil.check(w.shown_payload().seq == 5, "and nothing else follows (shown %d)" % w.shown_payload().seq)


func _share() -> void:
	var eight := _played_out([6, 0, 0, 0, 0, 0, 0, 0], 30, 10)
	TestUtil.check(eight["tail_shown"] == 60 and eight["tail_off"] == 0, "bursts of 6 every 8 frames, the last 10: each of the 60 pictures up the frames expected (%d off)" % eight["tail_off"])
	var four := _played_out([1, 0, 0, 0], 40, 10)
	TestUtil.check(four["tail_shown"] == 10 and four["tail_off"] == 0, "one every 4 frames, the last 10: each picture up the frames expected (%d off)" % four["tail_off"])
	var fake := FakeSimBackend.new()
	var w := WorldClient.new(fake)
	w.set_view(0, ViewRequest.new())
	var shares: Array = []
	for f in 160:
		if f % 4 == 0:
			var snap := Snapshot.new()
			snap.seq = f / 4 + 1
			snap.payloads.append(_publish(f / 4 + 1, 0))
			fake.serve(snap)
		w.poll()
		shares.append(w.shown_share())
	var last: Array = shares.slice(shares.size() - 4)
	var want := [0.0, 0.25, 0.5, 0.75]
	var near := true
	for i in 4:
		near = near and absf(float(last[i]) - want[i]) < 0.01
	TestUtil.check(near, "one publish every 4 frames through poll: the last frames' shares are 0, 0.25, 0.5, 0.75 (got %s)" % [last])
	w.set_time(1.0, true, 1.0 / 60.0)
	TestUtil.check(w.shown_share() == 1.0, "paused: the share is 1 (got %f)" % w.shown_share())


static func _publish(seq: int, row := -1) -> PayloadInfo:
	var p := PayloadInfo.new()
	p.seq = seq
	p.row = row
	return p


## `pattern` (publishes arriving each frame) repeated `times`, with the gap smoothed as `WorldClient.poll` does: {newest: frames whose
## newest publish changed, changes: frames whose shown publish changed, shown: publishes shown, skipped: publishes never shown, back:
## frames that showed an older publish, most_waiting: the most left waiting, tail_changes and tail_hold: in the last `tail` repeats, the
## frames whose picture changed and the most frames one picture stayed up, tail_shown and tail_off: the pictures that came up then and
## those whose predecessor stayed up other than the frames `WorldClient.expected_up` gave it, by 0.05 frames or more}.
static func _played_out(pattern: Array, times: int, tail := 0) -> Dictionary:
	var seq := 0
	var waiting: Array = []
	var pace: Array = [0.0, 1.0]
	var gap := 1.0
	var last_arrival := -1
	var shown := -1
	var shown_at := 0
	var out := {"newest": 0, "changes": 0, "shown": 0, "skipped": 0, "back": 0, "most_waiting": 0, "tail_changes": 0, "tail_hold": 0, "tail_shown": 0, "tail_off": 0}
	var expected := 0.0
	var frame := 0
	var tail_from := (times - tail) * pattern.size()
	for t in times:
		for n: int in pattern:
			var arrived: Array = []
			for k in n:
				seq += 1
				arrived.append(_publish(seq))
			if n > 0:
				out["newest"] += 1
				if last_arrival >= 0:
					gap = WorldClient.next_gap(gap, frame - last_arrival)
				last_arrival = frame
			var step := WorldClient.playout(waiting, arrived, pace, gap)
			waiting = step[1]
			pace = step[2]
			out["most_waiting"] = maxi(out["most_waiting"], waiting.size())
			if step[0] != null:
				var s: int = (step[0] as PayloadInfo).seq
				if s < shown:
					out["back"] += 1
				if s != shown:
					out["changes"] += 1
					out["shown"] += 1
					if tail > 0 and frame >= tail_from:
						out["tail_changes"] += 1
						out["tail_hold"] = maxi(out["tail_hold"], frame - shown_at)
						out["tail_shown"] += 1
						out["tail_off"] += 0 if absf(float(frame - shown_at) - expected) < 0.05 else 1  # (the smoothed gap nears the true one a quarter of the way an arrival)
					shown_at = frame
					expected = WorldClient.expected_up(waiting, pace, gap, frame - last_arrival)
				shown = s
			frame += 1
	out["skipped"] = seq - out["shown"] - waiting.size()
	return out
