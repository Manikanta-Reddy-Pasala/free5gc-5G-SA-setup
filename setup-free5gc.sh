#!/bin/bash
set -euo pipefail

# ============================================================
# free5GC Docker Compose Setup Script with UERANSIM
# Tested on: Ubuntu 22.04 LTS, Kernel 5.15.x / 6.8.x
# free5GC version: v4.2.0
# UERANSIM version: v3.2.7
#
# Install Modes:
#   minimal      - 4 containers: all-in-one CP + UPF + MongoDB + UERANSIM (default)
#   consolidated - 12 containers: individual core NFs + WebUI + UERANSIM
#   full         - 16 containers: everything including N3IWF, TNGF, NEF, CHF
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# SCRIPT_DIR is where this script (and compose files) live
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUBSCRIBER_IMSI="imsi-208930000000001"
SUBSCRIBER_PLMN="20893"
WEBUI_URL="http://localhost:5000"
WEBUI_USER="admin"
WEBUI_PASS="free5gc"

# Default install mode
INSTALL_MODE="${INSTALL_MODE:-}"

# ============================================================
# Compose file and service mapping per mode
# ============================================================

# Services for consolidated mode (individual NFs, no N3IWF/TNGF/CHF/NEF/N3IWUE)
CONSOLIDATED_SERVICES="db free5gc-nrf free5gc-amf free5gc-ausf free5gc-nssf free5gc-pcf free5gc-smf free5gc-udm free5gc-udr free5gc-upf free5gc-webui ueransim"

get_compose_cmd() {
    case "$INSTALL_MODE" in
        minimal)      echo "docker compose -f $SCRIPT_DIR/docker-compose-consolidated.yaml" ;;
        consolidated) echo "docker compose -f $SCRIPT_DIR/docker-compose.yaml" ;;
        full)         echo "docker compose -f $SCRIPT_DIR/docker-compose.yaml" ;;
    esac
}

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

    local KVER
    KVER=$(uname -r)
    local GTP5G_BUILD_DIR="/root/gtp5g-build"
    local GTP5G_KO="$GTP5G_BUILD_DIR/gtp5g.ko"

    mkdir -p "$GTP5G_BUILD_DIR"

    log_info "Building GTP5G kernel module in Docker for kernel $KVER..."

    # Detect which GCC version was used to build the kernel
    local KERNEL_GCC_VER=""
    if [ -f "/lib/modules/$KVER/build/include/generated/compile.h" ]; then
        KERNEL_GCC_VER=$(grep -oP 'gcc-\K[0-9]+' "/lib/modules/$KVER/build/include/generated/compile.h" 2>/dev/null | head -1)
    fi
    if [ -z "$KERNEL_GCC_VER" ] && [ -f "/proc/version" ]; then
        KERNEL_GCC_VER=$(grep -oP 'gcc-\K[0-9]+' /proc/version 2>/dev/null | head -1)
    fi

    local GCC_PKG="gcc"
    if [ -n "$KERNEL_GCC_VER" ]; then
        GCC_PKG="gcc-$KERNEL_GCC_VER"
        log_info "Kernel was built with gcc-$KERNEL_GCC_VER, installing matching compiler"
    fi

    docker build -t gtp5g-builder -f - "$GTP5G_BUILD_DIR" <<DOCKERFILE
FROM ubuntu:$(lsb_release -rs)
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    linux-headers-$KVER build-essential make $GCC_PKG git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/free5gc/gtp5g.git /gtp5g
WORKDIR /gtp5g
RUN LATEST_TAG=\$(git tag --sort=-version:refname | head -1) && \
    if [ -n "\$LATEST_TAG" ]; then \
        echo "Building gtp5g \$LATEST_TAG" && \
        git checkout "\$LATEST_TAG"; \
    fi && \
    make KVER=$KVER && \
    echo "Build successful: \$(ls -la gtp5g.ko)"
