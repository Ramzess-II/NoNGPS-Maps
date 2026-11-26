#!/usr/bin/env bash
# Run a build or test command and print little: the tail on success, the error lines and the tail on failure.
# Keeps an agent's context small. The exit code is the command's; the full output stays in the log file named at the end.
# Usage: nogps_quiet.sh <command> [args...]    e.g. nogps_quiet.sh just test "NoGps_.*" build-x
set -u
[ $# -gt 0 ] || { echo "usage: $0 <command> [args...]" >&2; exit 2; }
log=$(mktemp "${TMPDIR:-/tmp}/nogps-quiet.XXXXXX")
"$@" >"$log" 2>&1
rc=$?
if [ $rc -eq 0 ]; then
  tail -n "${NOGPS_QUIET_OK_LINES:-5}" "$log"
else
  echo "== $* failed with exit code $rc; error lines =="
  grep -n -E -i 'error|fail|FAILED|fatal|undefined|Traceback|assert|\bwhat\(\)|BUILD FAILED' "$log" | head -n "${NOGPS_QUIET_ERR_LINES:-40}"
  echo "== last ${NOGPS_QUIET_FAIL_TAIL:-40} lines =="
  tail -n "${NOGPS_QUIET_FAIL_TAIL:-40}" "$log"
fi
echo "== full output: $log =="
exit $rc
