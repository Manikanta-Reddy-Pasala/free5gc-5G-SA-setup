#!/bin/bash
# ============================================================
# run-free5gc.sh - Configure & Start free5GC with custom params
# ============================================================
# Updates all config files (AMF, SMF, NRF, NSSF, gNB, UE) with
# the provided MCC, MNC, and TAC, then starts the entire 5G SA core.
#
# Usage:
#   ./run-free5gc.sh --mcc 404 --mnc 30 --tac 1
#   ./run-free5gc.sh --mcc 001 --mnc 01        # uses default TAC=1
#   ./run-free5gc.sh --stop                     # stop all containers
#   ./run-free5gc.sh --status                   # show container status
#
# Defaults (free5GC test PLMN):
#   MCC=001, MNC=01, TAC=1
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Defaults ────────────────────────────────────────────────
MCC="001"
MNC="01"
TAC="1"
AMF_IP="10.100.200.16"
NGAP_PORT="38412"
DEBUG=false
STOP=false
STATUS=false

COMPOSE_FILE="docker-compose-portable.yaml"
CONFIG_DIR="config"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ── Parse Arguments ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mcc)   MCC="$2"; shift 2 ;;
        --mnc)   MNC="$2"; shift 2 ;;
        --tac)   TAC="$2"; shift 2 ;;
        --debug) DEBUG=true; shift ;;
        --stop)  STOP=true; shift ;;
        --status) STATUS=true; shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --mcc VALUE    Mobile Country Code (3 digits, default: 001)"
            echo "  --mnc VALUE    Mobile Network Code (2-3 digits, default: 01)"
            echo "  --tac VALUE    Tracking Area Code (decimal, default: 1)"
            echo "  --debug        Use debug-level logging"
            echo "  --stop         Stop all containers and clean up"
            echo "  --status       Show container status"
            echo "  -h, --help     Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

log() { echo "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"; }

# ── Stop command ────────────────────────────────────────────
if [ "$STATUS" = true ]; then
    docker compose -f "$COMPOSE_FILE" ps
    exit 0
fi

if [ "$STOP" = true ]; then
    log "Cleaning up SCTP forwarding rules..."
    iptables -t nat -D PREROUTING -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}" 2>/dev/null || true
    iptables -t nat -D OUTPUT -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}" 2>/dev/null || true
    iptables -D FORWARD -p sctp -d "$AMF_IP" --dport "$NGAP_PORT" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p sctp -s "$AMF_IP" --sport "$NGAP_PORT" -j ACCEPT 2>/dev/null || true
    log "Stopping all containers..."
    docker compose -f "$COMPOSE_FILE" down -v
    log "${GREEN}All containers stopped.${NC}"
    exit 0
fi

# ── Validate inputs ─────────────────────────────────────────
if ! [[ "$MCC" =~ ^[0-9]{3}$ ]]; then
    echo "${RED}ERROR: MCC must be exactly 3 digits (e.g. 001, 404, 310)${NC}"
    exit 1
fi
if ! [[ "$MNC" =~ ^[0-9]{2,3}$ ]]; then
    echo "${RED}ERROR: MNC must be 2 or 3 digits (e.g. 01, 30, 560)${NC}"
    exit 1
fi
if ! [[ "$TAC" =~ ^[0-9]+$ ]]; then
    echo "${RED}ERROR: TAC must be a decimal number (e.g. 1, 100, 33456)${NC}"
    exit 1
fi

# Derived values
PLMN="${MCC}${MNC}"
# TAC in hex (6-char zero-padded) for AMF config
TAC_HEX=$(printf "%06x" "$TAC")
# IMSI: MCC + MNC + fixed MSISDN
IMSI="imsi-${MCC}${MNC}0000050641"

log "${BOLD}free5GC Configuration${NC}"
log "  MCC:       ${GREEN}${MCC}${NC}"
log "  MNC:       ${GREEN}${MNC}${NC}"
log "  TAC:       ${GREEN}${TAC}${NC} (hex: ${TAC_HEX})"
log "  PLMN:      ${GREEN}${PLMN}${NC}"
log "  IMSI:      ${GREEN}${IMSI}${NC}"
echo ""

# ── Select config directory ─────────────────────────────────
if [ "$DEBUG" = true ]; then
    CONFIG_DIR="config-debug"
    log "Mode: ${YELLOW}DEBUG${NC} (debug-level logging)"
else
    CONFIG_DIR="config"
    log "Mode: ${GREEN}NORMAL${NC} (info-level logging)"
fi

