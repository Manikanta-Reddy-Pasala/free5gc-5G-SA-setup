#!/bin/bash
# ============================================================
# Run & Provision for free5GC Portable Deployment
# ============================================================
# Starts all 4 containers, waits for health, provisions a
# default subscriber, and shows status.
#
# Usage:
#   ./run.sh              # Full mode (all 4 containers, needs gtp5g)
#   ./run.sh --cp-only    # CP + DB + UERANSIM only (Mac/no gtp5g)
#   ./run.sh --down       # Stop and remove all containers
#   ./run.sh --status     # Show container status
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose-portable.yaml"
IMSI="imsi-208930000000001"
PLMN="20893"
K="8baf473f2f8fd09487cccbd7097c6862"
OPC="8e27b6af0e692e750f32667a3b14605d"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# ── Handle commands ───────────────────────────────────────────
case "${1:-}" in
    --down)
        log "Stopping all containers..."
        docker compose -f "$COMPOSE_FILE" down -v
        log "All containers stopped and volumes removed."
        exit 0
        ;;
    --status)
        docker compose -f "$COMPOSE_FILE" ps
        exit 0
        ;;
esac

CP_ONLY=false
if [ "${1:-}" = "--cp-only" ]; then
    CP_ONLY=true
    log "CP-only mode: skipping UPF (no gtp5g kernel module required)"
fi

# Ensure log directories exist
mkdir -p logs/cp logs/upf

# ── Step 1: Start containers ─────────────────────────────────
log "Step 1/4: Starting containers..."

if [ "$CP_ONLY" = true ]; then
    # Start without UPF profile
    docker compose -f "$COMPOSE_FILE" up -d db free5gc-cp ueransim
else
    docker compose -f "$COMPOSE_FILE" up -d
fi

# ── Step 2: Wait for CP health ───────────────────────────────
log "Step 2/4: Waiting for Control Plane to be healthy..."

MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' free5gc-cp 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "healthy" ]; then
        log "Control Plane is healthy (took ${WAITED}s)"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    if [ $((WAITED % 10)) -eq 0 ]; then
        log "  Still waiting... (${WAITED}s, status: $STATUS)"
    fi
done

if [ $WAITED -ge $MAX_WAIT ]; then
    log "WARNING: CP health check timed out after ${MAX_WAIT}s"
    log "Container logs:"
    docker logs free5gc-cp --tail 20 2>&1 | head -20
fi

# ── Step 3: Provision default subscriber ──────────────────────
log "Step 3/4: Provisioning subscriber $IMSI via direct MongoDB insert..."

# Wait for MongoDB to be ready
for attempt in $(seq 1 15); do
    if docker exec mongodb mongo --quiet --eval "db.runCommand({ping: 1})" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Insert subscriber data directly into MongoDB (no WebUI needed)
docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval '
// Clean existing subscriber data
var imsi = "'"$IMSI"'";
db["subscriptionData.authenticationData.authenticationSubscription"].deleteMany({ueId: imsi});
db["subscriptionData.provisionedData.amData"].deleteMany({ueId: imsi});
db["subscriptionData.provisionedData.smData"].deleteMany({ueId: imsi});
db["subscriptionData.provisionedData.smfSelectionSubscriptionData"].deleteMany({ueId: imsi});
db["policyData.ues.amData"].deleteMany({ueId: imsi});
db["policyData.ues.smData"].deleteMany({ueId: imsi});

// 1. Authentication Subscription
db["subscriptionData.authenticationData.authenticationSubscription"].insertOne({
    ueId: imsi,
    authenticationMethod: "5G_AKA",
    permanentKey: {permanentKeyValue: "'"$K"'", encryptionKey: 0, encryptionAlgorithm: 0},
    sequenceNumber: "000000000020",
    authenticationManagementField: "8000",
    milenage: {op: {opValue: "", encryptionKey: 0, encryptionAlgorithm: 0}},
    opc: {opcValue: "'"$OPC"'", encryptionKey: 0, encryptionAlgorithm: 0}
});

