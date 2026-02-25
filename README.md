# 5G SA Core Network Setup with free5GC & UERANSIM

A complete, beginner-friendly setup of a **5G Standalone (SA) core network** using [free5GC](https://github.com/free5gc/free5gc) v4.2.0 with [UERANSIM](https://github.com/aligungr/UERANSIM) v3.2.7 for RAN/UE simulation, all running via Docker Compose.

> **New to 5G?** Start with the [5G SA Fundamentals Guide](docs/01-5G-SA-FUNDAMENTALS.md) - it explains every component with real-world analogies.

## What's Inside

```
Your Phone (UE)          5G Base Station (gNB)        5G Core Network
┌───────────┐           ┌───────────────┐          ┌──────────────────────┐
│ UERANSIM  │──(radio)──│  UERANSIM     │──(N2)──> │ AMF  AUSF  UDM  UDR │
│ UE        │           │  gNB          │──(N3)──> │ SMF  PCF   NRF  NSSF│
└───────────┘           └───────────────┘          │ UPF                 │
                                                   └──────────┬───────────┘
                                                              │ (N6)
                                                         ┌────┴────┐
                                                         │ Internet │
                                                         └─────────┘
```

**4 core containers** (MongoDB, Control Plane, UPF, WebUI) + optional **UERANSIM** simulator for testing.

## Quick Start

Only needs Docker - no Go, GCC, or CMake on host. Works on Mac (Apple Silicon/Intel), Linux, or any OS.

```bash
git clone https://github.com/Manikanta-Reddy-Pasala/free5gc-5G-SA-setup.git
cd free5gc-5G-SA-setup
./free5gc.sh build            # Compile all NFs from source (~15 min first time)
./free5gc.sh start            # Start core only (MongoDB, CP, UPF, WebUI)
./free5gc.sh start --ueransim # Start core + UERANSIM simulator
./free5gc.sh start --ueransim --mcc 404 --mnc 30 --tac 1  # With custom PLMN
./free5gc.sh provision        # Provision default subscriber in MongoDB
./free5gc.sh bulk-provision --count 10  # Provision 10 subscribers (SUPI+KEY auto-increment)
./free5gc.sh ue start         # Launch UE, establish PDU session, setup data plane
./free5gc.sh ue status        # Check UE connectivity
./free5gc.sh stop             # Stop all containers
./free5gc.sh remove           # Remove all containers and volumes
```

**WebUI** for subscriber management:
- **URL**: `http://<server-ip>:4000`
- **Login**: `admin` / `free5gc`

**AMF Health Check** — raw TCP on port `50051`. Returns a proto-encoded `HealthCheckResponse`. No gRPC/HTTP2 required:

```bash
# Quick check — connect and read 3 bytes (020801 = SERVING)
python3 -c "
import socket
s = socket.socket(); s.connect(('<server-ip>', 50051)); s.settimeout(1)
data = s.recv(64); s.close()
# decode varint length prefix
idx, shift, length = 0, 0, 0
while True:
    b = data[idx]; idx += 1
    length |= (b & 0x7F) << shift
    if b < 0x80: break
    shift += 7
pb = data[idx:idx+length]
print('SERVING' if pb == b'\x08\x01' else 'NOT_SERVING' if pb == b'\x08\x02' else pb.hex())
"

# Or just check the raw bytes directly
python3 -c "import socket; s=socket.socket(); s.connect(('<server-ip>',50051)); s.settimeout(1); print(s.recv(64).hex()); s.close()"
# 020801  →  02=length(2)  08 01=HealthCheckResponse{status:SERVING}
```

Wire format: `[varint:length][proto HealthCheckResponse]`. If the client sends nothing within 500ms, the server responds anyway — compatible with simple k8s TCP liveness probes.

### All Commands

```bash
./free5gc.sh build                # Compile all NFs from source (~15 min)
./free5gc.sh build --quick        # Rebuild runtime images only (skip source compile)
./free5gc.sh start                # Start core only (MongoDB, CP, UPF, WebUI)
./free5gc.sh start --ueransim     # Start core + UERANSIM gNB simulator
./free5gc.sh start --ueransim --mcc 404 --mnc 30 --tac 1  # With custom PLMN/TAC
./free5gc.sh start --debug        # Start with debug-level logging
./free5gc.sh start --ueransim --debug  # UERANSIM + debug logging
./free5gc.sh provision            # Provision default subscriber in MongoDB
./free5gc.sh bulk-provision --count 10                    # Provision 10 subscribers
./free5gc.sh bulk-provision --supi 001010123456789 \
    --key 00112233445566778899aabbccddeeff \
    --opc 000102030405060708090a0b0c0d0e0f --count 5     # Custom SUPI/KEY/OPC
./free5gc.sh ue start             # Launch UE + setup data plane (requires --ueransim)
./free5gc.sh ue stop              # Stop UE + cleanup routes
./free5gc.sh ue status            # Check UE connectivity
./free5gc.sh capture start [name] # Start pcap capture (bridge + SBI)
./free5gc.sh capture stop         # Stop capture, merge and save pcap
./free5gc.sh stop                 # Stop all containers
./free5gc.sh remove               # Remove all containers and volumes
./free5gc.sh status               # Show container status
./free5gc.sh logs [nf]            # Tail logs (all or specific: amf, smf, etc.)
```

### Custom PLMN / TAC

Pass `--mcc`, `--mnc`, `--tac` to configure the network identity at startup. The script updates all config files (AMF, SMF, NRF, NSSF, gNB, UE) automatically:

```bash
./free5gc.sh start --mcc 404 --mnc 30 --tac 1                # Indian operator (core only)
./free5gc.sh start --ueransim --mcc 310 --mnc 560 --tac 50   # US operator + simulator
./free5gc.sh start --ueransim --debug                         # Simulator + debug logging
```

| Option | Description | Default |
|--------|-------------|---------|
| `--ueransim` | Include UERANSIM gNB/UE simulator | not started |
| `--mcc` | Mobile Country Code (3 digits) | 001 |
| `--mnc` | Mobile Network Code (2-3 digits) | 01 |
| `--tac` | Tracking Area Code (decimal) | 1 |
| `--debug` | Enable debug-level logging | off |

### Bulk Provisioning

Provision multiple subscribers at once. SUPI auto-increments by +1 for each UE. KEY can auto-increment or stay the same (`--same-key`):

```bash
./free5gc.sh bulk-provision --count 10    # 10 UEs, SUPI+KEY auto-increment
./free5gc.sh bulk-provision --count 64 --same-key   # 64 UEs, same KEY for all
./free5gc.sh bulk-provision --supi 001010000050641 --key 0C57E15A2CB86087097A6B50D42531DE --opc 109EE52735AE6D3849112CF4175029C7 --count 64 --same-key
```

| Option | Description | Default |
|--------|-------------|---------|
| `--supi` | Starting SUPI (digits only, no `imsi-` prefix) | 001010123456789 |
| `--key` | Starting K (32 hex chars) | 00112233445566778899aabbccddeeff |
| `--opc` | OPC, same for all UEs (32 hex chars) | 000102030405060708090a0b0c0d0e0f |
| `--count` | Number of UEs to provision | 1 |
| `--same-key` | Use same K for all UEs (don't increment) | off (key increments) |

Example with `--count 3` starting from SUPI `001010123456789`:
| UE | SUPI | KEY |
|----|------|-----|
| 1 | imsi-001010123456789 | 00112233445566778899aabbccddeeff |
| 2 | imsi-001010123456790 | 00112233445566778899aabbccddef00 |
| 3 | imsi-001010123456791 | 00112233445566778899aabbccddef01 |

### Debug Mode

Start with `--debug` to enable debug-level logging for all NFs:

```bash
./free5gc.sh start --debug        # Uses config-debug/ (logger level: debug)
./free5gc.sh start                # Uses config/ (logger level: info)
```

The `--debug` flag switches NF configs from `config/` to `config-debug/`, which has `logger.level: debug` for all NFs. This produces verbose per-message logs useful for troubleshooting registration, authentication, and PDU session issues.

### Debugging Inside Containers

The CP container includes network debugging tools (`tcpdump`, `ip`, `ss`, `ping`, `netstat`):

```bash
# Check SCTP listeners (AMF NGAP)
docker exec free5gc-cp ss -Slnp

# Check IP addresses and routing
docker exec free5gc-cp ip addr
docker exec free5gc-cp ip route

# Check all listening ports
docker exec free5gc-cp netstat -tlnp

# Capture traffic inside CP container
docker exec free5gc-cp tcpdump -i lo -n port 8000

# Ping between containers
docker exec free5gc-cp ping -c 3 upf.free5gc.org

# Inspect container network from host (using nsenter)
PID=$(docker inspect --format '{{.State.Pid}}' free5gc-cp)
nsenter -t $PID -n ss -Slnp          # SCTP listeners
nsenter -t $PID -n ip addr            # IP addresses
nsenter -t $PID -n tcpdump -i lo -c 10  # Quick packet capture
```

### Packet Capture

Capture NGAP, PFCP, GTP-U, and SBI traffic:

```bash
./free5gc.sh capture start my-test    # Start capture
# ... run your test / trigger UE registration ...
./free5gc.sh capture stop             # Stop, merge, and save pcap
```

Pcap files are saved to `logs/pcap-traces/`. Download and open in Wireshark:

```bash
scp root@<server-ip>:$(pwd)/logs/pcap-traces/my-test.pcap .
```

### View NF Logs

```bash
./free5gc.sh logs                     # All container logs
./free5gc.sh logs amf                 # AMF only (from /var/log/free5gc/amf.log)
./free5gc.sh logs smf                 # SMF only
./free5gc.sh logs upf                 # UPF container logs
./free5gc.sh logs ueransim            # UERANSIM container logs
```

Available NF log targets: `amf`, `ausf`, `udm`, `udr`, `smf`, `nrf`, `nssf`, `pcf`, `upf`, `ueransim`

---

## Container Architecture

```
DEPLOYMENT: 4 core containers + 1 optional
┌──────────────────────────────────────────────┐
│  mongodb                                     │  Database
│  free5gc-cp (NRF+AMF+AUSF+UDM+UDR+          │  All 8 CP NFs in 1 container
│              SMF+NSSF+PCF)                   │
│  upf                                         │  User plane (needs GTP5G)
│  webui                                       │  Browser-based management (port 4000)
├──────────────────────────────────────────────┤
│  ueransim (optional, --ueransim flag)        │  gNB + UE simulator
└──────────────────────────────────────────────┘
```

### Network Functions

| Container | Network Function | Role |
|-----------|-----------------|------|
| `free5gc-cp` | NRF, AMF, AUSF, UDM, UDR, SMF, NSSF, PCF | All control plane NFs consolidated |
| `upf` | User Plane Function | Routes all user data |
| `webui` | Web Console | Subscriber management UI |
| `mongodb` | Database | Subscriber and config storage |
| `ueransim` | gNB + UE Simulator | Simulates base station and phone (optional, `--ueransim`) |

### SBI Ports (inside free5gc-cp)

| NF | Port |
|----|------|
| NRF | 8000 |
| UDR | 8001 |
| UDM | 8002 |
| AUSF | 8003 |
| NSSF | 8004 |
| PCF | 8005 |
| AMF | 8006 |
| AMF TCP health | 50051 |
| SMF | 8007 |

### Network Configuration

| Network | Subnet/Port | Purpose |
|---------|------------|---------|
| Docker bridge | 10.100.200.0/24 | Internal NF communication |
| free5gc-cp | 10.100.200.16 | AMF NGAP + all SBI endpoints |
| NGAP | SCTP 38412 | gNB ↔ AMF control plane |
| GTP-U | UDP 2152 | gNB ↔ UPF user data |
| WebUI | TCP 4000 | Admin web interface |
| AMF TCP health | TCP 50051 | Proto health check (SERVING/NOT_SERVING) |

### SCTP Forwarding

Docker cannot proxy SCTP natively. The script automatically sets up iptables DNAT rules during `./free5gc.sh start` to forward host SCTP port 38412 to the AMF container (10.100.200.16). This is required for real gNB connectivity. Rules are cleaned up on `./free5gc.sh stop`. Use `./free5gc.sh remove` to also remove containers and volumes.

---

## Configuration

### Config Directories

| Directory | Logger Level | Use Case |
|-----------|-------------|----------|
| `config/` | info | Normal operation, production |
| `config-debug/` | debug | Troubleshooting, development |

Both directories contain the same NF configs with different logging levels. The `--debug` flag on `start` selects which directory to use.

### Current Network Parameters

| Parameter | Value |
|-----------|-------|
| PLMN (MCC/MNC) | 001/01 |
| TAC | 000001 |
| S-NSSAI | SST=3, SD=198153 |
| DNN | internet |

### Subscriber Configuration

Provision subscribers via WebUI at `http://<server-ip>:4000`. These values must match between the UE config (`config/uecfg.yaml`) and the subscriber database:

| Parameter | Value |
|-----------|-------|
| IMSI | 001010000050641 |
| MCC/MNC | 001/01 |
| K (Permanent Key) | 0c57e15a2cb86087097a6b50d42531de |
| OPC (Operator Code) | 109ee52735ae6d3849112cf4175029c7 |
| AMF | 8000 |
| Auth Method | 5G_AKA |

### Key Config Files

| File | Controls |
|------|----------|
| `config/amfcfg.yaml` | PLMN, NGAP, slices, security, NRF URI |
| `config/smfcfg.yaml` | UE IP pools, UPF address, DNS, DNN |
| `config/upfcfg.yaml` | GTP-U, PFCP, DNN routing |
| `config/nrfcfg.yaml` | MongoDB URI, SBI listen, PLMN |
| `config/gnbcfg.yaml` | MCC/MNC, gNB ID, TAC, AMF address |
| `config/uecfg.yaml` | IMSI, K, OPC, sessions, slices |
| `config/webuicfg.yaml` | Web server port (4000) |

---

## Connecting Real Equipment

Once the 5G core is verified with UERANSIM, you can connect real gNBs (srsRAN, OAI, commercial).

### Required gNB Parameters

| Parameter | Value |
|-----------|-------|
| AMF IP | Your server's IP |
| AMF SCTP Port | 38412 |
| MCC | 001 |
| MNC | 01 |
| TAC | 1 |
| S-NSSAI | SST=3, SD=198153 |

### Verify gNB Connection

```bash
./free5gc.sh logs amf    # Look for "NG Setup procedure is successful"
```

### Network Routing

```bash
# Ensure IP forwarding
sysctl -w net.ipv4.ip_forward=1

# NAT for UE traffic (if UPF is in Docker)
iptables -t nat -A POSTROUTING -s 10.60.0.0/16 -j MASQUERADE

# Firewall rules
iptables -A INPUT -p sctp --dport 38412 -j ACCEPT   # N2 NGAP
iptables -A INPUT -p udp --dport 2152 -j ACCEPT      # N3 GTP-U
```

---

## WebUI

- **URL**: `http://<server-ip>:4000`
- **Username**: `admin`
- **Password**: `free5gc`

Use the WebUI to add, edit, and delete subscribers. Each subscriber needs matching IMSI, K, OPC, and slice configuration.

---

## Test Suite

Automated test scripts in `tests/` covering 10 test cases:

```bash
./tests/run_all.sh              # Run all 10 tests
./tests/run_all.sh 1 3 5        # Run specific tests (TC01, TC03, TC05)
./tests/run_all.sh --list       # List available tests
```

| TC | Script | Description |
|----|--------|-------------|
| 01 | `tc01_parallel_registration.sh` | Parallel registration of multiple UEs |
| 02 | `tc02_crash_recovery.sh` | Component crash (CP/UPF/MongoDB) and recovery |
| 03 | `tc03_multi_apn.sh` | Two APNs (internet + ims) per UE |
| 04 | `tc04_multi_ue_deregistration.sh` | Simultaneous deregistration of multiple UEs |
| 05 | `tc05_paging_idle_ue.sh` | Paging idle UE with downlink data |
| 06 | `tc06_ue_context_release.sh` | UE context release (RLF + graceful) |
| 07 | `tc07_ran_config_update.sh` | RAN config update (TAC change) |
| 08 | `tc08_ng_reset.sh` | NG Reset (SCTP association restart) |
| 09 | `tc09_warning_message.sh` | PWS/CMAS warning message transmission |
| 10 | `tc10_memory_leak.sh` | Memory leak detection across reg/dereg cycles |

Individual tests can be run directly:
```bash
./tests/tc01_parallel_registration.sh 10    # 10 UEs (default: 5)
./tests/tc10_memory_leak.sh 20 5            # 20 cycles, 5 UEs per cycle
```

---

## Documentation

| Document | Description |
|----------|-------------|
| [5G SA Fundamentals](docs/01-5G-SA-FUNDAMENTALS.md) | Every component explained with diagrams |
| [Setup Guide](docs/02-SETUP-GUIDE.md) | Step-by-step installation |
| [Testing Guide](docs/03-TESTING-GUIDE.md) | Tests to verify your network |
| [Consolidated Deployment](docs/07-CONSOLIDATED-DEPLOYMENT.md) | 4-container architecture |
| [5G Procedures & NF Roles](docs/09-5G-PROCEDURES-AND-NF-ROLES.md) | Attach, Auth, PDU Session flows |
| [Portable Build & Trace](docs/10-PORTABLE-BUILD-AND-TRACE.md) | Build from source, run modes |

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues and fixes.

## References

- [free5GC Project](https://github.com/free5gc/free5gc) - Open source 5G core network
- [UERANSIM](https://github.com/aligungr/UERANSIM) - Open source 5G UE and RAN simulator
- [GTP5G](https://github.com/free5gc/gtp5g) - Linux kernel module for GTP-U
- [3GPP TS 23.501](https://www.3gpp.org/DynaReport/23501.htm) - 5G System Architecture
- [srsRAN Project](https://www.srsran.com/) - Open source 5G RAN

## License

This project is forked from [free5gc/free5gc-compose](https://github.com/free5gc/free5gc-compose). See [LICENSE.txt](LICENSE.txt).
