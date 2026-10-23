# Instructions for coding agents

Bups Are Alive is a realistic bacteria-evolution simulation and game: Godot 4.7 with GDScript for the game, and a C++ GDExtension for the simulation. [README.md](README.md) says how to build and run it, and [CONTRIBUTING.md](CONTRIBUTING.md) what a good change looks like. This file is what an agent needs to know about the project before changing it.

## What the project is for

It is a laboratory for watching real evolution happen: bups eat, swim toward food, divide, mutate and compete at real scales (micrometres, seconds), and the player can run it from real time up to x10,000. When goals conflict, in this order:

1. **It must be watchable and fun at speed.** The top playback speed (x10,000) is the most important performance target. Anything that adds per-step cost needs its cost measured at that speed. A little speed can be traded for clear accuracy, not a large chunk.
2. **It models real evolution accurately.** It is a realistic *life* simulator, not just an E. coli simulator: prefer the realistic mechanism over a gamey one, and say where realism was scaled for playability (mutation *rates* are raised well above a real microbe's, the *shape* of the spectrum stays realistic). A feature borrowed from another organism is fine if the combined organism is plausible and keeps the feature's real costs and trade-offs.
3. Everything else.

There are exactly **two clocks**: real time, and the simulation clock (playback speed multiplies it). Do not invent a scaled "game clock"; show times with `SimClock.format`. Units are µm and seconds. "Metabolism" is a gene, nothing else.

## Layout

- `scripts/`, `scenes/`, `ui/`: the game. `scripts/dish.gd` owns a dish (drawing, picking, layers, plankton); `scripts/main.gd` is the game screen; `scripts/session.gd` carries state between screens; `scripts/start_conditions.gd` is how a dish begins; `scripts/goal_tracker.gd` holds the experiments' goals.
- `native/src/`: the C++ simulation. `BupSim` holds the bups, `NutrientField` the nutrient grid and the sub-grid plankton clouds, `params.h` the constants. `scripts/sim_constants.gd` builds the constants it receives.
- `text/strings.cfg`: every word the player reads. `text/names.txt`: random bup names.
- `tests/` and `tools/`: tests and generators. `.github/workflows/`: the native build and the release.

## Conventions the tests enforce

- **All player-facing text** lives in `text/strings.cfg`: `Strings.t("section.key", args)` in code, `"@section.key"` in scenes, a comment above each key. `tests/strings_test.gd` checks that every key exists and that every raw file the game reads is covered by each export preset's `include_filter` (a raw file missing from an export makes the game show keys instead of words).
- **UI styling lives in the theme** (`scenes/menu_theme.tres`). Use `theme_type_variation`; add a variation to the theme when none fits (its base type must be a plain Control type, not another variation). No per-node overrides, no styles or colours built in code (colours only in `dish.gd` and `genome.gd`), one typeface (Commit Mono in `fonts/`), numeric settings through `ui/setting_row.tscn`. `tests/ui_lint_test.gd` fails on any of this. Screen paths live in `scripts/scenes.gd`.
- A bup's name has one source (`bup_names.gd`); do not build names elsewhere.

## Repository conventions

- **Commit messages** are one short line in the present tense, third person ("Fixes source selection"), with no body and no attribution trailer.
- **Secrets:** do not create, edit or delete `.env` files; reference their variables.
- **Saves are not stable.** The game is unreleased, so do not write code that reads old save formats, and do not edit a real `save.json` or `free_settings.json` in the user data folder; tests use scratch paths.
- **Releases** are made by pushing a `v*` tag (see the README); changing a workflow in `.github/workflows/` changes what builds.

## Debug log

F12, on any screen (undocumented in the game: not on the HUD or in the controls; only its notice is in `strings.cfg`), writes `bups-<date>_<time>-<ms>.log` and a `.png` of the screen to `user://logs/` (on macOS `~/Library/Application Support/Godot/app_userdata/<project>/logs/`), then shows "Debug info logged" for a few seconds. The log is JSON: the run's settings and state, the mean nutrient by distance from the dish centre (a rim ring or step shows there), the selected bup, and every simulation constant. It works in menus and in the tutorial: the `DebugHotkey` autoload (`ui/debug_hotkey.tscn`) takes the key, logs the current screen and the session, and the screen's `dish` and `debug_state()` when it has them. Each write prunes the folder to the newest 20 logs and nothing older than 14 days. When diagnosing a report, read the newest log (`ls -t`) and its screenshot. `scripts/debug_log.gd` builds it; add to `report` what a diagnosis keeps needing, and keep personal data out.

## Running things

Tests are headless scripts: `godot --headless --path . -s tests/<name>.gd` (`dialog_test` is a scene: `godot --headless --path . res://tests/dialog_test.tscn`); each prints an OK line or the failures. Run `godot --headless --path . --import` after adding a `class_name` script or a new asset.

- After any interface change run `ui_lint_test`, `strings_test`, `fonts_test`, `screens_test`, `settings_test`, `toolbar_test`, `free_mode_test`, `tutorial_test` and `debug_log_test`.
- The simulation tests are slow (`model_test`, `substep_test`, `cloud_test`, `motion_table_test`, `smoke`). **Work out what the answer should be first, from sources or derivation, and use a test to confirm it once.** Do not run tests in a loop to discover what is correct: write down the expected number and why, and size the sample so it can tell the effect from noise.
- Outcomes are deterministic for a seed (identical on any thread count); only timing varies. Timings are noisy on a busy machine, so compare variants in the same sitting.
- Windowed runs (for screenshots) should be short, self-quitting and off-screen (`--position 6000,6000`). Never kill processes broadly. Delete temporary test files afterwards.
- **Native code:** rebuild with `cd native && scons platform=<macos|windows|linux> arch=<universal|x86_64> target=template_debug api_version=4.5 -j8` (and `template_release`), and say when the C++ changed, since the other platforms' libraries come from the release workflow. Do not rebuild while headless runs that load the library are in progress.
- **The motion table** (`scripts/motion_table.gd`) is generated by `tools/gen_motion_table.gd` (about 5 minutes) and guarded by hashes: when `motion_table_test` says it is stale, regenerate it. A new constant in `SimConstants.build()` must be classified in `MOTION_INPUTS` or `OTHER_CONSTANTS`.

## Gotchas

- GDScript: `%g` is not a supported format; comparing a `String` to a `bool` with `==` is an error (check `is bool` first).
- The editor re-saves scenes and the theme in its own format (`&"Label"`); keep lint patterns tolerant of both. Typed node exports in a `.tscn` need `node_paths=PackedStringArray("prop")`. `.uid` files are tracked.
- Raw files (`.cfg`, `.txt`) are only exported when a preset's `include_filter` names them. The macOS export needs ETC2/ASTC import on (`project.godot`) and is ad-hoc signed, not notarized. A release is made by pushing a `v*` tag (see the README).
- The tutorial runs on every goal-mode start and only when switched on in free mode; nothing about it is saved in goal mode.
- The medium is 25x thicker than water (`Biology.MEDIUM_THICKNESS`): a stopgap so plankton clouds last long enough to climb, not a realism choice. The nutrient grid has cells 2R/100 across, so a big dish keeps plankton as sub-grid Gaussian "clouds" until they have spread to about a cell.
