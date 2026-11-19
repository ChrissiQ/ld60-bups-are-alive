class_name MemoryMode
extends RefCounted
## Low-memory mode as the game's screens see it: whether it is on, and what it limits (`PoolLimits.LOW_*`). It follows what the machine reported when
## the game started: it is on when the machine is not classed enough (`PoolLimits.classify`), and the player does not choose it. A dish that is
## already over a limit (a saved one or one thawed) runs as it is and cannot be given more: the ranges offered for it end at what it has.

## What the machine reported at start. Null until read; the simulation's start sets it to what it read itself (`SimService`), and the tests set a
## made-up machine here.
static var machine: MachineMemory = null

## The text of the start notices last shown, so the same ones are not shown again for the next game in the same run.
static var last_notice := ""


## The machine's report (read now when nothing has set it).
static func report() -> MachineMemory:
	if machine == null:
		machine = MachineMemory.read(RenderingServer.get_video_adapter_type(), MachineMemory.card_handles())
	return machine


static func is_low() -> bool:
	return PoolLimits.is_low_memory(report())


## Whether the machine itself is below the least the game is made for (what the first notice is about).
static func is_below() -> bool:
	return PoolLimits.classify(report()) == PoolLimits.MACHINE_BELOW


## The most a dish's bup limit may be set to: `held` is what the dish has now (it keeps what it has).
static func max_bup_limit(held := 0) -> int:
	if not is_low():
		return StartConditions.MAX_BUP_LIMIT
	return maxi(PoolLimits.LOW_BUPS, mini(held, StartConditions.MAX_BUP_LIMIT))


## The most cells across a dish's nutrient grid it may be given.
static func max_resolution() -> int:
	return StartConditions.MAX_NUTRIENT_RESOLUTION if not is_low() else PoolLimits.LOW_GRID


## The most dishes that run at once (the world's own rows when low-memory mode is off: the screen's dish numbers end sooner).
static func max_dishes() -> int:
	return GpuLayout.D_MAX if not is_low() else PoolLimits.LOW_DISHES


## The notice for a machine below the least: what it has free (or, when it is the installed memory that is short, what it has) and what the game
## needs, in GB.
static func below_text() -> String:
	var m := report()
	if m.available > 0 and m.available < PoolLimits.MIN_FREE:
		return Strings.t("banner.memory_below", [gb_text(m.available), gb_text(PoolLimits.MIN_FREE)])
	return Strings.t("banner.memory_below_installed", [gb_text(m.physical), gb_text(PoolLimits.MIN_PHYSICAL)])


## The notice that says what low-memory mode limits.
static func low_text() -> String:
	return Strings.t("banner.memory_low", [UiText.thousands(PoolLimits.LOW_BUPS), str(PoolLimits.LOW_DISHES), "%d x %d" % [PoolLimits.LOW_GRID, PoolLimits.LOW_GRID]])


## The notices to show after the game starts, in order.
static func start_notices() -> Array[String]:
	var out: Array[String] = []
	if not is_low():
		return out
	if is_below():
		out.append(below_text())
	out.append(low_text())
	return out


## A size in GB, one decimal at most ("3 GB", "0.5 GB", "7.8 GB").
static func gb_text(bytes: int) -> String:
	var text := String.num(snappedf(float(bytes) / float(PoolLimits.GIB), 0.1), 1)
	return Strings.t("ui.gigabytes", [text.trim_suffix(".0")])
