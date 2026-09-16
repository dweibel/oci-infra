#!/bin/bash
# Property-based test: Keep-alive iteration detection is correct
# **Validates: Requirements 6.1, 6.2, 6.4**
#
# Tests the core iteration detection logic from monitor_keep_alive() in isolation.
# The logic is extracted into detect_iterations() which:
#   - Reads a stream of log lines from stdin
#   - Counts lines matching "running stress-ng" or "skipping stress-ng" as successful iterations
#   - Detects error lines containing: error, fatal, panic, killed, terminated (case-insensitive)
#   - Returns 0 (success) after exactly 3 valid iterations with no interleaved errors
#   - Returns 1 (failure) on any error line or if fewer than 3 valid iterations are found
#
# Pattern matching criteria:
#   - "running stress-ng" = successful iteration
#   - "skipping stress-ng" = successful iteration
#   - "error"|"fatal"|"panic"|"killed"|"terminated" (case-insensitive) = error → failure
#   - 3 successful iterations without intervening errors = success
#   - Any error line = immediate failure
#   - No valid patterns (or fewer than 3) = failure

set -euo pipefail

# --- Extracted iteration detection function ---

# detect_iterations() — Core iteration detection logic extracted from monitor_keep_alive().
# Reads log lines from stdin, counts successful iteration markers, detects errors.
# Returns 0 after exactly 3 successful iterations, 1 on error or insufficient iterations.
detect_iterations() {
    local required_iterations=3
    local iteration_count=0
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Check for error indicators (case-insensitive)
        if echo "$line" | grep -qi "error\|fatal\|panic\|killed\|terminated"; then
            return 1
        fi

        # Check for successful iteration markers
        if echo "$line" | grep -q "running stress-ng\|skipping stress-ng"; then
            iteration_count=$((iteration_count + 1))

            if [[ $iteration_count -ge $required_iterations ]]; then
                return 0
            fi
        fi
    done

    # Reached end of input without 3 successful iterations
    return 1
}

# --- Test infrastructure ---

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
ITERATIONS_PER_PROPERTY=100

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS: $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        Detail: $2"
    fi
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
}

# --- Random generators ---

# Generate a random CPU percentage (0-100)
random_cpu() {
    echo $((RANDOM % 101))
}

# Generate a valid iteration line (either "running" or "skipping" variant)
generate_valid_line() {
    local cpu
    cpu=$(random_cpu)
    if [[ $((RANDOM % 2)) -eq 0 ]]; then
        echo "CPU usage ${cpu}% - running stress-ng"
    else
        echo "CPU usage ${cpu}% - skipping stress-ng"
    fi
}

