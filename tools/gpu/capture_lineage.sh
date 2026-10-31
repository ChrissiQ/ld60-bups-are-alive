#!/bin/bash
# Captures the two streams (tools/gpu/capture_lineage.gd): scenario E seed 1, 6 sim-hours (births and many deaths), and scenario F seed 2, 6
# sim-hours, with donors and raised ceilings among the founders, into tools/gpu/golden/ (the files' format is in the script's header). Windowed, through the lock.
# Usage: tools/gpu/capture_lineage.sh [outdir]   (default: tools/gpu/golden)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:-$root/tools/gpu/golden}"
log="$(mktemp)"
run() {
	RUN_LOCK_WAIT="${RUN_LOCK_WAIT:-86400}" "$root/tools/run_windowed.sh" "$log" -- \
		/Applications/Godot.app/Contents/MacOS/Godot --path "$root" --rendering-driver metal --position 6000,6000 \
		-s tools/gpu/capture_lineage.gd -- "$@" >/dev/null
	grep -E 'LINEAGE CAPTURE|ERROR' "$log"
}
run E 1 6 0 "$out/lineage_E_seed1"
run F 2 6 1 "$out/lineage_F_seed2_traits"
rm -f "$log"
