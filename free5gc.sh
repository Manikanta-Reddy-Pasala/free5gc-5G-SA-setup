#!/bin/bash
# ============================================================
# free5gc.sh - Build & Run for free5GC
# ============================================================
# Single script to build and run a portable 5G SA core.
# Works on Mac, Linux, or any OS with Docker installed.
#
# Usage:
#   ./free5gc.sh build                # Compile all NFs from source (~15 min)
#   ./free5gc.sh build --quick        # Rebuild runtime images only
#   ./free5gc.sh start                # Start core (without UERANSIM)
#   ./free5gc.sh start --ueransim     # Start core + UERANSIM simulator
#   ./free5gc.sh start --debug        # Start with debug-level logging
#   ./free5gc.sh start --mcc 404 --mnc 30 --tac 1   # Start with custom PLMN
#   ./free5gc.sh capture start [name] # Start pcap capture (bridge + SBI)
#   ./free5gc.sh capture stop         # Stop capture and save pcap
#   ./free5gc.sh provision            # Provision default subscriber in MongoDB
#   ./free5gc.sh bulk-provision --count 10  # Provision 10 subscribers (SUPI+KEY auto-increment)
#   ./free5gc.sh ue start               # Launch UE + setup data plane
#   ./free5gc.sh ue stop                # Stop UE + cleanup routes
#   ./free5gc.sh ue status              # Check UE connectivity
#   ./free5gc.sh stop                 # Stop all containers
#   ./free5gc.sh remove               # Remove all containers and volumes
#   ./free5gc.sh status               # Show container status
#   ./free5gc.sh logs [nf]            # Tail logs (all or specific NF)
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Constants ───────────────────────────────────────────────
COMPOSE_FILE="docker-compose-portable.yaml"
PCAP_DIR="${SCRIPT_DIR}/logs/pcap-traces"
CAPTURE_IF="br-free5gc"
AMF_IP="10.100.200.16"
NGAP_PORT="38412"

# Subscriber / PLMN (defaults — overridable via ./free5gc.sh start --mcc --mnc --tac)
IMSI="imsi-001010000050641"
PLMN="00101"
MCC="001"
MNC="01"
TAC="1"
K="0c57e15a2cb86087097a6b50d42531de"
OPC="109ee52735ae6d3849112cf4175029c7"
SQN="000000000020"
AMF_FIELD="8000"
SST=3
SD="198153"
DNN="internet"
UE_SUBNET="10.206.0.0/16"
GTPU_PORT="2152"
WEBUI_PORT=4000

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ── Helpers ─────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $1"; }


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

setup_sctp_forward() {
    # Docker can't proxy SCTP. Use iptables to DNAT host:38412 -> AMF container.
    # Clean up any existing rules first
    cleanup_sctp_forward 2>/dev/null

    # Load SCTP kernel module
    modprobe sctp 2>/dev/null || true

    # DNAT: incoming SCTP 38412 on any host interface -> AMF inside Docker
    iptables -t nat -A PREROUTING -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}"

    # Also handle locally-originated traffic (e.g. from the host itself)
    iptables -t nat -A OUTPUT -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}"

    # Allow forwarded SCTP traffic to reach the Docker bridge
    iptables -A FORWARD -p sctp -d "$AMF_IP" --dport "$NGAP_PORT" -j ACCEPT
    iptables -A FORWARD -p sctp -s "$AMF_IP" --sport "$NGAP_PORT" -j ACCEPT

    # Verify
    if ss -Slnp 2>/dev/null | grep -q "$NGAP_PORT"; then
        log "  SCTP ${NGAP_PORT} listening (AMF native)"
    else
        log "  SCTP DNAT rules added (host:${NGAP_PORT} -> ${AMF_IP}:${NGAP_PORT})"
    fi
}

cleanup_sctp_forward() {
    iptables -t nat -D PREROUTING -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}" 2>/dev/null || true
    iptables -t nat -D OUTPUT -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}" 2>/dev/null || true
    iptables -D FORWARD -p sctp -d "$AMF_IP" --dport "$NGAP_PORT" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p sctp -s "$AMF_IP" --sport "$NGAP_PORT" -j ACCEPT 2>/dev/null || true
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

setup_dataplane() {
    # Setup host-side routing and NAT so UE traffic can reach the internet
    # UPF assigns UEs IPs from 10.206.0.0/16. Traffic flows:
    #   UE -> gNB -> GTP-U tunnel -> UPF (decap) -> host -> internet
    # Host needs: route to UE subnet via UPF, NAT for outbound, FORWARD rules

    log "Setting up data plane routing..."

    # Detect UPF container IP dynamically
    local UPF_IP
    UPF_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' upf 2>/dev/null)
    if [ -z "$UPF_IP" ]; then
        log "ERROR: Cannot detect UPF container IP. Is UPF running?"
        return 1
    fi
    log "  UPF container IP: ${UPF_IP}"

    # Clean up any existing rules first
    cleanup_dataplane 2>/dev/null

    # Route UE subnet to UPF container
    ip route add "$UE_SUBNET" via "$UPF_IP" dev br-free5gc 2>/dev/null || \
        log "  Route ${UE_SUBNET} already exists"
    log "  Route: ${UE_SUBNET} via ${UPF_IP}"

    # NAT: masquerade UE traffic going to the internet
    iptables -t nat -A POSTROUTING -s "$UE_SUBNET" ! -o br-free5gc -j MASQUERADE
    log "  NAT: MASQUERADE for ${UE_SUBNET}"

    # FORWARD: allow UE traffic through the host
    iptables -I FORWARD 1 -s "$UE_SUBNET" -j ACCEPT
    iptables -I FORWARD 1 -d "$UE_SUBNET" -j ACCEPT
    log "  FORWARD: ACCEPT for ${UE_SUBNET}"

    # GTP-U: DNAT host:2152 -> UPF container (for real gNB traffic)
    iptables -t nat -A PREROUTING -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}"
    iptables -t nat -A OUTPUT -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${UPF_IP}:${GTPU_PORT}"
    iptables -I FORWARD 1 -p udp -d "$UPF_IP" --dport "$GTPU_PORT" -j ACCEPT
    iptables -I FORWARD 1 -p udp -s "$UPF_IP" --sport "$GTPU_PORT" -j ACCEPT
    log "  GTP-U: DNAT host:${GTPU_PORT} -> ${UPF_IP}:${GTPU_PORT}"

    log "Data plane routing configured."
}

