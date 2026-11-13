#!/bin/bash
# Runs the windowed simulation tests (tests/sim/*_test.gd, needing a GPU) one after another,
# each through tools/run_windowed.sh (the run lock) with a timeout each.
# Usage: tools/run_sim_tests.sh
# Env: RUN_SIM_TIMEOUT (seconds per test, default 1800), RUN_SIM_OUT (output folder,
#      default <project>/.godot/sim-tests); the lock and binary variables of run_windowed.sh apply.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${RUN_SIM_OUT:-$ROOT/.godot/sim-tests}"
cd "$ROOT" || exit 1

shopt -s nullglob
tests=(tests/sim/*_test.gd)
if [ ${#tests[@]} -eq 0 ]; then
	echo "run_sim_tests: no windowed tests in tests/sim"
	exit 0
fi

mkdir -p "$out_dir"
failed=0
for t in "${tests[@]}"; do
	name="$(basename "$t" .gd)"
	echo "== $t"
	RUN_TIMEOUT="${RUN_SIM_TIMEOUT:-1800}" "$ROOT/tools/run_windowed.sh" "$out_dir/$name.txt" -- \
		--path "$ROOT" --rendering-driver metal --position 6000,6000 -s "$t"
	status=$?
	if [ "$status" -ne 0 ]; then
		failed=$((failed + 1))
		echo "FAILED $t (exit $status)"
	fi
done

if [ "$failed" -ne 0 ]; then
	echo "run_sim_tests: $failed of ${#tests[@]} failed"
	exit 1
fi
echo "run_sim_tests: all ${#tests[@]} passed"
