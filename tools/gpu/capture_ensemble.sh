#!/bin/bash
# Captures the ensemble of the pooled world: scenarios B, D, E, F x seeds 1-16 x 6 sim-hours (tools/gpu/capture_ensemble.gd, windowed), each
# run through the run lock, into <outdir>/ensemble_pooled_<scenario>.txt (ENS and GENE lines; their format is in the script's header).
# Usage: tools/gpu/capture_ensemble.sh [outdir]   (default: tools/gpu/golden)
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:-$root/tools/gpu/golden}"
tmp="$(mktemp -d)"
for sc in B D E F; do
	: > "$out/ensemble_pooled_$sc.txt"
	for seed in $(seq 1 16); do
		RUN_LOCK_WAIT="${RUN_LOCK_WAIT:-86400}" "$root/tools/run_windowed.sh" "$tmp/run.txt" -- \
			--path "$root" --rendering-driver metal --position 6000,6000 -s tools/gpu/capture_ensemble.gd -- "$sc" "$seed" >/dev/null
		grep -E '^(ENS|GENE) ' "$tmp/run.txt" >> "$out/ensemble_pooled_$sc.txt"
	done
done
rm -rf "$tmp"
