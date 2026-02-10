# 5G SA Core Network Setup with free5GC & UERANSIM

A complete, beginner-friendly setup of a **5G Standalone (SA) core network** using [free5GC](https://github.com/free5gc/free5gc) v4.2.0 with [UERANSIM](https://github.com/aligungr/UERANSIM) v3.2.7 for RAN/UE simulation, all running via Docker Compose.

> **New to 5G?** Start with the [5G SA Fundamentals Guide](docs/01-5G-SA-FUNDAMENTALS.md) - it explains every component with real-world analogies.

## What's Inside

```
Your Phone (UE)          5G Base Station (gNB)        5G Core Network
┌───────────┐           ┌───────────────┐          ┌──────────────────────┐
│ UERANSIM  │──(radio)──│  UERANSIM     │──(N2)──> │ AMF  AUSF  UDM  UDR │
│ UE        │           │  gNB          │──(N3)──> │ SMF  PCF   NRF  NSSF│
└───────────┘           └───────────────┘          │ UPF  CHF   NEF  ... │
                                                   └──────────┬───────────┘
                                                              │ (N6)
                                                         ┌────┴────┐
                                                         │ Internet │
                                                         └─────────┘
```

**As few as 4 containers** (or up to 16) running a complete 5G SA network with 2 network slices, subscriber management, and internet connectivity. Choose the install mode that fits your use case.

## Quick Start

Only needs Docker - no Go, GCC, or CMake on host. Works on Mac (Apple Silicon/Intel), Linux, or any OS.

```bash
git clone https://github.com/Manikanta-Reddy-Pasala/free5gc-5G-SA-setup.git
cd free5gc-5G-SA-setup
./free5gc.sh build            # Compile all NFs from source (~15 min first time)
./free5gc.sh start            # Start containers + provision subscriber
./free5gc.sh test             # 1 UE registration + trace (shows NF-to-NF flow)
```

Auto-detects mode: Linux with gtp5g kernel module runs full mode (4 containers including UPF), otherwise CP-only mode (3 containers, Mac compatible).

### All Commands

```bash
./free5gc.sh build                # Compile all NFs from source (~15 min)
./free5gc.sh build --quick        # Rebuild runtime images only (skip source compile)
./free5gc.sh start                # Start containers + provision subscriber
./free5gc.sh test                 # 1 UE registration + full NF flow trace
./free5gc.sh test full            # 16 attach + 200 reject + 100 identify + trace
./free5gc.sh stop                 # Stop and remove all containers
./free5gc.sh status               # Show container status
./free5gc.sh logs [nf]            # Tail logs (all or specific NF like amf, smf)
```

See the full guide: [docs/10-PORTABLE-BUILD-AND-TRACE.md](docs/10-PORTABLE-BUILD-AND-TRACE.md)

### Manual Setup

Follow the step-by-step guide: [docs/02-SETUP-GUIDE.md](docs/02-SETUP-GUIDE.md)

## Test Results

After setup, you get a fully working 5G network:

```
UE Registration:  RM-REGISTERED (authenticated via 5G-AKA)
PDU Session 1:    10.60.0.1 (Slice SST=1, SD=010203) - 200/100 Mbps
PDU Session 2:    10.61.0.1 (Slice SST=1, SD=112233) - 200/100 Mbps
Internet Access:  Ping 8.8.8.8 via uesimtun0 - 0% loss, ~4ms RTT
```

## Documentation

| Document | Description | Audience |
|----------|-------------|----------|
| [5G SA Fundamentals](docs/01-5G-SA-FUNDAMENTALS.md) | What is 5G SA? Every component explained with diagrams | Beginners |
| [Setup Guide](docs/02-SETUP-GUIDE.md) | Step-by-step installation with explanations | DevOps / Lab setup |
| [Testing Guide](docs/03-TESTING-GUIDE.md) | 9 tests to verify your network, with log interpretation | Testing / Validation |
| [Mandatory Components](docs/04-MANDATORY-COMPONENTS.md) | Deep dive into each mandatory NF | Intermediate |
| [Recommended Components](docs/05-RECOMMENDED-COMPONENTS.md) | NSSF, PCF, WebUI details | Intermediate |
| [All Components](docs/06-ALL-COMPONENTS.md) | Complete NF documentation | Reference |
| [Consolidated Deployment](docs/07-CONSOLIDATED-DEPLOYMENT.md) | 4-container deployment architecture | DevOps / Edge |
| [Deployment Modes Guide](docs/08-DEPLOYMENT-MODES-GUIDE.md) | Full vs Mandatory vs Consolidated: comparison, deploy, and test | All levels |
| [5G Procedures & NF Roles](docs/09-5G-PROCEDURES-AND-NF-ROLES.md) | Real-world 5G procedures: Attach, Auth, PDU Session, Paging, and more | Intermediate / Advanced |
| [Portable Build & Trace](docs/10-PORTABLE-BUILD-AND-TRACE.md) | Build from source, run modes, UE simulation, data flow tracing | All levels |

---

## Mandatory vs Optional Components

Not every container is required to run a working 5G SA core. Here is a breakdown of what is **mandatory** (3GPP standard core), what is **recommended**, and what is **optional** (simulators, extras).

### Mandatory - 3GPP Core Network (Minimum Viable 5G Core)

These are the **minimum containers needed** to run a functional 5G SA core network per 3GPP TS 23.501. Without any of these, a UE cannot register or get internet access.

| Container | NF | Why It's Mandatory | 3GPP Reference |
|-----------|----|--------------------|----------------|
| `amf` | Access & Mobility Management | The single entry point for all UE signaling. No registration, no authentication, no mobility without AMF. | TS 23.502 |
| `smf` | Session Management | Creates PDU sessions (data pipes). Without SMF, a UE registers but cannot send/receive data. | TS 23.502 |
| `upf` | User Plane Function | The actual data router. All user traffic (web, video, etc.) flows through UPF. Needs GTP5G kernel module. | TS 29.244 |
| `nrf` | NF Repository Function | Service registry where all NFs find each other. Without NRF, AMF cannot find SMF, SMF cannot find UPF, etc. | TS 29.510 |
| `ausf` | Authentication Server | Executes 5G-AKA authentication. Without AUSF, no UE can prove its identity. | TS 33.501 |
| `udm` | Unified Data Management | Computes authentication vectors (RAND, AUTN, XRES*) from subscriber keys. Also manages subscription data. | TS 29.503 |
| `udr` | Unified Data Repository | Database backend that stores subscriber profiles, auth keys, and subscription data. UDM reads from UDR. | TS 29.504 |
| `mongodb` | Database | The actual persistent storage behind UDR. Stores all subscriber records, NF profiles, policy data. | (Implementation) |

**Minimum viable command:**
```bash
./free5gc.sh build   # Build from source (~15 min first time)
./free5gc.sh start   # Start CP + MongoDB + UERANSIM (auto-detects mode)
./free5gc.sh test    # Register 1 UE with full NF-to-NF trace
```

### Recommended - Important but Survivable Without

These significantly enhance your 5G network but are not strictly required for basic UE registration + data.

| Container | NF | What Happens Without It | When You Need It |
|-----------|----|-----------------------|-----------------|
| `nssf` | Network Slice Selection | AMF uses its own built-in slice selection logic. Works fine with 1-2 slices. | When you have multiple slices and need complex selection rules |
| `pcf` | Policy Control | Default QoS policies apply. No dynamic policy changes, no per-session bandwidth control. | When you need per-user/per-session QoS, bandwidth limits, or policy rules |
| `webui` | Web Console | You must manage subscribers via MongoDB shell commands instead of a web UI. | Always recommended - makes subscriber management easy |

### Optional - Simulators & Extras (Not Part of 3GPP Core)

These are **not 3GPP core network functions**. They are tools, simulators, or specialized gateways.

| Container | What It Is | Why It's Optional | When You Need It |
|-----------|-----------|-------------------|-----------------|
| `ueransim` | gNB + UE Simulator | **Test equipment, not a real network component.** Remove this entirely when connecting a real gNB. | Lab testing only. Replace with real gNB + real UE in production. |
| `n3iwf` | Non-3GPP Interworking | Only needed for Wi-Fi/untrusted access to 5G core via IPSec. Not needed for normal 3GPP (gNB) access. | When Wi-Fi devices need to access your 5G core |
| `tngf` | Trusted Non-3GPP Gateway | Similar to N3IWF but for trusted corporate Wi-Fi. Runs on host network. | When trusted Wi-Fi networks need 5G core access |
| `n3iwue` | Non-3GPP UE Simulator | Test UE for N3IWF. Only used to test Wi-Fi access scenarios. | Testing N3IWF connectivity only |
| `chf` | Charging Function | Billing/usage tracking. Not needed for basic connectivity. UEs connect fine without billing. | When you need usage metering or billing |
| `nef` | Network Exposure | API gateway for 3rd-party apps. No UE-facing function. | When external apps need to interact with the 5G core |

### Visual: What to Run for Each Use Case

```
INSTALL MODE: minimal (4 containers) - ./free5gc.sh start  [DEFAULT]
┌──────────────────────────────────────────────┐
│  mongodb                                     │  Database
│  free5gc-cp (NRF+AMF+AUSF+UDM+UDR+          │  All 8 NFs in 1 container
│              SMF+NSSF+PCF)                   │
│  upf                                         │  User plane (needs GTP5G)
│  ueransim                                    │  gNB + UE simulator
└──────────────────────────────────────────────┘
  Fastest startup, lowest resources
  No WebUI - subscriber provisioned via MongoDB

INSTALL MODE: consolidated (12 containers) - docker compose -f docker-compose-consolidated.yaml up -d
┌──────────────────────────────────────────────┐
│  mongodb → udr → udm → ausf                 │  Authentication chain
│  nrf                                         │  Service discovery
│  amf ← smf → upf                            │  Registration + Data
│  nssf, pcf                                   │  Slice selection + Policy
│  webui                                       │  Browser-based management
│  ueransim                                    │  gNB + UE simulator
└──────────────────────────────────────────────┘

INSTALL MODE: full (16 containers) - docker compose -f docker-compose.yaml up -d
  = consolidated + chf, n3iwf, tngf, nef, n3iwue

PRODUCTION: Real gNB (no UERANSIM)
  Use minimal or consolidated mode, remove ueransim, connect real gNB via N2/N3
```

---

## Container Configuration Deep Dive

Every container mounts a YAML config file from the `config/` directory. Here is exactly what each config controls and its key settings.

### Configuration File Map

| Container | Config File | Key Settings |
|-----------|------------|--------------|
| `amf` | `config/amfcfg.yaml` | PLMN (208/93), NGAP listen address, supported slices, security algorithms, NRF URI |
| `smf` | `config/smfcfg.yaml` | UE IP pools per slice, UPF address (N4/PFCP), DNS servers, DNN configuration |
| `upf` | `config/upfcfg.yaml` | GTP-U listen address, PFCP listen address, DNN routing, IP pool allocation |
| `nrf` | `config/nrfcfg.yaml` | MongoDB URI, SBI listen address, PLMN ID, default service URIs |
| `ausf` | `config/ausfcfg.yaml` | Supported PLMNs, group ID, NRF URI |
| `udm` | `config/udmcfg.yaml` | SUCI decryption keys (profiles A/B), NRF URI, supported services |
| `udr` | `config/udrcfg.yaml` | MongoDB URI (`mongodb://db:27017/free5gc`), NRF URI |
| `nssf` | `config/nssfcfg.yaml` | Slice-to-NSI mapping, AMF set info, supported S-NSSAIs |
| `pcf` | `config/pcfcfg.yaml` | MongoDB URI, policy services list, NRF URI |
| `chf` | `config/chfcfg.yaml` | MongoDB URI, CGF/billing server config, Diameter ports, quota limits |
| `nef` | `config/nefcfg.yaml` | MongoDB URI, PFD management service, NRF URI |
| `n3iwf` | `config/n3iwfcfg.yaml` | IKE bind address, IPSec tunnel config, AMF SCTP address, UE IP pool |
| `tngf` | `config/tngfcfg.yaml` | IKE/Radius bind (host network), AMF direct IP, IPSec tunnel config |
| `webui` | `config/webuicfg.yaml` | MongoDB URI, web server port (5000), billing server config |
| `ueransim` gNB | `config/gnbcfg.yaml` | MCC/MNC, gNB ID, TAC, AMF SCTP address, N3 GTP address, supported slices |
| `ueransim` UE | `config/uecfg.yaml` | IMSI, K, OPC, AMF field, requested PDU sessions, slice config |

### AMF Configuration (`config/amfcfg.yaml`)

The AMF is the **front door** of the core. Its config defines what the network accepts.

```yaml
# Key settings explained:
amfName: AMF                        # NF instance name
ngapIpList:                         # N2 interface - where gNB connects via SCTP
  - amf.free5gc.org                 # Resolves to 10.100.200.16 in Docker
ngapPort: 38412                     # Standard NGAP port (3GPP defined)

servedGuamiList:                    # Globally Unique AMF ID
  - plmnId: { mcc: 208, mnc: 93 }  # PLMN = France/Orange (test PLMN)
    amfId: cafe00                   # 3-byte AMF identifier

supportedTAList:                    # Tracking Areas this AMF serves
  - tac: 000001                     # Tracking Area Code = 1
    plmnId: { mcc: 208, mnc: 93 }
    snssaiList:                     # Slices supported in this TA
      - sst: 1, sd: 010203         # Slice 1: eMBB default
      - sst: 1, sd: 112233         # Slice 2: eMBB alternate

security:                           # NAS security configuration
  integrityOrder: [NIA2]            # Integrity: AES-CMAC (128-EIA2)
  cipheringOrder: [NEA0]           # Ciphering: NULL (no encryption - lab only!)

networkName:                        # Broadcast in registration accept
  full: free5GC
  short: free

nrfUri: http://nrf.free5gc.org:8000 # Where to find NRF for service discovery
```

**What you change for your setup:**
- `ngapIpList` - Must be reachable from your gNB
- `servedGuamiList.plmnId` - Must match your gNB and UE PLMN
- `supportedTAList.tac` - Must match your gNB TAC
- `snssaiList` - Must include slices your UEs will request
- `security.cipheringOrder` - Change to `NEA1` or `NEA2` for production

### SMF Configuration (`config/smfcfg.yaml`)

The SMF controls **session setup and IP allocation**. This is where you define what IP addresses UEs get.

```yaml
# Key settings explained:
pfcp:                                    # N4 interface to UPF
  nodeID: smf.free5gc.org               # SMF's PFCP identity
  listenAddr: smf.free5gc.org           # PFCP listen address
  externalAddr: smf.free5gc.org         # PFCP external address

snssaiInfos:                            # Per-slice configuration
  - sNssai: { sst: 1, sd: 010203 }     # Slice 1
    dnnInfos:
      - dnn: internet                   # Data Network Name
        dns:
          ipv4: 8.8.8.8                 # DNS for this slice
          ipv6: 2001:4860:4860::8888

  - sNssai: { sst: 1, sd: 112233 }     # Slice 2
    dnnInfos:
      - dnn: internet
        dns:
          ipv4: 8.8.8.8

userplaneInformation:
  upNodes:
    gNB1:
      type: AN                          # Access Network node
    UPF:
      type: UPF                         # User Plane Function node
      nodeID: upf.free5gc.org           # UPF PFCP address
      addr: upf.free5gc.org             # UPF N3 address (GTP-U)
      sNssaiUpfInfos:
        - sNssai: { sst: 1, sd: 010203 }
          dnnUpfInfoList:
            - dnn: internet
              pools:
                - cidr: 10.60.0.0/16    # UE IP pool for Slice 1
              staticPools:
                - cidr: 10.60.100.0/24  # Static IPs for Slice 1
        - sNssai: { sst: 1, sd: 112233 }
          dnnUpfInfoList:
            - dnn: internet
              pools:
                - cidr: 10.61.0.0/16    # UE IP pool for Slice 2

  links:                                # Topology: how gNB connects to UPF
    - A: gNB1
      B: UPF                            # gNB1 <--N3--> UPF
```

**What you change for your setup:**
- `snssaiInfos[].dns` - Your DNS servers
- `pools[].cidr` - UE IP address ranges
- `upNodes.UPF.nodeID` - UPF address if running on separate host

### UPF Configuration (`config/upfcfg.yaml`)

The UPF is the **data highway**. Requires the GTP5G Linux kernel module.

```yaml
pfcp:
  nodeID: upf.free5gc.org              # PFCP identity (must match SMF config)
  addr: upf.free5gc.org                # PFCP listen address

gtpu:
  forwarder: gtp5g                     # Kernel module for high-speed forwarding
  ifList:
    - addr: upf.free5gc.org            # N3 interface (receives GTP-U from gNB)
      type: N3                         # GTP-U tunnels from gNB land here
    - addr: upf.free5gc.org
      type: N9                         # GTP-U tunnels from I-UPF (ULCL mode)

dnnList:
  - dnn: internet
    cidr: 10.60.0.0/16                 # Must match SMF pool config
  - dnn: internet
    cidr: 10.61.0.0/16
```

### NRF Configuration (`config/nrfcfg.yaml`)

The NRF is the **phone directory** - all NFs register here and discover each other.

```yaml
sbi:
  scheme: http
  bindingIPv4: nrf.free5gc.org
  port: 8000                           # All NFs connect to this port

DefaultPlmnId:
  mcc: 208                             # Must match all other NFs
  mnc: 93

mongodb:
  name: free5gc                        # Database name
  url: mongodb://db:27017              # MongoDB connection
```

### gNB Configuration (`config/gnbcfg.yaml`) - UERANSIM Simulator

```yaml
mcc: 208                               # Must match AMF PLMN
mnc: 93                                # Must match AMF PLMN
nci: '0x000000010'                     # NR Cell Identity (36-bit)
idLength: 32                           # gNB ID length
tac: 1                                 # Must match AMF's supportedTAList

linkIp: 127.0.0.1                      # Internal RAN simulation link
ngapIp: gnb.free5gc.org                # N2 interface (SCTP to AMF)
gtpIp: gnb.free5gc.org                 # N3 interface (GTP-U to UPF)

amfConfigs:
  - address: amf.free5gc.org           # AMF N2 address
    port: 38412                        # AMF NGAP port

slices:
  - sst: 1, sd: 010203                # Slices this gNB supports
  - sst: 1, sd: 112233                # Must be subset of AMF's supported slices
```

### UE Configuration (`config/uecfg.yaml`) - UERANSIM Simulator

```yaml
supi: 'imsi-208930000000001'           # IMSI = MCC(208) + MNC(93) + MSISDN
mcc: 208
mnc: 93

key: '8baf473f2f8fd09487cccbd7097c6862'   # Permanent Key (K)
op: ''                                      # OP not used (OPC is used instead)
opType: 'OPC'
opc: '8e27b6af0e692e750f32667a3b14605d'    # Operator Code (derived from OP + K)
amf: '8000'                                 # Authentication Management Field

imei: '356938035643803'                # Device identity
imeiSv: '4370816125816151'

gnbSearchList:                         # Where to find gNB
  - 127.0.0.1                         # Loopback (gNB + UE in same container)
  - gnb.free5gc.org                   # Docker DNS resolution

sessions:                             # PDU sessions to establish after registration
  - type: 'IPv4'
    apn: 'internet'
    slice: { sst: 1, sd: 010203 }     # Request session on Slice 1
  - type: 'IPv4'
    apn: 'internet'
    slice: { sst: 1, sd: 112233 }     # Request session on Slice 2

configured-nssai:                      # Slices this UE is configured for
  - sst: 1, sd: 010203
  - sst: 1, sd: 112233

default-nssai:                         # Default slice if none specified
  - sst: 1
    sd: 1
```

---

## How Containers Are Connected (Interface Map)

Every container communicates via specific 3GPP-defined interfaces. Understanding these connections is key to troubleshooting and configuration.

### Complete Connection Diagram

```
                                    ┌─────────────────────────────────────────────────────┐
                                    │            SBI Bus (HTTP/2, port 8000)               │
                                    │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐  │
                                    │  │ AUSF│ │ UDM │ │ UDR │ │ NSSF│ │ PCF │ │ CHF │  │
                                    │  └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘  │
                                    │     │       │       │       │       │       │      │
                                    │     └───────┴───────┴───┬───┴───────┴───────┘      │
                                    │                         │                           │
                                    │                    ┌────┴────┐                      │
                                    │                    │   NRF   │ Service Registry      │
                                    │                    └────┬────┘                      │
                                    │                         │                           │
                                    │     ┌───────────────────┼────────────────────┐      │
                                    │     │                   │                    │      │
                                    │  ┌──┴──┐           ┌────┴────┐         ┌────┴───┐  │
                                    │  │ AMF │           │   SMF   │         │  NEF   │  │
                                    │  └──┬──┘           └────┬────┘         └────────┘  │
                                    │     │                   │                           │
                                    └─────┼───────────────────┼───────────────────────────┘
                                          │                   │
                              N2 (SCTP)   │       N4 (PFCP)   │
                              Port 38412  │                   │
                                          │              ┌────┴────┐        N6 (IP)
┌──────┐     Uu (Radio)    ┌──────┐       │              │   UPF   │────────────────> Internet
│  UE  │ ◄──────────────── │  gNB │───────┘              └────┬────┘
└──────┘                   └──┬───┘                           │
                              │         N3 (GTP-U)            │
                              └───────────────────────────────┘
                                        UDP 2152


     ┌──────────────┐                        ┌─────────────────────────────────┐
     │   MongoDB    │◄───── mongodb://db:27017 ──── NRF, UDR, PCF, CHF, NEF   │
     │  (Port 27017)│                        └─────────────────────────────────┘
     └──────────────┘

     ┌──────────────┐
     │    WebUI     │◄───── http://localhost:5000 ──── Browser (Admin)
     │  (Port 5000) │───── mongodb://db:27017 ──── Read/write subscriber data
     └──────────────┘
```

### Interface-by-Interface Breakdown

#### N2 Interface: gNB <--> AMF (Control Plane Signaling)

| Property | Value |
|----------|-------|
| **Protocol** | SCTP (Stream Control Transmission Protocol) |
| **Application** | NGAP (Next Generation Application Protocol) |
| **Port** | 38412 |
| **Direction** | gNB initiates SCTP association to AMF |
| **AMF Address** | `amf.free5gc.org` (10.100.200.16 in Docker) |
| **What flows here** | Registration requests, authentication messages, PDU session setup, handover, paging |

```
gNB ──(SCTP:38412)──> AMF
     NGAP messages:
       - NGSetupRequest/Response (gNB connects to AMF)
       - InitialUEMessage (UE starts registration)
       - UplinkNASTransport (UE → core signaling)
       - DownlinkNASTransport (core → UE signaling)
       - PDUSessionResourceSetup (data session creation)
```

#### N3 Interface: gNB <--> UPF (User Data Tunnel)

| Property | Value |
|----------|-------|
| **Protocol** | GTP-U (GPRS Tunneling Protocol - User Plane) |
| **Transport** | UDP |
| **Port** | 2152 |
| **Kernel Module** | GTP5G (Linux kernel module, required on UPF host) |
| **gNB Address** | `gnb.free5gc.org` |
| **UPF Address** | `upf.free5gc.org` |
| **What flows here** | All user data (web browsing, video, downloads) encapsulated in GTP-U tunnels |

```
gNB ──(GTP-U:UDP:2152)──> UPF
     Each PDU session = one GTP-U tunnel
     Identified by TEID (Tunnel Endpoint ID)
     Example: UE browsing → gNB encapsulates in GTP → UPF decapsulates → Internet
```

#### N4 Interface: SMF <--> UPF (Session Control)

| Property | Value |
|----------|-------|
| **Protocol** | PFCP (Packet Forwarding Control Protocol) |
| **Transport** | UDP |
| **Port** | Dynamic (assigned by kernel) |
| **SMF Address** | `smf.free5gc.org` |
| **UPF Node ID** | `upf.free5gc.org` |
| **What flows here** | Packet detection rules, forwarding rules, QoS enforcement, usage reports |

```
SMF ──(PFCP)──> UPF
     PFCP messages:
       - Association Setup (SMF discovers UPF)
       - Session Establishment (create forwarding rules for PDU session)
       - Session Modification (update rules, e.g., QoS change)
       - Session Deletion (tear down PDU session)
       - Session Report (UPF reports usage/events to SMF)
```

#### N6 Interface: UPF <--> Internet (Data Network)

| Property | Value |
|----------|-------|
| **Protocol** | Standard IP routing |
| **What it does** | UPF acts as router/NAT gateway between UE IP pool and external networks |
| **UE Pool 1** | 10.60.0.0/16 (Slice 010203) |
| **UE Pool 2** | 10.61.0.0/16 (Slice 112233) |
| **DNS** | 8.8.8.8 (configured in SMF) |
| **Implementation** | iptables NAT rules in UPF container (`config/upf-iptables.sh`) |

#### SBI: All NFs <--> NRF and Each Other (Service Discovery & Communication)

| Property | Value |
|----------|-------|
| **Protocol** | HTTP/2 |
| **Port** | 8000 (same for all NFs) |
| **Scheme** | HTTP (no TLS in default lab setup) |
| **Service Discovery** | NF registers with NRF at startup, discovers others via NRF |
| **Docker DNS** | Each NF has a Docker alias (e.g., `amf.free5gc.org`, `smf.free5gc.org`) |

**Who talks to whom over SBI:**

| Source NF | Destination NF | Service Used | Purpose |
|-----------|---------------|-------------|---------|
| All NFs | NRF | Nnrf_NFManagement | Register themselves at startup |
| AMF | NRF | Nnrf_NFDiscovery | Find SMF, AUSF, UDM, NSSF |
| AMF | AUSF | Nausf_UEAuthentication | Authenticate a UE |
| AUSF | UDM | Nudm_UEAuthentication | Get auth vectors (RAND, AUTN, XRES*) |
| UDM | UDR | Nudr_DataRepository | Read subscriber keys, subscription data |
| AMF | NSSF | Nnssf_NSSelection | Select network slice for UE |
| AMF | SMF | Nsmf_PDUSession | Create/modify/delete PDU sessions |
| SMF | PCF | Npcf_SMPolicyControl | Get QoS and policy rules for session |
| SMF | CHF | Nchf_ConvergedCharging | Report usage for billing |
| SMF | UDM | Nudm_SubscriberDataManagement | Get session management subscription data |

### Docker Network Setup

All containers run on a single Docker bridge network:

```yaml
networks:
  privnet:
    ipam:
      config:
        - subnet: 10.100.200.0/24    # All NF communication happens here
```

**Static IP assignments** (containers that need fixed addresses):

| Container | IP Address | Why Static |
|-----------|-----------|-----------|
| `amf` | 10.100.200.16 | gNB needs a stable SCTP endpoint; TNGF uses direct IP |
| `n3iwf` | 10.100.200.15 | Non-3GPP UEs connect via IKEv2 to this fixed IP |
| `n3iwue` | 10.100.200.203 | Needs known source IP for IPSec tunnel to N3IWF |

All other containers use Docker DNS resolution (e.g., `nrf.free5gc.org`, `smf.free5gc.org`).

### Complete Port Map

| Port | Protocol | Container | Interface | Exposed to Host? |
|------|----------|-----------|-----------|-------------------|
| 38412 | SCTP | AMF | N2 (NGAP) | No (Docker internal). Expose for real gNB. |
| 8000 | HTTP/2 | All NFs | SBI | No (internal NF-to-NF) |
| 2152 | UDP | UPF | N3 (GTP-U) | No (Docker internal). Expose for real gNB. |
| 5000 | TCP | WebUI | Web Console | **Yes** - `http://<host>:5000` |
| 2121-2122 | TCP | WebUI | Billing/CGF | Yes |
| 27017 | TCP | MongoDB | Database | No (internal only) |

---

## Connecting Real Equipment (After Core is Running)

Once the 5G core is up and running (verified with UERANSIM), you can replace the simulator with real hardware. This section covers connecting real gNBs, commercial UEs, and third-party test tools.

### Step 1: Expose Core Network Interfaces

By default, all ports are on the Docker bridge network (10.100.200.0/24) and **not accessible from outside the host**. To connect real equipment, you must expose the N2 and N3 interfaces.

#### Option A: Expose Ports in docker-compose.yaml

Edit `docker-compose.yaml` to publish AMF and UPF ports:

```yaml
  free5gc-amf:
    # ... existing config ...
    ports:
      - "38412:38412/sctp"    # N2: NGAP/SCTP - for gNB control plane
      # Note: SCTP port mapping requires Linux kernel SCTP support

  free5gc-upf:
    # ... existing config ...
    ports:
      - "2152:2152/udp"      # N3: GTP-U - for gNB user plane data
```

After editing:
```bash
docker compose down && docker compose up -d
```

#### Option B: Use Host Network Mode (Recommended for Real Equipment)

For production or real gNB testing, run AMF and UPF in host network mode for best performance:

```yaml
  free5gc-amf:
    network_mode: "host"
    # Update amfcfg.yaml: ngapIpList → your server's real IP

  free5gc-upf:
    network_mode: "host"
    # Update upfcfg.yaml: gtpu addr → your server's real IP
```

#### Option C: Macvlan Network (Dedicated NIC)

If your server has multiple NICs, create a macvlan for the 5G interfaces:

```bash
docker network create -d macvlan \
  --subnet=192.168.1.0/24 \
  --gateway=192.168.1.1 \
  -o parent=eth1 \
  5g-ran-net
```

### Step 2: Configure Your Real gNB

Every commercial or open-source gNB needs these parameters to connect to the free5GC core:

#### Required gNB Configuration Parameters

| Parameter | Value in This Setup | Where to Find/Change |
|-----------|-------------------|---------------------|
| **AMF IP Address** | Your server's IP (e.g., `135.181.93.114`) | `config/amfcfg.yaml` → `ngapIpList` |
| **AMF SCTP Port** | 38412 | Standard, don't change |
| **MCC** | 208 | `config/amfcfg.yaml` → `servedGuamiList.plmnId.mcc` |
| **MNC** | 93 | `config/amfcfg.yaml` → `servedGuamiList.plmnId.mnc` |
| **TAC** | 1 (hex: 000001) | `config/amfcfg.yaml` → `supportedTAList.tac` |
| **S-NSSAI (Slices)** | SST=1/SD=010203, SST=1/SD=112233 | `config/amfcfg.yaml` → `snssaiList` |
| **gNB ID** | Assign any unique 32-bit value | Your gNB config |
| **NR Cell ID** | Assign any unique 36-bit value | Your gNB config |

#### Example: Connecting an Open-Source gNB (srsRAN, OAI)

**srsRAN gNB** (`gnb.yaml`):
```yaml
amf:
  addr: 135.181.93.114               # Your server IP
  port: 38412
  bind_addr: 192.168.1.50            # gNB's own IP

cell_cfg:
  plmn: "20893"                      # Must match AMF: MCC=208, MNC=93
  tac: 1                             # Must match AMF TAC
  nci: 0x000000020                   # Unique NR Cell ID
  pci: 1                             # Physical Cell ID

slicing:
  - sst: 1
    sd: 010203                       # Must match AMF supported slices
```

**OpenAirInterface (OAI) gNB** (`gnb.conf`):
```
gNBs = ({
    tracking_area_code = 1;          # Must match AMF TAC
    plmn_list = ({ mcc = 208; mnc = 93; mnc_length = 2; snssaiList = ({ sst = 1; sd = 0x010203; }); });
    amf_ip_address = ({ ipv4 = "135.181.93.114"; });
});
```

#### After Connecting a Real gNB

Verify the connection from the AMF logs:

```bash
docker logs amf 2>&1 | grep -i "ng setup"
# Expected: "NG Setup procedure is successful"

docker logs amf 2>&1 | grep -i "ran"
# Expected: shows your gNB's info (gNB ID, Cell ID, TAC)
```

### Step 3: Provision Real SIM Cards / UEs

For real UEs (phones with 5G SIM cards), you need to:

#### 3a. Program SIM Cards

Each SIM card must be programmed with credentials that match the subscriber database:

| SIM Parameter | What It Is | Example Value |
|--------------|-----------|---------------|
| IMSI | Unique subscriber identity | 208930000000001 |
| K | Permanent authentication key (128-bit) | 8baf473f2f8fd09487cccbd7097c6862 |
| OP or OPC | Operator key | Use OPC: 8e27b6af0e692e750f32667a3b14605d |
| AMF | Auth Management Field | 8000 |

**SIM programming tools:**
- [pySim](https://github.com/osmocom/pysim) - Open source, works with most programmable SIMs
- [sysmoUSIM-SJA2](https://sysmocom.de/products/sysmousim/) - Programmable USIM cards
- Commercial SIM programming stations

```bash
# Example using pySim to program a sysmoUSIM:
pySim-prog.py -p 0 -t sysmoUSIM-SJA2 \
  -i 208930000000001 \         # IMSI
  -k 8baf473f2f8fd09487cccbd7097c6862 \  # K
  -o 8e27b6af0e692e750f32667a3b14605d \  # OPC
  -x 208 -y 93                 # MCC/MNC
```

#### 3b. Add Subscriber to free5GC Database

Use the WebUI (`http://<server>:5000`) or the API:

```bash
# Login to get token
TOKEN=$(curl -s -X POST "http://localhost:5000/api/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"free5gc"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

# Create subscriber (adjust IMSI, K, OPC to match your SIM)
curl -X POST "http://localhost:5000/api/subscriber/imsi-208930000000002/20893" \
  -H "Content-Type: application/json" \
  -H "Token: $TOKEN" \
  -d '{
    "plmnID": "20893",
    "ueId": "imsi-208930000000002",
    "AuthenticationSubscription": {
      "authenticationManagementField": "8000",
      "authenticationMethod": "5G_AKA",
      "milenage": {"op": {"encryptionAlgorithm": 0, "encryptionKey": 0, "opValue": ""}},
      "opc": {"encryptionAlgorithm": 0, "encryptionKey": 0, "opcValue": "YOUR_OPC_HERE"},
      "permanentKey": {"encryptionAlgorithm": 0, "encryptionKey": 0, "permanentKeyValue": "YOUR_K_HERE"},
      "sequenceNumber": "000000000020"
    },
    "AccessAndMobilitySubscriptionData": {
      "gpsis": ["msisdn-0900000002"],
      "nssai": {
        "defaultSingleNssais": [{"sst": 1, "sd": "010203"}],
        "singleNssais": [{"sst": 1, "sd": "112233"}]
      },
      "subscribedUeAmbr": {"downlink": "2 Gbps", "uplink": "1 Gbps"}
    },
    "SessionManagementSubscriptionData": [
      {"singleNssai": {"sst": 1, "sd": "010203"}, "dnnConfigurations": {"internet": {"sscModes": {"defaultSscMode": "SSC_MODE_1"}, "pduSessionTypes": {"defaultSessionType": "IPV4"}, "sessionAmbr": {"uplink": "200 Mbps", "downlink": "100 Mbps"}, "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8}}}}},
      {"singleNssai": {"sst": 1, "sd": "112233"}, "dnnConfigurations": {"internet": {"sscModes": {"defaultSscMode": "SSC_MODE_1"}, "pduSessionTypes": {"defaultSessionType": "IPV4"}, "sessionAmbr": {"uplink": "200 Mbps", "downlink": "100 Mbps"}, "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8}}}}}
    ],
    "SmfSelectionSubscriptionData": {"subscribedSnssaiInfos": {"01010203": {"dnnInfos": [{"dnn": "internet"}]}, "01112233": {"dnnInfos": [{"dnn": "internet"}]}}},
    "AmPolicyData": {"subscCats": ["free5gc"]},
    "SmPolicyData": {"smPolicySnssaiData": {"01010203": {"snssai": {"sst": 1, "sd": "010203"}, "smPolicyDnnData": {"internet": {"dnn": "internet"}}}, "01112233": {"snssai": {"sst": 1, "sd": "112233"}, "smPolicyDnnData": {"internet": {"dnn": "internet"}}}}},
    "FlowRules": []
  }'
```

### Step 4: Configure Real Phone APN Settings

On a real 5G phone with your programmed SIM:

| Phone Setting | Value |
|--------------|-------|
| **APN Name** | `internet` (must match DNN in config) |
| **APN Protocol** | IPv4 |
| **MCC** | 208 |
| **MNC** | 93 |
| **APN Type** | default,supl |

> On Android: Settings > Network > Mobile Networks > Access Point Names > Add New APN

### Step 5: Remove UERANSIM (Production Mode)

Once real equipment is connected, remove the simulator containers:

```yaml
# In docker-compose.yaml, comment out or remove:
#  ueransim:
#    ...
#  n3iwue:
#    ...
```

Or selectively stop them:
```bash
docker compose stop ueransim n3iwue
```

### Connecting Third-Party Test Tools

#### UERANSIM on a Separate Machine

Instead of running UERANSIM in Docker alongside the core, run it on a **different machine** to simulate a real RAN:

```bash
# On a separate Linux machine:
git clone https://github.com/aligungr/UERANSIM.git
cd UERANSIM && make

# Edit config/free5gc-gnb.yaml:
#   ngapIp: <this-machine-ip>
#   gtpIp: <this-machine-ip>
#   amfConfigs:
#     - address: <free5gc-server-ip>    # Your core network server
#       port: 38412

./build/nr-gnb -c config/free5gc-gnb.yaml    # Start gNB
./build/nr-ue -c config/free5gc-ue.yaml       # Start UE
```

#### Amarisoft (Commercial Test Tool)

[Amarisoft](https://www.amarisoft.com/) provides commercial gNB + UE simulators. Configure:

```
// amarisoft enb.cfg
{
  mme_list: [{
    s1ap_bind_addr: "<amarisoft-ip>",
    ngap: { amf_addr: "<free5gc-server-ip>", amf_port: 38412 }
  }],
  cell_list: [{
    plmn_list: [{ plmn: "20893", tac: 1 }],
    nr_cell_list: [{
      rf_port: 0,
      n_id_cell: 1,
      ssb_nr_arfcn: 632628,
      dl_nr_arfcn: 632628,
      band: 78,
      bandwidth: 40,
    }]
  }]
}
```

#### Open5GS Tester (open5gs-dbctl)

If migrating from Open5GS, note that free5GC uses a different subscriber format. Use the WebUI or API shown above, not open5gs-dbctl.

### Network Routing for Real Equipment

When connecting real gNBs from external networks, ensure proper routing:

```bash
# On the free5GC server, ensure IP forwarding is enabled:
sysctl -w net.ipv4.ip_forward=1

# If UPF is in Docker, add route for UE traffic to reach the Docker network:
# (This is handled automatically by Docker if you expose port 2152)

# For host-network UPF, configure NAT for UE pools:
iptables -t nat -A POSTROUTING -s 10.60.0.0/16 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.61.0.0/16 -j MASQUERADE

# Allow GTP-U traffic through firewall:
iptables -A INPUT -p udp --dport 2152 -j ACCEPT    # N3 GTP-U
iptables -A INPUT -p sctp --dport 38412 -j ACCEPT   # N2 NGAP
```

### Verification After Connecting Real Equipment

```bash
# 1. Check if gNB registered with AMF
docker logs amf 2>&1 | grep -i "ng setup"

# 2. Check registered UEs
docker logs amf 2>&1 | grep -i "registr"

# 3. Check PDU sessions
docker logs smf 2>&1 | grep -i "pdu session"

# 4. Check UPF forwarding
docker logs upf 2>&1 | grep -i "pfcp"

# 5. Check subscriber in database
docker exec mongodb mongo --quiet --eval '
  db = db.getSiblingDB("free5gc");
  db.subscriptionData.authenticationData.authenticationSubscription.find().forEach(
    function(doc) { print(doc.ueId + " - SQN: " + JSON.stringify(doc.sequenceNumber)); }
  );
'
```

---

## Architecture

### Network Functions (What Each Container Does)

| Container | Network Function | Role | Real-world Analogy |
|-----------|-----------------|------|-------------------|
| `amf` | Access & Mobility Management | Front door of the core. Handles registration, auth, mobility | Hotel reception desk |
| `smf` | Session Management | Sets up data sessions, allocates IPs, controls UPF | Network engineer setting up your connection |
| `upf` | User Plane Function | Routes all user data (the data highway) | Highway interchange |
| `nrf` | NF Repository | Service registry - NFs discover each other here | Phone directory for network functions |
| `ausf` | Authentication Server | Verifies subscriber identity (5G-AKA) | Security guard checking IDs |
| `udm` | Unified Data Management | Manages subscriber data, computes auth crypto | HR department |
| `udr` | Unified Data Repository | Database backend (MongoDB) | Filing cabinet |
| `nssf` | Network Slice Selection | Picks the right network slice for each subscriber | Traffic controller |
| `pcf` | Policy Control | Decides QoS rules, speed limits | Rules engine / Manager |
| `chf` | Charging Function | Billing and usage tracking | Billing department |
| `nef` | Network Exposure | API gateway for external apps | Public API |
| `n3iwf` | Non-3GPP Interworking | Connects Wi-Fi devices to 5G core | Side entrance (Wi-Fi) |
| `tngf` | Trusted Non-3GPP Gateway | Trusted non-3GPP access | Trusted side entrance |
| `webui` | Web Console | Admin UI for subscriber management | Admin dashboard |
| `mongodb` | Database | Stores all subscriber and config data | Database |
| `ueransim` | gNB + UE Simulator | Simulates base station and phone | Test equipment |

### Key Interfaces

```
UE ──(Uu)──> gNB ──(N2/SCTP)──> AMF ──(SBI/HTTP2)──> Other NFs
                   ──(N3/GTP-U)──> UPF ──(N6)──> Internet
                                    ^
                              SMF ──(N4/PFCP)
```

### Network Configuration

| Network | Subnet | Purpose |
|---------|--------|---------|
| Docker bridge | 10.100.200.0/24 | Internal NF communication |
| UE Pool 1 | 10.60.0.0/16 | PDU sessions (Slice 1) |
| UE Pool 2 | 10.61.0.0/16 | PDU sessions (Slice 2) |

## Management

### Portable deployment (free5gc.sh)

```bash
./free5gc.sh status               # Show container status
./free5gc.sh test                 # 1 UE registration + trace
./free5gc.sh test full            # 16 UE attach + 200 UE reject + trace
./free5gc.sh logs amf             # View AMF logs (or: smf, ausf, udm, udr, etc.)
./free5gc.sh stop                 # Stop and remove all containers
./free5gc.sh start                # Start containers + provision subscriber
```

### WebUI

- **URL**: `http://<server-ip>:5000`
- **Username**: `admin`
- **Password**: `free5gc`

## Important Notes

### SQN Fix for UERANSIM

UERANSIM starts with internal sequence number (SQN) = 0. The default subscriber SQN in free5GC (`16f3b3f70fc2`) is too large, causing "SQN out of range" authentication failures. The setup script automatically fixes this by setting SQN to `000000000020`.

### Prerequisites

- Ubuntu 22.04 LTS (Kernel 5.15.x or 6.8.x HWE)
- CPU with AVX support (for MongoDB 4.4+)
- 4 GB RAM minimum, 8 GB recommended (minimal mode works with 2 GB - only 4 containers)
- Root access
- Docker is installed automatically by the script
- GTP5G kernel module is built inside Docker (avoids Secure Boot and compiler issues)

## Subscriber Configuration

These values must match between `config/uecfg.yaml` and the subscriber database:

| Parameter | Value |
|-----------|-------|
| IMSI | 208930000000001 |
| MCC/MNC | 208/93 |
| K (Permanent Key) | 8baf473f2f8fd09487cccbd7097c6862 |
| OPC (Operator Code) | 8e27b6af0e692e750f32667a3b14605d |
| AMF | 8000 |
| Auth Method | 5G_AKA |

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) and [docs/02-SETUP-GUIDE.md#troubleshooting](docs/02-SETUP-GUIDE.md#troubleshooting) for common issues and fixes.

---

## References

- [free5GC Project](https://github.com/free5gc/free5gc) - Open source 5G core network
- [free5GC Documentation](https://free5gc.org/guide/) - Official guides
- [UERANSIM](https://github.com/aligungr/UERANSIM) - Open source 5G UE and RAN simulator
- [GTP5G](https://github.com/free5gc/gtp5g) - Linux kernel module for GTP-U
- [3GPP TS 23.501](https://www.3gpp.org/DynaReport/23501.htm) - 5G System Architecture specification
- [3GPP TS 23.502](https://www.3gpp.org/DynaReport/23502.htm) - 5G Procedures specification
- [3GPP TS 33.501](https://www.3gpp.org/DynaReport/33501.htm) - 5G Security Architecture
- [srsRAN Project](https://www.srsran.com/) - Open source 5G RAN (real gNB)
- [OpenAirInterface](https://openairinterface.org/) - Open source 5G RAN + Core
- [pySim](https://github.com/osmocom/pysim) - Open source SIM card programming tool

## License

This project is forked from [free5gc/free5gc-compose](https://github.com/free5gc/free5gc-compose). See [LICENSE.txt](LICENSE.txt).
