# Debugging

The two debug aids built into the game, and how to use them to diagnose a report. Neither is documented in the game: not on the HUD, in the controls list, in the tutorial or in the encyclopedia. Both keys are fixed (not rebindable) and are let through during the tutorial. The `DebugHotkey` autoload (`ui/debug_hotkey.tscn`) takes both keys.

## The debug log (F12)

F12, on any screen, writes a log and a screenshot of the screen to `user://logs/` and shows "Debug info logged" for a few seconds (only that notice is in `text/strings.cfg`). On macOS the folder is `~/Library/Application Support/Godot/app_userdata/<project>/logs/`.

**Diagnosing a report:** read the newest log (`ls -t`) and its screenshot.

- **Files:** `bups-<date>_<time>-<ms>.log` and a `.png` with the same name.
- **Where it works:** in menus and in the tutorial. `DebugHotkey` logs the current screen and the session, and the screen's `dish` and `debug_state()` when it has them.
- **Pruning:** each write prunes the folder to the newest 20 logs and nothing older than 14 days.
- **Code:** `scripts/debug_log.gd` builds it. Add to its `report` whatever a diagnosis keeps needing, and keep personal data out.

### What the log holds

The log is JSON:

- The run's settings and state, the selected bup, and every simulation constant.
- The mean nutrient by distance from the dish centre (a rim ring or step shows there).
- `display`: the frame the game assumed, and the refresh rate, window mode and vsync mode the screen reports now.
- `memory`: the figures the timing overlay's memory rows show, and the held share `memory_fraction`.
- `pictures_last_second`: `WorldClient.picture_rate()`.
- `recent_frames` and `recent_iterations`: the frame record, below.

### The frame record

`recent_frames` and `recent_iterations` come from `FrameRecord` (`scripts/frame_record.gd`), a fixed-size ring that the `DebugHotkey` autoload keeps always on, with the overlay shown or not. It costs a few clock reads a frame, allocates nothing and does not depend on the number of dishes. Both blocks cover the last ten seconds before F12 was pressed (not the frames the game is held for while the log is written).

For each frame it records:

- the frame's length (between the ends of two process steps);
- its main-thread process time (`process_frame` to the last node's `_process`);
- its parts: the world's poll, the game screen's own `_process`, the rest after it, and the family-tree look-ups `Dish.has_record` made in the frame;
- flags: the pointer over the stage or the dish, a hover card, a selection, a new simulation picture.

For each iteration the newest timings report, it records `iteration_ms`, `sync_ms`, `submit_ms_most` and `step_cost_ms`.

**`recent_frames`** has:

- the frame count and the late share (frames over 1.5 display frames, `late_limit_ms`);
- p50, p95, p99 and max of frame length, of process time and of each part (`parts_p95_ms`);
- the five longest frames, with their parts, flags and `seconds_before_key`;
- `late_with_long_process_share`: the share of late frames whose own process time passed a display frame.

**`recent_iterations`** has the p50, p95, p99 and max of each of the four figures.

## The timing overlay (F3)

F3 shows or hides the overlay on the game screen only. It is a child of the stage (`ui/timing_overlay.tscn`, `TimingOverlay`), off at start and not saved, and takes no mouse input.

It shows these rows, smoothed over the last second and rewritten four times a second:

| Row | Source |
|---|---|
| Simulation frames a second the dish in view gets (new pictures from the simulation, not the frames drawn between them) | `WorldClient.picture_rate()` |
| Simulated time per simulation frame, and the longest wait for one in screen redraws | `WorldClient.picture_rate()` (also in the F12 log) |
| Screen redraws a second (while the bups slide between pictures every redraw moves them) | `Engine.get_frames_per_second()` |
| Share of late redraws (longer than 1.5 display frames) | `WorldClient.display_ms` |
| The main thread's process time per frame at the 95th percentile over the last ten seconds | `FrameRecord.process_p95`, the same record as the log's `recent_frames` |
| Playback speed asked and reached | the screen's `sim_speed` and `achieved_speed` |
| Graphics memory the pool holds, and the memory the running dishes need, each against the pool's working budget | the newest snapshot's timing; `TimingOverlay.memory_figures`, the figures the F12 log's `memory` holds; `memory_need_fraction` is what the memory warning judges by |
| The card's usage against its budget, on a card with memory of its own that reports both; or, where the graphics memory is the system's, the system memory in use against the installed memory | `MachineMemory`'s `physical` and `available`, refreshed at the memory watch's pace |

A memory row whose figures are not known is hidden. The labels are `debug.overlay_*` in `text/strings.cfg`. The memory figures are explained in [simulation.md](simulation.md#memory-budget).
