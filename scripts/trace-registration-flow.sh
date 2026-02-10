#!/bin/bash
# ============================================================
# UE Registration Data Flow Tracer
# ============================================================
# Captures the complete 5G UE registration flow across all
# Network Functions, producing a formatted data flow report.
#
# What it does:
#   1. Snapshots all NF log positions (start markers)
#   2. Ensures subscriber is provisioned
#   3. Starts UE registration via UERANSIM
#   4. Waits for registration to complete
#   5. Collects and merges logs chronologically
#   6. Produces formatted data flow report
#
# Usage:
#   ./scripts/trace-registration-flow.sh
#   ./scripts/trace-registration-flow.sh --no-ue   # Just collect existing logs
#
# Output:
#   ./logs/registration-flow-{timestamp}.log
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
OUTPUT_DIR="logs"
REPORT_FILE="$OUTPUT_DIR/registration-flow-${TIMESTAMP}.log"
RAW_DIR="$OUTPUT_DIR/raw-${TIMESTAMP}"
SKIP_UE=false

if [ "${1:-}" = "--no-ue" ]; then
    SKIP_UE=true
fi

mkdir -p "$OUTPUT_DIR" "$RAW_DIR"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

NFS=(nrf udr udm ausf nssf pcf amf smf)

# ── Step 1: Verify containers are running ─────────────────────
log "Step 1/7: Verifying containers..."

for container in free5gc-cp ueransim mongodb; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log "ERROR: Container '$container' is not running."
        log "Run ./run.sh first."
        exit 1
    fi
done

UPF_RUNNING=false
if docker ps --format '{{.Names}}' | grep -q "^upf$"; then
    UPF_RUNNING=true
fi

log "  CP: running | UERANSIM: running | UPF: $UPF_RUNNING | MongoDB: running"

# ── Step 2: Record log positions (before registration) ────────
log "Step 2/7: Recording log positions..."

declare -A LOG_LINES_BEFORE
for nf in "${NFS[@]}"; do
    LOG_FILE="/var/log/free5gc/${nf}.log"
    LINES=$(docker exec free5gc-cp wc -l "$LOG_FILE" 2>/dev/null | awk '{print $1}' || echo "0")
    LOG_LINES_BEFORE[$nf]=$LINES
done

if [ "$UPF_RUNNING" = true ]; then
    UPF_LOG_LINES=$(docker logs upf 2>&1 | wc -l || echo "0")
else
    UPF_LOG_LINES=0
fi

UERANSIM_LOG_LINES=$(docker logs ueransim 2>&1 | wc -l || echo "0")

log "  Log positions recorded for ${#NFS[@]} NFs + UPF + UERANSIM"

# ── Step 3: Trigger UE registration ──────────────────────────
if [ "$SKIP_UE" = false ]; then
    log "Step 3/7: Starting UE registration..."

    # Kill any existing nr-ue process
    docker exec ueransim pkill -f nr-ue 2>/dev/null || true
    sleep 1

    # Start UE registration in background
    docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
    log "  UE registration triggered (nr-ue started)"

    # ── Step 4: Wait for registration to complete ──────────────
    log "Step 4/7: Waiting for registration to complete..."

    MAX_WAIT=30
    WAITED=0
    REGISTERED=false

    while [ $WAITED -lt $MAX_WAIT ]; do
        # Check UERANSIM logs for registration success
        if docker logs ueransim 2>&1 | tail -20 | grep -q "Registration complete\|PDU Session establishment is successful\|RM-REGISTERED"; then
            REGISTERED=true
            log "  UE registration completed (took ${WAITED}s)"
            break
        fi
        sleep 1
        WAITED=$((WAITED + 1))
    done

    if [ "$REGISTERED" = false ]; then
        log "  WARNING: Registration not confirmed after ${MAX_WAIT}s (collecting logs anyway)"
    fi

    # Give extra time for all log writes to flush
    sleep 2
else
    log "Step 3/7: Skipping UE registration (--no-ue mode)"
    log "Step 4/7: Skipping wait"
fi

# ── Step 5: Collect logs from all NFs ─────────────────────────
log "Step 5/7: Collecting logs from all NFs..."

