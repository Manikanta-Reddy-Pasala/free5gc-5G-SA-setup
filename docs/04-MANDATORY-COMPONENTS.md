# Mandatory Components - Minimum Viable 5G Core

## Overview

A working 5G Standalone (SA) core network requires **10 mandatory containers** for free5GC v4.2.0. This is the absolute minimum to achieve:

- UE registration (authentication)
- PDU session establishment (internet connectivity)
- Uplink/downlink data transfer

> **Important: 3GPP vs free5GC Reality**
>
> While 3GPP TS 23.501 considers NSSF and PCF as optional network functions, **free5GC v4.2.0 requires both**:
> - **Without PCF**: AMF fails with `"AMF can not select an PCF by NRF"` during UE registration
> - **Without NSSF**: AMF fails with `"AMF can not select an NSSF by NRF"` during PDU session establishment
>
> This was confirmed through testing on a live deployment. The theoretical 3GPP minimum of 8 NFs does **not** work with free5GC v4.2.0.

This document explains each component, why it's mandatory, and the complete end-to-end flow from UE power-on to internet browsing.

---

## The 10 Required Containers

### 1. MongoDB (mongo:4.4)

**Purpose**: Persistent storage for all subscriber data, policy data, and network function profiles.

**Configuration**: None required - runs standard `mongod` on port 27017.

**Why Mandatory**: UDR (User Data Repository) stores all subscriber information here. Without MongoDB, there's no way to authenticate users or retrieve their subscription data.

**Key Data Stored**:
- Subscriber credentials (K, OPC, SQN for 5G-AKA authentication)
- Subscriber profile (allowed DNNs, QoS, session AMBR)
- Network function profiles registered via NRF

---

### 2. NRF (free5gc/nrf:v4.2.0)

**Purpose**: Network Function Repository Function - service discovery registry for all network functions.

**Configuration**: `config/nrfcfg.yaml`

```yaml
nrfName: NRF
sbi:
  bindingIPv4: 0.0.0.0
  port: 8000
  registerIPv4: nrf.free5gc.org
MongoDBUrl: mongodb://mongodb:27017
```

**Why Mandatory**: All network functions (AMF, SMF, UDM, AUSF, UDR, UPF) register with NRF on startup. When AMF needs to find AUSF or when SMF needs to find UPF, they query NRF. Without NRF, network functions cannot discover each other.

**What It Does**:
- NF registration: Each NF sends HTTP/2 POST to NRF with its profile (type, address, supported services)
- NF discovery: NFs query NRF to find other NFs (e.g., "find me an AUSF for PLMN 208/93")
- NF status monitoring: Heartbeat mechanism to detect failed NFs

---

### 3. AMF (free5gc/amf:v4.2.0)

**Purpose**: Access and Mobility Management Function - the "front door" of the 5G core, handling all UE connections.

**Configuration**: `config/amfcfg.yaml`

```yaml
amfName: AMF
ngapIpList:
  - 192.168.0.8  # SCTP address for gNB connections
sbi:
  bindingIPv4: 0.0.0.0
  port: 8000
  registerIPv4: amf.free5gc.org
serviceNameList:
  - namf-comm
  - namf-evts
  - namf-mt
plmnSupportList:
  - plmnId:
      mcc: 208
      mnc: 93
    snssaiList:
      - sst: 1
        sd: 010203
      - sst: 1
        sd: 112233
supportTaiList:
  - plmnId:
      mcc: 208
      mnc: 93
    tac: 000001
```

**Why Mandatory**: AMF is the entry point for all UE signaling. It:
- Accepts N2 SCTP connections from gNB on port 38412
- Routes registration/authentication requests to AUSF/UDM
- Manages UE mobility (tracking areas, handovers)
- Coordinates PDU session establishment with SMF

**Key Interfaces**:
- **N1**: NAS signaling with UE (via gNB)
- **N2**: NGAP signaling with gNB (SCTP:38412)
- **SBI**: HTTP/2 with AUSF, UDM, SMF, NRF

---

### 4. AUSF (free5gc/ausf:v4.2.0)

**Purpose**: Authentication Server Function - orchestrates 5G-AKA authentication.

**Configuration**: `config/ausfcfg.yaml`

```yaml
ausfName: AUSF
sbi:
  bindingIPv4: 0.0.0.0
  port: 8000
  registerIPv4: ausf.free5gc.org
plmnSupportList:
  - mcc: 208
    mnc: 93
```

**Why Mandatory**: AUSF implements the 5G authentication protocol (5G-AKA). It:
- Receives authentication requests from AMF
- Coordinates with UDM to compute authentication vectors (RAND, AUTN, XRES*)
- Verifies UE's authentication response (RES* matches XRES*)
- Cannot be replaced by any other NF

**Authentication Flow**:
1. AMF → AUSF: "Authenticate SUPI imsi-208930000000001"
2. AUSF → UDM: "Get me auth vectors for this SUPI"
3. UDM → AUSF: Returns (RAND, AUTN, XRES*, KAUSF)
4. AUSF → AMF: Returns (RAND, AUTN) for UE challenge
5. AMF → AUSF: UE responded with RES*
6. AUSF verifies: RES* == XRES* → authentication success

---

### 5. UDM (free5gc/udm:v4.2.0)

**Purpose**: Unified Data Management - computes authentication vectors and manages subscription data.

**Configuration**: `config/udmcfg.yaml`

```yaml
udmName: UDM
sbi:
  bindingIPv4: 0.0.0.0
  port: 8000
  registerIPv4: udm.free5gc.org
plmnList:
  - plmnId:
      mcc: 208
      mnc: 93
```

**Why Mandatory**: UDM is the cryptographic engine and subscriber profile manager. It:
- Retrieves subscriber keys (K, OPC) from UDR
- Computes 5G-AKA authentication vectors using MILENAGE algorithm
- Provides subscriber profile to SMF (allowed DNNs, QoS, session AMBR)
- Cannot be skipped - authentication requires cryptographic computation

**Key Functions**:
- **Nudm_UEAuthentication**: Computes (RAND, AUTN, XRES*, KAUSF) from subscriber keys
- **Nudm_SubscriberDataManagement**: Returns subscriber profile (DNNs, slices, QoS)

---

### 6. UDR (free5gc/udr:v4.2.0)

**Purpose**: Unified Data Repository - database access layer for subscriber data.

**Configuration**: `config/udrcfg.yaml`

```yaml
udrName: UDR
sbi:
  bindingIPv4: 0.0.0.0
  port: 8000
  registerIPv4: udr.free5gc.org
mongodb:
  name: free5gc
  url: mongodb://mongodb:27017
```

**Why Mandatory**: UDR is the ONLY network function that reads/writes MongoDB. All subscriber data access goes through UDR. Without UDR:
- UDM cannot retrieve subscriber keys (K, OPC, SQN)
- SMF cannot retrieve session management subscription data
- No authentication or session establishment possible

**Data Model**:
```json
{
  "ueId": "imsi-208930000000001",
  "authenticationSubscription": {
    "authenticationManagementField": "8000",
    "authenticationMethod": "5G_AKA",
    "permanentKey": {
      "permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862"
    },
    "opc": {
      "opcValue": "8e27b6af0e692e750f32667a3b14605d"
    },
    "sequenceNumber": "000000000020"
  },
  "sessionManagementSubscriptionData": {
    "dnnConfigurations": {
      "internet": {
        "sscModes": {"defaultSscMode": "SSC_MODE_1"},
        "sessionAmbr": {"uplink": "200 Mbps", "downlink": "100 Mbps"},
        "5gQosProfile": {"5qi": 9}
      }
    }
  }
}
```

---

### 7. SMF (free5gc/smf:v4.2.0)

**Purpose**: Session Management Function - allocates IP addresses, manages PDU sessions, controls UPF.

**Configuration**: `config/smfcfg.yaml`

```yaml
smfName: SMF
sbi:
  bindingIPv4: 0.0.0.0
  port: 8000
  registerIPv4: smf.free5gc.org
pfcp:
  listenAddr: 192.168.0.6
  nodeID: 192.168.0.6
userplaneInformation:
  upNodes:
    UPF:
      type: UPF
      nodeID: 192.168.0.5
  links:
    - A: gNB1
      B: UPF
snssaiInfos:
  - sNssai:
      sst: 1
      sd: 010203
    dnnInfos:
      - dnn: internet
        dns:
          ipv4: 8.8.8.8
  - sNssai:
      sst: 1
      sd: 112233
    dnnInfos:
      - dnn: internet
        dns:
          ipv4: 8.8.8.8
ueSubnet: 10.60.0.0/16
```

**Why Mandatory**: SMF is the control plane for user sessions. It:
- Allocates UE IP addresses from pool (10.60.0.0/16 or 10.61.0.0/16)
- Retrieves subscriber session profile from UDM (allowed DNNs, QoS)
- Programs UPF with forwarding rules via PFCP (N4 interface)
- Manages session lifecycle (establishment, modification, release)

**Key Interfaces**:
- **N4**: PFCP with UPF (UDP:8805) - programs forwarding rules
- **SBI**: HTTP/2 with AMF, UDM, NRF

---

### 8. UPF (free5gc/upf:v4.2.0)

**Purpose**: User Plane Function - the data plane, forwards actual user traffic between gNB and internet.

**Configuration**: `config/upfcfg.yaml`

```yaml
pfcp:
  listenAddr: 192.168.0.5
  nodeID: 192.168.0.5
gtpu:
  forwarder: gtp5g
  ifList:
    - addr: 192.168.0.5
      type: N3
      name: upfgtp
      ifname: eth0
dnn_list:
  - dnn: internet
    cidr: 10.60.0.0/16
```

