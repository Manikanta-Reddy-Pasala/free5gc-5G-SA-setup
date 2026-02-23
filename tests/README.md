# free5GC Test Suite

Automated test scripts for validating the free5GC 5G SA core network using UERANSIM as the RAN/UE simulator.

## Prerequisites

- free5GC core must be running: `./free5gc.sh start`
- All 5 containers up: `mongodb`, `free5gc-cp`, `upf`, `webui`, `ueransim`

## Quick Start

```bash
# Run all 10 tests
./tests/run_all.sh

# Run specific tests
./tests/run_all.sh 1 4 10

# List available tests
./tests/run_all.sh --list
```

## Test Cases

| TC | Script | Description | Args |
|----|--------|-------------|------|
| 01 | `tc01_parallel_registration.sh` | Register multiple UEs simultaneously and verify all reach RM-REGISTERED | `[num_ues]` (default: 5) |
| 02 | `tc02_crash_recovery.sh` | Kill UPF, CP, and MongoDB one by one. Restart each and verify UE can re-register | - |
| 03 | `tc03_multi_apn.sh` | Provision UE with two DNNs (internet + ims), verify two PDU sessions and TUN interfaces | - |
| 04 | `tc04_multi_ue_deregistration.sh` | Register N UEs, deregister all at once, verify all reach RM-DEREGISTERED | `[num_ues]` (default: 3) |
| 05 | `tc05_paging_idle_ue.sh` | Register UE, wait for CM-IDLE, send downlink data to trigger paging | - |
| 06 | `tc06_ue_context_release.sh` | Test ungraceful (kill = RLF) and graceful (deregister) UE context release | - |
| 07 | `tc07_ran_config_update.sh` | Change TAC, restart CP + gNB, verify UE registers with new TAC, restore original | - |
| 08 | `tc08_ng_reset.sh` | Restart UERANSIM container and kill gNB process to simulate NG Reset, verify recovery | - |
| 09 | `tc09_warning_message.sh` | Send Write-Replace Warning Request via AMF API, check AMF/gNB logs for PWS handling | - |
| 10 | `tc10_memory_leak.sh` | Run register/deregister cycles, track container memory, report growth % | `[cycles] [num_ues]` (default: 10 3) |

## Running Individual Tests

```bash
# Parallel registration with 10 UEs
./tests/tc01_parallel_registration.sh 10

# Deregistration with 5 UEs
./tests/tc04_multi_ue_deregistration.sh 5

# Memory leak: 20 cycles, 5 UEs per cycle
./tests/tc10_memory_leak.sh 20 5
```

## How It Works

1. **common.sh** - Shared helpers used by all tests: WebUI login, subscriber provisioning, UE config generation, MongoDB patching
2. Each test script sources `common.sh`, ensures the core is running, then executes its test steps
3. Tests use `nr-cli` to interact with UERANSIM UEs (check status, deregister, list PDU sessions)
4. Results are printed as `PASS` / `FAIL` / `WARN` per step, with a summary at the end
5. `run_all.sh` runs tests sequentially and saves logs to `tests/logs/`

## Output

- Console: color-coded PASS/FAIL per step
- Logs: `tests/logs/tc<NN>_<name>_<timestamp>.log`
- Memory report (TC10): `tests/memory_report_<timestamp>.txt`

## Notes

- **TC03 (Multi-APN)**: Full dual-DNN support requires `ims` DNN added to `smfcfg.yaml` and `upfcfg.yaml` with its own IP pool. The test will show PARTIAL if only `internet` works.
- **TC05 (Paging)**: UERANSIM may not transition to CM-IDLE automatically. The test checks AMF logs for paging activity.
- **TC09 (Warning)**: free5GC v4.2 has limited PWS support. The test validates the API path exists.
- **TC10 (Memory)**: Growth > 20% flags as potential leak. Run with more cycles for reliable results.
