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
- The current tested vmangos branch head is `dbc360623b53a4d6bec1db9034bf54008715b152`.
- The Windows launcher repo path is `C:\Git\spp-cmangos-prox`.
- Proxmox `pct` operations remain target-side only, so direct launcher execution still belongs on the Proxmox host.
- A Debian 13 WSL full build now succeeds locally after source/CMake portability fixes in the vmangos workspace.
- The intended Proxmox host for this lane is `ser8`; an exploratory target-side validation was accidentally run on `m1pro` first.
- A launcher-managed vmangos core rebuild/install has now completed successfully on `ser8`, including install into `/srv/vmangos` and config deployment.
- For runtime validation that does not use a launcher-managed DB container, the operator-provided external DB endpoint is `192.168.1.47:3306` with `mangos` / `mangos`.
- The launcher now supports vmangos-specific external DB targeting through `VMANGOS_DB_HOST` and `VMANGOS_DB_PORT` in `config.env`, with fallback to the DB CT only when those are unset.
- The launcher also supports `VMANGOS_WORLD_DB_URL` in `config.env`; when no staged vmangos world asset exists yet, the vmangos world installer can download the configured archive into `/opt/spp-assets/vmangos/sql/` automatically.
- The launcher vmangos data install path now auto-seeds `/opt/spp-assets/vmangos/data/` from `/opt/spp-assets/vanilla/data/` when no dedicated vmangos asset pack exists locally, then validates `dbc`, `maps`, `vmaps`, and `mmaps` before copying into `/srv/vmangos/data/`.

## Confirmed Findings

Status: `Confirmed`

- The launcher vmangos source/branch pairing needed correction because the desired branch lives on `ileboii/core`, not the old upstream repo target.
- Linux case sensitivity is a real blocker in this fork: the repo contains `src/game/PlayerBots` while CMake requests `src/game/Playerbots`.
- MariaDB/MySQL compatibility handling in `src/shared/Database/DatabaseMysql.h` is relevant to this fork on modern Linux toolchains.
- Windows-only `_strnicmp` usage in PlayerBots sources breaks Linux compilation.
- Debian 13 WSL reproduces the same meaningful Linux-side build issues seen in the Proxmox path, so it is a valid debugging environment.
- The vmangos fork branch is a small fork layer over upstream `development`, not a large unrelated codebase:
  - merge-base with upstream `development`: `8c9bcf6ee795a16fa5b53e55aa94b07396b48adc`
  - fork branch ahead of base: `12` commits
  - upstream ahead after fetch: `1` commit
- The reproduced Linux blocker chain on Debian 13 WSL was:
  - Linux case-sensitive `PlayerBots` vs `Playerbots` CMake path mismatch
  - Windows-only `_strnicmp` usage in PlayerBots sources
  - several fork-port typos/stub breakpoints in PlayerBots (`const const`, outdated constructor call, `!nullptr` placeholders)
  - Unix link failure in `mangosd` from stray `-lzlib`
- A durable Unix-side CMake compatibility fix is to provide a `zlib` compatibility target that forwards to `ZLIB::ZLIB`, so leaked bare `zlib` links do not become `-lzlib` on Linux.
- The launcher's original vmangos inline patch helpers were too narrow for a fresh-clone Linux build. A deterministic patch-stack approach is more reliable than accumulating ad hoc `perl` edits.
- The launcher vmangos DB install/config path also needed external-DB support; vmangos now resolves DB host/port from `VMANGOS_DB_HOST` / `VMANGOS_DB_PORT` before falling back to `DB_CTID`.
- Per the upstream setup guide, the vMaNGOS world DB is not seeded from the core repo alone; it comes from a separate world database release, then receives repo-side `sql/migrations/*_world.sql` updates.
- On `m1pro`, there was no pre-existing launcher checkout or vmangos container to reuse; the target-side validation path started from a fresh Debian 13 LXC.
- A temporary Debian 13 LXC on `m1pro` (`CT 490`, hostname `spp-vmangos-test`) successfully configured and then built `mangosd` and `realmd` from a fresh clone when the exact WSL fix set was applied.
- The `m1pro` validation is useful proof that the fix set works in Proxmox/LXC, but `ser8` remains the intended host for continued operator-driven validation.

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