**Why Mandatory**: UPF is the actual packet gateway. Without UPF:
- No data forwarding between gNB and internet
- UE can register but cannot send/receive any data

**Key Functions**:
- Receives GTP-U encapsulated packets from gNB (N3, UDP:2152)
- Strips GTP-U header, extracts inner IP packet
- Performs NAT and forwards to internet (N6)
- Encapsulates downlink packets in GTP-U and sends to gNB

**Kernel Module Required**: UPF requires the **GTP5G kernel module** for high-performance packet processing:

```bash
git clone -b v0.9.5 https://github.com/free5gc/gtp5g.git
cd gtp5g
make clean && make
sudo make install
```

**Container Capabilities**: UPF needs `NET_ADMIN` capability to create GTP-U tunnels:

```yaml
cap_add:
  - NET_ADMIN
```

### 9. NSSF (free5gc/nssf:v4.2.0)

**Purpose**: Network Slice Selection Function - centralized slice selection for UE registration and PDU sessions.

**Configuration**: `config/nssfcfg.yaml`

```yaml
nssfName: NSSF
sbi:
  bindingIPv4: 0.0.0.0
  port: 8000
  registerIPv4: nssf.free5gc.org
nrfUri: http://nrf.free5gc.org:8000
nsiList:
  - snssai:
      sst: 1
      sd: "010203"
    nsiInformationList:
      - nrfId: http://nrf.free5gc.org:8000/nnrf-nfm/v1/nf-instances
        nsiId: "10"
  - snssai:
      sst: 1
      sd: "112233"
    nsiInformationList:
      - nrfId: http://nrf.free5gc.org:8000/nnrf-nfm/v1/nf-instances
        nsiId: "11"
```

**Why Mandatory in free5GC v4.2.0**: Although 3GPP considers NSSF optional, free5GC's AMF implementation **requires** NSSF to be registered with NRF. Without it:
- PDU session establishment fails with `"AMF can not select an NSSF Instance by NRF"`
- UE can register but cannot establish data sessions

**What It Does**:
- Maps requested S-NSSAI to Network Slice Instances (NSI)
- Determines which AMF set should serve the UE
- Points to the correct NRF instance per slice
- Manages Tracking Area to slice availability mapping

---

### 10. PCF (free5gc/pcf:v4.2.0)

**Purpose**: Policy Control Function - provides access and session management policies.

**Configuration**: `config/pcfcfg.yaml`

```yaml
pcfName: PCF
sbi:
  bindingIPv4: 0.0.0.0
  port: 8000
  registerIPv4: pcf.free5gc.org
nrfUri: http://nrf.free5gc.org:8000
serviceList:
  - serviceName: npcf-am-policy-control
  - serviceName: npcf-smpolicycontrol
    suppressNfDiscovery: true
  - serviceName: npcf-bdtpolicycontrol
  - serviceName: npcf-policyauthorization
    suppressNfDiscovery: true
  - serviceName: npcf-eventexposure
  - serviceName: npcf-ue-policy-control
```

**Why Mandatory in free5GC v4.2.0**: Although 3GPP considers PCF optional, free5GC's AMF implementation **requires** PCF to be registered with NRF. Without it:
- UE registration fails with `"AMF can not select an PCF by NRF"`
- No UE can register at all

**What It Does**:
- Provides AM (Access and Mobility) policies during UE registration
- Provides SM (Session Management) policies during PDU session setup
- Enforces QoS rules, bandwidth limits, and PCC rules
- Supports usage monitoring and policy triggers

---

## What's NOT Included and Impact

### CHF (Charging Function)

**Status**: Optional unless billing is required

**Impact**: No charging records generated, no billing. For production carrier networks, CHF is mandatory. For lab/testing, not needed.

---

### NEF (Network Exposure Function)

**Status**: Optional unless external API exposure is needed

**Impact**: No external API for 3rd-party applications to interact with 5G core (e.g., "trigger UE location update", "modify QoS for this session"). Required for edge computing, IoT platforms, enterprise APIs.

---

### N3IWF / TNGF

**Status**: Optional unless non-3GPP access is required

**Impact**: No Wi-Fi or wireline access to 5G core. UEs can only connect via 3GPP radio (gNB). Required for Wi-Fi calling, fixed wireless access (FWA).

---

### WebUI (free5gc/webconsole:v2.2.0)

**Status**: Optional - convenience tool, not a network function

**Impact**: Subscriber management must be done via MongoDB shell or HTTP API. WebUI is just a friendly web interface to add/edit subscribers, view registered UEs, etc.

**Workaround**: Direct MongoDB operations (see section below).

---

## How to Run (Minimal Deployment)

The repository includes `docker-compose-minimal.yaml` with only the 10 mandatory containers plus UERANSIM for testing:

```bash
# Start minimal 5G core (11 containers total: 10 core + UERANSIM)
docker compose -f docker-compose-minimal.yaml up -d

# Check all containers are running
docker compose -f docker-compose-minimal.yaml ps

# View logs
docker compose -f docker-compose-minimal.yaml logs -f amf
docker compose -f docker-compose-minimal.yaml logs -f smf

# Stop
docker compose -f docker-compose-minimal.yaml down
```

**Container List**:
1. mongodb
2. nrf
3. amf
4. ausf
5. udm
6. udr
7. smf
8. upf
9. nssf (required by AMF in free5GC v4.2.0)
10. pcf (required by AMF in free5GC v4.2.0)
11. ueransim (for testing - includes both gNB and UE)

---

## Complete UE-to-Core Flow (Step by Step)

This section explains the **complete end-to-end flow** from when a UE powers on to when it successfully browses the internet, involving ONLY the 8 mandatory network functions.

---

### Phase 1: NF Startup & Service Discovery

**Timeline**: Container startup (first 10 seconds)

1. **MongoDB starts** (container `mongodb`)
   - Listens on port 27017
   - Creates database `free5gc` if not exists
   - Ready to accept connections

2. **NRF starts** (container `nrf`)
   - Connects to MongoDB at `mongodb://mongodb:27017`
   - Binds HTTP/2 SBI server on `0.0.0.0:8000`
   - Registers itself with identifier `nrf.free5gc.org`
   - Log: `NRF service started`

3. **UDR starts** (container `udr`)
   - Connects to MongoDB at `mongodb://mongodb:27017`
   - Binds HTTP/2 SBI server on `0.0.0.0:8000`
   - Sends HTTP/2 PUT to NRF: `http://nrf.free5gc.org:8000/nnrf-nfm/v1/nf-instances/{uuid}`
   - Body: `{ "nfType": "UDR", "nfStatus": "REGISTERED", "ipv4Addresses": ["udr.free5gc.org"], "udrInfo": {...} }`
   - NRF stores UDR profile in MongoDB collection `NfProfile`
   - Log: `UDR registered to NRF successfully`

4. **UDM starts** (container `udm`)
   - Binds HTTP/2 SBI server on `0.0.0.0:8000`
   - Registers with NRF (same process as UDR)
   - Queries NRF to discover UDR: `GET http://nrf.free5gc.org:8000/nnrf-disc/v1/nf-instances?target-nf-type=UDR`
   - NRF returns: `{ "nfInstances": [{ "nfInstanceId": "...", "nfType": "UDR", "ipv4Addresses": ["udr.free5gc.org"], ... }] }`
   - UDM caches UDR address
   - Log: `UDM discovered UDR at udr.free5gc.org:8000`

5. **AUSF starts** (container `ausf`)
   - Registers with NRF
   - Discovers UDM via NRF
   - Log: `AUSF discovered UDM at udm.free5gc.org:8000`

6. **AMF starts** (container `amf`)
   - Binds SCTP server on `192.168.0.8:38412` (for gNB N2 connections)
   - Binds HTTP/2 SBI server on `0.0.0.0:8000`
   - Registers with NRF with PLMN 208/93, TAC 1, supported slices (SST=1/SD=010203, SST=1/SD=112233)
   - Discovers AUSF and UDM via NRF
   - Log: `AMF registered to NRF successfully`, `AMF discovered AUSF at ausf.free5gc.org:8000`, `AMF discovered UDM at udm.free5gc.org:8000`

7. **UPF starts** (container `upf`)
   - Loads GTP5G kernel module: `modprobe gtp5g`
   - Creates GTP-U tunnel interface `upfgtp` on eth0 (192.168.0.5)
   - Binds PFCP server on `192.168.0.5:8805` (for SMF N4 connections)
   - Registers with NRF
   - Log: `UPF service started`, `PFCP server listening on 192.168.0.5:8805`

8. **SMF starts** (container `smf`)
   - Binds PFCP client on `192.168.0.6:8805`
   - Registers with NRF with DNN `internet`, slices (SST=1/SD=010203, SST=1/SD=112233)
   - Discovers UPF via NRF: `GET http://nrf.free5gc.org:8000/nnrf-disc/v1/nf-instances?target-nf-type=UPF`
   - Sends PFCP Association Setup Request to UPF at `192.168.0.5:8805`
   - UPF responds with PFCP Association Setup Response
   - SMF stores UPF node ID (192.168.0.5) and capabilities
   - Discovers UDM via NRF
   - Log: `SMF established PFCP association with UPF at 192.168.0.5`, `SMF discovered UDM at udm.free5gc.org:8000`

**Result**: All 10 NFs are running, registered with NRF, and know how to reach each other. NRF's MongoDB `NfProfile` collection contains 9 entries (UDR, UDM, AUSF, AMF, SMF, UPF, NSSF, PCF, NRF itself).

---

### Phase 2: gNB Connection (N2 Setup)