cleanup_dataplane() {
    ip route del "$UE_SUBNET" dev br-free5gc 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$UE_SUBNET" ! -o br-free5gc -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s "$UE_SUBNET" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "$UE_SUBNET" -j ACCEPT 2>/dev/null || true
    # GTP-U cleanup (try all possible UPF IPs)
    for upf_ip in $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' upf 2>/dev/null) 10.100.200.3 10.100.200.4 10.100.200.5; do
        iptables -t nat -D PREROUTING -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${upf_ip}:${GTPU_PORT}" 2>/dev/null || true
        iptables -t nat -D OUTPUT -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${upf_ip}:${GTPU_PORT}" 2>/dev/null || true
        iptables -D FORWARD -p udp -d "$upf_ip" --dport "$GTPU_PORT" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -p udp -s "$upf_ip" --sport "$GTPU_PORT" -j ACCEPT 2>/dev/null || true
    done
}

cmd_ue() {
    local subcmd="${1:-start}"

    case "$subcmd" in
        start)
            # Launch UE and establish PDU session
            log "Launching UE (${IMSI})..."

            # Kill any existing UE process
            docker exec ueransim pkill -f nr-ue 2>/dev/null || true
            sleep 1

            # Start UE in background
            docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
            sleep 5

            # Check if uesimtun0 was created (PDU session established)
            if docker exec ueransim ip addr show uesimtun0 >/dev/null 2>&1; then
                local ue_ip
                ue_ip=$(docker exec ueransim ip addr show uesimtun0 2>/dev/null | grep 'inet ' | awk '{print $2}')
                log "UE connected! IP: ${ue_ip}"

                # Setup host routing for data plane
                setup_dataplane

                # Test connectivity from UE
                log "Testing UE internet connectivity..."
                local ping_result
                ping_result=$(docker exec ueransim ping -c 3 -W 2 -I uesimtun0 8.8.8.8 2>&1)
                if echo "$ping_result" | grep -q "bytes from"; then
                    log "  Ping 8.8.8.8 via uesimtun0: ${GREEN}OK${NC}"
                else
                    log "  Ping 8.8.8.8 via uesimtun0: ${YELLOW}FAILED${NC}"
                    log "  (UPF may need a moment to set up GTP tunnel)"
                fi
            else
                log "${RED}ERROR: uesimtun0 not created. PDU session failed.${NC}"
                log "Check AMF/SMF logs: ./free5gc.sh logs amf"
                docker exec ueransim cat /tmp/nr-ue.log 2>/dev/null || \
                    docker logs ueransim --tail 20 2>&1
                return 1
            fi
            ;;

        stop)
            log "Stopping UE..."
            docker exec ueransim pkill -f nr-ue 2>/dev/null || true
            cleanup_dataplane
            log "UE stopped and data plane routes cleaned up."
            ;;

        status)
            if docker exec ueransim ip addr show uesimtun0 >/dev/null 2>&1; then
                local ue_ip
                ue_ip=$(docker exec ueransim ip addr show uesimtun0 2>/dev/null | grep 'inet ' | awk '{print $2}')
                echo -e "${GREEN}UE is connected${NC}"
                echo "  IP: ${ue_ip}"
                echo "  Tunnel: uesimtun0"
                echo ""
                echo "Testing connectivity..."
                docker exec ueransim ping -c 2 -W 2 -I uesimtun0 8.8.8.8 2>&1 | tail -3
            else
                echo -e "${RED}UE is not connected${NC}"
                echo "  Start with: ./free5gc.sh ue start"
            fi
            ;;

        *)
            echo "Usage: ./free5gc.sh ue <start|stop|status>"
            ;;
    esac
}