DOCKERFILE

    local container_id
    container_id=$(docker create gtp5g-builder)
    docker cp "$container_id:/gtp5g/gtp5g.ko" "$GTP5G_KO"
    docker rm "$container_id" > /dev/null
    docker rmi gtp5g-builder > /dev/null 2>&1 || true

    if [ ! -f "$GTP5G_KO" ]; then
        log_error "Failed to build gtp5g.ko in Docker"
        exit 1
    fi

    log_info "GTP5G module built successfully, installing on host..."

    local ko_dest="/lib/modules/$KVER/kernel/drivers/net"
    mkdir -p "$ko_dest"
    cp "$GTP5G_KO" "$ko_dest/gtp5g.ko"
    depmod -a "$KVER"

    modprobe udp_tunnel 2>/dev/null || true

    if ! modprobe gtp5g 2>/dev/null; then
        log_warn "modprobe failed, trying insmod..."
        insmod "$GTP5G_KO" 2>&1 || true
    fi

    sleep 1

    if lsmod | grep -q gtp5g; then
        log_info "GTP5G kernel module loaded successfully ($(modinfo -F version gtp5g 2>/dev/null || echo 'unknown version'))"
        echo "udp_tunnel" > /etc/modules-load.d/gtp5g.conf
        echo "gtp5g" >> /etc/modules-load.d/gtp5g.conf
    else
        log_error "Failed to load GTP5G kernel module"
        log_error "Kernel: $KVER"
        log_warn "Checking dmesg for module loading errors..."
        dmesg | tail -20 | grep -i -E "gtp5g|module|signature|cert|verify" || true
        echo ""
        if command -v mokutil &>/dev/null; then
            local sb_state
            sb_state=$(mokutil --sb-state 2>/dev/null || echo "unknown")
            if echo "$sb_state" | grep -qi "enabled"; then
                log_error "Secure Boot is ENABLED - unsigned kernel modules cannot be loaded"
                log_warn "Disable Secure Boot in BIOS/UEFI settings"
            fi
        fi
        exit 1
    fi
}

# ============================================================
# Phase 2: Build all-in-one CP image (minimal mode only)
# ============================================================
build_consolidated_cp() {
    if docker image inspect free5gc-cp:v4.2.0 > /dev/null 2>&1; then
        log_info "free5gc-cp:v4.2.0 image already exists"
        return 0
    fi

    log_info "Building consolidated control plane image (8 NFs in 1)..."
    docker build -t free5gc-cp:v4.2.0 \
        -f "$SCRIPT_DIR/consolidated/Dockerfile.consolidated-cp" \
        "$SCRIPT_DIR/consolidated/"
    log_info "free5gc-cp:v4.2.0 built successfully"
}

# ============================================================
# Phase 3: Start Services
# ============================================================
start_services() {
    local compose_cmd
    compose_cmd=$(get_compose_cmd)

    log_info "Starting services (${BOLD}$INSTALL_MODE${NC} mode)..."

    case "$INSTALL_MODE" in
        minimal)
            # Build CP image if needed, then start all 4 services
            build_consolidated_cp
            $compose_cmd pull free5gc-upf ueransim db 2>/dev/null || true
            $compose_cmd up -d
            log_info "Waiting 30 seconds for all-in-one CP to initialize..."
            sleep 30
            ;;
        consolidated)
            $compose_cmd pull $CONSOLIDATED_SERVICES
            $compose_cmd up -d $CONSOLIDATED_SERVICES
            log_info "Waiting 25 seconds for services to initialize..."
            sleep 25
            ;;
        full)
            $compose_cmd pull
            $compose_cmd up -d
            log_info "Waiting 25 seconds for services to initialize..."
            sleep 25
            ;;
    esac

    # Show running containers
    local running
    running=$($compose_cmd ps --format json 2>/dev/null | grep -c '"running"' || $compose_cmd ps 2>/dev/null | grep -c "Up")
    log_info "$running containers running"
    $compose_cmd ps --format "table {{.Name}}\t{{.Status}}"
}

