#!/bin/bash
set -euo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LAUNCHER_VERSION="22"

# -------------------------
# First Run Bootstrap
# -------------------------
CONFIG_FILE="${SCRIPT_DIR}/config.env"
declare -A GAME_CTIDS
WEBSITE_REPO="https://github.com/japtenks/SPP-Web.git"
WEBSITE_SRC_DIR="/opt/SPP-Web"

php_single_quote_escape() {
  local value="${1//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf '%s' "$value"
}

set_or_append_config_line() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}

append_config_default_line() {
  local key="$1"
  local value="$2"

  if ! grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}

normalize_config_env() {
  [[ -f "$CONFIG_FILE" ]] || return 0

  # Canonical install-path ordering is owned by the launcher and must survive old configs.
  set_or_append_config_line "ALLOWED_EXPANSIONS" '("classic" "tbc" "wotlk" "vmangos")'
  set_or_append_config_line "LAUNCHER_VERSION" "\"${DEFAULT_LAUNCHER_VERSION}\""
  append_config_default_line "LAUNCHER_GIT_BRANCH" '"unknown"'
  append_config_default_line "LAUNCHER_GIT_COMMIT" '"unknown"'

  append_config_default_line "IP_VMANGOS" '""'
  append_config_default_line "VMANGOS_CORE_VERSION" '1'
  append_config_default_line "VMANGOS_WORLD_VERSION" '1'
  append_config_default_line "VMANGOS_CHARS_VERSION" '1'
  append_config_default_line "VMANGOS_REALM_VERSION" '1'
  append_config_default_line "VMANGOS_LOGS_VERSION" '1'
  append_config_default_line "VMANGOS_BOTS_VERSION" '1'
  append_config_default_line "VMANGOS_WEBSITE_VERSION" '0'
  append_config_default_line "VMANGOS_MAPS_VERSION" '1'
  append_config_default_line "MASTER_EXPANSION" '""'
  append_config_default_line "MASTER_REALMD_DB" '""'
}

refresh_launcher_git_tracking() {
  local branch="unknown"
  local commit="unknown"

  if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    commit=$(git -C "$SCRIPT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo "unknown")
  fi

  set_or_append_config_line "LAUNCHER_GIT_BRANCH" "\"${branch}\""
  set_or_append_config_line "LAUNCHER_GIT_COMMIT" "\"${commit}\""

  LAUNCHER_GIT_BRANCH="$branch"
  LAUNCHER_GIT_COMMIT="$commit"
}

update_launcher_self() {
  echo
  echo "Updating launcher from git..."
  echo

  git -C "$SCRIPT_DIR" fetch --all --prune || {
    echo "Launcher fetch failed."
    read -p "Press Enter to continue..." _
    return 1
  }

  git -C "$SCRIPT_DIR" pull --ff-only || {
    echo "Launcher update failed."
    read -p "Press Enter to continue..." _
    return 1
  }

  chmod +x "$SCRIPT_DIR/Launcher.sh" 2>/dev/null || true

  normalize_config_env
  source "$CONFIG_FILE"
  ALLOWED_EXPANSIONS=("classic" "tbc" "wotlk" "vmangos")
  LAUNCHER_VERSION="${LAUNCHER_VERSION:-$DEFAULT_LAUNCHER_VERSION}"
  LAUNCHER_GIT_BRANCH="${LAUNCHER_GIT_BRANCH:-unknown}"
  LAUNCHER_GIT_COMMIT="${LAUNCHER_GIT_COMMIT:-unknown}"
  refresh_launcher_git_tracking

  echo
  echo "Launcher updated to ${LAUNCHER_GIT_BRANCH}@${LAUNCHER_GIT_COMMIT}."
  echo "Reloading launcher..."
  sleep 1

  exec bash "$SCRIPT_DIR/Launcher.sh"
}

auto_detect_stack() {
  local _pct
  _pct=$(pct list) || return
  DB_CTID=$(awk '$3=="spp-db"    {print $1}' <<< "$_pct") || true
  WEB_CTID=$(awk '$3=="spp-web"  {print $1}' <<< "$_pct") || true
  LOGIN_CTID=$(awk '$3=="spp-login" {print $1}' <<< "$_pct") || true
  local _exp _ct
  for _exp in classic tbc wotlk vmangos; do
    _ct=$(awk -v name="spp-$_exp" '$3==name {print $1}' <<< "$_pct") || true
    [[ -n "$_ct" ]] && GAME_CTIDS[$_exp]=$_ct
  done
  return 0
}

if [[ ! -f $CONFIG_FILE ]]; then
  echo "Config missing. Attempting auto-detection..."
  auto_detect_stack

  if [[ -n "$DB_CTID" ]]; then
    echo "Existing containers detected. Rebuilding config..."
    DB_ROOT_PASS=""
    GAME_CORES=4
    GAME_RAM=4096
    STORAGE_CHOICE=$(pvesm status | awk '$2 ~ /lvmthin|zfs|btrfs/ && $3=="active" {print $1; exit}')
    [[ -z "$STORAGE_CHOICE" ]] && STORAGE_CHOICE="local-lvm"

    # Still need credentials even on rebuild
    read -p "DB root password: " DB_ROOT_PASS
    read -p "DB LAN username (e.g. sppuser): " DB_LAN_USER
    read -sp "DB LAN password: " DB_LAN_PASS; echo
    read -p "DB LAN host (% for any, or specific IP): " DB_LAN_HOST
    DB_LAN_HOST="${DB_LAN_HOST:-%}"
    read -p "RA admin username: " ADMIN_USER
    read -sp "RA admin password: " ADMIN_PASS; echo

  else
    echo "No stack detected. Running First Run Bootstrap."
    echo

    # --- Credentials ---
    read -p "DB root password: " DB_ROOT_PASS
    read -p "DB LAN username (e.g. sppuser): " DB_LAN_USER
    read -sp "DB LAN password: " DB_LAN_PASS; echo
    read -p "DB LAN host (% for any, or specific IP) [%]: " DB_LAN_HOST
    DB_LAN_HOST="${DB_LAN_HOST:-%}"
    read -p "RA admin username: " ADMIN_USER
    read -sp "RA admin password: " ADMIN_PASS; echo
    echo

    # --- Container resources ---
    read -p "LXC Game Cores [4]: " GAME_CORES
    GAME_CORES="${GAME_CORES:-4}"
    read -p "LXC Game RAM (MB) [16384]: " GAME_RAM
    GAME_RAM="${GAME_RAM:-16384}"
    echo

    # --- Storage ---
    mapfile -t STORAGE_LIST < <(pvesm status | awk '$3=="active"{print $1}')
    echo "Select storage:"
    select STORAGE_CHOICE in "${STORAGE_LIST[@]}"; do
      [[ -n "$STORAGE_CHOICE" ]] && break
    done
    echo
  fi

  # --- Network mode (shared for all containers) ---
  echo "Network mode for containers:"
  echo "  1) DHCP (automatic)"
  echo "  2) Static IPs (you assign per container)"
  read -p "Selection [1]: " NET_SEL
  NET_SEL="${NET_SEL:-1}"

  if [[ "$NET_SEL" == "2" ]]; then
    NETWORK_MODE="static"
    echo
    echo "Enter static IP config (CIDR format, e.g. 192.168.1.10/24)"
    read -p "  Bridge (e.g. vmbr0) [vmbr0]: " NET_BRIDGE
    NET_BRIDGE="${NET_BRIDGE:-vmbr0}"
    read -p "  Gateway: " NET_GW
    read -p "  spp-db   IP: " IP_DB
    read -p "  spp-web  IP: " IP_WEB
    read -p "  spp-login IP: " IP_LOGIN
    read -p "  spp-classic IP (leave blank to skip): " IP_CLASSIC
    read -p "  spp-tbc     IP (leave blank to skip): " IP_TBC
    read -p "  spp-wotlk   IP (leave blank to skip): " IP_WOTLK
    read -p "  spp-vmangos IP (leave blank to skip): " IP_VMANGOS
  else
    NETWORK_MODE="dhcp"
    NET_BRIDGE="vmbr0"
    NET_GW=""
    IP_DB="" IP_WEB="" IP_LOGIN=""
    IP_CLASSIC="" IP_TBC="" IP_WOTLK="" IP_VMANGOS=""
  fi
  echo

  # --- Template acquisition ---
  TEMPLATE_NAME=$(pveam list local | awk '/debian-[0-9]+-standard/ && !/testing/ {print $1}' | sort -V | tail -n1)
  if [[ -z "$TEMPLATE_NAME" ]]; then
    echo "Fetching latest Debian template..."
    pveam update
    TEMPLATE_NAME=$(pveam available | awk '/debian-[0-9]+-standard/ && !/testing/ {print $2}' | sort -V | tail -n1)
    pveam download local "$TEMPLATE_NAME"
  fi
  if [[ -z "$TEMPLATE_NAME" ]]; then
    echo "Template acquisition failed."
    exit 1
  fi

  # ---- Write full base config ----
  cat <<EOF > "$CONFIG_FILE"
ALLOWED_EXPANSIONS=("classic" "tbc" "wotlk" "vmangos")
INSTALLED_EXPANSIONS=()
LAUNCHER_VERSION="$DEFAULT_LAUNCHER_VERSION"
LAUNCHER_GIT_BRANCH="unknown"
LAUNCHER_GIT_COMMIT="unknown"
AUTO_START="0"
ASV="Off"

DB_HOST=""
DB_PORT=""
DB_ROOT_PASS="$DB_ROOT_PASS"
DB_LAN_USER="$DB_LAN_USER"
DB_LAN_PASS="$DB_LAN_PASS"
DB_LAN_HOST="$DB_LAN_HOST"
ADMIN_USER="$ADMIN_USER"
ADMIN_PASS="$ADMIN_PASS"

MARIADB_CORES=2
MARIADB_RAM=4096
MARIADB_DISK=16
LOGIN_CORES=1
LOGIN_RAM=1024
LOGIN_DISK=8
GAME_CORES=$GAME_CORES
GAME_RAM=$GAME_RAM
GAME_DISK=32
WEBSITE_CORES=2
WEBSITE_RAM=2048
WEBSITE_DISK=16

DEFAULT_STORAGE="$STORAGE_CHOICE"
DEFAULT_TEMPLATE="$TEMPLATE_NAME"

NETWORK_MODE="$NETWORK_MODE"
NET_BRIDGE="$NET_BRIDGE"
NET_GW="$NET_GW"
IP_DB="$IP_DB"
IP_WEB="$IP_WEB"
IP_LOGIN="$IP_LOGIN"
IP_CLASSIC="$IP_CLASSIC"
IP_TBC="$IP_TBC"
IP_WOTLK="$IP_WOTLK"
IP_VMANGOS="$IP_VMANGOS"

# Version Tracking
CLASSIC_CORE_VERSION=48
CLASSIC_WORLD_VERSION=28
CLASSIC_CHARS_VERSION=14
CLASSIC_REALM_VERSION=4
CLASSIC_LOGS_VERSION=1
CLASSIC_BOTS_VERSION=27
CLASSIC_WEBSITE_VERSION=7
CLASSIC_MAPS_VERSION=2
TBC_CORE_VERSION=43
TBC_WORLD_VERSION=22
TBC_CHARS_VERSION=14
TBC_REALM_VERSION=4
TBC_LOGS_VERSION=1
TBC_BOTS_VERSION=26
TBC_WEBSITE_VERSION=5
TBC_MAPS_VERSION=2
WOTLK_CORE_VERSION=25
WOTLK_WORLD_VERSION=18
WOTLK_CHARS_VERSION=7
WOTLK_REALM_VERSION=4
WOTLK_LOGS_VERSION=1
WOTLK_BOTS_VERSION=17
WOTLK_WEBSITE_VERSION=6
WOTLK_MAPS_VERSION=2
VMANGOS_CORE_VERSION=1
VMANGOS_WORLD_VERSION=1
VMANGOS_CHARS_VERSION=1
VMANGOS_REALM_VERSION=1
VMANGOS_LOGS_VERSION=1
VMANGOS_BOTS_VERSION=1
VMANGOS_WEBSITE_VERSION=0
VMANGOS_MAPS_VERSION=1
MASTER_EXPANSION=""
MASTER_REALMD_DB=""

# Module build toggles (ON/OFF) — edit via Launcher "Configure Modules" or directly
MODULE_ACHIEVEMENTS=ON
MODULE_IMMERSIVE=ON
MODULE_HARDCORE=ON
MODULE_TRANSMOG=ON
MODULE_DUALSPEC=ON
MODULE_BOOST=ON
MODULE_CUSTOM20=ON
MODULE_BALANCING=ON
MODULE_BARBER=ON
MODULE_TRAININGDUMMIES=ON
MODULE_VOICEOVER=ON
MODULE_EXTRACOMMANDS=ON
EOF
  echo "config.env created."
fi

normalize_config_env
source "$CONFIG_FILE"

# Keep install-path ordering canonical even if an older config.env exists.
ALLOWED_EXPANSIONS=("classic" "tbc" "wotlk" "vmangos")
LAUNCHER_VERSION="${LAUNCHER_VERSION:-$DEFAULT_LAUNCHER_VERSION}"
LAUNCHER_GIT_BRANCH="${LAUNCHER_GIT_BRANCH:-unknown}"
LAUNCHER_GIT_COMMIT="${LAUNCHER_GIT_COMMIT:-unknown}"
refresh_launcher_git_tracking

DB_CTID="${DB_CTID:-}"
WEB_CTID="${WEB_CTID:-}"
LOGIN_CTID="${LOGIN_CTID:-}"
GAME_CTID="${GAME_CTID:-}"
EXPANSION=""

declare -A VERSION_MAP
for EXP in classic tbc wotlk vmangos; do
  KEY=$(echo "$EXP" | tr '[:lower:]' '[:upper:]')
  for TYPE in WORLD CORE REALM CHARS LOGS MAPS WEBSITE; do
    VAR="${KEY}_${TYPE}_VERSION"
    VERSION_MAP["$EXP:$TYPE"]="${!VAR:-0}"
  done
done

expansion_title() {
  case "$1" in
    vmangos) echo "vMaNGOS" ;;
    *) echo "${1^}" ;;
  esac
}

expansion_settings_key() {
  case "$1" in
    classic) echo "vanilla" ;;
    tbc|wotlk|vmangos) echo "$1" ;;
    *) return 1 ;;
  esac
}

expansion_install_dir() {
  case "$1" in
    classic) echo "/srv/mangos-classic" ;;
    tbc) echo "/srv/mangos-tbc" ;;
    wotlk) echo "/srv/mangos-wotlk" ;;
    vmangos) echo "/srv/vmangos" ;;
    *) return 1 ;;
  esac
}

expansion_repo() {
  case "$1" in
    classic) echo "https://github.com/japtenks/mangos-classic.git" ;;
    tbc) echo "https://github.com/celguar/mangos-tbc.git" ;;
    wotlk) echo "https://github.com/celguar/mangos-wotlk.git" ;;
    vmangos) echo "https://github.com/vmangos/core.git" ;;
    *) return 1 ;;
  esac
}

expansion_branch() {
  case "$1" in
    classic|tbc|wotlk) echo "ike3-bots" ;;
    vmangos) echo "vmangos-ike3-playerbots" ;;
    *) return 1 ;;
  esac
}

expansion_realm_db_name() {
  case "$1" in
    classic) echo "classicrealmd" ;;
    tbc) echo "tbcrealmd" ;;
    wotlk) echo "wotlkrealmd" ;;
    vmangos) echo "vmangosrealmd" ;;
    *) return 1 ;;
  esac
}

expansion_realm_id() {
  case "$1" in
    classic) echo 1 ;;
    tbc) echo 2 ;;
    wotlk) echo 3 ;;
    vmangos) echo 4 ;;
    *) return 1 ;;
  esac
}

expansion_world_db_name() {
  case "$1" in
    classic) echo "classicmangos" ;;
    tbc) echo "tbcmangos" ;;
    wotlk) echo "wotlkmangos" ;;
    *) return 1 ;;
  esac
}

expansion_char_db_name() {
  case "$1" in
    classic) echo "classiccharacters" ;;
    tbc) echo "tbccharacters" ;;
    wotlk) echo "wotlkcharacters" ;;
    *) return 1 ;;
  esac
}

expansion_armory_db_name() {
  case "$1" in
    classic) echo "classicarmory" ;;
    tbc) echo "tbcarmory" ;;
    wotlk) echo "wotlkarmory" ;;
    *) return 1 ;;
  esac
}

expansion_bots_db_name() {
  case "$1" in
    classic) echo "classicplayerbots" ;;
    tbc) echo "tbcplayerbots" ;;
    wotlk) echo "wotlkplayerbots" ;;
    *) return 1 ;;
  esac
}

website_realm_map_php() {
  local master_realm_db="$1"
  local included=0

  echo "["
  for realm_exp in classic tbc wotlk; do
    if [[ -n "${GAME_CTIDS[$realm_exp]:-}" || "$realm_exp" == "${EXPANSION:-}" ]]; then
      local realm_id world_db char_db armory_db bots_db
      realm_id=$(expansion_realm_id "$realm_exp") || continue
      world_db=$(expansion_world_db_name "$realm_exp") || continue
      char_db=$(expansion_char_db_name "$realm_exp") || continue
      armory_db=$(expansion_armory_db_name "$realm_exp") || continue
      bots_db=$(expansion_bots_db_name "$realm_exp") || continue
      included=1
      cat <<EOF
    ${realm_id} => [
        'realmd' => '${master_realm_db}',
        'world' => '${world_db}',
        'chars' => '${char_db}',
        'armory' => '${armory_db}',
        'bots' => '${bots_db}',
    ],
EOF
    fi
  done
  if [[ $included -eq 0 && ! is_vmangos ]]; then
    local realm_id world_db char_db armory_db bots_db
    realm_id=$(expansion_realm_id "$EXPANSION") || true
    world_db=$(expansion_world_db_name "$EXPANSION") || true
    char_db=$(expansion_char_db_name "$EXPANSION") || true
    armory_db=$(expansion_armory_db_name "$EXPANSION") || true
    bots_db=$(expansion_bots_db_name "$EXPANSION") || true
    if [[ -n "${realm_id:-}" && -n "${world_db:-}" ]]; then
      cat <<EOF
    ${realm_id} => [
        'realmd' => '${master_realm_db}',
        'world' => '${world_db}',
        'chars' => '${char_db}',
        'armory' => '${armory_db}',
        'bots' => '${bots_db}',
    ],
EOF
    fi
  fi
  echo "]"
}

