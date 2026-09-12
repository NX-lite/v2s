#!/usr/bin/env bash

set -uo pipefail

swift test --no-parallel &
swift_pid=$!

(
    for _ in $(seq 1 210); do
        sleep 1
        if ! kill -0 "$swift_pid" 2>/dev/null; then
            exit 0
        fi
    done

    echo "Swift tests exceeded the diagnostic deadline; capturing process state." >&2
    ps -axo pid,ppid,state,etime,command >&2
    test_pid="$(pgrep -n -f '/v2sPackageTests\.xctest/Contents/MacOS/v2sPackageTests' || true)"
    if [[ -n "$test_pid" ]]; then
        echo "Sampling test process $test_pid" >&2
        sample "$test_pid" 3 1 >&2 || true
        kill -TERM "$test_pid" 2>/dev/null || true
    else
        echo "Could not locate the v2sPackageTests process." >&2
    fi
    kill -TERM "$swift_pid" 2>/dev/null || true
) &
watchdog_pid=$!

wait "$swift_pid"
status=$?
kill -TERM "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
exit "$status"