webui_login() {
    # Login to WebUI and return JWT token (retry up to 30s)
    local token=""
    local attempt=0
    local max_attempts=15
    while [ $attempt -lt $max_attempts ]; do
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

provision_one() {
    # Provision a single subscriber. Args: <imsi> <key> <opc> <token>
    local p_imsi="$1"
    local p_key="$2"
    local p_opc="$3"
    local p_token="$4"

    # Derive unique MSISDN from IMSI to avoid duplicate GPSI errors
    local p_msisdn
    p_msisdn="msisdn-$(echo "$p_imsi" | sed 's/imsi-//')"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://localhost:${WEBUI_PORT}/api/subscriber/${p_imsi}/${PLMN}" \
        -H 'Content-Type: application/json' \
        -H "Token: ${p_token}" \
        -d "{
  \"plmnID\": \"${PLMN}\",
  \"ueId\": \"${p_imsi}\",
  \"AuthenticationSubscription\": {
    \"authenticationMethod\": \"5G_AKA\",
    \"permanentKey\": {\"permanentKeyValue\": \"${p_key}\", \"encryptionKey\": 0, \"encryptionAlgorithm\": 0},
    \"sequenceNumber\": \"${SQN}\",
    \"authenticationManagementField\": \"${AMF_FIELD}\",
    \"milenage\": {\"op\": {\"opValue\": \"\", \"encryptionKey\": 0, \"encryptionAlgorithm\": 0}},
    \"opc\": {\"opcValue\": \"${p_opc}\", \"encryptionKey\": 0, \"encryptionAlgorithm\": 0}
  },
  \"AccessAndMobilitySubscriptionData\": {
    \"gpsis\": [\"${p_msisdn}\"],
    \"subscribedUeAmbr\": {\"downlink\": \"2 Gbps\", \"uplink\": \"1 Gbps\"},
    \"nssai\": {
      \"defaultSingleNssais\": [{\"sst\": ${SST}, \"sd\": \"${SD}\"}],
      \"singleNssais\": [{\"sst\": ${SST}, \"sd\": \"${SD}\"}]
    }
  },
  \"SessionManagementSubscriptionData\": [{
    \"singleNssai\": {\"sst\": ${SST}, \"sd\": \"${SD}\"},
    \"dnnConfigurations\": {
      \"${DNN}\": {
        \"pduSessionTypes\": {\"defaultSessionType\": \"IPV4\", \"allowedSessionTypes\": [\"IPV4\"]},
        \"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},
        \"5gQosProfile\": {\"5qi\": 9, \"arp\": {\"priorityLevel\": 8, \"preemptCap\": \"\", \"preemptVuln\": \"\"}, \"priorityLevel\": 8},
        \"sessionAmbr\": {\"downlink\": \"1000 Mbps\", \"uplink\": \"1000 Mbps\"}
      }
    }
  }],
  \"SmfSelectionSubscriptionData\": {
    \"subscribedSnssaiInfos\": {
      \"0${SST}${SD}\": {\"dnnInfos\": [{\"dnn\": \"${DNN}\"}]}
    }
  },
  \"AmPolicyData\": {\"subscCats\": [\"free5gc\"]},
  \"SmPolicyData\": {
    \"smPolicySnssaiData\": {
      \"0${SST}${SD}\": {
        \"snssai\": {\"sst\": ${SST}, \"sd\": \"${SD}\"},
        \"smPolicyDnnData\": {\"${DNN}\": {\"dnn\": \"${DNN}\"}}
      }
    }
  }
}")

    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        log "  ${p_imsi} created (HTTP $http_code)"
    elif [ "$http_code" = "409" ]; then
        log "  ${p_imsi} already exists (HTTP 409)"
    else
        log "  ${p_imsi} WARNING: unexpected response (HTTP $http_code)"
    fi

    # Patch MongoDB: add allowedSessionTypes
    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['subscriptionData.provisionedData.smData'].updateMany(
  { ueId: '${p_imsi}' },
  { \$set: { 'dnnConfigurations.internet.pduSessionTypes.allowedSessionTypes': ['IPV4'] } }
)" 2>&1 | grep -v "^$"

    # Patch MongoDB: populate smPolicySnssaiData
    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['policyData.ues.smData'].updateOne(
  { ueId: '${p_imsi}' },
  {
    \$set: {
      smPolicySnssaiData: {
        '0${SST}${SD}': {
          snssai: { sst: ${SST}, sd: '${SD}' },
          smPolicyDnnData: { '${DNN}': { dnn: '${DNN}' } }
        }
      }
    }
  },
  { upsert: true }
)" 2>&1 | grep -v "^$"
}

# Increment a hex string by an offset (preserves leading zeros and length)
# Uses python3 to handle 128-bit hex values (bash overflows at 64-bit)
hex_add() {
    local hex_str="$1"
    local offset="$2"
    local len=${#hex_str}
    python3 -c "print(format(int('${hex_str}',16)+${offset},'0${len}x'))"
}

cmd_provision() {
    log "Provisioning subscriber ${IMSI}..."
    log "Logging in to WebUI (port ${WEBUI_PORT})..."
    local token
    token=$(webui_login) || {
        log "ERROR: Failed to get JWT token from WebUI"
        return 1
    }
    log "  JWT token obtained"
    provision_one "$IMSI" "$K" "$OPC" "$token"
    log "Subscriber ${IMSI} provisioned."
}

cmd_bulk_provision() {
    # Defaults
    local start_supi="001010123456789"
    local start_key="00112233445566778899aabbccddeeff"
    local opc="000102030405060708090a0b0c0d0e0f"
    local count=1
    local same_key=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --supi)     start_supi="$2"; shift 2 ;;
            --key)      start_key="$2"; shift 2 ;;
            --opc)      opc="$2"; shift 2 ;;
            --count)    count="$2"; shift 2 ;;
            --same-key) same_key=true; shift ;;
            *) log "Unknown option: $1"; return 1 ;;
        esac
    done

    # Normalize hex to lowercase
    start_key=$(echo "$start_key" | tr '[:upper:]' '[:lower:]')
    opc=$(echo "$opc" | tr '[:upper:]' '[:lower:]')

    if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
        log "ERROR: --count must be a positive integer"
        return 1
    fi

    log "Bulk provisioning ${count} subscriber(s)..."
    log "  Starting SUPI: ${start_supi}"
    log "  KEY:           ${start_key}"
    if [ "$same_key" = true ]; then
        log "  KEY mode:      same for all (--same-key)"
    else
        log "  KEY mode:      auto-increment (+1 per UE)"
    fi
    log "  OPC (shared):  ${opc}"
    echo ""

    log "Logging in to WebUI (port ${WEBUI_PORT})..."
    local token
    token=$(webui_login) || {
        log "ERROR: Failed to get JWT token from WebUI"
        return 1
    }
    log "  JWT token obtained"
    echo ""

    local success=0
    local failed=0
    for (( i=0; i<count; i++ )); do
        local cur_supi_num
        cur_supi_num=$(python3 -c "print(format(int('${start_supi}')+${i},'0${#start_supi}d'))")
        local cur_imsi="imsi-${cur_supi_num}"
        local cur_key
        if [ "$same_key" = true ]; then
            cur_key="$start_key"
        else
            cur_key=$(hex_add "$start_key" "$i")
        fi

        log "[$(( i + 1 ))/${count}] Provisioning ${cur_imsi} (key: ${cur_key})..."
        if provision_one "$cur_imsi" "$cur_key" "$opc" "$token"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    log "Bulk provisioning complete: ${success} succeeded, ${failed} failed (total: ${count})"
}