# ── Step 1: Update config files ─────────────────────────────
log "${BOLD}Step 1/4: Updating config files with MCC=${MCC}, MNC=${MNC}, TAC=${TAC}...${NC}"

# --- amfcfg.yaml ---
AMF_CFG="${CONFIG_DIR}/amfcfg.yaml"
if [ -f "$AMF_CFG" ]; then
    # MCC/MNC in servedGuamiList, supportTaiList, plmnSupportList
    sed -i "s/^\(\s*-\?\s*mcc:\s*\)[0-9]\{3\}/\1${MCC}/g" "$AMF_CFG"
    sed -i "s/^\(\s*-\?\s*mnc:\s*\)[0-9]\{2,3\}/\1${MNC}/g" "$AMF_CFG"
    # TAC (hex format, 6 chars)
    sed -i "s/^\(\s*tac:\s*\)[0-9a-fA-F]\{6\}/\1${TAC_HEX}/" "$AMF_CFG"
    # NGAP port
    sed -i "s/^\(\s*ngapPort:\s*\)[0-9]\+/\1${NGAP_PORT}/" "$AMF_CFG"
    log "  ${GREEN}Updated${NC} $AMF_CFG"
else
    log "  ${YELLOW}SKIP${NC} $AMF_CFG (not found)"
fi

# --- smfcfg.yaml ---
SMF_CFG="${CONFIG_DIR}/smfcfg.yaml"
if [ -f "$SMF_CFG" ]; then
    sed -i "s/^\(\s*-\?\s*mcc:\s*\)[0-9]\{3\}/\1${MCC}/g" "$SMF_CFG"
    sed -i "s/^\(\s*-\?\s*mnc:\s*\)[0-9]\{2,3\}/\1${MNC}/g" "$SMF_CFG"
    log "  ${GREEN}Updated${NC} $SMF_CFG"
else
    log "  ${YELLOW}SKIP${NC} $SMF_CFG (not found)"
fi

# --- nrfcfg.yaml ---
NRF_CFG="${CONFIG_DIR}/nrfcfg.yaml"
if [ -f "$NRF_CFG" ]; then
    sed -i "s/^\(\s*-\?\s*mcc:\s*\)[0-9]\{3\}/\1${MCC}/g" "$NRF_CFG"
    sed -i "s/^\(\s*-\?\s*mnc:\s*\)[0-9]\{2,3\}/\1${MNC}/g" "$NRF_CFG"
    log "  ${GREEN}Updated${NC} $NRF_CFG"
else
    log "  ${YELLOW}SKIP${NC} $NRF_CFG (not found)"
fi

# --- nssfcfg.yaml ---
NSSF_CFG="${CONFIG_DIR}/nssfcfg.yaml"
if [ -f "$NSSF_CFG" ]; then
    # Only update the supportedPlmnList and supportedNssaiInPlmnList MCC/MNC (first 2 occurrences)
    # The amfSetList/amfList/taList sections have different PLMNs (466/92) — leave those as-is
    sed -i '/^  supportedPlmnList:/,/^  supportedNssaiInPlmnList:/{s/^\(\s*mcc:\s*\)[0-9]\{3\}/\1'"${MCC}"'/; s/^\(\s*mnc:\s*\)[0-9]\{2,3\}/\1'"${MNC}"'/}' "$NSSF_CFG"
    sed -i '/^  supportedNssaiInPlmnList:/,/^  nsiList:/{s/^\(\s*mcc:\s*\)[0-9]\{3\}/\1'"${MCC}"'/; s/^\(\s*mnc:\s*\)[0-9]\{2,3\}/\1'"${MNC}"'/}' "$NSSF_CFG"
    log "  ${GREEN}Updated${NC} $NSSF_CFG (supportedPlmnList only)"
else
    log "  ${YELLOW}SKIP${NC} $NSSF_CFG (not found)"
fi

# --- gnbcfg.yaml ---
GNB_CFG="${CONFIG_DIR}/gnbcfg.yaml"
if [ -f "$GNB_CFG" ]; then
    # MCC/MNC (quoted strings in UERANSIM format)
    sed -i "s/^mcc: \"[0-9]\{3\}\"/mcc: \"${MCC}\"/" "$GNB_CFG"
    sed -i "s/^mnc: \"[0-9]\{2,3\}\"/mnc: \"${MNC}\"/" "$GNB_CFG"
    # TAC (decimal integer)
    sed -i "s/^tac: [0-9]\+/tac: ${TAC}/" "$GNB_CFG"
    # AMF port
    sed -i "s/^\(\s*port:\s*\)[0-9]\+/\1${NGAP_PORT}/" "$GNB_CFG"
    log "  ${GREEN}Updated${NC} $GNB_CFG"
