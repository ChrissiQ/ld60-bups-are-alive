#!/usr/bin/env python3
"""Reads the SAMPLE/REACHED lines of tools/gpu/validate_dynamics.gd and compares CPU with GPU per scenario:
mean over seeds and the standard error of the mean, at chosen hours, with the difference in standard errors."""
import sys, math, collections

rows = collections.defaultdict(dict)  # (mode, scenario) -> seed -> {hour: values}
reached = collections.defaultdict(dict)
for line in open(sys.argv[1]):
    f = line.split()
    if not f:
        continue
    if f[0] == "REACHED":
        reached[(f[1], f[2])][int(f[3])] = float(f[4])
    elif f[0] == "SAMPLE":
        mode, sc, seed, hour = f[1], f[2], int(f[3]), float(f[4])
        vals = [float(x) for x in f[5:]]
        rows[(mode, sc)].setdefault(seed, {})[hour] = vals

names = ["pop", "speed", "sense", "metab", "size", "harm", "energy", "nutrient"]

def stats(xs):
    n = len(xs)
    m = sum(xs) / n
    sd = math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1)) if n > 1 else 0.0
    return m, sd / math.sqrt(n) if n > 1 else 0.0, n

for sc in sorted({k[1] for k in rows} | {k[1] for k in reached}):
    print("=== scenario", sc)
    if (("cpu", sc) in reached) and (("gpu", sc) in reached):
        c = list(reached[("cpu", sc)].values()); g = list(reached[("gpu", sc)].values())
        mc, ec, nc = stats(c); mg, eg, ng = stats(g)
        print("  hours to 1,000 bups: CPU %.2f +- %.2f (n=%d) | GPU %.2f +- %.2f (n=%d) | diff %.2f h = %.1f s.e." % (mc, ec, nc, mg, eg, ng, mg - mc, (mg - mc) / math.hypot(ec, eg)))
    cpu = rows.get(("cpu", sc)); gpu = rows.get(("gpu", sc))
    if not cpu or not gpu:
        continue
    hours = sorted(set.intersection(*[set(v) for v in list(cpu.values()) + list(gpu.values())]))
    if not hours:
        continue
    pick = sorted({hours[0], hours[len(hours) // 4], hours[len(hours) // 2], hours[3 * len(hours) // 4], hours[-1]})
    for h in pick:
        print("  hour %g (n = %d CPU, %d GPU seeds)" % (h, len(cpu), len(gpu)))
        for k, name in enumerate(names):
            c = [v[h][k] for v in cpu.values()]; g = [v[h][k] for v in gpu.values()]
            mc, ec, _ = stats(c); mg, eg, _ = stats(g)
            z = (mg - mc) / math.hypot(ec, eg) if math.hypot(ec, eg) > 0 else 0.0
            rel = (mg - mc) / mc * 100 if mc else 0.0
            print("    %-8s CPU %12.4f +- %9.4f | GPU %12.4f +- %9.4f | diff %+7.2f%%  (%+.1f s.e.)" % (name, mc, ec, mg, eg, rel, z))
