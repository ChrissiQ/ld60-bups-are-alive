# Parity fixtures

[measured] on the CPU simulation the pooled world replaced, Apple M1 Pro, Metal, Godot 4.7.2. These are what the CPU engine answered before the pooled GPU world; later tests compare against them.

Reproduce: the capture scripts (`capture_parity.sh`, `capture_parity.gd` in tools/gpu) need the deleted processor engine and are no longer in the tree; they are in the history of those paths up to their deletion, and ran on that engine (windowed, through the lock; four modes: `state`, `husks`, `goal`, `screens`).

Files are text (`var_to_str` for vectors and dicts) or gzip (read with `FileAccess.open_compressed(path, READ, COMPRESSION_GZIP)`).

| mode | file | what | stable? |
|---|---|---|---|
| state | `state_records.bin.gz` | `BupSim.export_state_bytes()` of the queries_check state: 20,000 bups (28-word records), radius 3000, seed 5, the last 50 on the spots of others (ties) | deterministic; reproduced byte for byte by a second run |
| state | `state_field_conc.bin.gz`, `state_field_puffs.bin.gz` | the nutrient grid (float32, conc) and the 60 clouds (5 floats each) as `export_packed()` | deterministic |
| state | `queries_pick_near.txt` | 300 rounds of `pick_bup(point, slack, pixel)` and 4 `nearest_and_count` each (the rounds of queries_check, rng seed 7) | deterministic |
| state | `queries_stats.txt` | `population_stats()` (full dict) and four `fraction_with_gene_at_least` answers | deterministic |
| state | `queries_info.txt` | `bup_info` (every key), `bup_steering`, `bup_radius(id, 2)`, `bup_pos` for 40 bups (indexes 0, 500, ... of `bup_ids()`) | deterministic |
| state | `medium_points.txt` | `field.read(p)` (the dish's `nutrient_at` concentration and slope) and `steering_at(p, 30, 60)` at 50 fixed points | deterministic |
| state | `haze_bytes.bin.gz` | `haze_bytes(DETECTION_FLOOR, 0.5*255/sqrt(10*HALF_SATURATION), 0.45*255)` as `dish_drawing.gd` calls it: 40,000 bytes | deterministic |
| state | `steer_<id>.bin.gz`, `steer_ids.txt` | `bup_steer_bytes(id, Dish.STEER_ALPHA)` for bups at index 3, 10000, 19999 (ids 4, 10001, 20000): 40,000 bytes each | deterministic |
| husks | `husks.txt` | `husks_export()` (x y energy age next) and `husk_near` of a CPU dish: 50 founders, radius 3000, density 32, death husks and stationary phase on, seed 3, 6 sim-hours (6 husks, 254 records, 250 alive) | deterministic |
| husks | `lineage_export.bin.gz`, `lineage_export.txt` | `lineage_export_bytes()` of the same dish and its counts | counts deterministic; the order of records inside the bytes is not (compare by id, as with the lineage files) |
| goal | `goal_run.txt` | goal mode's dish (`Dish.strike(null)`, seed 1, CPU backend, 20 s steps, `tracker.update` as Main does, `apply_costs` on completion), a sample every 30 sim-minutes: experiment 1 completes at 80,640 s (22:24:00); the run stops at 40 sim-hours with experiment 2 not reached (sense >= 70 is 0.07% of the colony at the end) | deterministic |
| screens | `game_100.png`, `game_150.png`, `game_250.png` | the game screen (free-mode start, 300 bups, 4000 um dish, x600) at interface size 100/150/250% with `native_override` 1.0, in a 1920x1080 window | pixels vary with GPU timing |
| screens | `debuglog/bups-*.log` and `.png` | one F12 debug log of that screen | time, fps, timing and positions vary; keys are stable |

Goal mode on the CPU backend is the fixture; on the GPU backend timing makes the run differ, so the completion times are compared "within one step".
