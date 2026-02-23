#!/bin/bash
# ============================================================
# TC02: Component Crash and Recovery
# Simulate crash of CP/UPF and verify recovery
# ============================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

header "TC02: Component Crash and Recovery"

ensure_core_running

# Step 1: Verify baseline - register a UE
info "Registering baseline UE..."
kill_all_ues
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10

imsi="imsi-001010000050641"
status=$(docker exec ueransim ./nr-cli "$imsi" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "Baseline UE registered"
else
    fail "Baseline UE failed to register, aborting"
    exit 1
fi
kill_all_ues

# ── Test A: UPF Crash and Recovery ──
echo ""
info "=== Test A: UPF Crash & Recovery ==="

info "Killing UPF container..."
docker kill upf >/dev/null 2>&1
sleep 3
upf_state=$(docker inspect --format='{{.State.Status}}' upf 2>/dev/null || echo "missing")
if [ "$upf_state" != "running" ]; then
    pass "UPF stopped (state: ${upf_state})"
else
    fail "UPF still running after kill"
fi

info "Restarting UPF..."
docker start upf >/dev/null 2>&1
sleep 10

upf_state=$(docker inspect --format='{{.State.Status}}' upf 2>/dev/null)
if [ "$upf_state" = "running" ]; then
    pass "UPF recovered (running)"
else
    fail "UPF failed to restart (state: ${upf_state})"
fi

# Verify UE can register after UPF recovery
info "Registering UE after UPF recovery..."
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10
status=$(docker exec ueransim ./nr-cli "$imsi" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE re-registered after UPF recovery"
else
    fail "UE failed to register after UPF recovery"
fi
kill_all_ues

# ── Test B: CP Crash and Recovery ──
echo ""
info "=== Test B: Control Plane Crash & Recovery ==="

info "Killing CP container..."
docker kill free5gc-cp >/dev/null 2>&1
sleep 3
cp_state=$(docker inspect --format='{{.State.Status}}' free5gc-cp 2>/dev/null || echo "missing")
if [ "$cp_state" != "running" ]; then
    pass "CP stopped (state: ${cp_state})"
else
    fail "CP still running after kill"
fi

info "Restarting CP..."
docker start free5gc-cp >/dev/null 2>&1
info "Waiting for CP to become healthy (up to 120s)..."
waited=0
while [ $waited -lt 120 ]; do
    health=$(docker inspect --format='{{.State.Health.Status}}' free5gc-cp 2>/dev/null || echo "unknown")
    if [ "$health" = "healthy" ]; then
        break
    fi
    sleep 5
    waited=$((waited + 5))
done

if [ "$health" = "healthy" ]; then
    pass "CP recovered and healthy (took ${waited}s)"
else
    fail "CP health check failed after 120s (status: ${health})"
fi

# Restart UERANSIM gNB to reconnect to AMF
info "Restarting UERANSIM gNB..."
docker restart ueransim >/dev/null 2>&1
sleep 10

# Verify UE can register after CP recovery
info "Registering UE after CP recovery..."
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10
status=$(docker exec ueransim ./nr-cli "$imsi" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE re-registered after CP recovery"
else
    fail "UE failed to register after CP recovery"
fi
kill_all_ues

# ── Test C: MongoDB Crash and Recovery ──
echo ""
info "=== Test C: MongoDB Crash & Recovery ==="

info "Killing MongoDB container..."
docker kill mongodb >/dev/null 2>&1
sleep 3
mongo_state=$(docker inspect --format='{{.State.Status}}' mongodb 2>/dev/null || echo "missing")
if [ "$mongo_state" != "running" ]; then
    pass "MongoDB stopped (state: ${mongo_state})"
else
    fail "MongoDB still running after kill"
fi

info "Restarting MongoDB..."
docker start mongodb >/dev/null 2>&1
sleep 10

mongo_state=$(docker inspect --format='{{.State.Status}}' mongodb 2>/dev/null)
if [ "$mongo_state" = "running" ]; then
    pass "MongoDB recovered (running)"
else
    fail "MongoDB failed to restart"
fi

# Verify UE can register after MongoDB recovery
info "Registering UE after MongoDB recovery..."
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 10
status=$(docker exec ueransim ./nr-cli "$imsi" -e "status" 2>/dev/null)
if echo "$status" | grep -q "RM-REGISTERED"; then
    pass "UE re-registered after MongoDB recovery"
else
    fail "UE failed to register after MongoDB recovery"
fi
kill_all_ues

# Summary
echo ""
echo -e "${BOLD}TC02 Complete${NC}: Check PASS/FAIL results above"
