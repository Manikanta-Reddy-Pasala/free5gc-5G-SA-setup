#!/bin/bash
# ============================================================
# free5GC UE Flow Trace Script
# ============================================================
# Traces 5G UE registration and rejection flows across ALL
# network functions in chronological order, showing the
# complete request/response chain.
#
# Tests:
#   1. Single UE registration flow (detailed trace)
#   2. 16 UE attach (flow + per-UE summary)
#   3. 200 UE rejection (first 3 detailed + summary)
#
# Prerequisites:
#   - free5GC minimal mode running (mongodb, free5gc-cp, upf, ueransim)
#   - gNB connected to AMF
#
# Usage:
#   ./ue-flow-trace.sh              # Run all 3 tests
#   ./ue-flow-trace.sh --single     # Single UE trace only
#   ./ue-flow-trace.sh --attach     # 16 UE attach only
#   ./ue-flow-trace.sh --reject     # 200 UE reject only
# ============================================================

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────
LOG_FILE="/root/ue-flow-trace-$(date '+%Y%m%d-%H%M%S').log"

MCC="208"
MNC="93"
PLMN="20893"
KEY="8baf473f2f8fd09487cccbd7097c6862"
OPC="8e27b6af0e692e750f32667a3b14605d"

ATTACH_COUNT=16
REJECT_COUNT=200
REJECT_IMSI_START=5001
PROVISION_BATCH=10
UE_SPAWN_DELAY_MS=100

NF_LIST=(amf ausf udm udr smf nrf nssf pcf)

# Colors (using $'...' for real ESC bytes)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# Counters
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0

# Log positions (set by snapshot_log_positions)
declare -A NF_POS
POS_UPF=0
POS_UERANSIM=0

# ── Helper Functions ──────────────────────────────────────────

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
        echo ""
        echo "================================================================"
        echo "  $1"
        echo "================================================================"
        echo ""
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

cleanup_ues() {
    log "Cleaning up UE instances..."
    docker exec ueransim pkill -f 'nr-ue' 2>/dev/null || true
    sleep 3
}

# ── Preflight ─────────────────────────────────────────────────

preflight_checks() {
    log_header "PRE-FLIGHT CHECKS"

    local containers
    containers=$(docker ps --format '{{.Names}}' | sort)

    for svc in mongodb free5gc-cp upf ueransim; do
        if echo "$containers" | grep -q "$svc"; then
            log_pass "Container '$svc' is running"
        else
            log_fail "Container '$svc' is NOT running"
            exit 1
        fi
    done

    local gnb_status
    gnb_status=$(docker logs ueransim 2>&1 | grep 'NG Setup procedure is successful' | tail -1)
    if [ -n "$gnb_status" ]; then
        log_pass "gNB connected to AMF"
    else
        log_fail "gNB not connected to AMF"
        exit 1
    fi

    if command -v gawk &>/dev/null || command -v awk &>/dev/null; then
        log_pass "awk available"
    else
        log_fail "awk not found"
        exit 1
    fi
}

