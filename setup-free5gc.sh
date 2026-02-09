#!/bin/bash
set -euo pipefail

# ============================================================
# free5GC Docker Compose Setup Script with UERANSIM
# Tested on: Ubuntu 22.04 LTS, Kernel 5.15.x
# free5GC version: v4.2.0
# UERANSIM version: v3.2.7
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

INSTALL_DIR="/root/free5gc-compose"
SUBSCRIBER_IMSI="imsi-208930000000001"
SUBSCRIBER_PLMN="20893"
WEBUI_URL="http://localhost:5000"
WEBUI_USER="admin"
WEBUI_PASS="free5gc"

# ============================================================
# Phase 1: Install Prerequisites
# ============================================================
install_docker() {
    log_info "Installing Docker Engine and Docker Compose..."

    if command -v docker &> /dev/null; then
        log_info "Docker already installed: $(docker --version)"
        return 0
    fi

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    log_info "Docker installed: $(docker --version)"
    log_info "Docker Compose installed: $(docker compose version)"
}

install_gtp5g() {
    log_info "Installing GTP5G kernel module..."

    if lsmod | grep -q gtp5g; then
        log_info "GTP5G kernel module already loaded"
        return 0
    fi

    apt-get install -y -qq linux-headers-$(uname -r) build-essential make gcc

    cd /root
    if [ ! -d "gtp5g" ]; then
        git clone https://github.com/free5gc/gtp5g.git
    fi

    cd gtp5g
    make clean || true
    make
    make install
    modprobe gtp5g

    if lsmod | grep -q gtp5g; then
        log_info "GTP5G kernel module loaded successfully"
    else
        log_error "Failed to load GTP5G kernel module"
        exit 1
    fi
}

# ============================================================
# Phase 2: Clone and Configure free5GC
# ============================================================
clone_free5gc() {
    log_info "Cloning free5gc-compose repository..."

    if [ -d "$INSTALL_DIR" ]; then
        log_warn "Directory $INSTALL_DIR already exists, pulling latest..."
        cd "$INSTALL_DIR" && git pull || true
    else
        cd /root
        git clone https://github.com/free5gc/free5gc-compose.git
    fi

    cd "$INSTALL_DIR"
    log_info "free5gc-compose cloned at $INSTALL_DIR"
}

# ============================================================
# Phase 3: Start Services
# ============================================================
start_services() {
    log_info "Pulling Docker images and starting services..."

    cd "$INSTALL_DIR"

    # Pull all images first
    docker compose pull

    # Start all services (includes UERANSIM gNB, N3IWF, N3IWUE, etc.)
    docker compose up -d

    log_info "Waiting 25 seconds for all services to initialize..."
    sleep 25

    # Verify all containers are running
    local running
    running=$(docker compose ps --format json 2>/dev/null | grep -c '"running"' || docker compose ps 2>/dev/null | grep -c "Up")
    log_info "$running containers running"

    # Print status
    docker compose ps --format "table {{.Name}}\t{{.Status}}"
}

