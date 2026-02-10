#!/bin/bash
# ============================================================
# free5gc.sh - Unified Build, Run & Test for free5GC
# ============================================================
# Single script to build, run, and test a portable 5G SA core.
# Works on Mac, Linux, or any OS with Docker installed.
#
# Usage:
#   ./free5gc.sh build                # Compile all NFs from source (~15 min)
#   ./free5gc.sh build --quick        # Rebuild runtime images only
#   ./free5gc.sh start                # Start containers + provision subscriber
#   ./free5gc.sh test                 # 1 UE registration + full NF flow trace
#   ./free5gc.sh test full            # 16 attach + 200 reject + 100 identify + trace
#   ./free5gc.sh stop                 # Stop and remove all containers
#   ./free5gc.sh status               # Show container status
#   ./free5gc.sh logs [nf]            # Tail logs (all or specific NF)
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Constants ───────────────────────────────────────────────
COMPOSE_FILE="docker-compose-portable.yaml"
IMSI="imsi-208930000000001"
PLMN="20893"
MCC="208"
MNC="93"
K="8baf473f2f8fd09487cccbd7097c6862"
OPC="8e27b6af0e692e750f32667a3b14605d"
SQN="000000000020"
AMF_FIELD="8000"
WEBUI_IMAGE="free5gc/webui:v4.2.0"

NFS=(nrf udr udm ausf nssf pcf amf smf)

ATTACH_COUNT=16
REJECT_COUNT=200
REJECT_IMSI_START=5001
IDENTIFY_COUNT=100
IDENTIFY_IMSI_START=1001
PROVISION_BATCH=10
UE_SPAWN_DELAY_MS=100
SETTLE_TIME=20

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# Test counters
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0

# ── Helpers ─────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $1"; }

log_pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    ((TOTAL_PASS++))
    ((TOTAL_TESTS++))
}

log_fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    ((TOTAL_FAIL++))
    ((TOTAL_TESTS++))
}

log_info() {
    echo -e "  ${YELLOW}[INFO]${NC} $1"
}

format_imsi() {
    printf "imsi-%s%s%010d" "$MCC" "$MNC" "$1"
}

detect_mode() {
    if [ "$(uname -s)" = "Linux" ] && lsmod 2>/dev/null | grep -q gtp5g; then
        echo "full"
    else
        echo "cp-only"
    fi
}

wait_healthy() {
    local container="$1"
    local max_wait="${2:-120}"
    local waited=0

    while [ $waited -lt "$max_wait" ]; do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")
        if [ "$status" = "healthy" ]; then
            log "  $container is healthy (took ${waited}s)"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
        if [ $((waited % 10)) -eq 0 ]; then
            log "  Still waiting... (${waited}s, status: $status)"
        fi
    done
    log "WARNING: $container health check timed out after ${max_wait}s"
    return 1
}

cleanup_ue_processes() {
    docker exec ueransim pkill -f 'nr-ue' 2>/dev/null || true
    sleep 2
}

# ── Subscriber Provisioning ─────────────────────────────────

