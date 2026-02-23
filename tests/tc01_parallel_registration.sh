#!/bin/bash
# ============================================================
# TC01: Parallel Registration
# Verify multiple UEs can register simultaneously
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

NUM_UES="${1:-5}"

header "TC01: Parallel Registration (${NUM_UES} UEs)"

ensure_core_running

# Step 1: Provision subscribers
info "Provisioning ${NUM_UES} subscribers..."
token=$(get_token) || { fail "Cannot get WebUI token"; exit 1; }

for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    imsi="imsi-${supi_num}"
    key=$(hex_add "$BASE_KEY" "$i")
    http_code=$(provision_subscriber "$imsi" "$key" "$OPC" "$token")
    patch_mongodb "$imsi"
    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ] || [ "$http_code" = "409" ]; then
        info "Provisioned $imsi"
    else
        fail "Failed to provision $imsi (HTTP $http_code)"
    fi
done

# Step 2: Generate UE configs and copy into container
info "Generating UE configs..."
kill_all_ues
TMPDIR=$(mktemp -d)
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    key=$(hex_add "$BASE_KEY" "$i")
    generate_ue_config "$supi_num" "$key" "$OPC" "${TMPDIR}/ue${i}.yaml" "internet"
    docker cp "${TMPDIR}/ue${i}.yaml" ueransim:/ueransim/config/ue${i}.yaml
done

# Step 3: Launch all UEs in parallel
info "Launching ${NUM_UES} UEs in parallel..."
for (( i=0; i<NUM_UES; i++ )); do
    docker exec -d ueransim ./nr-ue -c ./config/ue${i}.yaml &
done
wait

# Step 4: Wait for registrations to complete
info "Waiting 15s for registrations..."
sleep 15

# Step 5: Check registration status
passed=0
failed_count=0
for (( i=0; i<NUM_UES; i++ )); do
    supi_num=$(supi_add "$BASE_SUPI" "$i")
    imsi="imsi-${supi_num}"
    status=$(docker exec ueransim ./nr-cli "$imsi" -e "status" 2>/dev/null)
    if echo "$status" | grep -q "RM-REGISTERED"; then
        pass "UE ${imsi}: REGISTERED"
        passed=$((passed + 1))
    else
        fail "UE ${imsi}: NOT REGISTERED"
        echo "$status" | head -5
        failed_count=$((failed_count + 1))
    fi
done

# Cleanup
kill_all_ues
rm -rf "$TMPDIR"

# Summary
echo ""
if [ "$failed_count" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}TC01 PASSED${NC}: All ${NUM_UES} UEs registered successfully"
else
    echo -e "${RED}${BOLD}TC01 FAILED${NC}: ${passed}/${NUM_UES} registered, ${failed_count} failed"
fi