# Collect CP NF logs (only new lines since step 2)
for nf in "${NFS[@]}"; do
    LOG_FILE="/var/log/free5gc/${nf}.log"
    START_LINE=$((${LOG_LINES_BEFORE[$nf]} + 1))
    docker exec free5gc-cp tail -n "+${START_LINE}" "$LOG_FILE" 2>/dev/null > "$RAW_DIR/${nf}.log" || true
    LINE_COUNT=$(wc -l < "$RAW_DIR/${nf}.log" | tr -d ' ')
    log "  $nf: $LINE_COUNT new log lines"
done

# Collect UPF logs
if [ "$UPF_RUNNING" = true ]; then
    docker logs upf 2>&1 | tail -n "+$((UPF_LOG_LINES + 1))" > "$RAW_DIR/upf.log" || true
    LINE_COUNT=$(wc -l < "$RAW_DIR/upf.log" | tr -d ' ')
    log "  upf: $LINE_COUNT new log lines"
fi

# Collect UERANSIM logs
docker logs ueransim 2>&1 | tail -n "+$((UERANSIM_LOG_LINES + 1))" > "$RAW_DIR/ueransim.log" || true
LINE_COUNT=$(wc -l < "$RAW_DIR/ueransim.log" | tr -d ' ')
log "  ueransim: $LINE_COUNT new log lines"

# Also collect full container logs for reference
docker logs free5gc-cp > "$RAW_DIR/container-cp-full.log" 2>&1 || true

# ── Step 6: Parse and merge logs ──────────────────────────────
log "Step 6/7: Parsing and generating data flow report..."

# Generate the formatted report
cat > "$REPORT_FILE" << 'HEADER'
# ============================================================
# 5G UE Registration Data Flow Report
# ============================================================
# This report shows the complete message flow during UE
# registration across all 5G Core Network Functions.
#
# Legend:
#   -->  Request (outbound)
#   <--  Response (inbound)
#   [NF] Source network function
#   SBI  Service-Based Interface (HTTP/2)
#   NGAP N2 interface (gNB <-> AMF)
#   PFCP N4 interface (SMF <-> UPF)
#   NAS  Non-Access Stratum (UE <-> AMF)
# ============================================================

HEADER

echo "Report generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$REPORT_FILE"
echo "Timestamp: $TIMESTAMP" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# ── Section 1: UERANSIM Flow ─────────────────────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 1. UERANSIM (gNB + UE)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/ueransim.log" ]; then
    # Extract key UERANSIM events
    grep -E "initial-registration|Registration|PDU Session|NGAP|RRC|NAS|Authentication|Security Mode|Connected|Deregistration|RM-|CM-" \
        "$RAW_DIR/ueransim.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no UERANSIM logs captured)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 2: AMF Flow (Core Entry Point) ───────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 2. AMF (Access & Mobility Management)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "# AMF handles: NGAP from gNB, NAS from UE," >> "$REPORT_FILE"
echo "# calls AUSF/UDM/PCF/SMF/NSSF via SBI" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/amf.log" ]; then
    grep -E "NGAP|NAS|Registration|Authentication|Security|PDUSession|Nausf|Nudm|Nsmf|Npcf|Nnssf|InitialUEMessage|UEContextRelease|HandoverR|ServiceRequest|Deregistration|context|SUPI|SUCI|5GMM" \
        "$RAW_DIR/amf.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no AMF logs captured)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 3: AUSF Flow (Authentication) ────────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 3. AUSF (Authentication Server)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "# AUSF handles: Nausf_UEAuthentication" >> "$REPORT_FILE"
echo "# calls UDM for auth vectors" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/ausf.log" ]; then
    grep -E "UEAuthentication|AuthenticateRequest|5gAkaConfirmation|Nudm|EAP|SUPI|SUCI|auth|GenerateAuthData|ConfirmAuth" \
        "$RAW_DIR/ausf.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no AUSF logs captured)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 4: UDM Flow (Data Management) ────────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 4. UDM (Unified Data Management)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "# UDM handles: Nudm_UEAuthentication," >> "$REPORT_FILE"
echo "# Nudm_SubscriberDataManagement" >> "$REPORT_FILE"
echo "# calls UDR for data repository access" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/udm.log" ]; then
    grep -E "GenerateAuthData|GetAuthSubsData|ConfirmAuth|SDM|UECM|Registration|Subscribe|Nudr|SUPI|SUCI|auth|context|AMData|SMData|SmfSelection" \
        "$RAW_DIR/udm.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no UDM logs captured)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 5: UDR Flow (Data Repository) ────────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 5. UDR (Unified Data Repository)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "# UDR handles: Nudr_DataRepository" >> "$REPORT_FILE"