website_enabled_realm_ids_php() {
  local ids=()
  local realm_exp
  for realm_exp in classic tbc wotlk; do
    if [[ -n "${GAME_CTIDS[$realm_exp]:-}" || "$realm_exp" == "${EXPANSION:-}" ]]; then
      ids+=("$(expansion_realm_id "$realm_exp")")
    fi
  done
  if [[ ${#ids[@]} -eq 0 && ! is_vmangos ]]; then
    ids+=("$(expansion_realm_id "$EXPANSION")")
  fi
  local joined
  joined=$(IFS=,; echo "${ids[*]}")
  echo "[${joined}]"
}

is_vmangos() {
  [[ "${1:-$EXPANSION}" == "vmangos" ]]
}

is_shared_classic_family() {
  case "${1:-$EXPANSION}" in
    classic|tbc|wotlk) return 0 ;;
    *) return 1 ;;
  esac
}

owns_realm_install_lane() {
  is_vmangos || is_master
}

realm_version_owner() {
  if is_vmangos; then
    echo "$EXPANSION"
  else
    echo "${MASTER_EXPANSION:-$EXPANSION}"
  fi
}

resolve_shared_master_expansion() {
  local candidate

  if [[ -n "${MASTER_EXPANSION:-}" ]] && is_shared_classic_family "$MASTER_EXPANSION"; then
    echo "$MASTER_EXPANSION"
    return 0
  fi

  for candidate in classic tbc wotlk; do
    if [[ -n "${GAME_CTIDS[$candidate]:-}" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  if is_shared_classic_family "${EXPANSION:-}"; then
    echo "$EXPANSION"
    return 0
  fi

  return 1
}

ensure_shared_classic_context() {
  local shared_expansion
  auto_detect_stack
  shared_expansion=$(resolve_shared_master_expansion) || {
    echo "Shared services are only available for Classic, TBC, or WotLK install paths."
    echo "Install one of options 1-3 first, then use Shared Services."
    return 1
  }

  EXPANSION="$shared_expansion"
  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"
  if [[ -z "${GAME_CTID:-}" ]]; then
    echo "Shared master install path '$EXPANSION' is not installed yet."
    echo "Install the selected Classic/TBC/WotLK path before using shared website or shared config tools."
    return 1
  fi
}

run_with_shared_classic_context() {
  local target_fn="$1"
  shift

  local saved_expansion="${EXPANSION:-}"
  local saved_game_ctid="${GAME_CTID:-}"
  local rc=0

  ensure_shared_classic_context || return 1
  "$target_fn" "$@" || rc=$?

  EXPANSION="$saved_expansion"
  GAME_CTID="$saved_game_ctid"
  return $rc
}


#helper functions
get_storage() {
  echo "$DEFAULT_STORAGE"
}
# Resolve the IP for this container role
get_container_ip() {
  local ROLE=$1
  case "$ROLE" in
    mariadb) echo "${IP_DB:-}" ;;
    website) echo "${IP_WEB:-}" ;;
    login)   echo "${IP_LOGIN:-}" ;;
    game)
      case "${EXPANSION:-}" in
        classic) echo "${IP_CLASSIC:-}" ;;
        tbc)     echo "${IP_TBC:-}" ;;
        wotlk)   echo "${IP_WOTLK:-}" ;;
        vmangos) echo "${IP_VMANGOS:-}" ;;
      esac ;;
  esac
}

create_container() {
  local NAME=$1
  local ROLE_TYPE=$2
  local CTID=$3
  local START_ORDER=$4

if pct status "$CTID" &>/dev/null; then
  echo "CTID $CTID already exists. Skipping $NAME."
  return
fi

  case $ROLE_TYPE in
    mariadb) CORES=$MARIADB_CORES; RAM=$MARIADB_RAM; DISK=$MARIADB_DISK ;;
    website) CORES=$WEBSITE_CORES; RAM=$WEBSITE_RAM; DISK=$WEBSITE_DISK ;;
    login)   CORES=$LOGIN_CORES;   RAM=$LOGIN_RAM;   DISK=$LOGIN_DISK ;;
    game)    CORES=$GAME_CORES;    RAM=$GAME_RAM;    DISK=$GAME_DISK ;;
    *) echo "Unknown role $ROLE_TYPE"; return 1 ;;
  esac

  STORAGE=$(get_storage)

  if [[ "$ROLE_TYPE" == "website" ]]; then
    ensure_web_template || return 1
    TEMPLATE="$WEB_TEMPLATE_FULL"
  else
    TEMPLATE="$DEFAULT_TEMPLATE"
  fi

CONTAINER_IP=$(get_container_ip "$ROLE_TYPE")

if [[ "${NETWORK_MODE:-dhcp}" == "static" && -n "$CONTAINER_IP" ]]; then
  NET_ARG="name=eth0,bridge=${NET_BRIDGE},ip=${CONTAINER_IP},gw=${NET_GW}"
else
  NET_ARG="name=eth0,bridge=${NET_BRIDGE:-vmbr0},ip=dhcp"
fi

CMD=(
  pct create "$CTID" "$TEMPLATE"
  --hostname "$NAME"
  --cores "$CORES"
  --memory "$RAM"
  --rootfs "${STORAGE}:${DISK}"
  --net0 "$NET_ARG"
  --unprivileged 1
  --onboot 1
  --startup order="$START_ORDER"
  --features nesting=1
  --features keyctl=1
)

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY RUN]"
    printf '%q ' "${CMD[@]}"
    echo
    return
  fi

  "${CMD[@]}"
  pct start "$CTID"

  echo "Provisioning base OS inside $NAME..."
  printf '%q ' "${CMD[@]}"
  echo
  read -p "Press Enter to return..." _

  pct exec "$CTID" -- bash -c "
  set -euo pipefail
  apt update
  apt -y full-upgrade
  apt install -y locales
  sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
  "

  case "$ROLE_TYPE" in
mariadb)
  pct exec "$CTID" -- apt install -y mariadb-server git p7zip-full
  pct exec "$CTID" -- systemctl enable mariadb
  # Fix bind address immediately so it's never on 127.0.0.1
  pct exec "$CTID" -- bash -c "
    sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
    systemctl restart mariadb
  "
  DB_HOST=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
  sed -i "s/^DB_HOST=.*/DB_HOST=\"$DB_HOST\"/" "$CONFIG_FILE"
  ;;
    website)
      pct exec "$CTID" -- bash -c "
      set -e

      cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian bullseye main contrib non-free
deb http://archive.debian.org/debian bullseye-updates main contrib non-free
EOF

      echo 'Acquire::Check-Valid-Until false;' > /etc/apt/apt.conf.d/99no-check-valid

      apt update

      "

      pct exec "$CTID" -- apt install -y \
        apache2 git \
        php7.4 libapache2-mod-php7.4 \
        php7.4-mysql php7.4-curl php7.4-gd \
        php7.4-xml php7.4-mbstring php7.4-zip php7.4-intl \
        wget p7zip-full rsync php-gmp

      pct exec "$CTID" -- systemctl enable apache2

      WEB_CTID="$CTID"
      
      ;;
    game)
      pct exec "$CTID" -- apt install -y \
        git build-essential cmake \
        mariadb-client rsync \
        libssl-dev libbz2-dev libreadline-dev \
        libcurl4-openssl-dev zlib1g-dev \
        libncurses-dev libmariadb-dev libmariadb-dev-compat \
        libboost-all-dev libace-dev unzip wget p7zip-full \
        gdb
      ;;
    login)
      pct exec "$CTID" -- apt install -y libmariadb3 libssl3
      ;;
  esac
   
  echo "$NAME Setup. Install Services"
  echo
  read -p "Press Enter to return..." _
}

ensure_web_template() {

  WEB_TEMPLATE="debian-11-standard_11.7-1_amd64.tar.zst"
 TEMPLATE_STORAGE="local"
  CACHE_DIR="/var/lib/vz/template/cache"

  if [[ ! -f "${CACHE_DIR}/${WEB_TEMPLATE}" ]]; then
    echo "Downloading Debian 11 template for legacy web..."

    cd "$CACHE_DIR" || return 1
    wget -q "http://download.proxmox.com/images/system/${WEB_TEMPLATE}"

    if [[ ! -f "${CACHE_DIR}/${WEB_TEMPLATE}" ]]; then
      echo "Failed to download web template."
      return 1
    fi
  fi

 WEB_TEMPLATE_FULL="${TEMPLATE_STORAGE}:vztmpl/${WEB_TEMPLATE}"
}

derive_db_names() {
  case "$EXPANSION" in
    classic) DB_KEY="classic"; MAP_KEY="vanilla" ;;
    tbc)     DB_KEY="tbc";     MAP_KEY="tbc" ;;
    wotlk)   DB_KEY="wotlk";   MAP_KEY="wotlk" ;;
    vmangos) DB_KEY="vmangos"; MAP_KEY="vmangos" ;;
    *) echo "Unknown expansion: $EXPANSION"; return 1 ;;
  esac

  if is_vmangos; then
    WORLD_DB="${DB_KEY}"
  else
    WORLD_DB="${DB_KEY}mangos"
  fi
  CHAR_DB_NAME="${DB_KEY}characters"
  LOG_DB_NAME="${DB_KEY}logs"
  SETTINGS_KEY=$(expansion_settings_key "$EXPANSION") || return 1
  INSTALL_DIR=$(expansion_install_dir "$EXPANSION") || return 1
  EXPANSION_TITLE=$(expansion_title "$EXPANSION")

  if is_vmangos; then
    REALM_DB_NAME=$(expansion_realm_db_name "$EXPANSION") || return 1
  elif [[ -n "${MASTER_REALMD_DB:-}" ]]; then
    REALM_DB_NAME="$MASTER_REALMD_DB"
  elif [[ -n "${MASTER_EXPANSION:-}" ]] && is_shared_classic_family "$MASTER_EXPANSION"; then
    REALM_DB_NAME=$(expansion_realm_db_name "$MASTER_EXPANSION") || {
      echo "Unknown master expansion: $MASTER_EXPANSION"
      return 1
    }
  else
    REALM_DB_NAME=$(expansion_realm_db_name "$EXPANSION") || return 1
  fi
  REALM_ID=$(expansion_realm_id "$EXPANSION") || return 1
}

set_config_value() {
  local KEY=$1
  local VALUE=$2
  if grep -q "^${KEY}=" "$CONFIG_FILE"; then
    sed -i "s|^${KEY}=.*|${KEY}=\"${VALUE}\"|" "$CONFIG_FILE"
  else
    printf '%s="%s"\n' "$KEY" "$VALUE" >> "$CONFIG_FILE"
  fi
}

pin_master_expansion() {
  if [[ -z "${MASTER_EXPANSION:-}" ]] || { is_vmangos "$MASTER_EXPANSION" && is_shared_classic_family; }; then
    MASTER_EXPANSION="$EXPANSION"
    set_config_value "MASTER_EXPANSION" "$MASTER_EXPANSION"
    echo "Pinned master expansion: $MASTER_EXPANSION"
  else
    echo "Master expansion already pinned: $MASTER_EXPANSION"
  fi
}

pin_master_realmd_db() {
  if ! is_shared_classic_family; then
    echo "vMaNGOS uses a dedicated realm DB and does not pin MASTER_REALMD_DB."
    return 0
  fi

  if [[ -z "${MASTER_REALMD_DB:-}" ]]; then
    MASTER_REALMD_DB=$(expansion_realm_db_name "$EXPANSION") || return 1
    set_config_value "MASTER_REALMD_DB" "$MASTER_REALMD_DB"
    echo "Pinned master realmd DB: $MASTER_REALMD_DB"
  else
    echo "Master realmd DB already pinned: $MASTER_REALMD_DB"
  fi
}

sync_realmd_db_version_markers() {
  derive_db_names || return 1

  if is_vmangos; then
    echo "Skipping realmd_db_version sync for vMaNGOS."
    return 0
  fi

  local SHARED_REALMD_DB="${MASTER_REALMD_DB:-$REALM_DB_NAME}"
  if [[ "$REALM_DB_NAME" != "$SHARED_REALMD_DB" ]]; then
    echo "Keeping dedicated realmd_db_version markers in ${REALM_DB_NAME}."
    return 0
  fi

  local SINGLE_REALMD_SQL="/opt/spp-sql/sql/${MAP_KEY}/updates/realmd/5/single_realmd.sql"
  if pct exec "$DB_CTID" -- bash -c "
    set -euo pipefail
    export MYSQL_PWD='${DB_ROOT_PASS}'
    test -f '${SINGLE_REALMD_SQL}'
    mariadb -u root '${REALM_DB_NAME}' < '${SINGLE_REALMD_SQL}'
  "; then
    echo "Applied shared realmd_db_version markers to ${REALM_DB_NAME}."
  else
    echo "Failed applying shared realmd_db_version markers to ${REALM_DB_NAME}."
    return 1
  fi
}

is_master() {
  [[ "${EXPANSION}" == "${MASTER_EXPANSION:-}" ]]
}

write_version() {
  local FILE=$1
  local VALUE=$2
  pct exec "$DB_CTID" -- bash -c "echo \"$VALUE\" > /opt/$FILE"
}

update_world() {

  derive_db_names || return 1

  sync_repo || return 1

  BASE="/opt/spp-sql/sql/${MAP_KEY}/updates/world"
  VERSION_FILE="/opt/${EXPANSION}_world_version.spp"

  CURRENT=$(pct exec "$DB_CTID" -- cat "$VERSION_FILE" 2>/dev/null | cut -d'|' -f1 || echo 0)

  LATEST=$(pct exec "$DB_CTID" -- bash -c \
    "ls $BASE 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1")

  [[ -z "$LATEST" ]] && echo "No world updates found." && return
  (( LATEST <= CURRENT )) && echo "World DB already up to date." && return

  for DIR in $(pct exec "$DB_CTID" -- bash -c \
      "ls $BASE | grep -E '^[0-9]+$' | sort -n"); do

    if (( DIR > CURRENT )); then
      echo "Applying world update $DIR..."

      for f in $(pct exec "$DB_CTID" -- bash -c "ls $BASE/$DIR/*.sql"); do
        pct exec "$DB_CTID" -- mariadb \
          -u root -p"$DB_ROOT_PASS" "$WORLD_DB" < "$f"
      done

      write_version "${EXPANSION}_world_version.spp" "$DIR|$(date +%F_%H:%M)"
    fi
  done

  echo "World DB updated."
}

create_lan_db_user() {
  derive_db_names || return 1

  local ARMORY_DB="${EXPANSION}armory"

  # Build the GRANT list — always include this expansion's DBs
  local GRANTS="
    CREATE USER IF NOT EXISTS '${DB_LAN_USER}'@'${DB_LAN_HOST}' IDENTIFIED BY '${DB_LAN_PASS}';
    GRANT ALL PRIVILEGES ON ${WORLD_DB}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
    GRANT ALL PRIVILEGES ON ${CHAR_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
    GRANT ALL PRIVILEGES ON ${LOG_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
    GRANT ALL PRIVILEGES ON ${ARMORY_DB}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  "

  # Always grant realm DB access (shared, owned by master)
  GRANTS+="GRANT ALL PRIVILEGES ON ${REALM_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';"
  GRANTS+="FLUSH PRIVILEGES;"

  pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root -e \"${GRANTS}\"
  "
}

stat_state() {
  if pct exec "$GAME_CTID" -- systemctl is-active --quiet mangosd 2>/dev/null; then
    STACK_STATUS="Running"
    STACK_ACTION="Stop World"
  else
    STACK_STATUS="Stopped"
    STACK_ACTION="Start Stack"
  fi

  BOT_ROTATION_STATUS=$(get_bot_rotation_status)
}

manage_bot_rotation_pause() {
  local ACTION=${1:-status}
  local REASON=${2:-manual}

  pct exec "$GAME_CTID" -- bash -s -- "$ACTION" "$REASON" <<'__SPP_BOT_ROTATION_STATE__'
set -euo pipefail

action="$1"
reason="$2"
cron_file="/etc/cron.d/spp-bot-rotation-log"
disabled_file="${cron_file}.disabled"
tracker_dir="/var/lib/spp"
tracker_file="${tracker_dir}/bot-rotation-mangosd.state"

mkdir -p "$tracker_dir"

pause_count=0
mismatch_count=0
last_action="none"
last_reason="none"
last_updated="never"

if [[ -f "$tracker_file" ]]; then
  # shellcheck disable=SC1090
  source "$tracker_file"
fi

get_actual_status() {
  if [[ -f "$cron_file" ]]; then
    echo "active"
  elif [[ -f "$disabled_file" ]]; then
    echo "paused"
  else
    echo "missing"
  fi
}

restart_cron_if_present() {
  if systemctl list-unit-files cron.service >/dev/null 2>&1; then
    systemctl restart cron
  fi
}

actual_status=$(get_actual_status)

case "$action" in
  pause)
    pause_count=$((pause_count + 1))
    if [[ "$actual_status" == "active" ]]; then
      mv "$cron_file" "$disabled_file"
      restart_cron_if_present
      actual_status="paused"
    fi
    ;;
  resume)
    if (( pause_count > 0 )); then
      pause_count=$((pause_count - 1))
    else
      mismatch_count=$((mismatch_count + 1))
    fi

    if (( pause_count == 0 )) && [[ "$actual_status" == "paused" ]]; then
      mv "$disabled_file" "$cron_file"
      restart_cron_if_present
      actual_status="active"
    fi
    ;;
  status)
    ;;
  *)
    echo "invalid-action:$action"
    exit 1
    ;;
esac

last_action="$action"
actual_status=$(get_actual_status)

if [[ "$action" != "status" ]]; then
last_reason="$reason"
last_updated=$(date -Iseconds)

cat > "$tracker_file" <<EOF
pause_count=$pause_count
mismatch_count=$mismatch_count
last_action="$last_action"
last_reason="$last_reason"
last_updated="$last_updated"
actual_status="$actual_status"
EOF
fi

printf 'status=%s pause_count=%s mismatches=%s last_action=%s reason=%s updated=%s\n' \
  "$actual_status" "$pause_count" "$mismatch_count" "$last_action" "$last_reason" "$last_updated"
__SPP_BOT_ROTATION_STATE__
}

get_bot_rotation_status() {
  if [[ -z "${GAME_CTID:-}" ]]; then
    echo "unknown"
    return
  fi

  if [[ "$(pct status "$GAME_CTID" | awk '{print $2}')" != "running" ]]; then
    echo "unavailable (game container stopped)"
    return
  fi

  local TRACKER
  TRACKER=$(manage_bot_rotation_pause status "status-check" 2>/dev/null || true)

  if [[ -z "$TRACKER" ]]; then
    echo "unknown"
    return
  fi

  local STATUS PAUSES MISMATCHES
  STATUS=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^status=/) {sub(/^status=/,"",$i); print $i}}' <<< "$TRACKER")
  PAUSES=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^pause_count=/) {sub(/^pause_count=/,"",$i); print $i}}' <<< "$TRACKER")
  MISMATCHES=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^mismatches=/) {sub(/^mismatches=/,"",$i); print $i}}' <<< "$TRACKER")

  if [[ -z "$STATUS" ]]; then
    echo "unknown"
    return
  fi

  echo "${STATUS} (holds=${PAUSES:-0}, mismatches=${MISMATCHES:-0})"
}

stop_mangosd_managed() {
  local REASON=${1:-manual-stop}

  manage_bot_rotation_pause pause "$REASON" >/dev/null
  pct exec "$GAME_CTID" -- systemctl stop mangosd 2>/dev/null || true
}

start_mangosd_managed() {
  local REASON=${1:-manual-start}

  if pct exec "$GAME_CTID" -- systemctl start mangosd 2>/dev/null; then
    manage_bot_rotation_pause resume "$REASON" >/dev/null
  else
    echo "mangosd failed to start; bot rotation cron left unchanged."
    return 1
  fi
}

print_banner() {
  local EXP="${EXPANSION:-main}"
  local COLOR LOGO
  local CLEAR="\e[0m"
  local BANNER_VERSION="${LAUNCHER_VERSION:-$DEFAULT_LAUNCHER_VERSION}"
  local BANNER_BRANCH="${LAUNCHER_GIT_BRANCH:-unknown}"
  local BANNER_COMMIT="${LAUNCHER_GIT_COMMIT:-unknown}"

  case "$EXP" in
    tbc)
      COLOR="\e[32m"
      LOGO="
           ______  ___    _____
          /_  __/ / _ )  / ___/
           / /   / _  | / /__
          /_/   /____/  \___/
