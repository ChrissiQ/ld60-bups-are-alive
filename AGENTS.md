# Instructions for coding agents

Bups Are Alive is a realistic bacteria-evolution simulation and game: Godot 4.7 with GDScript for the game, and compute shaders on the GPU for the simulation. The only C++ is the family-tree store (`LineageStore`) and the graphics-memory query (`GpuMemory`). [README.md](README.md) says how to build and run it, and [CONTRIBUTING.md](CONTRIBUTING.md) what a good change looks like. This file is what every agent needs to know before changing the project; [Where to read next](#where-to-read-next) lists the docs for each area.

## What the project is for

It is a laboratory for watching real evolution happen: bups eat, swim toward food, divide, mutate and compete at real scales (micrometres, seconds), and the player can run it from real time up to x10,000. When goals conflict, in this order:

1. **It must be watchable and fun at speed.** The top playback speed (x10,000) is the most important performance target. Anything that adds per-step cost needs its cost measured at that speed. A little speed can be traded for clear accuracy, not a large chunk.
2. **It models real evolution accurately.** It is a realistic *life* simulator, not just an E. coli simulator: prefer the realistic mechanism over a gamey one, and say where realism was scaled for playability (mutation *rates* are raised well above a real microbe's; the *shape* of the spectrum stays realistic). A feature borrowed from another organism is fine if the combined organism is plausible and keeps the feature's real costs and trade-offs.
3. Everything else.

**Platform.** Windows with a desktop gaming GPU is the first-class platform, and the performance targets (the x10,000 top speed) are judged there. A cost in speed or smoothness on other machines (Apple Silicon, for example) is acceptable when it benefits Windows, and NVIDIA-only features are acceptable. Say what a performance figure was measured on, in the generic sense ("Windows, Direct3D 12"; "Apple Silicon, Metal").

**Clocks and units.** There are exactly two clocks: real time, and the simulation clock (playback speed multiplies it). Do not invent a scaled "game clock"; show times with `SimClock.format`. Units are um and seconds. "Metabolism" is a gene, nothing else.

## Where to read next

| Read | When |
|---|---|
| [docs/simulation.md](docs/simulation.md) | Changing `gpu/`, `scripts/sim/`, `tests/sim/`, `tools/gpu/`, the views, dishes, memory limits or the biology in the kernels. It holds the kernel rules (shaders, layouts, workgroups, the main `RenderingDevice`). |
| [docs/interface.md](docs/interface.md) | Changing a scene, the theme, a control, a dialog or a panel of the game screen. It holds the design-system rules. |
| [docs/testing.md](docs/testing.md) | Running or writing tests, especially the windowed (GPU) simulation tests, goldens and the software-GPU CI. |
| [docs/debugging.md](docs/debugging.md) | Diagnosing a report: the F12 debug log and the F3 timing overlay. |
| [docs/build-and-release.md](docs/build-and-release.md) | Rebuilding the native library, regenerating the motion table, exports and the release. |
| [docs/sources.md](docs/sources.md) | Before researching or citing a fact from published work. |

## Layout

- `scripts/`, `scenes/`, `ui/`: the game. The game screen's files are in [docs/interface.md](docs/interface.md#overview).
- `scripts/sim/`: the simulation's host side. `gpu/`: the kernels, their layouts and the shader set. `native/src/`: `LineageStore` (the family tree of every bup, a GDExtension), `GpuMemory` (the graphics card's memory and how much the system lets the game use) and their registration. `scripts/sim_constants.gd` builds the constants the kernels receive.
- `text/strings.cfg`: every word the player reads. `text/names.txt`: random bup names.
- `tests/`: headless tests; `tests/sim/`: windowed (GPU) simulation tests. `tools/`: generators and checks; `tools/gpu/`: ad hoc checks of the GPU path; `tools/ci/`: the compute probe the CI tests begin with. `.github/workflows/`: the lineage store's build, the simulation tests on a software GPU, and the release.

## Hard rules

- **Never edit a generated file.** Edit its source and run the generator ([Generated files](#generated-files)).
- **Never create, edit, rename or delete `.env` files.** Reference their variables from project code.
- **Saves are not stable.** The game is unreleased: do not write code that reads old save formats, and do not edit a real `save.json` or `free_settings.json` in the user data folder. Tests use scratch paths.
- **Commit messages** are one short line in the present tense, third person ("Fixes source selection"), with no body and no attribution trailer.
- **Never kill processes broadly.** Delete temporary test files when done.
- **Committed files are written for any reader.** Comments are for future developers and documentation for future audiences. Nothing tracked may speak of:
  - one person, one person's computer (its programs, displays, sizes or set-up), one session or one agent;
  - a file that is not tracked;
  - a plan or its labels (a package, a phase, a numbered row or decision);
  - who decided something or when, a conversation, or the work's own history.

  A reader with only the repository must be able to follow every sentence. Say the general condition ("a window manager may resize a new window"), and name a set-up only in the generic sense and only where the reader needs it (what a figure was measured on: "Apple Silicon, Metal"). Notes about a particular machine, run or person go in files that are not tracked. Read a diff for such wording before committing it.

### Generated files

| File | Source | Command | Stale check |
|---|---|---|---|
| `scenes/menu_theme.tres` | `design/tokens.json`, `tools/gen_theme.py` | `python3 tools/gen_theme.py`, then `godot --headless --path . --import` | `design_tokens_test` |
| `docs/design-system.html` | `design/tokens.json`, `tools/gen_design.py` | `python3 tools/gen_design.py` | `design_tokens_test` |
| `gpu/shaders/*.glsl` | `gpu/kernels*.gd` | `godot --headless --path . -s tools/gen_gpu_shaders.gd`, then `--import` | `gpu_shaders_test` |
| `scripts/motion_table.gd` | `tools/gen_motion_table.gd` | see [docs/build-and-release.md](docs/build-and-release.md#the-motion-table) | `motion_table_test` |

Run generators from the project root. Details are in [docs/interface.md](docs/interface.md#the-theme-is-generated) and [docs/simulation.md](docs/simulation.md#the-kernels).

## Conventions the tests enforce

- **All player-facing text** lives in `text/strings.cfg`: `Strings.t("section.key", args)` in code, `"@section.key"` in scenes, with a comment above each key. `tests/strings_test.gd` checks that every key exists and that every raw file the game reads is covered by each export preset's `include_filter` (a raw file missing from an export makes the game show keys instead of words).
- **UI styling lives in the theme.** No per-node overrides, no styles or colours built in code, two typefaces, numeric settings through `ui/setting_row.tscn`. `tests/ui_lint_test.gd` fails on any of it; the rules are in [docs/interface.md](docs/interface.md#styling-rules).
- **A bup's name has one source** (`bup_names.gd`); do not build names elsewhere.
- **Facts from published work are cited by key.** `docs/sources.md` lists every source with its DOI and the facts taken from it. Code and `text/strings.cfg` comments cite it as `@Key` (`[search: @Biselli2020]`); the file says how. Look there before researching a fact again. A new source gets its entry in the same change: `tests/sources_test.gd` fails on a key with no entry and on an entry nothing cites. Not every sourced fact is cited this way yet (some lines name their source in prose or carry `[memory]`); every new one is.
- **Free-mode defaults are goal mode's settings.** `StartConditions.new()` holds the defaults. Goal mode's dish is `dish.strike(null)`, which uses `StartConditions.new()`, so free mode differs only in letting them be changed (`tests/free_mode_test.gd` checks the defaults). A feature that is on in goal mode and a toggle in free mode is on by default there, and "reset to defaults" restores `StartConditions.new()`'s value.
- **Layouts of the GPU's data** are named once in `gpu/gpu_layout.gd`, never as numbers (`tests/sim_layout_test.gd`); see [docs/simulation.md](docs/simulation.md#layouts).

### The encyclopedia

The encyclopedia is kept true, complete and to concepts. An entry explains a term in up to two parts, kept apart as the Civilopedia keeps them:

- `<id>_about`: what it is in real life.
- `<id>_game`: how it works in the game (values, ranges, costs, and where the game departs from real life: a rate raised, a trait standing for many genes, a number that is a game choice).

An entry never says what to click or press, and never what a control does: that is the tutorial's (`[tutorial]`, the steps in `Main._start_tutorial`) and the tooltips', which are names and icons only.

- Every change that alters what an entry says (a constant, a cost, a rate, how a gene or mechanism works, a name, a range) updates the entry in the same change. Check the game part against the code, not from memory.
- A new gene, flag, mechanic, thing in the dish or term the player meets gets an entry (`scripts/encyclopedia.gd`, `[encyclopedia]` in `text/strings.cfg`).
- A changed or new interface part updates or adds a tutorial step.
- Anything about real biology is looked up and checked against sources before it is written: no misconception may stand in an educational text.

`tests/encyclopedia_test.gd` checks the links, that every gene has an entry and that no entry tells the player what to click. It cannot check the facts.

## Running things

How to run tests is in [docs/testing.md](docs/testing.md#headless-tests); run `godot --headless --path . --import` after adding a `class_name` script or a new asset.

- After an interface change run the suite in [docs/interface.md](docs/interface.md#checks-after-a-change).
- The simulation tests are slow and windowed ([docs/testing.md](docs/testing.md#simulation-tests)). Work out the expected answer first, from sources or derivation, and use a test to confirm it once; never run tests in a loop to discover what is correct ([docs/testing.md](docs/testing.md#writing-a-test)).

## Gotchas

- GDScript: `%g` is not a supported format. Comparing a `String` to a `bool` with `==` is an error (check `is bool` first).
- `.uid` files are tracked.
