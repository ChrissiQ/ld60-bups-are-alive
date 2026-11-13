# Parity fixtures

[measured] on Apple M1 Pro, Metal, Godot 4.7.2. These are what the CPU simulation the pooled world replaced answered: a 20,000-bup state and the answers it gave to queries about it. Tests in `tests/` and `tests/sim/` load the state into the pooled world and compare its answers with these.

Files are text (`var_to_str` for vectors and dicts) or gzip (read with `FileAccess.open_compressed(path, READ, COMPRESSION_GZIP)`).

| file | what | read by | stable? |
|---|---|---|---|
| `state_records.bin.gz` | the replaced simulation's exported state (28-word record layout): 20,000 bups, radius 3000, seed 5, the last 50 on the spots of others (ties) | `tests/sim/parity_game.gd` | deterministic |
| `state_field_conc.bin.gz`, `state_field_puffs.bin.gz` | the nutrient grid (float32, conc) and the 60 clouds (5 floats each) as `export_packed()` | `tests/sim/parity_game.gd` | deterministic |
| `queries_pick_near.txt` | 300 rounds of `pick_bup(point, slack, pixel)` and 4 `nearest_and_count` each (rng seed 7) | `tests/sim/parity_pick_test.gd` | deterministic |
| `queries_info.txt` | `bup_info` (every key), `bup_steering`, `bup_radius(id, 2)`, `bup_pos` for 40 bups (indexes 0, 500, ... of `bup_ids()`) | `tests/sim/parity_draw_test.gd` | deterministic |
| `medium_points.txt` | `field.read(p)` (the dish's `nutrient_at` concentration and slope) and `steering_at(p, 30, 60)` at 50 fixed points | `tests/sim/parity_queries_test.gd` | deterministic |
| `haze_bytes.bin.gz` | `haze_bytes(DETECTION_FLOOR, 0.5*255/sqrt(10*HALF_SATURATION), 0.45*255)` as `dish_drawing.gd` calls it: 40,000 bytes | `tests/sim/parity_draw_test.gd` | deterministic |
| `steer_<id>.bin.gz` | `bup_steer_bytes(id, Dish.STEER_ALPHA)` for bups at index 3, 10000, 19999 (ids 4, 10001, 20000): 40,000 bytes each | `tests/sim/parity_draw_test.gd` | deterministic |
| `lineage_export.bin.gz` | `lineage_export_bytes()` of a dish with husks (50 founders, radius 3000, density 32, death husks and stationary phase on, seed 3, 6 sim-hours): 254 records, 250 alive | `tests/dish_codec_test.gd`, `tests/lineage_store_test.gd` | counts deterministic; the order of records inside the bytes is not (compare by id) |
