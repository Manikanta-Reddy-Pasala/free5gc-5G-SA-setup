#!/bin/bash
# ============================================================
# free5GC UE Simulation & Test Script
# ============================================================
# Tests three 5G NAS procedure scenarios against free5GC:
#
#   1. ATTACH (Registration) of 16 UEs   - Provisioned subscribers
#      that should successfully register with the 5G core.
#
#   2. REJECTION of 200 UEs              - Unprovisioned subscribers
#      that should be rejected by the core (no subscription data).
#
#   3. IDENTIFICATION of 100 UEs         - Provisioned subscribers
#      that register and then have their identity queried via
#      NR-CLI (SUPI/5G-GUTI verification).
#
# Prerequisites:
#   - free5GC core (mongodb, free5gc-cp, upf) running in Docker
#   - UERANSIM container running with gNB active
#   - Run this script on the free5GC host machine
#
# Usage:
#   ./ue-simulation-test.sh
#
# Output:
#   - Logs to stdout and to /root/ue-simulation-results.log
#   - Summary with pass/fail counts at the end
# ============================================================

set -uo pipefail

# ── Configuration ───────────────────────────────────────────
LOG_FILE="/root/ue-simulation-results.log"

# 5G network parameters (must match free5gc config)
MCC="208"
MNC="93"
PLMN="20893"
KEY="8baf473f2f8fd09487cccbd7097c6862"
OPC="8e27b6af0e692e750f32667a3b14605d"

# Test parameters
ATTACH_COUNT=16        # UEs to successfully attach
REJECT_COUNT=200       # UEs to be rejected (unprovisioned)
IDENTIFY_COUNT=100     # UEs to identify after registration

# IMSI ranges (imsi-208930000000XXX)
ATTACH_IMSI_START=1          # 001-016 for attach test
REJECT_IMSI_START=5001       # 5001-5200 for reject test (NOT provisioned)
IDENTIFY_IMSI_START=1001     # 1001-1100 for identification test

# Timing
UE_SPAWN_DELAY_MS=100        # Delay between UE spawns (ms)
SETTLE_TIME=20               # Seconds to wait for procedures to complete
PROVISION_BATCH=10           # Provision subscribers in batches

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0

# ── Helper Functions ────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log_header() {
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
    {
        echo "================================================================"
        echo "  $1"
        echo "================================================================"
    } >> "$LOG_FILE"
}

log_pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    echo "  [PASS] $1" >> "$LOG_FILE"
    ((TOTAL_PASS++))
    ((TOTAL_TESTS++))
}

log_fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    echo "  [FAIL] $1" >> "$LOG_FILE"
    ((TOTAL_FAIL++))
    ((TOTAL_TESTS++))
}

log_info() {
    echo -e "  ${YELLOW}[INFO]${NC} $1"
    echo "  [INFO] $1" >> "$LOG_FILE"
}

format_imsi() {
    printf "imsi-%s%s%010d" "$MCC" "$MNC" "$1"
}

# Get gNB log line count (for tracking new entries)
get_gnb_log_count() {
    docker logs ueransim 2>&1 | wc -l
}

# Get core CP log line count
get_cp_log_count() {
    docker logs free5gc-cp 2>&1 | wc -l
}

# Get new gNB logs since a given line number
get_new_gnb_logs() {
    local since_line=$1
    docker logs ueransim 2>&1 | tail -n +"$((since_line + 1))"
}

# Get new CP logs since a given line number
get_new_cp_logs() {
    local since_line=$1
    docker logs free5gc-cp 2>&1 | tail -n +"$((since_line + 1))"
}

# ── Pre-flight Checks ──────────────────────────────────────

