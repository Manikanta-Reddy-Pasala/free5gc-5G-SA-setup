# UE Simulation Test Script

## Overview

`scripts/ue-simulation-test.sh` is a comprehensive test script that simulates and validates three key 5G NAS (Non-Access Stratum) procedures against a free5GC v4.2.0 core network using UERANSIM v3.2.7.

## Test Scenarios

### Test 1: Attach (Registration) of 16 UEs
- Provisions 16 subscribers in MongoDB with full 5G-AKA credentials
- Launches 16 UEs via UERANSIM's multi-UE mode (`nr-ue -n 16`)
- Verifies successful registration by checking gNB logs for:
  - `RRC Setup for UE[N]` - Radio layer connection established
  - `Initial Context Setup Request received` - AMF accepted registration
  - `PDU session resource(s) setup for UE[N]` - Data plane established (2 per UE, one per network slice)
- **Pass criteria**: All 16 UEs get Initial Context Setup and PDU sessions

### Test 2: Rejection of 200 UEs (Unprovisioned)
- Ensures 200 IMSI numbers (5001-5200) have NO subscription data in MongoDB
- Launches 200 UEs in 4 batches of 50
- Verifies rejection by checking:
  - gNB logs show RRC connection attempts but **zero** `Initial Context Setup` events
  - Core NF logs show authentication failures / subscriber not found errors
- **Pass criteria**: 0 unprovisioned UEs receive Initial Context Setup (all rejected)

### Test 3: Identification of 100 UEs
- Provisions 100 subscribers (IMSI 1001-1100) with full credentials
- Launches 100 UEs in 2 batches of 50
- Verifies identification by checking:
  - `RRC Setup` events (radio-level UE identification)
  - `Initial NAS message received` (NAS-level identity exchange)
  - `Initial Context Setup Request received` (AMF completed SUPI identification + authentication)
  - PDU session establishment (end-to-end identity verified)
- **Pass criteria**: >= 80% of UEs successfully identified and registered

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌────────────────────────┐     ┌──────────┐
│  Test Script │────>│   UERANSIM   │────>│     free5GC CP         │────>│ MongoDB  │
│  (Host)      │     │  (gNB + UEs) │     │ (AMF+AUSF+UDM+UDR+    │     │          │
│              │     │              │     │  SMF+NRF+NSSF+PCF)     │     │          │
└─────────────┘     └──────────────┘     └────────────────────────┘     └──────────┘
                           │                        │
                           │ N3 (GTP-U)             │
                           ▼                        │
                    ┌──────────────┐                │
                    │     UPF      │                │
                    │ (User Plane) │                │
                    └──────────────┘                │
```

## IMSI Ranges

| Test | IMSI Range | Count | Provisioned? |
|------|-----------|-------|-------------|
| Attach | imsi-208930000000001 to 016 | 16 | Yes |
| Reject | imsi-208930000005001 to 5200 | 200 | No |
| Identify | imsi-208930000001001 to 1100 | 100 | Yes |

## 5G Network Parameters

| Parameter | Value |
|-----------|-------|
| MCC | 208 |
| MNC | 93 |
| PLMN | 20893 |
| Key (K) | 8baf473f2f8fd09487cccbd7097c6862 |
| OPc | 8e27b6af0e692e750f32667a3b14605d |
| Auth Method | 5G-AKA |
| Network Slices | SST:1/SD:010203, SST:1/SD:112233 |
| DNN | internet |

## Prerequisites

- free5GC core running in Docker (mongodb, free5gc-cp, upf containers)
- UERANSIM container running with gNB connected to AMF
- Script must run on the free5GC host machine (not remotely)

## Usage

```bash
cd /root/free5gc-5G-SA-setup
./scripts/ue-simulation-test.sh
```

## Output

- Real-time colored output to stdout
- Full log saved to `/root/ue-simulation-results.log`
- Exit code 0 = all tests passed, 1 = failures

## Configuration

Timing and batch parameters can be adjusted at the top of the script:

```bash
UE_SPAWN_DELAY_MS=100   # Delay between UE spawns (ms)
SETTLE_TIME=20          # Wait time for procedures to complete (s)
PROVISION_BATCH=10      # MongoDB provisioning parallelism
```

## Cleanup

The script automatically cleans up after itself:
- Kills all nr-ue processes between tests
- Removes all test subscriber data from MongoDB (preserves imsi-208930000000001)

## Sample Output

```
================================================================
  TEST SUMMARY
================================================================

  Total Tests:  12
  Passed:       12
  Failed:       0

  ========================================
    ALL TESTS PASSED
  ========================================
```
