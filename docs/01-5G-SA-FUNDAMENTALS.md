# 5G Standalone (SA) Architecture - Complete Guide for Beginners

## Table of Contents

1. [What is 5G SA?](#what-is-5g-sa)
2. [4G vs 5G - Why the Change?](#4g-vs-5g---why-the-change)
3. [The 5G Network Architecture Overview](#the-5g-network-architecture-overview)
4. [Every Network Function Explained](#every-network-function-explained)
5. [How a Phone Connects to the 5G Network](#how-a-phone-connects-to-the-5g-network)
6. [Key 5G Concepts You Must Know](#key-5g-concepts-you-must-know)
7. [The Protocol Stack](#the-protocol-stack)
8. [How free5GC Maps to Real 5G](#how-free5gc-maps-to-real-5g)

---

## What is 5G SA?

**5G SA (Standalone)** is a completely new mobile network architecture defined by the 3GPP standards body. Unlike 5G NSA (Non-Standalone), which piggybacks on existing 4G infrastructure, **5G SA is a clean-slate design** with its own core network.

Think of it this way:
- **5G NSA** = New 5G radio + Old 4G core (like putting a new engine in an old car)
- **5G SA** = New 5G radio + New 5G core (an entirely new car)

### Why Does 5G SA Matter?

| Feature | 4G LTE | 5G NSA | 5G SA |
|---------|--------|--------|-------|
| Architecture | Monolithic (EPC) | 5G radio + 4G core | Fully cloud-native |
| Network Slicing | No | Limited | Full support |
| Ultra-low Latency | ~30ms | ~15ms | ~1ms |
| Edge Computing | Limited | Limited | Native URLLC |
| Service-Based | No | No | Yes (SBI) |

---

## 4G vs 5G - Why the Change?

### The Old Way: 4G LTE (EPC)

In 4G, the core network (called **EPC - Evolved Packet Core**) was built as a set of large, tightly-coupled network elements:

```
Phone ──> eNodeB ──> MME ──> HSS
                      |
                     SGW ──> PGW ──> Internet
```

- **MME** (Mobility Management Entity) = Handled everything: auth, paging, handover
- **HSS** (Home Subscriber Server) = Subscriber database
- **SGW/PGW** (Serving/PDN Gateway) = Data plane routing

**Problem**: These were monolithic boxes. If you needed more capacity for one function, you had to scale the entire box. It was expensive and inflexible.

### The New Way: 5G SA (SBA)

5G SA uses a **Service-Based Architecture (SBA)** where every function is a **microservice** that communicates over HTTP/2 REST APIs:

```
┌────────────────────────────────────────────────────────────────┐
│                    5G Service-Based Architecture                │
│                                                                │
│    ┌─────┐ ┌──────┐ ┌─────┐ ┌─────┐ ┌──────┐ ┌─────┐        │
│    │ NRF │ │ NSSF │ │ NEF │ │ UDM │ │ AUSF │ │ PCF │  ...   │
│    └──┬──┘ └──┬───┘ └──┬──┘ └──┬──┘ └──┬───┘ └──┬──┘        │
│       │       │        │       │        │        │             │
│    ═══╪═══════╪════════╪═══════╪════════╪════════╪═══ SBI Bus │
│       │       │        │       │        │        │             │
│    ┌──┴──┐ ┌──┴──┐                                            │
│    │ AMF │ │ SMF │                                             │
│    └──┬──┘ └──┬──┘                                            │
│       │       │                                                │
│      N2      N4                                                │
│       │       │                                                │
│    ┌──┴──┐ ┌──┴──┐                                            │
│    │ gNB │ │ UPF │──── N6 ───> Internet                       │
│    └──┬──┘ └─────┘                                            │
│       │                                                        │
│      Uu (Radio)                                                │
│       │                                                        │
│    ┌──┴──┐                                                     │
│    │ UE  │  (Your Phone)                                       │
│    └─────┘                                                     │
└────────────────────────────────────────────────────────────────┘
```

**Key difference**: Every box on the SBI bus can be independently deployed, scaled, and updated. This is why 5G core runs naturally on Kubernetes/Docker.

---

## The 5G Network Architecture Overview

The 5G network has three main layers:

### Layer 1: User Equipment (UE)
Your phone, IoT device, or in our case, the **UERANSIM** simulator.

### Layer 2: Radio Access Network (RAN)
The **gNB (gNodeB)** - the 5G base station that your phone connects to via radio waves. In our setup, UERANSIM simulates both the UE and gNB.

### Layer 3: 5G Core Network (5GC)
This is where all the intelligence lives. It's made up of multiple **Network Functions (NFs)** that we'll explain in detail below.

### Reference Points (Interfaces)

| Interface | Between | Purpose |
|-----------|---------|---------|
| **Uu** | UE <-> gNB | Radio interface (air) |
| **N2** | gNB <-> AMF | Control plane (NGAP/SCTP) |
| **N3** | gNB <-> UPF | User data plane (GTP-U) |
| **N4** | SMF <-> UPF | UPF control (PFCP) |
| **N6** | UPF <-> Internet | Data network |
| **SBI** | NF <-> NF | HTTP/2 REST APIs |

---

## Every Network Function Explained

### AMF - Access and Mobility Management Function

**What it does**: The AMF is the **front door** of the 5G core. Every message from the gNB goes through the AMF first.

**Real-world analogy**: Think of the AMF as the **reception desk at a hotel**. When you arrive (register), the receptionist:
1. Checks your identity (authentication)
2. Assigns you a room key (security context)
3. Keeps track of where you are (mobility)
4. Routes you to the right services

**Responsibilities**:
- **Registration**: When your phone turns on, the AMF handles the registration process
- **Authentication**: Works with AUSF to verify "is this really you?"
- **NAS Security**: Encrypts and integrity-protects messages between the phone and core
- **Mobility**: Tracks which gNB your phone is connected to
- **Paging**: Wakes up idle phones when someone calls/messages them

**In our setup**: Container `amf` at IP `10.100.200.16`, listening on SCTP port 38412 for N2 (NGAP) connections from UERANSIM gNB.

**Key logs to watch**:
```
[AMF][Ngap] SCTP Accept from: 10.100.200.13     # gNB connected
[AMF][Gmm] Handle Registration Request            # UE registering
[AMF][Gmm] Authentication procedure               # Auth started
[AMF][Gmm] UE switches to state [Registered]      # Success!
```

---

### SMF - Session Management Function

**What it does**: The SMF manages **data sessions** (called PDU Sessions). When your phone wants to access the internet, the SMF sets up the data path.

**Real-world analogy**: The SMF is like a **network engineer** who sets up a dedicated internet pipe for you. It:
1. Decides which UPF to use (like choosing which router to connect through)
2. Allocates an IP address for your device
3. Applies your data plan rules (speed limits, etc.)
4. Creates the tunnel between gNB and UPF

**Responsibilities**:
- **PDU Session Management**: Create, modify, release data sessions
- **IP Address Allocation**: Assigns an IP to each session (e.g., 10.60.0.1)
- **UPF Selection**: Chooses the right User Plane Function
- **QoS Control**: Applies quality-of-service rules from PCF
- **UPF Control via PFCP**: Tells the UPF how to route packets (N4 interface)

**In our setup**: Container `smf`, controls the UPF via N4 (PFCP protocol).

**Key logs to watch**:
```
[SMF][PduSess] Receive Create SM Context Request  # New session request
[SMF][PduSess] Allocated UE IP: 10.60.0.1         # IP assigned
[SMF][PFCP] Association Setup Response             # Connected to UPF
```

---

### UPF - User Plane Function

**What it does**: The UPF is the **data highway**. All user data (web browsing, streaming, etc.) flows through the UPF. It's the only NF that touches actual user traffic.

**Real-world analogy**: The UPF is like a **highway interchange**. It receives data packets from the gNB through a GTP tunnel, strips the tunnel header, and forwards the raw IP packet to the internet (and vice versa).

**Responsibilities**:
- **Packet Routing & Forwarding**: Routes packets between gNB and internet
- **GTP-U Tunnel Termination**: Handles GTP encapsulation/decapsulation
- **Policy Enforcement**: Rate limiting, packet filtering
- **Usage Reporting**: Reports data usage for billing (to CHF via SMF)

**Why GTP5G Kernel Module is Required**: The UPF needs to process GTP-U packets at kernel level for performance. The `gtp5g` kernel module provides this capability. Without it, the UPF cannot function.

**In our setup**: Container `upf`, uses the host's `gtp5g` kernel module via `NET_ADMIN` capability.

**Data flow**:
```
Phone ──(radio)──> gNB ──(GTP-U/N3)──> UPF ──(raw IP/N6)──> Internet
                                         ^
                                         |
                                   SMF controls via
                                   PFCP (N4)
```

---

### NRF - Network Repository Function

**What it does**: The NRF is the **service registry**. Every NF registers itself with the NRF, and other NFs discover services through it.

**Real-world analogy**: The NRF is like a **phone directory/DNS for network functions**. When the AMF needs to find the AUSF to authenticate a user, it asks the NRF: "Where is the AUSF?"

**Responsibilities**:
- **NF Registration**: Each NF registers its profile (type, address, supported services)
- **NF Discovery**: NFs query the NRF to find other NFs
- **NF Status Notification**: Notifies subscribers when NFs go up/down
- **OAuth2 Token Issuing**: Issues access tokens for NF-to-NF communication

**In our setup**: Container `nrf`, the first service to start (all others depend on it).

---

### AUSF - Authentication Server Function

**What it does**: The AUSF handles **authentication** - proving that a subscriber is who they claim to be.

**Real-world analogy**: AUSF is the **security guard** who checks your ID. It implements the 5G-AKA (Authentication and Key Agreement) protocol.

**How 5G Authentication Works (simplified)**:

```
UE                    AMF              AUSF             UDM
 |                     |                |                |
 |-- Registration ---->|                |                |
 |                     |-- Auth Req --->|                |
 |                     |                |-- Get Keys --->|
 |                     |                |<-- K, OPC, SQN-|
 |                     |                |                |
 |                     |                |  Compute:      |
 |                     |                |  RAND, XRES*,  |
 |                     |                |  AUTN, KAUSF   |
 |                     |                |                |
 |                     |<- Auth Vector -|                |
 |<-- Auth Request ----|  (RAND, AUTN)  |                |
 |                     |                |                |
 |  UE computes RES*   |                |                |
 |  using K + RAND     |                |                |
 |                     |                |                |
 |-- Auth Response --->|                |                |
 |   (RES*)            |-- Verify ---->|                |
 |                     |   RES*        |                |
 |                     |<-- Success ---|                |
 |<-- Auth Success! ---|                |                |
```

**Key Parameters**:
- **K** (Permanent Key): Secret key stored in SIM and network (never transmitted)
- **OPC** (Operator Code): Derived from the operator's secret OP and K
- **RAND**: Random challenge generated by the network
- **SQN** (Sequence Number): Prevents replay attacks
- **AUTN**: Authentication Token (proves network is legitimate)
- **RES***: Response from UE (proves UE is legitimate)

---

### UDM - Unified Data Management

**What it does**: The UDM manages **subscriber data** and handles the cryptographic computations for authentication.

**Real-world analogy**: UDM is the **HR department** that keeps all employee records. It knows your subscription details, which services you're allowed to use, and computes the crypto challenges for authentication.

**Responsibilities**:
- **Authentication Credential Processing**: Computes authentication vectors using Milenage algorithm
- **Subscriber Data Management**: Stores/retrieves subscription data
- **SUPI/SUCI Resolution**: Resolves encrypted subscriber identity to real identity
- **Access Authorization**: Determines if a subscriber can access specific services

---

### UDR - Unified Data Repository

**What it does**: The UDR is the **database backend** for UDM, PCF, and NEF. It stores all subscription data in MongoDB.

**Real-world analogy**: If UDM is the HR department, UDR is the **filing cabinet** where all records are physically stored.

**Data stored**:
- Authentication credentials (K, OPC, SQN)
- Access and mobility subscription data
- Session management subscription data
- Policy data

**In our setup**: Container `udr`, connects to MongoDB at `mongodb://db:27017/free5gc`.

---

### NSSF - Network Slice Selection Function

**What it does**: The NSSF helps select the right **network slice** for a subscriber.

**What is Network Slicing?**
Network slicing is one of 5G's killer features. It lets operators create multiple **virtual networks** on the same physical infrastructure:

```
┌─────────────────────────────────────────────┐
│           Physical 5G Infrastructure          │
│                                               │
│  ┌──────────────────────────────────────────┐ │
│  │ Slice 1: Enhanced Mobile Broadband (eMBB)│ │  <-- Your phone
│  │ SST=1, SD=010203                         │ │      (streaming, browsing)
│  │ High bandwidth, moderate latency         │ │
│  └──────────────────────────────────────────┘ │
│                                               │
│  ┌──────────────────────────────────────────┐ │
│  │ Slice 2: IoT / Massive MTC              │ │  <-- Smart meters, sensors
│  │ SST=1, SD=112233                         │ │      (millions of devices)
│  │ Low bandwidth, battery-efficient         │ │
│  └──────────────────────────────────────────┘ │
│                                               │
│  ┌──────────────────────────────────────────┐ │
│  │ Slice 3: Ultra-Reliable Low Latency      │ │  <-- Self-driving cars
│  │ SST=2                                    │ │      (critical, <1ms latency)
│  │ Guaranteed latency, high reliability     │ │
│  └──────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

**S-NSSAI** (Single Network Slice Selection Assistance Information):
- **SST** (Slice/Service Type): Category of slice (1=eMBB, 2=URLLC, 3=mIoT)
- **SD** (Slice Differentiator): Distinguishes slices within the same SST

**In our setup**: Two slices configured: SST=1/SD=010203 and SST=1/SD=112233.

---

### PCF - Policy Control Function

**What it does**: The PCF makes **policy decisions** - what QoS (Quality of Service) to give a subscriber, what their data limits are, etc.

**Real-world analogy**: PCF is the **rules engine**. It's like the manager who decides: "This customer has a premium plan, give them faster speeds" or "This IoT device only needs 1 Mbps."

**Responsibilities**:
- **Access & Mobility Policy**: Rules for registration and mobility
- **Session Policy**: QoS, data rate limits, allowed services per PDU session
- **UE Policy**: Rules pushed to the device itself

---

### CHF - Charging Function

**What it does**: The CHF handles **billing and charging** for subscriber usage.

**Real-world analogy**: CHF is the **billing department**. It tracks how much data you've used and charges accordingly (prepaid balance deduction or postpaid bill generation).

---

### NEF - Network Exposure Function

**What it does**: The NEF provides a **secure API gateway** for external applications to interact with the 5G network.

**Real-world analogy**: NEF is like an **API gateway** that lets third-party apps (e.g., a traffic management system) request network capabilities without directly accessing internal NFs.

---

### N3IWF - Non-3GPP Interworking Function

**What it does**: The N3IWF allows devices to connect to the 5G core network via **non-3GPP access** (like Wi-Fi) using IPsec tunnels.

**Real-world analogy**: If the normal entrance to a building is the 5G radio (gNB), the N3IWF is the **side entrance** that lets you in through Wi-Fi.

---

### WebUI - Web Console

**What it does**: A web-based admin console for managing subscribers (adding/editing/deleting SIM data).

**In our setup**: Accessible at `http://<server-ip>:5000`, login: admin/free5gc.

---

## How a Phone Connects to the 5G Network

Here's the complete flow when your phone (UE) turns on and connects to the internet:

### Phase 1: Registration (Getting on the network)

```
Step 1: UE ──(Uu radio)──> gNB: "I want to register"
        [RRC Setup Request]

Step 2: gNB ──(N2/NGAP)──> AMF: "New UE wants to register"
        [Initial UE Message with NAS Registration Request]

Step 3: AMF ──(SBI)──> AUSF: "Authenticate this SUCI"
Step 4: AUSF ──(SBI)──> UDM: "Generate auth vector for IMSI"
Step 5: UDM: Computes RAND, AUTN, XRES*, HXRES* using K and OPC
Step 6: UDM ──> AUSF ──> AMF: Auth Vector

Step 7: AMF ──(N2)──> gNB ──(Uu)──> UE: "Prove yourself"
        [Authentication Request with RAND, AUTN]

Step 8: UE: Verifies AUTN (proves network is real)
        UE: Computes RES* using K and RAND

Step 9: UE ──> gNB ──> AMF: "Here's my proof"
        [Authentication Response with RES*]

Step 10: AMF ──> AUSF: Verify RES* matches XRES*
Step 11: AUSF: "Authentication successful!"

Step 12: AMF ──> UE: Security Mode Command (start encryption)
Step 13: UE ──> AMF: Security Mode Complete

Step 14: AMF: Registration Accept
         UE is now REGISTERED on the network!
```

### Phase 2: PDU Session Establishment (Getting internet)

```
Step 1: UE ──> AMF: "I want internet access"
        [PDU Session Establishment Request, DNN="internet"]

Step 2: AMF ──> NSSF: "Which slice for this UE?"
Step 3: AMF ──> SMF: "Set up a PDU session"

Step 4: SMF ──> PCF: "What QoS rules for this subscriber?"
Step 5: PCF: "200 Mbps up, 100 Mbps down, QoS 5QI=9"

Step 6: SMF ──> UPF (via PFCP/N4): "Create forwarding rules"
        - Allocate IP: 10.60.0.1
        - Create GTP tunnel to gNB
        - Apply QoS rules

Step 7: SMF ──> AMF ──> gNB ──> UE: "Session established!"
        [PDU Session Establishment Accept with IP=10.60.0.1]

Step 8: gNB creates GTP-U tunnel to UPF on N3 interface

Now data flows:
UE ──(radio)──> gNB ──(GTP-U/N3)──> UPF ──(N6)──> Internet
```

### Phase 3: Data Flow (Browsing the internet)

```
Uplink (UE to Internet):
UE ──> gNB: IP packet [src=10.60.0.1, dst=8.8.8.8]
gNB: Encapsulate in GTP-U tunnel
gNB ──(N3)──> UPF: GTP-U packet
UPF: Decapsulate, apply rules, forward
UPF ──(N6)──> Internet: Raw IP packet

Downlink (Internet to UE):
Internet ──> UPF: IP packet [src=8.8.8.8, dst=10.60.0.1]
UPF: Look up forwarding rules, encapsulate in GTP-U
UPF ──(N3)──> gNB: GTP-U packet
gNB: Decapsulate, send over radio
gNB ──(Uu)──> UE: IP packet
```

---

## Key 5G Concepts You Must Know

### SUPI and SUCI

- **SUPI** (Subscription Permanent Identifier) = Your real identity (like IMSI: 208930000000001)
  - Format: `imsi-<MCC><MNC><MSIN>` = `imsi-208-93-0000000001`
- **SUCI** (Subscription Concealed Identifier) = Encrypted version of SUPI
  - 5G encrypts the SUPI before sending it over the air (privacy improvement over 4G)

### PLMN

**PLMN** (Public Land Mobile Network) identifies a mobile network operator:
- **MCC** (Mobile Country Code) = Country (208 = France, used for testing)
- **MNC** (Mobile Network Code) = Operator (93 = test network)
- Our PLMN: 208/93

### DNN (Data Network Name)

The DNN identifies which external network to connect to (equivalent to 4G's APN):
- `internet` = General internet access
- `ims` = IP Multimedia Subsystem (voice/video calls)

### 5QI (5G QoS Identifier)

The 5QI defines the QoS characteristics for a data flow:

| 5QI | Type | Latency | Use Case |
|-----|------|---------|----------|
| 1 | GBR | 100ms | Voice (VoNR) |
| 5 | Non-GBR | 100ms | IMS signaling |
| 9 | Non-GBR | 300ms | Video, web browsing (our config) |
| 69 | Non-GBR | 60ms | Mission-critical push-to-talk |
| 85 | Non-GBR | 5ms | Remote control, V2X |

### GTP-U (GPRS Tunneling Protocol - User Plane)

GTP-U creates tunnels to carry user data between the gNB and UPF. Each PDU session has its own GTP tunnel identified by a TEID (Tunnel Endpoint Identifier).

```
Original packet: [IP header][TCP/UDP][Data]

GTP-U tunnel:    [Outer IP][UDP:2152][GTP-U header][Inner IP][TCP/UDP][Data]
```

### PFCP (Packet Forwarding Control Protocol)

PFCP is the protocol between SMF and UPF (N4 interface). The SMF tells the UPF what to do with packets using PFCP rules:
- **PDR** (Packet Detection Rule): "Match packets from tunnel X"
- **FAR** (Forwarding Action Rule): "Forward matched packets to destination Y"
- **QER** (QoS Enforcement Rule): "Limit to 200 Mbps"
- **URR** (Usage Reporting Rule): "Report data usage every 1 GB"

### NGAP (Next Generation Application Protocol)

NGAP is the control plane protocol between gNB and AMF (N2 interface). It carries:
- NAS messages (Registration, Authentication, PDU Session)
- gNB management (NG Setup, UE Context)
- Handover procedures

It runs over **SCTP** (Stream Control Transmission Protocol) for reliability.

---

## The Protocol Stack

```
┌──────────────────────────────────────────────────────────┐
│                    Control Plane                          │
│                                                          │
│ UE          gNB              AMF         Other NFs       │
│ ┌─────┐    ┌─────┐         ┌──────┐    ┌──────────┐    │
│ │ NAS │    │     │         │ NAS  │    │          │    │
│ ├─────┤    │     │         ├──────┤    │ HTTP/2   │    │
│ │ RRC │<-->│ RRC │         │ NGAP │<-->│ (SBI)    │    │
│ ├─────┤    ├─────┤         ├──────┤    ├──────────┤    │
│ │PDCP │    │PDCP │         │ SCTP │    │ TCP      │    │
│ ├─────┤    ├─────┤         ├──────┤    ├──────────┤    │
│ │ RLC │    │ RLC │         │  IP  │    │   IP     │    │
│ ├─────┤    ├─────┤         ├──────┤    ├──────────┤    │
│ │ MAC │    │ MAC │         │ L2   │    │   L2     │    │
│ ├─────┤    ├─────┤         ├──────┤    ├──────────┤    │
│ │ PHY │<-->│ PHY │         │ L1   │    │   L1     │    │
│ └─────┘    └─────┘         └──────┘    └──────────┘    │
│   Uu          N2               SBI                      │
│ (Radio)    (SCTP)           (HTTP/2)                    │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│                     User Plane                            │
│                                                          │
│ UE          gNB              UPF          Internet        │
│ ┌─────┐    ┌─────┐         ┌──────┐    ┌──────────┐    │
│ │ App │    │     │         │      │    │          │    │
│ ├─────┤    │     │         │      │    │   App    │    │
│ │ IP  │    │ GTP-U│<------>│GTP-U │    ├──────────┤    │
│ ├─────┤    ├─────┤         ├──────┤    │   IP     │    │
│ │SDAP │    │SDAP │         │ UDP  │    ├──────────┤    │
│ ├─────┤    ├─────┤         ├──────┤    │   L2     │    │
│ │PDCP │    │PDCP │         │  IP  │    ├──────────┤    │
│ ├─────┤    ├─────┤         ├──────┤    │   L1     │    │
│ │ RLC │    │ RLC │         │ L2   │    └──────────┘    │
│ ├─────┤    ├─────┤         ├──────┤                     │
│ │ MAC │    │ MAC │         │ L1   │                     │
│ ├─────┤    ├─────┤         └──────┘                     │
│ │ PHY │<-->│ PHY │                                      │
│ └─────┘    └─────┘                                      │
│   Uu          N3              N6                        │
│ (Radio)    (GTP-U)         (IP)                         │
└──────────────────────────────────────────────────────────┘
```

---

## How free5GC Maps to Real 5G

| free5GC Component | Real-world Equivalent | Vendor Examples |
|---|---|---|
| `amf` container | AMF server | Nokia AMF, Ericsson AMF |
| `smf` container | SMF server | Nokia SMF, Huawei SMF |
| `upf` container + gtp5g | UPF appliance | Ericsson UPF, Cisco UPF |
| `nrf` container | NRF server | Usually part of vendor platform |
| `ausf` container | Authentication server | Part of subscriber management |
| `udm`/`udr` + MongoDB | Subscriber database (UDR/UDM) | Oracle UDR, Nokia UDM |
| `nssf` container | Slice management | Part of orchestration platform |
| `pcf` container | Policy engine | Nokia PCF, Ericsson PCRF |
| `chf` container | Charging/billing system | Ericsson OCS, Nokia CBS |
| `ueransim` container | Real gNB + test UE | Nokia AirScale, Ericsson RAN |
| `webui` container | OSS/BSS admin console | Vendor-specific NMS |

### What's Different in Our Lab vs Production?

| Aspect | Our Lab (free5GC) | Production |
|--------|-------------------|------------|
| Radio | Simulated (UERANSIM) | Real RF hardware |
| Scale | 1 UE, 1 gNB | Millions of UEs, thousands of gNBs |
| UPF | Software (gtp5g) | Hardware-accelerated (DPDK, SmartNIC) |
| Database | Single MongoDB | Clustered, geo-redundant |
| Redundancy | Single instance | Active-active, auto-failover |
| Deployment | Docker Compose | Kubernetes with Helm charts |
| Security | Self-signed certs | PKI with HSM |

---

## What's Next?

Now that you understand the components, proceed to:
- [02-SETUP-GUIDE.md](02-SETUP-GUIDE.md) - Step-by-step installation
- [03-TESTING-GUIDE.md](03-TESTING-GUIDE.md) - Testing and verification
