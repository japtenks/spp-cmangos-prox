# SPP CMaNGOS Proxmox Launcher

Interactive Bash launcher for deploying and operating a WoW private-server stack on a Proxmox host with LXC containers.

Inspired by Celguar's SPP Classic CMaNGOS work:
[spp-classics-cmangos](https://github.com/celguar/spp-classics-cmangos)

## Showcase

[`SPP-Web`](https://github.com/japtenks/SPP-Web) is the installed frontend for most administrative features today, and is expected to remain the main admin surface as more workflows move out of the terminal launcher.

To keep normal `git clone` checkouts lean, the showcase images are intended to be published as GitHub release assets instead of being committed into the repository. The README is wired to the asset names below, so uploading matching files to a release will light the gallery up without adding screenshot weight to the repo itself.

<!-- Expected release asset filenames:
showcase-launcher-main-paths.png
showcase-launcher-vmangos-stack.png
showcase-spp-web-admin.jpg
showcase-spp-web-news.jpg
-->

<table>
  <tr>
    <td width="50%">
      <a href="https://github.com/japtenks/spp-cmangos-prox/releases/latest/download/showcase-launcher-main-paths.png">
        <img src="https://github.com/japtenks/spp-cmangos-prox/releases/latest/download/showcase-launcher-main-paths.png" alt="Launcher install path selection" width="100%">
      </a>
      <br>
      <sub>Install-path selection with shared-services entry points for Classic, TBC, and vMaNGOS.</sub>
    </td>
    <td width="50%">
      <a href="https://github.com/japtenks/spp-cmangos-prox/releases/latest/download/showcase-launcher-vmangos-stack.png">
        <img src="https://github.com/japtenks/spp-cmangos-prox/releases/latest/download/showcase-launcher-vmangos-stack.png" alt="vMaNGOS launcher stack view" width="100%">
      </a>
      <br>
      <sub>Dedicated vMaNGOS stack view with maintenance, remote console, and world-state details.</sub>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <a href="https://github.com/japtenks/spp-cmangos-prox/releases/latest/download/showcase-spp-web-admin.jpg">
        <img src="https://github.com/japtenks/spp-cmangos-prox/releases/latest/download/showcase-spp-web-admin.jpg" alt="SPP-Web admin dashboard" width="100%">
      </a>
      <br>
      <sub>SPP-Web admin dashboard for operations, site maintenance, character tools, and bot controls.</sub>
    </td>
    <td width="50%">
      <a href="https://github.com/japtenks/spp-cmangos-prox/releases/latest/download/showcase-spp-web-news.jpg">
        <img src="https://github.com/japtenks/spp-cmangos-prox/releases/latest/download/showcase-spp-web-news.jpg" alt="SPP-Web news article view" width="100%">
      </a>
      <br>
      <sub>SPP-Web front page and news flow, which is already handling a growing share of day-to-day administration.</sub>
    </td>
  </tr>
</table>


## Support Status

| Install path | Status | Notes |
|---|---|---|
| Classic | Supported | Shared-services path. Uses shared DB, login, and website topology. Source profile can be switched between standard CMaNGOS and repo lane. |
| TBC | Supported | Shared-services path. Uses shared DB, login, and website topology. |
| vMaNGOS | Supported | Shares the common MariaDB container, but hosts its own `realmd` inside the game LXC instead of using `spp-login`. |
| WotLK | WIP | Not shown as a valid install lane until the install flow is proven. |

## Build Lanes

The launcher separates the runtime install path from the source/build lane:

| Engine lane | Build profile | Default source |
|---|---|---|
| CMaNGOS | `standard` | `cmangos/mangos-classic`, branch `master`, with `cmangos/playerbots` pulled into `src/modules/playerbot` |
| CMaNGOS | `repo` | `japtenks/mangos-classic`, branch `ike3-bots` |
| vMaNGOS | `repo pin` | `japtenks/SPP-Vmangos-nix`, branch `codex/ahbot-next` |

Source pins can be changed from:

```text
Maintenance -> Config Settings -> Source URLs and Branches
```

For Classic/CMaNGOS, the active profile can also be changed from:

```text
Maintenance -> Config Settings -> CMaNGOS Build Profile
```

`Launcher.sh` exposes both the Classic/CMaNGOS profile override and the wider `Source URLs and Branches` operator menu for pinned sources.

The top-level menu shows installed lanes only. Use `I - Install New` to select a family:

```text
1 - CMaNGOS (Classic, TBC)
2 - vMaNGOS (Classic, Tortoise)
```

The install wizard then lists valid uninstalled lanes, shows `pct list`, prompts for a new game-container CTID, creates the LXC, and rolls directly into `Full (re)Install`.

CMaNGOS Classic supports stock-vs-repo/module build profiles. vMaNGOS Classic uses the vMaNGOS bot build path. Tortoise/Turtle is visible under the vMaNGOS family as experimental, but it is not yet allowed to install because its DB/data/config flow is still unproven.

### Tortoise data extraction planning

Tortoise/Turtle WoW targets client `1.18.1` build `7272`. The upstream `faemwow/tortoise-wow` project currently recommends Linux builds on Ubuntu 22.04-class environments and calls out `ACE` as an additional dependency on top of the usual MaNGOS stack.

The future LXC lane should stage extracted assets under a dedicated path instead of reusing vanilla CMaNGOS data blindly:

```text
/opt/spp-assets/tortoise/data/dbc
/opt/spp-assets/tortoise/data/maps
/opt/spp-assets/tortoise/data/vmaps
/opt/spp-assets/tortoise/data/mmaps
```

The upstream extractor flow is currently Docker-oriented: set `TORTOISE_DATA_DIR`, set `WOW_CLIENT_DIR` to a local Turtle 1.18.1 client, then run `run-local-extractors.sh` inside `ghcr.io/faemwow/tortoise-wow-mangosd:latest`. That is a one-time extraction pass and upstream notes that it can take hours.

The current upstream DB bootstrap is also still manual:

```text
1. import sql/create_databases.sql
2. import the SQL files in sql/base
3. run mangosd so it can apply and track updates
```

The launcher should eventually convert that into a dedicated Proxmox/LXC install lane, likely `tortoise`, that:

- prompts for a mounted Turtle client path
- runs the extractor flow once and validates `dbc/maps/vmaps/mmaps`
- imports the upstream Turtle SQL bootstrap in the right order
- then hands off to the normal service/config flow inside the game LXC

## What The Launcher Does

Run `Launcher.sh` on the Proxmox host and it can:

- create and manage LXC containers running the separate services
- bootstrap the shared service containers
- install and rebuild server cores from source
- install base databases and incremental DB updates
- deploy config files from this repo
- start, stop, and autostart services
- manage the shared website for Classic-family realms
- open live logs, remote console, and GDB crash analysis

## Stack Layout

### Shared Classic-family topology

Classic and TBC use a shared-services model:

| Container | Role |
|---|---|
| `spp-db` | MariaDB for shared and per-realm databases |
| `spp-web` | Apache + PHP website |
| `spp-login` | Shared `realmd` container |
| `spp-classic` | Classic world server |
| `spp-tbc` | TBC world server |

The first installed Classic-family path becomes the shared realm owner. That owner owns the shared `realmd` DB, supplies the `realmd` binary deployed to `spp-login`, and drives the shared website setup.

### vMaNGOS/Turtle-family topology

vMaNGOS is available as a separate install path in `Launcher.sh`:

- it shares the same MariaDB container and website
- each vMaNGOS-family core hosts `realmd` inside its own game LXC
- the WoW client `realmlist` points at the game LXC for vMaNGOS/Turtle-family lanes
- Turtle/Tortoise should follow this same game-LXC `realmd` pattern once its DB/data extraction lane is proven

### WotLK note

WotLK remains a planning target, but it should stay out of the valid install menu until the install flow is complete.

The planned WotLK build direction is [`mod-playerbots`](https://github.com/mod-playerbots/mod-playerbots).

## Requirements

- Proxmox VE host with root shell access
- internet access from the Proxmox host for Git, package, and template downloads
- available Proxmox storage for multiple LXC containers
- enough CPU and RAM for at least one DB container, one web container, and one game container; CMaNGOS shared-login lanes also need the `spp-login` container

Recommended sizing from the current launcher flow:

- game container CPU: `4` cores by default
- game container RAM: `16384` MB by default

The launcher chooses a Debian LXC template and uses Proxmox `pct` commands directly, so it must be run on the Proxmox host itself.

## Quick Start

SSH into the Proxmox host:

```bash
ssh root@<proxmox-ip>
```

Clone the repo and run the launcher:

```bash
git clone https://github.com/japtenks/spp-cmangos-prox.git
cd spp-cmangos-prox
bash Launcher.sh
```

Then:

1. Complete first-run bootstrap prompts.
2. Choose `I - Install New`.
3. Select `CMaNGOS` or `vMaNGOS`.
4. Select the lane, enter a new game-container CTID, and let the wizard run the full install.

## First-Run Bootstrap

If `config.env` does not exist, the launcher enters bootstrap mode.

On a fresh host, it prompts for:

- DB root password
- DB LAN username
- DB LAN password
- DB LAN host
- RA admin username
- RA admin password
- game container CPU cores
- game container RAM
- Proxmox storage target
- network mode: DHCP or static IPs

If existing containers are already present, the launcher auto-detects them with `pct list`, rebuilds `config.env`, and asks for the credentials it cannot recover on its own.

Important bootstrap output:

- `config.env` is written in the repo directory
- install-path ordering is managed by the launcher
- DHCP or static IP choices apply to the containers it creates

Treat `config.env` as sensitive because it stores the database and RA credentials used by the stack.

Optional at-rest encryption is available from:

```text
Shared Services -> Configuration -> Config encryption
```

When enabled, the launcher stores secrets in `config.env.enc` instead of plaintext `config.env` and prompts for the passphrase when it starts.

## Install Flow

### 1. Select an install path

From the launcher, choose one of the install paths:

- `Classic`
- `TBC`
- `vMaNGOS`
- `WotLK` listed but untested

For Classic/TBC/vMaNGOS, the launcher will work from the selected install path context in the service and maintenance menus.

### 2. Create or attach the game container

For new installs, use `I - Install New`; the wizard selects the lane, creates the game container, and starts the full install. Existing lanes can still be managed through the per-path service and maintenance menus.

### 3. Run a full install

From the per-path menu:

```text
Maintenance -> I - Full (re)Install
```

At a high level, full install does the following:

- stops existing services for that path
- resets source/build/install state for the selected path
- installs or rebuilds the core from source
- installs path-specific databases
- installs the data pack
- deploys config files from `Settings/`
- writes service files
- applies DB connection details into config files

For Classic and TBC, the first installed Classic-family path also establishes the shared realm/login/website baseline.

Expected duration depends on hardware and network speed, but a full build-and-install pass is typically the longest operation in the launcher workflow.

## Day-To-Day Management

The launcher splits normal operations between per-path controls and shared services.

### Navigation map

| Where | Use it for |
|---|---|
| Per-path menu | World server lifecycle, maintenance, logs, RA, and config editing for the selected install path |
| `Shared Services` | Shared DB, website, CMaNGOS login, repo sync, shared config repair, and launcher updates |
| `Server Info` | Edit configs, realm address/name changes, crash logs, and GDB analysis |

### Start, stop, and check status

Use:

```text
Stack Control
```

This is where you:

- view stack status
- start the selected path and required shared containers
- stop the selected world server stack

For Classic/TBC, startup order is driven through the shared containers plus the selected game container. vMaNGOS remains a separate install path with its own behavior.

### Rebuild or update the core

Use:

```text
Maintenance -> Core
```

The current launcher supports:

- clean rebuilds
- incremental updates when changes are detected

Use full reinstall when you need a complete reset of core, DB, services, and configs for the selected path.

### Reinstall or update database components

Use:

```text
Maintenance -> Database
```

This area is for tasks such as:

- full DB install
- character resets
- locale imports
- `realmd` updates
- character DB updates
- playerbot DB updates
- bot rotation logging setup

Be careful here. Some options are destructive.

### Reapply settings and config files

Per-path config refresh:

```text
Maintenance -> Config Settings
Maintenance -> S - Setting Repo
```

Shared config repair:

```text
Shared Services -> Configuration
```

These flows are useful when:

- DB host or credentials changed
- config files drifted from repo defaults
- service files need to be recreated
- the realmlist entry needs repair

### Tail logs

Use:

```text
Live World Log
```

This tails the world log in real time from the selected install path. Use `Ctrl+C` to return to the menu.

### Connect with RA

Use:

```text
Remote Console
```

The launcher connects to the mangosd RA port using the admin credentials stored in `config.env`.

### Edit server configs

Use:

```text
Server Info
```

This menu gives quick access to:

- world config
- bot config
- `realmd` config
- other deployed `.conf` files
- server address updates
- realm name updates

For shared Classic-family paths, some realm-management messaging in the launcher points you toward the website for ongoing shared realm administration after bootstrap.

### Crash logs and GDB

Use:

```text
Server Info -> Crash Logs
Server Info -> Analyze Crash (GDB)
```

The launcher is designed to help with post-crash inspection:

- list available crash/core data
- open an interactive GDB session
- work against binaries installed with debug symbols retained

If crash analysis is not producing useful core files, reapply the generated service files through shared configuration so the expected service settings are restored.

### Autostart

Use:

```text
Autostart Status
```

This toggles service enablement for the selected path and updates the launcher-managed setting in `config.env`.

### Update launcher and shared website/services

Use:

```text
Shared Services
```

This area covers:

- DB/login/web container status
- starting and stopping shared services
- website install and update tasks for the shared Classic-family topology
- repo reset/update operations
- shared config repair
- launcher self-update

## Path Notes

### Classic

- supported
- part of the shared-services model
- can become the master Classic-family path if installed first

### TBC

- supported
- part of the shared-services model
- shares DB/login/website topology with Classic-family setup

### vMaNGOS

- supported
- separate install path
- shares the common MariaDB container while hosting `realmd` inside the vMaNGOS game LXC
- launcher source selection now defaults to a single vMaNGOS branch pin
- separate DB endpoint support exists in the launcher
- dedicated data pack URL support exists in the launcher via `VMANGOS_DATA_PACK_URL`
- database install is substantial and may take a while to complete

For deeper vMaNGOS build and validation notes, see [VMANGOS_BUILD_CONTROL.md](./VMANGOS_BUILD_CONTROL.md).

### vMaNGOS validation build lanes

Keep two standard WSL validation lanes distinct when preparing a branch for launcher handoff:

- `RelWithDebInfo + BUILD_PLAYERBOTS=ON`
  - use this for normal bridge validation, install parity checks, and most crash triage
  - this is optimized code with debug symbols, not a true `Debug` build
- `Debug + BUILD_PLAYERBOTS=ON`
  - use this for launcher repro work and crash-symbolization investigations where an actual debug build is required
  - this distinction happens at `cmake` configure time, not only at build time

Example WSL configure/build commands for the true debug lane:

```powershell
wsl.exe -d Debian --cd /home/japtenks/SPP-Vmangos-bridge-main cmake -S . -B build-debug -DCMAKE_BUILD_TYPE=Debug -DBUILD_PLAYERBOTS=ON
wsl.exe -d Debian --cd /home/japtenks/SPP-Vmangos-bridge-main cmake --build build-debug --target mangosd -- -j8
```

### vMaNGOS branch-to-launcher handoff

The intended workflow is:

1. Build and validate the vMaNGOS branch in WSL first.
   Use the lane that matches the goal:
   - `RelWithDebInfo + BUILD_PLAYERBOTS=ON` for normal install validation
   - `Debug + BUILD_PLAYERBOTS=ON` for launcher/crash-analysis repro work
2. Pin that candidate in the launcher at `Maintenance -> Config Settings -> vMaNGOS Source Pin`.
   The default vMaNGOS repo/branch is `https://github.com/japtenks/SPP-Vmangos-nix.git` on `codex/ahbot-next`.
3. The launcher release rebuild now follows the current source/build/install flow:
   - `cd /opt/source`
   - `git fetch origin`
   - `git checkout codex/ahbot-next`
   - `git reset --hard origin/codex/ahbot-next`
   - `cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_PLAYERBOTS=ON -DBUILD_EXTRACTORS=OFF`
   - `cmake --build build -j$(nproc)`
   - `cd /opt/source/build`
   - `make install`
4. Use the custom debug build option only when you need to test a non-default repo or branch.

You can edit the pin from the launcher at:

- `Maintenance -> Config Settings -> vMaNGOS Source Pin`

If no custom vMaNGOS source pin is set, the launcher falls back to `codex/ahbot-next`.

### WotLK

- exposed in the launcher menu
- currently untested in this workflow
- do not assume parity with the documented Classic/TBC paths

## Key Paths

### On the Proxmox host

| Path | Purpose |
|---|---|
| `./config.env` | launcher credentials and detected container settings |
| `./Settings/` | config templates deployed by install path |
| `./sql/` | SQL assets used by the launcher |
| `./Launcher.sh` | main launcher with shared-topology and config model |

### Inside containers

| Path | Purpose |
|---|---|
| `/opt/source/` | source checkout for the selected core |
| `/opt/source/build/` | build directory |
| `/opt/spp-settings/` | settings checkout inside game containers |
| `/srv/mangos-<path>/` or `/srv/vmangos/` | installed server files |
| `/var/log/mangos/Server.log` | live world server log |

## Troubleshooting

| Symptom | What to try |
|---|---|
| `config.env` is missing after a rerun | Run the launcher again. It auto-detects existing containers and rebuilds config where possible. |
| Debian template download fails | Run `pveam update` on the Proxmox host, then rerun the launcher. |
| World server will not start | Check `Live World Log`, then reapply shared config with `Shared Services -> Configuration -> Apply Server Confs`. |
| Database connections are wrong after an IP or credential change | Reapply server configs from `Shared Services -> Configuration`. |
| Realm address changed | Use `Server Info -> Change Server Address`. |
| Website has DB errors | Re-run the website DB alignment flow in `Shared Services -> Website`. |
| MariaDB is not accepting remote connections | Use the MariaDB config repair option under `Shared Services -> Configuration`. |
| Crash dumps are missing | Recreate service files from shared configuration so the expected core-dump settings are restored. |
| GDB lacks useful symbols | Rebuild the selected path so the installed binary matches the debug-symbol-bearing build output. |
| WotLK behavior differs from README expectations | This is expected. WotLK is present in the launcher but currently untested. |

## Operator Notes

- Run the launcher from the Proxmox host, not from another workstation shell.
- Use the website as the main ongoing admin surface for shared Classic-family realms after bootstrap.
- Treat WotLK as an available menu option, not a documented validated deployment path.