echo "# reads/writes MongoDB for subscriber data" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/udr.log" ]; then
    grep -E "AuthenticationSubscription|ProvisionedData|AmData|SmData|SmfSelection|PolicyData|CreateAuthenticationStatus|Query|context|GET|PUT|PATCH|POST|DELETE" \
        "$RAW_DIR/udr.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no UDR logs captured)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 6: NRF Flow (Service Registry) ───────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 6. NRF (NF Repository Function)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "# NRF handles: NF registration/discovery" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/nrf.log" ]; then
    grep -E "NFDiscover|NFRegister|NFProfile|Token|AccessToken|search|nfType|nfStatus" \
        "$RAW_DIR/nrf.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no NRF logs captured)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 7: NSSF Flow (Slice Selection) ───────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 7. NSSF (Network Slice Selection)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/nssf.log" ]; then
    grep -E "NSSelection|Nssai|Slice|NSSAI|SNSSAI|select" \
        "$RAW_DIR/nssf.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no NSSF logs captured)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 8: PCF Flow (Policy Control) ─────────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 8. PCF (Policy Control Function)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "# PCF handles: AM Policy, SM Policy" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/pcf.log" ]; then
    grep -E "AmPolicy|SmPolicy|PolicyAssociation|PolicyControl|Npcf|context|Create|Delete|Update" \
        "$RAW_DIR/pcf.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no PCF logs captured)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 9: SMF Flow (Session Management) ─────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 9. SMF (Session Management Function)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "# SMF handles: PDU Session management," >> "$REPORT_FILE"
echo "# PFCP sessions with UPF" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/smf.log" ]; then
    grep -E "PDUSession|CreateSMContext|PFCP|Session|Establishment|Modification|UPF|context|QoS|PduSessionType|Nsmf|N4" \
        "$RAW_DIR/smf.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no SMF logs captured)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 10: UPF Flow (User Plane) ────────────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 10. UPF (User Plane Function)" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "# UPF handles: PFCP sessions from SMF," >> "$REPORT_FILE"
echo "# GTP-U tunnels for user data" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

if [ -s "$RAW_DIR/upf.log" ]; then
    grep -E "PFCP|Session|Establishment|Modification|Association|FAR|PDR|QER|GTP|tunnel" \
        "$RAW_DIR/upf.log" >> "$REPORT_FILE" 2>/dev/null || echo "  (no matching events)" >> "$REPORT_FILE"
else
    echo "  (no UPF logs captured - UPF may not be running)" >> "$REPORT_FILE"
fi
echo "" >> "$REPORT_FILE"

