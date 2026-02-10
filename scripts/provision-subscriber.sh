#!/bin/bash
# ============================================================
# Subscriber Provisioning Script for free5GC v4.2.0
# ============================================================
# This script provisions a subscriber using the WebUI API and
# patches MongoDB to fix fields that WebUI doesn't populate
# correctly (allowedSessionTypes, smPolicySnssaiData).
#
# Usage:
#   ./scripts/provision-subscriber.sh [IMSI] [PLMN]
#
# Examples:
#   ./scripts/provision-subscriber.sh                           # Default: imsi-208930000000001, PLMN 20893
#   ./scripts/provision-subscriber.sh imsi-208930000000002 20893
#
# Prerequisites:
#   - Docker network exists (run docker compose up -d first)
#   - MongoDB container is running
#   - curl and python3 available on host
# ============================================================

set -euo pipefail

IMSI="${1:-imsi-208930000000001}"
PLMN="${2:-20893}"
DOCKER_NETWORK="${3:-free5gc-5g-sa-setup_privnet}"
WEBUI_IMAGE="free5gc/webui:v4.2.0"

# Auto-detect port: use 5001 on macOS (port 5000 is used by AirPlay)
if [ "$(uname)" = "Darwin" ]; then
    WEBUI_PORT=5001
else
    WEBUI_PORT=5000
fi

# Default 5G-AKA credentials (matches free5GC test defaults)
K="8baf473f2f8fd09487cccbd7097c6862"
OPC="8e27b6af0e692e750f32667a3b14605d"
SQN="000000000020"
AMF_FIELD="8000"

log() { echo "[$(date '+%H:%M:%S')] $1"; }

# ── Step 1: Start temporary WebUI container ─────────────────
log "Starting temporary WebUI container..."

# Clean up any leftover
docker rm -f webui-temp 2>/dev/null || true

# Check if webuicfg.yaml exists
WEBUI_CFG="./config/webuicfg.yaml"
if [ ! -f "$WEBUI_CFG" ]; then
    log "ERROR: $WEBUI_CFG not found. Run from the project root directory."
    exit 1
fi

docker run -d --name webui-temp \
    --network "$DOCKER_NETWORK" \
    -v "$(pwd)/config/webuicfg.yaml:/free5gc/config/webuicfg.yaml" \
    -v "$(pwd)/cert:/free5gc/cert" \
    -e GIN_MODE=release \
    -p "${WEBUI_PORT}:5000" \
    "$WEBUI_IMAGE" ./webui -c ./config/webuicfg.yaml

log "Waiting for WebUI to start..."
sleep 5

# Verify WebUI is running
if ! docker ps --filter name=webui-temp --format '{{.Status}}' | grep -q "Up"; then
    log "ERROR: WebUI failed to start. Logs:"
    docker logs webui-temp 2>&1
    docker rm -f webui-temp 2>/dev/null
    exit 1
fi

# ── Step 2: Login to get JWT token ──────────────────────────
log "Logging in to WebUI (admin/free5gc)..."

TOKEN=$(curl -s -X POST "http://localhost:${WEBUI_PORT}/api/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"free5gc"}' | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "None" ]; then
    log "ERROR: Failed to get JWT token from WebUI"
    docker rm -f webui-temp 2>/dev/null
    exit 1
fi
log "JWT token acquired"

# ── Step 3: Create subscriber via WebUI API ─────────────────
log "Creating subscriber $IMSI (PLMN: $PLMN)..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://localhost:${WEBUI_PORT}/api/subscriber/${IMSI}/${PLMN}" \
    -H 'Content-Type: application/json' \
    -H "Token: ${TOKEN}" \
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
      \"defaultSingleNssais\": [{\"sst\": 1, \"sd\": \"010203\"}, {\"sst\": 1, \"sd\": \"112233\"}]
    }
  },
  \"SessionManagementSubscriptionData\": [
    {
      \"singleNssai\": {\"sst\": 1, \"sd\": \"010203\"},
      \"dnnConfigurations\": {
        \"internet\": {
          \"pduSessionTypes\": {\"defaultSessionType\": \"IPV4\"},
          \"sscModes\": {\"defaultSscMode\": \"SSC_MODE_1\"},
          \"5gQosProfile\": {\"5qi\": 9, \"arp\": {\"priorityLevel\": 8, \"preemptCap\": \"\", \"preemptVuln\": \"\"}},
          \"sessionAmbr\": {\"downlink\": \"200 Mbps\", \"uplink\": \"100 Mbps\"}
        }
      }
    },
    {
      \"singleNssai\": {\"sst\": 1, \"sd\": \"112233\"},
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
      \"01010203\": {\"dnnInfos\": [{\"dnn\": \"internet\"}]},
      \"01112233\": {\"dnnInfos\": [{\"dnn\": \"internet\"}]}
    }
  }
}")