### Launcher workflow parity now proven for core build/install

- Observed symptom: the updated launcher-managed vmangos flow now completes the core build/install path on `ser8`.
- Current hypothesis: remaining parity work is now in DB/data/runtime handling rather than source compilation.
- Next action: keep the launcher source/patch flow as-is and focus follow-up changes on vmangos database/data staging.

### Proxmox/LXC validation still pending

- Observed symptom: the launcher-managed core install now succeeds on `ser8`, but vmangos DB install failed because the launcher only looked for `/opt/spp-assets/vmangos/sql/world.sql` or `world.7z`.
- Current hypothesis: `ser8` needs a staged vMaNGOS world database release from the separate database repo, and the launcher should accept broader release naming such as `world_full_*.7z` before applying repo migrations.
- Next action: update the launcher vmangos world installer to accept staged world release archives/files with vmangos-style naming, then rerun DB/runtime validation against the external DB host.

### MariaDB/MySQL compatibility warning still needs separate review

- Observed symptom: builds still emit the existing `DatabaseMysql.h` warning about an incompatible mysql version.
- Current hypothesis: this warning is not blocking the Linux build, but the compatibility handling remains worth auditing separately on modern Debian/Proxmox targets.
- Next action: treat this as a follow-up compatibility lane rather than a blocker now that the full WSL build succeeds.

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

1. Record the confirmed WSL success path and exact fix set in this control doc.
2. Reflect any durable build assumptions needed by the launcher vmangos flow.
3. Update the vmangos DB installer to accept a staged external world DB release and apply repo-side `*_world.sql` migrations after import.
4. Set `VMANGOS_DB_HOST` / `VMANGOS_DB_PORT` in `config.env` when using the external DB host instead of a DB CT.
5. Validate DB import on `ser8` against the intended DB target (`192.168.1.47:3306`).
6. Validate runtime basics after DB/data install succeeds.
7. Decide whether any fork fixes should be upstreamed or preserved as a local patch stack.
8. Revisit non-blocking compatibility warnings such as the MariaDB/MySQL guard once build/install parity is stable.

## Handoff Notes

Status: `Confirmed`

- Windows launcher repo path: `C:\Git\spp-cmangos-prox`
- Debian 13 WSL vmangos workspace: `/root/src/vmangos-core`
- Use Debian 13 WSL for direct Linux build/debug, not Windows shell assumptions.
- Use Proxmox only for target validation and launcher-runtime confirmation.
- Intended Proxmox host going forward: `ser8`
- `m1pro` already has a temporary proof container: `CT 490` / `spp-vmangos-test` with a successful vmangos binary build and current sizing of `4 vCPU`, `8 GiB RAM`, `16 GiB rootfs`.
- New launcher vmangos external DB keys:
  - `VMANGOS_DB_HOST`
  - `VMANGOS_DB_PORT`
  - `VMANGOS_WORLD_DB_URL`
- Most useful logs to capture next:
  - first `ser8` target-side DB import failure, including which vmangos world asset name/path was staged
  - whether the vmangos data install seeded from local Classic assets or used a dedicated vmangos data pack
  - any runtime/load errors after successful install against the chosen DB target
- Next-agent handoff focus:
  - treat the `ser8` core build/install as confirmed green
  - set `VMANGOS_DB_HOST="192.168.1.47"` and `VMANGOS_DB_PORT="3306"` in `config.env` if not already set
  - ensure `/opt/spp-assets/vmangos/sql/` contains a staged vMaNGOS world DB release from the separate database repo
  - run vmangos DB install/runtime validation against the external DB host
  - record exact commands, failures, and runtime observations back into this file
- Treat Linux case sensitivity and Linux portability issues as first-class concerns; do not assume Windows path behavior is safe.
- Preserve the distinction between:
  - true Linux portability fixes
  - obvious fork-port typos
  - intentional vMaNGOS stubs where CMaNGOS bot subsystems do not exist yet
