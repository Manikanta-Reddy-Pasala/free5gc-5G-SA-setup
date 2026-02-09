# Testing Guide - Verifying Your 5G SA Network

## Table of Contents

1. [Test Overview](#test-overview)
2. [Test 1: Container Health](#test-1-container-health)
3. [Test 2: NF Registration with NRF](#test-2-nf-registration-with-nrf)
4. [Test 3: gNB to AMF Connection (N2)](#test-3-gnb-to-amf-connection-n2)
5. [Test 4: UE Registration](#test-4-ue-registration)
6. [Test 5: PDU Session Establishment](#test-5-pdu-session-establishment)
7. [Test 6: End-to-End Data Connectivity](#test-6-end-to-end-data-connectivity)
8. [Test 7: Network Slice Verification](#test-7-network-slice-verification)
9. [Test 8: WebUI Access](#test-8-webui-access)
10. [Test 9: UE Deregistration and Re-registration](#test-9-ue-deregistration-and-re-registration)
11. [Interpreting Logs](#interpreting-logs)
12. [What Each Test Proves](#what-each-test-proves)

---

## Test Overview

These tests verify the entire 5G SA network stack, from bottom to top:

```
Test 1: Infrastructure  ────> Are all containers running?
Test 2: Service Mesh    ────> Can NFs find each other via NRF?
Test 3: RAN Connection  ────> Is the gNB connected to the core?
Test 4: Registration    ────> Can a UE authenticate and register?
Test 5: Session Setup   ────> Can the UE get an IP address?
Test 6: Data Plane      ────> Can the UE reach the internet?
Test 7: Slicing         ────> Are both network slices working?
Test 8: Management      ────> Is the admin console accessible?
Test 9: Mobility        ────> Can the UE re-register after disconnect?
```

---

## Test 1: Container Health

### Command
```bash
docker compose ps
```

### What It Tests
Verifies all 16 containers are running and haven't crashed.

### Expected Result
All containers show "Up" status:
```
NAME       STATUS
amf        Up X minutes
ausf       Up X minutes
chf        Up X minutes
mongodb    Up X minutes
n3iwf      Up X minutes
n3iwue     Up X minutes
nef        Up X minutes
nrf        Up X minutes
nssf       Up X minutes
pcf        Up X minutes
smf        Up X minutes
udm        Up X minutes
udr        Up X minutes
ueransim   Up X minutes
upf        Up X minutes
webui      Up X minutes
```

### What Goes Wrong
- **UPF not starting**: GTP5G kernel module not loaded
  ```bash
  # Fix:
  sudo modprobe gtp5g
  docker compose restart free5gc-upf
  ```
- **NFs restarting in loop**: NRF or MongoDB not ready. Wait 30 seconds and re-check.

---

## Test 2: NF Registration with NRF

### Command
```bash
# Check NRF for registered NFs
docker logs nrf 2>&1 | grep "Handle NFRegisterRequest" | wc -l
```

### What It Tests
Verifies that all Network Functions have registered with the NRF (service discovery). This is essential for NFs to find and communicate with each other.

### Expected Result
You should see 10+ registration entries (one for each NF that registers):
```bash
docker logs nrf 2>&1 | grep "Handle NFRegisterRequest"
```
Output shows registrations from AMF, SMF, AUSF, UDM, UDR, PCF, NSSF, CHF, NEF, N3IWF, TNGF.

### What This Proves
The **Service-Based Architecture (SBA)** is working. NFs can discover each other through the NRF, which is the foundation for all inter-NF communication.

---

## Test 3: gNB to AMF Connection (N2)

### Command
```bash
docker logs ueransim 2>&1 | grep "NG Setup"
```

### What It Tests
Verifies that the UERANSIM gNB has established an SCTP connection to the AMF on the N2 interface and completed the NG Setup procedure.

### Expected Result
```
[ngap] [debug] Sending NG Setup Request
[ngap] [debug] NG Setup Response received
[ngap] [info] NG Setup procedure is successful
```

### AMF Side Verification
```bash
docker logs amf 2>&1 | grep "NG Setup"
```
Expected:
```
[AMF][Ngap] Handle NGSetupRequest
[AMF][Ngap] Send NG-Setup response
```

### What This Proves
- **SCTP transport** between gNB and AMF is working (N2 interface)
- **NGAP protocol** is functioning correctly
- The AMF accepts the gNB's PLMN (208/93) and TAC (1)
- The gNB is now ready to forward UE messages to the core

### What Goes Wrong
- **"SCTP connection failed"**: AMF not reachable. Check AMF container is running.
- **"NG Setup Failure"**: PLMN mismatch. Verify MCC/MNC in `gnbcfg.yaml` matches `amfcfg.yaml`.

---

## Test 4: UE Registration

### Commands
```bash
# Start UE (if not already running)
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
sleep 15

# Check registration status
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
```

### What It Tests
Verifies the complete UE registration flow:
1. NAS Registration Request
2. 5G-AKA Authentication (RAND/AUTN/RES* exchange)
3. NAS Security Mode (encryption activation)
4. Registration Accept

### Expected Result
```
cm-state: CM-CONNECTED            # Connected to gNB
rm-state: RM-REGISTERED           # Registered with core network
mm-state: MM-REGISTERED/NORMAL-SERVICE  # Full service
5u-state: 5U1-UPDATED
sim-inserted: true
selected-plmn: 208/93             # Correct PLMN
current-cell: 1
current-plmn: 208/93
current-tac: 1
last-tai: PLMN[208/93] TAC[1]
stored-guti:                      # Temporary ID assigned
  plmn: 208/93
  amf-region-id: 0xca
  amf-set-id: 1016
  amf-pointer: 0
  tmsi: 0x0000000f
```

### Key Fields Explained

| Field | Value | Meaning |
|-------|-------|---------|
| cm-state | CM-CONNECTED | RRC connection to gNB is active |
| rm-state | RM-REGISTERED | UE is registered with the 5G core |
| mm-state | MM-REGISTERED/NORMAL-SERVICE | Full service available |
| selected-plmn | 208/93 | Connected to the right network |
| stored-guti | (has values) | AMF assigned a temporary ID |

### What This Proves
- **Authentication (AUSF/UDM)**: The network verified the UE's identity using 5G-AKA
- **Subscriber Database (UDR)**: The UE's K/OPC credentials were found and matched
- **Security (AMF)**: NAS encryption and integrity protection established
- **Identity Management (UDM)**: SUCI resolved to SUPI, GUTI assigned

### What Goes Wrong

| Symptom | Cause | Fix |
|---------|-------|-----|
| `rm-state: RM-DEREGISTERED` | Auth failed | Check subscriber exists, fix SQN |
| `mm-state: MM-REGISTER-INITIATED` | Auth in progress or failed | Wait 15s, then check AMF logs |
| `"SQN out of range"` in UE logs | SQN too large | Set SQN to `000000000020` |
| `"Re-Sync MAC failed"` in UDM logs | K/OPC mismatch | Verify keys match between uecfg.yaml and DB |

---

## Test 5: PDU Session Establishment

### Command
```bash
docker exec ueransim ./nr-cli imsi-208930000000001 -e "ps-list"
```

### What It Tests
Verifies that the UE can establish PDU sessions (data connections) with the network. This tests the SMF, UPF, and PCF working together.

### Expected Result
```
PDU Session1:
 state: PS-ACTIVE
 session-type: IPv4
 apn: internet
 s-nssai:
  sst: 0x01
  sd: 0x010203
 emergency: false
 address: 10.60.0.1              # IP from pool 1
 ambr: up[200Mb/s] down[100Mb/s] # Rate limits applied
 data-pending: false

PDU Session2:
 state: PS-ACTIVE
 session-type: IPv4
 apn: internet
 s-nssai:
  sst: 0x01
  sd: 0x112233
 emergency: false
 address: 10.61.0.1              # IP from pool 2
 ambr: up[200Mb/s] down[100Mb/s]
 data-pending: false
```

### TUN Interface Verification
```bash
docker exec ueransim ip addr show | grep -A2 uesimtun
```
Expected:
```
3: uesimtun0: <POINTOPOINT,UP,LOWER_UP> mtu 1400
    inet 10.60.0.1/16 scope global uesimtun0
4: uesimtun1: <POINTOPOINT,UP,LOWER_UP> mtu 1400
    inet 10.61.0.1/16 scope global uesimtun1
```

### What This Proves
- **SMF**: Successfully processed PDU Session Establishment Request
- **PCF**: Applied QoS policy (200/100 Mbps AMBR)
- **UPF**: PFCP session created, GTP-U tunnel established
- **IP Allocation**: SMF allocated IPs from the correct pools (10.60.x.x and 10.61.x.x)
- **Network Slicing**: Two separate sessions on two different slices

---

## Test 6: End-to-End Data Connectivity

### Command
```bash
# Ping through PDU Session 1 (slice 010203)
docker exec ueransim ping -I uesimtun0 -c 5 8.8.8.8

# Ping through PDU Session 2 (slice 112233)
docker exec ueransim ping -I uesimtun1 -c 5 8.8.8.8
```

### What It Tests
This is the **most important test**. It verifies end-to-end data flow:

```
UE (10.60.0.1)
  │
  ▼ TUN interface (uesimtun0)
UERANSIM UE process
  │
  ▼ GTP-U encapsulation
UERANSIM gNB
  │
  ▼ N3 (GTP-U over UDP:2152)
UPF (gtp5g kernel module)
  │
  ▼ Decapsulate, NAT, forward
Internet (8.8.8.8)
  │
  ▼ Response travels back
UE receives ICMP reply
```

### Expected Result
```
PING 8.8.8.8 (8.8.8.8) from 10.60.0.1 uesimtun0: 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=113 time=4.24 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=113 time=3.71 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=113 time=3.07 ms
64 bytes from 8.8.8.8: icmp_seq=4 ttl=113 time=3.42 ms
64 bytes from 8.8.8.8: icmp_seq=5 ttl=113 time=3.55 ms

--- 8.8.8.8 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4006ms
rtt min/avg/max/mdev = 3.067/3.598/4.235/0.377 ms
```

### What This Proves
- **Complete User Plane**: Data flows from UE through gNB, GTP-U tunnel, UPF to internet
- **GTP5G Kernel Module**: Packet encapsulation/decapsulation working
- **UPF Routing/NAT**: UPF correctly NATs internal IPs to external
- **Both directions**: Request (uplink) and response (downlink) paths work

### Extended Data Test (DNS + HTTP)
```bash
# DNS resolution test
docker exec ueransim sh -c "nslookup google.com 2>&1" || echo "nslookup not available"

# HTTP test (if curl available)
docker exec ueransim sh -c "wget -qO- http://ifconfig.me 2>&1" || echo "wget not available"
```

---

## Test 7: Network Slice Verification

### Command
```bash
# Check PDU sessions for slice info
docker exec ueransim ./nr-cli imsi-208930000000001 -e "ps-list"
```

### What It Tests
Verifies that two independent PDU sessions are established on different network slices, each with its own IP address pool.

### Expected Result
- **Session 1**: SST=1, SD=010203, IP from 10.60.0.0/16
- **Session 2**: SST=1, SD=112233, IP from 10.61.0.0/16

### How Slicing Works in This Setup

```
UERANSIM UE
  ├── PDU Session 1 (uesimtun0) ──> SMF selects slice 1/010203
  │   └── IP: 10.60.0.1 from UPF pool for slice 010203
  │
  └── PDU Session 2 (uesimtun1) ──> SMF selects slice 1/112233
      └── IP: 10.61.0.1 from UPF pool for slice 112233
```

Both sessions go through the same UPF but get different IP pools, demonstrating basic network slicing.

---

## Test 8: WebUI Access

### Command
```bash
# From the server itself
curl -s http://localhost:5000/api/subscriber | python3 -c "
import sys, json
subs = json.load(sys.stdin)
for s in subs:
    print(f'IMSI: {s.get(\"ueId\", \"unknown\")}')
"
```

### From Your Browser
Navigate to: `http://<server-ip>:5000`
- Username: `admin`
- Password: `free5gc`

### What It Tests
- WebUI container is accessible
- MongoDB connection from WebUI works
- Subscriber management is functional

---

## Test 9: UE Deregistration and Re-registration

### Commands
```bash
# Deregister UE
docker exec ueransim ./nr-cli imsi-208930000000001 -e "deregister normal"
sleep 5

# Check status - should be deregistered
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"

# Re-register
docker exec ueransim ./nr-cli imsi-208930000000001 -e "register"
sleep 10

# Check status - should be registered again
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
```

### What It Tests
- UE can cleanly deregister from the network
- Network properly cleans up resources (PDU sessions, contexts)
- UE can re-register without issues (no stale state)

---

## Interpreting Logs

### AMF Logs - What to Look For

```bash
docker logs amf 2>&1 | tail -50
```

| Log Message | Meaning |
|-------------|---------|
| `SCTP Accept from: X.X.X.X` | gNB connected |
| `Handle NGSetupRequest` | gNB NG Setup |
| `Handle Registration Request` | UE starting registration |
| `Authentication procedure` | Auth started |
| `Authentication Failure: Synch Failure` | SQN mismatch (fix SQN) |
| `Send Security Mode Command` | Auth succeeded, activating encryption |
| `Registration Accept` | UE successfully registered |
| `Handle PDUSessionResourceSetupResponse` | PDU session ready |

### SMF Logs

```bash
docker logs smf 2>&1 | tail -30
```

| Log Message | Meaning |
|-------------|---------|
| `Receive Create SM Context Request` | New PDU session request |
| `Allocated UE IP address` | IP assigned from pool |
| `PFCP Association Setup Response` | Connected to UPF |
| `Sending PFCP Session Establishment` | Setting up UPF rules |

### UPF Logs

```bash
docker logs upf 2>&1 | tail -20
```

| Log Message | Meaning |
|-------------|---------|
| `starting Gtpu Forwarder [gtp5g]` | GTP5G module loaded |
| `pfcp server started` | Listening for SMF commands |
| `handleAssociationSetupRequest` | SMF connected |

---

## What Each Test Proves

```
┌─────────────────────────────────────────────────────────────┐
│                    5G SA Test Coverage                        │
│                                                              │
│  Test 1 (Containers)     ─── Infrastructure Layer ✓         │
│  Test 2 (NRF)            ─── Service Discovery ✓            │
│  Test 3 (gNB-AMF)        ─── N2 Interface (NGAP/SCTP) ✓    │
│  Test 4 (Registration)   ─── Control Plane ✓                │
│     └── Auth (AUSF/UDM)  ─── 5G-AKA Protocol ✓             │
│     └── Security (AMF)   ─── NAS Encryption ✓               │
│  Test 5 (PDU Session)    ─── Session Management ✓           │
│     └── IP Allocation    ─── SMF/UPF Integration ✓          │
│     └── QoS Policy       ─── PCF Integration ✓              │
│  Test 6 (Ping)           ─── User Plane (N3/N6) ✓          │
│     └── GTP-U Tunnel     ─── gNB-UPF Data Path ✓           │
│     └── NAT/Routing      ─── UPF Internet Access ✓         │
│  Test 7 (Slicing)        ─── Network Slicing ✓             │
│  Test 8 (WebUI)          ─── Management Plane ✓            │
│  Test 9 (Re-registration)─── Mobility/State Management ✓   │
└─────────────────────────────────────────────────────────────┘
```

If all 9 tests pass, you have a **fully functional 5G SA core network** with:
- Working control plane (registration, authentication, session management)
- Working user plane (GTP-U tunneling, internet access)
- Working network slicing (two independent slices)
- Working management plane (WebUI subscriber management)
