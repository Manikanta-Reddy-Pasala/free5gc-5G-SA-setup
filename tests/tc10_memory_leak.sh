#!/bin/bash
# ============================================================
# TC10: Memory Leak Test
# Monitor memory usage across register/deregister cycles
# to detect memory leaks in NF components
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CYCLES="${1:-10}"
NUM_UES="${2:-3}"
REPORT_FILE="${TESTS_DIR}/memory_report_$(date +%Y%m%d_%H%M%S).txt"

header "TC10: Memory Leak Test (${CYCLES} cycles x ${NUM_UES} UEs)"

ensure_core_running

CONTAINERS=("free5gc-cp" "upf" "mongodb" "ueransim")

# Helper: capture memory stats for all containers
capture_memory() {
    local label="$1"
    echo "=== ${label} ===" >> "$REPORT_FILE"
    printf "%-15s %10s %10s %10s\n" "Container" "RSS (MB)" "VSZ (MB)" "Mem%" >> "$REPORT_FILE"
    for c in "${CONTAINERS[@]}"; do
        local mem_info
        mem_info=$(docker stats --no-stream --format "{{.MemUsage}}" "$c" 2>/dev/null || echo "N/A")
        local mem_pct
        mem_pct=$(docker stats --no-stream --format "{{.MemPerc}}" "$c" 2>/dev/null || echo "N/A")
        printf "%-15s %20s %10s\n" "$c" "$mem_info" "$mem_pct" >> "$REPORT_FILE"
    done
    echo "" >> "$REPORT_FILE"
}

# Helper: get numeric memory in MiB for a container
get_mem_mib() {
    local c="$1"
    docker stats --no-stream --format "{{.MemUsage}}" "$c" 2>/dev/null | awk '{print $1}' | sed 's/MiB//' | sed 's/GiB/*1024/' | bc 2>/dev/null || echo "0"
}

echo "Memory Leak Test Report" > "$REPORT_FILE"
echo "Date: $(date)" >> "$REPORT_FILE"
echo "Cycles: ${CYCLES}, UEs per cycle: ${NUM_UES}" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Step 1: Provision test subscribers
info "Provisioning ${NUM_UES} subscribers..."
token=$(get_token) || { fail "Cannot get WebUI token"; exit 1; }
TMPDIR=$(mktemp -d)

for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    imsi="imsi-${supi_num}"
    key=$(hex_add "$BASE_KEY" "$i")
    provision_subscriber "$imsi" "$key" "$OPC" "$token" >/dev/null
    patch_mongodb "$imsi"
    generate_ue_config "$supi_num" "$key" "$OPC" "${TMPDIR}/ue${i}.yaml" "internet"
    docker cp "${TMPDIR}/ue${i}.yaml" ueransim:/ueransim/config/ue${i}.yaml
done
pass "Provisioned ${NUM_UES} subscribers"

# Step 2: Capture baseline memory
info "Capturing baseline memory..."
kill_all_ues
sleep 5
capture_memory "BASELINE (before any cycles)"

# Capture initial values for comparison
declare -A initial_mem
for c in "${CONTAINERS[@]}"; do
    initial_mem[$c]=$(get_mem_mib "$c")
done
info "Baseline memory:"
for c in "${CONTAINERS[@]}"; do
    info "  ${c}: ${initial_mem[$c]} MiB"
done

# Step 3: Run register/deregister cycles
echo ""
for (( cycle=1; cycle<=CYCLES; cycle++ )); do
    info "[Cycle ${cycle}/${CYCLES}] Registering ${NUM_UES} UEs..."

    # Register all UEs
    for (( i=0; i<NUM_UES; i++ )); do
        docker exec -d ueransim ./nr-ue -c ./config/ue${i}.yaml
    done
    sleep 10

    # Deregister all UEs
    for (( i=0; i<NUM_UES; i++ )); do
        supi_num=$(supi_add "$BASE_SUPI" "$i")
        imsi="imsi-${supi_num}"
        docker exec ueransim ./nr-cli "$imsi" -e "deregister normal" 2>/dev/null &
    done
    wait
    sleep 3
    kill_all_ues
    sleep 2

    # Capture memory every 5 cycles or on last cycle
    if [ $((cycle % 5)) -eq 0 ] || [ "$cycle" -eq "$CYCLES" ]; then
        capture_memory "After cycle ${cycle}"
        info "[Cycle ${cycle}] Memory snapshot:"
        for c in "${CONTAINERS[@]}"; do
            current=$(get_mem_mib "$c")
            info "  ${c}: ${current} MiB"
        done
    fi
done

# Step 4: Capture final memory and compare
echo ""
info "Capturing final memory..."
sleep 5
capture_memory "FINAL (after all cycles)"

# Step 5: Analyze growth
echo "" >> "$REPORT_FILE"
echo "=== MEMORY GROWTH ANALYSIS ===" >> "$REPORT_FILE"
echo ""
info "Memory growth analysis:"

leak_detected=false
for c in "${CONTAINERS[@]}"; do
    final=$(get_mem_mib "$c")
    initial=${initial_mem[$c]}

    if [ "$initial" != "0" ] && [ -n "$initial" ] && [ -n "$final" ]; then
        growth=$(echo "$final - $initial" | bc 2>/dev/null || echo "0")
        pct=$(echo "scale=1; ($growth / $initial) * 100" | bc 2>/dev/null || echo "0")

        printf "%-15s Initial: %6s MiB  Final: %6s MiB  Growth: %+6s MiB (%s%%)\n" \
            "$c" "$initial" "$final" "$growth" "$pct" >> "$REPORT_FILE"

        if (( $(echo "$pct > 20" | bc -l 2>/dev/null || echo 0) )); then
            fail "${c}: Memory grew by ${growth} MiB (${pct}%) - possible leak"
            leak_detected=true
        elif (( $(echo "$pct > 10" | bc -l 2>/dev/null || echo 0) )); then
            warn "${c}: Memory grew by ${growth} MiB (${pct}%) - monitor"
        else
            pass "${c}: Memory stable (${growth} MiB / ${pct}%)"
        fi
    else
        info "${c}: Could not measure (initial=${initial}, final=${final})"
    fi
done

# Cleanup
kill_all_ues
rm -rf "$TMPDIR"

# Summary
echo ""
info "Full report saved to: ${REPORT_FILE}"
echo ""
if [ "$leak_detected" = true ]; then
    echo -e "${RED}${BOLD}TC10 WARNING${NC}: Potential memory leak detected. Review report."
else
    echo -e "${GREEN}${BOLD}TC10 PASSED${NC}: No significant memory growth after ${CYCLES} cycles"
fi
