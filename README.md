# SPP CMaNGOS Proxmox Launcher

Interactive bash script for deploying and managing a CMaNGOS WoW private server stack (Classic, TBC, WotLK) on a Proxmox host using LXC containers.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Getting Started](#3-getting-started)
4. [First-Run Bootstrap](#4-first-run-bootstrap)
5. [Container Architecture](#5-container-architecture)
6. [Master Expansion](#6-master-expansion)
7. [Installing an Expansion](#7-installing-an-expansion)
8. [Multi-Expansion Setup](#8-multi-expansion-setup)
9. [Menu Reference](#9-menu-reference)
10. [Crash Debugging](#10-crash-debugging)
11. [Key Paths](#11-key-paths)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Overview

The launcher provisions and manages all server infrastructure from the Proxmox host shell. It handles:

- LXC container creation and OS provisioning
- Compiling CMaNGOS + Playerbots from source
- Database installation and incremental updates
- Config file deployment
- Service management (start/stop/autostart)
- Website deployment
- Crash analysis via GDB

**What gets built:**

| Container | Role |
|---|---|
| `spp-db` | MariaDB — all databases for every expansion |
| `spp-web` | Apache + PHP 7.4 — armory, news, account pages |
| `spp-login` | realmd — authentication for all expansions |
| `spp-classic` | mangosd game server for Classic (Vanilla) |
| `spp-tbc` | mangosd game server for TBC |
| `spp-wotlk` | mangosd game server for WotLK |

Only one game container exists per expansion. The DB, web, and login containers are shared by all expansions.

---

## 2. Prerequisites

- Proxmox VE 8.x or 9.x with root SSH access
- Internet access from the Proxmox host (GitHub clones, apt packages, template downloads)
- Free storage: ~32 GB per game container + 16 GB for DB + 16 GB for web/login
- Recommended RAM per game container: 8–16 GB (set during bootstrap)

---

## 3. Getting Started

SSH into the Proxmox host as root:

```bash
ssh root@<proxmox-ip>
```

Clone the repo and run the launcher:

```bash
git clone https://github.com/japtenks/spp-cmangos-prox.git
cd spp-cmangos-prox
bash Launcher.sh
```

The launcher must be run from the Proxmox host shell — it uses `pct` commands to manage containers.

---

## 4. First-Run Bootstrap

If `config.env` does not exist, the launcher enters bootstrap mode. It first checks for existing containers via `pct list`. If none are found, it walks through a full first-run setup.

### Prompts

| Prompt | Notes |
|---|---|
| DB root password | MariaDB root password. Stored in `config.env` — keep this file secure. |
| DB LAN username | User the website and game servers connect as (e.g. `sppuser`). |
| DB LAN password | Password for the LAN user. |
| DB LAN host | `%` allows any host. Set to a specific IP to restrict access. |
| RA admin username | Remote console admin account name. |
| RA admin password | Remote console admin password. |
| LXC Game Cores | CPU cores per game container. Default: 4. |
| LXC Game RAM (MB) | RAM per game container. Default: 16384 (16 GB). |
| Storage | Select from available Proxmox storage pools. |
| Network mode | DHCP (automatic) or Static (you assign IPs per container). |

After completing these prompts, `config.env` is written and the launcher proceeds to the main menu.

**If containers already exist** (e.g. re-running after a failed bootstrap), the launcher auto-detects them via `pct list` and rebuilds `config.env` from the detected state, prompting only for credentials.

---

## 5. Container Architecture

```
Proxmox Host
├── spp-db      (MariaDB — all DBs)
├── spp-web     (Apache/PHP — website)
├── spp-login   (realmd — auth)
├── spp-classic (mangosd — Classic game server)
├── spp-tbc     (mangosd — TBC game server)
└── spp-wotlk   (mangosd — WotLK game server)
```

All containers are unprivileged Debian LXC with nesting enabled. Game containers are the only ones that compile and run the mangosd binary.

**Source and build tree inside each game container:**

```
/opt/source/                  CMaNGOS core (git clone)
/opt/source/src/modules/playerbot/   Playerbots (git clone)
/opt/source/build/            cmake build directory
/opt/spp-settings/            Sparse checkout of this repo (Settings/)
/srv/mangos-{expansion}/      Install prefix (bin/, etc/, data/)
/var/log/mangos/Server.log    World server log
```

---

## 6. Master Expansion

When the **first** expansion's realm database is installed, that expansion is pinned as the **master**. The master expansion:

- Owns the shared `realmd` database (`classicrealmd`, `tbcrealmd`, or `wotlkrealmd`)
- Has its realmd binary deployed to `spp-login`
- Has its website installed on `spp-web`

Non-master expansions get their own world, character, logs, and armory databases but share the auth realm DB. You cannot change the master expansion after the first realm install without a full reinstall.

**Recommendation:** Install the expansion you'll use most first and let it become master.

---

## 7. Installing an Expansion

### 7.1 Select an Expansion

From the main expansion menu, select the number corresponding to Classic, TBC, or WotLK. If the game container for that expansion doesn't exist, the launcher offers to create it.

### 7.2 Full Install

Navigate to `Maintenance → I - Full (re)Install`, type `YES` to confirm.

**What happens (in order):**

1. Stops existing services for that expansion
2. Removes old install dir, source tree, and version trackers
3. Drops and recreates all databases for this expansion
4. Clones `celguar/mangos-{expansion}` on branch `ike3-bots`
5. Clones `cmangos/playerbots` into `src/modules/playerbot`
6. Patches `CMakeLists.txt` to use `japtenks/cmangos-modules`
7. Runs cmake with all modules enabled (see below)
8. Compiles with `make -j$(nproc)` and installs to `/srv/mangos-{expansion}/`
9. Installs world, character, realm, logs, and armory databases
10. Downloads and extracts pre-built map/DBC/vmap data pack
11. Writes systemd service files
12. Deploys config files from this repo's `Settings/{expansion}/`
13. Updates all `.conf` files with correct DB host, user, and passwords
14. For master expansion: installs website and deploys realmd to `spp-login`

**Modules compiled in:**
Achievements, Immersive, Hardcore, Transmog, Dualspec, Boost, Custom20, Balancing, Barber, TrainingDummies, Voiceover, AHBot, Playerbots

**Build type:** `RelWithDebInfo` — optimized binary with debug symbols retained for crash analysis.

**Expected time:** 30–90 minutes depending on hardware. The cmake + make step is the longest.

---

## 8. Multi-Expansion Setup

To run Classic + TBC (or any combination):

1. Install Classic first — it becomes master (owns realmd DB, website, login)
2. Return to Expansion Select (`0` from Service Menu)
3. Select TBC, create container when prompted, run Full Install
4. TBC installs its own world/chars/logs/armory databases, adds its realm entry to the shared realm DB, and uses the same `spp-login` realmd

Each expansion's game server runs independently. The login container serves auth for all of them simultaneously. The website shows data for the master expansion by default.

**Realm IDs assigned automatically:**
- Classic → Realm ID 1
- TBC → Realm ID 2
- WotLK → Realm ID 3

---

## 9. Menu Reference

### Main Expansion Menu

```
1 - Classic   [Installed - CTID 103] / [Not Installed]
2 - Tbc       [Installed - CTID 104] / [Not Installed]
3 - Wotlk     [Installed - CTID 105] / [Not Installed]
S - Shared Services
0 - Exit
```

---

### Service Menu (per expansion)

Accessed after selecting an expansion. The header shows installed version state — green means current, red means behind expected version.

```
1 - Stack Control
2 - Maintenance
4 - Remote Console
5 - Live World Log
6 - Autostart Status: (On/Off)
7 - Server Info
0 - Expansion Select
```

**Stack Control**
- `Status` — shows each container's running state and service uptime
- `Start Stack` / `Stop World` — toggles based on current state. Start brings up all containers in order (DB → Web → Login → Game). Stop shuts down only the game container.

**Maintenance**

| Option | Action |
|---|---|
| `1 - Core → Clean Rebuild` | Deletes `/opt/source`, reclones, full recompile |
| `1 - Core → Incremental Update` | Pulls latest commits, rebuilds only if changes detected |
| `2 - Database → Install Full DB` | Drops and reinstalls all databases (**destructive**) |
| `2 - Database → Reset Characters` | Wipes character DB and reimports bot caches |
| `2 - Database → Install Locales` | Imports translation SQL for selected languages |
| `2 - Database → Update realmd DB` | Applies pending realmd SQL update files |
| `2 - Database → Update characters DB` | Applies pending character SQL update files |
| `2 - Database → Update PlayerBots DB` | Applies pending bot SQL update files |
| `2 - Database → Configure Bot Rotation Logging` | Sets up bot tracking tables and cron job in DB container |
| `3 - Install Data Pack` | Re-downloads and extracts map/DBC/vmap data |
| `4 - Config Settings → Update Bot Conf` | Pulls latest `aiplayerbot.conf` from repo, backs up current |
| `I - Full (re)Install` | Complete reinstall: compile + DB + maps + services |
| `S - Setting Repo` | Force re-sync `Settings/` sparse checkout on game container |

**Remote Console (`4`)** — connects to the mangosd Remote Administration port (3443) via telnet using the admin credentials from `config.env`.

**Live World Log (`5`)** — tails `/var/log/mangos/Server.log` in real time. `Ctrl+C` returns to menu.

**Autostart (`6`)** — toggles `systemctl enable/disable` for mangosd and realmd. When enabled, services start automatically when containers boot.

---

### Server Info Menu (`7`)

```
1 - World Settings      (opens mangosd.conf in nano)
2 - Bots Settings       (opens aiplayerbot.conf in nano, syncs bot rotation config)
3 - RealmD Settings     (opens realmd.conf in nano)
4 - Change Server Address
5 - Change Realm Name
7 - Crash Logs
8 - Analyze Crash (GDB)
```

**Change Server Address** — updates the `address` field in the realm DB's `realmlist` table. Use this when your server IP changes.

**Change Realm Name** — updates the realm name shown in the WoW server list.

---

### Shared Services Menu (`S`)

Available after at least one expansion is installed.

**Status** — uptime and container state for DB, login, and web containers.

**Service Control** — individual start/stop for MariaDB, realmd, and Apache.

**Website**
- `Install Website` — fresh clone of the armory site, imports DB tables (master expansion only)
- `Update Website` — git pull + rsync, preserves `config-protected.local.php`
- `Align php for website db` — rewrites DB connection settings in `config-protected.local.php`

**Repo** — manages the SQL/settings repo sparse checkout on DB and game containers.

**Configuration**
- `Apply Server Confs` — rewrites DB host/user/pass into all `.conf` files across all containers
- `Fix Realmlist` — re-inserts the correct realm entry for the current expansion
- `Autostart services creation` — (re)writes systemd service files on login and game containers
- `RealmD Install` — copies realmd binary from game container to login container
- `spp configs` — re-deploys Settings/ config files from repo to game container
- `Fix mariadb configs` — sets `bind-address = 0.0.0.0` in MariaDB config and restarts

---

### Key Config File Locations (inside containers)

| File | Container | Path |
|---|---|---|
| `mangosd.conf` | `spp-{expansion}` | `/srv/mangos-{expansion}/etc/mangosd.conf` |
| `aiplayerbot.conf` | `spp-{expansion}` | `/srv/mangos-{expansion}/etc/aiplayerbot.conf` |
| `realmd.conf` | `spp-login` | `/srv/mangos-{expansion}/etc/realmd.conf` |
| World server log | `spp-{expansion}` | `/var/log/mangos/Server.log` |

---

## 10. Crash Debugging

The server binary is compiled with `RelWithDebInfo`, which preserves debug symbols while keeping optimizations. GDB is installed on all game containers.

### Enabling Core Dumps

Core dumps are enabled via `LimitCORE=infinity` in the mangosd systemd service. If you installed before this was added, re-apply service files:

```
Shared Services → Configuration → Autostart services creation
```

Core files are written to the mangosd working directory when the process crashes:
```
/srv/mangos-{expansion}/bin/core.<pid>
```

### Crash Logs (`Server Info → 7`)

Lists all `core.*` files in the bin directory and any entries in systemd-coredump (if active on your Debian version).

### Analyze Crash (`Server Info → 8`)

Opens an interactive GDB session loaded with the mangosd binary and a selected core dump.

**Workflow:**
1. Server crashes → core file written to `/srv/mangos-{expansion}/bin/`
2. Open `Server Info → 8 - Analyze Crash`
3. The launcher lists available core files and prompts for selection (defaults to most recent)
4. GDB opens interactively

**Useful GDB commands:**

```
bt full                   Full backtrace of the crashing thread
thread apply all bt       Backtrace for every thread
info threads              List all threads with current frame
frame <n>                 Switch to stack frame n
info locals               Local variables in current frame
info registers            CPU register state at crash
list                      Source lines around current position
quit                      Exit GDB
```

**If systemd-coredump is active** (Debian 12+), the launcher falls back to `coredumpctl gdb mangosd` automatically if no file-based cores are found.

### Tips for Useful Crash Reports

- Always run `thread apply all bt` — CMaNGOS is multithreaded and the crash may be on a non-primary thread
- `bt full` shows local variable values in each frame, which is more useful than plain `bt`
- Symbol names and line numbers are available because of `RelWithDebInfo` — you'll see actual function names and source file references

---

## 11. Key Paths

### On the Proxmox Host

| Path | Purpose |
|---|---|
| `./config.env` | All credentials and CTID assignments — keep this safe |
| `./Settings/{vanilla,tbc,wotlk}/` | Config files deployed to game containers |
| `./sql/{vanilla,tbc,wotlk}/` | SQL files cloned into DB container at `/opt/spp-sql/` |

### Inside Containers (set via sparse checkout)

| Container | Path | Contents |
|---|---|---|
| `spp-db` | `/opt/spp-sql/` | Full SQL repo sparse checkout |
| `spp-{expansion}` | `/opt/spp-settings/` | Settings sparse checkout |
| `spp-{expansion}` | `/opt/source/` | CMaNGOS source tree |
| `spp-db` | `/opt/{expansion}_{type}_version.spp` | Version tracking files |

---

## 12. Troubleshooting

| Symptom | Fix |
|---|---|
| `config.env` missing on re-run | Re-run the launcher — it auto-detects existing containers and rebuilds it |
| "Template acquisition failed" | Run `pveam update` on the Proxmox host, then re-run |
| mangosd won't start | Check `5 - Live World Log`. Usually a DB connection error — run `Shared Services → Configuration → Apply Server Confs` |
| Can't connect from WoW client | Check `Server Info` — confirm the realmlist IP matches `spp-login`. Verify port 3724 is reachable |
| Version numbers show red | Run `Maintenance → Full (re)Install` to bring that expansion to expected version |
| MariaDB refusing remote connections | `Shared Services → Configuration → Fix mariadb configs` |
| Website shows DB errors | `Shared Services → Website → Align php for website db` |
| Realm address wrong after IP change | `Server Info → 4 - Change Server Address` |
| Both realms listed but one won't load | Each expansion's mangosd must be running — check status per expansion |
| Core dumps not appearing after crash | Re-apply service files: `Shared Services → Configuration → Autostart services creation` |
| GDB shows `?? ()` frames with no symbols | Binary may have been replaced without a rebuild — run an incremental update |
| `coredumpctl` not found | File-based cores are used instead — check `/srv/mangos-{expansion}/bin/core.*` |
| aiplayerbot.conf reverted unexpectedly | The conf update check runs on every core build — if repo has a newer version it deploys automatically. Check `.bkup*` files in the etc/ dir for your previous config |
