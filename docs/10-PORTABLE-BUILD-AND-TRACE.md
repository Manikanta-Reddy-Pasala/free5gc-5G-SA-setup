# Portable Build, Run & Trace Guide

Build all free5GC NFs + UERANSIM from source inside Docker, run the 5G core, simulate UE registration, and trace the full data flow across all network functions.

**Only requires Docker** - no Go, GCC, CMake, or other build tools on the host. Works on Mac (Apple Silicon/Intel), Linux (x86_64/ARM64), or any OS.

Everything is done through a single script: `./free5gc.sh`

---

## 1. Build from Source

```bash
git clone https://github.com/Manikanta-Reddy-Pasala/free5gc-5G-SA-setup.git
cd free5gc-5G-SA-setup
```

### Full Build (~15 min first time, cached after)

```bash
./free5gc.sh build
```

What happens:

1. **Source compilation** inside Docker (multi-stage `Dockerfile.build-all`)
   - Stage 1: `golang:latest` - clones free5GC v4.2.0, builds 8 CP NFs + UPF
   - Stage 2: `ubuntu:22.04` - clones UERANSIM, builds nr-gnb, nr-ue, nr-cli
   - Stage 3: copies all binaries to `/output`
2. **Binary extraction** - `docker run` with volume mount copies binaries to `build-output/`
3. **Runtime image build** - 3 lightweight Docker images from the extracted binaries

Output:
```
build-output/
  ├── cp/        nrf, amf, ausf, udm, udr, smf, nssf, pcf
  ├── upf/       upf, upf-iptables.sh
  └── ueransim/  nr-gnb, nr-ue, nr-cli, binder/

Images:
  free5gc-cp-local:v4.2.0       (~300MB)
  free5gc-upf-local:v4.2.0      (~140MB)
  free5gc-ueransim-local:latest  (~115MB)
```

### Quick Rebuild (skip source compilation)

If binaries already exist in `build-output/`, just rebuild the runtime images:

```bash
./free5gc.sh build --quick
```

---

## 2. Start the 5G Core

```bash
./free5gc.sh start
```

Auto-detects mode:
- **Full mode** (Linux with gtp5g): Starts 4 containers - MongoDB, Control Plane (8 NFs), UPF, UERANSIM
- **CP-only mode** (Mac / no gtp5g): Starts 3 containers - MongoDB, Control Plane, UERANSIM

### What `start` Does

1. Detects mode by checking `lsmod | grep gtp5g`
2. Starts containers via `docker compose -f docker-compose-portable.yaml`
3. Waits for CP health check (polls NRF HTTP endpoint, up to 120s)
4. Provisions a default subscriber using the WebUI API:
   - Starts a temporary `free5gc/webui:v4.2.0` container
   - Creates subscriber via `POST /api/subscriber/{imsi}/{plmn}`
   - Patches MongoDB: adds `allowedSessionTypes` and `smPolicySnssaiData`
   - Removes the temporary WebUI container
5. Restarts UERANSIM (ensures gNB connects after AMF NGAP is ready)
6. Shows container status

### Default Subscriber

Provisioned automatically by `start`:

| Parameter | Value |
|-----------|-------|
| IMSI | `imsi-208930000000001` |
| PLMN | `20893` (MCC=208, MNC=93) |
| K | `8baf473f2f8fd09487cccbd7097c6862` |
| OPC | `8e27b6af0e692e750f32667a3b14605d` |
| AMF | `8000` |
| Auth Method | 5G_AKA |
| Slices | SST=1/SD=010203, SST=1/SD=112233 |
| DNN | `internet` |

---

## 3. Test UE Registration

### Simple Test (1 UE + trace)

```bash
./free5gc.sh test
```

This will:
1. Record current log positions for all 8 CP NFs + UPF + UERANSIM
2. Kill any existing UE processes
3. Start 1 UE: `docker exec -d ueransim ./nr-ue -c ./config/uecfg.yaml`
4. Wait up to 30s for registration to complete
5. Collect new logs from every NF
6. **Print the registration trace** showing the NF chain:
   - UE -> gNB -> AMF -> AUSF -> UDM -> UDR -> MongoDB and back
   - Key events: Authentication Success, Security Mode, Registered, PDU Session
   - HTTP calls: POST /nausf-auth, GET /nudm-sdm, etc.
7. Print PASS/FAIL result
8. Save trace to `logs/trace-{timestamp}/trace.log`

### Full Test (16 attach + 200 reject + 100 identify)

```bash
./free5gc.sh test full
```

**Phase 1: Attach 16 UEs**
- Provisions 16 subscribers via direct MongoDB writes
- Launches 16 UEs simultaneously
- Chronological trace showing complete NF-to-NF flow:
  UERANSIM -> AMF -> AUSF -> UDM -> UDR -> MongoDB (request chain)
  then back: MongoDB -> UDR -> UDM -> AUSF -> AMF -> UERANSIM (response chain)
