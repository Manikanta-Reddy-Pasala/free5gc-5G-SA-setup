# Recommended Components - Enhanced 5G Core

> **Update (based on live testing)**: NSSF and PCF, while classified as "optional" by 3GPP TS 23.501, are **mandatory in free5GC v4.2.0**. Without PCF, registration fails. Without NSSF, PDU sessions fail. They are included in `docker-compose-minimal.yaml` as part of the 10 mandatory containers. See [04-MANDATORY-COMPONENTS.md](04-MANDATORY-COMPONENTS.md) for details.
>
> This document covers **WebUI** as the recommended addition beyond the mandatory 10, plus detailed information about NSSF and PCF capabilities for those who want to understand what these mandatory components actually do.

## Table of Contents

- [Overview](#overview)
- [NSSF and PCF - Mandatory in free5GC v4.2.0](#nssf-and-pcf---mandatory-in-free5gc-v420)
  - [NSSF - Network Slice Selection Function](#nssf---network-slice-selection-function)
  - [PCF - Policy Control Function](#pcf---policy-control-function)
- [WebUI - The Recommended Addition](#webui---the-recommended-addition)
  - [WebUI - Web Console](#webui---web-console)
- [How to Run Recommended Deployment](#how-to-run-recommended-deployment)
- [Enhanced UE-to-Core Flow](#enhanced-ue-to-core-flow)
- [Comparison Table](#comparison-table)
- [Architecture Diagram](#architecture-diagram)
- [Configuration Details](#configuration-details)
- [When You Need These Components](#when-you-need-these-components)

## Overview

Beyond the 10 mandatory containers, this document covers:

1. **Intelligent Slice Selection** (NSSF) - Already mandatory, but explained in depth here
2. **Dynamic Policy Control** (PCF) - Already mandatory, but explained in depth here
3. **Visual Management** (WebUI) - The one truly recommended addition for easier subscriber management

**Quick Decision Guide:**
- Running the mandatory 10 containers? Add **WebUI** for easy subscriber management.
- Managing more than 5 subscribers? Definitely add WebUI.
- Comfortable with MongoDB shell or WebUI API? WebUI is optional.
- Production deployment? Add WebUI plus CHF/NEF (see [06-ALL-COMPONENTS.md](06-ALL-COMPONENTS.md)).

## NSSF and PCF - Mandatory in free5GC v4.2.0

While these are documented here for deep understanding of their capabilities, **both are required** and included in the mandatory deployment.

### NSSF - Network Slice Selection Function

**Container:** `free5gc/nssf:v4.2.0`
**Config File:** `config/nssfcfg.yaml`
**Port:** 8000 (SBI), registered with NRF at `http://nssf:8000`

#### What It Does

When a UE registers with the network, it requests specific network slices (identified by S-NSSAI values like "SST=1, SD=010203"). The AMF needs to decide:
- Which slices are allowed for this UE?
- Which AMF should handle this slice?
- Which NRF instance serves this slice?

**Without NSSF:**
- AMF uses its own built-in slice selection logic
- AMF checks its `supportedTAList.snssaiList` configuration
- Works fine for simple single-slice deployments
- Cannot route UEs to different AMF sets based on slice

**With NSSF:**
- Centralized slice selection database
- Maps slices to AMF sets and NRF instances
- Supports multiple Network Slice Instances (NSI)
- Enables complex slice routing and AMF set selection

#### Configuration Highlights

The NSSF configuration defines 7 network slice instances:

```yaml
nsiList:
  - nsiInformationList:
      - nrfId: http://nrf:8000/nnrf-nfm/v1/nf-instances
        nsiId: 10
    snssai:
      sst: 1
      sd: "010203"

  - nsiInformationList:
      - nrfId: http://nrf:8000/nnrf-nfm/v1/nf-instances
        nsiId: 11
    snssai:
      sst: 1
      sd: "112233"

  - nsiInformationList:
      - nrfId: http://nrf:8000/nnrf-nfm/v1/nf-instances
        nsiId: 22
    snssai:
      sst: 1
```

**AMF Set Configuration:**

```yaml
amfSetList:
  - amfSetId: 1
    amfList:
      - ffa2e8d7-3275-49c7-8631-6af1df1d9d26  # AMF 1
      - 0e8831c3-6286-4689-ab27-1e2161e15cb1  # AMF 2
      - a1fba9ba-2e39-4e22-9c74-f749da571d0d  # AMF 3
    nrfAmfSet: http://nrf:8000/nnrf-nfm/v1/nf-instances
    supportedNssaiAvailabilityData:
      - tai:
          plmnId:
            mcc: "208"
            mnc: "93"
          tac: "000001"
        supportedSnssaiList:
          - sst: 1
            sd: "010203"
          - sst: 1
            sd: "112233"
```

**What This Means:**
- 7 different slice types are supported (NSI IDs 10-23)
- 3 AMFs work together as "AMF Set 1"
- Each slice is mapped to specific NRF instances
- Tracking Area Code (TAC) 000001 supports slices SST=1/SD=010203 and SST=1/SD=112233

#### When You Need NSSF

**Use Cases:**
1. Multiple network slices with different NRF instances
2. AMF set-based routing (load balancing across multiple AMFs)
3. Slice isolation requirements (enterprise vs. consumer traffic)
4. Different service levels per slice (eMBB, URLLC, mMTC)
5. Multi-tenancy deployments

**Skip NSSF If:**
- Single slice deployment
- Only one AMF instance
- Simple test/lab environment
- No slice-specific routing needed

### PCF - Policy Control Function

**Container:** `free5gc/pcf:v4.2.0`
**Config File:** `config/pcfcfg.yaml`
**Port:** 8000 (SBI), registered with NRF at `http://pcf:8000`

#### What It Does

PCF is the policy brain of the 5G core. It makes real-time decisions about:
- **QoS:** What quality of service should this session get?
- **Bandwidth:** How much upload/download speed is allowed?
- **Charging:** How should this session be billed?
- **Traffic Steering:** Which route should this traffic take?

**Without PCF:**
- SMF uses default QoS from subscriber data (typically 5QI=9, best effort)
- No dynamic bandwidth control
- Fixed AMBR (Aggregate Maximum Bit Rate) only
- No usage monitoring or policy enforcement

**With PCF:**
- Per-session QoS policies
- Dynamic bandwidth limits based on user profile
- PCC (Policy and Charging Control) rules
- Usage monitoring triggers (alert when 80% of quota used)
- Time-of-day policies (slower speeds during peak hours)
- Application-based QoS (video streaming gets higher priority)

#### Service Interfaces

PCF exposes 6 SBI services:

1. **Npcf_AMPolicyControl** - Access and Mobility policies (UE registration, idle mode)
2. **Npcf_SMPolicyControl** - Session Management policies (QoS flows, bandwidth limits)
3. **Npcf_BDTPolicyControl** - Background Data Transfer policies (scheduled downloads)
4. **Npcf_PolicyAuthorization** - Application-triggered policy requests
5. **Npcf_EventExposure** - Policy event notifications
6. **Npcf_UEPolicyControl** - UE-level policies (URSP rules)

**Most Important:** `Npcf_SMPolicyControl` - this is called by SMF during PDU session establishment.

#### How PCF Works

**Step-by-Step:**

1. UE requests PDU session through AMF
2. AMF forwards to SMF
3. **SMF queries PCF:** "I have subscriber IMSI-208930000000003 requesting DNN 'internet', slice SST=1. What policies apply?"
4. **PCF responds with SM Policy Decision:**
   - Session AMBR: 200 Mbps downlink / 100 Mbps uplink
   - Default QoS Flow: 5QI=9 (best effort)
   - PCC Rules: Allow all traffic, no filtering
   - Usage Monitoring: Trigger at 10 GB consumed
5. **SMF programs UPF** with these rules via PFCP
6. UPF enforces bandwidth limits and QoS in real-time

**Example PCF Response (JSON):**

```json
{
  "sessRules": {
    "rule-1": {
      "authSessAmbr": {
        "downlink": "200 Mbps",
        "uplink": "100 Mbps"
      }
    }
  },
  "pccRules": {
    "pcc-rule-1": {
      "pccRuleId": "rule-default",
      "flowInfos": [
        {
          "flowDescription": "permit out ip from any to assigned"
        }
      ],
      "precedence": 10,
      "refQosData": ["qos-data-1"]
    }
  },
  "qosDecs": {
    "qos-data-1": {
      "qosId": "qos-data-1",
      "5qi": 9,
      "maxbrUl": "100 Mbps",
      "maxbrDl": "200 Mbps"
    }
  }
}
```

#### When You Need PCF

**Use Cases:**
1. Different QoS per subscriber tier (Gold/Silver/Bronze)
2. Bandwidth management per user or session
3. Application-aware QoS (VoIP gets priority over file downloads)
4. Usage-based billing (track data consumption)
5. Time/location-based policies (slower speeds in congested areas)
6. Enterprise SLA enforcement

**Skip PCF If:**
- All users get same QoS
- No bandwidth limits needed
- Simple best-effort internet access
- Test/lab without policy requirements

## WebUI - The Recommended Addition

### WebUI - Web Console

**Container:** `free5gc/webui:v4.2.0`
**Config File:** `config/webuicfg.yaml`
**Ports:**
- 5000 (HTTP web interface)
- 2121 (Billing/CGF service)
- 2122 (Billing/CGF TLS service)

#### What It Does

WebUI is a browser-based admin panel for managing your 5G core network. Instead of writing MongoDB commands or curl API calls, you get visual forms and tables.

**Without WebUI:**
- Add subscriber via MongoDB shell:
  ```javascript
  db.subscribers.insertOne({
    "ueId": "imsi-208930000000003",
    "plmnId": "20893",
    "AuthenticationSubscription": {
      "authenticationMethod": "5G_AKA",
      "permanentKey": {
        "permanentKeyValue": "8baf473f2f8fd09487cccbd7097c6862"
      },
      "sequenceNumber": "16f3b3f70fc2",
      "authenticationManagementField": "8000",
      "milenage": {
        "op": {
          "opValue": "8e27b6af0e692e750f32667a3b14605d"
        }
      }
    },
    "AccessAndMobilitySubscriptionData": {
      "gpsis": ["msisdn-0900000000"],
      "subscribedUeAmbr": {
        "downlink": "1 Gbps",
        "uplink": "1 Gbps"
      },
      "nssai": {
        "defaultSingleNssais": [
          {"sst": 1, "sd": "010203"}
        ]
      }
    },
    "SessionManagementSubscriptionData": [{
      "singleNssai": {"sst": 1, "sd": "010203"},
      "dnnConfigurations": {
        "internet": {
          "sscModes": {"defaultSscMode": "SSC_MODE_1"},
          "pduSessionTypes": {"defaultSessionType": "IPV4"},
          "sessionAmbr": {
            "downlink": "1 Gbps",
            "uplink": "1 Gbps"
          },
          "5gQosProfile": {
            "5qi": 9,
            "arp": {
              "priorityLevel": 8
            }
          }
        }
      }
    }],
    "SmfSelectionSubscriptionData": {
      "subscribedSnssaiInfos": {
        "01010203": {
          "dnnInfos": [{
            "dnn": "internet"
          }]
        }
      }
    }
  })
  ```

**With WebUI:**
1. Open browser: `http://<server-ip>:5000`
2. Login: username `admin`, password `free5gc`
3. Click "Subscribers" → "Create"
4. Fill form:
   - IMSI: 208930000000003
   - K (Permanent Key): 8baf473f2f8fd09487cccbd7097c6862
   - OPc: 8e27b6af0e692e750f32667a3b14605d
   - AMBR: 1 Gbps down / 1 Gbps up
   - Slice: SST=1, SD=010203
   - DNN: internet
5. Click "Create"

**That's it.** The WebUI generates the full MongoDB document automatically.

#### Features

**Subscriber Management:**
- Create/Read/Update/Delete subscribers
- Assign slices and DNNs visually
- Set QoS profiles with dropdown menus
- Copy/paste security keys (K, OPc)
- Bulk import via CSV (future feature)

**Monitoring:**
- View registered UEs
- Active PDU sessions
- Subscriber status (online/offline)

**Billing Integration:**
- CGF (Charging Gateway Function) on ports 2121/2122
- Works with CHF (Charging Function) if enabled
- CDR (Call Detail Record) export

**User Roles:**
- Admin: Full access
- Operator: Read-only (future feature)

#### Configuration

**webuicfg.yaml:**

```yaml
info:
  version: 1.0.2
  description: WebUI Configuration

configuration:
  mongodb:
    name: free5gc
    url: mongodb://mongodb:27017

  logger:
    enable: true
    level: info
    reportCaller: false

  managedByConfigPod:
    enabled: true

  spec:
    type: NodePort
    ports:
      - port: 5000
        nodePort: 30500
        protocol: TCP
        name: webui
```

**Key Settings:**
- MongoDB connection: Uses same database as UDR
- Logger: Info level by default (change to debug for troubleshooting)
- Port 5000: Main web interface
- NodePort 30500: Access from outside Docker network

#### When You Need WebUI

**Use Cases:**
1. Managing more than 5 subscribers
2. Non-technical operators need to add UEs
3. Frequent subscriber changes (testing different devices)
4. Visual troubleshooting (see which UEs are registered)
5. Production environments (audit trail of changes)

**Skip WebUI If:**
- Automated provisioning via API/scripts
- Static subscriber database (never changes)
- Single UE test setup
- Comfortable with MongoDB shell commands

## How to Run Recommended Deployment

### Full Stack with Recommended Components

The `docker-compose.yaml` includes all 15 containers. For a **recommended deployment**, run these 12:

**8 Mandatory:**
1. MongoDB
2. NRF
3. UDR
4. UDM
5. AUSF
6. AMF
7. SMF
8. UPF

**3 Recommended:**
9. NSSF
10. PCF
11. WebUI

**1 Test Tool:**
12. UERANSIM (gNB + UE simulator)

**Start Full Stack:**

```bash
# Start all containers
docker compose up -d

# Verify recommended components are running
docker compose ps nssf pcf webui

# Expected output:
# NAME      IMAGE                    STATUS         PORTS
# nssf      free5gc/nssf:v4.2.0     Up 2 minutes   8000/tcp
# pcf       free5gc/pcf:v4.2.0      Up 2 minutes   8000/tcp
# webui     free5gc/webui:v4.2.0    Up 2 minutes   0.0.0.0:5000->5000/tcp

# Check logs for successful NRF registration
docker compose logs nssf | grep "Register to NRF"
docker compose logs pcf | grep "Register to NRF"

# Expected:
# [INFO][NSSF][Init] Register to NRF successfully
# [INFO][PCF][Init] Register to NRF successfully
```

### Minimal Recommended Stack (No Optional Components)

If you want to skip N3IWF, TNGF, CHF, NEF, N3IWUE (5 optional components):

```bash
# Start only mandatory + recommended + UERANSIM
docker compose up -d mongodb nrf udr udm ausf amf smf upf nssf pcf webui ueransim

# Or start all, then stop optional
docker compose up -d
docker compose stop n3iwf tngf chf nef n3iwue
```

### Accessing WebUI

**Browser:**
```
http://<server-ip>:5000
```

**Default Credentials:**
- Username: `admin`
- Password: `free5gc`

**If running on remote server:**
```bash
# SSH tunnel from your laptop
ssh -L 5000:localhost:5000 user@server-ip

# Then open browser to:
http://localhost:5000
```

**First Steps in WebUI:**
1. Login with admin/free5gc
2. Navigate to "SUBSCRIBERS" menu
3. Click "CREATE" button
4. Fill in subscriber details (see example in WebUI section)
5. Click "CREATE" to save

## Enhanced UE-to-Core Flow

This section shows **ONLY the differences** when NSSF and PCF are added. See [04-MANDATORY-COMPONENTS.md](04-MANDATORY-COMPONENTS.md) for the base flow.

### Phase 3: Registration - NSSF Addition

**Original Flow (without NSSF):**
```
UE → gNB → AMF (extracts SUPI from SUCI) → AUSF (auth) → UDM (get profile)
AMF checks its own supportedTAList.snssaiList config → Registers UE
```

**Enhanced Flow (with NSSF):**
```
UE → gNB → AMF (extracts SUPI from SUCI) → AUSF (auth) → UDM (get profile)
                ↓
AMF → NSSF (Nnssf_NSSelection) - "UE wants SST=1/SD=010203, which AMF/slices allowed?"
       ↓
NSSF checks NSI database (7 slice instances)
NSSF checks AMF set configuration
NSSF returns: {allowedSnssais: [SST=1/SD=010203], targetAmfSet: 1, nrfUri: http://nrf:8000}
                ↓
AMF registers UE with NSSF-approved slices
```

**What Changed:**
1. **Before AMF registration**, AMF now calls NSSF
2. **NSSF request includes:**
   - Requested S-NSSAIs from UE (e.g., SST=1, SD=010203)
   - TAI (Tracking Area Identity): MCC=208, MNC=93, TAC=000001
   - PLMN ID
   - Optional: UE's home network (for roaming)

3. **NSSF response includes:**
   - **Allowed S-NSSAIs:** Filtered list of slices UE can use
   - **Target AMF Set:** If UE should be served by different AMF
   - **NRF URI:** Which NRF instance serves this slice
   - **NSI ID:** Network Slice Instance identifier

4. **AMF decision:**
   - If `targetAmfSet` is different from current AMF's set → Redirect UE to other AMF
   - If `allowedSnssais` is empty → Reject registration
   - Otherwise → Proceed with allowed slices only

**Example NSSF Query/Response:**

**Request (AMF → NSSF):**
```http
GET /nnssf-nsselection/v1/network-slice-information?
  nf-type=AMF&
  nf-id=ffa2e8d7-3275-49c7-8631-6af1df1d9d26&
  slice-info-request-for-registration=
    {
      "requestedNssai": [
        {"sst": 1, "sd": "010203"}
      ],
      "mappingOfNssai": [],
      "subscribedNssai": [
        {"sst": 1, "sd": "010203"},
        {"sst": 1, "sd": "112233"}
      ],
      "tai": {
        "plmnId": {"mcc": "208", "mnc": "93"},
        "tac": "000001"
      }
    }
```

**Response (NSSF → AMF):**
```json
{
  "allowedNssaiList": [
    {
      "allowedSnssaiList": [
        {
          "allowedSnssai": {"sst": 1, "sd": "010203"},
          "nsiInformationList": [
            {
              "nrfId": "http://nrf:8000/nnrf-nfm/v1/nf-instances",
              "nsiId": "10"
            }
          ],
          "mappedHomeSnssai": {"sst": 1, "sd": "010203"}
        }
      ],
      "accessType": "3GPP_ACCESS"
    }
  ],
  "targetAmfSet": "1",
  "candidateAmfList": [
    "ffa2e8d7-3275-49c7-8631-6af1df1d9d26"
  ]
}
```

**Impact:**
- **Without NSSF:** AMF allows all slices in its config (potential security issue)
- **With NSSF:** Centralized slice policy, can deny slices per tracking area

### Phase 4: PDU Session - PCF Addition

**Original Flow (without PCF):**
```
UE → gNB → AMF → SMF (selects UPF)
SMF → UDM (get session subscription) → Programs UPF with default QoS (5QI=9)
```

**Enhanced Flow (with PCF):**
```
UE → gNB → AMF → SMF (selects UPF)
SMF → UDM (get session subscription)
       ↓
SMF → PCF (Npcf_SMPolicyControl_Create) - "Subscriber IMSI-X wants DNN 'internet', what policies?"
       ↓
PCF checks policy database (MongoDB policyData collection)
PCF checks subscriber tier (Gold/Silver/Bronze)
PCF returns SM Policy Decision:
  - Session AMBR: 200 Mbps down / 100 Mbps up
  - Default QoS: 5QI=9 (best effort)
  - PCC Rules: [rule-1: permit all, priority 10]
  - Usage Monitoring: Trigger at 10 GB volume
       ↓
SMF programs UPF via PFCP Session Establishment:
  - Creates FAR (Forwarding Action Rule) with QoS enforcement
  - Creates QER (QoS Enforcement Rule) with AMBR limits
  - Creates URR (Usage Reporting Rule) for 10 GB trigger
```

**What Changed:**
1. **After UDM query**, SMF now calls PCF before programming UPF
2. **PCF request includes:**
   - Subscriber identifier (SUPI/GPSI)
   - DNN (Data Network Name, e.g., "internet")
   - S-NSSAI (network slice)
   - PDU session type (IPv4/IPv6/Ethernet)
   - UE location (TAI, cell ID)
   - RAT type (NR = 5G New Radio)

3. **PCF response includes:**
   - **Session Rules:** AMBR (bandwidth limits), session timeout
   - **PCC Rules:** Traffic filters, QoS parameters, charging keys
   - **QoS Decisions:** 5QI, ARP (Allocation Retention Priority), GFBR/MFBR
   - **Usage Monitoring:** Volume/time thresholds, reporting triggers
   - **Traffic Steering:** Route certain apps through specific UPF

4. **SMF enforcement:**
   - Converts PCC rules to PFCP PDRs (Packet Detection Rules)
   - Converts QoS decisions to QERs (QoS Enforcement Rules)
   - Converts usage monitoring to URRs (Usage Reporting Rules)
   - UPF enforces these in real-time packet processing

**Example PCF Query/Response:**

**Request (SMF → PCF):**
```http
POST /npcf-smpolicycontrol/v1/sm-policies
Content-Type: application/json

{
  "supi": "imsi-208930000000003",
  "pduSessionId": 1,
  "dnn": "internet",
  "snssai": {"sst": 1, "sd": "010203"},
  "pduSessionType": "IPV4",
  "ratType": "NR",
  "servingNetwork": {
    "mcc": "208",
    "mnc": "93"
  },
  "ueLocation": {
    "nrLocation": {
      "tai": {
        "plmnId": {"mcc": "208", "mnc": "93"},
        "tac": "000001"
      },
      "ncgi": {
        "plmnId": {"mcc": "208", "mnc": "93"},
        "nrCellId": "000000010"
      }
    }
  },
  "ipDomain": "10.60.0.0/16"
}
```

**Response (PCF → SMF):**
```json
{
  "policyCtrlReqTriggers": [
    "PLMN_CH",
    "RES_MO_RE",
    "AC_TY_CH"
  ],
  "pccRules": {
    "rule-default": {
      "pccRuleId": "rule-default",
      "flowInfos": [
        {
          "flowDescription": "permit out ip from any to assigned",
          "flowDirection": "DOWNLINK"
        },
        {
          "flowDescription": "permit in ip from any to assigned",
          "flowDirection": "UPLINK"
        }
      ],
      "precedence": 10,
      "refQosData": ["qos-data-1"],
      "refChgData": ["chg-data-1"]
    }
  },
  "qosDecs": {
    "qos-data-1": {
      "qosId": "qos-data-1",
      "5qi": 9,
      "maxbrUl": "100 Mbps",
      "maxbrDl": "200 Mbps",
      "arp": {
        "priorityLevel": 8,
        "preemptCap": "NOT_PREEMPT",
        "preemptVuln": "NOT_PREEMPTABLE"
      }
    }
  },
  "sessRules": {
    "session-rule-1": {
      "authSessAmbr": {
        "uplink": "100 Mbps",
        "downlink": "200 Mbps"
      },
      "authDefQos": {
        "5qi": 9,
        "arp": {
          "priorityLevel": 8
        }
      }
    }
  },
  "umDecs": {
    "um-data-1": {
      "umId": "um-data-1",
      "volumeThreshold": 10000000000,
      "volumeThresholdUplink": 5000000000,
      "volumeThresholdDownlink": 5000000000
    }
  }
}
```

**What SMF Does with This:**

```
PCC Rule "rule-default" → PDR (Packet Detection Rule):
  - Match: All IP traffic (any source/dest)
  - Action: Forward to QER-1

QoS Decision "qos-data-1" → QER (QoS Enforcement Rule):
  - 5QI: 9 (non-GBR, best effort)
  - Max Bitrate UL: 100 Mbps
  - Max Bitrate DL: 200 Mbps
  - ARP Priority: 8 (medium)

Usage Monitoring "um-data-1" → URR (Usage Reporting Rule):
  - Volume Threshold: 10 GB total
  - Report to SMF when threshold reached
  - SMF then queries PCF for policy update (e.g., throttle speed)
```

**Impact:**
- **Without PCF:** All sessions get 5QI=9, same bandwidth (1 Gbps from subscription)
- **With PCF:** Per-session control, can give Gold tier 500 Mbps, Silver 100 Mbps, Bronze 10 Mbps

### Subscriber Management - WebUI Addition

**Original Method (MongoDB Shell):**

```bash
# SSH to server
ssh user@server

# Connect to MongoDB
docker compose exec mongodb mongosh mongodb://localhost:27017

# Switch to free5gc database
use free5gc

# Insert subscriber (100+ lines of JSON)
db.subscriptionData.provisionedData.amData.insertOne({...})
db.subscriptionData.provisionedData.smData.insertOne({...})
db.subscriptionData.authenticationData.authenticationSubscription.insertOne({...})

# Verify
db.subscriptionData.provisionedData.amData.findOne({"ueId": "imsi-208930000000003"})
```

**Enhanced Method (WebUI):**

```bash
# Open browser
http://<server-ip>:5000

# Login: admin / free5gc
# Click: SUBSCRIBERS → CREATE
# Fill form (takes 2 minutes):
  IMSI: 208930000000003
  K: 8baf473f2f8fd09487cccbd7097c6862
  OPc: 8e27b6af0e692e750f32667a3b14605d
  SQN: 16f3b3f70fc2
  AMF: 8000
  AMBR DL: 1 Gbps
  AMBR UL: 1 Gbps
  Default Slice: SST=1, SD=010203
  DNN: internet
  Session AMBR DL: 1 Gbps
  Session AMBR UL: 1 Gbps
  Default 5QI: 9

# Click: CREATE
# Done. Subscriber appears in table.
```

**What Changed:**
- **Time:** 10 minutes (MongoDB shell) → 2 minutes (WebUI)
- **Errors:** High (typos in JSON) → Low (form validation)
- **Skill:** Requires MongoDB knowledge → Basic web form skills
- **Verification:** Manual query → Visual table with green checkmark

**WebUI Features Beyond Basic CRUD:**

1. **Bulk Operations:**
   - Export all subscribers to CSV
   - Import from CSV (future feature)

2. **Search/Filter:**
   - Find subscriber by IMSI, MSISDN, or IP address
   - Filter by slice or DNN

3. **Status Monitoring:**
   - Green dot: UE is registered
   - Gray dot: UE is offline
   - Red dot: Authentication failed

4. **Audit Log:**
   - Who created/modified subscriber
   - When changes were made
   - Change history (future feature)

## Comparison Table

| Feature | Without NSSF/PCF/WebUI | With NSSF/PCF/WebUI |
|---------|------------------------|---------------------|
| **Slice Selection** | AMF built-in (checks own config) | NSSF with NSI mapping (centralized database) |
| **Slice Routing** | Single AMF only | AMF set selection, load balancing across 3 AMFs |
| **QoS Policy** | Default from subscription (5QI=9) | Dynamic per-session policies from PCF |
| **Bandwidth Control** | Fixed AMBR (e.g., 1 Gbps for all) | Per-session PCC rules (Gold: 500 Mbps, Silver: 100 Mbps) |
| **Subscriber Management** | MongoDB shell or curl API | Browser UI with forms and tables |
| **Time to Add UE** | 10 minutes (write JSON manually) | 2 minutes (fill form) |
| **Error Rate** | High (typos, missing fields) | Low (form validation, dropdown menus) |
| **Multi-AMF Support** | Not supported | NSSF routes UEs to correct AMF set |
| **Usage Monitoring** | None | PCF usage rules trigger at volume/time thresholds |
| **Traffic Steering** | Basic (all traffic to same UPF) | Advanced (route video to UPF-1, browsing to UPF-2) |
| **Billing Integration** | None | CGF via WebUI ports 2121/2122, CDR export |
| **Policy Updates** | Requires UE re-registration | PCF can update live sessions (trigger policy re-evaluation) |
| **Slice Isolation** | Logical only (same AMF/SMF) | Physical (different NRF/AMF per slice) |
| **Scalability** | Limited (single AMF bottleneck) | High (NSSF distributes load to AMF set) |

## Architecture Diagram

### Complete Data Flow with NSSF and PCF

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         UE REGISTRATION FLOW (WITH NSSF)                    │
└─────────────────────────────────────────────────────────────────────────────┘

   UE (IMSI-208930000000003)
    │
    │ NAS: Registration Request (SUCI, Requested NSSAI: [SST=1/SD=010203])
    ▼
   gNB (NGAP)
    │
    │ N2: Registration Request (SUCI, TAI, Requested NSSAI)
    ▼
┌──────┐
│ AMF  │  Step 1: Decrypt SUCI → SUPI via UDM
└──┬───┘
   │ Nudm_UECM_Get (SUCI)
   ▼
┌──────┐
│ UDM  │ Returns SUPI: imsi-208930000000003
└──────┘
   │
   │ Step 2: Authenticate via AUSF (5G AKA)
   ▼
┌──────┐    ┌──────┐
│ AUSF │───→│ UDM  │ Get K, OPc, SQN → Generate AV (RAND, AUTN, XRES*)
└──────┘    └──────┘
   │
   │ Returns AV to AMF
   ▼
┌──────┐
│ AMF  │  Step 3: Query NSSF for Slice Selection *** NEW ***
└──┬───┘
   │
   │ Nnssf_NSSelection_Get
   │  - Requested NSSAI: [SST=1/SD=010203]
   │  - TAI: MCC=208, MNC=93, TAC=000001
   │  - Home PLMN: 20893
   ▼
┌────────┐
│  NSSF  │  - Checks NSI database (7 slice instances)
└────┬───┘  - Checks AMF set configuration (AMF Set 1 with 3 AMFs)
     │      - Verifies slice is supported in this tracking area
     │      - Returns:
     │        • Allowed NSSAI: [SST=1/SD=010203]
     │        • Target AMF Set: 1 (current AMF is in this set, no redirect needed)
     │        • NRF URI: http://nrf:8000
     │        • NSI ID: 10
     │
     │ Response: {allowedNssaiList, targetAmfSet, candidateAmfList, nrfUri}
     ▼
┌──────┐
│ AMF  │  Step 4: Get Subscription Data from UDM
└──┬───┘
   │ Nudm_SDM_Get (SUPI, PLMN, allowed NSSAI from NSSF)
   ▼
┌──────┐
│ UDM  │ Returns: Access & Mobility subscription (AMBR, subscribed slices)
└──────┘
   │
   │ Step 5: AMF registers UE with NSSF-approved slices only
   ▼
┌──────┐
│ AMF  │ Registration Complete (allowed NSSAI, TAI list, 5G-GUTI)
└──┬───┘
   │ NAS: Registration Accept
   ▼
   gNB → UE (Registration Success)


┌─────────────────────────────────────────────────────────────────────────────┐
│                      PDU SESSION ESTABLISHMENT (WITH PCF)                   │
└─────────────────────────────────────────────────────────────────────────────┘

   UE
    │ NAS: PDU Session Establishment Request (SST=1/SD=010203, DNN="internet")
    ▼
   gNB (NGAP)
    │ N2: PDU Session Resource Setup Request
    ▼
┌──────┐
│ AMF  │ Forwards to SMF (selected via NRF discovery)
└──┬───┘
   │ Nsmf_PDUSession_CreateSMContext
   ▼
┌──────┐
│ SMF  │ Step 1: Get Session Subscription from UDM
└──┬───┘
   │ Nudm_SDM_Get (SUPI, DNN, S-NSSAI)
   ▼
┌──────┐
│ UDM  │ Returns: SM subscription (allowed DNNs, default QoS, session AMBR)
└──────┘
   │ Example: sessionAmbr: {downlink: "1 Gbps", uplink: "1 Gbps"}, 5qi: 9
   │
   │ Step 2: Query PCF for Session Management Policy *** NEW ***
   ▼
┌──────┐
│ SMF  │ Npcf_SMPolicyControl_Create
└──┬───┘
   │  POST /npcf-smpolicycontrol/v1/sm-policies
   │  Body: {
   │    supi: "imsi-208930000000003",
   │    pduSessionId: 1,
   │    dnn: "internet",
   │    snssai: {sst: 1, sd: "010203"},
   │    pduSessionType: "IPV4",
   │    ipDomain: "10.60.0.0/16"
   │  }
   ▼
┌─────┐
│ PCF │  - Checks policy database (MongoDB: policyData collection)
└──┬──┘  - Checks subscriber tier (query UDR or internal DB)
   │     - Applies policies:
   │       • If tier=Gold: AMBR 500 Mbps, 5QI=9
   │       • If tier=Silver: AMBR 100 Mbps, 5QI=9
   │       • If tier=Bronze: AMBR 10 Mbps, 5QI=9
   │     - Creates PCC rules:
   │       • Rule 1: Permit all IP, priority 10, QoS ref qos-data-1
   │     - Creates usage monitoring:
   │       • Volume threshold: 10 GB
   │
   │ Response: {
   │   sessRules: {authSessAmbr: {downlink: "200 Mbps", uplink: "100 Mbps"}},
   │   pccRules: {rule-default: {flowInfos: [...], refQosData: ["qos-data-1"]}},
   │   qosDecs: {qos-data-1: {5qi: 9, maxbrDl: "200 Mbps", maxbrUl: "100 Mbps"}},
   │   umDecs: {um-data-1: {volumeThreshold: 10000000000}}
   │ }
   ▼
┌──────┐
│ SMF  │ Step 3: Select UPF via NRF, establish PFCP session
└──┬───┘
   │ Convert PCF policies to PFCP rules:
   │  - PCC Rule → PDR (Packet Detection Rule): Match all IP traffic
   │  - QoS Decision → QER (QoS Enforcement Rule): Enforce 200 Mbps DL / 100 Mbps UL
   │  - Usage Monitoring → URR (Usage Reporting Rule): Report at 10 GB
   │
   │ PFCP Session Establishment Request
   ▼
┌─────┐
│ UPF │  Creates:
└──┬──┘  - PDR-1: Match all packets from UE IP (10.60.0.1)
   │     - FAR-1: Forward to DN (internet), apply QER-1
   │     - QER-1: Rate limit to 200 Mbps DL / 100 Mbps UL
   │     - URR-1: Count volume, report at 10 GB
   │
   │ PFCP Session Establishment Response (F-TEID for N3 tunnel)
   ▼
┌──────┐
│ SMF  │ Step 4: Respond to AMF with N2 SM Info (QoS profile, tunnel endpoint)
└──┬───┘
   │ Nsmf_PDUSession_CreateSMContext Response
   ▼
┌──────┐
│ AMF  │ N2: PDU Session Resource Setup Response
└──┬───┘
   │ Includes: UPF IP (192.168.2.6), GTP-U TEID, QoS Flow (5QI=9, AMBR 200/100 Mbps)
   ▼
   gNB
    │ Configures GTP-U tunnel to UPF
    │ NAS: PDU Session Establishment Accept
    ▼
   UE (Session Active, IP: 10.60.0.1)
    │
    │ User traffic (HTTP, ping, etc.)
    ▼
   gNB (GTP-U tunnel to UPF)
    ▼
┌─────┐
│ UPF │  *** Enforces PCF policies in real-time ***
└──┬──┘  - Every packet checked against PDR-1
   │     - QER-1 limits speed to 200 Mbps DL / 100 Mbps UL
   │     - URR-1 counts bytes, when 10 GB reached:
   │       → UPF sends Usage Report to SMF
   │       → SMF queries PCF: "User hit 10 GB, what now?"
   │       → PCF responds: "Throttle to 5 Mbps" or "Continue" or "Block"
   │       → SMF updates QER-1 via PFCP Session Modification
   │       → UPF enforces new speed limit
   │
   │ Packets to internet (NAT: 10.60.0.1 → public IP)
   ▼
  Internet (Data Network)


┌─────────────────────────────────────────────────────────────────────────────┐
│                   SUBSCRIBER MANAGEMENT (WITH WEBUI)                        │
└─────────────────────────────────────────────────────────────────────────────┘

 Operator's Laptop
    │ Browser: http://<server-ip>:5000
    ▼
┌─────────┐
│  WebUI  │  Login: admin / free5gc
└────┬────┘
     │ Dashboard → SUBSCRIBERS → CREATE
     │
     │ HTTP POST /api/subscriber
     │ Body: {
     │   plmnID: "20893",
     │   ueId: "imsi-208930000000003",
     │   AuthenticationSubscription: {
     │     authenticationMethod: "5G_AKA",
     │     permanentKey: "8baf473f2f8fd09487cccbd7097c6862",
     │     opc: "8e27b6af0e692e750f32667a3b14605d",
     │     sequenceNumber: "16f3b3f70fc2"
     │   },
     │   AccessAndMobilitySubscriptionData: {
     │     subscribedUeAmbr: {downlink: "1 Gbps", uplink: "1 Gbps"},
     │     nssai: {defaultSingleNssais: [{sst: 1, sd: "010203"}]}
     │   },
     │   SessionManagementSubscriptionData: {
     │     singleNssai: {sst: 1, sd: "010203"},
     │     dnnConfigurations: {
     │       internet: {
     │         pduSessionTypes: {defaultSessionType: "IPV4"},
     │         sessionAmbr: {downlink: "1 Gbps", uplink: "1 Gbps"},
     │         5gQosProfile: {5qi: 9}
     │       }
     │     }
     │   }
     │ }
     ▼
┌──────────┐
│ MongoDB  │  WebUI inserts 3 documents:
└──────────┘  1. subscriptionData.authenticationData.authenticationSubscription
              2. subscriptionData.provisionedData.amData
              3. subscriptionData.provisionedData.smData
     │
     │ Result: Subscriber created, appears in WebUI table with green checkmark
     ▼
 Operator sees success message: "Subscriber imsi-208930000000003 created"
```

### Service Interaction Matrix

```
┌─────────────────────────────────────────────────────────────────────────┐
│              Service-to-Service Calls (With NSSF/PCF)                   │
└─────────────────────────────────────────────────────────────────────────┘

              ┌───────┬───────┬───────┬───────┬───────┬───────┬───────┐
              │  NRF  │  UDM  │ AUSF  │ NSSF  │  PCF  │  UPF  │ WebUI │
┌─────────────┼───────┼───────┼───────┼───────┼───────┼───────┼───────┤
│ AMF         │   ✓   │   ✓   │   ✓   │   ✓   │       │       │       │
│  Calls:     │ Disc  │ UECM  │ Auth  │ NSel  │       │       │       │
│             │ NFMgt │ SDM   │       │       │       │       │       │
├─────────────┼───────┼───────┼───────┼───────┼───────┼───────┼───────┤
│ SMF         │   ✓   │   ✓   │       │       │   ✓   │   ✓   │       │
│  Calls:     │ Disc  │ SDM   │       │       │ SMPol │ PFCP  │       │
│             │ NFMgt │       │       │       │       │       │       │
├─────────────┼───────┼───────┼───────┼───────┼───────┼───────┼───────┤
│ AUSF        │   ✓   │   ✓   │       │       │       │       │       │
│  Calls:     │ NFReg │ Auth  │       │       │       │       │       │
├─────────────┼───────┼───────┼───────┼───────┼───────┼───────┼───────┤
│ PCF         │   ✓   │   ✓   │       │       │       │       │       │
│  Calls:     │ NFReg │ SDM   │       │       │       │       │       │
│             │       │ (UDR) │       │       │       │       │       │
├─────────────┼───────┼───────┼───────┼───────┼───────┼───────┼───────┤
│ NSSF        │   ✓   │       │       │       │       │       │       │
│  Calls:     │ NFReg │       │       │       │       │       │       │
├─────────────┼───────┼───────┼───────┼───────┼───────┼───────┼───────┤
│ WebUI       │       │       │       │       │       │       │ Mongo │
│  Calls:     │       │       │       │       │       │       │  DB   │
└─────────────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┘

Legend:
  Disc  = Discovery (find NF instances)
  NFMgt = NF Management (heartbeats, status updates)
  NFReg = NF Registration (on startup)
  UECM  = UE Context Management
  SDM   = Subscriber Data Management
  Auth  = Authentication
  NSel  = Network Slice Selection
  SMPol = SM Policy Control
  PFCP  = Packet Forwarding Control Protocol
```

## Configuration Details

### NSSF Configuration

**File:** `config/nssfcfg.yaml`

```yaml
info:
  version: 1.0.2
  description: NSSF Configuration

configuration:
  nssfName: NSSF
  sbi:
    scheme: http
    registerIPv4: nssf
    bindingIPv4: 0.0.0.0
    port: 8000
  serviceNameList:
    - nnssf-nsselection
    - nnssf-nssaiavailability
  nrfUri: http://nrf:8000

  # Network Slice Instance database
  nsiList:
    - snssai:
        sst: 1
        sd: "010203"
      nsiInformationList:
        - nrfId: http://nrf:8000/nnrf-nfm/v1/nf-instances
          nsiId: "10"

    - snssai:
        sst: 1
        sd: "112233"
      nsiInformationList:
        - nrfId: http://nrf:8000/nnrf-nfm/v1/nf-instances
          nsiId: "11"

    - snssai:
        sst: 1
      nsiInformationList:
        - nrfId: http://nrf:8000/nnrf-nfm/v1/nf-instances
          nsiId: "22"

    - snssai:
        sst: 2
        sd: "000001"
      nsiInformationList:
        - nrfId: http://nrf:8000/nnrf-nfm/v1/nf-instances
          nsiId: "23"

  # AMF Set Configuration
  amfSetList:
    - amfSetId: "1"
      amfList:
        - ffa2e8d7-3275-49c7-8631-6af1df1d9d26
        - 0e8831c3-6286-4689-ab27-1e2161e15cb1
        - a1fba9ba-2e39-4e22-9c74-f749da571d0d
      nrfAmfSet: http://nrf:8000/nnrf-nfm/v1/nf-instances
      supportedNssaiAvailabilityData:
        - tai:
            plmnId:
              mcc: "208"
              mnc: "93"
            tac: "000001"
          supportedSnssaiList:
            - sst: 1
              sd: "010203"
            - sst: 1
              sd: "112233"
            - sst: 1
            - sst: 2

  # TA (Tracking Area) to NSSAI mapping
  taList:
    - tai:
        plmnId:
          mcc: "208"
          mnc: "93"
        tac: "000001"
      accessType: 3GPP_ACCESS
      supportedSnssaiList:
        - sst: 1
          sd: "010203"
        - sst: 1
          sd: "112233"
        - sst: 1
        - sst: 2

  logger:
    enable: true
    level: info
    reportCaller: false
```

**Key Parameters:**
- **nsiList:** Maps S-NSSAI to NSI ID and NRF instance
- **amfSetList:** Groups AMFs into sets for load balancing
- **taList:** Which slices are available in each tracking area
- **supportedNssaiAvailabilityData:** AMF set slice support per TAI

### PCF Configuration

**File:** `config/pcfcfg.yaml`

```yaml
info:
  version: 1.0.3
  description: PCF Configuration

configuration:
  pcfName: PCF
  sbi:
    scheme: http
    registerIPv4: pcf
    bindingIPv4: 0.0.0.0
    port: 8000

  serviceList:
    - serviceName: npcf-am-policy-control
    - serviceName: npcf-smpolicycontrol
      suppressNfDiscovery: true
    - serviceName: npcf-bdtpolicycontrol
    - serviceName: npcf-policyauthorization
      suppressNfDiscovery: true
    - serviceName: npcf-eventexposure
    - serviceName: npcf-ue-policy-control

  nrfUri: http://nrf:8000

  # Default QoS settings
  defaultBdtRefId: BdtPolicyId-

  logger:
    enable: true
    level: info
    reportCaller: false
```

**Key Parameters:**
- **serviceList:** 6 PCF services, some use NRF discovery, some don't
- **suppressNfDiscovery: true:** Service doesn't register with NRF (internal only)
- **defaultBdtRefId:** Reference ID for Background Data Transfer policies

**Policy Database (MongoDB):**

PCF stores policies in MongoDB collection `policyData.policyDataSubscriptions`:

```javascript
// Example policy document
{
  "_id": "imsi-208930000000003",
  "supi": "imsi-208930000000003",
  "smPolicyData": {
    "smPolicySnssaiData": {
      "01010203": {  // Key format: SST + SD (hex)
        "snssai": {
          "sst": 1,
          "sd": "010203"
        },
        "smPolicyDnnData": {
          "internet": {
            "dnn": "internet",
            "allowedServices": ["*"],
            "subscCats": ["free5gc"],
            "gbr5qi": null,
            "sessionAmbr": {
              "downlink": "200 Mbps",
              "uplink": "100 Mbps"
            },
            "3gppChargingCharacteristics": "0000"
          }
        }
      }
    }
  }
}
```

### WebUI Configuration

**File:** `config/webuicfg.yaml`

```yaml
info:
  version: 1.0.2
  description: WebUI Configuration

configuration:
  mongodb:
    name: free5gc
    url: mongodb://mongodb:27017

  logger:
    enable: true
    level: info
    reportCaller: false

  managedByConfigPod:
    enabled: true

  # Kubernetes Service spec (ignored in Docker Compose)
  spec:
    type: NodePort
    ports:
      - port: 5000
        nodePort: 30500
        protocol: TCP
        name: webui
      - port: 2121
        protocol: TCP
        name: billing
      - port: 2122
        protocol: TCP
        name: billing-tls
```

**Key Parameters:**
- **mongodb.url:** Must match MongoDB container name/IP
- **logger.level:** Change to `debug` for troubleshooting
- **ports:** 5000 (WebUI), 2121/2122 (billing/CGF)

## When You Need These Components

### NSSF Use Cases

**Need NSSF:**
1. Multiple network slices with different service requirements (eMBB, URLLC, mMTC)
2. Multiple AMF instances, need load balancing across AMF sets
3. Different NRF instances per slice (multi-tenant deployments)
4. Slice-specific routing (enterprise traffic to AMF-1, consumer to AMF-2)
5. Roaming scenarios (select home vs. visited AMF based on slice)

**Skip NSSF:**
1. Single slice deployment (e.g., only SST=1/SD=010203)
2. Single AMF instance
3. Simple test/lab with no slice routing
4. All UEs use same slice

**Example Scenario:**
- **Scenario:** IoT company deploying 5G network for smart city
  - Slice 1 (SST=1/SD=010203): Emergency services (high priority, low latency)
  - Slice 2 (SST=1/SD=112233): Traffic cameras (high bandwidth, best effort)
  - Slice 3 (SST=2/SD=000001): Sensor data (low bandwidth, massive connections)
- **NSSF Configuration:**
  - Emergency slice → AMF Set 1 (dedicated AMFs with guaranteed resources)
  - Cameras + Sensors → AMF Set 2 (shared AMFs)
  - Each slice has separate NRF for isolation
- **Result:** Emergency UEs always get priority, never compete with cameras/sensors for AMF resources

### PCF Use Cases

**Need PCF:**
1. Different QoS tiers (Gold/Silver/Bronze subscribers)
2. Bandwidth management per user (prevent one user from hogging all bandwidth)
3. Application-aware QoS (VoIP gets priority over file downloads)
4. Usage-based billing (track data consumption, throttle after quota)
5. Time-of-day policies (slower speeds 9am-5pm, full speed after hours)
6. Location-based policies (slower in congested areas, faster in rural)

**Skip PCF:**
1. All users get same QoS (e.g., best-effort internet for all)
2. No bandwidth limits needed
3. Simple test/lab without policy requirements
4. Flat-rate billing (no need to track usage)

**Example Scenario:**
- **Scenario:** Mobile operator with 3 subscriber tiers
  - Gold: $100/month, 500 Mbps, unlimited data
  - Silver: $50/month, 100 Mbps, 50 GB/month
  - Bronze: $20/month, 10 Mbps, 10 GB/month
- **PCF Configuration:**
  - MongoDB collection stores tier per subscriber
  - When Silver user establishes session:
    - PCF returns Session AMBR: 100 Mbps DL / 50 Mbps UL
    - Usage Monitoring: Trigger at 40 GB (80% of quota)
  - When 40 GB reached:
    - UPF reports to SMF
    - SMF queries PCF
    - PCF responds: "Slow down to 1 Mbps (soft cap) or block (hard cap)"
    - SMF updates UPF via PFCP
- **Result:** Users pay for what they get, no surprises

### WebUI Use Cases

**Need WebUI:**
1. More than 5 subscribers (manual MongoDB is tedious)
2. Non-technical staff need to manage subscribers
3. Frequent subscriber changes (adding new devices, testing)
4. Need to see which UEs are online/offline
5. Production environment (audit trail of changes)
6. Customer self-service portal (future feature: users can update own profile)

**Skip WebUI:**
1. Automated provisioning via API/scripts (WebUI is redundant)
2. Static subscriber database (set up once, never changes)
3. Single UE test (easier to just insert MongoDB document manually)
4. All operations are scripted (CI/CD pipeline provisions UEs)

**Example Scenario:**
- **Scenario:** Enterprise campus with 500 employees, each has company-issued phone
  - IT help desk needs to:
    - Activate new phones when employee joins
    - Deactivate when employee leaves
    - Change QoS for executives (higher priority)
    - Reset SIM credentials if compromised
  - **Without WebUI:**
    - Help desk calls IT engineer
    - Engineer SSHs to server, runs MongoDB commands
    - Takes 15 minutes per change
    - Error-prone (typos in IMSI, wrong OPc key)
  - **With WebUI:**
    - Help desk logs into WebUI
    - Searches for employee by name/IMSI
    - Clicks "Edit", changes QoS dropdown from "Standard" to "Executive"
    - Clicks "Save"
    - Takes 1 minute
  - **Result:** Help desk is self-sufficient, IT engineer is free for higher-value work

## Summary

**Quick Reference:**

| Component | Main Benefit | When to Use | When to Skip |
|-----------|--------------|-------------|--------------|
| **NSSF** | Intelligent slice routing, multi-AMF support | Multiple slices, AMF sets, enterprise deployments | Single slice, single AMF, simple test |
| **PCF** | Per-session QoS, bandwidth control, policies | Different QoS tiers, usage billing, SLA enforcement | All users same QoS, no policies needed |
| **WebUI** | Visual subscriber management, easy CRUD | More than 5 subscribers, non-technical operators | Automated provisioning, static DB, single UE |

**Recommended Deployment Sizes:**

| Deployment Size | Containers to Run |
|-----------------|-------------------|
| **Minimal Test** (1-2 UEs, basic connectivity) | 10 mandatory + UERANSIM = 11 |
| **Lab** (5-10 UEs, realistic testing) | 10 mandatory + WebUI + UERANSIM = 12 |
| **Pilot** (50+ UEs, billing) | 10 mandatory + WebUI + CHF + UERANSIM = 13 |
| **Production** (100+ UEs, SLA requirements) | All 16 containers |

**Next Steps:**
1. To add WebUI to the mandatory deployment:
   ```bash
   docker compose up -d webui
   ```
2. No configuration changes needed - WebUI connects directly to MongoDB
3. Read [06-ALL-COMPONENTS.md](06-ALL-COMPONENTS.md) for N3IWF, TNGF, CHF, NEF (truly optional features)
4. Read [07-CONSOLIDATED-DEPLOYMENT.md](07-CONSOLIDATED-DEPLOYMENT.md) for merging into fewer containers