"
      ;;
    classic)
      COLOR="\e[33m"
      LOGO="
     _   __          _ ____
    | | / /__ ____  (_) / /__ _
    | |/ / _ \`/ _ \/ / / / _ \`/
    |___/\_,_/_//_/_/_/_/\_,_/
"
      ;;
    wotlk)
      COLOR="\e[36m"
      LOGO="
     _      __     __  __   __ __
    | | /| / /__  / /_/ /  / //_/
    | |/ |/ / _ \/ __/ /__/ ,
    |__/|__/\___/\__/____/_/|_|
"
      ;;
    *)
      COLOR="\e[0m"
      LOGO="
   ____  ____  ____
  / ___||  _ \|  _ \\
  \___ \| |_) | |_) |
   ___) |  __/|  __/
  |____/|_|   |_|roxmox v.${BANNER_VERSION}
"
      ;;
  esac

  clear
  echo -e "$COLOR"
  echo "########################################"
  echo "# SPP - ${EXP^}"
  echo "########################################"
  echo -e "$LOGO"
  echo "Launcher Git: ${BANNER_BRANCH}@${BANNER_COMMIT}"
  echo -e "$CLEAR"
}

print_version() {
  [[ -z "${DB_CTID:-}" ]] && return

  local RAW
  RAW=$(pct exec "$DB_CTID" -- bash -c "
    for f in core world chars realm logs maps website; do
      FILE=\"/opt/${EXPANSION}_\${f}_version.spp\"
      if [[ -f \"\$FILE\" ]]; then
        echo \"\${f}:\$(cat \$FILE)\"
      else
        echo \"\${f}:NOT_INSTALLED\"
      fi
    done
  " 2>/dev/null) || RAW=""

  local CORE_RAW WORLD_RAW CHARS_RAW REALM_RAW LOGS_RAW MAPS_RAW WEB_RAW
  CORE_RAW=$(grep  '^core:'    <<< "$RAW" | cut -d: -f2-)
  WORLD_RAW=$(grep '^world:'   <<< "$RAW" | cut -d: -f2-)
  CHARS_RAW=$(grep '^chars:'   <<< "$RAW" | cut -d: -f2-)
  REALM_RAW=$(grep '^realm:'   <<< "$RAW" | cut -d: -f2-)
  LOGS_RAW=$(grep  '^logs:'    <<< "$RAW" | cut -d: -f2-)
  MAPS_RAW=$(grep  '^maps:'    <<< "$RAW" | cut -d: -f2-)
  WEB_RAW=$(grep   '^website:' <<< "$RAW" | cut -d: -f2-)

  local CORE_VER CORE_BRANCH CORE_COMMIT BOT_BRANCH BOT_COMMIT BUILD_DATE
  IFS='|' read -r CORE_VER CORE_BRANCH CORE_COMMIT BOT_BRANCH BOT_COMMIT BUILD_DATE <<< "$CORE_RAW"

  local WORLD_VER; IFS='|' read -r WORLD_VER _ <<< "$WORLD_RAW"
  local CHARS_VER; IFS='|' read -r CHARS_VER _ <<< "$CHARS_RAW"
  local REALM_VER; IFS='|' read -r REALM_VER _ <<< "$REALM_RAW"
  local LOGS_VER;  IFS='|' read -r LOGS_VER  _ <<< "$LOGS_RAW"
  local MAPS_VER;  IFS='|' read -r MAPS_VER  _ <<< "$MAPS_RAW"
  local WEB_VER;   IFS='|' read -r WEB_VER   _ <<< "$WEB_RAW"

  local GREEN="\e[32m" RED="\e[31m" YELLOW="\e[33m" RESET="\e[0m"
  local EXPECTED_CORE="${VERSION_MAP[$EXPANSION:CORE]:-}"
  local EXPECTED_WORLD="${VERSION_MAP[$EXPANSION:WORLD]:-}"
  local CORE_COLOR WORLD_COLOR
  [[ "$CORE_VER" == "$EXPECTED_CORE" ]] && CORE_COLOR=$GREEN || CORE_COLOR=$RED
  [[ "$WORLD_VER" == "$EXPECTED_WORLD" ]] && WORLD_COLOR=$GREEN || WORLD_COLOR=$RED

  echo -e "Core: ${CORE_COLOR}v${CORE_VER:-NA}${RESET} (${CORE_BRANCH:-?}@${CORE_COMMIT:-?})"
  echo -e "Bots: ${YELLOW}${BOT_BRANCH:-?}@${BOT_COMMIT:-?}${RESET}"
  echo    "Built: ${BUILD_DATE:-unknown}"
  echo -e "World: ${WORLD_COLOR}${WORLD_VER:-NA}${RESET}"
  echo    "Chars: ${CHARS_VER:-NA}  Realm: ${REALM_VER:-NA}  Maps: ${MAPS_VER:-NA}"
  echo    "Web: ${WEB_VER:-NA}  Logs: ${LOGS_VER:-NA}"
}


ensure_shared_stack() {

  auto_detect_stack

  [[ -n "$DB_CTID" && -n "$WEB_CTID" && -n "$LOGIN_CTID" ]] && return

  echo
  echo "Shared SPP services incomplete."
  pct list
  echo

  if [[ -z "$DB_CTID" ]]; then
    read -p "Enter CTID for spp-db: " DB_NEW
    create_container "spp-db" "mariadb" "$DB_NEW" 1
  fi

  if [[ -z "$WEB_CTID" ]]; then
    read -p "Enter CTID for spp-web: " WEB_NEW
    create_container "spp-web" "website" "$WEB_NEW" 2
  fi

  if [[ -z "$LOGIN_CTID" ]]; then
    read -p "Enter CTID for spp-login: " LOGIN_NEW
    create_container "spp-login" "login" "$LOGIN_NEW" 3
  fi

  auto_detect_stack
}
ensure_game_container() {

  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"

  if [[ -n "$GAME_CTID" ]]; then
    return
  fi

  echo
  echo "Game container spp-$EXPANSION not found."
  read -p "Create it now? (y/n): " CONFIRM
  [[ "$CONFIRM" != "y" ]] && return 1

  pct list
  echo

  read -p "Enter CTID for spp-$EXPANSION: " NEW_CTID
  [[ ! "$NEW_CTID" =~ ^[0-9]+$ ]] && return 1

  create_container "spp-$EXPANSION" "game" "$NEW_CTID" 4

  auto_detect_stack
  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"
}

ensure_expansion_context() {
  if [[ -z "${EXPANSION:-}" ]]; then
    expansion_menu
  fi

  [[ -z "${EXPANSION:-}" ]] && return 1

  auto_detect_stack
  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"
}

ensure_service_target_context() {
  ensure_expansion_context || return 1
  ensure_game_container || return 1
}

#menus and functions

main() {

  while true; do
  
    service_menu
  done
}
expansion_menu() {
  while true; do
    clear
    print_banner
    auto_detect_stack

    echo "Choose Install Path:"
    echo

    for i in "${!ALLOWED_EXPANSIONS[@]}"; do
      EXP="${ALLOWED_EXPANSIONS[$i]}"
      CTID="${GAME_CTIDS[$EXP]:-}"
      STATUS=$([[ -n "$CTID" ]] && echo "[Installed - CTID $CTID]" || echo "[Not Installed]")
      TITLE="$(expansion_title "$EXP")"
      if [[ "$EXP" == "vmangos" ]]; then
        TITLE="${TITLE} [Dedicated Realm DB]"
      fi
      echo "$((i+1)) - $TITLE"
      echo "       [Install Path: $EXP]"
      echo "       $STATUS"
      echo
    done

    [[ -n "${EXPANSION:-}" ]] && echo "S - Shared Services"
    echo "M - Service Menu"
    echo "0 - Exit"
    echo

    read -p "Selection: " SEL
    SEL="${SEL:-}"

    [[ "$SEL" == "0" ]] && exit 0

    if [[ "$SEL" =~ ^[Ss]$ ]]; then
      shared_services_menu
      continue
    fi

    if [[ "$SEL" =~ ^[Mm]$ ]]; then
      service_menu
      continue
    fi

    INDEX=$((SEL-1))
    if [[ $INDEX -ge 0 && $INDEX -lt ${#ALLOWED_EXPANSIONS[@]} ]]; then
      EXPANSION="${ALLOWED_EXPANSIONS[$INDEX]}"
      return
    fi
  done
}

	
shared_services_menu() {
  auto_detect_stack

  while true; do
    print_banner
    echo
    echo "Shared Services (Classic/TBC/WotLK)"
    echo "Website is the intended admin surface for shared realms after bootstrap."
    echo
    echo "1 - Status"
    echo "2 - Service Control"
    echo "3 - Website"
    echo "4 - Repo"
    echo "5 - Configuration"
    echo
    echo "0 - Back"
    echo

    read -p "Selection: " SS

    case "$SS" in
      1) shared_status_menu ;;
      2) shared_service_control_menu ;;
      3) shared_website_menu ;;
      4) shared_repo_menu ;;
      5) shared_config_menu ;;
      0) break ;;
    esac
  done
}

shared_status_menu() {
  auto_detect_stack
  for CT in "$DB_CTID" "$LOGIN_CTID" "$WEB_CTID"; do
    NAME=$(pct config "$CT" | awk -F': ' '/hostname/ {print $2}')
    echo
    echo "$NAME ($CT)"
    pct status "$CT"
    pct exec "$CT" -- uptime
  done
  read -p "Press Enter..."
}
shared_service_control_menu() {
  echo
  echo "Service Control"
  echo
  echo "1 - Start DB"
  echo "2 - Stop DB"
  echo "3 - Start Login"
  echo "4 - Stop Login"
  echo "5 - Start Web"
  echo "6 - Stop Web"
  echo
  echo "0 - Back"

  read -p "Selection: " SC

  case "$SC" in
    1) pct start "$DB_CTID" ;;
    2) pct stop "$DB_CTID" ;;
    3) pct start "$LOGIN_CTID" ;;
    4) pct stop "$LOGIN_CTID" ;;
    5) pct start "$WEB_CTID" ;;
    6) pct stop "$WEB_CTID" ;;
  esac
}


shared_repo_menu() {
  echo
  echo "Repository"
  echo
  echo "1 - Reset SQL Repo"
  echo "2 - Update Repo"
  echo "3 - Sagrid-Argus Mods"
  echo "0 - Back"

  read -p "Selection: " R

  case "$R" in
    1)
      read -p "Confirm reset? (YES): " CONFIRM
      [[ "$CONFIRM" == "YES" ]] && sync_sql_repo
      ;;
    2)
      read -p "Confirm update? (YES): " CONFIRM
      [[ "$CONFIRM" == "YES" ]] && update_repo
      ;;
	3) install_sagrid_argus;;
  esac
}
sync_sql_repo() {
  pct exec "$DB_CTID" -- bash -c "
    set -e
    cd /opt
    rm -rf spp-sql

    git clone --depth 1 https://github.com/japtenks/spp-cmangos-prox.git spp-sql
  "
}
update_sql_repo() {
  pct exec "$DB_CTID" -- bash -c "
    set -e
    cd /opt/spp-sql || exit 0
cd /opt/spp-sql
git fetch --depth 1 origin
git reset --hard origin/HEAD
  "
}
update_settings_repo() {
for EXP in "${!GAME_CTIDS[@]}"; do
  GAME_CTID="${GAME_CTIDS[$EXP]}"

  pct exec "$GAME_CTID" -- bash -c "
  set -e
  cd /opt

  if [ -d spp-sql ]; then
      cd spp-sql
      git fetch --depth 1 origin
      git reset --hard origin/HEAD
  else
      git clone --depth 1 https://github.com/japtenks/spp-cmangos-prox.git spp-sql
  fi
  "
done
}
update_repo() {
  update_sql_repo
  update_settings_repo
}
install_sagrid_argus() {

EXPANSION="classic"
derive_db_names || return 1

ASSET_DIR="/opt/spp-assets/Sagrid-Argus"

echo "Stopping world server..."
stop_mangosd_managed "sagrid-argus-install"

echo "Fetching repo..."
mkdir -p /opt/spp-assets
cd /opt/spp-assets

if [ ! -d spp-cmangos-prox ]; then
  git clone --depth 1 --filter=blob:none --sparse https://github.com/japtenks/spp-cmangos-prox.git
fi

cd spp-cmangos-prox
git sparse-checkout set Sagrid-Argus
git pull

echo "Applying SQL..."
pct exec "$DB_CTID" -- bash -c "
cd /opt/spp-cmangos-prox/Sagrid-Argus/sql
for f in \$(ls *.sql | sort); do
  mariadb -u root ${WORLD_DB} < \$f
done
"

echo "Copying DBC..."
tar -C /opt/spp-assets/spp-cmangos-prox/Sagrid-Argus -cf /tmp/dbc.tar dbc
pct push "$GAME_CTID" /tmp/dbc.tar /tmp/dbc.tar
pct exec "$GAME_CTID" -- bash -c "tar -xf /tmp/dbc.tar -C ${INSTALL_DIR}/data && rm /tmp/dbc.tar"

echo "Copying patch..."
pct exec "$WEB_CTID" -- mkdir -p /var/www/html/downloads/tools
pct push "$WEB_CTID" /opt/spp-assets/spp-cmangos-prox/Sagrid-Argus/patch/patch-s.mpq /var/www/html/downloads/tools/patch-s.mpq

echo "Starting world server..."
start_mangosd_managed "sagrid-argus-install"
}

shared_config_menu() {
  echo
  echo "Configuration (Shared Classic/TBC/WotLK)"
  echo "Launcher realmlist actions here are bootstrap/repair only."
  echo
  echo "1 - Apply Server Confs"
  echo "2 - Bootstrap/Repair Shared Realmlist"
  echo "3 - Autostart services creation"
  echo "4 - RealmD Install"
  echo "5 - spp configs"
  echo "6 - Fix mariadb configs"
  echo "0 - Back"

  read -p "Selection: " C

  case "$C" in
    1) run_with_shared_classic_context update_db_conf ;;
    2) run_with_shared_classic_context fix_realm_entry ;;
    3) run_with_shared_classic_context service_create ;;
	4) run_with_shared_classic_context deploy_realmd ;;
	5) run_with_shared_classic_context deploy_spp_configs ;;
	6) fix_mariadb_bind ;;
  esac
}

update_db_conf() {
  derive_db_names || return 1
  local TARGET_EXPANSION="${1:-$EXPANSION}"
  local CONFIG_EXPANSIONS=("$TARGET_EXPANSION")

  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')

  MASTER_EXPANSION=$(resolve_shared_master_expansion) || {
    echo "No shared Classic/TBC/WotLK master expansion is available yet."
    return 1
  }

  MASTER_INSTALL_DIR=$(expansion_install_dir "$MASTER_EXPANSION") || return 1

  if pct exec "$LOGIN_CTID" -- test -f "${MASTER_INSTALL_DIR}/etc/realmd.conf" 2>/dev/null; then
    pct exec "$LOGIN_CTID" -- bash -c "
      sed -i \
      's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
      ${MASTER_INSTALL_DIR}/etc/realmd.conf
    "
    echo "realmd.conf updated."
  else
    echo "realmd.conf not found — running RealmD Install first..."
    local SAVED_EXP="$EXPANSION"
    EXPANSION="$MASTER_EXPANSION"
    derive_db_names || return 1
    deploy_realmd || return 1
    EXPANSION="$SAVED_EXP"
    derive_db_names || return 1

    pct exec "$LOGIN_CTID" -- bash -c "
      sed -i \
      's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
      ${MASTER_INSTALL_DIR}/etc/realmd.conf
    "
    echo "realmd.conf updated."
  fi

  # mangosd.conf — only update the expansion currently being installed/updated
  for EXP in "${CONFIG_EXPANSIONS[@]}"; do
    [[ -z "${GAME_CTIDS[$EXP]:-}" ]] && continue

    GAME_CTID="${GAME_CTIDS[$EXP]}"
    EXPANSION="$EXP"
    derive_db_names || continue

    pct exec "$GAME_CTID" -- test -f "${INSTALL_DIR}/etc/mangosd.conf" 2>/dev/null || {
      echo "$EXP mangosd.conf missing — skipping"
      continue
    }

    pct exec "$GAME_CTID" -- bash -c "
      if [[ '$EXP' == 'vmangos' ]]; then
        sed -i \
        -e 's|^LoginDatabase\.Info *=.*|LoginDatabase.Info              = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
        -e 's|^WorldDatabase\.Info *=.*|WorldDatabase.Info              = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${WORLD_DB}\"|' \
        -e 's|^CharacterDatabase\.Info *=.*|CharacterDatabase.Info          = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${CHAR_DB_NAME}\"|' \
        -e 's|^LogsDatabase\.Info *=.*|LogsDatabase.Info               = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${LOG_DB_NAME}\"|' \
        ${INSTALL_DIR}/etc/mangosd.conf
      else
        sed -i \
        -e 's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo     = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
        -e 's|^WorldDatabaseInfo *=.*|WorldDatabaseInfo     = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${WORLD_DB}\"|' \
        -e 's|^CharacterDatabaseInfo *=.*|CharacterDatabaseInfo = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${CHAR_DB_NAME}\"|' \
        -e 's|^LogsDatabaseInfo *=.*|LogsDatabaseInfo      = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${LOG_DB_NAME}\"|' \
        ${INSTALL_DIR}/etc/mangosd.conf
      fi
    "

    echo "$EXP mangosd.conf updated."
  done
}

service_create() {
  ensure_expansion_context || return 1
  derive_db_names || return 1

  # realmd service only written/reloaded on master expansion
  if is_master; then
    pct exec "$LOGIN_CTID" -- bash -c "
cat > /etc/systemd/system/realmd.service <<EOF
[Unit]
Description=$(if is_vmangos; then echo 'vMaNGOS'; else echo 'CMaNGOS'; fi) Realmd
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/bin
ExecStart=$INSTALL_DIR/bin/realmd -c $INSTALL_DIR/etc/realmd.conf
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
"
    pct exec "$LOGIN_CTID" -- systemctl daemon-reload
    echo "realmd service written for master: $MASTER_EXPANSION"
  else
    echo "Skipping realmd service — master is ${MASTER_EXPANSION}, not touching login container service."
  fi

  # mangosd service always written for this expansion's game container
  pct exec "$GAME_CTID" -- bash -c "
cat > /etc/systemd/system/mangosd.service <<EOF
[Unit]
Description=$(if is_vmangos; then echo 'vMaNGOS'; else echo 'CMaNGOS'; fi) World Server ($EXPANSION)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/bin
ExecStart=$INSTALL_DIR/bin/mangosd -c $INSTALL_DIR/etc/mangosd.conf
Restart=always
RestartSec=10
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
"
  pct exec "$GAME_CTID" -- systemctl daemon-reload

  apply_autostart_setting
}
fix_realm_entry() {
  ensure_expansion_context || return 1
  derive_db_names || return 1

  LOGIN_IP=$(pct exec "$LOGIN_CTID" -- hostname -I | awk '{print $1}')

  pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'

    mariadb -u root ${REALM_DB_NAME} -e \"
      DELETE FROM realmlist WHERE id=${REALM_ID};
      DELETE FROM realmlist WHERE name='SPP-${EXPANSION_TITLE}';

      INSERT INTO realmlist
        (id, name, address, port, icon, realmflags, timezone, allowedSecurityLevel)
      VALUES
        (${REALM_ID}, 'SPP-${EXPANSION_TITLE}', '${LOGIN_IP}', 8085, 1, 0, 1, 0);
    \"
  "

  if is_vmangos; then
    echo "Realm entry updated for ${EXPANSION_TITLE} (ID: ${REALM_ID}) in ${REALM_DB_NAME}."
  else
    echo "Bootstrap/repair realmlist entry updated for ${EXPANSION_TITLE} (ID: ${REALM_ID}) in shared DB ${REALM_DB_NAME}."
    echo "Use the website for ongoing shared realmlist administration."
  fi
}

fix_mariadb_bind() {
auto_detect_stack
  derive_db_names || return 1
pct exec "$DB_CTID" -- bash -c "

CONF=/etc/mysql/mariadb.conf.d/50-server.cnf

if grep -q '^bind-address' \$CONF; then
  sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' \$CONF
else
  echo 'bind-address = 0.0.0.0' >> \$CONF
fi

systemctl restart mariadb
"

}
deploy_spp_configs() {
ensure_expansion_context || return 1
derive_db_names || return 1

pct exec "$GAME_CTID" -- bash -c "
set -e
cd /opt
rm -rf spp-settings
git clone --depth 1 --filter=blob:none --sparse https://github.com/japtenks/spp-cmangos-prox.git spp-settings
cd spp-settings
git sparse-checkout set Settings/${SETTINGS_KEY}

CONF_DIR=\"Settings/${SETTINGS_KEY}\"
cp -f \$CONF_DIR/*.conf $INSTALL_DIR/etc/
"
}
deploy_realmd() {
  deploy_spp_configs || return 1

  INSTALL_DIR=$(expansion_install_dir "$EXPANSION") || return 1

  # Only deploy realmd binary if we are the master expansion
  if ! is_master; then
    echo "Skipping realmd binary deploy — master is ${MASTER_EXPANSION}."
    echo "realmd on spp-login already serves all expansions."
    return 0
  fi

  pct exec "$LOGIN_CTID" -- mkdir -p "$INSTALL_DIR/bin"
  pct exec "$LOGIN_CTID" -- mkdir -p "$INSTALL_DIR/etc"

  if ! pct exec "$GAME_CTID" -- test -f "$INSTALL_DIR/bin/realmd"; then
    echo "ERROR: realmd binary not found in $INSTALL_DIR/bin on $EXPANSION game container."
    return 1
  fi

  echo "Copying realmd binary to login container..."
  pct exec "$GAME_CTID" -- tar -C "$INSTALL_DIR" -cf - bin/realmd | \
  pct exec "$LOGIN_CTID" -- tar -C "$INSTALL_DIR" -xf -

  # Copy .dist then promote to .conf if not already present
  pct exec "$GAME_CTID" -- tar -C "$INSTALL_DIR/etc" -cf - realmd.conf.dist | \
  pct exec "$LOGIN_CTID" -- tar -C "$INSTALL_DIR/etc" -xf -

  pct exec "$LOGIN_CTID" -- bash -c "
    if [ ! -f $INSTALL_DIR/etc/realmd.conf ]; then
      cp $INSTALL_DIR/etc/realmd.conf.dist $INSTALL_DIR/etc/realmd.conf
      echo 'Created realmd.conf from .dist'
    else
      echo 'realmd.conf already exists, skipping.'
    fi
  "

  if pct exec "$GAME_CTID" -- test -f "/opt/spp-settings/Settings/${SETTINGS_KEY}/realmd.conf" 2>/dev/null; then
    pct exec "$GAME_CTID" -- tar -C "/opt/spp-settings/Settings/${SETTINGS_KEY}" -cf - realmd.conf | \
    pct exec "$LOGIN_CTID" -- tar -C "$INSTALL_DIR/etc" -xf -
  fi
}

shared_website_menu() {
  echo
  echo "Website (Shared Classic/TBC/WotLK Admin)"
  echo "Use the website as the primary admin surface for shared realmlist changes."
  echo
  echo "1 - Install Website"
  echo "2 - Update Website"
  echo "3 - Align php for website db"
  echo "4 - Refresh local website config"
  echo
  echo "0 - Back"

  read -p "Selection: " W

  case "$W" in
    1) run_with_shared_classic_context install_website ;;
    2) run_with_shared_classic_context update_website ;;
	3) run_with_shared_classic_context web_config ;;
    4) run_with_shared_classic_context update_config_protected ;;
  esac
}

update_config_protected() {
  echo "Refreshing local website config template from repo..."

  pct exec "$WEB_CTID" -- bash -c "
    set -e
    if [ ! -d '$WEBSITE_SRC_DIR' ]; then
      git clone '$WEBSITE_REPO' '$WEBSITE_SRC_DIR'
    fi
    cd '$WEBSITE_SRC_DIR'
    git fetch --depth 1 origin
    git reset --hard origin/HEAD
    if [ ! -f /var/www/html/config/config-protected.local.php ]; then
      if [ -f '$WEBSITE_SRC_DIR/config/config-protected.local.php.example' ]; then
        cp -f '$WEBSITE_SRC_DIR/config/config-protected.local.php.example' /var/www/html/config/config-protected.local.php
      else
        cp -f '$WEBSITE_SRC_DIR/config/config-protected.example.php' /var/www/html/config/config-protected.local.php
      fi
      chown www-data:www-data /var/www/html/config/config-protected.local.php
    fi
  "

  echo "Reapplying DB credentials..."
  web_config
}
install_website() {
  derive_db_names || return 1

  if is_vmangos; then
    echo "Website install is not implemented for vMaNGOS in this launcher yet."
    echo "vMaNGOS stays outside the shared website services topology."
    echo "Skipping website deployment."
    read -p "Press Enter to continue..."
    return 0
  fi

  if ! is_master; then
    echo "Website is pinned to master expansion: ${MASTER_EXPANSION}."
    echo "The website is the intended shared admin surface for Classic/TBC/WotLK realms."
    echo "To change the active world shown on the website, use 'Website' -> 'Switch Active World'."
    read -p "Press Enter to continue..."
    return 0
  fi

  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')

  echo
  echo "Installing Website (master: ${MASTER_EXPANSION})..."
  echo "The website will be the primary admin surface for shared Classic/TBC/WotLK realmlist management."
  echo

  pct exec "$WEB_CTID" -- bash -c "
    set -e
    rm -rf /var/www/html
    git clone --depth 1 '$WEBSITE_REPO' /var/www/html
    chown -R www-data:www-data /var/www/html
    chmod -R 755 /var/www/html
  "

  pct exec "$WEB_CTID" -- bash -c "
    a2enmod rewrite >/dev/null 2>&1 || true
    systemctl restart apache2
  "

  install_website_db
  web_config

  local WEB_EXPECTED="${VERSION_MAP[$EXPANSION:WEBSITE]}"
  local INSTALL_DATE
  INSTALL_DATE=$(date +%F_%H:%M)
  write_version "${MASTER_EXPANSION}_website_version.spp" "${WEB_EXPECTED}|${INSTALL_DATE}"

  echo
  echo "Website installed."
  echo "Use the website for ongoing shared realm admin after bootstrap."
  echo
  read -p "Press Enter to continue..."
}

install_website_db() {
  derive_db_names || return 1

  if is_vmangos; then
    return 0
  fi

  if is_master; then
    echo "Installing website tables into ${REALM_DB_NAME}..."
    if pct exec "$DB_CTID" -- bash -c "
      export MYSQL_PWD='${DB_ROOT_PASS}'
      BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"

      mariadb -u root \"${REALM_DB_NAME}\" < \"\$BASE/website.sql\"
      mariadb -u root \"${REALM_DB_NAME}\" < \"\$BASE/website_news.sql\"
    "; then
      echo "Website tables installed successfully."
    else
      echo "Website tables install FAILED."
      return 1
    fi
  else
    echo "Skipping website.sql — master is ${MASTER_EXPANSION}."
  fi

  echo "Shared realmlist administration should happen through the website after bootstrap."

  echo "Adding support tables to ${EXPANSION}armory..."
  if pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"

    mariadb -u root \"${EXPANSION}armory\" < \"\$BASE/armory_tooltip.sql\"
    mariadb -u root \"${EXPANSION}armory\" < \"\$BASE/bot_command.sql\"
  "; then
    echo "${EXPANSION} armory support tables installed successfully."
  else
    echo "${EXPANSION} armory support tables FAILED."
    return 1
  fi
}
  
update_website() {
  echo
  echo "Updating Website..."
  echo

  pct exec "$WEB_CTID" -- bash -c "
    set -e
    if [ ! -d '$WEBSITE_SRC_DIR' ]; then
      git clone '$WEBSITE_REPO' '$WEBSITE_SRC_DIR'
    fi
    cd '$WEBSITE_SRC_DIR'
    git fetch origin
    git reset --hard origin/HEAD

    rsync -a --delete \
      --exclude 'config/config-protected.local.php' \
      ./ /var/www/html/

    chown -R www-data:www-data /var/www/html
    chmod -R 755 /var/www/html
    systemctl restart apache2
  "

  echo
  echo "Website updated. Re-applying config..."
  echo

  web_config
}
web_config() {
  auto_detect_stack
  local SAVED_EXPANSION="${EXPANSION:-}"
  local SAVED_GAME_CTID="${GAME_CTID:-}"

  if ! ensure_shared_classic_context; then
    EXPANSION="$SAVED_EXPANSION"
    GAME_CTID="$SAVED_GAME_CTID"
    return 1
  fi

  derive_db_names || {
    EXPANSION="$SAVED_EXPANSION"
    GAME_CTID="$SAVED_GAME_CTID"
    return 1
  }

  local DB_IP
  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')
  local WEB_IP
  WEB_IP=$(pct exec "$WEB_CTID" -- hostname -I | awk '{print $1}')
  local GAME_IP
  GAME_IP=$(pct exec "$GAME_CTID" -- hostname -I | awk '{print $1}')
  local DEFAULT_REALM_ID
  DEFAULT_REALM_ID=$(expansion_realm_id "${MASTER_EXPANSION:-$EXPANSION}")
  local MASTER_REALM_DB
  MASTER_REALM_DB="${MASTER_REALMD_DB:-}"
  if [[ -z "$MASTER_REALM_DB" ]]; then
    MASTER_REALM_DB=$(expansion_realm_db_name "${MASTER_EXPANSION:-$EXPANSION}")
  fi
  local REALM_MAP_PHP
  REALM_MAP_PHP=$(website_realm_map_php "$MASTER_REALM_DB")
  local ENABLED_REALM_IDS_PHP
  ENABLED_REALM_IDS_PHP=$(website_enabled_realm_ids_php)
  local MULTIREALM_FLAG=0
  if [[ "$ENABLED_REALM_IDS_PHP" == *","* ]]; then
    MULTIREALM_FLAG=1
  fi
  local DB_IP_PHP
  DB_IP_PHP=$(php_single_quote_escape "$DB_IP")
  local GAME_IP_PHP
  GAME_IP_PHP=$(php_single_quote_escape "$GAME_IP")
  local DB_LAN_USER_PHP
  DB_LAN_USER_PHP=$(php_single_quote_escape "$DB_LAN_USER")
  local DB_LAN_PASS_PHP
  DB_LAN_PASS_PHP=$(php_single_quote_escape "$DB_LAN_PASS")
  local SOAP_PORT=7878

  pct exec "$WEB_CTID" -- bash -c "
    FILE=/var/www/html/config/config-protected.local.php
    if [ ! -f \$FILE ]; then
      if [ -f /var/www/html/config/config-protected.local.php.example ]; then
        cp -f /var/www/html/config/config-protected.local.php.example \$FILE
      else
        cp -f /var/www/html/config/config-protected.example.php \$FILE
      fi
    fi
    php <<'PHP'
<?php
\$file = '/var/www/html/config/config-protected.local.php';
\$config = is_file(\$file) ? require \$file : [];
if (!is_array(\$config)) {
    \$config = [];
}

\$config['db'] = array_merge(
    is_array(\$config['db'] ?? null) ? \$config['db'] : [],
    [
        'host' => '${DB_IP_PHP}',
        'port' => 3306,
        'user' => '${DB_LAN_USER_PHP}',
        'pass' => '${DB_LAN_PASS_PHP}',
    ]
);
\$config['clientConnectionHost'] = '${GAME_IP_PHP}';
\$config['serviceDefaults'] = array_merge(
    is_array(\$config['serviceDefaults'] ?? null) ? \$config['serviceDefaults'] : [],
    [
        'soap' => array_merge(
            is_array(\$config['serviceDefaults']['soap'] ?? null) ? \$config['serviceDefaults']['soap'] : [],
            [
                'port' => ${SOAP_PORT},
            ]
        ),
    ]
);
\$config['realmRuntime'] = array_merge(
    is_array(\$config['realmRuntime'] ?? null) ? \$config['realmRuntime'] : [],
    [
        'default_realm_id' => ${DEFAULT_REALM_ID},
        'multirealm' => ${MULTIREALM_FLAG},
    ]
);
\$config['realmDbMap'] = ${REALM_MAP_PHP};
\$config['enabledRealmIds'] = ${ENABLED_REALM_IDS_PHP};

\$content = \"<?php\\n\\nreturn \" . var_export(\$config, true) . \";\\n\";
file_put_contents(\$file, \$content);
PHP
    chown www-data:www-data \$FILE
  "

  echo "Web config updated — Bookmark website at http://${WEB_IP}"
  read -p "Press Enter to continue..."

  EXPANSION="$SAVED_EXPANSION"
  GAME_CTID="$SAVED_GAME_CTID"
}

service_menu() {
  ensure_shared_stack || return

  while true; do
    clear
    print_banner
    if [[ -n "${EXPANSION:-}" ]]; then
      print_version
    else
      echo "No install path selected yet."
    fi

    echo
    echo "Current Install Path: ${EXPANSION:-none}"
    echo "1 - Stack Control"
    echo "2 - Maintenance"
    echo "3 - Select Install Path"
    echo
    echo "4 - Remote Console"
    echo "5 - Live World Log"
    echo
    echo "6 - Autostart Status: ($ASV)"
	echo "7 - Server Info"
    echo "8 - Update Launcher"
    echo "0 - Back to Launcher"
    echo

    read -p "Selection: " MAIN

    case "$MAIN" in
      1) ensure_service_target_context && stack_control_menu ;;
      2) ensure_service_target_context && maintenance_menu ;;
      3) expansion_menu ;;
      4) ensure_service_target_context && connect_ra ;;
      5) ensure_service_target_context && live_logs ;;
      6) ensure_service_target_context && toggle_autostart ;;
	  7) ensure_service_target_context && server_info_menu ;;
      8) update_launcher_self ;;
      0) return ;;
    esac
  done
}
connect_ra() {

  if [[ -z "$ADMIN_USER" || -z "$ADMIN_PASS" ]]; then
    echo "Admin credentials not set."
    return 1
  fi

  IP=$(pct exec "$GAME_CTID" -- hostname -I | awk '{print $1}')

  if [[ -z "$IP" ]]; then
    echo "Could not determine IP."
    return 1
  fi

  echo "Connecting to RA at $IP:3443"
  echo "Type 'quit' to exit."
  echo

  {
    sleep 1
    echo "$ADMIN_USER"
    sleep 1
    echo "$ADMIN_PASS"
  } | telnet "$IP" 3443
}
live_logs() {
  echo "Press Ctrl+C to exit live view."
  trap 'echo; echo "Returning to menu..."; return' INT
  pct exec "$GAME_CTID" -- tail -f /var/log/mangos/Server.log
  trap - INT
}
toggle_autostart() {

  if [[ "$AUTO_START" == "1" ]]; then
    AUTO_START="0"
	ASV="Off"
  else
    AUTO_START="1"
	ASV="On"
  fi

  # update config.env
  sed -i "s/^AUTO_START=.*/AUTO_START=\"$AUTO_START\"/" "$CONFIG_FILE"
  sed -i "s/^ASV=.*/ASV=\"$ASV\"/" "$CONFIG_FILE"
  apply_autostart_setting

  echo "AUTO_START is now: $AUTO_START"
}
apply_autostart_setting() {
[[ -z "$LOGIN_CTID" ]] && auto_detect_stack
  if [[ "$AUTO_START" == "1" ]]; then
    pct exec "$LOGIN_CTID" -- systemctl enable realmd
    pct exec "$GAME_CTID" -- systemctl enable mangosd
	pct exec "$LOGIN_CTID" -- systemctl start realmd
    start_mangosd_managed "autostart-enable"
    echo "Autostart ENABLED"
  else
    pct exec "$LOGIN_CTID" -- systemctl disable realmd
    pct exec "$GAME_CTID" -- systemctl disable mangosd
    echo "Autostart DISABLED"
  fi
}

maintenance_menu() {
  while true; do
    #clear
    print_banner
    echo "Maintenance"
    echo
    echo "1 - Core"
    echo "2 - Database"
    echo "3 - (re)Install Data Pack"
    echo "4 - Config Settings"
    echo "I - Full (re)Install"
    echo "S - Setting Repo"	
    echo "0 - Back"
    echo

    read -p "Selection: " MSEL

    case "$MSEL" in
      1) core_menu ;;
      2) database_menu ;;
      3) install_data ;;
	  4) config_menu ;;
      I)
        read -p "Type YES to continue: " CONFIRM
        [[ "$CONFIRM" == "YES" ]] && full_install
        ;;
	  S) 	 
        read -p "Type YES to continue: " CONFIRM
        [[ "$CONFIRM" == "YES" ]] && sync_settings_repo ;;
      0) return ;;
    esac
  done
}

config_menu() {
  while true; do
    print_banner
    echo "Config Settings"
    echo
    echo "1 - Update Bot Conf from Repo"
    echo "0 - Back"
    echo
    read -p "Selection: " CSEL
    case "$CSEL" in
      1)
        derive_db_names || return 1
        check_and_update_botconf
        read -p "Press Enter to continue..."
        ;;
      0) return ;;
    esac
  done
}

core_menu() {
  while true; do
    print_banner
    echo
    echo "Core Maintenance"
    echo
    echo "1 - Clean Rebuild"
    echo "2 - Incremental Update"
    echo "3 - Configure Modules"
    echo "0 - Back"
    echo

    read -p "Selection: " CORE

    case "$CORE" in
      1)
        read -p "Confirm rebuild? (Y/N): " CONFIRM
        if [[ "${CONFIRM^^}" == "Y" ]]; then
          pct exec "$GAME_CTID" -- rm -rf /opt/source
          comp_server
          echo
          read -p "Core rebuild finished. Press Enter to continue..." _
        fi
        ;;
      2)
        read -p "Confirm update? (YES): " CONFIRM
        if [[ "$CONFIRM" == "YES" ]]; then
          update_core
          echo
          read -p "Core update finished. Press Enter to continue..." _
        fi
        ;;
      3) configure_modules ;;
      0) return ;;
    esac
  done
}

SPP_MODULES=(ACHIEVEMENTS IMMERSIVE HARDCORE TRANSMOG DUALSPEC BOOST CUSTOM20 BALANCING BARBER TRAININGDUMMIES VOICEOVER EXTRACOMMANDS)

build_module_flags() {
  local flags=""
  for mod in "${SPP_MODULES[@]}"; do
    local var="MODULE_${mod}"
    local val="${!var:-ON}"
    flags+=" -DBUILD_MODULE_${mod}=${val}"
  done
  echo "$flags"
}

configure_modules() {
  while true; do
    print_banner
    echo
    echo "Module Configuration  (changes saved immediately to config.env)"
    echo
    local i=1
    for mod in "${SPP_MODULES[@]}"; do
      local var="MODULE_${mod}"
      local val="${!var:-ON}"
      printf "  %2d - %-20s [%s]\n" "$i" "$mod" "$val"
      ((i++))
    done
    echo
    echo "   0 - Back"
    echo
    read -p "Toggle module #: " SEL
    [[ "$SEL" == "0" ]] && return
    if [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#SPP_MODULES[@]} )); then
      local mod="${SPP_MODULES[$((SEL-1))]}"
      local var="MODULE_${mod}"
      local cur="${!var:-ON}"
      local new="OFF"; [[ "$cur" == "OFF" ]] && new="ON"
      eval "MODULE_${mod}=${new}"
      sed -i "s/^MODULE_${mod}=.*/MODULE_${mod}=${new}/" "$CONFIG_FILE"
      echo "  $mod → $new"
      sleep 0.5
    fi
  done
}

comp_server() {
  derive_db_names || return 1
  local REPO BRANCH
  REPO=$(expansion_repo "$EXPANSION") || return 1
  BRANCH=$(expansion_branch "$EXPANSION") || return 1

  if is_vmangos; then
    pct exec "$GAME_CTID" -- bash -c "
      set -e
      cd /opt

      if [[ -d source ]]; then
        echo 'Updating existing vMaNGOS core...'
        cd source
        git fetch origin
        git checkout '$BRANCH'
        git pull --ff-only origin '$BRANCH'
      else
        echo 'Cloning fresh vMaNGOS core...'
        git clone '$REPO' source
        cd source
        git checkout '$BRANCH'
      fi
    "

    pct exec "$GAME_CTID" -- bash -c "
      set -e
      cd /opt/source
      rm -rf build
      mkdir -p build
      cd build
      cmake .. \
        -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DBUILD_EXTRACTORS=ON \
        -DBUILD_PLAYERBOTS=ON \
        -DSUPPORTED_CLIENT_BUILD=5875
      make -j\$(nproc)
      make install
      mkdir -p /var/log/mangos/
      cd '$INSTALL_DIR/etc' || exit 1

      for f in *.conf.dist; do
        base=\${f%.dist}
        [[ -f \$base ]] && continue
        cp \$f \$base
      done
    "

    update_core_metadata
    update_db_conf
    check_and_update_botconf
    return 0
  fi

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt

    if [[ -d source ]]; then
      echo 'Updating existing core...'
      cd source
      git fetch
      git checkout '$BRANCH'
      git pull
      cd src/modules/playerbot
      git fetch
      git checkout master
      git reset --hard origin/master
    else
      echo 'Cloning fresh core...'
      git clone '$REPO' source
      cd source
      git checkout '$BRANCH'
      sed -i 's|davidonete/cmangos-modules|japtenks/cmangos-modules|g' /opt/source/CMakeLists.txt
      mkdir -p src/modules
      cd src/modules
      git clone https://github.com/cmangos/playerbots.git playerbot
    fi

    # Apply SPP patches via sed (content-match, resilient to upstream context shifts)
    PLAIAI='/opt/source/src/modules/playerbot/playerbot/PlayerbotAI.cpp'
    DROPQ='/opt/source/src/modules/playerbot/playerbot/strategy/actions/DropQuestAction.cpp'
    if grep -q 'autoLoad && HasPlayerRelation()' \"\$PLAIAI\"; then
      sed -i 's|if (autoLoad && HasPlayerRelation()) sPlayerbotDbStore.Load(this);|if (autoLoad) sPlayerbotDbStore.Load(this); // spp: guild flavor override|' \"\$PLAIAI\"
      echo 'Applied: PlayerbotAI.cpp guild flavor patch'
    else
      echo 'Skipped: PlayerbotAI.cpp patch (already applied or line not found)'
    fi
    if grep -q 'ai->HasActivePlayerMaster()' \"\$DROPQ\" && ! grep -q 'IsAlt()' \"\$DROPQ\"; then
      sed -i 's|if (ai->HasActivePlayerMaster())|if (ai->IsAlt() \\&\\& ai->HasActivePlayerMaster())|' \"\$DROPQ\"
      echo 'Applied: DropQuestAction.cpp quest log patch'
    else
      echo 'Skipped: DropQuestAction.cpp patch (already applied or line not found)'
    fi
  "

  local MODULE_FLAGS
  MODULE_FLAGS=$(build_module_flags)
  local EXPECTED_MODULES=""
  for mod in "${SPP_MODULES[@]}"; do
    local var="MODULE_${mod}"
    local val="${!var:-ON}"
    if [[ "$val" == "ON" ]]; then
      EXPECTED_MODULES+=" $(echo "$mod" | tr '[:upper:]' '[:lower:]')"
    fi
  done

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt/source
    mkdir -p build
    cd build
    cmake .. \
      -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DBUILD_EXTRACTORS=OFF \
      -DPCH=1 \
      -DDEBUG=0 \
      -DBUILD_PLAYERBOTS=ON \
      -DBUILD_AHBOT=ON \
      -DBUILD_MODULES=ON \
      -DBUILD_GIT_ID=ON \
      $MODULE_FLAGS
    cmake .. \
      -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DBUILD_EXTRACTORS=OFF \
      -DPCH=1 \
      -DDEBUG=0 \
      -DBUILD_PLAYERBOTS=ON \
      -DBUILD_AHBOT=ON \
      -DBUILD_MODULES=ON \
      -DBUILD_GIT_ID=ON \
      $MODULE_FLAGS
    GENERATED_MODULES_FILE='/opt/source/src/modules/modules/src/Modules.cpp'
    if [[ ! -f \"\$GENERATED_MODULES_FILE\" ]]; then
      echo 'ERROR: Generated Modules.cpp not found after configure.'
      exit 1
    fi
    for lower_module in $EXPECTED_MODULES; do
      expected_class=\"\${lower_module^}Module\"
      if ! grep -q \"\$expected_class\" \"\$GENERATED_MODULES_FILE\"; then
        echo \"ERROR: Expected module '\$lower_module' missing from generated Modules.cpp\"
        exit 1
      fi
    done
    make -j\$(nproc)
    make install
    mkdir -p /var/log/mangos/
    cd "$INSTALL_DIR/etc" || exit 1

    for f in *.conf.dist; do
    base=\${f%.dist}
    [[ -f \$base ]] && continue
    cp \$f \$base
    done
  "

  update_core_metadata
  update_db_conf
  check_and_update_botconf
}

update_core() {
  derive_db_names || return 1

  if is_vmangos; then
    local OLD_CORE
    OLD_CORE=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse HEAD 2>/dev/null || echo "")

    pct exec "$GAME_CTID" -- bash -c "
      set -e
      cd /opt/source
      git fetch origin
      git checkout '$(expansion_branch "$EXPANSION")'
      git pull --ff-only origin '$(expansion_branch "$EXPANSION")'
    "

    local NEW_CORE
    NEW_CORE=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse HEAD)

    if [[ "$OLD_CORE" != "$NEW_CORE" ]]; then
      echo "Changes detected â€” rebuilding..."
      stop_mangosd_managed "core-rebuild"

      pct exec "$GAME_CTID" -- bash -c "
        set -e
        rm -rf /opt/source/build
        mkdir -p /opt/source/build
        cd /opt/source/build
        cmake .. \
          -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
          -DCMAKE_BUILD_TYPE=RelWithDebInfo \
          -DBUILD_EXTRACTORS=ON \
          -DBUILD_PLAYERBOTS=ON \
          -DSUPPORTED_CLIENT_BUILD=5875
        make -j\$(nproc)
        make install
      "

      start_mangosd_managed "core-rebuild"
    else
      echo "No core changes â€” skipping rebuild."
    fi

    update_core_metadata
    check_and_update_botconf
    return 0
  fi

  local OLD_CORE OLD_BOT
  OLD_CORE=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse HEAD)
  OLD_BOT=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse HEAD)
  local MODULE_FLAGS
  MODULE_FLAGS=$(build_module_flags)
  local EXPECTED_MODULES=""
  for mod in "${SPP_MODULES[@]}"; do
    local var="MODULE_${mod}"
    local val="${!var:-ON}"
    if [[ "$val" == "ON" ]]; then
      EXPECTED_MODULES+=" $(echo "$mod" | tr '[:upper:]' '[:lower:]')"
    fi
  done

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt/source
    git fetch
    git checkout ike3-bots
    git pull
    sed -i 's|davidonete/cmangos-modules|japtenks/cmangos-modules|g' /opt/source/CMakeLists.txt
    cd src/modules/playerbot
    git fetch
    git checkout master
    git reset --hard origin/master

    # Apply SPP patches via sed (content-match, resilient to upstream context shifts)
    PLAIAI='/opt/source/src/modules/playerbot/playerbot/PlayerbotAI.cpp'
    DROPQ='/opt/source/src/modules/playerbot/playerbot/strategy/actions/DropQuestAction.cpp'
    if grep -q 'autoLoad && HasPlayerRelation()' \"\$PLAIAI\"; then
      sed -i 's|if (autoLoad && HasPlayerRelation()) sPlayerbotDbStore.Load(this);|if (autoLoad) sPlayerbotDbStore.Load(this); // spp: guild flavor override|' \"\$PLAIAI\"
      echo 'Applied: PlayerbotAI.cpp guild flavor patch'
    else
      echo 'Skipped: PlayerbotAI.cpp patch (already applied or line not found)'
    fi
    if grep -q 'ai->HasActivePlayerMaster()' \"\$DROPQ\" && ! grep -q 'IsAlt()' \"\$DROPQ\"; then
      sed -i 's|if (ai->HasActivePlayerMaster())|if (ai->IsAlt() \\&\\& ai->HasActivePlayerMaster())|' \"\$DROPQ\"
      echo 'Applied: DropQuestAction.cpp quest log patch'
    else
      echo 'Skipped: DropQuestAction.cpp patch (already applied or line not found)'
    fi

    echo 'Refreshing fetched module sources...'
    rm -rf /opt/source/src/modules/modules
    for lower_module in $EXPECTED_MODULES; do
      rm -rf \"/opt/source/src/modules/\$lower_module\"
    done
  "

  local NEW_CORE NEW_BOT
  NEW_CORE=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse HEAD)
  NEW_BOT=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse HEAD)

  if true; then
    echo "Changes detected — rebuilding..."
    stop_mangosd_managed "core-rebuild"

    pct exec "$GAME_CTID" -- bash -c "
      set -e
      rm -rf /opt/source/build
      mkdir -p /opt/source/build
      cd /opt/source/build
      cmake .. \
        -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DBUILD_EXTRACTORS=OFF \
        -DPCH=1 \
        -DDEBUG=0 \
        -DBUILD_PLAYERBOTS=ON \
        -DBUILD_AHBOT=ON \
        -DBUILD_MODULES=ON \
        -DBUILD_GIT_ID=ON \
        $MODULE_FLAGS
      make -j\$(nproc)
      make install
    "

    start_mangosd_managed "core-rebuild"
  else
    echo "No core or bot changes — skipping rebuild."
  fi

  update_core_metadata
  check_and_update_botconf
}

update_core_metadata() {
CORE_BRANCH=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse --abbrev-ref HEAD)
CORE_COMMIT=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse --short HEAD)
if is_vmangos; then
BOT_BRANCH="integrated-playerbots"
BOT_COMMIT="$CORE_COMMIT"
else
BOT_BRANCH=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse --abbrev-ref HEAD)
BOT_COMMIT=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse --short HEAD)
fi
BUILD_DATE=$(date +%F_%H:%M)

KEY=$(echo "$EXPANSION" | tr '[:lower:]' '[:upper:]')
EXPECTED_CORE="${VERSION_MAP[$EXPANSION:CORE]}"

write_version "${EXPANSION}_core_version.spp" \
"${EXPECTED_CORE}|${CORE_BRANCH}|${CORE_COMMIT}|${BOT_BRANCH}|${BOT_COMMIT}|${BUILD_DATE}"
}

check_and_update_botconf() {
  # Requires: EXPANSION and GAME_CTID already set

  local INSTALL_DIR
  local MAP_KEY
  case "$EXPANSION" in
    classic)
      INSTALL_DIR="/srv/mangos-classic"
      MAP_KEY="vanilla"
      ;;
    tbc)
      INSTALL_DIR="/srv/mangos-tbc"
      MAP_KEY="tbc"
      ;;
    wotlk)
      INSTALL_DIR="/srv/mangos-wotlk"
      MAP_KEY="wotlk"
      ;;
    vmangos)
      INSTALL_DIR="/srv/vmangos"
      MAP_KEY="vmangos"
      ;;
    *)
      echo "WARNING: Unknown expansion '$EXPANSION' for botconf deploy. Skipping."
      return 0
      ;;
  esac

  local CONF_PATH="${INSTALL_DIR}/etc/aiplayerbot.conf"
  local VERSION_FILE="/opt/${EXPANSION}_botconf_version.spp"
  local CONF_REL="Settings/${MAP_KEY}/aiplayerbot.conf"

  # Ensure the sparse-checkout repo exists and is current on the game container
  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt
    if [ ! -d spp-settings ]; then
      git clone --depth 1 --filter=blob:none --sparse \
        https://github.com/japtenks/spp-cmangos-prox.git spp-settings
      cd spp-settings
      git sparse-checkout set Settings/${MAP_KEY}
    else
      cd spp-settings
      git fetch --depth 1 origin
      git reset --hard origin/HEAD
    fi
  "

  # Get the current commit hash of the conf file in the repo
  local REMOTE_HASH
  REMOTE_HASH=$(pct exec "$GAME_CTID" -- bash -c "
    git -C /opt/spp-settings log -1 --format='%H' -- '${CONF_REL}' 2>/dev/null || echo ''
  ")

  if [[ -z "$REMOTE_HASH" ]]; then
    echo "WARNING: Could not determine aiplayerbot.conf commit hash. Skipping."
    return 0
  fi

  # Read stored values: repo_hash | content_md5 | date
  local STORED
  STORED=$(pct exec "$GAME_CTID" -- bash -c "cat '${VERSION_FILE}' 2>/dev/null || echo ''")

  local LOCAL_HASH DEPLOYED_CONTENT_HASH
  IFS='|' read -r LOCAL_HASH DEPLOYED_CONTENT_HASH _ <<< "$STORED"

  # Get the md5 of the live deployed file
  local LIVE_CONTENT_HASH
  LIVE_CONTENT_HASH=$(pct exec "$GAME_CTID" -- bash -c "
    md5sum '${CONF_PATH}' 2>/dev/null | awk '{print \$1}' || echo ''
  ")

  local FILE_MODIFIED=0
  local NEW_REPO_VERSION=0

  [[ "$REMOTE_HASH" != "$LOCAL_HASH" ]]                        && NEW_REPO_VERSION=1
  [[ -n "$LIVE_CONTENT_HASH" && \
     -n "$DEPLOYED_CONTENT_HASH" && \
     "$LIVE_CONTENT_HASH" != "$DEPLOYED_CONTENT_HASH" ]]       && FILE_MODIFIED=1

  # Case 1: everything matches — nothing to do
  if [[ $NEW_REPO_VERSION -eq 0 && $FILE_MODIFIED -eq 0 ]]; then
    echo "aiplayerbot.conf is up to date (${REMOTE_HASH:0:8})."
    return 0
  fi

  # Case 2: locally modified but no new repo version — warn and leave it alone
  if [[ $FILE_MODIFIED -eq 1 && $NEW_REPO_VERSION -eq 0 ]]; then
    echo "WARNING: aiplayerbot.conf has local modifications but no new repo version exists."
    echo "         Leaving local file untouched."
    return 0
  fi

  # Case 3: new repo version, file untouched — deploy silently
  if [[ $NEW_REPO_VERSION -eq 1 && $FILE_MODIFIED -eq 0 ]]; then
    echo "New aiplayerbot.conf version detected (${LOCAL_HASH:0:8} -> ${REMOTE_HASH:0:8}). Deploying..."
    _deploy_botconf "$CONF_PATH" "$CONF_REL" "$VERSION_FILE" "$REMOTE_HASH"
    return 0
  fi

  # Case 4: new repo version AND local modifications — prompt
  if [[ $NEW_REPO_VERSION -eq 1 && $FILE_MODIFIED -eq 1 ]]; then
    echo
    echo "WARNING: aiplayerbot.conf has BOTH local modifications AND a new repo version."
    echo "  Deployed version : ${LOCAL_HASH:0:8}"
    echo "  New repo version : ${REMOTE_HASH:0:8}"
    echo
    read -p "Overwrite local changes with new repo version? (Y/N): " OW
    if [[ "${OW^^}" == "Y" ]]; then
      _deploy_botconf "$CONF_PATH" "$CONF_REL" "$VERSION_FILE" "$REMOTE_HASH"
    else
      echo "Skipping update. Local file preserved."
    fi
    return 0
  fi
}

# Internal helper — backs up, copies, and records the new version
_deploy_botconf() {
  local CONF_PATH=$1
  local CONF_REL=$2
  local VERSION_FILE=$3
  local REMOTE_HASH=$4

  # Backup with next available number
  local BKUP_NUM=1
  while pct exec "$GAME_CTID" -- test -f "${CONF_PATH}.bkup${BKUP_NUM}" 2>/dev/null; do
    ((BKUP_NUM++))
  done

  if pct exec "$GAME_CTID" -- test -f "$CONF_PATH" 2>/dev/null; then
    pct exec "$GAME_CTID" -- cp "$CONF_PATH" "${CONF_PATH}.bkup${BKUP_NUM}"
    echo "Backed up as aiplayerbot.conf.bkup${BKUP_NUM}"
  fi

  # Copy new conf from repo
  pct exec "$GAME_CTID" -- mkdir -p "$(dirname "$CONF_PATH")"
  pct exec "$GAME_CTID" -- cp "/opt/spp-settings/${CONF_REL}" "$CONF_PATH"

  # Record repo hash + content hash of what we just deployed
  local NEW_CONTENT_HASH
  NEW_CONTENT_HASH=$(pct exec "$GAME_CTID" -- bash -c "
    md5sum '${CONF_PATH}' | awk '{print \$1}'
  ")

  pct exec "$GAME_CTID" -- bash -c "
    echo '${REMOTE_HASH}|${NEW_CONTENT_HASH}|$(date +%F_%H:%M)' > '${VERSION_FILE}'
  "

  echo "aiplayerbot.conf deployed (${REMOTE_HASH:0:8})."
}

database_menu() {
  while true; do
    #clear
    print_banner

    echo
    echo "Database Maintenance"
    echo
    echo "1 - Install Full DB"
    echo "2 - Reset Characters"
    echo "3 - Install Locales"
	echo
	echo "4 - Update realmd DB"
	echo "5 - Update characters DB"
	echo "6 - Update PlayerBots DB"
    echo "7 - Configure Bot Rotation Logging"
	echo
    echo "0 - Back"
    echo

    read -p "Selection: " DBSEL

    case "$DBSEL" in
      1)
        read -p "Confirm reinstall? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && install_db
        ;;
      2)
        read -p "Confirm reset? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && reset_characters
        ;;
      3)         
	    read -p "Confirm install? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && install_locales ;;
	  4)         
	    read -p "Confirm update on realmd? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && update_db_type realmd ;;
	  5)         
	    read -p "Confirm update on characters? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && update_db_type characters ;;
	  6)         
	    read -p "Confirm update on PlayerBots? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && update_db_type playerbot ;;
      7)
        read -p "Configure bot rotation logging now? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && configure_bot_rotation_log
        ;;
      0) return ;;
    esac
  done
}

install_db() {
  derive_db_names || return 1
  if is_vmangos; then
    echo "Installing full DB with dedicated vMaNGOS realm/logon flow..."
  else
    echo "Installing full DB (including shared-classic-family realm DB)..."
  fi
  if is_vmangos; then
    create_lan_db_user
  fi
  install_world
  install_char
  if ! is_vmangos; then
    install_armory
  fi
  install_logs
  install_realm
  create_lan_db_user
  fix_realm_entry
  echo "DB install complete."
}
# Non-master expansions skip realm DB install
install_db_no_realm() {
  derive_db_names || return 1
  if is_vmangos; then
    echo "vMaNGOS always installs its own dedicated realm DB."
    install_db
    return $?
  fi
  echo "Installing expansion DB (world/chars/logs only)..."
  if is_vmangos; then
    create_lan_db_user
  fi
  install_world
  install_char
  if ! is_vmangos; then
    install_armory
  fi
  install_logs
  # Grant LAN user access to new DBs - realm DB already exists from master
  create_lan_db_user
  fix_realm_entry
  echo "DB install complete."
}

install_world() {
  derive_db_names || return 1
  echo "Installing world DB..."

  if is_vmangos; then
    local DB_IP
    DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')

    if pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      export MYSQL_PWD='${DB_LAN_PASS}'
      ASSET_BASE='/opt/spp-assets/vmangos/sql'
      TMP_DIR='/tmp/vmangos-sql'
      mkdir -p \"\$TMP_DIR\"

      WORLD_SQL=''
      if [[ -f \"\$ASSET_BASE/world.sql\" ]]; then
        WORLD_SQL=\"\$ASSET_BASE/world.sql\"
      elif [[ -f \"\$ASSET_BASE/world.7z\" ]]; then
        rm -f \"\$TMP_DIR/world.sql\"
        7z x -y \"\$ASSET_BASE/world.7z\" -o\"\$TMP_DIR\" >/dev/null
        WORLD_SQL=\"\$TMP_DIR/world.sql\"
      else
        echo 'Missing /opt/spp-assets/vmangos/sql/world.sql or world.7z'
        exit 1
      fi

      mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' -e \"
        DROP DATABASE IF EXISTS ${WORLD_DB};
        CREATE DATABASE ${WORLD_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      \"
      mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${WORLD_DB}' < \"\$WORLD_SQL\"

      for f in \"\$ASSET_BASE/world\"/*.sql; do
        [[ -f \"\$f\" ]] && mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${WORLD_DB}' < \"\$f\"
      done
    "; then
      echo "DB installed successfully."
    else
      echo "DB install FAILED."
      return 1
    fi

    WORLD_EXPECTED="${VERSION_MAP[$EXPANSION:WORLD]}"
    INSTALL_DATE=$(date +%F_%H:%M)
    write_version "${EXPANSION}_world_version.spp" "${WORLD_EXPECTED}|${INSTALL_DATE}"
    read -p "Press Enter to return..." _
    return 0
  fi

 if pct exec "$DB_CTID" -- bash -c "

  export MYSQL_PWD='${DB_ROOT_PASS}'

  BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"

  cd /opt
  rm -rf spp-sql
  git clone --depth 1 --filter=blob:none --sparse \
    https://github.com/japtenks/spp-cmangos-prox.git spp-sql

  cd spp-sql
  git sparse-checkout set sql/${MAP_KEY}
  cd sql/${MAP_KEY}

  7z x -y world.7z >/dev/null

  mariadb -u root < drop_world.sql
  mariadb -u root \"${WORLD_DB}\" < world.sql

  for f in world/*.sql; do
    [ -f \"\$f\" ] && mariadb -u root \"${WORLD_DB}\" < \"\$f\"
  done

  rm -f world.sql
 
  "; then
    echo "DB installed successfully."
  else
    echo "DB install FAILED."
    return 1
  fi
WORLD_EXPECTED="${VERSION_MAP[$EXPANSION:WORLD]}"
INSTALL_DATE=$(date +%F_%H:%M)

write_version "${EXPANSION}_world_version.spp" \
"${WORLD_EXPECTED}|${INSTALL_DATE}"
  read -p "Press Enter to return..." _
}
install_char() {
  derive_db_names || return 1

    echo "Installing character DB..."
 if is_vmangos; then
  local DB_IP
  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')

  if pct exec "$GAME_CTID" -- bash -c "
    set -euo pipefail
    export MYSQL_PWD='${DB_LAN_PASS}'
    SQL_BASE='/opt/source/sql'

    mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' -e \"
      DROP DATABASE IF EXISTS ${CHAR_DB_NAME};
      CREATE DATABASE ${CHAR_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    \"

    mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${CHAR_DB_NAME}' < \"\$SQL_BASE/characters.sql\"

    for f in \$(find \"\$SQL_BASE/migrations\" -maxdepth 1 -type f -name '*_characters.sql' | sort); do
      mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${CHAR_DB_NAME}' < \"\$f\"
    done

    for f in /opt/spp-assets/vmangos/sql/characters/*.sql; do
      [[ -f \"\$f\" ]] && mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${CHAR_DB_NAME}' < \"\$f\"
    done
  "; then
    echo "DB installed successfully."
  else
    echo "DB install FAILED."
    return 1
  fi
  write_version "${EXPANSION}_chars_version.spp" "${VERSION_MAP[$EXPANSION:CHARS]}"
  read -p "Press Enter to return..." _
  return 0
 fi

 if pct exec "$DB_CTID" -- bash -c "
 
  export MYSQL_PWD='${DB_ROOT_PASS}'

    BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"
  WORLD_DB=\"${WORLD_DB}\"
  CHAR_DB=\"${CHAR_DB_NAME}\"

  mariadb -u root < \"\$BASE/drop_characters.sql\"

  mariadb -u root \"\$CHAR_DB\" < \"\$BASE/characters.sql\"

  for dir in \$(ls -1 \"\$BASE/updates/characters\" | sort -n); do
    for f in \"\$BASE/updates/characters/\$dir\"/*.sql; do
      [ -f \"\$f\" ] && mariadb -u root \"\$CHAR_DB\" < \"\$f\"
    done
  done

  for f in \"\$BASE/characters\"/*.sql; do
    [ -f \"\$f\" ] && mariadb -u root \"\$CHAR_DB\" < \"\$f\"
  done
  
    mariadb -u root \"\$WORLD_DB\" < \"\$BASE/world/ai_playerbot_travel_nodes.sql\"
  mariadb -u root \"\$WORLD_DB\" < \"\$BASE/world/ai_playerbot_texts.sql\"
  mariadb -u root \"\$WORLD_DB\" < \"\$BASE/world/ai_playerbot_named_location.sql\"
  cd \"\$BASE/playerbot\"
  7z x -y characters_ai_playerbot_equip_cache.7z >/dev/null
  mariadb -u root \"\$CHAR_DB\" < characters_ai_playerbot_equip_cache.sql
  mariadb -u root \"\$CHAR_DB\" < characters_ai_playerbot_rnditem_cache.sql
  mariadb -u root \"\$CHAR_DB\" < characters_ai_playerbot_rarity_cache.sql

  rm -f characters_ai_playerbot_equip_cache.sql
  "; then
    echo "DB installed successfully."
  else
    echo "DB install FAILED."
    return 1
  fi
 write_version "${EXPANSION}_chars_version.spp" "${VERSION_MAP[$EXPANSION:CHARS]}"
   read -p "Press Enter to return..." _
}
install_logs() {
  derive_db_names || return 1
  echo "Installing logs DB..."

  if is_vmangos; then
    local DB_IP
    DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')

    if pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      export MYSQL_PWD='${DB_LAN_PASS}'
      SQL_BASE='/opt/source/sql'

      mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' -e \"
        DROP DATABASE IF EXISTS ${LOG_DB_NAME};
        CREATE DATABASE ${LOG_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      \"

      mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${LOG_DB_NAME}' < \"\$SQL_BASE/logs.sql\"

      for f in \$(find \"\$SQL_BASE/migrations\" -maxdepth 1 -type f -name '*_logs.sql' | sort); do
        mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${LOG_DB_NAME}' < \"\$f\"
      done
    "; then
      echo "Logs DB installed successfully."
    else
      echo "Logs DB install FAILED."
      return 1
    fi

    write_version "${EXPANSION}_logs_version.spp" "${VERSION_MAP[$EXPANSION:LOGS]}"
    read -p "Press Enter to return..." _
    return 0
  fi

  if pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"

    mariadb -u root < \"\$BASE/drop_logs.sql\"
    mariadb -u root \"${LOG_DB_NAME}\" < \"\$BASE/logs.sql\"
  "; then
    echo "Logs DB installed successfully."
  else
    echo "Logs DB install FAILED."
    return 1
  fi

  write_version "${EXPANSION}_logs_version.spp" "${VERSION_MAP[$EXPANSION:LOGS]}"
  read -p "Press Enter to return..." _
}

get_bot_conf_value() {
  local KEY=$1
  pct exec "$GAME_CTID" -- bash -c "
    awk -F= '/^[[:space:]]*${KEY}[[:space:]]*=/{v=\$2; sub(/#.*/, \"\", v); gsub(/[[:space:]]/, \"\", v); print v; exit}' '${INSTALL_DIR}/etc/aiplayerbot.conf'
  " 2>/dev/null | tr -d '\r'
}

sync_bot_rotation_config() {
  derive_db_names || return 1

  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-${GAME_CTID:-}}"
  [[ -z "${GAME_CTID:-}" ]] && echo "No game container found for ${EXPANSION}." && return 1

  if ! pct exec "$GAME_CTID" -- test -f "${INSTALL_DIR}/etc/aiplayerbot.conf"; then
    echo "aiplayerbot.conf not found for ${EXPANSION}."
    return 1
  fi

  local ACCOUNT_PREFIX MIN_IN_WORLD MAX_IN_WORLD MIN_OFFLINE MAX_OFFLINE
  local MIN_BOTS MAX_BOTS ACCOUNT_COUNT REBALANCE_MIN REBALANCE_MAX MAX_LOGINS
  local AVG_IN_WORLD AVG_OFFLINE EXPECTED_ONLINE_PCT

  ACCOUNT_PREFIX=$(get_bot_conf_value "AiPlayerbot.RandomBotAccountPrefix")
  MIN_IN_WORLD=$(get_bot_conf_value "AiPlayerbot.MinRandomBotInWorldTime")
  MAX_IN_WORLD=$(get_bot_conf_value "AiPlayerbot.MaxRandomBotInWorldTime")
  MIN_OFFLINE=$(get_bot_conf_value "AiPlayerbot.MinRandomBotRandomizeTime")
  MAX_OFFLINE=$(get_bot_conf_value "AiPlayerbot.MaxRandomRandomizeTime")
  MIN_BOTS=$(get_bot_conf_value "AiPlayerbot.MinRandomBots")
  MAX_BOTS=$(get_bot_conf_value "AiPlayerbot.MaxRandomBots")
  ACCOUNT_COUNT=$(get_bot_conf_value "AiPlayerbot.RandomBotAccountCount")
  REBALANCE_MIN=$(get_bot_conf_value "AiPlayerbot.RandomBotCountChangeMinInterval")
  REBALANCE_MAX=$(get_bot_conf_value "AiPlayerbot.RandomBotCountChangeMaxInterval")
  MAX_LOGINS=$(get_bot_conf_value "AiPlayerbot.RandomBotsMaxLoginsPerInterval")

  ACCOUNT_PREFIX="${ACCOUNT_PREFIX:-RNDBOT}"
  MIN_IN_WORLD="${MIN_IN_WORLD:-0}"
  MAX_IN_WORLD="${MAX_IN_WORLD:-0}"
  MIN_OFFLINE="${MIN_OFFLINE:-0}"
  MAX_OFFLINE="${MAX_OFFLINE:-0}"
  MIN_BOTS="${MIN_BOTS:-0}"
  MAX_BOTS="${MAX_BOTS:-0}"
  ACCOUNT_COUNT="${ACCOUNT_COUNT:-0}"
  REBALANCE_MIN="${REBALANCE_MIN:-0}"
  REBALANCE_MAX="${REBALANCE_MAX:-0}"
  MAX_LOGINS="${MAX_LOGINS:-0}"

  AVG_IN_WORLD=$(awk "BEGIN { printf \"%.1f\", (${MIN_IN_WORLD} + ${MAX_IN_WORLD}) / 2 }")
  AVG_OFFLINE=$(awk "BEGIN { printf \"%.1f\", (${MIN_OFFLINE} + ${MAX_OFFLINE}) / 2 }")
  EXPECTED_ONLINE_PCT=$(awk "BEGIN { total=${AVG_IN_WORLD}+${AVG_OFFLINE}; if (total <= 0) print \"0.0\"; else printf \"%.1f\", (${AVG_IN_WORLD}/total)*100 }")

  pct exec "$DB_CTID" -- bash -c "
    set -euo pipefail
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root '${REALM_DB_NAME}' -e \"
INSERT INTO bot_rotation_config
  (realm, expansion, char_db, random_bot_account_prefix,
   min_in_world_sec, max_in_world_sec, min_offline_sec, max_offline_sec,
   avg_in_world_sec, avg_offline_sec, expected_online_pct,
   min_random_bots, max_random_bots, account_count,
   rebalance_min_sec, rebalance_max_sec, max_logins_per_interval, last_synced)
VALUES
  (${REALM_ID}, '${EXPANSION}', '${CHAR_DB_NAME}', '${ACCOUNT_PREFIX}',
   ${MIN_IN_WORLD}, ${MAX_IN_WORLD}, ${MIN_OFFLINE}, ${MAX_OFFLINE},
   ${AVG_IN_WORLD}, ${AVG_OFFLINE}, ${EXPECTED_ONLINE_PCT},
   ${MIN_BOTS}, ${MAX_BOTS}, ${ACCOUNT_COUNT},
   ${REBALANCE_MIN}, ${REBALANCE_MAX}, ${MAX_LOGINS}, NOW())
ON DUPLICATE KEY UPDATE
  expansion = VALUES(expansion),
  char_db = VALUES(char_db),
  random_bot_account_prefix = VALUES(random_bot_account_prefix),
  min_in_world_sec = VALUES(min_in_world_sec),
  max_in_world_sec = VALUES(max_in_world_sec),
  min_offline_sec = VALUES(min_offline_sec),
  max_offline_sec = VALUES(max_offline_sec),
  avg_in_world_sec = VALUES(avg_in_world_sec),
  avg_offline_sec = VALUES(avg_offline_sec),
  expected_online_pct = VALUES(expected_online_pct),
  min_random_bots = VALUES(min_random_bots),
  max_random_bots = VALUES(max_random_bots),
  account_count = VALUES(account_count),
  rebalance_min_sec = VALUES(rebalance_min_sec),
  rebalance_max_sec = VALUES(rebalance_max_sec),
  max_logins_per_interval = VALUES(max_logins_per_interval),
  last_synced = NOW();
\"
  "

  echo "Bot rotation config synced for ${EXPANSION} (realm ${REALM_ID})."
}

configure_bot_rotation_log() {
  derive_db_names || return 1

  echo "Configuring bot rotation logging in ${REALM_DB_NAME} for realm ${REALM_ID}..."

  if pct exec "$DB_CTID" -- bash -s <<__BOT_ROTATION_REMOTE__
set -euo pipefail
export MYSQL_PWD='${DB_ROOT_PASS}'

if ! command -v cron >/dev/null 2>&1; then
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y cron
fi

mariadb -u root '${REALM_DB_NAME}' -e "
CREATE TABLE IF NOT EXISTS bot_rotation_log (
  id                           INT AUTO_INCREMENT PRIMARY KEY,
  realm                        INT NOT NULL,
  snapshot_time                DATETIME NOT NULL,
  server_start_time            DATETIME NULL,
  server_uptime_sec            BIGINT UNSIGNED,
  server_total_uptime_sec      BIGINT UNSIGNED,
  total_bots                   INT,
  total_online                 INT,
  rotating_active              INT,
  online_idle                  INT,
  cycled_off_progressed        INT,
  never_progressed             INT,
  pct_online_rotating          DECIMAL(5,1),
  pct_ever_rotated             DECIMAL(5,1),
  avg_level_rotating           DECIMAL(5,1),
  highest_level                INT,
  avg_equipped_ilvl_bots       DECIMAL(6,1),
  avg_equipped_ilvl_server     DECIMAL(6,1),
  cfg_min_in_world_sec         INT,
  cfg_max_in_world_sec         INT,
  cfg_avg_in_world_sec         DECIMAL(10,1),
  cfg_min_offline_sec          INT,
  cfg_max_offline_sec          INT,
  cfg_avg_offline_sec          DECIMAL(10,1),
  cfg_expected_online_pct      DECIMAL(5,1),
  cfg_min_bots                 INT,
  cfg_max_bots                 INT,
  cfg_account_count            INT,
  cfg_rebalance_min_sec        INT,
  cfg_rebalance_max_sec        INT,
  cfg_max_logins_per_interval  INT,
  observed_avg_online_sec      DECIMAL(10,1),
  observed_avg_offline_sec     DECIMAL(10,1),
  observed_online_sessions     INT,
  observed_offline_sessions    INT,
  KEY idx_bot_rotation_log_realm_time (realm, snapshot_time)
);

ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS realm INT NOT NULL AFTER id;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS server_start_time DATETIME NULL AFTER snapshot_time;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS server_uptime_sec BIGINT UNSIGNED AFTER server_start_time;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS server_total_uptime_sec BIGINT UNSIGNED AFTER server_uptime_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS online_idle INT AFTER rotating_active;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cycled_off_progressed INT AFTER online_idle;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS never_progressed INT AFTER cycled_off_progressed;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS avg_equipped_ilvl_bots DECIMAL(6,1) AFTER highest_level;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS avg_equipped_ilvl_server DECIMAL(6,1) AFTER avg_equipped_ilvl_bots;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_min_in_world_sec INT AFTER avg_equipped_ilvl_server;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_max_in_world_sec INT AFTER cfg_min_in_world_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_avg_in_world_sec DECIMAL(10,1) AFTER cfg_max_in_world_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_min_offline_sec INT AFTER cfg_avg_in_world_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_max_offline_sec INT AFTER cfg_min_offline_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_avg_offline_sec DECIMAL(10,1) AFTER cfg_max_offline_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_expected_online_pct DECIMAL(5,1) AFTER cfg_avg_offline_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_min_bots INT AFTER cfg_expected_online_pct;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_max_bots INT AFTER cfg_min_bots;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_account_count INT AFTER cfg_max_bots;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_rebalance_min_sec INT AFTER cfg_account_count;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_rebalance_max_sec INT AFTER cfg_rebalance_min_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS cfg_max_logins_per_interval INT AFTER cfg_rebalance_max_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS observed_avg_online_sec DECIMAL(10,1) AFTER cfg_max_logins_per_interval;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS observed_avg_offline_sec DECIMAL(10,1) AFTER observed_avg_online_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS observed_online_sessions INT AFTER observed_avg_offline_sec;
ALTER TABLE bot_rotation_log ADD COLUMN IF NOT EXISTS observed_offline_sessions INT AFTER observed_online_sessions;

CREATE TABLE IF NOT EXISTS bot_rotation_config (
  realm                     INT PRIMARY KEY,
  expansion                 VARCHAR(16) NOT NULL,
  char_db                   VARCHAR(64) NOT NULL,
  random_bot_account_prefix VARCHAR(32) NOT NULL DEFAULT 'RNDBOT',
  min_in_world_sec          INT,
  max_in_world_sec          INT,
  min_offline_sec           INT,
  max_offline_sec           INT,
  avg_in_world_sec          DECIMAL(10,1),
  avg_offline_sec           DECIMAL(10,1),
  expected_online_pct       DECIMAL(5,1),
  min_random_bots           INT,
  max_random_bots           INT,
  account_count             INT,
  rebalance_min_sec         INT,
  rebalance_max_sec         INT,
  max_logins_per_interval   INT,
  last_synced               DATETIME NOT NULL
);

CREATE TABLE IF NOT EXISTS bot_rotation_state (
  realm              INT NOT NULL,
  bot_guid           INT UNSIGNED NOT NULL,
  account_id         INT UNSIGNED NOT NULL,
  bot_name           VARCHAR(32) NOT NULL DEFAULT '',
  char_db            VARCHAR(64) NOT NULL,
  last_online        TINYINT(1) NOT NULL DEFAULT 0,
  last_change_time   DATETIME NOT NULL,
  last_seen_time     DATETIME NOT NULL,
  last_online_start  DATETIME NULL,
  last_offline_start DATETIME NULL,
  online_seconds     BIGINT UNSIGNED NOT NULL DEFAULT 0,
  offline_seconds    BIGINT UNSIGNED NOT NULL DEFAULT 0,
  online_sessions    INT UNSIGNED NOT NULL DEFAULT 0,
  offline_sessions   INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (realm, bot_guid),
  KEY idx_bot_rotation_state_realm (realm)
);

CREATE TABLE IF NOT EXISTS bot_rotation_ilvl_log (
  id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  realm               INT NOT NULL,
  snapshot_time       DATETIME NOT NULL,
  bot_guid            INT UNSIGNED NOT NULL,
  bot_name            VARCHAR(32) NOT NULL DEFAULT '',
  account_id          INT UNSIGNED NOT NULL,
  char_db             VARCHAR(64) NOT NULL,
  level               TINYINT UNSIGNED NOT NULL DEFAULT 0,
  online              TINYINT(1) NOT NULL DEFAULT 0,
  avg_equipped_ilvl   DECIMAL(6,1) NULL,
  equipped_item_count TINYINT UNSIGNED NOT NULL DEFAULT 0,
  KEY idx_bot_rotation_ilvl_log_realm_time (realm, snapshot_time),
  KEY idx_bot_rotation_ilvl_log_bot_time (realm, bot_guid, snapshot_time)
);
"

cat > /usr/local/bin/spp-bot-rotation-log.sh <<'EOF'
#!/bin/bash
set -euo pipefail
export MYSQL_PWD='${DB_ROOT_PASS}'

REALM_DB='${REALM_DB_NAME}'

db_exists() {
  mariadb -u root -Nse "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='\$1'" | grep -qx "\$1"
}

mariadb -u root "\$REALM_DB" -Nse "
  SELECT realm,
         char_db,
         random_bot_account_prefix,
         COALESCE(min_in_world_sec, 0),
         COALESCE(max_in_world_sec, 0),
         COALESCE(min_offline_sec, 0),
         COALESCE(max_offline_sec, 0),
         COALESCE(min_random_bots, 0),
         COALESCE(max_random_bots, 0),
         COALESCE(account_count, 0),
         COALESCE(rebalance_min_sec, 0),
         COALESCE(rebalance_max_sec, 0),
         COALESCE(max_logins_per_interval, 0)
  FROM bot_rotation_config
  ORDER BY realm
" | while IFS=$'\t' read -r realm char_db prefix min_in max_in min_off max_off min_bots max_bots account_count rebalance_min rebalance_max max_logins; do
  [[ -z "\${realm}" || -z "\${char_db}" ]] && continue
  db_exists "\${char_db}" || continue
  world_db="\${char_db%characters}mangos"
  db_exists "\${world_db}" || continue

  avg_in=\$(awk "BEGIN { printf \"%.1f\", (\${min_in} + \${max_in}) / 2 }")
  avg_off=\$(awk "BEGIN { printf \"%.1f\", (\${min_off} + \${max_off}) / 2 }")
  expected_pct=\$(awk "BEGIN { total=\${avg_in}+\${avg_off}; if (total <= 0) print \"0.0\"; else printf \"%.1f\", (\${avg_in}/total)*100 }")

  mariadb -u root "\${char_db}" -e "
    INSERT IGNORE INTO \${REALM_DB}.bot_rotation_state
      (realm, bot_guid, account_id, bot_name, char_db, last_online, last_change_time, last_seen_time, last_online_start, last_offline_start)
    SELECT
      \${realm},
      c.guid,
      c.account,
      c.name,
      '\${char_db}',
      c.online,
      NOW(),
      NOW(),
      CASE WHEN c.online = 1 THEN NOW() ELSE NULL END,
      CASE WHEN c.online = 0 THEN NOW() ELSE NULL END
    FROM \${char_db}.characters c
    WHERE c.account IN (
      SELECT id FROM \${REALM_DB}.account WHERE username LIKE '\${prefix}%'
    );

    UPDATE \${REALM_DB}.bot_rotation_state s
    JOIN (
      SELECT c.guid, c.account, c.name, c.online
      FROM \${char_db}.characters c
      WHERE c.account IN (
        SELECT id FROM \${REALM_DB}.account WHERE username LIKE '\${prefix}%'
      )
    ) cur ON s.realm = \${realm} AND s.bot_guid = cur.guid
    SET
      s.account_id = cur.account,
      s.bot_name = cur.name,
      s.char_db = '\${char_db}',
      s.online_seconds = s.online_seconds + CASE
        WHEN s.last_online = 1 AND cur.online = 0 THEN TIMESTAMPDIFF(SECOND, s.last_change_time, NOW())
        ELSE 0
      END,
      s.offline_seconds = s.offline_seconds + CASE
        WHEN s.last_online = 0 AND cur.online = 1 THEN TIMESTAMPDIFF(SECOND, s.last_change_time, NOW())
        ELSE 0
      END,
      s.online_sessions = s.online_sessions + CASE
        WHEN s.last_online = 1 AND cur.online = 0 THEN 1
        ELSE 0
      END,
      s.offline_sessions = s.offline_sessions + CASE
        WHEN s.last_online = 0 AND cur.online = 1 THEN 1
        ELSE 0
      END,
      s.last_online_start = CASE
        WHEN s.last_online = 0 AND cur.online = 1 THEN NOW()
        ELSE s.last_online_start
      END,
      s.last_offline_start = CASE
        WHEN s.last_online = 1 AND cur.online = 0 THEN NOW()
        ELSE s.last_offline_start
      END,
      s.last_change_time = CASE
        WHEN s.last_online <> cur.online THEN NOW()
        ELSE s.last_change_time
      END,
      s.last_online = cur.online,
      s.last_seen_time = NOW();

    INSERT INTO \${REALM_DB}.bot_rotation_ilvl_log
      (realm, snapshot_time, bot_guid, bot_name, account_id, char_db, level, online, avg_equipped_ilvl, equipped_item_count)
    SELECT
      \${realm},
      NOW(),
      c.guid,
      c.name,
      c.account,
      '\${char_db}',
      c.level,
      c.online,
      bot_gear.avg_ilvl,
      COALESCE(bot_gear.item_count, 0)
    FROM \${char_db}.characters c
    LEFT JOIN (
      SELECT
        ci.guid,
        ROUND(AVG(it.ItemLevel), 1) AS avg_ilvl,
        COUNT(*) AS item_count
      FROM \${char_db}.character_inventory ci
      JOIN \${world_db}.item_template it ON it.entry = ci.item_template
      WHERE ci.bag = 0
        AND ci.slot IN (0,1,2,4,5,6,7,8,9,10,11,12,13,14,15,16,17)
      GROUP BY ci.guid
    ) bot_gear ON bot_gear.guid = c.guid
    WHERE c.account IN (
      SELECT id FROM \${REALM_DB}.account WHERE username LIKE '\${prefix}%'
    );

    INSERT INTO \${REALM_DB}.bot_rotation_log
      (realm, snapshot_time, server_start_time, server_uptime_sec, server_total_uptime_sec,
       total_bots, total_online, rotating_active, online_idle,
       cycled_off_progressed, never_progressed, pct_online_rotating, pct_ever_rotated,
       avg_level_rotating, highest_level, avg_equipped_ilvl_bots, avg_equipped_ilvl_server,
       cfg_min_in_world_sec, cfg_max_in_world_sec, cfg_avg_in_world_sec,
       cfg_min_offline_sec, cfg_max_offline_sec, cfg_avg_offline_sec,
       cfg_expected_online_pct, cfg_min_bots, cfg_max_bots, cfg_account_count,
       cfg_rebalance_min_sec, cfg_rebalance_max_sec, cfg_max_logins_per_interval,
       observed_avg_online_sec, observed_avg_offline_sec,
       observed_online_sessions, observed_offline_sessions)
    SELECT
      \${realm},
      NOW(),
      FROM_UNIXTIME(uptime_info.starttime),
      uptime_info.current_uptime_sec,
      uptime_info.total_uptime_sec,
      COUNT(*),
      COALESCE(SUM(c.online = 1), 0),
      COALESCE(SUM(c.online = 1 AND c.xp > 0), 0),
      COALESCE(SUM(c.online = 1 AND c.xp = 0), 0),
      COALESCE(SUM(c.online = 0 AND c.xp > 0), 0),
      COALESCE(SUM(c.online = 0 AND c.xp = 0), 0),
      ROUND(COALESCE(SUM(c.online = 1 AND c.xp > 0) / NULLIF(SUM(c.online = 1), 0) * 100, 0), 1),
      ROUND(COALESCE(SUM(c.xp > 0) / NULLIF(COUNT(*), 0) * 100, 0), 1),
      ROUND(AVG(CASE WHEN c.xp > 0 THEN c.level END), 1),
      MAX(CASE WHEN c.xp > 0 THEN c.level END),
      bot_ilvl.avg_equipped_ilvl_bots,
      realm_ilvl.avg_equipped_ilvl_server,
      \${min_in},
      \${max_in},
      \${avg_in},
      \${min_off},
      \${max_off},
      \${avg_off},
      \${expected_pct},
      \${min_bots},
      \${max_bots},
      \${account_count},
      \${rebalance_min},
      \${rebalance_max},
      \${max_logins},
      obs.avg_online_sec,
      obs.avg_offline_sec,
      obs.total_online_sessions,
      obs.total_offline_sessions
    FROM \${char_db}.characters c
    CROSS JOIN (
      SELECT
        ROUND(SUM(online_seconds) / NULLIF(SUM(online_sessions), 0), 1) AS avg_online_sec,
        ROUND(SUM(offline_seconds) / NULLIF(SUM(offline_sessions), 0), 1) AS avg_offline_sec,
        COALESCE(SUM(online_sessions), 0) AS total_online_sessions,
        COALESCE(SUM(offline_sessions), 0) AS total_offline_sessions
      FROM \${REALM_DB}.bot_rotation_state
      WHERE realm = \${realm}
    ) obs
    CROSS JOIN (
      SELECT ROUND(AVG(per_bot.avg_ilvl), 1) AS avg_equipped_ilvl_bots
      FROM (
        SELECT ci.guid, AVG(it.ItemLevel) AS avg_ilvl
        FROM \${char_db}.character_inventory ci
        JOIN \${world_db}.item_template it ON it.entry = ci.item_template
        WHERE ci.bag = 0
          AND ci.slot IN (0,1,2,4,5,6,7,8,9,10,11,12,13,14,15,16,17)
          AND ci.guid IN (
            SELECT guid
            FROM \${char_db}.characters
            WHERE account IN (
              SELECT id FROM \${REALM_DB}.account WHERE username LIKE '\${prefix}%'
            )
          )
        GROUP BY ci.guid
      ) per_bot
    ) bot_ilvl
    CROSS JOIN (
      SELECT ROUND(AVG(per_char.avg_ilvl), 1) AS avg_equipped_ilvl_server
      FROM (
        SELECT ci.guid, AVG(it.ItemLevel) AS avg_ilvl
        FROM \${char_db}.character_inventory ci
        JOIN \${world_db}.item_template it ON it.entry = ci.item_template
        WHERE ci.bag = 0
          AND ci.slot IN (0,1,2,4,5,6,7,8,9,10,11,12,13,14,15,16,17)
        GROUP BY ci.guid
      ) per_char
    ) realm_ilvl
    CROSS JOIN (
      SELECT
        COALESCE(MAX(CASE WHEN u.starttime = latest.max_starttime THEN u.starttime END), 0) AS starttime,
        COALESCE(MAX(CASE WHEN u.starttime = latest.max_starttime THEN u.uptime END), 0) AS current_uptime_sec,
        COALESCE(SUM(u.uptime), 0) AS total_uptime_sec
      FROM \${REALM_DB}.uptime u
      CROSS JOIN (
        SELECT COALESCE(MAX(starttime), 0) AS max_starttime
        FROM \${REALM_DB}.uptime
        WHERE realmid = \${realm}
      ) latest
      WHERE u.realmid = \${realm}
    ) uptime_info
    WHERE c.account IN (
      SELECT id FROM \${REALM_DB}.account WHERE username LIKE '\${prefix}%'
    );
  "
done
EOF

chmod 755 /usr/local/bin/spp-bot-rotation-log.sh

cat > /etc/cron.d/spp-bot-rotation-log <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/15 * * * * root /usr/local/bin/spp-bot-rotation-log.sh >/var/log/spp-bot-rotation-log.log 2>&1
EOF

chmod 644 /etc/cron.d/spp-bot-rotation-log
systemctl enable cron
systemctl restart cron
__BOT_ROTATION_REMOTE__
  then
    sync_bot_rotation_config || return 1
    echo "Bot rotation logging configured."
  else
    echo "Bot rotation logging setup FAILED."
    return 1
  fi
}

install_realm() {
  derive_db_names || return 1

  if is_vmangos; then
    echo "Installing realm DB via dedicated vMaNGOS logon flow..."
    local DB_IP
    DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')

    if pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      export MYSQL_PWD='${DB_LAN_PASS}'
      SQL_BASE='/opt/source/sql'

      mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' -e \"
        DROP DATABASE IF EXISTS ${REALM_DB_NAME};
        CREATE DATABASE ${REALM_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      \"

      mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${REALM_DB_NAME}' < \"\$SQL_BASE/logon.sql\"

      for f in \$(find \"\$SQL_BASE/migrations\" -maxdepth 1 -type f -name '*_logon.sql' | sort); do
        mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${REALM_DB_NAME}' < \"\$f\"
      done

      for f in /opt/spp-assets/vmangos/sql/logon/*.sql; do
        [[ -f \"\$f\" ]] && mariadb --host='${DB_IP}' --port=3306 --user='${DB_LAN_USER}' '${REALM_DB_NAME}' < \"\$f\"
      done
    "; then
      echo "Realm DB installed successfully."
    else
      echo "Realm DB install FAILED."
      return 1
    fi

    configure_bot_rotation_log || return 1
    write_version "$(realm_version_owner)_realm_version.spp" "${VERSION_MAP[$EXPANSION:REALM]}"
    read -p "Press Enter to return..." _
    return 0
  fi

  pin_master_expansion
  pin_master_realmd_db || return 1
  derive_db_names || return 1

  echo "Installing realm DB via shared classic-family realmd flow..."

  if pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"

    mariadb -u root < \"\$BASE/drop_realmd.sql\"
    mariadb -u root \"${REALM_DB_NAME}\" < \"\$BASE/realmd.sql\"
    mariadb -u root \"${REALM_DB_NAME}\" < \"\$BASE/realmlist.sql\"

    for f in \"\$BASE/realmd\"/*.sql; do
      [ -f \"\$f\" ] && mariadb -u root \"${REALM_DB_NAME}\" < \"\$f\"
    done

    for dir in \$(ls -1 \"\$BASE/updates/realmd\" | sort -n); do
      for f in \"\$BASE/updates/realmd/\$dir\"/*.sql; do
        [ -f \"\$f\" ] && mariadb -u root \"${REALM_DB_NAME}\" < \"\$f\"
      done
    done
  "; then
    echo "Realm DB installed successfully."
  else
    echo "Realm DB install FAILED."
    return 1
  fi

  sync_realmd_db_version_markers || return 1
  configure_bot_rotation_log || return 1

  write_version "$(realm_version_owner)_realm_version.spp" "${VERSION_MAP[$EXPANSION:REALM]}"
  read -p "Press Enter to return..." _
}

install_armory() {
  derive_db_names || return 1
  echo "Installing ${EXPANSION}armory..."

  if pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"

    if [ ! -f \"\$BASE/armory.7z\" ]; then
      echo 'armory.7z not found.'
      exit 1
    fi

    cd \"\$BASE\"
    7z x -y armory.7z >/dev/null
    mariadb -u root < armory.sql
    rm -f armory.sql
  "; then
    echo "${EXPANSION} armory DB installed successfully."
  else
    echo "${EXPANSION} armory DB install FAILED."
    return 1
  fi
}


reset_characters() {
  derive_db_names || return 1

  read -p "Char Reset Are you sure (Y/N)? " CONFIRM
  [[ "$CONFIRM" != "Y" ]] && return

  install_char

  pct exec "$DB_CTID" -- bash -c "
  set -euo pipefail
  export MYSQL_PWD='${DB_ROOT_PASS}'

  BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"
  WORLD_DB=\"${WORLD_DB}\"
  CHAR_DB=\"${CHAR_DB_NAME}\"

  mariadb -u root \"\$WORLD_DB\" < \"\$BASE/world/ai_playerbot_travel_nodes.sql\"
  mariadb -u root \"\$WORLD_DB\" < \"\$BASE/world/ai_playerbot_texts.sql\"
  mariadb -u root \"\$WORLD_DB\" < \"\$BASE/world/ai_playerbot_named_location.sql\"
  cd \"\$BASE/playerbot\"
  7z x -y characters_ai_playerbot_equip_cache.7z >/dev/null
  mariadb -u root \"\$CHAR_DB\" < characters_ai_playerbot_equip_cache.sql
  mariadb -u root \"\$CHAR_DB\" < characters_ai_playerbot_rnditem_cache.sql
  mariadb -u root \"\$CHAR_DB\" < characters_ai_playerbot_rarity_cache.sql

  rm -f characters_ai_playerbot_equip_cache.sql

  echo 'Characters reset Done.'
  "
}
install_locales() {
  derive_db_names || return 1

  echo "Available locales:"
  echo "fr de es mx ru ko ch tw"
  read -p "Enter locales to install (space separated): " LOCALES
  read -p "Replace English? (y/N): " REPLACE

  pct exec "$DB_CTID" -- bash -c "
  set -euo pipefail
  export MYSQL_PWD='${DB_ROOT_PASS}'

  BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"
  WORLD_DB=\"${WORLD_DB}\"

  echo 'Extracting locales...'
  cd \"\$BASE\"
  7z x -y locales.7z >/dev/null

  echo 'Preparing world DB...'
  mariadb -u root \"\$WORLD_DB\" < \"\$BASE/locales/prepare.sql\"
  mariadb -u root \"\$WORLD_DB\" < \"\$BASE/locales/broadcast_text_locale.sql\"

  for LOC in ${LOCALES}; do
    case \$LOC in
      fr) DIR='French' ;;
      de) DIR='German' ;;
      es) DIR='Spanish' ;;
      mx) DIR='Spanish_South_American' ;;
      ru) DIR='Russian' ;;
      ko) DIR='Korean' ;;
      ch) DIR='Chinese' ;;
      tw) DIR='Taiwanese' ;;
      *) continue ;;
    esac

    echo \"Installing \$LOC...\"
    for f in \"\$BASE/locales/\$DIR\"/*.sql; do
      [ -f \"\$f\" ] && mariadb -u root \"\$WORLD_DB\" < \"\$f\"
    done

    if [[ \"${REPLACE}\" == \"y\" ]]; then
      echo \"Replacing English with \$LOC...\"
      mariadb -u root \"\$WORLD_DB\" < \"\$BASE/locales/replace_\${LOC}.sql\"
    fi
  done

  echo 'Updating quest locales...'
  mariadb -u root \"\$WORLD_DB\" < \"\$BASE/locales/quest_locale_all.sql\"

  rm -rf \"\$BASE/locales\"

  echo 'Locales complete.'
  "
}
update_db_type() {

  local TYPE="$1"

  if is_vmangos; then
    echo "vMaNGOS uses a dedicated SQL/update lane."
    echo "Incremental DB update automation is not implemented for vmangos yet."
    return 0
  fi

  local BASE="/opt/spp-sql/sql/${EXPANSION}/updates/${TYPE}"
  local VERSION_FILE="/opt/${EXPANSION}_${TYPE}_version.spp"

  case "$TYPE" in
    realmd)     TARGET_DB="$REALM_DB" ;;
    characters) TARGET_DB="$CHAR_DB" ;;
    playerbot)  TARGET_DB="$WORLD_DB" ;;
    website)    TARGET_DB="$REALM_DB" ;;
    *) echo "Unknown DB type: $TYPE"; return 1 ;;
  esac

  CURRENT=$(pct exec "$DB_CTID" -- cat "$VERSION_FILE" 2>/dev/null || echo 0)

  LATEST=$(pct exec "$DB_CTID" -- bash -c \
    "ls $BASE 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1")

  [[ -z "$LATEST" ]] && echo "No updates for $TYPE." && return
  (( LATEST <= CURRENT )) && echo "$TYPE already at v$CURRENT." && return

  echo "Updating $TYPE DB: $CURRENT -> $LATEST"

  for DIR in $(pct exec "$DB_CTID" -- bash -c \
      "ls $BASE | grep -E '^[0-9]+$' | sort -n"); do

    if (( DIR > CURRENT )); then
      echo "Applying $TYPE update $DIR..."

      for f in $(pct exec "$DB_CTID" -- bash -c "ls $BASE/$DIR/*.sql"); do
        pct exec "$DB_CTID" -- mariadb \
          -u root -p"$DB_ROOT_PASS" "$TARGET_DB" < "$f"
      done

      pct exec "$DB_CTID" -- bash -c "echo $DIR > $VERSION_FILE"
    fi
  done

  echo "$TYPE updated to v$LATEST."
}

install_data() {
  derive_db_names || return 1

  if is_vmangos; then
    local ASSET_DIR="/opt/spp-assets/vmangos/data"

    pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      test -d '$ASSET_DIR'
      mkdir -p '$INSTALL_DIR/data'
      rsync -a --delete '$ASSET_DIR/' '$INSTALL_DIR/data/'
    "

    local MAP_EXPECTED="${VERSION_MAP[$EXPANSION:MAPS]}"
    local INSTALL_DATE
    INSTALL_DATE=$(date +%F_%H:%M)
    write_version "${EXPANSION}_maps_version.spp" "${MAP_EXPECTED}|${INSTALL_DATE}"
    return 0
  fi

  local URL="https://github.com/celguar/spp-classics-cmangos/releases/download/v2.0/${MAP_KEY}.7z"
  local IDIR="/srv/mangos-${EXPANSION}"

  pct exec "$GAME_CTID" -- bash -c "
    set -euo pipefail
    cd '$IDIR'
    mkdir -p data
    cd data
    echo 'Downloading map package...'
    wget -c --show-progress --no-check-certificate '$URL' -O ${EXPANSION}.7z
    if [[ ! -f ${EXPANSION}.7z ]]; then
      echo 'Download failed.'
      exit 1
    fi
    echo 'Extracting...'
    7z x -y ${EXPANSION}.7z >/dev/null
    rm ${EXPANSION}.7z
    echo 'Maps ready.'
  "

  local MAP_EXPECTED="${VERSION_MAP[$EXPANSION:MAPS]}"
  local INSTALL_DATE
  INSTALL_DATE=$(date +%F_%H:%M)
  write_version "${EXPANSION}_maps_version.spp" "${MAP_EXPECTED}|${INSTALL_DATE}"
}

full_install() {
  derive_db_names || return 1

  echo "Stopping services..."
  stop_mangosd_managed "full-install"

  if is_master; then
    pct exec "$LOGIN_CTID" -- systemctl stop realmd 2>/dev/null || true
    pct exec "$WEB_CTID" -- systemctl stop apache2 2>/dev/null || true
  fi

  echo "Removing old install directory..."
  pct exec "$GAME_CTID" -- rm -rf "$INSTALL_DIR"

  if is_master; then
    pct exec "$LOGIN_CTID" -- rm -rf "$INSTALL_DIR"
    pct exec "$WEB_CTID" -- rm -rf /var/www/html/*
  fi

  echo "Removing old build + source..."
  pct exec "$GAME_CTID" -- rm -rf /opt/source /opt/spp-settings

  echo "Removing version trackers..."
  pct exec "$DB_CTID" -- rm -f \
    "/opt/${EXPANSION}_core_version.spp" \
    "/opt/${EXPANSION}_world_version.spp" \
    "/opt/${EXPANSION}_chars_version.spp" \
    "/opt/${EXPANSION}_logs_version.spp" \
    "/opt/${EXPANSION}_maps_version.spp"

  if owns_realm_install_lane; then
    pct exec "$DB_CTID" -- rm -f \
      "/opt/${EXPANSION}_realm_version.spp" \
      "/opt/${EXPANSION}_website_version.spp"
  fi

  echo "Dropping expansion databases..."
  pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root -e \"DROP DATABASE IF EXISTS ${WORLD_DB};\"
    mariadb -u root -e \"DROP DATABASE IF EXISTS ${CHAR_DB_NAME};\"
    mariadb -u root -e \"DROP DATABASE IF EXISTS ${LOG_DB_NAME};\"
    mariadb -u root -e \"DROP DATABASE IF EXISTS ${EXPANSION}armory;\"
  "

  # Shared classic-family expansions only drop the master realm DB; vMaNGOS drops its dedicated realm DB.
  if owns_realm_install_lane; then
    pct exec "$DB_CTID" -- bash -c "
      export MYSQL_PWD='${DB_ROOT_PASS}'
      mariadb -u root -e \"DROP DATABASE IF EXISTS ${REALM_DB_NAME};\"
    "
    if ! is_vmangos; then
      pin_master_expansion
    fi
  fi

  comp_server

  if owns_realm_install_lane; then
    install_db
  else
    install_db_no_realm
  fi

  install_data
  service_create

  if is_master; then
    install_website
  fi

  fix_realm_entry
  fix_mariadb_bind
  create_lan_db_user

  echo
  echo "Full install complete for $EXPANSION."
  read -p "Press Enter to continue..."
}

sync_settings_repo() {
  derive_db_names || return 1
  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt
    rm -rf spp-settings
    git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/japtenks/spp-cmangos-prox.git spp-settings
    cd spp-settings
    git sparse-checkout set Settings/${SETTINGS_KEY}
  "
}


stack_control_menu() {
  while true; do
    #clear
    print_banner
    stat_state
    echo
    echo "Bot rotation cron: $BOT_ROTATION_STATUS"
    echo
    #echo "$GAME_CTID - $EXPANSION Control"
    #echo "Status: $STACK_STATUS"
    #echo
    echo "1 - Status"
    echo "2 - $STACK_ACTION"
    echo "0 - Back"
    echo

    read -p "Selection: " CTRL

    case "$CTRL" in
      1) get_status ;;
      2)
        if [[ "$STACK_STATUS" == "Running" ]]; then
          stop_world
        else
          start_stack
        fi
        ;;
      0) return ;;
    esac
  done
}
get_status() {

auto_detect_stack
GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"

  GREEN="\e[32m"
  RESET="\e[0m"

  echo
  echo "=== STACK STATUS ==="
  echo "Bot rotation cron: $(get_bot_rotation_status)"

  for CT in "$LOGIN_CTID" "$GAME_CTID" "$WEB_CTID" "$DB_CTID"; do

    [ -z "$CT" ] && continue

    NAME=$(pct config "$CT" | awk -F': ' '/hostname/ {print $2}')
    STATE=$(pct status "$CT" | awk '{print $2}')

    echo
    echo "CT $CT ($NAME) - $STATE"

    [ "$STATE" != "running" ] && continue

    for svc in mangosd.service realmd.service mariadb.service apache2.service; do

      STATUS=$(pct exec "$CT" -- systemctl is-active "$svc" 2>/dev/null || true)

      if [ "$STATUS" = "active" ]; then

        start_time=$(pct exec "$CT" -- systemctl show -p ActiveEnterTimestamp "$svc" | cut -d= -f2)
        start_epoch=$(pct exec "$CT" -- date -d "$start_time" +%s)
        now_epoch=$(pct exec "$CT" -- date +%s)

        diff=$((now_epoch - start_epoch))
        days=$((diff/86400))
        hours=$(((diff%86400)/3600))
        mins=$(((diff%3600)/60))

        if [ "$days" -gt 0 ]; then
          runtime="${days}d ${hours}h ${mins}m"
        elif [ "$hours" -gt 0 ]; then
          runtime="${hours}h ${mins}m"
        else
          runtime="${mins}m"
        fi

        echo -e "  $svc -> ${GREEN}active${RESET} (up $runtime)"
      fi

    done

  done

  echo
  read -p "Press Enter to return..." _
}
stop_world() {
  if [[ "$(pct status "$GAME_CTID" | awk '{print $2}')" != "running" ]]; then
    echo "World already stopped."
    return
  fi

  echo "Stopping World..."
  stop_mangosd_managed "stack-stop"
  pct stop "$GAME_CTID"
}
start_stack() {

for CT in "$DB_CTID" "$WEB_CTID" "$LOGIN_CTID" "$GAME_CTID"; do
  STATE=$(pct status "$CT" | awk '{print $2}')
  if [[ "$STATE" != "running" ]]; then
    pct start "$CT"
    pct exec "$CT" -- bash -c "while ! systemctl is-system-running --quiet 2>/dev/null; do sleep 1; done"
  fi
done

pct exec "$DB_CTID" -- systemctl start mariadb
pct exec "$LOGIN_CTID" -- systemctl start realmd
pct exec "$WEB_CTID" -- systemctl start apache2
start_mangosd_managed "stack-start"
sync_bot_rotation_config || true

}

server_info_menu() {
  ensure_expansion_context || return 1
  auto_detect_stack
  LOGIN_IP=$(pct exec "$LOGIN_CTID" -- hostname -I | awk '{print $1}')

  while true; do
    #clear
    print_banner
    echo
    echo "-------- Server Info --------"
    echo
    echo "MySQL Host: $DB_HOST  Port: 3306"
    echo "      User: $DB_LAN_USER"
    echo
    echo "WoW Client:"
    echo "  set realmlist $LOGIN_IP"
    echo
    echo "1 - World Settings"
    echo "2 - Bots Settings"
    echo "3 - RealmD Settings"
    echo
    if is_vmangos; then
      echo "4 - Change Server Address"
      echo "5 - Change Realm Name"
    else
      echo "4 - Change Server Address (use website for shared realms)"
      echo "5 - Change Realm Name (use website for shared realms)"
    fi
    echo "6 - Other Settings"

    echo "7 - Crash Logs"
    echo "8 - Analyze Crash (GDB)"
    echo
    echo "0 - Back"
    echo

    read -p "Enter your choice: " INFO

    case "$INFO" in
      1) edit_world_settings ;;
      2) edit_bot_settings ;;
	  3) edit_realmd_settings ;;
      4) change_server_address ;;
      5) change_realm_name ;;
      6) edit_other_settings ;;

      7) view_crash_logs ;;
      8) analyze_crash ;;
      0) return ;;
    esac
  done
}
edit_world_settings() {
  derive_db_names || return 1
  pct exec "$GAME_CTID" -- nano "$INSTALL_DIR/etc/mangosd.conf"
}
edit_bot_settings() {
  derive_db_names || return 1
  pct exec "$GAME_CTID" -- nano "$INSTALL_DIR/etc/aiplayerbot.conf"
  echo
  echo "Syncing bot rotation config..."
  sync_bot_rotation_config
  read -p "Press Enter..." _
}
edit_realmd_settings() {
  derive_db_names || return 1
  pct exec "$LOGIN_CTID" -- nano "$INSTALL_DIR/etc/realmd.conf"
}
edit_other_settings() {
  derive_db_names || return 1
  local GAME_ETC="$INSTALL_DIR/etc"
  local LOGIN_ETC="$INSTALL_DIR/etc"
  local -a LABELS=()
  local -a TARGETS=()
  local -a PATHS=()

  while IFS= read -r conf; do
    [[ -z "$conf" ]] && continue
    case "$(basename "$conf")" in
      mangosd.conf|aiplayerbot.conf) continue ;;
    esac
    LABELS+=("Game: $(basename "$conf")")
    TARGETS+=("$GAME_CTID")
    PATHS+=("$conf")
  done < <(pct exec "$GAME_CTID" -- bash -lc "find '$GAME_ETC' -maxdepth 1 -type f -name '*.conf' | sort" 2>/dev/null)

  while IFS= read -r conf; do
    [[ -z "$conf" ]] && continue
    case "$(basename "$conf")" in
      realmd.conf) continue ;;
    esac
    LABELS+=("Login: $(basename "$conf")")
    TARGETS+=("$LOGIN_CTID")
    PATHS+=("$conf")
  done < <(pct exec "$LOGIN_CTID" -- bash -lc "find '$LOGIN_ETC' -maxdepth 1 -type f -name '*.conf' | sort" 2>/dev/null)

  if (( ${#LABELS[@]} == 0 )); then
    echo "No additional config files found."
    read -p "Press Enter to continue..." _
    return
  fi

  while true; do
    echo
    echo "Other Config Files"
    echo
    local i
    for ((i=0; i<${#LABELS[@]}; i++)); do
      printf "%d - %s\n" "$((i+1))" "${LABELS[$i]}"
    done
    echo "0 - Back"
    echo

    read -p "Selection: " OTHER_SEL
    [[ "$OTHER_SEL" == "0" ]] && return

    if [[ "$OTHER_SEL" =~ ^[0-9]+$ ]] && (( OTHER_SEL >= 1 && OTHER_SEL <= ${#LABELS[@]} )); then
      local idx=$((OTHER_SEL-1))
      pct exec "${TARGETS[$idx]}" -- nano "${PATHS[$idx]}"
    else
      echo "Invalid selection."
    fi
  done
}
change_server_address() {
  derive_db_names || return 1

  if ! is_vmangos; then
    echo "Use the website admin page to change shared Classic/TBC/WotLK realm addresses."
    read -p "Press Enter..." _
    return 0
  fi

  read -p "Enter new public IP: " NEWIP

  pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root ${REALM_DB_NAME} -e \"
      UPDATE realmlist SET address='${NEWIP}' WHERE id=${REALM_ID};
    \"
  "

  echo "Realm address updated."
  read -p "Press Enter..."
}
change_realm_name() {
  derive_db_names || return 1

  if ! is_vmangos; then
    echo "Use the website admin page to change shared Classic/TBC/WotLK realm names."
    read -p "Press Enter..." _
    return 0
  fi

  read -p "Enter new realm name: " NEWNAME

  pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root ${REALM_DB_NAME} -e \"
      UPDATE realmlist SET name='${NEWNAME}' WHERE id=${REALM_ID};
    \"
  "

  echo "Realm name updated."
  read -p "Press Enter..."
}
view_crash_logs() {
  derive_db_names || return 1
  local BIN_DIR="$INSTALL_DIR/bin"

  echo "=== Core files in $BIN_DIR ==="
  pct exec "$GAME_CTID" -- bash -c "
    ls -lht '$BIN_DIR'/core* 2>/dev/null || echo 'None found.'
  "

  echo
  echo "=== systemd-coredump entries ==="
  pct exec "$GAME_CTID" -- bash -c "
    coredumpctl list mangosd 2>/dev/null || echo '(systemd-coredump not available)'
  "

  read -p "Press Enter..."
}

analyze_crash() {
  derive_db_names || return 1
  local BIN_DIR="$INSTALL_DIR/bin"
  local BINARY="$BIN_DIR/mangosd"

  # Prefer file-based cores (written to WorkingDirectory by LimitCORE=infinity)
  local CORES
  CORES=$(pct exec "$GAME_CTID" -- bash -c "
    ls -t '$BIN_DIR'/core* 2>/dev/null || true
  ")

  # Fall back to systemd-coredump
  local COREDUMP_LIST
  COREDUMP_LIST=$(pct exec "$GAME_CTID" -- bash -c "
    coredumpctl list mangosd 2>/dev/null || true
  ")

  if [[ -z "$CORES" && -z "$COREDUMP_LIST" ]]; then
    echo "No core dumps found."
    echo "Ensure 'Autostart services creation' has been run to apply LimitCORE=infinity."
    echo "Core files will appear in: $BIN_DIR/core.<pid>"
    read -p "Press Enter..."
    return
  fi

  if [[ -n "$CORES" ]]; then
    echo "Available core dumps:"
    pct exec "$GAME_CTID" -- bash -c "ls -lht '$BIN_DIR'/core* 2>/dev/null"
    echo
    local LATEST
    LATEST=$(echo "$CORES" | head -1)
    read -p "Core file to load [$LATEST]: " CORE_FILE
    CORE_FILE="${CORE_FILE:-$LATEST}"
    echo
    echo "Opening GDB. Useful commands:"
    echo "  bt full                 — full backtrace of current thread"
    echo "  thread apply all bt     — backtrace for all threads"
    echo "  info registers          — CPU register state"
    echo "  quit                    — exit GDB"
    echo
    pct exec "$GAME_CTID" -- gdb "$BINARY" "$CORE_FILE"
  else
    echo "systemd-coredump entries for mangosd:"
    echo "$COREDUMP_LIST"
    echo
    echo "Opening most recent mangosd core via coredumpctl..."
    pct exec "$GAME_CTID" -- coredumpctl gdb mangosd
  fi
}



echo "DEBUG: reaching main" >&2

#program starts here
main