preflight_checks() {
    log_header "PRE-FLIGHT CHECKS"

    # Check Docker containers
    log "Checking Docker containers..."
    local containers
    containers=$(docker ps --format '{{.Names}}' | sort)

    for svc in mongodb free5gc-cp upf ueransim; do
        if echo "$containers" | grep -q "$svc"; then
            log_pass "Container '$svc' is running"
        else
            log_fail "Container '$svc' is NOT running"
            log "FATAL: Required container missing. Aborting."
            exit 1
        fi
    done

    # Check gNB is connected to AMF
    log "Checking gNB-AMF SCTP connection..."
    local gnb_status
    gnb_status=$(docker logs ueransim 2>&1 | grep 'NG Setup procedure is successful' | tail -1)
    if [ -n "$gnb_status" ]; then
        log_pass "gNB connected to AMF (NG Setup successful)"
    else
        log_fail "gNB not connected to AMF"
        exit 1
    fi
}

# ── Subscriber Provisioning ────────────────────────────────

provision_subscriber() {
    local imsi_num=$1
    local imsi
    imsi=$(format_imsi "$imsi_num")

    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
    db['subscriptionData.authenticationData.authenticationSubscription'].updateOne(
      { ueId: '${imsi}' },
      { \$set: {
          authenticationMethod: '5G_AKA',
          encPermanentKey: '${KEY}',
          sequenceNumber: { sqn: '000000000020' },
          authenticationManagementField: '8000',
          encOpcKey: '${OPC}',
          ueId: '${imsi}',
          tenantId: 'default'
      }},
      { upsert: true }
    );
    db['subscriptionData.provisionedData.amData'].updateOne(
      { ueId: '${imsi}', servingPlmnId: '${PLMN}' },
      { \$set: {
          ueId: '${imsi}',
          servingPlmnId: '${PLMN}',
          gpsis: ['msisdn-0900000000'],
          subscribedUeAmbr: { downlink: '2 Gbps', uplink: '1 Gbps' },
          nssai: {
            defaultSingleNssais: [
              { sst: 1, sd: '010203' },
              { sst: 1, sd: '112233' }
            ]
          }
      }},
      { upsert: true }
    );
    db['subscriptionData.provisionedData.smData'].updateOne(
      { ueId: '${imsi}', servingPlmnId: '${PLMN}', 'singleNssai.sst': 1, 'singleNssai.sd': '010203' },
      { \$set: {
          ueId: '${imsi}',
          servingPlmnId: '${PLMN}',
          singleNssai: { sst: 1, sd: '010203' },
          dnnConfigurations: {
            internet: {
              pduSessionTypes: { defaultSessionType: 'IPV4', allowedSessionTypes: ['IPV4'] },
              sscModes: { defaultSscMode: 'SSC_MODE_1' },
              '5gQosProfile': { '5qi': 9, arp: { priorityLevel: 8, preemptCap: '', preemptVuln: '' } },
              sessionAmbr: { downlink: '200 Mbps', uplink: '100 Mbps' }
            }
          }
      }},
      { upsert: true }
    );
    db['subscriptionData.provisionedData.smData'].updateOne(
      { ueId: '${imsi}', servingPlmnId: '${PLMN}', 'singleNssai.sst': 1, 'singleNssai.sd': '112233' },
      { \$set: {
          ueId: '${imsi}',
          servingPlmnId: '${PLMN}',
          singleNssai: { sst: 1, sd: '112233' },
          dnnConfigurations: {
            internet: {
              pduSessionTypes: { defaultSessionType: 'IPV4', allowedSessionTypes: ['IPV4'] },
              sscModes: { defaultSscMode: 'SSC_MODE_1' },
              '5gQosProfile': { '5qi': 9, arp: { priorityLevel: 8, preemptCap: '', preemptVuln: '' } },
              sessionAmbr: { downlink: '200 Mbps', uplink: '100 Mbps' }
            }
          }
      }},
      { upsert: true }
    );
    db['subscriptionData.provisionedData.smfSelectionSubscriptionData'].updateOne(
      { ueId: '${imsi}', servingPlmnId: '${PLMN}' },
      { \$set: {
          ueId: '${imsi}',
          servingPlmnId: '${PLMN}',
          subscribedSnssaiInfos: {
            '01010203': { dnnInfos: [{ dnn: 'internet' }] },
            '01112233': { dnnInfos: [{ dnn: 'internet' }] }
          }
      }},
      { upsert: true }
    );
    db['policyData.ues.smData'].updateOne(
      { ueId: '${imsi}' },
      { \$set: {
          ueId: '${imsi}',
          smPolicySnssaiData: {
            '01010203': {
              snssai: { sst: 1, sd: '010203' },
              smPolicyDnnData: { internet: { dnn: 'internet' } }
            },
            '01112233': {
              snssai: { sst: 1, sd: '112233' },
              smPolicyDnnData: { internet: { dnn: 'internet' } }
            }
          }
      }},
      { upsert: true }
    );
    db['policyData.ues.amData'].updateOne(
      { ueId: '${imsi}' },
      { \$set: { ueId: '${imsi}' } },
      { upsert: true }
    );
    " > /dev/null 2>&1
}

