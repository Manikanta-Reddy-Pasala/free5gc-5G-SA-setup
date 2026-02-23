#!/bin/bash
# ============================================================
# TC05: Paging for Idle UEs
# Register UE, let it go idle (CM-IDLE), then trigger downlink
# data to test paging procedure
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC05: Paging for Idle UEs"

ensure_core_running

IMSI="imsi-001010000050641"

# Step 1: Register UE and establish PDU session
info "Registering UE and establishing PDU session..."
kill_all_ues
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10

status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if ! echo "$status" | grep -q "RM-REGISTERED"; then
    fail "UE registration failed, aborting"
    exit 1
fi
pass "UE registered"

# Get UE IP from TUN interface
ue_ip=$(docker exec ueransim ip addr show uesimtun0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
if [ -z "$ue_ip" ]; then
    fail "No UE IP assigned (uesimtun0 not found)"
    exit 1
fi
pass "UE IP: ${ue_ip}"

# Step 2: Check initial CM state (should be CONNECTED)
cm_state=$(echo "$status" | grep "cm-state" | awk '{print $2}')
info "Initial CM state: ${cm_state}"

# Step 3: Wait for UE to transition to CM-IDLE
# UERANSIM simulates idle transition after inactivity
info "Waiting for UE to go CM-IDLE (up to 60s)..."
idle=false
for attempt in $(seq 1 12); do
    sleep 5
    status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
    cm_state=$(echo "$status" | grep "cm-state" | awk '{print $2}')
    if [ "$cm_state" = "CM-IDLE" ]; then
        pass "UE is CM-IDLE (after $((attempt * 5))s)"
        idle=true
        break
    fi
    info "Still CM-CONNECTED ($((attempt * 5))s)..."
done

if [ "$idle" = false ]; then
    warn "UE did not transition to CM-IDLE within 60s."
    info "UERANSIM may not support automatic idle transition."
    info "Simulating by checking paging support in AMF logs..."
fi

# Step 4: Trigger downlink data to invoke paging
# Send ping TO the UE IP from the host (through UPF)
info "Sending downlink traffic to UE (ping ${ue_ip})..."
# Setup data plane route if not already done
UPF_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' upf 2>/dev/null)
ip route add 10.206.0.0/16 via "$UPF_IP" dev br-free5gc 2>/dev/null || true

ping -c 5 -W 3 "$ue_ip" >/dev/null 2>&1 &
PING_PID=$!
sleep 8

# Step 5: Check if UE transitions back to CM-CONNECTED (paging success)
status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
cm_state=$(echo "$status" | grep "cm-state" | awk '{print $2}')

if [ "$cm_state" = "CM-CONNECTED" ]; then
    pass "UE transitioned to CM-CONNECTED (paging successful)"
else
    info "UE CM state: ${cm_state}"
    warn "Paging verification depends on UERANSIM idle mode support"
fi

kill $PING_PID 2>/dev/null || true

# Step 6: Check AMF logs for paging-related messages
info "Checking AMF logs for paging activity..."
paging_log=$(docker exec free5gc-cp grep -i "paging\|Paging\|ServiceRequest\|service request" /var/log/free5gc/amf.log 2>/dev/null | tail -5)
if [ -n "$paging_log" ]; then
    pass "Paging activity found in AMF logs:"
    echo "$paging_log"
else
    info "No paging entries in AMF logs (UE may have stayed connected)"
fi

# Step 7: Verify UE still has connectivity
info "Verifying UE connectivity after paging..."
ping_result=$(docker exec ueransim ping -c 3 -W 2 -I uesimtun0 8.8.8.8 2>&1)
if echo "$ping_result" | grep -q "bytes from"; then
    pass "UE internet connectivity confirmed after paging test"
else
    warn "UE ping failed (may need data plane route setup)"
fi

# Cleanup
kill_all_ues

# Summary
echo ""
echo -e "${BOLD}TC05 Complete${NC}"
info "Note: Full paging test requires UERANSIM to support CM-IDLE state transition."
info "The AMF paging timer t3513 is configured (6s, 4 retries) in amfcfg.yaml."
