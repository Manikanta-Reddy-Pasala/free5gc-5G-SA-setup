# Portable Build, Run & Trace Guide

Build all free5GC NFs + UERANSIM from source inside Docker, run the 5G core, simulate UE registration, and trace the full data flow across all network functions.

**Only requires Docker** - no Go, GCC, CMake, or other build tools on the host. Works on Mac (Apple Silicon/Intel), Linux (x86_64/ARM64), or any OS.

---

## 1. Build from Source

```bash
git clone https://github.com/Manikanta-Reddy-Pasala/free5gc-5G-SA-setup.git
cd free5gc-5G-SA-setup
chmod +x build.sh run.sh scripts/*.sh
```

### Full Build (~15 min first time, cached after)

```bash
./build.sh
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
./build.sh --quick
```

---

## 2. Run the 5G Core

### Option A: Full Mode (Linux with gtp5g kernel module)

Starts all 4 containers: MongoDB, Control Plane (8 NFs), UPF, UERANSIM.

```bash
./run.sh
```

### Option B: CP-Only Mode (Mac / no gtp5g)

Starts 3 containers: MongoDB, Control Plane, UERANSIM. Skips UPF.

```bash
./run.sh --cp-only
```

UE registration and authentication work fully. Only PDU session establishment (data plane) is skipped since there is no UPF.

### What run.sh Does

1. Starts containers via `docker compose -f docker-compose-portable.yaml`
2. Waits for CP health check (polls NRF HTTP endpoint, up to 120s)
3. Provisions a default subscriber using the WebUI API:
   - Starts a temporary `free5gc/webui:v4.2.0` container
   - Creates subscriber via `POST /api/subscriber/{imsi}/{plmn}`
   - Patches MongoDB: adds `allowedSessionTypes` and `smPolicySnssaiData`
   - Removes the temporary WebUI container
4. Shows container status

### Other Commands

```bash
./run.sh --status    # Show container status
./run.sh --down      # Stop all containers, remove volumes
```

### Default Subscriber

Provisioned automatically by `run.sh`:

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

## 3. UE Simulation

After `run.sh` finishes, the gNB is already running and connected to AMF. To simulate a UE:

### Register a UE

```bash
docker exec ueransim ./nr-ue -c ./config/uecfg.yaml
```

### Verify Registration Succeeded

```bash
# Check AMF state transitions
docker exec free5gc-cp grep -E "Authentication Success|SecurityMode|Registered" /var/log/free5gc/amf.log
```

Expected output shows the full state machine:
```
transition from [Deregistered] to [Authentication]
Authentication Success
transition from [Authentication] to [SecurityMode]
Handle Security Mode Complete
transition from [SecurityMode] to [ContextSetup]
transition from [ContextSetup] to [Registered]
```

### Check Authentication (AUSF)

```bash
docker exec free5gc-cp grep "5G AKA" /var/log/free5gc/ausf.log
```

Expected: `5G AKA confirmation succeeded`

### Check Subscriber Lookup (UDM/UDR)

```bash
docker exec free5gc-cp tail -20 /var/log/free5gc/udm.log
docker exec free5gc-cp tail -20 /var/log/free5gc/udr.log
```

### Check PDU Session (SMF) - Full Mode Only

```bash
docker exec free5gc-cp grep -i "pdu session" /var/log/free5gc/smf.log
```

In CP-only mode, you'll see `Host lookup failed: upf.free5gc.org` - this is expected.

---

## 4. Data Flow Tracing

The trace script captures the **complete registration flow** across all NFs with detailed SBI HTTP request/response logs.

### Run a Full Trace

```bash
./scripts/trace-registration-flow.sh
```

This will:
1. Record current log positions for all 8 CP NFs + UPF + UERANSIM
2. Trigger a new UE registration
3. Wait for registration to complete (or timeout after 30s)
4. Collect only the **new** log lines from each NF
5. Parse SBI HTTP calls (method, path, status code)
6. Merge all logs chronologically
7. Generate a summary of the registration flow

### Trace Existing Logs (No New Registration)

```bash
./scripts/trace-registration-flow.sh --skip-ue
```

### Output

Results are saved to `./logs/registration-flow-{timestamp}/`:

```
logs/registration-flow-20260210-192600/
  ├── raw/                  # Raw log files per NF
  │   ├── amf.log
  │   ├── ausf.log
  │   ├── udm.log
  │   ├── udr.log
  │   ├── smf.log
  │   ├── nrf.log
  │   ├── nssf.log
  │   ├── pcf.log
  │   ├── upf.log
  │   └── ueransim.log
  ├── parsed/               # Parsed HTTP calls per NF
  │   ├── amf-http.log
  │   ├── ausf-http.log
  │   └── ...
  ├── merged-flow.log       # All NFs merged chronologically
  └── summary.log           # Human-readable registration flow
```

### What the Trace Shows

The registration flow across NFs:

