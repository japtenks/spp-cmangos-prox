# vMaNGOS Build Control

## Mission

This document is the living control sheet for stabilizing the `ileboii/core` fork on branch `vmangos-ike3-playerbots` and aligning that work with the `spp-cmangos-prox` launcher flow.

The effort is both a practical build/debug stream and a chance to help shape the direction of a new fork. Future agents should treat this file as the primary handoff artifact for the vMaNGOS workstream.

## Official Workflow

Status: `Confirmed`

The official workflow for this effort is:

- `Windows host` for operator workflow and repo management
- `Debian 13 WSL` for direct Linux build/debug work
- `Proxmox/LXC` for launcher validation and deployment

This environment choice is locked unless a hard blocker is found.

Why Debian 13 WSL is the preferred build/debug path:

- It gives Linux-native behavior instead of Windows compatibility shortcuts.
- It closely matches the Proxmox target environment.
- It is faster to iterate in than debugging only through Proxmox host/container flows.
- It has already reproduced the real Linux-side issues found in this fork.

`Nix` is out of scope for now and is not the current preferred path. The current blockers are source/build portability issues, not an unsolved package-management problem.

## End Goal

Status: `In progress`

Success means all of the following are true:

- A Debian 13 WSL test build of `vmangos-ike3-playerbots` succeeds reliably.
- The launcher vmangos test-build/install flow reflects the working fixes.
- Proxmox validation succeeds for the `spp-vmangos` container workflow.
- Future agents can continue this work without needing prior chat history.

## Current State

Status: `Confirmed`

- Host operator environment is Windows.
- `Debian GNU/Linux 13 (trixie)` is installed and validated in WSL2.
- Ubuntu 24.04 WSL is also present, but Debian 13 WSL is the primary vmangos build/debug environment.
- The vmangos target repo is `https://github.com/ileboii/core.git`.
- The vmangos target branch is `vmangos-ike3-playerbots`.
- The Debian 13 WSL workspace is `/root/src/vmangos-core`.
- The Windows launcher repo path is `C:\Git\spp-cmangos-prox`.
- Proxmox `pct` operations remain target-side only, so direct launcher execution still belongs on the Proxmox host.

## Confirmed Findings

Status: `Confirmed`

- The launcher vmangos source/branch pairing needed correction because the desired branch lives on `ileboii/core`, not the old upstream repo target.
- Linux case sensitivity is a real blocker in this fork: the repo contains `src/game/PlayerBots` while CMake requests `src/game/Playerbots`.
- MariaDB/MySQL compatibility handling in `src/shared/Database/DatabaseMysql.h` is relevant to this fork on modern Linux toolchains.
- Windows-only `_strnicmp` usage in PlayerBots sources breaks Linux compilation.
- Debian 13 WSL reproduces the same meaningful Linux-side build issues seen in the Proxmox path, so it is a valid debugging environment.

## Working Decisions

Status: `Confirmed`

- Use Debian 13 WSL as the primary build/debug path.
- Use Proxmox/LXC as the final launcher/runtime validation target.
- Do not switch to Nix at this stage.
- Prioritize source compatibility fixes over environment churn.
- Port stable, validated fixes back into launcher automation after they are proven in Debian 13 WSL.
- Keep this document scoped to the vMaNGOS fork effort rather than expanding it into a launcher-wide or monorepo-wide tracker.

## Open Blockers

Status: `Blocked`

### Case-sensitive PlayerBots path mismatch

- Observed symptom: CMake fails because `add_subdirectory(Playerbots)` does not resolve on Linux.
- Current hypothesis: the fork was developed with Windows-tolerant casing assumptions.
- Next action: normalize the source tree or patch the CMake expectation in the Debian 13 WSL test workspace, then port the durable fix into launcher automation.

### Windows-only string compare usage

- Observed symptom: vmangos build fails in `PlayerbotAI.cpp` because `_strnicmp` is not defined on Linux.
- Current hypothesis: the fork contains Windows-specific string helpers that were not normalized to the portable aliases already used elsewhere in the codebase.
- Next action: patch Linux portability in the WSL workspace, rerun the build, and then reflect the same fix in the launcher workflow if the source remains unchanged upstream.

### Additional Linux portability issues likely to follow

- Observed symptom: current evidence shows this new fork compiles with many warnings and has already exposed multiple Linux-only breakpoints.
- Current hypothesis: more portability issues are likely once the current blockers are removed.
- Next action: continue iterative Debian 13 WSL build-debug cycles and record only confirmed blockers here.

## Master/Sub-Agent Use

Status: `Confirmed`

Use the routine in [Master-Sub-Agent-Routine.md](C:/Git/Master-Sub-Agent-Routine.md) whenever this work expands into multiple parallel bug streams.

Master-agent ownership for this vmangos effort:

- keep source-of-truth decisions stable
- prioritize blockers and choose the next lane of work
- review sub-agent findings and fixes
- integrate final changes
- run final validation before code is considered done

Likely sub-agent bug lanes for this fork:

- Linux build portability
- dependency/compiler compatibility
- launcher automation parity
- runtime/install validation

Use the master/sub-agent split when:

- more than one active blocker can be worked independently
- launcher changes and source-level fixes need parallel attention
- bug volume grows enough that one coordinating agent should own final integration

## Next Actions

Status: `Next`

1. Reproduce the current blocker in Debian 13 WSL.
2. Fix the current source/build issue in the WSL workspace.
3. Rerun the local Debian build.
4. Reflect the durable fix into the launcher flow.
5. Validate the equivalent behavior on Proxmox/LXC.
6. Commit once the build path is stable.

## Handoff Notes

Status: `Confirmed`

- Windows launcher repo path: `C:\Git\spp-cmangos-prox`
- Debian 13 WSL vmangos workspace: `/root/src/vmangos-core`
- Use Debian 13 WSL for direct Linux build/debug, not Windows shell assumptions.
- Use Proxmox only for target validation and launcher-runtime confirmation.
- Most useful logs to capture next:
  - first `error:` line from the Debian 13 WSL build
  - final `make: ***` lines if the build stops
  - any CMake configure failure block
- Treat Linux case sensitivity and Linux portability issues as first-class concerns; do not assume Windows path behavior is safe.
