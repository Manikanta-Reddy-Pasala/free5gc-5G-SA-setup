# Chapter 8: Deployment Modes Guide - Full vs Mandatory vs Consolidated

## Table of Contents

1. [Overview](#overview)
2. [Mode Comparison](#mode-comparison)
3. [Mode 1: Full Deployment (17 Containers)](#mode-1-full-deployment-17-containers)
4. [Mode 2: Mandatory Deployment (11 Containers)](#mode-2-mandatory-deployment-11-containers)
5. [Mode 3: Consolidated Deployment (4 Containers)](#mode-3-consolidated-deployment-4-containers)
6. [Quick Reference: Commands Cheat Sheet](#quick-reference-commands-cheat-sheet)
7. [Decision Guide: Which Mode to Choose](#decision-guide-which-mode-to-choose)
8. [Troubleshooting by Mode](#troubleshooting-by-mode)

---

## Overview

free5GC v4.2.0 with UERANSIM v3.2.7 can be deployed in **three distinct modes**, each suited to different use cases. All three modes deliver a functional 5G SA core that can register UEs, establish PDU sessions, and route traffic to the internet.

This guide provides a unified comparison and step-by-step instructions for deploying, testing, and managing each mode.

### Prerequisites (All Modes)

- Ubuntu 22.04 LTS (Kernel 5.4+)
- CPU with AVX support (for MongoDB 4.4+)
- 4 GB RAM minimum (8 GB recommended for Full mode)
- Root access
- Docker Engine + Docker Compose plugin installed
- GTP5G kernel module loaded (`modprobe gtp5g`)

---

## Mode Comparison

### At a Glance

| Feature | Full | Mandatory | Consolidated |
|---------|------|-----------|--------------|
| **Docker Compose File** | `docker-compose.yaml` | `docker-compose-minimal.yaml` | `docker-compose-consolidated.yaml` |
| **Total Containers** | 17 | 11 | 4 |
| **Control Plane Containers** | 13 (individual NFs) | 9 (individual NFs) | 1 (all CP in one) |
| **RAM Usage (approx.)** | ~3-4 GB | ~2-3 GB | ~1-1.5 GB |
| **Startup Time** | ~30-45 seconds | ~20-30 seconds | ~15-20 seconds |
| **Custom Build Required** | No | No | Yes (Dockerfile) |
| **WebUI Included** | Yes (port 5000) | No | No |
| **Charging (CHF)** | Yes | No | No |
| **Non-3GPP Access (N3IWF/TNGF)** | Yes | No | No |
| **Network Exposure (NEF)** | Yes | No | No |
| **Network Slicing** | Full (NSSF + PCF) | Yes (NSSF + PCF) | Yes (NSSF + PCF) |
| **Best For** | Full lab, demos, learning | Functional testing, CI/CD | Resource-constrained, edge |

### Container Inventory

| Container | Full | Mandatory | Consolidated |
|-----------|:----:|:---------:|:------------:|
| MongoDB | `mongodb` | `mongodb` | `mongodb` |
| NRF | `nrf` | `nrf` | *in `free5gc-cp`* |
| AMF | `amf` | `amf` | *in `free5gc-cp`* |
| AUSF | `ausf` | `ausf` | *in `free5gc-cp`* |
| UDM | `udm` | `udm` | *in `free5gc-cp`* |
| UDR | `udr` | `udr` | *in `free5gc-cp`* |
| SMF | `smf` | `smf` | *in `free5gc-cp`* |
| NSSF | `nssf` | `nssf` | *in `free5gc-cp`* |
| PCF | `pcf` | `pcf` | *in `free5gc-cp`* |
| UPF | `upf` | `upf` | `upf` |
| UERANSIM | `ueransim` | `ueransim` | `ueransim` |
| CHF | `chf` | -- | -- |
| NEF | `nef` | -- | -- |
| N3IWF | `n3iwf` | -- | -- |
| TNGF | `tngf` | -- | -- |
| WebUI | `webui` | -- | -- |
| N3IWUE | `n3iwue` | -- | -- |

> **Note on NSSF and PCF**: Although 3GPP considers NSSF and PCF as optional, free5GC v4.2.0 requires them for proper operation. Both are included in Mandatory and Consolidated modes.

---

## Mode 1: Full Deployment (17 Containers)

### What's Included

All 10 core NFs + all optional components + simulators:

- **Core NFs**: NRF, AMF, AUSF, UDM, UDR, SMF, UPF, NSSF, PCF
- **Optional NFs**: CHF (charging), NEF (network exposure), N3IWF (Wi-Fi interworking), TNGF (trusted non-3GPP)
- **Management**: WebUI (subscriber management on port 5000)
- **Simulators**: UERANSIM (gNB + UE), N3IWUE (non-3GPP UE)
- **Database**: MongoDB 4.4

### Deploy

```bash
cd free5gc-5G-SA-setup

# Start all 17 containers
docker compose up -d

# Wait for services to initialize (~30 seconds)
sleep 30

# Verify all containers are running
docker compose ps
```

### Network Configuration

| Component | IP/Address | Port |
|-----------|-----------|------|
| AMF (N2/NGAP) | `10.100.200.16` | 38412 (SCTP) |
| All NFs (SBI) | Docker DNS `*.free5gc.org` | 8000 (HTTP) |
| UPF (N3/GTP-U) | `upf.free5gc.org` | 2152 (UDP) |
| N3IWF | `10.100.200.15` | IKEv2 |
| TNGF | Host network | IKEv2 |
| WebUI | `0.0.0.0` | 5000 (TCP) |
| MongoDB | `db` | 27017 |

### Testing Steps

#### Step 1: Verify Container Health

```bash
docker compose ps
```

**Expected**: All 17 containers show `Up` status. Key containers to check:

```
NAME       STATUS
amf        Up
ausf       Up
chf        Up
mongodb    Up
n3iwf      Up
n3iwue     Up
nef        Up
nrf        Up
nssf       Up
pcf        Up
smf        Up
udm        Up
udr        Up
ueransim   Up
upf        Up
webui      Up
```

> **Note**: TNGF runs on host network and may show differently. N3IWF requires IPSec setup and may exit if the tunnel script fails -- this is normal if you are not testing non-3GPP access.

#### Step 2: Verify NF Registration with NRF

```bash
# Check NRF logs for registered NFs
docker logs nrf 2>&1 | grep -i "registered"

# Or query NRF API directly
docker exec nrf wget -qO- http://127.0.0.1:8000/nnrf-nfm/v1/nf-instances | python3 -m json.tool | grep nfType
```

**Expected**: At least 8 NFs registered: AMF, AUSF, UDM, UDR, SMF, NSSF, PCF, CHF.

#### Step 3: Provision a Subscriber

**Option A: Via WebUI**

1. Open `http://<server-ip>:5000` in a browser
2. Login: `admin` / `free5gc`
3. Go to Subscribers > New Subscriber
4. Set IMSI: `208930000000001`, K, OPC as per `config/uecfg.yaml`
5. Add both slices (SST=1/SD=010203 and SST=1/SD=112233)

**Option B: Via provisioning script**

```bash
./scripts/provision-subscriber.sh
```

This creates the subscriber and patches MongoDB for UERANSIM compatibility (SQN fix + session type fix).

#### Step 4: Register UE and Establish PDU Sessions

```bash
# Start the UE inside the UERANSIM container
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml

# Wait for registration
sleep 5

# Check UE registration status
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
```

**Expected output**:
```
cm-state: CM-CONNECTED
rm-state: RM-REGISTERED
```

#### Step 5: Verify PDU Sessions

```bash
# Check for tunnel interfaces
docker exec ueransim ip addr show uesimtun0
docker exec ueransim ip addr show uesimtun1
```

**Expected**:
- `uesimtun0`: IP in `10.60.0.0/16` range (Slice 1: SST=1/SD=010203)
- `uesimtun1`: IP in `10.61.0.0/16` range (Slice 2: SST=1/SD=112233)

#### Step 6: Test Internet Connectivity

```bash
# Ping via Slice 1
docker exec ueransim ping -I uesimtun0 -c 4 8.8.8.8

# Ping via Slice 2
docker exec ueransim ping -I uesimtun1 -c 4 8.8.8.8
```

**Expected**: 0% packet loss on both interfaces.

#### Step 7: Verify Network Slicing

```bash
# Both tunnels should have IPs in different subnets
docker exec ueransim ip addr show uesimtun0 | grep "inet "
docker exec ueransim ip addr show uesimtun1 | grep "inet "

# Verify in SMF logs
docker logs smf 2>&1 | grep -i "pdu session"
```

**Expected**: Two PDU sessions on different slices with IPs in `10.60.x.x` and `10.61.x.x`.

#### Step 8: Verify Optional NFs

```bash
# CHF (Charging)
docker logs chf 2>&1 | grep -i "started"

# NEF (Network Exposure)
docker logs nef 2>&1 | grep -i "started"

# WebUI
curl -s http://localhost:5000/api/login -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"free5gc"}' | grep access_token
```

#### Step 9: UE Deregistration and Re-registration

```bash
# Deregister
docker exec ueransim ./nr-cli imsi-208930000000001 -e "deregister normal"
sleep 3

# Verify deregistered
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
# Expected: rm-state: RM-DEREGISTERED

# Re-register
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 5
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
# Expected: rm-state: RM-REGISTERED
```

### When to Use Full Mode

- Learning and exploring all 5G NFs
- Demonstrating complete 5G SA capabilities
- Testing charging, non-3GPP access, or network exposure features
- Managing subscribers via WebUI
- Preparing for production deployment (validate all components before selecting mandatory-only)

### Teardown

```bash
docker compose down
# To also remove persistent data:
docker compose down -v
```

---

## Mode 2: Mandatory Deployment (11 Containers)

### What's Included

Only the NFs required for a functional 5G SA core + UERANSIM:

- **Core NFs**: NRF, AMF, AUSF, UDM, UDR, SMF, UPF, NSSF, PCF
- **Simulator**: UERANSIM (gNB + UE)
- **Database**: MongoDB 4.4
- **NOT included**: CHF, NEF, N3IWF, TNGF, WebUI, N3IWUE

### Deploy

```bash
cd free5gc-5G-SA-setup

# Start 11 containers using the minimal compose file
docker compose -f docker-compose-minimal.yaml up -d

# Wait for services to initialize (~20 seconds)
sleep 25

# Verify all containers are running
docker compose -f docker-compose-minimal.yaml ps
```

### Testing Steps

#### Step 1: Verify Container Health

```bash
docker compose -f docker-compose-minimal.yaml ps
```

**Expected**: 11 containers running:
```
NAME       STATUS
amf        Up
ausf       Up
mongodb    Up
nrf        Up
nssf       Up
pcf        Up
smf        Up
udm        Up
udr        Up
ueransim   Up
upf        Up
```

#### Step 2: Verify NF Registration

```bash
docker logs nrf 2>&1 | grep -i "registered"
```

**Expected**: 8 NFs registered (AMF, AUSF, UDM, UDR, SMF, NSSF, PCF, UPF).

#### Step 3: Provision a Subscriber

Since WebUI is not included in this mode, use the provisioning script:

```bash
./scripts/provision-subscriber.sh
```

> **How it works**: The script starts a temporary WebUI container on the Docker network, provisions the subscriber via the API, then stops the temporary container. It also patches MongoDB for UERANSIM compatibility.

**Manual alternative** (direct MongoDB):

```bash
# The provisioning script is recommended, but you can also insert directly
# See scripts/provision-subscriber.sh for the complete subscriber document format
```

#### Step 4: Register UE

```bash
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 5
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
```

**Expected**:
```
cm-state: CM-CONNECTED
rm-state: RM-REGISTERED
```

#### Step 5: Verify PDU Sessions and Connectivity

```bash
# Check tunnel interfaces
docker exec ueransim ip addr show uesimtun0
docker exec ueransim ip addr show uesimtun1

# Ping test on both slices
docker exec ueransim ping -I uesimtun0 -c 4 8.8.8.8
docker exec ueransim ping -I uesimtun1 -c 4 8.8.8.8
```

**Expected**: Two tunnel interfaces with IPs in `10.60.x.x` and `10.61.x.x`, 0% packet loss.

#### Step 6: Verify AMF and SMF Logs

```bash
# Registration success
docker logs amf 2>&1 | grep -i "5GMM message"

# PDU session creation
docker logs smf 2>&1 | grep -i "pdu session"

# UPF association
docker logs upf 2>&1 | grep -i "pfcp"
```

### When to Use Mandatory Mode

- Functional testing where optional NFs are not needed
- CI/CD pipelines (fewer containers = faster spin-up)
- Environments with limited resources (saves ~1 GB RAM over Full mode)
- When you manage subscribers via scripts rather than WebUI
- Focused testing of core 5G registration/session flows

### Teardown

```bash
docker compose -f docker-compose-minimal.yaml down
docker compose -f docker-compose-minimal.yaml down -v  # Include data removal
```

---

## Mode 3: Consolidated Deployment (4 Containers)

### What's Included

All 8 mandatory Control Plane NFs merged into a single container:

| Container | Contents | Image |
|-----------|----------|-------|
| `mongodb` | MongoDB 4.4 | `mongo:4.4` |
| `free5gc-cp` | NRF + AMF + AUSF + UDM + UDR + SMF + NSSF + PCF | `free5gc-cp:v4.2.0` (custom build) |
| `upf` | User Plane Function | `free5gc/upf:v4.2.0` |
| `ueransim` | gNB + UE simulator | `free5gc/ueransim:latest` |

### How It Works

The `free5gc-cp` container runs all 8 Control Plane NFs as separate processes within a single container:
- Each NF binds to a unique port (NRF:8000, UDR:8001, UDM:8002, AUSF:8003, NSSF:8004, PCF:8005, AMF:8006, SMF:8007)
- All NFs share the container's static IP (`10.100.200.16`)
- Config files in `config-consolidated/` use `0.0.0.0` as bind address and `10.100.200.16` for registration
- The startup script (`start-cp-nfs.sh`) launches NFs in dependency order with health checks
- A background monitor restarts any NF that crashes

### Build and Deploy

```bash
cd free5gc-5G-SA-setup

# Step 1: Build the consolidated CP image (one-time)
docker build -f consolidated/Dockerfile.consolidated-cp \
  -t free5gc-cp:v4.2.0 \
  consolidated/

# Step 2: Start 4 containers
docker compose -f docker-compose-consolidated.yaml up -d

# Wait for CP initialization (NFs start sequentially with health checks)
sleep 30

# Verify
docker compose -f docker-compose-consolidated.yaml ps
```

### Testing Steps

#### Step 1: Verify Container Health

```bash
docker compose -f docker-compose-consolidated.yaml ps
```

**Expected**: 4 containers, all `Up`. The `free5gc-cp` container should show `Up (healthy)`:
```
NAME         STATUS
free5gc-cp   Up (healthy)
mongodb      Up
ueransim     Up
upf          Up
```

#### Step 2: Verify All NF Processes Inside CP Container

```bash
docker exec free5gc-cp ps aux | grep -E "nrf|amf|ausf|udm|udr|smf|nssf|pcf"
```

**Expected**: 8 NF processes running:
```
root  ... ./nrf -c ./config/nrfcfg.yaml
root  ... ./udr -c ./config/udrcfg.yaml
root  ... ./udm -c ./config/udmcfg.yaml
root  ... ./ausf -c ./config/ausfcfg.yaml
root  ... ./nssf -c ./config/nssfcfg.yaml
root  ... ./pcf -c ./config/pcfcfg.yaml
root  ... ./amf -c ./config/amfcfg.yaml
root  ... ./smf -c ./config/smfcfg.yaml
```

#### Step 3: Verify NRF Health

```bash
# The compose file uses this as a health check
docker exec free5gc-cp wget -qO- http://127.0.0.1:8000/nnrf-nfm/v1/nf-instances | python3 -m json.tool | grep nfType
```

**Expected**: All 8 NFs registered with NRF.

#### Step 4: Provision a Subscriber

```bash
./scripts/provision-subscriber.sh
```

> The provisioning script works the same across all modes -- it starts a temporary WebUI container on the Docker network.

#### Step 5: Register UE and Test Connectivity

```bash
# Start UE
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 5

# Check registration
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"

# Check tunnels
docker exec ueransim ip addr show uesimtun0
docker exec ueransim ip addr show uesimtun1

# Ping test
docker exec ueransim ping -I uesimtun0 -c 4 8.8.8.8
docker exec ueransim ping -I uesimtun1 -c 4 8.8.8.8
```

**Expected**: Same results as other modes -- `RM-REGISTERED`, two tunnel interfaces, 0% packet loss.

#### Step 6: Check NF Logs Inside Consolidated Container

```bash
# All NF logs are stored inside the container
docker exec free5gc-cp cat /var/log/free5gc/nrf.log | tail -20
docker exec free5gc-cp cat /var/log/free5gc/amf.log | tail -20
docker exec free5gc-cp cat /var/log/free5gc/smf.log | tail -20

# Or follow logs in real-time
docker exec free5gc-cp tail -f /var/log/free5gc/amf.log
```

### Configuration Differences

The `config-consolidated/` directory contains modified configs for single-container operation:

| Parameter | Standard Config | Consolidated Config |
|-----------|----------------|---------------------|
| Bind address | NF-specific FQDN (e.g., `amf.free5gc.org`) | `0.0.0.0` (all interfaces) |
| Register IP | NF-specific FQDN | `10.100.200.16` (shared static IP) |
| NRF URI | `http://nrf.free5gc.org:8000` | `http://10.100.200.16:8000` |
| SBI ports | All NFs on port 8000 | Each NF on unique port (8000-8007) |

**Port mapping within the consolidated container**:

| NF | Port |
|----|------|
| NRF | 8000 |
| UDR | 8001 |
| UDM | 8002 |
| AUSF | 8003 |
| NSSF | 8004 |
| PCF | 8005 |
| AMF | 8006 |
| SMF | 8007 |

### When to Use Consolidated Mode

- Resource-constrained environments (Raspberry Pi, edge servers, VMs with limited RAM)
- Rapid prototyping and quick spin-up
- CI/CD pipelines where startup time matters
- Single-host deployments where container isolation is not needed
- Learning 5G without managing 11+ containers

### Teardown

```bash
docker compose -f docker-compose-consolidated.yaml down
docker compose -f docker-compose-consolidated.yaml down -v  # Include data removal
```

---

## Quick Reference: Commands Cheat Sheet

### Deploy

| Mode | Command |
|------|---------|
| Full | `docker compose up -d` |
| Mandatory | `docker compose -f docker-compose-minimal.yaml up -d` |
| Consolidated | `docker build -f consolidated/Dockerfile.consolidated-cp -t free5gc-cp:v4.2.0 consolidated/ && docker compose -f docker-compose-consolidated.yaml up -d` |

### Check Status

| Mode | Command |
|------|---------|
| Full | `docker compose ps` |
| Mandatory | `docker compose -f docker-compose-minimal.yaml ps` |
| Consolidated | `docker compose -f docker-compose-consolidated.yaml ps` |

### View Logs

| Mode | AMF Logs | SMF Logs |
|------|----------|----------|
| Full / Mandatory | `docker logs amf` | `docker logs smf` |
| Consolidated | `docker exec free5gc-cp cat /var/log/free5gc/amf.log` | `docker exec free5gc-cp cat /var/log/free5gc/smf.log` |

### Provision Subscriber

Works the same for all modes:
```bash
./scripts/provision-subscriber.sh
```

### Start UE

Works the same for all modes:
```bash
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
```

### Test Connectivity

Works the same for all modes:
```bash
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
docker exec ueransim ping -I uesimtun0 -c 4 8.8.8.8
docker exec ueransim ping -I uesimtun1 -c 4 8.8.8.8
```

### Teardown

| Mode | Command |
|------|---------|
| Full | `docker compose down -v` |
| Mandatory | `docker compose -f docker-compose-minimal.yaml down -v` |
| Consolidated | `docker compose -f docker-compose-consolidated.yaml down -v` |

---

## Decision Guide: Which Mode to Choose

```
START
  │
  ├─ Do you need CHF, NEF, N3IWF, WebUI, or non-3GPP access?
  │    YES ──> Full Mode (17 containers)
  │    NO
  │    │
  │    ├─ Is RAM < 2 GB or startup time critical?
  │    │    YES ──> Consolidated Mode (4 containers)
  │    │    NO
  │    │    │
  │    │    ├─ Do you want individual container logs and isolation?
  │    │    │    YES ──> Mandatory Mode (11 containers)
  │    │    │    NO  ──> Consolidated Mode (4 containers)
```

### Summary Table

| Scenario | Recommended Mode |
|----------|-----------------|
| First time learning 5G SA | Full |
| Classroom / workshop demo | Full |
| Testing core registration + data flows | Mandatory |
| CI/CD automated testing | Mandatory or Consolidated |
| Raspberry Pi / edge deployment | Consolidated |
| Quick proof-of-concept | Consolidated |
| Production-like validation | Full |
| Debugging a specific NF | Mandatory (separate containers) |
| Charging / billing development | Full (CHF required) |
| Wi-Fi to 5G core testing | Full (N3IWF required) |

---

## Troubleshooting by Mode

### Common to All Modes

| Issue | Cause | Fix |
|-------|-------|-----|
| UPF not starting | GTP5G kernel module not loaded | `sudo modprobe gtp5g && docker compose restart free5gc-upf` |
| NFs fail to register with NRF | NRF or MongoDB not ready yet | Wait 30 seconds, check `docker logs nrf` |
| UE auth fails (MAC failure) | Subscriber K/OPC mismatch | Verify `config/uecfg.yaml` matches provisioned subscriber |
| UE auth fails (SQN out of range) | SQN too large for UERANSIM | Run provisioning script (it patches SQN to `000000000020`) |
| No PDU session (no uesimtun0) | SMF cannot reach UPF via PFCP | Check `docker logs smf` for PFCP errors; verify UPF is running |
| Ping fails via uesimtun0 | UPF NAT rules not applied | `docker exec upf iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE` |
| "SupportedPDUSessionType" error | Missing `allowedSessionTypes` in subscriber data | Run provisioning script (it patches this automatically) |
| PCF nil pointer panic | Missing `smPolicySnssaiData` | Run provisioning script (it patches this automatically) |

### Full Mode Specific

| Issue | Cause | Fix |
|-------|-------|-----|
| N3IWF exits immediately | IPSec tunnel setup failed | Check `docker logs n3iwf`; ensure `config/n3iwf-ipsec.sh` is executable |
| TNGF not showing in `docker compose ps` | Runs on host network | Check with `docker ps \| grep tngf` |
| WebUI not accessible | Port 5000 blocked by firewall | `ufw allow 5000/tcp` or check cloud provider firewall rules |
| N3IWUE cannot connect | N3IWF not healthy | Ensure N3IWF is running first; check IPSec config |

### Mandatory Mode Specific

| Issue | Cause | Fix |
|-------|-------|-----|
| Cannot manage subscribers via browser | WebUI not included | Use `./scripts/provision-subscriber.sh` or start a temp WebUI: `docker run --rm --network free5gc-5g-sa-setup_privnet -p 5000:5000 free5gc/webui:v4.2.0` |

### Consolidated Mode Specific

| Issue | Cause | Fix |
|-------|-------|-----|
| `free5gc-cp:v4.2.0` image not found | Not built yet | Run `docker build -f consolidated/Dockerfile.consolidated-cp -t free5gc-cp:v4.2.0 consolidated/` |
| CP container not becoming healthy | NRF failed to start | `docker exec free5gc-cp cat /var/log/free5gc/nrf.log` |
| One NF crashed inside CP | Process died, monitor should restart | `docker exec free5gc-cp ps aux \| grep -E "nrf\|amf\|smf"` to check; restart container if needed |
| Port conflict inside CP | Config using wrong port | Verify `config-consolidated/` files have unique ports per NF |
| Cannot `docker logs` a specific NF | All NFs share one container | Use `docker exec free5gc-cp cat /var/log/free5gc/{nf}.log` instead |

---

## Further Reading

- [01-5G-SA-FUNDAMENTALS.md](01-5G-SA-FUNDAMENTALS.md) - What is 5G SA? Components explained for beginners
- [03-TESTING-GUIDE.md](03-TESTING-GUIDE.md) - Detailed 9-test validation guide (designed for Full mode)
- [04-MANDATORY-COMPONENTS.md](04-MANDATORY-COMPONENTS.md) - Deep dive into each mandatory NF
- [05-RECOMMENDED-COMPONENTS.md](05-RECOMMENDED-COMPONENTS.md) - NSSF, PCF, WebUI details
- [06-ALL-COMPONENTS.md](06-ALL-COMPONENTS.md) - Complete NF documentation
- [07-CONSOLIDATED-DEPLOYMENT.md](07-CONSOLIDATED-DEPLOYMENT.md) - Detailed consolidated architecture
- [09-5G-PROCEDURES-AND-NF-ROLES.md](09-5G-PROCEDURES-AND-NF-ROLES.md) - Real-world 5G procedures and which NFs participate
