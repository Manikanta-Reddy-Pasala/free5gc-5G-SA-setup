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
log "Step 3/4: Provisioning subscriber via WebUI API..."

# Use the existing provision script which handles the correct data format
DOCKER_NETWORK="free5gc-test_privnet"
if ! docker network ls --format '{{.Name}}' | grep -q "$DOCKER_NETWORK"; then
    # Try to detect the actual network name
    DOCKER_NETWORK=$(docker network ls --format '{{.Name}}' | grep privnet | head -1)
fi

if [ -f "./scripts/provision-subscriber.sh" ]; then
    ./scripts/provision-subscriber.sh "$IMSI" "$PLMN" "$DOCKER_NETWORK" || {
        log "WARNING: WebUI provisioning failed. Subscriber may need manual setup."
    }
else
    log "WARNING: provision-subscriber.sh not found. Skipping subscriber provisioning."
fi

log "Subscriber provisioning complete."

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
