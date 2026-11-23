# Testing

How the project's tests are run, what kinds there are, and how to run windowed (GPU) runs safely. What each simulation test checks is in the section it belongs to in [simulation.md](simulation.md); the interface suite is listed in [interface.md](interface.md#checks-after-a-change).

## Kinds of test

| Kind | Where | Needs | Speed |
|---|---|---|---|
| Headless | `tests/*_test.gd` | Nothing | Quick |
| Windowed simulation | `tests/sim/*_test.gd` | A window and a GPU | Slow |
| Software-GPU simulation | A subset of `tests/sim/` | Linux, the software Vulkan driver (lavapipe) | Slow; run in CI |
| Ad hoc checks | `tools/gpu/*.gd` | A window and a GPU | Varies; not exported |

`motion_table_test` is headless even though it checks simulation data.

## Headless tests

Each test is a script that prints an OK line or the failures:

```
godot --headless --path . -s tests/<name>.gd
godot --headless --path . res://tests/dialog_test.tscn     # dialog_test is a scene
```

- Run `godot --headless --path . --import` after adding a `class_name` script or a new asset.
- Run the interface suite as tracked tasks: a script error leaves a headless test hanging until its timeout.
- A headless run is given a 1280 x 720 window and ignores the saved preferences. Its simulation backend is the stub (see [simulation.md](simulation.md#overview)).

## Writing a test

Work out what the answer should be first, from sources or derivation, and use the test to confirm it once. Do not run a test in a loop to discover what is correct: write down the expected number and why, and size the sample so it can tell the effect from noise. Where a test's header lists expected values, a tag beside a figure says where it comes from (`[derived]`, `[measured]`; see [CONTRIBUTING.md](../CONTRIBUTING.md#tests)).

Outcomes are deterministic for a seed ([simulation.md](simulation.md#overview)); timings are noisy on a busy machine, so compare variants in the same sitting.

## Simulation tests

Helpers for the windowed tests in `tests/sim/` are `sim_harness.gd`, `scenario.gd` and `smoke.gd`.

`tools/run_sim_tests.sh` (a script for macOS) runs them one after another through `tools/run_windowed.sh`, with a timeout each. `run_windowed.sh` holds a lock so only one GPU run happens at a time. Nothing else may use the GPU during timings.

### Goldens

`goldens_test.gd` compares `validate_dynamics.gd gpu <scenario> 1 6` with `tools/gpu/golden/dynamics_pooled_<scenario>_seed1_6h.txt`, byte for byte. It is the check for a refactor that changes no behaviour.

The goldens were made on Apple Silicon with Metal. A run is deterministic per seed on one machine, but another GPU or driver gives different numbers, so on another machine make a golden yourself before the change.

### Ad hoc checks

The checks in `tools/gpu/` (`pool_*_check.gd`, `core_check.gd`, `view_check.gd`, `game_check.gd` and others) are not exported. On macOS run:

```
godot --path . --rendering-driver metal --position 6000,6000 -s tools/gpu/<script>.gd -- <args>
```

and send the output to a file.

### Windowed runs

Windowed runs for screenshots should be short, self-quitting and off-screen (`--position 6000,6000`). That position is off-screen only on a desktop that reaches that far; on a smaller one the system moves the window to a corner, partly in view.

The game manages its own window (full screen, or the project's maximized mode) unless it is headless, run from a script (`-s`), or given `--windowed` or `--resolution` (`UserSettings._window_is_managed`). A game started from the editor is managed, so the editor's `--position` does not leave it small.

A window that is not managed is kept as it was started for the run's first 10 s (`UserSettings.hold_windowed`, asked each frame by `PreferencesHook`). A window manager that lays windows out may resize a new window just after it opens, and a run measured in a window of another size, or with the pointer over the dish, is not the scene it claims. `tests/sim/interface_gate.gd` fails such a run.

### The tests on a software GPU

`.github/workflows/sim-tests.yml` runs these on a hosted Linux runner with no GPU, on the software Vulkan driver (lavapipe) under a virtual display (`xvfb-run`), by hand or as a job of the release:

`isolation_test`, `permutation_test`, `field_padding_test`, `continuation_test`, `conjugation_isolation_test`, `medium_isolation_test`, `near_lists_test`, `invariants_test`, `stats_test`, `faint_view_test`, `picture_steps_test`, `places_before_test`.

- **No recorded values.** These tests need no values recorded on another machine: they compare runs made on the one device, or count. `conjugation_isolation_test` also expects a dish's donors to grow in number; `invariants_test` and `stats_test` hold sums to tolerances that were not measured on this driver; `faint_view_test` compares the nutrient picture with a sum it works out itself.
- **The build.** The workflow builds the Linux debug `LineageStore` itself (at `GODOT_CPP_COMMIT`) and first dispatches one trivial kernel in an empty project (`tools/ci/compute_probe.gd`, `tools/ci/probe_project/`). A failure there is the runner's, not the game's.
- **Passing.** A test counts as passed only when its OK line is in the log.
- **Adding a test.** A test added to `tests/sim/` runs there only when the workflow's list names it.