if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
    log "Subscriber created via WebUI (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "409" ]; then
    log "Subscriber already exists (HTTP 409) - continuing with patches"
else
    log "WARNING: Unexpected HTTP $HTTP_CODE from WebUI. Continuing with patches..."
fi

# ── Step 4: Stop WebUI (no longer needed) ───────────────────
log "Stopping temporary WebUI..."
docker stop webui-temp >/dev/null 2>&1
docker rm webui-temp >/dev/null 2>&1

# ── Step 5: Patch MongoDB - add allowedSessionTypes ─────────
# WebUI doesn't populate allowedSessionTypes, which causes SMF
# to reject PDU sessions with "no SupportedPDUSessionType" error
log "Patching MongoDB: adding allowedSessionTypes to smData..."

docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['subscriptionData.provisionedData.smData'].updateMany(
  { ueId: '${IMSI}' },
  { \$set: { 'dnnConfigurations.internet.pduSessionTypes.allowedSessionTypes': ['IPV4'] } }
)" 2>&1 | grep -v "^$"

# ── Step 6: Patch MongoDB - populate smPolicySnssaiData ─────
# WebUI leaves smPolicySnssaiData as null, which causes PCF to
# crash with nil pointer panic when creating SM policies
log "Patching MongoDB: populating smPolicySnssaiData..."

docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval "
db['policyData.ues.smData'].updateOne(
  { ueId: '${IMSI}' },
  {
    \$set: {
      smPolicySnssaiData: {
        '01010203': {
          snssai: { sst: 1, sd: '010203' },
          smPolicyDnnData: {
            internet: { dnn: 'internet' }
          }
        },
        '01112233': {
          snssai: { sst: 1, sd: '112233' },
          smPolicyDnnData: {
            internet: { dnn: 'internet' }
          }
        }
      }
    }
  },
  { upsert: true }
)" 2>&1 | grep -v "^$"

# ── Step 7: Verify ──────────────────────────────────────────
log "Verifying subscriber data..."

SM_COUNT=$(docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval \
    "db['subscriptionData.provisionedData.smData'].countDocuments({ueId: '${IMSI}'})")

POLICY_COUNT=$(docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval \
    "db['policyData.ues.smData'].countDocuments({ueId: '${IMSI}', smPolicySnssaiData: {\$ne: null}})")

ALLOWED=$(docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval \
    "db['subscriptionData.provisionedData.smData'].countDocuments({ueId: '${IMSI}', 'dnnConfigurations.internet.pduSessionTypes.allowedSessionTypes': {\$exists: true}})")

log "Verification:"
log "  SM Data documents: $SM_COUNT (expected: 2)"
log "  Policy data with smPolicySnssaiData: $POLICY_COUNT (expected: 1)"
log "  SM Data with allowedSessionTypes: $ALLOWED (expected: 2)"

if [ "$SM_COUNT" = "2" ] && [ "$POLICY_COUNT" = "1" ] && [ "$ALLOWED" = "2" ]; then
    log "SUCCESS: Subscriber $IMSI provisioned and patched correctly"
else
    log "WARNING: Verification counts don't match expected values"
fi

log "Done. Subscriber $IMSI is ready for registration."
