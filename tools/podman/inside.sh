#!/usr/bin/env bash
set -euo pipefail
export FUZZER="/magma/fuzzers/$1" TARGET="/magma/targets/$2" PROGRAM=$3
export MAGMA=/magma/magma OUT=/magma_out SHARED=/magma_shared
export TIMEOUT=$4 POLL=$5 ARGS=$6 FUZZARGS=$7 MONITOR=/magma_shared/monitor
# Match FuzzBench's AFL setup: permit hosts with a piped core-dump handler.
# This bypasses AFL's startup check; it does not fix crash-handler latency.
export AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1
cat /proc/sys/kernel/core_pattern > "$SHARED/core-pattern.txt"
printf 'AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1\n' > "$SHARED/afl-environment.txt"
[[ $POLL =~ ^[1-9][0-9]*$ ]] || { echo 'POLL must be positive seconds' >&2; exit 2; }
[[ -x $OUT/monitor && -x $FUZZER/run.sh ]] || exit 2
command -v taskset >/dev/null || {
    echo 'Image lacks taskset; rebuild with the updated tools/podman/build.sh.' >&2
    exit 2
}
# Pin this shell before starting children; fork/exec inherit process affinity.
# This does not require delegation of the rootless cgroup cpuset controller.
taskset -pc "$8" $$
taskset -pc $$ > "$SHARED/cpu-affinity.txt"
cd "$SHARED"
mkdir "$MONITOR"
# Initialize storage synchronously. magma_init() permanently disables canaries
# in a process if its first open fails; a background-only monitor can race it.
"$OUT/monitor" --dump row > "$MONITOR/initial.tmp"
mv "$MONITOR/initial.tmp" "$MONITOR/0"
SECONDS=0
poll_monitor() {
    while :; do
        if "$OUT/monitor" --dump row > "$MONITOR/tmp" 2>/dev/null; then
            mv "$MONITOR/tmp" "$MONITOR/$SECONDS"
        fi
        sleep "$POLL"
    done
}
poll_monitor &
monitor_pid=$!
cleanup() {
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# No per-variant seed pruning: caller supplies the frozen evaluation corpus.
# Keep a bounded rotating fuzzer log and propagate early failures.
set +e
timeout --kill-after=30s "$TIMEOUT" "$FUZZER/run.sh" 2>&1 | \
    multilog n2 s1048576 "$SHARED/log"
statuses=("${PIPESTATUS[@]}")
elapsed=$SECONDS
set -e
printf '%s\n' "${statuses[0]}" > "$SHARED/fuzzer-exit-code"
printf '%s\n' "$elapsed" > "$SHARED/elapsed-seconds"
(( statuses[1] == 0 )) || exit "${statuses[1]}"
(( statuses[0] == 124 )) || {
    echo "Fuzzer ended before its budget: exit ${statuses[0]}; inspect log/current" >&2
    exit 1
}
cleanup
trap - EXIT
# A read consumes the available monitor buffer. Once the fuzzer has stopped,
# another read can return 1 simply because the poller already consumed it.
# Never truncate a valid snapshot while attempting that final read.
if [[ ! -s $MONITOR/$elapsed ]]; then
    if "$OUT/monitor" --dump row > "$MONITOR/final.tmp"; then
        mv "$MONITOR/final.tmp" "$MONITOR/$elapsed"
    else
        rm -f "$MONITOR/final.tmp"
        echo 'No fresh final monitor buffer; retaining the last recorded observation.'
    fi
fi
observed=$(find "$MONITOR" -maxdepth 1 -type f -name '[0-9]*' -size +0c \
    -printf '%f\n' | sort -n | tail -n 1)
[[ $observed =~ ^[0-9]+$ ]] || { echo 'No monitor observations recorded' >&2; exit 1; }
(( observed <= elapsed && elapsed - observed <= POLL + 2 )) || {
    echo "Last monitor observation ($observed s) is too far from run end ($elapsed s)." >&2
    exit 1
}
printf '%s\n' "$observed" > "$SHARED/observation-end-seconds"
[[ -s $SHARED/canaries.raw ]] || { echo 'No canary storage' >&2; exit 1; }
echo "Last canary observation: $observed seconds; campaign end: $elapsed seconds."
echo 'Campaign completed its time budget. Inspect fuzzer logs for actual progress.'
