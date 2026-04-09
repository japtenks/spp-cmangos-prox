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
- The launcher vmangos data install path now auto-seeds `/opt/spp-assets/vmangos/data/` from `/opt/spp-assets/vanilla/data/` when no dedicated vmangos asset pack exists locally; if neither exists, it downloads the same `vanilla.7z` Classic data pack used by the SPP Classic lane, then validates `dbc`, `maps`, `vmaps`, and `mmaps` before copying into `/srv/vmangos/data/`.
- On `ser8`, launcher-managed vmangos DB install completed through world, characters, logs, and dedicated `vmangosrealmd`, including bot rotation setup.
- Manual runtime smoke testing on `ser8` confirmed `realmd` starts cleanly against `vmangosrealmd`.
- Manual runtime smoke testing on `ser8` also confirmed `mangosd` reaches world startup, but runtime still needs launcher parity fixes for data layout and playerbot schema import.

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
- The `vmangos-ike3-playerbots` fork also ships required bot SQL under `src/game/PlayerBots/sql/{characters,world/classic}`. The launcher vmangos DB install must import that SQL into `vmangoscharacters` and `vmangos` or `mangosd` will later fail on missing `ai_playerbot_*` tables.
- The current local launcher source already includes bundled PlayerBots SQL import loops for both vmangos world and characters DB install paths; `ser8` still needs a launcher sync plus DB reinstall for those imports to actually take effect there.
- The launcher vmangos config writer needed two additional runtime fixes:
  - `mangosd.conf` must use the resolved vmangos DB endpoint, including `VMANGOS_DB_PORT`, not a blank port slot.
  - `RealmID` in `mangosd.conf` must match the dedicated `vmangosrealmd.realmlist` row (`id = 4` in the current lane).
- The launcher-managed vmangos data copy currently places assets under `/srv/vmangos/data`, but the deployed `mangosd.conf` still required manual correction from `DataDir = "."` to `DataDir = "../data"` during runtime smoke testing.
- The reused Classic data pack is good enough to advance startup, but vMaNGOS expects DBCs under the build-specific path `../data/5875/dbc`, not just `../data/dbc`.
- Reusing the Classic `mmaps` gets startup farther, but those files are not format-compatible long-term: the reused pack reported `generator v8`, while this vmangos fork expects `generator v6`.
- `mangosd` progressed past mmap warnings and then failed on missing playerbot schema in `vmangoscharacters` (`ai_playerbot_random_bots`), proving the remaining runtime blocker is playerbot SQL parity rather than general core/database startup.
- `core-db_latest.zip` from Ile's `db_latest` release is only a source-tree snapshot. It does not contain `ai_playerbot_random_bots`, and it is not a packaged DB dump for playerbot schema/data.
- The current account schemas differ between shared `classicrealmd.account` and dedicated `vmangosrealmd.account`, so standalone account copy must use a column-mapped insert rather than a blind row copy.
- The `SPP-Web` admin backup/xfer lane now has a vmangos-aware website patch in progress: it can expose vmangos transfer routes and generate account-xfer SQL that maps target account columns and sets the vmangos realm field to realm `4` instead of relying on a blind account row copy.
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

- Observed symptom: launcher-managed build, DB install, and data pack install now succeed on `ser8`, and manual `realmd` startup succeeds, but `mangosd` still needs launcher parity fixes for runtime paths/schema.
- Current hypothesis: the remaining runtime work is:
  - bake `DataDir = "../data"` into vmangos config deployment,
  - account for the `5875/dbc` path expectation,
  - import bundled playerbot SQL automatically,
  - and either supply vmangos-compatible `mmaps` or allow a temporary smoke-test path without them.
- Next action: sync the latest launcher, rerun vmangos DB install to import bundled playerbot SQL, then continue runtime validation against the external DB host.

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

1. Keep this control doc current as the vmangos runtime lane moves.
2. Sync the latest launcher changes to `ser8`, especially the bundled playerbot SQL import path.
3. Rerun vmangos DB install on `ser8` so `src/game/PlayerBots/sql/{characters,world/classic}` is actually imported into `vmangoscharacters` and `vmangos`.
4. Fold the manual runtime fixes back into launcher parity:
   - vmangos `mangosd.conf` should deploy with `DataDir = "../data"`
   - vmangos data install should account for `5875/dbc`
5. Continue runtime validation after the bot SQL rerun and determine whether vmangos-compatible `mmaps` are required immediately or only for full pathfinding parity.
6. Prepare standalone vmangos account creation/copy flow against `vmangosrealmd`, using column-mapped inserts from `classicrealmd.account` rather than blind row copies.
7. Wire up website-side account/character/guild transfer planning for `spp-classic` -> `spp-vmangos`.
8. Ensure the website-side vmangos lane can read from `vmangosrealmd` where needed, including WTF-download-related realm/account lookup paths.
9. Validate the new `SPP-Web` admin account-xfer package path against live `classicrealmd` -> `vmangosrealmd` schemas and confirm the generated SQL lands accounts on realm `4`.
9. Decide whether any fork fixes should be upstreamed or preserved as a local patch stack.
10. Revisit non-blocking compatibility warnings such as the MariaDB/MySQL guard once build/install parity is stable.

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
  - the next `ser8` vmangos DB reinstall run after the bundled PlayerBots SQL import patch
  - whether `mangosd` still reports missing `ai_playerbot_*` tables after that rerun
  - whether `mangosd` still requires manual `DataDir`/`5875/dbc` fixes after the next launcher sync
  - any remaining mmap/data-layout mismatches during startup
- Next-agent handoff focus:
  - treat the `ser8` core build/install, DB install, and data-pack install as confirmed green
  - treat `realmd` startup against `vmangosrealmd` as confirmed green
  - rerun vmangos DB install on `ser8` after syncing the new launcher so bundled PlayerBots SQL is imported
  - confirm whether `mangosd` still crashes on `ai_playerbot_random_bots` after that rerun
  - fold the remaining manual runtime fixes into launcher parity:
    - `DataDir = "../data"`
    - `5875/dbc` layout support
  - prepare standalone account creation/copy for vmangos:
    - source DB: `classicrealmd.account`
    - target DB: `vmangosrealmd.account`
    - use column-mapped insert/update, not raw row copy
    - set `current_realm = 4` for imported vmangos accounts
  - prepare website-side transfer work for `spp-classic` -> `spp-vmangos`:
    - account copy
    - character transfer
    - guild transfer
    - identify where `spp-web` should surface those actions and what DB mappings/config it will need
    - ensure the website can also pull the needed realm/account context from `vmangosrealmd` for WTF download support
  - record exact commands, failures, and runtime observations back into this file
- Treat Linux case sensitivity and Linux portability issues as first-class concerns; do not assume Windows path behavior is safe.
- Preserve the distinction between:
  - true Linux portability fixes
  - obvious fork-port typos
  - intentional vMaNGOS stubs where CMaNGOS bot subsystems do not exist yet