update_configs() {
    # Update all NF config files with current MCC/MNC/TAC values
    local cfg_dir="$1"
    local tac_hex
    tac_hex=$(printf "%06x" "$TAC")

    log "Updating configs: MCC=${MCC} MNC=${MNC} TAC=${TAC} (hex: ${tac_hex})"

    # amfcfg.yaml — MCC/MNC/TAC/NGAP port
    if [ -f "${cfg_dir}/amfcfg.yaml" ]; then
        sed -i "s/^\(\s*-\?\s*mcc:\s*\)[0-9]\{3\}/\1${MCC}/g" "${cfg_dir}/amfcfg.yaml"
        sed -i "s/^\(\s*-\?\s*mnc:\s*\)[0-9]\{2,3\}/\1${MNC}/g" "${cfg_dir}/amfcfg.yaml"
        sed -i "s/^\(\s*tac:\s*\)[0-9a-fA-F]\{6\}/\1${tac_hex}/" "${cfg_dir}/amfcfg.yaml"
        log "  Updated ${cfg_dir}/amfcfg.yaml"
    fi

    # smfcfg.yaml — MCC/MNC
    if [ -f "${cfg_dir}/smfcfg.yaml" ]; then
        sed -i "s/^\(\s*-\?\s*mcc:\s*\)[0-9]\{3\}/\1${MCC}/g" "${cfg_dir}/smfcfg.yaml"
        sed -i "s/^\(\s*-\?\s*mnc:\s*\)[0-9]\{2,3\}/\1${MNC}/g" "${cfg_dir}/smfcfg.yaml"
        log "  Updated ${cfg_dir}/smfcfg.yaml"
    fi

    # nrfcfg.yaml — MCC/MNC
    if [ -f "${cfg_dir}/nrfcfg.yaml" ]; then
        sed -i "s/^\(\s*-\?\s*mcc:\s*\)[0-9]\{3\}/\1${MCC}/g" "${cfg_dir}/nrfcfg.yaml"
        sed -i "s/^\(\s*-\?\s*mnc:\s*\)[0-9]\{2,3\}/\1${MNC}/g" "${cfg_dir}/nrfcfg.yaml"
        log "  Updated ${cfg_dir}/nrfcfg.yaml"
    fi

    # nssfcfg.yaml — MCC/MNC (only supportedPlmnList + supportedNssaiInPlmnList)
    if [ -f "${cfg_dir}/nssfcfg.yaml" ]; then
        sed -i '/^  supportedPlmnList:/,/^  supportedNssaiInPlmnList:/{s/^\(\s*mcc:\s*\)[0-9]\{3\}/\1'"${MCC}"'/; s/^\(\s*mnc:\s*\)[0-9]\{2,3\}/\1'"${MNC}"'/}' "${cfg_dir}/nssfcfg.yaml"
        sed -i '/^  supportedNssaiInPlmnList:/,/^  nsiList:/{s/^\(\s*mcc:\s*\)[0-9]\{3\}/\1'"${MCC}"'/; s/^\(\s*mnc:\s*\)[0-9]\{2,3\}/\1'"${MNC}"'/}' "${cfg_dir}/nssfcfg.yaml"
        log "  Updated ${cfg_dir}/nssfcfg.yaml"
    fi

    # gnbcfg.yaml — MCC/MNC/TAC (UERANSIM format: quoted strings, decimal TAC)
    if [ -f "${cfg_dir}/gnbcfg.yaml" ]; then
        sed -i "s/^mcc: \"[0-9]\{3\}\"/mcc: \"${MCC}\"/" "${cfg_dir}/gnbcfg.yaml"
        sed -i "s/^mnc: \"[0-9]\{2,3\}\"/mnc: \"${MNC}\"/" "${cfg_dir}/gnbcfg.yaml"
        sed -i "s/^tac: [0-9]\+/tac: ${TAC}/" "${cfg_dir}/gnbcfg.yaml"
        log "  Updated ${cfg_dir}/gnbcfg.yaml"
    fi

    # uecfg.yaml — IMSI/MCC/MNC
    if [ -f "${cfg_dir}/uecfg.yaml" ]; then
        sed -i "s/^supi: \"imsi-[0-9]\+\"/supi: \"${IMSI}\"/" "${cfg_dir}/uecfg.yaml"
        sed -i "s/^mcc: \"[0-9]\{3\}\"/mcc: \"${MCC}\"/" "${cfg_dir}/uecfg.yaml"
        sed -i "s/^mnc: \"[0-9]\{2,3\}\"/mnc: \"${MNC}\"/" "${cfg_dir}/uecfg.yaml"
        log "  Updated ${cfg_dir}/uecfg.yaml"
    fi
}

