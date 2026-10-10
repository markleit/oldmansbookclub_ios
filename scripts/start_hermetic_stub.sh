#!/bin/bash
# Starts (or restarts) the hermetic UI tests' stub server — scripts/hermetic_stub.py — as a host
# process, and waits until it is accepting connections.
#
# Called from two places: the OldMansBookClubUITests target's pre-build phase (project.yml), so a
# plain Xcode test run gets it; and scripts/regression.sh before any hermetic run, because CI
# (#204 C1) runs prebuilt test bundles with `test-without-building`, where no build phase runs.
#
# Idempotent: a stub left over from an interrupted earlier run (a crash, Xcode's Stop button) must
# not be mistaken for a healthy one — it is always replaced.
set -e
cd "$(dirname "$0")/.."
PID_FILE=/tmp/ombc-hermetic-stub.pid
LOG_FILE=/tmp/ombc-hermetic-stub.log
if [ -f "$PID_FILE" ]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  rm -f "$PID_FILE"
fi
nohup python3 scripts/hermetic_stub.py > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
# Real readiness, not a fixed sleep — the stub prints one line once its socket is bound.
for _ in $(seq 1 50); do
  grep -q "listening on" "$LOG_FILE" 2>/dev/null && exit 0
  sleep 0.1
done
echo "hermetic stub did not start in time" >&2
cat "$LOG_FILE" >&2
exit 1
