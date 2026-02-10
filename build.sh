#!/bin/bash
# ============================================================
# Portable Build Orchestrator for free5GC + UERANSIM
# ============================================================
# Builds all free5GC NFs + UERANSIM from source inside Docker,
# extracts binaries, and builds runtime images.
#
# Works on Mac, Linux, or any OS with Docker installed.
#
# Usage:
#   ./build.sh           # Full build (source compile + runtime images)
#   ./build.sh --quick   # Skip source build, just rebuild runtime images
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

QUICK_MODE=false
if [ "${1:-}" = "--quick" ]; then
    QUICK_MODE=true
fi

# ── Step 1: Build all from source using Docker ───────────────
if [ "$QUICK_MODE" = false ]; then
    log "Step 1/3: Building all free5GC + UERANSIM from source..."
    log "  This compiles Go + C++ code inside Docker. First run may take 10-20 minutes."

    docker build -f Dockerfile.build-all -t free5gc-builder:v4.2.0 .

    log "Source build complete."

    # ── Step 2: Extract binaries via volume mount ─────────────
    log "Step 2/3: Extracting built binaries to build-output/..."

    # Clean previous output
    rm -rf build-output
    mkdir -p build-output

    docker run --rm -v "$(pwd)/build-output:/export" free5gc-builder:v4.2.0

    # Verify extraction
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
        log "ERROR: build-output/cp/ not found. Run without --quick first."
        exit 1
    fi
fi

# ── Step 3: Build runtime images from local binaries ─────────
log "Step 3/3: Building runtime Docker images..."

# Create log directories
mkdir -p logs/cp logs/upf

docker compose -f docker-compose-portable.yaml build

log ""
log "========================================="
log "  BUILD COMPLETE"
log "========================================="
log ""
log "Runtime images built:"
docker images --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" | grep -E "free5gc-(cp|upf|ueransim)-local" || true
log ""
log "Next steps:"
log "  ./run.sh              # Start all containers + provision subscriber"
log "  ./run.sh --cp-only    # Start without UPF (Mac/no gtp5g kernel module)"
log ""
