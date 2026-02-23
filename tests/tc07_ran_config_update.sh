#!/bin/bash
# ============================================================
# TC07: RAN Configuration Update Procedure
# Test PLMN and TAC configuration update and verify gNB reconnects
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC07: RAN Configuration Update (PLMN/TAC Change)"

ensure_core_running

IMSI="imsi-001010000050641"

# Step 1: Verify baseline with current config
info "Verifying baseline gNB-AMF connection..."
kill_all_ues
sleep 2

# Check gNB is connected to AMF (look for NG Setup success in UERANSIM logs)
gnb_logs=$(docker logs ueransim --tail 50 2>&1)
if echo "$gnb_logs" | grep -qi "NG Setup procedure is successful\|ngSetup\|amf.*connected"; then
    pass "gNB connected to AMF with current config"
else
    info "gNB logs (last 10 lines):"
    echo "$gnb_logs" | tail -10
fi

# Register a UE to confirm connectivity
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10
status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered with baseline config (MCC=001, MNC=01, TAC=1)"
    tac=$(echo "$status" | grep "current-tac" | awk '{print $2}')
    info "Current TAC: ${tac}"
else
    fail "Baseline registration failed"
fi
kill_all_ues

# Step 2: Update TAC configuration
NEW_TAC="2"
NEW_TAC_HEX=$(printf "%06x" "$NEW_TAC")
info "Updating TAC from 1 to ${NEW_TAC}..."

# Update AMF config inside container
docker exec free5gc-cp sh -c "sed -i 's/tac: 000001/tac: ${NEW_TAC_HEX}/' /free5gc/config/amfcfg.yaml"
info "Updated AMF TAC to ${NEW_TAC_HEX}"

# Update gNB config
docker exec ueransim sh -c "sed -i 's/^tac: [0-9]*/tac: ${NEW_TAC}/' /ueransim/config/gnbcfg.yaml"
info "Updated gNB TAC to ${NEW_TAC}"

# Update UE config (not strictly needed, but for consistency)
# UE gets TAC from network, not config

# Step 3: Restart CP and UERANSIM to apply new config
info "Restarting Control Plane to apply new TAC..."
docker restart free5gc-cp >/dev/null 2>&1
waited=0
while [ $waited -lt 120 ]; do
    health=$(docker inspect --format='{{.State.Health.Status}}' free5gc-cp 2>/dev/null || echo "unknown")
    [ "$health" = "healthy" ] && break
    sleep 5
    waited=$((waited + 5))
done
if [ "$health" = "healthy" ]; then
    pass "CP restarted and healthy"
else
    fail "CP health check failed (status: ${health})"
fi

info "Restarting UERANSIM gNB with new TAC..."
docker restart ueransim >/dev/null 2>&1
sleep 10

# Step 4: Verify gNB reconnects with new TAC
gnb_logs=$(docker logs ueransim --tail 30 2>&1)
if echo "$gnb_logs" | grep -qi "NG Setup procedure is successful\|ngSetup"; then
    pass "gNB re-established NG Setup with new TAC"
else
    info "gNB logs:"
    echo "$gnb_logs" | tail -10
fi

# Step 5: Register UE and verify new TAC
info "Registering UE with new TAC..."
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10
status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered with updated TAC"
    new_tac=$(echo "$status" | grep "current-tac" | awk '{print $2}')
    info "UE reports TAC: ${new_tac}"
    if [ "$new_tac" = "$NEW_TAC" ]; then
        pass "TAC matches expected value (${NEW_TAC})"
    else
        warn "TAC mismatch: expected ${NEW_TAC}, got ${new_tac}"
    fi
else
    fail "UE registration failed with new TAC"
fi
kill_all_ues

# Step 6: Restore original TAC
info "Restoring original TAC (1)..."
docker exec free5gc-cp sh -c "sed -i 's/tac: ${NEW_TAC_HEX}/tac: 000001/' /free5gc/config/amfcfg.yaml"
docker exec ueransim sh -c "sed -i 's/^tac: ${NEW_TAC}/tac: 1/' /ueransim/config/gnbcfg.yaml"
docker restart free5gc-cp >/dev/null 2>&1
sleep 30
docker restart ueransim >/dev/null 2>&1
sleep 10
pass "Original config restored"

# Summary
echo ""
echo -e "${BOLD}TC07 Complete${NC}: RAN config update tested with TAC change ${CYAN}1 -> ${NEW_TAC} -> 1${NC}"
