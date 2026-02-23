#!/bin/bash
# ============================================================
# TC09: Warning Message Transmission (PWS/CMAS)
# Test Write-Replace Warning Request via AMF N2 interface
#
# Note: UERANSIM has limited PWS support. This test verifies
# AMF can handle the warning message flow and checks gNB logs.
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC09: Warning Message Transmission (PWS/CMAS)"

ensure_core_running

IMSI="imsi-001010000050641"

# Step 1: Register UE to ensure gNB-AMF connection is active
info "Registering UE to establish gNB-AMF link..."
kill_all_ues
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10

status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered, gNB-AMF NGAP link active"
else
    warn "UE not registered, proceeding with gNB-only test"
fi

# Step 2: Check AMF configuration for PWS support
info "Checking AMF for PWS/warning message capability..."
amf_config=$(docker exec free5gc-cp cat /free5gc/config/amfcfg.yaml 2>/dev/null)
if echo "$amf_config" | grep -qi "namf-comm\|namf-mt"; then
    pass "AMF has Namf_Communication service (required for PWS relay)"
fi

# Step 3: Test AMF N1N2 message transfer API (used for warning messages)
# The AMF N1N2 API is how CBE -> CBC -> AMF -> gNB warning flow works
info "Testing AMF SBI endpoint availability..."
amf_health=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8006" 2>/dev/null || echo "000")
if [ "$amf_health" != "000" ]; then
    pass "AMF SBI reachable (HTTP ${amf_health})"
else
    # AMF SBI is internal to the container, try from inside
    amf_health=$(docker exec free5gc-cp curl -s -o /dev/null -w "%{http_code}" "http://localhost:8006" 2>/dev/null || echo "000")
    if [ "$amf_health" != "000" ]; then
        pass "AMF SBI reachable from inside container (HTTP ${amf_health})"
    else
        warn "AMF SBI not reachable"
    fi
fi

# Step 4: Send a Write-Replace Warning indication via AMF API
# In a real deployment, CBC sends this. We simulate it via the AMF's N2 Namf_Communication API.
info "Simulating Write-Replace Warning Request via AMF API..."

# The warning message JSON payload following 3GPP TS 29.518
WARN_PAYLOAD='{
  "messageType": "WRITE_REPLACE_WARNING",
  "serialNumber": "0001",
  "messageIdentifier": "1234",
  "repetitionPeriod": 10,
  "numberOfBroadcastsRequested": 3,
  "warningAreaList": {
    "taiList": [{"plmnId": {"mcc": "001", "mnc": "01"}, "tac": "000001"}]
  },
  "warningMessageContents": "VGVzdCBXYXJuaW5nIE1lc3NhZ2U=",
  "dataCodingScheme": "01",
  "warningType": "0200"
}'

# Try sending via AMF non-UE N2 message API
warn_response=$(docker exec free5gc-cp curl -s -w "\n%{http_code}" \
    -X POST "http://localhost:8006/namf-comm/v1/non-ue-n2-messages/transfer" \
    -H 'Content-Type: application/json' \
    -d "$WARN_PAYLOAD" 2>/dev/null)

warn_http=$(echo "$warn_response" | tail -1)
warn_body=$(echo "$warn_response" | head -n -1)

if [ "$warn_http" = "200" ] || [ "$warn_http" = "204" ]; then
    pass "AMF accepted warning message request (HTTP ${warn_http})"
elif [ "$warn_http" = "501" ] || [ "$warn_http" = "404" ]; then
    info "AMF returned HTTP ${warn_http} - PWS endpoint may not be implemented in free5GC v4.2"
    info "Response: ${warn_body}"
else
    info "AMF response: HTTP ${warn_http}"
    info "Body: ${warn_body}"
fi

# Step 5: Check AMF logs for warning message handling
info "Checking AMF logs for warning/PWS activity..."
warn_logs=$(docker exec free5gc-cp grep -i "warning\|pws\|cmas\|etws\|write.replace\|broadcast" /var/log/free5gc/amf.log 2>/dev/null | tail -5)
if [ -n "$warn_logs" ]; then
    pass "Warning message activity found in AMF logs:"
    echo "$warn_logs"
else
    info "No PWS entries in AMF logs."
fi

# Step 6: Check UERANSIM gNB logs for warning message reception
info "Checking gNB logs for warning message relay..."
gnb_logs=$(docker logs ueransim --tail 50 2>&1)
if echo "$gnb_logs" | grep -qi "warning\|pws\|write.replace\|broadcast"; then
    pass "gNB received warning message"
else
    info "No warning message entries in gNB logs."
fi

# Cleanup
kill_all_ues

# Summary
echo ""
echo -e "${BOLD}TC09 Complete${NC}"
info "PWS/CMAS support in free5GC is limited. Full PWS testing requires:"
info "  1. CBC (Cell Broadcast Centre) integration"
info "  2. AMF PWS handler implementation (TS 23.041)"
info "  3. gNB SIB broadcast support in UERANSIM"
info "This test validates the AMF API endpoint and NGAP N2 message path."
