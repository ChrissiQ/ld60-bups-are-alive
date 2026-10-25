# Contributing

Thanks for wanting to help. Bug reports, ideas and pull requests are all welcome.

## Reporting a problem or suggesting something

Open an issue. For a bug, say what you did, what you expected, and what happened; the platform, the game version (the release tag) and, for anything about the simulation, the dish settings (size, nutrient, bloom, feed) help a lot. A screenshot is worth a paragraph.

## Setting up

Follow "Build and run from source" in the [README](README.md). The C++ simulation must be compiled once for your platform before the game will run from the editor.

## What a good change looks like

- **Keep it small and focused.** One change per pull request. If it is big, open an issue first so we can agree on the approach.
- **The simulation aims to be realistic.** Prefer the real mechanism over a gamey one, and say in the pull request where something was scaled for playability. Speed matters too: the top playback speed (x10,000) is a feature, so a change that adds per-step cost should come with a measurement.
- **Player-facing text** goes in `text/strings.cfg` (`Strings.t("section.key")` in code, `"@section.key"` in scenes; `text/names.txt` holds random names), never as a literal. If a built game shows raw keys like `menu.title`, those files are missing from the export: the export presets' `include_filter` must contain `text/*`.
- **Interface styling** goes through the theme in `scenes/menu_theme.tres` (use a `theme_type_variation`, or add one there). No per-node overrides, no colours or styles in code.
- **Match the code around you:** naming, comment density and idiom. Comments say why, not what.
- **Tests:** add or update a test for behaviour you change. The interface tests are quick and catch most slips (`ui_lint_test`, `strings_test`, `fonts_test`, `screens_test`, `settings_test`, `toolbar_test`, `free_mode_test`, `tutorial_test`); the simulation tests are slow, so run the ones your change can affect. How to run them is under "Tests" below. Please do not leave temporary test files behind.
- **Model changes:** every change to the simulation model must be made in both backends, the C++ in `native/` and the GPU kernels in `gpu/`. See the GPU path section of `AGENTS.md`.
- **Motion table:** `scripts/motion_table.gd` is generated (`tools/gen_motion_table.gd`, about 5 minutes). Regenerate it when `motion_table_test` says it is stale.
- **C++ changes:** rebuild for your platform and say in the pull request that the C++ changed; Windows and Linux libraries come from the release workflow.

`AGENTS.md` has the full list of project conventions and gotchas (it is written for coding agents, but it is just as useful for people).

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

The macOS export needs ETC2/ASTC texture import enabled (already set in `project.godot`).

## Commits and pull requests

- Commit messages are one short line in the present tense, third person: "Fixes source selection", "Adds a layers panel".
- In the pull request, say what changed and why, and how you checked it.

## License

By contributing you agree that your contribution is licensed under the project's [MIT License](LICENSE).