cmd_start() {
    local debug=false
    local with_ueransim=false

    # Parse start sub-arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --debug) debug=true; shift ;;
            --ueransim) with_ueransim=true; shift ;;
            --mcc)   MCC="$2"; shift 2 ;;
            --mnc)   MNC="$2"; shift 2 ;;
            --tac)   TAC="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Validate MCC/MNC/TAC
    if ! [[ "$MCC" =~ ^[0-9]{3}$ ]]; then
        log "ERROR: MCC must be exactly 3 digits (e.g. 001, 404, 310)"
        exit 1
    fi
    if ! [[ "$MNC" =~ ^[0-9]{2,3}$ ]]; then
        log "ERROR: MNC must be 2 or 3 digits (e.g. 01, 30, 560)"
        exit 1
    fi
    if ! [[ "$TAC" =~ ^[0-9]+$ ]]; then
        log "ERROR: TAC must be a decimal number (e.g. 1, 100, 33456)"
        exit 1
    fi

    # Recompute derived values from (possibly updated) MCC/MNC
    PLMN="${MCC}${MNC}"
    IMSI="imsi-${MCC}${MNC}0000050641"

    mkdir -p logs/cp logs/upf

    # Set config directory based on debug flag
    if [ "$debug" = true ]; then
        export CONFIG_DIR="config-debug"
        log "Mode: DEBUG (config-debug/ with debug-level logging)"
    else
        export CONFIG_DIR="config"
        log "Mode: NORMAL (config/ with info-level logging)"
    fi

    # Update config files with MCC/MNC/TAC
    update_configs "$CONFIG_DIR"

    log "PLMN: ${MCC}/${MNC}  TAC: ${TAC}  IMSI: ${IMSI}"

    # Start containers (core services; UERANSIM only with --ueransim)
    log "Step 1/5: Starting containers..."
    if [ "$with_ueransim" = true ]; then
        log "  Including UERANSIM (--ueransim flag)"
        docker compose -f "$COMPOSE_FILE" --profile ueransim up -d
    else
        docker compose -f "$COMPOSE_FILE" up -d
    fi

    # Wait for CP health
    log "Step 2/5: Waiting for Control Plane to be healthy..."
    wait_healthy "free5gc-cp" 120 || {
        log "Container logs:"
        docker logs free5gc-cp --tail 20 2>&1 | head -20
    }

    # Setup SCTP forwarding for NGAP (Docker can't proxy SCTP)
    log "Setting up SCTP port forwarding for NGAP (${NGAP_PORT} -> ${AMF_IP})..."
    setup_sctp_forward

    # Provision default subscriber
    log "Step 3/5: Provisioning default subscriber..."
    cmd_provision || log "WARNING: Subscriber provisioning failed. May need manual setup."

    # Restart UERANSIM to ensure gNB connects after AMF NGAP is ready (only if started)
    if [ "$with_ueransim" = true ]; then
        log "Restarting UERANSIM to ensure gNB-AMF connection..."
        docker restart ueransim >/dev/null 2>&1
        sleep 5
    fi

    # Setup data plane routing (host -> UPF -> internet for real UE traffic)
    log "Step 4/5: Setting up data plane routing..."
    setup_dataplane

    # Show status
    log "Step 5/5: Deployment status"
    echo ""
    if [ "$with_ueransim" = true ]; then
        docker compose -f "$COMPOSE_FILE" --profile ueransim ps
    else
        docker compose -f "$COMPOSE_FILE" ps
    fi
    echo ""
    log "========================================="
    log "  free5GC IS RUNNING"
    log "========================================="
    echo ""
    log "WebUI:  http://$(hostname -I | awk '{print $1}'):4000"
    log "        Login: admin / free5gc"
    if [ "$with_ueransim" = false ]; then
        log ""
        log "UERANSIM not started. To include it: ./free5gc.sh start --ueransim"
    fi
    log "Logs:   ./free5gc.sh logs"
    log "Stop:   ./free5gc.sh stop"
    log "Remove: ./free5gc.sh remove"
    echo ""
}