# ── Section 11: Sequence Diagram ──────────────────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 11. Expected Registration Sequence" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
cat >> "$REPORT_FILE" << 'SEQUENCE'
#
# UE        gNB        AMF       AUSF       UDM        UDR       MongoDB    NSSF     PCF        SMF        UPF
# |          |          |          |          |          |          |          |          |          |          |
# |--RRC---->|          |          |          |          |          |          |          |          |          |
# |          |--NGAP--->|          |          |          |          |          |          |          |          |
# |          |  InitialUEMessage   |          |          |          |          |          |          |          |
# |          |  (Registration Req) |          |          |          |          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |          |          |---SBI--->|          |          |          |          |          |          |          |
# |          |          | Nausf_UEAuthentication         |          |          |          |          |          |
# |          |          |          |---SBI--->|          |          |          |          |          |          |
# |          |          |          | Nudm_UEAuthentication          |          |          |          |          |
# |          |          |          |          |---SBI--->|          |          |          |          |          |
# |          |          |          |          | Nudr_DataRepository  |          |          |          |          |
# |          |          |          |          |          |--query-->|          |          |          |          |
# |          |          |          |          |          |<-result--|          |          |          |          |
# |          |          |          |          |<--SBI----|          |          |          |          |          |
# |          |          |          |<--SBI----|          |          |          |          |          |          |
# |          |          |<--SBI----|          |          |          |          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |          |<-NGAP----|          |          |          |          |          |          |          |          |
# |<-NAS-----|  (Auth Request)     |          |          |          |          |          |          |          |
# |--NAS---->|  (Auth Response)    |          |          |          |          |          |          |          |
# |          |--NGAP--->|          |          |          |          |          |          |          |          |
# |          |          |---SBI--->|          |          |          |          |          |          |          |
# |          |          | Nausf_5gAkaConfirmation         |          |          |          |          |          |
# |          |          |<--SBI----|          |          |          |          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |          |<-NGAP----|          |          |          |          |          |          |          |          |
# |<-NAS-----|  (Security Mode Command)       |          |          |          |          |          |          |
# |--NAS---->|  (Security Mode Complete)      |          |          |          |          |          |          |
# |          |--NGAP--->|          |          |          |          |          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |          |          |--SBI----------------------------------->|          |          |          |          |
# |          |          | Nnssf_NSSelection    |          |          |          |          |          |          |
# |          |          |<-SBI------------------------------------|          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |          |          |--SBI------------------------------------------------------>|          |          |
# |          |          | Npcf_AMPolicyControl_Create     |          |          |          |          |          |
# |          |          |<-SBI-------------------------------------------------------|          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |          |<-NGAP----|          |          |          |          |          |          |          |          |
# |<-NAS-----|  (Registration Accept)         |          |          |          |          |          |          |
# |--NAS---->|  (Registration Complete)       |          |          |          |          |          |          |
# |          |--NGAP--->|          |          |          |          |          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |  === PDU Session Establishment ===        |          |          |          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |--NAS---->|          |          |          |          |          |          |          |          |          |
# |          |--NGAP--->|          |          |          |          |          |          |          |          |
# |          |          |--SBI------------------------------------------------------------->|          |
# |          |          | Nsmf_PDUSession_CreateSMContext  |          |          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
# |          |          |          |          |          |          |          |   SMF--->|---PFCP--->|
# |          |          |          |          |          |          |          |          | Session   |
# |          |          |          |          |          |          |          |          | Establ.   |
# |          |          |          |          |          |          |          |   SMF<---|<--PFCP----|
# |          |          |          |          |          |          |          |          |          |          |
# |          |          |<-SBI--------------------------------------------------------------|          |
# |          |<-NGAP----|          |          |          |          |          |          |          |          |
# |<-NAS-----|  (PDU Session Accept)          |          |          |          |          |          |          |
# |          |          |          |          |          |          |          |          |          |          |
SEQUENCE

echo "" >> "$REPORT_FILE"

# ── Section 12: Raw Log Locations ─────────────────────────────
echo "# ========================================" >> "$REPORT_FILE"
echo "# 12. Raw Log Locations" >> "$REPORT_FILE"
echo "# ========================================" >> "$REPORT_FILE"
echo "#" >> "$REPORT_FILE"
echo "# Raw logs saved to: $RAW_DIR/" >> "$REPORT_FILE"
echo "#" >> "$REPORT_FILE"
for f in "$RAW_DIR"/*.log; do
    FNAME=$(basename "$f")
    FLINES=$(wc -l < "$f" | tr -d ' ')
    echo "#   $FNAME: $FLINES lines" >> "$REPORT_FILE"
done
echo "#" >> "$REPORT_FILE"

# ── Step 7: Summary ──────────────────────────────────────────
log "Step 7/7: Report complete!"
echo ""
log "========================================="
log "  REGISTRATION FLOW TRACE COMPLETE"
log "========================================="
echo ""
log "Report: $REPORT_FILE"
log "Raw logs: $RAW_DIR/"
echo ""
log "Quick view:"
log "  cat $REPORT_FILE"
echo ""

# Show a brief summary of what was captured
echo "--- Key Events Summary ---"
if [ -s "$RAW_DIR/ueransim.log" ]; then
    echo ""
    echo "UERANSIM:"
    grep -c "Registration\|PDU Session\|Authentication\|Security" "$RAW_DIR/ueransim.log" 2>/dev/null | xargs -I{} echo "  {} registration-related events"
fi
if [ -s "$RAW_DIR/amf.log" ]; then
    echo "AMF:"
    grep -c "NGAP\|NAS\|Registration\|Authentication\|PDUSession" "$RAW_DIR/amf.log" 2>/dev/null | xargs -I{} echo "  {} NGAP/NAS/Registration events"
fi
if [ -s "$RAW_DIR/ausf.log" ]; then
    echo "AUSF:"
    grep -c "UEAuthentication\|auth\|5gAka" "$RAW_DIR/ausf.log" 2>/dev/null | xargs -I{} echo "  {} authentication events"
fi
if [ -s "$RAW_DIR/smf.log" ]; then
    echo "SMF:"
    grep -c "PDUSession\|PFCP\|Session" "$RAW_DIR/smf.log" 2>/dev/null | xargs -I{} echo "  {} session events"
fi
echo ""
