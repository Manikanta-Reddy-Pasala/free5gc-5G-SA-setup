#!/bin/bash
# ============================================================
# TC08: NG Reset
# Test NG interface reset by restarting gNB and verifying
# AMF handles the reconnection and UEs can re-register
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC08: NG Reset Procedure"

ensure_core_running

IMSI="imsi-001010000050641"

# Step 1: Register UE (baseline)
info "Establishing baseline - registering UE..."
kill_all_ues
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10

status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered (baseline)"
else
    fail "Baseline registration failed"
    exit 1
fi

amf_lines_before=$(docker exec free5gc-cp wc -l /var/log/free5gc/amf.log 2>/dev/null | awk '{print $1}')

# Step 2: Simulate NG Reset by restarting UERANSIM (gNB)
# This causes the SCTP association to drop, which triggers NG Reset behavior in AMF
info "Simulating NG Reset - restarting UERANSIM container (gNB + UE)..."
docker restart ueransim >/dev/null 2>&1
sleep 10

# Step 3: Check AMF logs for NG Reset / SCTP association handling
info "Checking AMF logs for NG Reset handling..."
amf_new_logs=$(docker exec free5gc-cp tail -n +$((amf_lines_before + 1)) /var/log/free5gc/amf.log 2>/dev/null)

if echo "$amf_new_logs" | grep -qi "SCTP\|sctp\|association\|ngReset\|NG Reset\|ran connection"; then
    pass "AMF detected SCTP/NG connection change"
    echo "$amf_new_logs" | grep -i "sctp\|association\|reset\|ran connection\|remove" | tail -5
else
    info "AMF logs after restart:"
    echo "$amf_new_logs" | tail -10
fi

# Step 4: Verify gNB re-establishes NG Setup after reset
info "Checking gNB NG Setup re-establishment..."
gnb_logs=$(docker logs ueransim --tail 30 2>&1)
if echo "$gnb_logs" | grep -qi "NG Setup procedure is successful"; then
    pass "gNB re-established NG Setup after reset"
else
    warn "NG Setup success message not found in recent logs"
    echo "$gnb_logs" | tail -5
fi

# Step 5: Register UE after NG Reset
info "Registering UE after NG Reset..."
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10

status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered successfully after NG Reset"
else
    fail "UE registration failed after NG Reset"
fi

# Step 6: Verify data plane works after reset
info "Testing data plane after NG Reset..."
if docker exec ueransim ip addr show uesimtun0 >/dev/null 2>&1; then
    ping_result=$(docker exec ueransim ping -c 3 -W 2 -I uesimtun0 8.8.8.8 2>&1)
    if echo "$ping_result" | grep -q "bytes from"; then
        pass "Data plane works after NG Reset (ping 8.8.8.8 OK)"
    else
        warn "Ping failed (may need data plane route setup on host)"
    fi
else
    warn "No uesimtun0 interface (PDU session may not be established yet)"
fi

# Step 7: Force SCTP disconnect test (more aggressive)
echo ""
info "=== Aggressive NG Reset: kill gNB process only ==="
amf_lines_before=$(docker exec free5gc-cp wc -l /var/log/free5gc/amf.log 2>/dev/null | awk '{print $1}')

docker exec ueransim pkill -9 -f "nr-gnb" 2>/dev/null
docker exec ueransim pkill -9 -f "nr-ue" 2>/dev/null
sleep 5

amf_new_logs=$(docker exec free5gc-cp tail -n +$((amf_lines_before + 1)) /var/log/free5gc/amf.log 2>/dev/null)
if echo "$amf_new_logs" | grep -qi "sctp\|association\|remove\|release\|reset"; then
    pass "AMF detected gNB disconnect (SCTP association lost)"
else
    info "AMF may handle disconnect silently via timeout"
fi

# Restart gNB
info "Restarting gNB..."
docker exec -d ueransim ./nr-gnb -c ./config/gnbcfg.yaml
sleep 5

# Re-register UE
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10
status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered after aggressive NG Reset"
else
    fail "UE failed to register after aggressive NG Reset"
fi

# Cleanup
kill_all_ues

# Summary
echo ""
echo -e "${BOLD}TC08 Complete${NC}: NG Reset tested (container restart + process kill)"