cmd_capture() {
    local subcmd="${1:-start}"
    local name="${2:-capture-$(date +%Y%m%d-%H%M%S)}"

    if ! command -v tshark &>/dev/null; then
        log "ERROR: tshark not installed. Run: apt-get install -y tshark"
        exit 1
    fi

    case "$subcmd" in
        start)
            mkdir -p "$PCAP_DIR"
            chmod 777 "$PCAP_DIR" 2>/dev/null || true

            # Kill any leftover tshark
            pkill -f "tshark.*${CAPTURE_IF}" 2>/dev/null || true
            pkill -f "tshark.*pcap-traces" 2>/dev/null || true
            sleep 1

            local pcap_file="${PCAP_DIR}/${name}.pcap"
            local sbi_pcap_file="${PCAP_DIR}/${name}-sbi.pcap"

            # Capture bridge: NGAP (SCTP), PFCP (UDP 8805), GTP-U (UDP 2152)
            tshark -i "$CAPTURE_IF" -w "$pcap_file" \
                -f "sctp or udp port 8805 or udp port 2152" \
                -q </dev/null >/dev/null 2>&1 &
            local bridge_pid=$!

            # Capture SBI/HTTP2 on loopback inside free5gc-cp container
            local sbi_pid=0
            local cp_pid
            cp_pid=$(docker inspect --format '{{.State.Pid}}' free5gc-cp 2>/dev/null || echo "")
            if [ -n "$cp_pid" ] && [ "$cp_pid" != "0" ]; then
                nsenter -t "$cp_pid" -n tshark -i lo -w "$sbi_pcap_file" \
                    -f "tcp portrange 8000-8007" \
                    -q </dev/null >/dev/null 2>&1 &
                sbi_pid=$!
            fi

            sleep 2

            if kill -0 "$bridge_pid" 2>/dev/null; then
                log "Bridge capture started: $pcap_file (PID: $bridge_pid)"
            else
                log "ERROR: Failed to start bridge capture"
                exit 1
            fi
            if [ "$sbi_pid" -ne 0 ] && kill -0 "$sbi_pid" 2>/dev/null; then
                log "SBI capture started: $sbi_pcap_file (PID: $sbi_pid)"
            fi

            # Save PIDs for stop
            echo "$bridge_pid" > "${PCAP_DIR}/.bridge_pid"
            echo "$sbi_pid" > "${PCAP_DIR}/.sbi_pid"
            echo "$name" > "${PCAP_DIR}/.capture_name"

            log "Capture running. Stop with: ./free5gc.sh capture stop"
            ;;

        stop)
            local bridge_pid=0 sbi_pid=0 cap_name="capture"

            [ -f "${PCAP_DIR}/.bridge_pid" ] && bridge_pid=$(cat "${PCAP_DIR}/.bridge_pid")
            [ -f "${PCAP_DIR}/.sbi_pid" ] && sbi_pid=$(cat "${PCAP_DIR}/.sbi_pid")
            [ -f "${PCAP_DIR}/.capture_name" ] && cap_name=$(cat "${PCAP_DIR}/.capture_name")

            if [ "$bridge_pid" -ne 0 ] 2>/dev/null && kill -0 "$bridge_pid" 2>/dev/null; then
                kill "$bridge_pid" 2>/dev/null
                wait "$bridge_pid" 2>/dev/null || true
                log "Bridge capture stopped"
            fi
            if [ "$sbi_pid" -ne 0 ] 2>/dev/null && kill -0 "$sbi_pid" 2>/dev/null; then
                kill "$sbi_pid" 2>/dev/null
                wait "$sbi_pid" 2>/dev/null || true
                log "SBI capture stopped"
            fi

            sleep 1

            # Merge bridge + SBI pcaps
            local sbi_file="${PCAP_DIR}/${cap_name}-sbi.pcap"
            local base_file="${PCAP_DIR}/${cap_name}.pcap"
            if [ -f "$sbi_file" ] && [ -f "$base_file" ]; then
                local merged_file="${PCAP_DIR}/${cap_name}-merged.pcap"
                if mergecap -w "$merged_file" "$base_file" "$sbi_file" 2>/dev/null; then
                    mv "$merged_file" "$base_file"
                    rm -f "$sbi_file"
                    log "Merged SBI traffic into $(basename "$base_file")"
                fi
            fi

            chmod 644 "${PCAP_DIR}"/*.pcap 2>/dev/null || true
            rm -f "${PCAP_DIR}/.bridge_pid" "${PCAP_DIR}/.sbi_pid" "${PCAP_DIR}/.capture_name"

            if [ -f "$base_file" ]; then
                local pkt_count
                pkt_count=$(tshark -r "$base_file" 2>/dev/null | wc -l)
                log "Pcap saved: $base_file ($pkt_count packets)"
                log "Download: scp root@$(hostname -I | awk '{print $1}'):${base_file} ."
            fi
            ;;

        *)
            echo "Usage: ./free5gc.sh capture <start|stop> [name]"
            ;;
    esac
}

cmd_stop() {
    log "Cleaning up data plane routes..."
    cleanup_dataplane
    log "Cleaning up SCTP forwarding rules..."
    cleanup_sctp_forward
    log "Stopping all containers..."
    docker compose -f "$COMPOSE_FILE" --profile ueransim stop
    log "All containers stopped."
}

cmd_remove() {
    log "Removing all containers and volumes..."
    docker compose -f "$COMPOSE_FILE" --profile ueransim down -v
    log "All containers and volumes removed."
}

cmd_status() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║              free5GC Status & Validation                ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local all_ok=true

    # ── 1. Containers ──────────────────────────────────────
    echo -e "${CYAN}── Containers ──────────────────────────────────────────${NC}"
    local containers=("mongodb" "free5gc-cp" "upf" "webui")
    # Only check ueransim if its container exists
    if docker inspect ueransim >/dev/null 2>&1; then
        containers+=("ueransim")
    fi
    for c in "${containers[@]}"; do
        local state
        state=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
        local health=""
        if [ "$c" = "free5gc-cp" ]; then
            health=$(docker inspect --format='{{.State.Health.Status}}' "$c" 2>/dev/null || echo "")
            [ -n "$health" ] && health=" ($health)"
        fi
        if [ "$state" = "running" ]; then
            printf "  %-15s ${GREEN}%-10s${NC}%s\n" "$c" "running" "$health"
        else
            printf "  %-15s ${RED}%-10s${NC}\n" "$c" "$state"
            all_ok=false
        fi
    done
    echo ""

    # ── 2. Control Plane (NGAP/SCTP) ──────────────────────
    echo -e "${CYAN}── Control Plane (NGAP) ────────────────────────────────${NC}"
    # SCTP DNAT
    if iptables -t nat -C PREROUTING -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}" >/dev/null 2>&1; then
        echo -e "  SCTP DNAT :${NGAP_PORT}     ${GREEN}OK${NC}  -> ${AMF_IP}:${NGAP_PORT}"
    else
        echo -e "  SCTP DNAT :${NGAP_PORT}     ${RED}MISSING${NC}"
        all_ok=false
    fi
    # AMF listening
    if docker exec free5gc-cp ss -Slnp 2>/dev/null | grep -q "$NGAP_PORT"; then
        echo -e "  AMF SCTP listener    ${GREEN}OK${NC}  :${NGAP_PORT}"
    else
        echo -e "  AMF SCTP listener    ${RED}NOT LISTENING${NC}"
        all_ok=false
    fi
    echo ""

    # ── 3. Data Plane (GTP-U) ─────────────────────────────
    echo -e "${CYAN}── Data Plane (GTP-U) ──────────────────────────────────${NC}"
    local UPF_CUR_IP
    UPF_CUR_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' upf 2>/dev/null)
    # GTP-U DNAT
    if iptables -t nat -C PREROUTING -p udp --dport "$GTPU_PORT" -j DNAT --to-destination "${UPF_CUR_IP}:${GTPU_PORT}" >/dev/null 2>&1; then
        echo -e "  GTP-U DNAT :${GTPU_PORT}    ${GREEN}OK${NC}  -> ${UPF_CUR_IP}:${GTPU_PORT}"
    else
        echo -e "  GTP-U DNAT :${GTPU_PORT}    ${RED}MISSING${NC}"
        all_ok=false
    fi
    # UPF listening
    if docker exec upf ss -ulnp 2>/dev/null | grep -q "$GTPU_PORT"; then
        echo -e "  UPF GTP-U listener   ${GREEN}OK${NC}  :${GTPU_PORT}"
    else
        echo -e "  UPF GTP-U listener   ${RED}NOT LISTENING${NC}"
        all_ok=false
    fi
    # UPF pool
    local upf_pool
    upf_pool=$(docker exec upf ip route show 2>/dev/null | grep upfgtp | awk '{print $1}')
    if [ "$upf_pool" = "$UE_SUBNET" ]; then
        echo -e "  UPF IP pool          ${GREEN}OK${NC}  ${upf_pool} on upfgtp"
    else
        echo -e "  UPF IP pool          ${RED}WRONG${NC}  got: ${upf_pool:-none}, expected: ${UE_SUBNET}"
        all_ok=false
    fi
    # PFCP association
    if grep -q "New node\|handleAssociationSetupRequest" "$SCRIPT_DIR/logs/upf/upf.log" 2>/dev/null; then
        echo -e "  PFCP association     ${GREEN}OK${NC}  SMF <-> UPF"
    else
        echo -e "  PFCP association     ${RED}NOT FOUND${NC}"
        all_ok=false
    fi
    echo ""

    # ── 4. Host Routing & NAT ─────────────────────────────
    echo -e "${CYAN}── Host Routing & NAT ──────────────────────────────────${NC}"
    # Route
    if ip route show | grep -q "$UE_SUBNET"; then
        local via
        via=$(ip route show | grep "$UE_SUBNET" | awk '{print $3}')
        echo -e "  Route ${UE_SUBNET}  ${GREEN}OK${NC}  via ${via}"
    else
        echo -e "  Route ${UE_SUBNET}  ${RED}MISSING${NC}"
        all_ok=false
    fi
    # NAT
    if iptables -t nat -C POSTROUTING -s "$UE_SUBNET" ! -o br-free5gc -j MASQUERADE >/dev/null 2>&1; then
        echo -e "  NAT MASQUERADE       ${GREEN}OK${NC}  for ${UE_SUBNET}"
    else
        echo -e "  NAT MASQUERADE       ${RED}MISSING${NC}"
        all_ok=false
    fi
    # FORWARD
    if iptables -C FORWARD -s "$UE_SUBNET" -j ACCEPT >/dev/null 2>&1 && iptables -C FORWARD -d "$UE_SUBNET" -j ACCEPT >/dev/null 2>&1; then
        echo -e "  FORWARD rules        ${GREEN}OK${NC}  ACCEPT ${UE_SUBNET}"
    else
        echo -e "  FORWARD rules        ${RED}MISSING${NC}"
        all_ok=false
    fi
    # ip_forward
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    if [ "$fwd" = "1" ]; then
        echo -e "  IP forwarding        ${GREEN}OK${NC}  enabled"
    else
        echo -e "  IP forwarding        ${RED}DISABLED${NC}"
        all_ok=false
    fi
    echo ""

    # ── 5. Subscriber ─────────────────────────────────────
    echo -e "${CYAN}── Subscriber ──────────────────────────────────────────${NC}"
    local auth_count
    auth_count=$(docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "db['subscriptionData.authenticationData.authenticationSubscription'].count({ueId: '${IMSI}'})" 2>/dev/null)
    local am_count
    am_count=$(docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "db['subscriptionData.provisionedData.amData'].count({ueId: '${IMSI}'})" 2>/dev/null)
    local sm_count
    sm_count=$(docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "db['subscriptionData.provisionedData.smData'].count({ueId: '${IMSI}'})" 2>/dev/null)

    echo -e "  IMSI: ${IMSI}"
    echo -e "  PLMN: ${PLMN} (MCC:${MCC} MNC:${MNC})"
    echo -e "  NSSAI: SST:${SST} SD:${SD}  DNN:${DNN}"
    if [ "${auth_count:-0}" -ge 1 ] && [ "${am_count:-0}" -ge 1 ] && [ "${sm_count:-0}" -ge 1 ]; then
        echo -e "  MongoDB records      ${GREEN}OK${NC}  auth:${auth_count} am:${am_count} sm:${sm_count}"
    else
        echo -e "  MongoDB records      ${RED}INCOMPLETE${NC}  auth:${auth_count:-0} am:${am_count:-0} sm:${sm_count:-0}"
        echo -e "  Run: ${YELLOW}./free5gc.sh provision${NC}"
        all_ok=false
    fi
    echo ""

    # ── 6. NF Health (CP logs) ────────────────────────────
    echo -e "${CYAN}── NF Registration (NRF) ───────────────────────────────${NC}"
    local nfs=("NRF" "AMF" "AUSF" "UDM" "UDR" "SMF" "NSSF" "PCF")
    for nf in "${nfs[@]}"; do
        local nf_lower
        nf_lower=$(echo "$nf" | tr '[:upper:]' '[:lower:]')
        if [ -f "$SCRIPT_DIR/logs/cp/${nf_lower}.log" ]; then
            if grep -q "REGISTERED\|server started\|OAuth2 setting receive" "$SCRIPT_DIR/logs/cp/${nf_lower}.log" 2>/dev/null; then
                printf "  %-10s ${GREEN}OK${NC}\n" "$nf"
            else
                printf "  %-10s ${YELLOW}STARTING${NC}\n" "$nf"
            fi
        else
            printf "  %-10s ${RED}NO LOG${NC}\n" "$nf"
            all_ok=false
        fi
    done
    echo ""

    # ── 7. Connectivity Test ──────────────────────────────
    echo -e "${CYAN}── Connectivity ────────────────────────────────────────${NC}"
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    echo -e "  Host IP: ${host_ip}"
    echo -e "  WebUI:   http://${host_ip}:${WEBUI_PORT}"
    # Check if UERANSIM UE is connected
    if docker exec ueransim ip addr show uesimtun0 >/dev/null 2>&1; then
        local ue_ip
        ue_ip=$(docker exec ueransim ip addr show uesimtun0 2>/dev/null | grep 'inet ' | awk '{print $2}')
        echo -e "  UERANSIM UE:         ${GREEN}CONNECTED${NC}  IP: ${ue_ip}"
        # Quick ping test
        if docker exec ueransim ping -c 1 -W 2 -I uesimtun0 8.8.8.8 >/dev/null 2>&1; then
            echo -e "  UE -> Internet:      ${GREEN}OK${NC}  (ping 8.8.8.8)"
        else
            echo -e "  UE -> Internet:      ${RED}FAIL${NC}  (ping 8.8.8.8)"
            all_ok=false
        fi
    else
        echo -e "  UERANSIM UE:         ${YELLOW}NOT CONNECTED${NC}"
        echo -e "  (real gNB may connect separately)"
    fi
    echo ""

    # ── Summary ───────────────────────────────────────────
    echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
    if [ "$all_ok" = true ]; then
        echo -e "  ${GREEN}${BOLD}ALL CHECKS PASSED${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}SOME CHECKS FAILED${NC} — review above"
    fi
    echo -e "${BOLD}════════════════════════════════════════════════════════${NC}"
    echo ""
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
    echo "  build [--quick]       Build all NFs from source (~15 min)"
    echo "                        --quick: rebuild runtime images only"
    echo "  start [options]       Start core network (MongoDB, CP, UPF, WebUI)"
    echo "                        --ueransim: also start UERANSIM gNB simulator"
    echo "                        --mcc VALUE: Mobile Country Code (3 digits, default: 001)"
    echo "                        --mnc VALUE: Mobile Network Code (2-3 digits, default: 01)"
    echo "                        --tac VALUE: Tracking Area Code (decimal, default: 1)"
    echo "                        --debug: use debug-level logging configs"
    echo "  capture start [name]  Start pcap capture (bridge + SBI)"
    echo "  capture stop          Stop capture, merge and save pcap"
    echo "  provision             Provision default subscriber in MongoDB"
    echo "  bulk-provision        Provision multiple subscribers"
    echo "                        --supi VALUE: starting SUPI (default: 001010123456789)"
    echo "                        --key VALUE: starting K (default: 00112233445566778899aabbccddeeff)"
    echo "                        --opc VALUE: OPC, same for all (default: 000102030405060708090a0b0c0d0e0f)"
    echo "                        --count N: number of UEs to provision (default: 1)"
    echo "                        --same-key: use same K for all UEs (no increment)"
    echo "  ue start              Launch UE, establish PDU session, setup data plane"
    echo "  ue stop               Stop UE and cleanup data plane routes"
    echo "  ue status             Check UE connection and test ping"
    echo "  stop                  Stop all containers"
    echo "  remove                Remove all containers and volumes"
    echo "  status                Show container status"
    echo "  logs [nf]             Tail logs (all or specific: amf, smf, etc.)"
    echo ""
    echo "Examples:"
    echo "  ./free5gc.sh build"
    echo "  ./free5gc.sh start"
    echo "  ./free5gc.sh start --ueransim"
    echo "  ./free5gc.sh start --ueransim --mcc 404 --mnc 30 --tac 1"
    echo "  ./free5gc.sh start --debug"
    echo "  ./free5gc.sh capture start my-test"
    echo "  ./free5gc.sh capture stop"
    echo "  ./free5gc.sh bulk-provision --count 10"
    echo "  ./free5gc.sh bulk-provision --supi 001010123456789 --key 00112233445566778899aabbccddeeff --opc 000102030405060708090a0b0c0d0e0f --count 5"
    echo "  ./free5gc.sh stop"
    echo "  ./free5gc.sh logs amf"
}

# ── Main ────────────────────────────────────────────────────

case "${1:-}" in
    build)  cmd_build "${2:-}" ;;
    start)  shift; cmd_start "$@" ;;
    capture) shift; cmd_capture "$@" ;;
    provision) cmd_provision ;;
    bulk-provision) shift; cmd_bulk_provision "$@" ;;
    ue) shift; cmd_ue "$@" ;;
    stop)   cmd_stop ;;
    remove) cmd_remove ;;
    status) cmd_status ;;
    logs)   cmd_logs "${2:-}" ;;
    *)      show_usage ;;
esac