**Timeline**: When UERANSIM gNB container starts

1. **gNB initiates SCTP association**
   - gNB (192.168.0.10) opens SCTP connection to AMF (192.168.0.8:38412)
   - SCTP 4-way handshake: INIT → INIT-ACK → COOKIE-ECHO → COOKIE-ACK
   - Log (AMF): `SCTP association established with gNB at 192.168.0.10:36412`

2. **gNB sends NGSetupRequest**
   - NGAP message with:
     - Global gNB ID: `{ mcc: 208, mnc: 93, gnbId: 1 }`
     - Supported TACs: `[1]`
     - Supported PLMNs: `[{ mcc: 208, mnc: 93 }]`
     - Supported slices (S-NSSAIs): `[{ sst: 1, sd: 010203 }, { sst: 1, sd: 112233 }]`
   - Raw NGAP: `NGSetupRequest ::= { globalRAN-NodeID: { globalGNB-ID: { plmnIdentity: '208F930'H, gNB-ID: 1 } }, supportedTAList: [{ tac: '000001'H, broadcastPLMNList: [{ plmnIdentity: '208F930'H, taiSliceSupportList: [{ s-NSSAI: { sst: 1, sd: '010203'H } }, { s-NSSAI: { sst: 1, sd: '112233'H } }] }] }] }`

3. **AMF validates gNB configuration**
   - Checks PLMN: Does `208/93` match AMF's `plmnSupportList`? YES
   - Checks TAC: Does `1` match AMF's `supportTaiList`? YES
   - Checks slices: Are `SST=1/SD=010203` and `SST=1/SD=112233` in AMF's `snssaiList`? YES
   - All checks pass → gNB is authorized

4. **AMF responds with NGSetupResponse**
   - NGAP message with:
     - AMF name: `free5gc`
     - GUAMI (Globally Unique AMF ID): `{ plmnId: { mcc: 208, mnc: 93 }, amfId: '000001' }`
     - Relative AMF capacity: 255 (max)
     - Served PLMNs: `[{ plmnId: { mcc: 208, mnc: 93 }, supportedSlices: [...] }]`
   - Log (AMF): `Accepted NGSetup from gNB 208-93-1`

5. **N2 interface established**
   - gNB is now registered with AMF
   - gNB can forward UE NAS messages to AMF
   - AMF can send paging/handover commands to gNB

**ASCII Diagram**:
```
gNB (192.168.0.10:36412) ──SCTP──> AMF (192.168.0.8:38412)
                         NGSetupRequest
                         (PLMN=208/93, TAC=1, slices)
                         <───────────
                         NGSetupResponse
                         (AMF name, GUAMI)
```

---

### Phase 3: UE Registration (Authentication)

**Timeline**: When UE powers on or executes `./nr-ue`

1. **UE sends Registration Request**
   - NAS message (over RRC/Uu interface to gNB):
     - Message type: `REGISTRATION REQUEST`
     - Registration type: `initial registration`
     - SUCI (concealed SUPI): `suci-0-208-93-0-0-0-0-1` (encrypts SUPI `imsi-208930000000001`)
     - 5G-GUTI: none (first registration)
     - Last visited TAI: none
   - Log (UE): `Sending Initial Registration`

2. **gNB forwards to AMF via N2**
   - gNB wraps NAS message in NGAP `InitialUEMessage`:
     - RAN-UE-NGAP-ID: 1 (local UE identifier for this gNB)
     - NAS-PDU: [Registration Request bytes]
     - User location: `{ tac: 1, nr-CGI: { plmn: 208/93, cellId: 1 } }`
     - RRC establishment cause: `mo-Signalling` (mobile-originated signaling)
   - Sends via SCTP to AMF (192.168.0.8:38412)
   - Log (gNB): `InitialUEMessage sent to AMF for UE RAN-ID 1`

