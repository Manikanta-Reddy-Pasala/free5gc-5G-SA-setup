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

**16 containers** running a complete 5G SA network with 2 network slices, subscriber management, and internet connectivity.

## Quick Start

### Option 1: Automated (One Command)

```bash
ssh root@your-server
git clone https://github.com/Manikanta-Reddy-Pasala/free5gc-5G-SA-setup.git
cd free5gc-5G-SA-setup
chmod +x setup-free5gc.sh
./setup-free5gc.sh install
```

This handles everything: Docker, GTP5G kernel module, services, subscriber provisioning, and testing.

### Option 2: Manual Setup

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

```bash
./setup-free5gc.sh status    # Check all services and UE status
./setup-free5gc.sh test      # Re-run registration and connectivity tests
./setup-free5gc.sh logs amf  # View AMF logs (replace 'amf' with any service)
./setup-free5gc.sh stop      # Stop all services
./setup-free5gc.sh start     # Start all services
./setup-free5gc.sh clean     # Stop and remove all data
```

### WebUI

- **URL**: `http://<server-ip>:5000`
- **Username**: `admin`
- **Password**: `free5gc`

## Important Notes

### SQN Fix for UERANSIM

UERANSIM starts with internal sequence number (SQN) = 0. The default subscriber SQN in free5GC (`16f3b3f70fc2`) is too large, causing "SQN out of range" authentication failures. The setup script automatically fixes this by setting SQN to `000000000020`.

### Prerequisites

- Ubuntu 22.04 LTS (Kernel 5.4+)
- CPU with AVX support (for MongoDB 4.4+)
- 4 GB RAM minimum, 8 GB recommended
- Root access

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

## References

- [free5GC Project](https://github.com/free5gc/free5gc) - Open source 5G core network
- [free5GC Documentation](https://free5gc.org/guide/) - Official guides
- [UERANSIM](https://github.com/aligungr/UERANSIM) - Open source 5G UE and RAN simulator
- [GTP5G](https://github.com/free5gc/gtp5g) - Linux kernel module for GTP-U
- [3GPP TS 23.501](https://www.3gpp.org/DynaReport/23501.htm) - 5G System Architecture specification

## License

This project is forked from [free5gc/free5gc-compose](https://github.com/free5gc/free5gc-compose). See [LICENSE.txt](LICENSE.txt).
