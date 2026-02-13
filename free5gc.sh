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
#   ./free5gc.sh start                # Start containers + provision subscriber
#   ./free5gc.sh start --debug        # Start with debug-level logging
#   ./free5gc.sh capture start [name] # Start pcap capture (bridge + SBI)
#   ./free5gc.sh capture stop         # Stop capture and save pcap
#   ./free5gc.sh provision            # Provision subscriber in MongoDB
#   ./free5gc.sh ue start               # Launch UE + setup data plane
#   ./free5gc.sh ue stop                # Stop UE + cleanup routes
#   ./free5gc.sh ue status              # Check UE connectivity
#   ./free5gc.sh stop                 # Stop and remove all containers
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

# Subscriber / PLMN
IMSI="imsi-001010000050641"
PLMN="00101"
MCC="001"
MNC="01"
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

cmd_provision() {
    log "Provisioning subscriber ${IMSI}..."

    # Login to WebUI to get JWT token
    log "Logging in to WebUI (port ${WEBUI_PORT})..."
    local token
    token=$(curl -s -X POST "http://localhost:${WEBUI_PORT}/api/login" \
        -H 'Content-Type: application/json' \
        -d '{"username":"admin","password":"free5gc"}' | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

    if [ -z "$token" ] || [ "$token" = "None" ]; then
        log "ERROR: Failed to get JWT token from WebUI"
        return 1
    fi
    log "  JWT token obtained"

    # Create subscriber via WebUI API
    log "Creating subscriber ${IMSI} (PLMN: ${PLMN})..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://localhost:${WEBUI_PORT}/api/subscriber/${IMSI}/${PLMN}" \
        -H 'Content-Type: application/json' \
        -H "Token: ${token}" \
        -d "{
  \"plmnID\": \"${PLMN}\",
  \"ueId\": \"${IMSI}\",
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
        log "  Subscriber created (HTTP $http_code)"
    elif [ "$http_code" = "409" ]; then
        log "  Subscriber already exists (HTTP 409)"
    else
        log "WARNING: Unexpected response (HTTP $http_code)"
    fi

    # Patch MongoDB: add allowedSessionTypes
    log "Patching MongoDB: adding allowedSessionTypes..."
    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['subscriptionData.provisionedData.smData'].updateMany(
  { ueId: '${IMSI}' },
  { \$set: { 'dnnConfigurations.internet.pduSessionTypes.allowedSessionTypes': ['IPV4'] } }
)" 2>&1 | grep -v "^$"

    # Patch MongoDB: populate smPolicySnssaiData
    log "Patching MongoDB: populating smPolicySnssaiData..."
    docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['policyData.ues.smData'].updateOne(
  { ueId: '${IMSI}' },
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

    log "Subscriber ${IMSI} provisioned."
}

cmd_start() {
    local debug=false
    if [ "${1:-}" = "--debug" ]; then
        debug=true
    fi

    mkdir -p logs/cp logs/upf

    # Set config directory based on debug flag
    if [ "$debug" = true ]; then
        export CONFIG_DIR="config-debug"
        log "Mode: DEBUG (config-debug/ with debug-level logging)"
    else
        export CONFIG_DIR="config"
        log "Mode: NORMAL (config/ with info-level logging)"
    fi

    # Start all containers (CP + UPF + UERANSIM)
    log "Step 1/5: Starting containers..."
    docker compose -f "$COMPOSE_FILE" up -d

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

    # Restart UERANSIM to ensure gNB connects after AMF NGAP is ready
    log "Restarting UERANSIM to ensure gNB-AMF connection..."
    docker restart ueransim >/dev/null 2>&1
    sleep 5

    # Setup data plane routing (host -> UPF -> internet for real UE traffic)
    log "Step 4/5: Setting up data plane routing..."
    setup_dataplane

    # Show status
    log "Step 5/5: Deployment status"
    echo ""
    docker compose -f "$COMPOSE_FILE" ps
    echo ""
    log "========================================="
    log "  free5GC IS RUNNING"
    log "========================================="
    echo ""
    log "WebUI:  http://$(hostname -I | awk '{print $1}'):4000"
    log "        Login: admin / free5gc"
    log "Logs:   ./free5gc.sh logs"
    log "Stop:   ./free5gc.sh stop"
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
    echo "  build [--quick]       Build all NFs from source (~15 min)"
    echo "                        --quick: rebuild runtime images only"
    echo "  start [--debug]       Start all containers"
    echo "                        --debug: use debug-level logging configs"
    echo "  capture start [name]  Start pcap capture (bridge + SBI)"
    echo "  capture stop          Stop capture, merge and save pcap"
    echo "  provision             Provision subscriber (IMSI/PLMN) in MongoDB"
    echo "  ue start              Launch UE, establish PDU session, setup data plane"
    echo "  ue stop               Stop UE and cleanup data plane routes"
    echo "  ue status             Check UE connection and test ping"
    echo "  stop                  Stop and remove all containers"
    echo "  status                Show container status"
    echo "  logs [nf]             Tail logs (all or specific: amf, smf, etc.)"
    echo ""
    echo "Examples:"
    echo "  ./free5gc.sh build"
    echo "  ./free5gc.sh start"
    echo "  ./free5gc.sh start --debug"
    echo "  ./free5gc.sh capture start my-test"
    echo "  ./free5gc.sh capture stop"
    echo "  ./free5gc.sh stop"
    echo "  ./free5gc.sh logs amf"
}

# ── Main ────────────────────────────────────────────────────

case "${1:-}" in
    build)  cmd_build "${2:-}" ;;
    start)  cmd_start "${2:-}" ;;
    capture) shift; cmd_capture "$@" ;;
    provision) cmd_provision ;;
    ue) shift; cmd_ue "$@" ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    logs)   cmd_logs "${2:-}" ;;
    *)      show_usage ;;
esac
