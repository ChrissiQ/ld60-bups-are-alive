# Bups Are Alive

A small laboratory where you watch bacteria-like creatures ("bups") eat, swim, divide and evolve, with the real-world scales (micrometres, seconds) and a realistic model underneath. Play the guided experiments, or use free mode to set up any dish you like.

The game is Godot 4.7 (GDScript). The simulation itself is C++ (a GDExtension in `native/`), so it has to be compiled for your operating system; prebuilt libraries are included in releases.

## Play it

- **Just play:** download your platform's zip from the [Releases](https://github.com/ChrissiQ/ld60-bups-are-alive/releases) page.
  - **macOS:** the app is not notarized. If it says it can't be verified, right-click it and choose Open (or Privacy & Security, then Open Anyway). If it says it is "damaged", run `xattr -cr "Bups Are Alive.app"` in Terminal and open it again.
  - **Windows / Linux:** unzip and run.
- **From inside Godot without compiling anything:** download `BupsAreAlive-<version>-godot-project.zip` from a release (source plus prebuilt libraries for Windows, Linux and macOS), unzip it, open the folder in Godot 4.7 or later and press play.

In game, **Controls** on the title screen lists the keys. The main ones: Space pauses, `1`-`4` set the speed (x1 to x10,000), `I` inspects, `H` pans, scroll or `+`/`-` zoom, `W A S D` move the view, `Z X C V B` show or hide layers.

## CPU and GPU simulation

The simulation has two backends that implement the same model: C++ on the CPU (`native/`) and compute shaders on the GPU (`gpu/`, run through Godot's `RenderingDevice`). The GPU is much faster with large populations at high playback speeds. Slow playback always runs on the CPU.

The **GPU simulation** setting has three values:

- **Auto** (default): chooses the backend while the game runs, from the dish size, the population and the playback speed.
- **On**: runs on the GPU, except at slow playback.
- **Off**: runs on the CPU only.

Free mode offers the setting under the setup screen's Advanced options; goal mode always uses Auto. A machine with no usable GPU runs on the CPU.

## Build and run from source

You need Godot 4.7, Python 3 with SCons (`pip install scons`), and a C++ compiler (Xcode command line tools on macOS, MSVC on Windows, gcc/clang on Linux).

1. **Get the C++ bindings.** `native/godot-cpp/` is not in the repository; clone it at the commit the game was built with (`GODOT_CPP_COMMIT` in `.github/workflows/build-native.yml`):
   ```
   git clone https://github.com/godotengine/godot-cpp native/godot-cpp
   git -C native/godot-cpp checkout <that commit>
   ```
2. **Compile the simulation** (debug is what the editor uses; release is for exports):
   ```
   cd native
   scons platform=macos arch=universal target=template_debug api_version=4.5 -j8
   scons platform=macos arch=universal target=template_release api_version=4.5 -j8
   ```
   Use `platform=windows arch=x86_64` or `platform=linux arch=x86_64` on those systems. The libraries land in `native/bin/` (not committed).
3. **Open the project** in Godot 4.7 and press play (the first open imports assets), or run `godot --path .`.

Only the C++ needs compiling. GDScript changes take effect on the next run.

## Things to know

- **Saves** are `save.json` (goal mode) and `free_settings.json` (free-mode setup) in Godot's user data folder; the format may change before release.
- Font: Commit Mono (SIL Open Font License, `fonts/OFL.txt`).

## Contributing and license

Tests, releases and how to change the project are in [CONTRIBUTING.md](CONTRIBUTING.md). The code is under the [MIT License](LICENSE); the bundled font keeps its own license (`fonts/OFL.txt`).