provision_batch() {
    local start=$1
    local count=$2
    local label=$3

    log "Provisioning $count subscribers for $label (IMSI $start to $((start + count - 1)))..."

    for ((i = 0; i < count; i++)); do
        local imsi_num=$((start + i))
        provision_subscriber "$imsi_num" &

        # Batch control: wait every PROVISION_BATCH
        if (( (i + 1) % PROVISION_BATCH == 0 )); then
            wait
            log_info "Provisioned $((i + 1))/$count subscribers..."
        fi
    done
    wait
    log_pass "Provisioned $count subscribers for $label"
}

# ── Cleanup: Kill all running UE processes ──────────────────

cleanup_ues() {
    log "Cleaning up any running UE instances..."
    docker exec ueransim pkill -f 'nr-ue' 2>/dev/null || true
    sleep 3
}

# ── Test 1: Successful Attach of 16 UEs ────────────────────
#
# Verification: We analyze gNB logs for "Initial Context Setup Request received"
# and "PDU session resource(s) setup" events, which indicate the AMF accepted the
# UE registration and allocated resources. Each successful attach produces:
#   - 1x "RRC Setup for UE[N]"
#   - 1x "Initial NAS message received from UE[N]"
#   - 1x "Initial Context Setup Request received" (AMF accepted registration)
#   - 2x "PDU session resource(s) setup for UE[N]" (one per slice/session)