- Per-UE status table (REGISTERED + PDU session status)

**Phase 2: Reject 200 UEs**
- Launches 200 unprovisioned UEs in 4 batches of 50
- Chronological trace showing rejection flow across AMF/AUSF/UDM/UDR
- Rejection summary: RRC attempts, auth errors, registration rejects
- Verifies 0 context setups (all rejected)

**Phase 3: Identify 100 UEs**
- Provisions and registers 100 UEs in 2 batches of 50
- Chronological trace showing SUPI/SUCI identification events
- Verifies all 100 UEs are identified and registered

**Trace Output Format:**
```
TIMESTAMP    FLOW  NF        MODULE       LVL    MESSAGE
------------ ----- --------- ------------ -----  -------
13:52:01.234  ==>  UERANSIM  [nas]        INFO   Sending initial-registration
13:52:01.235  ==>  AMF       [NGAP]       INFO   Handle InitialUEMessage
13:52:01.236  -->  AMF       [GMM]        INFO   Nausf_UEAuthentication
13:52:01.237  >>>  AUSF      [GIN]        INFO   POST /nausf-auth/v1/ue-authentications
13:52:01.238  -->  AUSF      [UeAuth]     INFO   Nudm_UEAuthentication
13:52:01.239  >>>  UDM       [GIN]        INFO   POST /nudm-ueau/v1/.../security-information
13:52:01.240  -->  UDM       [UEAU]       INFO   Nudr_DataRepository
13:52:01.241  >>>  UDR       [GIN]        INFO   GET /nudr-dr/v1/subscription-data/.../authentication-data
13:52:01.245  <<<  UDR       [GIN]        INFO   200 | GET | /nudr-dr/...
13:52:01.246  <<<  UDM       [GIN]        INFO   200 | POST | /nudm-ueau/...
13:52:01.247  <<<  AUSF      [GIN]        INFO   201 | POST | /nausf-auth/...
13:52:01.300  ==>  AMF       [GMM]        INFO   Authentication Success
```

Legend: `==>` key milestones, `>>>` SBI requests, `<<<` SBI responses, `-->` NF-to-NF calls, `[!!]` errors

**Output:**
- Summary with pass/fail counts per phase
- Detailed trace saved to `logs/trace-{timestamp}.log`
- Raw per-NF logs in `logs/trace-full-{timestamp}/`

### What the Trace Shows

The registration flow across NFs:

```
UE -> gNB          : RRC Setup Request / NAS Registration Request
gNB -> AMF         : NGAP Initial UE Message (N2/SCTP)
AMF -> AUSF        : POST /nausf-auth/v1/ue-authentications (SBI)
AUSF -> UDM        : POST /nudm-ueau/v1/{supi}/security-information (SBI)
UDM -> UDR         : GET /nudr-dr/v1/subscription-data/{ueId}/authentication-data (SBI)
UDR -> MongoDB     : query subscriptionData.authenticationData
  <- responses flow back through each NF <-
AMF -> UE          : Authentication Request (5G-AKA challenge)
UE -> AMF          : Authentication Response
AMF -> AUSF        : PUT .../5g-aka-confirmation
  <- Authentication Success <-
AMF -> UE          : Security Mode Command
UE -> AMF          : Security Mode Complete
AMF -> gNB         : Initial Context Setup Request
gNB -> AMF         : Initial Context Setup Response
  <- UE is now REGISTERED <-
AMF -> SMF         : POST /nsmf-pdusession/v1/sm-contexts (PDU Session)
SMF -> UDM         : GET /nudm-sdm/v2/{supi}/sm-data
SMF -> PCF         : POST /npcf-smpolicycontrol/v1/sm-policies
SMF -> UPF         : PFCP Session Establishment (N4)
  <- PDU Session Established (full mode) or fails (CP-only) <-
```

---

## 4. Other Commands

### Stop

```bash
./free5gc.sh stop
```

Runs `docker compose -f docker-compose-portable.yaml down -v` to stop and remove all containers and volumes.

### Status

```bash
./free5gc.sh status
```

Shows `docker compose ps` output for all containers.

### Logs

```bash
./free5gc.sh logs              # Tail all container logs
./free5gc.sh logs amf          # Tail AMF NF log (/var/log/free5gc/amf.log)
./free5gc.sh logs smf          # Tail SMF NF log
./free5gc.sh logs upf          # Tail UPF container logs
./free5gc.sh logs ueransim     # Tail UERANSIM container logs
```

Available NF names: `amf`, `ausf`, `udm`, `udr`, `smf`, `nrf`, `nssf`, `pcf`, `upf`, `ueransim`

---

