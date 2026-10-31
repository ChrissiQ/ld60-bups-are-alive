#!/bin/bash
# Runs one Godot command at a time on this machine. Windowed and timing runs share
# one GPU, so each takes a lock first: it waits while another run holds the lock, or
# with RUN_LOCK_WAIT=0 refuses at once (exit 75). The lock is released on any exit.
# Usage: tools/run_windowed.sh <outfile> -- <godot args...>
# Env: RUN_LOCK_DIR (lock folder), RUN_LOCK_WAIT (seconds to wait, default 86400),
#      RUN_WINDOWED_BIN (Godot binary), RUN_TIMEOUT (seconds the run may take; exit 124 when over).
# Prints the output file's path last on stdout.
set -uo pipefail

LOCK_DIR="${RUN_LOCK_DIR:-/tmp/bups-windowed-run.lock}"
WAIT="${RUN_LOCK_WAIT:-86400}"
BIN="${RUN_WINDOWED_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

if [ $# -lt 3 ] || [ "$2" != "--" ]; then
	echo "usage: $0 <outfile> -- <godot args...>" >&2
	exit 2
fi
out="$1"
shift 2

if [ ! -x "$BIN" ]; then
	echo "run_windowed: Godot binary not found or not executable: $BIN" >&2
	exit 1
fi

# Removes the lock when the pid in it is no longer running. Returns 0 if it did.
clear_stale_lock() {
	local pid
	pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
	if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
		echo "run_windowed: clearing lock left by pid $pid (not running)" >&2
		# Moving the folder first makes the clearing atomic: only one run can take it.
		if mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null; then
			rm -rf "$LOCK_DIR.stale.$$"
		fi
		return 0
	fi
	return 1
}

start=$SECONDS
announced=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
	if clear_stale_lock; then
		continue
	fi
	if [ $((SECONDS - start)) -ge "$WAIT" ]; then
		echo "run_windowed: $LOCK_DIR is held by pid $(cat "$LOCK_DIR/pid" 2>/dev/null): $(cat "$LOCK_DIR/command" 2>/dev/null) (since $(cat "$LOCK_DIR/started" 2>/dev/null))" >&2
		exit 75
	fi
	if [ "$announced" = 0 ]; then
		echo "run_windowed: waiting for the run lock held by pid $(cat "$LOCK_DIR/pid" 2>/dev/null)" >&2
		announced=1
	fi
	sleep 5
done

printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf '%s\n' "$BIN $*" > "$LOCK_DIR/command"
date '+%Y-%m-%d %H:%M:%S' > "$LOCK_DIR/started"

child=""
watchdog=""
release() {
	rm -rf "$LOCK_DIR"
}
stop_watchdog() {
	if [ -n "$watchdog" ]; then
		pkill -P "$watchdog" 2>/dev/null
		kill "$watchdog" 2>/dev/null
		wait "$watchdog" 2>/dev/null
		watchdog=""
	fi
}
# A signal stops the Godot run too, then the lock is released by the EXIT trap.
stop_run() {
	if [ -n "$child" ]; then
		kill -TERM "$child" 2>/dev/null
		wait "$child" 2>/dev/null
	fi
	stop_watchdog
	exit "$1"
}
trap release EXIT
trap 'stop_run 143' TERM
trap 'stop_run 130' INT

mkdir -p "$(dirname "$out")"
"$BIN" "$@" > "$out" 2>&1 &
child=$!

if [ -n "${RUN_TIMEOUT:-}" ]; then
	# The timer only acts while the run is still going, so a finished run is never marked.
	(
		sleep "$RUN_TIMEOUT"
		if kill -0 "$child" 2>/dev/null; then
			: > "$LOCK_DIR/timed-out"
			kill -TERM "$child" 2>/dev/null
		fi
	) >/dev/null 2>&1 &
	watchdog=$!
fi

wait "$child"
status=$?
child=""
stop_watchdog

if [ -e "$LOCK_DIR/timed-out" ]; then
	echo "run_windowed: timed out after $RUN_TIMEOUT s" >&2
	status=124
fi
echo "$out"
exit "$status"
