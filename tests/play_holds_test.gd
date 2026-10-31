extends SceneTree
## Run: godot --headless --path . -s tests/play_holds_test.gd
## PlayHolds on a real Toolbar (the free-mode game screen's), the single-dish path's behaviour. Expected values are derived from scripts/play_holds.gd.
## Holds pause the game; release restores the speed from before the hold; two holds need two releases.


func _init() -> void:
	_run()


func _run() -> void:
	SimConstants.apply()
	var chosen := TestUtil.small_start()
	chosen.bups = 10
	var m: Node = TestUtil.game_screen(self, chosen)
	await process_frame
	var tb: Toolbar = m.toolbar
	var holds := PlayHolds.new(tb)  # (its own, beside the screen's: the screen holds nothing in free mode)

	# a hold pauses and locks; RESTORE gives back the speed from before.
	tb.speed_100_button.button_pressed = true
	TestUtil.check(not tb.is_paused() and tb.speed_100_button.button_pressed, "setup: playing at x100")
	holds.hold(&"a")
	TestUtil.check(holds.has(&"a") and tb.is_paused() and tb.resume_locked, "a hold pauses the game and locks the toolbar")
	tb.set_paused(false)
	TestUtil.check(tb.is_paused(), "a locked toolbar cannot resume")
	holds.release(&"a")
	TestUtil.check(not holds.has(&"a") and not tb.resume_locked, "release lifts the hold and the lock")
	TestUtil.check(not tb.is_paused() and tb.speed_100_button.button_pressed, "RESTORE after a hold begun while playing returns to the x100 playing")

	# A hold begun while already paused stays paused on RESTORE.
	tb.speed_1000_button.button_pressed = true
	tb.set_paused(true)
	holds.hold(&"a")
	holds.release(&"a")
	TestUtil.check(tb.is_paused(), "RESTORE after a hold begun while paused stays paused")
	tb.set_paused(false)
	TestUtil.check(not tb.is_paused() and tb.speed_1000_button.button_pressed, "the last speed is kept through a paused hold")

	# STAY and RESUME.
	tb.speed_100_button.button_pressed = true
	holds.hold(&"a")
	holds.release(&"a", PlayHolds.Then.STAY)
	TestUtil.check(tb.is_paused(), "STAY leaves the game paused")
	holds.hold(&"a")
	holds.release(&"a", PlayHolds.Then.RESUME)
	TestUtil.check(not tb.is_paused() and tb.speed_100_button.button_pressed, "RESUME plays at the last speed")

	# Idempotence: a second hold of the same name keeps the first's memory; releasing what is not held changes nothing.
	holds.hold(&"a")
	tb.pause_button.button_pressed = true  # (already paused by the hold)
	holds.hold(&"a")
	holds.release(&"a")
	TestUtil.check(not tb.is_paused(), "holding a name twice keeps what the first hold found (playing)")
	holds.release(&"nothing")
	TestUtil.check(not tb.is_paused() and not tb.resume_locked, "releasing a name that holds nothing changes nothing")

	# Two holds need two releases.
	holds.hold(&"a")
	holds.hold(&"b")
	holds.release(&"a")
	TestUtil.check(holds.has(&"b") and tb.is_paused() and tb.resume_locked, "one release of two holds leaves the game paused and locked")
	holds.release(&"b")
	TestUtil.check(not tb.resume_locked and tb.is_paused(), "released in the order held: the second hold began while paused, so the game stays paused")
	tb.set_paused(false)
	holds.hold(&"a")
	holds.hold(&"b")
	holds.release(&"b")
	TestUtil.check(tb.is_paused() and tb.resume_locked, "the later hold released first leaves the game paused and locked")
	holds.release(&"a")
	TestUtil.check(not tb.is_paused() and not tb.resume_locked, "the later hold released first: the earlier one's memory restores the playing")

	# RESTORE under another hold does nothing; RESUME under another hold plays but keeps the lock of the one left.
	holds.hold(&"a")
	holds.hold(&"b", false)
	holds.release(&"a", PlayHolds.Then.RESUME)
	TestUtil.check(not tb.is_paused() and not tb.resume_locked, "RESUME plays at once even while an unlocked hold remains, and only locked holds lock")

	# A hold that does not lock: the player may resume, enforce pauses again.
	tb.set_paused(true)
	tb.set_paused(false)
	TestUtil.check(not tb.is_paused(), "an unlocked hold lets the player resume")
	holds.enforce()
	TestUtil.check(tb.is_paused() and holds.has(&"b"), "enforce pauses again while a hold remains")
	holds.release(&"b", PlayHolds.Then.STAY)
	tb.set_paused(false)
	holds.enforce()
	TestUtil.check(not tb.is_paused(), "enforce does nothing with no holds")

	# Speed steps are blocked while locked.
	tb.speed_100_button.button_pressed = true
	holds.hold(&"a")
	tb.step_speed(1)
	TestUtil.check(tb.is_paused() and not tb.speed_1000_button.button_pressed, "step_speed does nothing while locked")
	holds.release(&"a")

	m.queue_free()
	await process_frame
	TestUtil.finish(self, "play_holds_test OK (%d checks)" % TestUtil.checks)
