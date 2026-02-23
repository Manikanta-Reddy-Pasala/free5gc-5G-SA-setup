#!/bin/bash
# ============================================================
# run_all.sh - Run all free5GC test cases
#
# Usage:
#   ./tests/run_all.sh              # Run all tests
#   ./tests/run_all.sh 1 3 5        # Run specific tests (TC01, TC03, TC05)
#   ./tests/run_all.sh --list       # List available tests
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

declare -A TESTS
TESTS[1]="tc01_parallel_registration.sh|TC01: Parallel Registration (5 UEs)"
TESTS[2]="tc02_crash_recovery.sh|TC02: Component Crash & Recovery"
TESTS[3]="tc03_multi_apn.sh|TC03: Multi-APN (Two DNNs per UE)"
TESTS[4]="tc04_multi_ue_deregistration.sh|TC04: Multi-UE De-Registration"
TESTS[5]="tc05_paging_idle_ue.sh|TC05: Paging for Idle UEs"
TESTS[6]="tc06_ue_context_release.sh|TC06: UE Context Release (RLF)"
TESTS[7]="tc07_ran_config_update.sh|TC07: RAN Configuration Update"
TESTS[8]="tc08_ng_reset.sh|TC08: NG Reset"
TESTS[9]="tc09_warning_message.sh|TC09: Warning Message (PWS/CMAS)"
TESTS[10]="tc10_memory_leak.sh|TC10: Memory Leak Test"

list_tests() {
    echo ""
    echo "Available test cases:"
    echo ""
    for i in $(seq 1 10); do
        local desc="${TESTS[$i]#*|}"
        printf "  %2d. %s\n" "$i" "$desc"
    done
    echo ""
    echo "Usage:"
    echo "  ./tests/run_all.sh              # Run all tests"
    echo "  ./tests/run_all.sh 1 3 5        # Run TC01, TC03, TC05"
    echo "  ./tests/run_all.sh --list       # Show this list"
    echo ""
}

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
    list_tests
    exit 0
fi

# Determine which tests to run
if [ $# -gt 0 ]; then
    TEST_IDS=("$@")
else
    TEST_IDS=($(seq 1 10))
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           free5GC Test Suite Runner                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Tests to run: ${#TEST_IDS[@]}"
echo "  Log directory: ${LOG_DIR}"
echo "  Timestamp: ${TIMESTAMP}"
echo ""

# Ensure core is running
echo -e "${CYAN}Checking if free5GC core is running...${NC}"
cp_state=$(docker inspect --format='{{.State.Status}}' free5gc-cp 2>/dev/null || echo "missing")
if [ "$cp_state" != "running" ]; then
    echo "Core not running. Start it first: ./free5gc.sh start"
    exit 1
fi
echo -e "${GREEN}Core is running.${NC}"
echo ""

# Run tests
declare -A RESULTS
total=0
passed_total=0
failed_total=0

for id in "${TEST_IDS[@]}"; do
    if [ -z "${TESTS[$id]:-}" ]; then
        echo -e "${RED}Unknown test ID: $id${NC}"
        continue
    fi

    script="${TESTS[$id]%%|*}"
    desc="${TESTS[$id]#*|}"
    log_file="${LOG_DIR}/${script%.sh}_${TIMESTAMP}.log"

    echo -e "${BOLD}─── Running: ${desc} ───${NC}"

    if [ ! -f "${SCRIPT_DIR}/${script}" ]; then
        echo -e "  ${RED}Script not found: ${script}${NC}"
        RESULTS[$id]="MISSING"
        continue
    fi

    # Run the test and capture output
    bash "${SCRIPT_DIR}/${script}" 2>&1 | tee "$log_file"
    exit_code=${PIPESTATUS[0]}

    total=$((total + 1))

    # Determine result from output
    if grep -q "PASSED" "$log_file"; then
        RESULTS[$id]="PASSED"
        passed_total=$((passed_total + 1))
    elif grep -q "FAILED" "$log_file"; then
        RESULTS[$id]="FAILED"
        failed_total=$((failed_total + 1))
    else
        RESULTS[$id]="COMPLETED"
        passed_total=$((passed_total + 1))
    fi

    echo ""
done

# Print summary
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                   TEST RESULTS SUMMARY                  ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"

for id in "${TEST_IDS[@]}"; do
    if [ -z "${TESTS[$id]:-}" ]; then continue; fi
    desc="${TESTS[$id]#*|}"
    result="${RESULTS[$id]:-SKIPPED}"
    case "$result" in
        PASSED|COMPLETED)
            printf "║  ${GREEN}%-7s${NC}  %-47s║\n" "$result" "$desc"
            ;;
        FAILED)
            printf "║  ${RED}%-7s${NC}  %-47s║\n" "$result" "$desc"
            ;;
        *)
            printf "║  ${YELLOW}%-7s${NC}  %-47s║\n" "$result" "$desc"
            ;;
    esac
done

echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
printf "║  Total: %-3d  Passed: ${GREEN}%-3d${NC}  Failed: ${RED}%-3d${NC}               ║\n" "$total" "$passed_total" "$failed_total"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Logs saved in: ${LOG_DIR}/"
echo ""
