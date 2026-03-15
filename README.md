# SPP Proxmox Stax v0.1

## Two-Realm Installation Guide: Classic & TBC
*Proxmox Host — Step-by-Step*

---

## Table of Contents
1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Getting the Script onto Proxmox](#3-getting-the-script-onto-proxmox)
4. [First-Run Bootstrap](#4-first-run-bootstrap)
5. [Building the Shared Services](#5-building-the-shared-services-db-web-login)
6. [Installing the Classic Realm](#6-installing-the-classic-vanilla-realm)
7. [Installing the TBC Realm](#7-installing-the-tbc-realm)
8. [Verifying the Stack](#8-verifying-the-stack)
9. [Post-Installation Configuration](#9-post-installation-configuration)
10. [Maintenance](#10-maintenance)
11. [Troubleshooting](#11-troubleshooting)
12. [Settings](#12-settings)

---

## 1. Overview

This guide walks through deploying two fully-functional CMangos — Vanilla (Classic) and The Burning Crusade (TBC) — on a single Proxmox host using the SPP CMaNGOS manager script. Both realms share one database container, one login container, and one website container; each gets its own dedicated game container.

**What gets built:**

| Container     | Role |
|            ---|   ---|
| `spp-db`      | MariaDB — holds all databases for every realm  |
| `spp-web`     | Apache/PHP website (armory, news, how-to-play) |
| `spp-login`   | Realmd — handles authentication for all realms |
| `spp-classic` | Game server for Classic (Vanilla)              |
| `spp-tbc`     | Game server for TBC                            |

---


## 2. Prerequisites

### 2.1 Proxmox Host
- Proxmox VE 9.x installed and accessible via web UI (`https://<host-ip>:8006`)
- At least 60 GB of free storage on whichever pool you'll use (local-lvm, zfs, etc.)
- Internet access from the Proxmox host — the script clones GitHub repos and downloads Debian templates
- SSH access to the Proxmox host as root


## 3. Getting the Script onto Proxmox

Log in to your Proxmox host via SSH as root and run the following:

```bash
# SSH into your Proxmox host
ssh root@<your-proxmox-ip>

# Create a working directory (optional)
# mkdir -p /opt/spp && cd /opt/spp

# Download the manager script
wget -O spp.sh https://raw.githubusercontent.com/japtenks/spp-cmangos-prox/main/launcher.sh

# Make it executable
chmod +x launcher.sh
```
---

## 4. First-Run Bootstrap

The first time you run the script, no `config.env` file exists. The script enters **First-Run Bootstrap** mode and asks a few setup questions.

***THIS IS PLAIN TEXT***

```bash
./launcher.sh
```

### 4.1 What the Bootstrap Prompts

| Prompt | What to Enter |
|---|---|
| DB root password | Choose a strong password for MariaDB root. Write it down — you won't be prompted again. It's stored in `config.env`. |
| LXC Game Cores | Number of CPU cores per game container. `4` is a good default. |
| LXC Game RAM (MB) | RAM in MB per game container. `16384` (16 GB) is a good default. |
| Storage selection | A numbered menu appears. Pick your Proxmox storage pool (e.g. `local-lvm`). |

After answering these prompts, the script writes `config.env` and auto-downloads the latest Debian LXC template from Proxmox's repositories if one isn't already cached. This may take a minute or two.

---

## 5. Building the Shared Services (DB, Web, Login)

After the bootstrap, the script opens the Expansion Menu. Because no containers exist yet, it will immediately prompt you to create the three shared containers.

### 5.1 Expansion Menu

You will see something like:

```
########################################
# SPP - Main
########################################

Choose Expansion:

1 - Classic
       [Not Installed]

2 - Tbc
       [Not Installed]

3 - Wotlk
       [Not Installed]

0 - Exit
```

Select `1` (Classic) to begin. The script will detect that shared services are missing and walk you through creating them.

### 5.2 Creating the Shared Containers

For each shared container the script will ask you to supply a CTID. Use the suggested values (100, 101, 102) or any unused IDs on your Proxmox host.

**Step 1 — DB container (`spp-db`)**
Enter CTID when prompted (suggested: `100`). The script creates the container, installs MariaDB, and records the container IP in `config.env`.

**Step 2 — Web container (`spp-web`)**
Enter CTID when prompted (suggested: `101`). Uses a Debian 11 template for PHP 7.4 compatibility. Apache is installed automatically.

**Step 3 — Login container (`spp-login`)**
Enter CTID when prompted (suggested: `102`). A lightweight container that runs the realmd authentication daemon.

Expect This to Take a While: Each container creation runs `apt update`, `apt full-upgrade`, and installs its service stack. On a first run with a fresh mirror cache, expect 5–15 minutes per container depending on your internet speed. The script will pause with `Press Enter to return...` after each container is provisioned — this is normal.

---

## 6. Installing the Classic (Vanilla) Realm

### 6.1 Create the Classic Game Container

After shared services are ready, you will be returned to the Expansion Menu. Select `1 - Classic` again. The script detects that `spp-classic` does not exist and offers to create it.

```
Game container spp-classic not found.
Create it now? (y/n): y

Enter CTID for spp-classic: 103
```

The script creates the container and installs the full build toolchain: git, cmake, libssl, boost, ACE, and the MariaDB dev libraries.

### 6.2 Enter the Service Menu

Once the Classic game container exists you are automatically dropped into the Classic Service Menu:

```
1 - Stack Control
2 - Maintenance
4 - Remote Console
5 - Live World Log
6 - Autostart Status: (Off)
7 - Server Info
0 - Expansion Select
```

### 6.3 Full Installation

Select `2 - Maintenance`, then `I - Full (re)Install`. When prompted, type `YES` and press Enter.

```
Type YES to continue: YES
```

The Full Install performs these steps in order — this is the longest step and will take **30–90 minutes** depending on hardware:

**Step 1 — Compile the server**
Clones `celguar/mangos-classic` and the playerbots repo, runs cmake with all modules enabled (Achievements, Transmog, Immersive, Hardcore, Bots, AHBot, etc.), and runs `make -j$(nproc)`.

**Step 2 — Install databases**
Clones the SQL repository, then installs world, characters, realm, and logs databases. Playerbot caches are decompressed and imported.

**Step 3 — Install map data**
Downloads the pre-extracted map/dbc/vmap pack from the celguar releases (~1–2 GB). 

**Step 4 — Create systemd services**
Writes `mangosd.service` on the game container and `realmd.service` on the login container.

**Step 5 — Install website**
Deploys the SPP Armory website into the web container and imports armory database tables.

**Step 6 — Configure databases**
Updates all `.conf` files with the correct database IPs, usernames, and passwords. Creates the LAN database user.

> ** Classic Installation Complete:** When the script returns to the Service Menu without errors, Classic is installed. The realm entry is already in the database pointing to the login container IP.

---

## 7. Installing the TBC Realm

Installing TBC follows the same pattern as Classic but uses a separate game container and its own set of databases.

**Step 1 — Return to Expansion Menu**
From the Service Menu, select `0 - Expansion Select`.

**Step 2 — Select TBC**
Choose `2 - Tbc` from the Expansion Menu.

**Step 3 — Create the TBC game container**
The script will ask to create `spp-tbc`. Confirm and enter CTID `104`.

**Step 4 — Full Install TBC**
Navigate to `Maintenance → I - Full (re)Install` and type `YES`. The entire compile + DB + maps + website cycle runs again for TBC.

---

## 8. Verifying the Stack

### 8.1 Check Status

From either expansion's Service Menu, go to `1 - Stack Control → 1 - Status`. You should see something like:

```
=== STACK STATUS ===

CT 102 (spp-login) - running
  realmd.service -> active (up 4m)

CT 103 (spp-classic) - running
  mangosd.service -> active (up 3m)

CT 101 (spp-web) - running
  apache2.service -> active (up 5m)

CT 100 (spp-db) - running
  mariadb.service -> active (up 6m)
```

### 8.2 Version Panel

The Service Menu header shows installed versions:

```
Core: v48 (ike3-bots@a3f2c1d)
Bots: master@7b4e2a1
Built: 2025-03-14_10:22
World: 28
Chars: 14  Realm: 4  Maps: 2
Web: 7  Logs: 1
```
---

## 9. Post-Installation Configuration

### 9.1 Autostart

By default autostart is `Off`, meaning the game servers do not start automatically when the containers boot. To enable it, select `6 - Autostart Status` from the Service Menu. The display toggles to `On` and `systemctl enable` is run on both realmd and mangosd.

### 9.2 Admin / Remote Console Credentials

To use the in-game Remote Administration (`4 - Remote Console`), set `ADMIN_USER` and `ADMIN_PASS` in `config.env`. These match the account you grant console access in-game via the `.account set` command.

```bash
# Edit config.env on the Proxmox host
nano /opt/spp/config.env

# Set these two lines:
ADMIN_USER="your_admin_account"
ADMIN_PASS="your_admin_password"
```


## 10. Maintenance

### 10.1 Starting and Stopping

From `Service Menu → 1 - Stack Control`, the script shows a dynamic button labelled **Start Stack** or **Stop World** depending on current state. Start Stack brings up all containers in the correct order (DB → Web → Login → Game). Stop World shuts down only the game container, leaving the database and login daemon running.

### 10.2 Updating the Core (Server Binary)

Navigate to `Maintenance → 1 - Core → 2 - Incremental Update`. The script pulls the latest commits on `ike3-bots` and rebuilds only if anything changed. A full clean rebuild (option `1`) deletes `/opt/source` and recompiles from scratch — use this if an incremental update fails.

### 10.3 Database Updates

Navigate to `Maintenance → 2 - Database`. Individual update targets are available:

- `4 - Update realmd DB` — applies pending SQL patches to the authentication database
- `5 - Update characters DB` — applies pending patches to the character database
- `6 - Update PlayerBots DB` — applies bot-related world/character patches
- `1 - Install Full DB` — drops and reinstalls all databases from scratch (**destructive — all characters lost**)
- `2 - Reset Characters` — wipes characters and reimports fresh bot caches

### 10.4 Website Updates

From the main menu, select `S - Shared Services → 3 - Website → 2 - Update Website`. This pulls the latest armory site from GitHub, preserves your config files, and restarts Apache.

### 10.5 Viewing Live Logs

From the Service Menu, select `5 - Live World Log`. This tails `/var/log/mangos/Server.log` inside the game container in real time. Press `Ctrl+C` to return to the menu.

---

## 11. Troubleshooting

| Problem | Solution |
|---|---|
| Containers already exist on re-run | The script detects them via `pct list` and skips creation. Re-running is always safe. |
| "Template acquisition failed" | Run `pveam update` on the Proxmox host then re-run the script. |
| mangosd won't start after install | Check `Service Menu → 5 - Live World Log`. Usually a DB connection error. Run `Shared Services → Configuration → Apply Server Confs`. |
| Can't connect from WoW client | Confirm realmlist IP matches `spp-login` IP from Server Info. Check port 3724 is reachable. |
| Both realms show in login but only one works | Each expansion's mangosd must be running. Check status for each expansion separately. |
| Website shows blank / DB errors | Run `Shared Services → Website → Align php for website db` to re-write the PHP connection config. |
| MariaDB refuses remote connections | Run `Shared Services → Configuration → Fix mariadb configs`. This sets `bind-address = 0.0.0.0`. |
| Realm address wrong after IP change | `Service Menu → Server Info → Change Server Address`. Enter the new IP. |
| Version numbers show red | Run `Maintenance → Full (re)Install` for that expansion to bring it up to the expected version. |
| Crash logs / core dumps | `Service Menu → Server Info → 7 - Crash Logs` lists any core dump files in the install directory. |

---

## 12. Settings

 - Under 7) - Server Info you can edit the settings
```
########################################
# SPP - Classic
########################################

     _   __          _ ____
    | | / /__ ____  (_) / /__ _
    | |/ / _ `/ _ \/ / / / _ `/
    |___/\_,_/_//_/_/_/_/\_,_/



-------- Server Info --------

MySQL Host: 127.0.0.1  Port: 3306
      User: mangos

WoW Client:
  set realmlist 192.168.1.111

1 - World Settings
2 - Bots Settings
3 - RealmD Settings

4 - Change Server Address
5 - Change Realm Name
7 - Crash Logs

0 - Back

Enter your choice:
```

# _**aiplayerbot.conf**_:
  ## Find these settings:
  AiPlayerbot.MinRandomBots = 1000
  AiPlayerbot.MaxRandomBots = 1000
  AiPlayerbot.RandomBotMinLevel = 1
  AiPlayerbot.RandomBotMaxLevel = 60

 - By default bot number is 1000. If you experience lag after 30+ minutes of running the server, try lowering bot number.
 - **Important!:** if you change bot number later, you will need to do "6 - Bots Menu -> Reset Random Bots" for changes to take effect.

  AiPlayerbot.SyncQuestWithPlayer = 0
 - If you set this to 1, bots in group will automatically complete & get reward from quest (If they have it) when you complete it.
 - E.g. you take quest to loot 10 items. You have 4 bots in group, they also take it. You loot 10 items, go back and complete the quest. Bots will complete it automatically and get rewards. So you won't have to loot 40 more items. Bots will ignore looting quest items.

  AiPlayerbot.AutoLearnTrainerSpells = 0
  AiPlayerbot.AutoLearnQuestSpells = 0
 - With this set to 1 bots will learn new spells/quest spells on levelup.
 - You can leave other settings unchanged.
# _**mangosd.conf**_:
 - here you can change XP and other rates. Look for "SERVER RATES" and change them if you want.

---
