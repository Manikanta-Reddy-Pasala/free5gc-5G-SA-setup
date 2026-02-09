# All Components - Complete 5G SA Network

This document covers the **complete free5GC deployment** with all 16+ containers, including optional Network Functions (NFs) for charging, billing, non-3GPP access, and external API exposure. It provides the end-to-end UE-to-core flow with every NF interaction explained step-by-step.

---

## Table of Contents

1. [All 16 Containers](#all-16-containers)
2. [How to Run Full Deployment](#how-to-run-full-deployment)
3. [Complete UE-to-Core Flow](#complete-ue-to-core-flow)
4. [Complete ASCII Diagram](#complete-ascii-diagram)
5. [Container Resource Usage](#container-resource-usage)
6. [Full Port Map](#full-port-map)
7. [Configuration Files](#configuration-files)
8. [Troubleshooting All Components](#troubleshooting-all-components)

---

## All 16 Containers

### Mandatory Core (10 Containers)

These containers are required for basic 5G SA operation with free5GC v4.2.0:

| Container | Image | Purpose | Config File |
|-----------|-------|---------|-------------|
| **MongoDB** | mongo:4.4 | Subscriber database | N/A |
| **NRF** | free5gc/nrf:v4.2.0 | Service discovery and registration | config/nrfcfg.yaml |
| **AMF** | free5gc/amf:v4.2.0 | Access and Mobility Management | config/amfcfg.yaml |
| **AUSF** | free5gc/ausf:v4.2.0 | Authentication Server Function | config/ausfcfg.yaml |
| **UDM** | free5gc/udm:v4.2.0 | Unified Data Management | config/udmcfg.yaml |
| **UDR** | free5gc/udr:v4.2.0 | Unified Data Repository | config/udrcfg.yaml |
| **SMF** | free5gc/smf:v4.2.0 | Session Management Function | config/smfcfg.yaml |
| **UPF** | free5gc/upf:v4.2.0 | User Plane Function | config/upfcfg.yaml |
| **NSSF** | free5gc/nssf:v4.2.0 | Network Slice Selection Function (required by AMF) | config/nssfcfg.yaml |
| **PCF** | free5gc/pcf:v4.2.0 | Policy Control Function (required by AMF) | config/pcfcfg.yaml |

> **Note**: While 3GPP considers NSSF and PCF optional, free5GC v4.2.0 requires both. Without PCF, registration fails. Without NSSF, PDU sessions fail.

### Recommended (1 Container)

Recommended for easier subscriber management:

| Container | Image | Purpose | Config File |
|-----------|-------|---------|-------------|
| **WebUI** | free5gc/webui:v4.2.0 | Web management interface | config/webuicfg.yaml |

### Optional - Charging & Exposure (2 Containers)

For billing, usage tracking, and 3rd party API access:

| Container | Image | Purpose | Config File |
|-----------|-------|---------|-------------|
| **CHF** | free5gc/chf:v4.2.0 | Charging Function (billing, CDR generation, Diameter) | config/chfcfg.yaml |
| **NEF** | free5gc/nef:v4.2.0 | Network Exposure Function (3rd party API gateway, PFD management) | config/nefcfg.yaml |

**CHF Details:**
- Handles converged charging (online/offline)
- Diameter interface on ports 3868 (TCP), 3869 (SCTP)
- CGF (Charging Gateway Function) on WebUI ports 2121 (FTP), 2122 (SFTP)
- Tracks volume, duration, events per PDU session
- Generates CDRs (Charging Data Records)

**NEF Details:**
- Exposes 5G core capabilities to external applications
- PFD (Packet Flow Description) management
- Traffic influence subscription
- Event monitoring and notification
- API authentication via NRF

### Optional - Non-3GPP Access (2 Containers)

For Wi-Fi and untrusted/trusted non-3GPP access:

| Container | Image | Purpose | Config File |
|-----------|-------|---------|-------------|
| **N3IWF** | free5gc/n3iwf:v4.2.0 | Non-3GPP Interworking Function (Wi-Fi/untrusted access via IPSec/IKEv2) | config/n3iwfcfg.yaml |
| **TNGF** | free5gc/tngf:v4.2.0 | Trusted Non-3GPP Gateway Function (trusted corporate Wi-Fi via Radius) | config/tngfcfg.yaml |

**N3IWF Details:**
- Static IP: 10.100.200.15
- UE pool: 10.0.0.0/24
- IKEv2 ports: 500 (UDP), 4500 (UDP NAT-T)
- Establishes IPSec tunnels with Wi-Fi UEs
- Creates N2 signaling to AMF, N3 GTP-U to UPF

**TNGF Details:**
- Runs on HOST network mode
- Radius authentication to enterprise AAA server
- Trusted non-3GPP access (no IPSec encryption needed)
- Directly creates N2/N3 interfaces

### Simulators (2 Containers)

For testing without physical gNB/UE:

| Container | Image | Purpose | Config File |
|-----------|-------|---------|-------------|
| **UERANSIM** | free5gc/ueransim:latest | gNB + 3GPP UE simulator | config/gnbcfg.yaml, config/uecfg.yaml |
| **N3IWUE** | free5gc/n3iwue:latest | Non-3GPP Wi-Fi UE simulator | config/n3uecfg.yaml |

**Total: 16+ containers** (including simulators)

---

## How to Run Full Deployment

### Prerequisites

- Docker and Docker Compose installed
- 8GB+ RAM recommended
- Ubuntu 20.04/22.04 or similar Linux distribution
- Kernel 5.4+ for UPF GTP-U support

### Start All Containers

```bash
# Clone repository
git clone https://github.com/free5gc/free5gc-compose.git
cd free5gc-compose

# Start all 16+ containers
docker compose up -d

# Verify all containers are running
docker compose ps

# Check logs for any container
docker compose logs -f amf
docker compose logs -f chf
docker compose logs -f n3iwf
```

### Start Selectively

If you want to run without optional components:

```bash
# Core only (mandatory + recommended)
docker compose up -d mongodb nrf amf ausf udm udr smf upf nssf pcf webui

# Core + Charging
docker compose up -d mongodb nrf amf ausf udm udr smf upf nssf pcf chf webui

# Core + Non-3GPP
docker compose up -d mongodb nrf amf ausf udm udr smf upf nssf pcf n3iwf webui

# Everything
docker compose up -d
```

### Stop All Containers

```bash
docker compose down

# Remove volumes (WARNING: deletes subscriber data in MongoDB)
docker compose down -v
```

---

## Complete UE-to-Core Flow

This section covers **every Network Function** involved in the UE registration and PDU session establishment process, including optional NFs like NSSF, PCF, CHF, and NEF.

### Phase 1: System Startup

**Step 1:** MongoDB starts
- Creates database `free5gc`
- Collections: `subscriptionData.authenticationData.authenticationSubscription`, `subscriptionData.provisionedData`, `policyData.ues.smData`

**Step 2:** NRF starts
- Connects to MongoDB: `mongodb://mongodb:27017`
- Listens on port 8000 (SBI HTTP/2)
- Ready to accept NF registrations

**Step 3:** All NFs register with NRF
Each NF sends `Nnrf_NFManagement_NFRegister` request with:
- NF type (AMF, SMF, UPF, AUSF, UDM, UDR, NSSF, PCF, CHF, NEF)
- NF instance ID (UUID)
- IP address and port
- Supported services (e.g., AMF: `Namf_Communication`, `Namf_EventExposure`)
- Supported PLMNs, slices, TACs

**NF Registration Order (typical):**
1. NSSF, PCF, CHF, NEF (policy and charging)
2. UDR (data storage)
3. UDM, AUSF (authentication)
4. SMF (session management)
5. UPF (user plane)
6. AMF (access management)
7. N3IWF, TNGF (non-3GPP access) - **optional**

**Step 4:** WebUI starts
- Connects to MongoDB for subscriber CRUD operations
- Listens on port 5000 (HTTP)
- Default admin credentials: `admin / free5gc`

**Step 5:** gNB (UERANSIM) registers
- Connects to AMF via N2 interface (SCTP port 38412)
- Sends `NG Setup Request` with:
  - Global gNB ID
  - Supported TACs (e.g., 1)
  - Supported S-NSSAIs (e.g., SST:1, SD:010203)
- AMF validates and sends `NG Setup Response`

**Step 6:** N3IWF registers (optional, if enabled)
- Registers with NRF as N3IWF NF type
- Establishes N2 connection to AMF (SCTP 38412)
- Listens for IKEv2 connections from Wi-Fi UEs on 10.100.200.15:500

---

### Phase 2: UE Registration (3GPP Access - Complete Flow)

This flow includes **all mandatory and recommended NFs** (NSSF, AUSF, UDM, UDR, PCF).

#### Step 1: Initial Registration Request
**UE → gNB → AMF**

- UE sends `Registration Request` with:
  - SUCI (Subscription Concealed Identifier) = encrypted SUPI
  - Registration type: Initial
  - Requested NSSAI: `[{sst:1, sd:010203}]`
- gNB forwards to AMF via N2 (NGAP protocol)

**AMF Actions:**
- Extracts SUCI from message
- Identifies TAI (Tracking Area Identity) from gNB
- Logs: `Handle Registration Request`

#### Step 2: Slice Selection (NSSF - Optional but Recommended)
**AMF → NSSF**

**If NSSF is deployed:**
- AMF queries NSSF: `Nnssf_NSSelection_Get`
  - Parameters: TAI, requested NSSAI, PLMN ID
- NSSF selects appropriate network slices
- NSSF returns: `Allowed NSSAI`, `Rejected NSSAI`, `Target AMF Set` (if different)
- Example response: `[{sst:1, sd:010203}]` (slice for eMBB - enhanced Mobile Broadband)

**If NSSF is NOT deployed:**
- AMF uses locally configured slices from `amfcfg.yaml`

#### Step 3: UE Identity Request (SUCI → SUPI)
**AMF → UDM**

- AMF needs to decrypt SUCI to get SUPI (permanent identifier)
- AMF sends `Nudm_UEAuthentication_Get` to UDM with SUCI
- UDM decrypts using private key
- UDM returns SUPI: `imsi-208930000000003`

#### Step 4: Authentication Vector Request
**AMF → AUSF → UDM → UDR → MongoDB**

**Full chain:**

1. **AMF → AUSF:** `Nausf_UEAuthentication_Authenticate`
   - Parameters: SUPI, serving network name (5G:mnc093.mcc208.3gppnetwork.org)

2. **AUSF → UDM:** `Nudm_UEAuthentication_Get`
   - Requests 5G AKA authentication vectors

3. **UDM → UDR:** `Nudr_DataRepository_Query`
   - Collection: `subscriptionData.authenticationData.authenticationSubscription`
   - Retrieves: K (permanent key), OPc (operator key), SQN (sequence number)

4. **UDR → MongoDB:** Direct query
   ```json
   {
     "ueId": "imsi-208930000000003",
     "authenticationMethod": "5G_AKA",
     "permanentKey": {
       "permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862"
     },
     "opc": {
       "opcValue": "8e27b6af0e692e750f32667a3b14605d"
     },
     "sequenceNumber": "16f3b3f70fc2"
   }
   ```

5. **UDM generates 5G AKA vectors:**
   - RAND (random challenge): 128 bits
   - AUTN (authentication token): 128 bits
   - XRES* (expected response): 128 bits
   - KAUSF (key material): 256 bits

6. **Response chain:** UDR → UDM → AUSF → AMF
   - AMF receives: RAND, AUTN, XRES*, KAUSF

#### Step 5: Authentication Request to UE
**AMF → gNB → UE**

- AMF sends `Authentication Request` with RAND, AUTN
- UE validates AUTN (checks if network is authentic)
- UE computes RES* using USIM card and K key
- UE sends `Authentication Response` with RES*

#### Step 6: Authentication Confirmation
**AMF → AUSF**

- AMF sends `Nausf_UEAuthentication_Authenticate` with RES*
- AUSF compares RES* with XRES*
- If match: authentication succeeds
- AUSF returns KSEAF (security key for AMF)

#### Step 7: Security Mode Command
**AMF → gNB → UE**

- AMF derives encryption keys from KSEAF
- AMF sends `Security Mode Command` with:
  - Ciphering algorithm: NEA0 (null) or NEA1/2/3 (AES, Snow3G, ZUC)
  - Integrity algorithm: NIA0 (null) or NIA1/2/3
- UE accepts and sends `Security Mode Complete`
- **NAS security context is now established**

#### Step 8: Retrieve Subscription Data
**AMF → UDM → UDR → MongoDB**

**Full chain:**

1. **AMF → UDM:** `Nudm_SubscriberDataManagement_Get`
   - Parameters: SUPI, PLMN ID, access type (3GPP_ACCESS)

2. **UDM → UDR:** `Nudr_DataRepository_Query`
   - Collection: `subscriptionData.provisionedData.amData`
   - Retrieves:
     - Subscribed NSSAI (allowed slices)
     - Subscriber status (registered/deregistered)
     - Default DNN (Data Network Name)
     - Access restrictions
     - Service area restrictions

3. **UDR → MongoDB:** Direct query
   ```json
   {
     "ueId": "imsi-208930000000003",
     "servingPlmnId": "20893",
     "subscribedUeAmbr": {
       "uplink": "1 Gbps",
       "downlink": "2 Gbps"
     },
     "nssai": {
       "defaultSingleNssais": [
         {"sst": 1, "sd": "010203"}
       ]
     },
     "gpsis": ["msisdn-0900000000"]
   }
   ```

4. **Response chain:** UDR → UDM → AMF

#### Step 9: Registration Accept
**AMF → gNB → UE**

- AMF sends `Registration Accept` with:
  - 5G-GUTI (Globally Unique Temporary Identifier) - new temporary identity
  - Allowed NSSAI: `[{sst:1, sd:010203}]`
  - TAI list (tracking areas UE can roam without registration update)
  - Periodic Registration Update Timer (e.g., 3600 seconds)

- UE sends `Registration Complete`
- **UE is now REGISTERED in RM-REGISTERED state**

#### Step 10: Create UE Context (Policy - PCF - Optional)
**AMF → PCF (if deployed)**

**If PCF is deployed:**
- AMF creates AM policy association: `Npcf_AMPolicyControl_Create`
  - Parameters: SUPI, access type, PLMN
- PCF returns AM policy (access mobility policy):
  - Service area restrictions
  - RFSP index (RAT/Frequency Selection Priority)
  - Triggers for policy update

**If PCF is NOT deployed:**
- AMF uses default policies from `amfcfg.yaml`

**Registration Complete! Total time: ~500ms - 1 second**

---

### Phase 3: PDU Session Establishment (Complete Flow with PCF and CHF)

This flow includes **policy control (PCF)** and **charging (CHF)**.

#### Step 1: PDU Session Request
**UE → gNB → AMF**

- UE sends `PDU Session Establishment Request` with:
  - PDU Session ID: 1
  - DNN (Data Network Name): "internet"
  - S-NSSAI: `{sst:1, sd:010203}`
  - PDU session type: IPv4

**AMF Actions:**
- Validates DNN and S-NSSAI are subscribed
- Logs: `Handle PDU Session Establishment Request`

#### Step 2: Select SMF
**AMF → NRF**

- AMF queries NRF: `Nnrf_NFDiscovery_Request`
  - NF type: SMF
  - S-NSSAI: `{sst:1, sd:010203}`
  - DNN: "internet"
  - TAI: 1

**NRF Actions:**
- Searches registered SMF instances
- Filters by S-NSSAI, DNN, TAI support
- Returns list of candidate SMFs with priority

**AMF selects SMF** (e.g., smf-1, 10.100.200.12:8000)

#### Step 3: Create SM Context
**AMF → SMF**

- AMF sends `Nsmf_PDUSession_CreateSMContext` with:
  - SUPI
  - PDU Session ID: 1
  - DNN: "internet"
  - S-NSSAI: `{sst:1, sd:010203}`
  - AMF callback URI

**SMF Actions:**
- Creates SM context for this PDU session
- Assigns session ID internally

#### Step 4: Get Session Management Subscription Data
**SMF → UDM → UDR → MongoDB**

**Full chain:**

1. **SMF → UDM:** `Nudm_SubscriberDataManagement_Get`
   - Parameters: SUPI, DNN, S-NSSAI

2. **UDM → UDR:** `Nudr_DataRepository_Query`
   - Collection: `subscriptionData.provisionedData.smData`
   - Retrieves:
     - Session AMBR (Aggregate Maximum Bit Rate)
     - Default 5QI (QoS Identifier)
     - Allowed DNN list
     - Charging characteristics

3. **UDR → MongoDB:** Direct query
   ```json
   {
     "ueId": "imsi-208930000000003",
     "servingPlmnId": "20893",
     "singleNssai": {"sst": 1, "sd": "010203"},
     "dnnConfigurations": {
       "internet": {
         "pduSessionTypes": {"defaultSessionType": "IPV4"},
         "sscModes": {"defaultSscMode": "SSC_MODE_1"},
         "5gQosProfile": {"5qi": 9, "arp": {"priorityLevel": 8}},
         "sessionAmbr": {"uplink": "100 Mbps", "downlink": "200 Mbps"},
         "staticIpAddress": [{"ipv4Addr": "10.60.0.1"}]
       }
     }
   }
   ```

4. **Response chain:** UDR → UDM → SMF

#### Step 5: Get SM Policy (PCF - Optional but Recommended)
**SMF → PCF**

**If PCF is deployed:**

1. **SMF → PCF:** `Npcf_SMPolicyControl_Create`
   - Parameters:
     - SUPI
     - DNN: "internet"
     - S-NSSAI: `{sst:1, sd:010203}`
     - PDU Session ID: 1
     - IP address: 10.60.0.1 (assigned by SMF from UE pool)
     - Access type: 3GPP_ACCESS
     - Charging characteristics

2. **PCF Actions:**
   - Queries UDR for policy data (operator rules, QoS limits)
   - Determines PCC (Policy and Charging Control) rules
   - Compiles SM policy decision

3. **PCF → SMF:** Returns SM policy with:
   - **Session rules:**
     - Session AMBR (e.g., uplink: 100 Mbps, downlink: 200 Mbps)
     - Default QoS rule (5QI: 9 - non-GBR internet)
   - **PCC rules (Packet Flow Description):**
     - Example: `rule-1` → Any IP traffic → 5QI: 9, ARP priority: 8
     - Example: `rule-2` → VoIP traffic (port 5060) → 5QI: 1, GBR: 100 Kbps
   - **Charging control:**
     - Online charging required: Yes/No
     - Offline charging required: Yes/No
     - Charging key: 1
     - Sponsor ID (if sponsored data)
   - **Usage monitoring:**
     - Volume threshold: 1 GB
     - Time threshold: 3600 seconds
     - Monitoring key: "mon-1"

4. **SMF stores policy** and applies to session

**If PCF is NOT deployed:**
- SMF uses default QoS from `smfcfg.yaml`:
  ```yaml
  qos:
    - qosRef: "9"
      5qi: 9
      sessionAmbr:
        uplink: "100 Mbps"
        downlink: "200 Mbps"
  ```

#### Step 6: Select UPF
**SMF → NRF**

- SMF queries NRF: `Nnrf_NFDiscovery_Request`
  - NF type: UPF
  - S-NSSAI: `{sst:1, sd:010203}`
  - DNN: "internet"
  - UE location (TAI: 1)

**NRF Actions:**
- Returns list of candidate UPFs
- SMF selects closest UPF (e.g., upf-1, 10.100.200.13)

#### Step 7: Reserve Charging Quota (CHF - Optional)
**SMF → CHF**

**If CHF is deployed:**

1. **SMF → CHF:** `Nchf_ConvergedCharging_Create`
   - Parameters:
     - SUPI
     - PDU Session ID: 1
     - DNN: "internet"
     - Charging key: 1 (from PCF policy)
     - Requested units:
       - Volume: 1 GB (1000000000 bytes)
       - Time: 3600 seconds
       - Service-specific units: 0
     - Session start time: 2026-02-09T10:00:00Z

2. **CHF Actions:**
   - Creates charging session (ChargingDataRef ID)
   - Allocates quota from subscriber balance (if online charging)
   - Determines rating (e.g., $0.10 per GB)
   - Starts usage tracking

3. **CHF → SMF:** Returns charging authorization with:
   - ChargingDataRef: "chg-session-12345"
   - Granted units:
     - Volume: 1 GB
     - Time: 3600 seconds
   - Validity time: 3600 seconds (quota expires, must reauthorize)
   - Final unit indication: Not final
   - Triggers: Volume threshold (800 MB), time threshold (3000s), validity time

4. **SMF stores charging context**

**If CHF is NOT deployed:**
- No charging tracking (free service)

#### Step 8: Establish N4 Session (PFCP)
**SMF → UPF**

**Protocol: PFCP (Packet Forwarding Control Protocol) - N4 interface**

1. **SMF → UPF:** `PFCP Session Establishment Request` with:
   - **PDR (Packet Detection Rule) - Uplink:**
     - PDR ID: 1
     - Precedence: 10
     - Source interface: ACCESS (from gNB)
     - UE IP address: 10.60.0.1
     - F-TEID (GTP-U tunnel from gNB): TEID: auto-allocated
     - Network instance: internet
     - QoS Enforcement Profile: 5QI: 9
   - **PDR - Downlink:**
     - PDR ID: 2
     - Precedence: 10
     - Source interface: CORE (from DN/internet)
     - UE IP address: 10.60.0.1
     - Network instance: internet
   - **FAR (Forwarding Action Rule) - Uplink:**
     - FAR ID: 1
     - Apply action: FORWARD
     - Destination interface: CORE (to DN/internet via N6)
     - Network instance: internet
   - **FAR - Downlink:**
     - FAR ID: 2
     - Apply action: FORWARD
     - Destination interface: ACCESS (to gNB via N3)
     - Outer header creation: GTP-U tunnel to gNB (TEID: to be provided in next step)
   - **QER (QoS Enforcement Rule):**
     - QER ID: 1
     - QFI (QoS Flow Identifier): 1
     - 5QI: 9
     - MBR uplink: 100 Mbps
     - MBR downlink: 200 Mbps
     - GFBR (if GBR): N/A (non-GBR flow)
   - **URR (Usage Reporting Rule) - if CHF deployed:**
     - URR ID: 1
     - Measurement method: VOLUME, TIME, DURATION
     - Volume threshold: 800 MB (trigger report at 80% of 1 GB quota)
     - Time threshold: 3000 seconds
     - Quota holding time: 3600 seconds

2. **UPF Actions:**
   - Allocates GTP-U TEID for downlink: e.g., 0x00000001
   - Allocates UE IP: 10.60.0.1 (or validates SMF-assigned IP)
   - Creates PDR, FAR, QER, URR entries in forwarding table
   - Installs iptables/eBPF rules for packet forwarding
   - Starts usage counters (uplink bytes, downlink bytes, duration)

3. **UPF → SMF:** `PFCP Session Establishment Response` with:
   - PFCP Session ID (F-SEID): UPF node ID + local session ID
   - Created PDR: Downlink F-TEID for N3 tunnel (TEID: 0x00000001)
   - UE IP address: 10.60.0.1
   - Cause: Request accepted

**N4 session established! UPF is ready to forward packets**

#### Step 9: Provide N2 SM Information to AMF
**SMF → AMF**

- SMF sends `Nsmf_PDUSession_CreateSMContext Response` with N2 SM info:
  - PDU Session ID: 1
  - QoS flows:
    - QFI: 1, 5QI: 9, ARP priority: 8
    - Session AMBR: uplink 100 Mbps, downlink 200 Mbps
  - **UPF N3 tunnel info:**
    - UPF GTP-U address: 10.100.200.13 (UPF IP)
    - UPF GTP-U TEID: 0x00000001 (for downlink)
  - UE IP address: 10.60.0.1

#### Step 10: Setup N3 Tunnel (AMF → gNB)
**AMF → gNB**

**Protocol: NGAP (N2 interface)**

- AMF sends `PDU Session Resource Setup Request` with:
  - UE NGAP ID (identifies UE context)
  - PDU Session ID: 1
  - QoS flows: QFI 1, 5QI 9, ARP 8
  - Session AMBR
  - **UPF N3 tunnel:** IP: 10.100.200.13, TEID: 0x00000001
  - NAS message container: `PDU Session Establishment Accept` for UE

**gNB Actions:**
1. Allocates GTP-U TEID for uplink: e.g., 0x00000ABC
2. Configures DRB (Data Radio Bearer):
   - DRB ID: 1
   - PDCP, RLC, MAC layer configs
   - Maps QFI 1 to DRB 1
3. Stores UPF tunnel info (10.100.200.13:0x00000001)
4. Sends RRC Reconfiguration to UE over Uu interface with DRB config

**UE Actions:**
- Accepts RRC Reconfiguration
- Activates DRB 1
- Sends RRC Reconfiguration Complete

#### Step 11: Confirm N3 Tunnel (gNB → AMF → SMF)
**gNB → AMF → SMF**

1. **gNB → AMF:** `PDU Session Resource Setup Response` with:
   - PDU Session ID: 1
   - Accepted QoS flows: QFI 1
   - **gNB N3 tunnel info:** IP: 10.100.200.11, TEID: 0x00000ABC (uplink)

2. **AMF → SMF:** `Nsmf_PDUSession_UpdateSMContext` with gNB tunnel info

3. **SMF → UPF:** `PFCP Session Modification Request` with:
   - Update FAR-1 (uplink): No change (forward to N6)
   - **Update FAR-2 (downlink):** Add outer header creation:
     - GTP-U tunnel to gNB: IP: 10.100.200.11, TEID: 0x00000ABC

4. **UPF → SMF:** `PFCP Session Modification Response`: Cause: Request accepted

**N3 tunnels established! Data path is now complete**

#### Step 12: Send PDU Session Accept to UE
**AMF → gNB → UE**

- AMF sends `PDU Session Establishment Accept` (NAS message) with:
  - PDU Session ID: 1
  - Session type: IPv4
  - UE IP address: 10.60.0.1
  - QoS rules: Default rule (all traffic), 5QI: 9
  - Session AMBR: uplink 100 Mbps, downlink 200 Mbps

- gNB forwards to UE via RRC

**PDU Session Established! UE can now send/receive data**

**Total time: ~1-2 seconds**

---

### Phase 4: Data Flow with Charging and Usage Reporting

This phase shows how user data flows through the network, with periodic usage reporting to CHF for billing.

#### Uplink Data Flow (UE → Internet)

**Step 1:** UE sends IP packet
- Source: 10.60.0.1 (UE IP)
- Destination: 8.8.8.8 (Google DNS)
- DRB 1, QFI 1

**Step 2:** gNB encapsulates in GTP-U
- GTP-U header: TEID: 0x00000001 (UPF tunnel), QFI: 1
- Outer IP: Source: 10.100.200.11 (gNB), Dest: 10.100.200.13 (UPF)
- Sends via N3 interface (UDP port 2152)

**Step 3:** UPF receives and processes
- Matches PDR-1 (uplink from ACCESS)
  - Source interface: ACCESS
  - F-TEID: 0x00000001
- Extracts inner IP packet (10.60.0.1 → 8.8.8.8)
- Applies QER-1: Enforces 5QI 9 (rate limiting, priority marking)
- Applies FAR-1: FORWARD to CORE (N6 interface)
- **Updates URR-1 counters:**
  - Uplink volume: +52 bytes (IP packet size)
  - Uplink packets: +1
  - Duration: continues
- Performs NAT (if configured):
  - Changes source IP: 10.60.0.1 → 172.18.0.3 (UPF public IP)
- Forwards to internet via N6 interface

**Step 4:** Internet processes packet
- Reaches 8.8.8.8, generates DNS response

#### Downlink Data Flow (Internet → UE)

**Step 1:** Internet sends IP packet
- Source: 8.8.8.8
- Destination: 172.18.0.3 (UPF public IP after NAT)

**Step 2:** UPF receives on N6 interface
- Performs reverse NAT:
  - Changes destination IP: 172.18.0.3 → 10.60.0.1 (UE IP)
- Matches PDR-2 (downlink from CORE)
  - Source interface: CORE
  - UE IP: 10.60.0.1
- Applies QER-1: Enforces 5QI 9
- Applies FAR-2: FORWARD to ACCESS (N3 interface)
  - Encapsulates in GTP-U: TEID: 0x00000ABC (gNB tunnel), QFI: 1
  - Outer IP: Source: 10.100.200.13 (UPF), Dest: 10.100.200.11 (gNB)
- **Updates URR-1 counters:**
  - Downlink volume: +60 bytes
  - Downlink packets: +1
- Sends to gNB via N3 (UDP port 2152)

**Step 3:** gNB receives and decapsulates
- Removes GTP-U header
- Extracts inner IP packet (8.8.8.8 → 10.60.0.1)
- Maps QFI 1 to DRB 1
- Sends to UE via Uu interface (RRC, PDCP, RLC, MAC, PHY layers)

**Step 4:** UE receives IP packet
- Application processes (e.g., browser displays webpage)

**Data flow complete! Round-trip time: ~50-100ms (depending on internet latency)**

#### Periodic Usage Reporting (UPF → SMF → CHF)

**Trigger Conditions (from URR-1):**
- Volume threshold reached: 800 MB uplink + downlink (80% of 1 GB quota)
- Time threshold reached: 3000 seconds elapsed
- Quota validity time expires: 3600 seconds
- PDU session termination

**Reporting Flow:**

**Step 1:** UPF detects trigger (e.g., 800 MB threshold)
- Current counters:
  - Uplink volume: 420 MB
  - Downlink volume: 380 MB
  - Total: 800 MB
  - Duration: 2500 seconds
  - Start time: 2026-02-09T10:00:00Z
  - End time: 2026-02-09T10:41:40Z

**Step 2:** UPF → SMF: `PFCP Session Report Request`
- Usage Report:
  - URR ID: 1
  - Uplink volume: 440401152 bytes (420 MB)
  - Downlink volume: 398458880 bytes (380 MB)
  - Total volume: 838860032 bytes (800 MB)
  - Duration: 2500 seconds
  - Start time: 2026-02-09T10:00:00Z
  - End time: 2026-02-09T10:41:40Z
  - Trigger: Volume threshold

**Step 3:** SMF acknowledges: `PFCP Session Report Response`

**Step 4:** SMF → CHF: `Nchf_ConvergedCharging_Update`
- ChargingDataRef: "chg-session-12345"
- Usage consumed:
  - Volume: 800 MB
  - Time: 2500 seconds
- Request new quota:
  - Volume: 1 GB
  - Time: 3600 seconds

**Step 5:** CHF processes usage
- Records CDR (Charging Data Record):
  ```json
  {
    "recordType": "USAGE_UPDATE",
    "recordSequenceNumber": 2,
    "supi": "imsi-208930000000003",
    "pduSessionId": 1,
    "dnn": "internet",
    "chargingKey": 1,
    "volumeUplink": 440401152,
    "volumeDownlink": 398458880,
    "duration": 2500,
    "startTime": "2026-02-09T10:00:00Z",
    "endTime": "2026-02-09T10:41:40Z",
    "rating": {
      "ratePerGB": 0.10,
      "totalCost": 0.08
    }
  }
  ```
- Deducts cost from subscriber balance (if online charging)
- Grants new quota

**Step 6:** CHF → SMF: Charging authorization
- Granted units:
  - Volume: 1 GB
  - Time: 3600 seconds
- Validity time: 3600 seconds
- Final unit indication: Not final

**Step 7:** SMF → UPF: `PFCP Session Modification Request`
- Update URR-1:
  - Reset counters (uplink: 0, downlink: 0)
  - New volume threshold: 800 MB
  - New time threshold: 3000 seconds
  - New quota holding time: 3600 seconds

**Step 8:** UPF → SMF: `PFCP Session Modification Response`
- Counters reset, new thresholds applied

**Charging cycle repeats every 800 MB or 3600 seconds**

#### Final Charging (PDU Session Termination)

When UE disconnects:

**Step 1:** UPF → SMF: Final usage report
- Total session usage:
  - Uplink: 1.2 GB
  - Downlink: 2.8 GB
  - Total: 4.0 GB
  - Duration: 7200 seconds (2 hours)

**Step 2:** SMF → CHF: `Nchf_ConvergedCharging_Release`
- Final usage consumed
- ChargingDataRef: "chg-session-12345"

**Step 3:** CHF generates final CDR
- Record type: SESSION_END
- Total volume: 4.0 GB
- Total cost: $0.40 (4 GB × $0.10/GB)
- Session end time: 2026-02-09T12:00:00Z

**Step 4:** CHF → CGF (Charging Gateway Function on WebUI)
- Sends CDR via FTP to WebUI:2121 or via Diameter (3868/3869)
- CGF stores CDR in billing system

**Charging complete! CDR sent to billing system**

---

### Phase 5: Non-3GPP Access Flow (N3IWF Path)

This is an **alternate path** for Wi-Fi UEs connecting via untrusted non-3GPP access (e.g., public Wi-Fi, home Wi-Fi without 5G femtocell).

#### Step 1: Wi-Fi UE Discovers N3IWF
**UE → N3IWF**

- UE has SIM card with SUPI but no cellular signal
- UE connects to Wi-Fi network (gets IP: 10.100.200.203 via DHCP)
- UE discovers N3IWF IP: 10.100.200.15 (configured or via DNS)
- UE initiates IKEv2 connection to N3IWF:500 (UDP)

#### Step 2: IKEv2 Phase 1 (IKE_SA_INIT)
**UE ↔ N3IWF**

- UE sends `IKE_SA_INIT` request:
  - Proposal: Encryption AES-256-CBC, PRF HMAC-SHA256, DH group 14
  - Nonce, KE (Key Exchange) payload
- N3IWF responds with chosen SA, nonce, KE
- **IKE SA established (no authentication yet)**

#### Step 3: IKEv2 Phase 2 (IKE_AUTH with EAP-5G)
**UE ↔ N3IWF ↔ AMF**

**Sub-step 3.1:** UE → N3IWF: `IKE_AUTH` request
- IDi (Identity): SUCI (encrypted SUPI)
- EAP-5G Start message
- Traffic selectors (UE wants IP address in 10.0.0.0/24 pool)

**Sub-step 3.2:** N3IWF → AMF: N2 connection
- N3IWF establishes SCTP connection to AMF:38412 (same as gNB)
- Sends `NG Setup Request`:
  - Global N3IWF ID
  - Supported TACs: 1
  - Supported S-NSSAIs: `{sst:1, sd:010203}`
- AMF sends `NG Setup Response`

**Sub-step 3.3:** N3IWF → AMF: `Initial UE Message`
- Contains EAP-5G message from UE (SUCI, registration request)
- Access type: NON_3GPP_ACCESS

**Sub-step 3.4:** AMF → N3IWF → UE: EAP-5G authentication
- AMF runs same authentication flow as 3GPP:
  - NSSF (slice selection)
  - AUSF → UDM → UDR → MongoDB (5G AKA)
  - Generates RAND, AUTN, XRES*
- AMF sends EAP-5G Request with RAND, AUTN
- N3IWF forwards via IKEv2 to UE
- UE computes RES*, sends EAP-5G Response
- AMF validates RES* with AUSF
- AMF sends EAP-5G Success

**Sub-step 3.5:** N3IWF → UE: `IKE_AUTH` response
- EAP-5G Success
- AUTH payload (proves N3IWF authenticated to AMF)
- Configuration payload:
  - Internal IP: 10.0.0.1 (from N3IWF pool)
  - DNS: 8.8.8.8
- Traffic selectors accepted

**Sub-step 3.6:** UE → N3IWF: `IKE_AUTH` final
- AUTH payload (proves UE authenticated)
- **IKE_AUTH complete, IPSec tunnel established**

#### Step 4: IPSec Child SA (ESP Tunnel)
**UE ↔ N3IWF**

- UE sends `CREATE_CHILD_SA` request:
  - Proposal: ESP (Encapsulating Security Payload) with AES-256-GCM
  - Traffic selectors: 0.0.0.0/0 (all traffic)
- N3IWF responds with chosen SA
- **IPSec ESP tunnel established (all UE traffic encrypted via IPSec)**

#### Step 5: N3IWF Registers UE with AMF
**N3IWF → AMF**

- N3IWF sends `Registration Request` on behalf of UE via N2
- AMF runs same registration flow:
  - UDM subscription data retrieval
  - PCF AM policy (if deployed)
  - Sends `Registration Accept`
- **UE is now REGISTERED via non-3GPP access**

#### Step 6: PDU Session Establishment (Non-3GPP)
**UE → N3IWF → AMF → SMF**

- UE sends `PDU Session Establishment Request` (via IPSec tunnel)
- N3IWF forwards to AMF via N2
- AMF → SMF: `Nsmf_PDUSession_CreateSMContext`
- SMF runs same flow:
  - UDM subscription data
  - PCF SM policy
  - CHF charging authorization (if deployed)
  - UPF selection
- **Key difference:** SMF instructs UPF to create N3 tunnel to **N3IWF** (not gNB)

**SMF → UPF:** `PFCP Session Establishment Request`
- PDR-1 (uplink): Source interface: ACCESS (from **N3IWF**)
  - F-TEID for N3IWF uplink tunnel
- FAR-2 (downlink): Destination interface: ACCESS (to **N3IWF**)
  - Outer header: GTP-U to N3IWF (IP: 10.100.200.15, TEID: 0x00000DEF)

**SMF → AMF → N3IWF:** N2 SM information with UPF tunnel

**N3IWF Actions:**
- Creates GTP-U tunnel to UPF (IP: 10.100.200.13, TEID: 0x00000001)
- Maps IPSec SA to GTP-U tunnel
- Responds to AMF with N3IWF tunnel info (TEID: 0x00000DEF)

**AMF → SMF → UPF:** Update with N3IWF tunnel (PFCP Session Modification)

**PDU session established! UE can now send data**

#### Step 7: Data Flow (Non-3GPP)
**Uplink:**
1. UE sends IP packet (10.60.0.1 → 8.8.8.8)
2. UE encrypts with IPSec ESP (AES-256-GCM)
3. UE encapsulates: Inner IP (10.60.0.1 → 8.8.8.8), ESP header, outer IP (10.0.0.1 → 10.100.200.15)
4. **N3IWF receives:**
   - Decrypts IPSec ESP
   - Extracts inner IP packet
   - Encapsulates in GTP-U (TEID: 0x00000001, to UPF)
5. **UPF processes** (same as 3GPP):
   - Matches PDR-1, applies QER-1, FAR-1
   - Forwards to internet via N6
6. Internet processes (8.8.8.8 responds)

**Downlink:**
1. Internet sends packet (8.8.8.8 → UPF public IP)
2. **UPF processes:**
   - NAT to UE IP (10.60.0.1)
   - Matches PDR-2, applies QER-1, FAR-2
   - Encapsulates in GTP-U (TEID: 0x00000DEF, to N3IWF)
3. **N3IWF receives:**
   - Decapsulates GTP-U
   - Extracts inner IP packet (8.8.8.8 → 10.60.0.1)
   - Encrypts with IPSec ESP
   - Encapsulates: Inner IP, ESP header, outer IP (10.100.200.15 → 10.0.0.1)
4. UE receives, decrypts IPSec, delivers to application

**Data flow complete! Path: UE → IPSec → N3IWF → GTP-U → UPF → Internet**

**Key differences from 3GPP:**
- No radio interface (Uu), no gNB
- IPSec encryption instead of PDCP/RLC encryption
- N3IWF acts as gateway between IPSec and GTP-U
- Same AMF, SMF, UPF, authentication, charging flows

---

### Phase 6: Trusted Non-3GPP Access (TNGF Path - Optional)

This is for **trusted non-3GPP access** (e.g., corporate Wi-Fi with 5G integration, no IPSec needed).

#### Key Differences from N3IWF:
- **No IPSec encryption** (trust relationship exists between operator and enterprise)
- Uses **Radius authentication** to enterprise AAA server
- Runs on **HOST network** mode (direct access to host interfaces)
- Suitable for **enterprise deployments** (office Wi-Fi, campus networks)

#### Flow Summary:
1. UE connects to trusted Wi-Fi, gets IP from enterprise DHCP
2. UE sends registration request to TNGF (no IKEv2, direct NAS message)
3. TNGF queries enterprise Radius server for authentication
4. Radius server validates credentials (user/pass or EAP-TLS cert)
5. TNGF forwards registration to AMF via N2
6. AMF runs same registration flow (UDM, PCF)
7. UE establishes PDU session, TNGF creates N3 tunnel to UPF
8. Data flows: UE → TNGF → GTP-U → UPF → Internet (no IPSec)

**When to use:**
- Corporate campus networks
- Trusted partner networks (e.g., hotel chain with agreement)
- Fixed wireless access (FWA) with trusted CPE

---

### Phase 7: External API Access (NEF)

The **NEF (Network Exposure Function)** allows **3rd party applications** to interact with the 5G core network.

#### Example Use Cases:
1. **Traffic influence:** Video CDN requests UPF to route traffic via specific path
2. **Event monitoring:** Rideshare app monitors UE location, roaming status
3. **QoS on-demand:** Gaming server requests low-latency slice for tournament
4. **PFD management:** Enterprise adds custom application detection rules

#### Example Flow: PFD Management (Packet Flow Description)

**Step 1:** External app authenticates with NEF
- OAuth 2.0 token or API key
- NEF validates with NRF (checks if app is authorized)

**Step 2:** App sends PFD management request
**External App → NEF:** `Nnef_PFDManagement_CreateTransaction`
- Application ID: "video-streaming-app"
- PFDs:
  - Flow description: IP 203.0.113.0/24, port 8080-8090
  - Domain name: `*.videocdn.example.com`
- Expiry time: 2026-02-10T00:00:00Z

**Step 3:** NEF validates and forwards
**NEF → NRF:** Discover PCF
**NEF → PCF:** `Npcf_PolicyAuthorization_Create`
- AppId: "video-streaming-app"
- PFD: IP 203.0.113.0/24, port 8080-8090

**Step 4:** PCF stores PFD and applies to sessions
- PCF creates PCC rule: Detect traffic to 203.0.113.0/24:8080-8090, apply 5QI 7 (video streaming)
- PCF notifies SMF of policy update via `Npcf_SMPolicyControl_UpdateNotify`

**Step 5:** SMF updates UPF
**SMF → UPF:** `PFCP Session Modification Request`
- New PDR-3: Detect destination IP 203.0.113.0/24, port 8080-8090
- New QER-2: Apply 5QI 7 (GBR 5 Mbps)
- New FAR-3: Forward to CORE with priority marking

**Step 6:** UPF applies new rules
- Traffic matching 203.0.113.0/24:8080-8090 now gets higher priority
- Video streaming packets bypass congestion queues

**Step 7:** NEF responds to app
**NEF → External App:** `201 Created`
- Transaction ID: "pfd-txn-12345"
- Expiry time: 2026-02-10T00:00:00Z

**External API complete! 3rd party app influenced network policy**

#### Other NEF APIs:
- **Nnef_EventExposure:** Subscribe to UE events (roaming, reachability, location)
- **Nnef_TrafficInfluence:** Request traffic routing to specific UPF or DN
- **Nnef_ChargeableParty:** Sponsor data for specific UE (zero-rating)

---

## Complete ASCII Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          5G SA Network - All Components                      │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────┐
│  External   │──────────────┐
│     App     │              │
└─────────────┘              │
                             ▼
                        ┌─────────┐
                        │   NEF   │────────┐
                        └─────────┘        │
                                           │
┌──────────────────────────────────────────│──────────────────────────────────┐
│                                          │                                   │
│  ┌─────────┐         ┌─────────┐        │        ┌─────────┐               │
│  │ MongoDB │◄────────│   NRF   │◄───────┴────────│  WebUI  │               │
│  └─────────┘         └─────────┘                 └─────────┘               │
│       ▲                   ▲                            │                    │
│       │                   │                            │ (admin)            │
│       │                   │ (service registration)     ▼                    │
│       │                   │                                                 │
│       │              ┌────┴───────────────────────────────┐                │
│       │              │                                     │                │
│       │         ┌────▼─────┐  ┌─────────┐  ┌─────────┐  ┌▼──────┐         │
│       │         │   AMF    │  │  NSSF   │  │   PCF   │  │  CHF  │         │
│       │         └────┬─────┘  └─────────┘  └────┬────┘  └───┬───┘         │
│       │              │                           │           │             │
│       │         ┌────▼─────┐  ┌─────────┐       │           │             │
│       │         │  AUSF    │  │   UDM   │       │           │             │
│       │         └────┬─────┘  └────┬────┘       │           │             │
│       │              │             │             │           │             │
│       │         ┌────▼─────────────▼──┐          │           │             │
│       └─────────│       UDR           │          │           │             │
│                 └─────────────────────┘          │           │             │
│                                                  │           │             │
│                        ┌─────────┐               │           │             │
│                        │   SMF   │◄──────────────┴───────────┘             │
│                        └────┬────┘                                         │
│                             │                                              │
│                        ┌────▼────┐                                         │
│                        │   UPF   │─────────► Internet (N6)                 │
│                        └────┬────┘                                         │
│                             │ (N3 GTP-U:2152)                              │
└─────────────────────────────│──────────────────────────────────────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
         │ (3GPP)             │ (Non-3GPP)         │ (Non-3GPP Trusted)
         │                    │                    │
    ┌────▼────┐          ┌────▼────┐         ┌────▼────┐
    │   gNB   │          │  N3IWF  │         │  TNGF   │
    └────┬────┘          └────┬────┘         └────┬────┘
         │ (Uu radio)         │ (IKEv2:500)       │ (direct NAS)
         │                    │ (IPSec ESP)       │
    ┌────▼────┐          ┌────▼────┐         ┌────▼────┐
    │ 3GPP UE │          │ Wi-Fi UE│         │ Corp UE │
    │ (UERANSIM)         │ (N3IWUE)│         │         │
    └─────────┘          └─────────┘         └─────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                         Interface Legend                                  │
├──────────────────────────────────────────────────────────────────────────┤
│  N1: UE ↔ AMF (NAS signaling)                                            │
│  N2: gNB/N3IWF ↔ AMF (NGAP signaling, SCTP:38412)                       │
│  N3: gNB/N3IWF ↔ UPF (GTP-U user data, UDP:2152)                        │
│  N4: SMF ↔ UPF (PFCP session control, UDP:8805)                         │
│  N6: UPF ↔ Internet (Data Network)                                       │
│  Uu: UE ↔ gNB (radio interface)                                          │
│  SBI: All NF ↔ NF (Service-Based Interface, HTTP/2, port 8000)          │
│  IKEv2: Wi-Fi UE ↔ N3IWF (IPSec tunnel establishment, UDP:500/4500)     │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                         Data Path Flow                                    │
├──────────────────────────────────────────────────────────────────────────┤
│  3GPP Path:                                                               │
│    UE ──(Uu)──► gNB ──(N3/GTP-U)──► UPF ──(N6)──► Internet              │
│                                                                           │
│  Non-3GPP Path:                                                           │
│    Wi-Fi UE ──(IPSec)──► N3IWF ──(N3/GTP-U)──► UPF ──(N6)──► Internet   │
│                                                                           │
│  Trusted Non-3GPP Path:                                                   │
│    Corp UE ──(Plain)──► TNGF ──(N3/GTP-U)──► UPF ──(N6)──► Internet     │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                      Charging & Billing Flow                              │
├──────────────────────────────────────────────────────────────────────────┤
│  1. SMF ──(Nchf_ConvergedCharging_Create)──► CHF (reserve quota)        │
│  2. UPF reports usage ──(PFCP)──► SMF ──(Update)──► CHF                 │
│  3. CHF generates CDR ──(FTP:2121 or Diameter:3868)──► CGF/WebUI        │
│  4. CGF stores CDR in billing system                                     │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                      External API Exposure                                │
├──────────────────────────────────────────────────────────────────────────┤
│  External App ──(OAuth2/API Key)──► NEF ──(NRF lookup)──► Target NF     │
│  Examples: PFD management, traffic influence, event monitoring           │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Container Resource Usage

Approximate resource usage per container (based on free5GC defaults, idle state):

| Container | Memory (MB) | CPU (%) | Notes |
|-----------|-------------|---------|-------|
| MongoDB | 200-500 MB | 5-10% | Grows with subscriber count |
| NRF | 20-30 MB | <1% | Lightweight registry |
| AMF | 30-50 MB | 2-5% | Per UE: +2-5 MB |
| AUSF | 15-25 MB | <1% | Stateless |
| UDM | 15-25 MB | <1% | Stateless proxy |
| UDR | 20-30 MB | <1% | DB client |
| NSSF | 15-25 MB | <1% | Slice selector |
| PCF | 20-35 MB | 1-2% | Policy engine |
| SMF | 40-60 MB | 5-10% | Per session: +5-10 MB |
| UPF | 50-100 MB | 10-30% | Data plane, grows with traffic |
| CHF | 25-40 MB | 1-2% | Charging state |
| NEF | 20-30 MB | <1% | API gateway |
| N3IWF | 30-50 MB | 2-5% | IPSec processing |
| TNGF | 25-40 MB | 1-3% | Radius client |
| WebUI | 30-50 MB | 1-2% | Web server |
| UERANSIM | 10-20 MB | 1-2% | Per UE: +5 MB |
| N3IWUE | 10-20 MB | 1-2% | Per UE: +5 MB |

**Total (all 16+ containers):** ~600 MB - 1.2 GB RAM, 30-60% CPU (idle/light load)

**Recommendations:**
- **Development:** 4 GB RAM, 2 CPU cores (core only)
- **Testing with simulators:** 8 GB RAM, 4 CPU cores
- **Production-like (all components):** 16 GB RAM, 8 CPU cores

---

## Full Port Map

### Mandatory Core

| Container | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| **MongoDB** | 27017 | TCP | MongoDB database |
| **NRF** | 8000 | TCP/HTTP2 | SBI (Service-Based Interface) |
| **AMF** | 8000 | TCP/HTTP2 | SBI |
| **AMF** | 38412 | SCTP | N2 interface (from gNB/N3IWF) |
| **AUSF** | 8000 | TCP/HTTP2 | SBI |
| **UDM** | 8000 | TCP/HTTP2 | SBI |
| **UDR** | 8000 | TCP/HTTP2 | SBI |
| **SMF** | 8000 | TCP/HTTP2 | SBI |
| **SMF** | 8805 | UDP | N4 PFCP (from UPF) |
| **UPF** | 2152 | UDP | N3 GTP-U (from gNB/N3IWF) |
| **UPF** | 8805 | UDP | N4 PFCP (to SMF) |

### Recommended

| Container | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| **NSSF** | 8000 | TCP/HTTP2 | SBI |
| **PCF** | 8000 | TCP/HTTP2 | SBI |
| **WebUI** | 5000 | TCP/HTTP | Web interface |
| **WebUI** | 2121 | TCP | FTP (CGF for CDRs from CHF) |
| **WebUI** | 2122 | TCP | SFTP (secure CGF) |

### Optional - Charging & Exposure

| Container | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| **CHF** | 8000 | TCP/HTTP2 | SBI |
| **CHF** | 3868 | TCP | Diameter (CCR/CCA charging) |
| **CHF** | 3869 | SCTP | Diameter (SCTP transport) |
| **NEF** | 8000 | TCP/HTTP2 | SBI (internal to 5GC) |
| **NEF** | 8888 | TCP/HTTP | External API (for 3rd party apps) |

### Optional - Non-3GPP Access

| Container | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| **N3IWF** | 8000 | TCP/HTTP2 | SBI |
| **N3IWF** | 38412 | SCTP | N2 interface (to AMF) |
| **N3IWF** | 2152 | UDP | N3 GTP-U (to UPF) |
| **N3IWF** | 500 | UDP | IKEv2 (from Wi-Fi UE) |
| **N3IWF** | 4500 | UDP | IKEv2 NAT-T (from Wi-Fi UE behind NAT) |
| **TNGF** | 8000 | TCP/HTTP2 | SBI |
| **TNGF** | 38412 | SCTP | N2 interface (to AMF) |
| **TNGF** | 2152 | UDP | N3 GTP-U (to UPF) |
| **TNGF** | 1812 | UDP | Radius auth (to AAA server) |
| **TNGF** | 1813 | UDP | Radius accounting (to AAA server) |

### Simulators

| Container | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| **UERANSIM** | 4997 | UDP | SCTP/NGAP control (gNB to AMF) |
| **UERANSIM** | 2152 | UDP | GTP-U (gNB to UPF) |
| **N3IWUE** | Random | UDP | IKEv2 client (to N3IWF:500) |

**Port Conflict Notes:**
- All NFs use port 8000 for SBI but on different IPs (10.100.200.10-20.30)
- AMF, N3IWF, TNGF share port 38412 (SCTP) but only AMF listens
- UPF, gNB, N3IWF, TNGF share port 2152 (GTP-U) on different interfaces
- In HOST network mode (TNGF, UPF), ports must not conflict with host services

---

## Configuration Files

All configuration files are in the `config/` directory:

| File | Purpose | Key Parameters |
|------|---------|----------------|
| `amfcfg.yaml` | AMF configuration | PLMN, TAI, NSSAI, security algorithms |
| `ausfcfg.yaml` | AUSF configuration | PLMN, authentication method |
| `nrfcfg.yaml` | NRF configuration | MongoDB URI, service URL |
| `nssfcfg.yaml` | NSSF configuration | Slice selection rules, AMF set |
| `pcfcfg.yaml` | PCF configuration | Policy rules, QoS limits |
| `smfcfg.yaml` | SMF configuration | DNN, UE pool, QoS profiles, UPF selection |
| `udmcfg.yaml` | UDM configuration | PLMN, UDR endpoint |
| `udrcfg.yaml` | UDR configuration | MongoDB URI, collections |
| `upfcfg.yaml` | UPF configuration | N3 interface, N4 interface, N6 interface, DNN |
| `chfcfg.yaml` | CHF configuration | Diameter endpoints, CGF config, rating groups |
| `nefcfg.yaml` | NEF configuration | External API port, OAuth2 config, PFD settings |
| `n3iwfcfg.yaml` | N3IWF configuration | IKEv2 settings, IPSec SA lifetime, UE pool |
| `tngfcfg.yaml` | TNGF configuration | Radius server IP, shared secret, network mode |
| `webuicfg.yaml` | WebUI configuration | MongoDB URI, admin credentials, FTP port |
| `gnbcfg.yaml` | UERANSIM gNB | MCC/MNC, TAC, NSSAI, AMF address, gNB ID |
| `uecfg.yaml` | UERANSIM UE | SUPI, K, OPc, PLMN, NSSAI, DNN |
| `n3uecfg.yaml` | N3IWUE | SUPI, K, OPc, N3IWF address, IPSec SA params |

**Key Configuration Parameters:**

### PLMN (Public Land Mobile Network)
- **MCC (Mobile Country Code):** 208 (France, used in examples)
- **MNC (Mobile Network Code):** 93 (operator ID)
- **PLMN ID:** "20893" (MCC + MNC)

### TAI (Tracking Area Identity)
- **TAC (Tracking Area Code):** 1 (for local deployment)
- **TAI = PLMN + TAC:** "20893, TAC 1"

### NSSAI (Network Slice Selection Assistance Information)
- **SST (Slice/Service Type):** 1 (eMBB - enhanced Mobile Broadband)
- **SD (Slice Differentiator):** "010203" (24-bit hex, identifies slice variant)
- **S-NSSAI:** `{sst: 1, sd: "010203"}`

### DNN (Data Network Name)
- "internet" (default for public internet access)
- "ims" (IP Multimedia Subsystem for VoLTE)
- Custom DNNs: "enterprise", "iot", etc.

### Security Keys (per subscriber in WebUI)
- **K (Permanent Key):** 128-bit secret key on USIM (e.g., `8baf473f2f8fd09487cccbd7097c6862`)
- **OPc (Operator Key):** 128-bit derived key (e.g., `8e27b6af0e692e750f32667a3b14605d`)
- **SQN (Sequence Number):** 48-bit anti-replay counter (e.g., `16f3b3f70fc2`)

### QoS Parameters
- **5QI (5G QoS Identifier):** 1-9 (GBR), 10-79 (non-GBR), 80-255 (operator-specific)
  - 1: Conversational voice (VoLTE) - GBR 100 Kbps
  - 5: IMS signaling - non-GBR
  - 7: Video streaming - GBR 5 Mbps
  - 9: Default internet - non-GBR
- **ARP (Allocation and Retention Priority):** 1-15 (1 = highest, 15 = lowest)
- **AMBR (Aggregate Maximum Bit Rate):**
  - Session AMBR: e.g., uplink 100 Mbps, downlink 200 Mbps
  - UE AMBR: e.g., uplink 1 Gbps, downlink 2 Gbps (across all sessions)

---

## Troubleshooting All Components

### Check All Containers

```bash
# List all containers with status
docker compose ps

# Expected output: 16+ containers, all "Up"
```

### Check Logs

```bash
# Core NFs
docker compose logs -f amf
docker compose logs -f smf
docker compose logs -f upf

# Optional NFs
docker compose logs -f pcf
docker compose logs -f chf
docker compose logs -f nef
docker compose logs -f n3iwf
docker compose logs -f tngf

# Simulators
docker compose logs -f ueransim
docker compose logs -f n3iwue
```

### Common Issues

#### 1. CHF Not Starting
**Symptom:** CHF container exits with `Error: Diameter bind failed`

**Cause:** Port 3868 or 3869 already in use

**Fix:**
```bash
# Check port usage
sudo netstat -tulpn | grep 3868

# Stop conflicting service or change CHF config
vim config/chfcfg.yaml
# Change diameter.bindAddr to different port
```

#### 2. N3IWF IKEv2 Connection Failed
**Symptom:** Wi-Fi UE cannot connect to N3IWF, logs show `IKE_SA_INIT timeout`

**Cause:** Firewall blocking UDP 500/4500

**Fix:**
```bash
# Allow IKEv2 ports
sudo ufw allow 500/udp
sudo ufw allow 4500/udp

# Or disable firewall for testing
sudo ufw disable
```

#### 3. TNGF Cannot Reach Radius Server
**Symptom:** TNGF logs show `Radius authentication timeout`

**Cause:** Radius server not reachable or wrong shared secret

**Fix:**
```bash
# Test Radius connectivity
ping <radius-server-ip>

# Verify shared secret in tngfcfg.yaml
vim config/tngfcfg.yaml
# radius.sharedSecret must match AAA server config
```

#### 4. NEF External API Not Accessible
**Symptom:** External app gets `Connection refused` on port 8888

**Cause:** NEF external API port not exposed in Docker

**Fix:**
```yaml
# Edit docker-compose.yaml
services:
  nef:
    ports:
      - "8888:8888"  # Add this line
```

```bash
# Restart NEF
docker compose restart nef
```

#### 5. CHF CDR Not Received by CGF
**Symptom:** CHF logs show `FTP upload failed` or `Diameter peer not responding`

**Cause:** WebUI FTP server not running or wrong IP

**Fix:**
```bash
# Check WebUI FTP status
docker compose logs webui | grep FTP

# Verify CHF config
vim config/chfcfg.yaml
# cgf.ftpServer must be WebUI container IP:2121
```

#### 6. PCF Policy Not Applied
**Symptom:** UE gets default QoS even though PCF has custom policy

**Cause:** SMF not querying PCF (PCF disabled in smfcfg.yaml)

**Fix:**
```yaml
# Edit config/smfcfg.yaml
services:
  - serviceName: npcf-smpolicycontrol
    suppFeat: "0"  # Enable PCF SM policy
```

```bash
# Restart SMF
docker compose restart smf
```

### Performance Tuning (All Components)

#### High Load Scenario (1000+ UEs)

**MongoDB:**
```yaml
# docker-compose.yaml
services:
  mongodb:
    command: mongod --wiredTigerCacheSizeGB 2 --maxConns 5000
```

**AMF:**
```yaml
# config/amfcfg.yaml
configuration:
  maxNumOfRegistrations: 10000
  maxNumOfSessions: 10000
  t3512: 3600  # Increase registration timer
```

**SMF:**
```yaml
# config/smfcfg.yaml
configuration:
  maxNumOfPDUSessions: 10000
  t3591: 10  # Reduce PDU session setup timeout
```

**UPF:**
```bash
# Increase kernel limits on host
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.wmem_max=26214400
sudo sysctl -w net.ipv4.ip_forward=1

# Add to UPF container
docker compose exec upf bash -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
```

#### Monitor Resource Usage

```bash
# Real-time stats
docker stats

# Expected output example:
# CONTAINER     CPU %    MEM USAGE / LIMIT    MEM %
# upf           25.2%    180MB / 8GB          2.25%
# smf           8.5%     95MB / 8GB           1.19%
# amf           5.3%     72MB / 8GB           0.90%
# mongodb       12.1%    450MB / 8GB          5.63%
```

---

## Summary

This document covered the **complete 5G SA network** with all 16+ components:

1. **Mandatory Core (10):** MongoDB, NRF, AMF, AUSF, UDM, UDR, SMF, UPF, NSSF, PCF
2. **Recommended (1):** WebUI
3. **Optional - Charging & Exposure (2):** CHF, NEF
4. **Optional - Non-3GPP Access (2):** N3IWF, TNGF
5. **Simulators (2):** UERANSIM, N3IWUE

**Key Flows Explained:**
- Complete 3GPP registration and PDU session (with NSSF, PCF, CHF)
- Non-3GPP access via N3IWF (IPSec tunnel for Wi-Fi UEs)
- Trusted non-3GPP via TNGF (corporate Wi-Fi)
- Charging and billing via CHF (usage tracking, CDR generation)
- External API access via NEF (PFD management, traffic influence)

**Total Deployment Time:** ~2-3 minutes to start all containers

**Next Steps:**
- For mandatory-only deployment, see: `03-MANDATORY.md`
- For UPF deep dive, see: `04-UPF.md`
- For troubleshooting, see: `07-TROUBLESHOOTING.md`