# ============================================================
# Phase 4: Provision Subscriber
# ============================================================
provision_subscriber() {
    log_info "Provisioning test subscriber ($SUBSCRIBER_IMSI)..."

    if [ "$INSTALL_MODE" = "minimal" ] || [ "$INSTALL_MODE" = "consolidated" ]; then
        # For consolidated mode, try WebUI first; for minimal, go straight to MongoDB
        if [ "$INSTALL_MODE" = "consolidated" ]; then
            local token
            token=$(curl -s -X POST "$WEBUI_URL/api/login" \
                -H "Content-Type: application/json" \
                -d "{\"username\":\"$WEBUI_USER\",\"password\":\"$WEBUI_PASS\"}" \
                | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

            if [ -n "$token" ]; then
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
                    log_info "Subscriber created via WebUI (HTTP 201)"
                else
                    log_warn "Subscriber creation returned HTTP $http_code (may already exist)"
                fi
                fix_subscriber_sqn
                return
            fi
            log_warn "WebUI not ready, falling back to MongoDB provisioning..."
        fi

        provision_subscriber_via_mongo
        return
    fi

    # Full mode - try WebUI, fallback to MongoDB
    local token
    token=$(curl -s -X POST "$WEBUI_URL/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$WEBUI_USER\",\"password\":\"$WEBUI_PASS\"}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

    if [ -z "$token" ]; then
        log_warn "WebUI login failed, falling back to MongoDB..."
        provision_subscriber_via_mongo
        return
    fi

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

    fix_subscriber_sqn
}

provision_subscriber_via_mongo() {
    log_info "Provisioning subscriber directly via MongoDB..."

    docker exec mongodb mongo --quiet --eval '
        db = db.getSiblingDB("free5gc");
        db.subscriptionData.authenticationData.authenticationSubscription.updateOne(
            {"ueId": "imsi-208930000000001"},
            {$set: {
                "ueId": "imsi-208930000000001",
                "authenticationMethod": "5G_AKA",
                "encPermanentKey": "8baf473f2f8fd09487cccbd7097c6862",
                "encOpcKey": "8e27b6af0e692e750f32667a3b14605d",
                "authenticationManagementField": "8000",
                "sequenceNumber": {"sqn": "000000000020"}
            }}, {upsert: true}
        );
        db.subscriptionData.provisionedData.amData.updateOne(
            {"ueId": "imsi-208930000000001", "servingPlmnId": "20893"},
            {$set: {
                "ueId": "imsi-208930000000001", "servingPlmnId": "20893",
                "gpsis": ["msisdn-0900000000"],
                "nssai": {"defaultSingleNssais": [{"sst": 1, "sd": "010203"}], "singleNssais": [{"sst": 1, "sd": "112233"}]},
                "subscribedUeAmbr": {"downlink": "2 Gbps", "uplink": "1 Gbps"}
            }}, {upsert: true}
        );
        db.subscriptionData.provisionedData.smData.updateOne(
            {"ueId": "imsi-208930000000001", "servingPlmnId": "20893", "singleNssai.sst": 1, "singleNssai.sd": "010203"},
            {$set: {
                "ueId": "imsi-208930000000001", "servingPlmnId": "20893",
                "singleNssai": {"sst": 1, "sd": "010203"},
                "dnnConfigurations": {"internet": {"sscModes": {"defaultSscMode": "SSC_MODE_1", "allowedSscModes": ["SSC_MODE_2","SSC_MODE_3"]}, "pduSessionTypes": {"defaultSessionType": "IPV4", "allowedSessionTypes": ["IPV4"]}, "sessionAmbr": {"uplink": "200 Mbps", "downlink": "100 Mbps"}, "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8, "preemptCap": "", "preemptVuln": ""}}}}
            }}, {upsert: true}
        );
        db.subscriptionData.provisionedData.smData.updateOne(
            {"ueId": "imsi-208930000000001", "servingPlmnId": "20893", "singleNssai.sst": 1, "singleNssai.sd": "112233"},
            {$set: {
                "ueId": "imsi-208930000000001", "servingPlmnId": "20893",
                "singleNssai": {"sst": 1, "sd": "112233"},
                "dnnConfigurations": {"internet": {"sscModes": {"defaultSscMode": "SSC_MODE_1", "allowedSscModes": ["SSC_MODE_2","SSC_MODE_3"]}, "pduSessionTypes": {"defaultSessionType": "IPV4", "allowedSessionTypes": ["IPV4"]}, "sessionAmbr": {"uplink": "200 Mbps", "downlink": "100 Mbps"}, "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8, "preemptCap": "", "preemptVuln": ""}}}}
            }}, {upsert: true}
        );
        db.subscriptionData.provisionedData.smfSelectionSubscriptionData.updateOne(
            {"ueId": "imsi-208930000000001", "servingPlmnId": "20893"},
            {$set: {"ueId": "imsi-208930000000001", "servingPlmnId": "20893",
                "subscribedSnssaiInfos": {"01010203": {"dnnInfos": [{"dnn": "internet"}]}, "01112233": {"dnnInfos": [{"dnn": "internet"}]}}}},
            {upsert: true}
        );
        db.policyData.ues.amData.updateOne(
            {"ueId": "imsi-208930000000001"},
            {$set: {"ueId": "imsi-208930000000001", "subscCats": ["free5gc"]}}, {upsert: true}
        );
        db.policyData.ues.smData.updateOne(
            {"ueId": "imsi-208930000000001"},
            {$set: {"ueId": "imsi-208930000000001", "smPolicySnssaiData": {
                "01010203": {"snssai": {"sst": 1, "sd": "010203"}, "smPolicyDnnData": {"internet": {"dnn": "internet"}}},
                "01112233": {"snssai": {"sst": 1, "sd": "112233"}, "smPolicyDnnData": {"internet": {"dnn": "internet"}}}
            }}}, {upsert: true}
        );
        print("Subscriber provisioned via MongoDB");
    '
    log_info "Subscriber provisioned directly via MongoDB"
}

fix_subscriber_sqn() {
    log_info "Setting subscriber SQN for UERANSIM compatibility..."
    docker exec mongodb mongo --quiet --eval '
        db = db.getSiblingDB("free5gc");
        db.subscriptionData.authenticationData.authenticationSubscription.updateOne(
            {"ueId": "imsi-208930000000001"},
            {$set: {"sequenceNumber": {"sqn": "000000000020"}}}
        );
        print("SQN set to 000000000020");
    '
}

# ============================================================
# Phase 5: Start UERANSIM UE and Test
# ============================================================
start_ue_and_test() {
    log_info "Restarting UERANSIM and starting UE..."

    local compose_cmd
    compose_cmd=$(get_compose_cmd)

    $compose_cmd restart ueransim
    sleep 8

    local gnb_ok
    gnb_ok=$(docker logs ueransim 2>&1 | grep -c "NG Setup procedure is successful" || true)
    if [ "$gnb_ok" -ge 1 ]; then
        log_info "gNB connected to AMF successfully"
    else
        log_error "gNB failed to connect to AMF"
        docker logs ueransim 2>&1 | tail -10
        exit 1
    fi

    docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
    log_info "Waiting 15 seconds for UE registration..."
    sleep 15

    local ue_status
    ue_status=$(docker exec ueransim ./nr-cli imsi-208930000000001 -e "status" 2>&1)
    echo ""
    echo "=== UE Registration Status ==="
    echo "$ue_status"

    if echo "$ue_status" | grep -q "RM-REGISTERED"; then
        log_info "UE Registration: SUCCESS"
    else
        log_error "UE Registration: FAILED"
        log_warn "Check AMF logs: docker logs amf (or docker logs free5gc-cp)"
        return 1
    fi

    echo ""
    echo "=== PDU Sessions ==="
    docker exec ueransim ./nr-cli imsi-208930000000001 -e "ps-list" 2>&1

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
    # Try both compose files to ensure everything is stopped
    docker compose -f "$SCRIPT_DIR/docker-compose-consolidated.yaml" down 2>/dev/null || true
    docker compose -f "$SCRIPT_DIR/docker-compose.yaml" down 2>/dev/null || true
    log_info "All services stopped"
}

clean_all() {
    log_info "Stopping services and removing all data..."
    docker compose -f "$SCRIPT_DIR/docker-compose-consolidated.yaml" down -v 2>/dev/null || true
    docker compose -f "$SCRIPT_DIR/docker-compose.yaml" down -v 2>/dev/null || true
    log_info "All services stopped and volumes removed"
}

show_status() {
    echo "=== Container Status ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" --filter "name=mongodb" --filter "name=free5gc" --filter "name=upf" --filter "name=ueransim" --filter "name=amf" --filter "name=smf" --filter "name=nrf" --filter "name=ausf" --filter "name=udm" --filter "name=udr" --filter "name=nssf" --filter "name=pcf" --filter "name=webui" --filter "name=chf" --filter "name=nef" --filter "name=n3iwf" --filter "name=tngf" --filter "name=n3iwue" 2>&1
    echo ""
    echo "=== UE Status ==="
    docker exec ueransim ./nr-cli imsi-208930000000001 -e "status" 2>&1 || echo "UE not running"
    echo ""
    echo "=== PDU Sessions ==="
    docker exec ueransim ./nr-cli imsi-208930000000001 -e "ps-list" 2>&1 || echo "No PDU sessions"
}

show_logs() {
    local service="${1:-amf}"
    docker logs --tail 50 "$service" 2>&1
}

print_mode_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}============================================${NC}"
    echo -e "${CYAN}${BOLD} Install Mode: ${YELLOW}$INSTALL_MODE${NC}"
    echo -e "${CYAN}${BOLD}============================================${NC}"
    case "$INSTALL_MODE" in
        minimal)
            echo -e " ${GREEN}All-in-one CP + UPF + MongoDB + UERANSIM (4 containers)${NC}"
            echo -e " 8 NFs merged into 1 container (free5gc-cp)"
            echo -e " ${YELLOW}Fastest startup, lowest resource usage${NC}"
            ;;
        consolidated)
            echo -e " ${GREEN}Individual core NFs + WebUI + UERANSIM (12 containers)${NC}"
            echo -e " MongoDB, NRF, AMF, AUSF, NSSF, PCF,"
            echo -e " SMF, UDM, UDR, UPF, UERANSIM, WebUI"
            echo -e " ${YELLOW}Skips: N3IWF, TNGF, N3IWUE, NEF, CHF${NC}"
            ;;
        full)
            echo -e " ${GREEN}All NFs + UERANSIM + WebUI (16 containers)${NC}"
            echo -e " Everything including N3IWF, TNGF, N3IWUE, NEF, CHF"
            ;;
    esac
    echo -e "${CYAN}${BOLD}============================================${NC}"
    echo ""
}

select_mode() {
    if [ -n "$INSTALL_MODE" ]; then
        case "$INSTALL_MODE" in
            full|minimal|consolidated) return 0 ;;
            *) log_error "Invalid mode: $INSTALL_MODE"; exit 1 ;;
        esac
    fi

    echo ""
    echo -e "${BOLD}Select installation mode:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} ${BOLD}minimal${NC}       - 4 containers: all-in-one CP + UPF + DB + UERANSIM (default)"
    echo -e "  ${GREEN}2)${NC} ${BOLD}consolidated${NC}  - 12 containers: individual NFs + WebUI + UERANSIM"
    echo -e "  ${GREEN}3)${NC} ${BOLD}full${NC}          - 16 containers: everything including N3IWF, TNGF, NEF, CHF"
    echo ""
    read -r -p "Enter choice [1/2/3] (default: 1): " choice

    case "${choice:-1}" in
        1|minimal)       INSTALL_MODE="minimal" ;;
        2|consolidated)  INSTALL_MODE="consolidated" ;;
        3|full)          INSTALL_MODE="full" ;;
        *)               log_error "Invalid choice: $choice"; exit 1 ;;
    esac
}

