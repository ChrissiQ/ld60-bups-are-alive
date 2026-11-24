# The simulation

How the simulation runs, from the commands the game sends to the pictures it draws. Read before changing `gpu/`, `scripts/sim/`, `tests/sim/`, `tools/gpu/` or the views. Tests: [testing.md](testing.md).

- [Overview](#overview)
- [Architecture](#architecture)
- [Time and speed](#time-and-speed)
- [The pool](#the-pool)
- [Memory budget](#memory-budget)
- [Dishes](#dishes)
- [Pictures: from the simulation to the screen](#pictures-from-the-simulation-to-the-screen)
- [Biology in the kernels](#biology-in-the-kernels)
- [The nutrient field](#the-nutrient-field)
- [Changing the simulation](#changing-the-simulation)
- [Measured and not built](#measured-and-not-built)
- [Where the code lives](#where-the-code-lives)

## Overview

The simulation is **one pooled world on the GPU**. Every running dish's bups, nutrient grid, plankton clouds and husks share one set of buffers, and a dish's run does not depend on what else is in the pool. The model lives in the compute kernels and nowhere else; the host code (`scripts/sim/`, one snake_case file a class: `SimCore` is `sim_core.gd`) schedules them, moves data and applies edits.

There is no CPU simulation, no backend setting and no automatic choice between backends. A machine that cannot make a local `RenderingDevice` with the imported `pool_*` shaders, and a headless run, get `CpuSimBackend`, a stub that runs nothing (`can_simulate()` is false, commands are dropped, the snapshot is empty).

An outcome is deterministic for a seed and identical on any thread count. Only timing varies, and the step the `Governor` chooses (see [Time and speed](#time-and-speed)) differs between machines; tools and tests that drive `SimCore` set the step themselves.

```
main thread                      sim thread (SimThread)               ResultWorker thread
-----------                      ----------------------               -------------------
Main, Dish, views                drain commands
  |  commands (WorldClient)  ->  Governor: how many steps, how long
  |                              SimCore.run: steps + answers + pictures
  |  Snapshot, SimReply      <-  (local RenderingDevice, one sync)  ->  stats -> Snapshot (mutex swap)
  |  pictures (Playout)      <-                                  |
  |                                                              |      LineageWorker thread
  |  LineageStore queries,   <-                                  +--->  family events, lineage steps
  |  freeze and save replies                                            -> LineageStore (its one writer)
ViewRenderer (main device): view_* kernels, MultiMesh, picks
```

## Architecture

### Threads and the seam

`SimService` (autoload, `scripts/sim/sim_service.gd`) makes the backend once: `GpuSimBackend` when `available()`, else the stub. `SimBackend` is the seam, and `tests/fakes` holds the test double.

The main thread talks to the simulation only through `WorldClient` (`scripts/sim/world_client.gd`, `WorldClient.shared()`):

- **Commands** go in a queue: `add_dish`, `remove_dish`, `freeze`, `thaw`, `pipette`, `resize`, `set_params`, `edit_world`, `set_time`, `set_view`, `ask`, `inspect`, `save_all`, `discard_frozen` (the family tree lets go of a frozen dish's claims, in order with the dish's freeze in the lineage worker's queue) and others.
- **Answers** come back as a `SimReply`.
- **What the world looks like** is the newest `Snapshot` (`latest()`, `snapshot_changed`).

The sim thread (`SimThread`) owns a local `RenderingDevice`, a `SimCore` and a `DishWorld` per dish. `SimCore` (`scripts/sim/sim_core.gd`) is synchronous and threadless, which is how tests and tools drive it directly. `DishWorld` (`scripts/sim/dish_world.gd`) is a dish's plankton, bloom, sources and emitters on the host; its events (clouds, deposits, husks) are stamped with the step they belong to, and `checkpoint` and `restore` undo a refused window.

### The iteration

`SimThread` loops: drain the commands, ask the `Governor` for steps, run an iteration, hand the result on. An iteration (`SimCore.run`):

1. Records the steps.
2. After them, in the same compute list, records the answers to the questions due and the main dish's pictures.
3. Submits, then syncs once, with one read-back of the dish state, stats, family events, answers and the pictures' bytes.
4. Hands the family events to `LineageWorker` and the rest of what was read to `ResultWorker` (`SimThread._hand_on`).

An iteration the memory budget refuses puts the dishes' worlds back (`DishWorld.restore`) and is retried with fewer steps.

### Results and the family tree

Two threads take what an iteration read back, each with its own queue, and neither waits on the other:

- **`ResultWorker`** decodes the stats and builds the `Snapshot` it swaps in under a mutex. Its queue holds at most `MAX_ITERATIONS` (2) iterations; past that the sim thread waits.
- **`LineageWorker`** is the one thread that writes `LineageStore` (the store's threading contract, in `native/src/lineage_store.h`). It takes each iteration's family events and, between them, the lineage steps of the commands, in the order the sim thread asked them: a dish's founders, a dish removed or resized (its deaths), a freeze (export, then release, then the reply with the blob), a thaw (import), a pipette (retarget), a frozen dish discarded, a save (each running dish's export, then the reply). Its queue is bounded by the bytes of family events it holds (`LineageWorker.MAX_BYTES`, 512 MiB: about 4 s of events of a world of two 2-million-bup dishes, by an estimate its comment gives, so a freeze of such a dish on a slower machine does not stop the simulation); past that the sim thread waits.

A reply that needs the store (a freeze's blob, a save's blobs) is completed by the lineage worker after its step. A reply that needs only the sim thread's work (a pipette's, a resize's) is completed by the result worker, after the snapshots of the iterations before it and before the next one's, and does not wait for the family tree.

**What lags.** The store runs behind the snapshots by what the lineage worker has queued: usually part of an iteration, and for the length of a freeze's export and release (up to a few seconds for a 2-million-bup dish) while one is done. Each push returns a ticket, each snapshot carries the ticket of every lineage step asked before its iteration (`Snapshot.lineage_ticket`), and `WorldClient.lineage_has(ticket)` says whether the store has done them. Meanwhile:

- a bup a snapshot shows may have no record yet (`Dish.has_record` false): the inspector keeps such a selection and shows nothing of it until the record comes, and lets go of a selection only when its record is still missing after the steps behind what was shown (the record is gone); the hover card and the watch list leave out a bup with no record;
- a thawed dish runs and shows at once, and its bups' records come when the lineage worker has imported its part;
- a pipette's bups keep the old dish as their home in the store until the retarget is done: `WorldClient.moved` (from the pipette's answer) and `home_of` give their new dish meanwhile (`Dish.has_bup`, `bup_ids`, `lineage_info`), and counts by home (`Dish.living_descendants_of`, the lineage panel's "alive elsewhere") are not shown until `WorldClient.homes_known`.

The snapshot's timing carries the lineage worker's figures (`lineage_ms`: the last iteration's events it applied; `lineage_queue`, `lineage_queue_bytes`, `lineage_behind_s`: how far the store is behind the snapshot), which the F12 log reports.

The lineage worker applies the events in calls of at most `LineageWorker.APPLY_PART` events (`apply_in_parts`: a step at a time, its births before its deaths, so the store ends as one call would leave it). The store holds its lock through a call, and the main thread looks a bup up every frame. One call for the events of two 2-million-bup dishes would hold the lock for tens of ms: about 8% of frames at 60 Hz were late, against under 1% in parts (measured on an NVIDIA card, Direct3D 12).

**Shutdown.** `SimThread.stop` stops the loop, lets both queues take pushes without waiting (so the sim thread cannot hang on a full one), joins the sim thread, then lets each worker finish what is queued and joins it: every lineage step runs and every reply waiting on one is completed, so stopping with a long backlog takes as long as the backlog. Leaving a game does not stop the threads: the menu's backdrop runs in the same world, and the steps of the dishes the game left (`release_dish`, `discard_frozen`) run in order behind it.

### Questions

The screen asks questions of the simulation (`WorldClient.ask`: shares, tracked bups, probes, husks). A dish's questions are answered at most every `SimThread.ANSWER_MSEC` (`_due_questions`), from the state after the iteration's steps.

- Each dish whose questions need the card takes a set of the question buffers (`GpuLayout.ANSWER_SETS`; set 0 is the publish's tracked bups). A dish past the last set is answered in the next list.
- The answer kernels bound their loops by what the card holds when they run, not by counts the host knew when it recorded them (`pool_track` reads the dish's segment from `DSTATE`).
- The tracked bups' places become probe points on the card (`pool_track_points`), so the steering at each comes from the same list.
- `SimCore.answer` (and `track`, `probe`, `husk_near`, `fraction_with_gene_at_least`) runs the same kernels in a list of their own, for tests and tools.

## Time and speed

Every dish shares one world clock. `Main._advance_world` sends `WorldClient.set_time(sim_speed, paused, real_dt)`, and the `Governor` (`scripts/sim/governor.gd`) turns it into steps. If the machine cannot keep up, the whole world slows together (`achieved_speed`).

### Step length

A step is the shortest that reaches the asked speed: `clamp(speed / R, speed x frame, MAX_STEP)`, with `MAX_STEP` 20 s at most.

- `frame` is the display's frame (`FALLBACK_STEPS_PER_SECOND`, 120 a second, while the display's rate is not known).
- `R` is the steps a second the machine sustains, sized to `HEADROOM` of what an iteration of the usual k costs: its fixed cost plus k times the cost of a step (`step_cost_ms`, a slow mean that one slow iteration moves by a few percent), plus the duty's rest.

While the machine keeps up with steps of a display frame of simulated time, the step is exactly that. Otherwise it is longer by a `stretch` that is the machine's alone: x100 on a machine managing 37 steps a second takes steps of about 3 s in place of 0.83 s.

The step changes only between iterations, and gradually:

- It moves half the way, in logarithm, to the stretch `R` asks for, and only when that stretch is more than `STRETCH_RAISE_BAND` above the current one or `STRETCH_LOWER_BAND` below it.
- Not before `WARMUP_ITERATIONS` iterations, and not again for `SETTLE_ITERATIONS`.
- A change restarts the pair the cost of a step is learned from and makes the next iteration a probe, because a step's cost can grow with its length (a small dish in water needs more diffusion rounds for a longer step).

### Steps per iteration

An iteration takes as many owed steps as fit `T_ITER_MS` at the measured cost of a step and `MAX_STEPS` (`GpuLayout.MAX_STEPS_PER_BATCH`). Owed time is capped, and a duty cycle backs off when frames run long.

`T_ITER_MS` bounds the steps' time alone. The fixed cost (the GPU wait, the pictures and answers recorded after the steps, the read-back, the tail) comes on top, so a pause or an edit waits at most that plus `T_ITER_MS`.

### Learning the cost of a step

An iteration takes `fixed_ms + k x step_ms`, learned apart. `step_ms` is the slope between an iteration and the one before it at another k. Until a slope is known it is an iteration's time over its steps, which charges the fixed cost to the steps and holds k at 1 whenever `T_ITER_MS` over that is 1.

- **Probe.** When no iteration of another k has come for `PROBE_EVERY` iterations, the next one is a probe: half the usual k or, at k = 1 or before a slope is known, up to what twice `T_ITER_MS` allows at the pessimistic cost and at least one step more. That is at most the fixed cost plus twice `T_ITER_MS`, or plus two steps where one step takes longer than `T_ITER_MS`. A probe never falls within the per-frame split.
- **A rising cost** (a dish filling) is taken at once. An iteration longer than `T_ITER_MS` whose steps took more than `GROWTH_TOLERANCE` times what the known cost predicts sets the cost to what they took, restarts the pair and leaves the fixed cost as it was. The next iteration is shorter, and a filling dish's iterations stay within about the fixed cost plus twice `T_ITER_MS`.

### Pictures within an iteration

An iteration that spans several display frames publishes the main dish's bups' picture after several of its steps (`SimThread._pictures_for`, `SimCore._record_shot`): one for each display frame the last iteration took (beginning to beginning), at most `GpuLayout.PICTURES_MOST` (6) and at most its steps, evenly spaced with the last step always among them. Only the last while the interface's frames run long (the duty under 1), because each picture shown costs the main device a build of the view. Haze, steer and the thumbnails come once an iteration.

Below `MAX_STEP`, a display frame owes `frame_steps` steps (its simulated time over the step, at least 1) and every iteration publishes one picture. After a late iteration the catch-up runs a frame's worth at a time, each with its own publish, while the simulation keeps up on its slow mean (`keeping_up`) and at most `SPLIT_OWED_MOST` frames' worth are owed; past that the owed steps merge into one iteration.

### Waiting for the next tick

With nothing owed, the sim thread waits for the next command. At one step a frame, with iterations that fill at least `SPIN_SHARE` (half) of the display's frame, it spins instead (`SimThread._wait_for_tick`, at most two frames after the last `set_time`). A thread that slept runs the next iteration's GPU wait slower (a one-step sync of about 4.3 ms against 3.0 at 100,000 bups, Apple Silicon, Metal) and the picture misses its frame. Spinning costs the same CPU as sleeping: about half a core either way (0.51 against 0.47-0.53).

## The pool

A dish takes a row of the `DISHP` and `DSTATE` tables (`GpuLayout.D_MAX`, 1024 rows), a 256-aligned segment of record slots, a 256-aligned block of field cells and its cloud-list squares.

### Buffers: growing and shrinking

`SimArena` holds the buffers by unit class.

**Growth.** A class grows by 1.5 when a batch would pass 90% of a buffer, never past the most that class can need: for record slots, the dishes' caps over the fill share; for the event ring, the births bound ([Room for births](#room-for-births)).

**Shrinking.** A class shrinks when it used under a quarter of its slots for a minute, never below room for the most it was asked for in that time (`asked`: room made ahead for a step's worst case is not shrunk and grown back). The event ring shrinks at the start of the next iteration, because an iteration's events are read after it.

**A dish that leaves the world** (`SimCore.remove_dish`: a freeze, a trash, a resize's old row) gives back at once. In the next pass, a quiet one included (so paused too), `SimCore._give_back` and `SimArena.give_back` shrink each class that holds more than 1.5 times what the running dishes need (`SimCore.room_needed`, the room an iteration is given) down to that. A class never goes under what the world still counts (the leaver's slots count until a step closes the gap, so they go the rest of the way after the next step) and never under the starting sizes.

**Counted in the budget.** The pictures' draw buffers and the textures made for the main device count against the memory budget: `SimArena.TEXTURES_SHARED` or `TEXTURES_HANDED`, by the path in use (the shared textures on the simulation's device, or on the byte path the read-back buffer and the main device's textures and staging buffers). A refused growth publishes no picture and shows as the stalled-memory banner (the timing's `refused_iteration`). The memory warning follows the need, not the bytes held ([Memory budget](#memory-budget)).

### Room for births

The room an iteration is given is the bound `SimCore.births_series` gives, from each dish's count and the sum of its bups' masses (word 12 of a STATS sample, `ST_MASS`; unknown after an edit, and then a bup is taken to divide every step).

The bound holds because a bup divides at most once a step and only with a mass of at least `division_mass_min` (2), and mass grows at most `growth_factor_max` a step (1.0147 at the longest step). The births of a step are at most min(its bups, its mass / 2). From 5,000 bups of mass 7 that is about 240,000 bups after 14 steps, where plain doubling would give 82 million.

`tests/births_bound_test.gd` computes the bound from the constants and checks the kernel text it rests on. A change to the growth or division rule must re-derive it.

### Cloud lists

A cloud that reaches several squares takes 25-56 entries of its dish's cloud lists. The entries (`ENT`, `ENTD`, 36 B each) are a class of their own:

- **Sizing.** The class starts at 12 entries a cloud slot and grows from the entries a cloud was measured to take. The room kernel leaves the peak and the density in `WD_ENTRIES_PEAK` and `WD_ENTRY_DENSITY`, taken from the entries every square would hold (`WD_ENTRIES_FULL`, summed whether a square is listed or not), so the room does not depend on which squares are listed. `SimArena.ensure_entries` asks for it with `SimCore.ENTRY_MARGIN` (1.25) of room.
- **Cuts.** The kernels cut a dish's lists at the real capacity (`WD_ENTRY_CAPACITY`) and at `ENTRIES_PER_CLOUD_MOST` (256) entries for a cloud of its quota. A cut still raises the overflow flag.
- **No reach, no list.** A cloud whose peak is under its cut, so that no bup can sense it or take from it, is in no list.

### Lists near bups only

When it pays, the lists cover only the squares near bups.

1. `pool_bin_mark` marks each bup's own square of a dish.
2. `pool_bin_wide_x` and `pool_bin_wide_y` widen the marks by the squares a bup can swim in a step (`SimCore._list_margin_um`: `0.25 v delta + 4 v sqrt(3 delta)` at the fastest speed a gene can reach).
3. The count and the scatter skip an unmarked square. A cut square still reads as empty, and the overflow flag still rises.

**A bup's read of an unlisted square** (`bin_list` false: a bup made or moved past the margin) takes its clouds from the cloud slots in index order, with the entry's test and values (`slot_entry`), and sums what the list would have given, byte for byte. `pool_bin_misses` counts these bups in `WD_FALLBACKS` (zero in the game's runs; a count since the world was made). It is a kernel of its own, not an `atomicAdd` in the reader, because on Metal a never-taken `atomicAdd` on `WORLD` in the reader changed the readers' results.

**A probe on an unlisted square** (far from every bup, or on a dish no step has listed yet) takes the same clouds but adds them in `pool_probe_slots`' tree order, so its answer can differ from the list's in the last bits. Probes are answers for the screen and take no part in the run.

**When the marks pay.** Only while a dish pool has few bups to a cloud and few squares to a cloud slot (`SimCore._marks_pay`: record slots under 2 a cloud slot, squares at most 100 a cloud slot, from the last read-back). Otherwise the step lists every square:

- `pool_bin_clear` writes the mark of every square, and the three marking passes and `pool_bin_misses` do not run.
- The readers (`pool_swim`, `pool_demand`, `pool_swim_demand`, `pool_apply`, `pool_apply_count`) run as their `_all` clones, made in `GpuKernels.all()` with `LISTED_ALL` defined, which have no code for an unlisted square.

The marking passes cost a pass over every square, and the reader's fallback code costs it a few percent where a bup always stands on a listed square. At 1.7M bups, or at 100 dishes of 10,000, that is more than the lists save (measured on Apple Silicon, Metal: 3.2 against 2.0 ms a step at 22,000 bups with the marks, 40 ms either way at 1.7M bups).

`SimCore.list_margin_override` is for checks only: -2 forces the unmarked mode. `tests/sim/near_lists_test.gd` compares dishes run with every square listed, only the bups' own squares, and the default.

### The nutrient picture and probes

The nutrient picture shows every cloud and reads no list. `pool_view_faint` adds every cloud that has a reach, with the mass it had when the lists were built, in fixed point, to the grid's concentration (`tests/sim/faint_view_test.gd`). The probes add the same back for an unlisted square.

`pool_probe_full` answers a probe on a listed square alone; `pool_probe_slots` takes an unlisted one, a workgroup of 64 threads to a probe that strides over the cloud slots and adds its partial sums in a fixed tree. One thread scanning every slot costs tens of ms a pass with millions of bups' clouds, and a dish no step has listed yet (one a pipette has just made) has every probe on an unlisted square while a paused world answers each move of the pointer.

## Memory budget

The pool is bounded by what the machine can give the GPU. The pieces:

| Piece | Role |
|---|---|
| `MachineMemory` (`scripts/sim/machine_memory.gd`) | The one meaning of the machine's physical and free memory on every platform (the engine's own figures differ by system). |
| `GpuMemory.query` (`native/src/gpu_memory.cpp`) | The card's own figures: DXGI on Windows, Vulkan's device-local heaps and `VK_EXT_memory_budget` on Linux, not known on macOS (the graphics memory is the system's there). |
| `PoolLimits` | The starting sizes, the ceiling (`budget_for`), `classify` (enough, low, below the minimum) and `warning_state`. |
| `MemoryWatch` (`scripts/sim/memory_watch.gd`) | Sets the working budget `memory_budget_bytes`. |
| `MemoryMode` (`scripts/memory_mode.gd`) | The game's low-memory mode. |

**The card's figures.** `MachineMemory.card_handles()` reads the driver handles `GpuMemory` needs on the main thread and passes them to every later read, so the sim thread can read the card too. Godot's Vulkan driver may not enable `VK_EXT_memory_budget`, in which case the budget and usage read as 0 and count as not given.

**The ceiling** (`PoolLimits.budget_for`):

- Shared graphics memory: 0.4 of the physical memory.
- A card with its own: `CARD_SHARE` (0.75) of the card's OS budget, else of its dedicated memory, never over 0.4 of the physical memory, and 2 GiB when the card's size could not be read.
- Never under 1 GiB, and with no upper cap.
- No single buffer may pass `SimArena.BUFFER_MOST`, 2 GiB: the largest resource Direct3D 12 documents, and under the 4 GiB - 1 of a Vulkan storage range and of a `RenderingDevice` buffer's 32-bit size. `SimArena.fits` refuses a growth that would pass it as it refuses one past the budget.

**The working budget.** `MemoryWatch` sets `memory_budget_bytes` every 5 s and before a growth. It is what the pool holds plus what it may still take: half the free system memory or, on a card that reports a live budget and usage, `CARD_SHARE` of the card's unused budget, between the floor and the ceiling. It falls at once and rises with hysteresis, and the arena shrinks sooner while the machine is short.

**The warning follows the need, not the bytes held.**

- `SimCore.need_bytes` is what the buffers and textures would take at the capacities the running dishes ask for (`SimArena.need_bytes`, `caps_for`: what is in use plus the room their next iteration asks for, with the `FILL` share).
- The timing's `memory_need_fraction` is its share of the budget, and `PoolLimits.warning_state` warns "near" at 0.9 of it. The banner therefore goes with a freeze and not with the shrink.
- A refused iteration is still "stalled". The held share, `memory_fraction`, is only in the debug log.

**Low-memory mode.** `MemoryMode` says whether the game is in low-memory mode: the machine is low or below the minimum, and nothing the player sets changes it. With no rendering device, or the stub backend, there is no pool to protect and the mode is off. The mode limits a dish to `PoolLimits.LOW_BUPS` (500,000 bups), `LOW_DISHES` (10 running dishes) and `LOW_GRID` (200 cells across); a loaded or thawed dish over a limit runs as it is and cannot be raised.

**What the player sees.** A notice after the start (after the tutorial) says when the machine is below the minimum or the mode is on (`MemoryNoticeDialog` in `scenes/main.tscn`, once a run for each text). A refused growth shows `banner.memory_budget`.

**Tests and tools.** `PoolLimits.new()` keeps a fixed 6 GiB for tests. `tools/gpu/mem_check.gd` probes all of this on any machine.

## Dishes

### Dishes in the game

`main.gd` keeps `dishes` (every running `Dish`, children of Main) and `dish`, the one in the main view. `add_dish(start)` joins one; `set_main_dish(d)` brings it into view (graph, watch list, layers and camera follow it; a selection or lineage open on the old one is closed).

**The view moves by itself only** when the dish in view goes (frozen, trashed, died out) and to a dish that dies out (and back once play resumes). A late answer never moves it off a dish the player chose; a pipette's answer follows the bups only if the player is still on the dish it was made in.

**Numbers and rows.** `Dish.number` is the world's number and is never reused within a world, but a new game's screen or the menu's backdrop may get the same number in the same row as the dish that left it. A dish therefore also knows the row's epoch (`WorldClient.epoch_of`, a count that grows each time a row is handed out, carried by the commands that fill a row and by every `DishState` and `PayloadInfo`). `Dish.is_mine` and the view's `_take` accept a state or a picture only if its number and epoch are the dish's own, so what a pipeline still holds of a dish that left the row is never shown by the dish that took it (`tests/sim/leave_game_test.gd`). The number the player sees (`_take_label`, 1 to 999, then the lowest free among running and frozen dishes) is a label that a thaw keeps.

**The dish strip** (`ui/dish_strip.gd`, `DishStrip`) shows each running dish's tile of the thumbnails' atlas (`ThumbAtlas`, `DishThumb`, written once a second by the simulation) and is hidden with one dish.

**Dishes not in view** keep their history from the snapshots they are handed. Each holds at most `Dish.BACKLOG_MAX` samples waiting to be recorded; more are thinned between the oldest and the newest and the gaps filled when the samples are taken, so its graph keeps its time span. `Main._record_parked_history` records them inside a time allowance each frame.

**A dish's plankton and sources** reach it as a `DishWorldCopy`, made when its world changed in an iteration. The plankton array is the `DishWorld`'s own, shared and never changed in place; each plankton is an immutable entry whose `id` stays with it while it floats. `Dish` keeps only the newest copy (`_hold_world`) and unpacks it into `Plankton` and `NutrientSource` objects, kept by id so a pick survives, when `plankton` or `sources` is read. A dish that is not drawn, or whose layers are hidden, costs no unpacking however many plankton float (about 2,000 on a 90 mm dish at bloom 2, a few ms to unpack).

**Extinction.** A dish that dies out pauses the game on it (`_on_dish_extinct`); resuming deletes it (`_retire_extinct`) unless it is the last running one. When the last running dish dies out, the game ends (`_game_over`, `EndDialog`) if the freezer is empty, and otherwise stays empty until a dish is unfrozen.

A freeze reads the dish whole on the simulation thread and takes it out of the world at once; its reply (the `DishBlob` with the dish's part of the family tree) comes from the lineage worker, which exports and releases the dish's lineage in order with the events before it, so with that worker behind it comes late. The screen does not wait for it, and a trash or the end of the game puts `discard_frozen` in the same queue after it. The other dishes, the snapshots, a pipette's answer and an unfrozen dish's showing do not wait for it either ([Results and the family tree](#results-and-the-family-tree)); only the family tree runs behind meanwhile.

Goal mode stays single (the pipette is locked there). Freezing and thawing: [interface.md](interface.md#the-freezer). Tests and tools: `tests/dishes_test.gd`, `tools/gpu/dishes_check.gd`, `tools/gpu/dishes_perf.gd`.

### The pipette

`Dish.pipette(world_pos, radius)` asks the simulation for a retarget: a zero-step iteration that moves the bups in the circle to a new row, with the same ids (`SimCore.pipette`, kernels `pool_pip_*`). The new dish's grid is made ahead on the worker pool.

- The waiting pipette keeps its source dish's number and is refused if that dish has left its row by the time the grid is ready, because a freed row is given out again at once (`tests/sim/pipette_row_reuse_test.gd`).
- `Main._finish_pipette` adopts the new `Dish` (`adopt`) and then asks Keep, Freeze or Trash about the old one (`_ask_about_old_dish`).
- The family tree stays in `LineageStore` under the same ids; the lineage worker gives the moved bups their new home (`retarget_ids`), which the reply's `lineage` ticket tells (`WorldClient.moved`).

The watch list is one for all dishes (`WatchList.dishes`), the layer buttons are one choice for every dish, and each dish keeps the zoom and position the camera had when it was last looked at (`Dish.view_zoom`). With the timer on (`tool_options.pipette_timer_changed`), the game pauses every so many simulated hours until a pipette moves bups (`Toolbar.resume_locked`).

### Husks

`Dish.plankton_husks` and `Dish.death_husks` (`StartConditions`, advanced options) make a dying plankton or bup leave a husk instead of a cloud (`pool_husk_*` kernels, a husk buffer in the pool, `Biology.HUSK_SECONDS`).

**In the interface.** Husks have a layer (`Layer.HUSKS`, default key M) and a mode of the select tool, both there only while the dish in view can have husks (`Dish.has_husks`; `LayersPanel.sync_from`, `ToolOptions.set_husks_available`). The select tool's Husks mode (and Inspect all) finds a husk by its place, because a husk has no id (`SimCore.husk_near`, `Dish.husk_at`, `husk_details`).

**The husk list is read at most once a hundred milliseconds, while the layer is shown.** `pool_husk_view` packs every live husk of the dish as a 2D MultiMesh transform (8 floats) into the husk cull's scratch buffer and counts them. When the list is due (`ViewRequest.want_husks`, set by `SimThread._view_request`), the kernel runs in the iteration's own list after the steps and the pictures, and the count and list come back in the iteration's one read-back (`SimCore.run`'s `husk_list`), with no submit or wait of its own. `SimCore.husk_view` reads it alone for tests and tools.

A list of its own, downloaded asynchronously ahead of the next iteration, makes the interface's frames irregular: at 999 dishes in water with husks and a step's diffusion rounds in one submit, frame p95 was about 16 ms against about 12.8 with the read in the iteration's list (measured on Apple Silicon, Metal). The read alone costs about 1.5 ms for 200,000 husks (same set-up) and is bound by the bytes moved, not by the kernel.

## Pictures: from the simulation to the screen

The simulation publishes the bups' payload, haze, steer and the thumbnails (`SimCore.publish`). The main device takes them (`ViewRenderer`, `scripts/sim/view_renderer.gd`), runs the `view_*` kernels, draws the bups into a MultiMesh and answers picks.

### Handover: shared textures or bytes

How the main device takes a publish depends on the driver (`ViewRenderer.cpu_handover()`).

| Path | Drivers | How it works |
|---|---|---|
| Shared textures | Metal, Direct3D 12 | Every `RenderingDevice` shares the system's device: the simulation shares textures and the main device imports them. |
| Byte path | Vulkan | Each local `RenderingDevice` is a `VkDevice` of its own, so a native handle means nothing on the main device. The simulation reads back only the bytes in use and the main device puts them into textures it owns (`hand_over_picture`, no `take_bound` bookkeeping). |

`ViewRenderer.force_cpu_handover`, or the user argument `--cpu-handover`, takes the byte path on any driver, so it can be tested on Metal.

On the byte path (`SimCore._publish_parts`) the read-back is the payload and its places before (as far as the dish is expected to reach), the pictures' pixels and the atlas's rows of tiles in use. Each part is requested with `buffer_get_data_async` before the iteration's submit, and the one sync completes them with no intermediate host copy. A dish past the expected count has the rest of its payload read after, with a wait. The payload and places before reach the main device through two buffers and `pool_copy_handed`.

### Publishing in the iteration's list

The pictures are recorded in the iteration's list after its steps (`SimCore._publish_record`), so they cost no wait of their own. A bups' picture before the last (`SimCore._record_shot`) follows the step it comes after. Each is a publish of its own, with its own number and simulated time and its own shared texture or, on the byte path, its own slot of PAYLOAD, IDTEX and PREVXY (`SimArena.picture_slots`). The slots also keep the previous picture's slot, its count (written by `pool_payload` into PICN) and its tracked bups (a TR set of its own, `GpuLayout.TRACK_SETS`).

Buffers and textures are made before the list, for the count the dish is expected to reach (`SimCore._expected_count`: its count, its last births a step with a quarter more, a sixteenth of its count and a row of texels). The payload kernels run over the count the card holds and write no further than the buffers hold. A dish that outgrew them in the steps is not drawn that time; the next publish is made for its count.

**Ids do not cross.** The simulation keeps the ids of its last `SimCore.ID_RING` publishes on its own device. A pick or hover answer carries the bup's index and the publish it was asked on, and `DishDrawing` asks `WorldClient.ids_at` (`SimCore.ids_at`) for that bup's id, so an id arrives a few frames after the pointer rests on a bup.

**The payload is not packed:** x and y are full floats in the picks, the density, the instances and the places before.

### Skipping pictures that are current

A pass of no steps makes only the pictures that are out of date. Each kind (bups', field's, husks', thumbnails') remembers the key of what its newest one was made of (`SimThread._current`): the view's dish and epoch, `SimCore.version` (raised by every change to what a picture shows), whether edits wait, and for the field how it is drawn. A key that still holds is not made again.

So an answer, a pointer moving over a paused dish, or a camera that only moved (a `ViewRequest` without a changed want) costs the answers and nothing of the pictures, however many bups the dish has (`SimThread._take_view`, `_view_request`). A paced picture that is out of date wakes the thread when its pace has passed (`_owed_msec`). The bups' picture is made again when the screen let go of what it held (`ViewRequest.fresh`) and when a bup the screen holds (selected or pointed: the question's `"pinned"` ids) has no place in the newest picture.

### Between pictures

Every bup is drawn part of the way from its place in the picture before to its place in the picture shown, so a crowd whose pictures are held several frames (about 19 new pictures a second at 2 million bups) moves on every frame, about one picture behind the newest.

**Where the place before comes from.** The simulation provides it on either path. `pool_payload` looks each bup up by id in the last bup picture made, still in its slot of IDTEX and PAYLOAD. The pictures take the slots in turn (`SimCore._picture_slots`), so a picture never writes the one before it; SLOTHEAD says which dish and how many texels each slot holds.

- The search starts from the bup's own texel (a bup that was in it was there or further on: those still here come first, in order), gallops to its id and halves the last stretch.
- It works because a dish's bups lie in rising id order. Compaction keeps the survivors' order and puts the newborns, whose ids are past every older one, after them; a pipette into a new dish and a thaw keep the order (`tests/sim/places_before_test.gd`).
- The place found goes into PREVXY. A bup in no picture before (a newborn, or the first picture of a dish: SLOTHEAD is cleared when the dish is not the last picture's, `SimCore._pic_dish`) gets its place in this picture. A bup out of order (only a pipette into a dish that has bups of its own, which the game does not do) is not found and is drawn without moving for that picture.

**A picture made with no step since the last** (an edit, a question, the view asked again: `SimCore._moved_since_pic`) shows the bups where they were. Each found bup takes that picture's place before instead, and the playout puts a publish at the same simulated time as the newest in that one's place, so the motion does not stop.

**The ids texture** (RGBA32UI) carries each bup's id and place before (`GpuLayout.IDS_*`). On the byte path the places before are handed over with the payload (8 bytes a bup) and `pool_copy_handed` writes them into the main device's own ids texture, which holds no ids. A tracked bup's answer in a picture (`pool_track_picture`) carries its place before in `R_PX` and `R_PY`, and `PayloadInfo.places_before` holds them.

**The share of the way** comes from the playout (`WorldClient.shown_share`: where its clock is between the picture before's simulated time and the shown one's; 1 while paused). `DishDrawing.share` gives it to the view (`ViewRenderer.draw_frame`), whose kernels draw, pick and look up every bup there (`GpuKernelsView.place_at`). The rings and the camera's follow take the same place (`DishDrawing.view_ring`), so a followed bup stays in the middle. A frame between pictures builds the view again (the instances, and the density picture when on); a held picture builds nothing.

Tests: `tests/sim/between_pictures_test.gd` (paced as on a 60 Hz display) and `tests/sim/slide_test.gd` (at the played settings, 2 million bups at x10,000 with 20 s steps: drawing does not stall or jump, the density picture and the capsules change on every frame between two pictures, and the bups whose place before differs from their place are the ones that moved).

### Playout

The display plays the publishes out on a clock of simulated time of its own (`WorldClient.Playout`). The picture shown is the first at or past the clock.

- The clock runs at the pace the publishes arrive at: their smoothed simulated span over the smoothed real time between arrivals.
- At each arrival it is trimmed toward a lead of `LEAD_SPANS` (2) arrivals' worth of simulated time behind the newest, and never more than `WAITING_MOST` - 1 publishes. An arrival up to about twice the usual time apart is met by the lead, so the bups move at an even speed instead of stopping at each picture. An iteration's burst of pictures is spread over the time to the next.
- That lead is the display's lag behind the simulation: about 170 ms, 1.5 pictures, at 2 million bups at x10,000 on Apple Silicon, Metal (`WorldClient.lag`).
- It keeps at most `WorldClient.WAITING_MOST` (`PICTURES_MOST` + 2) waiting past the one shown, brings a clock left `SNAP_SPANS` arrivals' worth behind up to the lead, and drops the publishes of a dish that left the main view.

`tests/playout_test.gd` covers it.

### Texture rings

- **Shared-texture path:** `SimCore.PAYLOAD_TEXTURES` (`WAITING_MOST` + 8) is the ring of payload and id textures. The main side holds at most `WAITING_MOST` + 6, so an iteration's last picture always finds one; with fewer free than it asks, an iteration publishes fewer pictures before its last. Haze, steer and the thumbnails have `SimCore.TEXTURES` (10) each.
- **Byte path:** the ids ring is `SimCore.ID_RING` (`WAITING_MOST` + `PICTURES_MOST` + 6) payloads.

### Density view

A bup shorter on screen than `Cell.MIN_VISIBLE_LENGTH_PX` is not a capsule. Those bups are one picture in which each texel takes the colour of one bup that covers it (the winner, never a mean, so a crowd keeps the bups' own colours). The `view_*` density kernels build it (`ViewRenderer.set_density`, turned on by `DishDrawing._ensure_view`) and `DishDrawing.density_sprite` shows it under the capsules once it has been built for the dish in view. A bup at or over that length is a capsule, and if the density kernels do not build, every bup is a capsule.

`tests/sim/winner_view_test.gd` checks it; `tools/gpu/den_shots.gd` shoots both drawings side by side.

## Biology in the kernels

The model is the kernels (`gpu/kernels_life.gd` and its neighbours); the constants it uses are in `scripts/biology.gd` and `Genome`.

### Death returns nutrient

A bup that starves or dies by chance returns `Biology.DEATH_RELEASE` of its body (mass at `COST_PER_MASS`) as a cloud where it died (`pool_death_clouds`, `pool_death_count`). One displaced at its dish's limit (the trim) or removed by an edit returns nothing. With `death_husks` a death leaves a husk instead and makes no cloud.

### Starvation

`Dish.stationary_phase` (`StartConditions.stationary_phase`, an advanced option in free mode; the `DPF_STATIONARY` flag of the dish) changes what happens to a bup whose reserve is at `MAINTENANCE_FLOOR`.

- It stops growing and pays `Biology.STARVE_MAINTENANCE` from its reserve and then from its mass, so it shrinks.
- It dies at a constant rate that grows with its metabolism gene (`Biology.STARVE_DEATH_RATE`, `STARVE_DEATH_GROWTH_HOURS`), or when it has shrunk to `STARVE_MIN_MASS_SHARE` of its birth mass.
- Without the option, a bup dies when the reserve is gone instead.

The code is the end of `pool_life`.

### Conjugation

A bup's record word 14 is its donor flag (0 or 1; the drag cost is worked out from the speed gene). A donor (`Genome.DONOR_*`, `CONJ_*`) copies a run of its genes into a non-donor it touches.

The kernels `pool_conj_clear`, `pool_conj_count`, `pool_conj_scan`, `pool_conj_scatter` and `pool_conj_apply` run before `pool_life`. They keep a hashed table of donors by 20 µm cell for each dish; each recipient looks at the cells as far round it as the largest donor could touch it, and changes only itself. `tests/sim/conjugation_isolation_test.gd` checks that dishes do not touch.

### Raised ceilings

A bup's record word 12 is its `reach`: two bits a gene, speed the lowest, counting how many times that gene's ceiling has been raised (`Genome.REACH_*`). It is not the bup's food yield, which is `exp(-harm) / sqrt(metabolism)` worked out where it is read. A raise multiplies the gene's `gene_max` in the mutation clamp (in `pool_life`), costs growth, and travels with the genes in a conjugation.

### Acetate: the second food

A bup that takes in more than its growth can use lets go of acetate besides (`Biology.ACETATE_*`: threshold-linear in the growth rate its intake could sustain, its own gain not reduced). A bup with room in its reserve takes acetate up from the cell it is in, at up to 0.45 of its glucose rate and less while there is glucose.

Acetate is a second field in the pool: the main field's grid and medium, no clouds, diffused with it (`DPF_ACETATE`). The kernels are `pool_ac_cells` and `pool_ac_apply`, `pool_diffuse2_a` and `pool_diffuse2_b`, and the fused `pool_ac_conj_life`.

Not modelled: inhibition by acetate (not significant at neutral pH), the glucose of clouds in the repression, and a view of acetate in the game.

### The acetate key

`Genome.key_level(reach)` reads bits 8-9 of the `reach` word: 0 none, 1 potentiated, 2 the key. The gene-ceiling code reads only the low eight bits. A division potentiates a level-0 line at `KEY_POTENTIATION_RATE`, and a level-1 line makes the key at `KEY_RATE`. The key multiplies acetate uptake by `KEY_FACTOR` and costs `KEY_COST` of growth. The stats pass sums it as a ninth value (`key`, a graph series).

### Divisions and generation

A bup has `divisions` (record word 20), the divisions in its line. A division adds one to the parent, lethal daughter or not, and the daughter starts at the parent's new count, because both products of a fission are one step further on. A bup has no generation of its own.

The population's `generation` is the mean `divisions` of the bups alive in the dish (the stats pass's tenth sum), as the LTEE counts generations per population. A pipette keeps the bups' counts, so the new dish carries on the count of its source.

### Limits

A dish's bups are held at `DP_LIMIT` with a hard cap `DP_CAP`. The trim expects the step's growth plus a margin of `CAP_SIGMAS` standard deviations, so the count stops a little short of the limit and is over it in a small share of frames (`tests/sim/cap_test.gd`).

### Medium and grid

A dish's medium is an advanced option (`StartConditions.medium_thickness`, water or thicker). A thicker medium makes plankton clouds last longer so they can be climbed; that is a stopgap for playability, not a realism choice.

The nutrient grid has cells 2R/100 across (R the dish radius), so a big dish keeps plankton as sub-grid Gaussian "clouds" until they have spread to about a cell.

## The nutrient field

The field pass is fused. `pool_fdiff` (`gpu/kernels_field.gd`) does the feed and the diffusion of glucose and acetate in 16x16 shared-memory tiles with a halo of 3, in rounds of at most 3 iterations. The count of rounds is odd, so the result always lands in `EFF` and `CONC2B`. The fixed `TILES` buffer, built by `SimCore._sync_tiles`, lists the tiles with the dishes that need the most rounds first.

- `pool_dep_land` copies `EFF` to `CONC` with the deposits added. `pool_clear` is out of the step (`pool_cells` zeroes the owner cells' sums).
- `pool_apply`, `pool_apply_count` and `pool_ac_cells` read the acetate from `CONC2B`; `pool_ac_cells` writes `CONC2`.
- The arithmetic and its order are the unfused pass's, so the goldens hold byte for byte. `SimCore.lone_field` runs the unfused path (`pool_feed`, `pool_diffuse_*`, `pool_dep_apply`, `pool_clear`, `pool_land_copy`) for `tools/gpu/fused_check.gd`.
- Field traffic is about 74 B a cell a step at 2 iterations.
- Per-kernel profiles of small dispatches are unreliable here: compare paths by interleaved wall-time batches.

**Splitting the rounds into submits.** The iterations are D x the step / (a cell's width)^2, so a 300 µm dish in water at 20 s steps runs 129 rounds. Many such dishes give a step of a hundred milliseconds or more of rounds (999 such dishes: about 140 ms), and one submit that long leaves the interface's frames late. `SimCore._record_step` therefore splits the rounds into submits of at most `FIELD_SUBMIT_MS` (4 ms, under half a display frame at 120 Hz), judging by the time a round's tile took in the field's own earlier submits, so the frames get the card between them.

At 999 such dishes this gave a frame p95 of 8.7 ms against 12.7 in one submit, at 2-3% of the speed (measured on Apple Silicon, Metal). A step whose rounds take under 4 ms in all is never split; that includes any dish of about 9 mm or more in water at 100 cells across, which runs one round.

## Changing the simulation

### The kernels

Every kernel is GLSL text with its buffer list, written by concern together with its registration:

| File (`gpu/`) | Kernels |
|---|---|
| `kernels_field.gd` | The nutrient field: feed, diffusion of nutrient and acetate, swimming, the bups' demand on cells and clouds, the cells' shares, what each bup takes and lets go. |
| `kernels_life.gd` | Bup lives: conjugation, division, death and mutation, the scans that place kept bups and newborns, the trim at the limit. |
| `kernels_clouds.gd` | Plankton clouds: the clouds and deposits a dish's world sends, spreading, going to the grid, lists by place, slot compaction, clouds of the dead. |
| `kernels_husks.gd` | Husks: what a death or a plankton leaves, and the slow leak. |
| `kernels_game.gd` | The game's side: family events, stats, questions and answers, the eraser, the field's copy. |
| `kernels_draw.gd` | The kernels that write the bups' MultiMesh on the GPU. |
| `kernels_core.gd` | Host operations of `SimCore`: clearing a row, edits, ids, copies into the shared textures. |
| `kernels_view.gd` | The `view_*` kernels of the main device. |

Each file has a `register(out)`. `gpu/kernels.gd` (`GpuKernels`) is how a kernel is made (`add`, the buffer types, the shared header and functions, the scans), and `GpuKernels.all()` gives them all. `tools/gen_gpu_shaders.gd` writes `gpu/shaders/<kernel>.glsl` from them. `gpu/shader_set.gd` (`ShaderSet`) loads the imported shaders, or compiles the text from `GpuKernels.all()` at run time for tools.

The game runs the `pool_*` kernels (and `ev_deposits`, and `view_*` on the main device). The GLSL text of a kernel that is not registered (`K_LIFE`, `K_EVENTS`, `K_STATS1`, `K_SWIM`...) is the template the pooled kernels are made from (`GpuKernelsLife.swapped`, `pool_life_slot`). The motion table's hash of `K_SWIM` therefore covers text the game runs only through `pool_swim`.

After editing a kernel, regenerate the shaders and import ([Generated files](../AGENTS.md#generated-files)). The importer reports success even when a shader fails to compile; `tests/gpu_shaders_test.gd` reads the errors and fails on stale files.

### Layouts

Every word of the bup record (28 words, 112 bytes, the 64-bit id as two uint words, 0 and 21; words 24-27 are the chemotaxis memory), the family events, the `DISHP` and `DSTATE` rows, `WORLD`, and every slot of P is named once in `gpu/gpu_layout.gd` (`GpuLayout`). A slot of P has a kind:

| Kind | Meaning |
|---|---|
| `const` | From `SimConstants.build()` (`scripts/sim_constants.gd`), set at the load. |
| `array` | An array. |
| `dish` | Set for each dish. |
| `batch` | Set for each iteration. |

`GpuKernels.add` declares the names a kernel uses at its top, so the GLSL and the host code read names, never numbers. A new record word, counter or slot goes in `GpuLayout`. Records move through the integer views, never as floats (`scripts/sim/record_codec.gd` is the host's codec). `tests/sim_layout_test.gd` (headless) checks the table.

### A dispatch runs whole workgroups

A kernel dispatched for fewer threads than its `local_size_x` (one thread runs a group of 64 invocations) must bound its index. A single-thread kernel begins with `if (gl_GlobalInvocationID.x != 0u) return;`; the others return past their count. Without it a second SIMD group sometimes applied an update again under GPU load: deposits and clouds doubled, and the step counter and next id advanced twice.

### The main RenderingDevice

The game's views run on it (the simulation runs on its own local device).

- Every call goes through `RenderingServer.call_on_render_thread`.
- Never `submit()` or `sync()`: the frame submits.
- Results come back with `buffer_get_data_async` a few frames later. The stalling `buffer_get_data` is only for where a stall is meant: a save.
- Every `buffer_update` of a batch comes before its `compute_list_begin`, because the device refuses updates while a compute list is open.
- Never set `multimesh.buffer` or a per-instance setter on the GPU-drawn MultiMesh: a CPU copy would overwrite the GPU's.

### Constants and the motion table

A new constant in `SimConstants.build()` that the GPU reads is a `const` slot of `GpuLayout`, filled by name ([Layouts](#layouts)), and must be classified for the motion table (`MOTION_INPUTS` or `OTHER_CONSTANTS`; [build-and-release.md](build-and-release.md#the-motion-table)).

## Measured and not built

**Dispatching by the live count** (measured on one-dish kernels, M1 Pro). The kernels ran over every slot, each returning past the count, at about 0.1 ms a step per 100,000 empty slots. An indirect dispatch (`compute_list_dispatch_indirect`) does not see a kernel's write made earlier in the same submit, but does see a `buffer_copy` between two lists. A copy per step needs a new compute list per step, which cost 60-85 µs a step: the net was zero at a 106,000 limit and a loss at a full dish. The pooled kernels have not been measured this way.

## Where the code lives

| Class | File | Role |
|---|---|---|
| `SimService` | `scripts/sim/sim_service.gd` | Autoload; makes the backend. |
| `WorldClient` | `scripts/sim/world_client.gd` | The main thread's only way to the simulation: commands, answers, snapshots, `Playout`. |
| `SimBackend`, `GpuSimBackend`, `CpuSimBackend` | `scripts/sim/` | The seam, the GPU backend, the stub. |
| `SimThread` | `scripts/sim/` | The loop of the sim thread. |
| `Governor` | `scripts/sim/governor.gd` | Time into steps. |
| `SimCore` | `scripts/sim/sim_core.gd` | Synchronous, threadless: records and runs iterations, answers, publishes. |
| `SimArena` | `scripts/sim/` | The pool's buffers and textures. |
| `DishWorld` | `scripts/sim/dish_world.gd` | A dish's plankton, bloom, sources and emitters on the host. |
| `ResultWorker` | `scripts/sim/` | Stats, snapshots, the replies in order with them. |
| `LineageWorker` | `scripts/sim/` | The family tree's thread: family events and lineage steps into `LineageStore`. |
| `ViewRenderer` | `scripts/sim/view_renderer.gd` | The main device's side of the pictures. |
| `PoolLimits`, `MachineMemory`, `MemoryWatch` | `scripts/sim/` | The memory budget. |
| `MemoryMode` | `scripts/memory_mode.gd` | The game's low-memory mode. |
| `LineageStore`, `GpuMemory` | `native/src/` | The only C++. |
| `GpuLayout`, `GpuKernels`, `ShaderSet` | `gpu/` | Layouts, kernel construction, the shader set. |