# Generate a random noise line (not a valid iteration, not an error)
generate_noise_line() {
    local noise_options=(
        "Checking OCI endpoint..."
        "curl: (7) Connection timed out"
        "sleep 2"
        "Starting iteration loop"
        "CPU measurement: collecting data"
        ""
        "2024-01-15 10:30:00 [INFO] Heartbeat sent"
        "stress-ng: info: dispatching hogs"
        "OCI health check passed"
    )
    local idx=$((RANDOM % ${#noise_options[@]}))
    echo "${noise_options[$idx]}"
}

# Generate an error line
generate_error_line() {
    local error_options=(
        "ERROR: Failed to connect to OCI endpoint"
        "fatal: keep-alive process crashed"
        "PANIC: out of memory"
        "Process killed by OOM killer"
        "Container terminated unexpectedly"
        "error: stress-ng failed to start"
        "Fatal exception in main loop"
        "keep-alive.sh: terminated by signal 9"
        "KILLED: received SIGKILL"
        "panic: runtime error"
    )
    local idx=$((RANDOM % ${#error_options[@]}))
    echo "${error_options[$idx]}"
}

# --- Property tests ---

echo "================================================================"
echo "Property Test: Keep-alive iteration detection is correct"
echo "Validates: Requirements 6.1, 6.2, 6.4"
echo "Iterations per sub-property: ${ITERATIONS_PER_PROPERTY}"
echo "================================================================"
echo ""

# --- Sub-property 1: Exactly 3 valid iterations → success ---
echo "[Sub-property 1] 3 valid iterations (no noise, no errors) → success"

for i in $(seq 1 $ITERATIONS_PER_PROPERTY); do
    run_test
    # Generate exactly 3 valid lines
    input=""
    input+="$(generate_valid_line)"$'\n'
    input+="$(generate_valid_line)"$'\n'
    input+="$(generate_valid_line)"$'\n'

    if echo "$input" | detect_iterations; then
        : # expected success
    else
        fail "Iteration $i: 3 valid lines should return success"
        break
    fi
done
if [[ $TESTS_FAILED -eq 0 || $TESTS_PASSED -eq $TESTS_RUN ]]; then
    pass "All $ITERATIONS_PER_PROPERTY sequences with exactly 3 valid iterations returned success"
fi

# --- Sub-property 2: More than 3 valid iterations → success (returns after 3rd) ---
echo ""
echo "[Sub-property 2] More than 3 valid iterations → success (stops at 3)"

for i in $(seq 1 $ITERATIONS_PER_PROPERTY); do
    run_test
    # Generate 3-8 valid lines
    local_count=$((3 + RANDOM % 6))
    input=""
    for j in $(seq 1 $local_count); do
        input+="$(generate_valid_line)"$'\n'
    done

    if echo "$input" | detect_iterations; then
        : # expected success
    else
        fail "Iteration $i: ${local_count} valid lines should return success (>= 3)"
        break
    fi
done
if [[ $TESTS_FAILED -eq 0 ]]; then
    pass "All $ITERATIONS_PER_PROPERTY sequences with 3+ valid iterations returned success"
fi

# --- Sub-property 3: Fewer than 3 valid iterations (no errors) → failure ---
echo ""
echo "[Sub-property 3] Fewer than 3 valid iterations (0-2) → failure"

prev_failed=$TESTS_FAILED
for i in $(seq 1 $ITERATIONS_PER_PROPERTY); do
    run_test
    # Generate 0-2 valid lines with optional noise
    local_count=$((RANDOM % 3))  # 0, 1, or 2
    input=""
    # Add some noise before
    for j in $(seq 1 $((RANDOM % 4))); do
        input+="$(generate_noise_line)"$'\n'
    done
    for j in $(seq 1 $local_count); do
        input+="$(generate_valid_line)"$'\n'
        # Optionally add noise between valid lines
        if [[ $((RANDOM % 2)) -eq 0 ]]; then
            input+="$(generate_noise_line)"$'\n'
        fi
    done
    # Add trailing noise
    for j in $(seq 1 $((RANDOM % 3))); do
        input+="$(generate_noise_line)"$'\n'
    done

    if echo "$input" | detect_iterations; then
        fail "Iteration $i: ${local_count} valid lines (< 3) should return failure"
        break
    fi
done
if [[ $TESTS_FAILED -eq $prev_failed ]]; then
    pass "All $ITERATIONS_PER_PROPERTY sequences with < 3 valid iterations returned failure"
fi

# --- Sub-property 4: Error line before 3 iterations → failure ---
echo ""
echo "[Sub-property 4] Error line appearing before 3rd iteration → immediate failure"

prev_failed=$TESTS_FAILED
for i in $(seq 1 $ITERATIONS_PER_PROPERTY); do
    run_test
    # Place 0-2 valid lines, then an error, then possibly more valid lines
    local_before=$((RANDOM % 3))  # 0, 1, or 2 valid lines before error
    input=""
    for j in $(seq 1 $local_before); do
        input+="$(generate_valid_line)"$'\n'
    done
    input+="$(generate_error_line)"$'\n'
    # Add more valid lines after the error (should never be counted since function returns on error)
    for j in $(seq 1 3); do
        input+="$(generate_valid_line)"$'\n'
    done

    if echo "$input" | detect_iterations; then
        fail "Iteration $i: Error after ${local_before} valid lines should return failure"
        break
    fi
done
if [[ $TESTS_FAILED -eq $prev_failed ]]; then
    pass "All $ITERATIONS_PER_PROPERTY sequences with error before 3rd iteration returned failure"
fi

# --- Sub-property 5: Valid iterations with interleaved noise → success ---
echo ""
echo "[Sub-property 5] 3+ valid iterations with interleaved noise lines → success"

prev_failed=$TESTS_FAILED
for i in $(seq 1 $ITERATIONS_PER_PROPERTY); do
    run_test
    # Generate 3 valid lines with noise interspersed
    input=""
    for j in $(seq 1 3); do
        # Add 0-5 noise lines before each valid line
        for k in $(seq 1 $((RANDOM % 6))); do
            input+="$(generate_noise_line)"$'\n'
        done
        input+="$(generate_valid_line)"$'\n'
    done
    # Add trailing noise
    for k in $(seq 1 $((RANDOM % 4))); do
        input+="$(generate_noise_line)"$'\n'
    done

    if echo "$input" | detect_iterations; then
        : # expected success
    else
        fail "Iteration $i: 3 valid lines with noise should return success"
        echo "Input was:"
        echo "$input"
        break
    fi
done
if [[ $TESTS_FAILED -eq $prev_failed ]]; then
    pass "All $ITERATIONS_PER_PROPERTY sequences with 3 valid iterations + noise returned success"
fi

# --- Sub-property 6: Empty input → failure ---
echo ""
echo "[Sub-property 6] Empty input → failure"

run_test
if echo "" | detect_iterations; then
    fail "Empty input should return failure"
else
    pass "Empty input correctly returned failure"
fi

# --- Sub-property 7: Only noise lines (no valid, no error) → failure ---
echo ""
echo "[Sub-property 7] Only noise lines (no valid patterns, no errors) → failure"

prev_failed=$TESTS_FAILED
for i in $(seq 1 $ITERATIONS_PER_PROPERTY); do
    run_test
    # Generate 1-20 noise-only lines
    local_count=$((1 + RANDOM % 20))
    input=""
    for j in $(seq 1 $local_count); do
        input+="$(generate_noise_line)"$'\n'
    done

    if echo "$input" | detect_iterations; then
        fail "Iteration $i: ${local_count} noise-only lines should return failure"
        break
    fi
done
if [[ $TESTS_FAILED -eq $prev_failed ]]; then
    pass "All $ITERATIONS_PER_PROPERTY sequences with only noise returned failure"
fi

# --- Sub-property 8: Error keywords are case-insensitive ---
echo ""
echo "[Sub-property 8] Error detection is case-insensitive"

prev_failed=$TESTS_FAILED
case_variants=(
    "ERROR: something broke"
    "Error: something broke"
    "error: something broke"
    "FATAL: crash"
    "Fatal: crash"
    "fatal: crash"
    "PANIC: oops"
    "Panic: runtime"
    "panic: nil pointer"
    "KILLED by signal"
    "Killed by OOM"
    "killed by signal"
    "TERMINATED unexpectedly"
    "Terminated: signal 15"
    "terminated by systemd"
)

for variant in "${case_variants[@]}"; do
    run_test
    input="$(generate_valid_line)"$'\n'
    input+="$(generate_valid_line)"$'\n'
    input+="${variant}"$'\n'
    input+="$(generate_valid_line)"$'\n'

    if echo "$input" | detect_iterations; then
        fail "Case variant '${variant}' should trigger error detection"
        break
    fi
done
if [[ $TESTS_FAILED -eq $prev_failed ]]; then
    pass "All ${#case_variants[@]} case variants correctly detected as errors"
fi

# --- Sub-property 9: "running stress-ng" and "skipping stress-ng" both count ---
echo ""
echo "[Sub-property 9] Both 'running stress-ng' and 'skipping stress-ng' are valid iterations"

prev_failed=$TESTS_FAILED

# Test: 3x "running stress-ng"
run_test
input="CPU usage 5% - running stress-ng"$'\n'
input+="CPU usage 12% - running stress-ng"$'\n'
input+="CPU usage 3% - running stress-ng"$'\n'
if echo "$input" | detect_iterations; then
    pass "3x 'running stress-ng' → success"
else
    fail "3x 'running stress-ng' should be success"
fi

# Test: 3x "skipping stress-ng"
run_test
input="CPU usage 85% - skipping stress-ng"$'\n'
input+="CPU usage 90% - skipping stress-ng"$'\n'
input+="CPU usage 77% - skipping stress-ng"$'\n'
if echo "$input" | detect_iterations; then
    pass "3x 'skipping stress-ng' → success"
else
    fail "3x 'skipping stress-ng' should be success"
fi

# Test: mixed valid patterns
run_test
input="CPU usage 5% - running stress-ng"$'\n'
input+="CPU usage 85% - skipping stress-ng"$'\n'
input+="CPU usage 10% - running stress-ng"$'\n'
if echo "$input" | detect_iterations; then
    pass "Mixed 'running'/'skipping' patterns → success"
else
    fail "Mixed valid patterns should be success"
fi

# --- Summary ---
echo ""
echo "================================================================"
echo "RESULTS: ${TESTS_RUN} tests run, ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
echo "================================================================"

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "OVERALL: FAIL"
    exit 1
else
    echo "OVERALL: PASS"
    exit 0
fi