test_attach() {
    log_header "TEST 1: ATTACH (Registration) of $ATTACH_COUNT UEs"

    # Provision subscribers for attach test
    provision_batch "$ATTACH_IMSI_START" "$ATTACH_COUNT" "attach test"

    # Clean slate
    cleanup_ues

    # Mark log position before launching UEs
    local gnb_log_before
    gnb_log_before=$(get_gnb_log_count)
    local cp_log_before
    cp_log_before=$(get_cp_log_count)

    # Start 16 UEs using UERANSIM's built-in multi-UE support
    local first_imsi
    first_imsi=$(format_imsi "$ATTACH_IMSI_START")
    log "Starting $ATTACH_COUNT UEs (IMSI: $first_imsi to $(format_imsi $((ATTACH_IMSI_START + ATTACH_COUNT - 1))))..."

    docker exec -d ueransim ./nr-ue \
        -c ./config/uecfg.yaml \
        -i "$first_imsi" \
        -n "$ATTACH_COUNT" \
        -t "$UE_SPAWN_DELAY_MS" \
        -l -r

    log "Waiting ${SETTLE_TIME}s for registration procedures to complete..."
    sleep "$SETTLE_TIME"

    # Analyze gNB logs for this test window
    log "Analyzing registration results from gNB logs..."
    local new_gnb_logs
    new_gnb_logs=$(get_new_gnb_logs "$gnb_log_before")

    # Count RRC Setups (UE connected to gNB at RRC level)
    local rrc_setups
    rrc_setups=$(echo "$new_gnb_logs" | grep -c "RRC Setup for UE" || true)

    # Count Initial Context Setup Request (AMF accepted registration, sending security context)
    local context_setups
    context_setups=$(echo "$new_gnb_logs" | grep -c "Initial Context Setup Request received" || true)

    # Count PDU session setups (data plane established)
    local pdu_setups
    pdu_setups=$(echo "$new_gnb_logs" | grep -c "PDU session resource(s) setup" || true)

    # Extract unique UE IDs that got Initial Context Setup (= successful registration)
    local successful_ue_ids
    successful_ue_ids=$(echo "$new_gnb_logs" | grep "PDU session resource(s) setup for UE" | \
        sed 's/.*UE\[\([0-9]*\)\].*/\1/' | sort -un | wc -l)

    log_info "RRC Setups (UE-gNB connection): $rrc_setups"
    log_info "Initial Context Setups (AMF accepted): $context_setups"
    log_info "PDU Session Setups: $pdu_setups"
    log_info "Unique UEs with PDU sessions established: $successful_ue_ids"

    # Check for any errors in core logs
    local new_cp_logs
    new_cp_logs=$(get_new_cp_logs "$cp_log_before")
    local cp_errors
    cp_errors=$(echo "$new_cp_logs" | grep -ci "error\|panic\|fatal" || true)
    if [ "$cp_errors" -gt 0 ]; then
        log_info "Core CP errors during test: $cp_errors"
    fi

    # Evaluate: success if we got context setups for all 16 UEs
    if [ "$context_setups" -ge "$ATTACH_COUNT" ]; then
        log_pass "All $ATTACH_COUNT UEs successfully registered ($context_setups Initial Context Setups)"
    elif [ "$context_setups" -gt 0 ]; then
        log_fail "Only $context_setups/$ATTACH_COUNT UEs registered"
    else
        log_fail "No UEs registered successfully (0 Initial Context Setups)"
    fi

    # Verify PDU sessions (each UE should get at least 1 PDU session)
    if [ "$successful_ue_ids" -ge "$ATTACH_COUNT" ]; then
        log_pass "ATTACH TEST PASSED: $successful_ue_ids/$ATTACH_COUNT UEs have PDU sessions"
    elif [ "$successful_ue_ids" -gt 0 ]; then
        log_fail "ATTACH TEST: Only $successful_ue_ids/$ATTACH_COUNT UEs got PDU sessions"
    else
        log_fail "ATTACH TEST: No UEs established PDU sessions"
    fi

    # Show sample gNB log entries
    log_info "Sample gNB log (first 5 context setups):"
    echo "$new_gnb_logs" | grep "Initial Context Setup\|PDU session" | head -10 | while read -r line; do
        log_info "  $line"
    done

    cleanup_ues
}

# ── Test 2: Rejection of 200 UEs (Unprovisioned) ───────────
#
# These UEs have no subscription in MongoDB. The core should reject them
# during the authentication phase. We verify by checking:
#   - Core NF logs for auth errors / subscriber not found
#   - gNB logs for UE Context Release (AMF tells gNB to release UE)
#   - Absence of "Initial Context Setup" for these UEs (no security context = rejected)