provision_subscriber() {
    # Provisions via WebUI API + MongoDB patches
    local imsi="${1:-$IMSI}"
    local plmn="${2:-$PLMN}"
    local docker_network="${3:-}"

    # Auto-detect network
    if [ -z "$docker_network" ]; then
        docker_network=$(docker network ls --format '{{.Name}}' | grep privnet | head -1)
    fi
    if [ -z "$docker_network" ]; then
        log "ERROR: Could not detect Docker network. Is the stack running?"
        return 1
    fi

    # Auto-detect port: use 5001 on macOS (port 5000 is used by AirPlay)
    local webui_port=5000
    if [ "$(uname)" = "Darwin" ]; then
        webui_port=5001
    fi

    log "Starting temporary WebUI container..."
    docker rm -f webui-temp 2>/dev/null || true

    if [ ! -f "./config/webuicfg.yaml" ]; then
        log "ERROR: config/webuicfg.yaml not found. Run from the project root."
        return 1
    fi

    docker run -d --name webui-temp \
        --network "$docker_network" \
        -v "$(pwd)/config/webuicfg.yaml:/free5gc/config/webuicfg.yaml" \
        -v "$(pwd)/cert:/free5gc/cert" \
        -e GIN_MODE=release \
        -p "${webui_port}:5000" \
        "$WEBUI_IMAGE" ./webui -c ./config/webuicfg.yaml
    sleep 5

    if ! docker ps --filter name=webui-temp --format '{{.Status}}' | grep -q "Up"; then
        log "ERROR: WebUI failed to start"
        docker rm -f webui-temp 2>/dev/null
        return 1
    fi

    # Login to get JWT token
    log "Logging in to WebUI..."
    local token
    token=$(curl -s -X POST "http://localhost:${webui_port}/api/login" \
        -H 'Content-Type: application/json' \
        -d '{"username":"admin","password":"free5gc"}' | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

    if [ -z "$token" ] || [ "$token" = "None" ]; then
        log "ERROR: Failed to get JWT token from WebUI"
        docker rm -f webui-temp 2>/dev/null
        return 1
    fi

    # Create subscriber
    log "Creating subscriber $imsi..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://localhost:${webui_port}/api/subscriber/${imsi}/${plmn}" \
        -H 'Content-Type: application/json' \
        -H "Token: ${token}" \
        -d "{
  \"plmnID\": \"${plmn}\",
  \"ueId\": \"${imsi}\",
  \"AuthenticationSubscription\": {
    \"authenticationMethod\": \"5G_AKA\",
    \"permanentKey\": {\"permanentKeyValue\": \"${K}\", \"encryptionKey\": 0, \"encryptionAlgorithm\": 0},
    \"sequenceNumber\": \"${SQN}\",
    \"authenticationManagementField\": \"${AMF_FIELD}\",
    \"milenage\": {\"op\": {\"opValue\": \"\", \"encryptionKey\": 0, \"encryptionAlgorithm\": 0}},
    \"opc\": {\"opcValue\": \"${OPC}\", \"encryptionKey\": 0, \"encryptionAlgorithm\": 0}
  },
  \"AccessAndMobilitySubscriptionData\": {
    \"gpsis\": [\"msisdn-0900000000\"],
    \"subscribedUeAmbr\": {\"downlink\": \"2 Gbps\", \"uplink\": \"1 Gbps\"},
    \"nssai\": {
      \"defaultSingleNssais\": [{\"sst\": 1, \"sd\": \"010203\"}, {\"sst\": 1, \"sd\": \"112233\"}]
    }
  },
  \"SessionManagementSubscriptionData\": [
    {
      \"singleNssai\": {\"sst\": 1, \"sd\": \"010203\"},
      \"dnnConfigurations\": {
        \"internet\": {
          \"pduSessionTypes\": {\"defaultSessionType\": \"IPV4\"},
          \"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},
          \"5gQosProfile\": {\"5qi\": 9, \"arp\": {\"priorityLevel\": 8, \"preemptCap\": \"\", \"preemptVuln\": \"\"}},
          \"sessionAmbr\": {\"downlink\": \"200 Mbps\", \"uplink\": \"100 Mbps\"}
        }
      }
    },
    {
      \"singleNssai\": {\"sst\": 1, \"sd\": \"112233\"},
      \"dnnConfigurations\": {
        \"internet\": {
          \"pduSessionTypes\": {\"defaultSessionType\": \"IPV4\"},
          \"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},
          \"5gQosProfile\": {\"5qi\": 9, \"arp\": {\"priorityLevel\": 8, \"preemptCap\": \"\", \"preemptVuln\": \"\"}},
          \"sessionAmbr\": {\"downlink\": \"200 Mbps\", \"uplink\": \"100 Mbps\"}
        }
      }
    }
  ],
  \"SmfSelectionSubscriptionData\": {
    \"subscribedSnssaiInfos\": {
      \"01010203\": {\"dnnInfos\": [{\"dnn\": \"internet\"}]},
      \"01112233\": {\"dnnInfos\": [{\"dnn\": \"internet\"}]}
    }
  }
}")

    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        log "Subscriber created via WebUI (HTTP $http_code)"
    elif [ "$http_code" = "409" ]; then
        log "Subscriber already exists (HTTP 409) - continuing with patches"
    else
        log "WARNING: Unexpected HTTP $http_code from WebUI. Continuing with patches..."
    fi

    # Stop WebUI
    docker stop webui-temp >/dev/null 2>&1
    docker rm webui-temp >/dev/null 2>&1

    # Patch MongoDB: add allowedSessionTypes
    log "Patching MongoDB: adding allowedSessionTypes..."
    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['subscriptionData.provisionedData.smData'].updateMany(
  { ueId: '${imsi}' },
  { \$set: { 'dnnConfigurations.internet.pduSessionTypes.allowedSessionTypes': ['IPV4'] } }
)" 2>&1 | grep -v "^$"

    # Patch MongoDB: populate smPolicySnssaiData
    log "Patching MongoDB: populating smPolicySnssaiData..."
    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['policyData.ues.smData'].updateOne(
  { ueId: '${imsi}' },
  {
    \$set: {
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
    }
  },
  { upsert: true }
)" 2>&1 | grep -v "^$"

    log "Subscriber $imsi provisioned."
}