// 2. Access and Mobility Subscription Data
db["subscriptionData.provisionedData.amData"].insertOne({
    ueId: imsi,
    servingPlmnId: "'"$PLMN"'",
    gpsis: ["msisdn-0900000000"],
    subscribedUeAmbr: {downlink: "2 Gbps", uplink: "1 Gbps"},
    nssai: {
        defaultSingleNssais: [
            {sst: 1, sd: "010203"},
            {sst: 1, sd: "112233"}
        ]
    }
});

// 3. Session Management Subscription Data (slice 1)
db["subscriptionData.provisionedData.smData"].insertOne({
    ueId: imsi,
    servingPlmnId: "'"$PLMN"'",
    singleNssai: {sst: 1, sd: "010203"},
    dnnConfigurations: {
        internet: {
            pduSessionTypes: {defaultSessionType: "IPV4", allowedSessionTypes: ["IPV4"]},
            sscModes: {defaultSscMode: "SSC_MODE_1"},
            "5gQosProfile": {"5qi": 9, arp: {priorityLevel: 8, preemptCap: "", preemptVuln: ""}},
            sessionAmbr: {downlink: "200 Mbps", uplink: "100 Mbps"}
        }
    }
});

// 4. Session Management Subscription Data (slice 2)
db["subscriptionData.provisionedData.smData"].insertOne({
    ueId: imsi,
    servingPlmnId: "'"$PLMN"'",
    singleNssai: {sst: 1, sd: "112233"},
    dnnConfigurations: {
        internet: {
            pduSessionTypes: {defaultSessionType: "IPV4", allowedSessionTypes: ["IPV4"]},
            sscModes: {defaultSscMode: "SSC_MODE_1"},
            "5gQosProfile": {"5qi": 9, arp: {priorityLevel: 8, preemptCap: "", preemptVuln: ""}},
            sessionAmbr: {downlink: "200 Mbps", uplink: "100 Mbps"}
        }
    }
});

// 5. SMF Selection Subscription Data
db["subscriptionData.provisionedData.smfSelectionSubscriptionData"].insertOne({
    ueId: imsi,
    servingPlmnId: "'"$PLMN"'",
    subscribedSnssaiInfos: {
        "01010203": {dnnInfos: [{dnn: "internet"}]},
        "01112233": {dnnInfos: [{dnn: "internet"}]}
    }
});

// 6. AM Policy Data
db["policyData.ues.amData"].insertOne({
    ueId: imsi,
    subscCats: ["free5gc"]
});

// 7. SM Policy Data (with smPolicySnssaiData to prevent PCF nil panic)
db["policyData.ues.smData"].insertOne({
    ueId: imsi,
    smPolicySnssaiData: {
        "01010203": {
            snssai: {sst: 1, sd: "010203"},
            smPolicyDnnData: {
                internet: {dnn: "internet"}
            }
        },
        "01112233": {
            snssai: {sst: 1, sd: "112233"},
            smPolicyDnnData: {
                internet: {dnn: "internet"}
            }
        }
    }
});

print("SUCCESS: Subscriber " + imsi + " provisioned with all required collections");
' 2>&1

log "Subscriber provisioned."

# ── Step 4: Show status ──────────────────────────────────────
log "Step 4/4: Deployment status"
echo ""
docker compose -f "$COMPOSE_FILE" ps
echo ""
log "========================================="
log "  free5GC PORTABLE IS RUNNING"
log "========================================="
echo ""
log "Container logs:     docker compose -f $COMPOSE_FILE logs -f"
log "NF logs:            ls -la logs/cp/"
log "Stop:               ./run.sh --down"
log "Status:             ./run.sh --status"
echo ""
log "Test registration:"
log "  docker exec ueransim ./nr-ue -c ./config/uecfg.yaml"
echo ""
log "Trace registration flow:"
log "  ./scripts/trace-registration-flow.sh"
echo ""