## 5. Debug Logging

All configs in `config-debug/` have `level: debug` set. This is used by the portable deployment (`docker-compose-portable.yaml`) by default.

### Logs on Host

NF logs are volume-mounted to the host:

```bash
ls logs/cp/      # amf.log, ausf.log, nrf.log, smf.log, etc.
ls logs/upf/     # upf.log (full mode only)
```

### Switch to Info-Level Logging

To reduce log volume, use `config-consolidated/` instead of `config-debug/` in `docker-compose-portable.yaml`. Those configs have `level: info`.

---

## 6. Full Mode vs CP-Only Mode

| | Full Mode | CP-Only Mode |
|---|-----------|-------------|
| **Requirement** | Linux with gtp5g kernel module | Mac, Linux, any OS |
| **Containers** | 4: db, cp, upf, ueransim | 3: db, cp, ueransim |
| **Registration** | Yes | Yes |
| **Authentication** | Yes | Yes |
| **PDU Session** | Yes | No (no UPF) |
| **Internet via UE** | Yes (`ping -I uesimtun0 8.8.8.8`) | No |
| **Use case** | Full end-to-end testing | Control plane study, SBI tracing |

Mode is auto-detected by `./free5gc.sh start`.

---

## 7. File Reference

### Core Script

| File | What It Does |
|------|-------------|
| `free5gc.sh` | Unified script: build, start, test, stop, status, logs |

### Build Files

| File | What It Does |
|------|-------------|
| `Dockerfile.build-all` | Multi-stage builder: compiles free5GC (Go) + UERANSIM (C++) from source |
| `Dockerfile.cp-local` | Runtime image for Control Plane (ubuntu:22.04 + 8 NF binaries) |
| `Dockerfile.upf-local` | Runtime image for UPF (debian:bookworm-slim + upf binary) |
| `Dockerfile.ueransim-local` | Runtime image for UERANSIM (ubuntu:22.04 + nr-gnb/nr-ue/nr-cli) |

### Config & Output Directories

| Directory | What It Contains |
|-----------|-----------------|
| `config-debug/` | NF YAML configs with `level: debug` (10 files) |
| `config/` | Standard NF configs + gNB/UE configs |
| `cert/` | TLS certificates for NF-to-NF communication |
| `build-output/` | Extracted binaries (created by `build`, not committed) |
| `logs/cp/` | CP NF log files mounted from container |
| `logs/upf/` | UPF log files mounted from container |
| `logs/trace-*/` | Test traces and raw per-NF logs |

### Legacy Scripts (still available)

| File | What It Does |
|------|-------------|
| `build.sh` | Standalone build orchestrator (superseded by `free5gc.sh build`) |
| `run.sh` | Standalone run + provision (superseded by `free5gc.sh start`) |
| `scripts/provision-subscriber.sh` | Standalone subscriber provisioning |
| `scripts/trace-registration-flow.sh` | Standalone registration trace |
| `scripts/ue-flow-trace.sh` | Advanced flow tracing with 3 test scenarios |
| `scripts/ue-simulation-test.sh` | Full UE simulation test suite |

---

## 8. Troubleshooting

### Build Issues

**"go: module requires Go >= X.Y.Z"** - The Dockerfile uses `golang:latest` with `GOTOOLCHAIN=auto`, so it automatically downloads the required Go version. If this fails, rebuild with `docker build --no-cache`.

**UERANSIM CMake fails on ARM64** - The Dockerfile auto-detects architecture via `uname -m`. If it fails, check that Docker buildx is using the correct platform.

### Runtime Issues

**gNB "SCTP Connection refused"** - AMF's NGAP listener may not be ready yet. The `start` command automatically restarts UERANSIM after CP is healthy. If issues persist:
```bash
docker restart ueransim
```

**Port 5000 conflict on macOS** - AirPlay uses port 5000. The provisioning logic auto-detects macOS and uses port 5001. Or disable AirPlay: System Settings > General > AirDrop & Handoff.

**"CreateSmContextRequest Error: 500"** - Expected in CP-only mode. SMF can't reach UPF. Registration still succeeds.

**"Nil PermanentKey" from UDM** - Subscriber wasn't provisioned correctly. Re-run:
```bash
./free5gc.sh stop && ./free5gc.sh start
```

### Useful Commands

```bash
# Container status
./free5gc.sh status

# Restart everything
./free5gc.sh stop && ./free5gc.sh start

# Check subscriber in MongoDB
docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval \
  'db["subscriptionData.authenticationData.authenticationSubscription"].find({},{ueId:1,authenticationMethod:1}).pretty()'

# Check registered UEs in AMF
docker exec free5gc-cp grep "Registered" /var/log/free5gc/amf.log

# Follow all NF logs in real time
./free5gc.sh logs
```