else
    log "  ${YELLOW}SKIP${NC} $GNB_CFG (not found)"
fi

# --- uecfg.yaml ---
UE_CFG="${CONFIG_DIR}/uecfg.yaml"
if [ -f "$UE_CFG" ]; then
    # SUPI/IMSI
    sed -i "s/^supi: \"imsi-[0-9]\+\"/supi: \"${IMSI}\"/" "$UE_CFG"
    # MCC/MNC (quoted strings)
    sed -i "s/^mcc: \"[0-9]\{3\}\"/mcc: \"${MCC}\"/" "$UE_CFG"
    sed -i "s/^mnc: \"[0-9]\{2,3\}\"/mnc: \"${MNC}\"/" "$UE_CFG"
    log "  ${GREEN}Updated${NC} $UE_CFG"
else
    log "  ${YELLOW}SKIP${NC} $UE_CFG (not found)"
fi

echo ""

# ── Step 2: Stop existing containers ────────────────────────
log "${BOLD}Step 2/4: Stopping any existing containers...${NC}"
# Clean up old SCTP rules
iptables -t nat -D PREROUTING -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}" 2>/dev/null || true
iptables -t nat -D OUTPUT -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}" 2>/dev/null || true
iptables -D FORWARD -p sctp -d "$AMF_IP" --dport "$NGAP_PORT" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -p sctp -s "$AMF_IP" --sport "$NGAP_PORT" -j ACCEPT 2>/dev/null || true

docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
echo ""

# ── Step 3: Start containers ────────────────────────────────
log "${BOLD}Step 3/4: Starting containers...${NC}"
mkdir -p logs/cp logs/upf

export CONFIG_DIR
docker compose -f "$COMPOSE_FILE" up -d

# Wait for CP to become healthy
log "Waiting for Control Plane to be healthy..."
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS_CHECK=$(docker inspect --format='{{.State.Health.Status}}' free5gc-cp 2>/dev/null || echo "unknown")
    if [ "$STATUS_CHECK" = "healthy" ]; then
        log "  ${GREEN}free5gc-cp is healthy${NC} (took ${WAITED}s)"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    if [ $((WAITED % 10)) -eq 0 ]; then
        log "  Still waiting... (${WAITED}s, status: $STATUS_CHECK)"
    fi
done
if [ $WAITED -ge $MAX_WAIT ]; then
    log "${YELLOW}WARNING: CP health check timed out after ${MAX_WAIT}s${NC}"
    docker logs free5gc-cp --tail 20 2>&1 | head -20
fi
echo ""

# ── Step 4: Setup SCTP forwarding & restart UERANSIM ────────
log "${BOLD}Step 4/4: Setting up SCTP forwarding & gNB connection...${NC}"

# Load SCTP kernel module
modprobe sctp 2>/dev/null || true

# DNAT rules for SCTP (Docker can't proxy SCTP natively)
iptables -t nat -A PREROUTING -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}"
iptables -t nat -A OUTPUT -p sctp --dport "$NGAP_PORT" -j DNAT --to-destination "${AMF_IP}:${NGAP_PORT}"
iptables -A FORWARD -p sctp -d "$AMF_IP" --dport "$NGAP_PORT" -j ACCEPT
iptables -A FORWARD -p sctp -s "$AMF_IP" --sport "$NGAP_PORT" -j ACCEPT
log "  SCTP DNAT rules added (host:${NGAP_PORT} -> ${AMF_IP}:${NGAP_PORT})"

# Restart UERANSIM to ensure gNB connects after AMF is ready
docker restart ueransim >/dev/null 2>&1
sleep 5
log "  UERANSIM restarted"
echo ""

# ── Show status ─────────────────────────────────────────────
docker compose -f "$COMPOSE_FILE" ps
echo ""
log "========================================="
log "  ${GREEN}${BOLD}free5GC IS RUNNING${NC}"
log "========================================="
echo ""
log "  PLMN:     ${BOLD}${MCC}/${MNC}${NC}"
log "  TAC:      ${BOLD}${TAC}${NC}"
log "  IMSI:     ${BOLD}${IMSI}${NC}"
log "  WebUI:    ${BOLD}http://$(hostname -I | awk '{print $1}'):4000${NC}"
log "            Login: admin / free5gc"
echo ""
log "  Logs:     ./free5gc.sh logs"
log "  Stop:     $0 --stop"
echo ""
