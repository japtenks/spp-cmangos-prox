# SPP CMaNGOS Proxmox Launcher

Interactive Bash launcher for deploying and operating a WoW private-server stack on a Proxmox host with LXC containers.

Inspired by Celguar's SPP Classic CMaNGOS work:
[spp-classics-cmangos](https://github.com/celguar/spp-classics-cmangos)


## Support Status

| Install path | Status | Notes |
|---|---|---|
| Classic | Supported | Shared-services path. Uses shared DB, login, and website topology. |
| TBC | Supported | Shared-services path. Uses shared DB, login, and website topology. |
| vMaNGOS | Supported | Separate behavior from shared realms. Uses a dedicated realm DB flow and sits outside the shared website model. |
| WotLK | Untested | Listed in the launcher, but not documented here as a validated lane. |

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

The first installed Classic-family path becomes the master expansion. The master owns the shared `realmd` DB, supplies the `realmd` binary deployed to `spp-login`, and drives the shared website setup.

### vMaNGOS topology

vMaNGOS is available as a separate install path in the launcher:

- it uses its own dedicated realm DB behavior
- it can target its own DB endpoint

### WotLK note

WotLK still appears in the launcher install-path list, but this README treats it as untested. Do not read the shared Classic/TBC guidance below as confirmation that the WotLK lane has been validated end to end.

## Requirements

- Proxmox VE host with root shell access
- internet access from the Proxmox host for Git, package, and template downloads
- available Proxmox storage for multiple LXC containers
- enough CPU and RAM for at least one DB container, one login container, one web container, and one game container

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
2. Choose an install path from the launcher menu.
3. Create or attach the required game container when prompted.
4. Open `Maintenance`.
5. Run `I - Full (re)Install`.

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

## Install Flow

### 1. Select an install path

From the launcher, choose one of the install paths:

- `Classic`
- `TBC`
- `vMaNGOS`
- `WotLK` listed but untested

For Classic/TBC/vMaNGOS, the launcher will work from the selected install path context in the service and maintenance menus.

### 2. Create or attach the game container

If the game container for the selected path does not exist yet, the launcher offers to create or attach it through the stack-control flow.

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
| `Shared Services` | DB, login, website, repo sync, shared config repair, and launcher updates |
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
- dedicated realm DB behavior
- separate DB endpoint support exists in the launcher
- database install is substantial and may take a while to complete

For deeper vMaNGOS build and validation notes, see [VMANGOS_BUILD_CONTROL.md](./VMANGOS_BUILD_CONTROL.md).

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
| `./Launcher.sh` | main operator entrypoint |

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
