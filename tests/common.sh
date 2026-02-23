#!/bin/bash
# ============================================================
# common.sh - Shared helpers for free5GC test scripts
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose-portable.yaml"
CONFIG_DIR="$PROJECT_DIR/config"
TESTS_DIR="$SCRIPT_DIR"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# Test defaults
WEBUI_PORT=4000
PLMN="00101"
MCC="001"
MNC="01"
SST=3
SD="198153"
DNN="internet"
SQN="000000000020"
AMF_FIELD="8000"

# Subscriber defaults for test UEs
BASE_SUPI="001010123456789"
BASE_KEY="00112233445566778899aabbccddeeff"
OPC="000102030405060708090a0b0c0d0e0f"

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC}: $1"; }
info() { echo -e "  ${CYAN}INFO${NC}: $1"; }
header() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
}

# Wait for a container to be running (max 60s)
wait_container() {
    local name="$1"
    local max="${2:-60}"
    local waited=0
    while [ $waited -lt "$max" ]; do
        local state
        state=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
        [ "$state" = "running" ] && return 0
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# Get WebUI JWT token
get_token() {
    local token=""
    local attempt=0
    while [ $attempt -lt 10 ]; do
        token=$(curl -s --max-time 3 -X POST "http://localhost:${WEBUI_PORT}/api/login" \
            -H 'Content-Type: application/json' \
            -d '{"username":"admin","password":"free5gc"}' | \
            python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "None" ]; then
            echo "$token"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

# Provision a subscriber via WebUI API
provision_subscriber() {
    local imsi="$1"
    local key="$2"
    local opc="$3"
    local token="$4"
    # Derive unique MSISDN from IMSI to avoid duplicate GPSI errors
    local msisdn
    msisdn="msisdn-$(echo "$imsi" | sed 's/imsi-//')"

    curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://localhost:${WEBUI_PORT}/api/subscriber/${imsi}/${PLMN}" \
        -H 'Content-Type: application/json' \
        -H "Token: ${token}" \
        -d "{
  \"plmnID\": \"${PLMN}\",
  \"ueId\": \"${imsi}\",
  \"AuthenticationSubscription\": {
    \"authenticationMethod\": \"5G_AKA\",
    \"permanentKey\": {\"permanentKeyValue\": \"${key}\", \"encryptionKey\": 0, \"encryptionAlgorithm\": 0},
    \"sequenceNumber\": \"${SQN}\",
    \"authenticationManagementField\": \"${AMF_FIELD}\",
    \"milenage\": {\"op\": {\"opValue\": \"\", \"encryptionKey\": 0, \"encryptionAlgorithm\": 0}},
    \"opc\": {\"opcValue\": \"${opc}\", \"encryptionKey\": 0, \"encryptionAlgorithm\": 0}
  },
  \"AccessAndMobilitySubscriptionData\": {
    \"gpsis\": [\"${msisdn}\"],
    \"subscribedUeAmbr\": {\"downlink\": \"2 Gbps\", \"uplink\": \"1 Gbps\"},
    \"nssai\": {
      \"defaultSingleNssais\": [{\"sst\": ${SST}, \"sd\": \"${SD}\"}],
      \"singleNssais\": [{\"sst\": ${SST}, \"sd\": \"${SD}\"}]
    }
  },
  \"SessionManagementSubscriptionData\": [{
    \"singleNssai\": {\"sst\": ${SST}, \"sd\": \"${SD}\"},
    \"dnnConfigurations\": {
      \"internet\": {
        \"pduSessionTypes\": {\"defaultSessionType\": \"IPV4\", \"allowedSessionTypes\": [\"IPV4\"]},
        \"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},
        \"5gQosProfile\": {\"5qi\": 9, \"arp\": {\"priorityLevel\": 8, \"preemptCap\": \"\", \"preemptVuln\": \"\"}, \"priorityLevel\": 8},
        \"sessionAmbr\": {\"downlink\": \"1000 Mbps\", \"uplink\": \"1000 Mbps\"}
      },
      \"ims\": {
        \"pduSessionTypes\": {\"defaultSessionType\": \"IPV4\", \"allowedSessionTypes\": [\"IPV4\"]},
        \"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},
        \"5gQosProfile\": {\"5qi\": 5, \"arp\": {\"priorityLevel\": 1, \"preemptCap\": \"\", \"preemptVuln\": \"\"}, \"priorityLevel\": 1},
        \"sessionAmbr\": {\"downlink\": \"500 Mbps\", \"uplink\": \"500 Mbps\"}
      }
    }
  }],
  \"SmfSelectionSubscriptionData\": {
    \"subscribedSnssaiInfos\": {
      \"0${SST}${SD}\": {\"dnnInfos\": [{\"dnn\": \"internet\"}, {\"dnn\": \"ims\"}]}
    }
  },
  \"AmPolicyData\": {\"subscCats\": [\"free5gc\"]},
  \"SmPolicyData\": {
    \"smPolicySnssaiData\": {
      \"0${SST}${SD}\": {
        \"snssai\": {\"sst\": ${SST}, \"sd\": \"${SD}\"},
        \"smPolicyDnnData\": {\"internet\": {\"dnn\": \"internet\"}, \"ims\": {\"dnn\": \"ims\"}}
      }
    }
  }
}"
}

