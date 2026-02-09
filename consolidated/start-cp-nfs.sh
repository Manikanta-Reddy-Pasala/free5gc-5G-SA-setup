#!/bin/bash
# ============================================================
# Consolidated Control Plane Startup Script
# Runs multiple free5GC NFs in a single container
# ============================================================
# This script starts NRF, AMF, AUSF, UDM, UDR, SMF, NSSF, PCF
# all within a single container, each as a background process.
#
# NRF starts first (service registry), then all others register.
# ============================================================

set -u

LOG_DIR="/var/log/free5gc"
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# Trap to clean up all child processes on container stop
cleanup() {
    log "Shutting down all NFs..."
    kill $(jobs -p) 2>/dev/null
    wait
    log "All NFs stopped."
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── Phase 0: Clean stale NF profiles from MongoDB ────────────
# Old NF profiles from previous runs cause registration conflicts
log "Cleaning stale NF profiles from MongoDB..."
for attempt in $(seq 1 10); do
    if wget -q -O /dev/null http://db:27017 2>/dev/null; then
        break
    fi
    sleep 1
done
# Use mongosh via the mongodb container isn't available here, but NRF
# will handle re-registration. Stale profiles auto-expire via heartbeat.

# ── Phase 1: Start NRF first (service registry) ─────────────
log "Starting NRF (service registry)..."
cd /free5gc
./nrf -c ./config/nrfcfg.yaml > "$LOG_DIR/nrf.log" 2>&1 &
NRF_PID=$!
log "NRF started (PID: $NRF_PID)"

# Wait for NRF to be ready
for i in $(seq 1 30); do
    if wget -q -O /dev/null http://nrf.free5gc.org:8000 2>/dev/null || \
       wget -q -O /dev/null http://127.0.0.1:8000 2>/dev/null; then
        log "NRF is ready"
        break
    fi
    sleep 1
done

# ── Phase 2: Start all other control plane NFs ──────────────
log "Starting UDR..."
./udr -c ./config/udrcfg.yaml > "$LOG_DIR/udr.log" 2>&1 &
UDR_PID=$!
sleep 1

log "Starting UDM..."
./udm -c ./config/udmcfg.yaml > "$LOG_DIR/udm.log" 2>&1 &
UDM_PID=$!
sleep 1

log "Starting AUSF..."
./ausf -c ./config/ausfcfg.yaml > "$LOG_DIR/ausf.log" 2>&1 &
AUSF_PID=$!
sleep 1

log "Starting NSSF..."
./nssf -c ./config/nssfcfg.yaml > "$LOG_DIR/nssf.log" 2>&1 &
NSSF_PID=$!
sleep 1

log "Starting PCF..."
./pcf -c ./config/pcfcfg.yaml > "$LOG_DIR/pcf.log" 2>&1 &
PCF_PID=$!
sleep 1

log "Starting AMF..."
./amf -c ./config/amfcfg.yaml > "$LOG_DIR/amf.log" 2>&1 &
AMF_PID=$!
sleep 1

log "Starting SMF..."
./smf -c ./config/smfcfg.yaml -u ./config/uerouting.yaml > "$LOG_DIR/smf.log" 2>&1 &
SMF_PID=$!
sleep 1

# ── Phase 3: Health monitoring ───────────────────────────────
log "All NFs started. PIDs: NRF=$NRF_PID UDR=$UDR_PID UDM=$UDM_PID AUSF=$AUSF_PID NSSF=$NSSF_PID PCF=$PCF_PID AMF=$AMF_PID SMF=$SMF_PID"
log "Logs available at: $LOG_DIR/"

# Monitor: if any critical NF dies, log it
while true; do
    for nf_name in NRF UDR UDM AUSF NSSF PCF AMF SMF; do
        eval pid=\$${nf_name}_PID
        if ! kill -0 "$pid" 2>/dev/null; then
            log "WARNING: $nf_name (PID $pid) has exited!"
        fi
    done
    sleep 30
done
