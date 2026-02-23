#!/bin/bash
# ============================================================
# TC03: Minimum Two APNs Connectivity per UE
# Verify UE can establish PDU sessions on two DNNs: internet + ims
#
# Prerequisites: SMF and AMF must support DNN "ims" in addition to "internet".
# This test adds the "ims" DNN config if not already present.
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC03: Multi-APN (Two DNNs per UE)"

ensure_core_running

SUPI="001010123456789"
IMSI="imsi-${SUPI}"
KEY="$BASE_KEY"

# Step 1: Ensure "ims" DNN is configured in AMF + SMF
info "Checking if 'ims' DNN is supported in AMF config..."
if ! docker exec free5gc-cp grep -q "ims" /free5gc/config/amfcfg.yaml 2>/dev/null; then
    warn "'ims' DNN not in AMF config. Adding it..."
    docker exec free5gc-cp sh -c "sed -i '/- internet/a\    - ims' /free5gc/config/amfcfg.yaml"
    info "Added 'ims' to AMF supportDnnList. Restart CP to apply."
    docker restart free5gc-cp >/dev/null 2>&1
    sleep 30
fi

# Step 2: Add ims DNN info to SMF via MongoDB (UPF pool reuse)
info "Ensuring 'ims' DNN routing in SMF UPF info..."
docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['NfProfile'].updateMany(
  { nfType: 'SMF' },
  { \$addToSet: { 'smfInfo.sNssaiSmfInfoList.\$[].dnnSmfInfoList': { dnn: 'ims' } } }
)" 2>/dev/null || true

# Step 3: Provision subscriber with both internet + ims DNNs
info "Provisioning subscriber with internet + ims DNNs..."
token=$(get_token) || { fail "Cannot get WebUI token"; exit 1; }
http_code=$(provision_subscriber "$IMSI" "$KEY" "$OPC" "$token")
patch_mongodb "$IMSI"
info "Provisioned $IMSI (HTTP $http_code)"

# Step 4: Generate UE config with TWO sessions (internet + ims)
info "Generating UE config with two PDU sessions..."
TMPDIR=$(mktemp -d)
generate_ue_config "$SUPI" "$KEY" "$OPC" "${TMPDIR}/ue_multi_apn.yaml" "internet,ims"
docker cp "${TMPDIR}/ue_multi_apn.yaml" ueransim:/ueransim/config/ue_multi_apn.yaml

# Step 5: Launch UE
kill_all_ues
info "Launching UE with multi-APN config..."
docker exec -d ueransim ./nr-ue -c ./config/ue_multi_apn.yaml
sleep 15

# Step 6: Check registration
status=$(docker exec ueransim ./nr-cli "$IMSI" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE registered: ${IMSI}"
else
    fail "UE registration failed"
    echo "$status"
fi

# Step 7: Check PDU sessions
ps_list=$(docker exec ueransim ./nr-cli "$IMSI" -e "ps-list" 2>/dev/null)
echo ""
info "PDU Session list:"
echo "$ps_list"
echo ""

internet_session=false
ims_session=false

if echo "$ps_list" | grep -q "internet"; then
    pass "PDU session on DNN 'internet' established"
    internet_session=true
else
    fail "No PDU session on DNN 'internet'"
fi

if echo "$ps_list" | grep -q "ims"; then
    pass "PDU session on DNN 'ims' established"
    ims_session=true
else
    warn "PDU session on DNN 'ims' not established"
    info "This may require SMF config changes to add 'ims' DNN with IP pool."
    info "Attempting manual PDU session establishment..."
    # Try to establish ims session manually via nr-cli
    docker exec ueransim ./nr-cli "$IMSI" -e "ps-establish IPv4 --dnn ims --sst 3 --sd 198153" 2>/dev/null
    sleep 5
    ps_list2=$(docker exec ueransim ./nr-cli "$IMSI" -e "ps-list" 2>/dev/null)
    if echo "$ps_list2" | grep -q "ims"; then
        pass "PDU session on DNN 'ims' established (manual)"
        ims_session=true
    else
        fail "PDU session on DNN 'ims' could not be established"
    fi
fi

# Step 8: Check TUN interfaces
tun_list=$(docker exec ueransim ip addr show 2>/dev/null | grep "uesimtun")
tun_count=$(echo "$tun_list" | grep -c "uesimtun" || echo 0)
info "TUN interfaces: ${tun_count}"
echo "$tun_list"

if [ "$tun_count" -ge 2 ]; then
    pass "Two or more TUN interfaces created (multi-APN confirmed)"
elif [ "$tun_count" -eq 1 ]; then
    warn "Only 1 TUN interface. Second DNN may need SMF/UPF config for 'ims'."
fi

# Cleanup
kill_all_ues
rm -rf "$TMPDIR"

# Summary
echo ""
if [ "$internet_session" = true ] && [ "$ims_session" = true ]; then
    echo -e "${GREEN}${BOLD}TC03 PASSED${NC}: UE has PDU sessions on both internet and ims"
else
    echo -e "${YELLOW}${BOLD}TC03 PARTIAL${NC}: internet=${internet_session}, ims=${ims_session}"
    info "To fully support 'ims' DNN, add it to smfcfg.yaml snssaiInfos and UPF DNN list."
fi
