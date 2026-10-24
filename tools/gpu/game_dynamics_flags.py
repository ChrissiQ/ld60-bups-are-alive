#!/usr/bin/env python3
"""Every hour and quantity where the GPU's mean differs from the CPU's by more than a threshold (default 2 s.e.), from the SAMPLE lines
of tools/gpu/game_dynamics.gd (or validate_dynamics.gd): python3 game_dynamics_flags.py file [threshold] [cap].
With `cap` (the scenario's bup limit), a population flag where the CPU holds exactly the cap with zero s.e. and the GPU is above it is
listed apart as the soft-limit artefact."""
import sys, math, collections

rows = collections.defaultdict(dict)
for line in open(sys.argv[1]):
    f = line.split()
    if f and f[0] == "SAMPLE":
        rows[(f[1], f[2])].setdefault(int(f[3]), {})[float(f[4])] = [float(x) for x in f[5:]]
thr = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
cap = float(sys.argv[3]) if len(sys.argv) > 3 else None
names = ["pop", "speed", "sense", "metab", "size", "harm", "energy", "nutrient"]

def stats(xs):
    n = len(xs); m = sum(xs) / n
    sd = math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1)) if n > 1 else 0.0
    return m, sd / math.sqrt(n) if n > 1 else 0.0

for sc in sorted({k[1] for k in rows}):
    cpu = rows.get(("cpu", sc)); gpu = rows.get(("gpu", sc))
    if not cpu or not gpu:
        continue
    hours = sorted(set.intersection(*[set(v) for v in list(cpu.values()) + list(gpu.values())]))
    flags = []; soft = []
    worst = {n: (0.0, 0) for n in names}
    for h in hours:
        for k, name in enumerate(names):
            c = [v[h][k] for v in cpu.values()]; g = [v[h][k] for v in gpu.values()]
            mc, ec = stats(c); mg, eg = stats(g)
            d = math.hypot(ec, eg)
            z = (mg - mc) / d if d > 0 else (0.0 if mg == mc else float("inf"))
            if abs(z) > abs(worst[name][0]):
                worst[name] = (z, h)
            if abs(z) > thr:
                item = (h, name, mg - mc, (mg - mc) / mc * 100 if mc else 0.0, mc, ec, mg, eg, z)
                (soft if name == "pop" and cap and ec == 0 and mc >= cap - 0.5 and mg > mc else flags).append(item)
    print("=== scenario %s: %d CPU seeds, %d GPU seeds, %d hours; flags above %.1f s.e.: %d (soft-limit artefact: %d)" % (sc, len(cpu), len(gpu), len(hours), thr, len(flags), len(soft)))
    for lst, label in ((flags, "FLAG"), (soft, "SOFT")):
        for h, name, d, rel, mc, ec, mg, eg, z in lst:
            print("  %s hour %g %-8s CPU %.4f +- %.4f | GPU %.4f +- %.4f | diff %+.4f (%+.2f%%) = %+.1f s.e." % (label, h, name, mc, ec, mg, eg, d, rel, z))
    print("  largest |z| per quantity: " + ", ".join("%s %+.1f (h%g)" % (n, worst[n][0], worst[n][1]) for n in names))
    nflag = collections.Counter(i[1] for i in flags)
    print("  flag count per quantity: " + (", ".join("%s %d" % kv for kv in sorted(nflag.items())) or "none"))