# ============================================================
# Main
# ============================================================
usage() {
    echo "Usage: $0 {install|start|stop|restart|test|status|logs|clean} [mode]"
    echo ""
    echo "Commands:"
    echo "  install [mode] - Full installation (Docker, GTP5G, free5GC, subscriber, test)"
    echo "  start [mode]   - Start services and UE"
    echo "  stop           - Stop all services"
    echo "  restart [mode] - Restart services"
    echo "  test           - Run UE registration and connectivity tests"
    echo "  status         - Show service and UE status"
    echo "  logs [svc]     - Show logs for a service (default: amf)"
    echo "  clean          - Stop and remove all data (destructive)"
    echo ""
    echo "Install Modes:"
    echo "  minimal        - 4 containers: all-in-one CP + UPF + DB + UERANSIM (default)"
    echo "  consolidated   - 12 containers: individual core NFs + WebUI + UERANSIM"
    echo "  full           - 16 containers: everything"
    echo ""
    echo "Examples:"
    echo "  $0 install                    # Default: minimal (4 containers)"
    echo "  $0 install minimal            # All-in-one CP (fastest)"
    echo "  $0 install consolidated       # Individual NFs + WebUI"
    echo "  $0 install full               # Everything"
    echo "  $0 status                     # Check everything"
    echo "  $0 logs free5gc-cp            # View all-in-one CP logs"
}

# Parse mode from second argument if provided
if [ -n "${2:-}" ]; then
    case "${2:-}" in
        full|minimal|consolidated) INSTALL_MODE="$2" ;;
    esac
fi

case "${1:-}" in
    install)
        select_mode
        print_mode_banner
        install_docker
        install_gtp5g
        start_services
        provision_subscriber
        start_ue_and_test
        echo ""
        log_info "============================================"
        log_info "free5GC setup complete! (mode: $INSTALL_MODE)"
        if [ "$INSTALL_MODE" != "minimal" ]; then
            log_info "WebUI: http://$(hostname -I | awk '{print $1}'):5000"
            log_info "  Username: admin"
            log_info "  Password: free5gc"
        fi
        log_info "============================================"
        ;;
    start)
        select_mode
        print_mode_banner
        start_services
        start_ue_and_test
        ;;
    stop)
        stop_services
        ;;
    restart)
        if [ -n "${2:-}" ]; then
            case "${2:-}" in
                full|minimal|consolidated) INSTALL_MODE="$2" ;;
            esac
        fi
        if [ -z "$INSTALL_MODE" ]; then
            select_mode
        fi
        local_compose=$(get_compose_cmd)
        $local_compose restart
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
