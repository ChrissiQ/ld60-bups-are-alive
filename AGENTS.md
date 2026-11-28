# Instructions for coding agents

Bups Are Alive is a realistic bacteria-evolution simulation and game: Godot 4.7 with GDScript, and GPU compute shaders for the simulation. The only C++ is the family-tree store (`LineageStore`) and the graphics-memory query (`GpuMemory`). [README.md](README.md) says how to build and run it, [CONTRIBUTING.md](CONTRIBUTING.md) what a good change looks like. This file is what every agent needs before changing the project; [Where to read next](#where-to-read-next) lists the docs per area.

## What the project is for

A laboratory for watching real evolution: bups eat, swim toward food, divide, mutate and compete at real scales (micrometres, seconds), at playback speeds from real time to x10,000. When goals conflict, in this order:

1. **Watchable and fun at speed.** x10,000 is the most important performance target. Anything that adds per-step cost needs it measured at that speed. A little speed can be traded for clear accuracy, not a large chunk.
2. **Accurate to real evolution.** It is a realistic *life* simulator, not just an E. coli one: prefer the realistic mechanism over a gamey one, and say where realism was scaled for playability (mutation *rates* are raised well above a real microbe's; the *shape* of the spectrum stays realistic). A feature borrowed from another organism is fine if the combined organism is plausible and keeps the feature's real costs and trade-offs.
3. Everything else.

**Platform.** Windows with a desktop gaming GPU is first-class, and the performance targets are judged there. A cost in speed or smoothness elsewhere (Apple Silicon, for example) is acceptable when it benefits Windows, and NVIDIA-only features are acceptable. Say what a figure was measured on, generically ("Windows, Direct3D 12"; "Apple Silicon, Metal").

**Clocks and units.** Two clocks only: real time and the simulation clock (playback speed multiplies it). No scaled "game clock"; show times with `SimClock.format`. Units are µm and seconds. "Metabolism" is a gene, nothing else.

## Where to read next

| Read | When |
|---|---|
| [docs/simulation.md](docs/simulation.md) | Changing `gpu/`, `scripts/sim/`, `tests/sim/`, `tools/gpu/`, the views, dishes, memory limits or the kernels' biology. Holds the kernel rules (shaders, layouts, workgroups, the main `RenderingDevice`). |
| [docs/interface.md](docs/interface.md) | Changing a scene, the theme, a control, a dialog or a panel. Holds the design-system rules. |
| [docs/encyclopedia.md](docs/encyclopedia.md) | Changing what a gene, mechanism, rate, cost or range does, or adding a term the player meets. |
| [docs/testing.md](docs/testing.md) | Running or writing tests, especially windowed (GPU) simulation tests, goldens and the software-GPU CI. |
| [docs/debugging.md](docs/debugging.md) | Diagnosing a report: the F12 debug log and the F3 timing overlay. |
| [docs/build-and-release.md](docs/build-and-release.md) | Rebuilding the native library, regenerating the motion table, exports, the release. |
| [docs/sources.md](docs/sources.md) | Before researching or citing a fact from published work. |

## Hard rules

- **Never edit a generated file.** Edit its source and run the generator ([Generated files](#generated-files)).
- **Never create, edit, rename or delete `.env` files.** Reference their variables from project code.
- **Saves are not stable.** The game is unreleased: write no code that reads old save formats, and do not edit a real `save.json` or `free_settings.json` in the user data folder. Tests use scratch paths.
- **Commit messages** are one short line in the present tense, third person ("Fixes source selection"), with no body and no attribution trailer.
- **Never kill processes broadly.** Delete temporary test files when done.
- **Committed files are written for any reader.** Comments are for future developers, documentation for future audiences. Nothing tracked may speak of:
  - one person, one person's computer (programs, displays, sizes, set-up), one session or one agent;
  - a file that is not tracked;
  - a plan or its labels (a package, a phase, a numbered row or decision);
  - who decided something or when, a conversation, or the work's own history.

  A reader with only the repository must follow every sentence. Say the general condition ("a window manager may resize a new window"); name a set-up only generically and only where the reader needs it (what a figure was measured on). Notes about a particular machine, run or person go in untracked files. Read a diff for such wording before committing it.

### Generated files

| File | Source | Command | Stale check |
|---|---|---|---|
| `scenes/menu_theme.tres` | `design/tokens.json`, `tools/gen_theme.py` | `python3 tools/gen_theme.py`, then `godot --headless --path . --import` | `design_tokens_test` |
| `docs/design-system.html` | `design/tokens.json`, `tools/gen_design.py` | `python3 tools/gen_design.py` | `design_tokens_test` |
| `gpu/shaders/*.glsl` | `gpu/kernels*.gd` | `godot --headless --path . -s tools/gen_gpu_shaders.gd`, then `--import` | `gpu_shaders_test` |
| `scripts/motion_table.gd` | `tools/gen_motion_table.gd` | see [docs/build-and-release.md](docs/build-and-release.md#the-motion-table) | `motion_table_test` |

Run generators from the project root. Details: [docs/interface.md](docs/interface.md#the-theme-is-generated), [docs/simulation.md](docs/simulation.md#the-kernels).

## Conventions the tests enforce

- **All player-facing text** lives in `text/strings.cfg`: `Strings.t("section.key", args)` in code, `"@section.key"` in scenes, a comment above each key. `tests/strings_test.gd` checks that every key exists and that every raw file the game reads is covered by each export preset's `include_filter` (a raw file missing from an export makes the game show keys instead of words).
- **UI styling lives in the theme.** No per-node overrides, no styles or colours built in code, two typefaces, numeric settings through `ui/setting_row.tscn`. `tests/ui_lint_test.gd` fails on any of it; rules in [docs/interface.md](docs/interface.md#styling-rules).
- **A bup's name has one source** (`bup_names.gd`); build names nowhere else.
- **Facts from published work are cited by key.** `docs/sources.md` lists every source with its DOI and the facts taken from it; look there before researching a fact again. Code and `text/strings.cfg` comments cite it as `@Key` (`[search: @Biselli2020]`). A new source gets its entry in the same change: `tests/sources_test.gd` fails on a key with no entry and an entry nothing cites. Some older lines name their source in prose or carry `[memory]`; every new fact is cited by key.
- **Free-mode defaults are goal mode's settings.** `StartConditions.new()` holds the defaults; goal mode's dish is `dish.strike(null)`, which uses it, so free mode differs only in letting them be changed (`tests/free_mode_test.gd`). A feature on in goal mode and a toggle in free mode is on by default there, and "reset to defaults" restores `StartConditions.new()`'s value.
- **GPU data layouts** are named once in `gpu/gpu_layout.gd`, never as numbers (`tests/sim_layout_test.gd`); see [docs/simulation.md](docs/simulation.md#layouts).

## The encyclopedia

Kept true, complete and to concepts. A change that alters what an entry says (a constant, cost, rate, mechanism, name or range) updates it in the same change, checked against the code. A new gene, flag, mechanic, dish thing or term the player meets gets an entry (`scripts/encyclopedia.gd`, `[encyclopedia]` in `text/strings.cfg`); a changed or new interface part updates or adds a tutorial step. Real biology is checked against sources before it is written. Entries never say what to click or press. The rest is in [docs/encyclopedia.md](docs/encyclopedia.md).

## Running things

How to run tests: [docs/testing.md](docs/testing.md#headless-tests). Run `godot --headless --path . --import` after adding a `class_name` script or a new asset.

- After an interface change run the suite in [docs/interface.md](docs/interface.md#checks-after-a-change).
- Simulation tests are slow and windowed ([docs/testing.md](docs/testing.md#simulation-tests)). Work out the expected answer first, from sources or derivation, and use a test to confirm it once; never run tests in a loop to discover what is correct ([docs/testing.md](docs/testing.md#writing-a-test)).

## Gotchas

- GDScript: `%g` is not a supported format. Comparing a `String` to a `bool` with `==` is an error (check `is bool` first).
- `.uid` files are tracked.
