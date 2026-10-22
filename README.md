# Bups Are Alive

A small laboratory where you watch bacteria-like creatures ("bups") eat, swim, divide and evolve, with the real-world scales (micrometres, seconds) and a realistic model underneath. Play the guided experiments, or use free mode to set up any dish you like.

The game is Godot 4.7 (GDScript). The simulation itself is C++ (a GDExtension in `native/`), so it has to be compiled for your operating system; prebuilt libraries are included in releases.

## Play it

- **Just play:** download your platform's zip from the [Releases](https://github.com/ChrissiQ/ld60-bups-are-alive/releases) page.
  - **macOS:** the app is not notarized. If it says it can't be verified, right-click it and choose Open (or Privacy & Security, then Open Anyway). If it says it is "damaged", run `xattr -cr "Bups Are Alive.app"` in Terminal and open it again.
  - **Windows / Linux:** unzip and run.
- **From inside Godot without compiling anything:** download `BupsAreAlive-<version>-godot-project.zip` from a release (source plus prebuilt libraries for Windows, Linux and macOS), unzip it, open the folder in Godot 4.7 or later and press play.

In game, **Controls** on the title screen lists the keys. The main ones: Space pauses, `1`-`4` set the speed (x1 to x10,000), `I` inspects, `H` pans, scroll or `+`/`-` zoom, `W A S D` move the view, `Z X C V B` show or hide layers.

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

## Tests

Headless scripts in `tests/`, each prints an OK line or the failures:

```
godot --headless --path . -s tests/ui_lint_test.gd
godot --headless --path . -s tests/strings_test.gd
godot --headless --path . res://tests/dialog_test.tscn
```

The quick ones cover the interface (`ui_lint_test`, `strings_test`, `fonts_test`, `screens_test`, `settings_test`, `toolbar_test`, `free_mode_test`, `tutorial_test`, `save_test`). The simulation ones are slow: `model_test`, `cloud_test`, `substep_test`, `motion_table_test`, and `smoke`, which plays a whole game. Run `godot --headless --path . --import` after adding a `class_name` script.

## Making a release

Push a version tag; the release workflow does the rest:

```
git tag v0.2.0
git push origin v0.2.0
```

It builds the libraries for Windows, Linux and macOS, exports the three builds, and publishes a GitHub release with notes (the commit subjects since the previous tag), the three builds, and the Godot project zip with the prebuilt libraries. Pushes alone build nothing. To move a tag, delete the release on GitHub first, then force-push the tag.

## Things to know

- **All player-facing text** is in `text/strings.cfg` (and `text/names.txt` for random names). Scenes use `@section.key`; code uses `Strings.t("section.key")`. If a built game shows raw keys like `menu.title`, those files are missing from the export: the export presets' `include_filter` must contain `text/*`.
- **The interface is styled only through the theme** (`scenes/menu_theme.tres`); `ui_lint_test` fails on hand-styling. See `AGENTS.md`.
- **Motion table:** `scripts/motion_table.gd` is generated (`tools/gen_motion_table.gd`, about 5 minutes). Regenerate it when `motion_table_test` says it is stale.
- **Changing C++:** rebuild the library for your platform; Windows and Linux libraries for releases come from the release workflow.
- **macOS exports** need ETC2/ASTC texture import enabled (already set in `project.godot`).
- **Saves** are `save.json` (goal mode) and `free_settings.json` (free-mode setup) in Godot's user data folder; the format may change before release.
- Font: Commit Mono (SIL Open Font License, `fonts/OFL.txt`).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). The code is under the [MIT License](LICENSE); the bundled font keeps its own license (`fonts/OFL.txt`).