```
UE → gNB          : RRC Setup Request / NAS Registration Request
gNB → AMF         : NGAP Initial UE Message (N2/SCTP)
AMF → AUSF        : POST /nausf-auth/v1/ue-authentications (SBI)
AUSF → UDM        : POST /nudm-ueau/v1/{supi}/security-information (SBI)
UDM → UDR         : GET /nudr-dr/v1/subscription-data/{ueId}/authentication-data (SBI)
UDR → MongoDB     : query subscriptionData.authenticationData
  ← responses flow back through each NF ←
AMF → UE          : Authentication Request (5G-AKA challenge)
UE → AMF          : Authentication Response
AMF → AUSF        : PUT .../5g-aka-confirmation
  ← Authentication Success ←
AMF → UE          : Security Mode Command
UE → AMF          : Security Mode Complete
AMF → gNB         : Initial Context Setup Request
gNB → AMF         : Initial Context Setup Response
  ← UE is now REGISTERED ←
AMF → SMF         : POST /nsmf-pdusession/v1/sm-contexts (PDU Session)
SMF → UDM         : GET /nudm-sdm/v2/{supi}/sm-data
SMF → PCF         : POST /npcf-smpolicycontrol/v1/sm-policies
SMF → UPF         : PFCP Session Establishment (N4)
  ← PDU Session Established (full mode) or fails (CP-only) ←
```

---

## 5. Debug Logging

All configs in `config-debug/` have `level: debug` set. This is used by the portable deployment (`docker-compose-portable.yaml`) by default.

### View Live Logs

```bash
# All containers
docker compose -f docker-compose-portable.yaml logs -f

# Specific NF log file
docker exec free5gc-cp tail -f /var/log/free5gc/amf.log
docker exec free5gc-cp tail -f /var/log/free5gc/smf.log

# List all available NF logs
docker exec free5gc-cp ls -la /var/log/free5gc/
```

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
| **Command** | `./run.sh` | `./run.sh --cp-only` |
| **Platform** | Linux (gtp5g required) | Mac, Linux, any OS |
| **Containers** | 4: db, cp, upf, ueransim | 3: db, cp, ueransim |
| **Registration** | Yes | Yes |
| **Authentication** | Yes | Yes |
| **PDU Session** | Yes | No (no UPF) |
| **Internet via UE** | Yes (`ping -I uesimtun0 8.8.8.8`) | No |
| **Use case** | Full end-to-end testing | Control plane study, SBI tracing |

---

## 7. File Reference

### Build Files

| File | What It Does |
|------|-------------|
| `Dockerfile.build-all` | Multi-stage builder: compiles free5GC (Go) + UERANSIM (C++) from source |
| `Dockerfile.cp-local` | Runtime image for Control Plane (ubuntu:22.04 + 8 NF binaries) |
| `Dockerfile.upf-local` | Runtime image for UPF (debian:bookworm-slim + upf binary) |
| `Dockerfile.ueransim-local` | Runtime image for UERANSIM (ubuntu:22.04 + nr-gnb/nr-ue/nr-cli) |
| `build.sh` | Orchestrates: source build → extract binaries → build runtime images |

### Run & Test Files

| File | What It Does |
|------|-------------|
| `docker-compose-portable.yaml` | 4-container deployment using locally-built images + debug configs |
| `run.sh` | Starts containers, provisions subscriber, shows status |
| `scripts/provision-subscriber.sh` | Creates subscriber via WebUI API + patches MongoDB |
| `scripts/trace-registration-flow.sh` | Captures cross-NF data flow during UE registration |

### Config & Output Directories

| Directory | What It Contains |
|-----------|-----------------|
| `config-debug/` | NF YAML configs with `level: debug` (10 files) |
| `config/` | Standard NF configs + gNB/UE configs |
| `cert/` | TLS certificates for NF-to-NF communication |
| `build-output/` | Extracted binaries (created by `build.sh`, not committed) |
| `logs/cp/` | CP NF log files mounted from container |
| `logs/upf/` | UPF log files mounted from container |

---

## 8. Troubleshooting

### Build Issues

**"go: module requires Go >= X.Y.Z"** - The Dockerfile uses `golang:latest` with `GOTOOLCHAIN=auto`, so it automatically downloads the required Go version. If this fails, rebuild with `docker build --no-cache`.

**UERANSIM CMake fails on ARM64** - The Dockerfile auto-detects architecture via `uname -m`. If it fails, check that Docker buildx is using the correct platform.

### Runtime Issues

**gNB "SCTP Connection refused"** - AMF's NGAP listener may not be ready yet. Restart UERANSIM:
```bash
docker restart ueransim
```

**Port 5000 conflict on macOS** - AirPlay uses port 5000. The provisioning script auto-detects macOS and uses port 5001. Or disable AirPlay: System Settings > General > AirDrop & Handoff.

**"CreateSmContextRequest Error: 500"** - Expected in CP-only mode. SMF can't reach UPF. Registration still succeeds.

**"Nil PermanentKey" from UDM** - Subscriber wasn't provisioned correctly. Re-run provisioning:
```bash
./scripts/provision-subscriber.sh imsi-208930000000001 20893
```

### Useful Commands

```bash
# Container status
docker compose -f docker-compose-portable.yaml ps

# Restart everything
./run.sh --down && ./run.sh --cp-only

# Check subscriber in MongoDB
docker exec mongodb mongo mongodb://localhost:27017/free5gc --quiet --eval \
  'db["subscriptionData.authenticationData.authenticationSubscription"].find({},{ueId:1,authenticationMethod:1}).pretty()'

# Check registered UEs in AMF
docker exec free5gc-cp grep "Registered" /var/log/free5gc/amf.log

# Follow all NF logs in real time
docker compose -f docker-compose-portable.yaml logs -f --tail 50
```