# Patch MongoDB for a subscriber
patch_mongodb() {
    local imsi="$1"
    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['subscriptionData.provisionedData.smData'].updateMany(
  { ueId: '${imsi}' },
  { \$set: { 'dnnConfigurations.internet.pduSessionTypes.allowedSessionTypes': ['IPV4'],
             'dnnConfigurations.ims.pduSessionTypes.allowedSessionTypes': ['IPV4'] } }
)" 2>&1 | grep -v "^$"
    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['policyData.ues.smData'].updateOne(
  { ueId: '${imsi}' },
  { \$set: { smPolicySnssaiData: {
    '0${SST}${SD}': { snssai: { sst: ${SST}, sd: '${SD}' },
      smPolicyDnnData: { 'internet': { dnn: 'internet' }, 'ims': { dnn: 'ims' } } } } } },
  { upsert: true }
)" 2>&1 | grep -v "^$"
}

# Increment hex string by offset (preserves length)
hex_add() {
    local hex_str="$1"
    local offset="$2"
    local len=${#hex_str}
    python3 -c "print(format(int('${hex_str}',16)+${offset},'0${len}x'))"
}

# Increment SUPI (decimal digit string) by offset (preserves length)
supi_add() {
    local supi="$1"
    local offset="$2"
    local len=${#supi}
    python3 -c "print(format(int('${supi}')+${offset},'0${len}d'))"
}

# Generate a UE config YAML for UERANSIM
generate_ue_config() {
    local supi="$1"
    local key="$2"
    local opc="$3"
    local output="$4"
    local sessions="${5:-internet}"  # comma-separated DNN list

    local session_block=""
    IFS=',' read -ra DNNS <<< "$sessions"
    for dnn in "${DNNS[@]}"; do
        session_block+="
  - type: \"IPv4\"
    apn: \"${dnn}\"
    slice:
      sst: 0x03
      sd: 0x198153"
    done

    cat > "$output" <<UECFG
supi: "imsi-${supi}"
mcc: "${MCC}"
mnc: "${MNC}"
key: "${key}"
op: "${opc}"
opType: "OPC"
amf: "8000"
imei: "356938035643803"
imeiSv: "4370816125816151"
gnbSearchList:
  - 127.0.0.1
  - gnb.free5gc.org
uacAic:
  mps: false
  mcs: false
uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false
sessions:${session_block}
configured-nssai:
  - sst: 0x03
    sd: 0x198153
default-nssai:
  - sst: 3
    sd: 0x198153
integrity:
  IA1: true
  IA2: true
  IA3: true
ciphering:
  EA1: true
  EA2: true
  EA3: true
integrityMaxRate:
  uplink: "full"
  downlink: "full"
UECFG
}

# Ensure core is running, or start it
ensure_core_running() {
    local cp_state
    cp_state=$(docker inspect --format='{{.State.Status}}' free5gc-cp 2>/dev/null || echo "missing")
    if [ "$cp_state" != "running" ]; then
        info "Core not running. Starting with: ./free5gc.sh start"
        cd "$PROJECT_DIR" && ./free5gc.sh start
    else
        info "Core is already running."
    fi
}

# Kill all UE processes inside UERANSIM container
kill_all_ues() {
    docker exec ueransim pkill -f "nr-ue" 2>/dev/null || true
    sleep 1
}
