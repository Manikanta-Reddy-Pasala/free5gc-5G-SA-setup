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
#   ./free5gc.sh stop                 # Stop and remove all containers
#   ./free5gc.sh status               # Show container status
#   ./free5gc.sh logs [nf]            # Tail logs (all or specific NF)
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Constants ───────────────────────────────────────────────
COMPOSE_FILE="docker-compose-portable.yaml"
IMSI="imsi-001010000050641"
PLMN="00101"
MCC="001"
MNC="01"
K="0c57e15a2cb86087097a6b50d42531de"
OPC="109ee52735ae6d3849112cf4175029c7"
SQN="000000000020"
AMF_FIELD="8000"

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

    # Use the persistent WebUI container from docker-compose
    if docker ps --filter name=webui --format '{{.Names}}' | grep -q "^webui$"; then
        log "Using persistent WebUI container..."
    else
        log "WebUI container not running. Starting it..."
        docker compose -f "$COMPOSE_FILE" up -d webui
        sleep 5
        if ! docker ps --filter name=webui --format '{{.Status}}' | grep -q "Up"; then
            log "ERROR: WebUI failed to start"
            return 1
        fi
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
      \"defaultSingleNssais\": [{\"sst\": 3, \"sd\": \"198153\"}]
    }
  },
  \"SessionManagementSubscriptionData\": [
    {
      \"singleNssai\": {\"sst\": 3, \"sd\": \"198153\"},
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
      \"03198153\": {\"dnnInfos\": [{\"dnn\": \"internet\"}]}
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
        '03198153': {
          snssai: { sst: 3, sd: '198153' },
          smPolicyDnnData: { internet: { dnn: 'internet' } }
        }
      }
    }
  },
  { upsert: true }
)" 2>&1 | grep -v "^$"

    log "Subscriber $imsi provisioned."
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
    mkdir -p logs/cp logs/upf

    # Start all containers (CP + UPF + UERANSIM)
    log "Step 1/4: Starting containers..."
    docker compose -f "$COMPOSE_FILE" up -d

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
    log "WebUI:  http://$(hostname -I | awk '{print $1}'):5000"
    log "        Login: admin / free5gc"
    log "Logs:   ./free5gc.sh logs"
    log "Stop:   ./free5gc.sh stop"
    echo ""
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
    echo "  build [--quick]       Build all NFs from source (~15 min)"
    echo "                        --quick: rebuild runtime images only"
    echo "  start                 Start containers + provision subscriber"
    echo "  stop                  Stop and remove all containers"
    echo "  status                Show container status"
    echo "  logs [nf]             Tail logs (all or specific: amf, smf, etc.)"
    echo ""
    echo "Examples:"
    echo "  ./free5gc.sh build"
    echo "  ./free5gc.sh start"
    echo "  ./free5gc.sh stop"
    echo "  ./free5gc.sh logs amf"
}

# ── Main ────────────────────────────────────────────────────

case "${1:-}" in
    build)  cmd_build "${2:-}" ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    logs)   cmd_logs "${2:-}" ;;
    *)      show_usage ;;
esac
