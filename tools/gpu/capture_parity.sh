#!/bin/bash
# Captures the parity fixtures (tools/gpu/capture_parity.gd, four modes) into tools/gpu/golden/parity (or the folder given). Windowed, through the lock.
# Usage: tools/gpu/capture_parity.sh [outdir]
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:-$root/tools/gpu/golden/parity}"
log="$(mktemp)"
for mode in state husks goal screens; do
	while true; do
		RUN_LOCK_WAIT="${RUN_LOCK_WAIT:-86400}" "$root/tools/run_windowed.sh" "$log" -- \
			/Applications/Godot.app/Contents/MacOS/Godot --path "$root" --rendering-driver metal --position 6000,6000 --resolution 1920x1080 \
			-s tools/gpu/capture_parity.gd -- "$mode" "$out" >/dev/null
		rc=$?
		[ "$rc" = 75 ] || break
	done
	echo "mode $mode exit $rc"
	grep -E 'PARITY|ERROR|SCRIPT' "$log"
done
rm -f "$log"
