# Chapter 9: 5G Procedures and NF Roles - How the Network Really Works

## Table of Contents

1. [Overview: What Each NF Does](#overview-what-each-nf-does)
2. [Procedure 1: UE Registration (Attach)](#procedure-1-ue-registration-attach)
3. [Procedure 2: Authentication (5G-AKA)](#procedure-2-authentication-5g-aka)
4. [Procedure 3: UE Identification (Identity Request)](#procedure-3-ue-identification-identity-request)
5. [Procedure 4: PDU Session Establishment](#procedure-4-pdu-session-establishment)
6. [Procedure 5: Paging (Reaching Idle UEs)](#procedure-5-paging-reaching-idle-ues)
7. [Procedure 6: Silent Call / Persistent Connected Mode](#procedure-6-silent-call--persistent-connected-mode)
8. [Procedure 7: Deregistration](#procedure-7-deregistration)
9. [NF-to-Procedure Mapping Table](#nf-to-procedure-mapping-table)
10. [Verifying Procedures in free5GC Logs](#verifying-procedures-in-free5gc-logs)

---

## Overview: What Each NF Does

Before diving into procedures, here is a one-line summary of each Network Function's role in the 5G SA core:

| NF | Full Name | One-Line Role |
|----|-----------|---------------|
| **AMF** | Access and Mobility Management Function | The single entry point for all UE signaling -- handles registration, authentication orchestration, mobility, and NAS message routing. |
| **AUSF** | Authentication Server Function | Executes the 5G-AKA authentication protocol, verifying the UE's identity using challenge-response cryptography. |
| **UDM** | Unified Data Management | Computes authentication vectors from subscriber keys and manages subscription data (allowed slices, session configs). |
| **UDR** | Unified Data Repository | The database abstraction layer -- stores and retrieves subscriber profiles, auth credentials, and policy data from MongoDB. |
| **SMF** | Session Management Function | Creates, modifies, and deletes PDU sessions -- allocates IP addresses, sets up GTP tunnels, and programs UPF forwarding rules. |
| **UPF** | User Plane Function | The data router -- all user traffic (web, video, voice) flows through UPF via GTP-U tunnels between gNB and the internet. |
| **NRF** | NF Repository Function | Service registry where all NFs register at startup and discover each other dynamically (the phone directory of the core). |
| **NSSF** | Network Slice Selection Function | Selects the appropriate network slice and AMF set for a UE based on its subscription and request. |
| **PCF** | Policy Control Function | Decides QoS rules, bandwidth limits, and access policies for each session, enforced by SMF and UPF. |
| **CHF** | Charging Function | Tracks usage (data volume, duration) for billing purposes -- reports from UPF flow through SMF to CHF. |
| **NEF** | Network Exposure Function | API gateway for third-party applications to interact with the 5G core (e.g., QoS on demand, monitoring events). |
| **N3IWF** | Non-3GPP Interworking Function | Enables Wi-Fi/untrusted access devices to connect to the 5G core via IPSec tunnels. |

### How NFs Communicate

All control plane NFs communicate over the **Service-Based Interface (SBI)** using HTTP/2 on port 8000. They discover each other via NRF.

```
                    ┌─────────────────────────────────────────────────────┐
                    │            SBI Bus (HTTP/2, port 8000)               │
                    │                                                       │
                    │  NRF ── AMF ── AUSF ── UDM ── UDR                   │
                    │          │                                            │
                    │         SMF ── PCF ── CHF ── NSSF ── NEF            │
                    └─────────────────────────────────────────────────────┘
                               │                    │
                    N2 (SCTP)  │         N4 (PFCP)  │
                               │                    │
                    ┌──────┐   │              ┌─────┴────┐      N6
                    │  gNB │───┘              │   UPF    │──────────> Internet
                    └──┬───┘                  └────┬─────┘
                       │         N3 (GTP-U)        │
                       └───────────────────────────┘
```

---

## Procedure 1: UE Registration (Attach)

Registration is the first thing a UE does when it powers on or enters a new network. It is the most complex procedure, involving 6+ NFs.

### What Happens

The UE proves its identity (authentication), receives a security context, and is assigned to the appropriate network slice. After registration, the UE is `RM-REGISTERED` and can request PDU sessions (data connectivity).

### NFs Involved

| NF | Role in Registration |
|----|---------------------|
| **AMF** | Orchestrates the entire procedure -- receives the initial NAS message from gNB, coordinates auth with AUSF, slice selection with NSSF, and sends the Registration Accept |
| **AUSF** | Runs 5G-AKA: receives auth vectors from UDM, challenges the UE, and verifies the UE's response |
| **UDM** | Generates authentication vectors (RAND, AUTN, XRES*, KAUSF) from the UE's permanent key (K) and OPC |
| **UDR** | Provides the subscriber's K, OPC, SQN, and subscription data to UDM |
| **NSSF** | Determines which network slice(s) and AMF set the UE should use based on requested and subscribed S-NSSAIs |
| **NRF** | AMF discovers AUSF, UDM, NSSF via NRF service discovery |

### Step-by-Step Sequence

```
  UE                gNB              AMF            NSSF          AUSF           UDM            UDR
   │                 │                │               │              │              │              │
   │ ──RRC Setup──>  │                │               │              │              │              │
   │                 │                │               │              │              │              │
   │ Registration    │ InitialUE      │               │              │              │              │
   │ Request ──────> │ Message ─────> │               │              │              │              │
   │ (SUCI, S-NSSAI) │ (NAS PDU)     │               │              │              │              │
   │                 │                │               │              │              │              │
   │                 │                │ ── NS Select ─>│              │              │              │
   │                 │                │ <── Allowed ───│              │              │              │
   │                 │                │   S-NSSAIs     │              │              │              │
   │                 │                │               │              │              │              │
   │                 │                │ ── Nausf_UEAuth ────────────> │              │              │
   │                 │                │   (SUCI)       │              │              │              │
   │                 │                │               │              │ ── Nudm ────> │              │
   │                 │                │               │              │  (SUPI from   │ ── Nudr ──> │
   │                 │                │               │              │   SUCI)       │  (get K,    │
   │                 │                │               │              │              │   OPC, SQN) │
   │                 │                │               │              │ <── Auth ──── │ <────────── │
   │                 │                │               │              │   Vectors     │              │
   │                 │                │ <── 5G-AKA Challenge ─────── │              │              │
   │                 │                │   (RAND, AUTN) │              │              │              │
   │                 │ DL NAS         │               │              │              │              │
   │ <── Auth Req ── │ <──────────── │               │              │              │              │
   │   (RAND, AUTN)  │                │               │              │              │              │
   │                 │                │               │              │              │              │
   │ Auth Response   │ UL NAS         │               │              │              │              │
   │ (RES*) ───────> │ ─────────────> │               │              │              │              │
   │                 │                │ ── Verify RES* ────────────> │              │              │
   │                 │                │ <── Auth OK ──────────────── │              │              │
   │                 │                │               │              │              │              │
   │                 │                │ ──── NAS Security Mode ────────────────────────────────── │
   │ <── Sec Mode ── │ <──────────── │  Command       │              │              │              │
   │   Command       │                │ (algorithms,   │              │              │              │
   │                 │                │  key set ID)   │              │              │              │
   │ Sec Mode ────>  │ ─────────────> │               │              │              │              │
   │   Complete      │                │               │              │              │              │
   │                 │                │               │              │              │              │
   │                 │                │ ── Get subscription ────────────────────────> │              │
   │                 │                │    data (AMF, SM data) ──────────────────────> │              │
   │                 │                │ <── Subscription data ───────────────────────── │              │
   │                 │                │               │              │              │              │
   │ <── Reg Accept  │ <──────────── │               │              │              │              │
   │   (5G-GUTI,     │                │               │              │              │              │
   │    allowed NSSAI,│                │               │              │              │              │
   │    t3512 timer)  │                │               │              │              │              │
   │                 │                │               │              │              │              │
   │ Reg Complete ─> │ ─────────────> │               │              │              │              │
   │                 │                │               │              │              │              │
```

### Key Parameters in This Setup

| Parameter | Value | Config File |
|-----------|-------|-------------|
| SUPI | `imsi-208930000000001` | `config/uecfg.yaml` |
| PLMN (MCC/MNC) | 208/93 | `config/amfcfg.yaml`, `config/uecfg.yaml` |
| Requested S-NSSAIs | SST=1/SD=010203, SST=1/SD=112233 | `config/uecfg.yaml` |
| AMF ID | `cafe00` | `config/amfcfg.yaml` |
| TAC | `000001` | `config/amfcfg.yaml`, `config/gnbcfg.yaml` |
| Periodic Registration Timer (t3512) | 3600s (1 hour) | `config/amfcfg.yaml` |
| Security Integrity | NIA2 (AES-CMAC / 128-EIA2) | `config/amfcfg.yaml` |
| Security Ciphering | NEA0 (NULL -- lab only) | `config/amfcfg.yaml` |

### How to Trigger with UERANSIM

```bash
# Start UE (triggers Registration Request automatically)
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml

# Verify registration succeeded
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
# Expected: rm-state: RM-REGISTERED, cm-state: CM-CONNECTED
```

### How to Verify in Logs

```bash
# AMF: Registration sequence
docker logs amf 2>&1 | grep -E "Registration|5GMM|SUCI|GUTI"

# AUSF: Authentication
docker logs ausf 2>&1 | grep -i "auth"

# UDM: Auth vector generation
docker logs udm 2>&1 | grep -i "auth"

# NSSF: Slice selection
docker logs nssf 2>&1 | grep -i "slice\|nssai"
```

### 3GPP Reference

- TS 23.502 Section 4.2.2.2 (Registration Procedure)
- TS 24.501 Section 5.5.1 (Registration)

---

## Procedure 2: Authentication (5G-AKA)

Authentication happens within the Registration procedure. It is the cryptographic core that proves the UE is who it claims to be.

### What Happens

The network challenges the UE with a random number (RAND) and an authentication token (AUTN). The UE uses its permanent key (K) to compute a response (RES*). The network compares RES* against the expected XRES*. If they match, the UE is authenticated.

### NFs Involved

| NF | Role in Authentication |
|----|----------------------|
| **AMF** | Initiates auth by sending SUCI to AUSF, forwards auth challenge/response NAS messages to/from UE |
| **AUSF** | Receives auth vectors from UDM, sends challenge to AMF, verifies UE's RES* against XRES*, derives KAUSF |
| **UDM** | Decrypts SUCI to SUPI, generates authentication vectors (RAND, AUTN, XRES*, KAUSF) using Milenage algorithm |
| **UDR** | Provides K, OPC, AMF field, and SQN to UDM for vector computation |

### The Cryptographic Flow

```
                    UDR                  UDM                 AUSF                AMF                 UE
                     │                    │                    │                   │                   │
                     │ <── Get K, OPC ──  │                    │                   │                   │
                     │     SQN, AMF ────> │                    │                   │                   │
                     │                    │                    │                   │                   │
                     │             ┌──────┴──────┐            │                   │                   │
                     │             │  Milenage:   │            │                   │                   │
                     │             │  K + RAND    │            │                   │                   │
                     │             │  → CK, IK    │            │                   │                   │
                     │             │  → XRES      │            │                   │                   │
                     │             │  → AUTN      │            │                   │                   │
                     │             │              │            │                   │                   │
                     │             │  Derive:     │            │                   │                   │
                     │             │  XRES* from  │            │                   │                   │
                     │             │  CK,IK,XRES  │            │                   │                   │
                     │             │              │            │                   │                   │
                     │             │  KAUSF from  │            │                   │                   │
                     │             │  CK, IK      │            │                   │                   │
                     │             └──────┬──────┘            │                   │                   │
                     │                    │                    │                   │                   │
                     │                    │ ── Auth Vector ──> │                   │                   │
                     │                    │  (RAND, AUTN,      │                   │                   │
                     │                    │   XRES*, KAUSF)    │                   │                   │
                     │                    │                    │                   │                   │
                     │                    │               ┌────┴────┐              │                   │
                     │                    │               │ Store   │              │                   │
                     │                    │               │ XRES*,  │              │                   │
                     │                    │               │ KAUSF   │              │                   │
                     │                    │               └────┬────┘              │                   │
                     │                    │                    │                   │                   │
                     │                    │                    │ ── RAND, AUTN ──> │ ── Auth Req ────> │
                     │                    │                    │                   │  (RAND, AUTN)     │
                     │                    │                    │                   │                   │
                     │                    │                    │                   │            ┌──────┴──────┐
                     │                    │                    │                   │            │ Verify AUTN │
                     │                    │                    │                   │            │ (SQN check) │
                     │                    │                    │                   │            │             │
                     │                    │                    │                   │            │ Compute:    │
                     │                    │                    │                   │            │ RES* from   │
                     │                    │                    │                   │            │ K + RAND    │
                     │                    │                    │                   │            └──────┬──────┘
                     │                    │                    │                   │                   │
                     │                    │                    │ <── RES* ──────── │ <── Auth Resp ─── │
                     │                    │                    │                   │    (RES*)         │
                     │                    │                    │                   │                   │
                     │                    │               ┌────┴────┐              │                   │
                     │                    │               │Compare: │              │                   │
                     │                    │               │RES* vs  │              │                   │
                     │                    │               │XRES*    │              │                   │
                     │                    │               │         │              │                   │
                     │                    │               │Match =  │              │                   │
                     │                    │               │AUTH OK  │              │                   │
                     │                    │               └────┬────┘              │                   │
                     │                    │                    │                   │                   │
                     │                    │                    │ ── Auth Success ─> │                   │
                     │                    │                    │   (KAUSF)          │                   │
                     │                    │                    │                   │                   │
```

### Key Derivation Chain

The authentication process derives a chain of keys used for all subsequent NAS and AS security:

```
K (Permanent Key, stored on SIM and in UDR)
 │
 ├── Milenage(K, RAND) ──> CK (Cipher Key), IK (Integrity Key)
 │
 ├── CK, IK ──> KAUSF (anchor key, stored at AUSF)
 │     │
 │     └── KAUSF ──> KAMF (AMF key, stored at AMF)
 │           │
 │           ├── KAMF ──> KNASenc (NAS encryption key)
 │           ├── KAMF ──> KNASint (NAS integrity key)
 │           └── KAMF ──> KgNB (gNB key, for AS security)
 │                 │
 │                 ├── KgNB ──> KRRCenc (RRC encryption)
 │                 ├── KgNB ──> KRRCint (RRC integrity)
 │                 └── KgNB ──> KUPenc (User plane encryption)
```

### Subscriber Credentials in This Setup

| Parameter | Value | Where Configured |
|-----------|-------|-----------------|
| K (Permanent Key) | `8baf473f2f8fd09487cccbd7097c6862` | `config/uecfg.yaml` + MongoDB subscriber |
| OPC (Operator Code) | `8e27b6af0e692e750f32667a3b14605d` | `config/uecfg.yaml` + MongoDB subscriber |
| AMF field | `8000` | `config/uecfg.yaml` + MongoDB subscriber |
| Auth Method | 5G_AKA | MongoDB subscriber `authenticationMethod` |
| SQN (Sequence Number) | `000000000020` (patched for UERANSIM) | MongoDB `sequenceNumber` |
| SUPI | `imsi-208930000000001` | `config/uecfg.yaml` + MongoDB |

### SQN (Sequence Number) Explained

The SQN prevents replay attacks. Both the UE and network maintain a synchronized sequence number:

- Each authentication increments the SQN
- If the UE receives an AUTN with SQN outside its acceptable range, it sends a **Sync Failure**
- The network then re-synchronizes using the UE's provided AUTS parameter

> **UERANSIM SQN Issue**: UERANSIM starts with SQN = 0. The default subscriber SQN in free5GC (`16f3b3f70fc2` = 25,238,553,415,874) is far too large, causing immediate "SQN out of range" failures. The provisioning script patches SQN to `000000000020` (= 32) to fix this.

### Security Algorithms in This Setup

| Type | Algorithm | Config Key | Notes |
|------|-----------|-----------|-------|
| NAS Integrity | NIA2 (128-EIA2, AES-CMAC) | `amfcfg.yaml: security.integrityOrder` | Production-ready |
| NAS Ciphering | NEA0 (NULL) | `amfcfg.yaml: security.cipheringOrder` | Lab only -- no encryption! |
| UE Integrity | IA1, IA2, IA3 all enabled | `uecfg.yaml: integrity` | UE supports all |
| UE Ciphering | EA1, EA2, EA3 all enabled | `uecfg.yaml: ciphering` | UE supports all |

> **Production Warning**: The default config uses `NEA0` (NULL ciphering) which provides no NAS encryption. For production, change to `NEA1` (SNOW 3G) or `NEA2` (AES-CTR).

### How to Verify in Logs

```bash
# AUSF: Auth vector exchange
docker logs ausf 2>&1 | grep -E "auth|5G-AKA|SUCI|SUPI"

# UDM: Key computation
docker logs udm 2>&1 | grep -E "auth|GenerateAuthData"

# AMF: Auth result
docker logs amf 2>&1 | grep -E "Authentication|Security Mode"
```

### 3GPP Reference

- TS 33.501 Section 6.1.3 (5G-AKA)
- TS 33.501 Annex A (Milenage algorithm)
- TS 29.509 (AUSF services)

---

## Procedure 3: UE Identification (Identity Request)

### What Happens

The AMF may request the UE to provide its identity during registration if the UE's identity cannot be determined from the initial message (e.g., GUTI is stale or unrecognized). This is a NAS-level procedure between AMF and UE.

### Identity Types

| Identity Type | What It Is | When Requested |
|--------------|-----------|----------------|
| **SUCI** | Subscription Concealed Identifier (encrypted SUPI) | Initial registration, unknown UE |
| **SUPI** | Subscription Permanent Identifier (IMSI) | Never sent in plaintext over air in 5G |
| **5G-GUTI** | 5G Globally Unique Temporary Identity | Normal re-registration, assigned by AMF |
| **IMEI** | International Mobile Equipment Identity | Equipment identity check (e.g., stolen device) |
| **IMEISV** | IMEI + Software Version | Equipment identity + firmware version |

### How 5G Protects IMSI (SUPI)

Unlike 4G where the IMSI can be sent in cleartext (IMSI catchers exploit this), 5G **never** sends the SUPI in plaintext over the radio:

```
SUPI (imsi-208930000000001)
  │
  ├── ECIES encryption (Profile A or B)
  │     using Home Network Public Key
  │
  └──> SUCI (encrypted, safe to send over air)
        │
        └── UDM decrypts SUCI → SUPI (inside the core only)
```

### NFs Involved

| NF | Role in Identification |
|----|----------------------|
| **AMF** | Sends Identity Request NAS message to UE, processes Identity Response, uses t3570 timer for retransmission |
| **UDM** | Decrypts SUCI to recover SUPI (SIDF -- Subscriber Identity De-concealing Function) |
| **UDR** | Stores the SUCI decryption keys (home network private keys) |

### Sequence

```
  UE                    gNB                   AMF
   │                     │                     │
   │                     │  ┌──────────────┐   │
   │                     │  │ Cannot       │   │
   │                     │  │ identify UE  │   │
   │                     │  │ from GUTI    │   │
   │                     │  └──────┬───────┘   │
   │                     │         │           │
   │ <── Identity Request ─────────────────── │
   │   (identity type:    │                    │   Start t3570 timer
   │    SUCI or IMEI)     │                    │
   │                     │                     │
   │ ── Identity Response ──────────────────> │   Stop t3570 timer
   │   (SUCI or IMEI)    │                    │
   │                     │                     │
   │                     │                     │ ── SUCI to UDM ──>
   │                     │                     │ <── SUPI (decrypted)
   │                     │                     │
```

### AMF Timer: t3570

| Timer | Value | Purpose |
|-------|-------|---------|
| t3570 | Network-configured (typically 6s) | If the UE does not respond to the Identity Request within t3570, the AMF retransmits (up to a configured max retries) |

### How to Verify in Logs

```bash
# AMF: Identity Request/Response
docker logs amf 2>&1 | grep -i "identity"

# UDM: SUCI decryption
docker logs udm 2>&1 | grep -i "SUCI\|SUPI\|deconceal"
```

### 3GPP Reference

- TS 24.501 Section 5.4.3 (Identification Procedure)
- TS 33.501 Section 6.12 (SUPI/SUCI)

---

## Procedure 4: PDU Session Establishment

### What Happens

After registration, the UE requests a PDU session (data connection). The network allocates an IP address, sets up GTP-U tunnels, configures QoS rules, and programs the UPF to forward the UE's traffic. The result is a `uesimtun` interface with internet connectivity.

### NFs Involved

| NF | Role in PDU Session |
|----|---------------------|
| **AMF** | Forwards PDU Session Establishment Request from UE to SMF, relays N2 SM info to gNB |
| **SMF** | Orchestrates the session: selects UPF, allocates IP, creates PFCP session, applies QoS rules |
| **UPF** | Installs forwarding rules (PDRs, FARs) via PFCP, establishes GTP-U tunnel with gNB, performs NAT for internet access |
| **PCF** | Provides SM Policy (QoS rules, bandwidth limits, authorized S-NSSAI) to SMF |
| **UDM** | Provides Session Management Subscription Data (allowed DNN, session AMBR) to SMF |
| **UDR** | Stores SM subscription data that UDM retrieves |
| **CHF** | Receives usage reports from SMF for billing (if charging is enabled) |

### Step-by-Step Sequence

```
  UE             gNB            AMF            SMF            PCF           UPF
   │               │              │              │              │              │
   │ PDU Session   │              │              │              │              │
   │ Estab Req ──> │ ──────────> │              │              │              │
   │ (S-NSSAI,     │  UL NAS     │              │              │              │
   │  DNN, type)   │              │              │              │              │
   │               │              │ ── Nsmf ───> │              │              │
   │               │              │  CreateSM    │              │              │
   │               │              │  Context     │              │              │
   │               │              │              │              │              │
   │               │              │              │ ── Npcf ───> │              │
   │               │              │              │  SMPolicy    │              │
   │               │              │              │  Create      │              │
   │               │              │              │ <── Policy ── │              │
   │               │              │              │  (QoS rules, │              │
   │               │              │              │   PCC rules) │              │
   │               │              │              │              │              │
   │               │              │              │ ── PFCP Session ──────────> │
   │               │              │              │    Establishment            │
   │               │              │              │    (PDR, FAR,   │           │
   │               │              │              │     QER, URR)   │           │
   │               │              │              │              │              │
   │               │              │              │ <── PFCP Response ───────── │
   │               │              │              │    (UPF F-TEID = │          │
   │               │              │              │     N3 GTP endpoint)        │
   │               │              │              │              │              │
   │               │              │ <── N1N2 ─── │              │              │
   │               │              │  Transfer    │              │              │
   │               │              │  (NAS PDU +  │              │              │
   │               │              │   N2 SM info)│              │              │
   │               │              │              │              │              │
   │               │ <── PDU Sess │              │              │              │
   │               │  Resource    │              │              │              │
   │               │  Setup Req   │              │              │              │
   │               │  (QoS flow,  │              │              │              │
   │               │   GTP TEID)  │              │              │              │
   │               │              │              │              │              │
   │ <── PDU Sess  │              │              │              │              │
   │  Estab Accept │              │              │              │              │
   │  (IP addr,    │              │              │              │              │
   │   QoS, DNN)   │              │              │              │              │
   │               │              │              │              │              │
   │               │ ── PDU Sess ─>│              │              │              │
   │               │  Resource     │              │              │              │
   │               │  Setup Resp   │              │              │              │
   │               │  (gNB TEID)   │              │              │              │
   │               │              │ ── Update ──> │              │              │
   │               │              │  SM Context   │ ── PFCP Modification ───> │
   │               │              │  (gNB TEID)   │    (gNB F-TEID)           │
   │               │              │              │              │              │
   │ ═══ GTP-U Tunnel (N3) ══════════════════════════════════> │              │
   │               │                                            │ ── NAT ──> Internet
```

### What Gets Created

| Component | Details |
|-----------|---------|
| **UE IP** | Allocated from SMF pool: `10.60.0.0/16` (Slice 1) or `10.61.0.0/16` (Slice 2) |
| **GTP-U Tunnel** | Between gNB and UPF on N3 interface (UDP port 2152), identified by TEID |
| **PFCP Session** | SMF programs UPF with PDR (Packet Detection Rule), FAR (Forwarding Action Rule), QER (QoS Enforcement Rule), URR (Usage Reporting Rule) |
| **QoS Flow** | 5QI=9 (default best-effort), session AMBR: 200 Mbps DL / 100 Mbps UL |
| **TUN interface** | `uesimtun0` (Slice 1), `uesimtun1` (Slice 2) created by UERANSIM |

### Configuration Parameters

| Parameter | Value | Config File |
|-----------|-------|-------------|
| UE IP Pool (Slice 1) | `10.60.0.0/16` | `config/smfcfg.yaml` |
| UE IP Pool (Slice 2) | `10.61.0.0/16` | `config/smfcfg.yaml` |
| DNN | `internet` | `config/smfcfg.yaml`, `config/uecfg.yaml` |
| DNS Server | `8.8.8.8` | `config/smfcfg.yaml` |
| Session AMBR | DL: 200 Mbps, UL: 100 Mbps | MongoDB subscriber data |
| 5QI | 9 (best-effort internet) | MongoDB subscriber data |
| UPF N3 address | `upf.free5gc.org` | `config/smfcfg.yaml` |
| GTP-U forwarder | `gtp5g` (kernel module) | `config/upfcfg.yaml` |
| NAT rule | `iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE` | `config/upf-iptables.sh` |

### How to Trigger with UERANSIM

PDU sessions are established automatically after UE registration based on `sessions` in `config/uecfg.yaml`:

```yaml
sessions:
  - type: 'IPv4'
    apn: 'internet'
    slice:
      sst: 1
      sd: 010203      # → uesimtun0, IP in 10.60.x.x
  - type: 'IPv4'
    apn: 'internet'
    slice:
      sst: 1
      sd: 112233      # → uesimtun1, IP in 10.61.x.x
```

### How to Verify

```bash
# Check tunnel interfaces and IPs
docker exec ueransim ip addr show uesimtun0
docker exec ueransim ip addr show uesimtun1

# Test data plane
docker exec ueransim ping -I uesimtun0 -c 3 8.8.8.8
docker exec ueransim ping -I uesimtun1 -c 3 8.8.8.8

# SMF logs: session creation
docker logs smf 2>&1 | grep -i "pdu session"

# UPF logs: PFCP association and session
docker logs upf 2>&1 | grep -i "pfcp"

# PCF logs: policy decision
docker logs pcf 2>&1 | grep -i "policy\|sm"
```

### 3GPP Reference

- TS 23.502 Section 4.3.2 (PDU Session Establishment)
- TS 29.244 (PFCP protocol -- SMF to UPF)
- TS 29.512 (PCF SM Policy)

---

## Procedure 5: Paging (Reaching Idle UEs)

### What Happens

When a UE is in **CM-IDLE** state (power saving, no active N2 connection), the network cannot reach it directly. Paging is how the network wakes up an idle UE -- the AMF sends a Paging message to gNBs in the UE's last known Tracking Area, and the gNBs broadcast the page over the radio.

### When Paging is Triggered

- Downlink data arrives for the UE at the UPF (UPF notifies SMF, SMF notifies AMF)
- Network-initiated signaling (e.g., incoming call, MT SMS)
- AMF needs to reach the UE for administrative purposes

### NFs Involved

| NF | Role in Paging |
|----|---------------|
| **UPF** | Detects downlink data for idle UE, sends Downlink Data Notification to SMF via PFCP |
| **SMF** | Receives data notification from UPF, requests AMF to page the UE |
| **AMF** | Sends Paging message to gNBs in the UE's registration area, manages t3513 timer |
| **gNB** | Broadcasts paging indication over the radio (UE's 5G-S-TMSI used for identification) |

### Sequence

```
                  Internet           UPF             SMF             AMF            gNB(s)          UE
                     │                │               │               │               │              │
  Downlink packet ──>│                │               │               │               │              │
  for idle UE        │ ──────────────>│               │               │               │              │
                     │                │               │               │               │              │
                     │         ┌──────┴──────┐        │               │               │              │
                     │         │ No GTP      │        │               │               │              │
                     │         │ tunnel for  │        │               │               │              │
                     │         │ this UE     │        │               │               │              │
                     │         │ (CM-IDLE)   │        │               │               │              │
                     │         └──────┬──────┘        │               │               │              │
                     │                │               │               │               │              │
                     │                │ ── DL Data ─> │               │               │              │
                     │                │  Notification  │               │               │              │
                     │                │  (PFCP)        │               │               │              │
                     │                │               │ ── Namf ────> │               │              │
                     │                │               │  N1N2Transfer │               │              │
                     │                │               │  (paging ind) │               │              │
                     │                │               │               │               │              │
                     │                │               │               │ ── Paging ──> │              │
                     │                │               │               │  (5G-S-TMSI,  │ ── Page ──> │
                     │                │               │               │   TAI list)   │  (radio     │
                     │                │               │               │               │   broadcast) │
                     │                │               │               │  Start t3513  │              │
                     │                │               │               │               │              │
                     │                │               │               │               │ <── Service  │
                     │                │               │               │ <──────────── │    Request   │
                     │                │               │               │  InitialUE    │              │
                     │                │               │               │  Message      │              │
                     │                │               │               │  Stop t3513   │              │
                     │                │               │               │               │              │
                     │                │               │            (Re-establish N2,  │              │
                     │                │               │             restore GTP-U)    │              │
                     │                │               │               │               │              │
                     │                │ <════ GTP-U Tunnel Restored ══════════════════│              │
                     │ <──────────── │  (deliver buffered DL data)    │              │              │
                     │                │               │               │               │ ──────────> │
                     │                │               │               │               │  DL data    │
```

### Key Timer: t3513

| Timer | Value | Purpose |
|-------|-------|---------|
| t3513 | Network-configured (typically 6s) | If the UE does not respond to paging within t3513, AMF retransmits the page. After max retries, AMF considers the UE unreachable. |

### CM State Transitions

```
UE Powers On ──> Registration ──> CM-CONNECTED (active data, N2 established)
                                       │
                                  Inactivity timer expires
                                  (gNB releases RRC connection)
                                       │
                                       v
                                  CM-IDLE (no N2, no RRC, UE in DRX)
                                       │
                                  Paging or UE-initiated Service Request
                                       │
                                       v
                                  CM-CONNECTED (restored)
```

### How to Simulate with UERANSIM

UERANSIM does not fully simulate CM-IDLE/paging (it keeps a continuous RRC connection). However, you can observe the concepts through:

```bash
# Check current CM state
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
# In UERANSIM, this will typically show CM-CONNECTED

# Deregister and re-register to see state transitions
docker exec ueransim ./nr-cli imsi-208930000000001 -e "deregister normal"
sleep 3
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
```

### 3GPP Reference

- TS 23.502 Section 4.2.3.3 (Network Triggered Service Request)
- TS 38.413 Section 9.3 (Paging in NGAP)
- TS 24.501 Section 5.6.2 (Service Request)

---

## Procedure 6: Silent Call / Persistent Connected Mode

### What Is a "Silent Call" in 5G?

In legacy networks, a "silent call" referred to law enforcement triggering an invisible call to locate a mobile device. In 5G, the equivalent concept is keeping a UE in **CM-CONNECTED** state continuously (preventing it from going idle), so the network always knows the UE's exact cell location and can reach it immediately.

### How to Keep a UE in CM-CONNECTED

There are several mechanisms in 5G to prevent a UE from going idle:

#### 1. Always-On PDU Session

The SMF can indicate an "always-on" PDU session, which signals the UE to maintain the session even without active data. This is configured per subscriber/session.

```
SMF ── PDU Session Establishment Accept ──> UE
       (always-on PDU session indication = ON)
```

#### 2. Periodic Registration Timer (t3512)

The AMF assigns a periodic registration timer in the Registration Accept message. The UE must re-register before this timer expires, even while idle. A short t3512 forces frequent signaling.

| Timer | Default Value | Effect |
|-------|--------------|--------|
| t3512 | 3600s (1 hour) in this setup | UE re-registers every hour. Shorter values (e.g., 60s) force near-continuous signaling. |

Config location: `config/amfcfg.yaml`
```yaml
t3512: 3600  # Periodic Registration Timer in seconds
```

#### 3. Continuous Downlink Data

Sending periodic small packets (e.g., ICMP ping) to the UE prevents the inactivity timer from expiring, keeping the UE in CM-CONNECTED.

### NFs Involved

| NF | Role |
|----|------|
| **AMF** | Sets t3512 timer, manages CM state, triggers Service Request after paging |
| **SMF** | Configures always-on PDU session indication |
| **UPF** | Maintains data path, buffers DL data during state transitions |
| **gNB** | Manages RRC connection (Connected vs Idle), inactivity timer |

### How to Simulate with UERANSIM

```bash
# Start UE (it will stay CM-CONNECTED as long as UERANSIM is running)
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml

# Verify CM-CONNECTED state
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
# Expected: cm-state: CM-CONNECTED

# Keep data flowing (prevents any idle transition)
docker exec ueransim ping -I uesimtun0 8.8.8.8
```

> **Note**: UERANSIM maintains a persistent connection by design, so the UE stays CM-CONNECTED throughout the simulation. In a real network, the gNB would release the RRC connection after an inactivity timer (typically 10-30 seconds of no data).

### 3GPP Reference

- TS 24.501 Section 9.11.3.55 (Always-on PDU session indication)
- TS 23.502 Section 4.2.2.2 (Registration, t3512 assignment)
- TS 23.502 Section 4.2.3.3 (Service Request / CM state transitions)

---

## Procedure 7: Deregistration

### What Happens

Deregistration removes the UE from the network. There are two types:

| Type | Who Initiates | When |
|------|--------------|------|
| **UE-initiated** | UE sends Deregistration Request | UE powering off, airplane mode, user action |
| **Network-initiated** | AMF sends Deregistration Request | Subscription revoked, admin action, implicit deregistration (UE unreachable) |

### UE-Initiated Deregistration

```
  UE                gNB              AMF            SMF            UPF
   │                 │                │               │              │
   │ Deregistration  │ UL NAS        │               │              │
   │ Request ──────> │ ────────────> │               │              │
   │ (type: normal   │               │               │              │
   │  or switch-off) │               │               │              │
   │                 │                │               │              │
   │                 │                │ ── Release ──> │              │
   │                 │                │    SM Context  │ ── PFCP ──> │
   │                 │                │               │  Session Del  │
   │                 │                │               │              │
   │                 │                │               │ <── PFCP ─── │
   │                 │                │               │  Del Response │
   │                 │                │ <── Context ── │              │
   │                 │                │    Released    │              │
   │                 │                │               │              │
   │ <── Dereg ──── │ <──────────── │               │              │
   │    Accept       │  DL NAS       │               │              │
   │                 │                │               │              │
   │                 │ <── UE Context │               │              │
   │                 │    Release Cmd │               │              │
   │                 │                │               │              │
```

### What Gets Cleaned Up

| Resource | Action |
|----------|--------|
| **NAS Security Context** | Cleared at AMF (keys invalidated) |
| **PDU Sessions** | Released: SMF sends PFCP Session Deletion to UPF |
| **GTP-U Tunnels** | Torn down on UPF and gNB |
| **UPF Forwarding Rules** | PDR, FAR, QER, URR removed |
| **UE IP Address** | Returned to SMF's IP pool |
| **UE Context at AMF** | Marked as deregistered |
| **RRC Connection** | Released by gNB |
| **uesimtun interfaces** | Destroyed by UERANSIM |

### Network-Initiated Deregistration

Triggered when the network decides to remove the UE:
- Admin removes subscriber from database
- Subscription expires
- Implicit deregistration (UE fails to re-register before t3512 + implicit deregistration timer)

```
  AMF             gNB              UE
   │                │               │
   │ ── Paging ──> │ ─── Page ──> │  (if UE is CM-IDLE)
   │                │               │
   │                │ <── Service ─ │
   │                │    Request    │
   │                │               │
   │ ── Deregistration Request ──> │
   │  (cause: e.g., "implicit      │
   │   deregistration")            │
   │                │               │
   │ <── Deregistration Accept ─── │  (if normal type)
   │                │               │
   │  Clean up all sessions         │
   │  and UE context                │
```

### How to Trigger with UERANSIM

```bash
# UE-initiated normal deregistration
docker exec ueransim ./nr-cli imsi-208930000000001 -e "deregister normal"

# Check status
sleep 3
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status"
# Expected: rm-state: RM-DEREGISTERED

# Verify PDU sessions are gone
docker exec ueransim ip addr show uesimtun0 2>&1
# Expected: "Device uesimtun0 does not exist"

# Re-register
docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml
```

### How to Verify in Logs

```bash
# AMF: Deregistration messages
docker logs amf 2>&1 | grep -i "deregist"

# SMF: PDU session release
docker logs smf 2>&1 | grep -i "release\|delete"

# UPF: PFCP session deletion
docker logs upf 2>&1 | grep -i "session\|delete"
```

### 3GPP Reference

- TS 23.502 Section 4.2.2.3 (UE-initiated Deregistration)
- TS 23.502 Section 4.2.2.4 (Network-initiated Deregistration)

---

## NF-to-Procedure Mapping Table

This table shows which NFs participate in each procedure:

| Procedure | AMF | AUSF | UDM | UDR | SMF | UPF | NRF | NSSF | PCF | CHF | gNB |
|-----------|:---:|:----:|:---:|:---:|:---:|:---:|:---:|:----:|:---:|:---:|:---:|
| **Registration** | **Lead** | Auth | Auth + Sub data | Key store | -- | -- | Discovery | Slice select | -- | -- | Transport |
| **Authentication** | Relay | **Lead** | Vectors | Keys | -- | -- | Discovery | -- | -- | -- | Transport |
| **Identification** | **Lead** | -- | SUCI decrypt | Keys | -- | -- | -- | -- | -- | -- | Transport |
| **PDU Session** | Relay | -- | Sub data | Sub data | **Lead** | Install rules | Discovery | -- | Policy | Billing | GTP-U tunnel |
| **Paging** | **Lead** | -- | -- | -- | Notify | DL data detect | -- | -- | -- | -- | Broadcast |
| **Silent Call** | Timer | -- | -- | -- | Always-on | Data path | -- | -- | -- | -- | RRC mgmt |
| **Deregistration** | **Lead** | -- | Notify | -- | Release | Remove rules | -- | -- | -- | -- | RRC release |

**Legend**:
- **Lead**: The NF that orchestrates the procedure
- Other entries describe the NF's specific contribution
- `--` means the NF is not involved

### NF Dependency Graph

Understanding which NFs depend on each other helps with startup ordering and debugging:

```
NRF ← (all NFs register here first)
 │
 ├── UDR ← UDM ← AUSF ← AMF (authentication chain)
 │                  │
 │                  └──── AMF (subscription data)
 │
 ├── NSSF ← AMF (slice selection)
 │
 ├── PCF ← SMF (policy decisions)
 │
 ├── CHF ← SMF (charging)
 │
 └── SMF ← AMF (session management)
      │
      └── UPF (via PFCP, not SBI)
```

**Startup Order** (used in consolidated mode):
1. NRF (must be first -- all others register with it)
2. UDR (database layer, no NF dependencies)
3. UDM (depends on UDR)
4. AUSF (depends on UDM)
5. NSSF (depends on NRF)
6. PCF (depends on NRF, UDR)
7. AMF (depends on AUSF, UDM, NSSF, NRF)
8. SMF (depends on AMF, PCF, UPF)

---

## Verifying Procedures in free5GC Logs

### Log Interpretation Quick Reference

| What to Search | Command | What It Means |
|----------------|---------|---------------|
| NF registration | `docker logs nrf 2>&1 \| grep "NFRegister"` | NFs registering with NRF at startup |
| gNB connection | `docker logs amf 2>&1 \| grep "NG Setup"` | gNB establishing N2/SCTP with AMF |
| UE registration | `docker logs amf 2>&1 \| grep "Registration"` | UE attach procedure |
| Authentication | `docker logs ausf 2>&1 \| grep "5G-AKA\|auth"` | 5G-AKA challenge-response |
| Security mode | `docker logs amf 2>&1 \| grep "Security Mode"` | NAS security activation |
| PDU session | `docker logs smf 2>&1 \| grep "PDU Session"` | Session establishment |
| IP allocation | `docker logs smf 2>&1 \| grep "UE IP\|address"` | IP assigned to UE |
| PFCP | `docker logs upf 2>&1 \| grep "PFCP"` | SMF-UPF association and sessions |
| Deregistration | `docker logs amf 2>&1 \| grep -i "deregist"` | UE detach |

### End-to-End Verification Script

Run this after starting the UE to verify all procedures completed successfully:

```bash
#!/bin/bash
echo "=== 1. NF Registration ==="
docker logs nrf 2>&1 | grep -c "NFRegister"
echo "NFs registered with NRF"

echo ""
echo "=== 2. gNB Connection ==="
docker logs amf 2>&1 | grep "NG Setup" | tail -1

echo ""
echo "=== 3. UE Registration ==="
docker exec ueransim ./nr-cli imsi-208930000000001 -e "status" 2>/dev/null

echo ""
echo "=== 4. PDU Sessions ==="
docker exec ueransim ip -brief addr show | grep uesimtun

echo ""
echo "=== 5. Data Plane ==="
docker exec ueransim ping -I uesimtun0 -c 1 -W 3 8.8.8.8 2>/dev/null | grep -E "transmitted|loss"
docker exec ueransim ping -I uesimtun1 -c 1 -W 3 8.8.8.8 2>/dev/null | grep -E "transmitted|loss"
```

---

## Further Reading

- [01-5G-SA-FUNDAMENTALS.md](01-5G-SA-FUNDAMENTALS.md) - 5G architecture overview for beginners
- [03-TESTING-GUIDE.md](03-TESTING-GUIDE.md) - Step-by-step testing with expected log outputs
- [04-MANDATORY-COMPONENTS.md](04-MANDATORY-COMPONENTS.md) - Deep dive into each mandatory NF's internals
- [08-DEPLOYMENT-MODES-GUIDE.md](08-DEPLOYMENT-MODES-GUIDE.md) - How to deploy and test each mode
- [3GPP TS 23.501](https://www.3gpp.org/DynaReport/23501.htm) - 5G System Architecture
- [3GPP TS 23.502](https://www.3gpp.org/DynaReport/23502.htm) - 5G Procedures
- [3GPP TS 33.501](https://www.3gpp.org/DynaReport/33501.htm) - 5G Security Architecture
- [3GPP TS 24.501](https://www.3gpp.org/DynaReport/24501.htm) - NAS Protocol for 5G
- [3GPP TS 29.244](https://www.3gpp.org/DynaReport/29244.htm) - PFCP (SMF-UPF interface)
