# Bups Are Alive

A small laboratory where you watch bacteria-like creatures ("bups") eat, swim, divide and evolve, with the real-world scales (micrometres, seconds) and a realistic model underneath. Play the guided experiments, or use free mode to set up any dish you like.

The game is Godot 4.7 (GDScript). The simulation runs on the GPU (compute shaders in `gpu/`, driven from `scripts/sim/` through Godot's `RenderingDevice`), so the game needs a GPU that supports compute. The only C++ is the family-tree store (`LineageStore`, a GDExtension in `native/`), which has to be compiled for your operating system; prebuilt libraries are included in releases.

## Play it

- **Just play:** download your platform's zip from the [Releases](https://github.com/ChrissiQ/ld60-bups-are-alive/releases) page.
  - **macOS:** the app is not notarized. If it says it can't be verified, right-click it and choose Open (or Privacy & Security, then Open Anyway). If it says it is "damaged", run `xattr -cr "Bups Are Alive.app"` in Terminal and open it again.
  - **Windows / Linux:** unzip and run.
- **From inside Godot without compiling anything:** download `BupsAreAlive-<version>-godot-project.zip` from a release (source plus prebuilt libraries for Windows, Linux and macOS), unzip it, open the folder in Godot 4.7 or later and press play.

In game, **Controls** on the title screen lists the keys. The main ones: Space pauses, `1`-`4` set the speed (x1 to x10,000), `I` inspects, `H` pans, scroll or `+`/`-` zoom, `W A S D` move the view, `Z X C M V B` show or hide layers.

## The simulation

Every running dish lives in one pooled world on the GPU: one set of buffers holds all the dishes' bups, nutrient grids, clouds and husks, and a dish's run does not depend on what else is in the pool. A thread of its own steps the world; the main thread shows the newest snapshot of it. There is no processor simulation and no backend setting. A machine without compute shaders (a headless run) gets a stub that runs nothing.

## Build and run from source

You need Godot 4.7, Python 3 with SCons (`pip install scons`), and a C++ compiler (Xcode command line tools on macOS), and a GPU with compute shaders to run the simulation.

1. **Get the C++ bindings.** `native/godot-cpp/` is not in the repository; clone it at the commit the game was built with (`GODOT_CPP_COMMIT` in `.github/workflows/build-native.yml`):
   ```
   git clone https://github.com/godotengine/godot-cpp native/godot-cpp
   git -C native/godot-cpp checkout <that commit>
   ```
2. **Compile the lineage store** (debug is what the editor uses; release is for exports). On macOS (on another system give its `platform` and `arch`, as the matrix of `.github/workflows/build-native.yml` lists them):
   ```
   cd native
   scons platform=macos arch=universal target=template_debug api_version=4.5 -j8
   scons platform=macos arch=universal target=template_release api_version=4.5 -j8
   ```
   The libraries land in `native/bin/` (not committed).
3. **Open the project** in Godot 4.7 and press play (the first open imports assets), or run `godot --path .`.

Only the lineage store needs compiling. GDScript changes take effect on the next run.

## Things to know

- **Saves** are `save.json` (goal mode) and `free_settings.json` (free-mode setup) in Godot's user data folder; the format may change before release.
- Fonts: IBM Plex Sans and Commit Mono (SIL Open Font License, `fonts/OFL-IBMPlex.txt`, `fonts/OFL.txt`).

## Contributing and license

Tests and how to change the project are in [CONTRIBUTING.md](CONTRIBUTING.md). The code is under the [MIT License](LICENSE); the bundled fonts keep their own licenses (`fonts/OFL-IBMPlex.txt`, `fonts/OFL.txt`).