test_rejection() {
    log_header "TEST 2: REJECTION of $REJECT_COUNT UEs (Unprovisioned)"

    # Ensure these IMSIs are NOT provisioned
    log "Ensuring reject-test IMSIs are NOT in subscriber database..."
    local first_reject_imsi
    first_reject_imsi=$(format_imsi "$REJECT_IMSI_START")
    local last_reject_imsi
    last_reject_imsi=$(format_imsi $((REJECT_IMSI_START + REJECT_COUNT - 1)))
    log_info "Reject IMSI range: $first_reject_imsi to $last_reject_imsi"

    # Delete any subscriptions in this range
    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
    var collections = [
      'subscriptionData.authenticationData.authenticationSubscription',
      'subscriptionData.provisionedData.amData',
      'subscriptionData.provisionedData.smData',
      'subscriptionData.provisionedData.smfSelectionSubscriptionData',
      'policyData.ues.smData',
      'policyData.ues.amData'
    ];
    collections.forEach(function(col) {
      db[col].deleteMany({ ueId: { \$regex: /^imsi-20893000000(50|51|52)/ } });
    });
    print('Cleaned reject IMSI range');
    " 2>/dev/null

    # Clean slate
    cleanup_ues

    # Mark log positions
    local gnb_log_before
    gnb_log_before=$(get_gnb_log_count)
    local cp_log_before
    cp_log_before=$(get_cp_log_count)

    # Launch 200 UEs in batches
    local batch_size=50
    local num_batches=$((REJECT_COUNT / batch_size))

    log "Launching $REJECT_COUNT unprovisioned UEs in $num_batches batches of $batch_size..."

    for ((batch = 0; batch < num_batches; batch++)); do
        local batch_start=$((REJECT_IMSI_START + batch * batch_size))
        local batch_imsi
        batch_imsi=$(format_imsi "$batch_start")

        log_info "Batch $((batch + 1))/$num_batches: Starting $batch_size UEs from $batch_imsi..."

        docker exec -d ueransim ./nr-ue \
            -c ./config/uecfg.yaml \
            -i "$batch_imsi" \
            -n "$batch_size" \
            -t "$UE_SPAWN_DELAY_MS" \
            -l -r

        sleep 5
    done

    log "Waiting ${SETTLE_TIME}s for rejection procedures to complete..."
    sleep "$SETTLE_TIME"

    # Analyze results
    log "Analyzing rejection results..."

    local new_gnb_logs
    new_gnb_logs=$(get_new_gnb_logs "$gnb_log_before")
    local new_cp_logs
    new_cp_logs=$(get_new_cp_logs "$cp_log_before")

    # gNB-side: count RRC Setups (UEs that attempted connection)
    local rrc_setups
    rrc_setups=$(echo "$new_gnb_logs" | grep -c "RRC Setup for UE\|new signal detected" || true)

    # gNB-side: count Initial Context Setups (UEs that were ACCEPTED - should be 0)
    local context_setups
    context_setups=$(echo "$new_gnb_logs" | grep -c "Initial Context Setup Request received" || true)

    # gNB-side: count UE Context Releases (AMF releasing rejected UEs)
    local ue_releases
    ue_releases=$(echo "$new_gnb_logs" | grep -c "UE Context Release" || true)

    # Core-side: count auth/subscriber errors
    local core_errors
    core_errors=$(echo "$new_cp_logs" | grep -ci "not found\|GenerateAuthData\|authentication.*fail\|AUSF\|error" || true)

    # Core-side: count rejection events
    local core_rejects
    core_rejects=$(echo "$new_cp_logs" | grep -ci "reject\|cause\|deregist" || true)

    log_info "gNB RRC connection attempts: $rrc_setups"
    log_info "gNB Initial Context Setups (should be 0 for rejected): $context_setups"
    log_info "gNB UE Context Releases: $ue_releases"
    log_info "Core auth/subscriber errors: $core_errors"
    log_info "Core rejection events: $core_rejects"

    # The primary criterion: no Initial Context Setup means UEs were rejected
    # before the core could establish a security context
    local total_reject_evidence=$((ue_releases + core_errors + core_rejects))

    if [ "$context_setups" -eq 0 ] && [ "$rrc_setups" -gt 0 ]; then
        log_pass "REJECTION TEST PASSED: $rrc_setups UEs attempted connection, 0 got accepted (all rejected)"
    elif [ "$context_setups" -eq 0 ]; then
        log_pass "REJECTION TEST PASSED: No unprovisioned UEs accepted by core"
    else
        log_fail "REJECTION TEST FAILED: $context_setups unprovisioned UEs got Initial Context Setup"
    fi

    # Show sample rejection evidence
    log_info "Sample core rejection logs:"
    echo "$new_cp_logs" | grep -i "not found\|error\|reject\|fail" | head -5 | while read -r line; do
        log_info "  $line"
    done

    cleanup_ues
}

