#!/usr/bin/env bash
set -uo pipefail

QEMU="${QEMU:-qemu-system-x86_64}"
QEMU_BASE_ARGS=(
	-kernel zig-out/bin/zag-image-x86_64-*
)

TIMEOUT="${TIMEOUT:-20}"      
KILL_AFTER="${KILL_AFTER:-5}"
POLL="${POLL:-0.05}"          
LOG_DIR="${LOG_DIR:-dst-logs}"
mkdir -p "$LOG_DIR"

passed=0
current_log=""
qemu_pid=""

stop_qemu() {
    if [ -n "$qemu_pid" ]; then
        kill "$qemu_pid" 2>/dev/null
        wait "$qemu_pid" 2>/dev/null
        qemu_pid=""
    fi
}

on_interrupt() {
    echo
    stop_qemu
    [ -n "$current_log" ] && rm -f "$current_log"
    echo "Stopped by user after $passed passed seed(s)." >&2
    exit 130
}
trap on_interrupt INT TERM

random_u64() {
    od -An -N8 -tu8 /dev/urandom | tr -d ' \n'
}

run_seed() {
    local seed="$1"

    current_log="$LOG_DIR/seed-$seed.log"

    timeout -k "$KILL_AFTER" "$TIMEOUT" \
        "$QEMU" \
        "${QEMU_BASE_ARGS[@]}" \
        -serial stdio \
        -m 256M \
        -display none \
        -icount shift=7,sleep=off \
        -append "test=fireworks seed=$seed" \
        -seed "$seed" \
        "${EXTRA_ARGS[@]}" \
        >"$current_log" 2>&1 &
    qemu_pid=$!

    # Poll until QEMU exits on its own (crash/timeout) or DONE appears.
    while kill -0 "$qemu_pid" 2>/dev/null; do
        if grep -q "DONE" "$current_log"; then
            kill "$qemu_pid" 2>/dev/null
            break
        fi
        sleep "$POLL"
    done
    wait "$qemu_pid" 2>/dev/null
    local status=$?
    qemu_pid=""

    if grep -q "DONE" "$current_log"; then
        echo "Seed $seed passed"
        rm -f "$current_log"
        current_log=""
        return 0
    fi

    if [ "$status" -eq 124 ]; then
        echo "Seed $seed FAILED: timed out after ${TIMEOUT}s without DONE" >&2
    else
        echo "Seed $seed FAILED: QEMU exited with $status without DONE" >&2
    fi
    echo "Log: $current_log (replay: SEED=$seed $0)" >&2
    echo "--- last 20 lines ---" >&2
    tail -n 20 "$current_log" >&2
    current_log=""
    return 1
}

EXTRA_ARGS=("$@")

if [ -n "${SEED:-}" ]; then
    run_seed "$SEED"
    exit $?
fi

while true; do
    seed="$(random_u64)"
    run_seed "$seed" || exit 1
    passed=$((passed + 1))
done