# ── Subscriber Provisioning ──────────────────────────────────

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
          ueId: '${imsi}', servingPlmnId: '${PLMN}',
          gpsis: ['msisdn-0900000000'],
          subscribedUeAmbr: { downlink: '2 Gbps', uplink: '1 Gbps' },
          nssai: { defaultSingleNssais: [{ sst: 1, sd: '010203' }, { sst: 1, sd: '112233' }] }
      }},
      { upsert: true }
    );
    db['subscriptionData.provisionedData.smData'].updateOne(
      { ueId: '${imsi}', servingPlmnId: '${PLMN}', 'singleNssai.sst': 1, 'singleNssai.sd': '010203' },
      { \$set: {
          ueId: '${imsi}', servingPlmnId: '${PLMN}',
          singleNssai: { sst: 1, sd: '010203' },
          dnnConfigurations: { internet: {
            pduSessionTypes: { defaultSessionType: 'IPV4', allowedSessionTypes: ['IPV4'] },
            sscModes: { defaultSscMode: 'SSC_MODE_1' },
            '5gQosProfile': { '5qi': 9, arp: { priorityLevel: 8, preemptCap: '', preemptVuln: '' } },
            sessionAmbr: { downlink: '200 Mbps', uplink: '100 Mbps' }
          }}
      }},
      { upsert: true }
    );
    db['subscriptionData.provisionedData.smData'].updateOne(
      { ueId: '${imsi}', servingPlmnId: '${PLMN}', 'singleNssai.sst': 1, 'singleNssai.sd': '112233' },
      { \$set: {
          ueId: '${imsi}', servingPlmnId: '${PLMN}',
          singleNssai: { sst: 1, sd: '112233' },
          dnnConfigurations: { internet: {
            pduSessionTypes: { defaultSessionType: 'IPV4', allowedSessionTypes: ['IPV4'] },
            sscModes: { defaultSscMode: 'SSC_MODE_1' },
            '5gQosProfile': { '5qi': 9, arp: { priorityLevel: 8, preemptCap: '', preemptVuln: '' } },
            sessionAmbr: { downlink: '200 Mbps', uplink: '100 Mbps' }
          }}
      }},
      { upsert: true }
    );
    db['subscriptionData.provisionedData.smfSelectionSubscriptionData'].updateOne(
      { ueId: '${imsi}', servingPlmnId: '${PLMN}' },
      { \$set: {
          ueId: '${imsi}', servingPlmnId: '${PLMN}',
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
            '01010203': { snssai: { sst: 1, sd: '010203' }, smPolicyDnnData: { internet: { dnn: 'internet' } } },
            '01112233': { snssai: { sst: 1, sd: '112233' }, smPolicyDnnData: { internet: { dnn: 'internet' } } }
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

    log "Provisioning $count subscribers for $label..."
    for ((i = 0; i < count; i++)); do
        provision_subscriber "$((start + i))" &
        if (( (i + 1) % PROVISION_BATCH == 0 )); then
            wait
        fi
    done
    wait
    log_pass "Provisioned $count subscribers"
}

# ── Log Position Snapshotting ─────────────────────────────────

snapshot_log_positions() {
    for nf in "${NF_LIST[@]}"; do
        NF_POS[$nf]=$(docker exec free5gc-cp sh -c "wc -l < /var/log/free5gc/${nf}.log 2>/dev/null" 2>/dev/null || echo 0)
    done
    POS_UPF=$(docker logs upf 2>&1 | wc -l)
    POS_UERANSIM=$(docker logs ueransim 2>&1 | wc -l)
}

# ── Log Collection & Merge ────────────────────────────────────

collect_all_logs() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Collect from each CP NF log file (parallel)
    for nf in "${NF_LIST[@]}"; do
        local since_line=${NF_POS[$nf]}
        local nf_upper="${nf^^}"
        (
            docker exec free5gc-cp tail -n +$((since_line + 1)) "/var/log/free5gc/${nf}.log" 2>/dev/null \
            | awk -v nf="$nf_upper" '
            {
                # Strip ANSI codes
                gsub(/\033\[[0-9;]*m/, "")
                # Remove leading/trailing whitespace from cleaned line
                gsub(/^[ \t]+/, "")

                # Match RFC3339Nano timestamp
                if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T([0-9]{2}:[0-9]{2}:[0-9]{2})\.([0-9]+)Z/)) {
                    # Extract time and fractional
                    ts = $0
                    sub(/Z.*/, "", ts)
                    sub(/.*T/, "", ts)
                    split(ts, tp, ".")
                    time_part = tp[1]
                    frac = tp[2]
                    # Pad to 9 digits
                    while (length(frac) < 9) frac = frac "0"
                    sort_key = time_part "." frac

                    # Get everything after timestamp
                    rest = $0
                    sub(/^[^ ]+ /, "", rest)

                    # Parse [LEVEL][NF][SubModule] pattern
                    level = "INFO"
                    submod = "Main"
                    msg = rest

                    if (match(rest, /\[([A-Z]+)\]\[([A-Za-z]+)\]\[([^\]]*)\]/, parts)) {
                        level = parts[1]
                        submod = parts[3]
                        msg = rest
                        sub(/^(\[[^\]]*\])+[ ]*/, "", msg)
                    } else if (match(rest, /\[([A-Z]+)\]\[([A-Za-z]+)\]/, parts)) {
                        level = parts[1]
                        submod = parts[2]
                        msg = rest
                        sub(/^(\[[^\]]*\])+[ ]*/, "", msg)
                    }

                    print sort_key "\x01" nf "\x01" submod "\x01" level "\x01" msg
                }
            }
            ' > "${tmp_dir}/${nf}.tagged"
        ) &
    done

    # Collect UPF logs
    (
        docker logs upf 2>&1 | tail -n +$((POS_UPF + 1)) \
        | awk '
        {
            gsub(/\033\[[0-9;]*m/, "")
            gsub(/^[ \t]+/, "")
            if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T([0-9]{2}:[0-9]{2}:[0-9]{2})\.([0-9]+)Z/)) {
                ts = $0; sub(/Z.*/, "", ts); sub(/.*T/, "", ts)
                split(ts, tp, "."); frac = tp[2]
                while (length(frac) < 9) frac = frac "0"
                sort_key = tp[1] "." frac
                rest = $0; sub(/^[^ ]+ /, "", rest)
                level = "INFO"; submod = "Main"; msg = rest
                if (match(rest, /\[([A-Z]+)\]\[([A-Za-z]+)\]\[([^\]]*)\]/, p)) {
                    level = p[1]; submod = p[3]; msg = rest; sub(/^(\[[^\]]*\])+[ ]*/, "", msg)
                } else if (match(rest, /\[([A-Z]+)\]\[([A-Za-z]+)\]/, p)) {
                    level = p[1]; submod = p[2]; msg = rest; sub(/^(\[[^\]]*\])+[ ]*/, "", msg)
                }
                print sort_key "\x01" "UPF" "\x01" submod "\x01" level "\x01" msg
            }
        }
        ' > "${tmp_dir}/upf.tagged"
    ) &

    # Collect UERANSIM logs (different timestamp format)
    (
        docker logs ueransim 2>&1 | tail -n +$((POS_UERANSIM + 1)) \
        | awk '
        {
            # Format: [2026-02-10 13:53:49.039] [module] [level] message
            if (match($0, /^\[([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2})\.([0-9]+)\]/, ts)) {
                time_part = ts[2]
                frac = ts[3]
                while (length(frac) < 9) frac = frac "0"
                sort_key = time_part "." frac

                rest = $0
                sub(/^\[[^\]]*\] /, "", rest)

                module = "gnb"; level = "info"; msg = rest
                if (match(rest, /^\[([^\]]*)\] \[([^\]]*)\] (.*)/, p)) {
                    module = p[1]; level = p[2]; msg = p[3]
                }

                print sort_key "\x01" "UERANSIM" "\x01" module "\x01" toupper(level) "\x01" msg
            }
        }
        ' > "${tmp_dir}/ueransim.tagged"
    ) &

    wait

    # Merge and sort chronologically
    cat "${tmp_dir}"/*.tagged 2>/dev/null | sort -t$'\x01' -k1,1 > "${tmp_dir}/merged.log"

    echo "${tmp_dir}"
}

# ── Flow Rendering ────────────────────────────────────────────

render_flow() {
    local merged_file="$1"
    local filter_pattern="${2:-}"

    local input_cmd="cat"
    if [ -n "$filter_pattern" ]; then
        input_cmd="grep -E"
    fi

    local line_count=0

    while IFS=$'\x01' read -r ts nf submod level message; do
        [ -z "$ts" ] && continue
        ((line_count++))

        # Truncate timestamp to milliseconds for display
        local display_ts
        display_ts="${ts%${ts#*.???}}"

        # Determine prefix based on line type
        local prefix="    "
        if [[ "$message" =~ Handle\ Registration\ Request|Authentication\ procedure$|Send\ Authentication\ Request|Authentication\ Success|Send\ Security\ Mode\ Command|Handle\ Security\ Mode\ Complete|Send\ Registration\ Accept|Handle\ Registration\ Complete|ContextSetup\ Success|RRC\ Setup\ for\ UE|Initial\ Context\ Setup\ Request\ received|PDU\ session\ resource ]]; then
            prefix=" ==> "
        elif [[ "$submod" = "GIN" && "$message" =~ POST|PUT ]]; then
            prefix=" >>> "
        elif [[ "$submod" = "GIN" ]]; then
            prefix=" <<< "
        elif [[ "$message" =~ [Ee]rror|[Ff]ail|[Rr]eject|Nil\ Permanent ]]; then
            prefix=" [!!]"
        fi

        # NF color
        local color=""
        case "$nf" in
            UERANSIM) color="$CYAN" ;;
            AMF)      color="$GREEN" ;;
            AUSF)     color="${BOLD}${YELLOW}" ;;
            UDM|UDR)  color="$YELLOW" ;;
            SMF)      color="$BLUE" ;;
            UPF)      color="$MAGENTA" ;;
        esac

        local nf_pad
        nf_pad=$(printf "%-10s" "$nf")
        local sub_pad
        sub_pad=$(printf "%-10s" "[$submod]")

        # Console output (colored)
        printf "%s %s%s %s %s [%-4s]  %s%s\n" \
            "$display_ts" "$color" "$prefix" "$nf_pad" "$sub_pad" "$level" "$message" "$NC"

        # File output (plain)
        printf "%s %s %s %s [%-4s]  %s\n" \
            "$display_ts" "$prefix" "$nf_pad" "$sub_pad" "$level" "$message" \
            >> "$LOG_FILE"

    done < <(
        if [ -n "$filter_pattern" ]; then
            grep -aE "$filter_pattern" "$merged_file"
        else
            cat "$merged_file"
        fi
    )

    log_info "Flow lines rendered: $line_count"
}

# ── Per-UE Summary Table ─────────────────────────────────────

print_ue_summary_table() {
    local merged_file="$1"
    local start_num="$2"
    local count="$3"

    local header
    header=$(printf "  %-4s  %-28s  %-12s  %-8s" \
        "UE#" "IMSI" "Status" "PDU")
    echo -e "${BOLD}${header}${NC}"
    echo "$header" >> "$LOG_FILE"

    local divider="  ----  ----------------------------  ------------  --------"
    echo "$divider"
    echo "$divider" >> "$LOG_FILE"

    local total_registered=0
    local total_pdu=0

    # Count total PDU sessions and context setups from the merged log
    local all_context
    all_context=$(grep -ca "Initial Context Setup Request received\|Send Initial Context Setup Request" "$merged_file" 2>/dev/null); all_context=${all_context:-0}
    local all_pdu
    all_pdu=$(grep -ca "PDU session resource(s) setup" "$merged_file" 2>/dev/null); all_pdu=${all_pdu:-0}

    for ((i = 0; i < count; i++)); do
        local ue_num=$((start_num + i))
        local imsi
        imsi=$(format_imsi "$ue_num")
        local ue_idx=$((i + 1))

        # Match by IMSI/SUCI in AMF logs
        local imsi_suffix
        imsi_suffix=$(printf "%010d" "$ue_num")
        local suci_pattern="suci-0-${MCC}-${MNC}-0000-0-0-${imsi_suffix}"

        local status="NO_ATTEMPT"
        if grep -qa "Send Registration Accept" "$merged_file" 2>/dev/null && \
           grep -qa "${suci_pattern}\|${imsi}" "$merged_file" 2>/dev/null; then
            # Check if this specific IMSI got a registration accept
            # Look for the SUCI appearing before a Registration Accept
            if grep -qa "MobileIdentity5GS: SUCI\[${suci_pattern}\]" "$merged_file" 2>/dev/null; then
                status="REGISTERED"
                ((total_registered++))
            fi
        fi
        if [ "$status" = "NO_ATTEMPT" ] && grep -qa "MobileIdentity5GS: SUCI\[${suci_pattern}\]" "$merged_file" 2>/dev/null; then
            status="ATTEMPTED"
        fi

        local line
        line=$(printf "  %-4d  %-28s  %-12s" "$ue_idx" "$imsi" "$status")

        if [ "$status" = "REGISTERED" ]; then
            echo -e "  ${GREEN}$(printf "%-4d" "$ue_idx")${NC}  $imsi  ${GREEN}$status${NC}"
        else
            echo -e "  ${RED}$(printf "%-4d" "$ue_idx")${NC}  $imsi  ${RED}$status${NC}"
        fi
        echo "$line" >> "$LOG_FILE"
    done

    echo ""
    log_info "Total registered: $total_registered/$count"
    log_info "Context Setup Requests: $all_context, PDU sessions: $all_pdu"
}

# ── Rejection Summary ────────────────────────────────────────

print_rejection_summary() {
    local merged_file="$1"

    local total_rrc
    total_rrc=$(grep -ca "RRC Setup for UE" "$merged_file" 2>/dev/null); total_rrc=${total_rrc:-0}
    local total_nas
    total_nas=$(grep -ca "Initial NAS message received" "$merged_file" 2>/dev/null); total_nas=${total_nas:-0}
    local total_context
    total_context=$(grep -ca "Initial Context Setup Request received" "$merged_file" 2>/dev/null); total_context=${total_context:-0}
    local total_reject
    total_reject=$(grep -ca "Registration Reject\|Send Registration Reject" "$merged_file" 2>/dev/null); total_reject=${total_reject:-0}
    local total_auth_err
    total_auth_err=$(grep -ca "Authenticate Request Error\|Nil PermanentKey\|not found" "$merged_file" 2>/dev/null); total_auth_err=${total_auth_err:-0}

    echo ""
    printf "  %-45s  %s\n" "RRC Setup attempts:" "$total_rrc"
    printf "  %-45s  %s\n" "Initial NAS messages:" "$total_nas"
    printf "  %-45s  ${RED}%s${NC}\n" "Authentication errors:" "$total_auth_err"
    printf "  %-45s  ${RED}%s${NC}\n" "Registration Rejects sent:" "$total_reject"
    printf "  %-45s  ${GREEN}%s${NC}\n" "Initial Context Setups (should be 0):" "$total_context"
    echo ""

    {
        printf "  %-45s  %s\n" "RRC Setup attempts:" "$total_rrc"
        printf "  %-45s  %s\n" "Initial NAS messages:" "$total_nas"
        printf "  %-45s  %s\n" "Authentication errors:" "$total_auth_err"
        printf "  %-45s  %s\n" "Registration Rejects sent:" "$total_reject"
        printf "  %-45s  %s\n" "Initial Context Setups (should be 0):" "$total_context"
    } >> "$LOG_FILE"

    if [ "$total_context" -eq 0 ] && [ "$total_rrc" -gt 0 ]; then
        log_pass "All $total_rrc UE attempts rejected, 0 accepted"
    elif [ "$total_context" -gt 0 ]; then
        log_fail "$total_context UEs unexpectedly accepted"
    else
        log_fail "No UE connection attempts detected"
    fi
}

# ── Cleanup Test Data ─────────────────────────────────────────

cleanup_test_data() {
    log "Removing test subscriber data..."
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
      db[col].deleteMany({ ueId: { \$ne: 'imsi-208930000000001' } });
    });
    " 2>/dev/null
    log_info "Test data cleaned (preserved original subscriber)"
}

# ── Test 1: Single UE Registration Trace ─────────────────────

trace_single_ue() {
    log_header "TRACE 1: Single UE Registration Flow"

    provision_subscriber 1
    log_pass "Provisioned subscriber imsi-208930000000001"

    cleanup_ues
    snapshot_log_positions

    local imsi
    imsi=$(format_imsi 1)
    log "Starting 1 UE ($imsi)..."
    docker exec -d ueransim ./nr-ue \
        -c ./config/uecfg.yaml \
        -i "$imsi" \
        -n 1 \
        -t "$UE_SPAWN_DELAY_MS" \
        -l -r

    log "Waiting 15s for registration + PDU session setup..."
    sleep 15

    local tmp_dir
    tmp_dir=$(collect_all_logs)

    log_header "CHRONOLOGICAL FLOW: Single UE Registration"
    echo ""
    echo -e "${BOLD}$(printf "%-12s %-5s %-10s %-10s %-6s  %s" "TIMESTAMP" "TYPE" "SERVICE" "MODULE" "LEVEL" "MESSAGE")${NC}"
    echo "$(printf "%-12s %-5s %-10s %-10s %-6s  %s" "TIMESTAMP" "TYPE" "SERVICE" "MODULE" "LEVEL" "MESSAGE")" >> "$LOG_FILE"
    echo "------------ ----- ---------- ---------- ------  -----------------------------------------------"
    echo "------------ ----- ---------- ---------- ------  -----------------------------------------------" >> "$LOG_FILE"
    render_flow "${tmp_dir}/merged.log"

    # Verify
    local context_setups
    context_setups=$(grep -ca "Initial Context Setup Request received" "${tmp_dir}/merged.log" 2>/dev/null); context_setups=${context_setups:-0}
    local pdu_sessions
    pdu_sessions=$(grep -ca "PDU session resource(s) setup" "${tmp_dir}/merged.log" 2>/dev/null); pdu_sessions=${pdu_sessions:-0}

    echo ""
    if [ "$context_setups" -ge 1 ]; then
        log_pass "UE registration successful"
    else
        log_fail "UE registration failed"
    fi
    if [ "$pdu_sessions" -ge 1 ]; then
        log_pass "PDU sessions established: $pdu_sessions"
    else
        log_fail "No PDU sessions"
    fi

    cleanup_ues
    rm -rf "$tmp_dir"
}

# ── Test 2: 16 UE Attach Trace ───────────────────────────────

trace_16ue_attach() {
    log_header "TRACE 2: 16 UE Attach Flow"

    provision_batch 1 "$ATTACH_COUNT" "16 UE attach"

    cleanup_ues
    snapshot_log_positions

    local first_imsi
    first_imsi=$(format_imsi 1)
    log "Starting $ATTACH_COUNT UEs ($first_imsi to $(format_imsi $ATTACH_COUNT))..."
    docker exec -d ueransim ./nr-ue \
        -c ./config/uecfg.yaml \
        -i "$first_imsi" \
        -n "$ATTACH_COUNT" \
        -t "$UE_SPAWN_DELAY_MS" \
        -l -r

    log "Waiting 25s for all registrations..."
    sleep 25

    local tmp_dir
    tmp_dir=$(collect_all_logs)

    log_header "CHRONOLOGICAL FLOW: 16 UE Attach"
    echo ""
    echo -e "${BOLD}$(printf "%-12s %-5s %-10s %-10s %-6s  %s" "TIMESTAMP" "TYPE" "SERVICE" "MODULE" "LEVEL" "MESSAGE")${NC}"
    echo "$(printf "%-12s %-5s %-10s %-10s %-6s  %s" "TIMESTAMP" "TYPE" "SERVICE" "MODULE" "LEVEL" "MESSAGE")" >> "$LOG_FILE"
    echo "------------ ----- ---------- ---------- ------  -----------------------------------------------"
    echo "------------ ----- ---------- ---------- ------  -----------------------------------------------" >> "$LOG_FILE"
    render_flow "${tmp_dir}/merged.log"

    log_header "PER-UE STATUS SUMMARY"
    print_ue_summary_table "${tmp_dir}/merged.log" 1 "$ATTACH_COUNT"

    cleanup_ues
    rm -rf "$tmp_dir"
}

# ── Test 3: 200 UE Rejection Trace ───────────────────────────

trace_200ue_reject() {
    log_header "TRACE 3: 200 UE Rejection Flow (Unprovisioned)"

    # Ensure reject range is NOT provisioned
    log "Ensuring reject-test IMSIs are NOT provisioned..."
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
    " 2>/dev/null

    cleanup_ues
    snapshot_log_positions

    # Launch 200 UEs in 4 batches of 50
    local batch_size=50
    local num_batches=$((REJECT_COUNT / batch_size))

    log "Launching $REJECT_COUNT unprovisioned UEs in $num_batches batches..."
    for ((batch = 0; batch < num_batches; batch++)); do
        local batch_start=$((REJECT_IMSI_START + batch * batch_size))
        local batch_imsi
        batch_imsi=$(format_imsi "$batch_start")
        log_info "Batch $((batch + 1))/$num_batches: 50 UEs from $batch_imsi"

        docker exec -d ueransim ./nr-ue \
            -c ./config/uecfg.yaml \
            -i "$batch_imsi" \
            -n "$batch_size" \
            -t "$UE_SPAWN_DELAY_MS" \
            -l -r

        sleep 5
    done

    log "Waiting 30s for rejection procedures..."
    sleep 30

    local tmp_dir
    tmp_dir=$(collect_all_logs)

    # Show first 3 UE rejection flows in detail
    log_header "DETAILED REJECTION FLOW (First 3 UEs)"
    echo ""
    echo -e "${BOLD}$(printf "%-12s %-5s %-10s %-10s %-6s  %s" "TIMESTAMP" "TYPE" "SERVICE" "MODULE" "LEVEL" "MESSAGE")${NC}"
    echo "$(printf "%-12s %-5s %-10s %-10s %-6s  %s" "TIMESTAMP" "TYPE" "SERVICE" "MODULE" "LEVEL" "MESSAGE")" >> "$LOG_FILE"
    echo "------------ ----- ---------- ---------- ------  -----------------------------------------------"
    echo "------------ ----- ---------- ---------- ------  -----------------------------------------------" >> "$LOG_FILE"

    # Filter for first 3 UEs: UE[1], UE[2], UE[3] from UERANSIM, plus AMF/AUSF/UDM/UDR errors
    render_flow "${tmp_dir}/merged.log" "UE\[1\]|UE\[2\]|UE\[3\]|Authenticate Request Error|Registration Reject|Authentication procedure failed|Nil PermanentKey|not found|Handle Registration Request|Authentication procedure$|HandleUeAuthPostRequest|GenerateAuthDataRequest|suci-0-208-93-0000-0-0-00000050(0[123])"

    # Full summary
    log_header "200 UE REJECTION SUMMARY"
    print_rejection_summary "${tmp_dir}/merged.log"

    cleanup_ues
    rm -rf "$tmp_dir"
}

# ── Main ──────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [--single|--attach|--reject|--all]"
    echo ""
    echo "  --single   Single UE registration flow trace"
    echo "  --attach   16 UE attach flow trace"
    echo "  --reject   200 UE rejection flow trace"
    echo "  --all      Run all 3 tests (default)"
}

main() {
    local run_single=true
    local run_attach=true
    local run_reject=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --single)  run_single=true; run_attach=false; run_reject=false ;;
            --attach)  run_single=false; run_attach=true; run_reject=false ;;
            --reject)  run_single=false; run_attach=false; run_reject=true ;;
            --all)     run_single=true; run_attach=true; run_reject=true ;;
            --help|-h) usage; exit 0 ;;
            *)         echo "Unknown option: $1"; usage; exit 1 ;;
        esac
        shift
    done

    echo "" > "$LOG_FILE"

    log_header "free5GC UE FLOW TRACE"
    log "Date: $(date)"
    log "Log file: $LOG_FILE"

    preflight_checks

    if $run_single; then
        trace_single_ue
    fi
    if $run_attach; then
        trace_16ue_attach
    fi
    if $run_reject; then
        trace_200ue_reject
    fi

    cleanup_test_data

    log_header "TRACING COMPLETE"

    echo ""
    echo -e "  ${CYAN}Total Tests:${NC}  $TOTAL_TESTS"
    echo -e "  ${GREEN}Passed:${NC}       $TOTAL_PASS"
    echo -e "  ${RED}Failed:${NC}       $TOTAL_FAIL"
    echo ""

    if [ "$TOTAL_FAIL" -eq 0 ]; then
        echo -e "  ${GREEN}ALL TESTS PASSED${NC}"
    else
        echo -e "  ${RED}$TOTAL_FAIL TEST(S) FAILED${NC}"
    fi

    echo ""
    log "Full trace log: $LOG_FILE"
}

main "$@"