3. **AMF extracts SUPI from SUCI**
   - Decrypts SUCI using home network private key → SUPI: `imsi-208930000000001`
   - Allocates AMF-UE-NGAP-ID: 1 (AMF's local UE identifier)
   - Creates UE context: `{ ranUeNgapId: 1, amfUeNgapId: 1, supi: imsi-208930000000001, plmn: 208/93, tai: 1 }`
   - Log (AMF): `Registration request for SUPI imsi-208930000000001`

4. **AMF queries NRF to find AUSF**
   - HTTP/2 GET: `http://nrf.free5gc.org:8000/nnrf-disc/v1/nf-instances?target-nf-type=AUSF&requester-nf-type=AMF&supi=imsi-208930000000001`
   - NRF searches `NfProfile` collection for `nfType: AUSF`, matching PLMN 208/93
   - Returns: `{ "nfInstances": [{ "nfInstanceId": "...", "ipv4Addresses": ["ausf.free5gc.org"], "port": 8000, ... }] }`
   - Log (AMF): `Discovered AUSF at ausf.free5gc.org:8000`

5. **AMF sends authentication request to AUSF**
   - HTTP/2 POST: `http://ausf.free5gc.org:8000/nausf-auth/v1/ue-authentications`
   - Body: `{ "supiOrSuci": "suci-0-208-93-0-0-0-0-1", "servingNetworkName": "5G:mnc093.mcc208.3gppnetwork.org", "resynchronizationInfo": null }`
   - Log (AMF): `Initiating authentication for imsi-208930000000001 via AUSF`

6. **AUSF queries NRF to find UDM**
   - HTTP/2 GET: `http://nrf.free5gc.org:8000/nnrf-disc/v1/nf-instances?target-nf-type=UDM&requester-nf-type=AUSF&supi=imsi-208930000000001`
   - NRF returns UDM address: `udm.free5gc.org:8000`
   - Log (AUSF): `Discovered UDM at udm.free5gc.org:8000`

7. **AUSF sends authentication request to UDM**
   - HTTP/2 POST: `http://udm.free5gc.org:8000/nudm-ueau/v1/imsi-208930000000001/security-information/generate-auth-data`
   - Body: `{ "servingNetworkName": "5G:mnc093.mcc208.3gppnetwork.org", "ausfInstanceId": "...", "authenticationMethod": "5G_AKA" }`
   - Log (AUSF): `Requesting auth vectors from UDM for imsi-208930000000001`

8. **UDM queries NRF to find UDR**
   - HTTP/2 GET: `http://nrf.free5gc.org:8000/nnrf-disc/v1/nf-instances?target-nf-type=UDR&requester-nf-type=UDM`
   - NRF returns: `udr.free5gc.org:8000`
   - Log (UDM): `Discovered UDR at udr.free5gc.org:8000`

9. **UDM sends request to UDR for subscriber keys**
   - HTTP/2 GET: `http://udr.free5gc.org:8000/nudr-dr/v1/subscription-data/imsi-208930000000001/authentication-data/authentication-subscription`
   - Log (UDM): `Fetching authentication subscription for imsi-208930000000001 from UDR`

10. **UDR reads from MongoDB**
    - MongoDB query: `db.subscriptionData.authenticationData.authenticationSubscription.find({ ueId: "imsi-208930000000001" })`
    - Returns:
      ```json
      {
        "ueId": "imsi-208930000000001",
        "authenticationMethod": "5G_AKA",
        "permanentKey": {
          "permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862",
          "encryptionKey": 0,
          "encryptionAlgorithm": 0
        },
        "opc": {
          "opcValue": "8e27b6af0e692e750f32667a3b14605d",
          "encryptionKey": 0,
          "encryptionAlgorithm": 0
        },
        "sequenceNumber": "000000000020"
      }
      ```
    - Log (UDR): `Retrieved authentication data for imsi-208930000000001`

11. **UDR returns subscriber data to UDM**
    - HTTP/2 200 OK with above JSON body
    - Log (UDR): `Returned authentication subscription to UDM`

12. **UDM computes 5G-AKA authentication vectors**
    - Inputs:
      - K (permanent key): `8baf473f2f8fd09487cccbd7097c6862`
      - OPC (operator key): `8e27b6af0e692e750f32667a3b14605d`
      - SQN (sequence number): `0x000000000020` (hex) = 32 (decimal)
      - AMF (auth management field): `0x8000` (from config)
      - Serving network: `5G:mnc093.mcc208.3gppnetwork.org`
    - MILENAGE algorithm (3GPP TS 35.205-206):
      - Generate RAND (128-bit random): `e.g., 465b5ce8b199b49faa5f0a2ee238a6bc`
      - Compute MAC-A: `f1(K, RAND, SQN || AMF || SQN || AMF)`
      - Compute RES: `f2(K, RAND)` → `e.g., 88d4834d89c7e68d`
      - Compute CK (cipher key): `f3(K, RAND)`
      - Compute IK (integrity key): `f4(K, RAND)`
      - Compute AK (anonymity key): `f5(K, RAND)`
      - Derive AUTN: `SQN ⊕ AK || AMF || MAC-A` → `e.g., 8011dc10fe7d1d3b2080faae0a2f3c32`
      - Derive RES* (5G): `KDF(CK || IK, serving network, RAND, RES)` → `e.g., a03c7d85e15ae4c07b3d370d19d35d9a`
      - Derive XRES* (expected response): `KDF(RES*, ...)` → `e.g., a03c7d85e15ae4c07b3d370d19d35d9a` (same as RES* in 5G-AKA)
      - Derive KAUSF (root key): `KDF(CK || IK, serving network, SQN ⊕ AK)`
    - Increment SQN: `0x000000000020` → `0x000000000021`
    - Update SQN in MongoDB via UDR
    - Log (UDM): `Computed auth vectors for imsi-208930000000001, SQN updated to 0x21`

13. **UDM returns authentication vectors to AUSF**
    - HTTP/2 200 OK with body:
      ```json
      {
        "authType": "5G_AKA",
        "rand": "465b5ce8b199b49faa5f0a2ee238a6bc",
        "autn": "8011dc10fe7d1d3b2080faae0a2f3c32",
        "xresStar": "a03c7d85e15ae4c07b3d370d19d35d9a",
        "kausf": "..."
      }
      ```
    - Log (UDM): `Returned auth vectors to AUSF`

14. **AUSF stores XRES* for later verification**
    - Saves in local cache: `{ supi: imsi-208930000000001, xresStar: a03c7d85e15ae4c07b3d370d19d35d9a, kausf: ... }`
    - Log (AUSF): `Stored XRES* for imsi-208930000000001`

15. **AUSF returns challenge to AMF**
    - HTTP/2 200 OK with body:
      ```json
      {
        "authType": "5G_AKA",
        "rand": "465b5ce8b199b49faa5f0a2ee238a6bc",
        "autn": "8011dc10fe7d1d3b2080faae0a2f3c32",
        "_links": {
          "5g-aka": {
            "href": "http://ausf.free5gc.org:8000/nausf-auth/v1/ue-authentications/{authCtxId}/5g-aka-confirmation"
          }
        }
      }
      ```
    - Log (AUSF): `Returned auth challenge (RAND, AUTN) to AMF`

16. **AMF sends Authentication Request to UE**
    - NAS message:
      - Message type: `AUTHENTICATION REQUEST`
      - ngKSI (key set identifier): 0
      - RAND: `465b5ce8b199b49faa5f0a2ee238a6bc`
      - AUTN: `8011dc10fe7d1d3b2080faae0a2f3c32`
    - Wrapped in NGAP `DownlinkNASTransport` with `amfUeNgapId: 1`, `ranUeNgapId: 1`
    - Sent via SCTP to gNB (192.168.0.8:38412 → 192.168.0.10:36412)
    - gNB forwards NAS message to UE via RRC/Uu (radio)
    - Log (AMF): `Sent Authentication Request to UE (RAND, AUTN)`

17. **UE computes RES***
    - UE has same K and OPC in its USIM/config
    - MILENAGE algorithm:
      - Verify AUTN: Extract `SQN ⊕ AK` and MAC-A from AUTN, compute MAC-A locally, compare → MATCH (authentication accepted)
      - Compute RES: `f2(K, RAND)` → `88d4834d89c7e68d`
      - Compute CK: `f3(K, RAND)`
      - Compute IK: `f4(K, RAND)`
      - Derive RES*: `KDF(CK || IK, serving network, RAND, RES)` → `a03c7d85e15ae4c07b3d370d19d35d9a`
      - Derive KAUSF: `KDF(CK || IK, serving network, SQN ⊕ AK)`
    - Log (UE): `Authentication challenge accepted, computed RES*`

18. **UE sends Authentication Response**
    - NAS message:
      - Message type: `AUTHENTICATION RESPONSE`
      - RES*: `a03c7d85e15ae4c07b3d370d19d35d9a`
    - Sent via RRC/Uu to gNB, gNB wraps in NGAP `UplinkNASTransport`, forwards to AMF
    - Log (UE): `Sent Authentication Response (RES*)`

19. **AMF forwards RES* to AUSF**
    - HTTP/2 PUT: `http://ausf.free5gc.org:8000/nausf-auth/v1/ue-authentications/{authCtxId}/5g-aka-confirmation`
    - Body: `{ "resStar": "a03c7d85e15ae4c07b3d370d19d35d9a" }`
    - Log (AMF): `Forwarding authentication response to AUSF`

20. **AUSF verifies RES* against XRES***
    - Retrieves stored XRES* from cache: `a03c7d85e15ae4c07b3d370d19d35d9a`
    - Compares: `resStar == xresStar` → **MATCH**
    - Authentication SUCCESS
    - Returns KAUSF and SUPI to AMF
    - Log (AUSF): `Authentication successful for imsi-208930000000001`

21. **AMF derives NAS security keys**
    - Computes KAMF: `KDF(KAUSF, SUPI, ABBA)`
    - Computes NAS encryption key (Kenc): `KDF(KAMF, algorithm-id, ...)`
    - Computes NAS integrity key (Kint): `KDF(KAMF, algorithm-id, ...)`
    - Log (AMF): `NAS security context established`

22. **AMF sends Registration Accept to UE**
    - NAS message (NAS-MAC protected and encrypted):
      - Message type: `REGISTRATION ACCEPT`
      - 5G-GUTI: `guti-208-93-1-0-1` (newly allocated)
      - TAI list: `[{ plmn: 208/93, tac: 1 }]`
      - Allowed NSSAI: `[{ sst: 1, sd: 010203 }, { sst: 1, sd: 112233 }]`
    - Wrapped in NGAP `DownlinkNASTransport`, sent via N2 to gNB
    - gNB forwards to UE via Uu
    - Log (AMF): `Sent Registration Accept to UE, assigned 5G-GUTI`

23. **UE is now RM-REGISTERED**
    - UE state: `5GMM-REGISTERED`
    - UE has 5G-GUTI, allowed slices, TAI list
    - UE can now request PDU session establishment
    - Log (UE): `Registration complete, state: RM-REGISTERED`

**ASCII Flow**:
```
UE ─radio(Uu)─> gNB ─N2/SCTP─> AMF ─SBI─> AUSF ─SBI─> UDM ─SBI─> UDR ─MongoDB query─> MongoDB
                                 ↓                      ↓                ↓                    ↓
                        1. Registration Req     2. Get auth vec  3. Get keys       4. Returns K, OPC, SQN
                                 ↓                      ↑                ↑                    ↑
                        5. Challenge (RAND, AUTN) <─────────────────────┘─────────(compute XRES*, KAUSF)
                                 ↓
UE computes RES* from RAND+AUTN  |
                                 ↓
UE ─Uu─> gNB ─N2─> AMF ─SBI─> AUSF (verify RES* == XRES*) → SUCCESS → Registration Accept
```

---

### Phase 4: PDU Session Establishment (Getting Internet)

**Timeline**: Immediately after registration (or triggered by user opening browser)

1. **UE sends PDU Session Establishment Request**
   - NAS message:
     - Message type: `PDU SESSION ESTABLISHMENT REQUEST`
     - PDU session ID: 1
     - DNN (Data Network Name): `internet`
     - S-NSSAI (slice): `{ sst: 1, sd: 010203 }`
     - PDU session type: `IPv4`
   - Sent via RRC/Uu to gNB, wrapped in NGAP `UplinkNASTransport` (amfUeNgapId: 1, ranUeNgapId: 1), forwarded to AMF
   - Log (UE): `Requesting PDU session for DNN=internet, slice SST=1/SD=010203`

2. **AMF queries NSSF for slice selection**
   - AMF calls NSSF: `Nnssf_NSSelection_Get` with requested S-NSSAI and TAI
   - NSSF returns allowed slices and target AMF set
   - AMF selects SMF based on NSSF-approved slice
   - Matching criteria: DNN `internet`, S-NSSAI `SST=1/SD=010203`, PLMN 208/93
   - Queries NRF: `GET http://nrf.free5gc.org:8000/nnrf-disc/v1/nf-instances?target-nf-type=SMF&dnn=internet&snssai={"sst":1,"sd":"010203"}`
   - NRF searches `NfProfile` collection, returns SMF address: `smf.free5gc.org:8000`
   - Log (AMF): `Selected SMF at smf.free5gc.org:8000 for DNN=internet, slice SST=1/SD=010203`

3. **AMF sends session creation request to SMF**
   - HTTP/2 POST: `http://smf.free5gc.org:8000/nsmf-pdusession/v1/sm-contexts`
   - Body:
     ```json
     {
       "supi": "imsi-208930000000001",
       "pei": "imei-123456789012345",
       "gpsi": "",
       "pduSessionId": 1,
       "dnn": "internet",
       "sNssai": { "sst": 1, "sd": "010203" },
       "servingNetwork": { "mcc": "208", "mnc": "93" },
       "anType": "3GPP_ACCESS",
       "smContextStatusUri": "http://amf.free5gc.org:8000/...",
       "n1SmMsg": { "contentId": "n1SmMsg" }
     }
     ```
   - Log (AMF): `Requesting SMF to create PDU session context`

4. **SMF queries UDM for session management subscription data**
   - HTTP/2 GET: `http://udm.free5gc.org:8000/nudm-sdm/v1/imsi-208930000000001/sm-data?dnn=internet&snssai={"sst":1,"sd":"010203"}`
   - UDM queries UDR: `GET http://udr.free5gc.org:8000/nudr-dr/v1/subscription-data/imsi-208930000000001/context-data/smf-registrations/1`
   - UDR reads MongoDB collection `subscriptionData.sessionManagementSubscriptionData`
   - Log (SMF): `Fetching subscriber session profile from UDM`

5. **UDM returns session management subscription data**
   - HTTP/2 200 OK with body:
     ```json
     {
       "dnnConfigurations": {
         "internet": {
           "pduSessionTypes": { "defaultSessionType": "IPV4" },
           "sscModes": { "defaultSscMode": "SSC_MODE_1" },
           "5gQosProfile": {
             "5qi": 9,
             "arp": { "priorityLevel": 8 },
             "priorityLevel": 8
           },
           "sessionAmbr": {
             "uplink": "200 Mbps",
             "downlink": "100 Mbps"
           }
         }
       }
     }
     ```
   - Log (UDM): `Returned session profile: DNN=internet, QoS 5QI=9, AMBR 200/100 Mbps`

6. **SMF allocates UE IP address**
   - SMF has two IP pools: `10.60.0.0/16` (for slice SST=1/SD=010203) and `10.61.0.0/16` (for SST=1/SD=112233)
   - Request is for slice `SST=1/SD=010203` → selects pool `10.60.0.0/16`
   - Allocates next available IP: `10.60.0.1` (first session)
   - Saves allocation in memory: `{ supi: imsi-208930000000001, pduSessionId: 1, ueIp: 10.60.0.1, dnn: internet, slice: {sst:1, sd:010203} }`
   - Log (SMF): `Allocated UE IP 10.60.0.1 for PDU session 1`

7. **SMF prepares PFCP Session Establishment Request**
   - Constructs forwarding rules (PDR/FAR):
     - **PDR (Packet Detection Rule) 1 - Downlink from N6 (internet)**:
       - Source: Any internet IP
       - Destination: `10.60.0.1`
       - Action: Forward via FAR 1
     - **FAR (Forwarding Action Rule) 1 - Encapsulate and send to gNB**:
       - Encapsulate in GTP-U tunnel (outer header: src=UPF IP 192.168.0.5, dst=gNB IP 192.168.0.10, TEID=allocated by UPF)
       - Forward to N3 interface
     - **PDR 2 - Uplink from N3 (gNB)**:
       - GTP-U tunnel with TEID (allocated by UPF)
       - Inner IP source: `10.60.0.1`
       - Action: Forward via FAR 2
     - **FAR 2 - Decapsulate and forward to internet**:
       - Strip GTP-U header
       - Perform NAT (10.60.0.1 → UPF's public IP or container IP)
       - Forward to N6 interface (internet)
   - Log (SMF): `Prepared PFCP rules: UE IP 10.60.0.1 ↔ internet via UPF`

8. **SMF sends PFCP Session Establishment Request to UPF**
   - PFCP message (UDP:8805 from 192.168.0.6 to 192.168.0.5):
     - Message type: `PFCP Session Establishment Request`
     - Node ID: `192.168.0.6` (SMF)
     - F-SEID (fully qualified session ID): `{ ipv4: 192.168.0.6, seid: 1 }`
     - PDR 1: `{ pdrId: 1, precedence: 1, ueIpAddress: 10.60.0.1, farId: 1 }`
     - FAR 1: `{ farId: 1, applyAction: FORW, forwardingParameters: { destinationInterface: ACCESS, outerHeaderCreation: { teid: 0, ipv4: 192.168.0.10 } } }`
     - PDR 2: `{ pdrId: 2, precedence: 1, sourceInterface: ACCESS, fteid: { teid: (allocated by UPF), ipv4: 192.168.0.5 }, ueIpAddress: 10.60.0.1, farId: 2 }`
     - FAR 2: `{ farId: 2, applyAction: FORW, forwardingParameters: { destinationInterface: CORE } }`
   - Log (SMF): `Sent PFCP Session Establishment Request to UPF 192.168.0.5`

9. **UPF creates forwarding rules**
   - Allocates uplink TEID: `1` (UPF's GTP-U tunnel endpoint ID for this session)
   - Programs GTP5G kernel module with forwarding rules:
     - Downlink: IP packet with dst=10.60.0.1 → encapsulate in GTP-U (TEID from gNB, to be received later) → send to gNB at 192.168.0.10:2152
     - Uplink: GTP-U packet from gNB with TEID=1 → decapsulate → NAT (10.60.0.1 → 192.168.0.5) → forward to internet
   - Creates network namespace for this session (if using strict isolation)
   - Log (UPF): `Created PFCP session for UE 10.60.0.1, uplink TEID=1`

10. **UPF returns PFCP Session Establishment Response**
    - PFCP message (UDP:8805 from 192.168.0.5 to 192.168.0.6):
      - Message type: `PFCP Session Establishment Response`
      - Cause: `Request accepted`
      - F-SEID: `{ ipv4: 192.168.0.5, seid: 1 }` (UPF's session ID)
      - Created PDR: `{ pdrId: 2, fteid: { teid: 1, ipv4: 192.168.0.5 } }` (uplink TEID=1 allocated by UPF)
    - Log (UPF): `PFCP session established, uplink TEID=1`

11. **SMF constructs N1N2MessageTransfer**
    - Prepares two messages:
      - **N1 (NAS) - PDU Session Establishment Accept**:
        - PDU session ID: 1
        - PDU session type: IPv4
        - SSC mode: 1
        - QoS rules: `{ qosRuleId: 1, 5qi: 9, sessionAmbr: { ul: 200 Mbps, dl: 100 Mbps } }`
        - UE IP address: `10.60.0.1`
        - DNS server: `8.8.8.8` (from SMF's `smfcfg.yaml` for DNN `internet`)
      - **N2 (NGAP) - PDU Session Resource Setup Request Transfer**:
        - PDU session ID: 1
        - GTP-U tunnel info for gNB↔UPF:
          - UPF GTP-U address: `192.168.0.5`
          - UPF uplink TEID: `1`
        - QoS flows: `{ qfi: 1, 5qi: 9, arp: 8 }`
    - Log (SMF): `Constructed N1N2 message with UE IP 10.60.0.1, UPF TEID=1`

12. **SMF returns SM context to AMF**
    - HTTP/2 201 Created with headers:
      - `Location: http://smf.free5gc.org:8000/nsmf-pdusession/v1/sm-contexts/{smContextId}`
    - Body:
      ```json
      {
        "smContextId": "urn:uuid:...",
        "n1SmMsg": { "contentId": "n1SmMsg" },
        "n2InfoContent": { "ngapIeType": "PDU_RES_SETUP_REQ", "ngapData": { ... } },
        "pduSessionId": 1
      }
      ```
    - Log (SMF): `Returned SM context to AMF with N1N2 message`

13. **AMF sends PDU Session Resource Setup Request to gNB**
    - NGAP message:
      - Message type: `PDUSessionResourceSetupRequest`
      - AMF-UE-NGAP-ID: 1
      - RAN-UE-NGAP-ID: 1
      - PDU session list:
        - PDU session ID: 1
        - NAS-PDU: [PDU Session Establishment Accept bytes]
        - S-NSSAI: `{ sst: 1, sd: 010203 }`
        - PDU session resource setup request transfer:
          - UL GTP tunnel: `{ transportLayerAddress: 192.168.0.5, gtp-TEID: 1 }`
          - QoS flows: `[{ qfi: 1, 5qi: 9, arp: 8 }]`
    - Sent via SCTP to gNB (192.168.0.8:38412 → 192.168.0.10:36412)
    - Log (AMF): `Sent PDUSessionResourceSetupRequest to gNB with UPF tunnel info (192.168.0.5, TEID=1)`

14. **gNB allocates downlink TEID and creates GTP-U tunnel**
    - gNB allocates its own downlink TEID: `1` (gNB's GTP-U tunnel endpoint for this session)
    - Creates GTP-U tunnel endpoint on its GTP-U interface (192.168.0.10:2152)
    - Configures radio bearer for UE:
      - Maps QFI 1 to DRB (Data Radio Bearer) 1
      - Configures RLC/PDCP for DRB 1
    - Programs forwarding rules:
      - Downlink: GTP-U from UPF (TEID=1) → decapsulate → send to UE via DRB 1 on radio
      - Uplink: Data from UE on DRB 1 → encapsulate in GTP-U (dst=192.168.0.5:2152, TEID=1) → send to UPF
    - Log (gNB): `Created GTP-U tunnel to UPF: local TEID=1 (DL), remote TEID=1 (UL), remote IP=192.168.0.5`

15. **gNB sends RRC Reconfiguration to UE**
    - RRC message (over Uu radio):
      - Message type: `RRCReconfiguration`
      - DRB to add: DRB 1 (mapped to PDU session 1, QFI 1)
      - SDAP config: Maps QFI 1 → DRB 1
      - PDCP config: Integrity and ciphering enabled
      - RLC config: Acknowledged mode (AM)
    - Embedded NAS PDU: [PDU Session Establishment Accept]
    - Log (gNB): `Sent RRCReconfiguration to UE with DRB 1 configuration`

16. **UE receives PDU Session Establishment Accept**
    - Extracts NAS message from RRC Reconfiguration
    - Reads UE IP: `10.60.0.1`, DNS: `8.8.8.8`, QoS: 5QI=9, session AMBR: 200/100 Mbps
    - Creates virtual network interface `uesimtun0` with IP `10.60.0.1/32`
    - Configures routing: Default route via `uesimtun0` (all traffic → PDU session)
    - Configures DNS resolver: `8.8.8.8`
    - Log (UE): `PDU session established, IP=10.60.0.1, DNS=8.8.8.8, interface=uesimtun0`

17. **UE sends RRC Reconfiguration Complete**
    - RRC message:
      - Message type: `RRCReconfigurationComplete`
      - Transaction ID: matches RRCReconfiguration
    - Sent via radio to gNB
    - Log (UE): `RRC reconfiguration complete, DRB 1 active`

18. **gNB sends PDU Session Resource Setup Response to AMF**
    - NGAP message:
      - Message type: `PDUSessionResourceSetupResponse`
      - AMF-UE-NGAP-ID: 1, RAN-UE-NGAP-ID: 1
      - PDU session setup response list:
        - PDU session ID: 1
        - PDU session resource setup response transfer:
          - DL GTP tunnel: `{ transportLayerAddress: 192.168.0.10, gtp-TEID: 1 }`
    - Sent via SCTP to AMF (192.168.0.10:36412 → 192.168.0.8:38412)
    - Log (gNB): `Sent PDUSessionResourceSetupResponse to AMF with gNB tunnel info (192.168.0.10, TEID=1)`

19. **AMF notifies SMF of gNB tunnel info**
    - HTTP/2 POST: `http://smf.free5gc.org:8000/nsmf-pdusession/v1/sm-contexts/{smContextId}/modify`
    - Body:
      ```json
      {
        "n2SmInfo": {
          "contentId": "n2SmInfo",
          "ngapIeType": "PDU_RES_SETUP_RSP",
          "ngapData": {
            "pduSessionId": 1,
            "dlQosFlowPerTnlInformation": {
              "upTransportLayerInformation": {
                "gtpTunnel": {
                  "transportLayerAddress": "192.168.0.10",
                  "gtpTeid": "00000001"
                }
              }
            }
          }
        }
      }
      ```
    - Log (AMF): `Notified SMF of gNB tunnel endpoint (192.168.0.10, TEID=1)`

20. **SMF sends PFCP Session Modification Request to UPF**
    - PFCP message (UDP:8805):
      - Message type: `PFCP Session Modification Request`
      - F-SEID: `{ ipv4: 192.168.0.6, seid: 1 }`
      - Update FAR 1:
        - `{ farId: 1, applyAction: FORW, forwardingParameters: { destinationInterface: ACCESS, outerHeaderCreation: { teid: 1, ipv4: 192.168.0.10 } } }`
    - Now UPF knows gNB's downlink TEID=1 for encapsulating downlink packets
    - Log (SMF): `Updated UPF with gNB tunnel info for downlink (192.168.0.10, TEID=1)`

21. **UPF updates forwarding rules**
    - Updates downlink FAR 1:
      - Downlink packets with dst=10.60.0.1 → encapsulate in GTP-U (outer header: src=192.168.0.5, dst=192.168.0.10, TEID=1) → send to gNB at 192.168.0.10:2152
    - Log (UPF): `Updated downlink tunnel: dst=192.168.0.10:2152, TEID=1`

22. **UPF returns PFCP Session Modification Response**
    - PFCP message: `PFCP Session Modification Response`, Cause: `Request accepted`
    - Log (UPF): `PFCP session modified successfully`

23. **PDU session fully established**
    - UE has IP `10.60.0.1`, can send/receive data
    - Data path: UE (uesimtun0) ↔ gNB (N3/GTP-U) ↔ UPF (N6) ↔ Internet
    - Log (SMF): `PDU session 1 fully established for imsi-208930000000001`

**ASCII Flow**:
```
UE ─Uu─> gNB ─N2/NGAP─> AMF ─SBI─> SMF ─SBI─> UDM ─SBI─> UDR ─MongoDB─> (fetch session profile)
                         ↓            ↓                                           ↑
                1. PDU Session Req   2. Query session data ─────────────────────┘
                         ↓            ↓
                         ↓        3. Allocate IP: 10.60.0.1
                         ↓            ↓
                         ↓        4. SMF ─N4/PFCP─> UPF (create forwarding rules, allocate TEID=1)
                         ↓            ↓                ↓
                         ↓        5. SMF returns N1N2 message (UE IP, UPF TEID=1)
                         ↓            ↓
                     6. AMF ─N2─> gNB (PDUSessionResourceSetupRequest: UPF IP 192.168.0.5, TEID=1)
                                   ↓
                              7. gNB creates GTP-U tunnel (local TEID=1)
                                   ↓
                              8. gNB ─RRC─> UE (RRCReconfiguration + PDU Session Accept, IP=10.60.0.1)
                                   ↓
                              9. UE creates uesimtun0 interface with IP 10.60.0.1
                                   ↓
                             10. gNB ─N2─> AMF (PDUSessionResourceSetupResponse: gNB IP 192.168.0.10, TEID=1)
                                              ↓
                                          11. AMF ─SBI─> SMF (notify gNB tunnel info)
                                                           ↓
                                                      12. SMF ─N4/PFCP─> UPF (update downlink FAR with gNB TEID=1)
                                                                           ↓
                                                                    13. PDU session ACTIVE
```

---

### Phase 5: Data Flow (Browsing the Internet)

**Timeline**: UE pings 8.8.8.8 or opens browser

**Uplink (UE → Internet)**:

1. **UE sends IP packet**
   - User executes: `ping 8.8.8.8`
   - UE's IP stack creates ICMP Echo Request:
     - Source IP: `10.60.0.1`
     - Destination IP: `8.8.8.8`
     - ICMP type: 8 (Echo Request)
     - ICMP identifier: 1234
     - ICMP sequence: 1
   - Packet written to `uesimtun0` interface (TUN device)
   - Log (UE): `Sending ping to 8.8.8.8 from 10.60.0.1`

2. **UE sends to gNB via radio**
   - SDAP layer: Maps QFI 1 (default bearer) to this packet
   - PDCP layer: Integrity protection + ciphering
   - RLC layer: Segmentation (if needed)
   - MAC layer: Multiplexing
   - PHY layer: Modulation, transmitted via antenna
   - Log (UE): `Transmitted IP packet via DRB 1 (QFI 1)`

3. **gNB receives from UE, encapsulates in GTP-U**
   - PHY/MAC/RLC/PDCP layers: Demodulate, decode, reassemble, decipher, verify integrity
   - SDAP layer: Extracts IP packet
   - GTP-U encapsulation:
     - Outer IP header: src=`192.168.0.10` (gNB), dst=`192.168.0.5` (UPF)
     - Outer UDP header: src=2152, dst=2152 (GTP-U port)
     - GTP-U header: Version=1, Message Type=0xFF (G-PDU), TEID=`1` (UPF's uplink TEID)
     - Inner IP packet: src=`10.60.0.1`, dst=`8.8.8.8`, ICMP Echo Request
   - Sends UDP packet to UPF at 192.168.0.5:2152 via N3 (Docker bridge network `free5gc-net`)
   - Log (gNB): `Encapsulated IP packet in GTP-U (TEID=1), sent to UPF 192.168.0.5:2152`

4. **UPF receives GTP-U packet**
   - Receives UDP packet on port 2152
   - Extracts TEID from GTP-U header: `1`
   - Looks up PFCP session by TEID: Finds session for UE 10.60.0.1 (PDR 2)
   - Matches PDR 2: Source interface=ACCESS, F-TEID=1, UE IP=10.60.0.1 → Action: Apply FAR 2
   - Executes FAR 2: Decapsulate GTP-U header
   - Log (UPF): `Received GTP-U packet (TEID=1), matched PDR 2, applying FAR 2 (decapsulate)`

5. **UPF extracts inner IP packet**
   - Inner packet: src=`10.60.0.1`, dst=`8.8.8.8`, ICMP Echo Request
   - Applies forwarding rule (FAR 2): Forward to CORE (N6 interface, internet)
   - Performs NAT (SNAT - Source NAT):
     - Original: src=`10.60.0.1`, dst=`8.8.8.8`
     - After NAT: src=`192.168.0.5` (UPF's IP on N6), dst=`8.8.8.8`
   - Stores NAT entry: `{ 10.60.0.1:icmp-id-1234 → 192.168.0.5:icmp-id-5678, dst: 8.8.8.8 }`
   - Log (UPF): `NAT applied: 10.60.0.1 → 192.168.0.5, forwarding to internet`

6. **Packet forwarded to internet**
   - UPF sends IP packet via N6 interface (Docker bridge network `free5gc-net` → host network → internet)
   - Docker host's routing table forwards to default gateway (e.g., home router)
   - Packet reaches Google DNS server at 8.8.8.8
   - Log (UPF): `Forwarded packet to internet: dst=8.8.8.8`

**Downlink (Internet → UE)**:

7. **Response comes back from internet**
   - Google DNS server (8.8.8.8) sends ICMP Echo Reply:
     - Source IP: `8.8.8.8`
     - Destination IP: `192.168.0.5` (UPF's NATed IP)
     - ICMP type: 0 (Echo Reply)
     - ICMP identifier: 5678 (NATed)
     - ICMP sequence: 1
   - Packet routed back to Docker host, then to UPF container via N6 interface
   - Log (UPF): `Received downlink packet from internet: src=8.8.8.8, dst=192.168.0.5`

8. **UPF performs reverse NAT**
   - Looks up NAT entry: `192.168.0.5:icmp-id-5678 → 10.60.0.1:icmp-id-1234`
   - Restores original destination:
     - Before: src=`8.8.8.8`, dst=`192.168.0.5`
     - After: src=`8.8.8.8`, dst=`10.60.0.1`
   - Log (UPF): `Reverse NAT: 192.168.0.5 → 10.60.0.1`

9. **UPF matches downlink PDR 1**
   - Packet: src=`8.8.8.8`, dst=`10.60.0.1`
   - Matches PDR 1: UE IP=10.60.0.1 → Action: Apply FAR 1
   - Executes FAR 1: Encapsulate in GTP-U, forward to ACCESS (N3 interface)
   - Log (UPF): `Matched downlink PDR 1, applying FAR 1 (encapsulate in GTP-U)`

10. **UPF encapsulates in GTP-U**
    - Outer IP header: src=`192.168.0.5` (UPF), dst=`192.168.0.10` (gNB)
    - Outer UDP header: src=2152, dst=2152
    - GTP-U header: Version=1, Message Type=0xFF, TEID=`1` (gNB's downlink TEID)
    - Inner IP packet: src=`8.8.8.8`, dst=`10.60.0.1`, ICMP Echo Reply
    - Sends UDP packet to gNB at 192.168.0.10:2152 via N3
    - Log (UPF): `Encapsulated in GTP-U (TEID=1), sent to gNB 192.168.0.10:2152`

11. **gNB receives GTP-U packet**
    - Receives UDP packet on port 2152
    - Extracts TEID: `1`
    - Looks up local GTP-U tunnel: TEID=1 → UE RAN-UE-NGAP-ID=1, DRB 1, QFI 1
    - Decapsulates GTP-U header
    - Inner packet: src=`8.8.8.8`, dst=`10.60.0.1`, ICMP Echo Reply
    - Log (gNB): `Received GTP-U packet (TEID=1), forwarding to UE via DRB 1`

12. **gNB forwards to UE via radio**
    - Maps QFI 1 to DRB 1
    - SDAP header: QFI=1
    - PDCP: Ciphering + integrity protection
    - RLC: Segmentation (if needed)
    - MAC: Multiplexing
    - PHY: Modulation, transmitted via antenna
    - Log (gNB): `Transmitted IP packet to UE via DRB 1 (QFI 1)`

13. **UE receives on radio**
    - PHY/MAC/RLC/PDCP: Demodulate, decode, reassemble, decipher, verify integrity
    - SDAP: Extracts IP packet
    - IP packet delivered to `uesimtun0` interface
    - Log (UE): `Received IP packet from network via DRB 1`

14. **UE's IP stack processes packet**
    - Receives ICMP Echo Reply: src=`8.8.8.8`, dst=`10.60.0.1`
    - Matches outgoing ping (identifier=1234, sequence=1)
    - Displays: `64 bytes from 8.8.8.8: icmp_seq=1 ttl=64 time=50 ms`
    - Log (UE): `Ping reply received from 8.8.8.8`

**Complete Data Path ASCII Diagram**:
```
UPLINK (UE → Internet):

UE (10.60.0.1) ─────┐
  uesimtun0         │
  ping 8.8.8.8      │ IP packet: src=10.60.0.1, dst=8.8.8.8
                    ↓
              [Radio Uu: SDAP/PDCP/RLC/MAC/PHY]
                    ↓
gNB (192.168.0.10) ─┴─> Encapsulate in GTP-U
                         Outer: src=192.168.0.10, dst=192.168.0.5
                         GTP-U TEID=1
                         Inner: src=10.60.0.1, dst=8.8.8.8
                         ↓
                    [N3: UDP:2152 via Docker network]
                         ↓
UPF (192.168.0.5) ───────┘ PDR 2 match → FAR 2: Decapsulate
                         ↓
                    NAT: 10.60.0.1 → 192.168.0.5
                         ↓
                    [N6: IP packet to internet]
                         ↓
Internet (8.8.8.8) ──────┘ ICMP Echo Reply


DOWNLINK (Internet → UE):

Internet (8.8.8.8) ──────┐ ICMP Echo Reply
                         │ src=8.8.8.8, dst=192.168.0.5
                         ↓
                    [N6: IP packet from internet]
                         ↓
UPF (192.168.0.5) ───────┘ Reverse NAT: 192.168.0.5 → 10.60.0.1
                         ↓
                    PDR 1 match → FAR 1: Encapsulate in GTP-U
                         Outer: src=192.168.0.5, dst=192.168.0.10
                         GTP-U TEID=1 (gNB's TEID)
                         Inner: src=8.8.8.8, dst=10.60.0.1
                         ↓
                    [N3: UDP:2152 via Docker network]
                         ↓
gNB (192.168.0.10) ──────┘ Decapsulate GTP-U, extract inner packet
                         ↓
              [Radio Uu: SDAP/PDCP/RLC/MAC/PHY]
                         ↓
UE (10.60.0.1) ──────────┘ Receive on uesimtun0
                         ↓
                    Display: "64 bytes from 8.8.8.8: icmp_seq=1"
```

---

## Subscriber Management Without WebUI

Since the minimal deployment doesn't include WebUI, subscribers must be managed via MongoDB shell or HTTP API.

### Adding a Subscriber via MongoDB Shell

```bash
# Connect to MongoDB container
docker exec -it mongodb mongo

# Switch to free5gc database
use free5gc

# Add subscriber authentication data
db.getCollection("subscriptionData.authenticationData.authenticationSubscription").insertOne({
  "ueId": "imsi-208930000000001",
  "authenticationMethod": "5G_AKA",
  "permanentKey": {
    "permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862",
    "encryptionKey": 0,
    "encryptionAlgorithm": 0
  },
  "opc": {
    "opcValue": "8e27b6af0e692e750f32667a3b14605d",
    "encryptionKey": 0,
    "encryptionAlgorithm": 0
  },
  "milenage": {
    "op": {
      "opValue": "",
      "encryptionKey": 0,
      "encryptionAlgorithm": 0
    }
  },
  "authenticationManagementField": "8000",
  "sequenceNumber": "000000000020",
  "msin": "0000000001"
})

# Add subscriber access and mobility data
db.getCollection("subscriptionData.provisionedData.amData").insertOne({
  "ueId": "imsi-208930000000001",
  "servingPlmnId": "20893",
  "gpsis": ["msisdn-0900000000"],
  "subscribedUeAmbr": {
    "uplink": "1 Gbps",
    "downlink": "2 Gbps"
  },
  "nssai": {
    "defaultSingleNssais": [
      {"sst": 1, "sd": "010203"},
      {"sst": 1, "sd": "112233"}
    ],
    "singleNssais": []
  }
})

# Add subscriber session management data
db.getCollection("subscriptionData.provisionedData.smData").insertOne({
  "ueId": "imsi-208930000000001",
  "servingPlmnId": "20893",
  "singleNssai": {"sst": 1, "sd": "010203"},
  "dnnConfigurations": {
    "internet": {
      "pduSessionTypes": {"defaultSessionType": "IPV4"},
      "sscModes": {"defaultSscMode": "SSC_MODE_1"},
      "5gQosProfile": {
        "5qi": 9,
        "arp": {"priorityLevel": 8},
        "priorityLevel": 8
      },
      "sessionAmbr": {
        "uplink": "200 Mbps",
        "downlink": "100 Mbps"
      }
    }
  }
})

# Exit MongoDB shell
exit
```

### Fixing SQN Mismatch

If authentication fails with "MAC failure" or "SQN out of range", reset the SQN:

```bash
docker exec -it mongodb mongo

use free5gc

# Reset SQN to a low value (hex format)
db.getCollection("subscriptionData.authenticationData.authenticationSubscription").updateOne(
  {"ueId": "imsi-208930000000001"},
  {$set: {"sequenceNumber": "000000000020"}}
)

exit
```

### Viewing Registered Subscribers

```bash
docker exec -it mongodb mongo --quiet --eval '
  db = db.getSiblingDB("free5gc");
  db.getCollection("subscriptionData.authenticationData.authenticationSubscription").find({}, {ueId: 1, sequenceNumber: 1, _id: 0}).forEach(printjson);
'
```

### Deleting a Subscriber

```bash
docker exec -it mongodb mongo --quiet --eval '
  db = db.getSiblingDB("free5gc");
  db.getCollection("subscriptionData.authenticationData.authenticationSubscription").deleteOne({"ueId": "imsi-208930000000001"});
  db.getCollection("subscriptionData.provisionedData.amData").deleteOne({"ueId": "imsi-208930000000001"});
  db.getCollection("subscriptionData.provisionedData.smData").deleteMany({"ueId": "imsi-208930000000001"});
  print("Subscriber deleted");
'
```

---

## Testing the Minimal Deployment

### Step 1: Start the 5G Core

```bash
# Ensure GTP5G kernel module is loaded (required for UPF)
lsmod | grep gtp5g
# If not loaded, build and install:
# git clone -b v0.9.5 https://github.com/free5gc/gtp5g.git
# cd gtp5g && make clean && make && sudo make install

# Start minimal deployment
docker compose -f docker-compose-minimal.yaml up -d

# Wait 10 seconds for all NFs to register with NRF
sleep 10

# Check all containers are running
docker compose -f docker-compose-minimal.yaml ps
# Expected: 11 containers, all "Up"
```

### Step 2: Verify NF Registration

```bash
# Check NRF logs - should see 9 NF registrations (UDR, UDM, AUSF, AMF, SMF, UPF, NSSF, PCF, NRF)
docker compose -f docker-compose-minimal.yaml logs nrf | grep "Handle NFRegisterRequest"

# Check MongoDB for registered NFs
docker exec -it mongodb mongo --quiet --eval '
  db = db.getSiblingDB("free5gc");
  db.NfProfile.find({}, {nfType: 1, ipv4Addresses: 1, _id: 0}).forEach(printjson);
'
# Expected output: 9 NF profiles (NRF, UDR, UDM, AUSF, AMF, SMF, UPF, NSSF, PCF)
```

### Step 3: Provision Subscriber

```bash
# Add subscriber imsi-208930000000001
docker exec -it mongodb mongo --quiet --eval '
  db = db.getSiblingDB("free5gc");
  db.getCollection("subscriptionData.authenticationData.authenticationSubscription").insertOne({
    "ueId": "imsi-208930000000001",
    "authenticationMethod": "5G_AKA",
    "permanentKey": {"permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862"},
    "opc": {"opcValue": "8e27b6af0e692e750f32667a3b14605d"},
    "authenticationManagementField": "8000",
    "sequenceNumber": "000000000020"
  });
  db.getCollection("subscriptionData.provisionedData.amData").insertOne({
    "ueId": "imsi-208930000000001",
    "servingPlmnId": "20893",
    "subscribedUeAmbr": {"uplink": "1 Gbps", "downlink": "2 Gbps"},
    "nssai": {"defaultSingleNssais": [{"sst": 1, "sd": "010203"}]}
  });
  db.getCollection("subscriptionData.provisionedData.smData").insertOne({
    "ueId": "imsi-208930000000001",
    "servingPlmnId": "20893",
    "singleNssai": {"sst": 1, "sd": "010203"},
    "dnnConfigurations": {
      "internet": {
        "pduSessionTypes": {"defaultSessionType": "IPV4"},
        "sscModes": {"defaultSscMode": "SSC_MODE_1"},
        "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8}},
        "sessionAmbr": {"uplink": "200 Mbps", "downlink": "100 Mbps"}
      }
    }
  });
  print("Subscriber added successfully");
'
```

### Step 4: Start UE

```bash
# Enter UERANSIM container
docker exec -it ueransim bash

# Start UE (gNB is already running)
cd /ueransim/build
./nr-ue -c /ueransim/config/ue.yaml

# Expected output:
# [INFO] UE started with IMSI: imsi-208930000000001
# [INFO] Registration Request sent
# [INFO] Authentication successful
# [INFO] Registration Accept received
# [INFO] UE state: RM-REGISTERED
# [INFO] PDU Session Establishment Request sent
# [INFO] PDU Session Establishment Accept received
# [INFO] PDU session established, IP: 10.60.0.1
```

### Step 5: Test Connectivity

```bash
# In UERANSIM container, test ping
ping -I uesimtun0 -c 4 8.8.8.8

# Expected output:
# 64 bytes from 8.8.8.8: icmp_seq=1 ttl=64 time=50.2 ms
# 64 bytes from 8.8.8.8: icmp_seq=2 ttl=64 time=49.8 ms
# 64 bytes from 8.8.8.8: icmp_seq=3 ttl=64 time=51.1 ms
# 64 bytes from 8.8.8.8: icmp_seq=4 ttl=64 time=50.5 ms

# Test DNS resolution
nslookup google.com 8.8.8.8

# Expected: Resolves to Google's IPs

# Test HTTP (if curl is available)
curl -I http://google.com

# Expected: HTTP/1.1 301 Moved Permanently (redirect to HTTPS)
```

### Step 6: Monitor Traffic

```bash
# In separate terminals, monitor logs:

# AMF logs (registration flow)
docker compose -f docker-compose-minimal.yaml logs -f amf

# SMF logs (PDU session establishment)
docker compose -f docker-compose-minimal.yaml logs -f smf

# UPF logs (data forwarding)
docker compose -f docker-compose-minimal.yaml logs -f upf

# Check UPF packet counters
docker exec upf ip -s link show upfgtp
# Expected: RX/TX packets > 0
```

### Step 7: Verify in MongoDB

```bash
# Check UE context in AMF
docker exec -it mongodb mongo --quiet --eval '
  db = db.getSiblingDB("free5gc");
  db.amContextData.find({"supi": "imsi-208930000000001"}, {supi: 1, guti: 1, cmState: 1, _id: 0}).forEach(printjson);
'
# Expected: cmState: "CONNECTED", guti assigned

# Check PDU session in SMF
docker exec -it mongodb mongo --quiet --eval '
  db = db.getSiblingDB("free5gc");
  db.smContextData.find({"supi": "imsi-208930000000001"}, {supi: 1, pduSessionId: 1, dnn: 1, ueIp: 1, _id: 0}).forEach(printjson);
'
# Expected: pduSessionId: 1, dnn: "internet", ueIp: "10.60.0.1"
```

### Troubleshooting

**Issue: UE registration fails with "Authentication failure"**

Solution: Reset SQN in MongoDB:
```bash
docker exec -it mongodb mongo --quiet --eval '
  db = db.getSiblingDB("free5gc");
  db.getCollection("subscriptionData.authenticationData.authenticationSubscription").updateOne(
    {"ueId": "imsi-208930000000001"},
    {$set: {"sequenceNumber": "000000000020"}}
  );
  print("SQN reset to 0x20");
'
```

**Issue: PDU session establishment fails with "Unknown DNN"**

Solution: Check smData collection has DNN "internet" configured for the subscriber.

**Issue: UE gets IP but cannot ping**

Solution: Check UPF has NET_ADMIN capability and GTP5G module is loaded:
```bash
docker inspect upf | grep NET_ADMIN
lsmod | grep gtp5g
```

**Issue: "TooManyLogicalSessions" error in MongoDB**

Solution: Kill all sessions:
```bash
docker exec -it mongodb mongo --quiet --eval '
  db = db.getSiblingDB("admin");
  db.auth("admin", "admin");
  db.adminCommand({killAllSessions: []});
'
```

---

## Subscriber Provisioning

> **Important**: Direct MongoDB shell inserts may not always work correctly with free5GC v4.2.0. The recommended approach is to use the **WebUI API** for subscriber provisioning, which stores data in the exact format expected by UDR/UDM.

### Recommended: Temporary WebUI Container

If you don't want WebUI running permanently, use it temporarily for subscriber provisioning:

```bash
# Start temporary WebUI container (must specify command explicitly)
docker run -d --name webui-temp \
  --network free5gc-5g-sa-setup_privnet \
  -v $(pwd)/config/webuicfg.yaml:/free5gc/config/webuicfg.yaml \
  -v $(pwd)/cert:/free5gc/cert \
  -e GIN_MODE=release \
  -p 5000:5000 \
  free5gc/webui:v4.2.0 ./webui -c ./config/webuicfg.yaml

# Wait for it to start
sleep 5

# Step 1: Login to get JWT token (default credentials: admin/free5gc)
TOKEN=$(curl -s -X POST http://localhost:5000/api/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"free5gc"}' | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Step 2: Add subscriber via WebUI API using JWT token
curl -X POST http://localhost:5000/api/subscriber/imsi-208930000000001/20893 \
  -H 'Content-Type: application/json' \
  -H "Token: $TOKEN" \
  -d '{
    "plmnID": "20893",
    "ueId": "imsi-208930000000001",
    "AuthenticationSubscription": {
      "authenticationMethod": "5G_AKA",
      "permanentKey": {"permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862", "encryptionKey": 0, "encryptionAlgorithm": 0},
      "sequenceNumber": "000000000020",
      "authenticationManagementField": "8000",
      "milenage": {"op": {"opValue": "", "encryptionKey": 0, "encryptionAlgorithm": 0}},
      "opc": {"opcValue": "8e27b6af0e692e750f32667a3b14605d", "encryptionKey": 0, "encryptionAlgorithm": 0}
    },
    "AccessAndMobilitySubscriptionData": {
      "gpsis": ["msisdn-0900000000"],
      "subscribedUeAmbr": {"downlink": "2 Gbps", "uplink": "1 Gbps"},
      "nssai": {
        "defaultSingleNssais": [{"sst": 1, "sd": "010203"}, {"sst": 1, "sd": "112233"}]
      }
    },
    "SessionManagementSubscriptionData": [
      {
        "singleNssai": {"sst": 1, "sd": "010203"},
        "dnnConfigurations": {
          "internet": {
            "pduSessionTypes": {"defaultSessionType": "IPV4"},
            "sscModes": {"defaultSscMode": "SSC_MODE_1"},
            "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8, "preemptCap": "", "preemptVuln": ""}},
            "sessionAmbr": {"downlink": "200 Mbps", "uplink": "100 Mbps"}
          }
        }
      },
      {
        "singleNssai": {"sst": 1, "sd": "112233"},
        "dnnConfigurations": {
          "internet": {
            "pduSessionTypes": {"defaultSessionType": "IPV4"},
            "sscModes": {"defaultSscMode": "SSC_MODE_1"},
            "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8, "preemptCap": "", "preemptVuln": ""}},
            "sessionAmbr": {"downlink": "200 Mbps", "uplink": "100 Mbps"}
          }
        }
      }
    ],
    "SmfSelectionSubscriptionData": {
      "subscribedSnssaiInfos": {
        "01010203": {"dnnInfos": [{"dnn": "internet"}]},
        "01112233": {"dnnInfos": [{"dnn": "internet"}]}
      }
    }
  }'

# Remove temporary WebUI container
docker stop webui-temp && docker rm webui-temp
```

---

## Summary

This minimal 5G SA core with **10 mandatory containers** demonstrates:

1. **Complete 5G SA architecture** for free5GC v4.2.0
2. **Service discovery** via NRF (all NFs find each other dynamically)
3. **5G-AKA authentication** using MILENAGE algorithm (AUSF + UDM + UDR)
4. **Slice selection** via NSSF (maps S-NSSAI to network slice instances)
5. **Policy control** via PCF (AM and SM policies during registration and session setup)
6. **PDU session management** with IP allocation (SMF) and forwarding rules (UPF via PFCP)
7. **User plane** data forwarding with GTP-U tunneling (gNB ↔ UPF) and NAT (UPF ↔ internet)

> **Note**: While 3GPP TS 23.501 considers NSSF and PCF optional, free5GC v4.2.0 requires both for basic operation. The true minimum for this version is **10 containers** (not 8).

For production deployments, add optional NFs based on requirements:
- **CHF**: Billing and charging
- **NEF**: External API exposure for 3rd-party apps
- **N3IWF/TNGF**: Wi-Fi and wireline access
- **WebUI**: Visual subscriber management

But for learning, testing, or small-scale deployments, these **10 mandatory containers** are all you need.

---

**Next Steps**:
- [05-RECOMMENDED-COMPONENTS.md](./05-RECOMMENDED-COMPONENTS.md) - WebUI for easier subscriber management
- [06-ALL-COMPONENTS.md](./06-ALL-COMPONENTS.md) - All 16+ containers explained
- [07-CONSOLIDATED-DEPLOYMENT.md](./07-CONSOLIDATED-DEPLOYMENT.md) - Merging into fewer containers