provision_subscriber_direct() {
    # Direct MongoDB provisioning (for multi-UE tests, faster than WebUI)
    local imsi_num=$1
    local imsi
    imsi=$(format_imsi "$imsi_num")

    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
    db['subscriptionData.authenticationData.authenticationSubscription'].updateOne(
      { ueId: '${imsi}' },
      { \$set: {
          authenticationMethod: '5G_AKA',
          encPermanentKey: '${K}',
          sequenceNumber: { sqn: '${SQN}' },
          authenticationManagementField: '${AMF_FIELD}',
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

provision_multi_subscribers() {
    local start=$1
    local count=$2
    local label=$3

    log "Provisioning $count subscribers for $label..."
    for ((i = 0; i < count; i++)); do
        provision_subscriber_direct "$((start + i))" &
        if (( (i + 1) % PROVISION_BATCH == 0 )); then
            wait
        fi
    done
    wait
    log "  Provisioned $count subscribers"
}

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
}

# ── Log Position Snapshotting & Collection ──────────────────

record_log_positions() {
    # Store per-NF line counts (bash 3.2 compatible - no associative arrays)
    for nf in "${NFS[@]}"; do
        local log_file="/var/log/free5gc/${nf}.log"
        local lines
        lines=$(docker exec free5gc-cp wc -l "$log_file" 2>/dev/null | awk '{print $1}' || echo "0")
        eval "LOG_POS_${nf}=${lines}"
    done

    LOG_POS_upf=0
    if docker ps --format '{{.Names}}' | grep -q "^upf$"; then
        LOG_POS_upf=$(docker logs upf 2>&1 | wc -l || echo "0")
    fi

    LOG_POS_ueransim=$(docker logs ueransim 2>&1 | wc -l || echo "0")
}

collect_new_logs() {
    local output_dir="$1"
    mkdir -p "$output_dir"

    for nf in "${NFS[@]}"; do
        local log_file="/var/log/free5gc/${nf}.log"
        eval "local start_line=\$((LOG_POS_${nf} + 1))"
        docker exec free5gc-cp tail -n "+${start_line}" "$log_file" 2>/dev/null > "$output_dir/${nf}.log" || true
    done

    if docker ps --format '{{.Names}}' | grep -q "^upf$"; then
        docker logs upf 2>&1 | tail -n "+$((LOG_POS_upf + 1))" > "$output_dir/upf.log" || true
    fi

    docker logs ueransim 2>&1 | tail -n "+$((LOG_POS_ueransim + 1))" > "$output_dir/ueransim.log" || true
}

# ── Trace Rendering ─────────────────────────────────────────

collect_and_merge_logs() {
    # Collect new logs from all NFs, merge chronologically into a tagged file.
    # Each line: SORT_KEY\tNF\tSUBMODULE\tLEVEL\tMESSAGE (tab-separated)
    # Returns path to a temp dir containing merged.log
    local log_dir="$1"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Collect CP NF logs (parallel)
    for nf in "${NFS[@]}"; do
        local nf_upper
        nf_upper=$(echo "$nf" | tr '[:lower:]' '[:upper:]')
        if [ -s "$log_dir/${nf}.log" ]; then
            (
            awk -v nf="$nf_upper" '
            function extract_bracket(s, result,    p1, p2) {
                p1 = index(s, "[")
                if (p1 == 0) return 0
                p2 = index(s, "]")
                if (p2 == 0) return 0
                result[0] = substr(s, p1+1, p2-p1-1)
                result[1] = substr(s, p2+1)
                return 1
            }
            {
                gsub(/\033\[[0-9;]*m/, "")
                gsub(/^[ \t]+/, "")
                # Match: 2026-02-10T20:09:15.999079668Z
                if ($0 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+Z/) {
                    ts = $0; sub(/Z.*/, "", ts); sub(/.*T/, "", ts)
                    split(ts, tp, "."); frac = tp[2]
                    while (length(frac) < 9) frac = frac "0"
                    sort_key = tp[1] "." frac
                    rest = $0; sub(/^[^ ]+ /, "", rest)

                    level = "INFO"; submod = "Main"; msg = rest
                    # Parse [LEVEL][Module][SubModule] or [LEVEL][Module]
                    tmp = rest; b1[0]=""; b2[0]=""; b3[0]=""
                    if (extract_bracket(tmp, b1)) {
                        level = b1[0]
                        tmp = b1[1]
                        if (extract_bracket(tmp, b2)) {
                            submod = b2[0]
                            tmp = b2[1]
                            if (extract_bracket(tmp, b3)) {
                                submod = b3[0]
                            }
                        }
                        # Strip all leading [...]  from msg
                        msg = rest
                        while (msg ~ /^\[/) {
                            sub(/^\[[^\]]*\][ ]*/, "", msg)
                        }
                    }
                    printf "%s\t%s\t%s\t%s\t%s\n", sort_key, nf, submod, level, msg
                }
            }' "$log_dir/${nf}.log" > "${tmp_dir}/${nf}.tagged"
            ) &
        fi
    done

    # UPF logs
    if [ -s "$log_dir/upf.log" ]; then
        (
        awk '
        function extract_bracket(s, result,    p1, p2) {
            p1 = index(s, "[")
            if (p1 == 0) return 0
            p2 = index(s, "]")
            if (p2 == 0) return 0
            result[0] = substr(s, p1+1, p2-p1-1)
            result[1] = substr(s, p2+1)
            return 1
        }
        {
            gsub(/\033\[[0-9;]*m/, "")
            gsub(/^[ \t]+/, "")
            if ($0 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+Z/) {
                ts = $0; sub(/Z.*/, "", ts); sub(/.*T/, "", ts)
                split(ts, tp, "."); frac = tp[2]
                while (length(frac) < 9) frac = frac "0"
                sort_key = tp[1] "." frac
                rest = $0; sub(/^[^ ]+ /, "", rest)
                level = "INFO"; submod = "Main"; msg = rest
                tmp = rest; b1[0]=""; b2[0]=""; b3[0]=""
                if (extract_bracket(tmp, b1)) {
                    level = b1[0]
                    tmp = b1[1]
                    if (extract_bracket(tmp, b2)) {
                        submod = b2[0]
                        tmp = b2[1]
                        if (extract_bracket(tmp, b3)) {
                            submod = b3[0]
                        }
                    }
                    msg = rest
                    while (msg ~ /^\[/) {
                        sub(/^\[[^\]]*\][ ]*/, "", msg)
                    }
                }
                printf "%s\t%s\t%s\t%s\t%s\n", sort_key, "UPF", submod, level, msg
            }
        }' "$log_dir/upf.log" > "${tmp_dir}/upf.tagged"
        ) &
    fi

    # UERANSIM logs (different timestamp format)
    if [ -s "$log_dir/ueransim.log" ]; then
        (
        awk '
        function extract_bracket(s, result,    p1, p2) {
            p1 = index(s, "[")
            if (p1 == 0) return 0
            p2 = index(s, "]")
            if (p2 == 0) return 0
            result[0] = substr(s, p1+1, p2-p1-1)
            result[1] = substr(s, p2+1)
            return 1
        }
        {
            # Match: [2026-02-10 20:09:01.859]
            if ($0 ~ /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\]/) {
                # Extract timestamp from first bracket
                inner = $0; sub(/^\[/, "", inner); sub(/\].*/, "", inner)
                # inner = "2026-02-10 20:09:01.859"
                split(inner, dt, " ")
                split(dt[2], tp, ".")
                frac = tp[2]
                while (length(frac) < 9) frac = frac "0"
                sort_key = tp[1] "." frac
                rest = $0; sub(/^\[[^\]]*\] */, "", rest)
                module = "gnb"; level = "info"; msg = rest
                # Parse [module] [level] message
                b1[0]=""; b2[0]=""
                if (extract_bracket(rest, b1)) {
                    module = b1[0]
                    tmp = b1[1]; sub(/^ */, "", tmp)
                    if (extract_bracket(tmp, b2)) {
                        level = b2[0]
                        msg = b2[1]; sub(/^ */, "", msg)
                    }
                }
                printf "%s\t%s\t%s\t%s\t%s\n", sort_key, "UERANSIM", module, toupper(level), msg
            }
        }' "$log_dir/ueransim.log" > "${tmp_dir}/ueransim.tagged"
        ) &
    fi

    wait

    # Merge and sort chronologically
    cat "${tmp_dir}"/*.tagged 2>/dev/null | sort -t$'\t' -k1,1 > "${tmp_dir}/merged.log"

    echo "${tmp_dir}"
}

render_chronological_flow() {
    # Renders a merged log file with color-coded NFs, request/response markers,
    # and key event highlighting. Shows the full flow across all NFs.
    #
    # Args: merged_file trace_file [filter_pattern] [max_lines]
    local merged_file="$1"
    local trace_file="$2"
    local filter_pattern="${3:-}"
    local max_lines="${4:-0}"

    [ -s "$merged_file" ] || return 0

    local input_file="$merged_file"
    local tmp_filtered=""

    if [ -n "$filter_pattern" ]; then
        tmp_filtered=$(mktemp)
        grep -aE "$filter_pattern" "$merged_file" > "$tmp_filtered" 2>/dev/null || true
        input_file="$tmp_filtered"
    fi

    # Header
    local hdr
    hdr=$(printf "%-12s %-5s %-9s %-12s %-5s  %s" "TIMESTAMP" "FLOW" "NF" "MODULE" "LVL" "MESSAGE")
    echo -e "${BOLD}${hdr}${NC}"
    echo "$hdr" >> "$trace_file"
    local div="------------ ----- --------- ------------ -----  -----------------------------------------------"
    echo "$div"
    echo "$div" >> "$trace_file"

    local line_count=0

    while IFS=$'\t' read -r ts nf submod level message; do
        [ -z "$ts" ] && continue

        if [ "$max_lines" -gt 0 ] && [ "$line_count" -ge "$max_lines" ]; then
            break
        fi
        ((line_count++))

        # Truncate timestamp to milliseconds
        local display_ts="${ts%${ts#*.???}}"

        # Determine flow direction prefix:
        #   >>> = outbound SBI request (POST, PUT to another NF)
        #   <<< = inbound SBI response (GIN handler returning)
        #   ==> = key registration/session milestone event
        #   [!!] = error / rejection
        #       = normal log line
        local prefix="     "
        if [[ "$message" =~ Handle\ Registration\ Request|Authentication\ procedure$|Send\ Authentication\ Request|Authentication\ Success|Send\ Security\ Mode\ Command|Handle\ Security\ Mode\ Complete|Send\ Registration\ Accept|Handle\ Registration\ Complete|ContextSetup\ Success|RRC\ Setup\ for\ UE|Initial\ Context\ Setup\ Request\ received|PDU\ session\ resource|RM-REGISTERED|PDU\ Session\ Establishment\ Accept|transition\ from ]]; then
            prefix=" ==> "
        elif [[ "$submod" == "GIN" && "$message" =~ POST|PUT|PATCH|DELETE ]]; then
            prefix=" >>> "
        elif [[ "$submod" == "GIN" ]]; then
            prefix=" <<< "
        elif [[ "$message" =~ Nausf_|Nudm_|Nudr_|Nsmf_|Npcf_|Nnssf_|nausf-auth|nudm-ueau|nudm-sdm|nudr-dr|nsmf-pdusession|npcf-smpolicy ]]; then
            prefix=" --> "
        elif [[ "$message" =~ [Ee]rror|[Ff]ail|[Rr]eject|Nil\ Permanent|not\ found ]]; then
            prefix=" [!!]"
        fi

        # NF color
        local color=""
        case "$nf" in
            UERANSIM) color="$CYAN" ;;
            AMF)      color="$GREEN" ;;
            AUSF)     color="${BOLD}${YELLOW}" ;;
            UDM|UDR)  color="$YELLOW" ;;
            NRF)      color="$NC" ;;
            NSSF)     color="$NC" ;;
            PCF)      color="$MAGENTA" ;;
            SMF)      color="$BLUE" ;;
            UPF)      color="${BOLD}${MAGENTA}" ;;
        esac

        local nf_pad
        nf_pad=$(printf "%-9s" "$nf")
        local sub_pad
        sub_pad=$(printf "%-12s" "[$submod]")

        # Console (colored)
        printf "%s %s%s%s %s%s%s %s [%-4s]  %s\n" \
            "$display_ts" "$color" "$prefix" "$NC" "$color" "$nf_pad" "$NC" "$sub_pad" "$level" "$message"

        # File (plain)
        printf "%s %s %-9s %-12s [%-4s]  %s\n" \
            "$display_ts" "$prefix" "$nf" "[$submod]" "$level" "$message" >> "$trace_file"

    done < "$input_file"

    [ -n "$tmp_filtered" ] && rm -f "$tmp_filtered"

    echo ""
    echo -e "  ${YELLOW}[INFO]${NC} $line_count flow lines rendered"
    echo "  [INFO] $line_count flow lines rendered" >> "$trace_file"
}

# ── Commands ────────────────────────────────────────────────

cmd_build() {
    local quick=false
    if [ "${1:-}" = "--quick" ]; then
        quick=true
    fi

    if [ "$quick" = false ]; then
        log "Step 1/3: Building all free5GC + UERANSIM from source..."
        log "  This compiles Go + C++ code inside Docker. First run may take 10-20 minutes."

        docker build -f Dockerfile.build-all -t free5gc-builder:v4.2.0 .

        log "Source build complete."

        log "Step 2/3: Extracting built binaries to build-output/..."
        rm -rf build-output
        mkdir -p build-output

        docker run --rm -v "$(pwd)/build-output:/export" free5gc-builder:v4.2.0

        if [ ! -f "build-output/cp/nrf" ]; then
            log "ERROR: Binary extraction failed. build-output/cp/nrf not found."
            exit 1
        fi

        log "Binaries extracted:"
        log "  CP NFs: $(ls build-output/cp/ | tr '\n' ' ')"
        log "  UPF:    $(ls build-output/upf/ | tr '\n' ' ')"
        log "  UERANSIM: $(ls build-output/ueransim/ | tr '\n' ' ')"

        if [ -f "build-output/BUILD_MANIFEST.txt" ]; then
            cat build-output/BUILD_MANIFEST.txt
        fi
    else
        log "Step 1/3: Skipping source build (--quick mode)"
        log "Step 2/3: Using existing build-output/"

        if [ ! -d "build-output/cp" ]; then
            log "ERROR: build-output/cp/ not found. Run './free5gc.sh build' first."
            exit 1
        fi
    fi

    log "Step 3/3: Building runtime Docker images..."
    mkdir -p logs/cp logs/upf

    docker compose -f "$COMPOSE_FILE" build

    log ""
    log "========================================="
    log "  BUILD COMPLETE"
    log "========================================="
    log ""
    log "Runtime images built:"
    docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" | grep -E "free5gc-(cp|upf|ueransim)-local" || true
    log ""
    log "Next: ./free5gc.sh start"
    log ""
}

cmd_start() {
    local mode
    mode=$(detect_mode)
    log "Detected mode: $mode"

    mkdir -p logs/cp logs/upf

    # Start containers
    log "Step 1/4: Starting containers..."
    if [ "$mode" = "cp-only" ]; then
        log "  CP-only mode: skipping UPF (no gtp5g kernel module)"
        docker compose -f "$COMPOSE_FILE" up -d db free5gc-cp ueransim
    else
        docker compose -f "$COMPOSE_FILE" up -d
    fi

    # Wait for CP health
    log "Step 2/4: Waiting for Control Plane to be healthy..."
    wait_healthy "free5gc-cp" 120 || {
        log "Container logs:"
        docker logs free5gc-cp --tail 20 2>&1 | head -20
    }

    # Provision subscriber
    log "Step 3/4: Provisioning default subscriber..."
    provision_subscriber "$IMSI" "$PLMN" || {
        log "WARNING: Subscriber provisioning failed. May need manual setup."
    }

    # Restart UERANSIM to ensure gNB connects after AMF NGAP is ready
    log "Restarting UERANSIM to ensure gNB-AMF connection..."
    docker restart ueransim >/dev/null 2>&1
    sleep 5

    # Show status
    log "Step 4/4: Deployment status"
    echo ""
    docker compose -f "$COMPOSE_FILE" ps
    echo ""
    log "========================================="
    log "  free5GC IS RUNNING"
    log "========================================="
    echo ""
    log "Test:   ./free5gc.sh test"
    log "Logs:   ./free5gc.sh logs"
    log "Stop:   ./free5gc.sh stop"
    echo ""
}

cmd_test_simple() {
    log "========================================="
    log "  TEST: Single UE Registration + Trace"
    log "========================================="
    echo ""

    # Verify containers
    for container in free5gc-cp ueransim mongodb; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            log "ERROR: Container '$container' is not running. Run './free5gc.sh start' first."
            exit 1
        fi
    done

    local upf_running=false
    if docker ps --format '{{.Names}}' | grep -q "^upf$"; then
        upf_running=true
    fi

    # Verify gNB connected
    if ! docker logs ueransim 2>&1 | grep -q 'NG Setup procedure is successful'; then
        log "WARNING: gNB may not be connected to AMF. Restarting UERANSIM..."
        docker restart ueransim >/dev/null 2>&1
        sleep 5
    fi

    # Record log positions
    log "Recording log positions..."
    record_log_positions

    # Kill existing UE processes
    cleanup_ue_processes

    # Start 1 UE
    log "Starting UE registration..."
    docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml

    # Wait for registration
    local max_wait=30
    local waited=0
    local registered=false

    while [ $waited -lt $max_wait ]; do
        # Check AMF log for Registered state (works in both full and CP-only modes)
        if docker exec free5gc-cp grep -q "transition from \[ContextSetup\] to \[Registered\]\|RM-REGISTERED" /var/log/free5gc/amf.log 2>/dev/null; then
            registered=true
            log "UE registration completed (took ${waited}s)"
            break
        fi
        # Also check gNB for Initial Context Setup (backup check)
        if docker logs ueransim 2>&1 | tail -20 | grep -q "Initial Context Setup Request received"; then
            registered=true
            log "UE registration completed (took ${waited}s)"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [ "$registered" = false ]; then
        log "WARNING: Registration not confirmed after ${max_wait}s (collecting logs anyway)"
    fi

    sleep 2

    # Collect new logs
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local log_dir="logs/trace-${timestamp}"
    mkdir -p "$log_dir"

    log "Collecting logs from all NFs..."
    collect_new_logs "$log_dir"

    # Merge and render chronological flow
    local trace_file="$log_dir/trace.log"
    echo "free5GC Single UE Registration Trace - $(date)" > "$trace_file"
    echo "" >> "$trace_file"

    log "Merging logs chronologically..."
    local merge_dir
    merge_dir=$(collect_and_merge_logs "$log_dir")

    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  NF-to-NF Flow: UE Registration${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
    echo "  Legend:  ==>  Key milestone    >>>  SBI request (POST/PUT)"
    echo "          <<<  SBI response      -->  NF-to-NF call"
    echo "          [!!] Error/rejection"
    echo ""

    render_chronological_flow "${merge_dir}/merged.log" "$trace_file"

    # Log line counts per NF
    echo ""
    echo -e "${BOLD}--- Log Volume Per NF ---${NC}"
    for nf_file in "$log_dir"/*.log; do
        [ -s "$nf_file" ] || continue
        local nf_name
        nf_name=$(basename "$nf_file" .log)
        local count
        count=$(wc -l < "$nf_file" | tr -d ' ')
        echo "  $nf_name: $count new log lines"
    done

    rm -rf "$merge_dir"

    # Result
    echo ""
    echo -e "${BOLD}--- Result ---${NC}"
    if [ "$registered" = true ]; then
        echo -e "  ${GREEN}PASS${NC} - UE successfully registered"
        if [ "$upf_running" = true ]; then
            if grep -q "PDU Session establishment is successful\|PDU session" "$log_dir/ueransim.log" 2>/dev/null || \
               grep -q "PDUSession\|PFCP Session Establishment" "$log_dir/smf.log" 2>/dev/null; then
                echo -e "  ${GREEN}PASS${NC} - PDU Session established"
            else
                echo -e "  ${YELLOW}INFO${NC} - PDU Session status unclear (check trace)"
            fi
        else
            echo -e "  ${YELLOW}INFO${NC} - UPF not running (CP-only mode) - no PDU session expected"
        fi
    else
        echo -e "  ${RED}FAIL${NC} - UE registration not confirmed"
    fi

    echo ""
    log "Trace saved to: $trace_file"
    log "Raw logs: $log_dir/"
    echo ""

    cleanup_ue_processes
}

cmd_test_full() {
    log "========================================="
    log "  TEST FULL: 16 Attach + 200 Reject + 100 Identify"
    log "========================================="
    echo ""
    echo "  Legend:  ==>  Key milestone    >>>  SBI request (POST/PUT)"
    echo "          <<<  SBI response      -->  NF-to-NF call"
    echo "          [!!] Error/rejection"
    echo ""

    # Verify containers
    for container in free5gc-cp ueransim mongodb upf; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            if [ "$container" = "upf" ]; then
                log "WARNING: UPF not running (CP-only mode). PDU sessions will not be established."
            else
                log "ERROR: Container '$container' is not running. Run './free5gc.sh start' first."
                exit 1
            fi
        fi
    done

    # Verify gNB connected
    if ! docker logs ueransim 2>&1 | grep -q 'NG Setup procedure is successful'; then
        log "ERROR: gNB not connected to AMF"
        exit 1
    fi

    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local trace_file="logs/trace-${timestamp}.log"
    local log_dir="logs/trace-full-${timestamp}"
    mkdir -p "$log_dir" "logs"

    echo "free5GC Full Test - $(date)" > "$trace_file"
    echo "Phases: Attach($ATTACH_COUNT) + Reject($REJECT_COUNT) + Identify($IDENTIFY_COUNT)" >> "$trace_file"
    echo "" >> "$trace_file"

    # ══════════════════════════════════════════════════════════
    # Phase 1: 16 UE Attach
    # ══════════════════════════════════════════════════════════
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  Phase 1: Attach $ATTACH_COUNT UEs (Registration + PDU Session)${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
    echo "Phase 1: Attach $ATTACH_COUNT UEs" >> "$trace_file"
    echo "================================" >> "$trace_file"
    echo "" >> "$trace_file"

    provision_multi_subscribers 1 "$ATTACH_COUNT" "attach test"

    cleanup_ue_processes
    record_log_positions

    local first_imsi
    first_imsi=$(format_imsi 1)
    log "Starting $ATTACH_COUNT UEs ($first_imsi to $(format_imsi $ATTACH_COUNT))..."
    docker exec -d ueransim ./nr-ue \
        -c ./config/uecfg.yaml \
        -i "$first_imsi" \
        -n "$ATTACH_COUNT" \
        -t "$UE_SPAWN_DELAY_MS" \
        -l -r

    log "Waiting 25s for registrations..."
    sleep 25

    collect_new_logs "$log_dir/phase1"

    # Merge and render chronological flow
    local merge_dir_p1
    merge_dir_p1=$(collect_and_merge_logs "$log_dir/phase1")

    echo ""
    echo -e "${BOLD}--- Phase 1: Full NF-to-NF Flow ---${NC}"
    echo ""
    render_chronological_flow "${merge_dir_p1}/merged.log" "$trace_file" \
        "Registration|Authentication|Security|PDUSession|Context Setup|PFCP|Initial NAS|Nausf|Nudm|Nudr|Nsmf|Npcf|nausf|nudm|nudr|nsmf|npcf|GIN|HandleUe|GenerateAuth|ConfirmAuth|GetAuthSubs|SmData|AmData|SDM|SUCI|SUPI|transition|CreateSMContext|Session Establishment|5gAka|5G AKA"

    # Analyze results from gNB logs
    local gnb_logs
    gnb_logs=$(docker logs ueransim 2>&1 | tail -n "+$((LOG_POS_ueransim + 1))")
    local context_setups
    context_setups=$(echo "$gnb_logs" | grep -c "Initial Context Setup Request received" || true)
    local pdu_setups
    pdu_setups=$(echo "$gnb_logs" | grep -c "PDU session resource(s) setup" || true)
    local unique_pdu_ues
    unique_pdu_ues=$(echo "$gnb_logs" | grep "PDU session resource(s) setup for UE" | \
        sed 's/.*UE\[\([0-9]*\)\].*/\1/' | sort -un | wc -l)

    echo ""
    log_info "Initial Context Setups: $context_setups"
    log_info "PDU Session Setups: $pdu_setups"
    log_info "Unique UEs with PDU sessions: $unique_pdu_ues"

    if [ "$context_setups" -ge "$ATTACH_COUNT" ]; then
        log_pass "All $ATTACH_COUNT UEs registered ($context_setups context setups)"
    elif [ "$context_setups" -gt 0 ]; then
        log_fail "Only $context_setups/$ATTACH_COUNT UEs registered"
    else
        log_fail "No UEs registered (0 context setups)"
    fi

    if [ "$unique_pdu_ues" -ge "$ATTACH_COUNT" ]; then
        log_pass "$unique_pdu_ues/$ATTACH_COUNT UEs have PDU sessions"
    elif [ "$unique_pdu_ues" -gt 0 ]; then
        log_fail "Only $unique_pdu_ues/$ATTACH_COUNT UEs got PDU sessions"
    fi

    # Per-UE summary table (use collected AMF logs which contain per-UE SUPI)
    local amf_phase1_log="$log_dir/phase1/amf.log"

    echo ""
    echo -e "${BOLD}  UE#   IMSI                          Status        PDU${NC}"
    echo "  ----  ----------------------------  ------------  --------"
    for ((i = 1; i <= ATTACH_COUNT; i++)); do
        local imsi
        imsi=$(format_imsi "$i")

        local status="${RED}NO_ATTEMPT${NC}"
        local pdu="-"
        # AMF logs contain [supi:SUPI:imsi-...] per UE
        if grep -q "supi:SUPI:${imsi}" "$amf_phase1_log" 2>/dev/null; then
            if grep "supi:SUPI:${imsi}" "$amf_phase1_log" | grep -q "Handle InitialRegistration\|ContextSetup" 2>/dev/null; then
                status="${GREEN}REGISTERED${NC}"
                if grep "supi:SUPI:${imsi}" "$amf_phase1_log" | grep -q "create smContext" 2>/dev/null; then
                    pdu="${GREEN}YES${NC}"
                else
                    pdu="${YELLOW}NO${NC}"
                fi
            else
                status="${YELLOW}ATTEMPTED${NC}"
            fi
        fi
        printf "  %-4d  %s  %-22b  %b\n" "$i" "$imsi" "$status" "$pdu"
    done

    rm -rf "$merge_dir_p1"
    cleanup_ue_processes

    # ══════════════════════════════════════════════════════════
    # Phase 2: 200 UE Reject
    # ══════════════════════════════════════════════════════════
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  Phase 2: Reject $REJECT_COUNT Unprovisioned UEs${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
    echo "" >> "$trace_file"
    echo "Phase 2: Reject $REJECT_COUNT Unprovisioned UEs" >> "$trace_file"
    echo "================================" >> "$trace_file"
    echo "" >> "$trace_file"

    # Ensure reject-range IMSIs are NOT provisioned
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

    cleanup_ue_processes
    record_log_positions

    # Launch 200 UEs in batches of 50
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

    collect_new_logs "$log_dir/phase2"

    # Merge and render rejection flow (show first ~200 lines of detail)
    local merge_dir_p2
    merge_dir_p2=$(collect_and_merge_logs "$log_dir/phase2")

    echo ""
    echo -e "${BOLD}--- Phase 2: Rejection Flow (sample of first 3 UEs) ---${NC}"
    echo ""
    render_chronological_flow "${merge_dir_p2}/merged.log" "$trace_file" \
        "UE\[1\]|UE\[2\]|UE\[3\]|Authenticate Request Error|Registration Reject|Authentication procedure failed|Nil PermanentKey|not found|Handle Registration Request|Authentication procedure$|HandleUeAuthPostRequest|GenerateAuthDataRequest|suci-0-208-93-0000-0-0-00000050(0[123])|GIN.*50(0[123])" \
        200

    # Analyze rejection results
    local reject_gnb_logs
    reject_gnb_logs=$(docker logs ueransim 2>&1 | tail -n "+$((LOG_POS_ueransim + 1))")
    local reject_context
    reject_context=$(echo "$reject_gnb_logs" | grep -c "Initial Context Setup Request received" || true)
    local reject_rrc
    reject_rrc=$(echo "$reject_gnb_logs" | grep -c "RRC Setup for UE\|new signal detected" || true)
    local reject_nas
    reject_nas=$(echo "$reject_gnb_logs" | grep -c "Initial NAS message received" || true)

    # CP-side analysis
    local cp_logs
    cp_logs=$(docker logs free5gc-cp 2>&1 | tail -n "+$((LOG_POS_amf + 1))" 2>/dev/null)
    local auth_errors
    auth_errors=$(echo "$cp_logs" | grep -ci "Nil PermanentKey\|not found\|Authenticate Request Error" 2>/dev/null || true)
    local reg_rejects
    reg_rejects=$(echo "$cp_logs" | grep -ci "Registration Reject\|Send Registration Reject" 2>/dev/null || true)

    echo ""
    echo -e "${BOLD}--- Rejection Summary ---${NC}"
    printf "  %-45s  %s\n" "RRC Setup attempts:" "$reject_rrc"
    printf "  %-45s  %s\n" "Initial NAS messages:" "$reject_nas"
    printf "  %-45s  ${RED}%s${NC}\n" "Authentication errors (AUSF/UDM):" "$auth_errors"
    printf "  %-45s  ${RED}%s${NC}\n" "Registration Rejects sent:" "$reg_rejects"
    printf "  %-45s  ${GREEN}%s${NC}\n" "Initial Context Setups (should be 0):" "$reject_context"
    echo ""

    if [ "$reject_context" -eq 0 ] && [ "$reject_rrc" -gt 0 ]; then
        log_pass "All $reject_rrc UE attempts rejected, 0 accepted"
    elif [ "$reject_context" -gt 0 ]; then
        log_fail "$reject_context UEs unexpectedly accepted"
    else
        log_fail "No UE connection attempts detected"
    fi

    rm -rf "$merge_dir_p2"
    cleanup_ue_processes

    # ══════════════════════════════════════════════════════════
    # Phase 3: 100 UE Identification
    # ══════════════════════════════════════════════════════════
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  Phase 3: Identify $IDENTIFY_COUNT UEs (SUPI/5G-GUTI)${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
    echo "" >> "$trace_file"
    echo "Phase 3: Identify $IDENTIFY_COUNT UEs" >> "$trace_file"
    echo "================================" >> "$trace_file"
    echo "" >> "$trace_file"

    provision_multi_subscribers "$IDENTIFY_IMSI_START" "$IDENTIFY_COUNT" "identification test"

    cleanup_ue_processes
    record_log_positions

    # Launch 100 UEs in batches of 50
    local id_batch_size=50
    local id_num_batches=$((IDENTIFY_COUNT / id_batch_size))

    log "Launching $IDENTIFY_COUNT UEs for identification in $id_num_batches batches..."
    for ((batch = 0; batch < id_num_batches; batch++)); do
        local batch_start=$((IDENTIFY_IMSI_START + batch * id_batch_size))
        local batch_imsi
        batch_imsi=$(format_imsi "$batch_start")
        log_info "Batch $((batch + 1))/$id_num_batches: $id_batch_size UEs from $batch_imsi"

        docker exec -d ueransim ./nr-ue \
            -c ./config/uecfg.yaml \
            -i "$batch_imsi" \
            -n "$id_batch_size" \
            -t "$UE_SPAWN_DELAY_MS" \
            -l -r

        sleep 8
    done

    log "Waiting ${SETTLE_TIME}s for registrations to complete..."
    sleep "$SETTLE_TIME"

    collect_new_logs "$log_dir/phase3"

    # Merge and render identification flow (sample of first 5 UEs)
    local merge_dir_p3
    merge_dir_p3=$(collect_and_merge_logs "$log_dir/phase3")

    echo ""
    echo -e "${BOLD}--- Phase 3: Identification Flow (sample) ---${NC}"
    echo ""
    render_chronological_flow "${merge_dir_p3}/merged.log" "$trace_file" \
        "Registration|Authentication|Security|SUPI|SUCI|5G-GUTI|identity|Context Setup|GIN|HandleUe|GenerateAuth|ConfirmAuth|GetAuthSubs|5gAka|5G AKA|AmData|transition" \
        150

    # Analyze identification results
    local id_gnb_logs
    id_gnb_logs=$(docker logs ueransim 2>&1 | tail -n "+$((LOG_POS_ueransim + 1))")
    local id_context_setups
    id_context_setups=$(echo "$id_gnb_logs" | grep -c "Initial Context Setup Request received" || true)
    local id_rrc_setups
    id_rrc_setups=$(echo "$id_gnb_logs" | grep -c "RRC Setup for UE" || true)
    local id_initial_nas
    id_initial_nas=$(echo "$id_gnb_logs" | grep -c "Initial NAS message received from UE" || true)
    local id_unique_pdu
    id_unique_pdu=$(echo "$id_gnb_logs" | grep "PDU session resource(s) setup for UE" | \
        sed 's/.*UE\[\([0-9]*\)\].*/\1/' | sort -un | wc -l)

    # CP-side: count authentication/identity events
    local id_cp_logs
    id_cp_logs=$(docker logs free5gc-cp 2>&1 | tail -n "+$((LOG_POS_amf + 1))" 2>/dev/null)
    local id_auth_events
    id_auth_events=$(echo "$id_cp_logs" | grep -ci "authentication\|AuthenticationData\|SUPI\|SUCI\|5G-GUTI\|identity" 2>/dev/null || true)

    echo ""
    echo -e "${BOLD}--- Identification Summary ---${NC}"
    printf "  %-45s  %s\n" "RRC Setups (radio identification):" "$id_rrc_setups"
    printf "  %-45s  %s\n" "Initial NAS messages (NAS identification):" "$id_initial_nas"
    printf "  %-45s  %s\n" "Initial Context Setups (full auth+identify):" "$id_context_setups"
    printf "  %-45s  %s\n" "Unique UEs with PDU sessions:" "$id_unique_pdu"
    printf "  %-45s  %s\n" "Core authentication/identity events:" "$id_auth_events"
    echo ""

    if [ "$id_context_setups" -ge "$IDENTIFY_COUNT" ]; then
        log_pass "All $IDENTIFY_COUNT UEs identified and registered ($id_context_setups context setups)"
    elif [ "$id_context_setups" -ge $((IDENTIFY_COUNT * 80 / 100)) ]; then
        log_pass "$id_context_setups/$IDENTIFY_COUNT UEs identified (>80% threshold)"
    else
        log_fail "Only $id_context_setups/$IDENTIFY_COUNT UEs identified"
    fi

    rm -rf "$merge_dir_p3"
    cleanup_ue_processes
    cleanup_test_data

    # ══════════════════════════════════════════════════════════
    # Final Summary
    # ══════════════════════════════════════════════════════════
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  TEST SUMMARY${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
    echo -e "  ${CYAN}Total Tests:${NC}  $TOTAL_TESTS"
    echo -e "  ${GREEN}Passed:${NC}       $TOTAL_PASS"
    echo -e "  ${RED}Failed:${NC}       $TOTAL_FAIL"
    echo ""

    {
        echo ""
        echo "SUMMARY: Total=$TOTAL_TESTS Passed=$TOTAL_PASS Failed=$TOTAL_FAIL"
        echo "Date: $(date)"
    } >> "$trace_file"

    if [ "$TOTAL_FAIL" -eq 0 ]; then
        echo -e "  ${GREEN}ALL TESTS PASSED${NC}"
    else
        echo -e "  ${RED}$TOTAL_FAIL TEST(S) FAILED${NC}"
    fi

    echo ""
    log "Full trace: $trace_file"
    log "Raw logs: $log_dir/"
    echo ""

    [ "$TOTAL_FAIL" -gt 0 ] && exit 1
    exit 0
}

cmd_stop() {
    log "Stopping all containers..."
    docker compose -f "$COMPOSE_FILE" down -v
    log "All containers stopped and volumes removed."
}

cmd_status() {
    docker compose -f "$COMPOSE_FILE" ps
}

cmd_logs() {
    local nf="${1:-}"

    if [ -z "$nf" ]; then
        docker compose -f "$COMPOSE_FILE" logs -f --tail 50
    else
        # Check if it's a CP NF with a log file
        case "$nf" in
            amf|ausf|udm|udr|smf|nrf|nssf|pcf)
                docker exec free5gc-cp tail -f "/var/log/free5gc/${nf}.log"
                ;;
            upf)
                docker logs -f upf --tail 50
                ;;
            ueransim|gnb|ue)
                docker logs -f ueransim --tail 50
                ;;
            *)
                log "Unknown NF: $nf"
                log "Available: amf, ausf, udm, udr, smf, nrf, nssf, pcf, upf, ueransim"
                exit 1
                ;;
        esac
    fi
}

show_usage() {
    echo "Usage: ./free5gc.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  build [--quick]    Build all NFs from source (~15 min)"
    echo "                     --quick: rebuild runtime images only"
    echo "  start              Start containers + provision subscriber"
    echo "  test               1 UE registration + full NF flow trace"
    echo "  test full          16 attach + 200 reject + 100 identify + trace"
    echo "  stop               Stop and remove all containers"
    echo "  status             Show container status"
    echo "  logs [nf]          Tail logs (all or specific: amf, smf, etc.)"
    echo ""
    echo "Examples:"
    echo "  ./free5gc.sh build"
    echo "  ./free5gc.sh start"
    echo "  ./free5gc.sh test"
    echo "  ./free5gc.sh logs amf"
}

# ── Main ────────────────────────────────────────────────────

case "${1:-}" in
    build)  cmd_build "${2:-}" ;;
    start)  cmd_start ;;
    test)   if [ "${2:-}" = "full" ]; then cmd_test_full; else cmd_test_simple; fi ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    logs)   cmd_logs "${2:-}" ;;
    *)      show_usage ;;
esac
