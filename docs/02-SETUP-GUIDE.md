# Step-by-Step Setup Guide

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Step 1: Install Docker](#step-1-install-docker)
3. [Step 2: Install GTP5G Kernel Module](#step-2-install-gtp5g-kernel-module)
4. [Step 3: Clone This Repository](#step-3-clone-this-repository)
5. [Step 4: Start All Services](#step-4-start-all-services)
6. [Step 5: Provision a Subscriber](#step-5-provision-a-subscriber)
7. [Step 6: Start UERANSIM UE](#step-6-start-ueransim-ue)
8. [Quick Start (Automated)](#quick-start-automated)
9. [Configuration Deep Dive](#configuration-deep-dive)
10. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 2 cores | 4+ cores |
| RAM | 4 GB | 8+ GB |
| Disk | 20 GB | 40+ GB |
| Network | 1 NIC | 1 NIC |

### Software Requirements

| Software | Version | Purpose |
|----------|---------|---------|
| Ubuntu | 22.04 LTS | Operating system |
| Kernel | 5.4+ | GTP5G module support |
| Docker | 20.10+ | Container runtime |
| Docker Compose | v2+ | Multi-container orchestration |
| Git | 2.x | Repository cloning |

### Check CPU AVX Support

MongoDB 4.4+ requires AVX instructions:
```bash
grep avx /proc/cpuinfo | head -1
# If this returns output, your CPU supports AVX
```

---

## Step 1: Install Docker

Docker is the container runtime that runs all free5GC network functions.

### What You're Installing

- **Docker Engine (docker-ce)**: The container runtime
- **Docker CLI (docker-ce-cli)**: Command-line tool
- **containerd.io**: Container lifecycle manager
- **Docker Compose plugin**: Multi-container orchestration (the `docker compose` command)

### Commands

```bash
# 1. Install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# 2. Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# 3. Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 4. Install Docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 5. Verify installation
docker --version        # Should show Docker version 24+
docker compose version  # Should show Docker Compose v2+
sudo systemctl is-active docker  # Should show "active"
```

### Expected Output
```
Docker version 29.2.1, build a5c7197
Docker Compose version v5.0.2
active
```

---

## Step 2: Install GTP5G Kernel Module

### Why Is This Needed?

The **GTP5G kernel module** is essential for the UPF (User Plane Function). In a 5G network, user data travels through GTP-U tunnels between the gNB and UPF. This kernel module enables Linux to process these GTP-U packets at kernel level, which is far more efficient than userspace processing.

Without it, the UPF container will fail to start or won't be able to forward any user traffic.

### Commands

```bash
# 1. Install kernel headers and build tools
sudo apt-get install -y linux-headers-$(uname -r) build-essential make gcc

# 2. Clone the gtp5g repository
cd /root
git clone https://github.com/free5gc/gtp5g.git

# 3. Build and install the module
cd gtp5g
make
sudo make install

# 4. Load the module
sudo modprobe gtp5g

# 5. Verify it's loaded
lsmod | grep gtp5g
```

### Expected Output
```
gtp5g                 135168  0
udp_tunnel             20480  1 gtp5g
```

### Make It Persistent Across Reboots

The `make install` step already creates `/etc/modules-load.d/gtp5g.conf` which auto-loads the module on boot. Verify:
```bash
cat /etc/modules-load.d/gtp5g.conf
# Should show:
# udp_tunnel
# gtp5g
```

---

## Step 3: Clone This Repository

```bash
cd /root
git clone https://github.com/Manikanta-Reddy-Pasala/free5gc-5G-SA-setup.git
cd free5gc-5G-SA-setup
```

### Repository Structure

```
free5gc-5G-SA-setup/
├── docker-compose.yaml          # Main compose file (all 16 services)
├── docker-compose-build.yaml    # Build from source
├── docker-compose-ulcl.yaml     # ULCL (multi-UPF) config
├── docker-compose-prometheus.yaml # Monitoring stack
├── setup-free5gc.sh             # Automated setup script
├── config/                      # Configuration files
│   ├── amfcfg.yaml              # AMF configuration
│   ├── smfcfg.yaml              # SMF configuration
│   ├── upfcfg.yaml              # UPF configuration
│   ├── gnbcfg.yaml              # UERANSIM gNB config
│   ├── uecfg.yaml               # UERANSIM UE config
│   └── ...                      # Other NF configs
├── cert/                        # TLS certificates
├── docs/                        # Documentation (you are here)
│   ├── 01-5G-SA-FUNDAMENTALS.md
│   ├── 02-SETUP-GUIDE.md
│   └── 03-TESTING-GUIDE.md
└── ueransim/                    # UERANSIM Dockerfile
```

---

## Step 4: Start All Services

### Pull and Start

```bash
cd /root/free5gc-5G-SA-setup

# Pull all pre-built images from Docker Hub
docker compose pull

# Start all 16 containers in background
docker compose up -d
```

### What Gets Started

The `docker compose up -d` command starts these containers in dependency order:

```
Phase 1 (no dependencies):
  ├── mongodb    (database)
  └── upf        (user plane - needs gtp5g)

Phase 2 (depends on mongodb):
  └── nrf        (service registry)

Phase 3 (depends on nrf):
  ├── amf        (access management)
  ├── smf        (session management, also needs upf)
  ├── ausf       (authentication)
  ├── udm        (data management)
  ├── udr        (data repository, also needs mongodb)
  ├── nssf       (slice selection)
  ├── pcf        (policy control)
  ├── nef        (network exposure)
  └── webui      (admin console)

Phase 4 (depends on amf, smf, upf):
  ├── ueransim   (gNB simulator)
  ├── n3iwf      (non-3GPP interworking)
  └── tngf       (trusted non-3GPP gateway)

Phase 5 (depends on n3iwf):
  └── n3iwue     (non-3GPP UE)

Phase 6 (depends on webui):
  └── chf        (charging)
```

### Wait and Verify

```bash
# Wait 25 seconds for all services to initialize
sleep 25

# Check all containers are running
docker compose ps
```

### Expected Output

All 16 containers should show "Up":
```
NAME       STATUS
amf        Up 30 seconds
ausf       Up 30 seconds
chf        Up 28 seconds
mongodb    Up 31 seconds
n3iwf      Up 28 seconds
n3iwue     Up 27 seconds
nef        Up 30 seconds
nrf        Up 30 seconds
nssf       Up 29 seconds
pcf        Up 29 seconds
smf        Up 29 seconds
udm        Up 29 seconds
udr        Up 30 seconds
ueransim   Up 28 seconds
upf        Up 31 seconds
webui      Up 29 seconds
```

### Verify gNB Connection

Check that the UERANSIM gNB has successfully connected to the AMF:

```bash
docker logs ueransim 2>&1 | tail -5
```

Expected:
```
[ngap] [info] NG Setup procedure is successful
```

---

## Step 5: Provision a Subscriber

### Why Is This Needed?

In a real 5G network, every SIM card is registered in the network's subscriber database. The UE cannot authenticate without its credentials (K, OPC) being stored in the UDM/UDR.

UERANSIM simulates a UE with pre-configured credentials (in `config/uecfg.yaml`). We need to add matching credentials to free5GC's database.

### Method 1: Using the Setup Script (Recommended)

```bash
./setup-free5gc.sh test
```

This automatically provisions the subscriber and runs all tests.

### Method 2: Using the WebUI (Manual/Visual)

1. Open browser: `http://<server-ip>:5000`
2. Login: `admin` / `free5gc`
3. Click "Subscribers" -> "New Subscriber"
4. Fill in:
   - SUPI: `208930000000001`
   - K: `8baf473f2f8fd09487cccbd7097c6862`
   - OPC: `8e27b6af0e692e750f32667a3b14605d`
   - AMF: `8000`
5. Click "Submit"

### Method 3: Using the API (Programmable)

```bash
# Login
TOKEN=$(curl -s -X POST http://localhost:5000/api/login \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"free5gc"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

# Create subscriber
curl -X POST "http://localhost:5000/api/subscriber/imsi-208930000000001/20893" \
    -H "Content-Type: application/json" \
    -H "Token: $TOKEN" \
    -d '<subscriber JSON - see setup script for full payload>'
```

### CRITICAL: Fix Sequence Number (SQN)

After creating the subscriber, you **must** set the SQN to a small value. UERANSIM starts with SQN=0, but the default SQN (`16f3b3f70fc2`) is far too large, causing authentication failure.

```bash
docker exec mongodb mongo --quiet --eval '
    db = db.getSiblingDB("free5gc");
    db.subscriptionData.authenticationData.authenticationSubscription.updateOne(
        {"ueId": "imsi-208930000000001"},
        {$set: {"sequenceNumber": {"sqnScheme": "GENERAL", "sqn": "000000000020"}}}
    );
    print("SQN fixed");
'
```

### Understanding the Subscriber Parameters

| Parameter | Value | Explanation |
|-----------|-------|-------------|
| SUPI/IMSI | 208930000000001 | Unique subscriber ID: MCC(208) + MNC(93) + MSIN(0000000001) |
| K | 8baf473f2f8fd09487cccbd7097c6862 | 128-bit permanent secret key (shared between SIM and network) |
| OPC | 8e27b6af0e692e750f32667a3b14605d | Operator-specific constant derived from OP and K |
| AMF | 8000 | Authentication Management Field (0x8000 = normal operation) |
| SQN | 000000000020 | Sequence number for replay attack prevention |
| SST/SD | 1/010203, 1/112233 | Network slices the subscriber can use |
| DNN | internet | Data network name (like an APN) |
| Session AMBR | 200 Mbps up / 100 Mbps down | Maximum aggregated data rate |
| 5QI | 9 | QoS class (9 = best effort, suitable for web browsing) |

---

## Step 6: Start UERANSIM UE

### Restart gNB (Clean State)

```bash
docker compose restart ueransim
sleep 8
```

### Start UE Simulator

```bash
# Start UE in background
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml

# Wait for registration
sleep 15
```

### What Happens During UE Startup

1. **PLMN Search**: UE scans for available networks, finds PLMN 208/93
2. **Cell Selection**: UE selects a suitable cell from gNB
3. **Registration**: UE sends Registration Request to AMF via gNB
4. **Authentication**: 5G-AKA procedure (RAND/AUTN exchange)
5. **Security Mode**: NAS encryption activated
6. **Registration Complete**: UE is now on the network
7. **PDU Session 1**: Established for slice 1/010203 -> IP 10.60.0.1
8. **PDU Session 2**: Established for slice 1/112233 -> IP 10.61.0.1

### Verify Registration

```bash
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
```

Expected output:
```
cm-state: CM-CONNECTED
rm-state: RM-REGISTERED
mm-state: MM-REGISTERED/NORMAL-SERVICE
```

---

## Quick Start (Automated)

Copy the setup script to your server and run:

```bash
scp setup-free5gc.sh root@<your-server>:/root/
ssh root@<your-server>
chmod +x /root/setup-free5gc.sh
/root/setup-free5gc.sh install
```

This single command does everything: installs Docker, builds GTP5G, clones the repo, starts services, provisions a subscriber, starts the UE, and runs connectivity tests.

---

## Configuration Deep Dive

### Key Config Files

#### config/amfcfg.yaml - AMF Configuration
```yaml
# PLMN identity - must match UERANSIM and subscriber
plmnId:
  mcc: 208   # Mobile Country Code (France, used for testing)
  mnc: 93    # Mobile Network Code (test network)

# Supported network slices
snssaiList:
  - sst: 1           # Slice type (1 = eMBB)
    sd: 010203        # Slice differentiator
  - sst: 1
    sd: 112233

# NGAP listening address for gNB connections
ngapIpList:
  - amf.free5gc.org   # Resolved via Docker DNS
ngapPort: 38412        # SCTP port
```

#### config/smfcfg.yaml - SMF Configuration
```yaml
# UE IP address pools
userplaneInformation:
  upNodes:
    UPF:
      type: UPF
      nodeID: upf.free5gc.org
      sNssaiUpfInfos:
        - sNssai:
            sst: 1
            sd: 010203
          dnnUpfInfoList:
            - dnn: internet
              pools:
                - cidr: 10.60.0.0/16    # IP pool for slice 1
        - sNssai:
            sst: 1
            sd: 112233
          dnnUpfInfoList:
            - dnn: internet
              pools:
                - cidr: 10.61.0.0/16    # IP pool for slice 2
```

#### config/gnbcfg.yaml - gNB Configuration
```yaml
mcc: "208"           # Must match AMF
mnc: "93"            # Must match AMF
tac: 1               # Tracking Area Code

# AMF connection
amfConfigs:
  - address: amf.free5gc.org
    port: 38412       # NGAP/SCTP

# Supported slices - must match AMF config
slices:
  - sst: 0x1
    sd: 0x010203
  - sst: 0x1
    sd: 0x112233
```

#### config/uecfg.yaml - UE Configuration
```yaml
supi: "imsi-208930000000001"  # Must match subscriber in DB
mcc: "208"
mnc: "93"

# Authentication keys - MUST match subscriber DB exactly
key: "8baf473f2f8fd09487cccbd7097c6862"
op: "8e27b6af0e692e750f32667a3b14605d"
opType: "OPC"          # This is OPC (not raw OP)
amf: "8000"

# PDU sessions to establish automatically
sessions:
  - type: "IPv4"
    apn: "internet"
    slice:
      sst: 0x01
      sd: 0x010203
  - type: "IPv4"
    apn: "internet"
    slice:
      sst: 0x01
      sd: 0x112233
```

### Docker Network Configuration

```yaml
networks:
  privnet:
    ipam:
      config:
        - subnet: 10.100.200.0/24    # Internal Docker network
    driver_opts:
      com.docker.network.bridge.name: br-free5gc
```

| Container | IP Assignment |
|-----------|---------------|
| AMF | 10.100.200.16 (fixed) |
| N3IWF | 10.100.200.15 (fixed) |
| N3IWUE | 10.100.200.203 (fixed) |
| Others | DHCP from 10.100.200.0/24 |

---

## Troubleshooting

### Container Won't Start

```bash
# Check which container failed
docker compose ps

# View container logs
docker logs <container-name> 2>&1 | tail -30

# Common issues:
# - UPF fails: gtp5g module not loaded -> modprobe gtp5g
# - NRF fails: MongoDB not ready -> restart NRF
# - Any NF fails with "connection refused": NRF not ready -> wait longer
```

### Authentication Failure

**Symptom**: UE stuck in `MM-REGISTER-INITIATED`

**Diagnosis**:
```bash
# Check AMF logs
docker logs amf 2>&1 | grep -E "ERRO|Auth" | tail -10

# Check UDM logs
docker logs udm 2>&1 | grep -E "ERRO|Sync|MAC" | tail -10
```

**Common causes**:

1. **No subscriber in DB** -> Create subscriber (Step 5)
2. **SQN too large** -> Reset SQN to `000000000020` (Step 5)
3. **Key mismatch** -> Verify K/OPC in `config/uecfg.yaml` matches subscriber DB
4. **PLMN mismatch** -> Verify MCC/MNC is 208/93 in all configs

### UE Registered But No Internet

**Symptom**: UE registered but `ping` fails through uesimtun0

```bash
# Check if TUN interfaces exist
docker exec ueransim ip addr show | grep uesimtun

# Check UPF routing
docker exec upf ip route

# Check if NAT is working
docker exec upf iptables -t nat -L
```

### View All Logs at Once

```bash
docker compose logs --tail 20 2>&1 | less
```

### Reset Everything

```bash
# Stop all containers and remove volumes (fresh start)
docker compose down -v

# Then start again from Step 4
docker compose up -d
```

---

Next: [03-TESTING-GUIDE.md](03-TESTING-GUIDE.md) - Detailed testing procedures