# ============================================================
# Phase 4: Provision Subscriber
# ============================================================
provision_subscriber() {
    log_info "Provisioning test subscriber ($SUBSCRIBER_IMSI)..."

    # Login to WebUI
    local token
    token=$(curl -s -X POST "$WEBUI_URL/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$WEBUI_USER\",\"password\":\"$WEBUI_PASS\"}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

    if [ -z "$token" ]; then
        log_error "Failed to login to WebUI"
        exit 1
    fi

    # Create subscriber via API
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$WEBUI_URL/api/subscriber/$SUBSCRIBER_IMSI/$SUBSCRIBER_PLMN" \
        -H "Content-Type: application/json" \
        -H "Token: $token" \
        -d @- <<'ENDJSON'
{
  "plmnID": "20893",
  "ueId": "imsi-208930000000001",
  "AuthenticationSubscription": {
    "authenticationManagementField": "8000",
    "authenticationMethod": "5G_AKA",
    "milenage": {"op": {"encryptionAlgorithm": 0, "encryptionKey": 0, "opValue": ""}},
    "opc": {"encryptionAlgorithm": 0, "encryptionKey": 0, "opcValue": "8e27b6af0e692e750f32667a3b14605d"},
    "permanentKey": {"encryptionAlgorithm": 0, "encryptionKey": 0, "permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862"},
    "sequenceNumber": "16f3b3f70fc2"
  },
  "AccessAndMobilitySubscriptionData": {
    "gpsis": ["msisdn-0900000000"],
    "nssai": {"defaultSingleNssais": [{"sst": 1, "sd": "010203"}], "singleNssais": [{"sst": 1, "sd": "112233"}]},
    "subscribedUeAmbr": {"downlink": "2 Gbps", "uplink": "1 Gbps"}
  },
  "SessionManagementSubscriptionData": [
    {"singleNssai": {"sst": 1, "sd": "010203"}, "dnnConfigurations": {"internet": {"sscModes": {"defaultSscMode": "SSC_MODE_1", "allowedSscModes": ["SSC_MODE_2", "SSC_MODE_3"]}, "pduSessionTypes": {"defaultSessionType": "IPV4", "allowedSessionTypes": ["IPV4"]}, "sessionAmbr": {"uplink": "200 Mbps", "downlink": "100 Mbps"}, "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8, "preemptCap": "", "preemptVuln": ""}}}}},
    {"singleNssai": {"sst": 1, "sd": "112233"}, "dnnConfigurations": {"internet": {"sscModes": {"defaultSscMode": "SSC_MODE_1", "allowedSscModes": ["SSC_MODE_2", "SSC_MODE_3"]}, "pduSessionTypes": {"defaultSessionType": "IPV4", "allowedSessionTypes": ["IPV4"]}, "sessionAmbr": {"uplink": "200 Mbps", "downlink": "100 Mbps"}, "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8, "preemptCap": "", "preemptVuln": ""}}}}}
  ],
  "SmfSelectionSubscriptionData": {"subscribedSnssaiInfos": {"01010203": {"dnnInfos": [{"dnn": "internet"}]}, "01112233": {"dnnInfos": [{"dnn": "internet"}]}}},
  "AmPolicyData": {"subscCats": ["free5gc"]},
  "SmPolicyData": {"smPolicySnssaiData": {"01010203": {"snssai": {"sst": 1, "sd": "010203"}, "smPolicyDnnData": {"internet": {"dnn": "internet"}}}, "01112233": {"snssai": {"sst": 1, "sd": "112233"}, "smPolicyDnnData": {"internet": {"dnn": "internet"}}}}},
  "FlowRules": []
}
ENDJSON
    )

    if [ "$http_code" = "201" ]; then
        log_info "Subscriber created successfully (HTTP 201)"
    else
        log_warn "Subscriber creation returned HTTP $http_code (may already exist)"
    fi

    # IMPORTANT: Fix SQN for UERANSIM compatibility
    # UERANSIM starts with SQN-MS=0, so the network SQN must be a small positive value
    # The default "16f3b3f70fc2" is too large and causes SQN out-of-range errors
    log_info "Setting subscriber SQN for UERANSIM compatibility..."
    docker exec mongodb mongo --quiet --eval '
        db = db.getSiblingDB("free5gc");
        db.subscriptionData.authenticationData.authenticationSubscription.updateOne(
            {"ueId": "imsi-208930000000001"},
            {$set: {"sequenceNumber": {"sqnScheme": "GENERAL", "sqn": "000000000020"}}}
        );
        print("SQN set to 000000000020");
    '
}

# ============================================================
# Phase 5: Start UERANSIM UE and Test
# ============================================================
start_ue_and_test() {
    log_info "Restarting UERANSIM and starting UE..."

    cd "$INSTALL_DIR"

    # Restart ueransim container to ensure clean state
    docker compose restart ueransim
    sleep 8

    # Verify gNB is connected
    local gnb_ok
    gnb_ok=$(docker logs ueransim 2>&1 | grep -c "NG Setup procedure is successful" || true)
    if [ "$gnb_ok" -ge 1 ]; then
        log_info "gNB connected to AMF successfully"
    else
        log_error "gNB failed to connect to AMF"
        docker logs ueransim 2>&1 | tail -10
        exit 1
    fi

    # Start UE in background
    docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
    log_info "Waiting 15 seconds for UE registration..."
    sleep 15

    # Check UE status
    local ue_status
    ue_status=$(docker exec ueransim ./nr-cli imsi-208930000000001 -e "status" 2>&1)
    echo ""
    echo "=== UE Registration Status ==="
    echo "$ue_status"

    if echo "$ue_status" | grep -q "RM-REGISTERED"; then
        log_info "UE Registration: SUCCESS"
    else
        log_error "UE Registration: FAILED"
        log_warn "Check AMF logs: docker logs amf"
        return 1
    fi

    # Check PDU sessions
    echo ""
    echo "=== PDU Sessions ==="
    docker exec ueransim ./nr-cli imsi-208930000000001 -e "ps-list" 2>&1

    # Ping tests
    echo ""
    echo "=== Connectivity Tests ==="
    log_info "Ping test via PDU Session 1 (uesimtun0)..."
    docker exec ueransim ping -I uesimtun0 -c 3 -W 3 8.8.8.8 2>&1 || log_warn "Ping via uesimtun0 failed"

    echo ""
    log_info "Ping test via PDU Session 2 (uesimtun1)..."
    docker exec ueransim ping -I uesimtun1 -c 3 -W 3 8.8.8.8 2>&1 || log_warn "Ping via uesimtun1 failed"

    echo ""
    log_info "All tests completed!"
}

# ============================================================
# Utility Functions
# ============================================================
stop_services() {
    log_info "Stopping all free5GC services..."
    cd "$INSTALL_DIR"
    docker compose down
    log_info "All services stopped"
}

clean_all() {
    log_info "Stopping services and removing all data..."
    cd "$INSTALL_DIR"
    docker compose down -v
    log_info "All services stopped and volumes removed"
}

show_status() {
    cd "$INSTALL_DIR"
    echo "=== Container Status ==="
    docker compose ps 2>&1
    echo ""
    echo "=== UE Status ==="
    docker exec ueransim ./nr-cli imsi-208930000000001 -e "status" 2>&1 || echo "UE not running"
    echo ""
    echo "=== PDU Sessions ==="
    docker exec ueransim ./nr-cli imsi-208930000000001 -e "ps-list" 2>&1 || echo "No PDU sessions"
}

show_logs() {
    local service="${1:-amf}"
    cd "$INSTALL_DIR"
    docker logs --tail 50 "$service" 2>&1
}

# ============================================================
# Main
# ============================================================
usage() {
    echo "Usage: $0 {install|start|stop|restart|test|status|logs|clean}"
    echo ""
    echo "Commands:"
    echo "  install   - Full installation (Docker, GTP5G, free5GC, subscriber, test)"
    echo "  start     - Start all services and UE"
    echo "  stop      - Stop all services"
    echo "  restart   - Restart all services (preserves data)"
    echo "  test      - Run UE registration and connectivity tests"
    echo "  status    - Show service and UE status"
    echo "  logs [svc]- Show logs for a service (default: amf)"
    echo "  clean     - Stop and remove all data (destructive)"
    echo ""
    echo "Examples:"
    echo "  $0 install          # First-time setup"
    echo "  $0 status           # Check everything"
    echo "  $0 logs smf         # View SMF logs"
    echo "  $0 restart          # Restart after config changes"
}

case "${1:-}" in
    install)
        install_docker
        install_gtp5g
        clone_free5gc
        start_services
        provision_subscriber
        start_ue_and_test
        echo ""
        log_info "============================================"
        log_info "free5GC setup complete!"
        log_info "WebUI: http://$(hostname -I | awk '{print $1}'):5000"
        log_info "  Username: admin"
        log_info "  Password: free5gc"
        log_info "============================================"
        ;;
    start)
        cd "$INSTALL_DIR"
        docker compose up -d
        sleep 20
        start_ue_and_test
        ;;
    stop)
        stop_services
        ;;
    restart)
        cd "$INSTALL_DIR"
        docker compose restart
        sleep 20
        start_ue_and_test
        ;;
    test)
        start_ue_and_test
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs "${2:-amf}"
        ;;
    clean)
        clean_all
        ;;
    *)
        usage
        exit 1
        ;;
esac