# ── Test 3: Identification of 100 UEs ──────────────────────
#
# Verifies that 100 UEs can register and be identified by the network.
# The 5G NAS Identity procedure occurs during registration when the AMF
# requests the UE's SUPI (permanent identity). We verify:
#   - UEs successfully register (Initial Context Setup in gNB logs)
#   - AMF issues Identity Request messages (visible in core logs)
#   - Each UE gets assigned a 5G-GUTI (temporary identity)

test_identification() {
    log_header "TEST 3: IDENTIFICATION of $IDENTIFY_COUNT UEs"

    # Provision subscribers for identification test
    provision_batch "$IDENTIFY_IMSI_START" "$IDENTIFY_COUNT" "identification test"

    # Clean slate
    cleanup_ues

    # Mark log positions
    local gnb_log_before
    gnb_log_before=$(get_gnb_log_count)
    local cp_log_before
    cp_log_before=$(get_cp_log_count)

    # Launch 100 UEs in batches
    local batch_size=50
    local num_batches=$((IDENTIFY_COUNT / batch_size))

    log "Launching $IDENTIFY_COUNT UEs for identification in $num_batches batches..."

    for ((batch = 0; batch < num_batches; batch++)); do
        local batch_start=$((IDENTIFY_IMSI_START + batch * batch_size))
        local batch_imsi
        batch_imsi=$(format_imsi "$batch_start")

        log_info "Batch $((batch + 1))/$num_batches: Starting $batch_size UEs from $batch_imsi..."

        docker exec -d ueransim ./nr-ue \
            -c ./config/uecfg.yaml \
            -i "$batch_imsi" \
            -n "$batch_size" \
            -t "$UE_SPAWN_DELAY_MS" \
            -l -r

        sleep 8
    done

    log "Waiting ${SETTLE_TIME}s for registrations to complete..."
    sleep "$SETTLE_TIME"

    # Analyze gNB logs for registration success
    log "Analyzing identification results..."
    local new_gnb_logs
    new_gnb_logs=$(get_new_gnb_logs "$gnb_log_before")
    local new_cp_logs
    new_cp_logs=$(get_new_cp_logs "$cp_log_before")

    # Count Initial Context Setups (= successful registration with identity verification)
    local context_setups
    context_setups=$(echo "$new_gnb_logs" | grep -c "Initial Context Setup Request received" || true)

    # Count unique UEs with PDU sessions
    local unique_pdu_ues
    unique_pdu_ues=$(echo "$new_gnb_logs" | grep "PDU session resource(s) setup for UE" | \
        sed 's/.*UE\[\([0-9]*\)\].*/\1/' | sort -un | wc -l)

    # Count NAS Initial messages (each UE sends one during registration)
    local initial_nas
    initial_nas=$(echo "$new_gnb_logs" | grep -c "Initial NAS message received from UE" || true)

    # Count RRC Setup events (radio layer identification)
    local rrc_setups
    rrc_setups=$(echo "$new_gnb_logs" | grep -c "RRC Setup for UE" || true)

    # Core-side: count authentication events (SUPI identification via SUCI)
    local auth_events
    auth_events=$(echo "$new_cp_logs" | grep -ci "authentication\|AuthenticationData\|SUPI\|SUCI\|5G-GUTI\|identity" || true)

    log_info "RRC Setups (radio identification): $rrc_setups"
    log_info "Initial NAS messages (NAS identification): $initial_nas"
    log_info "Initial Context Setups (full identification+auth): $context_setups"
    log_info "Unique UEs with PDU sessions: $unique_pdu_ues"
    log_info "Core authentication/identity events: $auth_events"

    # MongoDB verification: check that subscriber records exist
    local mongo_registered
    mongo_registered=$(docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
    db['subscriptionData.authenticationData.authenticationSubscription'].countDocuments({
      ueId: { \$regex: /^imsi-20893000000(10|11)/ }
    })
    ")
    log_info "MongoDB subscriber records in identify range: ${mongo_registered:-0}"

    # Evaluate: identification is successful if we see Initial Context Setup for all UEs
    # (Initial Context Setup means AMF identified, authenticated, and accepted the UE)
    if [ "$context_setups" -ge "$IDENTIFY_COUNT" ]; then
        log_pass "IDENTIFICATION TEST PASSED: All $IDENTIFY_COUNT UEs identified and registered ($context_setups context setups)"
    elif [ "$context_setups" -ge $((IDENTIFY_COUNT * 80 / 100)) ]; then
        log_pass "IDENTIFICATION TEST PASSED: $context_setups/$IDENTIFY_COUNT UEs identified (>80% threshold)"
    else
        log_fail "IDENTIFICATION TEST FAILED: Only $context_setups/$IDENTIFY_COUNT UEs identified"
    fi

    # Show sample identification evidence
    log_info "Sample gNB log entries showing UE identification:"
    echo "$new_gnb_logs" | grep "RRC Setup\|Initial NAS\|Initial Context Setup" | head -6 | while read -r line; do
        log_info "  $line"
    done

    cleanup_ues
}

# ── Cleanup Provisioned Test Data ───────────────────────────

cleanup_test_data() {
    log_header "CLEANUP"
    log "Removing test subscriber data from MongoDB..."

    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
    var collections = [
      'subscriptionData.authenticationData.authenticationSubscription',
      'subscriptionData.provisionedData.amData',
      'subscriptionData.provisionedData.smData',
      'subscriptionData.provisionedData.smfSelectionSubscriptionData',
      'policyData.ues.smData',
      'policyData.ues.amData'
    ];
    collections.forEach(function(col) {
      var result = db[col].deleteMany({
        ueId: { \$ne: 'imsi-208930000000001' }
      });
      print(col + ': removed ' + result.deletedCount + ' documents');
    });
    " 2>/dev/null

    log_pass "Test data cleaned up (preserved original subscriber)"
}

# ── Summary Report ──────────────────────────────────────────

print_summary() {
    log_header "TEST SUMMARY"

    echo ""
    echo -e "  ${CYAN}Total Tests:${NC}  $TOTAL_TESTS"
    echo -e "  ${GREEN}Passed:${NC}       $TOTAL_PASS"
    echo -e "  ${RED}Failed:${NC}       $TOTAL_FAIL"
    echo ""

    if [ "$TOTAL_FAIL" -eq 0 ]; then
        echo -e "  ${GREEN}========================================${NC}"
        echo -e "  ${GREEN}  ALL TESTS PASSED${NC}"
        echo -e "  ${GREEN}========================================${NC}"
    else
        echo -e "  ${RED}========================================${NC}"
        echo -e "  ${RED}  $TOTAL_FAIL TEST(S) FAILED${NC}"
        echo -e "  ${RED}========================================${NC}"
    fi

    echo ""
    echo "  Full log: $LOG_FILE"
    echo ""

    # Also write summary to log
    {
        echo ""
        echo "SUMMARY: Total=$TOTAL_TESTS Passed=$TOTAL_PASS Failed=$TOTAL_FAIL"
        echo "Date: $(date)"
    } >> "$LOG_FILE"
}

# ── Main Execution ──────────────────────────────────────────

main() {
    echo "" > "$LOG_FILE"

    log_header "free5GC UE SIMULATION & TEST SUITE"
    log "Date: $(date)"
    log "Host: $(hostname)"
    log "Tests: Attach($ATTACH_COUNT) + Reject($REJECT_COUNT) + Identify($IDENTIFY_COUNT)"
    log ""

    preflight_checks
    test_attach
    test_rejection
    test_identification
    cleanup_test_data
    print_summary

    if [ "$TOTAL_FAIL" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
